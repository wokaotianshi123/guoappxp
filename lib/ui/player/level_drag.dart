import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_device.dart';

enum LevelKind { brightness, volume }

/// 竖屏播放页两侧的亮度/音量竖滑条。
///
/// 竖屏整页是「上下滑切集」的 PageView，所以亮度和音量只挂在左右两条窄边上，
/// 手指落在边上时由本组件接管竖滑（PageView 收不到这一笔），中间区域照常翻页。
/// 点按不拦截：`HitTestBehavior.translucent` 让下面的「点一下暂停 / 长按倍速」继续生效。
class LevelDrag extends StatefulWidget {
  const LevelDrag({
    super.key,
    required this.kind,
    required this.alignment,
    this.width = 64,
  });
  final LevelKind kind;

  /// HUD 贴哪一侧（Alignment.centerLeft / centerRight）。
  final Alignment alignment;
  final double width;

  static bool supports(LevelKind kind) => switch (kind) {
    LevelKind.brightness => AppDevice.brightnessSupported,
    LevelKind.volume => true,
  };

  @override
  State<LevelDrag> createState() => _LevelDragState();
}

class _LevelDragState extends State<LevelDrag> {
  double? _value;
  double _pending = 0;
  bool _dragging = false;

  bool get _brightness => widget.kind == LevelKind.brightness;

  Future<void> _start(DragStartDetails _) async {
    setState(() {
      _dragging = true;
      _value = null;
      _pending = 0;
    });
    final value = await (_brightness ? AppDevice.brightness() : AppDevice.volume());
    if (!mounted || !_dragging) return;
    if (value == null) {
      setState(() => _dragging = false);
      return;
    }
    _apply(value + _pending);
  }

  void _update(DragUpdateDetails details) {
    if (!_dragging) return;
    final height = context.size?.height ?? MediaQuery.sizeOf(context).height;
    final delta = height <= 0 ? 0.0 : -details.delta.dy / height;
    if (_value case final value?) {
      _apply(value + delta);
    } else {
      _pending += delta;
    }
  }

  void _apply(double value) {
    final next = value.clamp(0.0, 1.0);
    setState(() => _value = next);
    unawaited(
      _brightness ? AppDevice.setBrightness(next) : AppDevice.setVolume(next),
    );
  }

  void _end() {
    if (!_dragging) return;
    setState(() {
      _dragging = false;
      _value = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!LevelDrag.supports(widget.kind)) {
      return const SizedBox.shrink();
    }
    final value = _value;
    return SizedBox(
      width: widget.width,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (details) => unawaited(_start(details)),
            onVerticalDragUpdate: _update,
            onVerticalDragEnd: (_) => _end(),
            onVerticalDragCancel: _end,
          ),
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: value == null ? 0 : 1,
              duration: const Duration(milliseconds: 140),
              child: Align(
                alignment: widget.alignment,
                child: _hud(context, value ?? 0),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hud(BuildContext context, double value) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 6),
    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        Icon(
          _brightness
              ? (value < .34
                    ? Icons.brightness_low_rounded
                    : value < .67
                    ? Icons.brightness_medium_rounded
                    : Icons.brightness_high_rounded)
              : value == 0
              ? Icons.volume_off_rounded
              : Icons.volume_up_rounded,
          size: 18,
          color: Colors.white,
        ),
        SizedBox(
          width: 6,
          height: 96,
          child: RotatedBox(
            quarterTurns: 3,
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
              color: Colors.white,
              backgroundColor: Colors.white.withValues(alpha: .25),
            ),
          ),
        ),
        Text(
          '${(value * 100).round()}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}
