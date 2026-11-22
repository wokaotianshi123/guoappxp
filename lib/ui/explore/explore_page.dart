import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../drama_feed.dart';
import '../../explore_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../live/live_page.dart';
import '../app_scope.dart';
import '../cover_blur.dart';
import '../shell/app_shell.dart';
import '../modules/modules_page.dart';
import '../settings/sources_page.dart';
import '../theme/motion.dart';
import '../detail/detail_page.dart';
import '../widgets/bar_button.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/drama_grid.dart';
import '../widgets/focus_ring.dart';
import '../widgets/follow_button.dart';
import '../widgets/form_text_field.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/page_header.dart';
import '../widgets/pull_refresh.dart';
import '../widgets/self_heal.dart';
import '../widgets/source_bar.dart';
import '../widgets/status_view.dart';
import '../widgets/swipe_switch.dart';
import 'explore_hero.dart';
import 'source_actions.dart';

class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key, required this.store});
  final LocalStore store;

  @override
  State<ExplorePage> createState() => ExplorePageState();
}

class ExplorePageState extends State<ExplorePage> {
  ExploreFeed? _explore;
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _tabsKey = GlobalKey();
  final _refreshKey = GlobalKey<PullRefreshState>();
  final _pages = <String, _CategoryPageState>{};
  PageController? _pager;
  String? _pagerSource;
  int? _pagerTarget;
  bool _paged = false;
  bool _dragging = false;
  String _shown = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _explore ??= ExploreFeed(AppScope.of(context).repository, widget.store);
  }

  @override
  void dispose() {
    _explore?.dispose();
    _pager?.dispose();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  ScrollController? get _activeScroll =>
      _paged ? _pages[_explore?.tab.id]?.scroll : _scroll;

  GlobalKey<PullRefreshState>? get _activeRefresh =>
      _paged ? _pages[_explore?.tab.id]?.refresh : _refreshKey;

  Future<void> refresh() async {
    final scroll = _activeScroll;
    if (scroll != null && scroll.hasClients) scroll.jumpTo(0);
    await _explore?.refresh();
  }

  void reselect() {
    final scroll = _activeScroll;
    if (scroll == null || !scroll.hasClients) return;
    if (scroll.offset <= 0) {
      unawaited(_activeRefresh?.currentState?.show());
      return;
    }
    unawaited(
      scroll.animateTo(
        0,
        duration: Motion.of(context, Motion.long),
        curve: Motion.enter,
      ),
    );
  }

  void _selectTab(String id) {
    if (id != _explore!.tab.id) {
      _explore!.select(id);
      return;
    }
    final scroll = _activeScroll;
    if (scroll == null || !scroll.hasClients || scroll.offset <= 0) return;
    unawaited(
      scroll.animateTo(
        0,
        duration: Motion.of(context, Motion.long),
        curve: Motion.enter,
      ),
    );
  }

  void _open(Drama drama, {bool autoplay = false}) => openPage<void>(
    context,
    (_) => DetailPage(store: widget.store, drama: drama, autoplay: autoplay),
  );

  /// 粘贴网盘分享链接：解析后直接进统一详情页选集播放。
  ///
  /// 加载中给出明确反馈（解析要转存/取流，可能几秒），失败时把原因显示出来，
  /// 不要只闪一下 SnackBar。
  Future<void> _pasteNetdisk() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _NetdiskLinkDialog(),
    );
    if (url == null || url.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('正在解析网盘分享…'),
        duration: Duration(seconds: 8),
      ),
    );
    try {
      final drama = await AppScope.of(context).repository.netdiskOpenShare(url);
      if (!mounted) return;
      messenger?.hideCurrentSnackBar();
      _open(drama);
    } catch (error) {
      if (!mounted) return;
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _pickCategory(BuildContext anchor) async {
    final explore = _explore!;
    final value = await showChoicePanel<String>(
      context: anchor,
      title: '全部分类',
      options: [for (final tab in explore.tabs) ChoiceOption(tab.id, tab.name)],
      selected: explore.tab.id,
      grid: ChoiceGrid.categories,
    );
    if (value != null) explore.select(value);
  }

  void _searchSubmitted(SourceSite source, String query) {
    if (query.trim().isEmpty) return;
    _search.clear();
    openSearch(context, widget.store, source, query: query);
  }

  void _resetScroll(ExploreFeed explore, {required bool deferred}) {
    final source = '${explore.source?.id}|';
    final shown = '$source${explore.tab.id}';
    if (shown == _shown) return;
    final switched = _shown.startsWith(source);
    _shown = shown;
    if (deferred && switched) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _toTop());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_explore!, widget.store]),
    builder: (context, _) {
      final explore = _explore!;
      final source = explore.source;
      final form = AppScope.formFactorOf(context);
      final television = form == FormFactor.television;
      final desktop = form == FormFactor.window;
      _paged = _swipes(form);
      if (!_paged) _resetScroll(explore, deferred: false);
      if (source == null) {
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (!television) const PageHeader(title: '发现'),
                Expanded(
                  child: SourceSite.values.isEmpty
                      ? StatusView(
                          title: '还没有安装站源',
                          message: widget.store.profile.admin
                              ? '站源以模块的形式提供，请在 我的 › 自定义模块 安装。'
                              : '请联系管理员安装站源模块。',
                          icon: Icons.extension_off_rounded,
                          action: '前往自定义模块',
                          onAction: () => openPage<void>(
                            context,
                            (_) => ModulesPage(store: widget.store),
                          ),
                        )
                      : StatusView(
                          title: '暂无可用站源',
                          message: '请在 我的 › 自定义XBPQ 中开启站源，或联系管理员开放权限。',
                          icon: Icons.public_off_rounded,
                          action: '前往自定义XBPQ',
                          onAction: () => openPage<void>(
                            context,
                            (_) => SourcesPage(store: widget.store),
                          ),
                        ),
                ),
              ],
            ),
          ),
        );
      }
      final inset = switch (form) {
        FormFactor.phone => 16.0,
        FormFactor.pad || FormFactor.window => 24.0,
        FormFactor.television => televisionInset,
      };
      final tabs = Padding(
        padding: EdgeInsets.symmetric(
          horizontal: form == FormFactor.phone ? 0 : inset,
        ),
        child: CategoryTabs<String>(
          key: _tabsKey,
          options: [
            for (final tab in explore.tabs) ChoiceOption(tab.id, tab.name),
          ],
          selected: explore.tab.id,
          pager: _paged ? _pagerFor(explore) : null,
          onSelected: _selectTab,
          onShowAll: _pickCategory,
        ),
      );
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              if (!television)
                HideOnScroll(
                  alignment: Alignment.bottomCenter,
                  child: SourceBar(
                    source: source.name,
                    searchController: _search,
                    onSwitchSource: (anchor) =>
                        pickSource(anchor, widget.store),
                    onOpenSearch: () =>
                        openSearch(context, widget.store, source),
                    onSearchSubmitted: (query) =>
                        _searchSubmitted(source, query),
                    leading: [
                      if (widget.store.blurCoversButton)
                        if (CoverBlurScope.of(context) case final blur?)
                          BarButton(
                            icon: blur.mode != CoverBlur.off
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                            tooltip: blur.mode != CoverBlur.off
                                ? '显示封面'
                                : '模糊封面',
                            onPressed: blur.onToggle,
                          ),
                    ],
                    actions: [
                      BarButton(
                        icon: Icons.live_tv_rounded,
                        tooltip: '直播',
                        onPressed: () =>
                            unawaited(openLive(context, store: widget.store)),
                      ),
                      BarButton(
                        icon: Icons.cloud_outlined,
                        tooltip: '粘贴网盘链接',
                        onPressed: () => unawaited(_pasteNetdisk()),
                      ),
                      if (desktop)
                        BarButton(
                          icon: Icons.refresh_rounded,
                          tooltip: '刷新',
                          onPressed: explore.refresh,
                        ),
                    ],
                  ),
                ),
              if (!television || explore.feed!.items.isEmpty) tabs,
              Expanded(
                child: _paged
                    ? _pagerView(explore, inset, tabs)
                    : _content(
                        explore,
                        explore.tab,
                        explore.feed!,
                        inset,
                        television,
                        tabs,
                        _scroll,
                        _refreshKey,
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );

  bool _swipes(FormFactor form) =>
      form == FormFactor.phone || form == FormFactor.pad;

  PageController _pagerFor(ExploreFeed explore) {
    final source = explore.source?.id;
    final pager = _pager;
    if (pager != null && source == _pagerSource) return pager;
    if (pager != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => pager.dispose());
    }
    _pagerSource = source;
    _pagerTarget = null;
    _dragging = false;
    final index = explore.tabs.indexWhere((tab) => tab.id == explore.tab.id);
    return _pager = PageController(initialPage: math.max(index, 0));
  }

  Widget _pagerView(ExploreFeed explore, double inset, Widget tabs) {
    final pager = _pagerFor(explore);
    final pages = explore.tabs;
    final index = pages.indexWhere((tab) => tab.id == explore.tab.id);
    if (index >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _follow(index));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _pageScrolled,
      child: PageView.builder(
        key: ValueKey(explore.source?.id),
        controller: pager,
        itemCount: pages.length,
        itemBuilder: (context, index) {
          final tab = pages[index];
          return _CategoryPage(
            key: ValueKey(tab.id),
            id: tab.id,
            pages: _pages,
            builder: (context, page) {
              final feed = explore.feedOf(tab);
              final warm = page.warm ??= feed.items.isNotEmpty;
              return _content(
                explore,
                tab,
                feed,
                inset,
                false,
                tabs,
                page.scroll,
                page.refresh,
                fade: !warm,
              );
            },
          );
        },
      ),
    );
  }

  bool _pageScrolled(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _dragging = true;
      _pagerTarget = null;
    } else if (notification is ScrollEndNotification && _dragging) {
      _dragging = false;
      final explore = _explore!;
      final page = _pager?.page?.round();
      final pages = explore.tabs;
      if (page != null && page >= 0 && page < pages.length) {
        explore.select(pages[page].id);
      }
    }
    return false;
  }

  void _follow(int index) {
    final pager = _pager;
    if (!mounted || pager == null || !pager.hasClients || _dragging) return;
    final page = pager.page;
    if (page == null || _pagerTarget == index) return;
    if ((page - index).abs() < .01) return;
    final from = page.round();
    if ((index - from).abs() > 1) {
      pager.jumpToPage(index > from ? index - 1 : index + 1);
    }
    _pagerTarget = index;
    unawaited(
      pager
          .animateToPage(
            index,
            duration: Motion.of(context, Motion.long),
            curve: Motion.standard,
          )
          .whenComplete(() {
            if (_pagerTarget == index) _pagerTarget = null;
          }),
    );
  }

  void _toTop() {
    final scroll = _activeScroll;
    if (scroll != null && scroll.hasClients) scroll.jumpTo(0);
  }

  Widget _content(
    ExploreFeed explore,
    CatalogCategory tab,
    DramaFeed feed,
    double inset,
    bool television,
    Widget tabs,
    ScrollController scroll,
    GlobalKey<PullRefreshState> refreshKey, {
    bool fade = true,
  }) {
    final hero = _hero(explore, tab);
    final items = explore.itemsIn(tab);
    if (feed.items.isEmpty) {
      return FadeSwitcher(child: _status(explore, feed, inset));
    }
    final phone = AppScope.formFactorOf(context) == FormFactor.phone;
    final desktop = AppScope.formFactorOf(context) == FormFactor.window;
    return FadeIn(
      enabled: fade,
      child: _grid(
        explore,
        tab,
        feed,
        hero,
        items,
        inset,
        television,
        tabs,
        phone,
        desktop,
        scroll,
        refreshKey,
      ),
    );
  }

  Widget _status(ExploreFeed explore, DramaFeed feed, double inset) {
    if (feed.loading) {
      final desktop = AppScope.formFactorOf(context) == FormFactor.window;
      return DramaGridSkeleton(
        key: const ValueKey('loading'),
        padding: EdgeInsets.fromLTRB(inset, desktop ? 20 : 16, inset, 0),
      );
    }
    if (feed.error.isNotEmpty) {
      return ErrorStatusView(
        key: const ValueKey('error'),
        title: '暂时无法加载',
        message: feed.error,
        icon: Icons.cloud_off_rounded,
        source: explore.source?.id ?? '',
        store: widget.store,
        verify: webViewVerifier(context),
        onRetry: () => feed.reload(force: true),
      );
    }
    return StatusView(
      key: const ValueKey('empty'),
      title: '这里还没有剧',
      message: '换一个分类看看',
      icon: Icons.inbox_outlined,
      action: '刷新',
      onAction: () => feed.reload(force: true),
    );
  }

  Widget _grid(
    ExploreFeed explore,
    CatalogCategory tab,
    DramaFeed feed,
    Widget? hero,
    List<Drama> items,
    double inset,
    bool television,
    Widget tabs,
    bool phone,
    bool desktop,
    ScrollController controller,
    GlobalKey<PullRefreshState> refreshKey,
  ) {
    final heroSection = hero == null
        ? const SizedBox(key: ValueKey('none'), width: double.infinity)
        : Padding(
            key: hero.key,
            padding: EdgeInsets.fromLTRB(inset, phone ? 12 : 16, inset, 0),
            child: hero,
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scroll = CustomScrollView(
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (television)
              SliverPadding(
                padding: const EdgeInsets.only(top: 8),
                sliver: SliverToBoxAdapter(child: tabs),
              ),
            SliverToBoxAdapter(
              child: television
                  ? heroSection
                  : AnimatedSize(
                      key: ValueKey(tab.id),
                      duration: Motion.of(context, Motion.long),
                      curve: Motion.enter,
                      alignment: Alignment.topCenter,
                      clipBehavior: Clip.none,
                      child: FadeSwitcher(
                        alignment: Alignment.topCenter,
                        child: heroSection,
                      ),
                    ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, desktop ? 20 : 16, inset, 0),
              sliver: DramaSliverGrid(
                width: constraints.maxWidth - inset * 2,
                items: items,
                rankOf: (drama) => explore.rankIn(tab, drama),
                autofocus:
                    television && hero == null && ShellForeground.of(context),
                heroScope: 'drama',
                showScore: tab.id != recommendTab.id,
                exploreBlur: true,
                onOpen: _open,
                onMore: (drama) => quickFollow(context, widget.store, drama),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                inset,
                8,
                inset,
                television ? 27 : 16,
              ),
              sliver: SliverToBoxAdapter(child: FeedFooter(feed: feed)),
            ),
          ],
        );
        return Stack(
          children: [
            AutoLoadMore(
              feed: feed,
              child: television
                  ? scroll
                  : PullRefresh(
                      key: refreshKey,
                      onRefresh: explore.refresh,
                      child: scroll,
                    ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  excluding: !feed.loading,
                  child: AnimatedOpacity(
                    opacity: feed.loading ? 1 : 0,
                    duration: Motion.of(context, Motion.medium),
                    curve: Motion.standard,
                    child: TickerMode(
                      enabled: feed.loading,
                      child: const LinearProgressIndicator(minHeight: 2),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget? _hero(ExploreFeed explore, CatalogCategory tab) {
    if (explore.resumeIn(tab) case final entry?) {
      final drama = entry.drama;
      final total = drama.episodes;
      final next = entry.finished && entry.episode < total
          ? entry.episode + 1
          : entry.episode;
      return ExploreHero(
        key: ValueKey(('resume', drama.id)),
        drama: drama,
        kicker: '继续观看',
        meta: total > 0
            ? '看到第 ${entry.episode} 集 · 共 $total 集'
            : '看到第 ${entry.episode} 集',
        progress: total > 0 ? entry.episode / total : null,
        action: '继续第 $next 集',
        onPlay: () => _open(drama, autoplay: true),
        onDetail: () => _open(drama),
      );
    }
    if (explore.featuredIn(tab) case final drama?) {
      return ExploreHero(
        key: ValueKey(('featured', drama.id)),
        drama: drama,
        kicker: '今日推荐',
        meta: [
          if (drama.category.isNotEmpty) drama.category,
          if (drama.episodes > 0) '共 ${drama.episodes} 集',
        ].join(' · '),
        action: '立即观看',
        onPlay: () => _open(drama, autoplay: true),
        onDetail: () => _open(drama),
      );
    }
    return null;
  }
}

/// 粘贴网盘分享链接的输入框。
class _NetdiskLinkDialog extends StatefulWidget {
  const _NetdiskLinkDialog();

  @override
  State<_NetdiskLinkDialog> createState() => _NetdiskLinkDialogState();
}

class _NetdiskLinkDialogState extends State<_NetdiskLinkDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final television = AppScope.of(context).television;
    return AlertDialog(
      title: const Text('粘贴网盘分享链接'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FormTextField(
              controller: _controller,
              url: true,
              autofocus: !television,
              decoration: const InputDecoration(
                labelText: '夸克分享链接',
                hintText: 'https://pan.quark.cn/s/xxxx',
                helperText: '解析后进入详情页选集播放；播放需要先在「网盘与订阅」里登录夸克',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        FocusRing(
          radius: 20,
          child: TextButton(
            autofocus: television,
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
        FocusRing(
          radius: 20,
          child: FilledButton(onPressed: _submit, child: const Text('打开')),
        ),
      ],
    );
  }
}

class _CategoryPage extends StatefulWidget {
  const _CategoryPage({
    super.key,
    required this.id,
    required this.pages,
    required this.builder,
  });
  final String id;
  final Map<String, _CategoryPageState> pages;
  final Widget Function(BuildContext context, _CategoryPageState page) builder;

  @override
  State<_CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends State<_CategoryPage> {
  final scroll = ScrollController();
  final refresh = GlobalKey<PullRefreshState>();
  bool? warm;

  @override
  void initState() {
    super.initState();
    widget.pages[widget.id] = this;
  }

  @override
  void dispose() {
    if (identical(widget.pages[widget.id], this)) {
      widget.pages.remove(widget.id);
    }
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, this);
}
