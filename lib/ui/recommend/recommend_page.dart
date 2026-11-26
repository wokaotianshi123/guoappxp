import 'dart:async';

import 'package:flutter/gestures.dart';
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
/// 版面与 THLRedGuo 的推荐流一致：一屏一部剧，左下角是剧名 / 集数 / 简介，
/// 右侧是追剧、选集、全屏、弹幕、详情、设置，底部一条进度条。触屏用滑动、
/// 桌面端用滚轮或按住拖动翻页，PageUp / PageDown 同样可以。
///
/// 只有「当前这一屏」挂播放器，相邻页面只显示封面占位——同屏多个播放器会
/// 抢解码器。切剧时旧的一屏从树上摘下来，播放器由它自己释放。
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
  bool _moving = false;

  PlaybackHandle? _handle;
  String _handleDrama = '';
  bool _wasVisible = false;

  /// 详情页压在上面时不让推荐页重建播放器。
  ///
  /// 详情页的「继续播放」会新建一套播放会话；如果推荐页在这一层继续出声，
  /// 两路音频会叠在一起。这里只停播放器，页面本身、当前第几部、翻页位置
  /// 都保留，返回后按观看进度把这一部接回来。
  bool _detailOpen = false;

  /// 推荐页是否在前台。单独挂在 [AppShell] 之外的测试场景按可见处理。
  static bool _visible(BuildContext context) {
    final tab = ShellVisibleTab.maybeOf(context);
    return tab == null || tab == AppTab.recommend;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final feed = _feed ??= RecommendFeed(
      AppScope.of(context).repository,
      widget.store,
    );
    final visible = _visible(context);
    final becameVisible = visible && !_wasVisible;
    _wasVisible = visible;
    if (feed.loading) return;
    // 换源时推荐页即使不在前台也会跟着刷新，万一那次请求被「发现」页的在途
    // 请求误伤，页面就会停在报错状态。用户点开推荐时再取一次，别让他自己
    // 去找刷新按钮。
    if (feed.items.isEmpty && (feed.error.isEmpty || becameVisible)) {
      unawaited(feed.refresh());
    }
  }

  @override
  void dispose() {
    _handle = null;
    _feed?.dispose();
    _pager.dispose();
    super.dispose();
  }

  void _dropHandle() {
    final handle = _handle;
    _handle = null;
    _handleDrama = '';
    // 显式释放：同一个 key 的播放页可能被原地复用（句柄被换成新的），
    // 旧句柄不在这里关掉就再没人 dispose，播放器会在后台一直出声。
    // PlaybackPage 自己的 dispose 也会调一次，那边做了幂等保护。
    handle?.dispose();
  }

  Future<void> _openDetail(RecommendFeed feed) async {
    final drama = feed.current;
    if (drama == null || _detailOpen) return;
    // 先停掉推荐页这一路：详情页的「继续播放」会再起一路，不停就是双路音频。
    // 只释放播放器，feed / 当前索引 / 翻页位置都不动，返回后原样接上。
    _detailOpen = true;
    _dropHandle();
    if (mounted) setState(() {});
    try {
      await openPage<void>(
        context,
        (_) => DetailPage(store: widget.store, drama: drama),
      );
    } finally {
      _detailOpen = false;
      // 返回时按详情页看过 / 播放保存的进度重建这一部的播放器。
      if (mounted) setState(() {});
    }
  }

  bool _busy(RecommendFeed feed) =>
      _moving || feed.loading || feed.loadingMore;

  Future<void> _move(RecommendFeed feed, int direction) async {
    if (_busy(feed)) return;
    final target = feed.index + direction;
    if (target < 0) return;
    if (target >= feed.items.length) {
      if (!feed.hasMore) return;
      setState(() => _moving = true);
      try {
        await feed.loadMore();
      } finally {
        if (mounted) setState(() => _moving = false);
      }
      if (!mounted || target >= feed.items.length) return;
    }
    if (!_pager.hasClients) return;
    setState(() => _moving = true);
    try {
      await _pager.animateToPage(
        target,
        duration: Motion.of(context, Motion.medium),
        curve: Motion.standard,
      );
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  /// [advance] 为真时是「换一批」：往后翻一页拿新的一组，而不是把当前这组
  /// 重新加载一遍（脚本 / 内核会缓存第一页，重取只会原样返回）。
  void _refresh(RecommendFeed feed, {bool advance = false}) {
    _dropHandle();
    _pagerIndex = 0;
    if (_pager.hasClients) _pager.jumpToPage(0);
    unawaited(feed.refresh(advance: advance));
  }

  /// 桌面端滚轮：一格翻一屏，与竖屏播放器的滚轮切集手感一致。
  void _wheel(PointerSignalEvent event, RecommendFeed feed) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta.dy;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      unawaited(_move(feed, delta > 0 ? 1 : -1));
    });
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
        // 换源 / 刷新 / 切走标签时都停掉播放器：旧的播放页会被下面的占位
        // 顶掉，由它自己释放会话。THLRedGuo 也是只有当前标签才挂播放器。
        if (!_visible(context) || feed.loading || feed.items.isEmpty) {
          _dropHandle();
        }
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
    return Stack(
      fit: StackFit.expand,
      children: [
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.pageDown): () =>
                unawaited(_move(feed, 1)),
            const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                unawaited(_move(feed, -1)),
          },
          child: Focus(
            autofocus: true,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                scrollbars: false,
                dragDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                  PointerDeviceKind.trackpad,
                },
              ),
              child: PageView.builder(
                key: ValueKey('recommend-pager-${widget.store.source}'),
                controller: _pager,
                scrollDirection: Axis.vertical,
                itemCount: pages.length,
                onPageChanged: (index) {
                  _pagerIndex = index;
                  _dropHandle();
                  feed.select(index);
                  if (pages.length - index <= 2) unawaited(feed.loadMore());
                },
                itemBuilder: (context, index) => Listener(
                  onPointerSignal: (event) => _wheel(event, feed),
                  child: _slide(feed, index),
                ),
              ),
            ),
          ),
        ),
        _topBar(feed),
      ],
    );
  }

  Widget _topBar(RecommendFeed feed) {
    final current = feed.current;
    final detailError = current == null ? null : feed.detailError(current.id);
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
            child: Row(
              children: [
                const Text(
                  '推荐',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    feed.items.isEmpty
                        ? '上滑换剧'
                        : '上滑换剧 · ${feed.index + 1}/${feed.items.length}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .72),
                      fontSize: 12,
                      shadows: const [
                        Shadow(color: Colors.black54, blurRadius: 8),
                      ],
                    ),
                  ),
                ),
                _barButton(
                  'feed-refresh',
                  '换一批',
                  Icons.refresh_rounded,
                  feed.loading ? null : () => _refresh(feed, advance: true),
                ),
                _barButton(
                  'feed-previous',
                  '上一部',
                  Icons.keyboard_arrow_up_rounded,
                  feed.index > 0 && !feed.loading
                      ? () => unawaited(_move(feed, -1))
                      : null,
                ),
                _barButton(
                  'feed-next',
                  '下一部',
                  Icons.keyboard_arrow_down_rounded,
                  feed.loading ? null : () => unawaited(_move(feed, 1)),
                ),
              ],
            ),
          ),
          if (feed.loadingMore)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (detailError != null && current != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
              child: Material(
                color: Colors.black.withValues(alpha: .45),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '这一部暂时无法播放',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: .8),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            unawaited(feed.loadDetail(current, force: true)),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _barButton(
    String id,
    String tooltip,
    IconData icon,
    VoidCallback? onPressed,
  ) => FocusRing(
    radius: 999,
    child: IconButton(
      key: ValueKey(id),
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      color: Colors.white,
      disabledColor: Colors.white.withValues(alpha: .3),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: .28),
        minimumSize: const Size(40, 40),
      ),
    ),
  );

  Widget _slide(RecommendFeed feed, int index) {
    final drama = feed.items[index];
    final current = index == feed.index;

    // 非当前页 / 页面不在前台 / 详情页压在上面：只显示封面，不建播放器。
    // 与 THLRedGuo 的 `index == feed.index && feed.active` 是同一套判断，
    // 切走标签或进详情就停止播放。
    if (!current || !_visible(context) || _detailOpen) {
      return _CoverPlaceholder(drama: drama);
    }

    final detail = feed.detailOf(drama.id);
    if (detail == null) {
      if (!feed.detailLoading(drama.id) && feed.detailError(drama.id) == null) {
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

    if (_handleDrama != drama.id || _handle == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_visible(context)) return;
        if (_handleDrama == drama.id || _handle != null) return;
        setState(() {
          _handle = PlaybackHandle(
            repository: AppScope.of(context).repository,
            store: widget.store,
            detail: detail,
            index: _startIndex(feed, drama, detail),
            position: widget.store.watched(drama.id)?.position.toDouble() ?? 0,
            autoplay: true,
            preopen: false,
          );
          _handleDrama = drama.id;
        });
      });
      return _CoverPlaceholder(drama: drama, loading: true);
    }

    return PlaybackPage(
      key: ValueKey('feed-player-${drama.id}'),
      store: widget.store,
      handle: _handle!,
      feed: true,
      onOpenDetail: () => unawaited(_openDetail(feed)),
    );
  }

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
