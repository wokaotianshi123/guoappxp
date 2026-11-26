import 'dart:io';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/recommend/recommend_feed.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/source_fixture.dart';

/// 推荐流的两条核心约定：
/// 1. 取流固定走「全部」分类，且不限制个数——滑到底要能继续补页；
/// 2. 每部剧的详情按需加载并缓存，供全屏播放建播放句柄。
void main() {
  const jsOfficial = 'js:hongguo';

  void installJsOfficial() => SourceSite.installJs([
    const SourceSite(
      jsOfficial,
      '官方免费短剧',
      '',
      available: true,
      recommends: true,
    ),
  ]);

  tearDown(() => SourceSite.installJs(const []));

  test('推荐可以持续翻页，不受条数上限限制', () async {
    installJsOfficial();
    final store = await openStore();
    await store.setSource(jsOfficial);

    // 每页 10 条，共 5 页 = 50 条，验证能一路翻下去。
    final repository = _PagedRepository(pageSize: 10, pages: 5);
    final feed = RecommendFeed(repository, store);
    addTearDown(feed.dispose);

    await feed.refresh();
    expect(feed.items.length, 10);
    expect(feed.hasMore, isTrue);
    // 推荐流的读取会话必须与发现页隔离，否则两个页面会互相取消。
    expect(repository.lanes, isNotEmpty);
    expect(repository.lanes.toSet(), {'feed'});

    for (var page = 2; page <= 5; page++) {
      await feed.loadMore();
      expect(feed.items.length, page * 10, reason: '第 $page 页应累计 ${page * 10} 条');
    }
    expect(feed.items.length, 50);
    expect(feed.hasMore, isFalse);

    // 到底之后再调用不应重复追加。
    await feed.loadMore();
    expect(feed.items.length, 50);
  });

  test('详情按需加载并缓存，供全屏播放使用', () async {
    installJsOfficial();
    final store = await openStore();
    await store.setSource(jsOfficial);

    final repository = _PagedRepository(pageSize: 3, pages: 1);
    final feed = RecommendFeed(repository, store);
    addTearDown(feed.dispose);

    await feed.refresh();
    final first = feed.items.first;

    // 首屏应已预取第一条的详情。
    expect(feed.detailOf(first.id), isNotNull);
    expect(repository.requested, contains(first.id));

    // 重复调用命中缓存，不再请求。
    final before = repository.requested.length;
    await feed.loadDetail(first);
    expect(repository.requested.length, before);
  });

  test('首屏请求被取消时自动重试，不把内部取消当成报错', () async {
    installJsOfficial();
    final store = await openStore();
    await store.setSource(jsOfficial);

    final repository = _CancelledOnceRepository();
    final feed = RecommendFeed(repository, store);
    addTearDown(feed.dispose);

    await feed.refresh();
    expect(repository.calls, 2, reason: '被取消后应自动再取一次');
    expect(feed.error, isEmpty);
    expect(feed.items, isNotEmpty);
  });

  test('取消最终还是失败时，不给用户看内部错误', () async {
    installJsOfficial();
    final store = await openStore();
    await store.setSource(jsOfficial);

    final repository = _CancelledRepository();
    final feed = RecommendFeed(repository, store);
    addTearDown(feed.dispose);

    await feed.refresh();
    expect(repository.calls, 2, reason: '只自动重试一次，避免无限重试');
    expect(feed.error, isNot(contains('context canceled')));
    expect(feed.error, contains('刷新'));
  });

  test('换源后推荐自动清掉旧源内容并加载新源', () async {
    installSourceFixture();
    addTearDown(() => SourceSite.install(const []));
    final store = await openStore();
    await store.setSource('hanxiaoquan');

    final repository = _SourceRepository();
    final feed = RecommendFeed(repository, store);
    addTearDown(feed.dispose);

    await feed.refresh();
    expect(feed.items, isNotEmpty);
    expect(feed.items.first.source, 'hanxiaoquan');

    // 换源只改一次 store，推荐流应自己跟着换掉，不需要用户再点刷新。
    await store.setSource('guipian');
    await _waitUntil(
      () => feed.items.isNotEmpty && feed.items.first.source == 'guipian',
    );
    expect(feed.items.any((item) => item.source == 'hanxiaoquan'), isFalse);
    expect(repository.lanes.toSet(), {'feed'});
  });

  test('刷新按钮换一批：往后翻一页拿新内容，而不是重载当前页', () async {
    installJsOfficial();
    final store = await openStore();
    await store.setSource(jsOfficial);

    final repository = _PagedRepository(pageSize: 4, pages: 3);
    final feed = RecommendFeed(repository, store);
    addTearDown(feed.dispose);

    await feed.refresh();
    final firstBatch = [for (final item in feed.items) item.title];
    expect(repository.requestedPages, [1]);

    await feed.refresh(advance: true);
    expect(repository.requestedPages, [1, 2], reason: '换一批必须请求下一页');
    expect([for (final item in feed.items) item.title], isNot(firstBatch));
    expect(feed.items.first.title, '推荐 2-0');
    expect(feed.index, 0, reason: '新的一批从第一部开始');
    expect(feed.detailOf(feed.items.first.id), isNotNull, reason: '新的第一部要能直接起播');
  });

  test('换一批跳过当前组里已经出现过的剧集', () async {
    installJsOfficial();
    final store = await openStore();
    await store.setSource(jsOfficial);

    final repository = _OverlapRepository();
    final feed = RecommendFeed(repository, store);
    addTearDown(feed.dispose);

    await feed.refresh();
    expect([for (final item in feed.items) item.title], ['a', 'b']);

    // 第二页与第一页有重叠（a 已经看过），只保留真正的新剧。
    await feed.refresh(advance: true);
    expect([for (final item in feed.items) item.title], ['c', 'd']);
    expect(repository.requestedPages, [1, 2]);
  });

  test('翻到底之后换一批回到第一页重新开始，不出现空列表', () async {
    installJsOfficial();
    final store = await openStore();
    await store.setSource(jsOfficial);

    final repository = _ExhaustedRepository();
    final feed = RecommendFeed(repository, store);
    addTearDown(feed.dispose);

    await feed.refresh();
    expect(feed.items, isNotEmpty);

    await feed.refresh(advance: true);
    expect(repository.requestedPages, [1, 2, 1], reason: '到底后应回到第一页');
    expect(feed.items, isNotEmpty);
    expect(feed.error, isEmpty);
  });

  test('内核推荐源换一批：再取流要带 more 标记', () async {
    SourceSite.install([
      const SourceSite(
        'modtest',
        '模块推荐源',
        '',
        available: true,
        recommends: true,
      ),
    ]);
    addTearDown(() => SourceSite.install(const []));
    final store = await openStore();
    await store.setSource('modtest');

    final repository = FakeRepository();
    final feed = RecommendFeed(repository, store);
    addTearDown(feed.dispose);

    await feed.refresh();
    expect(repository.recommendRequests.map((r) => r.more), [false]);

    await feed.refresh(advance: true);
    expect(
      repository.recommendRequests.map((r) => r.more),
      contains(true),
      reason: '换一批必须向内核要下一段信息流',
    );
  });

  test('hongguo.js 的推荐走信息流而不是固定 10 条的榜单', () {
    final script = File('assets/sources/hongguo.js').readAsStringSync();
    final start = script.indexOf('spider.recommendations');
    expect(start, greaterThan(0));
    final body = script.substring(start, start + 1200);

    // 推荐主体必须是分页信息流；榜单只允许留给 AI 剧这一条分支。
    expect(body, contains("paged('recommendations:'"));
    final rankedCalls = RegExp(r'rankedPage\(').allMatches(body).length;
    expect(
      rankedCalls,
      1,
      reason: '只有 AI 剧允许走榜单，其余必须走可无限翻页的信息流',
    );
    expect(body, isNot(contains('cachedRecommendBoard')));
  });
}

/// 按页返回固定条数的假仓库，用来验证「能一直翻下去」。
class _PagedRepository extends FakeRepository {
  _PagedRepository({required this.pageSize, required this.pages});

  final int pageSize;
  final int pages;

  /// 记录每次取流用的读取会话标记（应与发现页隔离）。
  final lanes = <String>[];

  /// 记录请求过的页码，用来断言「换一批」确实往后翻了页。
  final requestedPages = <int>[];

  /// 记录详情请求过的剧 id（基类只有计数，这里需要具体 id）。
  final requested = <String>[];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String lane = '',
    bool force = false,
  }) async {
    expect(category, isEmpty, reason: '推荐流固定从「全部」分类取流');
    lanes.add(lane);
    requestedPages.add(page);
    final items = [
      for (var i = 0; i < pageSize; i++)
        drama('r$page-$i', source: source, title: '推荐 $page-$i'),
    ];
    return CatalogPage(items, page: page, hasMore: page < pages);
  }

  @override
  Future<DramaDetail> detail(Drama target) async {
    requested.add(target.id);
    return DramaDetail(target, [
      Episode({'id': '1', 'title': '第 1 集', 'currentEpisode': 1}, 1),
    ]);
  }
}

/// 第一页与第二页有重叠，用来验证「换一批」会跳过看过的剧。
class _OverlapRepository extends FakeRepository {
  final requestedPages = <int>[];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String lane = '',
    bool force = false,
  }) async {
    requestedPages.add(page);
    final keys = page <= 1 ? ['a', 'b'] : ['a', 'c', 'd'];
    return CatalogPage(
      [for (final key in keys) drama(key, source: source, title: key)],
      page: page,
      hasMore: page < 2,
    );
  }

  @override
  Future<DramaDetail> detail(Drama target) async => DramaDetail(target, [
    Episode({'id': '1', 'title': '第 1 集', 'currentEpisode': 1}, 1),
  ]);
}

/// 只有一页：翻到底之后应回到第一页，而不是给一张空页。
class _ExhaustedRepository extends FakeRepository {
  final requestedPages = <int>[];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String lane = '',
    bool force = false,
  }) async {
    requestedPages.add(page);
    if (page > 1) return CatalogPage(const [], page: page, hasMore: false);
    return CatalogPage([
      drama('a', source: source, title: 'a'),
      drama('b', source: source, title: 'b'),
    ], page: 1, hasMore: false);
  }

  @override
  Future<DramaDetail> detail(Drama target) async => DramaDetail(target, [
    Episode({'id': '1', 'title': '第 1 集', 'currentEpisode': 1}, 1),
  ]);
}

/// 第一次取流像换源竞态那样被内核取消，第二次正常返回。
class _CancelledOnceRepository extends _PagedRepository {
  _CancelledOnceRepository() : super(pageSize: 2, pages: 1);

  int calls = 0;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String lane = '',
    bool force = false,
  }) async {
    calls++;
    if (calls == 1) throw AppFailure('context canceled');
    return super.catalog(
      source,
      page: page,
      query: query,
      category: category,
      lane: lane,
      force: force,
    );
  }
}

/// 每次都像被取消的假仓库：验证重试有上限，且错误文案不透出内部措辞。
class _CancelledRepository extends _PagedRepository {
  _CancelledRepository() : super(pageSize: 2, pages: 1);

  int calls = 0;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String lane = '',
    bool force = false,
  }) async {
    calls++;
    throw AppFailure('context canceled');
  }
}

/// 按当前站源返回内容的假仓库，用来验证换源后列表跟着换。
class _SourceRepository extends FakeRepository {
  final lanes = <String>[];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String lane = '',
    bool force = false,
  }) async {
    lanes.add(lane);
    return CatalogPage([
      drama('$source-1', source: source, title: '$source 第一集'),
      drama('$source-2', source: source, title: '$source 第二集'),
    ], page: page, hasMore: false);
  }

  @override
  Future<DramaDetail> detail(Drama target) async => DramaDetail(target, [
    Episode({'id': '1', 'title': '第 1 集', 'currentEpisode': 1}, 1),
  ]);
}

/// 等异步刷新落地；推荐流的换源刷新由 store 通知触发，没有可 await 的句柄。
Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待推荐流刷新超时');
}
