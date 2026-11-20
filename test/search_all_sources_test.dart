import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/search/search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/source_fixture.dart';

/// 搜索页「全部源」必须把每一个可见站源都带上——内置源、模块安装的源、
/// 以及用户自己加的 XBPQ / MacCMS 自定义源。少带一类就会表现为
/// 「某个源明明开着，搜索却永远搜不到它的内容」。
void main() {
  testWidgets('全部源覆盖可见模块与自定义源', (tester) async {
    installSourceFixture();
    final store = await openStore();
    await store.syncCustomSources([
      CustomSourceSite(
        id: 'custom:demo',
        name: '自定义示例',
        base: 'https://demo.example.com',
        rule: '{}',
      ),
    ]);

    final repository = FakeRepository();
    await tester.pumpWidget(
      AppScope(
        repository: repository,
        formFactor: FormFactor.phone,
        child: MaterialApp(
          home: SearchPage(store: store, source: store.sources.first),
        ),
      ),
    );
    await tester.pump();

    // 勾上「全部源」。
    await tester.tap(find.text('全部源'));
    await tester.pump();

    // 输入关键词并提交。
    await tester.enterText(find.byType(TextField).first, '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(repository.searchRequests, isNotEmpty, reason: '没有发起跨源搜索');
    final sent = repository.searchRequests.last.sources;

    // 期望集合：本地存储里所有可见站源（含模块源与自定义源）。
    final expected = store.sources.map((site) => site.id).toSet();
    expect(
      sent.toSet(),
      expected,
      reason: '跨源搜索没有覆盖全部可见站源',
    );

    // 明确校验两类来源都在里面。
    expect(sent, contains('custom:demo'), reason: '缺少自定义源');
    expect(
      sent.any((id) => !SourceSite.isCustomId(id) && id.isNotEmpty),
      isTrue,
      reason: '缺少内置/模块源',
    );
  });
}
