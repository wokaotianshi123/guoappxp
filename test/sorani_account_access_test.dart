import 'package:duanju_app/sorani_account.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/sources_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _SoraniRepository extends FakeRepository {
  _SoraniRepository({this.loggedIn = false});
  bool loggedIn;

  @override
  Future<SoraniAccount> soraniAccount() async =>
      SoraniAccount(loggedIn: loggedIn, name: loggedIn ? '测试用户' : '');

  @override
  Future<SoraniAccount> soraniLogout() async {
    loggedIn = false;
    return const SoraniAccount();
  }
}

Widget _host(
  Widget body, {
  required _SoraniRepository repository,
  bool television = false,
}) => AppScope(
  repository: repository,
  formFactor: television ? FormFactor.television : null,
  child: MaterialApp(home: Scaffold(body: body)),
);

FocusNode _tileNode(WidgetTester tester) => tester
    .widget<ListTile>(
      find
          .ancestor(of: find.text('青空账号'), matching: find.byType(ListTile))
          .first,
    )
    .focusNode!;

void main() {
  testWidgets('站源账号页不限制管理员，任何用户都能登录与退出', (tester) async {
    await tester.pumpWidget(
      _host(const SourceAccountsView(), repository: _SoraniRepository()),
    );
    await tester.pumpAndSettle();

    // 页面上不再有「需要管理员」的提示。
    expect(find.textContaining('管理员'), findsNothing);
    expect(find.text('青空账号'), findsOneWidget);
    expect(find.text('未登录。青空目前需要登录后才能播放'), findsOneWidget);

    // 登录按钮与整行都是可用的，不再因非管理员身份被禁用。
    final login = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '登录'),
    );
    expect(login.onPressed, isNotNull);
    final row = tester.widget<ListTile>(
      find
          .ancestor(of: find.text('青空账号'), matching: find.byType(ListTile))
          .first,
    );
    expect(row.onTap, isNotNull);
    expect(row.enabled, isTrue);
  });

  testWidgets('电视进入站源账号页时焦点落在青空账号，退出登录后不丢', (tester) async {
    final repository = _SoraniRepository(loggedIn: true);
    await tester.pumpWidget(
      _host(
        const SourceAccountsView(),
        repository: repository,
        television: true,
      ),
    );
    await tester.pumpAndSettle();

    final node = _tileNode(tester);
    expect(node.hasPrimaryFocus, isTrue, reason: '进入账号页时焦点应直接落在青空账号上');

    await tester.tap(find.widgetWithText(TextButton, '退出登录'));
    await tester.pumpAndSettle();

    expect(find.text('未登录。青空目前需要登录后才能播放'), findsOneWidget);
    expect(_tileNode(tester), same(node), reason: '退出登录不应重建焦点节点');
    expect(node.hasPrimaryFocus, isTrue, reason: '退出登录后焦点仍留在青空账号');
  });
}
