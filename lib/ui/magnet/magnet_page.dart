import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../magnet_models.dart';
import '../../models.dart';
import '../player/playback_handle.dart';
import '../player/playback_page.dart';

/// 磁力页：移植 cisou.apk 的多站源聚合搜索，并把结果接到 cibo 等价的
/// 「磁力 → 本机 HTTP 流 → guoappxp 播放器」链路。
/// 结果按站源拆成可左右切换的标签，每个标签独立记忆排序与「仅含磁力」筛选；
/// 每条结果会异步探测当前能连上的 DHT 节点数并支持按它排序。
class MagnetPage extends StatefulWidget {
  const MagnetPage({super.key, required this.store});

  final LocalStore store;

  @override
  State<MagnetPage> createState() => _MagnetPageState();
}

// 站源标签数量会随搜索结果变化，TabController 需要重建；用 TickerProviderStateMixin
// 而不是 SingleTickerProviderStateMixin，后者一个 State 只允许创建一个 ticker。
class _MagnetPageState extends State<MagnetPage> with TickerProviderStateMixin {
  final _controller = TextEditingController();

  // InheritedWidget 不能在字段初始化器里读，改用 getter 在 build / 事件里取。
  AppRepository get _repository => AppScope.of(context).repository;

  List<MagnetSite> _sites = const [];
  final Set<int> _selected = {};
  List<MagnetResult> _items = const [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String _query = '';
  String _error = '';
  String _warning = '';
  // 用磁力链接而不是 id 作为「正在准备」的键：没解析出 infohash 的结果 id 是空串，
  // 用空串初值会让所有这类条目一直转圈。null 表示当前没有正在准备的任务。
  String? _preparing;
  bool _sitesLoaded = false;

  // 站源标签：0 是「全部」，其余对应 magnetSiteGroups 的顺序。
  TabController? _tabs;
  int _activeTab = 0;
  final Map<String, MagnetSort> _sorts = {};
  final Map<String, bool> _onlyMagnet = {};
  int _dhtGeneration = 0;
  int _playGeneration = 0;
  bool _dhtLoading = false;
  int _dhtNodes = 0;

  // AppScope 是 InheritedWidget，dependOnInheritedWidgetOfExactType 不能在
  // initState 完成前调用；站源清单挪到 didChangeDependencies 里加载一次。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_sitesLoaded) {
      _sitesLoaded = true;
      _loadSites();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _tabs?.removeListener(_onTabChanged);
    _tabs?.dispose();
    super.dispose();
  }

  Future<void> _loadSites() async {
    try {
      final sites = await _repository.magnetSites();
      if (!mounted) return;
      setState(() {
        _sites = sites;
        _selected.clear();
        for (final site in sites) {
          if (site.state) _selected.add(site.id);
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  List<MagnetSiteGroup> get _groups => magnetSiteGroups(_items);

  String _tabKey(int index, List<MagnetSiteGroup> groups) =>
      index == 0 ? '*' : groups[index - 1].key;

  void _syncTabs(int length) {
    if (_tabs != null && _tabs!.length == length) return;
    final previous = _tabs?.index ?? 0;
    _tabs?.removeListener(_onTabChanged);
    _tabs?.dispose();
    _tabs = TabController(
      length: length,
      vsync: this,
      initialIndex: previous.clamp(0, length - 1),
    );
    _activeTab = _tabs!.index;
    _tabs!.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    final controller = _tabs;
    if (controller == null ||
        controller.indexIsChanging ||
        controller.index == _activeTab) {
      return;
    }
    setState(() => _activeTab = controller.index);
    _probeDht();
  }

  // 列表上左右滑动也能换站源；标签本身可直接点击，电视端用方向键聚焦标签。
  void _switchTab(int index) {
    final controller = _tabs;
    if (controller == null) return;
    final target = index.clamp(0, controller.length - 1);
    if (target == controller.index) return;
    controller.animateTo(target, duration: const Duration(milliseconds: 220));
  }

  List<MagnetResult> _visibleItems(String key, List<MagnetSiteGroup> groups) {
    final base = key == '*'
        ? _items
        : groups
              .firstWhere(
                (group) => group.key == key,
                orElse: () =>
                    MagnetSiteGroup(key: key, name: '', items: const []),
              )
              .items;
    return magnetFilterResults(
      base,
      sort: _sorts[key] ?? MagnetSort.defaultOrder,
      onlyMagnet: _onlyMagnet[key] ?? false,
    );
  }

  Future<void> _search({bool more = false}) async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() => _error = '请输入搜索关键词');
      return;
    }
    if (_loading || _loadingMore) return;
    final page = more ? _page + 1 : 1;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _items = const [];
      }
      _error = '';
      _warning = '';
    });
    try {
      final result = await _repository.magnetSearch(
        more ? _query : query,
        page: page,
        sites: _selected.toList(),
      );
      if (!mounted) return;
      setState(() {
        _query = more ? _query : query;
        _page = result.page;
        _hasMore = result.hasMore;
        _warning = result.warning;
        _items = more ? [..._items, ...result.items] : result.items;
        if (result.sites.isNotEmpty && _sites.isEmpty) _sites = result.sites;
      });
      // 翻页也会补探测新出现的 hash，Go 侧 5 分钟缓存会跳过已探过的。
      _probeDht();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  /// 后台补 DHT 节点数：先出结果、再增量回填数字，不阻塞搜索。
  /// 切标签 / 切排序会发起新一轮，旧一轮的结果按 generation 丢弃。
  Future<void> _probeDht({bool force = false}) async {
    final groups = _groups;
    // 新一轮搜索可能让站源标签变少，先夹到合法范围再决定探测哪一批 hash，
    // 不要因为旧的标签索引越界就整轮跳过。
    final index = _activeTab.clamp(0, groups.length);
    final key = _tabKey(index, groups);
    final hashes = _visibleItems(key, groups)
        .where((item) => item.hasMagnet && item.id.isNotEmpty)
        .map((item) => item.id)
        .take(24)
        .toList();
    if (hashes.isEmpty) return;
    final generation = ++_dhtGeneration;
    final repository = _repository;
    if (mounted) setState(() => _dhtLoading = true);
    try {
      final info = await repository.magnetPeers(hashes, force: force);
      if (!mounted || generation != _dhtGeneration) return;
      final byHash = <String, MagnetPeerItem>{
        for (final row in info.items) row.hash.toLowerCase(): row,
      };
      setState(() {
        _dhtNodes = info.dhtNodes;
        _dhtLoading = false;
        _items = [
          for (final item in _items)
            byHash.containsKey(item.id.toLowerCase())
                ? item.copyWith(
                    dht: byHash[item.id.toLowerCase()]!.dht,
                    peers: byHash[item.id.toLowerCase()]!.peers,
                    dhtProbed: true,
                  )
                : item,
        ];
      });
    } catch (_) {
      if (mounted && generation == _dhtGeneration) {
        setState(() => _dhtLoading = false);
      }
    }
  }

  Future<void> _pickSites() async {
    final chosen = await showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SitePicker(sites: _sites, selected: _selected),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(chosen);
    });
  }

  Future<void> _play(MagnetResult result, [int? forced]) async {
    if (!result.playable) return;
    final repository = _repository;
    // 允许在「正在准备」时直接点另一条：先掐掉旧任务，再用新 generation 启动。
    final generation = ++_playGeneration;
    if (!mounted) return;
    setState(() {
      _preparing = result.magnet;
      _error = '';
    });
    List<MagnetFile> files;
    try {
      // 串行等取消返回，避免并发 FFI 里取消请求晚到、误把新任务也停掉。
      await repository.magnetCancel();
      files = await repository.magnetFiles(result.magnet);
    } catch (error) {
      // 被更新的一次点击取代时，旧任务的报错不该盖掉新任务的状态。
      if (!mounted || generation != _playGeneration) return;
      setState(() {
        _preparing = null;
        _error = '磁力解析失败：$error';
      });
      return;
    }
    if (!mounted || generation != _playGeneration) return;
    setState(() => _preparing = null);
    if (files.isEmpty) {
      setState(() => _error = '种子里没有可播放的文件');
      return;
    }
    int chosen = forced ?? -1;
    if (chosen < 0) {
      final videos = files.where((file) => file.video).toList();
      if (videos.length == 1) {
        chosen = videos.first.index;
      } else if (files.length == 1) {
        chosen = files.first.index;
      } else {
        chosen =
            await showModalBottomSheet<int>(
              context: context,
              isScrollControlled: true,
              builder: (context) =>
                  _FilePicker(files: files, title: result.title),
            ) ??
            -1;
      }
    }
    if (chosen < 0 || !mounted || generation != _playGeneration) return;
    await _openPlayer(result, files, chosen);
  }

  Future<void> _openPlayer(
    MagnetResult result,
    List<MagnetFile> files,
    int chosen,
  ) async {
    final picked = files.indexWhere((file) => file.index == chosen);
    final start = picked < 0 ? 0 : picked;
    // 用一套「伪剧集」把磁力交给现有播放器：每个种子文件对应一集，
    // PlaybackLoader 看到 raw['magnet'] 就会改走 magnetPlay。
    final detail = DramaDetail(
      Drama(
        id: 'magnet:${result.id.isEmpty ? result.title : result.id}',
        source: 'magnet',
        sourceId: result.id,
        title: result.title,
        description: [
          result.site,
          result.size,
          result.date,
        ].where((part) => part.isNotEmpty).join(' · '),
        episodes: files.length,
      ),
      [
        for (var i = 0; i < files.length; i++)
          Episode({
            'id': 'magnet:${result.id}:${files[i].index}',
            'title': files[i].name,
            'currentEpisode': i + 1,
            'magnet': result.magnet,
            'fileIndex': files[i].index,
          }, i + 1),
      ],
    );
    final handle = PlaybackHandle(
      repository: _repository,
      store: widget.store,
      detail: detail,
      index: start,
    );
    handle.session.start(start);
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PlaybackPage(store: widget.store, handle: handle),
      ),
    );
    handle.dispose();
  }

  Future<void> _copy(MagnetResult result) async {
    final value = result.magnet.isNotEmpty ? result.magnet : result.detail;
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制磁力链接')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    _syncTabs(groups.length + 1);
    final activeTab = _activeTab.clamp(0, groups.length);
    final key = _tabKey(activeTab, groups);
    final sort = _sorts[key] ?? MagnetSort.defaultOrder;
    final onlyMagnet = _onlyMagnet[key] ?? false;
    final visible = _visibleItems(key, groups);

    return Scaffold(
      appBar: AppBar(title: const Text('磁力')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: '搜索磁力资源',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loading ? null : () => _search(),
                  child: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('搜索'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _sites.isEmpty ? null : _pickSites,
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text('站源 ${_selected.length}/${_sites.length}'),
                ),
                const SizedBox(width: 12),
                if (_query.isNotEmpty)
                  Expanded(
                    child: Text(
                      '「$_query」共 ${_items.length} 条',
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(_error, style: const TextStyle(color: Colors.red)),
            ),
          if (_warning.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _warning,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          // 站源标签：一个「全部」+ 每个有结果的站源，可点可左右滑。
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding: const EdgeInsets.symmetric(horizontal: 12),
            tabs: [
              Tab(text: '全部 ${_items.length}'),
              for (final group in groups)
                Tab(text: '${group.name} ${group.items.length}'),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                PopupMenuButton<MagnetSort>(
                  onSelected: (value) {
                    setState(() => _sorts[key] = value);
                    _probeDht();
                  },
                  itemBuilder: (context) => [
                    for (final value in MagnetSort.values)
                      PopupMenuItem<MagnetSort>(
                        value: value,
                        child: Text(value.label),
                      ),
                  ],
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sort, size: 18),
                      const SizedBox(width: 4),
                      Text(sort.label),
                      const Icon(Icons.arrow_drop_down, size: 18),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('仅含磁力'),
                  selected: onlyMagnet,
                  visualDensity: VisualDensity.compact,
                  onSelected: (value) =>
                      setState(() => _onlyMagnet[key] = value),
                ),
                const Spacer(),
                if (_dhtLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: '刷新 DHT 节点数',
                    icon: const Icon(Icons.hub_outlined, size: 20),
                    onPressed: _items.isEmpty
                        ? null
                        : () => _probeDht(force: true),
                  ),
              ],
            ),
          ),
          if (_items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _dhtLoading
                      ? '正在探测可连接的 DHT 节点…'
                      : _dhtNodes > 0
                      ? 'DHT 网络已连接 $_dhtNodes 个节点 · 可按 DHT 数量排序'
                      : 'DHT 网络暂未连上节点 · 节点数会随探测自动更新',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          Expanded(
            child: Focus(
              // 电视 / 键盘：结果区聚焦后左右方向键直接换站源标签。
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    _switchTab(activeTab - 1);
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                    _switchTab(activeTab + 1);
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -250) _switchTab(activeTab + 1);
                  if (velocity > 250) _switchTab(activeTab - 1);
                },
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                          _loading
                              ? '正在搜索…'
                              : _items.isEmpty
                              ? '输入关键词，搜索 35 个磁力站源'
                              : '当前标签没有符合条件的结果',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 12),
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = visible[index];
                          final preparing =
                              _preparing != null && _preparing == item.magnet;
                          return ListTile(
                            title: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                item.site,
                                if (item.size.isNotEmpty) item.size,
                                if (item.date.isNotEmpty) item.date,
                                if (item.dhtProbed) 'DHT ${item.dht}',
                                if (item.dhtProbed && item.peers > item.dht)
                                  '节点 ${item.peers}',
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: preparing
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: '复制磁力链接',
                                        icon: const Icon(
                                          Icons.copy_all_outlined,
                                        ),
                                        onPressed: () => _copy(item),
                                      ),
                                      IconButton(
                                        tooltip: item.playable
                                            ? '播放'
                                            : '未解析出磁力链接',
                                        icon: Icon(
                                          item.playable
                                              ? Icons.play_circle_fill
                                              : Icons.link_off_outlined,
                                        ),
                                        onPressed: item.playable
                                            ? () => _play(item)
                                            : null,
                                      ),
                                    ],
                                  ),
                            onTap: item.playable ? () => _play(item) : null,
                          );
                        },
                      ),
              ),
            ),
          ),
          if (_hasMore && _items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _loadingMore ? null : () => _search(more: true),
                  child: Text(_loadingMore ? '加载中…' : '加载更多'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SitePicker extends StatefulWidget {
  const _SitePicker({required this.sites, required this.selected});

  final List<MagnetSite> sites;
  final Set<int> selected;

  @override
  State<_SitePicker> createState() => _SitePickerState();
}

class _SitePickerState extends State<_SitePicker> {
  late final Set<int> _chosen = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: 460,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '选择站源',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _chosen.clear();
                      for (final site in widget.sites) {
                        _chosen.add(site.id);
                      }
                    }),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: () => setState(_chosen.clear),
                    child: const Text('清空'),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(_chosen),
                    icon: const Icon(Icons.check),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final site in widget.sites)
                    CheckboxListTile(
                      value: _chosen.contains(site.id),
                      title: Text(site.name),
                      subtitle: site.info.isEmpty
                          ? null
                          : Text(
                              site.info,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _chosen.add(site.id);
                        } else {
                          _chosen.remove(site.id);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilePicker extends StatelessWidget {
  const _FilePicker({required this.files, required this.title});

  final List<MagnetFile> files;
  final String title;

  String _size(int bytes) {
    if (bytes <= 0) return '';
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                '选择要播放的文件',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final file in files)
                    ListTile(
                      leading: Icon(
                        file.video
                            ? Icons.movie_outlined
                            : Icons.insert_drive_file_outlined,
                      ),
                      title: Text(
                        file.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_size(file.size)),
                      onTap: () => Navigator.of(context).pop(file.index),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
