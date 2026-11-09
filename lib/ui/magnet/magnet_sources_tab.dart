import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../../core_bridge.dart';
import '../../magnet_models.dart';

/// 三个一级标签里的「磁力源管理」。
/// 交互对齐「新增 xbpq 网页源」：填网址 → 自动识别规则 → 预览/微调 → 保存。
///
/// 内置源与自定义源都能编辑：改内置源会写进 Go 侧的覆盖层，「恢复默认」时
/// 连同自定义源一起清掉、回到出厂的 35 站。新增按钮旁提供导入/导出，
/// 导出的就是当前生效配置（含被改过的内置源）。
class MagnetSourcesTab extends StatefulWidget {
  const MagnetSourcesTab({
    super.key,
    required this.onChanged,
    this.active = true,
  });

  /// 源清单变化后通知外层，让搜索/播放标签重新拉站源。
  final VoidCallback onChanged;

  /// 是否是当前显示的子页；未显示时不拉站源，第一次切到才开始。
  final bool active;

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
    if (!_booted && widget.active) {
      _booted = true;
      _load();
    }
  }

  @override
  void didUpdateWidget(MagnetSourcesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_booted && widget.active) {
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
      builder: (context) =>
          _MagnetSiteEditor(repository: _repository, existing: existing),
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
          '将清空所有自定义磁力源、撤销对内置源的修改，并恢复被移除的内置站源。'
          '此操作不可撤销。',
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

  /// 导出当前生效配置到剪贴板：含内置源（被改过的是改后版本）与自定义源。
  Future<void> _export() async {
    try {
      final content = await _repository.magnetExportSites();
      if (!mounted) return;
      final pretty = _prettyJson(content);
      // 剪贴板在部分平台/测试环境没有 handler，setData 会一直挂着不返回；
      // 因此不 await 它：写成功就顺手复制，失败也不影响下面的内容预览。
      unawaited(
        Clipboard.setData(
          ClipboardData(text: pretty),
        ).catchError((Object _) {}),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导出站源配置'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '共 ${_sites.length} 个站源（含内置源当前生效的规则）。'
                  '内容已尝试复制到剪贴板，也可直接选中下方文本保存为 .json 备份。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 240),
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      pretty,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '导出失败：$error');
    }
  }

  /// 从剪贴板导入。默认「合并」，也可选择「替换」（先清空自定义与内置修改）。
  Future<void> _import() async {
    // 剪贴板读取在无 handler 的环境会挂起，加超时兜底，读不到就让用户自己粘贴。
    var seed = '';
    try {
      final clipboard = await Clipboard.getData(
        Clipboard.kTextPlain,
      ).timeout(const Duration(milliseconds: 600));
      seed = clipboard?.text?.trim() ?? '';
    } catch (_) {
      seed = '';
    }
    if (!mounted) return;
    final payload = await showDialog<_ImportRequest>(
      context: context,
      builder: (context) => _ImportDialog(seed: seed),
    );
    if (payload == null || !mounted) return;
    try {
      final result = await _repository.magnetImportSites(
        payload.content,
        mode: payload.mode,
      );
      await _load();
      widget.onChanged();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入完成：${result.summary}')));
    } catch (error) {
      if (mounted) setState(() => _error = '导入失败：$error');
    }
  }

  String _prettyJson(String raw) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final customCount = _sites.where((site) => site.custom).length;
    final editedCount = _sites.where((site) => site.edited).length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '共 ${_sites.length} 个磁力源 · 自定义 $customCount 个'
                '${editedCount > 0 ? ' · 已改内置 $editedCount 个' : ''}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              // 操作按钮单独一行并允许横向滚动：窄屏（手机 / 分屏）下
              // 五个按钮挤在一行会被截断，导致点不到导入导出。
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    TextButton.icon(
                      onPressed: _import,
                      icon: const Icon(Icons.file_download_outlined, size: 18),
                      label: const Text('导入'),
                    ),
                    TextButton.icon(
                      onPressed: _export,
                      icon: const Icon(Icons.file_upload_outlined, size: 18),
                      label: const Text('导出'),
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
          child: _loading && !_booted
              ? const SizedBox.shrink()
              : _loading
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
                          if (site.edited) ...[
                            const SizedBox(width: 4),
                            const _EditedBadge(),
                          ],
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
                          // 内置源同样可编辑：保存后写入 Go 侧覆盖层。
                          IconButton(
                            tooltip: site.custom ? '编辑' : '编辑内置源',
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            onPressed: () => _openEditor(site),
                          ),
                          IconButton(
                            tooltip: '删除',
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 20,
                            ),
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

/// 「已改」小标：内置源被用户改过时提示，方便与出厂规则区分。
class _EditedBadge extends StatelessWidget {
  const _EditedBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '已改',
        style: TextStyle(fontSize: 10, color: scheme.onTertiaryContainer),
      ),
    );
  }
}

/// 导入请求：内容 + 合并方式。
class _ImportRequest {
  const _ImportRequest(this.content, this.mode);

  final String content;
  final String mode;
}

/// 导入弹窗：粘贴 JSON，选择「合并」或「替换」。
class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.seed});

  final String seed;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  late final _content = TextEditingController(text: widget.seed);
  String _mode = 'merge';
  String? _error;

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _content.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请先粘贴站源配置 JSON');
      return;
    }
    Navigator.pop(context, _ImportRequest(text, _mode));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入站源配置'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '粘贴「导出」得到的 JSON（也接受纯站源数组）。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _content,
              maxLines: 10,
              minLines: 6,
              autocorrect: false,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '站源配置 JSON',
              ),
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'merge', label: Text('合并')),
                ButtonSegment(value: 'replace', label: Text('替换')),
              ],
              selected: {_mode},
              onSelectionChanged: (value) =>
                  setState(() => _mode = value.first),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _mode == 'merge'
                    ? '合并：追加新源、更新同 ID 的源，不影响其它源。'
                    : '替换：先清空自定义源与内置源修改，再导入这份配置。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('导入')),
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
          _analysisSummary = '已按站点 HTML 生成磁力源规则：可直接保存，也可在下方微调。';
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
    // 编辑已有源时源网址不必重填：内置源的地址来自出厂规则，改规则就够了。
    final editing = widget.existing != null;
    if (base.isEmpty && !editing) {
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
        // 自定义源与内置源都走这条：Go 侧按 ID 判断写自定义表还是覆盖层。
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
    title: Text(
      widget.existing == null
          ? '新增磁力源'
          : widget.existing!.custom
          ? '编辑磁力源'
          : '编辑内置磁力源',
    ),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.existing != null && !widget.existing!.custom)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '这是内置源。保存后只覆盖它的规则，原始规则仍保留在安装包里；'
                    '点「恢复默认」可还原为出厂规则。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
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
                      Text(
                        summary,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
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
