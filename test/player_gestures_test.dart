import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/ui/player/player_gestures.dart';
import 'package:flutter/gestures.dart';
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

  @override
  Future<void> release(String session) async {}
}

final _show = drama('show', title: '测试剧');

Future<PlayerGestures> _gestures(
  LocalStore store, {
  required bool requireHold,
}) async {
  final session = PlaybackSession(
    repository: _Repository(),
    store: store,
    detail: dramaDetail(_show, count: 3),
    player: FakePlayer(),
    index: 0,
  );
  addTearDown(session.dispose);
  await pumpEventQueue();
  final gestures = PlayerGestures(
    session: session,
    volumeSwipe: false,
    requireHold: requireHold,
  );
  addTearDown(gestures.dispose);
  return gestures;
}

/// 左半屏按下（竖屏播放区 400x800），后续 move 用它记录的手指编号。
void _down(PlayerGestures gestures, {double x = 60, double y = 400}) =>
    gestures.pointerDown(
      PointerDownEvent(position: Offset(x, y), pointer: 1),
      width: 400,
      height: 800,
    );

void _move(PlayerGestures gestures, double y, {double x = 60}) =>
    gestures.pointerMove(
      PointerMoveEvent(position: Offset(x, y), pointer: 1),
    );

void main() {
  test('短促上下滑不调亮度，留给翻页切集', () async {
    final store = await openStore();
    final gestures = await _gestures(store, requireHold: true);

    _down(gestures);
    _move(gestures, 320);
    _move(gestures, 240);

    expect(gestures.hud.type, SwipeAction.none);
  });

  test('长按之后上下滑才调亮度', () async {
    final store = await openStore();
    final gestures = await _gestures(store, requireHold: true);

    _down(gestures);
    gestures.hold();
    _move(gestures, 320);
    _move(gestures, 240);

    expect(gestures.hud.type, SwipeAction.brightness);
    expect(gestures.hud.value, greaterThan(.5));
  });

  test('横屏的拖拽不必长按也调亮度', () async {
    final store = await openStore();
    final gestures = await _gestures(store, requireHold: false);

    _down(gestures);
    _move(gestures, 320);
    _move(gestures, 240);

    expect(gestures.hud.type, SwipeAction.brightness);
    expect(gestures.hud.value, greaterThan(.5));
  });
}
