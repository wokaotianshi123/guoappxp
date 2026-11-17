import 'dart:ui' show PointerDeviceKind;

import 'package:duanju_app/ui/widgets/focus_ring.dart';
import 'package:duanju_app/ui/widgets/horizontal_scroll_bar.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Issue #5：Windows 端横向栏（直播分类栏、直播源栏、搜索页站源栏）鼠标左键
/// 按住拖不动。根因是 FocusOutlineScrollBehavior 没覆盖 dragDevices，沿用了
/// MaterialScrollBehavior 的默认集合，里面不含 mouse。
void main() {
  test('滚动行为把鼠标算进可拖动设备', () {
    const behavior = FocusOutlineScrollBehavior();
    expect(behavior.dragDevices, contains(PointerDeviceKind.mouse));
    // 原有设备不能丢，否则触屏和触摸板反而坏掉。
    expect(behavior.dragDevices, contains(PointerDeviceKind.touch));
    expect(behavior.dragDevices, contains(PointerDeviceKind.trackpad));
  });

  testWidgets('横向滚动条在桌面端挂上 Scrollbar 且可鼠标拖动', (tester) async {
    // 必须在测试体内部还原：TestWidgetsFlutterBinding 会在 body 结束后立刻检查
    // foundation 调试变量有没有被改动，addTearDown 跑到那时候已经晚了。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              child: HorizontalScrollBar(
                controller: controller,
                child: ListView(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (var index = 0; index < 20; index++)
                      SizedBox(width: 80, child: Text('项目 $index')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 桌面端要有可见的滚动条（thumbVisibility: true 会真的画出来）。
      final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar).first);
      expect(scrollbar.thumbVisibility, isTrue);

      // 鼠标拖动必须能滚动：模拟按住左键横向拖。
      expect(controller.offset, 0);
      await tester.drag(
        find.text('项目 0'),
        const Offset(-120, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('移动端不加滚动条', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HorizontalScrollBar(child: SizedBox(height: 40, width: 40)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Scrollbar), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
