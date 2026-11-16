import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_modules.dart';
import '../app_scope.dart';
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
///
/// 页面分四个标签：已安装、在线仓库、内置、手动。每个模块单独一张卡片；
/// 在线仓库和内置只列还没装的（以及可更新的），装好之后就从列表里消失，
/// 避免同一批模块在两处重复出现。
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

class _ModulesViewState extends State<ModulesView>
    with SingleTickerProviderStateMixin, _ModuleActions {
  late final _tabs = TabController(length: 4, vsync: this)
    ..addListener(_tabChanged);
  List<SourceModule>? _modules;
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
      _loadIndex();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _tabChanged() {
    // 切到在线仓库时才显示刷新按钮，这里要跟着重建 AppBar。
    if (!_tabs.indexIsChanging) setState(() {});
  }

  Future<void> _loadIndex() async {
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

  Future<void> _toggle(SourceModule module, bool value) {
    final repository = _repository;
    return saveSetting(context, () async {
      await _store.setSourceEnabled(module.id, value);
      // 关掉站源时把它的下载一起暂停：任务留在列表里，打开后可继续。
      if (!value && repository.supportsDownloads) {
        await repository.controlDownloads('pauseSource', id: module.id);
      }
    });
  }

  Widget _list(List<Widget> children) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
    itemCount: children.length,
    itemBuilder: (_, index) => children[index],
    separatorBuilder: (_, _) => const SizedBox(height: 12),
  );

  Widget _installedTab() {
    final modules = _modules;
    final enabled = _canInstall;
    final latest = {
      for (final entry in _index?.entries ?? const <ModuleIndexEntry>[])
        entry.id: entry,
    };
    return _list([
      if (_error case final error?) _Note(error),
      if (modules == null && _error == null)
        const _Loading()
      else if (modules != null && modules.isEmpty)
        const _Note('还没有安装模块。站源以模块的形式提供，可以从在线仓库、内置或手动安装。')
      else if (modules != null)
        for (final module in modules)
          _InstalledCard(
            module: module,
            update: _updateFor(module, latest[module.id]),
            enabled: _store.sourceEnabled(module.id),
            onToggle:
                _store.profile.admin &&
                    module.error.isEmpty &&
                    SourceSite.isAvailable(module.id)
                ? (value) => _toggle(module, value)
                : null,
            onDetails: () => showDialog<void>(
              context: context,
              builder: (_) => _DetailsDialog(module: module),
            ),
            onUpdate: enabled && _updateFor(module, latest[module.id]) != null
                ? () => _installIndexed(latest[module.id]!)
                : null,
            onUninstall: enabled ? () => _uninstall(module) : null,
          ),
    ]);
  }

  Widget _catalogTab({required bool bundled}) {
    final enabled = _canInstall;
    final installed = {for (final module in _modules ?? const []) module.id};
    final warning = bundled ? '' : _index?.warning ?? '';
    final listed = [
      for (final entry in _index?.entries ?? const <ModuleIndexEntry>[])
        if (entry.bundled == bundled) entry,
    ];
    // 只列未安装的：在线仓库与内置两页都不该出现已经在「已安装」里的模块。
    final entries = [
      for (final entry in listed)
        if (!installed.contains(entry.id)) entry,
    ];
    return _list([
      if (warning.isNotEmpty) _Note(warning),
      if (_indexError ?? _error case final error?)
        _Note(error)
      else if (_index == null || _modules == null)
        const _Loading()
      else if (listed.isEmpty && warning.isEmpty)
        _Note(bundled ? '这个安装包没有内置模块。' : '仓库里还没有模块。')
      else if (entries.isEmpty)
        _Note(bundled ? '内置模块都已安装。' : '仓库里的模块都已安装。')
      else
        for (final entry in entries)
          _IndexCard(
            entry: entry,
            onInstall: enabled ? () => _installIndexed(entry) : null,
          ),
    ]);
  }

  Widget _manualTab() {
    final enabled = _canInstall;
    return _list([
      SettingsCard(
        children: [
          SettingsTile(
            title: '选择本地文件',
            subtitle: '选择模块的 zip 安装包',
            enabled: enabled,
            onTap: enabled ? _installFile : null,
          ),
        ],
      ),
      SettingsCard(
        children: [
          SettingsTile(
            title: '输入下载地址',
            subtitle: '填写 zip 安装包的下载地址',
            enabled: enabled,
            onTap: enabled ? _installAddress : null,
          ),
        ],
      ),
      const _Note('安装、更新与卸载需要管理员身份。装上的模块提供的站源会出现在「站源管理」里，与内置源、自定义源用同一套开关。'),
    ]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => Column(
      children: [
        // 标签栏做在内容里而不是 AppBar.bottom：这个页面既可能被当成独立路由
        // 打开（自带 Scaffold），也可能作为设置的右侧子页内嵌（外面已有
        // Scaffold），两种情况下都不该再套一层 AppBar。
        Material(
          color: Colors.transparent,
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: TabBar(
                    controller: _tabs,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                    unselectedLabelStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    tabs: const [
                      Tab(text: '已安装'),
                      Tab(text: '在线仓库'),
                      Tab(text: '内置'),
                      Tab(text: '手动'),
                    ],
                  ),
                ),
                if (_tabs.index == 1)
                  BarButton(
                    icon: Icons.refresh_rounded,
                    tooltip: '刷新',
                    onPressed: _index == null && _indexError == null
                        ? null
                        : _loadIndex,
                  ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _installedTab(),
              _catalogTab(bundled: false),
              _catalogTab(bundled: true),
              _manualTab(),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 模块卡片的外壳：标题 + 版本 + 标识 + 描述，底部一条分隔线和操作区。
/// 每个模块独占一张卡，比之前挤在一个列表里更容易看清版本与身份。
class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.name,
    required this.adult,
    required this.version,
    required this.id,
    required this.body,
    this.trailing,
    this.actions = const [],
    this.onTap,
  });
  final String name;
  final bool adult;
  final String version;
  final String id;
  final List<Widget> body;
  final Widget? trailing;
  final List<Widget> actions;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.35,
    );
    final footer = actions.isNotEmpty;
    return GroupCard(
      children: [
        InkWell(
          onTap: onTap,
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(18, 14, 12, footer ? 10 : 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DefaultTextStyle.merge(
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontSize: 18,
                            ),
                            child: _ModuleTitle(name, adult: adult),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '版本：${version.isEmpty ? '未标注' : version}',
                            style: meta,
                          ),
                          Text('标识：$id', style: meta),
                          if (body.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            ...body,
                          ],
                        ],
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
              if (footer) ...[
                Divider(
                  height: 1,
                  indent: 18,
                  endIndent: 18,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.6,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                  child: Row(
                    spacing: 8,
                    children: [const Spacer(), ...actions],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

ButtonStyle _cardButton(ColorScheme colors, {bool primary = false}) =>
    FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      backgroundColor: primary ? colors.primaryContainer : null,
      foregroundColor: primary ? colors.onPrimaryContainer : null,
    );

class _InstalledCard extends StatelessWidget {
  const _InstalledCard({
    required this.module,
    required this.update,
    required this.enabled,
    required this.onToggle,
    required this.onDetails,
    required this.onUpdate,
    required this.onUninstall,
  });
  final SourceModule module;
  final ModuleIndexEntry? update;
  final bool enabled;
  final ValueChanged<bool>? onToggle;
  final VoidCallback onDetails;
  final VoidCallback? onUpdate;
  final VoidCallback? onUninstall;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ModuleCard(
      name: module.name,
      adult: module.adult,
      version: module.version,
      id: module.id,
      onTap: onDetails,
      body: [
        if (module.error.isNotEmpty)
          Text(module.error, style: TextStyle(color: colors.error))
        else ...[
          if (module.description.isNotEmpty) Text(module.description),
          if (update case final update?)
            Text(
              '可更新到 ${update.version}',
              style: TextStyle(color: colors.primary),
            ),
        ],
      ],
      trailing: FocusRing(
        radius: 20,
        child: Switch(value: enabled, onChanged: onToggle),
      ),
      actions: [
        if (update != null) ...[
          FocusRing(
            radius: 20,
            child: FilledButton.tonalIcon(
              style: _cardButton(colors, primary: true),
              onPressed: onUpdate,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('更新'),
            ),
          ),
          FocusRing(
            radius: 20,
            child: IconButton.filledTonal(
              visualDensity: VisualDensity.compact,
              tooltip: '卸载',
              onPressed: onUninstall,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ),
        ] else
          FocusRing(
            radius: 20,
            child: FilledButton.tonalIcon(
              style: _cardButton(colors),
              onPressed: onUninstall,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('卸载'),
            ),
          ),
      ],
    );
  }
}

class _IndexCard extends StatelessWidget {
  const _IndexCard({required this.entry, required this.onInstall});
  final ModuleIndexEntry entry;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ModuleCard(
      name: entry.name,
      adult: entry.adult,
      version: entry.version,
      id: entry.id,
      body: [if (entry.description.isNotEmpty) Text(entry.description)],
      trailing: FocusRing(
        radius: 20,
        child: FilledButton.tonalIcon(
          style: _cardButton(colors, primary: true),
          onPressed: onInstall,
          icon: const Icon(Icons.download_rounded),
          label: const Text('安装'),
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
    if (!adult) return Text(text);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Row(
      spacing: 8,
      children: [
        Flexible(child: Text(text)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: colors.errorContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '限制级',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onErrorContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _InstallDialog extends StatelessWidget {
  const _InstallDialog({required this.module, this.details = false});
  final SourceModule module;

  /// 详情模式：已安装模块的卡片点开后只看信息，底部只有「关闭」。
  final bool details;

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
        details
            ? module.name
            : module.installed
            ? '更新 ${module.name}？'
            : '安装 ${module.name}？',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (module.description.isNotEmpty) Text(module.description),
            if (module.error.isNotEmpty)
              section('加载失败', module.error),
            section(
              '版本',
              !details && module.installed
                  ? '${module.previous.isEmpty ? '未标注' : module.previous} → $version'
                  : version,
            ),
            section('标识', module.id),
            if (module.sourceId.isNotEmpty && module.sourceId != module.id)
              section('站源 ID', module.sourceId),
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
        if (details)
          FocusRing(
            radius: 20,
            child: TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          )
        else ...[
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
      ],
    );
  }
}

/// 已安装模块的详情：内容与安装确认一致，但只读。
class _DetailsDialog extends StatelessWidget {
  const _DetailsDialog({required this.module});
  final SourceModule module;

  @override
  Widget build(BuildContext context) =>
      _InstallDialog(module: module, details: true);
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

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Center(child: CircularProgressIndicator()),
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
