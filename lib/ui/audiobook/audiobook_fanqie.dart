import 'dart:convert';
import 'dart:io';

import '../../core_bridge.dart';

const fanqieAudiobookGenre = '4';
const fanqieChapterPageSize = 50;

/// 榜单接口忽略 limit、固定每页返回 30 条；offset 步长取 30 时相邻页零重叠。
/// 实测男/女榜各约 34 页（offset 990 之后返回空），两榜 book_id 不重叠，
/// 合计约 2040 本，是番茄畅听完整的听书书库。
const fanqieRankPageSize = 30;

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

/// 听书页顶部的两个书源。红果听书和番茄畅听是同一后端（红果专辑在
/// `api.novelfm.com` 上按同一 `book_id` 可直接查详情与目录），区别在于
/// 红果听书吃官方书城的听书专辑（带主播、集数、评分），番茄听书吃榜单。
class FanqieAudiobookOrigin {
  const FanqieAudiobookOrigin(this.name, this.type);

  final String name;
  final int type;
}

const fanqieAudiobookOrigins = [
  FanqieAudiobookOrigin('红果听书', 0),
  FanqieAudiobookOrigin('番茄听书', 1),
];

/// 主播名里出现这些词时，说明是官方 AI 音色而不是真人录制。
const _fanqieAiAnchorHints = [
  'ai',
  '智能',
  '机器',
  '合成',
  'tts',
  '番茄畅听',
  '番茄小说',
  '听书助手',
];

/// 详情页的有声书类型标签。
String fanqieVoiceMode(String anchor) {
  final text = anchor.trim().toLowerCase();
  if (text.isEmpty) return 'AI 朗读';
  for (final hint in _fanqieAiAnchorHints) {
    if (text.contains(hint)) return 'AI 朗读';
  }
  return '真人录音';
}

/// 番茄畅听榜单返回的 `category_v2` 真实标签（按出现频次挑选的高频分类）。
///
/// 榜单接口没有分类列表，分类是从榜单书籍自带的标签里统计出来的，因此这些
/// 名字都能在番茄畅听的实际数据里对应到书，不是凭空编的分类词。选分类时把
/// 男/女两个榜的书池合并后按标签过滤。
const fanqieAudiobookCategories = [
  '都市',
  '玄幻',
  '悬疑',
  '灵异',
  '推理',
  '历史',
  '系统',
  '穿越',
  '重生',
  '民俗秘闻',
  '游戏体育',
  '都市生活',
  '科幻末世',
  '战神赘婿',
  '现代言情',
  '古代言情',
  '豪门总裁',
  '宫斗宅斗',
  '年代',
  '种田',
  '神医',
  '女强',
  '玄幻言情',
  '先婚后爱',
];

// —— 番茄畅听官方书城（fanqie.apk 反编译所得，实时数据源）——
//
// APK 的 assets/tab_v2_simple.json 只有 6 个一级 tab 和 8 本兜底书，真正的
// 书库与分类由 BookmallApiService 下发；smali 里硬编码了 host 和路径
// `/novelfm/bookmall/tab_v2/v1/`，scheme `novelfm3040://` 对应 aid=3040。
// 实测匿名 GET 可用，但必须带 update_version_code，并按 tab_type 分别请求
// 才有书目。这里每次进听书页都重新请求，书与分类随时间更新，不落静态快照。
const novelfmBookmallUrl =
    'https://api.novelfm.com/novelfm/bookmall/tab_v2/v1/';
const novelfmCommonQuery =
    'aid=3040&device_platform=android&version_name=6.7.8&version_code=678'
    '&device_type=SM-G9730&iid=1&device_id=1&update_version_code=1';

/// 官方一级分类：推荐 / 听书 / 相声评书 / 出版物 / 故事 / 音乐。
const novelfmTabTypes = <int>[10, 12, 4, 5, 9, 6];

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
    this.cover = '',
    this.intro = '',
    this.board = 0,
    this.anchor = '',
    this.source = 'fanqie',
  });

  final String id;
  final String title;
  final String author;
  final String category;

  /// 书源：`hongguo` = 红果听书（听书 / 小说），其余按番茄听书处理。
  final String source;

  bool get isHongguo => source == 'hongguo';

  /// 有声书主播名；为空说明这条没有真人录制。
  final String anchor;

  /// 详情页标签：有主播录制的算「真人录音」，否则是 AI 音色朗读。
  String get voiceMode => fanqieVoiceMode(anchor);

  /// 榜单/搜索返回的 `thumb_url` 封面地址，为空时列表显示占位图。
  final String cover;

  /// 榜单/搜索返回的 `abstract` 简介，为空时列表显示「暂无简介」。
  final String intro;

  /// 归属榜单：0 男生听书榜、1 女生听书榜。官方书城按 gender 归类，
  /// 榜单/搜索来源默认 0（它们本来就在当前榜里展示）。
  final int board;
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

/// 官方书城单个 tab 的解析结果。
class FanqieOfficialPage {
  const FanqieOfficialPage({
    this.books = const [],
    this.categoryDims = const {},
    this.hotTags = const [],
    this.tabTitle = '',
    this.tabType = 0,
  });

  static const empty = FanqieOfficialPage();

  final List<FanqieBook> books;

  /// 官方分类名 → Dim（1 主类 / 2 角色 / 3 金手指 / 10 细分，0 为热门标签）。
  final Map<String, int> categoryDims;
  final List<String> hotTags;
  final String tabTitle;
  final int tabType;
}

/// 多个 tab、多轮采样合并后的官方书城结果。
class FanqieOfficialResult {
  const FanqieOfficialResult({
    this.books = const [],
    this.categories = const [],
    this.hotTags = const [],
    this.tabs = const [],
  });

  static const empty = FanqieOfficialResult();

  final List<FanqieBook> books;

  /// 官方分类词表，按 Dim 从小到大、再按名称排序。
  final List<String> categories;
  final List<String> hotTags;
  final List<String> tabs;
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

  /// 实时拉取官方书城某个一级分类（tab_type）。
  Future<FanqieOfficialPage> officialTab(int tabType) async {
    final url = '$novelfmBookmallUrl?$novelfmCommonQuery&tab_type=$tabType';
    return fanqieOfficialPage(
      jsonDecode(await _fetch(url)),
      tabType: tabType,
    );
  }

  Future<FanqieOfficialPage> _officialTabSafe(int tabType) async {
    try {
      return await officialTab(tabType);
    } catch (_) {
      // 单个分类失败不影响其它分类与现有榜单书库。
      return FanqieOfficialPage.empty;
    }
  }

  /// 抓全部一级分类并累积去重。首屏推荐带随机性，多取几轮覆盖更多书；
  /// 每次调用都重新请求，不会用到固化的书目。
  Future<FanqieOfficialResult> officialAll({int rounds = 3}) async {
    final pages = <FanqieOfficialPage>[];
    for (var round = 0; round < rounds; round++) {
      pages.addAll(await Future.wait<FanqieOfficialPage>([
        for (final tab in novelfmTabTypes) _officialTabSafe(tab),
      ]));
    }
    final books = <FanqieBook>[];
    final seenBooks = <String>{};
    final dims = <String, int>{};
    final hotTags = <String>[];
    final seenTags = <String>{};
    final tabs = <String>[];
    final seenTabs = <String>{};
    for (final page in pages) {
      if (page.tabTitle.isNotEmpty && seenTabs.add(page.tabTitle)) {
        tabs.add(page.tabTitle);
      }
      for (final tag in page.hotTags) {
        if (seenTags.add(tag)) hotTags.add(tag);
      }
      page.categoryDims.forEach((name, dim) {
        final old = dims[name];
        if (old == null || (dim > 0 && (old == 0 || dim < old))) {
          dims[name] = dim;
        }
      });
      for (final book in page.books) {
        if (seenBooks.add(book.id)) books.add(book);
      }
    }
    final categories = dims.keys.toList()
      ..sort((a, b) {
        final byDim = (dims[a] ?? 99).compareTo(dims[b] ?? 99);
        return byDim != 0 ? byDim : a.compareTo(b);
      });
    return FanqieOfficialResult(
      books: books,
      categories: categories,
      hotTags: hotTags,
      tabs: tabs,
    );
  }

  Future<FanqieSearchPage> rank(
    FanqieAudiobookBoard board, {
    int page = 1,
  }) async {
    final offset = (page < 1 ? 0 : page - 1) * fanqieRankPageSize;
    final url =
        'https://api.fanqiesdk.com/api/novel/channel/homepage/rank/rank_list/v2/'
        '?aid=13&limit=$fanqieRankPageSize&offset=$offset'
        '&side_type=${board.sideType}&type=${board.type}';
    return fanqieRankPage(jsonDecode(await _fetch(url)));
  }

  /// 抓取榜单的**全部**书目。
  ///
  /// 榜单接口的 `has_more` 恒为 false、`limit` 被忽略（固定每页 30 条），只有
  /// offset 递增才会持续返回新书；实测男/女榜各约 34 页、两榜 book_id 不重叠，
  /// 合计约 2040 本。这里分批并发翻页，翻到连续两批出现空页或达到
  /// [maxPages] 为止；每批结束通过 [onProgress] 回吐当前累计书池，调用方可以边加载边把
  /// 书目显示出来，不必等全部抓完。单页失败只让那一页少几本书。
  Future<List<FanqieBook>> rankAll(
    FanqieAudiobookBoard board, {
    void Function(List<FanqieBook> pool)? onProgress,
    int batchSize = 6,
    int maxPages = 60,
  }) async {
    final seen = <String>{};
    final pool = <FanqieBook>[];
    var emptyBatches = 0;
    var page = 1;
    while (page <= maxPages && emptyBatches < 2) {
      final batch = <int>[];
      while (batch.length < batchSize && page <= maxPages) {
        batch.add(page++);
      }
      final results = await Future.wait([
        for (final number in batch)
          rank(board, page: number).catchError(
            (Object _) => const FanqieSearchPage(books: [], hasMore: false),
          ),
      ]);
      var nonEmpty = 0;
      for (final result in results) {
        if (result.books.isNotEmpty) nonEmpty++;
        for (final book in result.books) {
          if (seen.add(book.id)) pool.add(book);
        }
      }
      // 榜单分页连续，一旦某批出现空页就说明接近末尾；连续两批都有空页
      // 才停，避免个别请求失败被误判成已经翻到尽头。
      final emptyPages = results.length - nonEmpty;
      emptyBatches = emptyPages > 0 ? emptyBatches + 1 : 0;
      final notify = onProgress;
      if (notify != null) notify(List<FanqieBook>.of(pool));
    }
    return pool;
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

  // —— 红果听书（听书 / 小说）：数据来自红果 App 官方书城，与短剧共用设备签名 ----

  /// 拉红果书城某个频道的书单。推荐流每次只回一批，pages 控制连拉几批。
  Future<List<FanqieBook>> hongguoCatalog(
    String category, {
    int page = 1,
    int pages = 1,
  }) async {
    final core = repository;
    if (core == null) return const [];
    final out = <FanqieBook>[];
    final seen = <String>{};
    for (var index = 0; index < pages; index++) {
      final reply = await core.audiobookHongguoCatalog(category, page + index);
      for (final book in fanqieHongguoBooks(reply)) {
        if (seen.add(book.id)) out.add(book);
      }
    }
    return out;
  }

  Future<FanqieSearchPage> hongguoSearch(
    String category,
    String query, {
    int page = 1,
  }) async {
    final text = query.trim();
    final core = repository;
    if (text.isEmpty || core == null) {
      return const FanqieSearchPage(books: [], hasMore: false);
    }
    final reply = await core.audiobookHongguoSearch(category, text, page);
    return FanqieSearchPage(
      books: fanqieHongguoBooks(reply),
      hasMore: reply['hasMore'] == true,
    );
  }

  Future<List<FanqieChapter>> _hongguoChapters(String bookId) async {
    final core = repository;
    if (core == null) return const [];
    final reply = await core.audiobookHongguoChapters(bookId);
    final rows = reply['chapters'];
    if (rows is! List) return const [];
    final chapters = <FanqieChapter>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final id = '${row['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;
      chapters.add(
        FanqieChapter(
          id: id,
          title: '${row['title'] ?? ''}'.trim(),
          order: (row['order'] as num?)?.toInt() ?? chapters.length + 1,
          locked: row['locked'] == true,
        ),
      );
    }
    return chapters;
  }

  Future<List<FanqieChapter>> allChapters(String bookId) async {
    final cached = _chapters[bookId];
    if (cached != null) return List<FanqieChapter>.of(cached);
    final all = bookId.startsWith(fanqieHongguoPrefix)
        ? await _hongguoChapters(bookId.substring(fanqieHongguoPrefix.length))
        : await _loadChapters(bookId);
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

/// 红果听书的书籍 ID 前缀：两边都是纯数字 book_id，加前缀区分书源，
/// 书架、进度、下载目录也随之隔离。
const fanqieHongguoPrefix = 'hg:';

/// 解析红果书城 / 搜索的 `{books: [...]}` 回包。
List<FanqieBook> fanqieHongguoBooks(Object? decoded) {
  final root = decoded is Map ? decoded : const {};
  final rows = root['books'];
  if (rows is! List) return const [];
  final books = <FanqieBook>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final rawId = '${row['id'] ?? ''}'.trim();
    final title = '${row['title'] ?? ''}'.trim();
    if (rawId.isEmpty || title.isEmpty) continue;
    books.add(
      FanqieBook(
        id: rawId.startsWith(fanqieHongguoPrefix)
            ? rawId
            : '$fanqieHongguoPrefix$rawId',
        title: title,
        author: '${row['author'] ?? ''}'.trim(),
        category: '${row['category'] ?? ''}'.trim(),
        cover: '${row['cover'] ?? ''}'.trim(),
        intro: '${row['intro'] ?? ''}'.trim(),
        anchor: '${row['anchor'] ?? ''}'.trim(),
        board: (row['board'] as num?)?.toInt() ?? 0,
        source: 'hongguo',
      ),
    );
  }
  return books;
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
          cover: fanqieCover(row['thumb_url']),
          intro: fanqieIntro(row['abstract']),
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
          // 榜单同时给 category（逗号串）与 category_v2（标签数组），后者更干净。
          category: fanqieCategory(row['category_v2'] ?? row['category']),
          cover: fanqieCover(row['thumb_url']),
          intro: fanqieIntro(row['abstract']),
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

/// 解析官方书城 tab_v2 回包：只留 genre=4 的听书，同时抽出官方分类词表
/// （popular_tags.show_tags + 每本书的 category_info）和热门标签。
FanqieOfficialPage fanqieOfficialPage(Object? decoded, {int tabType = 0}) {
  final root = decoded is Map ? decoded : const <String, dynamic>{};
  final data = root['data'];
  final tabs = data is Map ? data['book_tab_infos'] : null;
  var title = '';
  var type = tabType;
  final dims = <String, int>{};
  final hotTags = <String>[];
  final rows = <Map>[];
  if (tabs is List) {
    for (final rawTab in tabs) {
      if (rawTab is! Map) continue;
      final tabTitle = fanqiePlainText('${rawTab['tab_title'] ?? ''}');
      if (tabTitle.isNotEmpty) title = tabTitle;
      final parsedType = int.tryParse('${rawTab['tab_type'] ?? ''}');
      if (parsedType != null && parsedType != 0) type = parsedType;
      final cells = rawTab['cells'];
      if (cells is! List) continue;
      for (final rawCell in cells) {
        if (rawCell is! Map) continue;
        final popular = rawCell['popular_tags'];
        final showTags = popular is Map ? popular['show_tags'] : null;
        if (showTags is List) {
          for (final rawTag in showTags) {
            if (rawTag is! Map) continue;
            final name = fanqiePlainText('${rawTag['name'] ?? ''}');
            if (name.isEmpty) continue;
            hotTags.add(name);
            dims.putIfAbsent(name, () => 0);
          }
        }
        rows.add(rawCell);
        final subCells = rawCell['sub_cells'];
        if (subCells is List) {
          for (final rawSub in subCells) {
            if (rawSub is Map) rows.add(rawSub);
          }
        }
      }
    }
  }
  void addCategory(String name, int dim) {
    if (name.isEmpty) return;
    final old = dims[name];
    if (old == null || (dim > 0 && (old == 0 || dim < old))) dims[name] = dim;
  }

  final books = <FanqieBook>[];
  final seen = <String>{};
  for (final cell in rows) {
    final list = cell['books'];
    if (list is! List) continue;
    for (final rawBook in list) {
      if (rawBook is! Map) continue;
      if ('${rawBook['genre'] ?? ''}' != fanqieAudiobookGenre) continue;
      final id = '${rawBook['book_id'] ?? ''}'.trim();
      final bookTitle = fanqiePlainText(
        '${rawBook['book_name'] ?? rawBook['title'] ?? ''}',
      );
      if (id.isEmpty || bookTitle.isEmpty || seen.contains(id)) continue;
      seen.add(id);
      final names = <String>[];
      for (final part in '${rawBook['tags'] ?? ''}'.split(',')) {
        final tag = fanqiePlainText(part);
        if (tag.isNotEmpty && !names.contains(tag)) names.add(tag);
      }
      final info = '${rawBook['category_info'] ?? ''}';
      if (info.isNotEmpty) {
        try {
          final entries = jsonDecode(info);
          if (entries is List) {
            for (final entry in entries) {
              if (entry is! Map) continue;
              final name = fanqiePlainText('${entry['Name'] ?? ''}');
              addCategory(name, int.tryParse('${entry['Dim'] ?? ''}') ?? 0);
              if (name.isNotEmpty &&
                  !names.contains(name) &&
                  names.length < 12) {
                names.add(name);
              }
            }
          }
        } catch (_) {
          // 个别书没有 category_info 或格式异常，忽略即可。
        }
      }
      books.add(
        FanqieBook(
          id: id,
          title: bookTitle,
          author: fanqiePlainText('${rawBook['author'] ?? ''}'),
          category: fanqieCategory(names),
          cover: fanqieCover(
            rawBook['audio_thumb_uri'] ?? rawBook['thumb_url'] ?? '',
          ),
          intro: fanqieIntro(rawBook['abstract']),
          board: '${rawBook['gender'] ?? ''}'.trim() == '0' ? 1 : 0,
          anchor: fanqiePlainText('${rawBook['anchor'] ?? ''}'),
        ),
      );
    }
  }
  return FanqieOfficialPage(
    books: books,
    categoryDims: dims,
    hotTags: hotTags,
    tabTitle: title,
    tabType: type,
  );
}

/// 只展示书池里确实有书的分类：高频基线标签优先，再补官方书城实时学到的
/// 分类（按官方 Dim 排序）。分类内容来自当次请求，不是写死的一份清单。
List<String> fanqieCategoriesFrom(
  Iterable<FanqieBook> pool, {
  Iterable<String> preferred = const [],
}) {
  final counts = <String, int>{};
  for (final book in pool) {
    for (final tag in book.category.split(RegExp(r'[·,，、/\s]+'))) {
      final name = tag.trim();
      if (name.isNotEmpty) counts[name] = (counts[name] ?? 0) + 1;
    }
  }
  final order = <String>[...fanqieAudiobookCategories, ...preferred];
  final seen = <String>{};
  final result = <String>[];
  for (final name in order) {
    if (counts.containsKey(name) && seen.add(name)) result.add(name);
  }
  return result;
}

/// 在全量书池里按关键词匹配书名 / 作者 / 分类 / 简介。
///
/// 服务端搜索里听书（genre=4）结果很稀疏，单页常常 0～2 本，导致搜索看起来
/// 只覆盖榜单前几项。榜单全量书池本身就是番茄畅听完整的听书库，本地匹配能让
/// 搜索覆盖全部书目，且命中的都是确认可播放的听书。支持空格分词（需全部命中），
/// 书名 / 分类命中的排在前面。
List<FanqieBook> fanqieSearchInPool(Iterable<FanqieBook> pool, String query) {
  final words = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return const [];
  final matches = <_ScoredBook>[];
  for (final book in pool) {
    final title = book.title.toLowerCase();
    final author = book.author.toLowerCase();
    final category = book.category.toLowerCase();
    final intro = book.intro.toLowerCase();
    final haystack = '$title $author $category $intro';
    if (!words.every((word) => haystack.contains(word))) continue;
    var score = 0;
    for (final word in words) {
      if (title.contains(word)) score += 4;
      if (category.contains(word)) score += 3;
      if (author.contains(word)) score += 2;
      if (intro.contains(word)) score += 1;
    }
    matches.add(_ScoredBook(book, score));
  }
  matches.sort((a, b) => b.score.compareTo(a.score));
  return [for (final item in matches) item.book];
}

class _ScoredBook {
  const _ScoredBook(this.book, this.score);

  final FanqieBook book;
  final int score;
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

/// 封面 URL 原样保留（带签名参数），列表用 Image.network 直接加载。
String fanqieCover(Object? value) => '${value ?? ''}'.trim();

/// 简介可能带高亮/换行标签，去掉标签与实体后再展示。
String fanqieIntro(Object? value) =>
    fanqieInlineText('${value ?? ''}').replaceAll('\n', ' ').trim();

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
