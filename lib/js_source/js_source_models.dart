import 'dart:convert';

/// 一个已导入的 JS 数据源（CatPawOpen / CatVodOpen 规范）。
///
/// 与 thlredguo 的同名类一致，只是把「版本比较」保留下来：内置源升级、
/// 用户导入同名源时，靠它判断该不该覆盖。
class JsSourceMeta {
  static final _versionPattern = RegExp(
    r'^(\d{1,9})\.(\d{1,9})\.(\d{1,9})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );

  /// 从源码里读 `version: "x.y.z"`，用于和已安装版本比较。
  static String scriptVersion(String script) =>
      RegExp(
        r'''\bversion\s*:\s*["']([^"']+)["']''',
      ).firstMatch(script)?.group(1) ??
      '';

  static bool isVersionNewer(String candidate, String baseline) {
    if (candidate.length > 128 || baseline.length > 128) return false;
    final a = _versionPattern.firstMatch(candidate);
    final b = _versionPattern.firstMatch(baseline);
    if (a == null || b == null) return false;
    for (var index = 1; index <= 3; index++) {
      final order = int.parse(
        a.group(index)!,
      ).compareTo(int.parse(b.group(index)!));
      if (order != 0) return order > 0;
    }
    final ap = a.group(4);
    final bp = b.group(4);
    if (ap == null || bp == null) return ap == null && bp != null;
    final ai = ap.split('.');
    final bi = bp.split('.');
    for (var index = 0; index < ai.length && index < bi.length; index++) {
      final left = ai[index];
      final right = bi[index];
      if (left == right) continue;
      final an = RegExp(r'^\d+$').hasMatch(left);
      final bn = RegExp(r'^\d+$').hasMatch(right);
      if (an != bn) return !an;
      if (an) {
        final digitsA = left.replaceFirst(RegExp(r'^0+'), '');
        final digitsB = right.replaceFirst(RegExp(r'^0+'), '');
        final order = digitsA.length == digitsB.length
            ? digitsA.compareTo(digitsB)
            : digitsA.length.compareTo(digitsB.length);
        if (order != 0) return order > 0;
      } else {
        return left.compareTo(right) > 0;
      }
    }
    return ai.length > bi.length;
  }

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String type;
  final String icon;
  final bool requiresAuth;
  final List<String> features;

  /// 脚本在本地沙箱目录里的文件名（`hongguo.js`）。
  final String fileName;

  const JsSourceMeta({
    required this.id,
    required this.name,
    this.version = '1.0.0',
    this.description = '',
    this.author = '',
    this.type = 'video',
    this.icon = '',
    this.requiresAuth = false,
    this.features = const [],
    this.fileName = '',
  });

  factory JsSourceMeta.fromJson(Map<String, dynamic> json) {
    return JsSourceMeta(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '1.0.0',
      description: json['description'] as String? ?? '',
      author: json['author'] as String? ?? '',
      type: json['type'] as String? ?? 'video',
      icon: json['icon'] as String? ?? '',
      requiresAuth: json['requiresAuth'] as bool? ?? false,
      features:
          (json['features'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      fileName: json['fileName'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'description': description,
    'author': author,
    'type': type,
    'icon': icon,
    'requiresAuth': requiresAuth,
    'features': features,
    'fileName': fileName,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is JsSourceMeta &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  /// 在站源表里用的 id：加 `js:` 前缀，与内核自带站源、自定义 XBPQ 源
  /// 完全隔开。脚本里的 `meta.id` 仍原样保留在 [id] 里。
  String get sourceId => jsSourceIdOf(id);
}

/// JS 源的站源前缀。用户在源菜单里看到的是一类独立站源，
/// 播放 / 详情 / 搜索都按这个前缀路由到沙箱。
const jsSourcePrefix = 'js:';

String jsSourceIdOf(String id) => '$jsSourcePrefix$id';
bool isJsSourceId(String id) => id.startsWith(jsSourcePrefix);
String jsSourceScriptId(String sourceId) =>
    sourceId.startsWith(jsSourcePrefix)
    ? sourceId.substring(jsSourcePrefix.length)
    : sourceId;

/// 从脚本源码里抽 meta。沙箱不支持在 Dart 侧执行 JS 取 meta（那要先把
/// 引擎跑起来），导入时用正则读 `spider.meta` 的字面量字段——与 thlredguo
/// 的 DartCoreEngine 同一套规则，导入失败时不落盘。
JsSourceMeta? parseJsSourceMeta(String script, String fileName) {
  try {
    final idMatch = RegExp(r'''id:\s*["']([^"']+)["']''').firstMatch(script);
    final nameMatch = RegExp(
      r'''name:\s*["']([^"']+)["']''',
    ).firstMatch(script);
    if (idMatch == null || nameMatch == null) return null;

    final id = idMatch.group(1)!.trim();
    final name = nameMatch.group(1)!.trim();
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(id)) return null;
    if (name.isEmpty) return null;

    final version =
        RegExp(r'''version:\s*["']([^"']+)["']''').firstMatch(script)?.group(1) ??
        '1.0.0';
    final description =
        RegExp(
          r'''description:\s*["']([^"']+)["']''',
        ).firstMatch(script)?.group(1) ??
        '';
    final author =
        RegExp(r'''author:\s*["']([^"']+)["']''').firstMatch(script)?.group(1) ??
        '';

    final features = <String>[];
    final featMatch = RegExp(r'features:\s*\[(.*?)\]').firstMatch(script);
    if (featMatch != null) {
      for (final match in RegExp(
        r'''["']([^"']+)["']''',
      ).allMatches(featMatch.group(1)!)) {
        features.add(match.group(1)!.trim());
      }
    }
    if (features.isEmpty) features.addAll(['search', 'categories']);

    return JsSourceMeta(
      id: id,
      name: name,
      version: version.trim(),
      description: description.trim(),
      author: author.trim(),
      features: features,
      fileName: fileName,
    );
  } catch (_) {
    return null;
  }
}

/// 导入时的文件名校验：只认单层、以 .js 结尾、不含路径分隔符与保留字符。
bool validJsSourceFileName(String name) {
  if (name.isEmpty || name.length > 180) return false;
  if (name.contains('/') || name.contains(r'\') || name.contains('..')) {
    return false;
  }
  if (RegExp(r'[<>:"|?*\x00-\x1F]').hasMatch(name)) return false;
  return name.toLowerCase().endsWith('.js');
}

/// 把脚本正文转成可直接写盘的 UTF-8 文本：有些站点发的是带 BOM 的文件，
/// 带着 BOM 会让 `id:` 正则第一个字符匹配不上。
String normalizeJsScript(String raw) {
  var script = raw;
  if (script.startsWith('\uFEFF')) script = script.substring(1);
  return script.replaceAll('\r\n', '\n');
}

/// 导入结果：成功带上解析出的 meta，失败带上原因，界面直接显示。
class JsImportResult {
  const JsImportResult.ok(this.meta) : error = '';
  const JsImportResult.failed(this.error) : meta = null;
  final JsSourceMeta? meta;
  final String error;
  bool get success => meta != null;
}

/// 把 JSON 编码后的 meta 放进诊断日志用。
String jsMetaSummary(JsSourceMeta meta) => jsonEncode({
  'id': meta.id,
  'name': meta.name,
  'version': meta.version,
});
