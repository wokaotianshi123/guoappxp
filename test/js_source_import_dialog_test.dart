import 'package:duanju_app/js_source/js_source_presets.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/js_source_import_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('内置订阅包含「小果」订阅地址', () {
    final preset = findPresetSubscription('xiaoguo');
    expect(preset, isNotNull);
    expect(preset!.name, '小果');
    expect(
      preset.url,
      'https://cfkua.wokaotianshi.eu.org/https://raw.githubusercontent.com/'
      'wokaotianshi123/config/refs/heads/main/xiaoguojs/xiaoguo.json',
    );
  });

  testWidgets('从网址导入默认空输入框，点「小果」后才回填并可导入', (tester) async {
    String? imported;
    await tester.pumpWidget(
      AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.phone,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  imported = await showDialog<String>(
                    context: context,
                    builder: (_) => const JsSourceImportDialog(),
                  );
                },
                child: const Text('打开导入'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('js-subscription-url')),
    );
    expect(field.controller!.text, isEmpty, reason: '默认不能预填订阅地址');

    await tester.tap(find.byKey(const ValueKey('js-subscription-xiaoguo')));
    await tester.pumpAndSettle();
    final url = findPresetSubscription('xiaoguo')!.url;
    expect(field.controller!.text, url);

    await tester.tap(find.byKey(const ValueKey('js-subscription-import')));
    await tester.pumpAndSettle();
    expect(imported, url);
  });
}
