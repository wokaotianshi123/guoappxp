import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/custom_sources_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _AnalyzeRepository extends FakeRepository {
  _AnalyzeRepository(this.result, {this.failWith});

  final Map<String, dynamic> result;
  final String? failWith;
  final List<String> analyzed = [];

  @override
  Future<Map<String, dynamic>> analyzeCustomSourceSite(String base) async {
    analyzed.add(base);
    if (failWith != null) throw StateError(failWith!);
    return result;
  }
}

const _rule =
    '{"主页url": "https://example.com", '
    '"分类url": "https://example.com/vodtype/{cateId}-{catePg}.html", '
    '"分类": "电影\$1#电视剧\$2"}';

/// 表单弹窗是叠加在列表页上的，所有查找都限定在 AlertDialog 内，
/// 避免底层页面的同名控件干扰断言。
Finder _inDialog(Finder finder) =>
    find.descendant(of: find.byType(AlertDialog), matching: finder);

Future<void> _openNewSourceEditor(
  WidgetTester tester,
  _AnalyzeRepository repository,
) async {
  final store = await openStore();
  await tester.pumpWidget(
    AppScope(
      repository: repository,
      child: MaterialApp(
        home: CustomSourcesPage(repository: repository, store: store),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('新增'));
  await tester.pumpAndSettle();
  expect(find.text('新增自定义源'), findsOneWidget);
}

Future<void> _enterBaseAndAnalyze(WidgetTester tester) async {
  // 表单里第 0 个是源名称、第 1 个是源网址。
  await tester.enterText(
    _inDialog(find.byType(TextField)).at(1),
    'https://example.com',
  );
  await tester.pump();
  await tester.tap(_inDialog(find.widgetWithText(FilledButton, '自动识别规则')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('新增自定义源时可抓 HTML 自动识别并回填规则', (tester) async {
    final repository = _AnalyzeRepository({
      'rule': _rule,
      'name': 'example',
      'base': 'https://example.com',
      'kind': 'web',
      'mode': '规则',
      'notes': ['识别到分类模式（2 个分类）', '列表字段已反推并用分类页实测'],
    });
    await _openNewSourceEditor(tester, repository);

    final analyzeButton = _inDialog(
      find.widgetWithText(FilledButton, '自动识别规则'),
    );
    expect(analyzeButton, findsOneWidget);
    // 没填网址时按钮必须不可用，避免空地址打到核心。
    expect(tester.widget<FilledButton>(analyzeButton).onPressed, isNull);

    await _enterBaseAndAnalyze(tester);

    expect(repository.analyzed, ['https://example.com']);
    expect(find.textContaining('已按网页 HTML 生成规则'), findsOneWidget);
    expect(find.textContaining('识别到分类模式'), findsOneWidget);
    // 规则开关打开后会出现第三个输入框（规则 JSON），且内容已回填。
    final fields = _inDialog(find.byType(TextField)).evaluate().toList();
    expect(fields, hasLength(3));
    final ruleField = tester.widget<TextField>(
      _inDialog(find.byType(TextField)).at(2),
    );
    expect(ruleField.controller?.text, _rule);
    // 名称留空时用核心给出的站点名自动填。
    final nameField = tester.widget<TextField>(
      _inDialog(find.byType(TextField)).at(0),
    );
    expect(nameField.controller?.text, 'example');
  });

  testWidgets('识别不出可靠规则时保留为普通网页源', (tester) async {
    final repository = _AnalyzeRepository({
      'rule': '',
      'name': 'example',
      'base': 'https://example.com',
      'kind': 'web',
      'mode': '网址',
      'notes': ['未识别到分类链接，保留为普通网页源'],
    });
    await _openNewSourceEditor(tester, repository);
    await _enterBaseAndAnalyze(tester);

    expect(find.textContaining('未能识别出可靠规则'), findsOneWidget);
    // 不切到规则模式 = 不新增规则输入框，也不产生空规则。
    expect(_inDialog(find.byType(TextField)), findsNWidgets(2));
    final toggle = tester.widget<SwitchListTile>(
      _inDialog(find.byType(SwitchListTile)),
    );
    expect(toggle.value, isFalse);
  });

  testWidgets('自动识别失败时把错误显示在表单里', (tester) async {
    final repository = _AnalyzeRepository(const {}, failWith: '抓取超时');
    await _openNewSourceEditor(tester, repository);
    await _enterBaseAndAnalyze(tester);

    expect(find.textContaining('自动识别失败'), findsOneWidget);
    expect(find.textContaining('抓取超时'), findsOneWidget);
    // 失败后按钮恢复可用，用户可以重试。
    expect(
      tester
          .widget<FilledButton>(
            _inDialog(find.widgetWithText(FilledButton, '自动识别规则')),
          )
          .onPressed,
      isNotNull,
    );
  });
}
