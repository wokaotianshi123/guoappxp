import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'js_source_models.dart';
import 'js_source_presets.dart';
import 'js_signing_profile.dart';
import '../subscription_models.dart';

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

  /// 首次启用谁：优先官方源（功能完整，签名已内置即可播），
  /// 没有时才退回列表首个。
  String _defaultSourceId() {
    for (final id in const ['hongguo']) {
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

  // ------------------------------------------------------------ 打包 / 订阅

  /// 订阅包里的配置文件名；导入时优先识别它。
  static const subscriptionFileName = 'xiaoguo.json';

  /// 把选中的脚本源打成一个订阅包：`xiaoguo.json` + 每个脚本本体。
  ///
  /// [ids] 为空表示导出全部。包内布局：
  /// ```
  /// xiaoguo.json
  /// hongguo.js
  /// volcanoexpo-com.js
  /// ```
  /// 配置里的 url 写成 `.\hongguo.js`，按 JSON 自身所在目录解析。
  /// 解压后整个目录可以直接给 App / 本地服务版读取，zip 也能原样导入。
  Uint8List exportZip({List<String> ids = const []}) {
    final wanted = ids.isEmpty ? null : ids.toSet();
    final entries = <({String name, String fileName, String script})>[];
    for (final source in _sources) {
      if (wanted != null && !wanted.contains(source.id)) continue;
      final script = _scripts[source.id];
      if (script == null) continue;
      final fileName = source.fileName.isNotEmpty
          ? p.basename(source.fileName)
          : '${source.id}.js';
      entries.add((name: source.name, fileName: fileName, script: script));
    }
    if (entries.isEmpty) throw StateError('没有可导出的脚本源');
    return buildSubscriptionArchive(entries);
  }

  /// 把「显示名 + 文件名 + 脚本正文」打成订阅包。
  ///
  /// 与 [exportZip] 分开是为了能在纯 Dart 测试里验证包的结构：配置固定叫
  /// `xiaoguo.json`，每条地址写成 `.\文件名`，与配置文件放在同一层。
  @visibleForTesting
  static Uint8List buildSubscriptionArchive(
    List<({String name, String fileName, String script})> entries,
  ) {
    final archive = Archive();
    final rows = <Map<String, String>>[];
    final used = <String>{};
    for (final entry in entries) {
      var name = entry.fileName;
      if (!name.toLowerCase().endsWith('.js')) name = '${entry.name}.js';
      var unique = name;
      for (var index = 2; !used.add(unique.toLowerCase()); index++) {
        unique = '${p.basenameWithoutExtension(name)}-$index.js';
      }
      archive.add(ArchiveFile.string(unique, entry.script));
      rows.add({'name': entry.name, 'url': '.\\$unique'});
    }
    // 用 JsonEncoder 输出，反斜杠会被正确转义成 `\\`，其它客户端也能读。
    final config = const JsonEncoder.withIndent('  ').convert({'sources': rows});
    archive.add(ArchiveFile.string(subscriptionFileName, config));
    return ZipEncoder().encodeBytes(archive);
  }

  /// 从 zip 导入脚本源。
  ///
  /// 优先识别包里的订阅配置（`xiaoguo.json` 或任一能解析的 `.json`）：
  /// 配置里写相对地址的脚本直接从包内取文件安装，写绝对地址的才下载。
  /// 配置没提到的 `.js` 仍按 meta 逐个安装，兼容原来只放脚本的 zip。
  Future<JsZipImportResult> importZip(Uint8List bytes) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (error) {
      return JsZipImportResult.failed('不是有效的 zip：$error');
    }
    final files = <String, ArchiveFile>{};
    for (final file in archive) {
      if (!file.isFile) continue;
      files[_archiveKey(file.name)] = file;
    }
    final imported = <JsSourceMeta>[];
    final failed = <String>[];
    final consumed = <String>{};

    final config = _findSubscriptionConfig(files);
    if (config != null) {
      final configDir = p.posix.dirname(config.key);
      for (final entry in parseLocalSubscription(config.text)) {
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
          final script = normalizeJsScript(
            utf8.decode(target.file.content, allowMalformed: true),
          );
          final result = await import(script, p.posix.basename(target.key));
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
      if (consumed.contains(entry.key) || !entry.key.endsWith('.js')) continue;
      final name = p.posix.basename(entry.value.name);
      try {
        final script = normalizeJsScript(
          utf8.decode(entry.value.content, allowMalformed: true),
        );
        final result = await import(script, name);
        if (result.success) {
          imported.add(result.meta!);
        } else {
          failed.add('$name（${result.error}）');
        }
      } catch (_) {
        failed.add('$name（无法读取）');
      }
    }
    return JsZipImportResult(imported: imported, failed: failed);
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
      if (parseLocalSubscription(text).isEmpty) continue;
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
    } catch (_) {
      // 保留原路径继续匹配。
    }
    final direct = files[key];
    if (direct != null && key.endsWith('.js')) {
      return (key: key, file: direct);
    }
    final base = p.posix.basename(key);
    for (final entry in files.entries) {
      if (entry.key.endsWith('.js') &&
          p.posix.basename(entry.key) == base) {
        return (key: entry.key, file: entry.value);
      }
    }
    return null;
  }

  /// 只解析订阅，不导入：给「选择要装哪些」的弹层用。
  ///
  /// 返回的每条候选都带可下载的绝对地址；地址本身不是订阅（是脚本直链）
  /// 时 `fromSubscription` 为 false，调用方可以跳过选择直接导入。
  Future<SubscriptionFetch> fetchSubscription(String url) async {
    final ({Uint8List bytes, Uri uri}) downloaded;
    try {
      downloaded = await _download(url.trim(), 2 * 1024 * 1024);
    } on Exception catch (error) {
      return SubscriptionFetch.failed('订阅拉取失败：$error');
    }
    final text = utf8.decode(downloaded.bytes, allowMalformed: true);
    final entries = parseJsSubscription(text, base: downloaded.uri);
    if (entries.isEmpty) {
      // 不是订阅，是单个脚本直链。
      return SubscriptionFetch(
        candidates: [
          SubscriptionCandidate(
            name: '',
            url: url.trim(),
            detail: downloaded.uri.pathSegments.isEmpty
                ? url
                : downloaded.uri.pathSegments.last,
          ),
        ],
        fromSubscription: false,
      );
    }
    return SubscriptionFetch(
      candidates: [
        for (final entry in entries)
          SubscriptionCandidate(
            name: entry.name,
            url: entry.url,
            detail: _candidateDetail(entry.url, downloaded.uri),
          ),
      ],
      fromSubscription: true,
    );
  }

  /// 列表副标题：相对地址显示成「文件名 · 来自订阅」，绝对地址显示主机名。
  static String _candidateDetail(String url, Uri base) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
      return name.isEmpty ? uri.host : '$name · ${uri.host}';
    }
    return uri.path;
  }

  /// 解析本机订阅配置里的候选，供选择弹层用。
  ///
  /// 相对地址会解析成绝对路径（和配置同目录），并校验不越界；越界的条目标
  /// 记在 [SubscriptionFetch.error] 里，不阻断其它条目。
  SubscriptionFetch fetchLocalSubscription(
    String text, {
    String? configPath,
  }) {
    final entries = parseLocalSubscription(text);
    if (entries.isEmpty) {
      return const SubscriptionFetch.failed('不是可识别的订阅配置（需要 sources 或 url）');
    }
    final directory = configPath == null || configPath.isEmpty
        ? null
        : p.dirname(configPath);
    final candidates = <SubscriptionCandidate>[];
    final skipped = <String>[];
    for (final entry in entries) {
      final uri = Uri.tryParse(entry.url);
      final label = entry.name.isEmpty ? entry.url : entry.name;
      if (uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty) {
        candidates.add(
          SubscriptionCandidate(
            name: entry.name,
            url: entry.url,
            detail: _candidateDetail(entry.url, Uri()),
          ),
        );
        continue;
      }
      if (directory == null) {
        skipped.add('$label（相对地址需要和脚本一起打包成 zip 导入）');
        continue;
      }
      var relative = entry.url;
      try {
        relative = Uri.decodeComponent(relative);
      } catch (_) {}
      final resolved = p.normalize(p.join(directory, relative));
      if (!p.isWithin(directory, resolved) && !p.equals(directory, resolved)) {
        skipped.add('$label（地址超出配置目录）');
        continue;
      }
      candidates.add(
        SubscriptionCandidate(
          name: entry.name,
          url: entry.url,
          localPath: resolved,
          detail: p.basename(resolved),
        ),
      );
    }
    return SubscriptionFetch(
      candidates: candidates,
      fromSubscription: true,
      notice: skipped.isEmpty ? '' : skipped.join('；'),
    );
  }

  /// 按用户勾选的候选逐个导入，每条都回调进度。
  ///
  /// [isCancelled] 在每条开始前调用：返回 true 就停止后续条目，已装好的保留。
  /// 正在下载的那一条无法从外部打断（HttpClient 在内部），所以取消是
  /// 「最多再等一条」的语义，不会把剩下的全部跑完。
  Future<SubscriptionImportReport> importCandidates(
    List<SubscriptionCandidate> candidates, {
    void Function(SubscriptionProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final imported = <String>[];
    final failed = <String>[];
    var cancelled = false;
    for (var index = 0; index < candidates.length; index++) {
      if (isCancelled?.call() == true) {
        cancelled = true;
        break;
      }
      final candidate = candidates[index];
      onProgress?.call(
        SubscriptionProgress(
          done: index,
          total: candidates.length,
          name: candidate.label,
        ),
      );
      final label = candidate.label;
      try {
        final JsImportResult result;
        if (candidate.localPath.isNotEmpty) {
          final file = File(candidate.localPath);
          if (!await file.exists()) {
            failed.add('$label（同目录下找不到 ${candidate.url}）');
            continue;
          }
          final bytes = await file.readAsBytes();
          if (bytes.length > 4 * 1024 * 1024) {
            failed.add('$label（脚本超过 4MB）');
            continue;
          }
          result = await import(
            normalizeJsScript(utf8.decode(bytes, allowMalformed: true)),
            p.basename(candidate.localPath),
          );
        } else {
          result = await importFromUrl(candidate.url);
        }
        if (result.success) {
          imported.add(result.meta!.name);
        } else {
          failed.add('$label（${result.error}）');
        }
      } catch (error) {
        failed.add('$label（$error）');
      }
    }
    if (!cancelled) {
      onProgress?.call(
        SubscriptionProgress(
          done: candidates.length,
          total: candidates.length,
          name: '',
        ),
      );
    }
    return SubscriptionImportReport(imported: imported, failed: failed);
  }

  /// 从订阅地址导入。
  ///
  /// 订阅就是一个远程 JSON，里面列出若干脚本源的名称与地址，形如
  /// `{"sources":[{"name":"…","url":"…"}]}`；也接受裸数组、以及
  /// `{"url":"…"}` 这种单个脚本的写法。`url` 可以是绝对地址，也可以相对
  /// 订阅 JSON 自身的位置写（`./xxx/xxx.js`、`.\xxx\xxx.js`）。相对地址
  /// 一律按订阅 JSON 所在目录解析，和配置文件放在一起的脚本解压后即可
  /// 直接使用；单个反斜杠写法的 JSON 也会自动修复。解析后逐个下载安装。
  Future<JsSubscriptionResult> importSubscription(String url) async {
    final ({Uint8List bytes, Uri uri}) downloaded;
    try {
      downloaded = await _download(url.trim(), 2 * 1024 * 1024);
    } on Exception catch (error) {
      return JsSubscriptionResult.failed('订阅拉取失败：$error');
    }
    final text = utf8.decode(downloaded.bytes, allowMalformed: true);
    // 相对地址要按订阅 JSON 自己的位置解析：订阅放在 /subs/list.json 时，
    // `./a.js` 指 /subs/a.js，而不是 App 的当前目录。用重定向后的最终地址，
    // 免得短链跳转后目录对不上。
    final entries = parseJsSubscription(text, base: downloaded.uri);
    if (entries.isEmpty) {
      // 不是订阅，而是一个脚本直链：按普通网址导入处理。
      final single = await importFromUrl(url);
      if (single.success) {
        return JsSubscriptionResult(imported: [single.meta!], failed: const []);
      }
      return JsSubscriptionResult.failed(
        '既不是订阅 JSON，也不是可导入的脚本：${single.error}',
      );
    }
    final imported = <JsSourceMeta>[];
    final failed = <String>[];
    for (final entry in entries) {
      final result = await importFromUrl(entry.url);
      if (result.success) {
        imported.add(result.meta!);
      } else {
        failed.add(
          '${entry.name.isEmpty ? entry.url : entry.name}（${result.error}）',
        );
      }
    }
    return JsSubscriptionResult(imported: imported, failed: failed);
  }

  /// 导入本机的订阅配置（例如导出包里的 `xiaoguo.json`）。
  ///
  /// 配置里写绝对地址的直接下载。写相对地址时，如果 [configPath] 给了
  /// 配置文件在本机的位置，就从它所在目录读同名脚本（解压导出包后直接
  /// 选 `xiaoguo.json` 即可）；读不到才提示改用 zip 包。
  Future<JsSubscriptionResult> importLocalSubscription(
    String text, {
    String? configPath,
  }) async {
    final entries = parseLocalSubscription(text);
    if (entries.isEmpty) {
      return JsSubscriptionResult.failed('不是可识别的订阅配置（需要 sources 或 url）');
    }
    final directory = configPath == null || configPath.isEmpty
        ? null
        : p.dirname(configPath);
    final imported = <JsSourceMeta>[];
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
      // 只允许读配置所在目录内的文件，避免 `../` 越界读本机任意文件。
      var relative = entry.url;
      try {
        relative = Uri.decodeComponent(relative);
      } catch (_) {
        // 保留原样，按文件名去找。
      }
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
        final script = normalizeJsScript(
          utf8.decode(bytes, allowMalformed: true),
        );
        final result = await import(script, p.basename(resolved));
        if (result.success) {
          imported.add(result.meta!);
        } else {
          failed.add('$label（${result.error}）');
        }
      } catch (error) {
        failed.add('$label（无法读取：$error）');
      }
    }
    return JsSubscriptionResult(imported: imported, failed: failed);
  }

  /// 解析订阅 JSON，取出「名称 + 脚本地址」列表。
  ///
  /// 兼容几种常见写法：`{"sources":[…]}`、裸数组、脚本名作 key 的映射，以及
  /// 单个 `{"name":"…","url":"…"}`。
  ///
  /// [base] 是订阅 JSON 自身的地址。给了它，`./xxx/xxx.js`、`xxx/xxx.js`
  /// 这类相对地址会按订阅所在目录解析；也容忍 Windows 反斜杠写法
  /// `.\xxx\xxx.js`。没给 base 时相对地址无法下载，按旧行为忽略。
  static List<JsSubscriptionEntry> parseJsSubscription(
    String text, {
    Uri? base,
  }) {
    final entries = <JsSubscriptionEntry>[];
    for (final row in _subscriptionRows(text)) {
      final raw = row is String
          ? row
          : row is Map
          ? _subscriptionUrlOf(row)
          : '';
      final url = resolveJsSubscriptionUrl(raw, base);
      if (url.isEmpty) continue;
      entries.add(JsSubscriptionEntry(_subscriptionNameOf(row), url));
    }
    return entries;
  }

  /// 解析本地的订阅配置（导出包里的 `xiaoguo.json`）。
  ///
  /// 与 [parseJsSubscription] 的区别是**保留相对地址**：包里的脚本就在
  /// 同一个 zip 内，调用方按相对路径去包里取文件，不需要联网。
  static List<JsSubscriptionEntry> parseLocalSubscription(String text) {
    final entries = <JsSubscriptionEntry>[];
    for (final row in _subscriptionRows(text)) {
      final raw = row is String
          ? row
          : row is Map
          ? _subscriptionUrlOf(row)
          : '';
      final url = _normalizeSubscriptionPath(raw);
      if (url.isEmpty) continue;
      entries.add(JsSubscriptionEntry(_subscriptionNameOf(row), url));
    }
    return entries;
  }

  /// 订阅条目的显示名；裸地址（字符串行）没有名字，交给调用方用文件名兜底。
  static String _subscriptionNameOf(Object? row) {
    if (row is! Map) return '';
    return (row['name'] ?? row['title'] ?? '').toString().trim();
  }

  /// 把订阅 JSON 摊平成行：数组、`sources` 列表、单对象或映射写法。
  static List<Object?> _subscriptionRows(String text) {
    // 记事本 / 部分 Windows 编辑器会在 UTF-8 前加 BOM，直接 jsonDecode 会失败。
    final body = text.startsWith('\uFEFF') ? text.substring(1) : text;
    final decoded = _decodeSubscription(body);
    if (decoded == null) return const [];
    final rows = <Object?>[];
    if (decoded is List) {
      rows.addAll(decoded);
    } else if (decoded is Map) {
      for (final key in const ['sources', 'js', 'scripts', 'list', 'data']) {
        final value = decoded[key];
        if (value is List) {
          rows.addAll(value);
          break;
        }
      }
      if (rows.isEmpty) {
        if (_subscriptionUrlOf(decoded).isNotEmpty) {
          // 单个脚本写法：{"name":"…","url":"…"}。
          rows.add(decoded);
        } else {
          // 映射写法：{ "源名": "https://…/a.js" }
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

  static String _subscriptionUrlOf(Map row) =>
      (row['url'] ?? row['address'] ?? row['src'] ?? row['path'] ?? '')
          .toString()
          .trim();

  /// 包内相对地址统一成 `a/b.js` 形式，供 zip 查找用。
  static String _normalizeSubscriptionPath(String raw) {
    var value = raw.trim().replaceAll(r'\', '/');
    while (value.startsWith('./')) {
      value = value.substring(2);
    }
    return value;
  }

  /// 解析订阅 JSON；严格解析失败时尝试修复 Windows 反斜杠路径。
  ///
  /// 订阅作者常直接把 `.\hongguo.js` 写进 JSON，但单个 `\` 在 JSON 里是
  /// 非法转义（`\h` 不是合法序列），严格解析会整份失败。这里只修「像
  /// 脚本地址的字符串」，把路径里的反斜杠按字面量补成 `\\` 再解析一次，
  /// 避免因为一个反斜杠丢掉整份订阅。已经是合法写法的 JSON 不受影响。
  static Object? _decodeSubscription(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
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
  static final _scriptSuffix = RegExp(r'\.js(?:[?#].*)?$', caseSensitive: false);

  /// 把 `.js` 字符串里的单个反斜杠补成 `\\`；成对的 `\\` 与 `\"`、`\/`
  /// 原样保留，保证修复后的 JSON 仍能按原意解开。
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
  ///
  /// 只接受 http / https：绝对地址直用，相对地址一律按 [base]（订阅 JSON
  /// 自身的地址）解析。Windows 反斜杠 `.\hongguo.js` 先统一成 `/`。
  static String resolveJsSubscriptionUrl(String raw, Uri? base) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    // URL 只认 `/`；订阅作者在 Windows 上常写成 `.\xxx\xxx.js`。
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

  /// 统一下载：限制大小，避免订阅里塞进一个超大文件。
  ///
  /// 返回值带上**重定向后的最终地址**：订阅里的相对地址要按它解析，短链
  /// （`…/sub` → `…/config/list.json`）跳转后目录才对得上。
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
      request.headers.set('User-Agent', 'Mozilla/5.0 (guoapp js sandbox)');
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

  @override
  void dispose() {
    _disposed = true;
    if (identical(current, this)) current = null;
    super.dispose();
  }
}
