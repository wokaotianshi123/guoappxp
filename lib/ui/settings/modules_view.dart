import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../source_modules.dart';
import '../app_scope.dart';
import '../shell/app_shell.dart';
import '../widgets/bar_button.dart';
import '../widgets/focus_ring.dart';
import '../widgets/form_text_field.dart';
import '../widgets/group_card.dart';
import 'settings_rows.dart';

/// 站源模块页：装在「设置 → 站源」里。
///
/// 模块是可安装的站源。装上的模块提供的站源会立刻出现在站源管理与源显示列表里，
/// 与内置源、自定义源用同一套开关；与本体同名的模块（例如红果、笔盒）由核心
/// 改成 `mod-<标识>` 登记，界面标出「（模块）」，两者共存互不影响。
class ModulesView extends StatefulWidget {
  const ModulesView({super.key, required this.store});
  final LocalStore store;

  @override
  State<ModulesView> createState() => _ModulesViewState();
}

mixin _ModuleActions<T extends StatefulWidget> on State<T> {
  bool _busy = false;

  LocalStore get _store;

  AppRepository get _repository => AppScope.of(context).repository;

  bool get _canInstall => _store.profile.admin && !_store.locked && !_busy;

  Future<void> _refresh();

  void _show(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// 核心没编进模块能力时，Go 侧只会回一句「不支持的应用操作」。这种
  /// 「新前端 + 旧核心」的混合构建几乎都是没有重新完整构建，换成能照着做的提示。
  String _describe(Object failure) {
    final message = '$failure';
    return message.contains('不支持的应用操作')
        ? '当前安装包里的本地核心不支持站源模块，请重新完整构建后再试'
        : message;
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } catch (failure) {
      _show(_describe(failure));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _installIndexed(ModuleIndexEntry entry) => _run(
    () async => _install(await _repository.prepareModule(indexed: entry.id)),
  );

  Future<void> _install(SourceModule module) async {
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => _InstallDialog(module: module),
    );
    if (accepted != true) return;
    final source = await _repository.installModule(module.token);
    // 新装的模块默认开启：用户刚点完安装，源栏里立刻就能看到它。
    // 必须先把模块源登记进本地再打开——否则 setSourceEnabled 会以
    // 「站源无效」把这次操作拒掉。
    if (!module.installed && source.isNotEmpty) {
      await _store.syncModuleSources(
        moduleSourceSites(await _repository.modules()),
      );
      await _store.setSourceEnabled(source, true);
    }
    _show('${module.name} 已安装');
  }
}

ModuleIndexEntry? _updateFor(SourceModule module, ModuleIndexEntry? entry) =>
    entry != null &&
        module.error.isEmpty &&
        isNewerModuleVersion(entry.version, module.version)
    ? entry
    : null;

class _ModulesViewState extends State<ModulesView> with _ModuleActions {
  List<SourceModule>? _modules;
  String? _error;
  ModuleStore? _index;

  @override
  LocalStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _loadIndex();
    });
  }

  Future<void> _loadIndex() async {
    final index = await _repository.moduleIndex().then<ModuleStore?>(
      (index) => index,
      onError: (_) => null,
    );
    if (mounted) setState(() => _index = index);
  }

  @override
  Future<void> _refresh() async {
    try {
      final modules = await _repository.modules();
      // 站源列表、搜索与追剧都按本地登记的模块源判断可用性，
      // 所以每次刷新模块页都顺手同步一次。
      await widget.store.syncModuleSources(moduleSourceSites(modules));
      if (mounted) {
        setState(() {
          _modules = modules;
          _error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => _error = _describe(failure));
    }
  }

  Future<void> _openCatalog({required bool bundled}) async {
    await openPage<void>(
      context,
      (_) => _CatalogPage(store: widget.store, bundled: bundled),
    );
    if (!mounted) return;
    await _refresh();
    unawaited(_loadIndex());
  }

  Future<void> _installFile() => _run(() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (file == null) return;
    var location = file.path;
    if (location == null) {
      final size = await file.length();
      if (size == null || size > 8 * 1024 * 1024) {
        throw AppFailure('安装包过大或无法读取');
      }
      location = path.join(
        (await getApplicationCacheDirectory()).path,
        'module-picked.zip',
      );
      await File(location).writeAsBytes(await file.readAsBytes());
    }
    await _install(await _repository.prepareModule(file: location));
  });

  Future<void> _installAddress() async {
    final address = await showDialog<String>(
      context: context,
      builder: (_) => const _AddressDialog(),
    );
    if (address == null || address.isEmpty) return;
    await _run(
      () async => _install(await _repository.prepareModule(url: address)),
    );
  }

  Future<void> _uninstall(SourceModule module) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('卸载 ${module.name}？'),
        content: const Text(
          '该站源的追剧、观看记录和已下载视频会保留，但在重新安装前不再显示。',
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
              child: const Text('卸载'),
            ),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await _run(() async {
      await _repository.uninstallModule(module.id);
      _show('${module.name} 已卸载');
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final enabled = _canInstall;
      final modules = _modules;
      final latest = {
        for (final entry in _index?.entries ?? const <ModuleIndexEntry>[])
          entry.id: entry,
      };
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (_error case final error?) _Note(error),
          const SectionHeader(title: '已安装站源', padding: _headerPadding),
          if (_index?.warning case final warning? when warning.isNotEmpty)
            _Note(warning),
          if (modules == null && _error == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (modules != null && modules.isEmpty)
            const _Note('还没有安装模块。站源以模块的形式提供，安装后才能在发现、搜索中使用。')
          else if (modules != null)
            SettingsCard(
              children: [
                for (final module in modules)
                  _ModuleTile(
                    module: module,
                    update: _updateFor(module, latest[module.id]),
                    onUpdate: enabled
                        ? () => _installIndexed(latest[module.id]!)
                        : null,
                    onUninstall: enabled ? () => _uninstall(module) : null,
                  ),
              ],
            ),
          const SectionHeader(title: '添加新站源', padding: _headerPadding),
          SettingsCard(
            children: [
              SettingsTile(
                title: '从商店安装',
                subtitle: '浏览模块商店里的站源模块',
                onTap: () => _openCatalog(bundled: false),
              ),
              SettingsTile(
                title: '从内置安装',
                subtitle: '安装包自带的模块，卸载后可在这里装回',
                onTap: () => _openCatalog(bundled: true),
              ),
              SettingsTile(
                title: '从文件安装',
                subtitle: '选择模块的 zip 安装包',
                enabled: enabled,
                onTap: enabled ? _installFile : null,
              ),
              SettingsTile(
                title: '从地址安装',
                subtitle: '填写 zip 安装包的下载地址',
                enabled: enabled,
                onTap: enabled ? _installAddress : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _Note(
            '模块装上后，它提供的站源会出现在「站源管理」与源显示列表里，与内置源、'
            '自定义源用同一套开关。与本体同名的模块会另行标记并共存。'
            '安装、更新与卸载需要管理员身份。',
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ],
      );
    },
  );
}

const _headerPadding = EdgeInsets.fromLTRB(4, 12, 0, 6);

class _CatalogPage extends StatefulWidget {
  const _CatalogPage({required this.store, required this.bundled});
  final LocalStore store;
  final bool bundled;

  @override
  State<_CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<_CatalogPage> with _ModuleActions {
  Map<String, SourceModule>? _installed;
  String? _error;
  ModuleStore? _index;
  String? _indexError;

  @override
  LocalStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _reloadIndex();
    });
  }

  Future<void> _reloadIndex() async {
    setState(() {
      _index = null;
      _indexError = null;
    });
    try {
      final index = await _repository.moduleIndex();
      if (mounted) setState(() => _index = index);
    } catch (failure) {
      if (mounted) setState(() => _indexError = _describe(failure));
    }
  }

  @override
  Future<void> _refresh() async {
    try {
      final modules = await _repository.modules();
      await widget.store.syncModuleSources(moduleSourceSites(modules));
      if (mounted) {
        setState(() {
          _installed = {for (final module in modules) module.id: module};
          _error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => _error = _describe(failure));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bundled = widget.bundled;
    return Scaffold(
      appBar: AppBar(
        title: Text(bundled ? '内置模块' : '模块商店'),
        actions: [
          if (!bundled)
            BarButton(
              icon: Icons.refresh_rounded,
              tooltip: '刷新',
              onPressed: _index == null && _indexError == null
                  ? null
                  : _reloadIndex,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final enabled = _canInstall;
          final installed = _installed;
          final warning = bundled ? '' : _index?.warning ?? '';
          final entries =
              [
                for (final entry
                    in _index?.entries ?? const <ModuleIndexEntry>[])
                  if (entry.bundled == bundled) entry,
              ]..sort(
                (a, b) => ((installed?.containsKey(a.id) ?? false) ? 1 : 0)
                    .compareTo((installed?.containsKey(b.id) ?? false) ? 1 : 0),
              );
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (warning.isNotEmpty) _Note(warning),
              if (_indexError ?? _error case final error?)
                _Note(error)
              else if (_index == null || installed == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (entries.isEmpty && warning.isEmpty)
                _Note(bundled ? '这个安装包没有内置模块。' : '商店里还没有模块。')
              else if (entries.isNotEmpty)
                SettingsCard(
                  children: [
                    for (final entry in entries)
                      _IndexTile(
                        entry: entry,
                        installed: installed[entry.id],
                        onInstall: enabled
                            ? () => _installIndexed(entry)
                            : null,
                      ),
                  ],
                ),
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({
    required this.module,
    required this.update,
    required this.onUpdate,
    required this.onUninstall,
  });
  final SourceModule module;
  final ModuleIndexEntry? update;
  final VoidCallback? onUpdate;
  final VoidCallback? onUninstall;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final version = module.version.isEmpty ? '' : ' · ${module.version}';
    return MergeSemantics(
      child: ListTile(
        minTileHeight: 68,
        contentPadding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
        title: _ModuleTitle('${module.name}$version', adult: module.adult),
        subtitle: Text(
          module.error.isNotEmpty
              ? module.error
              : update != null
              ? '可更新到 ${update!.version}'
              : module.sourceId.isNotEmpty
              ? '站源：${module.sourceId}'
              : module.description.isEmpty
              ? module.id
              : module.description,
          style: module.error.isNotEmpty
              ? TextStyle(color: colors.error)
              : update != null
              ? TextStyle(color: colors.primary)
              : null,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (update != null)
              FocusRing(
                radius: 20,
                child: TextButton(onPressed: onUpdate, child: const Text('更新')),
              ),
            FocusRing(
              radius: 20,
              child: TextButton(
                onPressed: onUninstall,
                child: const Text('卸载'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuleTitle extends StatelessWidget {
  const _ModuleTitle(this.text, {required this.adult});
  final String text;
  final bool adult;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget badge(String label, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
    return Row(
      spacing: 8,
      children: [
        Flexible(child: Text(text)),
        badge('模块', theme.colorScheme.primary),
        if (adult) badge('限制级', theme.colorScheme.error),
      ],
    );
  }
}

class _IndexTile extends StatelessWidget {
  const _IndexTile({
    required this.entry,
    required this.installed,
    required this.onInstall,
  });
  final ModuleIndexEntry entry;
  final SourceModule? installed;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final module = installed;
    final update = module != null && _updateFor(module, entry) != null;
    return MergeSemantics(
      child: ListTile(
        minTileHeight: 68,
        contentPadding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
        title: _ModuleTitle(
          '${entry.name} · ${entry.version}',
          adult: entry.adult,
        ),
        subtitle: Text(
          update
              ? '已安装 ${module.version}，可更新'
              : entry.description.isEmpty
              ? entry.id
              : entry.description,
          style: update ? TextStyle(color: colors.primary) : null,
        ),
        trailing: FocusRing(
          radius: 20,
          child: TextButton(
            onPressed: module == null || update ? onInstall : null,
            child: Text(
              module == null
                  ? '安装'
                  : update
                  ? '更新'
                  : '已安装',
            ),
          ),
        ),
      ),
    );
  }
}

class _InstallDialog extends StatelessWidget {
  const _InstallDialog({required this.module});
  final SourceModule module;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final version = module.version.isEmpty ? '未标注' : module.version;
    final capabilities = [
      for (final name in module.capabilities)
        moduleCapabilityNames[name] ?? name,
    ];
    Widget section(String title, String body) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(title, style: text.labelLarge),
          Text(body),
        ],
      ),
    );
    return AlertDialog(
      title: Text(
        module.installed ? '更新 ${module.name}？' : '安装 ${module.name}？',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (module.description.isNotEmpty) Text(module.description),
            section(
              '版本',
              module.installed
                  ? '${module.previous.isEmpty ? '未标注' : module.previous} → $version'
                  : version,
            ),
            section('标识', module.id),
            section('内容分级', module.adult ? '限制级' : '非限制级'),
            section(
              '可访问的域名',
              module.hosts.isEmpty ? '无' : module.hosts.join('\n'),
            ),
            section('提供的功能', ['目录、详情和播放', ...capabilities].join('、')),
          ],
        ),
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
            child: Text(module.installed ? '更新' : '安装'),
          ),
        ),
      ],
    );
  }
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('从地址安装'),
    content: FormTextField(
      controller: _controller,
      autofocus: true,
      url: true,
      decoration: const InputDecoration(hintText: 'https://…/module.zip'),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      FocusRing(
        radius: 20,
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
      FocusRing(
        radius: 20,
        child: FilledButton(onPressed: _submit, child: const Text('下一步')),
      ),
    ],
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        height: 1.6,
      ),
    ),
  );
}
