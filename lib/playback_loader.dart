import 'core_bridge.dart';
import 'models.dart';

class PlaybackLoader {
  PlaybackLoader(this.repository);

  final AppRepository repository;
  int _generation = 0;
  bool _closed = false;

  Future<PlaybackPlan?> load(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool localOnly = false,
    bool online = false,
    bool adBlock = true,
    int route = 0,
  }) => _load(() async {
    // 磁力搜索结果会把 magnet:?xt=... 放在分集的 raw 里，直接走 Go 侧
    // 「磁力 → 本机 HTTP 流」，拿到的 PlaybackPlan 与站源取流完全一致，
    // 后面的播放器、弹幕、进度、选集逻辑一行都不用改。
    final magnet = episode.raw['magnet'] as String? ?? '';
    if (magnet.startsWith('magnet:')) {
      return repository.magnetPlay(
        magnet,
        fileIndex: (episode.raw['fileIndex'] as num?)?.toInt() ?? -1,
      );
    }
    if (online) {
      return repository.resolveOnline(
        drama,
        episode,
        quality: quality,
        adBlock: adBlock,
        route: route,
      );
    }
    if (localOnly) {
      final plan = await repository.localPlayback(drama, episode);
      if (plan == null || !plan.local) {
        throw AppFailure('本地视频不可用，请重新下载或选择在线播放。', code: 'local_media');
      }
      return plan;
    }
    return repository.resolve(
      drama,
      episode,
      quality: quality,
      adBlock: adBlock,
      route: route,
    );
  });

  Future<PlaybackPlan?> fallback(PlaybackPlan current) =>
      _load(() => repository.fallback(current));

  Future<PlaybackPlan?> selectRoute(PlaybackPlan current, int route) =>
      _load(() => repository.selectRoute(current, route));

  Future<PlaybackPlan?> use(PlaybackPlan prepared) =>
      _load(() async => prepared);

  Future<PlaybackPlan?> _load(Future<PlaybackPlan> Function() resolve) async {
    if (_closed) {
      return null;
    }
    final generation = ++_generation;
    try {
      await repository.cancelPlayback();
      if (_closed || generation != _generation) {
        return null;
      }
      final plan = await resolve();
      if (_closed || generation != _generation) {
        await repository.release(plan.session);
        return null;
      }
      return plan;
    } catch (_) {
      if (_closed || generation != _generation) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    _generation++;
    await repository.cancelPlayback();
  }
}
