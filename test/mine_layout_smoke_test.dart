import 'package:duanju_app/download_converter.dart';
import 'package:duanju_app/download_overview.dart';
import 'package:duanju_app/merge_queue.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/mine/mine_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 宽屏布局冒烟测试：在多种窗口尺寸下把「我的」页铺开，
/// 只要出现 RenderFlex 布局异常就算失败。
///
/// 这类 bug 的典型表现是整块子树被丢弃（界面只剩一部分内容），
/// 单看某个手机尺寸的测试完全发现不了。
void main() {
  Future<void> pump(WidgetTester tester, Size size, {FormFactor? form}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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

  // 覆盖手机 / 平板 / 小窗口 / 宽窗口 / 超宽，避免只测一个尺寸漏掉分支。
  const sizes = <String, Size>{
    '手机竖屏 390x844': Size(390, 844),
    '手机横屏 844x390': Size(844, 390),
    '平板 1024x1366': Size(1024, 1366),
    '窄窗口 700x1000': Size(700, 1000),
    '宽窗口 1600x1000': Size(1600, 1000),
    '超宽 2560x1440': Size(2560, 1440),
  };

  for (final entry in sizes.entries) {
    testWidgets('「我的」页在 ${entry.key} 下布局正常', (tester) async {
      await pump(tester, entry.value);
      expect(
        tester.takeException(),
        isNull,
        reason: '${entry.key} 下出现布局异常，整块内容可能被丢弃',
      );
      // 关键入口必须真的渲染出来，而不只是「没报错」。
      for (final label in ['直播', '听书', '设置']) {
        expect(find.text(label), findsWidgets, reason: '${entry.key} 缺少入口 $label');
      }
    });
  }

  // 回归：电视模式可以在手机上手动开启。以前 8 个入口固定塞进一行，
  // 390dp 宽时每格只有二十几 dp，图标和标题挤成一团、标题完全看不见。
  for (final size in const [Size(390, 844), Size(844, 390), Size(1920, 1080)]) {
    testWidgets(
      '电视模式 ${size.width.toInt()}x${size.height.toInt()} 下入口不被挤扁',
      (tester) async {
        await pump(tester, size, form: FormFactor.television);
        expect(tester.takeException(), isNull, reason: '电视模式下出现布局异常');
        for (final label in ['直播', '听书', '自定义模块', '网盘与订阅', '设置']) {
          final finder = find.text(label);
          expect(finder, findsWidgets, reason: '电视模式缺少入口 $label');
          final box = finder.evaluate().first.renderObject as RenderBox;
          expect(
            box.size.width,
            greaterThan(80),
            reason: '入口「$label」标题只剩 ${box.size.width}dp 宽，被挤成一团',
          );
        }
      },
    );
  }
}
