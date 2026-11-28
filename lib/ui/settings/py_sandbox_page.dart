import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../py_source/py_bridge.dart';
import '../../py_source/py_source_gateway.dart';
import '../../py_source/py_source_models.dart';
import '../../py_source/py_source_service.dart';
import 'py_source_import_dialog.dart';

/// 我的 › PY 沙箱。
///
/// 与 JS 沙箱同构：导入（文件 / 网址 / 粘贴源码）、切换当前源、开关、
/// 导出与卸载。区别是脚本由内嵌 CPython 执行，只在 Android / iOS /
/// Windows（内置 Python）上可用；其它环境会显示运行时不可用。
class PySandboxPage extends StatefulWidget {
  const PySandboxPage({super.key, required this.store});

  final LocalStore store;

  @override
  State<PySandboxPage> createState() => _PySandboxPageState();
}

class _PySandboxPageState extends State<PySandboxPage> {
  late final PySourceService _service =
      PySourceService.current ?? PySourceGateway.instance.service;
  final _name = TextEditingController();
  final _source = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _source.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _toast('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _activate(PySourceMeta meta) => _run(() async {
    if (!await _service.switchSource(meta.id)) {
      _toast('切换失败：文件可能已被删除');
      return;
    }
    _refresh();
    final target = meta.sourceId;
    if (widget.store.allowsSource(target)) {
      try {
        await widget.store.setSource(target);
      } catch (_) {}
    }
    _toast('已启用 ${meta.name}');
  });

  Future<void> _toggle(PySourceMeta meta, bool enabled) => _run(() async {
    await widget.store.setSourceEnabled(meta.sourceId, enabled);
    _toast(enabled ? '已开启 ${meta.name}' : '已隐藏 ${meta.name}');
  });

  Future<void> _exportOne(PySourceMeta meta) => _run(() async {
    final bytes = _service.exportZip(ids: [meta.id]);
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final saved = await FilePicker.saveFile(
      fileName: 'guoapp-py-${meta.id}-$stamp.zip',
      bytes: bytes,
      mimeType: 'application/zip',
    );
    if (saved != null) _toast('已导出 ${meta.name}');
  });

  Future<void> _delete(PySourceMeta meta) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('卸载 py 源'),
        content: Text('确定卸载「${meta.name}」吗？\n本机的 ${meta.fileName} 会被移除，相关观看记录仍保留。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('卸载')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      final path = _service.pathOf(meta.id) ?? '';
      await _service.removeSource(meta.id);
      if (path.isNotEmpty) await PyBridge.dispose(path);
      _refresh();
      _toast('已卸载 ${meta.name}');
    });
  }

  /// 导入入口收进一个弹层：移动端正文放三个等宽按钮会把「导入文件」
  /// 挤成两行，脚本名也只剩两三个字一行。这里与 JS 沙箱保持一致。
  Future<void> _import() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('选择本地文件'),
              subtitle: const Text('.py 脚本、订阅 JSON，或含脚本的 zip 订阅包'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: const Text('从网址导入'),
              subtitle: const Text('脚本直链，或订阅 JSON'),
              onTap: () => Navigator.pop(context, 'url'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_rounded),
              title: const Text('粘贴源码'),
              subtitle: const Text('直接把 py 代码贴进来'),
              onTap: () => Navigator.pop(context, 'paste'),
            ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'file':
        await _importFile();
      case 'url':
        await _importUrl();
      case 'paste':
        await _importPaste();
    }
  }

  Future<void> _importFile() => _run(() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['py', 'json', 'zip'],
    );
    if (file == null) return;
    final lower = file.name.toLowerCase();
    if (lower.endsWith('.zip')) {
      final result = await _service.importZip(await file.readAsBytes());
      _refresh();
      if (result.error.isNotEmpty) {
        _toast('导入失败：${result.error}');
        return;
      }
      _toast(
        result.failed.isEmpty
            ? '已导入 ${result.imported.length} 个 py 源'
            : '导入 ${result.imported.length} 个，失败 ${result.failed.length} 个',
      );
      return;
    }
    final bytes = await file.readAsBytes();
    final text = utf8.decode(bytes, allowMalformed: true);
    if (lower.endsWith('.json')) {
      // 订阅配置：同目录下放着的脚本会一起装进来。
      final result = await _service.importLocalSubscription(
        text,
        configPath: file.path,
      );
      _refresh();
      if (result.imported.isEmpty) {
        _toast('导入失败：${result.error.isEmpty ? result.failed.join('、') : result.error}');
        return;
      }
      _toast(
        result.failed.isEmpty
            ? '已导入 ${result.imported.length} 个 py 源'
            : '导入 ${result.imported.length} 个，失败 ${result.failed.length} 个',
      );
      return;
    }
    final result = await _service.import(text, file.name);
    if (result.meta == null) {
      _toast('导入失败：${result.error}');
      return;
    }
    final meta = result.meta!;
    final validation = await PyBridge.validate(_service.scriptOf(meta.id) ?? '');
    _refresh();
    if (validation != null && !validation.ok) {
      _toast('已导入但不完整：${validation.error}');
    } else {
      _toast('已导入 ${meta.name}');
    }
  });

  Future<void> _importUrl() async {
    final url = await showDialog<String>(
      context: context,
      builder: (context) => const PySourceImportDialog(),
    );
    if (url == null || url.isEmpty) return;
    await _run(() async {
      // 订阅与直链只下载一次：服务端按内容判断是订阅 JSON 还是 .py 脚本。
      final result = await _service.importUrl(url);
      _refresh();
      if (result is PySubscriptionResult) {
        if (result.imported.isEmpty) {
          _toast('导入失败：${result.error.isEmpty ? result.failed.join('、') : result.error}');
          return;
        }
        _toast(
          result.failed.isEmpty
              ? '已导入 ${result.imported.length} 个 py 源'
              : '导入 ${result.imported.length} 个，失败 ${result.failed.length} 个',
        );
        return;
      }
      if (result is PyImportResult) {
        if (result.meta == null) {
          _toast('导入失败：${result.error}');
          return;
        }
        _toast('已导入 ${result.meta!.name}');
      }
    });
  }

  Future<void> _importPaste() async {
    final result = await showDialog<({String name, String source})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('粘贴源码'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _name, decoration: const InputDecoration(labelText: '文件名（如 demo.py）')),
              const SizedBox(height: 12),
              TextField(
                controller: _source,
                minLines: 8,
                maxLines: 14,
                decoration: const InputDecoration(labelText: 'py 源码'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              (name: _name.text.trim(), source: _source.text),
            ),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await _run(() async {
      final imported = await _service.import(result.source, result.name);
      if (imported.meta == null) {
        _toast('导入失败：${imported.error}');
        return;
      }
      _refresh();
      _toast('已导入 ${imported.meta!.name}');
    });
  }

  Future<void> _importZip() => _run(() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final result = await _service.importZip(bytes);
    _refresh();
    if (result.error.isNotEmpty) {
      _toast('导入失败：${result.error}');
      return;
    }
    _toast(
      result.failed.isEmpty
          ? '已导入 ${result.imported.length} 个 py 源'
          : '导入 ${result.imported.length} 个，失败 ${result.failed.length} 个',
    );
  });

  Future<void> _exportAll() => _run(() async {
    if (_service.sources.isEmpty) {
      _toast('还没有可导出的 py 源');
      return;
    }
    final ids = await showDialog<List<String>>(
      context: context,
      builder: (_) => _PyExportPicker(sources: _service.sources),
    );
    if (ids == null || ids.isEmpty || !mounted) return;
    final bytes = _service.exportZip(ids: ids);
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final name = ids.length == 1
        ? 'guoapp-py-${ids.first}-$stamp.zip'
        : 'guoapp-py-${ids.length}-$stamp.zip';
    final saved = await FilePicker.saveFile(
      fileName: name,
      bytes: bytes,
      mimeType: 'application/zip',
    );
    if (saved != null) _toast('已导出 ${ids.length} 个 py 源的订阅包');
  });

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空全部 py 源'),
        content: const Text('将删除本机所有已导入的 .py 源，此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清空')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _service.clearAll();
      _refresh();
      _toast('已清空');
    });
  }

  void _refresh() {
    PySourceGateway.instance.refreshSources();
    widget.store.sourcesChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PY 沙箱'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else ...[
            IconButton(
              onPressed: _import,
              icon: const Icon(Icons.add_circle_outline_rounded),
              tooltip: '导入（文件 / 网址 / 粘贴）',
            ),
            IconButton(
              onPressed: _exportAll,
              icon: const Icon(Icons.ios_share_rounded),
              tooltip: '导出订阅包',
            ),
            IconButton(
              onPressed: _importZip,
              icon: const Icon(Icons.unarchive_outlined),
              tooltip: '导入 zip 订阅包',
            ),
            IconButton(
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空',
            ),
          ],
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _runtimeBanner(),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _runtimeBanner() {
    return FutureBuilder<PyRuntimeStatus>(
      future: PyBridge.status(),
      builder: (context, snapshot) {
        final status = snapshot.data;
        if (status == null || status.available) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.errorContainer,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(status.notReadyMessage, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
        );
      },
    );
  }

  Widget _list() {
    final sources = _service.sources;
    if (sources.isEmpty) {
      return const Center(child: Text('还没有 py 源。点右上角 + 导入一个 .py 蜘蛛脚本。'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: sources.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final meta = sources[index];
        final active = meta.id == _service.activeSourceId;
        final enabled = widget.store.allowsSource(meta.sourceId);
        return _PySourceCard(
          meta: meta,
          active: active,
          enabled: enabled,
          onToggle: (value) => _toggle(meta, value),
          onActivate: () => _activate(meta),
          onExport: () => _exportOne(meta),
          onDelete: () => _delete(meta),
        );
      },
    );
  }
}

/// 单个 py 源卡片。
///
/// 移动端窄屏下把开关与操作按钮挤在标题同一行，会把脚本名压成每行两三个字。
/// 这里改成：标题独占整行（最多两行），开关在右上角，操作按钮放到底部一行，
/// 与 JS 沙箱的卡片布局一致。
class _PySourceCard extends StatelessWidget {
  const _PySourceCard({
    required this.meta,
    required this.active,
    required this.enabled,
    required this.onToggle,
    required this.onActivate,
    required this.onExport,
    required this.onDelete,
  });

  final PySourceMeta meta;
  final bool active;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onActivate;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
      height: 1.4,
    );
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: active
                        ? colors.primaryContainer
                        : colors.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    active ? Icons.play_circle_fill_rounded : Icons.terminal_rounded,
                    size: 22,
                    color: active
                        ? colors.onPrimaryContainer
                        : colors.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        meta.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(fontSize: 16),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${meta.fileName}${active ? ' · 当前启用' : ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Switch(value: enabled, onChanged: onToggle),
              ],
            ),
          ),
          Divider(
            height: 1,
            indent: 18,
            endIndent: 18,
            color: colors.outlineVariant.withValues(alpha: 0.6),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: Row(
              children: [
                if (active)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      '当前启用',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else
                  TextButton.icon(
                    onPressed: onActivate,
                    icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                    label: const Text('启用'),
                  ),
                const Spacer(),
                IconButton(
                  onPressed: onExport,
                  icon: const Icon(Icons.save_alt_rounded),
                  tooltip: '导出这个源',
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: '卸载',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 导出勾选弹层：与 JS 沙箱同一套交互。
class _PyExportPicker extends StatefulWidget {
  const _PyExportPicker({required this.sources});
  final List<PySourceMeta> sources;

  @override
  State<_PyExportPicker> createState() => _PyExportPickerState();
}

class _PyExportPickerState extends State<_PyExportPicker> {
  late final Set<String> _selected = {
    for (final source in widget.sources) source.id,
  };

  bool get _allSelected => _selected.length == widget.sources.length;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导出 py 源'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: Text(
                  '已选 ${_selected.length} / ${widget.sources.length} 个',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  if (_allSelected) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(widget.sources.map((source) => source.id));
                  }
                }),
                child: Text(_allSelected ? '全不选' : '全选'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final source in widget.sources)
                  CheckboxListTile(
                    value: _selected.contains(source.id),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        _selected.add(source.id);
                      } else {
                        _selected.remove(source.id);
                      }
                    }),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      source.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      source.fileName.isEmpty ? source.id : source.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '包内含 xiaoguo.json 与脚本，可直接在「我的 › PY 沙箱」里重新导入，'
            '解压后整个目录也能给其他客户端读取。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _selected.isEmpty
            ? null
            : () => Navigator.pop(context, _selected.toList()),
        child: const Text('导出'),
      ),
    ],
  );
}
