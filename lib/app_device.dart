import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppDevice {
  const AppDevice({this.television = false, this.version = ''});
  final bool television;
  final String version;
  static const channel = MethodChannel('duanju/device');
  static var _televisionMode = false;
  static var _phoneMode = false;

  static Future<AppDevice> detect({
    AppDevice fallback = const AppDevice(),
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      try {
        final info = await PackageInfo.fromPlatform();
        return AppDevice(version: info.version);
      } catch (_) {
        return fallback;
      }
    }
    try {
      final data = await channel
          .invokeMapMethod<String, dynamic>('deviceInfo')
          .timeout(const Duration(seconds: 2));
      final television = data?['television'];
      if (television is! bool) return fallback;
      final version = data?['version'];
      return AppDevice(
        television: television,
        version: version is String && version.isNotEmpty
            ? version
            : fallback.version,
      );
    } on PlatformException {
      return fallback;
    } on MissingPluginException {
      return fallback;
    } on TimeoutException {
      return fallback;
    }
  }

  /// 播放器手势的亮度调节能力。
  ///
  /// 只有 Android 由 MainActivity 提供窗口级亮度覆盖；桌面端与 iOS 没有
  /// 等价能力，手势里必须据此关掉亮度分支，避免出现「有条无效果」的假调节。
  static bool get brightnessSupported =>
      defaultTargetPlatform == TargetPlatform.android;

  /// 读取当前屏幕亮度（0.0 ~ 1.0）。非 Android 返回中性的 0.5。
  static Future<double> getBrightness() async {
    if (defaultTargetPlatform != TargetPlatform.android) return 0.5;
    try {
      final value = await channel.invokeMethod<double>('getBrightness');
      return (value ?? 0.5).clamp(0.0, 1.0);
    } catch (_) {
      return 0.5;
    }
  }

  static Future<void> setBrightness(double brightness) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await channel.invokeMethod('setBrightness', {
        'brightness': brightness.clamp(0.01, 1.0),
      });
    } catch (_) {}
  }

  /// 退出播放器时恢复窗口默认亮度，别把调暗的亮度留在整个应用上。
  static Future<void> resetBrightness() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await channel.invokeMethod('resetBrightness');
    } catch (_) {}
  }

  static Future<bool> compatibleRendering() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await channel.invokeMethod<bool>('compatibleRendering') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setCompatibleRendering(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      await channel.invokeMethod('setCompatibleRendering', {
        'enabled': enabled,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setTelevisionMode(bool enabled) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _televisionMode = enabled;
      return setPlayerOrientation(PlayerOrientation.auto);
    }
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await channel.invokeMethod<void>('setTelevisionMode', {
        'enabled': enabled,
      });
    } catch (_) {}
  }

  static Future<void> setPhoneMode(bool enabled) {
    _phoneMode = enabled;
    return releaseOrientation();
  }

  static Future<void> releaseOrientation() => setPlayerOrientation(
    _phoneMode ? PlayerOrientation.lockedPortrait : PlayerOrientation.auto,
  );

  static Future<void> setPlayerOrientation(
    PlayerOrientation orientation,
  ) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await channel.invokeMethod<void>('setPlayerOrientation', {
          'mode': orientation.name,
        });
      } catch (_) {}
      return;
    }
    try {
      await SystemChrome.setPreferredOrientations(switch (_televisionMode
          ? PlayerOrientation.landscape
          : orientation) {
        PlayerOrientation.landscape ||
        PlayerOrientation.lockedLandscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
        PlayerOrientation.portrait || PlayerOrientation.lockedPortrait =>
          const [DeviceOrientation.portraitUp],
        PlayerOrientation.auto => const [],
      });
    } catch (_) {}
  }

  static Future<({int level, bool charging})?> battery() async {
    try {
      final data = await channel.invokeMapMethod<String, dynamic>('battery');
      final level = data?['level'];
      if (level is! int) return null;
      return (level: level, charging: data?['charging'] == true);
    } catch (_) {
      return null;
    }
  }

  /// 让 Windows runner 修一次输入法上下文。
  ///
  /// Flutter 3.47.x 的 Windows 嵌入层在窗口失焦再回来后，子窗口的 IMM32→TSF
  /// 会话会过期：键盘消息照常到达，但中文候选框再也不出现，表现为「只能输入
  /// 字母」（flutter/flutter#190042）。runner 在窗口重新获得焦点时已经会修，
  /// 这里再补一次「输入框拿到焦点」的触发，覆盖窗口一直有焦点、只是应用内换了
  /// 输入框的场景。其它平台没有这个方法，调用失败直接忽略。
  static Future<void> repairIme() async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await channel.invokeMethod<void>('repairIme');
    } catch (_) {
      // 旧版 runner 没有这个方法，或当前不是 Windows 原生宿主，忽略即可。
    }
  }
}

enum PlayerOrientation {
  landscape,
  lockedLandscape,
  portrait,
  lockedPortrait,
  auto,
}
