import 'dart:async';
import 'dart:io';

import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/audiobook/audiobook_fanqie.dart';
import 'package:duanju_app/ui/audiobook/audiobook_pool_snapshot.dart';
import 'package:duanju_app/ui/audiobook/audiobook_screen.dart';
import 'package:duanju_app/ui/audiobook/audiobook_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 把 path_provider 指到临时目录：快照就落在 `<support>/audiobooks/pool` 下。
void _bindSupportDirectory(Directory directory) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => directory.path,
      );
}

/// 首屏请求永远不返回，用来证明「快照命中时不需要等网络」。
class _PendingCatalogRepository extends FakeRepository {
  var calls = 0;

  @override
  Future<Map<String, dynamic>> audiobookHongguoCatalog(
    String category,
    int page,
  ) {
    calls++;
    return Completer<Map<String, dynamic>>().future;
  }
}

/// 让真实文件 I/O 与请求链跑完：快照读取走 dart:io，不在测试的假时钟里，
/// 必须借 runAsync 推进，再 pump 把 setState 的帧刷出来。
Future<void> _settle(WidgetTester tester) async {
  for (var index = 0; index < 20; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('audiobook-pool-snapshot');
    addTearDown(() async {
      if (support.existsSync()) await support.delete(recursive: true);
    });
    _bindSupportDirectory(support);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });

  const listenBook = FanqieBook(
    id: 'hg:1',
    title: '我在精神病院学斩神',
    author: '张三',
    category: '都市高武',
    cover: '',
    intro: '简介',
    anchor: '主播甲',
    board: 0,
    source: 'hongguo',
  );

  test('首屏快照可以原样读回，字段不丢', () async {
    await AudiobookPoolSnapshot.write('listen', const [
      listenBook,
    ], hasMore: true);
    final restored = await AudiobookPoolSnapshot.read('listen');
    expect(restored, isNotNull);
    final book = restored!.books.single;
    expect(book.id, 'hg:1');
    expect(book.title, '我在精神病院学斩神');
    expect(book.author, '张三');
    expect(book.category, '都市高武');
    expect(book.intro, '简介');
    expect(book.anchor, '主播甲');
    expect(book.source, 'hongguo');
    expect(book.isHongguo, isTrue);
    expect(restored.hasMore, isTrue);
  });

  test('两个频道的快照互不覆盖', () async {
    await AudiobookPoolSnapshot.write('listen', const [
      listenBook,
    ], hasMore: true);
    await AudiobookPoolSnapshot.write('novel', const [
      FanqieBook(id: 'hg:2', title: '小说频道', author: '', category: ''),
    ], hasMore: false);
    final listen = await AudiobookPoolSnapshot.read('listen');
    final novel = await AudiobookPoolSnapshot.read('novel');
    expect(listen!.books.single.title, '我在精神病院学斩神');
    expect(novel!.books.single.title, '小说频道');
    expect(listen.hasMore, isTrue);
    expect(novel.hasMore, isFalse);
  });

  test('超过有效期的快照被忽略', () async {
    await AudiobookPoolSnapshot.write('listen', const [
      listenBook,
    ], hasMore: true);
    final file = File(
      '${support.path}${Platform.pathSeparator}audiobooks'
      '${Platform.pathSeparator}pool${Platform.pathSeparator}hongguo-listen.json',
    );
    expect(file.existsSync(), isTrue);
    await file.setLastModified(
      DateTime.now().subtract(
        AudiobookPoolSnapshot.maxAge + const Duration(hours: 1),
      ),
    );
    expect(await AudiobookPoolSnapshot.read('listen'), isNull);
  });

  test('空列表不写入，坏文件当作没有快照', () async {
    await AudiobookPoolSnapshot.write('listen', const [], hasMore: true);
    expect(await AudiobookPoolSnapshot.read('listen'), isNull);

    final directory = Directory(
      '${support.path}${Platform.pathSeparator}audiobooks'
      '${Platform.pathSeparator}pool',
    );
    await directory.create(recursive: true);
    await File(
      '${directory.path}${Platform.pathSeparator}hongguo-novel.json',
    ).writeAsString('{半截 JSON');
    expect(await AudiobookPoolSnapshot.read('novel'), isNull);
  });

  testWidgets('快照命中时先渲染书单，不等首屏请求返回', (tester) async {
    await tester.runAsync(
      () => AudiobookPoolSnapshot.write('listen', const [
        listenBook,
      ], hasMore: true),
    );
    final repository = _PendingCatalogRepository();
    final store = await tester.runAsync(
      () => AudiobookStore.openDirectory(
        Directory('${support.path}${Platform.pathSeparator}store'),
      ),
    );

    await tester.pumpWidget(
      AppScope(
        repository: repository,
        formFactor: FormFactor.window,
        child: MaterialApp(
          home: Scaffold(
            body: AudiobookScreen(
              repository: repository,
              api: FanqieAudiobookApi(repository: repository),
              store: store,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);

    expect(repository.calls, 1, reason: '首屏请求应该已经发出，只是还没回来');
    expect(find.text('我在精神病院学斩神'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('没有快照时才显示加载态并给出时长提示', (tester) async {
    final repository = _PendingCatalogRepository();
    final store = await tester.runAsync(
      () => AudiobookStore.openDirectory(
        Directory('${support.path}${Platform.pathSeparator}store'),
      ),
    );

    await tester.pumpWidget(
      AppScope(
        repository: repository,
        formFactor: FormFactor.window,
        child: MaterialApp(
          home: Scaffold(
            body: AudiobookScreen(
              repository: repository,
              api: FanqieAudiobookApi(repository: repository),
              store: store,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);

    expect(repository.calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('首次打开需要几秒'), findsOneWidget);
  });
}
