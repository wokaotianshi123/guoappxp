import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../app_device.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../playback_preferences.dart';
import '../../playback_session.dart';
import '../app_scope.dart';
import '../downloads/download_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/contained_slider.dart';
import '../widgets/follow_button.dart';
import 'danmaku_overlay.dart';
import 'playback_details_sheet.dart';
import 'playback_sheets.dart';
import 'playback_handle.dart';
import 'player_video.dart';
import 'player_gestures.dart';
import 'player_surface.dart';

const _maskHeight = 68.0;

/// 左侧亮度区的右边界（占播放区宽度），和横屏播放器的左半屏一致。
///
/// 最左侧五分之一仍然是「长按 2 倍速」，亮度从五分之一到一半之间生效。
const _brightnessZone = .5;

String _status(Drama drama) =>
    drama.releaseLabel == '状态未知' ? '' : '${drama.releaseLabel} · ';

class PortraitPlayerPage extends StatefulWidget {
  const PortraitPlayerPage({
    super.key,
    required this.store,
    required this.handle,
  });
  final LocalStore store;
  final PlaybackHandle handle;

  @override
  State<PortraitPlayerPage> createState() => _PortraitPlayerPageState();
}

class _PortraitPlayerPageState extends State<PortraitPlayerPage>
    with WidgetsBindingObserver {
  late final _pages = PageController(initialPage: _session.index);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Player? _bound;
  Timer? _hintTimer;
  String _hint = '';
  bool _scrolling = false;
  bool _edgeHinted = false;
  bool _holding = false;
  bool _overMask = false;
  int _heldIndex = -1;
  bool _dragging = false;
  double? _seekValue;
  double? _seekTarget;
  Timer? _seekTimer;

  // 双指缩放：0 = 完整画面（有黑边），1 = 铺满屏幕（两侧略有裁切）。
  final _pointers = <int, Offset>{};
  double? _pinchFrom;
  double _pinchBase = 0;
  double _zoom = 0;
  int _zoomedIndex = -1;
  bool _pinching = false;
  DateTime _pinchTapGuard = DateTime.fromMillisecondsSinceEpoch(0);

  /// 竖屏的滑动调亮度/快进快退，行为与横屏播放器一致；
  /// 但竖屏短促的上下滑是切集，所以亮度要「长按后」才接管，
  /// 右半屏竖滑也留给翻页，不再调音量。
  late final PlayerGestures _gestures = PlayerGestures(
    session: _session,
    brightnessZone: _brightnessZone,
    volumeSwipe: false,
    requireHold: true,
  );

  PlaybackSession get _session => widget.handle.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.addListener(_changed);
    _bind();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_changed);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _hintTimer?.cancel();
    _seekTimer?.cancel();
    _gestures.dispose();
    _pages.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _session.setForeground(
        state == AppLifecycleState.resumed ||
            defaultTargetPlatform == TargetPlatform.windows &&
                state == AppLifecycleState.inactive,
      );

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
      }),
    );
    for (final changes in [stream.duration, stream.buffering, stream.playing]) {
      _subscriptions.add(changes.listen((_) => _refresh()));
    }
  }

  void _changed() {
    _bind();
    // 换集后回到完整画面，别把上一集的放大状态带过去。
    if (_zoomedIndex != _session.index) {
      _zoomedIndex = _session.index;
      _zoom = 0;
      _pinching = false;
      _pointers.clear();
    }
    if (_holding && _session.index != _heldIndex) _pressEnd();
    if (!_scrolling &&
        _pages.hasClients &&
        _pages.page?.round() != _session.index) {
      _pages.jumpToPage(_session.index);
    }
    _refresh();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  double get _pinchSpan {
    if (_pointers.length < 2) return 0;
    final points = _pointers.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  void _beginPinch() {
    if (_pinching) return;
    _pinchFrom = _pinchSpan;
    _pinchBase = _zoom;
    setState(() => _pinching = true);
  }

  void _updatePinch() {
    final from = _pinchFrom;
    if (!_pinching || from == null || from <= 0) return;
    final span = _pinchSpan;
    if (span <= 0) return;
    // 手指张开 100% 左右就铺满；捏合回 1 倍以下就回到完整画面。
    final next = (_pinchBase + (span / from - 1) * 1.6).clamp(0.0, 1.0);
    if ((next - _zoom).abs() < .001) return;
    setState(() => _zoom = next);
  }

  void _endPinch() {
    final from = _pinchFrom;
    _pinchFrom = null;
    // 双指张开 / 捏合不再只是临时放大，而是把结果记成画面比例：
    // 过半即「裁切」，否则回「自动」，退出播放页后仍然保持。
    final target = _zoom >= .4 ? VideoFit.crop : VideoFit.auto;
    setState(() {
      _pinching = false;
      _zoom = 0;
    });
    if (from != null && target != _session.videoFit) {
      unawaited(_session.setVideoFit(target).catchError((Object _) => _saveFailed()));
      unawaited(HapticFeedback.selectionClick());
      _say(target == VideoFit.crop ? '画面比例：裁切，双指捏合恢复' : '画面比例：自动');
    }
    // 捏合结束后短时间内不响应单击，避免误触暂停。
    _pinchTapGuard = DateTime.now().add(const Duration(milliseconds: 300));
  }

  /// 把「完整画面」放大到刚好铺满容器所需的倍数。
  /// 短剧是 9:16，长屏手机上按 contain 显示会上下留黑边，放大后只裁掉两侧一点。
  double _coverScale(
    double width,
    double height,
    double aspectRatio,
    double zoom,
  ) {
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return 1;
    }
    final aspect = aspectRatio.isFinite && aspectRatio > 0
        ? aspectRatio
        : 9 / 16;
    final videoWidth = math.min(width, height * aspect);
    final videoHeight = videoWidth / aspect;
    final cover = math.max(width / videoWidth, height / videoHeight);
    return 1 + (cover - 1) * zoom;
  }

  void _endSeek() {
    _seekTimer?.cancel();
    _seekTarget = null;
    _seekValue = null;
  }

  void _say(String text) {
    _hintTimer?.cancel();
    setState(() => _hint = text);
    _hintTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _hint = '');
    });
  }

  bool _scrolled(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _edgeHinted = false;
      setState(() => _scrolling = true);
    } else if (notification is ScrollUpdateNotification && _scrolling) {
      if (!_edgeHinted && metrics.pixels < metrics.minScrollExtent - 40) {
        _edgeHinted = true;
        _say('已经是第一集');
      } else if (!_edgeHinted &&
          metrics.pixels > metrics.maxScrollExtent + 40) {
        _edgeHinted = true;
        _say('已经是最后一集');
      }
    } else if (notification is ScrollEndNotification) {
      final page = (metrics.pixels / metrics.viewportDimension).round();
      if (_scrolling) setState(() => _scrolling = false);
      if (page != _session.index &&
          page >= 0 &&
          page < _session.detail.episodes.length) {
        unawaited(_session.play(page));
      }
    }
    return false;
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (_scrolling) return;
      final target = _session.index + (event.scrollDelta.dy > 0 ? 1 : -1);
      if (target < 0) return _say('已经是第一集');
      if (target >= _session.detail.episodes.length) {
        return _say('已经是最后一集');
      }
      setState(() => _scrolling = true);
      unawaited(
        _pages.animateToPage(
          target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _pressStart(LongPressStartDetails details, double width) {
    final x = details.localPosition.dx;
    if (x < width / 5) {
      // 最左侧：沿用「长按临时 2 倍速、下滑松手锁定」。
      if (!_session.boostLocked) _session.holdBoost();
      unawaited(HapticFeedback.selectionClick());
      setState(() {
        _holding = true;
        _heldIndex = _session.index;
        _overMask = false;
      });
    } else if (x < width * _brightnessZone && AppDevice.brightnessSupported) {
      // 左侧亮度区：长按后上下滑调亮度、左右滑快进快退；
      // 短促的上下滑仍然是翻页切集，因为这里不抢手势、只等长按成立。
      // 非 Android 没有窗口亮度能力，这里退回原来的「打开播放设置」。
      _gestures.hold();
      unawaited(HapticFeedback.selectionClick());
    } else {
      unawaited(HapticFeedback.selectionClick());
      unawaited(_openSettings());
    }
  }

  void _pressMove(LongPressMoveUpdateDetails details) {
    if (!_holding) return;
    final media = MediaQuery.of(context);
    final over =
        details.globalPosition.dy >=
        media.size.height - media.padding.bottom - _maskHeight;
    if (over != _overMask) {
      unawaited(HapticFeedback.selectionClick());
      setState(() => _overMask = over);
    }
  }

  void _pressEnd() {
    if (!_holding) return;
    if (_overMask) {
      _session.setBoostLocked(!_session.boostLocked);
    } else if (!_session.boostLocked) {
      _session.endBoost();
    }
    setState(() {
      _holding = false;
      _overMask = false;
    });
  }

  Future<void> _openSettings() => showPlayerSheet(
    context,
    (_) => PlaybackSettings(session: _session, onFailure: _saveFailed),
  );

  Future<void> _openEpisodes() => showPlayerSheet(
    context,
    (_) => PlaybackDetailsSheet(
      session: _session,
      store: widget.store,
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

  void _saveFailed() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('播放偏好未能保存，请重试')));
  }

  @override
  Widget build(BuildContext context) {
    final dark = playerTheme(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.systemBars(Brightness.dark),
      child: Theme(
        data: dark,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: _scrolled,
                child: PageView.builder(
                  controller: _pages,
                  scrollDirection: Axis.vertical,
                  physics: _pinching
                      ? const NeverScrollableScrollPhysics()
                      : const _PagePhysics(),
                  itemCount: _session.detail.episodes.length,
                  itemBuilder: _page,
                ),
              ),
              IgnorePointer(ignoring: _scrolling, child: _controls(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _page(BuildContext context, int index) {
    final session = _session;
    final current = index == session.index;
    final player = current
        ? session.player
        : index == session.standbyIndex
        ? session.standby
        : null;
    final waiting = player == null || current && session.loading;
    return Listener(
      onPointerSignal: _wheel,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!waiting)
            LayoutBuilder(
              builder: (context, constraints) {
                final video = PlayerVideo(
                  key: ValueKey(player),
                  handle: widget.handle,
                  player: player,
                  fit: session.videoFit,
                );
                // 只有当前这一集跟随双指缩放的进度。
                final zoom = current ? _zoom : 0.0;
                if (zoom <= 0) return video;
                return ClipRect(
                  child: Transform.scale(
                    scale: _coverScale(
                      constraints.maxWidth,
                      constraints.maxHeight,
                      session.aspectRatio,
                      zoom,
                    ),
                    child: video,
                  ),
                );
              },
            ),
          if (waiting)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 16,
                children: [
                  Text(
                    '第 ${session.detail.episodes[index].number} 集',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (current) const CircularProgressIndicator(),
                ],
              ),
            ),
          if (current) ...[
            DanmakuOverlay(
              key: const ValueKey('danmaku'),
              controller: session.danmaku,
              video: session.videoSize,
          fit: session.videoFit,
              style: session.danmakuStyle,
            ),
            LayoutBuilder(
              key: const ValueKey('gestures'),
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return Listener(
                  onPointerDown: (event) {
                    _pointers[event.pointer] = event.position;
                    if (_pointers.length > 1) return _beginPinch();
                    _gestures.pointerDown(
                      event,
                      width: width,
                      height: constraints.maxHeight,
                    );
                  },
                  onPointerMove: (event) {
                    if (_pointers.containsKey(event.pointer)) {
                      _pointers[event.pointer] = event.position;
                    }
                    if (_pointers.length > 1) return _updatePinch();
                    _gestures.pointerMove(event);
                  },
                  onPointerUp: (event) {
                    _pointers.remove(event.pointer);
                    if (_pinching) {
                      if (_pointers.isEmpty) _endPinch();
                      return;
                    }
                    _gestures.pointerUp(event);
                  },
                  onPointerCancel: (event) {
                    _pointers.remove(event.pointer);
                    if (_pinching) {
                      if (_pointers.isEmpty) _endPinch();
                      return;
                    }
                    _gestures.pointerCancel(event);
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (_) {
                      // 刚做完滑动/亮度/捏合手势时抬手的事件不应被当成「点按」。
                      if (_gestures.suppressTap ||
                          DateTime.now().isBefore(_pinchTapGuard)) {
                        return;
                      }
                      session.togglePlayback();
                    },
                    onLongPressStart: (details) => _pressStart(details, width),
                    onLongPressMoveUpdate: _pressMove,
                    onLongPressEnd: (_) => _pressEnd(),
                    onLongPressCancel: _pressEnd,
                  ),
                );
              },
            ),
            AnimatedBuilder(
              animation: _gestures,
              builder: (context, _) => GestureHud(state: _gestures.hud),
            ),
          ],
        ],
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final session = _session;
    final padding = MediaQuery.paddingOf(context);
    final bottom = padding.bottom;
    final locked = session.boostLocked;
    return Stack(
      fit: StackFit.expand,
      children: [
        const IgnorePointer(
          child: Align(
            alignment: Alignment.topCenter,
            child: _Shade(height: 130, top: true),
          ),
        ),
        const IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: _Shade(height: 220, top: false),
          ),
        ),
        if (session.ready && session.paused)
          Center(
            child: IgnorePointer(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .35),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 44,
                  color: Colors.white.withValues(alpha: .9),
                ),
              ),
            ),
          ),
        if (session.ready && session.stalled)
          const IgnorePointer(
            child: Center(child: CircularProgressIndicator()),
          ),
        if (session.error case final error?)
          PlaybackFailure(session: session, error: error),
        Positioned(
          key: const ValueKey('header'),
          left: 4,
          right: 12,
          top: padding.top,
          height: 56,
          child: _header(),
        ),
        if (_dragging)
          Positioned(
            left: 0,
            right: 0,
            bottom: bottom + 140,
            child: IgnorePointer(
              child: Center(child: _seekBubble(_seekValue ?? 0)),
            ),
          ),
        Positioned(
          key: const ValueKey('progress'),
          left: 16,
          right: 16,
          bottom: bottom + 60,
          height: 32,
          child: _progress(context),
        ),
        Positioned(
          key: const ValueKey('episodes'),
          left: 16,
          right: 16,
          bottom: bottom + 16,
          height: 44,
          child: _episodeStrip(),
        ),
        if (_holding) ...[
          Positioned(
            left: 0,
            right: 0,
            top: padding.top + 76,
            child: IgnorePointer(child: Center(child: _boostBadge())),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: bottom + _maskHeight,
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black,
                child: Padding(
                  padding: EdgeInsets.only(bottom: bottom),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 8,
                    children: [
                      Icon(
                        !_overMask
                            ? Icons.fast_forward_rounded
                            : locked
                            ? Icons.lock_open_rounded
                            : Icons.lock_rounded,
                        size: 20,
                        color: Colors.white,
                      ),
                      Text(
                        '${_overMask ? '' : '下滑'}松手${locked ? '取消' : '锁定'} 2 倍速',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        if (_hint.isNotEmpty)
          IgnorePointer(
            child: Align(
              alignment: const Alignment(0, -.5),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .72),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _hint,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),
        if (session.saveWarning case final warning?)
          Positioned(
            top: padding.top + 64,
            left: 12,
            right: 12,
            child: Material(
              color: const Color(0xE6322424),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        warning,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: session.saveProgress,
                      child: const Text('重试保存'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _header() {
    final session = _session;
    const shadow = [Shadow(color: Color(0x66000000), blurRadius: 2)];
    return Row(
      spacing: 2,
      children: [
        IconButton(
          onPressed: () => unawaited(Navigator.maybePop(context)),
          icon: const Icon(Icons.arrow_back_rounded),
          color: Colors.white,
          tooltip: '返回',
          style: IconButton.styleFrom(fixedSize: const Size.square(48)),
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.detail.drama.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  shadows: shadow,
                ),
              ),
              Text(
                '第 ${session.episode.number} 集',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: .78),
                  fontSize: 12,
                  shadows: shadow,
                ),
              ),
            ],
          ),
        ),
        FollowIcon(
          store: widget.store,
          drama: session.detail.drama,
          color: Colors.white,
          activeColor: Theme.of(context).colorScheme.primaryFixedDim,
        ),
      ],
    );
  }

  Widget _seekBubble(double value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text.rich(
      TextSpan(
        text: formatClock(Duration(milliseconds: value.round())),
        children: [
          TextSpan(
            text: ' / ${formatClock(_session.player.state.duration)}',
            style: TextStyle(color: Colors.white.withValues(alpha: .6)),
          ),
        ],
      ),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    ),
  );

  Widget _progress(BuildContext context) =>
      PlaybackProgressBuilder(player: _session.player, builder: _progressBar);

  Widget _progressBar(BuildContext context) {
    final session = _session;
    final state = session.player.state;
    final duration = state.duration;
    final seekable = session.ready && duration > Duration.zero;
    final max = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final position = (_seekValue ?? state.position.inMilliseconds.toDouble())
        .clamp(0.0, max);
    final dragging = _dragging;
    final colors = Theme.of(context).colorScheme;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: dragging ? 6 : 3,
        padding: EdgeInsets.zero,
        activeTrackColor: colors.primary,
        thumbColor: colors.primary,
        inactiveTrackColor: Colors.white.withValues(alpha: .25),
        secondaryActiveTrackColor: Colors.white.withValues(alpha: .4),
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: dragging ? 10 : 6,
        ),
        overlayShape: SliderComponentShape.noOverlay,
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      child: ContainedSlider(
        slider: Slider(
          value: position,
          max: max,
          secondaryTrackValue: state.buffer.inMilliseconds.toDouble().clamp(
            0.0,
            max,
          ),
          semanticFormatterCallback: (value) =>
              formatClock(Duration(milliseconds: value.round())),
          onChangeStart: seekable
              ? (value) {
                  _seekTimer?.cancel();
                  _seekTarget = null;
                  setState(() {
                    _dragging = true;
                    _seekValue = value;
                  });
                }
              : null,
          onChanged: seekable
              ? (value) => setState(() => _seekValue = value)
              : null,
          onChangeEnd: (value) {
            _dragging = false;
            if (seekable) {
              _seekTarget = value;
              _seekTimer?.cancel();
              _seekTimer = Timer(const Duration(seconds: 2), () {
                if (mounted) setState(_endSeek);
              });
              unawaited(session.seekTo(Duration(milliseconds: value.round())));
              setState(() {});
            } else {
              setState(_endSeek);
            }
          },
        ),
      ),
    );
  }

  Widget _episodeStrip() {
    final drama = _session.detail.drama;
    final count = _session.detail.episodes.length;
    final status = _status(drama);
    return Material(
      color: Colors.white.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openEpisodes,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
          child: Row(
            spacing: 8,
            children: [
              const Icon(
                Icons.view_list_rounded,
                size: 18,
                color: Colors.white,
              ),
              const Text(
                '选集 · 简介',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Expanded(
                child: Text(
                  '· $status共 $count 集',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .72),
                    fontSize: 14,
                  ),
                ),
              ),
              const Icon(
                Icons.keyboard_arrow_up_rounded,
                size: 20,
                color: Colors.white,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _boostBadge() => Container(
    height: 32,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(16),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        Icon(Icons.fast_forward_rounded, size: 16, color: Colors.white),
        Text(
          '2 倍速播放中',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _PagePhysics extends BouncingScrollPhysics {
  const _PagePhysics({super.parent});

  @override
  _PagePhysics applyTo(ScrollPhysics? ancestor) =>
      _PagePhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: .5, stiffness: 400, ratio: 1);
}

class _Shade extends StatelessWidget {
  const _Shade({required this.height, required this.top});
  final double height;
  final bool top;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: height,
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.topCenter : Alignment.bottomCenter,
          end: top ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [
            Color(top ? 0x8C000000 : 0xA6000000),
            const Color(0x00000000),
          ],
        ),
      ),
    ),
  );
}
