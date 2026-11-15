import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/ui/audiobook/audiobook_fanqie.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 分别记录「按需分页」与「全量书池」两个 action 的调用，用来验证
/// 红果听书不会在点开书源时触发会启动后台全量翻页的 pool 接口。
class _LazyLoadRepository extends FakeRepository {
  final catalogPages = <int>[];
  final catalogCategories = <String>[];
  var poolCalls = 0;

  @override
  Future<Map<String, dynamic>> audiobookHongguoCatalog(
    String category,
    int page,
  ) async {
    catalogCategories.add(category);
    catalogPages.add(page);
    return <String, dynamic>{
      'books': <Map<String, dynamic>>[
        for (var index = 1; index <= 2; index++)
          <String, dynamic>{
            'id': '${category}_${page}_$index',
            'title': '$category 第 $page 页 $index',
            'author': '主播',
            'category': '都市',
          },
      ],
      'hasMore': page < 3,
      'origin': 'hongguo',
    };
  }

  @override
  Future<Map<String, dynamic>> audiobookHongguoPool(
    String category, {
    int since = 0,
  }) async {
    poolCalls++;
    return <String, dynamic>{
      'books': <dynamic>[],
      'loading': false,
      'total': 0,
      'origin': 'hongguo',
    };
  }
}

void main() {
  test('按需分页只取当前页，不触发全量书池后台抓取', () async {
    final repository = _LazyLoadRepository();
    final api = FanqieAudiobookApi(repository: repository);

    final first = await api.hongguoCatalogPage('listen');
    expect(first.books, hasLength(2));
    expect(first.books.first.id, 'hg:listen_1_1');
    expect(first.books.first.isHongguo, isTrue);
    expect(first.hasMore, isTrue);
    expect(repository.catalogPages, [1]);
    expect(repository.catalogCategories, ['listen']);
    // 关键：按需加载不能触发会启动后台全量翻页的 pool action。
    expect(repository.poolCalls, 0);

    final last = await api.hongguoCatalogPage('listen', page: 3);
    expect(last.hasMore, isFalse);
    expect(repository.catalogPages, [1, 3]);
    expect(repository.poolCalls, 0);
  });

  test('页码钳制到 1；没有仓库时返回空页而不是抛错', () async {
    final repository = _LazyLoadRepository();
    final api = FanqieAudiobookApi(repository: repository);

    final clamped = await api.hongguoCatalogPage('novel', page: 0);
    expect(clamped.books, hasLength(2));
    expect(repository.catalogPages, [1]);

    final offline = FanqieAudiobookApi();
    final empty = await offline.hongguoCatalogPage('listen');
    expect(empty.books, isEmpty);
    expect(empty.hasMore, isFalse);
  });

  test('连续多页按 book_id 去重，且不走全量书池', () async {
    final repository = _LazyLoadRepository();
    final api = FanqieAudiobookApi(repository: repository);

    final books = await api.hongguoCatalog('listen', pages: 2);
    expect(books, hasLength(4));
    expect(books.map((book) => book.id).toSet(), hasLength(4));
    expect(repository.catalogPages, [1, 2]);
    expect(repository.poolCalls, 0);
  });
}
