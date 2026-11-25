import 'dart:io';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/recommend/recommend_feed.dart';
import 'package:duanju_app/source_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

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
