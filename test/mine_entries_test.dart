import 'package:duanju_app/download_converter.dart';
import 'package:duanju_app/download_overview.dart';
import 'package:duanju_app/merge_queue.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/mine/mine_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 「我的」页的入口顺序与管理员标识是这次改动的核心诉求：
/// 自上而下必须是 最近观看 → 直播 → 听书 → 自定义模块 → 自定义XBPQ →
/// JS 沙箱 → 网盘与订阅 → 下载 → 设置，且不再出现「管理员」字样。
void main() {
  Future<void> pumpMine(WidgetTester tester, {required FormFactor form}) async {
    final store = await openStore();
    final repository = FakeRepository();
    final downloads = DownloadOverview(
      repository,
      store,
      interval: const Duration(hours: 1),
    );
    final converter = DownloadConverter(repository, downloads);
    final merges = MergeQueue(repository);
    addTearDown(downloads.dispose);
    addTearDown(converter.dispose);
    addTearDown(merges.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          repository: repository,
          formFactor: form,
          child: MinePage(
            store: store,
            downloads: downloads,
            converter: converter,
            merges: merges,
            entryFocus: FocusNode(),
            onExitUp: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  const expected = [
    '最近观看',
    '直播',
    '听书',
    '自定义模块',
    '自定义XBPQ',
    'JS 沙箱',
    '网盘与订阅',
    '下载',
    '设置',
  ];

  testWidgets('手机端入口自上而下按指定顺序排列', (tester) async {
    await pumpMine(tester, form: FormFactor.phone);

    for (final label in expected) {
      expect(find.text(label), findsWidgets, reason: '缺少入口：$label');
    }
    // 「最近观看」是上方海报区的小标题，其余是入口卡片；用纵坐标验证真实顺序。
    double topOf(String label) {
      final box =
          find.text(label).evaluate().first.renderObject as RenderBox;
      return box.localToGlobal(Offset.zero).dy;
    }

    final tops = [for (final label in expected) topOf(label)];
    expect(tops, orderedEquals([...tops]..sort()), reason: '入口顺序不对：$tops');
  });

  // 回归：宽屏（Windows / 平板）曾经因为 Row 用了 CrossAxisAlignment.stretch
  // 而整块入口消失——那个方向是无界高度，stretch 会要求 infinity 并触发布局
  // 断言，界面只剩「最近观看」。这里逐个断言入口真的渲染出来了。
  for (final form in [FormFactor.window, FormFactor.pad]) {
    testWidgets('${form.name} 宽屏下所有入口都在', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpMine(tester, form: form);

      for (final label in expected) {
        expect(find.text(label), findsWidgets, reason: '宽屏缺少入口：$label');
      }
      // 布局能正常完成（没有 overflow / 断言）才会走到这里。
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('窄窗口退化为单列，入口仍然齐全', (tester) async {
    tester.view.physicalSize = const Size(700, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpMine(tester, form: FormFactor.window);

    for (final label in expected) {
      expect(find.text(label), findsWidgets, reason: '窄窗口缺少入口：$label');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('不再显示「管理员」标识', (tester) async {
    await pumpMine(tester, form: FormFactor.phone);
    expect(find.textContaining('管理员'), findsNothing);
    expect(find.textContaining('普通用户'), findsNothing);
  });

  testWidgets('听书入口可以打开听书页', (tester) async {
    await pumpMine(tester, form: FormFactor.phone);
    await tester.tap(find.text('听书'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // 页面骨架的标题栏应出现，说明真的进了听书页而不是停在原处。
    expect(find.widgetWithText(AppBar, '听书'), findsOneWidget);
  });
}
