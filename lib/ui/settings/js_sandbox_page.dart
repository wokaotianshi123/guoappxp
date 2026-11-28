import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../js_source/js_source_diagnostics.dart';
import '../../js_source/js_source_gateway.dart';
import '../../js_source/js_source_models.dart';
import '../../js_source/js_source_service.dart';
import '../../js_source/js_signing_profile.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../widgets/focus_ring.dart';
import '../widgets/group_card.dart';
import 'js_source_import_dialog.dart';
import 'subscription_picker_dialog.dart';
import '../../subscription_models.dart';

/// 我的 › JS 沙箱。
///
/// 脚本源的安装与启用都在这页：导入（文件 / 网址 / 源码）、切换当前源、
/// 删除与清空。脚本在端侧独立上下文里跑，与内核站源完全解耦——换一个
/// 脚本就是换一套目录 / 详情 / 取流逻辑，不用重编内核。
class JsSandboxPage extends StatefulWidget {
  const JsSandboxPage({super.key, required this.store});

  final LocalStore store;

  @override
  State<JsSandboxPage> createState() => _JsSandboxPageState();
}

class _JsSandboxPageState extends State<JsSandboxPage> {
  late final JsSourceService _service =
      JsSourceService.current ?? JsSourceGateway.instance.service;

  final _name = TextEditingController();
  final _script = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _script.dispose();
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

  /// 带返回值、带 busy 标记的一次性操作。
  ///
  /// [_run] 只收 `Future<void>`，拉取订阅这类「要拿到结果再继续」的动作用它
  /// 没法写，又不能为此把它改成泛型（会牵动全部既有调用点）。
  Future<T?> _runValue<T>(Future<T> Function() action) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      return await action();
    } catch (error) {
      _toast('$error');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _activate(JsSourceMeta meta) => _run(() async {
    final ok = await _service.switchSource(meta.id);
    if (!ok) {
      _toast('切换失败：脚本可能已被删除');
      return;
    }
    JsSourceGateway.instance.refreshSources();
    widget.store.sourcesChanged();
    // 当前浏览的源如果还是内核源，顺手切到刚激活的脚本源，省得用户再找。
    final target = meta.sourceId;
    if (widget.store.allowsSource(target)) {
      try {
        await widget.store.setSource(target);
      } catch (_) {}
    }
    _toast('已启用 ${meta.name}');
  });

  /// 开启 / 隐藏这个脚本源。与模块源同一套开关：关掉后它不出现在站源菜单、
  /// 搜索、追剧和观看记录里，脚本与记录都还在，重新打开就回来。
  Future<void> _toggle(JsSourceMeta meta, bool enabled) => _run(() async {
    await widget.store.setSourceEnabled(meta.sourceId, enabled);
    _toast(enabled ? '已开启 ${meta.name}' : '已隐藏 ${meta.name}');
  });

  /// 只导出这一个脚本源，格式与「导出」里的多选包一致。
  Future<void> _exportOne(JsSourceMeta meta) => _run(() async {
    final bytes = _service.exportZip(ids: [meta.id]);
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final saved = await FilePicker.saveFile(
      fileName: 'guoapp-js-${meta.id}-$stamp.zip',
      bytes: bytes,
      mimeType: 'application/zip',
    );
    if (saved != null) _toast('已导出 ${meta.name} 的订阅包');
  });

  Future<void> _delete(JsSourceMeta meta) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('卸载脚本源'),
        content: Text(
          '确定卸载「${meta.name}」吗？\n'
          '本机的 ${meta.fileName} 会被移除，相关的观看记录仍保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _service.removeSource(meta.id);
      JsSourceGateway.instance.refreshSources();
      widget.store.sourcesChanged();
      _toast('已卸载 ${meta.name}');
    });
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空所有脚本源'),
        content: const Text('将删除本机全部 .js 脚本，且不可恢复。内置的官方源可以重新导入。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('全部清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _service.clearAll();
      JsSourceGateway.instance.refreshSources();
      widget.store.sourcesChanged();
      _toast('已清空脚本源');
    });
  }

  Future<void> _importSource(String script, String fileName) => _run(() async {
    final result = await _service.import(script, fileName);
    if (!result.success) {
      _toast('导入失败：${result.error}');
      return;
    }
    JsSourceGateway.instance.refreshSources();
    widget.store.sourcesChanged();
    _toast('已导入 ${result.meta!.name}');
  });

  /// 导入入口统一到一处：一个弹层里选「本地文件」还是「从网址导入」。
  /// 本地文件既可以是单个 .js 脚本，也可以是导出的订阅包（zip，含配置
  /// 与脚本）或订阅 JSON；网址既可以是脚本直链，也可以是订阅 JSON。
  Future<void> _import() async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => const _ImportDialog(),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'file':
        await _fileImport();
      case 'url':
        await _urlImport();
    }
  }

  /// 导出：先勾选要打包的脚本源，再存成一个订阅包
  /// （`xiaoguo.json` + 脚本），与模块导出同一套流程。
  Future<void> _export() async {
    final sources = _service.sources;
    if (sources.isEmpty) {
      _toast('还没有可导出的脚本源');
      return;
    }
    final ids = await showDialog<List<String>>(
      context: context,
      builder: (_) => _ExportPicker(sources: sources),
    );
    if (ids == null || ids.isEmpty || !mounted) return;
    await _run(() async {
      final bytes = _service.exportZip(ids: ids);
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final name = ids.length == 1
          ? 'guoapp-js-${ids.first}-$stamp.zip'
          : 'guoapp-js-${ids.length}-$stamp.zip';
      final saved = await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: 'application/zip',
      );
      if (saved != null) _toast('已导出 ${ids.length} 个脚本源的订阅包');
    });
  }

  Future<void> _fileImport() => _run(() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['js', 'json', 'zip'],
    );
    if (file == null) return;
    final size = await file.length();
    final lower = file.name.toLowerCase();
    if (lower.endsWith('.zip')) {
      if (size == null || size > 16 * 1024 * 1024) {
        _toast('压缩包过大或无法读取（上限 16MB）');
        return;
      }
      final result = await _service.importZip(await file.readAsBytes());
      if (!result.success) {
        _toast(
          result.error.isNotEmpty
              ? '导入失败：${result.error}'
              : '压缩包里没有可导入的脚本：${result.failed.join('；')}',
        );
        return;
      }
      JsSourceGateway.instance.refreshSources();
      widget.store.sourcesChanged();
      _toast(_importSummary('已导入', result.imported.length, result.failed));
      return;
    }
    if (size == null || size > 4 * 1024 * 1024) {
      _toast('文件过大或无法读取（上限 4MB）');
      return;
    }
    final bytes = await file.readAsBytes();
    if (lower.endsWith('.json')) {
      // 本地订阅同样先列出条目让用户挑，与网址导入一致。
      final fetch = _service.fetchLocalSubscription(
        utf8.decode(bytes, allowMalformed: true),
        configPath: file.path,
      );
      if (fetch.candidates.isEmpty) {
        _toast(
          fetch.error.isNotEmpty
              ? '导入失败：${fetch.error}'
              : '这个配置里没有可导入的脚本',
        );
        return;
      }
      if (!mounted) return;
      final report = await showDialog<SubscriptionImportReport>(
        context: context,
        barrierDismissible: false,
        builder: (context) => SubscriptionPickerDialog(
          title: '选择要导入的脚本源',
          notice: fetch.notice,
          candidates: fetch.candidates,
          onImport: (selected, onProgress, isCancelled) =>
              _service.importCandidates(
                selected,
                onProgress: onProgress,
                isCancelled: isCancelled,
              ),
        ),
      );
      if (!mounted || report == null) return;
      JsSourceGateway.instance.refreshSources();
      widget.store.sourcesChanged();
      _toast(_importSummary('已导入', report.imported.length, report.failed));
      return;
    }
    final script = utf8.decode(bytes, allowMalformed: true);
    final name = lower.endsWith('.js') ? file.name : '${file.name}.js';
    final result = await _service.import(script, name);
    if (!result.success) {
      _toast('导入失败：${result.error}');
      return;
    }
    JsSourceGateway.instance.refreshSources();
    widget.store.sourcesChanged();
    _toast('已导入 ${result.meta!.name}');
  });

  String _importSummary(String prefix, int count, List<String> failed) => [
    '$prefix $count 个脚本源',
    if (failed.isNotEmpty) '${failed.length} 个失败：${failed.join('；')}',
  ].join('，');

  Future<void> _pasteImport() async {
    final preset = _service.sources.isEmpty
        ? 'custom_source.js'
        : '${_service.sources.first.id}_copy.js';
    _name.text = preset;
    _script.clear();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('粘贴脚本源码'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '脚本需符合 CatPawOpen / CatVodOpen 规范，并带有 id、name 的 meta 定义。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '文件名（需以 .js 结尾）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _script,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'JavaScript 源码',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (_name.text.trim().isEmpty || _script.text.trim().isEmpty) {
                return;
              }
              Navigator.pop(context, true);
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (result == true) {
      await _importSource(_script.text, _name.text.trim());
    }
  }

  Future<void> _urlImport() async {
    final url = await showDialog<String>(
      context: context,
      builder: (context) => const JsSourceImportDialog(),
    );
    if (!mounted || url == null || url.isEmpty) return;
    // 第一步：只解析订阅，拿到可勾选的清单。
    final fetch = await _runValue(() => _service.fetchSubscription(url));
    if (!mounted || fetch == null) return;
    if (fetch.candidates.isEmpty) {
      _toast(
        fetch.error.isNotEmpty
            ? '导入失败：${fetch.error}'
            : '这个地址里没有可导入的脚本',
      );
      return;
    }
    // 直链没有选择余地，直接导入。
    if (!fetch.fromSubscription) {
      await _run(() async {
        final report = await _service.importCandidates(fetch.candidates);
        JsSourceGateway.instance.refreshSources();
        widget.store.sourcesChanged();
        _toast(_importSummary('已导入', report.imported.length, report.failed));
      });
      return;
    }
    // 第二步：让用户勾选，导入时右上角显示进度。
    final report = await showDialog<SubscriptionImportReport>(
      context: context,
      barrierDismissible: false,
      builder: (context) => SubscriptionPickerDialog(
        title: '选择要导入的脚本源',
        notice: fetch.notice,
        candidates: fetch.candidates,
        onImport: (selected, onProgress, isCancelled) =>
            _service.importCandidates(
              selected,
              onProgress: onProgress,
              isCancelled: isCancelled,
            ),
      ),
    );
    if (!mounted || report == null) return;
    JsSourceGateway.instance.refreshSources();
    widget.store.sourcesChanged();
    _toast(_importSummary('已导入', report.imported.length, report.failed));
  }

  /// 官方脚本的 App 接口要签名参数；这里让用户粘贴同一份 JSON。
  /// 没有配置时脚本会明确报 SOURCE_CONFIGURATION_MISSING，不会静默失败。
  Future<void> _editSigning() async {
    final controller = TextEditingController(
      text: _service.signing == null
          ? ''
          : jsonEncode({
              'id': _service.signing!.id,
              'material': _service.signing!.material,
            }),
    );
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('签名参数'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '官方源签名已随安装包内置，通常不需要填写。若要换成自己的密钥，'
                '把 {"id":"…","material":"…"} 粘贴进来，装载脚本时会自动替换占位符。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 5,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: '签名参数 JSON',
                  hintText: '{"id":"…","material":"…"}',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (_service.signing != null)
            TextButton(
              onPressed: () => Navigator.pop(context, 'clear'),
              child: const Text('清除'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'clear') {
      await _service.setSigningProfile(null);
      JsSourceGateway.instance.cancelAll();
      _toast('已清除签名参数');
      return;
    }
    final profile = JsSigningProfile.parse(controller.text);
    if (profile == null) {
      _toast('参数无效：id 需为 9 字节、material 需为 32 字节的 base64');
      return;
    }
    await _service.setSigningProfile(profile);
    JsSourceGateway.instance.cancelAll();
    _toast('签名参数已保存，脚本会在下次请求时重新装载');
  }

  /// 维护菜单：粘贴源码、重新扫描、清空。导入与导出各有独立的圆形按钮，
  /// 不再和这些维护动作混在一个列表里。
  Future<void> _showActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.code_rounded),
              title: const Text('粘贴脚本源码'),
              onTap: () => Navigator.pop(context, 'code'),
            ),
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: const Text('重新扫描本机脚本'),
              onTap: () => Navigator.pop(context, 'reload'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_forever_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                '清空所有脚本源',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => Navigator.pop(context, 'clear'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'code':
        await _pasteImport();
      case 'reload':
        await _run(() async {
          await _service.reload();
          JsSourceGateway.instance.refreshSources();
          widget.store.sourcesChanged();
          _toast('已重新扫描，共 ${_service.sources.length} 个脚本源');
        });
      case 'clear':
        await _clearAll();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      // 页内不再重复标题：AppBar 已经写明「JS 沙箱」，正文直接从说明开始，
      // 省下一行高度给脚本列表。
      title: const Text('JS 沙箱'),
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
          FocusRing(
            radius: 999,
            child: IconButton(
              tooltip: '导入（文件 / 压缩包 / 网址或订阅）',
              onPressed: _import,
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
          ),
          FocusRing(
            radius: 999,
            child: IconButton(
              tooltip: '导出订阅包（配置 + 脚本）',
              onPressed: _export,
              icon: const Icon(Icons.ios_share_rounded),
            ),
          ),
          FocusRing(
            radius: 999,
            child: IconButton(
              tooltip: '粘贴源码 / 重新扫描 / 清空',
              onPressed: _showActions,
              icon: const Icon(Icons.more_horiz_rounded),
            ),
          ),
        ],
        const SizedBox(width: 4),
      ],
    ),
    body: ListenableBuilder(
      listenable: Listenable.merge([_service, widget.store]),
      builder: (context, _) {
        final sources = _service.sources;
        final active = _service.activeSourceId;
        final current = widget.store.source;
        return ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '脚本源在端侧独立上下文里运行：目录、搜索、详情、取流都由脚本自己完成，'
                '与内核站源互不影响。当前站源为「${SourceSite.byId(current).name}」。'
                '右侧开关控制它是否出现在站源菜单、搜索与追剧中，关掉后脚本和记录都保留。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                '已导入脚本（${sources.length}）',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (sources.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: _EmptySources(),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  spacing: 10,
                  children: [
                    for (final meta in sources)
                      _SourceCard(
                        meta: meta,
                        active: meta.id == active,
                        inUse: meta.sourceId == current,
                        enabled: widget.store.sourceEnabled(meta.sourceId),
                        onToggle: (value) => _toggle(meta, value),
                        onActivate: () => _activate(meta),
                        onExport: () => _exportOne(meta),
                        onDelete: () => _delete(meta),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GroupCard(
                children: [
                  SettingsTile(
                    icon: Icons.key_rounded,
                    title: '签名参数',
                    subtitle: _service.signing == null
                        ? '未配置。官方源的分类 / 详情 / 取流都要签名，缺它无法出片。'
                        : _service.signing!.builtIn
                        ? '已随安装包内置官方源签名，无需手动填写；可在下方填自己的参数覆盖。'
                        : '已配置，脚本请求会带上签名头。',
                    value: _service.signing == null
                        ? '未配置'
                        : _service.signing!.builtIn
                        ? '已内置'
                        : '已配置',
                    onTap: _editSigning,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '最近请求',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const _DiagnosticsCard(),
          ],
        );
      },
    ),
  );
}

/// 导入入口：本地 .js 文件、含若干脚本的 zip、或网址 / 订阅地址。
class _ImportDialog extends StatelessWidget {
  const _ImportDialog();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('导入脚本源'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ImportChoice(
              icon: Icons.file_open_outlined,
              title: '选择本地文件',
              subtitle: '.js 脚本、订阅 JSON，或含配置与脚本的订阅包（zip）',
              onTap: () => Navigator.pop(context, 'file'),
            ),
            const SizedBox(height: 8),
            _ImportChoice(
              icon: Icons.link_rounded,
              title: '从网址导入',
              subtitle: '脚本直链，或订阅 JSON（里面列着若干脚本名与地址）',
              onTap: () => Navigator.pop(context, 'url'),
            ),
            const SizedBox(height: 14),
            Text(
              '订阅是一个 JSON：{"sources":[{"name":"…","url":"…"}]}，'
              '也接受裸数组。url 可以写相对地址（./a.js、.\\a.js），按订阅'
              '所在目录解析。导出包里的 xiaoguo.json 与脚本放在同一目录：'
              '选 zip，或解压后直接选 xiaoguo.json，都会读同目录脚本，不需要'
              '联网。填错成脚本直链时会自动按单个脚本导入。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: colors.onSurfaceVariant,
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
      ],
    );
  }
}

class _ImportChoice extends StatelessWidget {
  const _ImportChoice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            spacing: 12,
            children: [
              Icon(icon, color: colors.onSurfaceVariant),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// 导出勾选：默认全选，可以只打包其中几个源。
class _ExportPicker extends StatefulWidget {
  const _ExportPicker({required this.sources});
  final List<JsSourceMeta> sources;

  @override
  State<_ExportPicker> createState() => _ExportPickerState();
}

class _ExportPickerState extends State<_ExportPicker> {
  late final Set<String> _selected = {
    for (final source in widget.sources) source.id,
  };

  bool get _allSelected => _selected.length == widget.sources.length;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导出脚本源'),
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
                      '${source.id} · v${source.version}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '包内含 xiaoguo.json 与脚本：可直接在「导入 › 选择本地文件」里重新导入，'
            '解压后也能给本地服务版读取。',
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

class _EmptySources extends StatelessWidget {
  const _EmptySources();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      children: [
        Icon(
          Icons.extension_off_rounded,
          size: 40,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text('还没有脚本源', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '点右上角「导入」加入 .js 脚本，或从内置的官方源开始。',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.meta,
    required this.active,
    required this.inUse,
    required this.enabled,
    required this.onToggle,
    required this.onActivate,
    required this.onExport,
    required this.onDelete,
  });

  final JsSourceMeta meta;

  /// 是这个脚本在当前沙箱里处于「启用」状态（同一时间只有一个）。
  final bool active;

  /// 当前浏览的站源就是它。
  final bool inUse;

  /// 站源显示开关。关掉后脚本还在，只是不出现在站源菜单、搜索和追剧里。
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onActivate;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  /// 电视端方向键线性遍历卡片内的可聚焦项。
  ///
  /// 开关在顶行右侧、操作按钮在底行，直角几何遍历下从按钮按「下」会跳过同排
  /// 剩下的按钮直接跳到下一张卡片。这里拦截上下键改用阅读顺序的
  /// next/previous 逐个移动（与模块页的卡片同一套做法），左右键仍走几何遍历。
  static KeyEventResult _cardKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        primary.nextFocus();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        primary.previousFocus();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
      height: 1.4,
    );
    return GroupCard(
      children: [
        Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _cardKey,
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
                        Icons.javascript_rounded,
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
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  meta.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontSize: 17,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text('v${meta.version}', style: muted),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${meta.fileName} · ${meta.author.isEmpty ? "内置" : meta.author}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: muted,
                          ),
                          if (meta.description.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                meta.description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (meta.features.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  for (final feature in meta.features.take(6))
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: colors.secondaryContainer,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        feature,
                                        style: theme.textTheme.labelSmall,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FocusRing(
                      radius: 20,
                      child: Switch(
                        value: enabled,
                        onChanged: onToggle,
                      ),
                    ),
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
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(
                  spacing: 8,
                  children: [
                    if (inUse)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          '使用中',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    else if (active)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          '当前启用',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      FocusRing(
                        radius: 20,
                        child: FilledButton.tonalIcon(
                          onPressed: onActivate,
                          icon: const Icon(Icons.check_circle_outline_rounded),
                          label: const Text('启用'),
                        ),
                      ),
                    const Spacer(),
                    FocusRing(
                      radius: 20,
                      child: IconButton.filledTonal(
                        visualDensity: VisualDensity.compact,
                        tooltip: '导出这个脚本源',
                        onPressed: onExport,
                        icon: const Icon(Icons.save_alt_rounded),
                      ),
                    ),
                    FocusRing(
                      radius: 20,
                      child: FilledButton.tonalIcon(
                        onPressed: onDelete,
                        icon: const Icon(Icons.delete_outline_rounded),
                        label: const Text('卸载'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DiagnosticsCard extends StatefulWidget {
  const _DiagnosticsCard();

  @override
  State<_DiagnosticsCard> createState() => _DiagnosticsCardState();
}

class _DiagnosticsCardState extends State<_DiagnosticsCard> {
  @override
  Widget build(BuildContext context) {
    final entries = JsSourceDiagnostics.shared.entries.take(8).toList();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  '还没有请求记录。打开一个脚本源浏览 / 播放后，这里会显示最近的接口往来。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              )
            else
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        entry.failed
                            ? Icons.error_outline_rounded
                            : Icons.check_circle_outline_rounded,
                        size: 14,
                        color: entry.failed ? colors.error : colors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.text,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
            if (entries.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    JsSourceDiagnostics.shared.clear();
                    setState(() {});
                  },
                  child: const Text('清除记录'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
