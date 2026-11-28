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
    // 站点常给出「共 N 集」但只放出前几集的播放地址（`accessible_episode_cnt`）。
    // 详情页要显示真实总数，并说明可播放的只有这么多，否则用户会以为源坏了。
    final declared = intValue(vod['vod_episodes']) > 0
        ? intValue(vod['vod_episodes'])
        : _episodeCountFromRemarks(_text(vod['vod_remarks']));
    final playable = routes.first.chapters.length;
    final total = declared > playable ? declared : playable;
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
    final primary = routes.first;
    final episodes = <Episode>[];
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

  /// 播放地址：返回原样 url + header，`parse` 交给调用方决定。
  static ({
    String url,
    Map<String, String> headers,
    bool parse,
    String danmakuId,
    String danmakuUrl,
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
    // 部分 py 蜘蛛会在播放结果里直接给弹幕标识与地址；红果系走 `danmaku`。
    final danmakuId = _text(result['danmakuId']);
    var danmakuUrl = _text(result['danmaku']);
    if (danmakuUrl.isEmpty) danmakuUrl = _text(result['danmakuUrl']);
    return (
      url: url,
      headers: headers,
      parse: parse,
      danmakuId: danmakuId,
      danmakuUrl: danmakuUrl,
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
