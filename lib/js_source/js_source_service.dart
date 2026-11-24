import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'js_source_models.dart';
import 'js_source_presets.dart';
import 'js_signing_profile.dart';

/// JS 数据源（脚本）的安装、扫描与启用状态。
///
/// 移植自 thlredguo 的 `JsSourceService`，唯一的改动是把存储从 Go 内核的
/// `jsSource.*` 动作搬到 Dart 侧：脚本落在应用支持目录的 `js_sources/`
/// 下，一个脚本一个 `.js` 文件，启用项记在 SharedPreferences。
///
/// 这样同一份沙箱在 App（内核）与本地服务版（浏览器）里行为一致：都是
/// 「一个目录 + 一个激活 id」，换设备把目录拷走即可。
class JsSourceService extends ChangeNotifier {
  JsSourceService({this.onChanged});

  /// 源列表或启用项变化后的回调，网关据此重挂 `SourceSite` 条目。
  final VoidCallback? onChanged;

  static JsSourceService? current;
  static const _activeSourceKey = 'js_source_active_id';
  static const _dirName = 'js_sources';

  SharedPreferences? _preferences;
  Directory? _directory;
  List<JsSourceMeta> _sources = const [];
  final Map<String, String> _scripts = {};
  String _activeSourceId = '';
  JsSigningProfile? _signing;
  bool _initialized = false;
  bool _disposed = false;
  bool _busy = false;
  Future<void>? _initializing;

  List<JsSourceMeta> get sources => List.unmodifiable(_sources);
  String get activeSourceId => _activeSourceId;
  bool get initialized => _initialized;
  bool get loading => _busy;
  JsSourceMeta? get activeSource => sourceById(_activeSourceId);
  String? get activeScript => _scripts[_activeSourceId];

  JsSourceMeta? sourceById(String id) {
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  /// 已配置的签名参数（官方脚本的 App 接口需要）。
  JsSigningProfile? get signing => _signing;

  /// 脚本正文，已按需填入签名参数。运行时池按 sourceId 缓存，正文变了
  /// 会重建实例，所以换签名后要 `reload()` 让池重新装载。
  String? scriptOf(String id) {
    final raw = _scripts[id];
    if (raw == null) return null;
    final profile = _signing;
    return profile == null || !profile.configured ? raw : profile.apply(raw);
  }

  Future<void> setSigningProfile(JsSigningProfile? profile) async {
    await JsSigningProfile.save(profile);
    // 清掉用户自己填的签名后回到构建时内置的那份（可能为空）。
    _signing = profile ?? JsSigningProfile.builtInProfile;
    _changed();
  }

  Future<Directory> _root() async {
    final cached = _directory;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, _dirName));
    if (!await directory.exists()) await directory.create(recursive: true);
    return _directory = directory;
  }

  Future<T> _withLoading<T>(Future<T> Function() operation) async {
    if (_disposed) throw StateError('JS 沙箱已关闭');
    _busy = true;
    notifyListeners();
    try {
      return await operation();
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _changed() {
    onChanged?.call();
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initializing ??= _withLoading(() async {
      _preferences ??= await SharedPreferences.getInstance();
      _signing = await JsSigningProfile.load();
      await _scan();
      await _installPresets();
      final saved = _preferences?.getString(_activeSourceKey) ?? '';
      _activeSourceId = _sources.any((source) => source.id == saved)
          ? saved
          : _defaultSourceId();
      _initialized = true;
      _changed();
    }).whenComplete(() => _initializing = null);
  }

  /// 首次启用谁：优先官方源（功能完整，补上签名参数即可播），其次网页版
  /// （只用于浏览），都没有时才退回列表首个。
  String _defaultSourceId() {
    for (final id in const ['hongguo', 'hongguoweb']) {
      if (_sources.any((source) => source.id == id)) return id;
    }
    return _sources.isEmpty ? '' : _sources.first.id;
  }

  /// 内置源：出厂带一份官方短剧脚本，用户第一次打开沙箱即可直接播。
  /// 已装版本比内置版本新时保留用户的（脚本可能是用户自己更新的）。
  Future<void> _installPresets() async {
    for (final preset in kPresetJsSources) {
      final script = await preset.loadScript();
      final meta = parseJsSourceMeta(script, preset.fileName);
      if (meta == null) continue;
      final installed = sourceById(meta.id);
      if (installed != null &&
          JsSourceMeta.isVersionNewer(
            installed.version,
            JsSourceMeta.scriptVersion(script),
          )) {
        continue;
      }
      await _writeScript(preset.fileName, script, meta);
    }
  }

  Future<void> _scan() async {
    final directory = await _root();
    final metas = <String, JsSourceMeta>{};
    final scripts = <String, String>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.js')) {
        continue;
      }
      try {
        final content = normalizeJsScript(await entity.readAsString());
        final meta = parseJsSourceMeta(content, p.basename(entity.path));
        if (meta == null) continue;
        final existing = metas[meta.id];
        if (existing != null &&
            !JsSourceMeta.isVersionNewer(meta.version, existing.version)) {
          continue;
        }
        metas[meta.id] = meta;
        scripts[meta.id] = content;
      } catch (_) {
        // 单个脚本损坏不该拖垮整张列表，跳过即可。
      }
    }
    _sources = metas.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _scripts
      ..clear()
      ..addAll(scripts);
  }

  Future<void> _writeScript(
    String fileName,
    String script,
    JsSourceMeta meta,
  ) async {
    final directory = await _root();
    final target = File(p.join(directory.path, fileName));
    if (!await target.exists() || await target.readAsString() != script) {
      await target.writeAsString(script, flush: true);
    }
    _scripts[meta.id] = script;
    _sources = [
      for (final source in _sources)
        if (source.id != meta.id) source,
      meta,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<bool> switchSource(String sourceId) async {
    if (_activeSourceId == sourceId) return true;
    if (!_sources.any((source) => source.id == sourceId)) return false;
    return _withLoading(() async {
      _activeSourceId = sourceId;
      _preferences ??= await SharedPreferences.getInstance();
      await _preferences?.setString(_activeSourceKey, sourceId);
      _changed();
      return true;
    });
  }

  /// 导入脚本。文件名决定落盘名，meta.id 决定站源标识。
  Future<JsImportResult> import(String script, String fileName) => _withLoading(
    () async {
      var name = fileName.trim();
      if (name.isEmpty) name = 'custom_source.js';
      if (!name.toLowerCase().endsWith('.js')) name = '$name.js';
      if (!validJsSourceFileName(name)) {
        return const JsImportResult.failed('文件名无效，需以 .js 结尾且不能包含路径');
      }
      final content = normalizeJsScript(script);
      if (content.trim().isEmpty) {
        return const JsImportResult.failed('脚本内容为空');
      }
      if (utf8.encode(content).length > 4 * 1024 * 1024) {
        return const JsImportResult.failed('脚本超过 4MB，无法导入');
      }
      final meta = parseJsSourceMeta(content, name);
      if (meta == null) {
        return const JsImportResult.failed('无法识别脚本的 meta 定义（需要 id 与 name 字段）');
      }
      // 同一个 id 换了文件名：删掉旧文件，避免扫描出两个同 id 的源。
      await _removeFileOf(meta.id, keep: name);
      await _writeScript(name, content, meta);
      if (_activeSourceId.isEmpty) {
        _activeSourceId = meta.id;
        _preferences ??= await SharedPreferences.getInstance();
        await _preferences?.setString(_activeSourceKey, meta.id);
      }
      _changed();
      return JsImportResult.ok(meta);
    },
  );

  Future<JsImportResult> importFromUrl(String url) async {
    HttpClient? client;
    try {
      final uri = Uri.parse(url.trim());
      if (!{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        return const JsImportResult.failed('只支持 http / https 直链');
      }
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'Mozilla/5.0 (guoapp js sandbox)');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.contentLength > 4 * 1024 * 1024) {
        return JsImportResult.failed('下载失败（HTTP ${response.statusCode}）');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          return const JsImportResult.failed('脚本超过 4MB，无法导入');
        }
        bytes.add(chunk);
      }
      var fileName = uri.pathSegments.isEmpty
          ? 'remote_source.js'
          : uri.pathSegments.last;
      if (!fileName.toLowerCase().endsWith('.js')) fileName = '$fileName.js';
      final script = utf8.decode(bytes.takeBytes(), allowMalformed: true);
      return await import(script, fileName);
    } on Exception catch (error) {
      return JsImportResult.failed('网络拉取失败：$error');
    } finally {
      client?.close(force: true);
    }
  }

  Future<void> _removeFileOf(String id, {String keep = ''}) async {
    final directory = await _root();
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.js')) {
        continue;
      }
      final name = p.basename(entity.path);
      if (name == keep) continue;
      try {
        final meta = parseJsSourceMeta(
          normalizeJsScript(await entity.readAsString()),
          name,
        );
        if (meta?.id == id) await entity.delete();
      } catch (_) {}
    }
  }

  Future<bool> removeSource(String sourceId) => _withLoading(() async {
    await _removeFileOf(sourceId);
    _scripts.remove(sourceId);
    _sources = [
      for (final source in _sources)
        if (source.id != sourceId) source,
    ];
    if (_activeSourceId == sourceId) {
      _activeSourceId = _sources.isEmpty ? '' : _sources.first.id;
      _preferences ??= await SharedPreferences.getInstance();
      if (_activeSourceId.isEmpty) {
        await _preferences?.remove(_activeSourceKey);
      } else {
        await _preferences?.setString(_activeSourceKey, _activeSourceId);
      }
    }
    _changed();
    return true;
  });

  Future<void> reload() => _withLoading(() async {
    await _scan();
    if (!_sources.any((source) => source.id == _activeSourceId)) {
      _activeSourceId = _sources.isEmpty ? '' : _sources.first.id;
      _preferences ??= await SharedPreferences.getInstance();
      await _preferences?.setString(_activeSourceKey, _activeSourceId);
    }
    _changed();
  });

  Future<void> clearAll() => _withLoading(() async {
    final directory = await _root();
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.js')) {
        await entity.delete();
      }
    }
    _sources = const [];
    _scripts.clear();
    _activeSourceId = '';
    _preferences ??= await SharedPreferences.getInstance();
    await _preferences?.remove(_activeSourceKey);
    _changed();
  });

  @override
  void dispose() {
    _disposed = true;
    if (identical(current, this)) current = null;
    super.dispose();
  }
}
