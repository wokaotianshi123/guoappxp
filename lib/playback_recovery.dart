import 'models.dart';

enum PlaybackRecoveryAction { alternative, refresh, stop }

class PlaybackRecovery {
  static const maxAttempts = 3;
  int _attempts = 0;
  bool _refreshed = false;

  void reset() {
    _attempts = 0;
    _refreshed = false;
  }

  PlaybackRecoveryAction next(PlaybackPlan plan) {
    if (_attempts >= maxAttempts) {
      return PlaybackRecoveryAction.stop;
    }
    if (plan.hasAlternative) {
      _attempts++;
      return PlaybackRecoveryAction.alternative;
    }
    if (!_refreshed) {
      _attempts++;
      _refreshed = true;
      return PlaybackRecoveryAction.refresh;
    }
    return PlaybackRecoveryAction.stop;
  }
}

class PlaybackHealth {
  static const stallTimeout = Duration(seconds: 20);
  Duration? _position;
  DateTime? _lastProgress;
  bool _sawProgress = false;

  /// 播放期间是否真的收到过进度变化。部分电视 / 硬解设备根本不发 position
  /// 事件，此时「进度没动」不是卡死的证据，不能拿它触发重新加载。
  bool get sawProgress => _sawProgress;

  void reset() {
    _position = null;
    _lastProgress = null;
    _sawProgress = false;
  }

  bool stalled({
    required Duration position,
    required bool playing,
    required bool foreground,
    required DateTime now,
    // 缓冲中进度本来就不动，不能算卡死；TV 硬件解码起播时尤其容易误判。
    bool buffering = false,
  }) {
    if (!playing || !foreground || buffering || position != _position) {
      if (playing && foreground && !buffering && _position != null) {
        _sawProgress = true;
      }
      _position = position;
      _lastProgress = now;
      return false;
    }
    if (!_sawProgress) {
      _lastProgress = now;
      return false;
    }
    _lastProgress ??= now;
    return now.difference(_lastProgress!) >= stallTimeout;
  }
}
