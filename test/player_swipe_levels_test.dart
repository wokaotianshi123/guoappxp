import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/ui/player/level_drag.dart';
import 'package:duanju_app/ui/player/swipe_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int routeIndex = -1,
  }) async => const PlaybackPlan(
    url: 'https://media.test/a.m3u8',
    session: 's1',
    quality: 1080,
    qualities: [1080],
  );

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

void main() {
  final calls = <String>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('duanju/device'), (
          call,
        ) async {
          calls.add(call.method);
          return switch (call.method) {
            'getBrightness' => 0.5,
            'volume' => 0.5,
            _ => null,
          };
        });
  });

  // 横屏全屏的手势层：左半屏竖滑调亮度、右半屏竖滑调音量。
  // 子层带 onTapUp / onLongPressStart，和真实播放页一致，确认长按识别器
  // 不会把手势从竖滑手里抢走。
  testWidgets('fullscreen swipe controls adjust brightness and volume', (
    tester,
  ) async {
    final store = await openStore();
    final show = drama('show', title: '测试剧');
    final session = PlaybackSession(
      repository: _Repository(),
      store: store,
      detail: dramaDetail(show, count: 2),
      player: FakePlayer(),
      index: 0,
    );
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: SwipeControls(
          session: session,
          levels: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (_) {},
            onLongPressStart: (_) {},
            onLongPressEnd: (_) {},
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
    await tester.pump();

    final rect = tester.getRect(find.byType(SwipeControls));
    await tester.dragFrom(
      Offset(rect.left + rect.width * .2, rect.center.dy),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(calls, contains('setBrightness'));

    calls.clear();
    await tester.dragFrom(
      Offset(rect.left + rect.width * .8, rect.center.dy),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(calls, contains('setVolume'));

    session.dispose();
    await tester.pump();
  });

  // 竖屏两侧窄边：竖滑调节生效，但窄边上的点按仍然穿透到下层（暂停/长按倍速）。
  testWidgets('portrait edge strips adjust levels and keep taps going through', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox.expand(),
              ),
              const Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: LevelDrag(
                  kind: LevelKind.brightness,
                  alignment: Alignment.centerLeft,
                ),
              ),
              const Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: LevelDrag(
                  kind: LevelKind.volume,
                  alignment: Alignment.centerRight,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.dragFrom(const Offset(20, 300), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(calls, contains('setBrightness'));

    calls.clear();
    await tester.dragFrom(
      Offset(size.width - 20, 300),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    expect(calls, contains('setVolume'));

    calls.clear();
    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(calls, isEmpty);
  });
}
