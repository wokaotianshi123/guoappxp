import 'dart:async';

import 'package:flutter/material.dart';

import '../local_store.dart';

import '../ui/widgets/focus_ring.dart';
import '../ui/widgets/status_view.dart';
import 'live_models.dart';
import 'live_player_page.dart';
import 'live_repository.dart';
import 'live_sources.dart';
import 'live_store.dart';

/// 收藏分类的伪 ID：它不是真实分类，只在分类栏里代表「我的收藏」。
const _favouritesId = '__favourites';

/// 直播频道列表页。
///
/// 顶部是直播源与分类，下面是该分类的频道网格；点频道进入全屏播放。
/// 收藏与最近观看来自 [LiveStore]，按用户隔离保存。
class LivePage extends StatefulWidget {
  const LivePage({
    super.key,
    required this.repository,
    required this.store,
    this.greenMode = false,
  });
  final LiveRepository repository;
  final LiveStore store;
  final bool greenMode;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  LiveSource? _source;
  List<LivePlatform> _platforms = const [];
  String _platform = '';
  List<LiveChannel> _channels = const [];
  List<LiveChannel> _lastGood = const [];
  String _lastGoodPlatform = '';
  bool _loading = true;
  bool _failed = false;
  String? _error;
  int _generation = 0;
  // 房间型源（斗鱼 / 哔哩哔哩 / 虎牙）按页返回，一页 30 个房间。
  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;

  List<LiveSource> get _sources => LiveSource.visible(widget.greenMode);

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_storeChanged);
    final sources = _sources;
    if (sources.isNotEmpty) {
      _source = sources.first;
      unawaited(_loadPlatforms());
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    super.dispose();
  }

  void _storeChanged() {
    if (!mounted) return;
    // 只刷新收藏列表内容，不动当前分类，否则点收藏会跳回其它分类。
    if (_platform == _favouritesId) {
      setState(() => _channels = widget.store.favourites);
    } else {
      setState(() {});
    }
  }

  Future<void> _loadPlatforms({bool force = false}) async {
    final source = _source;
    if (source == null) return;
    final token = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
      _error = null;
      _channels = const [];
    });
    try {
      final platforms = await widget.repository.platforms(source, force: force);
      if (!mounted || token != _generation) return;
      setState(() {
        _platforms = platforms;
        _platform = platforms.isEmpty ? '' : platforms.first.id;
      });
      if (platforms.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      await _loadChannels(platforms.first);
    } catch (error) {
      if (!mounted || token != _generation) return;
      setState(() {
        _loading = false;
        _failed = true;
        _error = '$error';
      });
    }
  }

  Future<void> _loadChannels(
    LivePlatform platform, {
    bool append = false,
  }) async {
    final source = _source;
    if (source == null) return;
    if (append && (!_hasMore || _loadingMore)) return;
    final token = _generation;
    final page = append ? _page + 1 : 1;
    setState(() {
      if (append) {
        _loadingMore = true;
      } else {
        _loading = true;
        _failed = false;
        _error = null;
        _platform = platform.id;
      }
    });
    try {
      final channels = await widget.repository.channels(
        source,
        platform,
        page: page,
      );
      if (!mounted || token != _generation) return;
      setState(() {
        _page = page;
        if (append) {
          final seen = {for (final item in _channels) item.key};
          _channels = [
            ..._channels,
            for (final item in channels)
              if (seen.add(item.key)) item,
          ];
          _loadingMore = false;
        } else {
          _channels = channels;
          _lastGood = channels;
          _lastGoodPlatform = platform.id;
          _loading = false;
        }
        // 不足一页说明后面没有了；房间型源没有总数接口，只能用页长判断。
        _hasMore = source.paginated && channels.length >= 24;
      });
    } catch (error) {
      if (!mounted || token != _generation) return;
      setState(() {
        if (append) {
          _loadingMore = false;
          _hasMore = false;
        } else {
          _loading = false;
          // 同一分类重新加载失败时保留上一次的内容，避免闪回空态。
          _channels = _lastGoodPlatform == platform.id ? _lastGood : const [];
          _failed = _channels.isEmpty;
          _error = '$error';
        }
      });
    }
  }

  void _selectSource(LiveSource source) {
    if (source.id == _source?.id) return;
    widget.repository.clear();
    setState(() {
      _source = source;
      _platforms = const [];
      _platform = '';
      _channels = const [];
      _lastGood = const [];
      _lastGoodPlatform = '';
      _page = 1;
      _hasMore = false;
      _loadingMore = false;
    });
    unawaited(_loadPlatforms());
  }

  void _selectPlatform(String id) {
    if (id == _platform) return;
    if (id == _favouritesId) {
      ++_generation;
      setState(() {
        _platform = _favouritesId;
        _channels = widget.store.favourites;
        _loading = false;
        _failed = false;
        _error = null;
        _hasMore = false;
        _loadingMore = false;
      });
      return;
    }
    final platform = _platforms.where((item) => item.id == id).firstOrNull;
    if (platform == null) return;
    unawaited(_loadChannels(platform));
  }

  Future<void> _open(int index) async {
    final source = _source;
    final channel = _channels[index];
    if (source == null) return;
    await widget.store.remember(channel);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LivePlayerPage(
          repository: widget.repository,
          store: widget.store,
          source: source,
          channels: _channels,
          index: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('直播'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: _loading
              ? null
              : () => unawaited(_loadPlatforms(force: true)),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: _body(context),
  );

  Widget _body(BuildContext context) {
    final sources = _sources;
    if (sources.isEmpty) {
      return const StatusView(
        title: '暂无可用的直播源',
        message: '当前分级模式屏蔽了全部直播源，关闭后即可观看。',
        icon: Icons.live_tv_outlined,
      );
    }
    if (_failed) {
      return StatusView(
        title: '直播源暂时不可用',
        message: _error,
        icon: Icons.cloud_off_rounded,
        action: '重试',
        onAction: () => unawaited(_loadPlatforms(force: true)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sources.length > 1) _sourceBar(sources),
        _platformBar(),
        const Divider(height: 1),
        Expanded(child: _channelBody(context)),
      ],
    );
  }

  Widget _sourceBar(List<LiveSource> sources) => SizedBox(
    height: 56,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: sources.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final source = sources[index];
        return _Chip(
          label: source.name,
          selected: source.id == _source?.id,
          onTap: () => _selectSource(source),
        );
      },
    ),
  );

  Widget _platformBar() => SizedBox(
    height: 52,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      itemCount: _platforms.length + 1,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _Chip(
            label: '收藏 ${widget.store.favourites.length}',
            selected: _platform == _favouritesId,
            onTap: () => _selectPlatform(_favouritesId),
          );
        }
        final platform = _platforms[index - 1];
        return _Chip(
          label: platform.name,
          badge: platform.count > 0 ? '${platform.count}' : null,
          selected: platform.id == _platform,
          onTap: () => _selectPlatform(platform.id),
        );
      },
    ),
  );

  Widget _channelBody(BuildContext context) {
    if (_loading && _channels.isEmpty) {
      return const StatusView.loading(title: '正在加载频道');
    }
    if (_channels.isEmpty) {
      final favourite = _platform == _favouritesId;
      return StatusView(
        title: favourite ? '还没有收藏频道' : '该分类暂时没有频道',
        message: favourite ? '在播放页点收藏，之后可以在这里快速找到。' : '换个分类或稍后重试。',
        icon: favourite ? Icons.star_border_rounded : Icons.tv_off_rounded,
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisExtent: 64,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _channels.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _channels.length) {
          final platform = _platforms
              .where((item) => item.id == _platform)
              .firstOrNull;
          return _MoreTile(
            loading: _loadingMore,
            onTap: platform == null
                ? null
                : () => unawaited(_loadChannels(platform, append: true)),
          );
        }
        final channel = _channels[index];
        return _ChannelTile(
          channel: channel,
          onTap: () => unawaited(_open(index)),
        );
      },
    );
  }
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({required this.loading, required this.onTap});

  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 16,
      child: Material(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: loading ? null : onTap,
          child: Center(
            child: loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 6,
                    children: [
                      Icon(
                        Icons.expand_more_rounded,
                        size: 20,
                        color: colors.onSurfaceVariant,
                      ),
                      Text(
                        '加载更多',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
  });
  final String label;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 999,
      child: Material(
        color: selected ? colors.primary : colors.surfaceContainerHigh,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? colors.onPrimary : colors.onSurface,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                if (badge case final badge?)
                  Text(
                    badge,
                    style: TextStyle(
                      fontSize: 12,
                      color: (selected ? colors.onPrimary : colors.onSurface)
                          .withValues(alpha: .7),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel, required this.onTap});
  final LiveChannel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 房间型直播源把「主播 · 房间标题 · 热度」放在 subtitle 里。
    final secondary = channel.number.isNotEmpty
        ? channel.number
        : channel.subtitle;
    return FocusRing(
      radius: 16,
      child: Material(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (secondary.isNotEmpty)
                        Text(
                          secondary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(
                  Icons.play_circle_outline_rounded,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 全局共享的直播仓库：复用同一个 HttpClient 与频道缓存，避免每次进入直播页
/// 都新建连接池；进程退出时随应用一起释放。
LiveRepository? _shared;

LiveRepository sharedLiveRepository() => _shared ??= LiveRepository();

/// 按当前用户取直播收藏/最近观看存储；切换用户时重建，避免串号。
LiveStore? _liveStore;
String _liveStoreProfile = '';

LiveStore liveStoreFor(LocalStore owner) {
  if (_liveStore == null || _liveStoreProfile != owner.profile.id) {
    _liveStore?.dispose();
    _liveStore = LiveStore(owner.preferences, owner.profile.id)..load();
    _liveStoreProfile = owner.profile.id;
  }
  return _liveStore!;
}

/// 打开直播页（首页与我的页的入口都走这里）。
Future<void> openLive(
  BuildContext context, {
  required LocalStore store,
  bool greenMode = false,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => LivePage(
      repository: sharedLiveRepository(),
      store: liveStoreFor(store),
      greenMode: greenMode,
    ),
  ),
);
