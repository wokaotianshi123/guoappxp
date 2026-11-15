import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/ui/audiobook/audiobook_fanqie.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 记录真实发往核心的书城请求次数。核心里的设备签名请求无法被
/// Dart 侧的 generation 作废旧结果取消，重复切源会越堆越多直到假死。
class _CountingRepository extends FakeRepository {
  var calls = 0;
  final seen = <String>[];

  @override
  Future<Map<String, dynamic>> audiobookHongguoCatalog(
    String category,
    int page,
  ) async {
    calls++;
    seen.add('$category:$page');
    await Future<void>.delayed(const Duration(milliseconds: 30));
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
}

void main() {
  test('同一频道同一页并发调用只发一次请求（单飞）', () async {
    final repository = _CountingRepository();
    final api = FanqieAudiobookApi(repository: repository);
    final results = await Future.wait([
      api.hongguoCatalogPage('listen'),
      api.hongguoCatalogPage('listen'),
      api.hongguoCatalogPage('listen'),
    ]);
    expect(repository.calls, 1, reason: '切书源 / 连点不能打出多个不可取消的设备签名请求');
    expect(repository.seen, ['listen:1']);
    for (final result in results) {
      expect(result.books.length, 2);
    }
  });

  test('两分钟内来回切源命中缓存，核心零新增请求', () async {
    final repository = _CountingRepository();
    final api = FanqieAudiobookApi(repository: repository);
    await api.hongguoCatalogPage('listen');
    expect(repository.calls, 1);
    await api.hongguoCatalogPage('listen');
    await api.hongguoCatalogPage('listen');
    expect(repository.calls, 1);
  });

  test('不同频道与不同页各自独立，不会被单飞误合并', () async {
    final repository = _CountingRepository();
    final api = FanqieAudiobookApi(repository: repository);
    await Future.wait([
      api.hongguoCatalogPage('listen', page: 1),
      api.hongguoCatalogPage('novel', page: 1),
      api.hongguoCatalogPage('listen', page: 2),
    ]);
    expect(repository.calls, 3);
    expect(repository.seen.toSet(), {'listen:1', 'novel:1', 'listen:2'});
  });

  test('页码钳制到 1；没有仓库时返回空页而不是抛错', () async {
    final api = FanqieAudiobookApi();
    final page = await api.hongguoCatalogPage('listen', page: 0);
    expect(page.books, isEmpty);
    expect(page.hasMore, isFalse);
  });
}
