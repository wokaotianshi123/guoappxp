import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/ui/player/player_lock.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Stack(children: [child])),
);

void main() {
  testWidgets('locked overlay shows one unlock button per alignment', (
    tester,
  ) async {
    var unlocks = 0;
    await tester.pumpWidget(
      _host(
        PlayerLockOverlay(
          locked: true,
          alignments: const [Alignment.centerLeft, Alignment.centerRight],
          padding: const EdgeInsets.symmetric(horizontal: 20),
          onUnlock: () => unlocks++,
          onBlocked: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 横屏锁定后左右两侧中部都要能解锁。
    expect(find.byIcon(Icons.lock_rounded), findsNWidgets(2));

    final buttons = find.byType(PlayerLockButton);
    expect(buttons, findsNWidgets(2));

    final left = tester.getCenter(buttons.at(0));
    final width = tester.getSize(find.byType(PlayerLockOverlay)).width;
    expect(left.dx, lessThan(width * .25));
    expect(tester.getCenter(buttons.at(1)).dx, greaterThan(width * .75));

    for (final finder in [buttons.at(0), buttons.at(1)]) {
      await tester.tap(finder);
      await tester.pump();
    }
    expect(unlocks, 2);
  });

  testWidgets('unlocked overlay renders nothing', (tester) async {
    await tester.pumpWidget(
      _host(
        PlayerLockOverlay(
          locked: false,
          alignments: const [Alignment.centerLeft],
          onUnlock: () {},
          onBlocked: () {},
        ),
      ),
    );
    expect(find.byIcon(Icons.lock_rounded), findsNothing);
  });
}
