import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/search/search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 站源一多（内置 + 模块 + 自定义），搜索页顶部的站源栏原来用 Wrap 换行往上长，
/// 会把下面的结果区挤成 0 高度，表现为「整页不能上下滑、结果出不来」。
/// 现在固定一行横向滚动，这里锁住高度与结果区可用空间。
void main() {
  testWidgets('many sources keep the results area scrollable', (tester) async {
    final store = await openStore();
    await store.syncCustomSources([
      for (var index = 0; index < 12; index++)
        CustomSourceSite(
          id: 'custom:src$index',
          name: '自定义源$index',
          base: 'https://example$index.com',
          rule: '{}',
        ),
    ]);
    expect(store.sources.length, greaterThan(10));

    await tester.pumpWidget(
      AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.phone,
        child: MaterialApp(
          home: SearchPage(store: store, source: store.sources.last),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final bar = find.byWidgetPredicate(
      (widget) =>
          widget is SingleChildScrollView &&
          widget.scrollDirection == Axis.horizontal,
    );
    expect(bar, findsOneWidget);

    // 一行的高度（chip 约 40 + 上边距 8），绝不能随源数量增长。
    expect(tester.getSize(bar).height, lessThan(70));

    // 站源栏下面是给结果 / 最近搜索留的滚动区，不能被挤没。
    final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final below = screen - tester.getBottomLeft(bar).dy;
    expect(below, greaterThan(200));

    // 站源栏自己能横向滑到最后一个源。
    expect(find.text('自定义源11'), findsOneWidget);
    await tester.drag(bar, const Offset(-600, 0));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
