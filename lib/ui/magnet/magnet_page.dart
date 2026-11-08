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
class MagnetPage extends StatefulWidget {
  const MagnetPage({super.key, required this.store});

  final LocalStore store;

  @override
  State<MagnetPage> createState() => _MagnetPageState();
}

class _MagnetPageState extends State<MagnetPage> {
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
    if (!result.playable || _preparing != null) return;
    final repository = _repository;
    setState(() {
      _preparing = result.magnet;
      _error = '';
    });
    List<MagnetFile> files;
    try {
      files = await repository.magnetFiles(result.magnet);
    } catch (error) {
      if (mounted) {
        setState(() {
          _preparing = null;
          _error = '磁力解析失败：$error';
        });
      }
      return;
    } finally {
      if (mounted) setState(() => _preparing = null);
    }
    if (!mounted) return;
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
    if (chosen < 0 || !mounted) return;
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
          Expanded(
            child: _items.isEmpty
                ? Center(
                    child: Text(
                      _loading ? '正在搜索…' : '输入关键词，搜索 35 个磁力站源',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: _items.length + (_hasMore ? 1 : 0),
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index == _items.length) {
                        return Padding(
                          padding: const EdgeInsets.all(16),
                          child: OutlinedButton(
                            onPressed: _loadingMore
                                ? null
                                : () => _search(more: true),
                            child: Text(_loadingMore ? '加载中…' : '加载更多'),
                          ),
                        );
                      }
                      final item = _items[index];
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
                                    icon: const Icon(Icons.copy_all_outlined),
                                    onPressed: () => _copy(item),
                                  ),
                                  IconButton(
                                    tooltip: item.playable ? '播放' : '未解析出磁力链接',
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
