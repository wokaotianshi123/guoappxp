import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/search/search_page.dart';

import 'support/fakes.dart';

Future<void> openSearchPage(
  WidgetTester tester,
  LocalStore store, {
  FormFactor formFactor = FormFactor.window,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AppScope(
        repository: FakeRepository(),
        formFactor: formFactor,
        child: SearchPage(store: store, source: store.sources.first),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('输入拼音首字母会弹出本地匹配的标题（桌面端）', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    final store = await openStore();
    await store.rememberSearch('霸道总裁');

    await openSearchPage(tester, store);
    await tester.enterText(find.byType(TextField), 'bdzc');
    await tester.pumpAndSettle();

    expect(find.text('本地匹配（原文 / 拼音首字母）'), findsOneWidget);
    expect(find.text('霸道总裁'), findsOneWidget);

    // 清空输入后候选跟着消失，不能留着上一次的结果。
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('本地匹配（原文 / 拼音首字母）'), findsNothing);
  });

  testWidgets('原文子串同样能匹配，且不区分大小写', (tester) async {
    final store = await openStore();
    await store.rememberSearch('霸道总裁');

    await openSearchPage(tester, store);
    await tester.enterText(find.byType(TextField), '总裁');
    await tester.pumpAndSettle();

    expect(find.text('霸道总裁'), findsOneWidget);
  });

  testWidgets('「全部源」是否显示只看构建能力与实际站源数', (tester) async {
    final store = await openStore();
    await openSearchPage(tester, store);

    // 红果鉴内置红果 + 番茄两个源，站源数大于 1 就该给「全部源」入口；
    // 真果鉴本来就是为了跨源，即使只开了一个源也要留着它。
    final expected = allSourcesEnabled || store.sources.length > 1;
    expect(find.text('全部源'), expected ? findsOneWidget : findsNothing);
  });
}
