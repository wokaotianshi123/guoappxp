import 'dart:convert';
import 'dart:io';

import '../../core_bridge.dart';

const fanqieAudiobookGenre = '4';
const fanqieChapterPageSize = 50;

class FanqieAudiobookBoard {
  const FanqieAudiobookBoard(this.name, this.sideType, this.type);

  final String name;
  final int sideType;
  final int type;
}

/// 番茄畅听公开榜。`side_type=17` 是听书榜，`type` 1 为男生、0 为女生。
const fanqieAudiobookBoards = [
  FanqieAudiobookBoard('听书榜', 17, 1),
  FanqieAudiobookBoard('女生听书', 17, 0),
];

class AudiobookSegment {
  const AudiobookSegment(this.text, this.start);

  final String text;
  final double start;
}

class AudiobookLine {
  const AudiobookLine(
    this.text,
    this.start,
    this.end, [
    this.segments = const [],
  ]);

  final String text;
  final double start;
  final double end;

  /// 逐句时间戳（仅来自带时间轴的听书正文）；为空时整段作为一个单位。
  final List<AudiobookSegment> segments;
}

class FanqieBook {
  const FanqieBook({
    required this.id,
    required this.title,
    required this.author,
    required this.category,
  });

  final String id;
  final String title;
  final String author;
  final String category;
}

class FanqieChapter {
  const FanqieChapter({
    required this.id,
    required this.title,
    required this.order,
    required this.locked,
  });

  final String id;
  final String title;
  final int order;
  final bool locked;
}

class FanqieSearchPage {
  const FanqieSearchPage({required this.books, required this.hasMore});

  final List<FanqieBook> books;
  final bool hasMore;
}

class FanqieChapterPage {
  const FanqieChapterPage({
    required this.chapters,
    required this.total,
    required this.hasMore,
  });

  final List<FanqieChapter> chapters;
  final int total;
  final bool hasMore;
}

class FanqieAudiobookApi {
  FanqieAudiobookApi({this.fetcher, this.repository});

  final Future<String> Function(String url)? fetcher;

  /// guoappxp 的仓库：默认由 Go 核心代发听书请求，代理 / 限流设置与各端一致；
  /// 未注入仓库时（单测或独立工具）才回落到 Dart 直连。
  final AppRepository? repository;
  final Map<String, List<FanqieChapter>> _chapters = {};

  Future<FanqieSearchPage> rank(
    FanqieAudiobookBoard board, {
    int page = 1,
  }) async {
    final offset = (page < 1 ? 0 : page - 1) * 20;
    final url =
        'https://api.fanqiesdk.com/api/novel/channel/homepage/rank/rank_list/v2/'
        '?aid=13&limit=20&offset=$offset&side_type=${board.sideType}&type=${board.type}';
    return fanqieRankPage(jsonDecode(await _fetch(url)));
  }

  Future<List<String>> chapterText(String itemId) async {
    final url =
        'https://fanqienovel.com/api/reader/full?itemId=${Uri.encodeQueryComponent(itemId)}';
    final body = (await _fetch(url, headers: const {'ismobile': '0'})).trim();
    if (body.isEmpty) return const [];
    return fanqieChapterTexts(jsonDecode(body));
  }

  Future<FanqieSearchPage> search(String query, {int page = 1}) async {
    final text = query.trim();
    if (text.isEmpty) return const FanqieSearchPage(books: [], hasMore: false);
    final offset = (page < 1 ? 0 : page - 1) * 10;
    final url =
        'https://api.fanqiesdk.com/api/novel/channel/homepage/search/search/v1/'
        '?q=${Uri.encodeQueryComponent(text)}&offset=$offset&aid=13'
        '&app_name=news_article&version_name=7.0.8&device_platform=android';
    return fanqieSearchPage(jsonDecode(await _fetch(url)));
  }

  Future<List<FanqieChapter>> allChapters(String bookId) async {
    final cached = _chapters[bookId];
    if (cached != null) return List<FanqieChapter>.of(cached);
    final all = await _loadChapters(bookId);
    _chapters[bookId] = all;
    return List<FanqieChapter>.of(all);
  }

  Future<FanqieChapterPage> chapters(String bookId, {int page = 1}) async {
    final all = await allChapters(bookId);
    final current = page < 1 ? 1 : page;
    final start = (current - 1) * fanqieChapterPageSize;
    if (start >= all.length) {
      return FanqieChapterPage(
        chapters: const [],
        total: all.length,
        hasMore: false,
      );
    }
    final end = start + fanqieChapterPageSize;
    final slice = all.sublist(start, end > all.length ? all.length : end);
    return FanqieChapterPage(
      chapters: slice,
      total: all.length,
      hasMore: end < all.length,
    );
  }

  Future<void> requirePlayable(String bookId, String chapterId) async {
    final url =
        'https://api5-normal-sinfonlineb.fqnovel.com/reading/reader/audio/playinfo/'
        '?aid=1967&app_name=novelapp&book_id=${Uri.encodeQueryComponent(bookId)}'
        '&item_ids=${Uri.encodeQueryComponent(chapterId)}&tone_id=0&req_type=0';
    final body = (await _fetch(url)).trim();
    if (body.isEmpty) {
      throw AppFailure('这一章暂时没有音频地址');
    }
  }

  Future<List<FanqieChapter>> _loadChapters(String bookId) async {
    final url =
        'https://fanqienovel.com/api/reader/directory/detail?bookId=${Uri.encodeQueryComponent(bookId)}';
    return fanqieChapters(jsonDecode(await _fetch(url)));
  }

  Future<String> _fetch(String url, {Map<String, String>? headers}) {
    final get = fetcher;
    if (get != null) return get(url);
    final core = repository;
    if (core != null) {
      return core.audiobookFetch(url, headers: headers ?? const {});
    }
    return _defaultGet(url, headers: headers);
  }
}

FanqieSearchPage fanqieSearchPage(Object? decoded) {
  final root = decoded is Map ? decoded : const {};
  final data = root['data'];
  final rows = data is Map ? data['list'] ?? data['ret_data'] : null;
  final books = <FanqieBook>[];
  if (rows is List) {
    for (final row in rows) {
      if (row is! Map) continue;
      if ('${row['genre']}' != fanqieAudiobookGenre) continue;
      final id = '${row['book_id'] ?? ''}'.trim();
      final title = fanqiePlainText(
        '${row['title'] ?? row['book_name'] ?? ''}',
      );
      if (id.isEmpty || title.isEmpty) continue;
      books.add(
        FanqieBook(
          id: id,
          title: title,
          author: fanqiePlainText('${row['author'] ?? ''}'),
          category: fanqiePlainText('${row['category'] ?? ''}'),
        ),
      );
    }
  }
  final hasMore = data is Map && data['has_more'] == true;
  return FanqieSearchPage(books: books, hasMore: hasMore);
}

List<FanqieChapter> fanqieChapters(Object? decoded) {
  final root = decoded is Map ? decoded : const {};
  final data = root['data'];
  final volumes = data is Map ? data['chapterListWithVolume'] : null;
  final chapters = <FanqieChapter>[];
  if (volumes is! List) return chapters;
  for (final volume in volumes) {
    if (volume is! List) continue;
    for (final row in volume) {
      if (row is! Map) continue;
      final id = '${row['itemId'] ?? ''}'.trim();
      final title = fanqiePlainText('${row['title'] ?? ''}');
      if (id.isEmpty || title.isEmpty) continue;
      final order =
          int.tryParse('${row['realChapterOrder'] ?? ''}') ??
          chapters.length + 1;
      final locked = row['isChapterLock'] == true || row['needPay'] == 1;
      chapters.add(
        FanqieChapter(id: id, title: title, order: order, locked: locked),
      );
    }
  }
  return chapters;
}

FanqieSearchPage fanqieRankPage(Object? decoded) {
  final root = decoded is Map ? decoded : const {};
  final data = root['data'];
  final rows = data is Map ? data['result'] : null;
  final books = <FanqieBook>[];
  if (rows is List) {
    for (final row in rows) {
      if (row is! Map) continue;
      if ('${row['genre']}' != fanqieAudiobookGenre) continue;
      final id = '${row['book_id'] ?? ''}'.trim();
      final title = fanqiePlainText(
        '${row['book_name'] ?? row['title'] ?? ''}',
      );
      if (id.isEmpty || title.isEmpty) continue;
      books.add(
        FanqieBook(
          id: id,
          title: title,
          author: fanqiePlainText('${row['author'] ?? ''}'),
          category: fanqieCategory(row['category']),
        ),
      );
    }
  }
  final hasMore = data is Map && data['has_more'] == true;
  return FanqieSearchPage(books: books, hasMore: hasMore);
}

List<String> fanqieChapterTexts(Object? decoded) {
  final root = decoded is Map ? decoded : const {};
  final data = root['data'];
  final chapter = data is Map ? data['chapterData'] : null;
  final source = chapter is Map ? chapter : (data is Map ? data : const {});
  final raw = source['content'];
  if (raw is List) {
    return [
      for (final item in raw)
        if (fanqiePlainText('$item').isNotEmpty) fanqiePlainText('$item'),
    ];
  }
  return fanqieParagraphs('$raw');
}

List<String> fanqieParagraphs(String html) {
  final matches = RegExp(
    r'<p\b[^>]*>(.*?)</p>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html);
  if (matches.isEmpty) {
    final plain = fanqieInlineText(html);
    return plain.isEmpty ? const [] : [plain];
  }
  return [
    for (final match in matches)
      if (fanqieInlineText(match.group(1) ?? '').isNotEmpty)
        fanqieInlineText(match.group(1) ?? ''),
  ];
}

List<AudiobookLine> paceAudiobookLines(List<String> texts, double duration) {
  if (texts.isEmpty) return const [];
  final weights = [
    for (final text in texts) text.runes.isEmpty ? 1 : text.runes.length,
  ];
  final total = weights.fold<int>(0, (sum, weight) => sum + weight);
  final span = duration > 0 ? duration : 0.0;
  var cursor = 0.0;
  final lines = <AudiobookLine>[];
  for (var index = 0; index < texts.length; index++) {
    final width = span * weights[index] / total;
    final end = index == texts.length - 1 ? span : cursor + width;
    lines.add(AudiobookLine(texts[index], cursor, end));
    cursor = end;
  }
  return lines;
}

/// 把原生 `audiobookText` 返回的段落换成带时间的行。
/// 每段都有时间戳时用服务端逐句时间；缺任何一段就整体退回按字数比例分配。
List<AudiobookLine> audiobookTimedLines(Object? decoded, double duration) {
  final root = decoded is Map ? decoded : const {};
  final rows = root['paragraphs'];
  if (rows is! List || rows.isEmpty) return const [];
  final texts = <String>[];
  final starts = <double>[];
  final segments = <List<AudiobookSegment>>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final text = '${row['text'] ?? ''}'.trim();
    if (text.isEmpty) continue;
    texts.add(text);
    starts.add((row['start'] as num?)?.toDouble() ?? -1);
    final parts = row['segments'];
    segments.add([
      if (parts is List)
        for (final part in parts)
          if (part is Map && '${part['text'] ?? ''}'.isNotEmpty)
            AudiobookSegment(
              '${part['text']}',
              (part['start'] as num?)?.toDouble() ?? -1,
            ),
    ]);
  }
  if (texts.isEmpty) return const [];
  if (starts.any((start) => start < 0)) {
    return paceAudiobookLines(texts, duration);
  }
  final lines = <AudiobookLine>[];
  for (var index = 0; index < texts.length; index++) {
    final next = index + 1 < texts.length ? starts[index + 1] : duration;
    final start = index == 0 ? 0.0 : starts[index];
    final end = next > start ? next : start;
    lines.add(AudiobookLine(texts[index], start, end, segments[index]));
  }
  return lines;
}

/// 当前句在段内的序号；没有逐句时间时返回 -1。
int audiobookSegmentAt(AudiobookLine line, double seconds) {
  if (line.segments.isEmpty) return -1;
  var found = 0;
  for (var index = 0; index < line.segments.length; index++) {
    if (line.segments[index].start <= seconds) found = index;
  }
  return found;
}

/// 双击位置的字符偏移落在哪一句，返回该句起点；没有逐句时间时返回整段起点。
double audiobookSeekForOffset(AudiobookLine line, int offset) {
  var cursor = 0;
  for (final segment in line.segments) {
    cursor += segment.text.length;
    if (offset < cursor) {
      return segment.start < line.start ? line.start : segment.start;
    }
  }
  return line.start;
}

int audiobookLineAt(List<AudiobookLine> lines, double seconds) {
  if (lines.isEmpty) return -1;
  for (var index = 0; index < lines.length; index++) {
    if (seconds < lines[index].end || index == lines.length - 1) return index;
  }
  return lines.length - 1;
}

String fanqieCategory(Object? value) {
  if (value is List) {
    return value
        .map((item) => fanqiePlainText('$item'))
        .where((item) => item.isNotEmpty)
        .join(' · ');
  }
  return fanqiePlainText('${value ?? ''}');
}

String fanqiePlainText(String value) =>
    value.replaceAll(RegExp(r'</?em>'), '').trim();

String fanqieInlineText(String value) => fanqiePlainText(
  value
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"'),
);

Future<String> _defaultGet(String url, {Map<String, String>? headers}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.refererHeader, 'https://fanqienovel.com/');
    final extra = headers;
    if (extra != null) {
      for (final entry in extra.entries) {
        request.headers.set(entry.key, entry.value);
      }
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw AppFailure('听书源返回 ${response.statusCode}');
    }
    return await response.transform(utf8.decoder).join();
  } on AppFailure {
    rethrow;
  } catch (_) {
    throw AppFailure('无法连接听书源');
  } finally {
    client.close(force: true);
  }
}
