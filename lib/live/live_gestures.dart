import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset, PointerDeviceKind;

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/gestures.dart'
    show PointerCancelEvent, PointerDownEvent, PointerMoveEvent, PointerUpEvent;
import 'package:media_kit/media_kit.dart' show Player;

import '../app_device.dart';
import '../ui/player/player_gestures.dart' show GestureHudState, SwipeAction;
import 'live_playback.dart';

/// 首次越过判定距离后锁定的滑动方向，避免斜着划时误改亮度/音量。
enum _Axis { none, horizontal, vertical }

/// 直播播放页的触摸手势：长按成立后，左半屏上下滑调亮度、右半屏上下滑调音量。
///
/// 与点播的 PlayerGestures 分开实现：直播没有进度条，不做左右滑快进；而且
/// 竖滑只在「长按成立」之后才接管，避免单击显示控制条、返回等动作被误判。
/// 亮度走 [AppDevice] 的窗口级覆盖，音量改 mpv 的播放器音量，两者都只在本次
/// 观看生效（退出页面时恢复窗口亮度，音量不写存档）。
class LiveGestureController extends ChangeNotifier {
  LiveGestureController({required this.playback}) {
    unawaited(
      AppDevice.getBrightness().then((value) {
        if (!_disposed) {
          _brightness = value;
          notifyListeners();
        }
      }),
    );
  }

  final LivePlaybackController playback;

  GestureHudState _hud = const GestureHudState();
  GestureHudState get hud => _hud;

  final Set<int> _pointers = <int>{};
  int? _pointer;
  Offset? _origin;
  double _viewWidth = 0;
  double _viewHeight = 0;
  double _swipeThreshold = 70;
  double _brightness = .5;
  double _brightnessStart = .5;
  double _volumeStart = 100;
  bool _touch = false;
  bool _moved = false;
  bool _leftZone = false;
  bool _held = false;
  SwipeAction _mode = SwipeAction.none;
  _Axis _axis = _Axis.none;
  bool _disposed = false;
  DateTime _ignoreTapUntil = DateTime(2000);
  Timer? _hudTimer;

  /// 手势刚结束时为 true：此时抬手不应被当成「点按」去切换控制条。
  bool get suppressTap => DateTime.now().isBefore(_ignoreTapUntil);

  /// 长按成立：按落点锁定「左亮度 / 右音量」，并先亮一下当前值提示可以滑动。
  ///
  /// 只有触摸才接管；鼠标拖拽不做亮度/音量，免得桌面端误触。
  void hold(Offset localPosition) {
    if (_disposed || _held || _pointer == null || !_touch) return;
    final Player? player = playback.player;
    if (player == null) return;
    _held = true;
    _leftZone = _viewWidth > 0 ? localPosition.dx < _viewWidth * .5 : _leftZone;
    if (_leftZone) {
      // 非 Android 没有窗口亮度能力，左侧竖滑直接放弃，避免出现「有条无效果」
      // 的假调节；右侧音量由 mpv 提供，任何平台都可用。
      if (!AppDevice.brightnessSupported) return;
      _brightnessStart = _brightness;
      _show(SwipeAction.brightness, _brightness);
    } else {
      _volumeStart = player.state.volume;
      _show(SwipeAction.volume, _volumeStart / 100);
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
    _pointer = event.pointer;
    _origin = event.localPosition;
    _viewWidth = width;
    _viewHeight = height;
    _swipeThreshold = math.max(30, math.min(80, height * .08));
    _touch = event.kind == PointerDeviceKind.touch;
    _leftZone = width > 0 && event.localPosition.dx < width * .5;
    _brightnessStart = _brightness;
    _volumeStart = playback.player?.state.volume ?? 100;
    _moved = false;
    _held = false;
    _mode = SwipeAction.none;
    _axis = _Axis.none;
  }

  void pointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _origin == null) return;
    final diff = event.localPosition - _origin!;
    if (diff.distance > 12) _moved = true;
    // 长按未成立、鼠标或尺寸未知时不接管竖滑。
    if (!_held || !_touch || _viewHeight <= 0) return;
    // 向上滑动为增加，向下滑动为减少。
    final dy = _origin!.dy - event.localPosition.dy;
    if (_axis == _Axis.none) {
      if (diff.distance < 16) return;
      _axis = diff.dx.abs() > dy.abs() ? _Axis.horizontal : _Axis.vertical;
      _mode = _leftZone ? SwipeAction.brightness : SwipeAction.volume;
      if (_mode == SwipeAction.brightness && !AppDevice.brightnessSupported) {
        _axis = _Axis.horizontal;
      }
    }
    if (_axis != _Axis.vertical) return;
    // 竖向留一点死区，避免手指轻微抖动就把亮度/音量改掉。
    if (dy.abs() < _swipeThreshold) return;
    final ratio = dy / (_viewHeight * .6);
    final Player? player = playback.player;
    if (_mode == SwipeAction.brightness) {
      _brightness = (_brightnessStart + ratio).clamp(.01, 1.0);
      unawaited(AppDevice.setBrightness(_brightness));
      _show(SwipeAction.brightness, _brightness);
    } else if (player != null) {
      final volume = (_volumeStart + ratio * 100).clamp(0.0, 100.0);
      unawaited(player.setVolume(volume));
      _show(SwipeAction.volume, volume / 100);
    }
  }

  void pointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_pointer != event.pointer || _origin == null) {
      _reset();
      return;
    }
    // 长按提示 / 调节条留一点余韵，抬手立刻消失会看不清最终数值。
    if (_hud.type != SwipeAction.none) _dismissLater();
    if (_moved) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _reset();
  }

  void pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    _dismiss();
    _reset();
  }

  void _show(SwipeAction action, double value) {
    if (_disposed) return;
    _hudTimer?.cancel();
    final next = GestureHudState(type: action, value: value);
    if (next.type == _hud.type && next.value == _hud.value) return;
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
    _axis = _Axis.none;
    _mode = SwipeAction.none;
    _held = false;
    _moved = false;
    _touch = false;
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
