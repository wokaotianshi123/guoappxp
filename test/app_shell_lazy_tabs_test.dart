import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/follow/follow_page.dart';
import 'package:duanju_app/ui/mine/mine_page.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> pumpShell(WidgetTester tester) async {
  final store = await openStore();
  await tester.pumpWidget(
    MaterialApp(
      home: AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.phone,
        child: AppShell(store: store),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> selectTab(WidgetTester tester, AppTab tab) async {
  await tester.tap(find.byKey(ValueKey('nav-${tab.name}')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder pageOf(AppTab tab) => switch (tab) {
  AppTab.follow => find.byType(FollowPage),
  AppTab.mine => find.byType(MinePage),
  _ => throw StateError('unexpected tab: $tab'),
};

void main() {
  test('启动默认「发现」时推荐流不进树，避免提前拉推荐列表', () {
    final mounted = initialMountedTabs();
    expect(mounted.contains(AppTab.explore), isTrue);
    expect(mounted.contains(AppTab.recommend), isFalse);
    expect(mounted.length, AppTab.values.length - 1);
  });

  test('切到推荐后再切回，挂载集合幂等，不会重建页面重复加载', () {
    final mounted = initialMountedTabs();
    expect(mounted.add(AppTab.recommend), isTrue);
    final count = mounted.length;
    expect(mounted.add(AppTab.recommend), isFalse);
    expect(mounted.length, count);
    expect(mounted.contains(AppTab.recommend), isTrue);
  });

  testWidgets('未访问推荐时，追剧 / 我的各自显示自己的页面', (
    tester,
  ) async {
    await pumpShell(tester);
    // 回归前提：推荐从未被切过去，IndexedStack 的 children 少一个。
    expect(initialMountedTabs().contains(AppTab.recommend), isFalse);

    // IndexedStack 只把 index 指向的 child 标为 onstage，其余 child 被 Finder
    // 跳过。因此「能找到该页面」等价于「index 没有错位、也没有越界空白」。
    for (final tab in [AppTab.follow, AppTab.mine]) {
      await selectTab(tester, tab);
      expect(
        pageOf(tab),
        findsOneWidget,
        reason: '切到${tab.label}后应显示对应页面，而不是空白',
      );
      for (final other in [AppTab.follow, AppTab.mine]) {
        if (other == tab) continue;
        expect(
          pageOf(other),
          findsNothing,
          reason: '切到${tab.label}时不应显示${other.label}的页面',
        );
      }
    }
  });

  // 电视端顶部导航默认只有发现 / 追剧 / 我的：推荐流整屏起播，遥控器不好操作，
  // 还要和首屏抢解码器与网络。想用的人在 设置 › 外观 里打开。
  testWidgets('电视端默认不显示推荐标签，打开开关后才出现', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = await openStore();
    expect(store.televisionRecommend, isFalse);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.television,
          child: ListenableBuilder(
            listenable: store,
            builder: (context, _) => AppShell(store: store),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('nav-recommend')), findsNothing);
    for (final tab in [AppTab.explore, AppTab.follow, AppTab.mine]) {
      expect(
        find.byKey(ValueKey('nav-${tab.name}')),
        findsOneWidget,
        reason: '电视端应保留${tab.label}',
      );
    }

    await store.setTelevisionRecommend(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('nav-recommend')), findsOneWidget);
  });
}
