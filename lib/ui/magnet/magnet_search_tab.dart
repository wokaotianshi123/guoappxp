import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../magnet_models.dart';
import 'magnet_chip_flow.dart';
import 'magnet_playback.dart';

/// 三个一级标签里的「磁力搜索」：移植 cisou.apk 的多站源聚合搜索。
///
/// 搜索走「会话 + 轮询」：点搜索后立刻拿到全部站源标签，各站并发去抓，
/// 每抓完一个站就增量填充结果，不必等最慢的站——这就是「边搜边显」。
/// 结果按站源拆成可左右切换的标签，每个标签独立记忆排序与筛选；
/// 每条结果会异步探测可连接节点数，不可达的标红，并支持「仅可达」筛选。
class MagnetSearchTab extends StatefulWidget {
  const MagnetSearchTab({
    super.key,
    required this.store,
    required this.sitesVersion,
    this.active = true,
  });

  final LocalStore store;

  /// 磁力源管理里新增/删除站源后 +1，触发这里重新拉站源清单。
  final ValueListenable<int> sitesVersion;

  /// 是否是当前显示的子页。父页用 Visibility 保活三个子页，未显示时不加载数据，
  /// 第一次被切到时才开始拉站源与热词。
  final bool active;

  @override
  State<MagnetSearchTab> createState() => _MagnetSearchTabState();
}

class _MagnetSearchTabState extends State<MagnetSearchTab> {
  final _controller = TextEditingController();

  AppRepository get _repository =>
      _cachedRepository ?? AppScope.of(context).repository;

  List<MagnetSite> _sites = const [];
  final Set<int> _selected = {};
  List<MagnetResult> _items = const [];

  /// 在 didChangeDependencies 里抓住 repository：dispose() 时不能再查
  /// InheritedWidget（元素已 deactivate，会抛「Looking up a deactivated
  /// widget's ancestor is unsafe」）。
  AppRepository? _cachedRepository;

  /// 会话里全部目标站的状态：标签先按它画出来，再随结果填充计数。
  List<MagnetSessionSite> _sessionSites = const [];
  String _session = '';
  bool _streaming = false;
  Timer? _pollTimer;
  int _pollGeneration = 0;

  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String _query = '';
  String _error = '';
  String _warning = '';
  String? _preparing;
  bool _sitesLoaded = false;

  // 搜索框下面的 20 个热词：单行横滑，固定行高，不挤占结果区。
  List<String> _hotWords = const [];
  bool _hotLoading = false;

  int _activeTab = 0;
  final Map<String, MagnetSort> _sorts = {};
  final Map<String, bool> _onlyMagnet = {};
  final Map<String, bool> _onlyReachable = {};
  int _dhtGeneration = 0;
  int _playGeneration = 0;
  bool _dhtLoading = false;
  int _dhtNodes = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cachedRepository = AppScope.of(context).repository;
    // 只在「第一次被显示」时加载：父页保活三个子页，未显示的不该发请求。
    if (!_sitesLoaded && widget.active) {
      _sitesLoaded = true;
      _loadSites();
      _loadHotWords();
      // 磁力页一打开就预热 BT 引擎与 DHT：用户真正点播放时省掉冷启动。
      _warmup();
    }
  }

  @override
  void didUpdateWidget(MagnetSearchTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从别的标签切回来时才补加载（正常情况下早就在 didChangeDependencies 里做过了）。
    if (!_sitesLoaded && widget.active) {
      _sitesLoaded = true;
      _loadSites();
      _loadHotWords();
      _warmup();
    }
  }

  Future<void> _warmup() async {
    try {
      await _repository.magnetWarmup();
    } catch (_) {
      // 预热失败不影响搜索；点播放时会再懒启动一次。
    }
  }

  @override
  void initState() {
    super.initState();
    widget.sitesVersion.addListener(_onSitesChanged);
  }

  void _onSitesChanged() => _loadSites();

  @override
  void dispose() {
    widget.sitesVersion.removeListener(_onSitesChanged);
    _pollTimer?.cancel();
    // 页面销毁时把会话停掉，别让后台还在抓站。用缓存的 repository，
    // dispose 阶段不能再查 InheritedWidget。
    final session = _session;
    final repository = _cachedRepository;
    if (session.isNotEmpty && repository != null) {
      unawaited(repository.magnetSearchStop(session));
    }
    _controller.dispose();
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

  Future<void> _loadHotWords({bool refresh = false}) async {
    if (_hotLoading) return;
    if (mounted) setState(() => _hotLoading = true);
    try {
      final words = await _repository.magnetHotWords(refresh: refresh);
      if (!mounted) return;
      if (words.isNotEmpty) {
        setState(() => _hotWords = words.take(20).toList(growable: false));
      }
    } catch (_) {
      // 热词只是快捷入口，失败时保持上一批，不打断搜索主流程。
    } finally {
      if (mounted) setState(() => _hotLoading = false);
    }
  }

  /// 标签分组：会话里登记的全部站（即使还没出结果）都要有标签；
  /// 结果里出现但会话没登记的站也要补一个标签，否则那些结果只能出现在「全部」。
  ///
  /// 站源 id 缺失（Go 侧没解析出 infohash 的条目常常 siteId=0）时退回按站名匹配，
  /// 否则「磁力猫」这类标签会永远显示 0 条，把结果藏起来。
  List<MagnetSiteGroup> get _groups {
    if (_sessionSites.isEmpty) return magnetSiteGroups(_items);

    bool belongs(MagnetResult item, int siteId, String name) => item.siteId > 0
        ? item.siteId == siteId
        : (name.isNotEmpty && item.site == name);

    final groups = <MagnetSiteGroup>[
      for (final site in _sessionSites)
        MagnetSiteGroup(
          key: 'id:${site.siteId}',
          name: site.name,
          items: _items
              .where((item) => belongs(item, site.siteId, site.name))
              .toList(growable: false),
        ),
    ];

    // 会话没登记、但结果里出现过的站：按 id（优先）或站名补标签。
    final knownIds = {for (final site in _sessionSites) site.siteId};
    final knownNames = {
      for (final site in _sessionSites)
        if (site.name.isNotEmpty) site.name,
    };
    final extraIds = <int>[];
    final extraNames = <String>[];
    final namesById = <int, String>{};
    for (final item in _items) {
      if (item.siteId > 0) {
        if (knownIds.contains(item.siteId) ||
            namesById.containsKey(item.siteId)) {
          continue;
        }
        namesById[item.siteId] = item.site.isEmpty ? '其它站源' : item.site;
        extraIds.add(item.siteId);
      } else if (item.site.isNotEmpty && !knownNames.contains(item.site)) {
        if (extraNames.contains(item.site)) continue;
        extraNames.add(item.site);
      }
    }
    for (final id in extraIds) {
      groups.add(
        MagnetSiteGroup(
          key: 'id:$id',
          name: namesById[id]!,
          items: _items
              .where((item) => item.siteId == id)
              .toList(growable: false),
        ),
      );
    }
    for (final name in extraNames) {
      groups.add(
        MagnetSiteGroup(
          key: 'name:$name',
          name: name,
          items: _items
              .where((item) => item.siteId == 0 && item.site == name)
              .toList(growable: false),
        ),
      );
    }
    return groups;
  }

  String _tabKey(int index, List<MagnetSiteGroup> groups) =>
      index == 0 ? '*' : groups[index - 1].key;

  /// 结果标签实际显示的分组：某个站源已经抓完却一条都没搜到时先不显示它的标签，
  /// 免得一排「0 条 / ✕」把真正有结果的标签挤到第二行甚至「更多」里。
  ///
  /// 还在抓取的站源必须保留：用户要靠标签上的「…」看到哪些站还在跑。
  /// 下次搜索或翻页时分组会重新计算，标签自然又会出现（所以是「暂时」隐藏）。
  List<MagnetSiteGroup> get _visibleGroups => [
    for (final group in _groups)
      if (group.items.isNotEmpty || _groupRunning(group.key)) group,
  ];

  bool _groupRunning(String key) =>
      _sessionSites.any((site) => 'id:${site.siteId}' == key && site.running);

  /// 当前选中项按最新可见标签收敛：正在看的站源刚被抓完且没结果、标签被隐藏时，
  /// 索引会越过可见范围，这时回落到「全部」而不是停到某个不相干的站。
  int _activeIndex(List<MagnetSiteGroup> groups) =>
      _activeTab <= groups.length ? _activeTab : 0;

  /// 切换结果标签。标签改成可换行的 chip 后不再有 TabController，
  /// 直接改索引并补探当前标签的节点数即可。
  void _switchTab(int index) {
    // 只用可见标签的数量收敛：被隐藏的站源不在标签行里，键位切换不能跳进去。
    final target = index.clamp(0, _visibleGroups.length);
    if (target == _activeTab) return;
    setState(() => _activeTab = target);
    _probeDht();
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
      onlyReachable: _onlyReachable[key] ?? false,
    );
  }

  /// 停掉当前会话（用户点「停止」或发起新搜索时）。
  Future<void> _stopStreaming() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final session = _session;
    if (session.isEmpty) return;
    _session = '';
    if (mounted) {
      setState(() {
        _streaming = false;
        _loading = false;
        // 停止后把还在跑的站标成已停止，标签不再转圈。
        _sessionSites = [
          for (final site in _sessionSites)
            site.running
                ? MagnetSessionSite(
                    siteId: site.siteId,
                    name: site.name,
                    state: 'done',
                    count: site.count,
                  )
                : site,
        ];
      });
    }
    try {
      await _repository.magnetSearchStop(session);
    } catch (_) {
      // 停止失败不阻断界面。
    }
  }

  Future<void> _search({bool more = false}) async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() => _error = '请输入搜索关键词');
      return;
    }
    if (more && (_loading || _loadingMore || _streaming)) return;
    // 新搜索先中断上一次会话，避免两轮结果混在一起。
    await _stopStreaming();
    final page = more ? _page + 1 : 1;
    final generation = ++_pollGeneration;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _items = const [];
        _sessionSites = const [];
      }
      _error = '';
      _warning = '';
      _streaming = true;
    });
    try {
      final snapshot = await _repository.magnetSearchStart(
        more ? _query : query,
        page: page,
        sites: _selected.toList(),
      );
      if (!mounted || generation != _pollGeneration) return;
      _session = snapshot.id;
      _applySnapshot(snapshot, more: more);
      // 会话在 start 阶段就已经跑完（例如没有可用站源）时不必再轮询，
      // 否则空快照会把 hasMore / 计数覆盖掉。
      if (snapshot.running) {
        _schedulePoll(generation);
      } else {
        setState(() {
          _streaming = false;
          _loading = false;
          _loadingMore = false;
        });
        _probeDht();
      }
    } catch (error) {
      if (mounted && generation == _pollGeneration) {
        setState(() {
          _error = '$error';
          _loading = false;
          _loadingMore = false;
          _streaming = false;
        });
      }
    }
  }

  void _schedulePoll(int generation) {
    _pollTimer?.cancel();
    _pollTimer = Timer(const Duration(milliseconds: 120), () {
      unawaited(_pollOnce(generation));
    });
  }

  Future<void> _pollOnce(int generation) async {
    if (!mounted || generation != _pollGeneration || _session.isEmpty) return;
    try {
      final snapshot = await _repository.magnetSearchPoll(_session);
      if (!mounted || generation != _pollGeneration) return;
      _applySnapshot(snapshot);
      if (snapshot.running) {
        _schedulePoll(generation);
      } else {
        setState(() {
          _streaming = false;
          _loading = false;
          _loadingMore = false;
        });
        _probeDht();
      }
    } catch (error) {
      if (!mounted || generation != _pollGeneration) return;
      setState(() {
        _error = '$error';
        _streaming = false;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _applySnapshot(MagnetSessionSnapshot snapshot, {bool more = false}) {
    setState(() {
      _session = snapshot.id.isNotEmpty ? snapshot.id : _session;
      _query = snapshot.query.isNotEmpty ? snapshot.query : _query;
      _page = snapshot.page;
      // hasMore 只在会话结束时才是权威值：轮询的增量快照里它是默认 false，
      // 直接赋值会把「还有下一页」清掉。
      if (!snapshot.running) _hasMore = snapshot.hasMore;
      if (snapshot.warning.isNotEmpty) _warning = snapshot.warning;
      if (snapshot.sites.isNotEmpty) _sessionSites = snapshot.sites;
      if (snapshot.items.isNotEmpty) {
        final byId = <String, MagnetResult>{
          for (final item in _items)
            if (item.id.isNotEmpty) item.id: item,
        };
        final appended = <MagnetResult>[];
        for (final item in snapshot.items) {
          if (item.id.isEmpty) {
            appended.add(item);
            continue;
          }
          final existing = byId[item.id];
          if (existing == null) {
            byId[item.id] = item;
            appended.add(item);
          } else if (existing.magnet.isEmpty && item.magnet.isNotEmpty) {
            // 详情页补到了磁力：替换成可播放版本。
            byId[item.id] = existing.copyWith(
              magnet: item.magnet,
              playable: true,
            );
          }
        }
        final merged = <MagnetResult>[
          for (final item in _items)
            if (item.id.isNotEmpty && byId.containsKey(item.id))
              byId[item.id]!
            else
              item,
          ...appended,
        ];
        _items = merged;
      }
    });
    // 这里不主动探测：边搜边显期间每来一批就探一次会把同一个 hash 反复
    // 塞进 BT 客户端（旧条目也还在列表里）。统一在会话结束时探一次。
  }

  /// 后台补节点数：先出结果、再增量回填数字与可达性，不阻塞搜索。
  Future<void> _probeDht({bool force = false}) async {
    final groups = _visibleGroups;
    if (groups.isEmpty) return;
    final index = _activeIndex(groups);
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
    final generation = ++_playGeneration;
    bool isCurrent() => mounted && generation == _playGeneration;
    if (!isCurrent()) return;
    setState(() => _error = '');
    // 与「磁力播放」标签共用同一条「先解析、再选集、后加载播放器」链路。
    await resolveAndPlayMagnet(
      context,
      repository: repository,
      store: widget.store,
      magnet: result.magnet,
      title: result.title,
      subtitle: [
        result.site,
        result.size,
        result.date,
      ].where((part) => part.isNotEmpty).join(' · '),
      fileIndex: forced,
      isCurrent: isCurrent,
      onPreparing: (preparing) {
        if (!isCurrent()) return;
        setState(() => _preparing = preparing ? result.magnet : null);
      },
      onError: (message) {
        if (!isCurrent()) return;
        setState(() => _error = message);
      },
    );
  }

  void _useHotWord(String word) {
    _controller.text = word;
    _search();
  }

  @override
  Widget build(BuildContext context) {
    // 标签只用「有结果 / 还在抓」的站源；正在看的站如果刚好没结果被隐藏，
    // 下面的 clamp 会把选中项收敛回「全部」，不会出现空白标签页。
    final groups = _visibleGroups;
    final emptySites = _groups.length - groups.length;
    // 标签数量随结果变化（各站逐个返回），越界的索引在这里按最新数量收敛。
    final activeTab = _activeIndex(groups);
    final key = _tabKey(activeTab, groups);
    final sort = _sorts[key] ?? MagnetSort.defaultOrder;
    final onlyMagnet = _onlyMagnet[key] ?? false;
    final onlyReachable = _onlyReachable[key] ?? false;
    final visible = _visibleItems(key, groups);
    final unreachableCount = _items
        .where((item) => item.reachability == MagnetReachability.unreachable)
        .length;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 矮窗口（横屏手机、小窗）里热词和站源标签各只放一行，避免把结果区挤没；
        // 高窗口才给两行。
        final tight = constraints.maxHeight < 560;
        return Column(
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
                  if (_streaming)
                    FilledButton.icon(
                      onPressed: _stopStreaming,
                      icon: const Icon(Icons.stop_rounded, size: 18),
                      label: const Text('停止'),
                    )
                  else
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
            // 磁力热词：按窗口宽度换行（最多两行），放不下的收进「更多」——
            // 原来是单行横滑，窄窗口要一直横滑才看得到后半截。点一下即搜索；
            // 「换一批」重新从磁力站首页随机抓取。热词为空时整块不渲染。
            if (_hotWords.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: MagnetChipFlow(
                        style: MagnetChipStyle.pill,
                        maxLines: tight ? 1 : 2,
                        items: [
                          for (final word in _hotWords)
                            MagnetChipItem(
                              label: word,
                              onTap: () => _useHotWord(word),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 30,
                      height: 30,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: '换一批热词',
                        iconSize: 17,
                        icon: _hotLoading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                        onPressed: _hotLoading
                            ? null
                            : () => _loadHotWords(refresh: true),
                      ),
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
                        _streaming
                            ? '「$_query」已找到 ${_items.length} 条 · 搜索中…'
                            : emptySites > 0
                            ? '「$_query」共 ${_items.length} 条'
                                  ' · $emptySites 个站源没有结果（标签已收起）'
                            : '「$_query」共 ${_items.length} 条',
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
            // 结果标签按窗口宽度换行：宽屏一行放更多，窄屏自动多行，不再靠横滑。
            // 两行仍放不下时折叠成「更多」，点开直接切换。
            if (_items.isNotEmpty || _streaming)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                child: MagnetChipFlow(
                  items: [
                    MagnetChipItem(
                      label: '全部 ${_items.length}',
                      selected: activeTab == 0,
                      onTap: () => _switchTab(0),
                    ),
                    for (var index = 0; index < groups.length; index++)
                      MagnetChipItem(
                        label: _tabLabel(groups[index]),
                        selected: activeTab == index + 1,
                        onTap: () => _switchTab(index + 1),
                      ),
                  ],
                  maxLines: tight ? 1 : 2,
                ),
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
                  const SizedBox(width: 6),
                  FilterChip(
                    label: const Text('仅含磁力'),
                    selected: onlyMagnet,
                    visualDensity: VisualDensity.compact,
                    onSelected: (value) =>
                        setState(() => _onlyMagnet[key] = value),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: const Text('仅可达'),
                    selected: onlyReachable,
                    visualDensity: VisualDensity.compact,
                    onSelected: (value) =>
                        setState(() => _onlyReachable[key] = value),
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
                      tooltip: '刷新节点数与可达性',
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
                        ? '正在探测可连接节点…'
                        : _dhtNodes > 0
                        ? 'DHT 已连接 $_dhtNodes 个节点'
                              '${unreachableCount > 0 ? ' · $unreachableCount 条不可达（红色）' : ''}'
                        : 'DHT 网络暂未连上节点 · 可达性会随探测自动更新',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            Expanded(
              child: Focus(
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
                                ? '输入关键词，搜索 ${_sites.length} 个磁力站源'
                                : onlyReachable
                                ? '当前标签没有可达的结果，可关掉「仅可达」看看'
                                : '当前标签没有符合条件的结果',
                            style: Theme.of(context).textTheme.bodyMedium,
                            textAlign: TextAlign.center,
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
                            return _MagnetResultTile(
                              item: item,
                              preparing: preparing,
                              onPlay: () => _play(item),
                              onCopy: () => copyMagnetLink(
                                context,
                                item.magnet.isNotEmpty
                                    ? item.magnet
                                    : item.detail,
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),
            if (_hasMore && _items.isNotEmpty && !_streaming)
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
        );
      },
    );
  }

  /// 标签文案带上抓取状态：还在跑的显示转圈小标，失败的不显示 0 条误导用户。
  String _tabLabel(MagnetSiteGroup group) {
    final site = _sessionSites.firstWhere(
      (row) => 'id:${row.siteId}' == group.key,
      orElse: () => const MagnetSessionSite(siteId: 0, name: ''),
    );
    if (site.siteId == 0) return '${group.name} ${group.items.length}';
    if (site.running) return '${group.name} …';
    if (site.failed) return '${group.name} ✕';
    return '${group.name} ${group.items.length}';
  }
}

/// 结果行：不可达的整行标红，并显示节点数。
class _MagnetResultTile extends StatelessWidget {
  const _MagnetResultTile({
    required this.item,
    required this.preparing,
    required this.onPlay,
    required this.onCopy,
  });

  final MagnetResult item;
  final bool preparing;
  final VoidCallback onPlay;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reachability = item.reachability;
    final unreachable = reachability == MagnetReachability.unreachable;
    final accent = unreachable ? theme.colorScheme.error : null;

    final meta = <String>[
      item.site,
      if (item.size.isNotEmpty) item.size,
      if (item.date.isNotEmpty) item.date,
      if (item.dhtProbed) 'DHT ${item.dht}',
      if (item.dhtProbed && item.peers > item.dht) '节点 ${item.peers}',
    ];

    return ListTile(
      title: Text(
        item.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: accent == null ? null : TextStyle(color: accent),
      ),
      subtitle: Row(
        children: [
          if (unreachable)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(
                Icons.error_outline,
                size: 14,
                color: theme.colorScheme.error,
              ),
            )
          else if (reachability == MagnetReachability.reachable)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(
                Icons.check_circle_outline,
                size: 14,
                color: theme.colorScheme.primary,
              ),
            ),
          Expanded(
            child: Text(
              meta.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent ?? theme.textTheme.bodySmall?.color,
              ),
            ),
          ),
          if (unreachable)
            Text(
              '不可达',
              style: TextStyle(fontSize: 11, color: theme.colorScheme.error),
            ),
        ],
      ),
      trailing: preparing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '复制磁力链接',
                  icon: const Icon(Icons.copy_all_outlined),
                  onPressed: onCopy,
                ),
                IconButton(
                  tooltip: item.playable ? '播放' : '未解析出磁力链接',
                  icon: Icon(
                    item.playable
                        ? Icons.play_circle_fill
                        : Icons.link_off_outlined,
                  ),
                  onPressed: item.playable ? onPlay : null,
                ),
              ],
            ),
      onTap: item.playable ? onPlay : null,
    );
  }
}

/// 热词胶囊：自定义高度 28，避免 ActionChip 默认的最小点击区把整行撑高。
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
