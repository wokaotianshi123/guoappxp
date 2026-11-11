import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core_bridge.dart';
import '../playback_session.dart' show videoDisplaySize;
import 'live_models.dart';
import 'live_repository.dart';
import 'live_sources.dart';

/// 直播播放状态：频道列表页的顶部预览与全屏播放页共用同一实例，换台不重建引擎。
class LivePlaybackController extends ChangeNotifier {
  LivePlaybackController({required this.repository});

  static const maxRetries = 3;
  static const _reconnectDelay = Duration(seconds: 2);

  /// 起播后迟迟没有画面的判定时限。列表型直播源的代理线路会返回正常清单却
  /// 一直卡在缓冲，不触发错误事件，只靠 error 回调永远等不到换线。
  static const _stallTimeout = Duration(seconds: 15);

  final LiveRepository repository;

  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _reconnect;
  Timer? _stall;
  bool _frames = false;
  double _aspectRatio = 16 / 9;

  Player? _player;
  VideoController? _controller;
  LiveSource? _source;
  List<LiveChannel> _channels = const [];
  int _index = 0;
  int _generation = 0;
  int _retries = 0;
  int _route = 0;
  bool _loading = false;
  bool _buffering = false;
  bool _paused = false;
  bool _disposed = false;
  String? _error;

  Player? get player => _player;
  VideoController? get controller => _controller;
  LiveSource? get source => _source;
  List<LiveChannel> get channels => _channels;
  LiveChannel? get channel => _channels.isEmpty
      ? null
      : _channels[_index.clamp(0, _channels.length - 1)];
  int get index => _index;
  int get count => _channels.length;
  bool get loading => _loading;
  bool get buffering => _buffering;
  bool get ready => _player != null;
  bool get paused => _paused;
  int get route => _route;
  // 房间型源（斗鱼 / 哔哩哔哩 / 虎牙）在点击时才解析真实地址，
  // 列表里没有多条线路；仍按「一条线路」显示，避免出现 1/0。
  int get routeCount {
    final urls = channel?.urls.length ?? 0;
    return urls > 0 ? urls : 1;
  }

  String? get error => _error;
  double get aspectRatio => _aspectRatio;

  void _ensurePlayer() {
    if (_player != null || _disposed) return;
    final player = Player();
    _player = player;
    // 直播流对 mpv 是非可寻址（non-seekable）源，demuxer 打开时会在 OSD/日志里
    // 打印 “not seekable”。设为 yes 后用缓存强行可寻址，也支持直播内拖动。
    final platform = player.platform;
    if (platform is NativePlayer) {
      unawaited(
        platform
            .setProperty('force-seekable', 'yes', waitForInitialization: true)
            .catchError((Object _) {}),
      );
    }
    _controller = VideoController(player);
    _subscriptions.add(player.stream.error.listen(_onError));
    _subscriptions.add(
      player.stream.buffering.listen((value) {
        if (_disposed || value == _buffering) return;
        _buffering = value;
        if (!value && player.state.playing) {
          _stall?.cancel();
        }
        notifyListeners();
      }),
    );
    _subscriptions.add(
      player.stream.playing.listen((value) {
        if (_disposed) return;
        _paused = !value;
        if (!value) {
          notifyListeners();
          return;
        }
        _stall?.cancel();
        if (_error == null) {
          notifyListeners();
          return;
        }
        _error = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      player.stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (_disposed || size == null) return;
        _frames = true;
        _stall?.cancel();
        final ratio = size.width / size.height;
        if (ratio.isFinite &&
            ratio > 0 &&
            (ratio - _aspectRatio).abs() > 0.01) {
          _aspectRatio = ratio;
          notifyListeners();
        }
      }),
    );
  }

  bool get _hasPlayback {
    final player = _player;
    if (player == null) return false;
    if (_frames) return true;
    return player.state.playing && !player.state.buffering;
  }

  void _armStallWatch() {
    _stall?.cancel();
    _stall = Timer(_stallTimeout, () {
      if (_disposed || _error != null) return;
      // playing 事件与布防存在竞态：事件先到再布防时计时器无人取消，
      // 必须在触发时复核真实播放状态，避免正常播放被误判断流。
      if (_hasPlayback) return;
      _onError('当前线路长时间没有画面');
    });
  }

  /// 切换直播源或分类：重置频道表并按需播放第一条。
  Future<void> load(
    LiveSource source,
    List<LiveChannel> channels, {
    int index = 0,
    bool autoplay = true,
  }) async {
    _source = source;
    _channels = List.of(channels);
    _index = channels.isEmpty ? 0 : index.clamp(0, channels.length - 1);
    _retries = 0;
    _route = 0;
    _error = null;
    if (!autoplay || channels.isEmpty) {
      notifyListeners();
      return;
    }
    try {
      _ensurePlayer();
    } catch (error) {
      _error = '直播播放器无法启动：$error';
      notifyListeners();
      return;
    }
    await play(_index);
  }

  Future<void> play(int index, {bool reconnect = false}) async {
    if (_disposed || _channels.isEmpty) return;
    final channel = _channels[index.clamp(0, _channels.length - 1)];
    final source = _source;
    if (source == null) return;
    if (!reconnect) _retries = 0;
    if (!reconnect && index != _index) _route = 0;
    final token = ++_generation;
    _index = index;
    _loading = true;
    if (!reconnect) _error = null;
    notifyListeners();
    try {
      _ensurePlayer();
      final player = _player;
      if (player == null) throw AppFailure('直播播放器无法启动');
      final plan = await _resolve(source, channel);
      if (_disposed || token != _generation) return;
      _frames = false;
      await _applyUserAgent(plan.headers);
      await player.open(
        Media(
          plan.url,
          httpHeaders: plan.headers.isEmpty ? null : plan.headers,
        ),
      );
      if (_disposed || token != _generation) return;
      _loading = false;
      _error = null;
      _paused = false;
      // 直播没有进度条提醒用户，屏幕自动熄灭会被当成「播放失败」，
      // 起播成功后保持常亮，退出播放页时还原。
      unawaited(_keepAwake(true));
      _armStallWatch();
      notifyListeners();
    } catch (error) {
      if (_disposed || token != _generation) return;
      _loading = false;
      _error = '$error';
      notifyListeners();
    }
  }

  /// 把媒体头里的 User-Agent 同步给 mpv。
  ///
  /// media_kit 只把 headers 塞进 mpv 的 `http-header-fields`，而 mpv 自己还会
  /// 按 `user-agent` 选项（默认 libmpv）再发一个 UA 并覆盖前者。虎牙 CDN 校验
  /// 请求方身份，UA 不对就只给几秒画面，所以这里显式设置一次。
  Future<void> _applyUserAgent(Map<String, String> headers) async {
    final platform = _player?.platform;
    if (platform is! NativePlayer) return;
    var agent = liveUserAgent;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != 'user-agent') continue;
      final value = entry.value.trim();
      if (value.isNotEmpty) agent = value;
      break;
    }
    try {
      await platform.setProperty(
        'user-agent',
        agent,
        waitForInitialization: true,
      );
    } catch (_) {
      // 个别平台的 mpv 构建把 user-agent 当只读选项，失败时沿用默认值。
    }
  }

  /// 直连型直播源（面板 / 列表）支持在同一频道内切换线路。
  Future<LivePlayback> _resolve(LiveSource source, LiveChannel channel) {
    final multiRoute =
        source.protocol == LiveProtocol.pingtai ||
        source.protocol == LiveProtocol.list;
    if (_route > 0 && multiRoute && channel.urls.length > _route) {
      return Future.value(
        LivePlayback(url: channel.urls[_route], headers: channel.headers),
      );
    }
    return repository.playback(source, channel);
  }

  /// 切换到指定线路并重新播放。
  Future<void> playRoute(int route) {
    _route = route < 0 ? 0 : route;
    return play(_index);
  }

  /// 上一台 / 下一台，越界时环绕。
  void switchBy(int delta) {
    if (_channels.length < 2) return;
    final next = (_index + delta + _channels.length) % _channels.length;
    unawaited(play(next));
  }

  Future<void> retry() => play(_index, reconnect: true);

  void togglePause() {
    final player = _player;
    if (player == null) return;
    _paused = !_paused;
    unawaited(_paused ? player.pause() : player.play());
    notifyListeners();
  }

  /// 保持屏幕常亮。部分平台（无原生实现的桌面环境）会抛异常，直接吞掉。
  Future<void> _keepAwake(bool enabled) async {
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {}
  }

  void _onError(String message) {
    if (_disposed) return;
    _loading = false;
    _error = message.isEmpty ? '直播中断' : message;
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    final channel = this.channel;
    // 线路数多于固定重试次数时必须走完整批线路：列表型源的可用线路可能排在
    // 最后一条，只允许推进 3 次就永远够不到它。
    final routes = channel?.urls.length ?? 0;
    final limit = routes > 1 ? routes : maxRetries;
    if (_retries >= limit) return;
    _retries++;
    // 实测列表型直播源的代理线路质量波动很大（同一批前缀会交替返回
    // 404/500 或掉到十几 KB/s），重连必须换线路。
    if (channel != null && channel.urls.length > 1) {
      _route = (_route + 1) % channel.urls.length;
    }
    _reconnect?.cancel();
    _reconnect = Timer(_reconnectDelay, () {
      if (!_disposed) unawaited(play(_index, reconnect: true));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_keepAwake(false));
    _reconnect?.cancel();
    _stall?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _player?.dispose();
    _player = null;
    _controller = null;
    super.dispose();
  }
}
