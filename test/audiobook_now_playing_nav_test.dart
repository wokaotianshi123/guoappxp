import 'dart:io';

import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/audiobook/audiobook_fanqie.dart';
import 'package:duanju_app/ui/audiobook/audiobook_screen.dart';
import 'package:duanju_app/ui/audiobook/audiobook_store.dart';
import 'package:duanju_app/ui/widgets/focus_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  Future<void> pumpBar(WidgetTester tester) async {
    final session = AudiobookSession.instance;
    final previous = (
      book: session.book,
      chapters: session.chapters,
      repository: session.repository,
      api: session.api,
      store: session.store,
    );
    addTearDown(() {
      session.book = previous.book;
      session.chapters = previous.chapters;
      session.repository = previous.repository;
      session.api = previous.api;
      session.store = previous.store;
      session.notifyListeners();
    });
    final directory = Directory.systemTemp.createTempSync('audiobook-nav');
    addTearDown(() => directory.deleteSync(recursive: true));
    session.repository = FakeRepository();
    session.api = FanqieAudiobookApi(repository: FakeRepository());
    session.store = AudiobookStore(directory);
    session.book = const FanqieBook(
      id: 'test-book',
      title: '测试书',
      author: '作者',
      category: '悬疑',
    );
    session.chapters = const [
      FanqieChapter(id: 'c1', title: '第一章', order: 1, locked: false),
    ];
    session.index = 0;
    session.notifyListeners();

    await tester.pumpWidget(
      AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.television,
        child: const MaterialApp(
          home: Scaffold(bottomNavigationBar: AudiobookNowPlayingBar()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('方向键能从标题区走到播放/关闭按钮', (tester) async {
    await pumpBar(tester);

    final play = find.byKey(const ValueKey('audiobook-now-playing-play'));
    final close = find.byKey(const ValueKey('audiobook-now-playing-close'));
    expect(play, findsOneWidget);
    expect(close, findsOneWidget);

    // 从状态栏整体开始，按右键往下走，看能不能停到两个按钮上。
    final visited = <String>{};
    for (var step = 0; step < 8; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus;
      final ctx = focused?.context;
      if (ctx == null) continue;
      if (ctx.widget.key == const ValueKey('audiobook-now-playing-play')) {
        visited.add('play');
      }
      if (ctx.widget.key == const ValueKey('audiobook-now-playing-close')) {
        visited.add('close');
      }
      // 也检查祖先：焦点节点可能落在 IconButton 内部的 InkWell 上。
      if (find
          .descendant(of: play, matching: find.byType(InkWell))
          .evaluate()
          .any((e) => _hasFocus(e))) {
        visited.add('play');
      }
      if (find
          .descendant(of: close, matching: find.byType(InkWell))
          .evaluate()
          .any((e) => _hasFocus(e))) {
        visited.add('close');
      }
    }
    expect(
      visited,
      containsAll(<String>['play', 'close']),
      reason: '方向键必须能停在播放和关闭按钮上，实际到达：$visited',
    );
  });

  testWidgets('两个按钮是同级焦点节点，不再被整条状态栏吞掉', (tester) async {
    await pumpBar(tester);

    // 上一版用 ListTile.onTap 时，它生成的焦点节点覆盖整条 (0,528)-(800,600)，
    // 两个按钮被包在它内部，方向键只会在父节点上打转。这里断言三者的矩形是
    // 并排的、没有互相包含。
    Rect rectOf(String key) {
      final box = tester.renderObject(find.byKey(ValueKey(key)));
      return box is RenderBox
          ? box.localToGlobal(Offset.zero) & box.size
          : Rect.zero;
    }

    final open = rectOf('audiobook-now-playing-open');
    final play = rectOf('audiobook-now-playing-play');
    final close = rectOf('audiobook-now-playing-close');

    expect(open.isEmpty, isFalse);
    expect(play.isEmpty, isFalse);
    expect(close.isEmpty, isFalse);
    // 互不包含：任何一个都不该把另一个整块盖住。
    expect(open.contains(play.center), isFalse, reason: '播放按钮被标题区盖住了');
    expect(open.contains(close.center), isFalse, reason: '关闭按钮被标题区盖住了');
    expect(play.contains(close.center), isFalse);
    // 从左到右依次排开，方向键才有明确的空间顺序。
    expect(open.right, lessThanOrEqualTo(play.left + 1));
    expect(play.right, lessThanOrEqualTo(close.left + 1));
  });
}

bool _hasFocus(Element element) {
  final node = Focus.maybeOf(element);
  return node?.hasFocus ?? false;
}
