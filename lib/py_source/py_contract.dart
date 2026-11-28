import 'dart:convert';

import '../js_source/js_source_gateway.dart' show normalizeCover, categoryNameOf;
import '../models.dart';

/// TVBox Python 蜘蛛的输出（`vod_*` 字段）到本项目模型的转换。
///
/// 与 JS 沙箱的转换口径保持一致：`vod_play_from` / `vod_play_url` 用
/// `$$$` 分线路、`#` 分集、`$` 分「标题/编号」。
class PyContract {
  PyContract._();

  static String _text(Object? value) => value?.toString().trim() ?? '';

  static Drama dramaFromVod(String source, Map<String, dynamic> vod, String category) {
    final vodId = _text(vod['vod_id']);
    return Drama(
      id: '$source:$vodId',
      source: source,
      sourceId: vodId,
      title: _text(vod['vod_name']).isEmpty ? '未命名' : _text(vod['vod_name']),
      description: _text(vod['vod_remarks']),
      cover: normalizeCover(_text(vod['vod_pic'])),
      episodes: intValue(vod['vod_episodes']),
      category: categoryNameOf(
        _text(vod['vod_class']).isEmpty ? category : _text(vod['vod_class']),
      ),
      vip: false,
    );
  }

  static CatalogPage pageFromResult(
    String source,
    Map<String, dynamic> result,
    String category, {
    int page = 1,
  }) {
    final rows = result['list'] as List? ?? const [];
    final items = <Drama>[];
    for (final row in rows) {
      if (row is Map) {
        items.add(dramaFromVod(source, Map<String, dynamic>.from(row), category));
      }
    }
    final current = intValue(result['page']) > 0 ? intValue(result['page']) : page;
    final pageCount = intValue(result['pagecount']);
    return CatalogPage(
      items,
      page: current,
      hasMore: items.isNotEmpty && current < pageCount,
    );
  }

  /// 详情：只展开第一条线路，保持选集简洁；线路总数交给播放页切线路。
  static DramaDetail detailFromResult(
    Drama base,
    Map<String, dynamic> result,
  ) {
    final rows = result['list'] as List? ?? const [];
    if (rows.isEmpty || rows.first is! Map) {
      return DramaDetail(base, const [], warning: '该源未返回详情');
    }
    final vod = Map<String, dynamic>.from(rows.first as Map);
    final routes = parseRoutes(
      _text(vod['vod_play_from']),
      _text(vod['vod_play_url']),
    );
    if (routes.isEmpty) {
      return DramaDetail(base, const [], warning: '该源没有返回可播放的分集');
    }
    final category = categoryNameOf(
      _text(vod['vod_class']).isEmpty ? base.category : _text(vod['vod_class']),
    );
    // 切季时 `base.id` 形如 `py:xxx#s2`（见 `seasons()`）。这里要按季号
    // 选对应的线路，否则切到第二季仍然展开第一季的分集。
    final wantedSeason = _seasonFromDramaId(base.id);
    final primary = wantedSeason == null
        ? primaryRoute(routes)
        : (routes.firstWhere(
                (route) => seasonNumberOf(route.name) == wantedSeason,
                orElse: () => primaryRoute(routes),
              ));
    // 集数必须按「选中那条线路」算。
    //
    // `vod_remarks`（如「全140集」）和 `vod_episodes` 说的是整部剧/某一季的
    // 数字，跟当前线路没关系：多季时第一季只有 115 集，写成 140 会让用户
    // 以为少了 25 集。只有单季剧才用声明值补足「未放出」的提示。
    final declared = intValue(vod['vod_episodes']) > 0
        ? intValue(vod['vod_episodes'])
        : _episodeCountFromRemarks(_text(vod['vod_remarks']));
    final playable = primary.chapters.length;
    final isMultiSeason = routes.any(
      (route) => seasonNumberOf(route.name) != null,
    );
    final total = isMultiSeason
        ? playable
        : (declared > playable ? declared : playable);
    final drama = Drama(
      id: base.id,
      source: base.source,
      sourceId: _text(vod['vod_id']).isEmpty ? base.sourceId : _text(vod['vod_id']),
      title: _text(vod['vod_name']).isEmpty ? base.title : _text(vod['vod_name']),
      description: _text(vod['vod_content']).isEmpty ? base.description : _text(vod['vod_content']),
      cover: normalizeCover(_text(vod['vod_pic'])).isEmpty
          ? base.cover
          : normalizeCover(_text(vod['vod_pic'])),
      episodes: total,
      category: category,
      vip: false,
    );
    final episodes = <Episode>[];
    for (var i = 0; i < primary.chapters.length; i++) {
      episodes.add(
        Episode({
          ...primary.chapters[i],
          'routeName': primary.name,
          'routeIndex': routes.indexOf(primary),
          'routeCount': routes.length,
        }, episodes.length + 1),
      );
    }
    return DramaDetail(
      drama,
      episodes,
      warning: episodes.isEmpty
          ? '该源详情未提供播放地址'
          : (total > episodes.length
                ? '该源共 $total 集，目前只放出前 ${episodes.length} 集，其余需要源侧权限'
                : ''),
    );
  }

  /// 从 `vod_remarks` 里取总集数：「全140集」「更新至24集」都能认。
  static int _episodeCountFromRemarks(String remarks) {
    final match = RegExp(r'(\d+)\s*集').firstMatch(remarks);
    if (match == null) return 0;
    return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  /// 详情页默认展开哪条线路。
  ///
  /// 红果系把多季做成「一季一条线路」，并在最前面塞一条
  /// `全季连播 1013集` 的合并线路。直接取第一条会把 1013 集全部铺进播放
  /// 列表，看起来就像「多季没有分季」。这里优先选季号最小的那条线路
  /// （也就是第一季），没有分季时才退回第一条。
  static ({String name, List<Map<String, dynamic>> chapters}) primaryRoute(
    List<({String name, List<Map<String, dynamic>> chapters})> routes,
  ) {
    // 先看有没有真正的分季线路：至少两条线路带不同的季号。
    final numbered = <({String name, List<Map<String, dynamic>> chapters})>[];
    final numbers = <int>{};
    for (final route in routes) {
      final number = seasonNumberOf(route.name);
      if (number == null) continue;
      numbered.add(route);
      numbers.add(number);
    }
    if (numbers.length >= 2 && numbered.isNotEmpty) {
      numbered.sort((a, b) {
        final left = seasonNumberOf(a.name) ?? 0;
        final right = seasonNumberOf(b.name) ?? 0;
        return left.compareTo(right);
      });
      return numbered.first;
    }
    // 没有分季：优先第一条不是「全季连播 / 合集」的线路。
    for (final route in routes) {
      if (!isMergedSeasonRoute(route.name)) return route;
    }
    return routes.first;
  }

  /// 从线路名里取季号：「第2季 超清」「第二季」「第三部」都能认。
  static int? seasonNumberOf(String label) {
    final match = RegExp(r'第\s*([0-9]+|[一二三四五六七八九十]+)\s*[季部]')
        .firstMatch(label);
    if (match == null) return null;
    final raw = match.group(1) ?? '';
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt > 0 ? asInt : null;
    const digits = '零一二三四五六七八九';
    var total = 0;
    var current = 0;
    for (final char in raw.split('')) {
      if (char == '十') {
        total += (current == 0 ? 1 : current) * 10;
        current = 0;
      } else {
        final value = digits.indexOf(char);
        if (value < 0) return null;
        current = value;
      }
    }
    total += current;
    return total > 0 ? total : null;
  }

  /// 「全季连播」「合集」「全集」这类把各季混在一条线路里的名字。
  ///
  /// 红果系的线路顺序是：`全季连播 1013集` + 第一至六季。这类合并线路
  /// 不能当默认线路，否则播放列表会被塞进上千集。
  static bool isMergedSeasonRoute(String label) =>
      RegExp(r'全季|合集|全集|连播|完整版').hasMatch(label);

  /// 从剧集 id 里取季标记：`py:xxx#s2` → 2。没有标记时返回 null。
  static int? _seasonFromDramaId(String id) {
    final match = RegExp(r'#s(\d+)$').firstMatch(id);
    if (match == null) return null;
    final number = int.tryParse(match.group(1) ?? '') ?? 0;
    return number > 0 ? number : null;
  }

  /// 播放地址：返回原样 url + header，`parse` 交给调用方决定。
  static ({
    String url,
    Map<String, String> headers,
    bool parse,
    String danmakuId,
    List<String> danmakuUrls,
  })
  planFromResult(Map<String, dynamic> result) {
    final headers = <String, String>{};
    final raw = result['header'];
    if (raw is Map) {
      raw.forEach((key, value) => headers[key.toString()] = value.toString());
    } else if (raw is String && raw.trim().startsWith('{')) {
      try {
        final decoded = raw.trim();
        // 避免为这种情况引入额外依赖：直接尝试 JSON 解码。
        final parsed = _tryDecodeMap(decoded);
        parsed?.forEach((key, value) => headers[key.toString()] = value.toString());
      } catch (_) {}
    }
    var url = _text(result['url']);
    if (url.isEmpty) url = _text(result['playUrl']);
    final parse = result['parse'] == true ||
        intValue(result['parse']) == 1 ||
        result['jx'] == true ||
        intValue(result['jx']) == 1;
    // 弹幕：蜘蛛有两种写法——直接给地址字符串，或给 `[{name, url}]` 列表
    // （红果系 `_DM_IN_PLAYER = "list"` 就是列表，并支持多条线路）。
    final danmakuId = _text(result['danmakuId']);
    final danmakuUrls = <String>[];
    void addDanmaku(Object? value) {
      final text = _text(value);
      if (text.isNotEmpty && !danmakuUrls.contains(text)) danmakuUrls.add(text);
    }

    final rawDanmaku = result['danmaku'];
    if (rawDanmaku is List) {
      for (final row in rawDanmaku) {
        if (row is Map) {
          addDanmaku(row['url'] ?? row['address'] ?? row['src']);
        } else {
          addDanmaku(row);
        }
      }
    } else {
      addDanmaku(rawDanmaku);
    }
    addDanmaku(result['danmakuUrl']);
    return (
      url: url,
      headers: headers,
      parse: parse,
      danmakuId: danmakuId,
      danmakuUrls: danmakuUrls,
    );
  }

  static Map<String, dynamic>? _tryDecodeMap(String text) {
    try {
      final value = jsonDecode(text);
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } catch (_) {
      return null;
    }
  }

  /// `from: 线路一$$$线路二`、`url: 第1集$A#第2集$B$$$...` → 线路列表。
  static List<({String name, List<Map<String, dynamic>> chapters})> parseRoutes(
    String fromRaw,
    String urlRaw,
  ) {
    final froms = fromRaw.isEmpty ? const ['默认'] : fromRaw.split(r'$$$');
    final groups = urlRaw.isEmpty ? const <String>[] : urlRaw.split(r'$$$');
    final routes = <({String name, List<Map<String, dynamic>> chapters})>[];
    for (var g = 0; g < groups.length; g++) {
      final name = g < froms.length && froms[g].trim().isNotEmpty
          ? froms[g].trim()
          : '线路${g + 1}';
      final chapters = <Map<String, dynamic>>[];
      for (final segment in groups[g].split('#')) {
        final trimmed = segment.trim();
        if (trimmed.isEmpty) continue;
        final at = trimmed.indexOf(r'$');
        final title = at > 0 ? trimmed.substring(0, at) : '第${chapters.length + 1}集';
        final playId = at > 0 ? trimmed.substring(at + 1) : trimmed;
        if (playId.isEmpty) continue;
        chapters.add({'id': playId, 'title': title, 'raw': playId});
      }
      if (chapters.isNotEmpty) routes.add((name: name, chapters: chapters));
    }
    return routes;
  }
}
