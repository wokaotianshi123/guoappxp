import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/widgets/category_tabs.dart';
import 'package:duanju_app/ui/widgets/choice_panel.dart';

import 'support/fakes.dart';

Widget _host(Widget child) => AppScope(
  repository: FakeRepository(),
  formFactor: FormFactor.window,
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  testWidgets('默认行为不变：分类条不溢出时不显示「全部分类」', (tester) async {
    await tester.pumpWidget(
      _host(
        CategoryTabs<String>(
          options: const [
            ChoiceOption('a', '全部'),
            ChoiceOption('b', '都市'),
          ],
          selected: 'a',
          onSelected: (_) {},
          onShowAll: (_) {},
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('全部分类'), findsNothing);
  });

  testWidgets('默认行为不变：分类条溢出时显示「全部分类」', (tester) async {
    await tester.pumpWidget(
      _host(
        CategoryTabs<String>(
          options: [
            for (var index = 0; index < 30; index++)
              ChoiceOption('c$index', '分类$index'),
          ],
          selected: 'c0',
          onSelected: (_) {},
          onShowAll: (_) {},
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('全部分类'), findsOneWidget);
  });

  testWidgets('alwaysShowAll：分类很少时入口也常驻，点击能打开面板', (tester) async {
    var showAll = 0;
    var selected = '';
    await tester.pumpWidget(
      _host(
        CategoryTabs<String>(
          options: const [
            ChoiceOption('a', '全部'),
            ChoiceOption('b', '都市'),
            ChoiceOption('c', '悬疑'),
          ],
          selected: 'a',
          onSelected: (value) => selected = value,
          onShowAll: (_) => showAll++,
          alwaysShowAll: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('全部分类'), findsOneWidget);

    await tester.tap(find.byTooltip('全部分类'));
    await tester.pump();
    expect(showAll, 1);

    await tester.tap(find.text('悬疑'));
    await tester.pump();
    expect(selected, 'c');
  });

  testWidgets('选中很靠后的分类时，横向分类条会自动跟随滚动', (tester) async {
    final options = [
      for (var index = 0; index < 30; index++)
        ChoiceOption('c$index', '分类$index'),
    ];
    var selected = 'c0';
    late StateSetter rebuild;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return CategoryTabs<String>(
              options: options,
              selected: selected,
              onSelected: (_) {},
              alwaysShowAll: true,
            );
          },
        ),
      ),
    );
    await tester.pump();

    ScrollableState scrollable() => tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(CategoryTabs<String>),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable().position.maxScrollExtent, greaterThan(0));
    expect(scrollable().position.pixels, 0);

    // 模拟从「全部分类」面板里选了列表末尾的分类。
    rebuild(() => selected = 'c27');
    await tester.pump();
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(scrollable().position.pixels, greaterThan(0));
  });
}
