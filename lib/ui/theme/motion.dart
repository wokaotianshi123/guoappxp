import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';

/// 全应用统一的动效节奏。
///
/// - 时长分三档；电视端遥控器操作只用最短的一档，避免等动画；
/// - 系统开启「减少动画」时一律返回 [Duration.zero]；
/// - 页面转场与下面的返回手势预览共用同一套曲线。
abstract final class Motion {
  static const short = Duration(milliseconds: 150);
  static const medium = Duration(milliseconds: 250);
  static const long = Duration(milliseconds: 300);

  static const enter = Easing.emphasizedDecelerate;
  static const exit = Easing.emphasizedAccelerate;
  static const standard = Easing.standard;

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration of(BuildContext context, Duration duration) {
    if (reduced(context)) return Duration.zero;
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    if (scope?.television ?? false) {
      return duration > short ? short : duration;
    }
    return duration;
  }
}

/// 手机上「淡出 + 轻微缩放」的页面转场，并在 Android 上接系统预测返回手势：
/// 侧滑时当前页跟着手指缩小、平移、露出上一页，松手继续缩小淡出，拖回边缘
/// 则回弹。桌面上按 Esc / 点返回键仍是普通的淡出缩放。
class _FadeScalePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeScalePageTransitionsBuilder();

  @override
  Duration get transitionDuration => Motion.long;

  @override
  Duration get reverseTransitionDuration => Motion.medium;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final reduced = Motion.reduced(context);
    Widget transition() {
      if (reduced) return child;
      final enter = CurvedAnimation(
        parent: animation,
        curve: Motion.enter,
        reverseCurve: Motion.exit,
      );
      return FadeTransition(
        opacity: enter,
        child: ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0).animate(enter),
          child: child,
        ),
      );
    }

    if (defaultTargetPlatform != TargetPlatform.android || reduced) {
      return transition();
    }
    return _BackGesture(route: route, child: transition());
  }
}

/// 把 Android 的预测返回事件接到页面转场上。
///
/// 这个类只做三件事：
/// 1. 收到手势开始时把「返回进度」交给路由（框架会据此倒放页面动画）；
/// 2. 手势移动时同步进度；
/// 3. 在页面动画之上叠加缩小 / 平移 / 圆角，露出下面那一页。
class _BackGesture extends StatefulWidget {
  const _BackGesture({required this.route, required this.child});
  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_BackGesture> createState() => _BackGestureState();
}

class _BackGestureState extends State<_BackGesture>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final _drag = AnimationController(vsync: this);
  var _edge = SwipeEdge.left;
  var _active = false;

  PageRoute<dynamic> get _route => widget.route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _drag.dispose();
    super.dispose();
  }

  bool get _canPop => _route.isCurrent && _route.popGestureEnabled;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent || !_canPop) return false;
    _route.handleStartBackGesture(progress: 1 - backEvent.progress);
    _active = true;
    setState(() {
      _edge = backEvent.swipeEdge;
      _drag.value = backEvent.progress;
    });
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_active) return;
    _route.handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);
    _drag.value = backEvent.progress;
  }

  @override
  void handleCancelBackGesture() {
    if (!_active) return;
    _route.handleCancelBackGesture();
    // 拖回边缘：页面回到原位（回弹），不是直接跳一下。
    _drag
        .animateBack(0, duration: Motion.medium, curve: Motion.standard)
        .whenCompleteOrCancel(() {
          if (mounted && _drag.value == 0) _active = false;
        });
  }

  @override
  void handleCommitBackGesture() {
    if (!_active) return;
    _active = false;
    _route.handleCommitBackGesture();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _drag,
    builder: (context, child) => _preview(context, child!),
    child: widget.child,
  );

  Widget _preview(BuildContext context, Widget child) {
    final progress = _drag.value;
    if (progress <= 0) return child;
    final width = MediaQuery.sizeOf(context).width;
    final shift = (width / 20 - 8) * progress;
    return Transform.translate(
      offset: Offset(_edge == SwipeEdge.left ? shift : -shift, 0),
      child: Transform.scale(
        scale: 1 - 0.1 * progress,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32 * progress),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ),
    );
  }
}

class _FadePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadePageTransitionsBuilder();

  @override
  Duration get transitionDuration => Motion.short;

  @override
  Duration get reverseTransitionDuration => Motion.short;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion.reduced(context)) return child;
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Motion.standard),
      child: child,
    );
  }
}

PageTransitionsTheme pageTransitions({required bool television}) {
  if (television) {
    const fade = _FadePageTransitionsBuilder();
    return const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: fade,
        TargetPlatform.iOS: fade,
        TargetPlatform.macOS: fade,
        TargetPlatform.windows: fade,
        TargetPlatform.linux: fade,
        TargetPlatform.fuchsia: fade,
      },
    );
  }
  const scale = _FadeScalePageTransitionsBuilder();
  return const PageTransitionsTheme(
    builders: {
      TargetPlatform.android: scale,
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: scale,
      TargetPlatform.linux: scale,
      TargetPlatform.fuchsia: scale,
    },
  );
}

/// 不想带转场的临时页面（例如打开即用的全屏播放页）。
Route<T> fadeRoute<T>(WidgetBuilder builder, {RouteSettings? settings}) =>
    PageRouteBuilder<T>(
      settings: settings,
      transitionDuration: Motion.medium,
      reverseTransitionDuration: Motion.short,
      pageBuilder: (context, _, _) => builder(context),
      transitionsBuilder: (context, animation, _, child) =>
          Motion.reduced(context)
          ? child
          : FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Motion.standard,
              ),
              child: child,
            ),
    );
