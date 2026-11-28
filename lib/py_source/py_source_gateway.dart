import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core_bridge.dart';
import '../danmaku_models.dart';
import '../js_source/js_source_gateway.dart' show normalizeCover, categoryNameOf;
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

  /// 脚本是否实现了弹幕能力。
  ///
  /// 判定口径必须宽松：脚本自己实现 `danmaku` / `danmakuContent` 算支持；
  /// 红果系这类在 `playerContent` 里返回 `danmaku` 地址的也算支持——它们的
  /// 弹幕字段要等播放时才有，`ping` 根本看不出来。所以这里一律按支持注册，
  /// 真正没有弹幕时播放页显示「这段暂无弹幕」，而不是把入口整个藏掉。
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
          // 必须放行：`SourceSite.danmaku` 是播放页弹幕按钮的总开关，
          // 置 false 会让控制器直接判「本集暂不支持弹幕」。
          danmaku: true,
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

  /// 脚本是否具备弹幕能力。只探一次并缓存，避免每次播放都多打 RPC。
  ///
  /// 注意：这里返回 true 只表示「值得去要一次弹幕」，不代表一定有内容。
  /// 红果系在 `playerContent` 里才给出弹幕地址，`ping` 看不到，所以探测
  /// 失败或没有显式方法时也按「支持」处理——否则会白白丢掉弹幕。
  final Map<String, bool> _danmakuSupport = {};

  Future<bool> _supportsDanmaku(String path) async {
    final cached = _danmakuSupport[path];
    if (cached != null) return cached;
    try {
      final reply = await PyBridge.call(path, {'action': 'ping'});
      final methods = {
        ...(reply['methods'] as List? ?? const []).map((v) => v.toString()),
        ...(reply['optional'] as List? ?? const []).map((v) => v.toString()),
      };
      final explicit =
          methods.contains('danmaku') || methods.contains('danmakuContent');
      // 有显式方法当然支持；没有也放行，交给播放时的 danmaku 字段决定。
      return _danmakuSupport[path] = explicit || methods.isNotEmpty;
    } catch (_) {
      return _danmakuSupport[path] = true;
    }
  }

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
    // 脚本没声明分类时补一条「全部」：否则分类条整个是空的，目录页
    // 连一个 tab 都没有，看起来就像「源没接上」。
    if (rows.isEmpty) return const [CatalogCategory.all];
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
    // 蜘蛛取流失败时常常「礼貌地」返回站点首页或 SITE + "/"，而不是报错。
    // 直接拿去播放只会得到一个打不开的网页，用户看到的是「不能播放」。
    // 这里识别出来，给出能看懂的原因。
    if (_looksLikeSiteRoot(plan.url)) {
      throw AppFailure(
        '这个 py 源没有取到播放地址（源返回了站点首页，通常是源侧取流接口被限制或需要更新）',
        code: 'NO_STREAM',
      );
    }
    // 弹幕：优先用脚本自己给的地址/标识。红果系 py 蜘蛛在 playerContent
    // 里直接返回本机弹幕地址（可能多条），但仍需要一个稳定的 episodeId
    // 做分页校验，所以这里统一按「源内编号:集号」补一个。
    var danmakuId = plan.danmakuId;
    final danmakuUrls = plan.danmakuUrls;
    if (danmakuId.isEmpty &&
        (danmakuUrls.isNotEmpty || await _supportsDanmaku(_path(source)))) {
      danmakuId = '${drama.sourceId}:${episode.number}';
    }
    return PlaybackPlan(
      url: plan.url,
      directUrl: plan.url,
      headers: plan.headers,
      quality: quality,
      session: 'py:${pySourceScriptId(source)}',
      danmakuId: danmakuId,
      danmakuUrls: danmakuUrls,
      routeName: routeName,
      playToken: target,
      routeIndex: routeIndex >= 0 ? routeIndex : intValue(episode.raw['routeIndex']),
      routeCount: intValue(episode.raw['routeCount']) > 0
          ? intValue(episode.raw['routeCount'])
          : 1,
    );
  });

  /// 判断播放地址是不是「站点首页」这种占位返回值。
  ///
  /// 蜘蛛取流失败时经常返回 `SITE + "/"`（如 `https://hongguoduanju.com/`），
  /// 它不是视频地址，播放器打不开。真正的播放地址一定带路径或查询参数。
  static bool _looksLikeSiteRoot(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) return false;
    final path = uri.path;
    // 根路径且没有查询参数 → 视为站点首页占位。
    if (path.isEmpty || path == '/') {
      return uri.query.isEmpty;
    }
    // 明显不是媒体地址的网页路径（详情页 / 首页列表）也排除。
    return RegExp(r'^/detail\b').hasMatch(path) ||
        RegExp(r'^/category\b').hasMatch(path);
  }

  Future<PlaybackPlan> resolveRoute(int routeIndex) async {
    final last = _lastResolve;
    if (last == null) {
      throw AppFailure('线路信息已失效，请重新打开剧集', code: 'NO_ROUTE');
    }
    return resolve(last.drama, last.episode, routeIndex: routeIndex);
  }

  /// 多季：TVBox 方言没有标准多季方法，常见做法是「一季一条线路」
  /// （`vod_play_from` 里写「第N季 超清」）。这里从线路名解析季号，
  /// 每一季用对应线路的分集构造一个 `DramaSeason`。
  ///
  /// 脚本另外实现了 `seriesSeasons` 时优先用它。
  Future<List<DramaSeason>> seasons(Drama drama) => _guard(() async {
    final source = drama.source;
    final sourceId = drama.sourceId.trim().isNotEmpty
        ? drama.sourceId.trim()
        : drama.id;
    if (sourceId.isEmpty) return const <DramaSeason>[];

    // 先问脚本有没有专门的多季方法。
    final explicit = await PyBridge.call(_path(source), {
      'action': 'seasons',
      'vodId': sourceId,
    });
    final explicitRows = explicit['list'] as List? ?? const [];
    if (explicitRows.isNotEmpty) {
      final seasons = <int, DramaSeason>{};
      for (final row in explicitRows) {
        if (row is! Map) continue;
        final vod = Map<String, dynamic>.from(row);
        final id = (vod['vod_id']?.toString() ?? '').trim();
        final title = (vod['vod_name']?.toString() ?? '').trim();
        if (id.isEmpty || title.isEmpty) continue;
        final number = intValue(vod['season']);
        if (number <= 0) continue;
        seasons[number] = DramaSeason(
          number: number,
          drama: Drama(
            id: '$source:$id',
            source: source,
            sourceId: id,
            title: title,
            description: (vod['vod_content']?.toString() ?? '').trim(),
            cover: normalizeCover(vod['vod_pic']?.toString() ?? ''),
            episodes: intValue(vod['vod_episodes']),
            category: categoryNameOf(
              (vod['vod_class']?.toString() ?? '').trim().isEmpty
                  ? drama.category
                  : vod['vod_class'].toString(),
            ),
            vip: false,
          ),
        );
      }
      if (seasons.isNotEmpty) {
        return seasons.values.toList()
          ..sort((a, b) => a.number.compareTo(b.number));
      }
    }

    // 回退：从详情线路名里解析「第N季」。这是红果系 py 蜘蛛的通行做法
    // （多季时一季一条线路，线路名写成「第N季 超清」）。
    //
    // 注意不能把「画质线路」当季：单季剧的线路名是 超清 / 高清 / 标准，
    // 没有季号，这时必须返回空，否则详情页会冒出 5 个假季。
    final detail = await PyBridge.call(_path(source), {
      'action': 'detail',
      'vodId': sourceId,
    });
    final rows = detail['list'] as List? ?? const [];
    if (rows.isEmpty || rows.first is! Map) return const <DramaSeason>[];
    final vod = Map<String, dynamic>.from(rows.first as Map);
    final routes = PyContract.parseRoutes(
      vod['vod_play_from']?.toString() ?? '',
      vod['vod_play_url']?.toString() ?? '',
    );
    if (routes.length < 2) return const <DramaSeason>[];
    // 先确认线路名里确实带季号，且不止一个季。
    final numbers = <int>[];
    for (final route in routes) {
      final number = _seasonNumberOf(route.name);
      if (number != null && !numbers.contains(number)) numbers.add(number);
    }
    if (numbers.length < 2) return const <DramaSeason>[];
    final seasons = <int, DramaSeason>{};
    for (var index = 0; index < routes.length; index++) {
      final route = routes[index];
      final number = _seasonNumberOf(route.name);
      if (number == null) continue;
      if (seasons.containsKey(number)) continue;
      seasons[number] = DramaSeason(
        number: number,
        drama: Drama(
          id: '${drama.id}#s$number',
          source: source,
          sourceId: sourceId,
          title: '${drama.title} 第$number季',
          description: drama.description,
          cover: drama.cover,
          episodes: route.chapters.length,
          category: drama.category,
          vip: false,
        ),
      );
    }
    if (seasons.length < 2) return const <DramaSeason>[];
    return seasons.values.toList()
      ..sort((a, b) => a.number.compareTo(b.number));
  });

  /// 从线路名里取季号：「第2季 超清」「第二季」「第三部」都能认。
  static int? _seasonNumberOf(String label) => PyContract.seasonNumberOf(label);

  /// 弹幕：py 蜘蛛的通行做法是在 `playerContent` 里给 `danmaku` 字段
  /// （通常是本机 `http://127.0.0.1:PORT/hg_dm?...` 的 XML/JSON 地址）。
  /// 这里把它取回来解析；脚本另外实现 `danmaku` 方法时也能直接用。
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) => _guard(() async {
    final source = plan.session;
    final next = startMs + durationMs;
    final items = <DanmakuItem>[];
    final seen = <String>{};

    void addRow(Object? id, Object? text, int timeMs) {
      final key = id?.toString() ?? '';
      final value = text?.toString().trim() ?? '';
      if (key.isEmpty || value.isEmpty || timeMs <= 0) return;
      if (timeMs < startMs || timeMs >= next) return;
      if (!seen.add(key)) return;
      items.add(DanmakuItem(id: key, text: value, timeMs: timeMs));
    }

    // 1) 脚本自己实现 danmaku 方法时优先用它；没实现时宿主会回退到
    //    playerContent 的 danmaku 字段，所以要把线路与分集 token 一起带上。
    final raw = await PyBridge.call(_path(source), {
      'action': 'danmaku',
      'series': plan.danmakuId,
      'video': plan.danmakuId,
      'startMs': startMs,
      'durationMs': durationMs,
      'flag': plan.routeName,
      'playId': plan.playToken,
    });
    final itemRows = raw['items'];
    if (itemRows is List && itemRows.isNotEmpty) {
      for (final row in itemRows.take(200)) {
        if (row is! Map) continue;
        var timeMs = intValue(row['timeMs']);
        if (timeMs <= 0) timeMs = intValue(row['createTime']) * 1000;
        addRow(row['id'], row['text'], timeMs);
      }
    } else {
      for (final row in (raw['list'] as List? ?? const []).take(200)) {
        if (row is! Map) continue;
        addRow(row['id'], row['text'], intValue(row['createTime']) * 1000);
      }
    }

    // 2) 没有的话，去弹幕地址取。地址来自两处：宿主回退拿到的 urls，
    //    以及播放计划里已经带的 danmakuUrls（红果系走这条）。
    if (items.isEmpty) {
      final urls = <String>[
        for (final value in raw['urls'] as List? ?? const [])
          if (value.toString().trim().isNotEmpty) value.toString().trim(),
        ...plan.danmakuUrls,
      ];
      for (final url in urls) {
        final text = await _fetchDanmaku(url);
        if (text.isEmpty) continue;
        _parseDanmakuText(text, addRow);
        // 取到就够用；多条地址通常互为备份，全拉只会拖慢首帧。
        if (items.isNotEmpty) break;
      }
    }

    items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return DanmakuPage(
      episodeId: plan.danmakuId,
      startMs: startMs,
      nextMs: next,
      items: items,
    );
  });

  /// 拉取弹幕正文；失败返回空串，不影响播放。
  Future<String> _fetchDanmaku(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '';
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'Mozilla/5.0 (guoapp py sandbox)');
      final response = await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode < 200 || response.statusCode >= 300) return '';
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 12))) {
        if (bytes.length + chunk.length > 8 * 1024 * 1024) break;
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes(), allowMalformed: true);
    } catch (_) {
      return '';
    } finally {
      client.close(force: true);
    }
  }

  /// 解析弹幕正文：兼容 JSON（items/list）与 B 站风格 XML（`<d p="时间,模式,...">文本</d>`）。
  void _parseDanmakuText(
    String text,
    void Function(Object? id, Object? text, int timeMs) addRow,
  ) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        final rows = decoded is Map
            ? (decoded['items'] ?? decoded['list'] ?? decoded['data'])
            : decoded;
        if (rows is List) {
          for (final row in rows.take(400)) {
            if (row is! Map) continue;
            var timeMs = intValue(row['timeMs']);
            if (timeMs <= 0) {
              final seconds = double.tryParse('${row['time'] ?? row['progress'] ?? ''}');
              if (seconds != null) timeMs = (seconds * 1000).round();
            }
            if (timeMs <= 0) timeMs = intValue(row['createTime']) * 1000;
            addRow(row['id'] ?? row['cid'] ?? row['text'], row['text'] ?? row['content'], timeMs);
          }
        }
        return;
      } catch (_) {
        // 落到 XML 分支。
      }
    }
    final pattern = RegExp(r'<d\s+p="([^"]*)"[^>]*>([^<]*)</d>');
    var index = 0;
    for (final match in pattern.allMatches(text)) {
      final parts = (match.group(1) ?? '').split(',');
      final seconds = double.tryParse(parts.isNotEmpty ? parts[0] : '');
      if (seconds == null) continue;
      addRow('xml${index++}', match.group(2), (seconds * 1000).round());
    }
  }


  bool ownsSession(String session) => session.startsWith('py:');

  void cancel(String source, String scope) {}
  void cancelAll() {}
  void cancelPlayback() {}
}
