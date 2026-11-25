import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _RouteRepository extends FakeRepository {
  final requests = <int>[];
  var _sessions = 0;

  PlaybackPlan _plan(int route) {
    _sessions++;
    return PlaybackPlan(
      url: 'https://media.test/$_sessions.m3u8',
      session: 'session-$_sessions',
      routeIndex: route,
      routeCount: 3,
      quality: 1080,
      qualities: const [1080],
    );
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int routeIndex = -1,
  }) async => _plan(0);

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      _plan(current.routeIndex + 1);

  @override
  Future<PlaybackPlan> selectRoute(PlaybackPlan current, int route) async {
    requests.add(route);
    return _plan(route);
  }

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => null;

  @override
  Future<void> release(String session) async {}
}

Future<(PlaybackSession, FakePlayer, _RouteRepository)> _open() async {
  final store = await openStore();
  final repository = _RouteRepository();
  final player = FakePlayer();
  final session = PlaybackSession(
    repository: repository,
    store: store,
    detail: dramaDetail(drama('show', title: '测试剧'), count: 3),
    player: player,
    index: 0,
  );
  await pumpEventQueue();
  return (session, player, repository);
}

void main() {
  test('切线路会按线路下标重新解析并打开新的播放地址', () async {
    final (session, player, repository) = await _open();
    addTearDown(session.dispose);
    expect(session.routeIndex, 0);
    expect(session.routeCount, 3);
    expect(session.hasRoutes, isTrue);
    expect(session.routeLabel, '线路 1/3');
    final first = player.opened.last;

    await session.selectRoute(2);
    await pumpEventQueue();

    expect(repository.requests, [2]);
    expect(session.routeIndex, 2);
    expect(session.routeLabel, '线路 3/3');
    expect(player.opened.last.uri, isNot(first.uri));
    expect(session.switchingRoute, isFalse);
    expect(session.error, isNull);
  });

  test('重复选当前线路、越界线路都不发请求', () async {
    final (session, _, repository) = await _open();
    addTearDown(session.dispose);

    await session.selectRoute(0);
    await session.selectRoute(-1);
    await session.selectRoute(3);
    await pumpEventQueue();

    expect(repository.requests, isEmpty);
    expect(session.routeIndex, 0);
  });
}
