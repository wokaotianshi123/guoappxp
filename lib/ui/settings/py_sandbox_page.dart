import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../py_source/py_bridge.dart';
import '../../py_source/py_source_gateway.dart';
import '../../py_source/py_source_models.dart';
import '../../py_source/py_source_service.dart';

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

  Future<void> _importFile() => _run(() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['py'],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final result = await _service.import(
      utf8.decode(bytes, allowMalformed: true),
      file.name,
    );
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
    final url = await _promptText('从网址导入', 'py 文件直链');
    if (url == null || url.trim().isEmpty) return;
    await _run(() async {
      final result = await _service.importFromUrl(url);
      if (result.meta == null) {
        _toast('导入失败：${result.error}');
        return;
      }
      _refresh();
      _toast('已导入 ${result.meta!.name}');
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
    _toast('导入 ${result.imported.length} 个，失败 ${result.failed.length} 个');
  });

  Future<void> _exportAll() => _run(() async {
    if (_service.sources.isEmpty) {
      _toast('还没有可导出的 py 源');
      return;
    }
    final bytes = _service.exportZip();
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final saved = await FilePicker.saveFile(
      fileName: 'guoapp-py-$stamp.zip',
      bytes: bytes,
      mimeType: 'application/zip',
    );
    if (saved != null) _toast('已导出全部 py 源');
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

  Future<String?> _promptText(String title, String hint) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    return value;
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
          IconButton(onPressed: _busy ? null : _importZip, icon: const Icon(Icons.unarchive_outlined), tooltip: '导入 zip'),
          IconButton(onPressed: _busy ? null : _exportAll, icon: const Icon(Icons.archive_outlined), tooltip: '导出全部'),
          IconButton(onPressed: _busy ? null : _clearAll, icon: const Icon(Icons.delete_sweep_outlined), tooltip: '清空'),
        ],
      ),
      body: Column(
        children: [
          _runtimeBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(child: FilledButton.icon(onPressed: _busy ? null : _importFile, icon: const Icon(Icons.file_open_outlined), label: const Text('导入文件'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : _importUrl, icon: const Icon(Icons.link), label: const Text('网址'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : _importPaste, icon: const Icon(Icons.edit_note), label: const Text('粘贴'))),
              ],
            ),
          ),
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
      return const Center(child: Text('还没有 py 源。点上方按钮导入一个 .py 蜘蛛脚本。'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: sources.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final meta = sources[index];
        final active = meta.id == _service.activeSourceId;
        final enabled = widget.store.allowsSource(meta.sourceId);
        return ListTile(
          leading: Icon(active ? Icons.play_circle_fill : Icons.terminal, color: active ? Theme.of(context).colorScheme.primary : null),
          title: Text(meta.name),
          subtitle: Text('${meta.fileName}${active ? ' · 当前启用' : ''}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(value: enabled, onChanged: (value) => _toggle(meta, value)),
              IconButton(onPressed: () => _activate(meta), icon: const Icon(Icons.check_circle_outline), tooltip: '启用'),
              IconButton(onPressed: () => _exportOne(meta), icon: const Icon(Icons.archive_outlined), tooltip: '导出'),
              IconButton(onPressed: () => _delete(meta), icon: const Icon(Icons.delete_outline), tooltip: '卸载'),
            ],
          ),
        );
      },
    );
  }
}
