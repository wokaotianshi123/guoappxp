import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/ui/player/episode_grid.dart';
import 'package:duanju_app/ui/player/playback_details_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  var _sessions = 0;

  PlaybackPlan _plan() {
    _sessions++;
    return PlaybackPlan(
      url: 'https://media.test/$_sessions.m3u8',
      session: 'session-$_sessions',
      routeIndex: 0,
      routeCount: 1,
      quality: 1080,
      qualities: const [1080, 720],
    );
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int route = 0,
  }) async => _plan();

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
    bool adBlock = true,
    int route = 0,
  }) async => _plan();
}

Drama _drama(String description) => Drama(
  id: 'hongguo:portrait',
  source: 'hongguo',
  title: '竖屏测试剧',
  description: description,
  category: '都市',
);

/// PlaybackSession 带着两个 periodic Timer，widget test 在测试体结束时会检查
/// pending timers，所以必须在测试体内部（而非 tearDown 里）dispose。
Future<void> _scenario(
  WidgetTester tester, {
  required String description,
  required Future<void> Function() body,
  int initialTab = 0,
  bool canDownload = false,
}) async {
  final store = await openStore();
  final session = PlaybackSession(
    repository: _Repository(),
    store: store,
    detail: dramaDetail(_drama(description), count: 3),
    player: FakePlayer(),
    standby: FakePlayer(),
    index: 0,
    autoplay: false,
  );
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.blue,
          brightness: Brightness.dark,
        ),
        home: Scaffold(
          body: PlaybackDetailsSheet(
            session: session,
            store: store,
            canDownload: canDownload,
            onDownload: (_) {},
            initialTab: initialTab,
          ),
        ),
      ),
    );
    await body();
  } finally {
    session.dispose();
  }
}

void main() {
  testWidgets('竖屏面板默认仍是选集，简介只在切换页签后出现', (tester) async {
    await _scenario(
      tester,
      description: '竖屏剧情简介内容',
      body: () async {
        // 打开面板后默认也不是简介，播放画面上更不会常驻剧集详情。
        expect(find.byType(EpisodeGrid), findsOneWidget);
        expect(find.text('竖屏剧情简介内容'), findsNothing);

        await tester.tap(find.text('简介'));
        await tester.pump();
        expect(find.text('竖屏剧情简介内容'), findsOneWidget);
        expect(find.textContaining('共 3 集 · 都市'), findsOneWidget);
        expect(find.byType(EpisodeGrid), findsNothing);

        await tester.tap(find.text('选集'));
        await tester.pump();
        expect(find.byType(EpisodeGrid), findsOneWidget);
      },
    );
  });

  testWidgets('没有简介数据时显示「暂无简介」', (tester) async {
    await _scenario(
      tester,
      description: '',
      initialTab: 1,
      body: () async {
        expect(find.text('暂无简介'), findsOneWidget);
      },
    );
  });

  testWidgets('指定初始页签时可以直接打开简介', (tester) async {
    await _scenario(
      tester,
      description: '直接打开的简介',
      initialTab: 1,
      body: () async {
        expect(find.text('直接打开的简介'), findsOneWidget);
        expect(find.byType(EpisodeGrid), findsNothing);
      },
    );
  });

  testWidgets('下载多选入口只属于选集页，切到简介不会残留', (tester) async {
    await _scenario(
      tester,
      description: '简介内容',
      canDownload: true,
      body: () async {
        expect(find.byTooltip('下载选集'), findsOneWidget);
        await tester.tap(find.text('简介'));
        await tester.pump();
        expect(find.byTooltip('下载选集'), findsNothing);
        await tester.tap(find.text('选集'));
        await tester.pump();
        expect(find.byTooltip('下载选集'), findsOneWidget);
      },
    );
  });
}
