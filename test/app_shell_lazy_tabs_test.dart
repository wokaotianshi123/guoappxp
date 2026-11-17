import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/follow/follow_page.dart';
import 'package:duanju_app/ui/history/history_page.dart';
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
  AppTab.history => find.byType(HistoryPage),
  AppTab.mine => find.byType(MinePage),
  _ => throw StateError('unexpected tab: $tab'),
};

void main() {
  test('启动默认「发现」时听书页不进树，避免提前加载书池', () {
    final mounted = initialMountedTabs();
    expect(mounted.contains(AppTab.explore), isTrue);
    expect(mounted.contains(AppTab.audiobook), isFalse);
    expect(mounted.length, AppTab.values.length - 1);
  });

  test('切到听书后再切回，挂载集合幂等，不会重建页面重复加载', () {
    final mounted = initialMountedTabs();
    expect(mounted.add(AppTab.audiobook), isTrue);
    final count = mounted.length;
    expect(mounted.add(AppTab.audiobook), isFalse);
    expect(mounted.length, count);
    expect(mounted.contains(AppTab.audiobook), isTrue);
  });

  testWidgets('未访问听书时，追剧 / 历史 / 我的各自显示自己的页面', (
    tester,
  ) async {
    await pumpShell(tester);
    // 回归前提：听书从未被切过去，IndexedStack 的 children 少一个。
    expect(initialMountedTabs().contains(AppTab.audiobook), isFalse);

    // IndexedStack 只把 index 指向的 child 标为 onstage，其余 child 被 Finder
    // 跳过。因此「能找到该页面」等价于「index 没有错位、也没有越界空白」。
    for (final tab in [AppTab.follow, AppTab.history, AppTab.mine]) {
      await selectTab(tester, tab);
      expect(
        pageOf(tab),
        findsOneWidget,
        reason: '切到${tab.label}后应显示对应页面，而不是空白',
      );
      for (final other in [AppTab.follow, AppTab.history, AppTab.mine]) {
        if (other == tab) continue;
        expect(
          pageOf(other),
          findsNothing,
          reason: '切到${tab.label}时不应显示${other.label}的页面',
        );
      }
    }
  });
}
