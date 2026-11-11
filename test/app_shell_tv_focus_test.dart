import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:duanju_app/ui/theme/app_theme.dart';

import 'support/fakes.dart';

Future<LocalStore> openTelevisionShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  final store = await openStore();
  await tester.pumpWidget(
    MaterialApp(
      home: AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.television,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: AppShell(store: store),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return store;
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// 每个标签各是一个带文字的 InkWell，FocusNode 由宿主持有。
List<FocusNode> tabNodes(WidgetTester tester) => [
  for (final label in ['发现', '听书', '追剧', '我的'])
    find
        .ancestor(of: find.text(label), matching: find.byType(InkWell))
        .evaluate()
        .map((element) => element.widget as InkWell)
        .first
        .focusNode!,
];

IconButton button(WidgetTester tester, String tooltip) => find
    .ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton))
    .evaluate()
    .map((element) => element.widget as IconButton)
    .first;

String searchTooltip(LocalStore store) =>
    '在 ${SourceSite.byId(store.source).name} 中搜索';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('电视端实心按钮聚焦时反色，方向键选中一眼可辨', () {
    for (final brightness in Brightness.values) {
      final theme = AppTheme.build(
        const Color(0xFF3366CC),
        brightness,
        television: true,
      );
      final colors = theme.colorScheme;
      final style = theme.filledButtonTheme.style!;
      // 旧的 12% onSurface 叠色在已经是主色底的「播放」上几乎看不出来；
      // 现在聚焦直接反色，非聚焦仍走组件默认（主色底）。
      expect(
        style.backgroundColor!.resolve({WidgetState.focused}),
        colors.onSurface,
      );
      expect(style.backgroundColor!.resolve(<WidgetState>{}), isNull);
      expect(
        style.foregroundColor!.resolve({WidgetState.focused}),
        colors.surface,
      );
      expect(style.side!.resolve({WidgetState.focused})?.width, 2);
      expect(style.side!.resolve(<WidgetState>{}), isNull);
      // 非电视主题不受影响。
      final normal = AppTheme.build(
        const Color(0xFF3366CC),
        brightness,
        television: false,
      );
      expect(normal.filledButtonTheme.style, isNull);
    }
  });

  testWidgets('电视端顶栏切到追剧 / 我的后，源与搜索按钮仍常驻', (tester) async {
    await openTelevisionShell(tester);
    final tabs = tabNodes(tester);
    expect(tabs, hasLength(4));
    tabs.first.requestFocus();
    await tester.pump();

    expect(find.byTooltip('切换站源'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(tabs[1].hasPrimaryFocus, isTrue);
    expect(find.byTooltip('切换站源'), findsOneWidget, reason: '焦点移到追剧后源按钮不能跟着消失');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(tabs[2].hasPrimaryFocus, isTrue);
    expect(find.byTooltip('切换站源'), findsOneWidget, reason: '焦点移到我的后源按钮不能跟着消失');
  });

  testWidgets('电视端顶栏方向键依次经过 发现→听书→追剧→我的→源→搜索', (tester) async {
    final store = await openTelevisionShell(tester);
    final tabs = tabNodes(tester);
    final source = button(tester, '切换站源').focusNode!;
    final search = button(tester, searchTooltip(store)).focusNode!;
    FocusNode? primary() => FocusManager.instance.primaryFocus;
    tabs.first.requestFocus();
    await tester.pump();

    for (final expected in [tabs[1], tabs[2], tabs[3], source, search]) {
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(primary(), expected, reason: '右键应走到顶栏的下一项，而不是跳进内容区');
    }
    // 到达最右端后按键被吃掉，焦点不能掉回内容区。
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(primary(), search);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primary(), source);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primary(), tabs[3]);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(primary(), tabs[2]);
  });

  testWidgets('电视端从内容区按上能回到顶栏，继续左右可达两个按钮', (tester) async {
    final store = await openTelevisionShell(tester);
    final tabs = tabNodes(tester);
    final source = button(tester, '切换站源').focusNode!;
    final search = button(tester, searchTooltip(store)).focusNode!;
    final header = {...tabs, source, search};
    final content = FocusManager.instance.primaryFocus!;
    expect(header.contains(content), isFalse, reason: '测试起点应在内容区');

    // 内容区可能还有分类标签等中间行，连按「上」逐层回到顶栏。
    for (var i = 0; i < 6; i++) {
      if (header.contains(FocusManager.instance.primaryFocus)) break;
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(
      header.contains(FocusManager.instance.primaryFocus),
      isTrue,
      reason: '最上一行继续按上必须回到顶栏',
    );
    // 回到顶栏后，右键仍然能一路走到搜索按钮。
    for (var i = 0; i < 8; i++) {
      if (FocusManager.instance.primaryFocus == search) break;
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(FocusManager.instance.primaryFocus, search);
  });
}
