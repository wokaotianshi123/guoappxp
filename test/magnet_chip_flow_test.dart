import 'package:duanju_app/ui/magnet/magnet_chip_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用固定宽度渲染标签流，模拟不同窗口宽度。
Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required List<MagnetChipItem> items,
  int maxLines = 2,
  List<Widget> trailing = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: MagnetChipFlow(
              items: items,
              maxLines: maxLines,
              trailing: trailing,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<MagnetChipItem> _items(
  List<String> labels, {
  int selected = -1,
  List<int>? tapped,
}) => [
  for (var i = 0; i < labels.length; i++)
    MagnetChipItem(
      label: labels[i],
      selected: i == selected,
      onTap: () => tapped?.add(i),
    ),
];

void main() {
  testWidgets('宽窗口里标签一行放得下，不出现「更多」', (tester) async {
    final tapped = <int>[];
    await _pump(
      tester,
      width: 600,
      items: _items(['站一', '站二', '站三'], tapped: tapped),
    );
    for (final label in ['站一', '站二', '站三']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.textContaining('+'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口里按可用宽度分行，放不下的进「更多」并可点选', (tester) async {
    final tapped = <int>[];
    await _pump(
      tester,
      width: 150,
      maxLines: 2,
      items: _items(['站一', '站二', '站三', '站四', '站五', '站六'], tapped: tapped),
    );
    // 150px 一行放不下 6 个，必然出现折叠入口。
    expect(find.textContaining('+'), findsOneWidget);
    // 没有横向滚动容器：标签全部通过换行或折叠安排，不靠横滑。
    expect(find.byType(ListView), findsNothing);

    await tester.tap(find.textContaining('+'));
    await tester.pumpAndSettle();
    // 菜单里列出折叠的标签，点第一个应回调对应索引。
    expect(find.text('站六'), findsWidgets);
    await tester.tap(find.text('站六').last);
    await tester.pumpAndSettle();
    expect(tapped, contains(5));
  });

  testWidgets('选中项被折叠时「更多」直接显示该项名称', (tester) async {
    await _pump(
      tester,
      width: 150,
      maxLines: 1,
      items: _items(['站一', '站二', '站三', '站四'], selected: 3),
    );
    // 选中的「站四」被折叠后，折叠入口改用它自己的名字，不让用户以为选择丢了。
    expect(
      find.ancestor(
        of: find.text('站四'),
        matching: find.byType(PopupMenuButton<int>),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('trailing 与标签一起换行且不溢出', (tester) async {
    await _pump(
      tester,
      width: 200,
      maxLines: 2,
      items: _items(['第一站', '第二站', '第三站']),
      trailing: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Chip(label: Text('仅可达')),
            IconButton(onPressed: () {}, icon: const Icon(Icons.refresh)),
          ],
        ),
      ],
    );
    expect(find.text('仅可达'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
