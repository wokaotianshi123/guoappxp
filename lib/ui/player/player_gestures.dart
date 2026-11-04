import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app_device.dart';
import '../../playback_session.dart';

/// 手势正在调节的对象。
enum SwipeAction { none, brightness, volume, seek }

/// 一次手势产生的 HUD 状态：亮度/音量给 0~1 的进度，快进快退只给一句话。
class GestureHudState {
  const GestureHudState({
    this.type = SwipeAction.none,
    this.value = 0,
    this.label = '',
  });
  final SwipeAction type;
  final double value;
  final String label;
}

/// 首次越过判定距离后锁定的滑动方向，避免斜着划时在「亮度」和「快进」之间跳。
enum _Axis { none, horizontal, vertical }

/// 播放器的触摸手势：左右滑动快进/快退，左半屏上下滑调亮度，右半屏上下滑调音量。
///
/// 单独抽出来是因为 [PlaybackSurface] 已经同时管着控制条、弹幕和弹窗焦点，
/// 手势状态（起点、方向锁、抑制 tap）自成一套，混进去会很难读。
class PlayerGestures extends ChangeNotifier {
  PlayerGestures({
    required this.session,
    this.seekStep = 15,
    this.brightnessZone = .5,
    this.volumeSwipe = true,
    this.requireHold = false,
  }) {
    unawaited(
      AppDevice.getBrightness().then((value) {
        if (!_disposed) {
          _brightness = value;
          notifyListeners();
        }
      }),
    );
  }

  final PlaybackSession session;

  /// 一次左右滑动快进/快退的秒数。
  final int seekStep;

  /// 亮度手势生效的左侧区域占播放区宽度的比例。
  ///
  /// 竖屏播放器外层是纵向翻页（上下滑动切集），播放页据此判断长按点
  /// 是否落在亮度区。
  final double brightnessZone;

  /// 右半屏上下滑动是否调音量。
  ///
  /// 竖屏播放器要保留「上下滑动切集」，所以传 false 关掉音量竖滑，
  /// 免得一次翻页顺带把音量改掉。
  final bool volumeSwipe;

  /// 是否必须「长按之后」才允许上下滑动调亮度。
  ///
  /// 竖屏播放器的短促上下滑是切集，直接吃掉竖滑会把切集手势废掉；
  /// 因此竖屏里先长按进入调节，再上下滑才改亮度。左右滑快进快退不受影响，
  /// 因为纵向翻页本来就不认横向手势。
  final bool requireHold;

  GestureHudState _hud = const GestureHudState();
  GestureHudState get hud => _hud;

  final Set<int> _pointers = {};
  int? _pointer;
  Offset? _origin;
  Offset? _last;
  double _viewHeight = 0;
  double _swipeThreshold = 70;
  double _horizontalThreshold = 60;
  double _brightness = .5;
  double _brightnessStart = .5;
  double _volumeStart = 100;
  bool _moved = false;
  bool _leftZone = false;
  bool _brightnessMode = false;
  bool _held = false;
  bool _disposed = false;
  _Axis _axis = _Axis.none;
  DateTime _ignoreTapUntil = DateTime(2000);
  Timer? _hudTimer;

  /// 手势刚结束时为 true：此时抬手不应被当成「点按」去切换控制条。
  bool get suppressTap => DateTime.now().isBefore(_ignoreTapUntil);

  /// [requireHold] 模式下，长按已开启本次手势的上下调节。
  bool get _canAdjust => _held || !requireHold;

  /// 长按开始：竖屏里先长按、再上下滑才调亮度，短促上下滑继续交给翻页切集。
  void hold() {
    if (_disposed || _held) return;
    _held = true;
    // 先亮一下当前亮度，让人知道现在上下滑有用。
    if (AppDevice.brightnessSupported) {
      _show(SwipeAction.brightness, _brightness);
    }
  }

  void pointerDown(
    PointerDownEvent event, {
    required double width,
    required double height,
  }) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1) {
      _reset();
      return;
    }
    if (!session.ready) return;
    _pointer = event.pointer;
    _origin = _last = event.localPosition;
    _viewHeight = height;
    _swipeThreshold = math.max(30, math.min(80, height * .08));
    _horizontalThreshold = width > 0
        ? math.max(40, math.min(120, width * .12))
        : 60;
    _moved = false;
    _axis = _Axis.none;
    _brightnessMode = false;
    // 只有触摸才有「哪半边」的概念；鼠标拖拽不做亮度/音量，免得误触。
    _leftZone =
        event.kind == PointerDeviceKind.touch &&
        width > 0 &&
        event.localPosition.dx < width * brightnessZone;
    _brightnessStart = _brightness;
    _volumeStart = session.player.state.volume;
  }

  void pointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _origin == null) return;
    _last = event.localPosition;
    final dx = event.localPosition.dx - _origin!.dx;
    // 向上滑动为增加，向下滑动为减少。
    final dy = _origin!.dy - event.localPosition.dy;
    final diff = event.localPosition - _origin!;
    if (diff.distance > 12) _moved = true;
    if (!_moved || _viewHeight <= 0) return;

    // 已经进入亮度档：只认上下滑动，左右滑动不再改判成快进。
    if (_brightnessMode) {
      final ratio = dy / (_viewHeight * .6);
      _brightness = (_brightnessStart + ratio).clamp(.01, 1.0);
      unawaited(AppDevice.setBrightness(_brightness));
      _show(SwipeAction.brightness, _brightness);
      return;
    }

    if (_axis == _Axis.none) {
      if (diff.distance < 16) return;
      _axis = dx.abs() > dy.abs() ? _Axis.horizontal : _Axis.vertical;
      // 左侧竖滑进入亮度档后，本次手势不再改判。
      if (_axis == _Axis.vertical &&
          _canAdjust &&
          _leftZone &&
          AppDevice.brightnessSupported) {
        _brightnessMode = true;
        _brightness = _brightnessStart;
        _show(SwipeAction.brightness, _brightness);
        return;
      }
    }

    if (_axis == _Axis.horizontal && dx.abs() >= _horizontalThreshold) {
      // 滑动途中只预览，抬手才真正跳转，免得一次滑动里反复 seek 拖死解码器。
      final forward = dx > 0;
      _show(SwipeAction.seek, 0, label: '${forward ? '快进' : '后退'} $seekStep 秒');
      return;
    }

    if (_axis == _Axis.vertical) {
      // 竖屏播放器的右半屏竖滑属于「上下滑动切集」，这里不接管音量。
      if (!volumeSwipe || !_canAdjust) return;
      // 竖向留一点死区，避免手指轻微抖动就把音量/亮度改掉。
      if (dy.abs() < _swipeThreshold) return;
      final ratio = dy / (_viewHeight * .6);
      final volume = (_volumeStart + ratio * 100).clamp(0.0, 100.0);
      session.setVolume(volume);
      _show(SwipeAction.volume, volume / 100);
    }
  }

  void pointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_pointer != event.pointer || _origin == null) {
      _reset();
      return;
    }
    final delta = (_last ?? event.localPosition) - _origin!;
    final horizontal =
        delta.dx.abs() >= _horizontalThreshold &&
        delta.dx.abs() > delta.dy.abs() * 1.5;

    if (_brightnessMode) {
      _dismissLater();
    } else if (_hud.type == SwipeAction.brightness) {
      // 长按后没怎么滑动就松手：只收起提示，亮度保持原样。
      _dismiss();
    } else if (_moved && horizontal && _axis == _Axis.horizontal) {
      _seek(delta.dx > 0 ? seekStep : -seekStep);
      _dismiss();
    } else if (_hud.type == SwipeAction.seek) {
      _dismiss();
    } else if (_hud.type == SwipeAction.volume) {
      _dismissLater();
    }

    if (_moved) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _reset();
  }

  void pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    _reset();
  }

  void _seek(int seconds) {
    final duration = session.player.state.duration;
    if (!session.ready || duration <= Duration.zero) return;
    final target = Duration(
      milliseconds:
          (session.player.state.position.inMilliseconds + seconds * 1000).clamp(
            0,
            duration.inMilliseconds,
          ),
    );
    unawaited(session.seekTo(target));
  }

  void _show(SwipeAction action, double value, {String label = ''}) {
    if (_disposed) return;
    _hudTimer?.cancel();
    final next = GestureHudState(type: action, value: value, label: label);
    if (next.type == _hud.type &&
        next.value == _hud.value &&
        next.label == _hud.label) {
      return;
    }
    _hud = next;
    notifyListeners();
  }

  void _dismissLater() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 800), _dismiss);
  }

  void _dismiss() {
    _hudTimer?.cancel();
    if (_disposed || _hud.type == SwipeAction.none) return;
    _hud = const GestureHudState();
    notifyListeners();
  }

  void _reset() {
    _pointer = null;
    _origin = null;
    _last = null;
    _axis = _Axis.none;
    _brightnessMode = false;
    _held = false;
  }

  /// 离开播放页时恢复窗口默认亮度。
  void restoreBrightness() => unawaited(AppDevice.resetBrightness());

  @override
  void dispose() {
    _disposed = true;
    _hudTimer?.cancel();
    _pointers.clear();
    restoreBrightness();
    super.dispose();
  }
}

/// 手势提示层：亮度条、音量条、快进/快退预览。容器恒为深色，文字必须显式白色。
class GestureHud extends StatelessWidget {
  const GestureHud({super.key, required this.state});
  final GestureHudState state;

  @override
  Widget build(BuildContext context) {
    if (state.type == SwipeAction.none) return const SizedBox.shrink();
    if (state.type == SwipeAction.seek) {
      final forward = !state.label.startsWith('后退');
      return IgnorePointer(
        child: Center(
          child: Container(
            width: 132,
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
            decoration: _panel,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  forward
                      ? Icons.fast_forward_rounded
                      : Icons.fast_rewind_rounded,
                  color: Colors.white,
                  size: 36,
                ),
                const SizedBox(height: 12),
                Text(
                  state.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: .5,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final brightness = state.type == SwipeAction.brightness;
    final value = state.value.clamp(0.0, 1.0);
    final icon = !brightness
        ? (value == 0
              ? Icons.volume_off_rounded
              : value < .5
              ? Icons.volume_down_rounded
              : Icons.volume_up_rounded)
        : value < .33
        ? Icons.brightness_low_rounded
        : value < .66
        ? Icons.brightness_medium_rounded
        : Icons.brightness_high_rounded;
    return IgnorePointer(
      child: Center(
        child: Container(
          width: 120,
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          decoration: _panel,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 36),
              const SizedBox(height: 14),
              SizedBox(
                width: 70,
                height: 6,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: value,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${brightness ? '亮度' : '音量'} ${(value * 100).round()}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: .5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static final _panel = BoxDecoration(
    color: Colors.black.withValues(alpha: .75),
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: Colors.white.withValues(alpha: .15)),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: .4),
        blurRadius: 18,
        spreadRadius: 2,
      ),
    ],
  );
}
