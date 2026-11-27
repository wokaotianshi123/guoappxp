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
    int routeIndex = -1,
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
        routeIndex: routeIndex,
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

  /// 被别的会话顺带取消时，核心回的是内部错误 `context canceled`。
  /// 这种情况网络请求其实没坏，重来一次通常就能拿到流。
  static bool _cancelled(Object error) {
    final text = (error is AppFailure ? error.message : '$error').toLowerCase();
    return text.contains('context canceled') ||
        text.contains('context cancelled') ||
        text.contains('operation was canceled') ||
        text.contains('operation was cancelled');
  }

  Future<PlaybackPlan?> _load(Future<PlaybackPlan> Function() resolve) async {
    if (_closed) {
      return null;
    }
    final generation = ++_generation;
    for (var attempt = 0; ; attempt++) {
      try {
        // 只在第一次发全局取消，重试时直接发新请求：核心的 begin 本身
        // 会顶掉上一轮；重试再 cancel 一次反而可能误伤同时起播的别的会话。
        if (attempt == 0) {
          await repository.cancelPlayback();
          if (_closed || generation != _generation) {
            return null;
          }
        }
        final plan = await resolve();
        if (_closed || generation != _generation) {
          await repository.release(plan.session);
          return null;
        }
        return plan;
      } catch (error) {
        if (_closed || generation != _generation) {
          return null;
        }
        // 别的播放会话退出时可能刚好把这一路也取消掉（例如详情页返回推荐）。
        // 先自动重试一次；再失败就换成用户能看懂的提示，不暴露内部错误。
        if (_cancelled(error)) {
          if (attempt == 0) continue;
          throw AppFailure('播放请求被中断，请重试。', code: 'playback_canceled');
        }
        rethrow;
      }
    }
  }

  /// 关闭时只标记自己失效，不再发全局 `cancelPlayback`。
  ///
  /// 核心的取消是全局的：详情页退场动画结束时才 dispose，如果这时补发一次
  /// 取消，会把推荐页刚重建、正在取流的新会话一起打断（#18）。自己的在途
  /// 请求由 generation 丢弃，结果晚到也会 release。
  Future<void> close() async {
    _closed = true;
    _generation++;
  }
}
