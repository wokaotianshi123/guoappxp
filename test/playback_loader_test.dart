import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_loader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 播放取流的最小替身：可以卡住 resolve，记录取消 / 释放次数，
/// 也可以按顺序返回失败或成功结果。
class _LoaderRepository extends FakeRepository {
  _LoaderRepository(this._plans);

  final List<Object> _plans;
  final started = Completer<void>();
  Completer<void>? gate;
  int resolves = 0;
  int cancels = 0;
  final released = <String>[];

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool adBlock = true,
    int routeIndex = -1,
  }) async {
    final index = resolves++;
    if (!started.isCompleted) started.complete();
    await gate?.future;
    final plan = _plans[index < _plans.length ? index : _plans.length - 1];
    if (plan is Exception) throw plan;
    return plan as PlaybackPlan;
  }

  @override
  Future<void> cancelPlayback() async => cancels++;

  @override
  Future<void> release(String session) async => released.add(session);
}

Episode _episode() => Episode({'currentEpisode': 1, 'title': '第1集'}, 1);

void main() {
  test('关闭旧会话不会再发全局取消，打断新会话 (#18)', () async {
    final plan = const PlaybackPlan(url: 'https://cdn/a.m3u8', session: 's1');
    final repository = _LoaderRepository([plan]);
    repository.gate = Completer<void>();
    final loader = PlaybackLoader(repository);

    final loading = loader.load(drama('a'), _episode());
    await repository.started.future;
    expect(repository.cancels, 1, reason: '开始取流前只取消自己之前那一轮');

    await loader.close();
    // #18 的根因：详情页退场动画结束后才 close，旧 loader 补发的全局取消
    // 会把推荐页刚重建的取流一起打断。close 只能标记自己失效。
    expect(repository.cancels, 1, reason: 'close() 不应该再发全局 cancelPlayback');

    repository.gate!.complete();
    expect(await loading, isNull, reason: '已关闭的 loader 丢弃结果');
    expect(repository.released, ['s1'], reason: '晚到的结果要主动 release');
  });

  test('遇到 context canceled 会自动重试一次', () async {
    final plan = const PlaybackPlan(url: 'https://cdn/a.m3u8', session: 's1');
    final repository = _LoaderRepository([
      AppFailure('context canceled'),
      plan,
    ]);
    final loader = PlaybackLoader(repository);

    final result = await loader.load(drama('a'), _episode());

    expect(repository.resolves, 2);
    expect(result?.session, 's1');
    expect(repository.released, isEmpty);
  });

  test('连续取消时给用户看得懂的提示，不暴露 context canceled', () async {
    final repository = _LoaderRepository([
      AppFailure('context canceled'),
      AppFailure('context canceled'),
    ]);
    final loader = PlaybackLoader(repository);

    await expectLater(
      loader.load(drama('a'), _episode()),
      throwsA(
        isA<AppFailure>()
            .having((error) => error.code, 'code', 'playback_canceled')
            .having(
              (error) => error.message,
              'message',
              isNot(contains('context')),
            ),
      ),
    );
    expect(repository.resolves, 2, reason: '只自动重试一次，避免死循环');
  });
}
