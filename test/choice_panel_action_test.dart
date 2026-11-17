import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/widgets/choice_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 「管理站源」原来贴在面板底部，手机上正好压在系统返回手势 / 导航条上，
/// 容易误触；现在放到标题栏右上角，这里锁住位置别再掉回底部。
void main() {
  testWidgets('choice panel action sits in the header, above the grid', (
    tester,
  ) async {
    var managed = 0;
    await tester.pumpWidget(
      // AppScope 必须在 MaterialApp 之上（真实 App 里是 MaterialApp.builder），
      // 否则弹层走根 Navigator 的 overlay，拿不到 AppScope，FocusRing 会炸。
      AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.phone,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showChoicePanel<String>(
                    context: context,
                    title: '全部站源',
                    options: const [
                      ChoiceOption('a', '站源甲'),
                      ChoiceOption('b', '站源乙'),
                      ChoiceOption('c', '站源丙'),
                    ],
                    selected: 'a',
                    grid: ChoiceGrid.sources,
                    action: (
                      label: '管理站源',
                      icon: Icons.tune_rounded,
                      onPressed: () => managed++,
                    ),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final action = find.byTooltip('管理站源');
    expect(action, findsOneWidget);

    final actionY = tester.getCenter(action).dy;
    final titleY = tester.getCenter(find.text('全部站源')).dy;
    final gridTop = tester.getTopLeft(find.text('站源甲')).dy;

    // 与标题同一行（右上角），并且明确在站源网格之上。
    expect((actionY - titleY).abs(), lessThan(30));
    expect(actionY, lessThan(gridTop));

    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(managed, 1);
    // 点完顺带把面板关掉，别把用户留在半透明页上。
    expect(find.text('全部站源'), findsNothing);
  });
}
