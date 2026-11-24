import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 官方脚本的签名参数（`id` + `material`，各为 base64）。
///
/// 官方短剧脚本的 App 接口要求每组请求带 `x-gorgon` / `x-medusa` 之类的
/// 签名头，签名密钥并不在公开脚本里：脚本里留的是两个占位符
/// `__THL_HONGGUO_SIGNING_ID_BASE64__` / `..._MATERIAL_BASE64__`。
///
/// 构建机通过 `--dart-define=HONGGUO_SIGNING_CONFIG={"id":"…","material":"…"}`
/// （GitHub Actions 里是同名 Secret）把参数编译进 App：出厂即带官方源签名，
/// 「我的 › JS 沙箱」不需要再让用户粘贴同一份 JSON。用户仍可在沙箱里填自己的
/// 参数覆盖内置值；装载脚本时做一次字符串替换。两端都把
/// `SOURCE_CONFIGURATION_MISSING` 翻成明确的提示。
class JsSigningProfile {
  static const idToken = '__THL_HONGGUO_SIGNING_ID_BASE64__';
  static const materialToken = '__THL_HONGGUO_SIGNING_MATERIAL_BASE64__';
  static const _key = 'js_source_signing_profile';

  /// 构建时编译进包里的签名参数（见类注释）。未注入时为空字符串。
  static const builtInRaw = String.fromEnvironment('HONGGUO_SIGNING_CONFIG');

  const JsSigningProfile({
    required this.id,
    required this.material,
    this.builtIn = false,
  });

  final String id;
  final String material;

  /// 来自构建时注入，而不是用户在沙箱里粘贴。
  final bool builtIn;

  bool get configured => id.isNotEmpty && material.isNotEmpty;

  /// 解析用户粘贴或构建注入的 JSON。字段长度按脚本里的解码规则校验：
  /// id 解出来 9 字节、material 32 字节，两位都错就直接拒绝，避免装进
  /// 一份看似成功、实际每次请求都失败的配置。
  static JsSigningProfile? parse(String raw) {
    try {
      final value = jsonDecode(raw.trim());
      if (value is! Map) return null;
      final id = value['id']?.toString() ?? '';
      final material = value['material']?.toString() ?? '';
      final idBytes = base64Decode(id);
      final materialBytes = base64Decode(material);
      if (idBytes.length != 9 || materialBytes.length != 32) return null;
      return JsSigningProfile(id: id, material: material);
    } catch (_) {
      return null;
    }
  }

  /// 构建时编译进包的官方源签名参数；没有注入时返回 null。
  static JsSigningProfile? get builtInProfile {
    final profile = parse(builtInRaw);
    return profile == null
        ? null
        : JsSigningProfile(
            id: profile.id,
            material: profile.material,
            builtIn: true,
          );
  }

  /// 用户在沙箱里填的优先，没填则用构建时内置的那份。
  static Future<JsSigningProfile?> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final saved = parse(raw);
        if (saved != null) return saved;
      }
    } catch (_) {
      // 读不到用户配置时退回内置签名，不让沙箱因此变成未配置。
    }
    return builtInProfile;
  }

  static Future<void> save(JsSigningProfile? profile) async {
    final preferences = await SharedPreferences.getInstance();
    if (profile == null || !profile.configured) {
      await preferences.remove(_key);
      return;
    }
    await preferences.setString(
      _key,
      jsonEncode({'id': profile.id, 'material': profile.material}),
    );
  }

  /// 把占位符替换成真参数。没有配置或脚本里没有占位符时原样返回。
  String apply(String script) {
    if (!configured) return script;
    var output = script;
    if (output.contains(idToken)) {
      output = output.replaceAll(idToken, id);
    }
    if (output.contains(materialToken)) {
      output = output.replaceAll(materialToken, material);
    }
    return output;
  }
}
