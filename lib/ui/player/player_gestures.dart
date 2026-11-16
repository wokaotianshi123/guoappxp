import 'package:flutter/material.dart';

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

/// 手势提示层：亮度条、音量条、快进/快退预览。容器恒为深色，文字必须显式白色。
///
/// 直播页（lib/live/live_gestures.dart）复用这里的展示层，手势状态机在那边自己管；
/// 短剧播放页的手势由 SwipeControls 内部处理，不经过这个组件。
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
