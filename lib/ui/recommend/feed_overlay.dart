import 'package:flutter/material.dart';

import '../player/player_surface.dart';
import '../widgets/contained_slider.dart';
import '../widgets/focus_ring.dart';

/// 推荐流的沉浸式浮层：左下角是剧名、集数与简介，右侧是竖排操作，
/// 最底下一条进度条。播放器的标准控件全部让位，只留这一套。
class FeedOverlay extends StatefulWidget {
  const FeedOverlay({
    super.key,
    required this.position,
    required this.duration,
    required this.buffer,
    required this.title,
    required this.episodeText,
    required this.description,
    required this.sourceName,
    required this.playing,
    required this.enabled,
    required this.following,
    required this.danmakuEnabled,
    required this.danmakuSupported,
    required this.fullscreen,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.onFavorite,
    required this.onEpisodes,
    required this.onIntro,
    required this.onFullscreen,
    required this.onDanmaku,
    required this.onDetail,
    required this.onSettings,
  });

  final Duration position;
  final Duration duration;
  final Duration buffer;
  final String title;
  final String episodeText;
  final String description;
  final String sourceName;
  final bool playing;
  final bool enabled;
  final bool following;
  final bool danmakuEnabled;
  final bool danmakuSupported;
  final bool fullscreen;
  final VoidCallback onTogglePlayback;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onFavorite;
  final VoidCallback onEpisodes;
  final VoidCallback onIntro;
  final VoidCallback onFullscreen;
  final VoidCallback onDanmaku;
  final VoidCallback onDetail;
  final VoidCallback onSettings;

  @override
  State<FeedOverlay> createState() => _FeedOverlayState();
}

class _FeedOverlayState extends State<FeedOverlay> {
  double? _drag;

  Widget _action(
    String id,
    IconData icon,
    String label,
    String sub,
    VoidCallback onPressed, {
    Color? color,
    bool dense = false,
    bool labelled = true,
  }) => Padding(
    padding: EdgeInsets.only(bottom: dense ? 4 : 10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FocusRing(
          radius: 999,
          child: IconButton(
            key: ValueKey('feed-$id'),
            tooltip: label,
            onPressed: onPressed,
            style: IconButton.styleFrom(
              foregroundColor: color ?? Colors.white,
              backgroundColor: Colors.black.withValues(alpha: .38),
              minimumSize: Size.square(dense ? 32 : 44),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.zero,
            ),
            icon: Icon(
              icon,
              size: dense ? 19 : 24,
              color: color ?? Colors.white,
            ),
          ),
        ),
        if (labelled)
          Text(
            sub,
            style: TextStyle(
              fontSize: dense ? 10 : 11,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
            ),
          ),
      ],
    ),
  );

  Widget _progress(BuildContext context, Color accent) {
    final max = widget.duration.inMilliseconds > 0
        ? widget.duration.inMilliseconds.toDouble()
        : 1.0;
    final value = (_drag ?? widget.position.inMilliseconds.toDouble()).clamp(
      0.0,
      max,
    );
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        padding: EdgeInsets.zero,
        activeTrackColor: accent,
        thumbColor: accent,
        inactiveTrackColor: Colors.white24,
        secondaryActiveTrackColor: Colors.white38,
        overlayShape: SliderComponentShape.noOverlay,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      child: ContainedSlider(
        slider: Slider(
          key: const ValueKey('feed-seek'),
          value: value,
          max: max,
          secondaryTrackValue: widget.buffer.inMilliseconds.toDouble().clamp(
            0.0,
            max,
          ),
          semanticFormatterCallback: (at) =>
              formatClock(Duration(milliseconds: at.round())),
          onChangeStart: widget.enabled ? (at) => setState(() => _drag = at) : null,
          onChanged: widget.enabled ? (at) => setState(() => _drag = at) : null,
          onChangeEnd: widget.enabled
              ? (at) {
                  setState(() => _drag = null);
                  widget.onSeek(Duration(milliseconds: at.round()));
                }
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 480;
        final wide = constraints.maxWidth > constraints.maxHeight;
        final dense = constraints.maxHeight < 560;
        final labelled = constraints.maxHeight >= 430;
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              ignoring: !widget.enabled,
              child: GestureDetector(
                key: const ValueKey('feed-surface'),
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTogglePlayback,
                child: Center(
                  child: !widget.playing
                      ? Icon(
                          Icons.play_arrow_rounded,
                          size: 76,
                          color: Colors.white.withValues(alpha: .72),
                          shadows: const [
                            Shadow(color: Colors.black54, blurRadius: 12),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 300,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                    ),
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  wide ? 24 : 16,
                  40,
                  12,
                  MediaQuery.paddingOf(context).bottom + 2,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(
                                  radius: 13,
                                  backgroundColor: accent.withValues(
                                    alpha: .85,
                                  ),
                                  child: Text(
                                    widget.sourceName.isEmpty
                                        ? '荐'
                                        : widget.sourceName.substring(0, 1),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    '@${widget.sourceName}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              widget.title,
                              key: const ValueKey('feed-title'),
                              maxLines: compact ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                height: 1.25,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            TextButton.icon(
                              key: const ValueKey('feed-episode'),
                              onPressed: widget.onEpisodes,
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 4,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: const Icon(
                                Icons.play_circle_outline_rounded,
                                size: 18,
                              ),
                              label: Text(
                                widget.episodeText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            if (!compact && widget.description.isNotEmpty)
                              GestureDetector(
                                key: const ValueKey('feed-intro'),
                                onTap: widget.onIntro,
                                child: Text(
                                  widget.description,
                                  maxLines: wide ? 1 : 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.45,
                                    color: Colors.white.withValues(alpha: .78),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _action(
                          'favorite',
                          widget.following
                              ? Icons.bookmark_rounded
                              : Icons.bookmark_border_rounded,
                          widget.following ? '取消追剧' : '加入追剧',
                          widget.following ? '已追剧' : '追剧',
                          widget.onFavorite,
                          color: widget.following ? accent : Colors.white,
                          dense: dense,
                          labelled: labelled,
                        ),
                        _action(
                          'episodes',
                          Icons.video_library_outlined,
                          '选集',
                          '选集',
                          widget.onEpisodes,
                          dense: dense,
                          labelled: labelled,
                        ),
                        _action(
                          'fullscreen',
                          widget.fullscreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          widget.fullscreen ? '退出全屏' : '全屏播放',
                          '全屏',
                          widget.onFullscreen,
                          dense: dense,
                          labelled: labelled,
                        ),
                        if (widget.danmakuSupported)
                          _action(
                            'danmaku',
                            widget.danmakuEnabled
                                ? Icons.subtitles
                                : Icons.subtitles_off,
                            widget.danmakuEnabled ? '关闭弹幕' : '开启弹幕',
                            '弹幕',
                            widget.onDanmaku,
                            dense: dense,
                          labelled: labelled,
                          ),
                        _action(
                          'detail',
                          Icons.info_outline_rounded,
                          '剧集详情',
                          '详情',
                          widget.onDetail,
                          dense: dense,
                          labelled: labelled,
                        ),
                        _action(
                          'settings',
                          Icons.tune_rounded,
                          '播放设置',
                          '设置',
                          widget.onSettings,
                          dense: dense,
                          labelled: labelled,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 6,
              right: 6,
              bottom: MediaQuery.paddingOf(context).bottom,
              child: _progress(context, accent),
            ),
          ],
        );
      },
    );
  }
}
