import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_build.dart';
import '../../catalog_sort.dart';
import '../../core_bridge.dart';
import '../../drama_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_catalog.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../shell/app_shell.dart';
import '../widgets/drama_grid.dart';
import '../widgets/follow_button.dart';
import '../widgets/focus_ring.dart';
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
  late AppRepository _repository;
  late SourceCatalog _catalog;
  DramaFeed? _results;
  String _submitted = '';
  List<String> _suggestions = const [];

  /// 本地标题候选：输入 `BDZC` 也能列出「霸道总裁」。
  ///
  /// 站源搜索接口只认原文，桌面端又没有字母键盘，纯字母串发过去必然空手而归。
  /// 所以在输入过程中先从追剧、观看记录、最近搜索这几处本地索引里按原文 /
  /// 拼音首字母找一遍，点一条就等于用完整标题去搜。
  List<String> _localMatches = const [];
  Timer? _debounce;
  int _suggestion = 0;
  bool _ready = false;

  /// 「全部源」：并发搜索所有已开启的站源。偏好存在本机，下次打开沿用。
  bool _allSources = false;

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
    _allSources = widget.store.searchAllSources && _allSourceToggle;
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
    super.dispose();
  }

  /// 「全部源」开关：只要这次构建本来就是为了跨源、或者当前能搜的站源多于
  /// 一个，就显示出来。
  ///
  /// 原先写死 `ALL_SOURCES && 站源数 > 1`：红果鉴导入自定义源之后明明有多个源、
  /// 也能跨源搜，开关却一直不出现；真果鉴要是用户只开了一个源，开关也会消失，
  /// 看上去就像「跨源搜索没了」。跨源搜索本身按实际站源列表发起，不需要这个常量
  /// 来决定能不能显示。
  bool get _allSourceToggle =>
      allSourcesEnabled || widget.store.sources.length > 1;

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
    if (_allSources) {
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
      _localMatches = const [];
    });
  }

  // ---- 全部源：启动 + 轮询增量结果 ----

  void _startCross(String query) {
    _results?.dispose();
    _results = null;
    final generation = ++_generation;
    _stopPolling(cancelRemote: true);
    final sources = [for (final site in widget.store.sources) site.id];
    setState(() {
      _submitted = query;
      _suggestions = const [];
      _localMatches = const [];
      _crossError = '';
      _pollFailures = 0;
      _cross = SearchProgress(
        query: query,
        pending: sources,
        total: sources.length,
      );
    });
    if (sources.isEmpty) {
      setState(() => _crossError = '没有已开启的站源，请先在「站源管理」里开启');
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

  void _toggleAllSources(bool value) {
    setState(() => _allSources = value);
    unawaited(
      widget.store.setSearchAllSources(value).catchError((Object _) {}),
    );
    // 已经搜过一次的话，立刻按新模式重搜，不用让用户再敲一遍回车。
    final query = _submitted;
    if (query.isNotEmpty) _submit(query);
  }

  void _changed(String text) {
    _debounce?.cancel();
    final query = text.trim();
    final generation = ++_suggestion;
    final local = _localTitles(query);
    if (!widget.source.searchSuggestions || query.isEmpty) {
      setState(() {
        _suggestions = const [];
        _localMatches = local;
      });
      return;
    }
    setState(() => _localMatches = local);
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final items = await _repository.suggestions(query);
        if (mounted && generation == _suggestion) {
          setState(() => _suggestions = items);
        }
      } catch (_) {}
    });
  }

  /// 在本地认识的标题里按原文 / 拼音首字母找匹配，最多 8 条。
  ///
  /// 顺序按「最近看过的 → 追剧 → 搜过的关键词」，同一标题只留一条。
  List<String> _localTitles(String query) {
    final term = query.trim();
    if (term.isEmpty) return const [];
    final titles = <String>[];
    void add(String title) {
      if (titles.length >= 8 || titles.contains(title)) return;
      if (matchesTitle(title, term)) titles.add(title);
    }

    for (final entry in widget.store.history) {
      if (titles.length >= 8) break;
      add(entry.drama.title);
    }
    for (final drama in widget.store.favorites) {
      if (titles.length >= 8) break;
      add(drama.title);
    }
    for (final entry in widget.store.recentSearches) {
      if (titles.length >= 8) break;
      add(entry);
    }
    return titles;
  }

  Widget _candidateHeader(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 字母键盘的实时候选：本地拼音匹配在前，站源建议在后。
  Future<List<String>> _letterMatches(String query) async {
    final local = _localTitles(query);
    final term = query.trim();
    if (term.isEmpty || _allSources || !widget.source.searchSuggestions) {
      return local;
    }
    try {
      final remote = await _repository.suggestions(term);
      return {...local, ...remote}.take(12).toList();
    } catch (_) {
      return local;
    }
  }

  void _open(Drama drama) => openPage<void>(
    context,
    (_) => DetailPage(store: widget.store, drama: drama),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // 站源列表是异步加载的（自定义源、用户权限都会变）：不跟着 store 重建的话，
    // 进页面那一刻只有内置源，`全部源` 开关就会被算成「不值得显示」并且一直不刷新。
    listenable: widget.store,
    builder: (context, _) => _page(context),
  );

  Widget _page(BuildContext context) {
    final television = AppScope.of(context).television;
    final field = SearchField(
      hint: _allSources ? '搜索全部站源' : '在 ${widget.source.name} 中搜索',
      controller: _controller,
      focusNode: _focus,
      autofocus: widget.query.isEmpty,
      onChanged: _changed,
      onSubmitted: _submit,
      letterKeyboard: widget.store.televisionKeyboard,
      // 字母键盘敲的是拼音首字母，站源的搜索建议只认原文，直接拿 `bdzc` 去问
      // 基本返回空。所以先过一遍本地标题（追剧 / 观看记录 / 最近搜索），再把
      // 站源建议接在后面；「全部源」模式下建议只覆盖单一站源，反而误导，跳过。
      matches: _letterMatches,
    );
    if (television) {
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
            if (_allSourceToggle) _allSourceBar(context, televisionInset),
            Expanded(child: _body(context)),
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
            if (_allSourceToggle) _allSourceBar(context, null),
            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  /// 「全部源」开关 + 一句话说明。电视端用遥控左右键也能选中。
  Widget _allSourceBar(BuildContext context, double? inset) {
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(inset ?? 16, 8, inset ?? 16, 0),
      child: Row(
        children: [
          FocusRing(
            radius: 999,
            child: FilterChip(
              avatar: Icon(
                _allSources
                    ? Icons.travel_explore_rounded
                    : Icons.public_rounded,
                size: 16,
              ),
              label: const Text('全部源'),
              selected: _allSources,
              onSelected: _toggleAllSources,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _allSources ? '同时搜索所有已开启的站源，结果边搜边出' : '只搜索 ${widget.source.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: caption,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final television = AppScope.of(context).television;
    // 输入框里的词还没提交过，就先给候选：本地拼音匹配排前面，站源建议接在后面。
    final typing = _controller.text.trim() != _submitted;
    if (typing && (_localMatches.isNotEmpty || _suggestions.isNotEmpty)) {
      final padding = television
          ? const EdgeInsets.fromLTRB(televisionInset, 8, televisionInset, 27)
          : const EdgeInsets.symmetric(vertical: 8);
      return ListView(
        padding: padding,
        children: [
          if (_localMatches.isNotEmpty) ...[
            _candidateHeader(context, '本地匹配（原文 / 拼音首字母）'),
            for (final item in _localMatches)
              TileFocus(
                builder: (focusNode) => ListTile(
                  focusNode: focusNode,
                  leading: const Icon(Icons.auto_awesome_rounded, size: 20),
                  title: Text(item),
                  onTap: () => _submit(item),
                ),
              ),
          ],
          if (_suggestions.isNotEmpty) ...[
            if (_localMatches.isNotEmpty) _candidateHeader(context, '站源建议'),
            for (final item in _suggestions)
              TileFocus(
                builder: (focusNode) => ListTile(
                  focusNode: focusNode,
                  leading: const Icon(Icons.search_rounded, size: 20),
                  title: Text(item),
                  onTap: () => _submit(item),
                ),
              ),
          ],
        ],
      );
    }
    if (_allSources) return _crossBody(context);
    final results = _results;
    if (results == null) return _recent(context);
    if (results.items.isEmpty) {
      if (results.loading) return const StatusView.loading(title: '正在搜索');
      if (results.error.isNotEmpty) {
        return StatusView(
          title: '搜索失败',
          message: results.error,
          icon: Icons.cloud_off_rounded,
          action: '重试',
          onAction: () => results.reload(),
        );
      }
      return StatusView(
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
      final scope = _allSources ? '全部站源' : widget.source.name;
      if (recent.isEmpty) {
        return StatusView(
          title: '在 $scope 中搜索',
          message: '输入剧名或关键词',
          icon: Icons.search_rounded,
        );
      }
      final theme = Theme.of(context);
      return ListView(
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
                  onPressed: () => widget.store
                      .clearRecentSearches()
                      .catchError((Object _) {}),
                  child: const Text('清空'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final query in recent)
                FocusRing(
                  radius: 8,
                  child: GestureDetector(
                    // 长按（桌面上右键）只删这一条，不用清空整个列表。
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
        ],
      );
    },
  );
}
