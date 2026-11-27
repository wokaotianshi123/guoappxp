import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/follow/follow_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required FormFactor form,
    Size size = const Size(360, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = await openStore();
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          repository: FakeRepository(),
          formFactor: form,
          child: FollowPage(
            store: store,
            entryFocus: FocusNode(),
            onExitUp: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('手机窄屏用顶部两段切换，内容不再被 92px 竖栏挤占 (#19)', (tester) async {
    await pump(tester, form: FormFactor.phone);

    expect(
      find.byKey(const ValueKey('library-tabs')),
      findsOneWidget,
      reason: '手机端应出现顶部切换',
    );
    expect(find.byKey(const ValueKey('library-tab-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-tab-1')), findsOneWidget);

    // 竖栏不再渲染，列表宽度应接近整屏，而不是 360 - 92。
    expect(find.byKey(const ValueKey('library-追剧')), findsNothing);
    final scroll = tester.getSize(find.byType(CustomScrollView).first);
    expect(scroll.width, greaterThan(330));

    await tester.tap(find.byKey(const ValueKey('library-tab-1')));
    await tester.pumpAndSettle();

    expect(find.text('观看记录'), findsWidgets);
    expect(find.text('清空'), findsOneWidget, reason: '历史页自己的清空入口要保留');

    await tester.tap(find.byKey(const ValueKey('library-tab-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('我的追剧'), findsOneWidget);
  });

  testWidgets('平板 / 桌面仍保留左侧竖栏', (tester) async {
    await pump(tester, form: FormFactor.pad, size: const Size(1024, 1366));

    expect(find.byKey(const ValueKey('library-tabs')), findsNothing);
    expect(find.byKey(const ValueKey('library-追剧')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-历史记录')), findsOneWidget);
  });
}
