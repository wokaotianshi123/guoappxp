import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../../recommend/recommend_feed.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../widgets/cover_backdrop.dart';
import '../widgets/cover_image.dart';
import '../widgets/focus_ring.dart';
import '../widgets/status_view.dart';

const _shade = Color(0xFF161214);

/// 推荐：整屏一部剧，上下滑动换下一部。
///
/// 移植自 THLRedGuo 首页的推荐项（竖向 [PageView]），落在「发现」右侧的
/// 独立标签里。与原版只放官方短剧不同，这里跟着当前站源走：站源支持推荐
/// 接口就用推荐流，否则退化成该源的「全部」目录。
class RecommendPage extends StatefulWidget {
  const RecommendPage({super.key, required this.store});
  final LocalStore store;

  @override
  State<RecommendPage> createState() => _RecommendPageState();
}

class _RecommendPageState extends State<RecommendPage> {
  RecommendFeed? _feed;
  final _pager = PageController();
  int _pagerIndex = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final feed = _feed ??= RecommendFeed(
      AppScope.of(context).repository,
      widget.store,
    );
    // 首帧之后才拉数据：这一页按需挂载，进页面就该开始加载。
    if (!feed.loading && feed.items.isEmpty && feed.error.isEmpty) {
      unawaited(feed.refresh());
    }
  }

  @override
  void dispose() {
    _feed?.dispose();
    _pager.dispose();
    super.dispose();
  }

  void _openDetail(Drama drama) => openPage<void>(
    context,
    (_) => DetailPage(store: widget.store, drama: drama),
  );

  Future<void> _move(RecommendFeed feed, int direction) async {
    final target = feed.index + direction;
    if (target < 0) return;
    if (target >= feed.items.length) {
      if (!feed.hasMore) return;
      await feed.loadMore();
      if (!mounted) return;
    }
    if (!_pager.hasClients || target >= feed.items.length) return;
    await _pager.animateToPage(
      target,
      duration: Motion.of(context, Motion.medium),
      curve: Motion.standard,
    );
  }

  void _refresh(RecommendFeed feed) {
    if (_pager.hasClients) _pager.jumpToPage(0);
    unawaited(feed.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final feed = _feed;
    if (feed == null) {
      return const Scaffold(body: SafeArea(child: StatusView.loading()));
    }
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) {
        final television = AppScope.of(context).television;
        final source = widget.store.source;
        final body = switch (feed) {
          _ when source.isEmpty => StatusView(
            title: '还没有选择站源',
            message: '先在「发现」里挑一个站源，推荐会跟着站源走。',
            icon: Icons.play_circle_outline_rounded,
          ),
          _ when feed.loading && feed.items.isEmpty => const StatusView.loading(
            title: '正在准备推荐',
          ),
          _ when feed.items.isEmpty => StatusView(
            title: '暂时没有推荐',
            message: feed.error.isEmpty ? '这个站源还没有可推荐的剧集。' : feed.error,
            icon: Icons.play_circle_outline_rounded,
            action: '刷新',
            onAction: () => _refresh(feed),
          ),
          _ => _pagerView(feed, television),
        };
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: Stack(
              children: [
                Positioned.fill(child: body),
                if (feed.items.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: _header(feed),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(RecommendFeed feed) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
    child: Row(
      spacing: 8,
      children: [
        const Text(
          '推荐',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        Expanded(
          child: Text(
            '上滑换剧 · ${feed.index + 1}/${feed.items.length}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        FocusRing(
          radius: 999,
          child: IconButton(
            tooltip: '刷新推荐',
            onPressed: feed.loading ? null : () => _refresh(feed),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        FocusRing(
          radius: 999,
          child: IconButton(
            tooltip: '上一部',
            onPressed: feed.index > 0 ? () => unawaited(_move(feed, -1)) : null,
            icon: const Icon(Icons.keyboard_arrow_up_rounded),
          ),
        ),
        FocusRing(
          radius: 999,
          child: IconButton(
            tooltip: '下一部',
            onPressed: feed.hasMore || feed.index < feed.items.length - 1
                ? () => unawaited(_move(feed, 1))
                : null,
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
        ),
      ],
    ),
  );

  Widget _pagerView(RecommendFeed feed, bool television) {
    final pages = feed.items;
    if (_pagerIndex != feed.index && _pager.hasClients) {
      _pagerIndex = feed.index;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pager.hasClients) return;
        if ((_pager.page ?? 0).round() == feed.index) return;
        _pager.jumpToPage(feed.index);
      });
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.pageDown): () =>
            unawaited(_move(feed, 1)),
        const SingleActivator(LogicalKeyboardKey.pageUp): () =>
            unawaited(_move(feed, -1)),
      },
      child: Focus(
        autofocus: television,
        child: PageView.builder(
          key: ValueKey('recommend-pager-${widget.store.source}'),
          controller: _pager,
          scrollDirection: Axis.vertical,
          itemCount: pages.length,
          onPageChanged: (index) {
            _pagerIndex = index;
            feed.select(index);
            if (pages.length - index <= 2) unawaited(feed.loadMore());
          },
          itemBuilder: (context, index) => _RecommendCard(
            drama: pages[index],
            onPlay: () => _openDetail(pages[index]),
            onDetail: () => _openDetail(pages[index]),
          ),
        ),
      ),
    );
  }
}

/// 单部剧的整屏卡片：模糊封面打底 + 海报 + 标题与简介 + 播放按钮。
class _RecommendCard extends StatelessWidget {
  const _RecommendCard({
    required this.drama,
    required this.onPlay,
    required this.onDetail,
  });
  final Drama drama;
  final VoidCallback onPlay;
  final VoidCallback onDetail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final meta = [
      if (drama.category.isNotEmpty) drama.category,
      if (drama.episodes > 0) '共 ${drama.episodes} 集',
      if (drama.score.isNotEmpty) '评分 ${drama.score}',
    ].join(' · ');
    return LayoutBuilder(
      builder: (context, constraints) {
        final phone = AppScope.formFactorOf(context) == FormFactor.phone;
        final posterHeight = math.min(
          constraints.maxHeight * (phone ? 0.42 : 0.5),
          460.0,
        );
        final posterWidth = posterHeight * 2 / 3;
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: _shade),
            CoverBackdrop(
              drama: drama,
              sigma: 44,
              opacity: 0.7,
              overlay: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _shade.withValues(alpha: 0.85),
                  _shade.withValues(alpha: 0.62),
                  _shade.withValues(alpha: 0.95),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, 64, 20, phone ? 24 : 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x73000000),
                          blurRadius: 28,
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: SizedBox(
                      width: posterWidth,
                      height: posterHeight,
                      child: DramaCover(
                        drama: drama,
                        radius: 16,
                        details: false,
                        exploreBlur: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    drama.title,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.25,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.78),
                      ),
                    ),
                  ],
                  if (drama.description.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: Text(
                        drama.description,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: Colors.white.withValues(alpha: 0.72),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 12,
                    children: [
                      FocusRing(
                        radius: 999,
                        child: FilledButton.icon(
                          onPressed: onPlay,
                          style: FilledButton.styleFrom(
                            backgroundColor: colors.primaryFixedDim,
                            foregroundColor: colors.onPrimaryFixed,
                            minimumSize: const Size(0, 44),
                            padding: const EdgeInsets.fromLTRB(18, 0, 24, 0),
                          ),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('立即观看'),
                        ),
                      ),
                      FocusRing(
                        radius: 999,
                        child: FilledButton(
                          onPressed: onDetail,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: 0.16),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                          ),
                          child: const Text('详情'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
