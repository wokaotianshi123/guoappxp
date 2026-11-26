import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../download_converter.dart';
import '../../merge_queue.dart';
import '../../download_overview.dart';
import '../../follow_updater.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../explore/explore_page.dart';
import '../explore/source_actions.dart';
import '../follow/follow_page.dart';
import '../recommend/recommend_page.dart';
import '../mine/mine_page.dart';
import '../modules/module_install.dart';
import '../widgets/bar_button.dart';
import '../theme/motion.dart';
import '../widgets/focus_ring.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/source_bar.dart';

enum AppTab {
  explore('发现', Icons.explore_outlined, Icons.explore),
  recommend('推荐', Icons.play_circle_outline_rounded, Icons.play_circle_rounded),
  follow('追剧', Icons.bookmark_border_rounded, Icons.bookmark_rounded),
  mine('我的', Icons.person_outline_rounded, Icons.person_rounded);

  const AppTab(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 启动时就挂载的标签：默认停在「发现」，推荐流暂不进树。
///
/// [IndexedStack] 会一次性构建所有 children，推荐流只要在树里就会立刻
/// initState → 拉推荐列表，首屏请求和发现页抢限流 / IPC / CPU，打开软件就被拖卡。
/// 推荐流改为用户第一次切过去时才挂载（见 [_AppShellState]）。未挂载的标签
/// 必须用空占位对齐 index，否则 IndexedStack 的子节点位置与 [_tab.index]
/// 错位，表现为切到追剧 / 历史 / 我的时整页透明或空白。
/// 单独抽出来便于回归测试锁住这条策略。
Set<AppTab> initialMountedTabs() =>
    <AppTab>{...AppTab.values}..remove(AppTab.recommend);

Future<T?> openPage<T>(BuildContext context, WidgetBuilder builder) =>
    Navigator.of(
      context,
      rootNavigator: switch (AppScope.formFactorOf(context)) {
        FormFactor.phone || FormFactor.television => true,
        FormFactor.pad || FormFactor.window => false,
      },
    ).push(MaterialPageRoute<T>(builder: builder));

class ShellForeground extends InheritedWidget {
  const ShellForeground({
    super.key,
    required this.foreground,
    required super.child,
  });
  final bool foreground;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ShellForeground>()
          ?.foreground ??
      true;

  @override
  bool updateShouldNotify(ShellForeground oldWidget) =>
      foreground != oldWidget.foreground;
}

class ShellBars extends InheritedNotifier<ValueNotifier<bool>> {
  const ShellBars({super.key, required super.notifier, required super.child});

  static bool shown(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ShellBars>()
          ?.notifier
          ?.value ??
      true;
}

/// 当前显示的是哪个标签。
///
/// 标签页一旦挂进 [IndexedStack] 就会一直留在树里，页面自己看不出「我又被
/// 切回来了」。需要「重新可见时自愈」的页面（比如推荐页换源后停在报错）依赖
/// 这个 InheritedWidget 拿到当前标签。
class ShellVisibleTab extends InheritedWidget {
  const ShellVisibleTab({super.key, required this.tab, required super.child});

  final AppTab tab;

  /// 当前标签；不在 [AppShell] 里（比如单独测某个页面）时返回 null。
  static AppTab? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellVisibleTab>()?.tab;

  static AppTab of(BuildContext context) => maybeOf(context) ?? AppTab.explore;

  @override
  bool updateShouldNotify(ShellVisibleTab oldWidget) => tab != oldWidget.tab;
}

class HideOnScroll extends StatelessWidget {
  const HideOnScroll({
    super.key,
    required this.alignment,
    required this.child,
    this.enabled = true,
  });
  final Alignment alignment;
  final Widget child;

  /// 是否允许随滚动收起。为 false 时始终显示，只保留布局位置。
  final bool enabled;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedAlign(
      alignment: alignment,
      heightFactor: enabled && !ShellBars.shown(context) ? 0 : 1,
      duration: Motion.of(context, Motion.medium),
      curve: Motion.standard,
      child: child,
    ),
  );
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.store});
  final LocalStore store;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _heroes = [
    for (final _ in AppTab.values) MaterialApp.createMaterialHeroController(),
  ];
  final _navigators = [
    for (final _ in AppTab.values) GlobalKey<NavigatorState>(),
  ];
  final _tabFocus = [for (final _ in AppTab.values) FocusNode()];
  final _tabScrolls = [for (final _ in AppTab.values) ScrollController()];
  final _followEntry = FocusNode();
  final _mineEntry = FocusNode();
  final _header = FocusNode();
  final _televisionTabs = GlobalKey();
  final _explore = GlobalKey<ExplorePageState>();
  static const _revealVelocity = 400.0;
  final _barsShown = ValueNotifier(true);
  final _scrollClock = Stopwatch()..start();
  var _scrollVelocity = VelocityTracker.withKind(PointerDeviceKind.touch);
  var _tab = AppTab.explore;
  var _headerFocused = false;
  /// 只有访问过的标签才把根页面挂进 [IndexedStack]；未访问的用空占位保持
  /// index 对齐，不构建页面、不触发任何数据加载。切到某标签时由 [_select]
  /// 同帧换成真实 Navigator，之后一直保留状态，不会重复初始化或重复加载。
  final Set<AppTab> _mountedTabs = initialMountedTabs();
  FocusNode? _lastFocus;
  Timer? _exitWindow;
  DownloadOverview? _downloads;
  DownloadConverter? _converter;
  MergeQueue? _merges;
  FollowUpdater? _followUpdater;

  NavigatorState? get _navigator => _navigators[_tab.index].currentState;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_followFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(offerRestoredModules(context, widget.store));
      unawaited(_announceModulesMoved());
    });
  }

  /// 模块从「站源 › 模块」搬到「我的 › 自定义模块」后，老用户升级第一次启动
  /// 时提示一次就够。全新安装（没有任何观看记录）不提示——他们没见过旧结构，
  /// 说「已移到」只会让人困惑；标记照样落库，之后也不再提。
  Future<void> _announceModulesMoved() async {
    final store = widget.store;
    if (store.modulesMovedHintShown) return;
    final upgrading = store.history.isNotEmpty;
    await store.setModulesMovedHintShown(true);
    if (!mounted || !upgrading) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('模块已移到「我的 › 自定义模块」，原「站源」页现在叫「自定义XBPQ」'),
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _downloads ??= DownloadOverview(
      AppScope.of(context).repository,
      widget.store,
    );
    _converter ??= DownloadConverter(
      AppScope.of(context).repository,
      _downloads!,
    );
    _merges ??= MergeQueue(AppScope.of(context).repository)
      ..onFinished = _mergeFinished;
    _followUpdater ??= FollowUpdater(
      AppScope.of(context).repository,
      widget.store,
    )..start();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_followFocus);
    for (final node in _tabFocus) {
      node.dispose();
    }
    for (final scroll in _tabScrolls) {
      scroll.dispose();
    }
    for (final hero in _heroes) {
      hero.dispose();
    }
    _followEntry.dispose();
    _mineEntry.dispose();
    _header.dispose();
    _barsShown.dispose();
    _exitWindow?.cancel();
    _converter?.dispose();
    _merges?.dispose();
    _downloads?.dispose();
    _followUpdater?.dispose();
    super.dispose();
  }

  List<AppTab> get _tabs => AppTab.values;

  void _select(AppTab tab) {
    _barsShown.value = true;
    setState(() {
      _tab = tab;
      // 切过去的同时把该标签挂进树里，同一次 build 生效，不会闪出空白页。
      _mountedTabs.add(tab);
    });
  }

  bool _scrolled(ScrollNotification notification) {
    // 移动端不收起顶栏 / 底栏：这里直接不跟踪滚动，省掉无意义的通知与重建，
    // 也避免切到桌面端时残留一个「已收起」的旧状态。
    if (mobilePlatform) return false;
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    if (notification is ScrollStartNotification) {
      _scrollVelocity = VelocityTracker.withKind(PointerDeviceKind.touch);
    }
    if (metrics.pixels <= metrics.minScrollExtent) {
      _barsShown.value = true;
    } else if (notification is ScrollUpdateNotification &&
        !metrics.outOfRange) {
      _scrollVelocity.addPosition(
        _scrollClock.elapsed,
        Offset(0, metrics.pixels),
      );
      final delta = notification.scrollDelta ?? 0;
      if (delta > 0) {
        _barsShown.value = false;
      } else if (delta < 0) {
        final velocity =
            _scrollVelocity.getVelocityEstimate()?.pixelsPerSecond.dy ?? 0;
        if (-velocity >= _revealVelocity) _barsShown.value = true;
      }
    }
    return false;
  }

  void _tap(AppTab tab) {
    if (tab != _tab) return _select(tab);
    final navigator = _navigator;
    if (navigator != null && navigator.canPop()) {
      return navigator.popUntil((route) => route.isFirst);
    }
    if (tab == AppTab.explore) return _explore.currentState?.reselect();
    for (final position in _tabScrolls[tab.index].positions) {
      if (position.pixels <= position.minScrollExtent) continue;
      unawaited(
        position.animateTo(
          position.minScrollExtent,
          duration: Motion.of(context, Motion.long),
          curve: Motion.enter,
        ),
      );
    }
  }

  void _mergeFinished(MergeTask task) {
    if (task.state == MergeState.cancelled) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          task.state == MergeState.done
              ? '「${task.fileName}」${task.message}'
              : '「${task.fileName}」合并失败：${task.message}',
        ),
      ),
    );
  }

  void _followFocus() {
    final previous = _lastFocus;
    final focused = _lastFocus = FocusManager.instance.primaryFocus;
    final index = _tabFocus.indexWhere((node) => node == focused);
    if (index < 0) return;
    if (previous?.ancestors.contains(_header) ?? false) {
      _select(AppTab.values[index]);
    } else if (index != _tab.index) {
      _tabFocus[_tab.index].requestFocus();
    }
  }

  Future<void> _back() async {
    final navigator = _navigator;
    if (navigator != null && await navigator.maybePop()) return;
    if (!mounted) return;
    final television = AppScope.of(context).television;
    if (_tab == AppTab.explore && (!television || _headerFocused)) {
      _armExit();
      return;
    }
    if (_tab == AppTab.explore) _explore.currentState?.refresh();
    _select(AppTab.explore);
    if (television) _tabFocus.first.requestFocus();
  }

  void _armExit() {
    const window = Duration(seconds: 2);
    setState(() {
      _exitWindow = Timer(window, () {
        if (mounted) setState(() => _exitWindow = null);
      });
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('再按一次返回退出应用'), duration: window),
      );
  }

  Widget _root(AppTab tab) => switch (tab) {
    AppTab.explore => ExplorePage(key: _explore, store: widget.store),
    AppTab.recommend => RecommendPage(store: widget.store),
    AppTab.follow => FollowPage(
      store: widget.store,
      entryFocus: _followEntry,
      onExitUp: _tabFocus[AppTab.follow.index].requestFocus,
    ),
    AppTab.mine => MinePage(
      store: widget.store,
      downloads: _downloads!,
      converter: _converter!,
      merges: _merges!,
      entryFocus: _mineEntry,
      onExitUp: _tabFocus[AppTab.mine.index].requestFocus,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final stack = NotificationListener<NavigationNotification>(
      onNotification: (_) {
        setState(() {});
        return false;
      },
      child: IndexedStack(
        index: _tab.index,
        children: [
          for (final tab in AppTab.values)
            if (_mountedTabs.contains(tab))
              _TabFade(
                selected: tab == _tab,
                child: HeroControllerScope(
                  controller: _heroes[tab.index],
                  child: Navigator(
                    key: _navigators[tab.index],
                    routeTraversalEdgeBehavior:
                        TraversalEdgeBehavior.parentScope,
                    routeDirectionalTraversalEdgeBehavior:
                        TraversalEdgeBehavior.parentScope,
                    onGenerateInitialRoutes: (_, _) => [
                      MaterialPageRoute<void>(
                        builder: (_) => PrimaryScrollController(
                          controller: _tabScrolls[tab.index],
                          child: _root(tab),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              // 未访问过的标签用空占位对齐 index：不构建根页面，
              // 也就不会在默认「发现」页时提前加载听书模块，更不会让
              // 追剧 / 历史 / 我的因为位置错位而整页透明或越界空白。
              const SizedBox.shrink(),
        ],
      ),
    );
    final pages = ShellForeground(
      foreground: ModalRoute.of(context)?.isCurrent ?? true,
      child: ShellVisibleTab(tab: _tab, child: stack),
    );
    final television = AppScope.of(context).television;
    final tabs = _tabs;
    if (!tabs.contains(_tab)) _tab = AppTab.explore;
    final covered = _navigator?.canPop() ?? false;
    return PopScope(
      canPop:
          _exitWindow != null &&
          _tab == AppTab.explore &&
          !covered &&
          (!television || _headerFocused),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: switch (AppScope.formFactorOf(context)) {
        FormFactor.phone => ShellBars(
          notifier: _barsShown,
          child: Scaffold(
            body: NotificationListener<ScrollNotification>(
              onNotification: _scrolled,
              child: pages,
            ),
            bottomNavigationBar: covered
                ? null
                : HideOnScroll(
                    alignment: Alignment.topCenter,
                    enabled: !mobilePlatform,
                    child: NavigationBar(
                      height: 72,
                      selectedIndex: tabs.indexOf(_tab),
                      onDestinationSelected: (index) => _tap(tabs[index]),
                      destinations: [
                        for (final tab in tabs)
                          NavigationDestination(
                            key: ValueKey('nav-${tab.name}'),
                            icon: _badged(tab, Icon(tab.icon)),
                            selectedIcon: _badged(tab, Icon(tab.selectedIcon)),
                            label: tab.label,
                          ),
                      ],
                    ),
                  ),
          ),
        ),
        FormFactor.pad || FormFactor.window => _wide(pages),
        FormFactor.television => Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                if (!covered)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      televisionInset,
                      27,
                      televisionInset,
                      8,
                    ),
                    child: Focus(
                      focusNode: _header,
                      canRequestFocus: false,
                      skipTraversal: true,
                      onFocusChange: (focused) =>
                          setState(() => _headerFocused = focused),
                      onKeyEvent: (_, event) {
                        final entry = switch (_tab) {
                          AppTab.follow => _followEntry,
                          AppTab.mine => _mineEntry,
                          AppTab.explore || AppTab.recommend => null,
                        };
                        if (event is KeyUpEvent ||
                            event.logicalKey != LogicalKeyboardKey.arrowDown ||
                            entry?.context == null) {
                          return KeyEventResult.ignored;
                        }
                        revealFocus(entry!);
                        return KeyEventResult.handled;
                      },
                      child: _televisionHeader(),
                    ),
                  ),
                Expanded(child: pages),
              ],
            ),
          ),
        ),
      },
    );
  }

  Widget _badged(AppTab tab, Widget icon) => tab == AppTab.mine
      ? _DownloadBadge(downloads: _downloads!, child: icon)
      : icon;

  Widget _televisionHeader() {
    final tabs = Row(
      key: _televisionTabs,
      spacing: 6,
      children: [
        for (final tab in _tabs)
          _TelevisionTab(
            tab: tab,
            selected: tab == _tab,
            focusNode: _tabFocus[tab.index],
            onTap: () => _select(tab),
          ),
      ],
    );
    final store = widget.store;
    if (store.source.isEmpty) {
      return SizedBox(height: 48, child: tabs);
    }
    final source = SourceSite.byId(store.source);
    return SourceBar(
      source: source.name,
      televisionLeading: tabs,
      onSwitchSource: (anchor) => pickSource(anchor, store),
      onOpenSearch: () => openSearch(context, store, source),
      onSearchSubmitted: (query) =>
          openSearch(context, store, source, query: query),
    );
  }

  Widget _wide(Widget pages) {
    final roomy = MediaQuery.sizeOf(context).width >= 840;
    final expanded = roomy && widget.store.sideBarExpanded;
    return Scaffold(
      body: Row(
        children: [
          _SideBar(
            tabs: _tabs,
            selected: _tab,
            expanded: expanded,
            badged: _badged,
            onSelect: _tap,
            onToggle: roomy
                ? () => widget.store.setSideBarExpanded(!expanded)
                : null,
          ),
          Expanded(
            child: RepaintBoundary(
              child: MediaQuery.removePadding(
                context: context,
                removeLeft: true,
                child: pages,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

typedef _SideMetrics = ({
  double width,
  double inset,
  double top,
  double menuGap,
  double spacing,
  double itemHeight,
  double iconSize,
  double labelSize,
  EdgeInsets labelPadding,
});

_SideMetrics _sideMetrics({required bool desktop, required bool expanded}) =>
    desktop
    ? (
        width: expanded ? 240 : 80,
        inset: 12,
        top: 12,
        menuGap: 8,
        spacing: 4,
        itemHeight: 48,
        iconSize: 22,
        labelSize: 14,
        labelPadding: const EdgeInsets.fromLTRB(17, 0, 16, 0),
      )
    : (
        width: expanded ? 232 : 88,
        inset: 16,
        top: 8,
        menuGap: 12,
        spacing: 4,
        itemHeight: 56,
        iconSize: 24,
        labelSize: 15,
        labelPadding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
      );

class _TabFade extends StatelessWidget {
  const _TabFade({required this.selected, required this.child});
  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: selected ? 1 : 0,
    duration: selected ? Motion.of(context, Motion.medium) : Duration.zero,
    curve: Motion.enter,
    child: child,
  );
}

class _SideBar extends StatefulWidget {
  const _SideBar({
    required this.tabs,
    required this.selected,
    required this.expanded,
    required this.badged,
    required this.onSelect,
    this.onToggle,
  });
  final List<AppTab> tabs;
  final AppTab selected;
  final bool expanded;
  final Widget Function(AppTab tab, Widget icon) badged;
  final ValueChanged<AppTab> onSelect;
  final VoidCallback? onToggle;

  @override
  State<_SideBar> createState() => _SideBarState();
}

class _SideBarState extends State<_SideBar> {
  bool? _desktop;
  bool _roomy = false;

  @override
  Widget build(BuildContext context) {
    final desktop = AppScope.formFactorOf(context) == FormFactor.window;
    final roomy = widget.onToggle != null;
    final animate = _desktop == desktop && _roomy == roomy;
    _desktop = desktop;
    _roomy = roomy;
    final expanded = widget.expanded;
    final onToggle = widget.onToggle;
    final metrics = _sideMetrics(desktop: desktop, expanded: expanded);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        right: false,
        child: AnimatedContainer(
          key: const ValueKey('side-bar'),
          duration: animate
              ? Motion.of(context, expanded ? Motion.long : Motion.medium)
              : Duration.zero,
          curve: expanded ? Motion.enter : Motion.exit,
          width: metrics.width,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              metrics.inset,
              metrics.top,
              metrics.inset,
              12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: metrics.spacing,
              children: [
                Padding(
                  padding: EdgeInsets.only(bottom: metrics.menuGap),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 56,
                      height: 48,
                      child: onToggle == null
                          ? null
                          : Center(
                              child: BarButton(
                                icon: Icons.menu_rounded,
                                tooltip: expanded ? '收起侧栏' : '展开侧栏',
                                onPressed: onToggle,
                              ),
                            ),
                    ),
                  ),
                ),
                for (final tab in widget.tabs)
                  _SideItem(
                    tab: tab,
                    selected: tab == widget.selected,
                    expanded: expanded,
                    metrics: metrics,
                    badged: widget.badged,
                    onTap: () => widget.onSelect(tab),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem({
    required this.tab,
    required this.selected,
    required this.expanded,
    required this.metrics,
    required this.badged,
    required this.onTap,
  });
  final AppTab tab;
  final bool selected;
  final bool expanded;
  final _SideMetrics metrics;
  final Widget Function(AppTab tab, Widget icon) badged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final color = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    final icon = badged(
      tab,
      ToggleIconSwitcher(
        child: Icon(
          selected ? tab.selectedIcon : tab.icon,
          key: ValueKey(selected),
          color: color,
          size: metrics.iconSize,
        ),
      ),
    );
    final duration = Motion.of(context, Motion.medium);
    final item = AnimatedContainer(
      duration: duration,
      curve: Motion.standard,
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        color: selected ? colors.secondaryContainer : Colors.transparent,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey('nav-${tab.name}'),
          onTap: onTap,
          child: SizedBox(
            height: metrics.itemHeight,
            child: Padding(
              padding: EdgeInsets.only(left: metrics.labelPadding.left),
              child: Row(
                children: [
                  icon,
                  const SizedBox(width: 12),
                  Expanded(
                    child: ExcludeSemantics(
                      excluding: !expanded,
                      child: AnimatedOpacity(
                        opacity: expanded ? 1 : 0,
                        alwaysIncludeSemantics: true,
                        duration: Motion.of(context, Motion.short),
                        curve: expanded
                            ? const Interval(0.4, 1, curve: Motion.enter)
                            : Motion.exit,
                        child: AnimatedDefaultTextStyle(
                          duration: duration,
                          curve: Motion.standard,
                          style: theme.textTheme.titleSmall!.copyWith(
                            fontSize: metrics.labelSize,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: color,
                          ),
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: metrics.labelPadding.right,
                            ),
                            child: Text(
                              tab.label,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Semantics(
      selected: selected,
      child: FocusRing(
        radius: metrics.itemHeight / 2,
        child: expanded ? item : Tooltip(message: tab.label, child: item),
      ),
    );
  }
}

class _DownloadBadge extends StatelessWidget {
  const _DownloadBadge({required this.downloads, required this.child});
  final DownloadOverview downloads;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: downloads,
    builder: (context, child) {
      final count = downloads.active;
      return Badge(
        isLabelVisible: count > 0,
        label: ToggleIconSwitcher(
          child: Text(
            count > 99 ? '99+' : '$count',
            key: ValueKey(count > 99 ? 100 : count),
          ),
        ),
        child: child,
      );
    },
    child: child,
  );
}

class _TelevisionTab extends StatelessWidget {
  const _TelevisionTab({
    required this.tab,
    required this.selected,
    required this.focusNode,
    required this.onTap,
  });
  final AppTab tab;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      child: FocusPill(
        focusNode: focusNode,
        selected: selected,
        textStyle: theme.textTheme.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        child: InkWell(
          key: ValueKey('nav-${tab.name}'),
          focusNode: focusNode,
          autofocus: tab == AppTab.explore,
          focusColor: Colors.transparent,
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            alignment: Alignment.center,
            child: Text(tab.label),
          ),
        ),
      ),
    );
  }
}
