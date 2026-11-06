import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/ui/player/playback_handle.dart';
import 'package:duanju_app/ui/player/television_player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  final routes = <int>[];
  var sessions = 0;

  PlaybackPlan _plan({int route = 0}) {
    sessions++;
    return PlaybackPlan(
      url: 'https://media.test/$sessions.m3u8',
      session: 'session-$sessions',
      routeIndex: route,
      routeCount: 3,
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
  }) async => _plan(route: route);

  @override
  Future<PlaybackPlan> selectRoute(PlaybackPlan current, int route) async {
    routes.add(route);
    return _plan(route: route);
  }

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
    bool adBlock = true,
    int route = 0,
  }) async => null;
}

/// widget test 里没有 media_kit 纹理，用替身替换 Video 画面，
/// 这样只需要一个真的 PlaybackSession，不必构造原生 Player。
class _Handle implements PlaybackHandle {
  _Handle(PlaybackSession session) : _session = session;

  PlaybackSession _session;

  // PlaybackHandle 把 session 声明成 late final，接口里也带上隐式 setter。
  @override
  PlaybackSession get session => _session;

  @override
  set session(PlaybackSession value) => _session = value;

  @override
  VideoController video(Player player) => throw UnimplementedError();

  @override
  void dispose() {}
}

final _show = drama('tv', title: '电视测试剧');

Future<void> _scenario(
  WidgetTester tester, {
  required Future<void> Function(PlaybackSession session, _Repository repository)
  body,
}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  final store = await openStore();
  final repository = _Repository();
  final session = PlaybackSession(
    repository: repository,
    store: store,
    detail: dramaDetail(_show, count: 12),
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
        home: TelevisionPlayerPage(
          handle: _Handle(session),
          videoSurface: (_) => const SizedBox.expand(),
        ),
      ),
    );
    await _settle(tester);
    await body(session, repository);
  } finally {
    // 先让页面 dispose 掉自己的隐藏计时器，再关掉会话的两个周期计时器。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    session.dispose();
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

FocusNode _nodeOf(WidgetTester tester, String text) => find
    .ancestor(of: find.text(text), matching: find.byType(InkWell))
    .evaluate()
    .map((element) => element.widget as InkWell)
    .first
    .focusNode!;

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('电视控制条同时提供线路与选集，方向键能依次到达', (tester) async {
    await _scenario(
      tester,
      body: (session, repository) async {
        expect(find.text('选集'), findsOneWidget);
        expect(find.text('线路 1/3'), findsOneWidget);
        expect(find.textContaining('去广告'), findsOneWidget);

        // 初始焦点在播放键：右移依次经过下一集、弹幕、去广告、选集、线路。
        for (var i = 0; i < 4; i++) {
          await _press(tester, LogicalKeyboardKey.arrowRight);
        }
        expect(_nodeOf(tester, '选集').hasPrimaryFocus, isTrue);
        await _press(tester, LogicalKeyboardKey.arrowRight);
        expect(_nodeOf(tester, '线路 1/3').hasPrimaryFocus, isTrue);
      },
    );
  });

  testWidgets('线路菜单列出全部线路并能手动切换', (tester) async {
    await _scenario(
      tester,
      body: (session, repository) async {
        await tester.tap(find.text('线路 1/3'));
        await _settle(tester);
        expect(find.text('线路 1'), findsOneWidget);
        expect(find.text('线路 2'), findsOneWidget);
        expect(find.text('线路 3'), findsOneWidget);

        await tester.tap(find.text('线路 2'));
        await _settle(tester);
        expect(repository.routes, [1]);
        expect(session.routeIndex, 1);
        expect(find.text('线路 2/3'), findsOneWidget);
      },
    );
  });

  testWidgets('选集抽屉列出全部集数，方向键移动并可点选', (tester) async {
    await _scenario(
      tester,
      body: (session, repository) async {
        await tester.tap(find.text('选集'));
        await _settle(tester);
        expect(find.text('共 12 集 · 当前第 1 集'), findsOneWidget);
        expect(find.text('12'), findsOneWidget);
        expect(find.text('1'), findsOneWidget);

        await _press(tester, LogicalKeyboardKey.arrowRight);
        expect(_nodeOf(tester, '2').hasPrimaryFocus, isTrue);
        await _press(tester, LogicalKeyboardKey.arrowDown);
        expect(find.byType(GridView), findsOneWidget);

        await tester.tap(find.text('3'));
        await _settle(tester);
        expect(session.index, 2);
        expect(find.textContaining('共 12 集'), findsNothing);
        expect(find.text('选集'), findsOneWidget);
      },
    );
  });

  testWidgets('短暂失焦不会打断已经开始的播放', (tester) async {
    await _scenario(
      tester,
      body: (session, repository) async {
        session.start(0);
        await _settle(tester);
        expect(session.player.state.playing, isTrue);

        // TV 全屏切换 / 系统弹层只会让 App 瞬间 inactive。
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump(const Duration(milliseconds: 100));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump(const Duration(milliseconds: 700));

        expect(session.player.state.playing, isTrue);
        expect(repository.sessions, 1, reason: '不该重新解析播放地址');

        // 真正长时间进入后台仍然暂停，回到前台再接着播。
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump(const Duration(milliseconds: 700));
        expect(session.player.state.playing, isFalse);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(session.player.state.playing, isTrue);
        expect(repository.sessions, 1);
      },
    );
  });
}
