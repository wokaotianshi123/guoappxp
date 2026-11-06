import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../playback_preferences.dart';
import '../../playback_session.dart';
import '../settings/sorani_account_view.dart';
import '../widgets/contained_slider.dart';
import 'danmaku_overlay.dart';
import 'option_grid.dart';
import 'option_layout.dart';
import 'playback_handle.dart';
import 'player_gestures.dart';

String formatClock(Duration value) {
  final seconds = value.inSeconds;
  String two(int number) => number.toString().padLeft(2, '0');
  final clock = '${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
  return seconds >= 3600 ? '${seconds ~/ 3600}:$clock' : clock;
}

enum _Popup { quality, route, speed, volume }

class PlayerSurface extends StatefulWidget {
  const PlayerSurface({
    super.key,
    required this.handle,
    required this.hint,
    this.touch = false,
    required this.fullscreen,
    required this.wide,
    required this.onFullscreen,
    required this.onWide,
    required this.onSurface,
  });
  final PlaybackHandle handle;
  final ValueListenable<String> hint;
  final bool touch;
  final bool fullscreen;
  final bool wide;
  final VoidCallback onFullscreen;
  final VoidCallback onWide;
  final VoidCallback onSurface;

  @override
  State<PlayerSurface> createState() => _PlayerSurfaceState();
}

class _PlayerSurfaceState extends State<PlayerSurface> {
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _links = {for (final popup in _Popup.values) popup: LayerLink()};

  /// 弹层入口按钮，弹层比按钮宽时靠它的实际位置把弹层横向挪回播放器内。
  final _targets = {for (final popup in _Popup.values) popup: GlobalKey()};
  Timer? _hideTimer;
  Timer? _pointerTimer;
  Timer? _closeTimer;
  Timer? _tapTimer;
  Timer? _streakTimer;
  int _streak = 0;
  int _streakTaps = 0;
  bool _holding = false;
  bool _visible = true;
  bool _overBar = false;
  bool _pointer = false;
  _Popup? _popup;
  double? _seekValue;
  double? _seekTarget;
  Timer? _seekTimer;
  Player? _bound;

  /// 弹层里选项太多时用来竖向滚动，必须长期持有，滚动条要它才能定位。
  final _optionsScroll = ScrollController();
  late final PlayerGestures _gestures = PlayerGestures(session: _session);

  PlaybackSession get _session => widget.handle.session;

  void _endSeek() {
    _seekTimer?.cancel();
    _seekTarget = null;
    _seekValue = null;
  }

  @override
  void initState() {
    super.initState();
    _session.addListener(_bind);
    _bind();
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
    _subscriptions.add(
      stream.position.listen((position) {
        final target = _seekTarget;
        if (target != null && (position.inMilliseconds - target).abs() < 1000) {
          _endSeek();
        }
        _refresh();
      }),
    );
    for (final changes in [
      stream.duration,
      stream.buffer,
      stream.buffering,
      stream.volume,
    ]) {
      _subscriptions.add(changes.listen((_) => _refresh()));
    }
    _subscriptions.add(
      stream.playing.listen((playing) {
        if (playing) _scheduleHide();
        _refresh();
      }),
    );
  }

  @override
  void dispose() {
    _session.removeListener(_bind);
    _hideTimer?.cancel();
    _pointerTimer?.cancel();
    _closeTimer?.cancel();
    _seekTimer?.cancel();
    _tapTimer?.cancel();
    _streakTimer?.cancel();
    _gestures.dispose();
    _optionsScroll.dispose();
    if (_holding) _session.endBoost();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(Duration(milliseconds: widget.touch ? 3000 : 500), () {
      final state = _session.player.state;
      if (!mounted ||
          _overBar ||
          _popup != null ||
          _seekValue != null ||
          !state.playing ||
          state.buffering ||
          _session.boosting) {
        return;
      }
      setState(() => _visible = false);
    });
  }

  void _movePointer() {
    if (!_pointer) setState(() => _pointer = true);
    _pointerTimer?.cancel();
    _pointerTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _pointer = false);
    });
  }

  void _show() {
    if (!mounted) return;
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _open(_Popup popup) {
    _closeTimer?.cancel();
    if (_popup != popup) {
      // 换一个弹层时回到顶部，免得沿用上一个弹层滚到一半的位置。
      if (_optionsScroll.hasClients) _optionsScroll.jumpTo(0);
      setState(() => _popup = popup);
    }
    _show();
  }

  void _closeLater() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 200), _close);
  }

  void _close() {
    _closeTimer?.cancel();
    if (!mounted || _popup == null) return;
    setState(() => _popup = null);
    _scheduleHide();
  }

  void _toggleControls() {
    final state = _session.player.state;
    if (_visible && state.playing && _session.ready && !_session.stalled) {
      _hideTimer?.cancel();
      setState(() => _visible = false);
    } else {
      _show();
    }
  }

  void _tapUp(TapUpDetails details, double width) {
    // 刚做完滑动/亮度手势时抬手的事件不应再被当成「点按」。
    if (_gestures.suppressTap) return;
    widget.onSurface();
    final x = details.localPosition.dx;
    final side = x < width / 4
        ? -1
        : x > width * 3 / 4
        ? 1
        : 0;
    if (_streak != 0) {
      if (side == _streak.sign) return _streakTap(side);
      setState(_commitStreak);
    }
    if (_tapTimer?.isActive ?? false) {
      _tapTimer!.cancel();
      if (side == 0) {
        _session.togglePlayback();
      } else {
        _startStreak(side);
      }
      return;
    }
    _tapTimer = Timer(const Duration(milliseconds: 300), _toggleControls);
  }

  void _startStreak(int side) {
    final duration = _session.player.state.duration;
    if (!_session.ready || duration <= Duration.zero) return;
    _streak = side;
    _streakTaps = 0;
    unawaited(HapticFeedback.selectionClick());
    _armStreak();
  }

  void _streakTap(int side) {
    _streakTaps++;
    if (_streakTaps.isEven) {
      _streak += side;
      unawaited(HapticFeedback.selectionClick());
    }
    _armStreak();
  }

  void _armStreak() {
    _streakTimer?.cancel();
    _streakTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(_commitStreak);
    });
    setState(() {});
  }

  void _commitStreak() {
    _streakTimer?.cancel();
    final steps = _streak;
    _streak = 0;
    final state = _session.player.state;
    if (steps == 0 || !_session.ready || state.duration <= Duration.zero) {
      return;
    }
    final target = (state.position.inMilliseconds + steps * 10000).clamp(
      0,
      state.duration.inMilliseconds,
    );
    unawaited(_session.seekTo(Duration(milliseconds: target)));
  }

  void _pressStart() {
    if (!_session.ready) return;
    _session.holdBoost();
    unawaited(HapticFeedback.selectionClick());
    _holding = true;
  }

  void _pressEnd() {
    if (!_holding) return;
    _holding = false;
    _session.endBoost();
  }

  Future<void> _change(Future<void> Function() change) async {
    _close();
    widget.onSurface();
    try {
      await change();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('播放偏好未能保存，请重试')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      final state = _session.player.state;
      final visible =
          _visible || !state.playing || _session.stalled || !_session.ready;
      final popup = visible ? _popup : null;
      return MouseRegion(
        onHover: (_) => _movePointer(),
        cursor: visible || _pointer
            ? MouseCursor.defer
            : SystemMouseCursors.none,
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            fit: StackFit.expand,
            children: [
              Video(
                key: ValueKey(_session.player),
                controller: widget.handle.video(_session.player),
                controls: NoVideoControls,
                pauseUponEnteringBackgroundMode: false,
              ),
              DanmakuOverlay(
                controller: _session.danmaku,
                aspectRatio: _session.aspectRatio,
              ),
              if (widget.touch)
                LayoutBuilder(
                  builder: (context, constraints) => Listener(
                    onPointerDown: (event) => _gestures.pointerDown(
                      event,
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                    ),
                    onPointerMove: _gestures.pointerMove,
                    onPointerUp: _gestures.pointerUp,
                    onPointerCancel: _gestures.pointerCancel,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) =>
                          _tapUp(details, constraints.maxWidth),
                      onLongPressStart: (_) => _pressStart(),
                      onLongPressEnd: (_) => _pressEnd(),
                      onLongPressCancel: _pressEnd,
                    ),
                  ),
                )
              else
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    widget.onSurface();
                    _session.togglePlayback();
                  },
                  onDoubleTap: widget.onFullscreen,
                ),
              if (_session.ready && _session.stalled)
                const IgnorePointer(
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_session.ready && !state.playing) _pausedMark(),
              if (_streak != 0) _streakBadge(),
              AnimatedBuilder(
                animation: _gestures,
                builder: (context, _) => GestureHud(state: _gestures.hud),
              ),
              IgnorePointer(
                ignoring: !visible,
                child: ExcludeFocus(
                  excluding: !visible,
                  child: AnimatedOpacity(
                    opacity: visible ? 1 : 0,
                    duration: state.playing
                        ? const Duration(milliseconds: 180)
                        : Duration.zero,
                    child: Listener(
                      onPointerDown: widget.touch
                          ? (_) => _scheduleHide()
                          : null,
                      child: _controls(context),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 80,
                child: MouseRegion(
                  hitTestBehavior: HitTestBehavior.translucent,
                  onEnter: (_) => _overBar = true,
                  onHover: (_) => _show(),
                  onExit: (_) {
                    _overBar = false;
                    _scheduleHide();
                  },
                ),
              ),
              if (popup != null && widget.touch)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _close,
                ),
              if (popup != null)
                Positioned(
                  left: 0,
                  top: 0,
                  child: CompositedTransformFollower(
                    link: _links[popup]!,
                    showWhenUnlinked: false,
                    targetAnchor: Alignment.topCenter,
                    followerAnchor: Alignment.bottomCenter,
                    offset: const Offset(0, -6),
                    child: MouseRegion(
                      onEnter: (_) => _closeTimer?.cancel(),
                      onExit: (_) => _closeLater(),
                      child: _popupBody(context, popup, constraints),
                    ),
                  ),
                ),
              _hint(),
              if (_session.saveWarning case final warning?)
                _saveWarning(warning),
              if (_session.loading) PlaybackLoading(session: _session),
              if (_session.error case final error?)
                PlaybackFailure(session: _session, error: error),
            ],
          ),
        ),
      );
    },
  );

  Widget _pausedMark() => Positioned(
    right: 20,
    bottom: 92,
    child: IgnorePointer(
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .4),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.play_arrow_rounded,
          size: 42,
          color: Colors.white.withValues(alpha: .9),
        ),
      ),
    ),
  );

  Widget _streakBadge() {
    final forward = _streak > 0;
    return IgnorePointer(
      child: Align(
        alignment: Alignment(forward ? .75 : -.75, 0),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              Icon(
                forward
                    ? Icons.fast_forward_rounded
                    : Icons.fast_rewind_rounded,
                size: 20,
                color: Colors.white,
              ),
              Text(
                '${forward ? '快进' : '快退'} ${_streak.abs() * 10} 秒',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final state = _session.player.state;
    final duration = state.duration;
    final max = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final position = (_seekValue ?? state.position.inMilliseconds.toDouble())
        .clamp(0.0, max);
    final colors = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        const IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: double.infinity,
              height: 200,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xC7000000)],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 6,
          right: 6,
          bottom: 52,
          height: 28,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: colors.primary,
              thumbColor: colors.primary,
              inactiveTrackColor: Colors.white.withValues(alpha: .25),
              secondaryActiveTrackColor: Colors.white.withValues(alpha: .4),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: ContainedSlider(
              slider: Slider(
                value: position,
                max: max,
                secondaryTrackValue: state.buffer.inMilliseconds
                    .toDouble()
                    .clamp(0.0, max),
                semanticFormatterCallback: (value) =>
                    formatClock(Duration(milliseconds: value.round())),
                onChangeStart: _session.ready && duration > Duration.zero
                    ? (_) {
                        _hideTimer?.cancel();
                        _seekTimer?.cancel();
                        _seekTarget = null;
                      }
                    : null,
                onChanged: _session.ready && duration > Duration.zero
                    ? (value) => setState(() => _seekValue = value)
                    : null,
                onChangeEnd: (value) {
                  if (_session.ready && duration > Duration.zero) {
                    _seekTarget = value;
                    _seekTimer?.cancel();
                    _seekTimer = Timer(const Duration(seconds: 2), () {
                      if (mounted) setState(_endSeek);
                    });
                    unawaited(
                      _session.seekTo(Duration(milliseconds: value.round())),
                    );
                  } else {
                    setState(_endSeek);
                  }
                  _scheduleHide();
                },
              ),
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 10,
          height: 48,
          child: _toolbar(context, position),
        ),
      ],
    );
  }

  Widget _toolbar(BuildContext context, double position) {
    final colors = Theme.of(context).colorScheme;
    final state = _session.player.state;
    final playing = state.playing;
    final ready = _session.ready;
    return Row(
      children: [
        _icon(
          Icons.skip_previous_rounded,
          '上一集',
          _session.hasPrevious ? () => unawaited(_session.previous()) : null,
        ),
        _icon(
          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          playing ? '暂停' : '播放',
          ready ? _session.togglePlayback : null,
          size: 48,
          iconSize: 30,
        ),
        _icon(
          Icons.skip_next_rounded,
          '下一集',
          _session.hasNext ? () => unawaited(_session.next()) : null,
        ),
        const SizedBox(width: 8),
        Text(
          '${formatClock(Duration(milliseconds: position.round()))} / ${formatClock(state.duration)}',
          maxLines: 1,
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: .86),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (_session.danmakuSupported) ...[
          const SizedBox(width: 4),
          _icon(
            _session.danmakuEnabled
                ? Icons.subtitles_rounded
                : Icons.subtitles_off_rounded,
            _session.danmakuEnabled ? '关闭弹幕' : '打开弹幕',
            () => _change(_session.toggleDanmaku),
            color: _session.danmakuEnabled ? colors.primary : null,
          ),
        ],
        const Spacer(),
        _popupTarget(
          _Popup.quality,
          _text(
            _session.qualityLabel,
            '清晰度',
            ready && !_session.local ? () => _open(_Popup.quality) : null,
          ),
        ),
        // 线路紧挨着清晰度放：两者都是「换一条地址重播」，桌面端没有手机那套
        // 播放设置抽屉，线路只能在这里给入口。
        if (!_session.local)
          _popupTarget(
            _Popup.route,
            _text(
              '线路 ${_session.routeIndex + 1}/${_session.routeCount}',
              '播放线路',
              ready && _session.canSwitchRoute
                  ? () => _open(_Popup.route)
                  : null,
            ),
          ),
        _popupTarget(
          _Popup.speed,
          _text(
            '${_session.speed}x',
            '倍速',
            ready ? () => _open(_Popup.speed) : null,
            bold: true,
          ),
        ),
        if (!widget.touch)
          _popupTarget(
            _Popup.volume,
            _icon(
              state.volume == 0
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
              state.volume == 0 ? '取消静音' : '静音',
              () => _session.toggleMute(),
            ),
          ),
        _icon(Icons.picture_in_picture_alt_rounded, '画中画', null),
        if (!widget.touch && !widget.fullscreen)
          _icon(
            Icons.width_wide_rounded,
            widget.wide ? '退出宽屏' : '宽屏',
            widget.onWide,
            color: widget.wide ? colors.primary : null,
          ),
        _icon(
          widget.fullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          widget.fullscreen ? '退出全屏' : '全屏',
          widget.onFullscreen,
        ),
      ],
    );
  }

  Widget _popupTarget(_Popup popup, Widget child) {
    final enabled = switch (popup) {
      // 本地文件没有清晰度与线路可选，悬停展开只会弹出空面板。
      _Popup.quality => !_session.local,
      _Popup.route => _session.canSwitchRoute,
      _ => true,
    };
    return CompositedTransformTarget(
      key: _targets[popup],
      link: _links[popup]!,
      child: MouseRegion(
        onEnter: enabled && _session.ready ? (_) => _open(popup) : null,
        onExit: (_) => _closeLater(),
        child: child,
      ),
    );
  }

  Widget _icon(
    IconData icon,
    String label,
    VoidCallback? onPressed, {
    double size = 44,
    double iconSize = 24,
    Color? color,
  }) => Semantics(
    label: label,
    button: true,
    excludeSemantics: true,
    child: _HoverScale(
      enabled: onPressed != null,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon),
        iconSize: iconSize,
        color: color ?? Colors.white,
        disabledColor: Colors.white.withValues(alpha: .36),
        style: IconButton.styleFrom(
          fixedSize: Size.square(size),
          overlayColor: Colors.transparent,
        ),
      ),
    ),
  );

  Widget _text(
    String text,
    String label,
    VoidCallback? onPressed, {
    bool bold = false,
  }) => Semantics(
    label: label,
    button: true,
    child: _HoverScale(
      enabled: onPressed != null,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          fixedSize: const Size.fromHeight(40),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white.withValues(alpha: .6),
          overlayColor: Colors.transparent,
          textStyle: TextStyle(
            fontSize: 14,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        child: Text(text),
      ),
    ),
  );

  /// 弹层自身的左右内边距，算总宽时要加上。
  static const double _popupPadding = 6;

  Widget _popupBody(BuildContext context, _Popup popup, BoxConstraints space) {
    final view = switch (popup) {
      _Popup.volume => _OptionView(child: _volume(context), width: 44),
      _Popup.route => _options<int>(
        space: space,
        values: [
          for (var route = 0; route < _session.routeCount; route += 1) route,
        ],
        selected: _session.routeIndex,
        label: (value) => '线路 ${value + 1}',
        onSelected: (value) => _change(() => _session.setRoute(value)),
      ),
      _Popup.speed => _options<double>(
        space: space,
        values: playbackSpeeds.reversed.toList(),
        selected: _session.speed,
        label: (value) => '${value}x',
        onSelected: (value) => _change(() => _session.setSpeed(value)),
      ),
      _Popup.quality => _options<int>(
        space: space,
        values: [..._session.qualities, 0],
        selected: _session.quality,
        label: (value) => value == 0 ? '自动' : '${value}P',
        onSelected: (value) => _change(() => _session.setQuality(value)),
      ),
    };
    return Transform.translate(
      offset: Offset(_popupShift(popup, view.width + _popupPadding * 2), 0),
      child: Material(
        color: const Color(0xE0141414),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(_popupPadding),
          child: view.child,
        ),
      ),
    );
  }

  /// 弹层默认贴着按钮居中向上展开。线路多的时候弹层比按钮宽得多，靠右的按钮
  /// 一展开就会顶出播放器右边被裁掉，这里按按钮的真实位置把弹层挪回可视区域。
  double _popupShift(_Popup popup, double popupWidth) {
    final host = context.findRenderObject();
    final target = _targets[popup]?.currentContext?.findRenderObject();
    if (host is! RenderBox || target is! RenderBox) return 0;
    if (!host.hasSize || !target.hasSize) return 0;
    final hostWidth = host.size.width;
    final center = target
        .localToGlobal(Offset(target.size.width / 2, 0), ancestor: host)
        .dx;
    final centered = center - popupWidth / 2;
    const margin = 8.0;
    final limit = hostWidth - margin - popupWidth;
    // 弹层比窗口还宽时无处可挪，直接居中。
    if (limit <= margin) return (hostWidth - popupWidth) / 2 - centered;
    return centered.clamp(margin, limit) - centered;
  }

  /// 弹层下方要留给控制条的高度：工具条底距 10 + 高 48 + 弹层间距 6 + 余量。
  static const double _popupBottomReserve = 76;

  /// 弹层左右留白 + 自身内边距。
  static const double _popupSideReserve = 36;

  _OptionView _options<T>({
    required BoxConstraints space,
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required void Function(T) onSelected,
  }) {
    // 弹层贴在控制条上方、控制条又贴着窗口底部，能用多高取决于控制条以上还剩
    // 多少空间。线路多的源一集可能几十上百条线路：先按高度分行、按行数分列，
    // 整屏放得下就照老样子显示；放不下就把列数钉死在宽度允许的最大值、改成按
    // 行填充，再套竖向滚动，保证每一条都点得到。
    final height = space.maxHeight.isFinite ? space.maxHeight : 720.0;
    final width = space.maxWidth.isFinite ? space.maxWidth : 1280.0;
    final availableHeight = (height - _popupBottomReserve).clamp(
      OptionGridMetrics.rowHeight,
      double.infinity,
    );
    final availableWidth = (width - _popupSideReserve).clamp(
      OptionGridMetrics.cellWidth,
      double.infinity,
    );
    final plan = planOptionGrid(
      count: values.length,
      availableHeight: availableHeight,
      availableWidth: availableWidth,
      rowHeight: OptionGridMetrics.rowHeight,
      columnWidth: OptionGridMetrics.cellWidth,
      gap: OptionGridMetrics.gap,
    );
    return _OptionView(
      // 单列时宽度由文字撑开、算不准，按最小宽度估个够用的值即可。
      width: plan.singleColumn
          ? OptionGridMetrics.minWidth
          : OptionGrid.widthOf(plan),
      child: OptionGrid<T>(
        plan: plan,
        availableHeight: availableHeight,
        values: values,
        selected: selected,
        label: label,
        onSelected: onSelected,
        scrollController: _optionsScroll,
      ),
    );
  }

  Widget _volume(BuildContext context) {
    final volume = _session.player.state.volume.clamp(0.0, 100.0);
    return SizedBox(
      width: 44,
      height: 156,
      child: Column(
        children: [
          Text(
            '${volume.round()}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: -1,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: Colors.white,
                  thumbColor: Colors.white,
                  inactiveTrackColor: Colors.white.withValues(alpha: .25),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                ),
                child: ContainedSlider(
                  slider: Slider(
                    value: volume,
                    max: 100,
                    semanticFormatterCallback: (value) =>
                        '音量 ${value.round()}%',
                    onChanged: _session.setVolume,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hint() => ValueListenableBuilder(
    valueListenable: widget.hint,
    builder: (context, hint, _) {
      final boosting = _session.boosting;
      final text = boosting ? '倍速播放中' : hint;
      if (text.isEmpty) return const SizedBox.shrink();
      return IgnorePointer(
        child: Align(
          alignment: const Alignment(0, -.5),
          child: Container(
            padding: boosting
                ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: boosting ? .6 : .72),
              borderRadius: BorderRadius.circular(boosting ? 10 : 12),
            ),
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white,
                fontSize: boosting ? 13 : 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _saveWarning(String warning) => Positioned(
    top: 12,
    left: 12,
    right: 12,
    child: Align(
      alignment: Alignment.topCenter,
      child: Material(
        color: const Color(0xE6322424),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  warning,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _session.saveProgress,
                child: const Text('重试保存'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class PlaybackProgressBuilder extends StatefulWidget {
  const PlaybackProgressBuilder({
    super.key,
    required this.player,
    required this.builder,
  });
  final Player player;
  final WidgetBuilder builder;

  @override
  State<PlaybackProgressBuilder> createState() =>
      _PlaybackProgressBuilderState();
}

class _PlaybackProgressBuilderState extends State<PlaybackProgressBuilder> {
  final List<StreamSubscription<Duration>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(PlaybackProgressBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) _listen();
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  void _listen() {
    _cancel();
    final stream = widget.player.stream;
    for (final changes in [stream.position, stream.buffer]) {
      _subscriptions.add(
        changes.listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
  }

  void _cancel() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class PlaybackLoading extends StatelessWidget {
  const PlaybackLoading({super.key, required this.session});
  final PlaybackSession session;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black.withValues(alpha: .78),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            session.loadingMessage,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ],
      ),
    ),
  );
}

class PlaybackFailure extends StatelessWidget {
  const PlaybackFailure({
    super.key,
    required this.session,
    required this.error,
    this.retryFocus,
  });
  final PlaybackSession session;
  final String error;
  final FocusNode? retryFocus;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Colors.black.withValues(alpha: .9),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.play_disabled_rounded,
                size: 48,
                color: colors.primary,
              ),
              const SizedBox(height: 16),
              const Text(
                '暂时无法播放',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  error,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .78),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (session.loginRequired)
                    FilledButton(
                      focusNode: retryFocus,
                      onPressed: () async {
                        if (await showSoraniLogin(context) != null) {
                          await session.retry();
                        }
                      },
                      child: const Text('去登录'),
                    )
                  else
                    FilledButton(
                      focusNode: retryFocus,
                      onPressed: session.retry,
                      child: Text(session.localFailure ? '重试本地播放' : '重试'),
                    ),
                  if (session.localFailure)
                    TextButton(
                      onPressed: session.switchOnline,
                      child: const Text('改为在线播放'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HoverScale extends StatefulWidget {
  const _HoverScale({required this.enabled, required this.child});
  final bool enabled;
  final Widget child;

  @override
  State<_HoverScale> createState() => _HoverScaleState();
}

class _HoverScaleState extends State<_HoverScale> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: AnimatedScale(
      scale: _hovered && widget.enabled ? 1.15 : 1,
      duration: const Duration(milliseconds: 120),
      child: widget.child,
    ),
  );
}

/// 弹层内容 + 它占的宽度，弹层据此判断要不要横向挪回播放器内。
class _OptionView {
  const _OptionView({required this.child, required this.width});
  final Widget child;
  final double width;
}
