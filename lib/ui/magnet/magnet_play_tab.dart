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

/// 三个一级标签里的「磁力播放」：
/// 上方一行「粘贴磁力链接 → 播放」，与磁力搜索一样先解析种子文件列表、
/// 再选集加载内置播放器；下方是按磁力站动态生成的分类列表（无封面、按行），
/// 点任一行同样先解析再播放。列表出来后异步探测各条目的可连接节点数，
/// 不可达的标红，并支持「仅可达」筛选（与磁力搜索页行为一致）。
class MagnetPlayTab extends StatefulWidget {
  const MagnetPlayTab({
    super.key,
    required this.store,
    required this.sitesVersion,
    this.active = true,
  });

  final LocalStore store;
  final ValueListenable<int> sitesVersion;

  /// 是否是当前显示的子页；未显示时不加载分类与列表，第一次切到才开始拉。
  final bool active;

  @override
  State<MagnetPlayTab> createState() => _MagnetPlayTabState();
}

class _MagnetPlayTabState extends State<MagnetPlayTab> {
  final _link = TextEditingController();

  AppRepository get _repository => AppScope.of(context).repository;

  List<MagnetSite> _sites = const [];
  List<MagnetResult> _items = const [];
  int? _siteId; // null = 全部站源
  // 分类不是写死的词表：由 Go 侧抓各磁力站首页导航得到，点分类按真实地址浏览。
  // 站点没提供分类时 _categories 为空，分类行只留「全部」，列表照常加载。
  List<MagnetCategory> _categories = const [];
  bool _categoryLoading = false;
  int _categoryGeneration = 0;
  String _categoryKey = ''; // 空 = 全部（按站点默认浏览地址拉列表）
  String _categoryUrl = '';
  int _categorySiteId = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String _error = '';
  String _warning = '';
  bool _booted = false;
  int _generation = 0;
  // 正在解析的磁力链接（用于列表项/按钮的 loading 态），以及防止旧解析任务
  // 覆盖新任务的自增序号——行为对齐「磁力搜索」标签。
  String? _preparing;
  int _playGeneration = 0;
  // 解析中的「停止」信号：用户再点一次按钮就 complete，解析链路会立即取消。
  Completer<void>? _cancelSignal;
  // 可达性：列表先出来，再异步回填 DHT 节点数；「仅可达」只保留探测到有节点的条目。
  bool _onlyReachable = false;
  bool _dhtLoading = false;
  int _dhtNodes = 0;
  int _dhtGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.sitesVersion.addListener(_onSitesChanged);
    // 首屏就预热 BT 引擎，点播放时 DHT 已有节点。
    _warmup();
  }

  Future<void> _warmup() async {
    try {
      await _repository.magnetWarmup();
    } catch (_) {
      // 预热失败不影响后续播放。
    }
  }

  void _onSitesChanged() {
    _loadSites();
    // 站源有增删改，分类缓存也要跟着失效重抓。
    _loadCategories(refresh: true);
    _browse();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_booted && widget.active) {
      _booted = true;
      _loadSites();
      _loadCategories();
      _browse();
    }
  }

  @override
  void didUpdateWidget(MagnetPlayTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 第一次被切到这个标签时才加载；之后靠保活不再重复请求。
    if (!_booted && widget.active) {
      _booted = true;
      _loadSites();
      _loadCategories();
      _browse();
    }
  }

  @override
  void dispose() {
    widget.sitesVersion.removeListener(_onSitesChanged);
    _link.dispose();
    super.dispose();
  }

  Future<void> _loadSites() async {
    try {
      final sites = await _repository.magnetSites();
      if (!mounted) return;
      if (_siteId != null && !sites.any((site) => site.id == _siteId)) {
        _siteId = null;
      }
      setState(() => _sites = sites.where((site) => site.state).toList());
    } catch (_) {
      // 分类拿不到时仍可用「全部」浏览，不阻断页面。
    }
  }

  /// 拉取所选站源首页的真实分类。抓不到（站点本来就没有分类 / 超时 / 断网）
  /// 时不报错、不阻断：_categories 保持空，分类行只剩「全部」，列表照常按
  /// 站点默认浏览地址加载。
  Future<void> _loadCategories({bool refresh = false}) async {
    final generation = ++_categoryGeneration;
    if (mounted) setState(() => _categoryLoading = true);
    try {
      final sites = _siteId == null ? <int>[] : <int>[_siteId!];
      final categories = await _repository.magnetCategories(
        sites: sites,
        refresh: refresh,
      );
      if (!mounted || generation != _categoryGeneration) return;
      var key = _categoryKey;
      if (key.isNotEmpty && !categories.any((item) => item.key == key)) {
        key = '';
        _categoryUrl = '';
        _categorySiteId = 0;
      }
      setState(() {
        _categories = categories;
        _categoryKey = key;
        _categoryLoading = false;
      });
    } catch (_) {
      if (mounted && generation == _categoryGeneration) {
        setState(() => _categoryLoading = false);
      }
    }
  }

  Future<void> _browse({bool more = false}) async {
    if (_loading || _loadingMore) return;
    final generation = ++_generation;
    final page = more ? _page + 1 : 1;
    // 选中真实分类时只看它所属的那个源；否则沿用当前站源选择（null=全部）。
    final sites = _categorySiteId > 0
        ? <int>[_categorySiteId]
        : _siteId == null
        ? <int>[]
        : <int>[_siteId!];
    const query = ''; // 分类浏览用真实地址，不再拿固定词当关键词
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
      final result = await _repository.magnetBrowse(
        query,
        page: page,
        sites: sites,
        categoryUrl: _categoryUrl,
        categorySiteId: _categorySiteId,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = result.page;
        _hasMore = result.hasMore;
        _warning = result.warning;
        _items = more ? [..._items, ...result.items] : result.items;
        if (result.sites.isNotEmpty && _sites.isEmpty) {
          _sites = result.sites.where((site) => site.state).toList();
        }
      });
      // 列表先显示，节点数与可达性后台补；不 await，避免拖慢首屏。
      unawaited(_probeDht());
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  /// 后台补节点数：列表先显示，再增量回填 DHT 数量与可达性，不阻塞浏览。
  /// 只探还没探测过的条目（加载更多时前几页已经探过，不重复塞进 BT 客户端）；
  /// 手动点「刷新可达性」时 force，忽略后端缓存重新探。
  Future<void> _probeDht({bool force = false}) async {
    final hashes = _items
        .where(
          (item) =>
              item.hasMagnet &&
              item.id.isNotEmpty &&
              (force || !item.dhtProbed),
        )
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
      // 探测失败不改列表：条目保持「未探测」，不会被误标成不可达。
      if (mounted && generation == _dhtGeneration) {
        setState(() => _dhtLoading = false);
      }
    }
  }

  void _selectSite(int? id) {
    if (_siteId == id) return;
    setState(() {
      _siteId = id;
      // 旧分类属于旧站源，切源后回到「全部」，再按新源重抓分类。
      _categories = const [];
      _categoryKey = '';
      _categoryUrl = '';
      _categorySiteId = 0;
    });
    _loadCategories();
    _browse();
  }

  void _selectCategory(MagnetCategory? category) {
    final key = category?.key ?? '';
    if (_categoryKey == key) return;
    setState(() {
      _categoryKey = key;
      _categoryUrl = category?.url ?? '';
      _categorySiteId = category?.siteId ?? 0;
    });
    _browse();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    setState(() {
      _link.text = text;
      _error = '';
    });
  }

  Future<void> _playInput() async {
    // 正在解析时按钮变成「停止解析」，再点一次立即中断。
    if (_preparing != null) {
      _stopParsing();
      return;
    }
    final link = _link.text.trim();
    if (!link.startsWith('magnet:')) {
      setState(() => _error = '请粘贴以 magnet: 开头的磁力链接');
      return;
    }
    await _resolveAndPlay(
      magnet: link,
      title: '磁力链接播放',
      subtitle: link.length > 80 ? '${link.substring(0, 80)}…' : link,
    );
  }

  /// 用户点「停止解析」：complete 取消信号，解析链路会调 magnetCancel 中断
  /// Go 侧的元数据等待，界面立刻复位。
  void _stopParsing() {
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
    setState(() => _preparing = null);
  }

  /// 输入框与分类列表共用的播放入口：先取消旧任务、解析种子文件列表、
  /// 选集，最后才加载内置播放器（不把裸磁力链接直接丢给播放器）。
  Future<void> _resolveAndPlay({
    required String magnet,
    required String title,
    String subtitle = '',
  }) async {
    final repository = _repository;
    final generation = ++_playGeneration;
    bool isCurrent() => mounted && generation == _playGeneration;
    if (!isCurrent()) return;
    final signal = Completer<void>();
    _cancelSignal = signal;
    setState(() => _error = '');
    await resolveAndPlayMagnet(
      context,
      repository: repository,
      store: widget.store,
      magnet: magnet,
      title: title,
      subtitle: subtitle,
      isCurrent: isCurrent,
      cancelSignal: signal.future,
      onPreparing: (preparing) {
        if (!isCurrent()) return;
        setState(() => _preparing = preparing ? magnet : null);
      },
      onError: (message) {
        if (!isCurrent()) return;
        setState(() => _error = message);
      },
    );
    if (_cancelSignal == signal) _cancelSignal = null;
  }

  void _playResult(MagnetResult item) {
    if (!item.playable || !item.magnet.startsWith('magnet:')) {
      setState(() => _error = '这条资源暂未解析出磁力链接');
      return;
    }
    _resolveAndPlay(
      magnet: item.magnet,
      title: item.title,
      subtitle: [
        item.site,
        if (item.size.isNotEmpty) item.size,
        if (item.date.isNotEmpty) item.date,
      ].join(' · '),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = magnetFilterResults(_items, onlyReachable: _onlyReachable);
    final unreachableCount = _items
        .where((item) => item.reachability == MagnetReachability.unreachable)
        .length;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 矮窗口里站源标签只放一行（35 个源放两行会把列表压没），高窗口给两行。
        final tight = constraints.maxHeight < 560;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 输入区：左边可输入/粘贴，右边播放按钮。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _link,
                      maxLines: 2,
                      minLines: 1,
                      textInputAction: TextInputAction.go,
                      autocorrect: false,
                      decoration: InputDecoration(
                        hintText: '粘贴或输入 magnet:?xt=urn:btih:… 磁力链接',
                        prefixIcon: const Icon(Icons.link_rounded),
                        suffixIcon: IconButton(
                          tooltip: '从剪贴板粘贴',
                          icon: const Icon(
                            Icons.content_paste_go_outlined,
                            size: 19,
                          ),
                          onPressed: _paste,
                        ),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _playInput(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    // 解析中再点一次即停止，不必等 40 秒超时。
                    onPressed: _playInput,
                    icon: _preparing == null
                        ? const Icon(Icons.play_arrow_rounded, size: 20)
                        : const Icon(Icons.stop_rounded, size: 20),
                    label: Text(_preparing == null ? '播放' : '停止解析'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(88, 48),
                    ),
                  ),
                ],
              ),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Text(
                  _error,
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            // 内容分类：首项「全部」按站点默认地址浏览，其余全部来自站点首页
            // 实际抓到的导航分类（每个源各不相同）；站点没分类时这一行只剩「全部」，
            // 列表照常加载。整行固定 34px，不挤占列表。
            SizedBox(
              height: 34,
              child: Row(
                children: [
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      scrollDirection: Axis.horizontal,
                      itemCount: _categories.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return ChoiceChip(
                            label: const Text(
                              '全部',
                              style: TextStyle(fontSize: 12),
                            ),
                            selected: _categoryKey.isEmpty,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            onSelected: (_) => _selectCategory(null),
                          );
                        }
                        final category = _categories[index - 1];
                        // 「全部站源」下分类可能来自多个站，带上站名避免同名混淆。
                        final label =
                            _siteId == null && category.siteName.isNotEmpty
                            ? '${category.siteName}·${category.name}'
                            : category.name;
                        return ChoiceChip(
                          label: Text(
                            label,
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: _categoryKey == category.key,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          onSelected: (_) => _selectCategory(category),
                        );
                      },
                    ),
                  ),
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      tooltip: '刷新分类',
                      iconSize: 17,
                      icon: _categoryLoading
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.category_outlined),
                      onPressed: _categoryLoading
                          ? null
                          : () => _loadCategories(refresh: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // 磁力站源：按当前可用站源动态生成，第一个是「全部」。按窗口宽度
            // 换行（最多两行），放不下的收进「更多」——之前是横向滚动，窄窗口
            // 只能看到前几个站。
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 8, 2),
              child: MagnetChipFlow(
                maxLines: tight ? 1 : 2,
                items: [
                  MagnetChipItem(
                    label: '全部',
                    selected: _siteId == null,
                    onTap: () => _selectSite(null),
                  ),
                  for (final site in _sites)
                    MagnetChipItem(
                      label: site.name,
                      selected: _siteId == site.id,
                      onTap: () => _selectSite(site.id),
                    ),
                ],
                // 筛选与刷新作为一组跟在标签流末尾，不会被拆散。
                trailing: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 1,
                        height: 16,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        color: theme.dividerColor,
                      ),
                      FilterChip(
                        label: const Text(
                          '仅可达',
                          style: TextStyle(fontSize: 12),
                        ),
                        selected: _onlyReachable,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        onSelected: (value) {
                          setState(() => _onlyReachable = value);
                          // 打开筛选时若还有条目没探过，立刻补一次，别让列表一开就空。
                          if (value) unawaited(_probeDht());
                        },
                      ),
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: '刷新节点数与可达性',
                          iconSize: 17,
                          icon: _dhtLoading
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.hub_outlined),
                          onPressed: _dhtLoading
                              ? null
                              : () => _probeDht(force: true),
                        ),
                      ),
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: '刷新列表',
                          iconSize: 17,
                          icon: const Icon(Icons.refresh_rounded),
                          onPressed: _loading ? null : () => _browse(),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_warning.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                child: Text(_warning, style: theme.textTheme.bodySmall),
              ),
            // 只在探测中或确实有死链时占一行，平时不挤列表。
            if (_items.isNotEmpty && (_dhtLoading || unreachableCount > 0))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                child: Text(
                  _dhtLoading
                      ? '正在探测可连接节点…'
                      : 'DHT 已连接 $_dhtNodes 个节点 · $unreachableCount 条不可达（红色）',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: _loading && _items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : visible.isEmpty
                  ? Center(
                      child: Text(
                        _items.isEmpty
                            ? '暂无资源，可切换分类或点刷新重试'
                            : _onlyReachable
                            ? '当前没有探测到可达的资源，可关掉「仅可达」看看'
                            : '当前没有符合条件的结果',
                        style: theme.textTheme.bodyMedium,
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
                        return ListTile(
                          // 按需求不设封面：整行只给文字与操作按钮。
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
                              if (item.reachability ==
                                  MagnetReachability.unreachable)
                                '不可达',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                item.reachability ==
                                    MagnetReachability.unreachable
                                ? TextStyle(
                                    color: theme.colorScheme.error,
                                    fontSize: 12,
                                  )
                                : null,
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
                                        size: 20,
                                      ),
                                      onPressed: () => copyMagnetLink(
                                        context,
                                        item.magnet.isNotEmpty
                                            ? item.magnet
                                            : item.detail,
                                      ),
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
                                          ? () => _playResult(item)
                                          : null,
                                    ),
                                  ],
                                ),
                          onTap: item.playable ? () => _playResult(item) : null,
                        );
                      },
                    ),
            ),
            if (_hasMore && _items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: OutlinedButton(
                  onPressed: _loadingMore ? null : () => _browse(more: true),
                  child: Text(_loadingMore ? '加载中…' : '加载更多'),
                ),
              ),
          ],
        );
      },
    );
  }
}
