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
import 'fanqie_backend.dart';
import 'local_store.dart';
import 'app_build.dart';
import 'ranking_models.dart';
import 'cover_decoder.dart';
import 'catalog_updates.dart';
import 'download_collections.dart';
import 'resource_settings.dart';
import 'diary_service.dart';
import 'sorani_account.dart';

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
    // iOS / macOS 的核心是以静态库链进主程序的，符号直接从进程里取。
    library = DynamicLibrary.process();
  } else {
    throw UnsupportedError('当前首版支持 Android 手机和 Windows 电脑');
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

typedef _NativeStderrLog = Int32 Function(Pointer<Utf8>);
typedef _DartStderrLog = int Function(Pointer<Utf8>);

/// 把原生核心（c-shared / c-archive）的标准错误重定向到 [logPath]。
///
/// 核心里的 panic 会被最外层 recover 兜成一句「本地核心处理失败，请重试」，
/// 堆栈只写 stderr；Android 上没有 logcat 抓取、Windows 双击启动没有 console，
/// 这些堆栈就彻底丢了。重定向到文件后即便只有一句错误提示，也能顺着堆栈定位。
/// 该符号在旧版原生核心里不存在，查找失败时静默跳过（旧包退回原行为）。
void installStderrLog(String logPath) {
  try {
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
      return;
    }
    final install = library.lookupFunction<_NativeStderrLog, _DartStderrLog>(
      'DuanjuInstallStderrLog',
    );
    final ptr = logPath.toNativeUtf8();
    try {
      install(ptr);
    } finally {
      malloc.free(ptr);
    }
  } catch (_) {
    // 符号不存在（旧原生核心）或路径不可写：忽略，退回原行为。
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

  /// 首启设备注册门禁：查询红果主设备 + 辅助设备是否都注册好；
  /// [register] 为 true 时是用户显式重试，会清掉上一次失败的暂停窗口。
  Future<bool> hongguoDevices({bool register = false}) async => true;

  // ---- 青空次元站源账号（所有用户均可登录 / 退出）----
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
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
    bool adBlock = true,
    int route = 0,
  }) async => null;
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
  Future<Drama> followCheck(Drama drama) async => (await detail(drama)).drama;
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持红果推荐');
  Future<List<RankingBoard>> rankingBoards() async => const [];
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持榜单');
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  bool get supportsSourceManagement => false;
  Future<List<String>> suggestions(String query) async => const [];
  Future<Map<String, dynamic>> storage() async => {};
  Future<Map<String, dynamic>> cacheInfo({String cacheDirectory = ''}) async =>
      {};
  Future<Map<String, dynamic>> clearCache({String cacheDirectory = ''}) async =>
      {};
  Future<String> downloadDirectory() async =>
      (await storage())['directory'] as String? ?? '';
  Future<void> moveDownloads(String directory) async =>
      throw AppFailure('当前环境不支持迁移');
  Future<int> workLease(String id, String command) async => 0;
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
    int route = 0,
  }) =>
      resolve(drama, episode, quality: quality, adBlock: adBlock, route: route);
  Future<void> initialize();
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
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
  Future<DramaDetail> detail(Drama drama);

  /// 同一系列的各季（按季号升序）。站源没有系列剧数据时返回空列表。
  Future<List<DramaSeason>> seasons(Drama drama) async => const [];

  /// [route] 是上一次选中的线路序号（0 起）：切集、换清晰度时沿用它，
  /// 只有这一集没有这条线路时核心才会回落到第一条线路。
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int route = 0,
  });
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  Future<PlaybackPlan> selectRoute(PlaybackPlan current, int route) =>
      throw AppFailure('当前环境不支持切换播放线路');
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

  // ---- 红果听书（听书 / 小说）：与番茄听书并列的第二个书源 ----

  /// 红果书城目录。category 是 `listen`（听书）或 `novel`（小说）。
  Future<Map<String, dynamic>> audiobookHongguoCatalog(
    String category,
    int page,
  ) async => throw AppFailure('当前环境不支持红果听书');

  /// 红果书城搜索，按频道（听书 / 小说）各查各的。
  Future<Map<String, dynamic>> audiobookHongguoSearch(
    String category,
    String query,
    int page,
  ) async => throw AppFailure('当前环境不支持红果听书');

  /// 红果听书详情 + 全量目录。
  Future<Map<String, dynamic>> audiobookHongguoChapters(String bookId) async =>
      throw AppFailure('当前环境不支持红果听书');

  /// 红果听书单章音频（加密音频带 CENC key）。
  Future<Map<String, dynamic>> audiobookHongguoMedia(
    String bookId,
    String chapterId,
  ) async => throw AppFailure('当前环境不支持红果听书');

  /// 投屏：核心把当前播放会话再挂一份到 0.0.0.0，返回电视能访问的内网基址。
  /// [peer] 是电视的地址，核心据此确定手机这一侧用哪块网卡（Android 上
  /// 枚举网卡不一定拿得到地址，按路由挑出口最可靠）。
  /// 非原生核心（测试替身 / 平台不支持）直接报错，界面据此隐藏投屏入口。
  Future<String> castBase({String peer = ''}) async =>
      throw AppFailure('当前环境不支持投屏');

  /// 停止投屏后关掉局域网监听，避免端口一直开着。
  Future<void> releaseCastBase() async {}

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
}

class NativeRepository extends AppRepository {
  static final _coverDecoder = CoverDecoder();
  static final _coverPaths = <String, String>{};
  NativeRepository({this.background = false});
  final bool background;
  LocalStore? access;
  final _readOwner = DateTime.now().microsecondsSinceEpoch.toString();
  int _readSequence = 0;
  final _activeReads = <String, int>{};

  /// 下载列表的上一份结果：指纹 + 解析好的任务。轮询时把指纹带回去，
  /// 列表没变时核心只回指纹，省掉整份列表的序列化 / 传输 / 解析。
  (String, List<DownloadJob>) _downloadCache = ('', const []);

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

  @override
  Future<bool> hongguoDevices({bool register = false}) async =>
      (await _call({
        'action': 'hongguoDevices',
        if (register) 'command': 'register',
      }))['ready'] ==
      true;

  // 青空账号与自定义源一样属于「谁用谁登」的本机状态，不校验管理员身份；
  // 仅保留 _call 里对所有动作统一生效的「当前用户已锁定」保护。
  @override
  Future<SoraniAccount> soraniAccount() async =>
      SoraniAccount.fromJson(await _call({'action': 'soraniAccount'}));

  @override
  Future<SoraniCaptcha> soraniCaptcha() async {
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
    return SoraniAccount.fromJson(
      await _call({'action': 'soraniAccount', 'command': 'logout'}),
    );
  }

  /// 这个请求是不是要打番茄站源（目录/分类带 source，详情/取流带 drama）。
  bool _targetsFanqie(Map<String, dynamic> input) {
    if (input['source'] == 'fanqie') return true;
    final drama = input['drama'];
    return drama is Map && drama['source'] == 'fanqie';
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
    bool adBlock = true,
    int route = 0,
  }) async => PlaybackPlan.fromJson(
    await _read('preload', {
      'action': 'preload',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'adBlock': adBlock,
      'route': route,
      'force': online || access?.canDownload == false,
    }),
  );

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    _authorize('hongguo');
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
  Future<void> cancelCatalog() => _cancelReads('catalog-');
  @override
  Future<void> cancelSuggestions() => _cancelReads('suggestions');
  @override
  Future<void> cancelRecommendations() => _cancelReads('recommendations-');

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async {
    _authorize('hongguo');
    return CatalogPage.fromJson(
      await _read('recommendations-$genre', {
        'action': 'recommendations',
        'category': genre,
        'command': more ? 'more' : '',
        'force': force,
      }),
    );
  }

  @override
  Future<Drama?> supplementMetadata(Drama drama) async {
    if (!(drama.source == 'hongguo' && drama.onlineDate.isEmpty ||
        drama.source == 'huangdou' &&
            (drama.heat.isEmpty || drama.vipStatus == null))) {
      return null;
    }
    final result = await _read('metadata', {
      'action': 'metadata',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  Future<Drama> followCheck(Drama drama) async {
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
    final result = await _call({'action': 'rankingBoards'});
    return [
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
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage.fromJson(
    await _call({
      'action': 'rankings',
      'board': board,
      'page': page,
      'force': force,
    }),
  );

  void _authorize(String source, {bool download = false}) {
    if (!SourceSite.isAvailable(source)) {
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
  Future<List<String>> suggestions(String query) async {
    _authorize('hongguo');
    final result = await _read('suggestions', {
      'action': 'suggestions',
      'query': query,
    });
    return (result['items'] as List? ?? []).whereType<String>().toList();
  }

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
  Future<Map<String, dynamic>> cacheInfo({String cacheDirectory = ''}) =>
      _call({'action': 'cacheInfo', 'cacheDirectory': cacheDirectory});

  @override
  Future<Map<String, dynamic>> clearCache({String cacheDirectory = ''}) =>
      _call({'action': 'clearCache', 'cacheDirectory': cacheDirectory});

  @override
  Future<void> moveDownloads(String directory) async {
    _downloadPermission();
    if (access != null && !access!.profile.admin) {
      throw AppFailure('仅管理员可更改下载目录');
    }
    await BackgroundDownloads.ensureStarted();
    await workLease('storage', 'start');
    try {
      await _call({'action': 'moveDownloads', 'directory': directory});
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
  int _playbackSequence = DateTime.now().microsecondsSinceEpoch;

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
          action == 'lan' &&
              {
                'stop',
                'respond',
                'cancel',
                'disconnect',
              }.contains(input['command']);
      final epoch = access?.profileEpoch;
      if (!unrestricted && access?.locked == true) throw AppFailure('请先解锁当前用户');
      if (action == 'rankings') {
        _authorize(RankingBoard.sourceForID(input['board'] as String));
      }
      if (action == 'recommendations' ||
          action == 'cachedRecommendations' ||
          action == 'suggestions' ||
          action == 'danmaku') {
        _authorize('hongguo');
      }
      if ({'catalog', 'cached', 'categories'}.contains(action)) {
        _authorize(input['source'] as String);
      }
      if ({
        'cover',
        'prepareCover',
        'detail',
        'metadata',
        'resolve',
        'preload',
        'enqueueDownloads',
        'localPlayback',
      }.contains(action)) {
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
      // 番茄的内容来自本机引擎（安卓/iOS 是进程内 FFI，桌面端是独立进程）。
      // 用户刚打开应用就点进来时引擎可能还在初始化，先等它一小会儿；
      // 已经就绪或已确定失败时这里立即返回，不会拖慢正常请求。
      if (_targetsFanqie(input)) {
        await FanqieBackend.waitReady(const Duration(seconds: 8));
      }
      final body = jsonEncode(input);
      final response =
          await Isolate.run(
            () => jsonDecode(_nativeRequest(body)) as Map<String, dynamic>,
          ).timeout(
            Duration(
              seconds: action == 'moveDownloads'
                  ? 620
                  : action == 'analyzeCustomSourceSite'
                  ? 100
                  : action == 'danmaku'
                  ? 15
                  : action == 'preload'
                  ? 20
                  : 70,
            ),
          );
      if (response['ok'] != true) {
        var message = response['error'] as String? ?? '读取失败，请重试';
        if (message.contains('番茄内容引擎未就绪')) {
          // 原生核心只知道「连不上引擎」，真正的现场在宿主这边（动态库没进包、
          // 符号对不上、初始化失败、还在起……）。用宿主的原因替换掉那句通用
          // 文案，用户看到的才是能照着做的信息。
          // 带上 action 和 Go 侧原文：同样的「未就绪」可能发生在目录、搜索、
          // 详情或取流，只有原文里的 URL 与 errno 能分清是哪一层挂的。
          final original = message;
          final reason = await FanqieBackend.describeNow();
          message = '番茄内容引擎未就绪（$action）：$reason；调用失败原文：$original';
        }
        throw AppFailure(message, code: response['code'] as String? ?? '');
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
      throw AppFailure('站源响应超时，请重试');
    } catch (_) {
      throw AppFailure('本地核心加载失败，请使用完整安装包重新安装');
    }
  }

  @override
  Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    // 尽早把原生核心的标准错误重定向到日志文件：核心内部 panic 只会对外回
    // 「本地核心处理失败，请重试」，堆栈仅写 stderr，桌面端与 Android 都取不到。
    // 重定向后堆栈落在 <logs>/native_stderr.log。符号不存在时静默跳过。
    final stderrLog = path.join(directory.path, 'logs', 'native_stderr.log');
    installStderrLog(stderrLog);
    DiaryService.nativeStderrLogPath = stderrLog;
    if (!background) {
      DiaryService.nativeLogPath = path.join(directory.path, 'logs', 'app.log');
    }
    final build = await _call({
      'action': 'initialize',
      'directory': directory.path,
    });
    if (build['allSources'] != allSourcesEnabled) {
      throw AppFailure('应用与原生核心的站源版本不一致，请使用完整安装包重新安装');
    }
    if (!background) await BackgroundDownloads.prepare();
    if (!background) {
      // 番茄内置源的内容引擎：与本地核心并行启动，不阻塞界面。
      // 非 Android 平台没有引擎产物，ensureStarted 会直接返回；
      // 站源此时仍会显示，播放时给出「引擎未就绪」的提示。
      unawaited(FanqieBackend.ensureStarted());
    }
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
    bool force = false,
  }) async => CatalogPage.fromJson(
    await _read(query.isEmpty ? 'catalog-$source' : 'catalog-$source-search', {
      'action': 'catalog',
      'source': source,
      'page': page,
      'query': query,
      'category': category,
      'force': force,
    }),
  );
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage.fromJson(
        await _call({
          'action': 'cached',
          'source': source,
          'category': category,
        }),
      );
  @override
  Future<SearchProgress> searchStart(
    List<String> sources,
    String query,
  ) async => SearchProgress.fromJson(
    await _call({
      'action': 'searchStart',
      'sources': sources,
      'query': query,
      'page': 1,
    }),
  );
  @override
  Future<SearchProgress> searchPoll(String id) async => SearchProgress.fromJson(
    await _call({'action': 'searchPoll', 'search': id}),
  );
  @override
  Future<void> searchCancel(String id) async {
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
  Future<DramaDetail> detail(Drama drama) async => DramaDetail.fromJson(
    await _call({'action': 'detail', 'drama': drama.toJson()}),
  );
  @override
  Future<List<DramaSeason>> seasons(Drama drama) async {
    final json = await _call({'action': 'seasons', 'drama': drama.toJson()});
    return [
      for (final row in json['items'] as List? ?? const [])
        DramaSeason.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int route = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'adBlock': adBlock,
      'route': route,
      'sequence': ++_playbackSequence,
    }),
  );
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      PlaybackPlan.fromJson(
        await _call({
          'action': 'fallback',
          'session': current.session,
          'sequence': ++_playbackSequence,
        }),
      );
  @override
  Future<PlaybackPlan> selectRoute(PlaybackPlan current, int route) async =>
      PlaybackPlan.fromJson(
        await _call({
          'action': 'selectRoute',
          'session': current.session,
          'route': route,
          'sequence': ++_playbackSequence,
        }),
      );
  @override
  Future<void> cancelPlayback() async {
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
    return _downloadCache.$2
        .where(
          (job) =>
              SourceSite.isAvailable(job.drama.source) &&
              (access == null || access!.allowsSource(job.drama.source)),
        )
        .toList();
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
    int route = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'adBlock': adBlock,
      'route': route,
      'force': true,
      'sequence': ++_playbackSequence,
    }),
  );

  @override
  Future<void> release(String session) async {
    if (session.isEmpty) {
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

  @override
  Future<Map<String, dynamic>> audiobookHongguoCatalog(
    String category,
    int page,
  ) => _call({
    'action': 'audiobookHongguoCatalog',
    'category': category,
    'page': page,
  });

  @override
  Future<Map<String, dynamic>> audiobookHongguoSearch(
    String category,
    String query,
    int page,
  ) => _call({
    'action': 'audiobookHongguoSearch',
    'category': category,
    'query': query,
    'page': page,
  });

  @override
  Future<Map<String, dynamic>> audiobookHongguoChapters(String bookId) =>
      _call({'action': 'audiobookHongguoChapters', 'query': bookId});

  @override
  Future<Map<String, dynamic>> audiobookHongguoMedia(
    String bookId,
    String chapterId,
  ) => _call({
    'action': 'audiobookHongguoMedia',
    'query': bookId,
    'category': chapterId,
  });

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

  // ---- 自定义源管理 ----
  //
  // 说明：这里刻意不调用 _adminPermission()。自定义源与源显示开关属于
  // 「谁用谁配」的本机偏好，普通用户也应该能自己加源、改源、删源；
  // 只有下载目录、系统代理这类会影响整机/其它用户的设置才限制管理员。

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
}
