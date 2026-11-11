import 'dart:io';

import 'package:duanju_app/ui/audiobook/audiobook_download.dart';
import 'package:duanju_app/ui/audiobook/audiobook_fanqie.dart';
import 'package:duanju_app/ui/audiobook/audiobook_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('书架、进度和书签可以重新读出，历史只保留最近 50 本', () async {
    final directory = await Directory.systemTemp.createTemp('audiobook-store');
    addTearDown(() => directory.delete(recursive: true));
    final store = await AudiobookStore.openDirectory(directory);
    const book = FanqieBook(id: 'b', title: '斗破', author: '甲', category: '玄幻');
    const other = FanqieBook(id: 'o', title: '另一本', author: '', category: '');
    const chapter = FanqieChapter(
      id: 'c',
      title: '第一章',
      order: 1,
      locked: false,
    );
    await store.toggleShelf(book);
    await store.toggleShelf(other);
    await store.remember(book, chapter, 12.4, duration: 80);
    await store.addBookmark(book, chapter, 12.4);
    await store.markMissing(book.id, 'x', '没有地址');
    for (var index = 1; index <= 51; index++) {
      await store.remember(
        FanqieBook(id: 'h$index', title: '书$index', author: '', category: ''),
        chapter,
        index.toDouble(),
      );
    }
    final again = await AudiobookStore.openDirectory(directory);
    expect(again.shelf.map((item) => item.id), ['o', 'b']);
    expect(again.heardSeconds(book.id, chapter.id), 12.4);
    expect(again.durationSeconds(book.id, chapter.id), 80);
    expect(again.bookmarks(book.id).single.chapterTitle, '第一章');
    expect(again.missingReason(book.id, 'x'), '没有地址');
    expect(again.history, hasLength(50));
    expect(again.history.first.book.id, 'h51');
    expect(again.history.last.book.id, 'h2');
    expect(again.latest(book.id), isNull);
  });

  test('快进退按秒夹在章节内', () {
    expect(seekAudiobookSeconds(100, 15, 200), 115);
    expect(seekAudiobookSeconds(5, -15, 200), 0);
    expect(seekAudiobookSeconds(190, 15, 200), 200);
    expect(formatAudiobookClock(3661), '1:01:01');
    expect(formatAudiobookClock(0), '00:00');
  });

  test('下载选择跳过已有文件，补齐只重试缺章且不改进度', () async {
    final directory = await Directory.systemTemp.createTemp('audiobook-select');
    addTearDown(() => directory.delete(recursive: true));
    final store = await AudiobookStore.openDirectory(directory);
    const book = FanqieBook(id: 'b', title: '书', author: '', category: '');
    final chapters = [
      for (var order = 1; order <= 4; order++)
        FanqieChapter(
          id: 'c$order',
          title: '第$order章',
          order: order,
          locked: false,
        ),
    ];
    await store.remember(book, chapters[0], 99, duration: 100);
    await store.remember(book, chapters[1], 10, duration: 100);
    final local = store.audioFile(book.id, 'c2');
    await local.parent.create(recursive: true);
    await local.writeAsBytes(const [9]);
    await store.audioFile(book.id, 'c4').writeAsBytes(const [9]);
    await store.markMissing(book.id, 'c2', '失败');
    await store.addBookmark(book, chapters[1], 10);

    List<String> ids(
      String kind, {
      String chapterId = '',
      int from = 0,
      int to = 0,
    }) => [
      for (final chapter in selectAudiobookDownloads(
        chapters: chapters,
        kind: kind,
        bookId: book.id,
        store: store,
        chapterId: chapterId,
        fromOrder: from,
        toOrder: to,
      ))
        chapter.id,
    ];

    expect(ids('single', chapterId: 'c3'), ['c3']);
    expect(ids('single', chapterId: 'c4'), isEmpty);
    expect(ids('range', from: 4, to: 2), ['c3']);
    expect(ids('unfinished'), ['c3']);
    expect(ids('all'), ['c1', 'c3']);
    expect(ids('missing'), ['c2']);
    await store.clearMissing(book.id, 'c2');
    expect(store.heardSeconds(book.id, 'c2'), 10);
    expect(store.bookmarks(book.id).single.seconds, 10);
    expect(store.latest(book.id)?.chapterId, 'c2');
    expect(ids('missing'), isEmpty);
  });

  test('下载写成音频和密钥，失败不留空文件，离线仍用原进度', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/good') {
        request.response.headers.set('Content-Type', 'audio/mp4');
        request.response.add(const [1, 2, 3, 4]);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/empty') {
        await request.response.close();
        return;
      }
      request.response.statusCode = 500;
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp('audiobook-files');
    addTearDown(() => directory.delete(recursive: true));
    final store = await AudiobookStore.openDirectory(directory);
    const book = FanqieBook(id: 'b', title: '书', author: '甲', category: '评书');
    const good = FanqieChapter(
      id: 'good',
      title: '好章',
      order: 1,
      locked: false,
    );
    const bad = FanqieChapter(id: 'bad', title: '坏章', order: 2, locked: false);
    const empty = FanqieChapter(
      id: 'empty',
      title: '空章',
      order: 3,
      locked: false,
    );
    await store.remember(book, good, 42, duration: 100);
    await store.addBookmark(book, good, 42);
    await store.markMissing(book.id, bad.id, '上次失败');
    final report = await downloadAudiobookChapters(
      media: (bookId, chapterId) async => {
        'url': 'http://127.0.0.1:${server.port}/$chapterId',
        'decryptionKey': '00112233445566778899aabbccddeeff',
        'duration': 80,
        'headers': {'User-Agent': 'test'},
      },
      store: store,
      book: book,
      chapters: const [good, bad, empty],
    );
    expect(report.completed, 1);
    expect(report.failed, 2);
    expect(store.audioFile(book.id, good.id).lengthSync(), 4);
    expect(
      store.localKey(book.id, good.id),
      '00112233445566778899aabbccddeeff',
    );
    expect(store.hasLocal(book.id, bad.id), isFalse);
    expect(store.hasLocal(book.id, empty.id), isFalse);
    expect(
      File('${store.audioFile(book.id, bad.id).path}.part').existsSync(),
      isFalse,
    );
    expect(store.missingReason(book.id, bad.id), '下载返回 500');
    expect(store.missingReason(book.id, empty.id), '下载到的音频是空的');
    expect(store.missingReason(book.id, good.id), isNull);
    expect(store.heardSeconds(book.id, good.id), 42);
    expect(store.bookmarks(book.id).single.seconds, 42);
    expect(store.durationSeconds(book.id, good.id), 80);
    final again = await AudiobookStore.openDirectory(directory);
    expect(again.heardSeconds(book.id, good.id), 42);
    expect(again.bookmarks(book.id).single.chapterTitle, '好章');
    expect(again.latest(book.id)?.seconds, 42);
    final target = audiobookOpenTarget(
      store: again,
      bookId: book.id,
      chapterId: good.id,
      remote: {'url': 'https://cdn.example/a.m4a', 'decryptionKey': 'ffff'},
    );
    expect(target.local, isTrue);
    expect(target.url, again.audioFile(book.id, good.id).path);
    expect(target.key, '00112233445566778899aabbccddeeff');
    expect(target.headers, isEmpty);
    final remote = audiobookOpenTarget(
      store: again,
      bookId: book.id,
      chapterId: bad.id,
      remote: {
        'url': 'https://cdn.example/a.m4a',
        'decryptionKey': 'ffff',
        'headers': {'Referer': 'https://novelfm.changdunovel.com/'},
      },
    );
    expect(remote.local, isFalse);
    expect(remote.url, 'https://cdn.example/a.m4a');
    expect(remote.key, 'ffff');
    expect(remote.headers['Referer'], 'https://novelfm.changdunovel.com/');
  });
}
