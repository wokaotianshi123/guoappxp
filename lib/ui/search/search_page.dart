import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_bridge.dart';
import '../../drama_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_catalog.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../widgets/drama_grid.dart';
import '../widgets/follow_button.dart';
import '../widgets/focus_ring.dart';
import '../widgets/horizontal_scroll_bar.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/search_field.dart';
import '../widgets/status_view.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.store,
    required this.source,
    this.query = '',
  });
  final LocalStore store;
  final SourceSite source;
  final String query;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final _controller = TextEditingController(text: widget.query);
  final _focus = FocusNode();
  // 站源栏的滚动 controller：桌面端靠它显示可拖动的横向滚动条。
  final _sourceScroll = ScrollController();
  late AppRepository _repository;
  late SourceCatalog _catalog;
  DramaFeed? _results;
  String _submitted = '';
  List<String> _suggestions = const [];
  Timer? _debounce;
  int _suggestion = 0;
  final _shownSuggestions = <Object>{};
  bool _ready = false;

  /// 参与搜索的站源 id。默认只勾当前源；点「全部源」把所有已开启的站源都勾上。
  /// 是否全选这个偏好存在本机，下次打开沿用。
  List<String> _picked = const [];

  List<String> get _allSourceIds => [
    for (final site in widget.store.sources) site.id,
  ];

  /// 走跨源搜索的条件：勾了多个源，或者勾了单个但不是当前源。
  bool get _crossMode =>
      _picked.length > 1 ||
      (_picked.length == 1 && _picked.first != widget.source.id);

  String get _hint => _crossMode
      ? '搜索已选的 ${_picked.length} 个站源'
      : '在 ${widget.source.name} 中搜索';

  // 全部源搜索的流式状态：核心那边每返回一个站源就更新一次快照。
  SearchProgress? _cross;
  String _crossError = '';
  String _searchId = '';
  Timer? _poll;
  int _generation = 0;
  int _pollFailures = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _repository = AppScope.of(context).repository;
    _catalog = SourceCatalog(_repository, widget.source);
    final ids = _allSourceIds;
    _picked = widget.store.searchAllSources && ids.length > 1
        ? ids
        : [widget.source.id];
    if (widget.query.trim().isNotEmpty) _submit(widget.query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestion++;
    _generation++;
    _poll?.cancel();
    final search = _searchId;
    if (search.isNotEmpty) unawaited(_repository.searchCancel(search));
    unawaited(_repository.cancelSuggestions());
    _results?.dispose();
    _controller.dispose();
    _focus.dispose();
    _sourceScroll.dispose();
    super.dispose();
  }

  /// 「全部源」开关：当前能搜的站源多于一个时才显示——只有一个源时
  /// 跨源搜索与普通搜索没有区别，留着开关只会让人困惑。
  bool get _allSourceToggle => widget.store.sources.length > 1;

  void _forget(String query) {
    unawaited(HapticFeedback.selectionClick());
    unawaited(widget.store.forgetSearch(query).catchError((Object _) {}));
  }

  void _submit(String text) {
    final query = text.trim();
    if (query.isEmpty) return;
    _controller.text = query;
    _focus.unfocus();
    _debounce?.cancel();
    _suggestion++;
    unawaited(widget.store.rememberSearch(query).catchError((Object _) {}));
    if (_crossMode) {
      _startCross(query);
      return;
    }
    _resetCross();
    _results?.dispose();
    final results = _results = DramaFeed(
      load: (page, _) => _catalog.search(query, page: page),
    )..addListener(() => setState(() {}));
    unawaited(results.reload());
    setState(() {
      _submitted = query;
      _suggestions = const [];
    });
  }

  // ---- 全部源：启动 + 轮询增量结果 ----

  void _startCross(String query) {
    _results?.dispose();
    _results = null;
    final generation = ++_generation;
    _stopPolling(cancelRemote: true);
    final sources = _picked.isEmpty ? [widget.source.id] : _picked;
    setState(() {
      _submitted = query;
      _suggestions = const [];
      _crossError = '';
      _pollFailures = 0;
      _cross = SearchProgress(
        query: query,
        pending: sources,
        total: sources.length,
      );
    });
    if (sources.isEmpty) {
      setState(() => _crossError = '没有已开启的站源，请先在「站源」里开启');
      return;
    }
    unawaited(() async {
      try {
        final result = await _repository.searchStart(sources, query);
        if (!mounted || generation != _generation) {
          unawaited(_repository.searchCancel(result.id));
          return;
        }
        _searchId = result.id;
        setState(() => _cross = result);
        _schedulePoll(generation);
      } catch (error) {
        if (!mounted || generation != _generation) return;
        setState(() => _crossError = error.toString());
      }
    }());
  }

  /// 轮询间隔压到 250ms 左右：站源一回来就能刷到屏幕上，
  /// 又不至于把原生核心的请求通道打满。
  void _schedulePoll(int generation) {
    _poll?.cancel();
    _poll = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted || generation != _generation) return;
      final search = _searchId;
      if (search.isEmpty) return;
      try {
        final result = await _repository.searchPoll(search);
        if (!mounted || generation != _generation) return;
        _pollFailures = 0;
        setState(() => _cross = result);
        if (!result.finished) _schedulePoll(generation);
      } catch (error) {
        if (!mounted || generation != _generation) return;
        if (++_pollFailures >= 4) {
          setState(() => _crossError = error.toString());
          return;
        }
        _schedulePoll(generation);
      }
    });
  }

  void _stopPolling({bool cancelRemote = false}) {
    _poll?.cancel();
    _poll = null;
    final search = _searchId;
    _searchId = '';
    if (cancelRemote && search.isNotEmpty) {
      unawaited(_repository.searchCancel(search));
    }
  }

  void _resetCross() {
    _generation++;
    _stopPolling(cancelRemote: true);
    _pollFailures = 0;
    _crossError = '';
    if (_cross != null) setState(() => _cross = null);
  }

  /// 「全部源」：把所有已开启的站源都勾上；再点一次回到只搜当前源。
  void _toggleAllSources(bool value) {
    final ids = _allSourceIds;
    setState(() => _picked = value ? ids : [widget.source.id]);
    unawaited(
      widget.store.setSearchAllSources(value).catchError((Object _) {}),
    );
    _research();
  }

  /// 单个站源的勾选。至少留一个：全不勾就等于搜不了，没必要让用户走到那一步。
  void _toggleSource(String id, bool value) {
    final next = [..._picked];
    if (value) {
      if (next.contains(id)) return;
      next.add(id);
    } else {
      if (next.length <= 1 || !next.contains(id)) return;
      next.remove(id);
    }
    next.sort(
      (a, b) => _allSourceIds.indexOf(a).compareTo(_allSourceIds.indexOf(b)),
    );
    setState(() => _picked = next);
    // 手动勾选就不再是「全选」，把偏好同步回去，下次打开按这个状态恢复。
    unawaited(
      widget.store
          .setSearchAllSources(next.length == _allSourceIds.length)
          .catchError((Object _) {}),
    );
    _research();
  }

  /// 已经搜过一次的话，立刻按新的勾选重搜，不用让用户再敲一遍回车。
  void _research() {
    final query = _submitted;
    if (query.isNotEmpty) _submit(query);
  }

  void _changed(String text) {
    _debounce?.cancel();
    final query = text.trim();
    final generation = ++_suggestion;
    if (!widget.source.searchSuggestions || query.isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final items = await _repository.suggestions(widget.source.id, query);
        if (mounted && generation == _suggestion) {
          setState(() => _suggestions = items);
        }
      } catch (_) {}
    });
  }

  void _open(Drama drama) => openPage<void>(
    context,
    (_) => DetailPage(store: widget.store, drama: drama),
  );

  @override
  Widget build(BuildContext context) {
    final field = SearchField(
      hint: _hint,
      controller: _controller,
      focusNode: _focus,
      autofocus: widget.query.isEmpty,
      onChanged: _changed,
      onSubmitted: _submit,
      letterKeyboard: widget.store.televisionKeyboard,
      matches: widget.source.searchSuggestions
          ? (query) => _repository.suggestions(widget.source.id, query)
          : null,
    );
    if (AppScope.of(context).television) {
      return Scaffold(
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                televisionInset,
                27,
                televisionInset,
                0,
              ),
              child: field,
            ),
            if (_allSourceToggle) _sourceBar(context, televisionInset),
            Expanded(child: FadeSwitcher(child: _body(context))),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(padding: const EdgeInsets.only(right: 16), child: field),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            if (_allSourceToggle) _sourceBar(context, null),
            Expanded(child: FadeSwitcher(child: _body(context))),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final television = AppScope.of(context).television;
    if (_crossMode) return _crossBody(context);
    if (_suggestions.isNotEmpty && _controller.text.trim() != _submitted) {
      return ListView(
        key: const ValueKey('suggest'),
        padding: television
            ? const EdgeInsets.fromLTRB(televisionInset, 8, televisionInset, 27)
            : const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final (index, item) in _suggestions.indexed)
            EnterOnce(
              key: ValueKey(index),
              id: item,
              played: _shownSuggestions,
              index: index,
              child: TileFocus(
                builder: (focusNode) => ListTile(
                  focusNode: focusNode,
                  leading: const Icon(Icons.search_rounded),
                  title: Text(item),
                  onTap: () => _submit(item),
                ),
              ),
            ),
        ],
      );
    }
    final results = _results;
    if (results == null) {
      return KeyedSubtree(
        key: const ValueKey('recent'),
        child: _recent(context),
      );
    }
    if (results.items.isEmpty) {
      if (results.loading) {
        return const StatusView.loading(
          key: ValueKey('loading'),
          title: '正在搜索',
        );
      }
      if (results.error.isNotEmpty) {
        return StatusView(
          key: const ValueKey('error'),
          title: '搜索失败',
          message: results.error,
          icon: Icons.cloud_off_rounded,
          action: '重试',
          onAction: () => results.reload(),
        );
      }
      return StatusView(
        key: const ValueKey('empty'),
        title: '没有找到「$_submitted」',
        message: '换个关键词试试',
        icon: Icons.search_off_rounded,
      );
    }
    final inset = television
        ? televisionInset
        : AppScope.formFactorOf(context) == FormFactor.phone
        ? 16.0
        : 24.0;
    return LayoutBuilder(
      key: ValueKey(('results', _submitted)),
      builder: (context, constraints) => AutoLoadMore(
        feed: results,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                inset,
                television ? 16 : 8,
                inset,
                0,
              ),
              sliver: DramaSliverGrid(
                width: constraints.maxWidth - inset * 2,
                items: results.items,
                autofocus: television,
                heroScope: 'drama',
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
              sliver: SliverToBoxAdapter(child: FeedFooter(feed: results)),
            ),
          ],
        ),
      ),
    );
  }

  /// 站源勾选条：「全部源」一键全选，后面逐个列出已开启的站源。
  /// 勾一个就是单源搜索，勾多个并发搜索并去重。电视端用遥控左右键也能选。
  ///
  /// 用 Wrap 流式排布而不是横向滚动列表：站源一多（模块商店装完有十几个）
  /// 横排会被挤出屏幕，得先横向滑动才能点到，桌面端尤其难用。流式换行后
  /// 每个站源都在视野里，点起来直接。
  Widget _sourceBar(BuildContext context, double? inset) {
    final sources = widget.store.sources;
    final all = _picked.length == sources.length;
    final pad = inset ?? 16;
    // 一行横向滚动，不换行：源一多（内置 + 模块 + 自定义）Wrap 会往上长，
    // 把下面的结果区挤成 0 高度，看着就是「整页不能上下滑、结果出不来」。
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 8, 0, 0),
      child: HorizontalScrollBar(
        controller: _sourceScroll,
        child: SingleChildScrollView(
          controller: _sourceScroll,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.only(right: pad),
          child: Row(
            spacing: 8,
            children: [
              FocusRing(
                radius: 999,
                child: FilterChip(
                  avatar: Icon(
                    all ? Icons.travel_explore_rounded : Icons.public_rounded,
                    size: 16,
                  ),
                  label: const Text('全部源'),
                  selected: all,
                  onSelected: _toggleAllSources,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              for (final site in sources)
                FocusRing(
                  radius: 999,
                  child: FilterChip(
                    label: Text(site.name),
                    selected: _picked.contains(site.id),
                    onSelected: (value) => _toggleSource(site.id, value),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 全部源的流式结果：头部显示进度，下面就是已经搜到的条目，边到边加。
  Widget _crossBody(BuildContext context) {
    final television = AppScope.of(context).television;
    final inset = television
        ? televisionInset
        : AppScope.formFactorOf(context) == FormFactor.phone
        ? 16.0
        : 24.0;
    if (_crossError.isNotEmpty && (_cross?.items.isEmpty ?? true)) {
      return StatusView(
        title: '搜索失败',
        message: _crossError,
        icon: Icons.cloud_off_rounded,
        action: '重试',
        onAction: () => _submit(_submitted),
      );
    }
    final progress = _cross;
    if (progress == null || progress.items.isEmpty) {
      if (progress != null && progress.finished) {
        return StatusView(
          title: '没有找到「$_submitted」',
          message: progress.warning.isNotEmpty
              ? progress.warning
              : '换个关键词，或减少勾选的站源再试试',
          icon: Icons.search_off_rounded,
        );
      }
      // 首个结果还没回来：给转圈 + 实时进度，让用户知道在搜哪些站源。
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 32,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 20),
              Text('正在搜索全部源', style: Theme.of(context).textTheme.titleMedium),
              if (progress != null && progress.total > 0) ...[
                const SizedBox(height: 16),
                _crossHeader(context, progress, _crossError),
              ],
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => CustomScrollView(
        // 结果一直在变长，保持滚动位置别被重建顶回去。
        key: const PageStorageKey<String>('search-cross'),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
            sliver: SliverToBoxAdapter(
              child: _crossHeader(context, progress, _crossError),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
            sliver: DramaSliverGrid(
              width: constraints.maxWidth - inset * 2,
              items: progress.items,
              autofocus: television,
              onOpen: _open,
              onMore: (drama) => quickFollow(context, widget.store, drama),
              subtitleOf: (drama) {
                final name = SourceSite.byId(drama.source).name;
                return drama.peers.isEmpty
                    ? name
                    : '$name · 另 ${drama.peers.length} 源';
              },
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              inset,
              12,
              inset,
              television ? 27 : 16,
            ),
            sliver: SliverToBoxAdapter(
              child: Text(
                progress.running ? '继续搜索中…' : '已经搜完全部站源',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _crossHeader(
    BuildContext context,
    SearchProgress progress,
    String error,
  ) {
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final status = progress.running
        ? '已搜索 ${progress.done}/${progress.total} 个站源 · 已找到 ${progress.items.length} 条'
        : '已搜索 ${progress.total} 个站源 · 共 ${progress.items.length} 条';
    final pending = [
      for (final id in progress.pending.take(4)) SourceSite.byId(id).name,
    ].join('、');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox.square(
              dimension: 14,
              child: progress.running
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : Icon(
                      Icons.travel_explore_rounded,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (progress.running) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress.total == 0
                  ? null
                  : (progress.done / progress.total).clamp(0.0, 1.0),
              minHeight: 3,
            ),
          ),
          if (progress.pending.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '正在搜索 $pending${progress.pending.length > 4 ? ' 等' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: caption,
            ),
          ],
        ],
        if (progress.warning.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            progress.warning,
            style: caption?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        if (error.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            '刷新结果时出错：$error',
            style: caption?.copyWith(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _recent(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final recent = widget.store.recentSearches;
      return FadeSwitcher(child: _recentContent(context, recent));
    },
  );

  Widget _recentContent(BuildContext context, List<String> recent) {
    if (recent.isEmpty) {
      return StatusView(
        key: const ValueKey('empty'),
        title: '在 ${widget.source.name} 中搜索',
        message: '输入剧名或关键词',
        icon: Icons.search_rounded,
      );
    }
    final theme = Theme.of(context);
    return ListView(
      key: const ValueKey('recent'),
      padding: AppScope.of(context).television
          ? const EdgeInsets.fromLTRB(televisionInset, 8, televisionInset, 27)
          : const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '最近搜索',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            FocusRing(
              radius: 999,
              child: TextButton(
                onPressed: () => widget.store.clearRecentSearches().catchError(
                  (Object _) {},
                ),
                child: const Text('清空'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AnimatedSize(
          duration: Motion.of(context, Motion.medium),
          curve: Motion.enter,
          alignment: Alignment.topLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final query in recent)
                FocusRing(
                  radius: 8,
                  child: GestureDetector(
                    onLongPress: () => _forget(query),
                    onSecondaryTap: () => _forget(query),
                    child: ActionChip(
                      avatar: const Icon(Icons.history_rounded, size: 16),
                      label: Text(query),
                      onPressed: () => _submit(query),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
