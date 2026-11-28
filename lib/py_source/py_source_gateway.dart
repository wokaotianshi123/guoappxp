import 'dart:async';

import '../core_bridge.dart';
import '../danmaku_models.dart';
import '../models.dart';
import '../ranking_models.dart';
import 'py_bridge.dart';
import 'py_contract.dart';
import 'py_source_models.dart';
import 'py_source_service.dart';

/// py 沙箱与 App 之间的桥。
///
/// 与 `JsSourceGateway` 同构：把已导入的 `.py` 挂成 `SourceSite`（`py:` 前缀），
/// 目录 / 详情 / 播放请求翻译成 TVBox py 蜘蛛动作再映射回本项目的模型。
/// Python 不在 Dart 侧跑，全部经 [PyBridge] 交给平台后端。
class PySourceGateway {
  PySourceGateway._();
  static final instance = PySourceGateway._();

  PySourceService? _service;
  bool _attached = false;
  ({Drama drama, Episode episode})? _lastResolve;

  PySourceService get service => _service ??= PySourceService();

  Future<void> attach(PySourceService value) async {
    _service = value;
    await value.initialize();
    refreshSources();
    _attached = true;
  }

  bool get attached => _attached;

  void refreshSources() {
    final source = _service;
    if (source == null) return;
    SourceSite.installPy([
      for (final meta in source.sources)
        SourceSite(
          meta.sourceId,
          meta.name,
          meta.description,
          available: true,
          pagedSearch: true,
          searchSuggestions: false,
          recommends: false,
          danmaku: false,
          vipPrompt: false,
          category: '',
        ),
    ]);
  }

  bool handles(String source) {
    if (!isPySourceId(source)) return false;
    final script = _service?.scriptOf(pySourceScriptId(source));
    return script != null && script.isNotEmpty;
  }

  PySourceMeta? metaOf(String source) =>
      _service?.sourceById(pySourceScriptId(source));

  String _path(String source) {
    final id = pySourceScriptId(source);
    final path = _service?.pathOf(id) ?? '';
    if (path.isEmpty) {
      throw AppFailure('这个 py 源还没有导入，请到 我的 › PY 沙箱 添加', code: 'py_missing');
    }
    return path;
  }

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw AppFailure('py 源响应超时，请稍后重试', code: 'TIMEOUT');
    } catch (error) {
      throw AppFailure('py 源执行失败：$error', code: 'py_exec');
    }
  }

  Future<List<CatalogCategory>> categories(String source) => _guard(() async {
    final home = await PyBridge.call(_path(source), {'action': 'categories'});
    final rows = <CatalogCategory>[];
    final seen = <String>{};
    for (final item in home['class'] as List? ?? const []) {
      if (item is! Map) continue;
      final id = item['type_id']?.toString().trim() ?? '';
      final name = item['type_name']?.toString().trim() ?? '';
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
      rows.add(CatalogCategory(id, name));
    }
    return rows;
  });

  Future<CatalogPage> catalog(
    String source,
    String category,
    int page, {
    String query = '',
    bool force = false,
  }) => _guard(() async {
    if (query.trim().isNotEmpty) {
      final result = await PyBridge.call(_path(source), {
        'action': 'search',
        'query': query.trim(),
        'page': page,
      });
      return PyContract.pageFromResult(source, result, category, page: page);
    }
    final result = await PyBridge.call(_path(source), {
      'action': 'catalog',
      'category': category,
      'page': page,
    });
    return PyContract.pageFromResult(source, result, category, page: page);
  });

  Future<CatalogPage> recommendations(String source, String genre, int page) =>
      _guard(() async => CatalogPage(const []));

  Future<List<String>> suggestions(String source, String query) =>
      _guard(() async => const <String>[]);

  Future<List<RankingBoard>> rankingBoards(String source) =>
      _guard(() async => const <RankingBoard>[]);

  Future<RankingPage> rankings(String source, RankingBoard board, int page) =>
      _guard(() async => RankingPage(items: const [], page: page, hasMore: false));

  Future<DramaDetail> detail(Drama drama) => _guard(() async {
    final source = drama.source;
    final sourceId = drama.sourceId.isNotEmpty ? drama.sourceId : drama.id;
    if (sourceId.isEmpty) {
      throw AppFailure('这部剧缺少源内编号，无法打开详情', code: 'py_bad_id');
    }
    final result = await PyBridge.call(_path(source), {
      'action': 'detail',
      'vodId': sourceId,
    });
    return PyContract.detailFromResult(drama, result);
  });

  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int routeIndex = -1,
  }) => _guard(() async {
    final source = drama.source;
    _lastResolve = (drama: drama, episode: episode);
    var routeName = (episode.raw['routeName']?.toString() ?? '').trim();
    var target = (episode.raw['id'] ?? episode.id).toString().trim();
    if (routeIndex >= 0) {
      final fresh = await detail(drama);
      final routes = <({String name, List<Map<String, dynamic>> chapters})>[];
      // 详情已按第一条线路展开；切换线路时用原始 vod 重新解析。
      final raw = await PyBridge.call(_path(source), {
        'action': 'detail',
        'vodId': drama.sourceId.isNotEmpty ? drama.sourceId : drama.id,
      });
      final rows = raw['list'] as List? ?? const [];
      if (rows.isNotEmpty && rows.first is Map) {
        final vod = Map<String, dynamic>.from(rows.first as Map);
        final parsed = PyContract.parseRoutes(
          vod['vod_play_from']?.toString() ?? '',
          vod['vod_play_url']?.toString() ?? '',
        );
        routes.addAll(parsed);
        if (fresh.episodes.isEmpty) {
          throw AppFailure('这个 py 源没有返回可播放的分集', code: 'MISSING_EPISODE');
        }
      }
      if (routeIndex < routes.length) {
        final route = routes[routeIndex];
        final position = episode.number - 1;
        routeName = route.name;
        if (position >= 0 && position < route.chapters.length) {
          target = (route.chapters[position]['id'] ?? '').toString();
        }
      }
    }
    if (target.isEmpty) target = '${episode.number}';
    final result = await PyBridge.call(_path(source), {
      'action': 'resolve',
      'flag': routeName.isEmpty ? 'flag' : routeName,
      'playId': target,
    });
    final plan = PyContract.planFromResult(result);
    if (plan.url.isEmpty) {
      throw AppFailure('这个 py 源没有返回播放地址', code: 'NO_STREAM');
    }
    return PlaybackPlan(
      url: plan.url,
      directUrl: plan.url,
      headers: plan.headers,
      quality: quality,
      session: 'py:${pySourceScriptId(source)}',
      routeIndex: routeIndex >= 0 ? routeIndex : intValue(episode.raw['routeIndex']),
      routeCount: intValue(episode.raw['routeCount']) > 0
          ? intValue(episode.raw['routeCount'])
          : 1,
    );
  });

  Future<PlaybackPlan> resolveRoute(int routeIndex) async {
    final last = _lastResolve;
    if (last == null) {
      throw AppFailure('线路信息已失效，请重新打开剧集', code: 'NO_ROUTE');
    }
    return resolve(last.drama, last.episode, routeIndex: routeIndex);
  }

  Future<List<DramaSeason>> seasons(Drama drama) =>
      _guard(() async => const <DramaSeason>[]);

  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) => _guard(() async => DanmakuPage(
    episodeId: plan.danmakuId,
    startMs: startMs,
    nextMs: startMs + durationMs,
    items: const [],
  ));


  bool ownsSession(String session) => session.startsWith('py:');

  void cancel(String source, String scope) {}
  void cancelAll() {}
  void cancelPlayback() {}
}
