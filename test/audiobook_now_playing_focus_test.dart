import 'dart:io';

import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/audiobook/audiobook_fanqie.dart';
import 'package:duanju_app/ui/audiobook/audiobook_screen.dart';
import 'package:duanju_app/ui/audiobook/audiobook_store.dart';
import 'package:duanju_app/ui/widgets/focus_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 电视端听书：底部的「正在播放」最小化状态栏里，播放与关闭两个按钮原来只是
/// 裸 IconButton，遥控器遍历不到它们（没有 FocusRing 就没有焦点节点，也画不出
/// 焦点框），按遥控器上下左右永远停不到这两个按钮上。
void main() {
  testWidgets('最小化状态栏的播放/关闭按钮都能拿到焦点', (tester) async {
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

    // 状态栏在 book / chapter / repository / api / store 任一为 null 时直接
    // 返回 SizedBox.shrink()，所以这几项都得给上，否则测的是空壳。
    final directory = Directory.systemTemp.createTempSync('audiobook-focus');
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

    // 状态栏确实渲染出来了，两个按钮都在。
    expect(find.byKey(const ValueKey('audiobook-now-playing')), findsOneWidget);
    final play = find.byKey(const ValueKey('audiobook-now-playing-play'));
    final close = find.byKey(const ValueKey('audiobook-now-playing-close'));
    expect(play, findsOneWidget);
    expect(close, findsOneWidget);

    // 关键断言：两个按钮都包在 FocusRing 里，才可能被遥控器聚焦并画出焦点框。
    // 裸 IconButton 虽然在 Material 里自身可聚焦，但没有 FocusRing 就看不到焦点
    // 框，电视端等于「按了不知道停在哪」。
    expect(
      find.ancestor(of: play, matching: find.byType(FocusRing)),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: close, matching: find.byType(FocusRing)),
      findsOneWidget,
    );

    // 按钮本身必须可点，否则焦点停上去也没用。
    expect(tester.widget<IconButton>(play).onPressed, isNotNull);
    expect(tester.widget<IconButton>(close).onPressed, isNotNull);
  });
}
