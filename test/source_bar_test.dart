import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/widgets/source_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> _pump(
  WidgetTester tester,
  FormFactor form, {
  VoidCallback? onSearch,
}) async {
  await tester.pumpWidget(
    AppScope(
      repository: FakeRepository(),
      formFactor: form,
      child: MaterialApp(
        home: Scaffold(
          body: SourceBar(
            source: '测试源',
            onSwitchSource: (_) {},
            onOpenSearch: () => onSearch?.call(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // 主页顶栏在手机 / 平板 / Windows 窗口下要完全一致：标题 + 切换站源 + 搜索按钮。
  // 以前平板和窗口塞了一个常驻输入框，占宽还跟另外两端不一样。
  for (final form in [FormFactor.phone, FormFactor.pad, FormFactor.window]) {
    testWidgets('$form 顶栏只有搜索按钮，没有常驻输入框', (tester) async {
      var opened = 0;
      await _pump(tester, form, onSearch: () => opened++);
      expect(find.text('测试源'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.search_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      expect(opened, 1, reason: '点搜索按钮才进入搜索页');
    });
  }

  testWidgets('电视顶栏仍是标题 + 两个按钮', (tester) async {
    var opened = 0;
    await _pump(tester, FormFactor.television, onSearch: () => opened++);
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.byIcon(Icons.public_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });
}
