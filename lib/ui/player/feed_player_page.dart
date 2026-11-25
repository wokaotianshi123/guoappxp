import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../app_device.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../playback_session.dart';
import '../app_scope.dart';
import '../downloads/download_actions.dart';
import '../recommend/feed_overlay.dart';
import 'danmaku_overlay.dart';
import 'playback_handle.dart';
import 'playback_sheets.dart';
import 'player_surface.dart';
import 'player_video.dart';
import 'portrait_player_page.dart';
import 'window_fullscreen.dart';

/// 推荐流里的一屏：视频占满整屏，控件全部交给 [FeedOverlay]。
///
/// 与竖屏播放页的区别是不带上下滑切集——切剧由外层的推荐流负责，
/// 这里只管当前这一部剧的播放、选集、全屏、弹幕与设置。
class FeedPlayerPage extends StatefulWidget {
  const FeedPlayerPage({
    super.key,
    required this.store,
    required this.handle,
    this.onOpenDetail,
  });

  final LocalStore store;
  final PlaybackHandle handle;
  final VoidCallback? onOpenDetail;

  @override
  State<FeedPlayerPage> createState() => _FeedPlayerPageState();
}

class _FeedPlayerPageState extends State<FeedPlayerPage> {
  /// 全屏是窗口 / 设备级状态，换一部剧不该退回竖屏，所以放在类上；
  /// [_live] 用来判断最后一屏离开时才复原方向。
  static bool _fullscreen = false;
  static int _live = 0;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Player? _bound;
  int _sheets = 0;

  PlaybackSession get _session => widget.handle.session;

  @override
  void initState() {
    super.initState();
    _live++;
    if (_fullscreen) unawaited(_applyFullscreen(true));
    _session.addListener(_changed);
    _bind();
  }

  @override
  void dispose() {
    _live--;
    _session.removeListener(_changed);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    if (_live <= 0 && _fullscreen) {
      _fullscreen = false;
      unawaited(_applyFullscreen(false));
    }
    super.dispose();
  }

  void _bind() {
    final player = _session.player;
    if (identical(player, _bound)) return;
    _bound = player;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final stream = player.stream;
    for (final changes in [stream.playing, stream.duration, stream.buffering]) {
      _subscriptions.add(changes.listen((_) => _changed()));
    }
  }

  void _changed() {
    _bind();
    if (mounted) setState(() {});
  }

  Future<void> _sheet(WidgetBuilder builder, {bool fitContent = false}) async {
    setState(() => _sheets++);
    try {
      await showPlayerSheet(
        context,
        builder,
        fitContent: fitContent,
        barrierColor: Colors.black.withValues(alpha: .35),
      );
    } finally {
      if (mounted) setState(() => _sheets--);
    }
  }

  Future<void> _openEpisodes({int tab = 0}) => _sheet(
    (_) => EpisodeSheet(
      session: _session,
      store: widget.store,
      initialTab: tab,
      onSeasons: () => unawaited(_openSeasons()),
      canDownload:
          AppScope.of(context).repository.supportsDownloads &&
          widget.store.canDownload,
      onDownload: (indexes) => unawaited(
        downloadEpisodes(context, widget.store, _session.detail, [
          for (final index in indexes) _session.detail.episodes[index],
        ]),
      ),
    ),
  );

  Future<void> _openSeasons() async {
    DramaSeason? picked;
    await _sheet(
      fitContent: true,
      (_) => SeasonSheet(
        session: _session,
        onSeason: (season) => picked = season,
      ),
    );
    if (!mounted) return;
    if (picked case final season?) {
      if (!await _session.playSeason(season) && mounted) {
        _say('${season.label}切换失败，请稍后重试');
      }
    } else {
      await _openEpisodes();
    }
  }

  Future<void> _openSettings() => _sheet(
    (_) => PlaybackSettings(session: _session, onFailure: _saveFailed),
  );

  void _saveFailed() {
    if (mounted) _say('播放偏好未能保存，请重试');
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _applyFullscreen(bool full) async {
    if (desktopPlatform) {
      await setWindowFullScreen(full);
      return;
    }
    await AppDevice.setPlayerOrientation(
      full ? PlayerOrientation.landscape : PlayerOrientation.auto,
    );
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    await _applyFullscreen(_fullscreen);
  }

  Future<void> _toggleDanmaku() async {
    if (!_session.danmakuSupported) {
      _say('这个站源没有弹幕');
      return;
    }
    try {
      await _session.toggleDanmaku();
    } catch (_) {
      _saveFailed();
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      await widget.store.toggleFavorite(_session.detail.drama);
    } catch (_) {
      if (mounted) _say('追剧状态未能保存');
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final drama = session.detail.drama;
    final dark = playerTheme(context);
    return Theme(
      data: dark,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (session.ready)
              PlayerVideo(
                key: ValueKey(session.player),
                handle: widget.handle,
                player: session.player,
                fit: session.videoFit,
              )
            else if (session.error case final error?)
              PlaybackFailure(session: session, error: error)
            else
              PlaybackLoading(session: session),
            if (session.danmakuSupported)
              DanmakuOverlay(
                controller: session.danmaku,
                video: session.videoSize,
                fit: session.videoFit,
                style: session.danmakuStyle,
              ),
            if (_sheets > 0)
              const IgnorePointer(child: ColoredBox(color: Colors.black38)),
            if (session.error == null)
              PlaybackProgressBuilder(
                player: session.player,
                builder: (context) => FeedOverlay(
                  position: session.player.state.position,
                  duration: session.player.state.duration,
                  buffer: session.player.state.buffer,
                  title: drama.title,
                  episodeText:
                      '第 ${session.episode.number} 集 · 共 ${session.detail.episodes.length} 集',
                  description: drama.description,
                  sourceName: SourceSite.byId(drama.source).name,
                  playing: session.player.state.playing,
                  enabled: session.ready,
                  following: widget.store.following(drama.id) != null,
                  danmakuEnabled: session.danmakuEnabled,
                  danmakuSupported: session.danmakuSupported,
                  fullscreen: _fullscreen,
                  onTogglePlayback: session.togglePlayback,
                  onSeek: (target) => unawaited(session.seekTo(target)),
                  onFavorite: () => unawaited(_toggleFavorite()),
                  onEpisodes: () => unawaited(_openEpisodes()),
                  onIntro: () => unawaited(_openEpisodes(tab: 1)),
                  onFullscreen: () => unawaited(_toggleFullscreen()),
                  onDanmaku: () => unawaited(_toggleDanmaku()),
                  onDetail: () => widget.onOpenDetail?.call(),
                  onSettings: () => unawaited(_openSettings()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
