import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../app_device.dart';
import '../ui/player/player_gestures.dart' show GestureHud;
import '../ui/widgets/focus_ring.dart';
import 'live_gestures.dart';
import 'live_models.dart';
import 'live_playback.dart';
import 'live_repository.dart';
import 'live_sources.dart';
import 'live_store.dart';

/// 直播全屏播放页。
///
/// 与点播播放器分开实现：直播没有进度、集数与清晰度概念，控制项只有换台、
/// 换线路、暂停、收藏与全屏，避免把点播那一套状态机套到直播流上。
class LivePlayerPage extends StatefulWidget {
  const LivePlayerPage({
    super.key,
    required this.repository,
    required this.store,
    required this.source,
    required this.channels,
    this.index = 0,
  });
  final LiveRepository repository;
  final LiveStore store;
  final LiveSource source;
  final List<LiveChannel> channels;
  final int index;

  @override
  State<LivePlayerPage> createState() => _LivePlayerPageState();
}

class _LivePlayerPageState extends State<LivePlayerPage> {
  late final LivePlaybackController _playback;
  late final LiveGestureController _gestures;
  Timer? _hide;
  var _visible = true;
  bool _fullscreen = false;

  /// 当前已下发给原生层的全屏方向，用于画面比例变化时判断要不要重新锁定。
  PlayerOrientation? _appliedOrientation;

  @override
  void initState() {
    super.initState();
    _playback = LivePlaybackController(repository: widget.repository)
      ..addListener(_changed);
    _gestures = LiveGestureController(playback: _playback);
    unawaited(
      _playback.load(widget.source, widget.channels, index: widget.index),
    );
    _scheduleHide();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _playback.removeListener(_changed);
    _gestures.dispose();
    _playback.dispose();
    _restorePresentation();
    super.dispose();
  }

  /// 按视频真实宽高比决定全屏方向：宽于高的画面锁横屏，竖屏/方形画面锁竖屏。
  /// 用 locked 变体而不是可随传感器解除的 landscape/portrait，保证 Flutter 的
  /// 全屏状态与原生方向始终一致。
  PlayerOrientation get _targetOrientation => _playback.aspectRatio > 1
      ? PlayerOrientation.lockedLandscape
      : PlayerOrientation.lockedPortrait;

  String get _orientationText {
    final ratio = _playback.aspectRatio;
    final label = ratio > 1 ? '横屏' : '竖屏';
    return '$label画面 · ${ratio.toStringAsFixed(2)} : 1';
  }

  String get _fullscreenTooltip {
    if (_fullscreen) return '退出全屏';
    return _playback.aspectRatio > 1 ? '横屏全屏' : '竖屏全屏';
  }

  void _changed() {
    if (!mounted) return;
    // 换台后画面比例可能从横屏切成竖屏（或反过来）：全屏状态跟着重新锁定，
    // 不必先退出全屏再点一次。
    if (_fullscreen) {
      final target = _targetOrientation;
      if (target != _appliedOrientation) {
        _appliedOrientation = target;
        unawaited(AppDevice.setPlayerOrientation(target));
      }
    }
    setState(() {});
  }

  /// 切换全屏时同步系统方向栏与状态栏。Windows 走窗口全屏，不碰屏幕方向。
  void _applyPresentation(bool full) {
    _appliedOrientation = full ? _targetOrientation : null;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(windowManager.setFullScreen(full).catchError((Object _) {}));
      return;
    }
    if (full) {
      unawaited(AppDevice.setPlayerOrientation(_targetOrientation));
    } else {
      unawaited(AppDevice.releaseOrientation());
    }
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ).catchError((Object _) {}),
    );
  }

  /// 离开页面时还原方向栏与系统栏，避免把横屏/沉浸式状态带回列表页。
  void _restorePresentation() {
    if (!_fullscreen) return;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(windowManager.setFullScreen(false).catchError((Object _) {}));
      return;
    }
    unawaited(AppDevice.releaseOrientation());
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
      ).catchError((Object _) {}),
    );
  }

  void _toggleFullscreen() {
    final full = !_fullscreen;
    setState(() => _fullscreen = full);
    _applyPresentation(full);
    _reveal();
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted && _visible) setState(() => _visible = false);
    });
  }

  void _reveal() {
    setState(() => _visible = true);
    _scheduleHide();
  }

  void _toggleControls() {
    if (_visible) {
      _hide?.cancel();
      setState(() => _visible = false);
    } else {
      _reveal();
    }
  }

  LiveChannel? get _channel => _playback.channel;

  @override
  Widget build(BuildContext context) {
    final channel = _channel;
    // 全屏时先按返回键退出全屏，第二次返回才离开播放页。
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _video(),
            Positioned.fill(child: _gestureLayer()),
            if (_playback.loading)
              const Center(
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            if (_playback.error case final error? when !_playback.loading)
              Center(child: _errorPanel(error)),
            // HUD 本身不接收点击，整层再包一层 IgnorePointer 保证事件穿透到手势层。
            IgnorePointer(
              child: AnimatedBuilder(
                animation: _gestures,
                builder: (context, _) => GestureHud(state: _gestures.hud),
              ),
            ),
            AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_visible,
                child: _controls(channel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 手势层：原始指针事件交给 [LiveGestureController]，单击与长按交给
  /// GestureDetector。长按成立后才允许竖向滑动改亮度/音量。
  Widget _gestureLayer() => LayoutBuilder(
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
        onTap: () {
          if (_gestures.suppressTap) return;
          _toggleControls();
        },
        onLongPressStart: (details) => _gestures.hold(details.localPosition),
      ),
    ),
  );

  Widget _video() {
    final controller = _playback.controller;
    if (controller == null) return const SizedBox.shrink();
    final video = Video(
      controller: controller,
      controls: NoVideoControls,
      pauseUponEnteringBackgroundMode: false,
    );
    // 全屏时让画面铺满屏幕（Video 内部按原始比例居中，不会拉伸）；未全屏时
    // 按视频比例居中，与频道列表的预览观感一致。
    if (_fullscreen) return SizedBox.expand(child: video);
    return Center(
      child: AspectRatio(aspectRatio: _playback.aspectRatio, child: video),
    );
  }

  Widget _errorPanel(String error) {
    return Container(
      width: 420,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded, color: Colors.white70, size: 36),
          const SizedBox(height: 10),
          const Text(
            '直播中断',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            error,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: () => unawaited(_playback.retry()),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _controls(LiveChannel? channel) {
    final favourite = channel != null && widget.store.isFavourite(channel.key);
    final multi = _playback.routeCount > 1;
    // 底部那一排（上一台 / 暂停 / 下一台）原来固定贴着 bottom:16，在手机横屏里正好
    // 压在 iOS Home 指示条、Android 手势条（甚至三键导航栏）上，既难点也容易误触。
    // 这里把视图安全区加进去：横向还要避开刘海/挖孔所在的左右安全区。
    final insets = MediaQuery.viewPaddingOf(context);
    final bottom = 16 + insets.bottom;
    final left = 16 + insets.left;
    final right = 16 + insets.right;
    return Stack(
      fit: StackFit.expand,
      children: [
        const _Shade(top: true),
        const _Shade(top: false),
        Positioned(
          left: left,
          right: right,
          top: 12 + insets.top,
          child: Row(
            spacing: 8,
            children: [
              _round(
                Icons.arrow_back_rounded,
                '返回',
                () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      channel?.label ?? '直播',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        shadows: [
                          Shadow(color: Color(0x66000000), blurRadius: 3),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    // 实时标出画面比例与将进入的全屏方向，方便判断横竖屏。
                    Text(
                      _orientationText,
                      maxLines: 1,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        shadows: [
                          Shadow(color: Color(0x66000000), blurRadius: 3),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _round(
                favourite ? Icons.star_rounded : Icons.star_border_rounded,
                favourite ? '取消收藏' : '收藏',
                channel == null
                    ? null
                    : () => unawaited(widget.store.toggleFavourite(channel)),
              ),
              // 全屏按钮的目标方向由当前视频比例决定，比例变化时 tooltip 同步更新。
              _round(
                _fullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                _fullscreenTooltip,
                _toggleFullscreen,
              ),
            ],
          ),
        ),
        Positioned(
          left: left,
          right: right,
          bottom: bottom,
          child: Row(
            spacing: 10,
            children: [
              _round(
                Icons.skip_previous_rounded,
                '上一台',
                _playback.channels.length < 2
                    ? null
                    : () {
                        _playback.switchBy(-1);
                        _reveal();
                      },
              ),
              _round(
                _playback.paused
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
                _playback.paused ? '播放' : '暂停',
                () {
                  _playback.togglePause();
                  _reveal();
                },
                strong: true,
              ),
              _round(
                Icons.skip_next_rounded,
                '下一台',
                _playback.channels.length < 2
                    ? null
                    : () {
                        _playback.switchBy(1);
                        _reveal();
                      },
              ),
              const Spacer(),
              if (_playback.count > 0)
                Text(
                  '${_playback.index + 1} / ${_playback.count}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              if (multi)
                _pill(
                  '线路 ${_playback.route + 1}/${_playback.routeCount}',
                  '切换线路',
                  () {
                    final next = (_playback.route + 1) % _playback.routeCount;
                    unawaited(_playback.playRoute(next));
                    _reveal();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _round(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    bool strong = false,
  }) => FocusRing(
    radius: 999,
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: strong
            ? Colors.white.withValues(alpha: .22)
            : Colors.black.withValues(alpha: .42),
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white38,
        minimumSize: Size.square(strong ? 52 : 44),
      ),
      icon: Icon(icon),
    ),
  );

  Widget _pill(String text, String tooltip, VoidCallback onPressed) =>
      FocusRing(
        radius: 999,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            backgroundColor: Colors.black.withValues(alpha: .42),
            foregroundColor: Colors.white,
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          child: Text(text),
        ),
      );
}

class _Shade extends StatelessWidget {
  const _Shade({required this.top});
  final bool top;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    top: top ? 0 : null,
    bottom: top ? null : 0,
    height: 120,
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: const [Color(0x99000000), Color(0x00000000)],
          ),
        ),
      ),
    ),
  );
}
