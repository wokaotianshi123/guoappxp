import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../magnet_models.dart';
import 'magnet_playback.dart';

/// 三个一级标签里的「磁力播放」：
/// 上方一行「粘贴磁力链接 → 播放」，直接把链接交给内置播放器解析；
/// 下方是按磁力站动态生成的分类列表（无封面、按行），点任一行即播放。
class MagnetPlayTab extends StatefulWidget {
  const MagnetPlayTab({
    super.key,
    required this.store,
    required this.sitesVersion,
  });

  final LocalStore store;
  final ValueListenable<int> sitesVersion;

  @override
  State<MagnetPlayTab> createState() => _MagnetPlayTabState();
}

/// 内容分类快捷词。分类本身按「磁力站实际有哪些站」动态生成（站源 Tab），
/// 这里只提供一组浏览词，用来换一批站内资源。
const _categoryWords = <String>['最新', '电影', '剧集', '动漫', '综艺', '4K', '音乐'];

class _MagnetPlayTabState extends State<MagnetPlayTab> {
  final _link = TextEditingController();

  AppRepository get _repository => AppScope.of(context).repository;

  List<MagnetSite> _sites = const [];
  List<MagnetResult> _items = const [];
  int? _siteId; // null = 全部站源
  String _category = '最新';
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String _error = '';
  String _warning = '';
  bool _booted = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.sitesVersion.addListener(_onSitesChanged);
  }

  void _onSitesChanged() {
    _loadSites();
    _browse();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_booted) {
      _booted = true;
      _loadSites();
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

  Future<void> _browse({bool more = false}) async {
    if (_loading || _loadingMore) return;
    final generation = ++_generation;
    final page = more ? _page + 1 : 1;
    final sites = _siteId == null ? <int>[] : <int>[_siteId!];
    final query = _category == '最新' ? '' : _category;
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

  void _selectSite(int? id) {
    if (_siteId == id) return;
    setState(() => _siteId = id);
    _browse();
  }

  void _selectCategory(String word) {
    if (_category == word) return;
    setState(() => _category = word);
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
    final link = _link.text.trim();
    if (!link.startsWith('magnet:')) {
      setState(() => _error = '请粘贴以 magnet: 开头的磁力链接');
      return;
    }
    setState(() => _error = '');
    try {
      await openMagnetPlayback(
        context,
        repository: _repository,
        store: widget.store,
        magnet: link,
        title: '磁力链接播放',
        subtitle: link.length > 80 ? '${link.substring(0, 80)}…' : link,
      );
    } catch (error) {
      if (mounted) setState(() => _error = '磁力播放失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                      icon: const Icon(Icons.content_paste_go_outlined, size: 19),
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
                onPressed: _playInput,
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: const Text('播放'),
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
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
          ),
        // 内容分类快捷词：固定单行高度，不挤占列表。
        SizedBox(
          height: 34,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: _categoryWords.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final word = _categoryWords[index];
              final selected = _category == word;
              return ChoiceChip(
                label: Text(word, style: const TextStyle(fontSize: 12)),
                selected: selected,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onSelected: (_) => _selectCategory(word),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        // 磁力站分类：按当前可用站源动态生成，第一个是「全部」。
        SizedBox(
          height: 38,
          child: Row(
            children: [
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  scrollDirection: Axis.horizontal,
                  itemCount: _sites.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    final id = index == 0 ? null : _sites[index - 1].id;
                    final label = index == 0 ? '全部' : _sites[index - 1].name;
                    final selected = _siteId == id;
                    return FilterChip(
                      label: Text(label, style: const TextStyle(fontSize: 12)),
                      selected: selected,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      onSelected: (_) => _selectSite(id),
                    );
                  },
                ),
              ),
              IconButton(
                tooltip: '刷新列表',
                iconSize: 19,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _loading ? null : () => _browse(),
              ),
            ],
          ),
        ),
        if (_warning.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
            child: Text(_warning, style: theme.textTheme.bodySmall),
          ),
        const Divider(height: 1),
        Expanded(
          child: _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
              ? Center(
                  child: Text(
                    '当前分类暂无资源，点右上角刷新或切换分类',
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = _items[index];
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
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '复制磁力链接',
                            icon: const Icon(Icons.copy_all_outlined, size: 20),
                            onPressed: () => copyMagnetLink(
                              context,
                              item.magnet.isNotEmpty
                                  ? item.magnet
                                  : item.detail,
                            ),
                          ),
                          IconButton(
                            tooltip: item.playable ? '播放' : '未解析出磁力链接',
                            icon: Icon(
                              item.playable
                                  ? Icons.play_circle_fill
                                  : Icons.link_off_outlined,
                            ),
                            onPressed: item.playable
                                ? () => playMagnetResult(
                                      context,
                                      repository: _repository,
                                      store: widget.store,
                                      result: item,
                                      onError: (message) =>
                                          setState(() => _error = message),
                                    )
                                : null,
                          ),
                        ],
                      ),
                      onTap: item.playable
                          ? () => playMagnetResult(
                                context,
                                repository: _repository,
                                store: widget.store,
                                result: item,
                                onError: (message) =>
                                    setState(() => _error = message),
                              )
                          : null,
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
  }
}
