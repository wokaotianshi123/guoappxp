import 'package:duanju_app/models.dart';
import 'package:duanju_app/source_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _TopicRepository extends FakeRepository {
  @override
  CatalogPage pageFor(String source, String category, String query, int page) =>
      CatalogPage(
        [drama('p$page', source: source, category: '都市')],
        hasMore: true,
        page: page,
      );
}

void main() {
  test('categories only contain what the source declares', () async {
    final repository = FakeRepository()
      ..categoryList = const [
        CatalogCategory.all,
        CatalogCategory('short_play', '真人剧'),
        CatalogCategory('comic', 'AI成人漫剧'),
        CatalogCategory('comic_again', 'AI漫剧'),
      ]
      ..cachedPages['hongguo|'] = CatalogPage([
        drama('1', category: '都市'),
        drama('2', category: '成长'),
        drama('3', category: 'AI 漫剧'),
        drama('4', source: 'huangdou', category: '甜宠'),
      ]);
    final catalog = SourceCatalog(repository, SourceSite.byId('hongguo'));
    await catalog.loadCategories();
    expect(
      [for (final category in catalog.categories) category.id],
      ['', 'short_play', 'comic'],
    );
    expect(catalog.categories[2].name, 'AI 漫剧');
    // 缓存里出现的「都市 / 成长 / 未分类」都不该冒成分类 tab。
    expect(
      catalog.categories.map((category) => category.name),
      ['全部', '真人剧', 'AI 漫剧'],
    );
  });

  test('duplicate declared categories are deduped', () async {
    final repository = FakeRepository()
      ..categoryList = const [
        CatalogCategory.all,
        CatalogCategory('short_play', '真人剧'),
        CatalogCategory('tag:cate_96', '甜宠'),
        CatalogCategory('tag:cate_1', '都市'),
      ]
      ..cachedPages['hongguo|'] = CatalogPage([
        drama('1', category: '都市'),
        drama('2', category: '成长'),
      ]);
    final catalog = SourceCatalog(repository, SourceSite.byId('hongguo'));
    await catalog.loadCategories();
    expect(
      [for (final category in catalog.categories) category.id],
      ['', 'short_play', 'tag:cate_96', 'tag:cate_1'],
    );
  });

  test('cached drama categories never become tabs', () async {
    final repository = FakeRepository()
      ..categoryList = const [CatalogCategory.all]
      ..cachedPages['hongguo|'] = CatalogPage([
        drama('1', category: '都市'),
        drama('2', category: '成长'),
      ]);
    final catalog = SourceCatalog(repository, SourceSite.byId('hongguo'));
    await catalog.loadCategories();
    expect(
      [for (final category in catalog.categories) category.id],
      [''],
    );
  });

  test('fetch passes the declared category id through untouched', () async {
    final repository = _TopicRepository()
      ..categoryList = const [
        CatalogCategory.all,
        CatalogCategory('short_play', '真人剧'),
      ]
      ..cachedPages['hongguo|'] = CatalogPage([
        drama('1', category: '都市'),
      ]);
    final catalog = SourceCatalog(repository, SourceSite.byId('hongguo'));
    await catalog.loadCategories();

    final page = await catalog.fetch(catalog.categories.last);
    expect(repository.catalogRequests, ['hongguo|short_play||1']);
    expect([for (final item in page.items) item.id], ['hongguo:p1']);
    expect(page.hasMore, isTrue);
  });

  test('search pages only where the source searches by page', () async {
    final repository = _TopicRepository();
    final huangdou = await SourceCatalog(
      repository,
      const SourceSite('huangdou', '黄豆', '精选短剧'),
    ).search('剧名');
    final hongguo = await SourceCatalog(
      repository,
      SourceSite.byId('hongguo'),
    ).search('剧名', page: 2);
    expect(huangdou.hasMore, isFalse);
    expect(hongguo.hasMore, isTrue);
    expect(repository.catalogRequests, ['huangdou||剧名|1', 'hongguo||剧名|2']);
  });
}
