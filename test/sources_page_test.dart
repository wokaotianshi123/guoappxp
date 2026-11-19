import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/modules/modules_page.dart';
import 'package:duanju_app/ui/settings/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// issue #7：模块从「站源 › 模块」拆出来，站源页只剩一页。
/// 这里锁住结构调整后的两个事实：站源页不再套页签、模块页不再被套在里面。
void main() {
  testWidgets('自定义XBPQ 页只有一页，不再有页签', (tester) async {
    // 页面较长（内置站源分好几组），把测试窗口调高，让整页都在树里。
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = await openStore();
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: SourcesPage(store: store),
        ),
      ),
    );
    await tester.pump();

    // 原来这里是「站源与自定义源 / 模块」两个页签，模块页被套在里层。
    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(ModulesPage), findsNothing);
    // AppBar 标题 + 页内分区标题都是「自定义XBPQ」；管理入口在下方，
    // 超出首屏时用 skipOffstage: false 找。
    expect(find.text('自定义XBPQ'), findsWidgets);
    expect(find.text('管理自定义XBPQ'), findsOneWidget);
  });
}
