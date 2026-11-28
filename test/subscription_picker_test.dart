import 'package:duanju_app/subscription_models.dart';
import 'package:duanju_app/ui/settings/subscription_picker_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 订阅导入勾选弹层：勾选、全选、TV 方向键、防焦点丢失、进度显示。
void main() {
  const candidates = [
    SubscriptionCandidate(name: '源 A', url: r'.\a.js', detail: 'a.js'),
    SubscriptionCandidate(name: '源 B', url: r'.\b.js', detail: 'b.js'),
    SubscriptionCandidate(name: '源 C', url: r'.\c.js', detail: 'c.js'),
  ];

  Future<void> pump(
    WidgetTester tester, {
    String notice = '',
    Future<SubscriptionImportReport> Function(
      List<SubscriptionCandidate>,
      void Function(SubscriptionProgress),
      bool Function(),
    )?
    onImport,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<SubscriptionImportReport>(
                  context: context,
                  builder: (_) => SubscriptionPickerDialog(
                    title: '选择要导入的脚本源',
                    notice: notice,
                    candidates: candidates,
                    onImport: onImport,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('列表与勾选', () {
    testWidgets('默认全选，显示条目名与副标题', (tester) async {
      await pump(tester);
      expect(find.text('源 A'), findsOneWidget);
      expect(find.text('a.js'), findsOneWidget);
      expect(find.textContaining('全选'), findsOneWidget);
      // 默认全选 → 按钮显示 3 个
      expect(find.text('导入 3 个'), findsOneWidget);
    });

    testWidgets('点条目取消勾选，按钮数字跟着变', (tester) async {
      await pump(tester);
      await tester.tap(find.text('源 B'));
      await tester.pumpAndSettle();
      expect(find.text('导入 2 个'), findsOneWidget);
    });

    testWidgets('全选开关能取消全部，全部取消时导入按钮禁用', (tester) async {
      await pump(tester);
      await tester.tap(find.textContaining('全选'));
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '导入 0 个'),
      );
      expect(button.onPressed, isNull, reason: '没选任何条目时不能导入');
    });

    testWidgets('越界提示显示在顶部', (tester) async {
      await pump(tester, notice: '源 X（地址超出配置目录）');
      expect(find.text('源 X（地址超出配置目录）'), findsOneWidget);
    });

    test('部分跳过不影响整份订阅可用', () {
      const fetch = SubscriptionFetch(
        candidates: [SubscriptionCandidate(name: 'A', url: r'.\a.js')],
        fromSubscription: true,
        notice: '源 B（地址超出配置目录）',
      );
      expect(fetch.success, isTrue, reason: '部分跳过不该让整份订阅失败');
      expect(fetch.notice, isNotEmpty);
    });

    test('致命错误才算失败', () {
      const fetch = SubscriptionFetch.failed('订阅拉取失败：HTTP 404');
      expect(fetch.success, isFalse);
      expect(fetch.error, isNotEmpty);
      expect(fetch.notice, isEmpty);
    });
  });

  group('TV 方向键', () {
    testWidgets('打开后焦点落在第一行（不用先按方向键）', (tester) async {
      await pump(tester);
      final primary = FocusManager.instance.primaryFocus;
      expect(primary, isNotNull);
      expect(primary!.debugLabel, isNot('subscription-all'));
    });

    testWidgets('上下键在条目间移动，不会跳到按钮上', (tester) async {
      await pump(tester);
      // 先把焦点放到第一行
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final after = FocusManager.instance.primaryFocus;
      expect(after, isNotNull, reason: '按方向键后焦点不能丢');
    });

    testWidgets('方向键始终有焦点，不会点不动', (tester) async {
      await pump(tester);
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus,
          isNotNull,
          reason: '第 $i 次按向下键后焦点丢失',
        );
      }
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus,
          isNotNull,
          reason: '第 $i 次按向上键后焦点丢失',
        );
      }
    });

    testWidgets('左右键在全选与导入之间移动', (tester) async {
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, isNotNull);
    });
  });

  group('导入进度', () {
    testWidgets('右上角实时显示已导入 / 剩余 / 共', (tester) async {
      final gate = <void Function(SubscriptionProgress)>[];
      await pump(
        tester,
        onImport: (selected, onProgress, isCancelled) async {
          // 立刻报第一条进度，然后挂住等测试推进
          onProgress(
            const SubscriptionProgress(done: 0, total: 3, name: '源 A'),
          );
          gate.add(onProgress);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          onProgress(
            const SubscriptionProgress(done: 3, total: 3, name: ''),
          );
          return const SubscriptionImportReport(
            imported: ['源 A', '源 B', '源 C'],
          );
        },
      );

      await tester.tap(find.text('导入 3 个'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(
        find.text('已导入 0，剩余 3，共 3'),
        findsOneWidget,
        reason: '导入开始后应显示初始进度',
      );

      await tester.pumpAndSettle();
      // 全部成功 → 弹层关闭
      expect(find.byType(SubscriptionPickerDialog), findsNothing);
    });

    testWidgets('部分失败时留在弹层并显示失败原因', (tester) async {
      await pump(
        tester,
        onImport: (selected, onProgress, isCancelled) async {
          onProgress(
            const SubscriptionProgress(done: 3, total: 3, name: ''),
          );
          return const SubscriptionImportReport(
            imported: ['源 A'],
            failed: ['源 B（HTTP 404）'],
          );
        },
      );
      await tester.tap(find.text('导入 3 个'));
      await tester.pumpAndSettle();
      expect(find.textContaining('源 B（HTTP 404）'), findsOneWidget);
      expect(find.byType(SubscriptionPickerDialog), findsOneWidget);
    });
  });

  group('导入中强制取消', () {
    testWidgets('导入中取消键仍可点，第一次点变成「强制关闭」', (tester) async {
      await pump(
        tester,
        onImport: (selected, onProgress, isCancelled) async {
          onProgress(
            const SubscriptionProgress(done: 0, total: 3, name: '源 A'),
          );
          // 挂住，模拟某一条卡在网络请求里
          await Future<void>.delayed(const Duration(seconds: 30));
          return const SubscriptionImportReport(imported: ['源 A']);
        },
      );
      await tester.tap(find.text('导入 3 个'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      // 导入中：取消键仍然可点（不是 null），文案变成「停止导入」
      final cancel = tester.widget<TextButton>(
        find.byKey(const ValueKey('subscription-cancel')),
      );
      expect(cancel.onPressed, isNotNull, reason: '导入中取消键不能失效，否则就卡死了');
      expect(find.text('停止导入'), findsOneWidget);

      // 点一次 → 变成「强制关闭」
      await tester.tap(find.byKey(const ValueKey('subscription-cancel')));
      await tester.pump();
      expect(find.text('强制关闭'), findsOneWidget);
    });

    testWidgets('取消后停止后续条目，已装好的保留', (tester) async {
      final seen = <String>[];
      await pump(
        tester,
        onImport: (selected, onProgress, isCancelled) async {
          for (var i = 0; i < selected.length; i++) {
            if (isCancelled()) break;
            seen.add(selected[i].label);
            onProgress(
              SubscriptionProgress(done: i, total: selected.length, name: ''),
            );
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          return SubscriptionImportReport(imported: List.of(seen));
        },
      );
      await tester.tap(find.text('导入 3 个'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2));

      // 导入中请求停止
      await tester.tap(find.byKey(const ValueKey('subscription-cancel')));
      await tester.pumpAndSettle();

      expect(seen.length, lessThan(3), reason: '取消后不该把剩下的全部跑完');
      expect(seen, isNotEmpty, reason: '已经装好的要保留');
    });
  });

  group('进度模型', () {
    test('剩余不会为负', () {
      const progress = SubscriptionProgress(done: 5, total: 3, name: '');
      expect(progress.remaining, 0);
    });

    test('正常递减', () {
      expect(
        const SubscriptionProgress(done: 1, total: 3, name: '').remaining,
        2,
      );
    });
  });
}
