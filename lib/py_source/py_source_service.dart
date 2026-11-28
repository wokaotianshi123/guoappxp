import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'py_source_models.dart';

/// Python 数据源（TVBox `class Spider`）的安装、扫描与启用状态。
///
/// 与 `JsSourceService` 同构：一个源一个 `.py` 文件，落在应用支持目录的
/// `py_sources/` 下，启用项记在 SharedPreferences。区别只在元信息来自
/// 文件名而不是脚本里的 `meta` 字面量。
class PySourceService extends ChangeNotifier {
  PySourceService({this.onChanged});

  final VoidCallback? onChanged;

  static PySourceService? current;
  static const _activeSourceKey = 'py_source_active_id';
  static const _dirName = 'py_sources';

  SharedPreferences? _preferences;
  Directory? _directory;
  List<PySourceMeta> _sources = const [];
  final Map<String, String> _scripts = {};
  final Map<String, String> _paths = {};
  String _activeSourceId = '';
  bool _initialized = false;
  bool _disposed = false;
  bool _busy = false;
  Future<void>? _initializing;

  List<PySourceMeta> get sources => List.unmodifiable(_sources);
  String get activeSourceId => _activeSourceId;
  bool get initialized => _initialized;
  bool get loading => _busy;
  PySourceMeta? get activeSource => sourceById(_activeSourceId);
  String? get activeScript => _scripts[_activeSourceId];

  PySourceMeta? sourceById(String id) {
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  String? scriptOf(String id) => _scripts[id];

  /// 脚本在磁盘上的绝对路径。py 宿主按路径加载蜘蛛，必须传这个而不是文件名。
  String? pathOf(String id) => _paths[id];

  Future<Directory> _root() async {
    final cached = _directory;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, _dirName));
    if (!await directory.exists()) await directory.create(recursive: true);
    return _directory = directory;
  }

  Future<T> _withLoading<T>(Future<T> Function() operation) async {
    if (_disposed) throw StateError('PY 沙箱已关闭');
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
      await _scan();
      final saved = _preferences?.getString(_activeSourceKey) ?? '';
      _activeSourceId = _sources.any((source) => source.id == saved)
          ? saved
          : (_sources.isEmpty ? '' : _sources.first.id);
      _initialized = true;
      _changed();
    }).whenComplete(() => _initializing = null);
  }

  Future<void> _scan() async {
    final directory = await _root();
    final metas = <String, PySourceMeta>{};
    final scripts = <String, String>{};
    final paths = <String, String>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.py')) {
        continue;
      }
      try {
        final fileName = p.basename(entity.path);
        final result = pyMetaFromFileName(fileName);
        final meta = result.meta;
        if (meta == null) continue;
        final content = normalizePyScript(await entity.readAsString());
        metas[meta.id] = meta;
        scripts[meta.id] = content;
        paths[meta.id] = entity.path;
      } catch (_) {
        // 单个文件损坏不该拖垮整张列表。
      }
    }
    _sources = metas.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _scripts
      ..clear()
      ..addAll(scripts);
    _paths
      ..clear()
      ..addAll(paths);
  }

  Future<bool> _writeScript(String fileName, String script, PySourceMeta meta) async {
    final directory = await _root();
    final target = File(p.join(directory.path, fileName));
    if (!await target.exists() || await target.readAsString() != script) {
      await target.writeAsString(script, flush: true);
    }
    _scripts[meta.id] = script;
    _paths[meta.id] = target.path;
    _sources = [
      for (final source in _sources)
        if (source.id != meta.id) source,
      meta,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return true;
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

  Future<PyImportResult> import(String script, String fileName) => _withLoading(
    () async {
      var name = fileName.trim();
      if (name.isEmpty) name = 'custom_source.py';
      if (!name.toLowerCase().endsWith('.py')) name = '$name.py';
      final result = pyMetaFromFileName(name);
      final meta = result.meta;
      if (meta == null) return PyImportResult.failed(result.error);
      final content = normalizePyScript(script);
      if (content.trim().isEmpty) {
        return const PyImportResult.failed('脚本内容为空');
      }
      if (utf8.encode(content).length > 4 * 1024 * 1024) {
        return const PyImportResult.failed('脚本超过 4MB，无法导入');
      }
      if (!RegExp(r'class\s+Spider\b').hasMatch(content)) {
        return const PyImportResult.failed('未找到 class Spider，不是 TVBox py 蜘蛛');
      }
      // 同一个标识换了文件名：删掉旧文件，避免扫描出两个同标识的源。
      await _removeFileOf(meta.id, keep: name);
      await _writeScript(name, content, meta);
      if (_activeSourceId.isEmpty) {
        _activeSourceId = meta.id;
        _preferences ??= await SharedPreferences.getInstance();
        await _preferences?.setString(_activeSourceKey, meta.id);
      }
      _changed();
      return PyImportResult.ok(meta);
    },
  );

  Future<PyImportResult> importFromUrl(String url) async {
    HttpClient? client;
    try {
      final uri = Uri.parse(url.trim());
      if (!{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        return const PyImportResult.failed('只支持 http / https 直链');
      }
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'Mozilla/5.0 (guoapp py sandbox)');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.contentLength > 4 * 1024 * 1024) {
        return PyImportResult.failed('下载失败（HTTP ${response.statusCode}）');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          return const PyImportResult.failed('脚本超过 4MB，无法导入');
        }
        bytes.add(chunk);
      }
      var fileName = uri.pathSegments.isEmpty
          ? 'remote_source.py'
          : uri.pathSegments.last;
      if (!fileName.toLowerCase().endsWith('.py')) fileName = '$fileName.py';
      final script = utf8.decode(bytes.takeBytes(), allowMalformed: true);
      return await import(script, fileName);
    } on Exception catch (error) {
      return PyImportResult.failed('网络拉取失败：$error');
    } finally {
      client?.close(force: true);
    }
  }

  Future<void> _removeFileOf(String id, {String keep = ''}) async {
    final directory = await _root();
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.py')) {
        continue;
      }
      final name = p.basename(entity.path);
      if (name == keep) continue;
      final meta = pyMetaFromFileName(name).meta;
      if (meta?.id == id) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }

  Future<bool> removeSource(String sourceId) => _withLoading(() async {
    await _removeFileOf(sourceId);
    _scripts.remove(sourceId);
    _paths.remove(sourceId);
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
      if (entity is File && entity.path.toLowerCase().endsWith('.py')) {
        await entity.delete();
      }
    }
    _sources = const [];
    _scripts.clear();
    _paths.clear();
    _activeSourceId = '';
    _preferences ??= await SharedPreferences.getInstance();
    await _preferences?.remove(_activeSourceKey);
    _changed();
  });

  /// 导出选中的 py 源为 zip；[ids] 为空表示全部。
  Uint8List exportZip({List<String> ids = const []}) {
    final wanted = ids.isEmpty ? null : ids.toSet();
    final archive = Archive();
    final used = <String>{};
    var added = 0;
    for (final source in _sources) {
      if (wanted != null && !wanted.contains(source.id)) continue;
      final script = _scripts[source.id];
      if (script == null) continue;
      var name = source.fileName.isNotEmpty
          ? p.basename(source.fileName)
          : '${source.id}.py';
      if (!name.toLowerCase().endsWith('.py')) name = '$name.py';
      var unique = name;
      for (var index = 2; !used.add(unique.toLowerCase()); index++) {
        unique = '${p.basenameWithoutExtension(name)}-$index.py';
      }
      archive.add(ArchiveFile.string(unique, script));
      added++;
    }
    if (added == 0) throw StateError('没有可导出的 py 源');
    return ZipEncoder().encodeBytes(archive);
  }

  /// 从 zip 导入：包内每个 `.py` 文件各装一个源。
  Future<PyZipImportResult> importZip(Uint8List bytes) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (error) {
      return PyZipImportResult(error: '不是有效的 zip：$error');
    }
    final imported = <PySourceMeta>[];
    final failed = <String>[];
    for (final file in archive) {
      if (!file.isFile) continue;
      final name = p.basename(file.name.replaceAll('\\', '/'));
      if (!name.toLowerCase().endsWith('.py')) continue;
      try {
        final content = utf8.decode(file.content as List<int>, allowMalformed: true);
        final result = await import(content, name);
        if (result.meta != null) {
          imported.add(result.meta!);
        } else {
          failed.add('$name（${result.error}）');
        }
      } catch (error) {
        failed.add('$name（$error）');
      }
    }
    return PyZipImportResult(imported: imported, failed: failed);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
