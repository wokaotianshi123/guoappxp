import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../../core_bridge.dart';
import '../../magnet_models.dart';

/// 三个一级标签里的「磁力源管理」。
/// 交互对齐「新增 xbpq 网页源」：填网址 → 自动识别规则 → 预览/微调 → 保存，
/// 支持新增、编辑（自定义源）与删除（内置站也能删，Go 侧记进 disabled 表）。
class MagnetSourcesTab extends StatefulWidget {
  const MagnetSourcesTab({super.key, required this.onChanged});

  /// 源清单变化后通知外层，让搜索/播放标签重新拉站源。
  final VoidCallback onChanged;

  @override
  State<MagnetSourcesTab> createState() => _MagnetSourcesTabState();
}

class _MagnetSourcesTabState extends State<MagnetSourcesTab> {
  AppRepository get _repository => AppScope.of(context).repository;

  List<MagnetSite> _sites = const [];
  bool _loading = true;
  String _error = '';
  bool _booted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_booted) {
      _booted = true;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final sites = await _repository.magnetSites();
      if (!mounted) return;
      setState(() => _sites = sites);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openEditor([MagnetSite? existing]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _MagnetSiteEditor(
        repository: _repository,
        existing: existing,
      ),
    );
    if (saved != true) return;
    await _load();
    widget.onChanged();
  }

  Future<void> _remove(MagnetSite site) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除磁力源'),
        content: Text(
          site.custom
              ? '确定删除自定义磁力源「${site.name}」？'
              : '确定移除内置磁力源「${site.name}」？可在「恢复默认」里找回。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _repository.removeMagnetSite(site.id);
      await _load();
      widget.onChanged();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('磁力源已删除')));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '删除失败：$error');
    }
  }

  Future<void> _reset() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复默认磁力源'),
        content: const Text(
          '将清空所有自定义磁力源，并恢复被移除的内置站源。此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _repository.resetMagnetSites();
      await _load();
      widget.onChanged();
    } catch (error) {
      if (mounted) setState(() => _error = '恢复失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final customCount = _sites.where((site) => site.custom).length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '共 ${_sites.length} 个磁力源 · 自定义 $customCount 个',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: const Text('恢复默认'),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: () => _openEditor(),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新增'),
              ),
            ],
          ),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              _error,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _sites.isEmpty
              ? const Center(child: Text('暂无磁力源，点「新增」添加一个'))
              : ListView.separated(
                  itemCount: _sites.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final site = _sites[index];
                    return ListTile(
                      leading: Icon(
                        site.custom
                            ? Icons.person_add_alt_rounded
                            : Icons.public_rounded,
                        size: 20,
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              site.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _SourceBadge(custom: site.custom),
                        ],
                      ),
                      subtitle: Text(
                        [
                          if (site.mainUrl.isNotEmpty) site.mainUrl,
                          if (site.info.isNotEmpty) site.info,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (site.custom)
                            IconButton(
                              tooltip: '编辑',
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              onPressed: () => _openEditor(site),
                            ),
                          IconButton(
                            tooltip: '删除',
                            icon: const Icon(Icons.delete_outline_rounded, size: 20),
                            onPressed: () => _remove(site),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.custom});

  final bool custom;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: custom
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        custom ? '自定义' : '内置',
        style: TextStyle(
          fontSize: 10,
          color: custom ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 新增/编辑弹窗：与 custom_sources_view.dart 的 _CustomSourceEditor 同构。
/// 自动识别只回填表单，不写盘；用户看过规则后仍需点「保存」。
class _MagnetSiteEditor extends StatefulWidget {
  const _MagnetSiteEditor({required this.repository, this.existing});

  final AppRepository repository;
  final MagnetSite? existing;

  @override
  State<_MagnetSiteEditor> createState() => _MagnetSiteEditorState();
}

class _MagnetSiteEditorState extends State<_MagnetSiteEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _base = TextEditingController(
    text: widget.existing?.mainUrl ?? '',
  );
  late final _rule = TextEditingController(text: widget.existing?.rule ?? '');
  bool _busy = false;
  bool _analyzing = false;
  String? _error;
  String? _analysisSummary;
  List<String> _analysisNotes = const [];

  @override
  void initState() {
    super.initState();
    _base.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _base.dispose();
    _rule.dispose();
    super.dispose();
  }

  Future<void> _analyze() async {
    if (_busy) return;
    final base = _base.text.trim();
    if (base.isEmpty) {
      setState(() => _error = '请先填写磁力源网址再自动识别');
      return;
    }
    setState(() {
      _busy = true;
      _analyzing = true;
      _error = null;
      _analysisSummary = null;
      _analysisNotes = const [];
    });
    try {
      final result = await widget.repository.analyzeMagnetSite(base);
      if (!mounted) return;
      setState(() {
        _analysisNotes = result.notes;
        if (result.hasRule) {
          _rule.text = result.rule;
          if (_name.text.trim().isEmpty && result.name.isNotEmpty) {
            _name.text = result.name;
          }
          _analysisSummary =
              '已按站点 HTML 生成磁力源规则：可直接保存，也可在下方微调。';
        } else {
          _analysisSummary = '未能识别出可靠规则，请手动粘贴规则 JSON。';
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = '自动识别失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _analyzing = false;
        });
      }
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final rule = _rule.text.trim();
    final base = _base.text.trim();
    if (rule.isEmpty) {
      setState(() => _error = '请先自动识别或粘贴磁力源规则');
      return;
    }
    if (base.isEmpty) {
      setState(() => _error = '请填写源网址');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final existing = widget.existing;
      if (existing == null) {
        await widget.repository.addMagnetSite(
          name: _name.text.trim(),
          base: base,
          rule: rule,
        );
      } else {
        await widget.repository.updateMagnetSite(
          existing.id,
          name: _name.text.trim(),
          rule: rule,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? '新增磁力源' : '编辑磁力源'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: '源名称',
                hintText: '例如：我的磁力站',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _base,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '源网址',
                hintText: 'https://example.com',
                helperText: '填好网址后点「自动识别磁力源」，会抓取站点 HTML 反推搜索地址与列表 XPath。',
                helperMaxLines: 2,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: _busy || _base.text.trim().isEmpty ? null : _analyze,
                icon: _analyzing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_fix_high_rounded, size: 18),
                label: Text(_analyzing ? '识别中…' : '自动识别磁力源'),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _rule,
              enabled: !_busy,
              maxLines: 8,
              minLines: 4,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '磁力源规则 JSON',
                hintText:
                    '{"mainUrl":"https://…","searchUrl":"…[keyword]…[page]…",'
                    '"expressionModel":{"group":"//div[…]","title":".//a[1]"}}',
                helperText: '规则含 request/expressionModel，保存时会校验 group 与搜索地址。',
                helperMaxLines: 2,
              ),
            ),
            if (_analysisSummary case final summary?)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(summary, style: Theme.of(context).textTheme.bodySmall),
                      for (final note in _analysisNotes.take(8))
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '• $note',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        autofocus: true,
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(_busy ? '保存中…' : '保存'),
      ),
    ],
  );
}
