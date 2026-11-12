import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../playback_preferences.dart';
import '../../playback_session.dart';
import '../app_scope.dart';
import '../theme/app_theme.dart';
import '../widgets/cover_image.dart';
import 'danmaku_overlay.dart';
import 'playback_handle.dart';
import 'player_surface.dart';
import 'player_video.dart';

enum _Menu { speed, quality, route, fit }

/// 弹出菜单里每行的高度（选项 44 + 间距 2），用来把选中项滚进可视区。
const _menuRowExtent = 46.0;
const _episodeCellHeight = 52.0;
const _episodeGap = 8.0;
const _episodeRowExtent = _episodeCellHeight + _episodeGap;

final _arrows = {
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
};

final _confirms = {
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.gameButtonA,
};

class TelevisionPlayerPage extends StatefulWidget {
  const TelevisionPlayerPage({
    super.key,
    required this.handle,
    this.videoSurface,
  });
  final PlaybackHandle handle;

  /// 仅供 widget test：替换底层 Video 画面，测试环境没有 media_kit 纹理。
  final Widget Function(Player player)? videoSurface;

  @override
  State<TelevisionPlayerPage> createState() => _TelevisionPlayerPageState();
}

class _TelevisionPlayerPageState extends State<TelevisionPlayerPage>
    with WidgetsBindingObserver {
  final _surface = FocusNode(debugLabel: 'tv-player');
  final _bar = FocusNode(debugLabel: 'tv-player-bar');
  final _previous = FocusNode();
  final _play = FocusNode();
  final _next = FocusNode();
  final _danmaku = FocusNode();
  final _adBlock = FocusNode();
  final _episodes = FocusNode(debugLabel: 'tv-player-episodes');
  final _route = FocusNode(debugLabel: 'tv-player-route');
  final _speed = FocusNode();
  final _quality = FocusNode();
  final _fit = FocusNode();
  final _retry = FocusNode();
  final _options = <FocusNode>[];
  final _episodeNodes = <FocusNode>[];
  final _menuScroll = ScrollController();
  final _episodeScroll = ScrollController();
  final _links = {for (final menu in _Menu.values) menu: LayerLink()};
  StreamSubscription<bool>? _playing;
  Player? _bound;
  Timer? _hideTimer;
  Timer? _seekCommit;
  Timer? _seekDisplay;
  Timer? _foregroundTimer;
  bool _visible = true;
  bool _failed = false;
  bool _episodePanel = false;
  int _episodeColumns = 6;
  _Menu? _menu;
  Duration? _seekTarget;
  Duration _seekFrom = Duration.zero;
  int _seekOffset = 0;
  bool _seekShown = false;

  PlaybackSession get _session => widget.handle.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.addListener(_changed);
    _changed();
    _scheduleHide();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _play.requestFocus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_changed);
    unawaited(_playing?.cancel());
    _hideTimer?.cancel();
    _seekCommit?.cancel();
    _seekDisplay?.cancel();
    _foregroundTimer?.cancel();
    for (final node in [
      _surface,
      _bar,
      _previous,
      _play,
      _next,
      _danmaku,
      _adBlock,
      _episodes,
      _route,
      _speed,
      _quality,
      _fit,
      _retry,
      ..._options,
      ..._episodeNodes,
    ]) {
      node.dispose();
    }
    _menuScroll.dispose();
    _episodeScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Windows 窗口失焦只发 inactive；TV 全屏切换、系统弹层、遥控器焦点变化
    // 也会让 App 瞬间 inactive。立刻按「进入后台」暂停，会把刚加载成功的
    // 播放打断，回到前台后又触发自动恢复，表现成反复重新加载直至失败。
    final foreground =
        state == AppLifecycleState.resumed ||
        defaultTargetPlatform == TargetPlatform.windows &&
            state == AppLifecycleState.inactive;
    _foregroundTimer?.cancel();
    if (foreground) {
      _session.setForeground(true);
      return;
    }
    _foregroundTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) _session.setForeground(false);
    });
  }

  void _changed() {
    final player = _session.player;
    if (!identical(player, _bound)) {
      _bound = player;
      unawaited(_playing?.cancel());
      _playing = player.stream.playing.listen((playing) {
        if (!mounted) return;
        // 自动连播下一集时播放器会先停后播：换集瞬间的 playing=false 不是
        // 用户暂停，不该把已经隐藏的播控重新弹出来（#83）。只有手动暂停，
        // 或最后一集播完（没有下一集）才显示播控。
        if (playing) {
          _scheduleHide();
        } else if (_session.paused || !_session.hasNext) {
          _reveal();
        }
        setState(() {});
      });
    }
    final failed = _session.error != null;
    if (failed == _failed) return;
    _failed = failed;
    _closeMenu(refocus: false);
    _closeEpisodes(refocus: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (failed) {
        _retry.requestFocus();
      } else {
        _reveal(force: true);
      }
    });
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted ||
          !_visible ||
          _menu != null ||
          _episodePanel ||
          !_session.player.state.playing ||
          _session.error != null) {
        return;
      }
      _hide();
    });
  }

  void _hide() {
    if (_menu != null || _episodePanel) return;
    _hideTimer?.cancel();
    _surface.requestFocus();
    setState(() => _visible = false);
  }

  void _reveal({bool force = false}) {
    if (_visible && !force) return _scheduleHide();
    setState(() => _visible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _visible && _menu == null && !_episodePanel) {
        _play.requestFocus();
      }
    });
    _scheduleHide();
  }

  void _back() {
    if (_episodePanel) {
      _closeEpisodes();
    } else if (_menu != null) {
      _closeMenu();
    } else if (_visible) {
      _hide();
    }
  }

  void _step(int seconds) {
    final state = _session.player.state;
    final duration = state.duration;
    if (!_session.ready || duration <= Duration.zero) return;
    if (!(_seekCommit?.isActive ?? false)) {
      _seekFrom = _seekTarget ?? state.position;
      _seekOffset = 0;
    }
    _seekOffset += seconds;
    final target = _seekFrom.inMilliseconds + _seekOffset * 1000;
    _seekDisplay?.cancel();
    _seekCommit?.cancel();
    _seekCommit = Timer(const Duration(milliseconds: 500), _commitSeek);
    setState(() {
      _seekTarget = Duration(
        milliseconds: target.clamp(0, duration.inMilliseconds),
      );
      _seekShown = true;
    });
    if (_visible) _scheduleHide();
  }

  void _commitSeek() {
    final target = _seekTarget;
    if (target == null) return;
    unawaited(_session.seekTo(target));
    _seekDisplay = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() {
        _seekShown = false;
        _seekTarget = null;
      });
    });
  }

  void _episode(int direction) {
    if (direction < 0) {
      unawaited(_session.previous());
    } else {
      unawaited(_session.next());
    }
    _reveal();
  }

  Future<void> _change(Future<void> Function() change) async {
    try {
      await change();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('播放偏好未能保存，请重试')));
    }
  }

  /// 控制条上从左到右的焦点顺序。所有渲染出来的按钮都必须在这里登记，
  /// 否则遥控器左右键会直接跳过它（去广告按钮之前就漏了）。
  List<FocusNode> get _row => [
    _previous,
    _play,
    _next,
    if (_session.danmakuSupported) _danmaku,
    _adBlock,
    _episodes,
    if (!_session.local) _route,
    _speed,
    _quality,
    _fit,
  ];

  bool _enabled(FocusNode node) =>
      node == _previous && _session.hasPrevious ||
      node == _next && _session.hasNext ||
      node == _speed && _session.ready ||
      node == _quality && _session.ready && !_session.local ||
      node == _fit ||
      node == _route && _session.ready && !_session.local ||
      node == _adBlock && !_session.local ||
      node == _episodes ||
      node == _play ||
      node == _danmaku;

  void _moveInRow(FocusNode from, int direction) {
    final row = _row;
    for (
      var index = row.indexOf(from) + direction;
      index >= 0 && index < row.length;
      index += direction
    ) {
      if (_enabled(row[index])) return row[index].requestFocus();
    }
  }

  List<Object> _values(_Menu menu) => switch (menu) {
    _Menu.speed => playbackSpeeds.reversed.toList(),
    _Menu.quality => [..._session.qualities, 0],
    // 单线路也给出一条，用户至少能确认「本集只有一条线路」。
    _Menu.fit => VideoFit.values,
    _Menu.route => List<int>.generate(
      _session.routeCount < 1 ? 1 : _session.routeCount,
      (index) => index,
    ),
  };

  Object _selected(_Menu menu) => switch (menu) {
    _Menu.speed => _session.speed,
    _Menu.quality => _session.quality,
    _Menu.route => _session.routeIndex,
    _Menu.fit => _session.videoFit,
  };

  FocusNode _button(_Menu menu) => switch (menu) {
    _Menu.speed => _speed,
    _Menu.quality => _quality,
    _Menu.route => _route,
    _Menu.fit => _fit,
  };

  void _openMenu(_Menu menu) {
    final values = _values(menu);
    while (_options.length < values.length) {
      _options.add(FocusNode());
    }
    _hideTimer?.cancel();
    setState(() => _menu = menu);
    final index = values.indexOf(_selected(menu));
    final selected = index < 0 ? 0 : index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _menu != menu) return;
      _options[selected].requestFocus();
      _scrollMenuTo(selected);
    });
  }

  void _closeMenu({bool refocus = true}) {
    final menu = _menu;
    if (menu == null) return;
    setState(() => _menu = null);
    if (refocus) _button(menu).requestFocus();
    _scheduleHide();
  }

  void _pick(_Menu menu, Object value) {
    _closeMenu();
    unawaited(
      _change(
        () => switch (menu) {
          _Menu.speed => _session.setSpeed(value as double),
          _Menu.quality => _session.setQuality(value as int),
          _Menu.route => _session.setRoute(value as int),
          _Menu.fit => _session.setVideoFit(value as VideoFit),
        },
      ),
    );
  }

  void _scrollMenuTo(int index) {
    if (!_menuScroll.hasClients) return;
    _scrollRowIntoView(_menuScroll, index * _menuRowExtent, 44);
  }

  void _scrollEpisodeTo(int index) {
    if (!_episodeScroll.hasClients) return;
    _scrollRowIntoView(
      _episodeScroll,
      index ~/ _episodeColumns * _episodeRowExtent,
      _episodeCellHeight,
    );
  }

  /// 焦点是被按键直接搬运的，几何遍历不会替我们滚动，得自己把目标行挪进来。
  void _scrollRowIntoView(
    ScrollController controller,
    double top,
    double height,
  ) {
    final position = controller.position;
    final view = position.viewportDimension;
    if (top >= position.pixels && top + height <= position.pixels + view) {
      return;
    }
    final target = (top - (view - height) / 2).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target != position.pixels) controller.jumpTo(target);
  }

  void _openEpisodes() {
    final count = _session.detail.episodes.length;
    while (_episodeNodes.length < count) {
      _episodeNodes.add(FocusNode());
    }
    _hideTimer?.cancel();
    setState(() => _episodePanel = true);
    final index = _session.index.clamp(0, count == 0 ? 0 : count - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_episodePanel || count == 0) return;
      _episodeNodes[index].requestFocus();
      _scrollEpisodeTo(index);
    });
  }

  void _closeEpisodes({bool refocus = true}) {
    if (!_episodePanel) return;
    setState(() => _episodePanel = false);
    if (refocus) _episodes.requestFocus();
    _scheduleHide();
  }

  void _pickEpisode(int index) {
    _closeEpisodes();
    if (index != _session.index) unawaited(_session.play(index));
    _reveal();
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent || _session.error != null) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    switch (key) {
      case LogicalKeyboardKey.mediaPlayPause || LogicalKeyboardKey.space:
        if (down) _session.togglePlayback();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaPlay || LogicalKeyboardKey.mediaPause:
        if (down &&
            _session.player.state.playing !=
                (key == LogicalKeyboardKey.mediaPlay)) {
          _session.togglePlayback();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaTrackNext:
        if (down) _episode(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaTrackPrevious:
        if (down) _episode(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaFastForward:
        _step(10);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaRewind:
        _step(-10);
        return KeyEventResult.handled;
    }
    if (_episodePanel) return _episodePanelKey(key);
    if (_menu case final menu?) return _menuKey(menu, key);
    final horizontal = key == LogicalKeyboardKey.arrowLeft
        ? -1
        : key == LogicalKeyboardKey.arrowRight
        ? 1
        : 0;
    if (!_visible) {
      if (horizontal != 0) {
        _step(horizontal * 10);
        return KeyEventResult.handled;
      }
      if (_arrows.contains(key) || _confirms.contains(key)) {
        if (down) _reveal();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    _scheduleHide();
    final node = FocusManager.instance.primaryFocus;
    if (node == _bar) {
      if (horizontal != 0) {
        _step(horizontal * 10);
      } else if (key == LogicalKeyboardKey.arrowDown) {
        _play.requestFocus();
      } else if (_confirms.contains(key)) {
        if (down) _session.togglePlayback();
      } else if (key != LogicalKeyboardKey.arrowUp) {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (!_arrows.contains(key)) return KeyEventResult.ignored;
    if (node != null && _row.contains(node)) {
      if (horizontal != 0) {
        _moveInRow(node, horizontal);
      } else if (key == LogicalKeyboardKey.arrowUp) {
        _bar.requestFocus();
      }
    } else {
      _play.requestFocus();
    }
    return KeyEventResult.handled;
  }

  /// 选集面板按固定列数搬焦点：左右一集、上下一行，不依赖几何遍历。
  /// 确认键留给格子自己的 InkWell（onTap）处理。
  KeyEventResult _episodePanelKey(LogicalKeyboardKey key) {
    if (!_arrows.contains(key)) return KeyEventResult.ignored;
    final count = _session.detail.episodes.length;
    if (count == 0) return KeyEventResult.handled;
    final index = _episodeNodes.indexWhere((node) => node.hasPrimaryFocus);
    final current = index < 0 ? _session.index : index;
    final step = switch (key) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      LogicalKeyboardKey.arrowUp => -_episodeColumns,
      LogicalKeyboardKey.arrowDown => _episodeColumns,
      _ => 0,
    };
    final target = (current + step).clamp(0, count - 1);
    if (target != current) {
      _episodeNodes[target].requestFocus();
      _scrollEpisodeTo(target);
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _menuKey(_Menu menu, LogicalKeyboardKey key) {
    if (!_arrows.contains(key)) return KeyEventResult.ignored;
    final count = _values(menu).length;
    final index = _options.indexWhere((node) => node.hasPrimaryFocus);
    final current = index < 0 ? 0 : index;
    final step = switch (key) {
      LogicalKeyboardKey.arrowUp => -1,
      LogicalKeyboardKey.arrowDown => 1,
      // 线路动辄几十条：左右键按页翻，不用一路按下去。
      LogicalKeyboardKey.arrowLeft when menu == _Menu.route => -8,
      LogicalKeyboardKey.arrowRight when menu == _Menu.route => 8,
      _ => 0,
    };
    if (step == 0) return KeyEventResult.handled;
    final target = (current + step).clamp(0, count - 1);
    _options[target].requestFocus();
    _scrollMenuTo(target);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark
        ? theme
        : AppTheme.build(
            theme.colorScheme.primary,
            Brightness.dark,
            television: true,
          );
    return Theme(
      data: dark,
      child: ListenableBuilder(
        listenable: _session,
        builder: (context, _) {
          final failed = _session.error != null;
          return PopScope(
            canPop: failed || !_visible && _menu == null && !_episodePanel,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _back();
            },
            child: Focus(
              focusNode: _surface,
              autofocus: true,
              onKeyEvent: _key,
              child: Scaffold(
                backgroundColor: Colors.black,
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (widget.videoSurface case final surface?)
                      surface(_session.player)
                    else
                      PlayerVideo(
                        key: ValueKey(_session.player),
                        handle: widget.handle,
                        player: _session.player,
                        fit: _session.videoFit,
                      ),
                    DanmakuOverlay(
                      controller: _session.danmaku,
                      video: _session.videoSize,
                fit: _session.videoFit,
                      style: _session.danmakuStyle,
                    ),
                    if (_session.loading) PlaybackLoading(session: _session),
                    if (_session.ready && _session.stalled)
                      const Center(child: CircularProgressIndicator()),
                    if (!_visible && _seekShown) ...[
                      const _Shade(top: false),
                      _bubble(),
                      _progress(bottom: 27, focusable: false),
                    ],
                    ExcludeFocus(
                      excluding: !_visible || failed,
                      child: Visibility(
                        visible: _visible,
                        maintainState: true,
                        child: _controls(context),
                      ),
                    ),
                    if (_session.saveWarning case final warning?)
                      _saveWarning(warning),
                    if (_session.error case final error?)
                      PlaybackFailure(
                        session: _session,
                        error: error,
                        retryFocus: _retry,
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final playing = _session.player.state.playing;
    final menu = _menu;
    return Stack(
      fit: StackFit.expand,
      children: [
        const _Shade(top: true),
        const _Shade(top: false),
        Positioned(
          left: televisionInset,
          right: televisionInset,
          top: 27,
          child: Text(
            '${_session.detail.drama.title} 第 ${_session.episode.number} 集',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              height: 1.3,
              shadows: [Shadow(color: Color(0x66000000), blurRadius: 3)],
            ),
          ),
        ),
        _progress(bottom: 103, focusable: true),
        Positioned(
          left: televisionInset,
          right: televisionInset,
          bottom: 27,
          height: 60,
          child: Row(
            spacing: 12,
            children: [
              _round(
                _previous,
                Icons.skip_previous_rounded,
                '上一集',
                () => _episode(-1),
              ),
              _round(
                _play,
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                playing ? '暂停' : '播放',
                _session.togglePlayback,
                strong: true,
              ),
              _round(_next, Icons.skip_next_rounded, '下一集', () => _episode(1)),
              const Spacer(),
              if (_session.danmakuSupported)
                _pill(
                  _danmaku,
                  _session.danmakuEnabled ? '弹幕 开' : '弹幕 关',
                  _session.danmakuEnabled ? '关闭弹幕' : '打开弹幕',
                  () => unawaited(_change(_session.toggleDanmaku)),
                  color: _session.danmakuEnabled ? colors.primary : null,
                ),
              _pill(
                _adBlock,
                _session.adBlock ? '去广告 开' : '去广告 关',
                _session.adBlock ? '关闭去广告' : '打开去广告',
                () => unawaited(
                  _change(() => _session.setAdBlock(!_session.adBlock)),
                ),
                color: _session.adBlock ? colors.primary : null,
              ),
              _pill(_episodes, '选集', '选集', _openEpisodes),
              if (!_session.local)
                CompositedTransformTarget(
                  link: _links[_Menu.route]!,
                  child: _pill(
                    _route,
                    '线路 ${_session.routeIndex + 1}/${_session.routeCount}',
                    '播放线路',
                    () => _openMenu(_Menu.route),
                  ),
                ),
              CompositedTransformTarget(
                link: _links[_Menu.speed]!,
                child: _pill(
                  _speed,
                  '${_session.speed}x',
                  '倍速',
                  () => _openMenu(_Menu.speed),
                ),
              ),
              CompositedTransformTarget(
                link: _links[_Menu.quality]!,
                child: _pill(
                  _quality,
                  _session.qualityLabel,
                  '清晰度',
                  () => _openMenu(_Menu.quality),
                ),
              ),
              CompositedTransformTarget(
                link: _links[_Menu.fit]!,
                child: _pill(
                  _fit,
                  '比例 ${_session.videoFit.label}',
                  '画面比例',
                  () => _openMenu(_Menu.fit),
                ),
              ),
            ],
          ),
        ),
        if (menu != null)
          Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _links[menu]!,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topRight,
              followerAnchor: Alignment.bottomRight,
              offset: const Offset(0, -20),
              child: _menuBody(menu),
            ),
          ),
        if (_episodePanel) _episodeBody(),
      ],
    );
  }

  /// 右侧抽屉：只在按「选集」后出现，不占播放画面的常驻空间。
  Widget _episodeBody() {
    final episodes = _session.detail.episodes;
    final width = (MediaQuery.sizeOf(context).width * .42).clamp(320.0, 560.0);
    return Positioned(
      right: televisionInset,
      top: 84,
      bottom: 103,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: const Color(0xF018181A),
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Color(0x80000000),
              blurRadius: 32,
              offset: Offset(0, 12),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
              child: Row(
                spacing: 12,
                children: [
                  const Text(
                    '选集',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '共 ${episodes.length} 集 · 当前第 ${_session.episode.number} 集',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .62),
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final inner = constraints.maxWidth - 32;
                  _episodeColumns = (inner / 76).floor().clamp(2, 10);
                  return GridView.builder(
                    controller: _episodeScroll,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _episodeColumns,
                      mainAxisExtent: _episodeCellHeight,
                      crossAxisSpacing: _episodeGap,
                      mainAxisSpacing: _episodeGap,
                    ),
                    itemCount: episodes.length,
                    itemBuilder: (context, index) => _episodeCell(index),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _episodeCell(int index) {
    final episode = _session.detail.episodes[index];
    final current = index == _session.index;
    final node = _episodeNodes[index];
    return ListenableBuilder(
      listenable: node,
      builder: (context, _) {
        final focused = node.hasPrimaryFocus;
        final colors = Theme.of(context).colorScheme;
        return Semantics(
          label: '第 ${episode.number} 集${episode.vip ? '，VIP' : ''}',
          button: true,
          selected: current,
          excludeSemantics: true,
          child: InkWell(
            focusNode: node,
            onTap: () => _pickEpisode(index),
            borderRadius: BorderRadius.circular(10),
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            highlightColor: Colors.transparent,
            splashColor: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: focused
                    ? colors.primary
                    : current
                    ? colors.primary.withValues(alpha: .32)
                    : Colors.white.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Text(
                      '${episode.number}',
                      style: TextStyle(
                        color: focused ? colors.onPrimary : Colors.white,
                        fontSize: 17,
                        fontWeight: current || focused
                            ? FontWeight.w700
                            : FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (episode.vip)
                    const Positioned(
                      right: 5,
                      top: 5,
                      child: Icon(Icons.lock_rounded, size: 12, color: vipGold),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _bubble() {
    final forward = _seekOffset >= 0;
    return Align(
      alignment: const Alignment(0, -.07),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            Icon(
              forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
              size: 24,
              color: Colors.white,
            ),
            Text(
              '${forward ? '快进' : '快退'} ${_seekOffset.abs()} 秒',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progress({required double bottom, required bool focusable}) =>
      Positioned(
        left: televisionInset,
        right: televisionInset,
        bottom: bottom,
        height: 28,
        child: PlaybackProgressBuilder(
          player: _session.player,
          builder: (context) => ListenableBuilder(
            listenable: _bar,
            builder: (context, _) => _progressRow(
              focused: focusable && _bar.hasPrimaryFocus,
              focusable: focusable,
            ),
          ),
        ),
      );

  Widget _progressRow({required bool focused, required bool focusable}) {
    final colors = Theme.of(context).colorScheme;
    final state = _session.player.state;
    final duration = state.duration;
    final total = duration.inMilliseconds;
    final position = _seekTarget ?? state.position;
    double fraction(Duration value) =>
        total > 0 ? (value.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
    final played = fraction(position);
    final thickness = focused
        ? 8.0
        : _seekShown
        ? 6.0
        : 4.0;
    final knob = focused
        ? 20.0
        : _seekShown
        ? 14.0
        : 0.0;
    const clock = TextStyle(
      color: Colors.white,
      fontSize: 16,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    final track = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final x = width * played;
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.centerLeft,
          children: [
            Container(
              height: thickness,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .22),
                borderRadius: BorderRadius.circular(thickness / 2),
              ),
            ),
            Container(
              width: width * fraction(state.buffer),
              height: thickness,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .38),
                borderRadius: BorderRadius.circular(thickness / 2),
              ),
            ),
            Container(
              width: x,
              height: thickness,
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(thickness / 2),
              ),
            ),
            if (knob > 0)
              Positioned(
                left: x - knob / 2,
                child: Container(
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: focused
                        ? [
                            BoxShadow(
                              color: colors.primary.withValues(alpha: .45),
                              spreadRadius: 5,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            if (focused)
              Positioned(
                left: x,
                bottom: 24,
                child: FractionalTranslation(
                  translation: const Offset(-.5, 0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x59000000),
                          blurRadius: 14,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Text(
                      formatClock(position),
                      style: const TextStyle(
                        color: Color(0xFF111111),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
    return Row(
      spacing: 16,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48),
          child: Text(
            formatClock(position),
            style: clock.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: focusable
              ? Semantics(
                  label: '播放进度',
                  value: formatClock(position),
                  child: Focus(focusNode: _bar, child: track),
                )
              : track,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48),
          child: Text(
            formatClock(duration),
            textAlign: TextAlign.right,
            style: clock.copyWith(color: Colors.white.withValues(alpha: .72)),
          ),
        ),
      ],
    );
  }

  Widget _control(
    FocusNode node,
    String label,
    VoidCallback onPressed, {
    required ShapeBorder shape,
    required Widget Function(bool focused, bool enabled) builder,
  }) {
    final enabled = _enabled(node);
    return Semantics(
      label: label,
      button: true,
      enabled: enabled,
      excludeSemantics: true,
      child: ListenableBuilder(
        listenable: node,
        builder: (context, _) {
          final focused = enabled && node.hasPrimaryFocus;
          return AnimatedScale(
            scale: focused ? 1.08 : 1,
            duration: const Duration(milliseconds: 120),
            child: InkWell(
              focusNode: node,
              canRequestFocus: enabled,
              onTap: enabled ? onPressed : null,
              customBorder: shape,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              child: builder(focused, enabled),
            ),
          );
        },
      ),
    );
  }

  Decoration _look(bool focused, bool enabled, ShapeBorder shape, double rest) {
    final colors = Theme.of(context).colorScheme;
    return ShapeDecoration(
      shape: shape,
      color: focused
          ? colors.primary
          : Colors.white.withValues(alpha: enabled ? rest : .06),
      shadows: focused
          ? const [
              BoxShadow(
                color: Color(0x73000000),
                blurRadius: 20,
                offset: Offset(0, 6),
              ),
            ]
          : null,
    );
  }

  Color _ink(bool focused, bool enabled, [Color? color]) {
    if (focused) return Theme.of(context).colorScheme.onPrimary;
    if (!enabled) return Colors.white.withValues(alpha: .3);
    return color ?? Colors.white;
  }

  Widget _round(
    FocusNode node,
    IconData icon,
    String label,
    VoidCallback onPressed, {
    bool strong = false,
  }) {
    const shape = CircleBorder();
    return _control(
      node,
      label,
      onPressed,
      shape: shape,
      builder: (focused, enabled) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 52,
        height: 52,
        decoration: _look(focused, enabled, shape, strong ? .22 : .14),
        child: Icon(
          icon,
          size: strong ? 24 : 22,
          color: _ink(focused, enabled),
        ),
      ),
    );
  }

  Widget _pill(
    FocusNode node,
    String text,
    String label,
    VoidCallback onPressed, {
    Color? color,
  }) {
    const shape = StadiumBorder();
    return _control(
      node,
      label,
      onPressed,
      shape: shape,
      builder: (focused, enabled) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: _look(focused, enabled, shape, .14),
        child: Text(
          text,
          style: TextStyle(
            color: _ink(focused, enabled, color),
            fontSize: 17,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  Widget _menuBody(_Menu menu) {
    final colors = Theme.of(context).colorScheme;
    final values = _values(menu);
    final selected = _selected(menu);
    String label(Object value) => switch (menu) {
      _Menu.speed => '${value}x',
      _Menu.quality => value == 0 ? '自动' : '${value}P',
      _Menu.route => '线路 ${(value as int) + 1}',
      _Menu.fit => (value as VideoFit).label,
    };
    // 线路可能几十条：菜单高度封顶后交给滚动，选中项由 _scrollMenuTo 带进来。
    final maxHeight = (MediaQuery.sizeOf(context).height - 230)
        .clamp(120.0, 560.0)
        .toDouble();
    return Container(
      width: 190,
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xF018181A),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x80000000),
            blurRadius: 32,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: SingleChildScrollView(
        controller: _menuScroll,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 2,
          children: [
            for (final (index, value) in values.indexed)
              ListenableBuilder(
                listenable: _options[index],
                builder: (context, _) {
                  final focused = _options[index].hasPrimaryFocus;
                  final current = value == selected;
                  final color = focused
                      ? colors.onPrimary
                      : current
                      ? colors.primary
                      : Colors.white.withValues(alpha: .88);
                  return Semantics(
                    label: label(value),
                    selected: current,
                    button: true,
                    excludeSemantics: true,
                    child: InkWell(
                      focusNode: _options[index],
                      onTap: () => _pick(menu, value),
                      borderRadius: BorderRadius.circular(10),
                      focusColor: Colors.transparent,
                      hoverColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      splashColor: Colors.transparent,
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.fromLTRB(12, 0, 18, 0),
                        decoration: BoxDecoration(
                          color: focused ? colors.primary : null,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          spacing: 8,
                          children: [
                            SizedBox(
                              width: 18,
                              child: current
                                  ? Icon(
                                      Icons.check_rounded,
                                      size: 18,
                                      color: color,
                                    )
                                  : null,
                            ),
                            Text(
                              label(value),
                              style: TextStyle(
                                color: color,
                                fontSize: 17,
                                fontWeight: current || focused
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _saveWarning(String warning) => Positioned(
    top: 27,
    left: televisionInset,
    right: televisionInset,
    child: Align(
      alignment: Alignment.topCenter,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xE6322424),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          warning,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
    ),
  );
}

class _Shade extends StatelessWidget {
  const _Shade({required this.top});
  final bool top;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Align(
      alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
      child: SizedBox(
        width: double.infinity,
        height: top ? 130 : 190,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: top
                  ? const [Color(0xA6000000), Color(0x00000000)]
                  : const [Color(0x00000000), Color(0xB3000000)],
            ),
          ),
        ),
      ),
    ),
  );
}
