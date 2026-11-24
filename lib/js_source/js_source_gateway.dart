import 'dart:async';

import '../core_bridge.dart';
import '../danmaku_models.dart';
import '../models.dart';
import '../ranking_models.dart';
import 'catpaw_js_runtime.dart';
import 'js_source_diagnostics.dart';
import 'js_source_models.dart';
import 'js_source_service.dart';

/// JS 沙箱与 App 之间的唯一桥。
///
/// 职责：
/// 1. 把 `JsSourceService` 里已导入的脚本挂成 `SourceSite`（`js:` 前缀），
///    让源菜单、搜索、追剧、历史都把它们当普通站源；
/// 2. 把站源的目录 / 详情 / 播放 / 弹幕请求翻译成 CatPawOpen 协议调用，
///    再把脚本返回的 `vod` 映射回本项目的 `Drama` / `Episode` / `PlaybackPlan`。
///
/// 内核（Go）完全不参与：沙箱在 Dart 侧跑 JS，取到的直链直接交给播放器，
/// 所以新增一个脚本源不需要重编内核。
class JsSourceGateway {
  JsSourceGateway._();
  static final instance = JsSourceGateway._();

  final CatPawRuntimePool _pool = CatPawRuntimePool();
  JsSourceService? _service;
  bool _attached = false;

  /// 最近一次 [resolve] 的上下文。播放页切线路时只会拿到 PlaybackPlan，
  /// 没有 Drama / Episode，靠这份缓存重建第 N 集在新线路上的编号。
  ({Drama drama, Episode episode})? _lastResolve;

  /// 按指定线路重新解析当前集（供播放页切线路用）。
  Future<PlaybackPlan> resolveRoute(int routeIndex) async {
    final last = _lastResolve;
    if (last == null) {
      throw AppFailure('线路信息已失效，请重新打开剧集', code: 'NO_ROUTE');
    }
    return resolve(last.drama, last.episode, routeIndex: routeIndex);
  }

  JsSourceService get service => _service ??= JsSourceService();

  /// 启动时调用一次：装载脚本、挂站源、预热官方源的游客会话。
  Future<void> attach(JsSourceService service) async {
    _service = service;
    await service.initialize();
    refreshSources();
    _attached = true;
  }

  bool get attached => _attached;

  /// 把已安装脚本同步进 `SourceSite`。导入 / 删除 / 启用变化后都要跑一遍。
  void refreshSources() {
    final source = _service;
    if (source == null) return;
    SourceSite.installJs([
      for (final meta in source.sources)
        SourceSite(
          meta.sourceId,
          meta.name,
          meta.description,
          available: true,
          pagedSearch: meta.features.contains('search'),
          searchSuggestions: meta.features.contains('suggestions'),
          recommends: meta.features.contains('recommendations'),
          danmaku: meta.features.contains('danmaku'),
          vipPrompt: false,
          category: '',
        ),
    ]);
  }

  /// 请求是不是该由沙箱接管。
  bool handles(String source) {
    if (!isJsSourceId(source)) return false;
    final script = _service?.scriptOf(jsSourceScriptId(source));
    return script != null && script.isNotEmpty;
  }

  JsSourceMeta? metaOf(String source) =>
      _service?.sourceById(jsSourceScriptId(source));

  String? _scriptOf(String source) =>
      _service?.scriptOf(jsSourceScriptId(source));

  Future<CatPawJsRuntime> _runtime(String source, String scope) async {
    final script = _scriptOf(source);
    if (script == null) {
      throw AppFailure('这个 JS 源还没有导入，请到 我的 › JS 沙箱 添加', code: 'js_missing');
    }
    try {
      return await _pool.get(jsSourceScriptId(source), script, scope: scope);
    } catch (error) {
      if (error is CatPawSourceFailure) {
        throw AppFailure(error.message, code: error.code);
      }
      throw AppFailure('JS 源加载失败：$error', code: 'js_load');
    }
  }

  /// 统一把运行时异常翻成界面能显示的 [AppFailure]，同时保留错误码。
  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on AppFailure {
      rethrow;
    } on CatPawSourceFailure catch (error) {
      throw AppFailure(_friendly(error.code, error.message), code: error.code);
    } on TimeoutException {
      throw AppFailure('JS 源响应超时，请稍后重试', code: 'TIMEOUT');
    } catch (error) {
      final detail = JsSourceDiagnostics.analyzeError(error);
      throw AppFailure(
        _friendly(detail.code, 'JS 源执行失败：${detail.message}'),
        code: detail.code,
      );
    }
  }

  /// 缺签名参数的提示要说清楚去哪补，否则用户只看到脚本抛的原文。
  String _friendly(String code, String fallback) {
    if (code == 'SOURCE_CONFIGURATION_MISSING') {
      return '这个脚本需要签名参数：内置官方源已随安装包配置好；自定义脚本请在 我的 › JS 沙箱 › 签名参数里填密钥后重试';
    }
    if (code == 'DRM_PROTECTED') {
      return '这一集的片源是 DRM 加密的，没有播放器密钥解不出来，本源只能浏览；官方源需内置签名参数才能播放';
    }
    return fallback;
  }

  void cancel(String source, String scope) {
    if (!isJsSourceId(source)) return;
    _pool.cancelPending(sourceId: jsSourceScriptId(source), scope: scope);
  }

  void cancelAll() => _pool.cancelPending();

  // ---------------------------------------------------------------- 目录

  Future<List<CatalogCategory>> categories(String source) => _guard(() async {
    final runtime = await _runtime(source, 'catalog');
    final home = await runtime.home(filter: _isHongguo(source));
    final rows = <CatalogCategory>[];
    final seen = <String>{};
    for (final item in home.classes) {
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
      final runtime = await _runtime(source, 'search');
      final result = await runtime.search(query.trim(), page: page);
      return CatalogPage(
        [for (final vod in result.list) _dramaFromVod(source, vod, category)],
        page: result.page,
        hasMore: result.hasMore,
      );
    }
    final runtime = await _runtime(source, 'catalog');
    final result = await runtime.category(
      category,
      page,
      extend: _isHongguo(source) && page == 1
          ? const {'initialBatch': 12}
          : null,
    );
    return CatalogPage(
      [for (final vod in result.list) _dramaFromVod(source, vod, category)],
      page: page,
      hasMore: result.hasMore,
    );
  });

  Future<CatalogPage> recommendations(String source, String genre, int page) =>
      _guard(() async {
        final runtime = await _runtime(source, 'catalog');
        final result = await runtime.discoveryPage(
          'recommendations',
          genre,
          page,
        );
        return CatalogPage(
          [for (final vod in result.list) _dramaFromVod(source, vod, genre)],
          page: result.page,
          hasMore: result.hasMore,
        );
      });

  Future<List<String>> suggestions(String source, String query) =>
      _guard(() async {
        final runtime = await _runtime(source, 'suggestions');
        return runtime.suggestions(query);
      });

  Future<List<RankingBoard>> rankingBoards(String source) => _guard(() async {
    final runtime = await _runtime(source, 'catalog');
    final rows = await runtime.rankingBoards();
    return [
      for (final row in rows)
        if ((row['id']?.toString() ?? '').isNotEmpty)
          RankingBoard(
            id: '$source:${row['id']}',
            source: source,
            name: row['name']?.toString() ?? '榜单',
            description: row['description']?.toString() ?? '',
          ),
    ];
  });

  Future<RankingPage> rankings(String source, RankingBoard board, int page) =>
      _guard(() async {
        final runtime = await _runtime(source, 'catalog');
        final key = board.id.startsWith('$source:')
            ? board.id.substring(source.length + 1)
            : board.id;
        final result = await runtime.discoveryPage('rankings', key, page);
        return RankingPage(
          items: [
            for (final vod in result.list)
              RankingItem(
                intValue(vod['vod_rank']) > 0 ? intValue(vod['vod_rank']) : 0,
                _dramaFromVod(source, vod, ''),
                metric: vod['vod_metric']?.toString() ?? '',
              ),
          ],
          page: result.page,
          hasMore: result.hasMore,
          updatedText: result.updatedText,
        );
      });

  // ---------------------------------------------------------------- 详情

  Future<DramaDetail> detail(Drama drama) => _guard(() async {
    final source = drama.source;
    final sourceId = _cleanSourceId(drama);
    if (sourceId.isEmpty) {
      throw AppFailure('这部剧缺少源内编号，无法打开详情', code: 'js_bad_id');
    }
    final runtime = await _runtime(source, 'detail');
    final result = await runtime.detail(sourceId);
    final vod = result.vod;

    final routes = _routesOf(vod);
    if (routes.isEmpty) {
      throw AppFailure('这个 JS 源没有返回可播放的分集', code: 'MISSING_EPISODE');
    }
    final chapters = routes.first.chapters;

    var rich = drama;
    final title = vod['vod_name']?.toString().trim() ?? '';
    final cover = normalizeCover(vod['vod_pic']?.toString() ?? '');
    final description = vod['vod_content']?.toString().trim() ?? '';
    final tags = _tagsOf(vod);
    rich = Drama(
      id: drama.id,
      source: source,
      sourceId: sourceId,
      title: title.isEmpty ? drama.title : title,
      description: description.isEmpty ? drama.description : description,
      cover: cover.isEmpty ? drama.cover : cover,
      episodes: chapters.length,
      category: categoryNameOf(
        vod['vod_category']?.toString() ?? drama.category,
      ),
      vip: false,
      heat: drama.heat,
      views: drama.views,
      onlineDate: drama.onlineDate,
      score: drama.score,
      tags: tags.isEmpty ? drama.tags : tags,
      releaseStatus: drama.releaseStatus,
      badge: drama.badge,
      peers: drama.peers,
    );

    // 详情页只展示第一条线路的分集，不把其他线路合并进来：选集保持简洁，
    // 标题不带「线路名 · 集名」前缀，详情页因此不出现线路切换条。
    // 线路总数通过 routeCount 带给播放页；播放页切线路时按 routeIndex
    // 重新解析详情，取对应线路的同一集。
    final episodes = <Episode>[];
    final primary = routes.first;
    for (var i = 0; i < primary.chapters.length; i++) {
      episodes.add(
        Episode({
          ...primary.chapters[i],
          'routeName': primary.name,
          'routeIndex': 0,
          'routeCount': routes.length,
        }, episodes.length + 1),
      );
    }

    return DramaDetail(rich, episodes);
  });

  // ---------------------------------------------------------------- 播放

  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int routeIndex = -1,
  }) => _guard(() async {
    final source = drama.source;
    final sourceId = _cleanSourceId(drama);
    // 记住这次解析的上下文，播放页切线路时（只有 plan 没有 drama）要用它重建。
    _lastResolve = (drama: drama, episode: episode);
    final runtime = await _runtime(source, 'playback');
    final flags = <Map<String, dynamic>>[
      {'quality': quality, 'seriesId': sourceId},
    ];

    // 线路名来自详情页写入的 routeName；没有时退回 'flag'（脚本可忽略）。
    var routeName = (episode.raw['routeName']?.toString() ?? '').trim();
    var target = (episode.raw['raw'] ?? episode.raw['id'] ?? episode.id)
        .toString()
        .trim();

    // 切换到别的线路：重新拉详情，按线路序号取该线路第 N 集的分集编号。
    if (routeIndex >= 0) {
      final fresh = await runtime.detail(sourceId);
      final routes = _routesOf(fresh.vod);
      if (routeIndex < routes.length) {
        final route = routes[routeIndex];
        final position = episode.number - 1;
        routeName = route.name;
        if (position >= 0 && position < route.chapters.length) {
          target = (route.chapters[position]['raw'] ?? '').toString();
        }
      }
    }
    final flag = routeName.isEmpty ? 'flag' : routeName;

    if (target.isEmpty) target = '${episode.number}';
    if (!target.startsWith('http://') &&
        !target.startsWith('https://') &&
        !target.contains('/') &&
        !target.contains('_') &&
        sourceId.isNotEmpty) {
      target = '${sourceId}_$target';
    }

    var play = await runtime.play(flag, target, flags: flags);
    if (play.url.isEmpty && sourceId.isNotEmpty) {
      final fallbackTarget = '${sourceId}_${episode.number}';
      if (fallbackTarget != target) {
        play = await runtime.play(flag, fallbackTarget, flags: flags);
      }
    }
    if (play.url.isEmpty) {
      // 分集地址可能是上一轮详情里拿到的旧编号：重新拉一次详情再试。
      final refreshed = await runtime.detail(sourceId);
      final chapters = _chaptersOf(
        refreshed.vod['vod_play_url']?.toString() ?? '',
      );
      if (episode.number > 0 && episode.number <= chapters.length) {
        final retry = (chapters[episode.number - 1]['raw'] ?? '').toString();
        if (retry.isNotEmpty && retry != target) {
          play = await runtime.play('flag', retry, flags: flags);
        }
      }
    }
    if (play.url.isEmpty) {
      throw AppFailure(
        CatPawSourceFailure.playback(play.errorCode).message,
        code: play.errorCode.isEmpty ? 'NO_STREAM' : play.errorCode,
      );
    }

    final stream = play.url;
    final detected = RegExp(
      r'/(2160|1080|720|480|360)p[./]',
    ).firstMatch(stream);
    final effective = play.quality > 0
        ? play.quality
        : int.tryParse(detected?.group(1) ?? '') ?? 0;
    final qualities = play.qualities.isNotEmpty
        ? play.qualities
        : [if (effective > 0) effective];

    return PlaybackPlan(
      url: stream,
      directUrl: stream,
      headers: play.header,
      decryptionKey: play.decryptionKey,
      quality: effective,
      qualities: qualities,
      // session 只用来标记「这条流归沙箱管」，release / 弹幕按它路由。
      session: 'js:${jsSourceScriptId(source)}',
      danmakuId: play.danmakuId,
      // 多线路：让播放页显示「线路 N/M」并允许切换。
      routeIndex: routeIndex >= 0
          ? routeIndex
          : intValue(episode.raw['routeIndex']),
      routeCount: intValue(episode.raw['routeCount']) > 0
          ? intValue(episode.raw['routeCount'])
          : 1,
    );
  });

  // ---------------------------------------------------------------- 弹幕

  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) => _guard(() async {
    final source = plan.session;
    final runtime = await _runtime(source, 'danmaku');
    final raw = await runtime.danmaku(plan.danmakuId, startMs, durationMs);
    final next = startMs + durationMs;
    final items = <DanmakuItem>[];
    final seen = <String>{};
    for (final row in (raw['list'] as List? ?? const []).take(90)) {
      if (row is! Map) continue;
      final id = row['id']?.toString() ?? '';
      final text = row['text']?.toString().trim() ?? '';
      final seconds = intValue(row['createTime']);
      if (id.isEmpty || text.isEmpty || seconds <= 0 || !seen.add(id)) continue;
      final timeMs = seconds * 1000;
      if (timeMs < startMs || timeMs >= next) continue;
      items.add(DanmakuItem(id: id, text: text, timeMs: timeMs));
    }
    items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return DanmakuPage(
      episodeId: plan.danmakuId,
      startMs: startMs,
      nextMs: next,
      items: items,
    );
  });

  /// 沙箱的播放会话没有内核侧资源，释放是空操作。
  bool ownsSession(String session) => session.startsWith('js:');

  /// 系列多季：脚本源用 `seriesSeasons` 暴露同一系列的不同季。
  ///
  /// 脚本返回的每一行都是完整的 vod（`vod_id` / `vod_name` / `vod_pic` /
  /// `vod_episodes` / `season`），这里映射成 `DramaSeason`，界面上才能
  /// 出现「第 N 季」切换。没有该能力的源（未实现 `seriesSeasons`）会抛错，
  /// 由调用方当成「没有多季」处理。
  Future<List<DramaSeason>> seasons(Drama drama) => _guard(() async {
    final source = drama.source;
    final sourceId = _cleanSourceId(drama);
    if (sourceId.isEmpty) return const <DramaSeason>[];
    final runtime = await _runtime(source, 'seasons');
    final rows = await runtime.seriesSeasons(sourceId);
    final seasons = <int, DramaSeason>{};
    for (final vod in rows) {
      final id = (vod['vod_id']?.toString() ?? '').trim();
      final title = (vod['vod_name']?.toString() ?? '').trim();
      if (id.isEmpty || title.isEmpty) continue;
      final number = intValue(vod['season']);
      if (number <= 0) continue;
      final cover = normalizeCover(vod['vod_pic']?.toString() ?? '');
      seasons[number] = DramaSeason(
        number: number,
        drama: Drama(
          id: '$source:$id',
          source: source,
          sourceId: id,
          title: title,
          description: (vod['vod_content']?.toString() ?? '').trim(),
          cover: cover,
          episodes: intValue(vod['vod_episodes']),
          category: categoryNameOf(
            (vod['vod_category']?.toString() ?? '').trim().isEmpty
                ? drama.category
                : vod['vod_category'].toString(),
          ),
          vip: false,
          releaseStatus: vod['vod_release_status']?.toString() ?? '',
        ),
      );
    }
    final sorted = seasons.values.toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    return sorted;
  });

  void dispose() {
    _pool.disposeAll();
  }

  // ---------------------------------------------------------------- 映射

  bool _isHongguo(String source) => jsSourceScriptId(source) == 'hongguo';

  String _cleanSourceId(Drama drama) {
    var id = drama.sourceId.trim();
    if (id.isEmpty) id = drama.id;
    if (id.startsWith('${drama.source}:')) {
      id = id.substring(drama.source.length + 1);
    }
    return id.trim();
  }

  Drama _dramaFromVod(
    String source,
    Map<String, dynamic> vod,
    String fallbackCategory,
  ) {
    final rawId = (vod['vod_id']?.toString() ?? '').trim();
    final id = rawId.isEmpty
        ? '${DateTime.now().microsecondsSinceEpoch}'
        : rawId;
    final remarks = vod['vod_remarks']?.toString() ?? '';
    final episodeMatch = RegExp(r'(\d+)').firstMatch(remarks);
    final title = (vod['vod_name']?.toString() ?? '').trim();
    final tags = _tagsOf(vod);
    return Drama(
      id: '$source:$id',
      source: source,
      sourceId: id,
      title: title.isEmpty ? '短剧' : title,
      description: (vod['vod_content']?.toString() ?? '').trim(),
      cover: normalizeCover(vod['vod_pic']?.toString() ?? ''),
      episodes: intValue(vod['vod_episodes']) > 0
          ? intValue(vod['vod_episodes'])
          : int.tryParse(episodeMatch?.group(1) ?? '') ?? 0,
      category: _categoryOf(vod, fallbackCategory, tags),
      vip: vod['vip'] == true,
      heat: vod['vod_heat']?.toString() ?? '',
      views: vod['vod_views']?.toString() ?? '',
      score: vod['vod_score']?.toString() ?? '',
      tags: tags,
      releaseStatus: vod['vod_release_status']?.toString() ?? '',
    );
  }

  /// 分类：优先脚本给的 `vod_category`；为空时退回当前 tab 的分类名；
  /// 都为空则用第一个题材标签（对齐 guoapp 站源 dramaFromRow 的做法），
  /// 避免「推荐」「全部」里所有剧都落到「短剧 / 未分类」。
  String _categoryOf(
    Map<String, dynamic> vod,
    String fallbackCategory,
    List<String> tags,
  ) {
    final raw = (vod['vod_category']?.toString() ?? '').trim();
    if (raw.isNotEmpty) return categoryNameOf(raw);
    final fallback = fallbackCategory.trim();
    if (fallback.isNotEmpty) return categoryNameOf(fallback);
    if (tags.isNotEmpty) return categoryNameOf(tags.first);
    return categoryNameOf('');
  }

  List<String> _tagsOf(Map<String, dynamic> vod) {
    final raw = vod['vod_tag'] ?? vod['tags'];
    final rows = <String>[];
    if (raw is String) {
      rows.addAll(raw.split(',').map((item) => item.trim()));
    } else if (raw is List) {
      rows.addAll(raw.map((item) => item.toString().trim()));
    }
    const junk = {'vip', '付费', '付费短剧', 'vip专享', '预告'};
    return [
      for (final tag in rows)
        if (tag.isNotEmpty && !junk.contains(tag.toLowerCase())) tag,
    ].take(12).toList();
  }

  /// `vod_play_url` 是 CatVod 的老格式：多线路用 `$$$` 分隔，集用 `#`，
  /// 每集 `标题$播放编号`。`vod_play_from` 用 `$$$` 给出对应的线路名。
  ///
  /// 返回全部线路（顺序与 `vod_play_from` 一致），供详情页做线路切换。
  List<JsRoute> _routesOf(Map<String, dynamic> vod) {
    final raw = vod['vod_play_url']?.toString().trim() ?? '';
    if (raw.isEmpty) return const [];
    final names = (vod['vod_play_from']?.toString() ?? '')
        .split(r'$$$')
        .map((item) => item.trim())
        .toList();
    final lines = raw.split(r'$$$');
    final routes = <JsRoute>[];
    for (var i = 0; i < lines.length; i++) {
      final chapters = _chaptersOfLine(lines[i]);
      if (chapters.isEmpty) continue;
      final name = i < names.length && names[i].isNotEmpty
          ? names[i]
          : '线路 ${routes.length + 1}';
      routes.add(JsRoute(name: name, chapters: chapters));
    }
    return routes;
  }

  /// 只取第一条线路的分集（`vod_play_url` 没有 `$$$` 时的常规情况）。
  List<Map<String, dynamic>> _chaptersOf(String playUrl) {
    final routes = _chaptersOfLine(playUrl);
    return routes;
  }

  List<Map<String, dynamic>> _chaptersOfLine(String line) {
    final value = line.trim();
    if (value.isEmpty) return const [];
    final chapters = <Map<String, dynamic>>[];
    var index = 1;
    for (final item in value.split('#')) {
      final trimmed = item.trim();
      if (trimmed.isEmpty) continue;
      var title = '第 $index 集';
      var playId = trimmed;
      if (trimmed.contains(r'$')) {
        final parts = trimmed.split(r'$');
        if (parts.first.trim().isNotEmpty) title = parts.first.trim();
        playId = parts.sublist(1).join(r'$').trim();
      }
      chapters.add({
        'id': playId.isEmpty ? '$index' : playId,
        'title': title,
        'currentEpisode': index,
        'raw': playId.isEmpty ? '$index' : playId,
        'vip': false,
      });
      index++;
    }
    return chapters;
  }
}

/// 脚本源的一条播放线路：名称 + 该线路的分集。
class JsRoute {
  const JsRoute({required this.name, required this.chapters});
  final String name;
  final List<Map<String, dynamic>> chapters;
}

/// 封面地址归一：脚本偶尔给 `//host/x.jpg` 或空值。
String normalizeCover(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';
  if (value.startsWith('//')) return 'https:$value';
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    return '';
  }
  return value;
}

/// 分类名归一，与 `SourceCatalog.categoryName` 同一套口径，避免
/// 「AI短剧」和「AI 短剧」在界面上分成两个 tab。
///
/// 脚本源会给出三种「技术性」分类值，必须在这里翻成人话，否则界面上
/// 会直接显示 `app:discover:playlet`、`find_drama` 这类内部标识，或者
/// 因为认不出来被归到「未分类」：
/// 1. `app:discover:<genre>`：官方发现页的分类（推荐 tab 用的就是它）；
/// 2. `app:*` / `hongguo-app:*`：官方接口里的榜单、剧场等标识；
/// 3. `find_drama`：`SourceCatalog.recommendGenre`，推荐流的默认题材。
String categoryNameOf(String raw) {
  final value = raw.trim();
  if (value.startsWith('app:discover:')) {
    return switch (value.split(':').last) {
      'playlet' => '真人剧',
      'motion_comic' => '漫剧',
      'ai_playlet' => 'AI 剧',
      _ => '短剧',
    };
  }
  if (value.startsWith('app:') || value.startsWith('hongguo-app:')) {
    return '短剧';
  }
  if (value == 'find_drama') return '短剧';
  final compact = value.replaceAll(RegExp(r'\s+'), '');
  return switch (compact) {
    'AI成人短剧' || 'AI短剧' => 'AI 短剧',
    'AI成人漫剧' || 'AI漫剧' => 'AI 漫剧',
    'AI换脸' => 'AI 换脸',
    'AI魔改' => 'AI 魔改',
    'AI剧' => 'AI 剧',
    'real-drama' || 'real_series' => '真人剧',
    'comic-drama' || 'comic_series' || 'comic' => '漫剧',
    'ai-drama' || 'ai_series' => 'AI 剧',
    '' => '未分类',
    _ => value,
  };
}

/// 供 `core_bridge` 判断某条播放会话是不是沙箱的。
bool isJsPlaybackSession(String session) => session.startsWith('js:');

/// 「全部源」聚合搜索里，脚本源的那一半。
///
/// 内核的搜索会话只认它自己注册过的站源，`js:` 前缀进不去，因此脚本源在
/// 本地并发搜，结果按站源并进内核快照：进度（pending / done / total）、
/// 失败原因都跟着一起并，界面的进度条才不会停在 99%。
class JsSearchMerge {
  JsSearchMerge({required this.query, required this.sources});

  final String query;
  final List<String> sources;
  final List<Drama> _items = [];
  final List<String> _done = [];
  final Map<String, String> _failures = {};
  final Map<String, bool> _running = {};

  /// 这次搜索是否只有脚本源（没有任何内核源）。
  bool onlyJs = false;

  bool get finished => _running.isEmpty;

  void run(JsSourceGateway gateway, String query) {
    for (final source in sources) {
      _running[source] = true;
      gateway
          .catalog(source, '', 1, query: query)
          .then((page) => _items.addAll(page.items))
          .catchError((Object error) {
            _failures[source] = error is AppFailure ? error.message : '$error';
          })
          .whenComplete(() {
            _running.remove(source);
            _done.add(source);
          });
    }
  }

  SearchProgress snapshot(String id) => SearchProgress(
    id: id,
    query: query,
    items: List.unmodifiable(_items),
    sources: List.unmodifiable(_done),
    pending: List.unmodifiable(_running.keys),
    failures: Map.unmodifiable(_failures),
    total: sources.length,
    done: sources.length - _running.length,
    finished: finished,
  );

  SearchProgress merge(SearchProgress base) {
    final seen = {for (final drama in base.items) drama.id};
    return SearchProgress(
      id: base.id,
      query: base.query,
      items: [
        ...base.items,
        for (final drama in _items)
          if (seen.add(drama.id)) drama,
      ],
      sources: [...base.sources, for (final source in _done) source],
      pending: [...base.pending, ..._running.keys],
      failures: {...base.failures, ..._failures},
      warning: base.warning,
      total: base.total + sources.length,
      done: base.done + sources.length - _running.length,
      finished: base.finished && finished,
    );
  }
}
