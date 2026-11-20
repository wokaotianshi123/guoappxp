import 'core_bridge.dart';
import 'models.dart';
import 'web_verify.dart';

class PlaybackLoader {
  PlaybackLoader(this.repository);

  final AppRepository repository;
  int _generation = 0;
  bool _closed = false;

  /// 站源把播放地址写成 `browser://<短链>` 时，先在隐藏浏览器里走完验证，
  /// 再把落地地址塞回分集给站源模块取直链。
  Future<Episode> _verified(Episode episode) async {
    final raw = episode.raw;
    final videoUrl = raw['videoUrl'];
    if (videoUrl is! String ||
        !videoUrl.startsWith(WebVerify.marker) ||
        videoUrl.length <= WebVerify.marker.length) {
      return episode;
    }
    final resolved = await WebVerify.instance.resolve(
      videoUrl.substring(WebVerify.marker.length),
    );
    return Episode(
      Map<String, dynamic>.from(raw)
        ..['pageUrl'] = resolved
        ..['videoUrl'] = '',
      episode.number,
    );
  }

  /// 核心回 `verify` 表示这一集要先用浏览器完成验证。
  /// 这里走完验证，把落地地址写回分集的 pageUrl 再解析一次。
  Future<PlaybackPlan> _resolveWithVerify(
    Future<PlaybackPlan> Function(Episode) resolve,
    Episode episode,
  ) async {
    final plan = await resolve(episode);
    if (plan.verify.isEmpty) return plan;
    final landed = await WebVerify.instance.resolve(plan.verify);
    final verified = Episode(
      Map<String, dynamic>.from(episode.raw)
        ..['pageUrl'] = landed
        ..['videoUrl'] = '',
      episode.number,
    );
    return resolve(verified);
  }

  Future<PlaybackPlan?> load(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool localOnly = false,
    bool online = false,
    bool adBlock = true,
  }) => _load(() async {
    if (online) {
      return _resolveWithVerify(
        (item) => repository.resolveOnline(
          drama,
          item,
          quality: quality,
          adBlock: adBlock,
        ),
        await _verified(episode),
      );
    }
    if (localOnly) {
      final plan = await repository.localPlayback(drama, episode);
      if (plan == null || !plan.local) {
        throw AppFailure('本地视频不可用，请重新下载或选择在线播放。', code: 'local_media');
      }
      return plan;
    }
    return _resolveWithVerify(
      (item) => repository.resolve(
        drama,
        item,
        quality: quality,
        adBlock: adBlock,
      ),
      await _verified(episode),
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
