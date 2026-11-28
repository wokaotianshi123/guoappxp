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
        final content = normalizePyScript(await entity.readAsString());
        // 显示名优先取脚本里的 getName()，读不到才用文件名。
        final result = pyMetaFromFileName(fileName, script: content);
        final meta = result.meta;
        if (meta == null) continue;
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
      final content = normalizePyScript(script);
      // 显示名优先取脚本里的 getName()，读不到才用文件名。
      final result = pyMetaFromFileName(name, script: content);
      final meta = result.meta;
      if (meta == null) return PyImportResult.failed(result.error);
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
    try {
      final downloaded = await _download(url.trim(), 4 * 1024 * 1024);
      var fileName = downloaded.uri.pathSegments.isEmpty
          ? 'remote_source.py'
          : downloaded.uri.pathSegments.last;
      if (!fileName.toLowerCase().endsWith('.py')) fileName = '$fileName.py';
      final script = utf8.decode(downloaded.bytes, allowMalformed: true);
      return await import(script, fileName);
    } on Exception catch (error) {
      return PyImportResult.failed('网络拉取失败：$error');
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
  ///
  /// 包内布局与 JS 沙箱一致：一份订阅配置 + 每个脚本本体。
  /// ```
  /// xiaoguo.json
  /// demo.py
  /// myspider.py
  /// ```
  /// 配置里的 url 写成 `.\demo.py`，按 JSON 自身所在目录解析，
  /// 解压后整个目录可以直接给 App 或其他客户端读取。
  Uint8List exportZip({List<String> ids = const []}) {
    final wanted = ids.isEmpty ? null : ids.toSet();
    final entries = <({String name, String fileName, String script})>[];
    for (final source in _sources) {
      if (wanted != null && !wanted.contains(source.id)) continue;
      final script = _scripts[source.id];
      if (script == null) continue;
      var fileName = source.fileName.isNotEmpty
          ? p.basename(source.fileName)
          : '${source.id}.py';
      if (!fileName.toLowerCase().endsWith('.py')) fileName = '$fileName.py';
      entries.add((name: source.name, fileName: fileName, script: script));
    }
    if (entries.isEmpty) throw StateError('没有可导出的 py 源');
    return buildSubscriptionArchive(entries);
  }

  /// 订阅包里的配置文件名；导入时优先识别它。
  static const subscriptionFileName = 'xiaoguo.json';

  /// 把「显示名 + 文件名 + 脚本正文」打成订阅包。
  @visibleForTesting
  static Uint8List buildSubscriptionArchive(
    List<({String name, String fileName, String script})> entries,
  ) {
    final archive = Archive();
    final rows = <Map<String, String>>[];
    final used = <String>{};
    for (final entry in entries) {
      var name = entry.fileName;
      if (!name.toLowerCase().endsWith('.py')) name = '${entry.name}.py';
      var unique = name;
      for (var index = 2; !used.add(unique.toLowerCase()); index++) {
        unique = '${p.basenameWithoutExtension(name)}-$index.py';
      }
      archive.add(ArchiveFile.string(unique, entry.script));
      rows.add({'name': entry.name, 'url': '.\\$unique'});
    }
    final config = const JsonEncoder.withIndent('  ').convert({'sources': rows});
    archive.add(ArchiveFile.string(subscriptionFileName, config));
    return ZipEncoder().encodeBytes(archive);
  }

  /// 从订阅地址导入。
  ///
  /// 订阅是一份远程 JSON：`{"sources":[{"name":"…","url":"…"}]}`，也接受
  /// 裸数组、`{"url":"…"}` 这种单脚本写法。相对地址按订阅 JSON 自身的
  /// 位置解析。地址指向单个 `.py` 直链时按普通网址导入处理。
  Future<PySubscriptionResult> importSubscription(String url) async {
    final result = await importUrl(url);
    if (result is PySubscriptionResult) return result;
    return PySubscriptionResult.failed('订阅拉取失败');
  }

  /// 一个地址可能是订阅 JSON，也可能是单个 `.py` 直链：只下载一次再判断。
  ///
  /// 返回 [PySubscriptionResult]（订阅）或 [PyImportResult]（单脚本），
  /// 调用方按类型分别处理，避免直链被下载两次。
  Future<Object> importUrl(String url) async {
    final ({Uint8List bytes, Uri uri}) downloaded;
    try {
      downloaded = await _download(url.trim(), 4 * 1024 * 1024);
    } on Exception catch (error) {
      return PySubscriptionResult.failed('拉取失败：$error');
    }
    final text = utf8.decode(downloaded.bytes, allowMalformed: true);
    final entries = parseSubscription(text, base: downloaded.uri);
    if (entries.isEmpty) {
      var fileName = downloaded.uri.pathSegments.isEmpty
          ? 'remote_source.py'
          : downloaded.uri.pathSegments.last;
      if (!fileName.toLowerCase().endsWith('.py')) fileName = '$fileName.py';
      return import(text, fileName);
    }
    final imported = <PySourceMeta>[];
    final failed = <String>[];
    for (final entry in entries) {
      final result = await importFromUrl(entry.url);
      if (result.success) {
        imported.add(result.meta!);
      } else {
        failed.add('${entry.name.isEmpty ? entry.url : entry.name}（${result.error}）');
      }
    }
    return PySubscriptionResult(imported: imported, failed: failed);
  }

  /// 导入本机的订阅配置（例如导出包里的 `xiaoguo.json`）。
  ///
  /// 绝对地址直接下载；相对地址若 [configPath] 给出了配置文件位置，
  /// 就从它所在目录读同名脚本（解压导出包后直接选 `xiaoguo.json` 即可）。
  Future<PySubscriptionResult> importLocalSubscription(
    String text, {
    String? configPath,
  }) async {
    final entries = parseSubscription(text);
    if (entries.isEmpty) {
      return PySubscriptionResult.failed('不是可识别的订阅配置（需要 sources 或 url）');
    }
    final directory = configPath == null || configPath.isEmpty
        ? null
        : p.dirname(configPath);
    final imported = <PySourceMeta>[];
    final failed = <String>[];
    for (final entry in entries) {
      final uri = Uri.tryParse(entry.url);
      final label = entry.name.isEmpty ? entry.url : entry.name;
      if (uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty) {
        final result = await importFromUrl(entry.url);
        if (result.success) {
          imported.add(result.meta!);
        } else {
          failed.add('$label（${result.error}）');
        }
        continue;
      }
      if (directory == null) {
        failed.add('$label（相对地址 ${entry.url} 需要和脚本一起打包成 zip 导入）');
        continue;
      }
      var relative = entry.url;
      try {
        relative = Uri.decodeComponent(relative);
      } catch (_) {}
      final resolved = p.normalize(p.join(directory, relative));
      if (!p.isWithin(directory, resolved) && !p.equals(directory, resolved)) {
        failed.add('$label（地址 ${entry.url} 超出配置目录）');
        continue;
      }
      final file = File(resolved);
      if (!await file.exists()) {
        failed.add('$label（同目录下找不到 ${entry.url}）');
        continue;
      }
      try {
        final bytes = await file.readAsBytes();
        if (bytes.length > 4 * 1024 * 1024) {
          failed.add('$label（脚本超过 4MB）');
          continue;
        }
        final result = await import(
          utf8.decode(bytes, allowMalformed: true),
          p.basename(resolved),
        );
        if (result.success) {
          imported.add(result.meta!);
        } else {
          failed.add('$label（${result.error}）');
        }
      } catch (error) {
        failed.add('$label（无法读取：$error）');
      }
    }
    return PySubscriptionResult(imported: imported, failed: failed);
  }

  /// 解析订阅 JSON，取出「名称 + 脚本地址」列表。
  ///
  /// 兼容 `{"sources":[…]} `、裸数组、映射写法、单个对象。给了 [base]
  /// 时相对地址按订阅所在目录解析，也容忍 Windows 反斜杠写法。
  static List<({String name, String url})> parseSubscription(
    String text, {
    Uri? base,
  }) {
    final entries = <({String name, String url})>[];
    for (final row in _subscriptionRows(text)) {
      final raw = row is String
          ? row
          : row is Map
          ? _subscriptionUrlOf(row)
          : '';
      final url = resolveSubscriptionUrl(raw, base);
      if (url.isEmpty) continue;
      entries.add((name: _subscriptionNameOf(row), url: url));
    }
    return entries;
  }

  static String _subscriptionNameOf(Object? row) {
    if (row is! Map) return '';
    return (row['name'] ?? row['title'] ?? '').toString().trim();
  }

  static String _subscriptionUrlOf(Map row) =>
      (row['url'] ?? row['address'] ?? row['src'] ?? row['path'] ?? '')
          .toString()
          .trim();

  static List<Object?> _subscriptionRows(String text) {
    final body = text.startsWith('\uFEFF') ? text.substring(1) : text;
    final decoded = _decodeSubscription(body);
    if (decoded == null) return const [];
    final rows = <Object?>[];
    if (decoded is List) {
      rows.addAll(decoded);
    } else if (decoded is Map) {
      for (final key in const ['sources', 'py', 'scripts', 'list', 'data']) {
        final value = decoded[key];
        if (value is List) {
          rows.addAll(value);
          break;
        }
      }
      if (rows.isEmpty) {
        if (_subscriptionUrlOf(decoded).isNotEmpty) {
          rows.add(decoded);
        } else {
          for (final entry in decoded.entries) {
            if (entry.value is String) {
              rows.add({'name': '${entry.key}', 'url': entry.value});
            }
          }
        }
      }
    }
    return rows;
  }

  static Object? _decodeSubscription(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      // 订阅作者常把 `.\demo.py` 直接写进 JSON，单个反斜杠是非法转义，
      // 严格解析会整份失败；把 .py 路径里的反斜杠补成 `\\` 再试一次。
      final patched = _repairScriptPaths(body);
      if (patched == body) return null;
      try {
        return jsonDecode(patched);
      } on FormatException {
        return null;
      }
    }
  }

  static final _jsonString = RegExp(r'"((?:[^"\\]|\\.)*)"');
  static final _scriptSuffix = RegExp(r'\.py(?:[?#].*)?$', caseSensitive: false);

  static String _repairScriptPaths(String text) {
    return text.replaceAllMapped(_jsonString, (match) {
      final value = match.group(1)!;
      if (!value.contains(r'\') || !_scriptSuffix.hasMatch(value)) {
        return match.group(0)!;
      }
      final buffer = StringBuffer();
      for (var index = 0; index < value.length; index++) {
        final char = value[index];
        if (char != r'\') {
          buffer.write(char);
          continue;
        }
        if (index + 1 < value.length) {
          final next = value[index + 1];
          if (next == r'\') {
            buffer.write(r'\\');
            index++;
            continue;
          }
          if (next == '"' || next == '/') {
            buffer.write(r'\');
            buffer.write(next);
            index++;
            continue;
          }
        }
        buffer.write(r'\\');
      }
      return '"${buffer.toString()}"';
    });
  }

  /// 把订阅里的一条地址解析成可下载的绝对地址。
  static String resolveSubscriptionUrl(String raw, Uri? base) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    value = value.replaceAll(r'\', '/');
    final absolute = Uri.tryParse(value);
    if (absolute == null) return '';
    if (absolute.hasScheme) {
      return _isDownloadable(absolute) ? absolute.toString() : '';
    }
    if (base == null) return '';
    final resolved = base.resolve(value);
    return _isDownloadable(resolved) ? resolved.toString() : '';
  }

  static bool _isDownloadable(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;

  /// 统一下载：限制大小，并返回重定向后的最终地址（相对地址按它解析）。
  Future<({Uint8List bytes, Uri uri})> _download(String url, int limit) async {
    final uri = Uri.parse(url);
    if (!{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('只支持 http / https 地址');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'Mozilla/5.0 (guoapp py sandbox)');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      var effective = uri;
      for (final redirect in response.redirects) {
        effective = effective.resolveUri(redirect.location);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > limit) {
          throw const FormatException('文件过大');
        }
        bytes.add(chunk);
      }
      return (bytes: bytes.takeBytes(), uri: effective);
    } finally {
      client.close(force: true);
    }
  }

  /// 从 zip 导入：优先读订阅配置，配置没提到的 `.py` 仍逐个安装。
  Future<PyZipImportResult> importZip(Uint8List bytes) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (error) {
      return PyZipImportResult(error: '不是有效的 zip：$error');
    }
    final files = <String, ArchiveFile>{};
    for (final file in archive) {
      if (!file.isFile) continue;
      files[_archiveKey(file.name)] = file;
    }
    final imported = <PySourceMeta>[];
    final failed = <String>[];
    final consumed = <String>{};

    final config = _findSubscriptionConfig(files);
    if (config != null) {
      final configDir = p.posix.dirname(config.key);
      for (final entry in parseSubscription(config.text)) {
        final label = entry.name.isEmpty ? entry.url : entry.name;
        final uri = Uri.tryParse(entry.url);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          final result = await importFromUrl(entry.url);
          if (result.success) {
            imported.add(result.meta!);
          } else {
            failed.add('$label（${result.error}）');
          }
          continue;
        }
        final target = _lookupArchiveScript(
          files,
          configDir == '.' ? entry.url : p.posix.join(configDir, entry.url),
        );
        if (target == null) {
          failed.add('$label（压缩包里缺少 ${entry.url}）');
          continue;
        }
        consumed.add(target.key);
        try {
          final result = await import(
            utf8.decode(target.file.content, allowMalformed: true),
            p.posix.basename(target.key),
          );
          if (result.success) {
            imported.add(result.meta!);
          } else {
            failed.add('$label（${result.error}）');
          }
        } catch (error) {
          failed.add('$label（无法读取：$error）');
        }
      }
    }

    for (final entry in files.entries) {
      if (consumed.contains(entry.key) || !entry.key.endsWith('.py')) continue;
      final name = p.posix.basename(entry.value.name);
      try {
        final content = utf8.decode(
          entry.value.content,
          allowMalformed: true,
        );
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

  static String _archiveKey(String name) {
    var key = name.replaceAll(r'\', '/');
    while (key.startsWith('./')) {
      key = key.substring(2);
    }
    return key.toLowerCase();
  }

  /// 在 zip 里找订阅配置：优先 `xiaoguo.json`，其次任一能解析出条目的 JSON。
  static ({String key, String text})? _findSubscriptionConfig(
    Map<String, ArchiveFile> files,
  ) {
    final keys = [
      for (final key in files.keys)
        if (key.endsWith('.json')) key,
    ]..sort((a, b) {
        final aPreferred = p.posix.basename(a) == subscriptionFileName;
        final bPreferred = p.posix.basename(b) == subscriptionFileName;
        if (aPreferred != bPreferred) return aPreferred ? -1 : 1;
        return a.compareTo(b);
      });
    for (final key in keys) {
      String text;
      try {
        text = utf8.decode(files[key]!.content, allowMalformed: true);
      } catch (_) {
        continue;
      }
      if (parseSubscription(text).isEmpty) continue;
      return (key: key, text: text);
    }
    return null;
  }

  /// 按相对路径在 zip 里找脚本；找不到再退回同名文件。
  static ({String key, ArchiveFile file})? _lookupArchiveScript(
    Map<String, ArchiveFile> files,
    String target,
  ) {
    var path = target;
    final cut = path.indexOf(RegExp(r'[?#]'));
    if (cut >= 0) path = path.substring(0, cut);
    var key = _archiveKey(path);
    try {
      key = _archiveKey(Uri.decodeComponent(key));
    } catch (_) {}
    final direct = files[key];
    if (direct != null && key.endsWith('.py')) {
      return (key: key, file: direct);
    }
    final base = p.posix.basename(key);
    for (final entry in files.entries) {
      if (entry.key.endsWith('.py') &&
          p.posix.basename(entry.key) == base) {
        return (key: entry.key, file: entry.value);
      }
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
