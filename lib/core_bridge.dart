import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'danmaku_models.dart';
import 'background_downloads.dart';
import 'local_store.dart';
import 'ranking_models.dart';
import 'cover_decoder.dart';
import 'catalog_updates.dart';
import 'download_collections.dart';
import 'resource_settings.dart';
import 'diary_service.dart';
import 'webview_bridge.dart';
import 'sorani_account.dart';
import 'source_modules.dart';
import 'js_source/js_source_gateway.dart';
import 'py_source/py_source_gateway.dart';

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

String _nativeRequest(String body) {
  final DynamicLibrary library;
  if (Platform.isAndroid) {
    library = DynamicLibrary.open('libduanju_core.so');
  } else if (Platform.isWindows) {
    library = DynamicLibrary.open(
      path.join(path.dirname(Platform.resolvedExecutable), 'duanju_core.dll'),
    );
  } else if (Platform.isIOS || Platform.isMacOS) {
    library = DynamicLibrary.process();
  } else {
    throw UnsupportedError('当前支持 Android、iOS、Windows 和 macOS');
  }
  final request = library.lookupFunction<_NativeRequest, _DartRequest>(
    'DuanjuRequest',
  );
  final free = library.lookupFunction<_NativeFree, _DartFree>('DuanjuFree');
  final input = body.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try {
    output = request(input);
    if (output == nullptr) {
      throw StateError('本地核心没有返回结果');
    }
    return output.toDartString();
  } finally {
    malloc.free(input);
    if (output != nullptr) {
      free(output);
    }
  }
}

class AppFailure implements Exception {
  AppFailure(this.message, {this.code = ''});
  final String message;
  final String code;
  @override
  String toString() => message;
}

abstract class AppRepository {
  Future<ResourceSettings> resourceSettings() async => const ResourceSettings();
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => throw AppFailure('当前环境不支持资源设置');
  final catalogUpdates = CatalogUpdates();
  Future<void> cancelPreload() async {}
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => null;
  Future<List<CastDevice>> castDevices() async => throw AppFailure('当前环境不支持投屏');
  Future<void> castPlay(
    CastDevice device,
    Drama drama,
    Episode episode, {
    int quality = 0,
    double position = 0,
  }) async => throw AppFailure('当前环境不支持投屏');
  Future<CastStatus> castStatus() async => throw AppFailure('当前环境不支持投屏');
  Future<void> castControl(String command, {double position = 0}) async {}

  /// 投屏：核心把当前播放会话再挂一份到 0.0.0.0，返回电视能访问的内网基址。
  /// [peer] 是电视的地址，核心据此确定手机这一侧用哪块网卡（Android 上
  /// 枚举网卡不一定拿得到地址，按路由挑出口最可靠）。
  Future<String> castBase({String peer = ''}) async =>
      throw AppFailure('当前环境不支持投屏');

  /// 停止投屏后关掉局域网监听，避免端口一直开着。
  Future<void> releaseCastBase() async {}
  Future<bool> castActive() async => false;
  Future<void> cancelDanmaku() async {}
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async => throw AppFailure('当前环境不支持弹幕');
  Future<void> cancelCatalog() async {}
  Future<void> cancelSuggestions() async {}
  Future<void> cancelRecommendations() async {}
  Future<Drama?> supplementMetadata(Drama drama) async => null;
  Future<List<DramaSeason>> seasons(Drama drama) async => const [];
  Future<Drama> followCheck(Drama drama) async => (await detail(drama)).drama;
  /// [lane] 只用来隔离读取会话，不会发给内核。
  ///
  /// 内核按 `会话名` 串行化同类请求：同一会话来了更新的请求，就会把前一个
  /// 取消。推荐页与发现页会同时向同一个站源取流，如果共用会话名，就会互相
  /// 取消，界面上表现为莫名其妙的「context canceled」。各页面用不同 lane
  /// 即可各取各的。
  Future<CatalogPage> recommendations(
    String source,
    String genre, {
    bool more = false,
    bool force = false,
    String lane = '',
  }) async => throw AppFailure('当前环境不支持推荐');
  Future<List<RankingBoard>> rankingBoards() async => const [];
  Future<RankingPage> rankings(
    RankingBoard board, {
    int page = 1,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持榜单');
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  bool get supportsSourceManagement => false;
  // ---- 自定义源管理（所有人可用，不限制管理员）----
  Future<List<CustomSourceSite>> customSources() async => const [];
  Future<CustomSourceSite> addCustomSource({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async => throw AppFailure('当前环境不支持自定义源');
  Future<CustomSourceSite> updateCustomSource(
    String id, {
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async => throw AppFailure('当前环境不支持自定义源');
  Future<void> removeCustomSource(String id) async =>
      throw AppFailure('当前环境不支持自定义源');
  Future<String> exportCustomSources() async => throw AppFailure('当前环境不支持自定义源');
  Future<Map<String, dynamic>> importCustomSources(String content) async =>
      throw AppFailure('当前环境不支持自定义源');
  Future<int> resetCustomSources() async => throw AppFailure('当前环境不支持自定义源');

  /// 输入站点网址，抓取网页 HTML 自动反推 XBPQ 规则。只返回规则与诊断说明，
  /// 不会写入自定义源；是否保存由用户在表单里点「保存」决定。
  Future<Map<String, dynamic>> analyzeCustomSourceSite(String base) async =>
      throw AppFailure('当前环境不支持自定义源');

  Future<List<SourceModule>> modules() async => const [];
  Future<ModuleStore> moduleIndex() async => throw AppFailure('当前环境不支持模块商店');

  /// 读取在线仓库配置（仓库名 + index.json 地址列表与当前启用项）。
  Future<ModuleRepositories> moduleRepositories() async =>
      throw AppFailure('当前环境不支持在线仓库');

  /// 保存在线仓库配置；返回核心回传的最新配置。
  Future<ModuleRepositories> saveModuleRepositories(
    List<ModuleRepository> repositories,
    int active,
  ) async => throw AppFailure('当前环境不支持在线仓库');
  Future<SourceModule> prepareModule({
    String file = '',
    String url = '',
    String indexed = '',
    bool bundled = false,
  }) async => throw AppFailure('当前环境不支持安装模块');

  /// 批量准备安装包：可一次提交多个本地文件与多个在线地址，
  /// 单个 zip 里含多个子模块 zip 时也会被展开。返回每一项的结果。
  Future<List<PreparedModule>> prepareModules({
    List<String> files = const [],
    List<String> urls = const [],
  }) async => throw AppFailure('当前环境不支持安装模块');
  Future<String> installModule(String token) async =>
      throw AppFailure('当前环境不支持安装模块');
  Future<void> uninstallModule(String id) async =>
      throw AppFailure('当前环境不支持卸载模块');

  /// 批量卸载，返回成功与失败的标识。
  Future<({List<String> removed, List<String> failures})> uninstallModules(
    List<String> ids,
  ) async => throw AppFailure('当前环境不支持卸载模块');

  /// 恢复默认：删除全部用户安装的模块，并把内置模块重新装回来。
  Future<({List<String> removed, int bundled})> resetModules() async =>
      throw AppFailure('当前环境不支持恢复默认模块');

  /// 导出模块为 zip 字节。ids 为空表示全部用户安装的模块。
  Future<ModuleExport> exportModules({List<String> ids = const []}) async =>
      throw AppFailure('当前环境不支持导出模块');
  Map<String, int> missingSourceDownloads() => const {};
  Future<List<String>> suggestions(String source, String query) async =>
      const [];
  Future<Map<String, dynamic>> storage() async => {};
  Future<String> downloadDirectory() async =>
      (await storage())['directory'] as String? ?? '';
  Future<({String path, String reason})> moveDownloads(
    String directory,
  ) async => throw AppFailure('当前环境不支持迁移');
  Future<int> workLease(String id, String command) async => 0;
  Future<int> cacheBytes() async => 0;
  Future<void> clearCache() async => throw AppFailure('当前环境不支持清理缓存');
  Future<List<String>> deleteAllData() async => throw AppFailure('当前环境不支持删除数据');
  bool get supportsDownloads => false;
  Future<List<DownloadJob>> downloads() async => [];
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async => throw AppFailure('当前环境不支持下载');
  Future<void> controlDownloads(String command, {String id = ''}) async {}
  Future<DownloadConversion> beginConversion(String id) async =>
      throw AppFailure('当前环境不支持处理下载');
  Future<void> finishConversion(String id, String result) async {}
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids,
  ) async {
    final completed = <String>[], failures = <String, String>{};
    for (final id in ids.toSet()) {
      try {
        await controlDownloads(command, id: id);
        completed.add(id);
      } catch (error) {
        failures[id] = error.toString();
      }
    }
    return DownloadBatchResult(completed: completed, failures: failures);
  }

  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) => enqueueDownloads(detail, episodes, quality: quality);
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async =>
      null;
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
  }) => resolve(drama, episode, quality: quality, adBlock: adBlock);
  Future<bool> sourceDevices(String source, {bool register = false}) async =>
      true;
  Future<SoraniAccount> soraniAccount() async => const SoraniAccount();
  Future<SoraniCaptcha> soraniCaptcha() async =>
      throw AppFailure('当前版本不支持登录青空次元');
  Future<SoraniAccount> soraniLogin({
    required String identifier,
    required String password,
    required String captchaId,
    required SoraniCaptchaTrack track,
  }) async => throw AppFailure('当前版本不支持登录青空次元');
  Future<SoraniAccount> soraniLogout() async => const SoraniAccount();
  Future<void> initialize();
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String lane = '',
    bool force = false,
  });
  Future<CatalogPage> cached(String source, {String category = ''});

  /// 跨源聚合搜索：启动一轮并发搜索并立刻返回首个快照，
  /// 之后用 [searchPoll] 增量取结果，无需等所有站源搜完。
  Future<SearchProgress> searchStart(List<String> sources, String query) =>
      throw AppFailure('当前环境不支持全部源搜索');
  Future<SearchProgress> searchPoll(String id) =>
      throw AppFailure('当前环境不支持全部源搜索');
  Future<void> searchCancel(String id) async {}
  Future<String> cover(Drama drama, {bool force = false});
  bool coverCached(Drama drama) => false;

  /// 已解码并缓存到本机的封面路径，供封面组件在异步读取完成前直接显示，
  /// 避免每次重建都先闪一下占位图。
  String? knownCover(Drama drama) => null;
  Future<DramaDetail> detail(Drama drama);
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int routeIndex = -1,
  });
  Future<PlaybackPlan> fallback(PlaybackPlan current);

  /// 切到第 [route] 条线路（从 0 开始）。核心支持 selectRoute 时一步到位；
  /// 旧核心只认识「下一条」，这里沿 fallback 往前翻，翻不到就报错。
  Future<PlaybackPlan> selectRoute(PlaybackPlan current, int route) async {
    var plan = current;
    for (var step = 0; step <= 8 && plan.routeIndex != route; step++) {
      plan = await fallback(plan);
    }
    if (plan.routeIndex != route) throw AppFailure('这条线路暂时切不过去，请稍后重试');
    return plan;
  }

  Future<void> cancelPlayback();
  Future<void> release(String session);

  // ---- 听书（番茄畅听）：Flutter 与本地服务端共用 Go 核心的同一组动作 ----
  Future<Map<String, dynamic>> audiobookMedia(
    String bookId,
    String chapterId,
  ) async => throw AppFailure('当前环境不支持听书播放');

  /// 章节正文：`paragraphs` 每项含 `text`、`start`（秒，无时间戳为 -1）和逐句 `segments`。
  Future<Map<String, dynamic>> audiobookText(String chapterId) async =>
      throw AppFailure('当前环境不支持听书原文');

  /// 榜单 / 搜索 / 目录 / 网页正文的原始 JSON；Go 核心按域名白名单代发。
  Future<String> audiobookFetch(
    String url, {
    Map<String, String> headers = const {},
  }) async => throw AppFailure('当前环境不支持听书源');

  // ---- 网盘分享（夸克 / UC）：扫码登录、Cookie 登录、分享解析、直链取流 ----
  Future<Map<String, dynamic>> netdiskStatus() async => const {};

  /// 生成扫码登录二维码，返回 `id` 与 `qrBase64`（PNG）。
  /// [provider] 取 `quark` 或 `uc`，默认夸克。
  Future<Map<String, dynamic>> netdiskLogin({
    String provider = 'quark',
  }) async => throw AppFailure('当前环境不支持网盘登录');
  Future<Map<String, dynamic>> netdiskLoginPoll(String session) async =>
      const {};

  /// 用浏览器里复制出来的 Cookie 直接登录（免扫码）。
  Future<Map<String, dynamic>> netdiskLoginCookie(
    String cookie, {
    String provider = 'quark',
  }) async => throw AppFailure('当前环境不支持网盘登录');
  Future<void> netdiskLogout(String provider) async {}

  /// 解析分享链接，返回 `episodes`（每项含 `fid`、`name`、`size`）。
  Future<Map<String, dynamic>> netdiskShare(String url) async =>
      throw AppFailure('当前环境不支持网盘分享');

  /// 把分享里第 index 集转存并取回直链（含播放所需请求头）。
  Future<Map<String, dynamic>> netdiskPlay(String url, int index) async =>
      throw AppFailure('当前环境不支持网盘播放');

  /// 把分享解析成标准剧集，供统一详情页与主播放器使用。
  Future<Drama> netdiskOpenShare(String url) async =>
      throw AppFailure('当前环境不支持网盘分享');

  /// 清理网盘根目录下的临时转存目录。
  Future<Map<String, dynamic>> netdiskCleanup({
    String provider = 'quark',
  }) async => const {};

  // ---- 饭太硬 / TVBox 接口订阅 ----
  Future<Map<String, dynamic>> tvboxStatus() async => const {};

  /// 订阅接口地址，返回 `supportedCount` / `skippedCount` / `sites`。
  Future<Map<String, dynamic>> tvboxSubscribe(String url) async =>
      throw AppFailure('当前环境不支持 TVBox 订阅');
  Future<Map<String, dynamic>> tvboxClear() async => const {};

  // ---- 人机验证桥接：站源需要 Cloudflare 校验时用它 ----
  /// 返回该站源建议打开的验证地址；没有可用地址时返回空串。
  Future<String> sourceChallengeUrl(String source) async => '';

  /// 登记 WebView 回环抓取端口与验证后的 Cookie / UA，核心之后会用它取页面。
  Future<void> registerWebViewBridge({
    required int port,
    required String url,
    required String source,
    String cookies = '',
    String userAgent = '',
  }) async {}

  /// 登记 Android TVBox .jar Spider 插件桥接端口。
  Future<void> registerSpiderBridge(int port) async {}

  /// 当前平台是否支持应用内浏览器完成人机验证。
  bool get supportsWebViewVerify => false;

  /// 打开应用内验证页，通过后把 Cookie / UA 交给核心。
  Future<bool> verifySource(String source) async => false;
}

class NativeRepository extends AppRepository {
  static final _coverDecoder = CoverDecoder();

  /// JS 沙箱网关。沙箱挂载后才有值；没挂载时所有入口退回内核，老用户
  /// 不会因为沙箱初始化慢半拍而看到一排空列表。
  JsSourceGateway? get jsSandbox =>
      JsSourceGateway.instance.attached ? JsSourceGateway.instance : null;

  /// PY 沙箱网关。装配后才有值，未装配时所有入口退回内核。
  PySourceGateway? get pySandbox =>
      PySourceGateway.instance.attached ? PySourceGateway.instance : null;
  static final _coverPaths = <String, String>{};
  NativeRepository({this.background = false});
  final bool background;
  LocalStore? access;
  final _readOwner = DateTime.now().microsecondsSinceEpoch.toString();
  int _readSequence = 0;
  final _activeReads = <String, int>{};

  void _adminPermission() {
    if (access != null && (access!.locked || !access!.profile.admin)) {
      throw AppFailure('仅管理员可修改本机资源设置');
    }
  }

  @override
  Future<ResourceSettings> resourceSettings() async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({'action': 'resourceSettings'}),
    );
  }

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({
        'action': 'saveResourceSettings',
        'settings': settings.toJson(),
      }),
    );
  }

  Future<Map<String, dynamic>> _read(
    String scope,
    Map<String, dynamic> input,
  ) async {
    final sequence = ++_readSequence;
    _activeReads[scope] = sequence;
    try {
      return await _call({
        ...input,
        'session': '$_readOwner:$scope',
        'sequence': sequence,
      });
    } finally {
      if (_activeReads[scope] == sequence) _activeReads.remove(scope);
    }
  }

  Future<void> _cancelReads(String prefix) async {
    final reads = _activeReads.entries
        .where((entry) => entry.key.startsWith(prefix))
        .toList();
    await Future.wait(
      reads.map((entry) async {
        try {
          await _call({
            'action': 'cancelRead',
            'session': '$_readOwner:${entry.key}',
            'sequence': entry.value,
          });
        } catch (_) {}
      }),
    );
  }

  @override
  Future<void> cancelDanmaku() => _cancelReads('danmaku');

  @override
  Future<void> cancelPreload() => _cancelReads('preload');

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async {
    // 沙箱源没有内核预缓冲队列：返回 null 让预加载器跳过，播放时照常解析。
    if (jsSandbox?.handles(drama.source) == true) return null;
    if (pySandbox?.handles(drama.source) == true) return null;
    return PlaybackPlan.fromJson(
      await _read('preload', {
        'action': 'preload',
        'drama': drama.toJson(),
        'chapter': episode.raw,
        'index': episode.number,
        'quality': quality,
        'force': online || access?.canDownload == false,
      }),
    );
  }

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    final sandbox = jsSandbox;
    if (sandbox != null &&
        plan.danmakuId.isNotEmpty &&
        isJsPlaybackSession(plan.session)) {
      return sandbox.danmaku(plan, startMs: startMs, durationMs: durationMs);
    }
    final py = pySandbox;
    // py 源即使没有 danmakuId，只要播放计划里带了弹幕地址（红果系在
    // playerContent 里直接给本机 /hg_dm 地址）也应该交给沙箱去取。
    if (py != null &&
        plan.session.startsWith('py:') &&
        (plan.danmakuId.isNotEmpty || plan.danmakuUrls.isNotEmpty)) {
      return py.danmaku(plan, startMs: startMs, durationMs: durationMs);
    }
    if (plan.local || plan.session.isEmpty || plan.danmakuId.isEmpty) {
      throw AppFailure('本集暂不支持弹幕');
    }
    return DanmakuPage.fromJson(
      await _read('danmaku', {
        'action': 'danmaku',
        'playbackSession': plan.session,
        'startMs': startMs,
        'durationMs': durationMs,
      }),
      episodeId: plan.danmakuId,
      startMs: startMs,
      durationMs: durationMs,
    );
  }

  @override
  Future<List<CastDevice>> castDevices() async {
    final result = await _call({'action': 'cast', 'command': 'discover'});
    return [
      for (final row in (result['items'] as List? ?? []).whereType<Map>())
        (id: row['id'] as String? ?? '', name: row['name'] as String? ?? ''),
    ];
  }

  @override
  Future<void> castPlay(
    CastDevice device,
    Drama drama,
    Episode episode, {
    int quality = 0,
    double position = 0,
  }) async {
    try {
      await BackgroundDownloads.ensureStarted();
    } on AppFailure {
      DiaryService.add('[Cast] 后台服务未启动，应用退到后台后投屏可能中断');
    }
    await _call({
      'action': 'cast',
      'command': 'play',
      'device': device.id,
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'startMs': (position * 1000).round(),
    });
  }

  @override
  Future<CastStatus> castStatus() async {
    final result = await _call({'action': 'cast', 'command': 'status'});
    return (
      state: result['state'] as String? ?? 'stopped',
      position: intValue(result['positionMs']) / 1000,
      duration: intValue(result['durationMs']) / 1000,
    );
  }

  @override
  Future<void> castControl(String command, {double position = 0}) async {
    await _call({
      'action': 'cast',
      'command': command,
      'startMs': (position * 1000).round(),
    });
  }

  @override
  Future<bool> castActive() async =>
      (await _call({'action': 'cast', 'command': 'active'}))['active'] == true;

  @override
  Future<String> castBase({String peer = ''}) async {
    final data = await _call({
      'action': 'castBase',
      if (peer.isNotEmpty) 'peer': peer,
    });
    final base = data['base'];
    if (base is! String || base.isEmpty) {
      throw AppFailure('无法获取局域网投屏地址，请确认手机已连接 Wi-Fi');
    }
    return base;
  }

  @override
  Future<void> releaseCastBase() async {
    try {
      await _call({'action': 'closeCast'});
    } catch (_) {}
  }

  @override
  Future<void> cancelCatalog() {
    jsSandbox?.cancelAll();
    pySandbox?.cancelAll();
    return _cancelReads('catalog-');
  }

  @override
  Future<void> cancelSuggestions() => _cancelReads('suggestions');
  @override
  Future<void> cancelRecommendations() => _cancelReads('recommendations-');

  @override
  Future<CatalogPage> recommendations(
    String source,
    String genre, {
    bool more = false,
    bool force = false,
    String lane = '',
  }) async {
    final sandbox = jsSandbox;
    if (sandbox != null && sandbox.handles(source)) {
      return sandbox.recommendations(source, genre, more ? 0 : 1);
    }
    final py = pySandbox;
    if (py != null && py.handles(source)) {
      return py.recommendations(source, genre, more ? 0 : 1);
    }
    _authorize(source);
    return CatalogPage.fromJson(
      await _read('recommendations-$source-$genre${lane.isEmpty ? '' : '-$lane'}', {
        'action': 'recommendations',
        'source': source,
        'category': genre,
        'command': more ? 'more' : '',
        'force': force,
      }),
    );
  }

  @override
  Future<Drama?> supplementMetadata(Drama drama) async {
    if (!SourceSite.byId(drama.source).metadata) return null;
    final result = await _read('metadata', {
      'action': 'metadata',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  Future<Drama> followCheck(Drama drama) async {
    final sandbox = jsSandbox;
    if (sandbox != null && sandbox.handles(drama.source)) {
      return (await sandbox.detail(drama)).drama;
    }
    final py = pySandbox;
    if (py != null && py.handles(drama.source)) {
      return (await py.detail(drama)).drama;
    }
    _authorize(drama.source);
    final result = await _call({
      'action': 'followCheck',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  bool get supportsSourceManagement => true;

  @override
  Future<List<RankingBoard>> rankingBoards() async {
    final sandbox = jsSandbox;
    final jsBoards = <RankingBoard>[];
    if (sandbox != null) {
      for (final site in SourceSite.jsValues) {
        if (!sandbox.handles(site.id)) continue;
        try {
          jsBoards.addAll(await sandbox.rankingBoards(site.id));
        } catch (_) {
          // 单个脚本没实现榜单不该让整个榜单请求失败。
        }
      }
    }
    final result = await _call({'action': 'rankingBoards'});
    return [
          ...jsBoards,
          for (final row in result['items'] as List? ?? [])
            RankingBoard.fromJson(Map<String, dynamic>.from(row as Map)),
        ]
        .where(
          (board) =>
              SourceSite.isAvailable(board.source) &&
              (access?.allowsSource(board.source) ?? true),
        )
        .toList();
  }

  @override
  Future<RankingPage> rankings(
    RankingBoard board, {
    int page = 1,
    bool force = false,
  }) async {
    final sandbox = jsSandbox;
    if (sandbox != null && sandbox.handles(board.source)) {
      return sandbox.rankings(board.source, board, page);
    }
    final py = pySandbox;
    if (py != null && py.handles(board.source)) {
      return py.rankings(board.source, board, page);
    }
    _authorize(board.source);
    return RankingPage.fromJson(
      await _call({
        'action': 'rankings',
        'board': board.id,
        'page': page,
        'force': force,
      }),
    );
  }

  void _authorize(String source, {bool download = false}) {
    // 自定义源 / JS 沙箱源不进核心注册源列表，显式放行，避免顶层可用性
    // 判定再次收窄时把所有 XBPQ / MacCMS / 脚本源拦成「当前版本不包含此站源」。
    if (!SourceSite.isCustomId(source) && !SourceSite.isAvailable(source)) {
      throw AppFailure('当前版本不包含此站源');
    }
    if (access == null) return;
    if (access!.locked ||
        !access!.allowsSource(source) ||
        download && !access!.canDownload) {
      throw AppFailure('当前用户没有此操作权限');
    }
  }

  void _downloadPermission() {
    if (access != null && (access!.locked || !access!.canDownload)) {
      throw AppFailure('当前用户仅支持在线观看');
    }
  }

  @override
  Future<List<String>> suggestions(String source, String query) async {
    final sandbox = jsSandbox;
    if (sandbox != null && sandbox.handles(source)) {
      return sandbox.suggestions(source, query);
    }
    final py = pySandbox;
    if (py != null && py.handles(source)) {
      return py.suggestions(source, query);
    }
    _authorize(source);
    final result = await _read('suggestions', {
      'action': 'suggestions',
      'source': source,
      'query': query,
    });
    return (result['items'] as List? ?? []).whereType<String>().toList();
  }

  @override
  Future<Map<String, dynamic>> netdiskStatus() async =>
      await _call({'action': 'netdiskStatus'});

  @override
  Future<Map<String, dynamic>> netdiskLogin({
    String provider = 'quark',
  }) async => await _call({'action': 'netdiskLogin', 'source': provider});

  @override
  Future<Map<String, dynamic>> netdiskLoginCookie(
    String cookie, {
    String provider = 'quark',
  }) async => await _call({
    'action': 'netdiskLoginCookie',
    'source': provider,
    'url': cookie,
  });

  @override
  Future<Map<String, dynamic>> netdiskLoginPoll(String session) async =>
      await _call({'action': 'netdiskLoginPoll', 'session': session});

  @override
  Future<void> netdiskLogout(String provider) async {
    await _call({'action': 'netdiskLogout', 'source': provider});
  }

  @override
  Future<Map<String, dynamic>> netdiskShare(String url) async =>
      await _call({'action': 'netdiskShare', 'url': url});

  @override
  Future<Map<String, dynamic>> netdiskPlay(String url, int index) async =>
      await _call({'action': 'netdiskPlay', 'url': url, 'index': index});

  @override
  Future<Drama> netdiskOpenShare(String url) async {
    final result = await _call({'action': 'netdiskOpenShare', 'url': url});
    return Drama.fromJson(
      Map<String, dynamic>.from(result['drama'] as Map? ?? const {}),
    );
  }

  @override
  Future<Map<String, dynamic>> netdiskCleanup({
    String provider = 'quark',
  }) async => await _call({'action': 'netdiskCleanup', 'source': provider});

  @override
  Future<Map<String, dynamic>> tvboxStatus() async =>
      await _call({'action': 'tvboxStatus'});

  @override
  Future<Map<String, dynamic>> tvboxSubscribe(String url) async {
    final result = await _call({'action': 'tvboxSubscribe', 'url': url});
    _installSources(result['sources']);
    return result;
  }

  @override
  Future<Map<String, dynamic>> tvboxClear() async {
    final result = await _call({'action': 'tvboxClear'});
    _installSources(result['sources']);
    return result;
  }

  @override
  Future<String> sourceChallengeUrl(String source) async {
    final result = await _call({
      'action': 'sourceChallengeUrl',
      'source': source,
    });
    return result['url'] as String? ?? '';
  }

  @override
  Future<void> registerWebViewBridge({
    required int port,
    required String url,
    required String source,
    String cookies = '',
    String userAgent = '',
  }) async {
    await _call({
      'action': 'webViewBridge',
      'index': port,
      'url': url,
      'source': source,
      'token': cookies,
      'device': userAgent,
    });
  }

  @override
  Future<void> registerSpiderBridge(int port) async {
    await _call({'action': 'spiderBridge', 'index': port});
  }

  @override
  bool get supportsWebViewVerify => WebViewBridge.supported;

  @override
  Future<bool> verifySource(String source) =>
      WebViewBridge.verifySource(this, source);

  @override
  Future<String> downloadDirectory() async {
    _downloadPermission();
    return (await _call({'action': 'downloadDirectory'}))['directory']
            as String? ??
        '';
  }

  @override
  Future<Map<String, dynamic>> storage() async {
    _downloadPermission();
    return _call({'action': 'storage'});
  }

  @override
  Future<({String path, String reason})> moveDownloads(String directory) async {
    _downloadPermission();
    if (access != null && !access!.profile.admin) {
      throw AppFailure('仅管理员可更改下载目录');
    }
    await BackgroundDownloads.ensureStarted();
    await workLease('storage', 'start');
    try {
      final result = await _call({
        'action': 'moveDownloads',
        'directory': directory,
      });
      return (
        path: result['leftover'] as String? ?? '',
        reason: result['leftoverReason'] as String? ?? '',
      );
    } finally {
      await workLease('storage', 'end');
    }
  }

  @override
  Future<int> workLease(String id, String command) async => intValue(
    (await _call({
      'action': 'workLease',
      'jobId': id,
      'command': command,
    }))['count'],
  );

  @override
  Future<int> cacheBytes() async =>
      intValue((await _call({'action': 'cache'}))['bytes']);

  @override
  Future<void> clearCache() async {
    await _call({'action': 'clearCache'});
    _coverPaths.clear();
  }

  @override
  Future<List<String>> deleteAllData() async {
    if (access != null && !access!.profile.admin) {
      throw AppFailure('仅管理员可删除全部数据');
    }
    await workLease('storage', 'start');
    try {
      final result = await _call({'action': 'deleteAllData'});
      return [
        for (final item in result['leftover'] as List? ?? const []) '$item',
      ];
    } catch (_) {
      await workLease('storage', 'end');
      rethrow;
    }
  }

  int _playbackSequence = DateTime.now().microsecondsSinceEpoch;
  (String, List<DownloadJob>) _downloadCache = ('', const []);
  List<DownloadJob> _visibleDownloads = const [];

  @override
  Future<bool> sourceDevices(String source, {bool register = false}) async =>
      (await _call({
        'action': 'sourceDevices',
        'source': source,
        if (register) 'command': 'register',
      }))['ready'] ==
      true;

  void _soraniPermission() {
    if (access != null && (access!.locked || !access!.profile.admin)) {
      throw AppFailure('仅管理员可登录或退出青空次元账号');
    }
  }

  @override
  Future<SoraniAccount> soraniAccount() async =>
      SoraniAccount.fromJson(await _call({'action': 'soraniAccount'}));

  @override
  Future<SoraniCaptcha> soraniCaptcha() async {
    _soraniPermission();
    return SoraniCaptcha.fromJson(
      await _call({'action': 'soraniAccount', 'command': 'captcha'}),
    );
  }

  @override
  Future<SoraniAccount> soraniLogin({
    required String identifier,
    required String password,
    required String captchaId,
    required SoraniCaptchaTrack track,
  }) async {
    _soraniPermission();
    return SoraniAccount.fromJson(
      await _call({
        'action': 'soraniAccount',
        'command': 'login',
        'account': {
          'identifier': identifier,
          'password': password,
          'captchaId': captchaId,
          'track': track.toJson(),
        },
      }),
    );
  }

  @override
  Future<SoraniAccount> soraniLogout() async {
    _soraniPermission();
    return SoraniAccount.fromJson(
      await _call({'action': 'soraniAccount', 'command': 'logout'}),
    );
  }

  Future<Map<String, dynamic>> _call(Map<String, dynamic> input) async {
    try {
      final action = input['action'] as String;
      final unrestricted =
          {
            'initialize',
            'release',
            'cancelPlayback',
            'cancelRead',
            'updateSystemProxy',
          }.contains(action) ||
          action == 'workLease' && input['command'] == 'end' ||
          action == 'finishConversion' ||
          action == 'cast' && {'stop', 'active'}.contains(input['command']) ||
          action == 'lan' &&
              {
                'stop',
                'respond',
                'cancel',
                'disconnect',
              }.contains(input['command']);
      final epoch = access?.profileEpoch;
      if (!unrestricted && access?.locked == true) throw AppFailure('请先解锁当前用户');
      if ({
        'catalog',
        'cached',
        'categories',
        'recommendations',
        'cachedRecommendations',
        'suggestions',
      }.contains(action)) {
        _authorize(input['source'] as String);
      }
      if ({
            'cover',
            'prepareCover',
            'detail',
            'seasons',
            'metadata',
            'resolve',
            'preload',
            'enqueueDownloads',
            'localPlayback',
          }.contains(action) ||
          action == 'cast' && input['command'] == 'play') {
        _authorize(
          (input['drama'] as Map)['source'] as String,
          download: action == 'enqueueDownloads' || action == 'localPlayback',
        );
      }
      if (!unrestricted &&
          {
            'downloads',
            'controlDownloads',
            'controlDownloadBatch',
            'beginConversion',
            'storage',
            'downloadDirectory',
            'moveDownloads',
            'workLease',
          }.contains(action)) {
        _downloadPermission();
      }
      if (action == 'resolve' && access != null && !access!.canDownload) {
        input['force'] = true;
      }
      final body = jsonEncode(input);
      final response =
          await Isolate.run(
            () => jsonDecode(_nativeRequest(body)) as Map<String, dynamic>,
          ).timeout(
            Duration(
              seconds: action == 'moveDownloads' || action == 'deleteAllData'
                  ? 620
                  : action == 'danmaku'
                  ? 15
                  : action == 'preload'
                  ? 20
                  : 70,
            ),
          );
      if (response['ok'] != true) {
        throw AppFailure(
          response['error'] as String? ?? '读取失败，请重试',
          code: response['code'] as String? ?? '',
        );
      }
      final data = response['data'];
      if (!unrestricted && epoch != access?.profileEpoch) {
        if (data is Map && data['session'] is String) {
          await release(data['session'] as String);
        }
        if (action == 'workLease' && input['command'] == 'start') {
          await workLease(input['jobId'] as String, 'end');
        }
        throw AppFailure('用户已切换，请重新操作');
      }
      return data is Map ? Map<String, dynamic>.from(data) : {};
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      if (input['session'] is String &&
          input['sequence'] is int &&
          {
            'catalog',
            'categories',
            'suggestions',
            'recommendations',
            'metadata',
            'danmaku',
            'preload',
          }.contains(input['action'])) {
        unawaited(
          _call({
            'action': 'cancelRead',
            'session': input['session'],
            'sequence': input['sequence'],
          }).catchError((Object _) => <String, dynamic>{}),
        );
      }
      DiaryService.add('[Core] ${input['action']} 超时');
      throw AppFailure(
        const {
              'catalog',
              'categories',
              'suggestions',
              'recommendations',
              'rankings',
              'rankingBoards',
              'metadata',
              'danmaku',
              'preload',
              'detail',
              'seasons',
              'followCheck',
              'resolve',
              'fallback',
            }.contains(input['action'])
            ? '站源响应超时，请重试'
            : '操作超时，请重试',
      );
    } catch (error) {
      DiaryService.add('[Core] ${input['action']} 调用异常：$error');
      final text = '$error';
      throw AppFailure(
        error is UnsupportedError ||
                text.contains('Failed to load dynamic library') ||
                text.contains('Failed to lookup symbol')
            ? '本地核心加载失败，请使用完整安装包重新安装'
            : '应用内部出错，请重试；反复出现时请带上日记反馈',
      );
    }
  }

  void _installSources(Object? rows) {
    SourceSite.install([
      for (final row in rows as List? ?? const [])
        SourceSite.fromJson(Map<String, dynamic>.from(row as Map)),
    ]);
    access?.sourcesChanged();
  }

  // ---- 自定义源管理 ----
  //
  // 这里刻意不做管理员校验：自定义源与源显示开关属于「谁用谁配」的本机偏好，
  // 普通用户也应该能自己加源、改源、删源；只有下载目录、系统代理这类会影响
  // 整机/其它用户的设置才限制管理员。

  @override
  Future<List<CustomSourceSite>> customSources() async {
    final result = await _call({'action': 'customSources'});
    return [
      for (final row in result['items'] as List? ?? const [])
        CustomSourceSite.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<CustomSourceSite> addCustomSource({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async {
    final result = await _call({
      'action': 'addCustomSource',
      'name': name,
      'base': base,
      'rule': rule,
      'kind': kind,
    });
    return CustomSourceSite.fromJson(Map<String, dynamic>.from(result as Map));
  }

  @override
  Future<CustomSourceSite> updateCustomSource(
    String id, {
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async {
    final result = await _call({
      'action': 'updateCustomSource',
      'source': id,
      'name': name,
      'base': base,
      'rule': rule,
      'kind': kind,
    });
    return CustomSourceSite.fromJson(Map<String, dynamic>.from(result as Map));
  }

  @override
  Future<void> removeCustomSource(String id) async {
    await _call({'action': 'removeCustomSource', 'source': id});
  }

  @override
  Future<String> exportCustomSources() async {
    final result = await _call({'action': 'exportCustomSources'});
    return (result as Map)['content'] as String? ?? '';
  }

  @override
  Future<Map<String, dynamic>> importCustomSources(String content) async {
    final result = await _call({
      'action': 'importCustomSources',
      'content': content,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  @override
  Future<int> resetCustomSources() async {
    final result = await _call({'action': 'resetCustomSources'});
    return (result as Map)['removed'] as int? ?? 0;
  }

  @override
  Future<Map<String, dynamic>> analyzeCustomSourceSite(String base) async {
    final result = await _call({
      'action': 'analyzeCustomSourceSite',
      'base': base,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  @override
  Future<List<SourceModule>> modules() async {
    final result = await _call({'action': 'modules'});
    return [
      for (final row in result['items'] as List? ?? const [])
        SourceModule.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<ModuleStore> moduleIndex() async {
    final result = await _call({'action': 'moduleIndex'});
    return ModuleStore([
      for (final row in result['items'] as List? ?? const [])
        ModuleIndexEntry.fromJson(Map<String, dynamic>.from(row as Map)),
    ], warning: result['warning'] as String? ?? '');
  }

  @override
  Future<ModuleRepositories> moduleRepositories() async =>
      ModuleRepositories.fromJson(
        await _call({'action': 'moduleRepositories'}),
      );

  @override
  Future<ModuleRepositories> saveModuleRepositories(
    List<ModuleRepository> repositories,
    int active,
  ) async => ModuleRepositories.fromJson(
    await _call({
      'action': 'saveModuleRepositories',
      'repositories': [for (final repo in repositories) repo.toJson()],
      'activeRepository': active,
    }),
  );

  @override
  Future<SourceModule> prepareModule({
    String file = '',
    String url = '',
    String indexed = '',
    bool bundled = false,
  }) async {
    return SourceModule.fromJson(
      await _call({
        'action': 'prepareModule',
        'file': file,
        'url': url,
        'source': indexed,
        'bundled': bundled,
      }),
    );
  }

  @override
  Future<String> installModule(String token) async {
    final result = await _call({'action': 'installModule', 'token': token});
    _installSources(result['sources']);
    return result['source'] as String;
  }

  @override
  Future<void> uninstallModule(String id) async {
    final result = await _call({'action': 'uninstallModule', 'source': id});
    _installSources(result['sources']);
  }

  @override
  Future<List<PreparedModule>> prepareModules({
    List<String> files = const [],
    List<String> urls = const [],
  }) async {
    final result = await _call({
      'action': 'prepareModules',
      'files': files,
      'urls': urls,
    });
    return [
      for (final row in result['items'] as List? ?? const [])
        PreparedModule.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<({List<String> removed, List<String> failures})> uninstallModules(
    List<String> ids,
  ) async {
    final result = await _call({'action': 'uninstallModules', 'ids': ids});
    _installSources(result['sources']);
    return (
      removed: (result['removed'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      failures: (result['failures'] as List? ?? const [])
          .whereType<String>()
          .toList(),
    );
  }

  @override
  Future<({List<String> removed, int bundled})> resetModules() async {
    final result = await _call({'action': 'resetModules'});
    _installSources(result['sources']);
    return (
      removed: (result['removed'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      bundled: (result['bundled'] as List? ?? const []).length,
    );
  }

  @override
  Future<ModuleExport> exportModules({List<String> ids = const []}) async {
    final result = await _call({'action': 'exportModules', 'ids': ids});
    final content = result['content'] as String? ?? '';
    if (content.isEmpty) throw AppFailure('没有可导出的模块');
    return ModuleExport(
      bytes: base64Decode(content),
      names: (result['names'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      count: result['count'] as int? ?? 0,
    );
  }

  @override
  Map<String, int> missingSourceDownloads() {
    final counts = <String, int>{};
    for (final job in _downloadCache.$2) {
      final source = job.drama.source;
      if (!SourceSite.isAvailable(source)) {
        counts[source] = (counts[source] ?? 0) + 1;
      }
    }
    return counts;
  }

  @override
  Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    if (!background) {
      DiaryService.nativeLogPath = path.join(directory.path, 'logs', 'app.log');
    }
    final external = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : null;
    final build = await _call({
      'action': 'initialize',
      'directory': directory.path,
      'cache': (await getApplicationCacheDirectory()).path,
      if (external != null) 'downloads': path.join(external.path, 'downloads'),
    });
    _installSources(build['sources']);
    if (!background) await BackgroundDownloads.prepare();
    if (!background) {
      SystemProxyMonitor.start((value) async {
        await _call({'action': 'updateSystemProxy', 'systemProxy': value});
      });
    }
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    final sandbox = jsSandbox;
    if (sandbox != null && sandbox.handles(source)) {
      final rows = await sandbox.categories(source);
      return rows.isEmpty ? const [CatalogCategory.all] : rows;
    }
    final py = pySandbox;
    if (py != null && py.handles(source)) {
      final rows = await py.categories(source);
      return rows.isEmpty ? const [CatalogCategory.all] : rows;
    }
    final result = await _read('categories-$source', {
      'action': 'categories',
      'source': source,
      'force': force,
    });
    return [
      for (final row in result['items'] as List? ?? const [])
        CatalogCategory.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String lane = '',
    bool force = false,
  }) async {
    final sandbox = jsSandbox;
    if (sandbox != null && sandbox.handles(source)) {
      return sandbox.catalog(
        source,
        category,
        page,
        query: query,
        force: force,
      );
    }
    final py = pySandbox;
    if (py != null && py.handles(source)) {
      return py.catalog(
        source,
        category,
        page,
        query: query,
        force: force,
      );
    }
    return CatalogPage.fromJson(
      await _read(
        switch ((query.isEmpty, lane.isEmpty)) {
          (false, _) => 'catalog-$source-search',
          (true, true) => 'catalog-$source',
          (true, false) => 'catalog-$source-$lane',
        },
        {
          'action': 'catalog',
          'source': source,
          'page': page,
          'query': query,
          'category': category,
          'force': force,
        },
      ),
    );
  }

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async {
    // 沙箱源没有内核缓存表：交给它自己按分类现取，避免「全部」tab 一片空。
    if (jsSandbox?.handles(source) == true) {
      return CatalogPage(const []);
    }
    if (pySandbox?.handles(source) == true) {
      return CatalogPage(const []);
    }
    return CatalogPage.fromJson(
      await _call({'action': 'cached', 'source': source, 'category': category}),
    );
  }

  /// 「全部源」里的 JS 源搜索会话：内核不认识 `js:` 前缀，脚本又在 Dart
  /// 侧跑，所以脚本源单独并发搜，再把结果并进内核的快照。
  final Map<String, JsSearchMerge> _jsSearches = {};

  @override
  Future<SearchProgress> searchStart(List<String> sources, String query) async {
    final sandbox = jsSandbox;
    final jsSources = sandbox == null
        ? const <String>[]
        : [
            for (final source in sources)
              if (sandbox.handles(source)) source,
          ];
    final native = [
      for (final source in sources)
        if (!SourceSite.isJsId(source) && !SourceSite.isPyId(source)) source,
    ];
    if (jsSources.isEmpty) {
      return SearchProgress.fromJson(
        await _call({
          'action': 'searchStart',
          'sources': sources,
          'query': query,
          'page': 1,
        }),
      );
    }
    _jsSearches.removeWhere((_, merge) => merge.finished);
    final merge = JsSearchMerge(query: query, sources: jsSources)
      ..run(sandbox!, query);
    merge.onlyJs = native.isEmpty;
    if (native.isEmpty) {
      final id = 'js-${DateTime.now().microsecondsSinceEpoch}';
      _jsSearches[id] = merge;
      return merge.snapshot(id);
    }
    final base = SearchProgress.fromJson(
      await _call({
        'action': 'searchStart',
        'sources': native,
        'query': query,
        'page': 1,
      }),
    );
    _jsSearches[base.id] = merge;
    return merge.merge(base);
  }

  @override
  Future<SearchProgress> searchPoll(String id) async {
    final merge = _jsSearches[id];
    if (merge != null && merge.onlyJs) {
      return merge.snapshot(id);
    }
    final base = SearchProgress.fromJson(
      await _call({'action': 'searchPoll', 'search': id}),
    );
    return merge == null ? base : merge.merge(base);
  }

  @override
  Future<void> searchCancel(String id) async {
    _jsSearches.remove(id);
    try {
      await _call({'action': 'searchCancel', 'search': id});
    } catch (_) {
      // 会话已结束或核心正在重启：取消失败不算错误。
    }
  }

  @override
  bool coverCached(Drama drama) =>
      _coverPaths.containsKey('${drama.id}\u0000${drama.cover}');

  @override
  String? knownCover(Drama drama) =>
      _coverPaths['${drama.id}\u0000${drama.cover}'];

  @override
  Future<String> cover(Drama drama, {bool force = false}) async {
    final key = '${drama.id}\u0000${drama.cover}';
    final known = force ? null : _coverPaths[key];
    if (known != null) {
      _authorize(drama.source);
      if (await File(known).exists()) return known;
      _coverPaths.remove(key);
    }
    final epoch = access?.profileEpoch;
    final result = await _call({
      'action': 'cover',
      'drama': drama.toJson(),
      'force': force,
    });
    final file = result['path'] as String? ?? '';
    if (file.isEmpty) throw AppFailure('海报暂不可用');
    if (result['heic'] != true) return _rememberCover(key, file);
    final converted = await _coverDecoder.convert(
      file,
      () => _call({'action': 'prepareCover', 'drama': drama.toJson()}),
      force: force,
    );
    _authorize(drama.source);
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return _rememberCover(key, converted);
  }

  String _rememberCover(String key, String path) {
    _coverPaths.remove(key);
    _coverPaths[key] = path;
    if (_coverPaths.length > 2000) _coverPaths.remove(_coverPaths.keys.first);
    return path;
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final sandbox = jsSandbox;
    if (sandbox != null && sandbox.handles(drama.source)) {
      return sandbox.detail(drama);
    }
    final py = pySandbox;
    if (py != null && py.handles(drama.source)) {
      return py.detail(drama);
    }
    return DramaDetail.fromJson(
      await _call({'action': 'detail', 'drama': drama.toJson()}),
    );
  }

  @override
  Future<List<DramaSeason>> seasons(Drama drama) async {
    // JS 沙箱源的多季走脚本的 `seriesSeasons`，内核不认识 `js:` 源。
    final sandbox = jsSandbox;
    if (sandbox != null && sandbox.handles(drama.source)) {
      try {
        return await sandbox.seasons(drama);
      } catch (_) {
        // 脚本没实现多季或接口暂不可用时，按「没有多季」处理，不影响详情页。
        return const <DramaSeason>[];
      }
    }
    final py = pySandbox;
    if (py != null && py.handles(drama.source)) {
      try {
        return await py.seasons(drama);
      } catch (_) {
        return const <DramaSeason>[];
      }
    }
    final result = await _call({'action': 'seasons', 'drama': drama.toJson()});
    return [
      for (final row in result['items'] as List? ?? const [])
        DramaSeason.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int routeIndex = -1,
  }) async {
    final sandbox = jsSandbox;
    if (sandbox != null && sandbox.handles(drama.source)) {
      return sandbox.resolve(
        drama,
        episode,
        quality: quality,
        routeIndex: routeIndex,
      );
    }
    final py = pySandbox;
    if (py != null && py.handles(drama.source)) {
      return py.resolve(
        drama,
        episode,
        quality: quality,
        routeIndex: routeIndex,
      );
    }
    return PlaybackPlan.fromJson(
      await _call({
        'action': 'resolve',
        'drama': drama.toJson(),
        'chapter': episode.raw,
        'index': episode.number,
        'quality': quality,
        'adBlock': adBlock,
        'sequence': ++_playbackSequence,
      }),
    );
  }

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async {
    if (isJsPlaybackSession(current.session) || current.session.startsWith('py:')) {
      throw AppFailure('这个源只返回了一条线路', code: 'NO_ROUTE');
    }
    return PlaybackPlan.fromJson(
      await _call({
        'action': 'fallback',
        'session': current.session,
        'sequence': ++_playbackSequence,
      }),
    );
  }

  @override
  Future<PlaybackPlan> selectRoute(PlaybackPlan current, int route) async {
    final sandbox = jsSandbox;
    if (isJsPlaybackSession(current.session)) {
      if (route == current.routeIndex) return current;
      if (sandbox != null) {
        // JS 源支持多线路时，按线路号重新解析当前集。
        return sandbox.resolveRoute(route);
      }
      throw AppFailure('这个 JS 源只返回了一条线路', code: 'NO_ROUTE');
    }
    if (current.session.startsWith('py:')) {
      if (route == current.routeIndex) return current;
      final py = pySandbox;
      if (py == null) {
        throw AppFailure('这个 py 源只返回了一条线路', code: 'NO_ROUTE');
      }
      return py.resolveRoute(route);
    }
    return PlaybackPlan.fromJson(
      await _call({
        'action': 'selectRoute',
        'session': current.session,
        'route': route,
        'sequence': ++_playbackSequence,
      }),
    );
  }

  @override
  Future<void> cancelPlayback() async {
    jsSandbox?.cancelPlayback();
    pySandbox?.cancelPlayback();
    await _call({'action': 'cancelPlayback', 'sequence': ++_playbackSequence});
  }

  @override
  bool get supportsDownloads => access?.canDownload ?? true;

  @override
  Future<List<DownloadJob>> downloads() async {
    final result = await _call({
      'action': 'downloads',
      'since': _downloadCache.$1,
    });
    if (result['jobs'] case final List jobs) {
      _downloadCache = (
        result['fingerprint'] as String? ?? '',
        jobs
            .whereType<Map>()
            .map(
              (value) => DownloadJob.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList(),
      );
    }
    final visible = _downloadCache.$2
        .where(
          (job) =>
              SourceSite.isAvailable(job.drama.source) &&
              (access == null || access!.allowsSource(job.drama.source)),
        )
        .toList();
    final previous = _visibleDownloads;
    if (visible.length == previous.length &&
        visible.indexed.every(
          (entry) => identical(entry.$2, previous[entry.$1]),
        )) {
      return previous;
    }
    return _visibleDownloads = List.unmodifiable(visible);
  }

  @override
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'force': true,
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids,
  ) async {
    _downloadPermission();
    final epoch = access?.profileEpoch;
    if (ids.isEmpty || ids.length > 500) throw AppFailure('每批请选择 1 至 500 个任务');
    final visible = (await downloads()).map((job) => job.id).toSet();
    if (ids.any((id) => !visible.contains(id))) {
      throw AppFailure('部分任务已删除或当前用户无权操作，请刷新');
    }
    if (command == 'resume') await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return DownloadBatchResult.fromJson(
      await _call({
        'action': 'controlDownloadBatch',
        'command': command,
        'jobIds': ids,
      }),
    );
  }

  @override
  Future<void> controlDownloads(String command, {String id = ''}) async {
    _downloadPermission();
    if (command == 'resume' || command == 'resumeAll') {
      await BackgroundDownloads.ensureStarted();
    }
    if (access != null && !access!.profile.admin) {
      final visible = await downloads();
      if (command == 'pauseAll' || command == 'resumeAll') {
        for (final job in visible.where(
          (job) => command == 'pauseAll' ? job.active : job.resumable,
        )) {
          await _call({
            'action': 'controlDownloads',
            'command': command == 'pauseAll' ? 'pause' : 'resume',
            'jobId': job.id,
          });
        }
        return;
      }
      if (!visible.any((job) => job.id == id)) {
        throw AppFailure('当前用户没有此下载任务权限');
      }
    }
    await _call({
      'action': 'controlDownloads',
      'command': command,
      'jobId': id,
    });
  }

  @override
  Future<DownloadConversion> beginConversion(String id) async {
    final result = await _call({'action': 'beginConversion', 'jobId': id});
    return (
      input: result['input'] as String? ?? '',
      key: result['key'] as String? ?? '',
      output: result['output'] as String? ?? '',
    );
  }

  @override
  Future<void> finishConversion(String id, String result) async {
    await _call({'action': 'finishConversion', 'jobId': id, 'command': result});
  }

  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async {
    final result = await _call({
      'action': 'localPlayback',
      'drama': drama.toJson(),
      'index': episode.number,
    });
    if ((result['url'] as String? ?? '').isEmpty) return null;
    return PlaybackPlan.fromJson(result);
  }

  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'adBlock': adBlock,
      'force': true,
      'sequence': ++_playbackSequence,
    }),
  );

  @override
  Future<void> release(String session) async {
    if (session.isEmpty || isJsPlaybackSession(session)) {
      return;
    }
    try {
      await _call({'action': 'release', 'session': session});
    } catch (_) {}
  }

  @override
  Future<Map<String, dynamic>> audiobookMedia(
    String bookId,
    String chapterId,
  ) => _call({
    'action': 'audiobookMedia',
    'query': bookId,
    'category': chapterId,
  });

  @override
  Future<Map<String, dynamic>> audiobookText(String chapterId) =>
      _call({'action': 'audiobookText', 'category': chapterId});

  @override
  Future<String> audiobookFetch(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final data = await _call({
      'action': 'audiobookFetch',
      'query': url,
      if (headers.isNotEmpty) 'content': jsonEncode(headers),
    });
    final body = data['body'];
    if (body is! String || body.isEmpty) {
      throw AppFailure('听书源没有返回内容');
    }
    return body;
  }
}
