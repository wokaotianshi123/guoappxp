import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app_build.dart';
import '../app_device.dart';
import '../core_bridge.dart';
import '../local_store.dart';
import '../theme_color.dart';
import 'app_scope.dart';
import 'device_registration.dart';
import 'shell/app_shell.dart';
import 'theme/app_theme.dart';
import 'theme/system_color.dart';
import 'users/unlock_page.dart';
import 'widgets/focus_ring.dart';

class DuanjuApp extends StatefulWidget {
  const DuanjuApp({
    super.key,
    required this.repository,
    this.store,
    this.bootstrapError,
    this.onRetry,
    this.television = false,
    this.version = '',
  });
  final AppRepository repository;
  final LocalStore? store;
  final String? bootstrapError;
  final VoidCallback? onRetry;
  final bool television;
  final String version;

  @override
  State<DuanjuApp> createState() => _DuanjuAppState();
}

class _DuanjuAppState extends State<DuanjuApp> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  Color? _systemColor;
  int? _profileEpoch;
  var _television = false;
  var _phone = false;
  (Color, bool)? _themeKey;
  late (ThemeData, ThemeData) _themes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance
      ..addEarlyKeyEventHandler(_blockKeyboardFocus)
      ..addEarlyKeyEventHandler(_leaveTextField)
      ..addListener(_focusChanged);
    _loadSystemColor();
  }

  @override
  void dispose() {
    FocusManager.instance
      ..removeEarlyKeyEventHandler(_blockKeyboardFocus)
      ..removeEarlyKeyEventHandler(_leaveTextField)
      ..removeListener(_focusChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 输入框获得焦点时，请 Windows runner 修一次输入法上下文。
  ///
  /// Flutter 3.47.x 的 Windows 嵌入层在窗口失焦再回来后，子窗口的 IMM32→TSF
  /// 会话会过期：键盘消息照常到达，但中文候选框再也不出现，表现为「只能输入
  /// 字母」，要退出应用重开才恢复（flutter/flutter#190042）。runner 已经在窗口
  /// 重新获得焦点时修一次，这里补上「输入框拿到焦点」这个时机——窗口一直有焦点、
  /// 只是应用内换了输入框时，会话同样可能已经失效。
  ///
  /// 放在应用级而不是逐个输入框里，是因为裸 TextField 散落在听书、自定义源、
  /// 用户编辑、密码弹窗等多处，逐个挂容易漏。
  void _focusChanged() {
    if (focusedTextField() == null) return;
    final focus = FocusManager.instance.primaryFocus;
    if (identical(focus, _lastImeFocus)) return;
    _lastImeFocus = focus;
    AppDevice.repairIme();
  }

  FocusNode? _lastImeFocus;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadSystemColor();
  }

  Future<void> _loadSystemColor() async {
    final color = await readSystemColor();
    if (mounted && color != _systemColor) {
      setState(() => _systemColor = color);
    }
  }

  static final _focusKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
  };

  KeyEventResult _blockKeyboardFocus(KeyEvent event) {
    if (_television) return KeyEventResult.ignored;
    final key = event.logicalKey;
    return key == LogicalKeyboardKey.tab ||
            focusedTextField() == null &&
                !keyboardControlsFocused() &&
                _focusKeys.contains(key)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  KeyEventResult _leaveTextField(KeyEvent event) {
    if (!_television || event is KeyUpEvent) return KeyEventResult.ignored;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null ||
        focusedTextField() == null ||
        textFieldKeepsKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    return direction != null && focus.focusInDirection(direction)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  /// 桌面端的 Esc：先交给最近的 DismissIntent（关闭弹窗 / 退出全屏等），
  /// 没人接管才退一层页面。
  ///
  /// 这里只处理 Esc，**不要**再处理 [LogicalKeyboardKey.goBack]：
  /// Android 的返回键 / 三键导航 / 侧滑手势在发 goBack 按键事件的同时，
  /// 系统还会走一遍 popRoute（PopScope → Navigator.maybePop），两路一起
  /// 处理就会一次退两级——搜索结果进详情后按返回直接回到首页、设置分组页
  /// 返回越过设置根页都是这个原因。
  KeyEventResult _escape(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    final context =
        focusedTextField()?.context ??
        FocusManager.instance.primaryFocus?.context;
    if (context == null) return KeyEventResult.ignored;
    const intent = DismissIntent();
    final action = Actions.maybeFind<DismissIntent>(context, intent: intent);
    if (action != null &&
        Actions.of(context).invokeActionIfEnabled(action, intent, context).$1) {
      return KeyEventResult.handled;
    }
    final navigator = Navigator.maybeOf(context);
    if (navigator == null || !navigator.canPop()) {
      return KeyEventResult.ignored;
    }
    navigator.maybePop();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return ListenableBuilder(
      listenable: Listenable.merge([?store]),
      builder: (_, _) => _application(store),
    );
  }

  void _resetRoutes(LocalStore? store) {
    final epoch = store?.profileEpoch;
    if (epoch == _profileEpoch) return;
    final previous = _profileEpoch;
    _profileEpoch = epoch;
    if (previous == null) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _navigator.currentState?.popUntil((route) => route.isFirst),
    );
  }

  Widget _application(LocalStore? store) {
    _resetRoutes(store);
    final formFactor = switch (store?.displayMode) {
      'television' => FormFactor.television,
      'phone' => FormFactor.phone,
      'pad' => FormFactor.pad,
      'window' => desktopPlatform ? FormFactor.window : FormFactor.pad,
      _ => widget.television ? FormFactor.television : null,
    };
    final television = formFactor == FormFactor.television;
    if (television != _television) {
      unawaited(AppDevice.setTelevisionMode(television));
    }
    _television = television;
    final systemColor = (store?.followSystemColor ?? true)
        ? _systemColor
        : null;
    final seed =
        systemColor ?? Color((store?.themeColor ?? ThemeColor.orange).seed);
    if ((seed, television) != _themeKey) {
      _themeKey = (seed, television);
      _themes = (
        AppTheme.build(seed, Brightness.light, television: television),
        AppTheme.build(seed, Brightness.dark, television: television),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => FocusManager.instance.highlightStrategy = television
          ? FocusHighlightStrategy.alwaysTraditional
          : FocusHighlightStrategy.alwaysTouch,
    );
    return MaterialApp(
      navigatorKey: _navigator,
      title: appName,
      debugShowCheckedModeBanner: false,
      scrollBehavior: const FocusOutlineScrollBehavior(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: _themes.$1,
      darkTheme: _themes.$2,
      themeMode: AppTheme.mode(store?.themeMode ?? 'system'),
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemBars(Theme.of(context).brightness),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) => _escape(event),
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
                  ActivateIntent(),
              SingleActivator(
                LogicalKeyboardKey.gameButtonA,
                includeRepeats: false,
              ): ActivateIntent(),
            },
            child: AppScope(
              repository: widget.repository,
              formFactor: formFactor,
              systemColorAvailable: _systemColor != null,
              version: widget.version,
              child: Builder(
                builder: (context) {
                  final phone =
                      AppScope.formFactorOf(context) == FormFactor.phone;
                  if (phone != _phone) {
                    _phone = phone;
                    unawaited(AppDevice.setPhoneMode(phone));
                  }
                  return FocusOutlineMotion(
                    child: FocusOutlineLayer(
                      child: FocusTraversalGroup(
                        policy: ReadingOrderTraversalPolicy(
                          requestFocusCallback: revealFocus,
                        ),
                        child: child!,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
      home: switch (store) {
        null => _BootScreen(
          error: widget.bootstrapError,
          onRetry: widget.onRetry,
        ),
        LocalStore(locked: true) => UnlockPage(store: store),
        _ => DeviceRegistrationGate(
          store: store,
          child: AppShell(key: ValueKey(store.profileEpoch), store: store),
        ),
      },
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen({this.error, this.onRetry});
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 24,
          children: [
            if (error == null) const CircularProgressIndicator(),
            Text(
              error ?? '正在打开$appName',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (error != null && onRetry != null)
              FilledButton(onPressed: onRetry, child: const Text('重新打开')),
          ],
        ),
      ),
    ),
  );
}
