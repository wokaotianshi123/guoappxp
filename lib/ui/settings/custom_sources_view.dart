import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../widgets/focus_ring.dart';
import '../widgets/status_view.dart';
import 'settings_rows.dart';

/// 网络地址导入栏的预设配置地址。
///
/// 打开「从网络地址导入」时默认填入第一项，用户也可点选恢复；输入框仍可手动
/// 修改成任意地址。遥控器端这些预设是可聚焦按钮，方向键能选中。
class CustomSourceImportPreset {
  const CustomSourceImportPreset(this.name, this.url);

  final String name;
  final String url;
}

/// 内置预设：默认填入第一项「网页」，也可点选「采集」切换。
///
/// 预设本身是「加速链接+网址」拼接形态，核心会作为整体识别抓取，
/// 不会只取斜杠前的加速域名。
const List<CustomSourceImportPreset> customSourceImportPresets = [
  CustomSourceImportPreset(
    '网页',
    'https://cfkua.wokaotianshi.eu.org/https://raw.githubusercontent.com/'
        'wokaotianshi123/wokaotianshi123.github.io/refs/heads/main/'
        'hongguo/config.json',
  ),
  CustomSourceImportPreset(
    '采集',
    'https://cfkua.wokaotianshi.eu.org/https://raw.githubusercontent.com/'
        'wokaotianshi123/jgcj/refs/heads/main/hongguo.json',
  ),
];

/// 自定义站源管理页。
///
/// 任何用户都可以新增、编辑、删除符合 MacCMS 模板的站点地址，或直接粘贴
/// XBPQ 爬虫规则 JSON；支持整包导出 JSON、从文件或网络地址批量导入。
class CustomSourcesPage extends StatefulWidget {
  const CustomSourcesPage({
    super.key,
    required this.repository,
    required this.store,
  });
  final AppRepository repository;
  final LocalStore store;

  @override
  State<CustomSourcesPage> createState() => _CustomSourcesPageState();
}

class _CustomSourcesPageState extends State<CustomSourcesPage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sources = await widget.repository.customSources();
      await widget.store.syncCustomSources(sources);
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _openEditor({CustomSourceSite? existing}) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _CustomSourceEditor(
        repository: widget.repository,
        store: widget.store,
        existing: existing,
      ),
    );
    if (changed == true && mounted) unawaited(_load());
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final content = await widget.repository.exportCustomSources();
      if (content.isEmpty) throw const FormatException('没有可导出的自定义源');
      final saved = await FilePicker.saveFile(
        fileName:
            'duanju-custom-sources-'
            '${DateTime.now().toIso8601String().substring(0, 10)}.json',
        bytes: Uint8List.fromList(utf8.encode(content)),
        mimeType: 'application/json',
      );
      if (saved != null && mounted) _showMessage('已导出到 $saved');
    } catch (error) {
      if (mounted) _showMessage('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    final content = await showDialog<String>(
      context: context,
      builder: (_) => const _CustomSourceImportDialog(),
    );
    if (content == null || content.trim().isEmpty || !mounted) return;
    await _runImport(content.trim());
  }

  Future<void> _runImport(String content) async {
    setState(() => _busy = true);
    try {
      final result = await widget.repository.importCustomSources(content);
      await widget.store.syncCustomSources(
        await widget.repository.customSources(),
      );
      if (!mounted) return;
      _showImportResult(result);
    } catch (error) {
      if (mounted) _showMessage('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复默认源'),
        content: const Text(
          '将删除全部自定义源（含 XBPQ 规则），仅保留内置源。'
          '此操作不可撤销，建议先「导出 JSON」备份。',
        ),
        actions: [
          FocusRing(
            radius: 20,
            child: TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
          ),
          FocusRing(
            radius: 20,
            child: FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认恢复'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final removed = await widget.repository.resetCustomSources();
      await widget.store.syncCustomSources(
        await widget.repository.customSources(),
      );
      if (mounted) _showMessage('已删除 $removed 个自定义源，恢复为默认内置源');
    } catch (error) {
      if (mounted) _showMessage('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(CustomSourceSite source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除自定义源'),
        content: Text('确定删除「${source.name}」吗？已加载的剧集仍会保留在设备上。'),
        actions: [
          FocusRing(
            radius: 20,
            child: TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
          ),
          FocusRing(
            radius: 20,
            child: FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await saveSetting(context, () async {
      await widget.repository.removeCustomSource(source.id);
      await widget.store.syncCustomSources(
        await widget.repository.customSources(),
      );
    });
    if (mounted) unawaited(_load());
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showImportResult(Map<String, dynamic> result) {
    final added = (result['added'] as List? ?? const []).length;
    final updated = (result['updated'] as List? ?? const []).length;
    final skipped = (result['skipped'] as List? ?? const [])
        .map((item) => '$item')
        .toList();
    final failed = (result['failed'] as List? ?? const [])
        .map((item) => '$item')
        .toList();
    final details = [
      ...skipped.map((item) => '跳过：$item'),
      ...failed.map((item) => '失败：$item'),
    ];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入完成'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('新增 $added 个，更新 $updated 个。'),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final line in details)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        line,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          FocusRing(
            radius: 20,
            child: FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('自定义源'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: _loading || _busy ? null : () => unawaited(_load()),
          icon: const Icon(Icons.refresh_rounded),
        ),
        IconButton(
          tooltip: '导出 JSON',
          onPressed: _busy ? null : () => unawaited(_export()),
          icon: const Icon(Icons.upload_file_rounded),
        ),
        IconButton(
          tooltip: '导入（文件或网络地址）',
          onPressed: _busy ? null : () => unawaited(_import()),
          icon: const Icon(Icons.download_rounded),
        ),
        IconButton(
          tooltip: '恢复默认源',
          onPressed: _busy ? null : () => unawaited(_reset()),
          icon: const Icon(Icons.restore_rounded),
        ),
        const SizedBox(width: 4),
        FocusRing(
          radius: 999,
          child: FilledButton.icon(
            onPressed: _busy ? null : () => unawaited(_openEditor()),
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('新增'),
          ),
        ),
        const SizedBox(width: 12),
      ],
    ),
    body: ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        if (_error case final error?) {
          return StatusView(
            title: '无法读取自定义源',
            message: error,
            icon: Icons.error_outline_rounded,
            action: '重试',
            onAction: () => unawaited(_load()),
          );
        }
        final sources = widget.store.customSources;
        if (_loading && sources.isEmpty) {
          return const StatusView.loading(title: '正在读取自定义源');
        }
        if (sources.isEmpty) {
          return const StatusView(
            title: '还没有自定义源',
            message:
                '点击「新增」填入 MacCMS 站点地址或粘贴 XBPQ 爬虫规则；'
                '也可以导入文件批量添加，导出 JSON 备份迁移。',
            icon: Icons.dns_outlined,
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                '自定义源会读取网站地址并判断是否符合 MacCMS 规范；'
                '符合后套用通用规则自动完成列表展示、搜索与播放。'
                '录入 XBPQ 爬虫规则的站点按规则字段逐项截取。',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
            ),
            for (final source in sources) _sourceCard(source),
          ],
        );
      },
    ),
  );

  Widget _sourceCard(CustomSourceSite source) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        margin: EdgeInsets.zero,
        child: MergeSemantics(
          child: TileFocus(
            builder: (focusNode) => ListTile(
              focusNode: focusNode,
              minTileHeight: 68,
              contentPadding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
              leading: Icon(
                source.hasRule ? Icons.code_rounded : Icons.dns_outlined,
              ),
              title: Text(
                source.hasRule ? '${source.name}（规则）' : source.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                source.base,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onTap: () => unawaited(_openEditor(existing: source)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeFocus(
                    child: IconButton(
                      tooltip: '删除',
                      onPressed: () => unawaited(_remove(source)),
                      icon: Icon(Icons.delete_outline, color: colors.error),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomSourceEditor extends StatefulWidget {
  const _CustomSourceEditor({
    required this.repository,
    required this.store,
    this.existing,
  });
  final AppRepository repository;
  final LocalStore store;
  final CustomSourceSite? existing;

  @override
  State<_CustomSourceEditor> createState() => _CustomSourceEditorState();
}

class _CustomSourceEditorState extends State<_CustomSourceEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _base = TextEditingController(text: widget.existing?.base ?? '');
  late final _rule = TextEditingController(text: widget.existing?.rule ?? '');
  bool _ruleMode = false;
  bool _busy = false;
  bool _analyzing = false;
  String? _error;
  List<String> _analysisNotes = const [];
  String? _analysisSummary;
  late String _kind = widget.existing?.kind ?? '';

  @override
  void initState() {
    super.initState();
    _ruleMode = widget.existing?.hasRule ?? false;
    // 网址一变化就刷新「自动识别」按钮的可用状态。
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

  Future<void> _save() async {
    if (_busy) return;
    final rule = _ruleMode ? _rule.text.trim() : '';
    if (_ruleMode && rule.isEmpty) {
      setState(() => _error = '粘贴规则 JSON 后再保存，或关闭规则开关');
      return;
    }
    if (!_ruleMode && _base.text.trim().isEmpty) {
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
        await widget.repository.addCustomSource(
          name: _name.text.trim(),
          base: _base.text.trim(),
          rule: rule,
          kind: _kind,
        );
      } else {
        await widget.repository.updateCustomSource(
          existing.id,
          name: _name.text.trim(),
          base: _base.text.trim(),
          rule: rule,
          kind: _kind,
        );
      }
      await widget.store.syncCustomSources(
        await widget.repository.customSources(),
      );
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

  /// 抓取站点网页 HTML，让 Go 核心反推分类 / 列表 / 搜索 / 详情 / 播放规则并回填表单。
  /// 这里只填表，不写盘；用户看过规则后仍需点「保存」才真正新增自定义源。
  Future<void> _analyze() async {
    if (_busy) return;
    final base = _base.text.trim();
    if (base.isEmpty) {
      setState(() => _error = '请先填写源网址再自动识别');
      return;
    }
    setState(() {
      _busy = true;
      _analyzing = true;
      _error = null;
      _analysisNotes = const [];
      _analysisSummary = null;
    });
    try {
      final result = await widget.repository.analyzeCustomSourceSite(base);
      final rule = (result['rule'] as String? ?? '').trim();
      final notes = (result['notes'] as List? ?? const [])
          .whereType<String>()
          .where((line) => line.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _analysisNotes = notes;
        if (rule.isNotEmpty) {
          _rule.text = rule;
          _ruleMode = true;
          if (_name.text.trim().isEmpty) {
            _name.text = (result['name'] as String? ?? '').trim();
          }
          _analysisSummary =
              '已按网页 HTML 生成规则：可直接保存，也可在下方微调后保存。规则优先于源类型，无需改动源类型。';
        } else {
          _analysisSummary =
              '未能识别出可靠规则，已保留为普通网页源（引擎会自动适配 MacCMS 站点），也可以手动粘贴规则。';
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

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? '新增自定义源' : '编辑自定义源'),
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
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: '源名称',
                hintText: _ruleMode ? '留空则用规则里的域名' : '例如：我的影院',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _base,
              enabled: !_busy && !_ruleMode,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '源网址',
                hintText: 'https://example.com',
                helperText: _ruleMode
                    ? '规则模式下网址由规则「主页url」决定；要识别别的站点请先关闭规则开关。'
                    : '填好网址后点「自动识别规则」，会抓取网页 HTML 反推分类、列表、搜索与播放字段。',
                helperMaxLines: 3,
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
                label: Text(_analyzing ? '识别中…' : '自动识别规则'),
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(
                labelText: '源类型',
                helperText: '自动：先探测再兜底；网页源走 HTML 抓取；JSON 源直连接口。',
                helperMaxLines: 2,
              ),
              items: const [
                DropdownMenuItem(value: '', child: Text('自动（默认）')),
                DropdownMenuItem(value: 'web', child: Text('网页源（HTML 抓取）')),
                DropdownMenuItem(value: 'json', child: Text('JSON 源（直连接口）')),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _kind = value ?? ''),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('XBPQ 爬虫规则'),
              subtitle: const Text('粘贴 JSON 规则，按规则字段截取内容'),
              value: _ruleMode,
              onChanged: _busy
                  ? null
                  : (_) => setState(() {
                      _ruleMode = !_ruleMode;
                      _error = null;
                    }),
            ),
            if (_ruleMode)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextField(
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
                    hintText:
                        '{"主页url":"https://…","分类url":"…{cateId}-{catePg}…",'
                        '"数组":"…&&…","标题":"…","链接":"…"}',
                    helperText: '兼容截取语法（A&&B）与 p: 选择器；保存时校验规则有效性。',
                    helperMaxLines: 2,
                  ),
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
                      if (_analysisNotes.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        for (final note in _analysisNotes.take(8))
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '• $note',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
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
      FocusRing(
        radius: 20,
        child: TextButton(
          autofocus: true,
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
      ),
      FocusRing(
        radius: 20,
        child: FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '保存中…' : '保存'),
        ),
      ),
    ],
  );
}

/// 导入方式选择弹窗：本地文件（JSON/TXT）或远程网络配置地址。
class _CustomSourceImportDialog extends StatefulWidget {
  const _CustomSourceImportDialog();

  @override
  State<_CustomSourceImportDialog> createState() =>
      _CustomSourceImportDialogState();
}

class _CustomSourceImportDialogState extends State<_CustomSourceImportDialog> {
  final _url = TextEditingController(
    text: customSourceImportPresets.isEmpty
        ? ''
        : customSourceImportPresets.first.url,
  );
  bool _fileMode = true;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _applyPreset(CustomSourceImportPreset preset) {
    setState(() {
      _url.text = preset.url;
      _url.selection = TextSelection.collapsed(offset: preset.url.length);
    });
  }

  void _submitUrl() {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    Navigator.pop(context, url);
  }

  Future<void> _pickFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json', 'txt'],
    );
    if (file == null || !mounted) return;
    final size = await file.length();
    if (size == null || size > 8 * 1024 * 1024) {
      _message('导入文件过大或无法读取');
      return;
    }
    try {
      final content = utf8.decode(await file.readAsBytes());
      if (mounted) Navigator.pop(context, content);
    } catch (_) {
      if (mounted) _message('导入文件不是有效的 UTF-8 文本');
    }
  }

  void _message(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final television = AppScope.of(context).television;
    return AlertDialog(
      title: const Text('导入自定义源'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('从网络地址导入'),
              subtitle: const Text(
                '粘贴 TVBox 配置 / JSON / TXT 地址，核心自动抓取解析',
                style: TextStyle(fontSize: 12),
              ),
              value: !_fileMode,
              onChanged: (value) => setState(() => _fileMode = !value),
            ),
            if (_fileMode)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('选择本地 JSON / TXT 文件导入。'),
                    const SizedBox(height: 12),
                    FocusRing(
                      radius: 999,
                      child: FilledButton.tonalIcon(
                        onPressed: () => unawaited(_pickFile()),
                        icon: const Icon(Icons.folder_open_rounded, size: 20),
                        label: const Text('选择文件'),
                      ),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _url,
                      autofocus: !television,
                      maxLines: 1,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      autocorrect: false,
                      onSubmitted: (_) => _submitUrl(),
                      decoration: const InputDecoration(
                        labelText: '配置地址',
                        hintText: 'https://…/config.json',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (customSourceImportPresets.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const Text(
                        '可选默认地址（点击填入，仍可手动修改）',
                        style: TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final preset in customSourceImportPresets)
                            _ImportPresetChip(
                              preset: preset,
                              selected: _url.text.trim() == preset.url,
                              onSelected: () => _applyPreset(preset),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        FocusRing(
          radius: 20,
          child: TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
        if (!_fileMode)
          FocusRing(
            radius: 20,
            child: FilledButton(onPressed: _submitUrl, child: const Text('导入')),
          ),
      ],
    );
  }
}

/// 网络地址导入栏的预设地址按钮：触屏点击或遥控器方向键聚焦都能填入地址。
class _ImportPresetChip extends StatelessWidget {
  const _ImportPresetChip({
    required this.preset,
    required this.selected,
    required this.onSelected,
  });

  final CustomSourceImportPreset preset;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 999,
      child: OutlinedButton.icon(
        onPressed: onSelected,
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          backgroundColor: selected ? scheme.primaryContainer : null,
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        icon: Icon(
          selected ? Icons.check_circle_rounded : Icons.cloud_download_rounded,
          size: 18,
        ),
        label: Text(preset.name, style: const TextStyle(fontSize: 13)),
      ),
    );
  }
}
