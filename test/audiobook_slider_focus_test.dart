import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 听书进度条的焦点陷阱。
///
/// 根因（已实测确认）：Slider 在默认的 traditional 导航模式下把上下左右**四个**
/// 键全绑给了 _AdjustSliderIntent（flutter/src/material/slider.dart 的
/// _traditionalNavShortcutMap）。焦点一旦落进进度条，按上键只会把进度从 5 改成
/// 5.5，焦点再也出不来——这就是「焦点误入进度条后无法逃逸」。
///
/// 改用 NavigationMode.directional 后，Slider 只吃左右键
/// （_directionalNavShortcutMap），上下键交回焦点遍历。
void main() {
  /// 让 Slider 真正拿到焦点。注意 tap 不行：Slider 的焦点节点在它内部，
  /// 点击不会把 primaryFocus 移过去（实测 primaryFocus 仍是 FocusScope）。
  Future<List<double>> focusSlider(
    WidgetTester tester, {
    required NavigationMode mode,
  }) async {
    final values = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                const Text('上方'),
                MediaQuery(
                  data: MediaQuery.of(context).copyWith(navigationMode: mode),
                  child: Slider(value: 5, max: 10, onChanged: values.add),
                ),
                const Text('下方'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 取 Slider 内部那个真正可聚焦的节点。
    final nodes = find
        .descendant(of: find.byType(Slider), matching: find.byType(Focus))
        .evaluate()
        .map((element) => (element.widget as Focus).focusNode)
        .whereType<FocusNode>()
        .where((node) => node.canRequestFocus)
        .toList();
    expect(nodes, hasLength(1), reason: 'Slider 内应当正好有一个可聚焦节点');
    nodes.single.requestFocus();
    // 不能 pumpAndSettle：Slider 获得焦点会启动 value indicator 的
    // interactionTimer，界面永远不静止，pumpAndSettle 会挂到超时。
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      same(nodes.single),
      reason: '焦点必须真的落在进度条上，否则这个测试没有意义',
    );
    return values;
  }

  testWidgets('方向导航模式下上下键不被进度条吃掉', (tester) async {
    final values = await focusSlider(tester, mode: NavigationMode.directional);

    // 左右键仍然调进度——键盘没失效。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(values, isNotEmpty, reason: '右键应当调整进度');

    // 上下键必须不被消费，交给焦点遍历才能逃出去。
    final afterRight = values.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(values.length, afterRight, reason: '上键不该被进度条吃掉，否则焦点逃不出去');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(values.length, afterRight, reason: '下键不该被进度条吃掉');
  });

  testWidgets('传统导航模式下上下键确实会吃掉焦点（原 bug）', (tester) async {
    final values = await focusSlider(tester, mode: NavigationMode.traditional);

    final before = values.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      values.length,
      greaterThan(before),
      reason: '默认模式下上键会改进度——这正是焦点被困住的原因',
    );
  });
}
