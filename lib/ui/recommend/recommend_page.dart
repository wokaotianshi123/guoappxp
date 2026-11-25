import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../../recommend/recommend_feed.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../player/playback_handle.dart';
import '../player/playback_page.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../widgets/cover_backdrop.dart';
import '../widgets/cover_image.dart';
import '../widgets/focus_ring.dart';
import '../widgets/status_view.dart';

const _shade = Color(0xFF161214);

/// 推荐：整屏播放一部剧，上下滑动换下一部。
///
/// 与 THLRedGuo 的推荐流（`VideoFeedScreen`）结构一致：
/// * 每屏给**完整的播放器**（`PlaybackPage`），带进度条、暂停、选集、
///   倍速、清晰度等全部控件，不是简化版；
/// * 只有「当前页」真正挂播放器，相邻页只显示封面占位——与 THLRedGuo
///   的 `_page()` 判断 `index == feed.index` 是同一套做法，避免多个
///   播放器实例同时抢解码器与画中画状态；
/// * 滑到倒数第二部就自动补页，推荐条数不设上限。
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

  /// 当前页的播放句柄。切页时释放旧的、建新的——同一时刻只有一个播放器。
  PlaybackHandle? _handle;
  String _handleDrama = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final feed = _feed ??= RecommendFeed(
      AppScope.of(context).repository,
      widget.store,
    );
    if (!feed.loading && feed.items.isEmpty && feed.error.isEmpty) {
      unawaited(feed.refresh());
    }
  }

  @override
  void dispose() {
    _disposeHandle();
    _feed?.dispose();
    _pager.dispose();
    super.dispose();
  }

  void _disposeHandle() {
    _handle?.dispose();
    _handle = null;
    _handleDrama = '';
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
      if (!mounted || target >= feed.items.length) return;
    }
    if (!_pager.hasClients) return;
    await _pager.animateToPage(
      target,
      duration: Motion.of(context, Motion.medium),
      curve: Motion.standard,
    );
  }

  void _refresh(RecommendFeed feed) {
    _disposeHandle();
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
          _ => _pagerView(feed),
        };
        return Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(bottom: false, child: body),
        );
      },
    );
  }

  Widget _pagerView(RecommendFeed feed) {
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
        autofocus: true,
        child: PageView.builder(
          key: ValueKey('recommend-pager-${widget.store.source}'),
          controller: _pager,
          scrollDirection: Axis.vertical,
          itemCount: pages.length,
          onPageChanged: (index) {
            _pagerIndex = index;
            feed.select(index);
            _disposeHandle();
            if (pages.length - index <= 2) unawaited(feed.loadMore());
          },
          itemBuilder: (context, index) => _slide(feed, index),
        ),
      ),
    );
  }

  Widget _slide(RecommendFeed feed, int index) {
    final drama = feed.items[index];
    final current = index == feed.index;

    // 非当前页：只显示剧名与封面，不建播放器。与 THLRedGuo 一致。
    if (!current) {
      return _CoverPlaceholder(drama: drama);
    }

    final detail = feed.detailOf(drama.id);
    if (detail == null) {
      // 详情还没到：先出封面 + 加载态，同时触发拉取。
      //
      // 这里必须延到帧后：`loadDetail` 会同步 notifyListeners，
      // 而当前正在 build（PageView 的 itemBuilder 内），直接调用会触发
      // 「setState() called during build」。
      if (!feed.detailLoading(drama.id)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(feed.loadDetail(drama));
        });
      }
      return _CoverPlaceholder(
        drama: drama,
        loading: true,
        error: feed.detailError(drama.id),
        onRetry: () => unawaited(feed.loadDetail(drama, force: true)),
      );
    }

    // 当前页：完整的播放器。切剧时换一个新句柄。
    if (_handleDrama != drama.id) {
      // 建播放器同样不能在 build 里做（会初始化解码器并可能触发通知），
      // 延到帧后；这一帧先显示封面。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_handleDrama == drama.id) return;
        setState(() {
          _disposeHandle();
          _handle = PlaybackHandle(
            repository: AppScope.of(context).repository,
            store: widget.store,
            detail: detail,
            index: _startIndex(feed, drama, detail),
            position: _startPosition(feed, drama),
            autoplay: true,
            preopen: false,
          );
          _handleDrama = drama.id;
        });
      });
      return _CoverPlaceholder(drama: drama, loading: true);
    }
    final handle = _handle!;
    return Stack(
      fit: StackFit.expand,
      children: [
        PlaybackPage(store: widget.store, handle: handle),
        // 顶部标题条 + 底部剧名，浮在播放器之上但不挡控件。
        Positioned(
          left: 14,
          right: 14,
          top: 8,
          child: IgnorePointer(
            child: Row(
              children: [
                Text(
                  '推荐',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: Colors.white.withValues(alpha: 0.94),
                    shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '上滑换剧 · ${index + 1}/${feed.items.length}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.72),
                      shadows: const [
                        Shadow(blurRadius: 8, color: Colors.black54),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 右下角：详情与换一批（其余控件播放器自带）。
        Positioned(
          right: 10,
          bottom: 96,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              _SideButton(
                icon: Icons.info_outline_rounded,
                tooltip: '详情与选集',
                onPressed: () => _openDetail(drama),
              ),
              _SideButton(
                icon: Icons.refresh_rounded,
                tooltip: '换一批推荐',
                onPressed: () => _refresh(feed),
              ),
              _SideButton(
                icon: Icons.keyboard_arrow_up_rounded,
                tooltip: '上一部',
                onPressed: feed.index > 0
                    ? () => unawaited(_move(feed, -1))
                    : null,
              ),
              _SideButton(
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: '下一部',
                onPressed: () => unawaited(_move(feed, 1)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 从上次看到的位置继续；没有记录就从推荐流给的开头集开始。
  int _startIndex(RecommendFeed feed, Drama drama, DramaDetail detail) {
    final watched = widget.store.watched(drama.id);
    if (watched != null) {
      final index = detail.episodes.indexWhere(
        (episode) => episode.number == watched.episode,
      );
      if (index >= 0) return index;
    }
    return 0;
  }

  double _startPosition(RecommendFeed feed, Drama drama) {
    final watched = widget.store.watched(drama.id);
    return watched?.position.toDouble() ?? 0;
  }
}

/// 非当前页 / 详情未就绪时的封面占位。
class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({
    required this.drama,
    this.loading = false,
    this.error,
    this.onRetry,
  });
  final Drama drama;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Stack(
      fit: StackFit.expand,
      children: [
        CoverBackdrop(
          drama: drama,
          sigma: 42,
          opacity: 0.5,
          overlay: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _shade.withValues(alpha: 0.72),
              Colors.transparent,
              _shade.withValues(alpha: 0.86),
            ],
          ),
        ),
        Center(
          child: SizedBox(
            height: 230,
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: DramaCover(
                drama: drama,
                radius: 14,
                details: false,
                exploreBlur: true,
              ),
            ),
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 28,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: [
              Text(
                drama.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  height: 1.25,
                ),
              ),
              if (error != null)
                Row(
                  spacing: 10,
                  children: [
                    Expanded(
                      child: Text(
                        '这部暂时无法播放：$error',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.72),
                        ),
                      ),
                    ),
                    TextButton(onPressed: onRetry, child: const Text('重试')),
                  ],
                )
              else if (loading)
                Row(
                  spacing: 8,
                  children: [
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    Text(
                      '正在准备播放',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SideButton extends StatelessWidget {
  const _SideButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: FocusRing(
      radius: 999,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon),
        color: Colors.white,
        disabledColor: Colors.white.withValues(alpha: 0.3),
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.38),
        ),
      ),
    ),
  );
}
