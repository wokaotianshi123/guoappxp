import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_modules.dart';
import '../app_scope.dart';
import '../settings/settings_rows.dart';
import 'module_install.dart';
import '../settings/sorani_account_view.dart';
import '../widgets/bar_button.dart';
import '../widgets/focus_ring.dart';
import '../widgets/form_text_field.dart';
import '../widgets/group_card.dart';

class ModulesPage extends StatefulWidget {
  const ModulesPage({super.key, required this.store});
  final LocalStore store;

  @override
  State<ModulesPage> createState() => _ModulesPageState();
}

/// 没有声明类目的老模块在「已安装」里归到这一段的末尾。
const _unclassified = '未分类';

ModuleIndexEntry? _updateFor(SourceModule module, ModuleIndexEntry? entry) =>
    entry != null &&
        module.error.isEmpty &&
        isNewerModuleVersion(entry.version, module.version)
    ? entry
    : null;

List<SourceModule> _arranged(List<SourceModule> modules, List<String> order) {
  final byId = {for (final module in modules) module.id: module};
  return [for (final id in order) ?byId.remove(id), ...byId.values];
}

Map<String, String> _missingSources(
  LocalStore store,
  AppRepository repository,
) {
  final records = store.missingSourceRecords();
  final downloads = repository.missingSourceDownloads();
  final sources = {
    ...records.follows.keys,
    ...records.history.keys,
    ...downloads.keys,
  }.toList()..sort();
  String describe(String source) => [
    if (records.follows[source] case final count?) '追剧 $count 部',
    if (records.history[source] case final count?) '观看记录 $count 条',
    if (downloads[source] case final count?) '下载 $count 集',
  ].join('，');
  return {for (final source in sources) source: describe(source)};
}

class _ModulesPageState extends State<ModulesPage>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 4, vsync: this)
    ..addListener(_tabChanged);
  List<SourceModule>? _modules;
  List<String>? _moving;
  String? _error;
  ModuleStore? _index;
  String? _indexError;
  ModuleRepositories? _repositories;
  bool _busy = false;

  LocalStore get _store => widget.store;

  AppRepository get _repository => AppScope.of(context).repository;

  /// 模块属于本机内容（装在设备上、谁用谁配），不限制管理员；
  /// locked 表示本地用户配置损坏，那种状态下不允许改动。
  bool get _canInstall => !_store.locked && !_busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _loadIndex();
      _loadRepositories();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _tabChanged() {
    if (!_tabs.indexIsChanging) setState(() {});
  }

  Future<void> _refresh() async {
    try {
      final modules = await _repository.modules();
      if (mounted) {
        setState(() {
          _modules = modules;
          _error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    }
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
      if (mounted) setState(() => _indexError = '$failure');
    }
  }

  Future<void> _loadRepositories() async {
    try {
      final repos = await _repository.moduleRepositories();
      if (mounted) setState(() => _repositories = repos);
    } catch (_) {
      // 在线仓库配置不可用时保持默认视图，不影响其它 tab。
    }
  }

  /// 打开在线仓库管理：增删改切换仓库，保存后刷新配置与商店列表。
  Future<void> _manageRepositories() async {
    final current = _repositories ?? const ModuleRepositories();
    final result = await showDialog<ModuleRepositories>(
      context: context,
      builder: (_) => _RepositoriesDialog(config: current),
    );
    if (result == null) return;
    await _run(() async {
      await _repository.saveModuleRepositories(
        result.repositories,
        result.active,
      );
      _show('在线仓库配置已保存');
    });
    await _loadRepositories();
    await _loadIndex();
  }

  void _show(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } catch (failure) {
      _show('$failure');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _installIndexed(ModuleIndexEntry entry) => _run(
    () async => _install(
      await _repository.prepareModule(
        indexed: entry.id,
        bundled: entry.bundled,
      ),
    ),
  );

  Future<void> _install(SourceModule module) async {
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => _ModuleDialog(module: module, install: true),
    );
    if (accepted != true) return;
    _show(await _applyInstall(module) ?? '${module.name} 已安装');
  }

  Future<String?> _applyInstall(SourceModule module) =>
      applyModuleInstall(_repository, _store, module);

  Future<void> _installAll(List<ModuleIndexEntry> entries) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => BatchInstallDialog(
        entries: entries,
        title: '安装 ${entries.length} 个站源？',
        message: '这些站源会逐个安装并启用。',
      ),
    );
    if (accepted != true) return;
    await _run(
      () async =>
          _show(await installIndexedModules(_repository, _store, entries)),
    );
  }

  Future<void> _installFile() => _run(() async {
    final files = await _pickModuleFiles();
    if (files.isEmpty) return;
    // 每个文件先落到本地可读路径：移动端拿到的可能是内存字节。
    final locations = <String>[];
    for (final file in files) {
      var location = file.path;
      if (location == null) {
        final size = await file.length();
        if (size == null || size > 8 * 1024 * 1024) {
          throw AppFailure('${file.name} 过大或无法读取');
        }
        location = path.join(
          (await getApplicationCacheDirectory()).path,
          'module-picked-${DateTime.now().microsecondsSinceEpoch}.zip',
        );
        await File(location).writeAsBytes(await file.readAsBytes());
      }
      locations.add(location);
    }
    await _installBatch(files: locations);
  });

  /// 选择本地模块安装包。个别设备的系统文件选择器会因存储权限拒绝访问，
  /// 直接抛出的「权限不够」对用户没有指导意义，这里翻译成可操作的提示。
  Future<List<PlatformFile>> _pickModuleFiles() async {
    try {
      return await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        dialogTitle: '选择模块安装包（可多选）',
      );
    } catch (error) {
      throw AppFailure(_filePickerMessage(error));
    }
  }

  String _filePickerMessage(Object error) {
    final text = '$error';
    final lower = text.toLowerCase();
    if (text.contains('权限') ||
        lower.contains('permission') ||
        lower.contains('denied') ||
        lower.contains('access')) {
      return '无法访问文件，请检查存储权限后重试';
    }
    return text;
  }

  Future<void> _installAddress() async {
    final input = await showDialog<_AddressInput>(
      context: context,
      builder: (_) => const _AddressDialog(),
    );
    if (input == null) return;
    final urls = input.urls;
    if (urls.isEmpty) return;
    await _installBatch(urls: urls);
  }

  /// 批量安装：一次把多个文件 / 多个地址交给核心展开并暂存，
  /// 单个 zip 里含多个模块时会被展开成多项，由用户勾选后安装。
  Future<void> _installBatch({
    List<String> files = const [],
    List<String> urls = const [],
  }) async {
    final prepared = await _repository.prepareModules(files: files, urls: urls);
    if (!mounted) return;
    final ready = [
      for (final item in prepared)
        if (item.ok) item,
    ];
    final failed = [
      for (final item in prepared)
        if (!item.ok) item,
    ];
    if (ready.isEmpty) {
      throw AppFailure(
        failed.isEmpty
            ? '没有可安装的模块'
            : '全部失败：${failed.map((item) => '${item.displayName}（${item.error}）').join('；')}',
      );
    }
    final chosen = await showDialog<List<PreparedModule>>(
      context: context,
      builder: (_) => _BatchInstallPreview(items: ready, failures: failed),
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;
    var installed = 0;
    final notices = <String>[];
    final errors = <String>[];
    for (final item in chosen) {
      final module = item.module!;
      try {
        final warning = await _applyInstall(module);
        installed++;
        if (warning != null) notices.add(warning);
      } catch (failure) {
        errors.add('${module.name}：$failure');
      }
    }
    _show(
      [
        '已安装 $installed 个站源',
        if (errors.isNotEmpty) '${errors.length} 个失败：${errors.join('；')}',
        if (failed.isNotEmpty) '${failed.length} 个无法识别',
        if (ready.length > chosen.length)
          '跳过 ${ready.length - chosen.length} 个未勾选',
        ...notices,
      ].join('，'),
    );
  }

  Future<void> _uninstall(SourceModule module) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('卸载 ${module.name}？'),
        content: const Text('该站源的追剧、观看记录和已下载视频会保留，但在重新安装前不再显示，正在下载的集会暂停。'),
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
      if (_repository.supportsDownloads && SourceSite.isAvailable(module.id)) {
        await _repository.controlDownloads('pauseSource', id: module.id);
      }
      await _repository.uninstallModule(module.id);
      _show('${module.name} 已卸载');
    });
  }

  /// 导出模块：ids 为空表示全部用户安装的模块。
  Future<void> _exportModules({List<String> ids = const []}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final export = await _repository.exportModules(ids: ids);
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final name = ids.isEmpty
          ? 'guoapp-modules-$stamp.zip'
          : ids.length == 1
          ? 'guoapp-module-${ids.first}-$stamp.zip'
          : 'guoapp-modules-${ids.length}-$stamp.zip';
      final saved = await FilePicker.saveFile(
        fileName: name,
        bytes: export.bytes,
        mimeType: 'application/zip',
      );
      if (saved != null && mounted) {
        _show('已导出 ${export.count} 个模块到 $saved');
      }
    } catch (failure) {
      _show('$failure');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 选择要导出的模块。返回 null 表示取消。
  Future<List<String>?> _chooseModulesToExport() async {
    final modules = _modules ?? const <SourceModule>[];
    if (modules.isEmpty) {
      _show('还没有安装任何模块');
      return null;
    }
    return showDialog<List<String>>(
      context: context,
      builder: (_) => _ModuleExportPicker(modules: modules),
    );
  }

  /// 恢复默认：删除全部用户安装的模块，内置模块重新装回来。
  Future<void> _resetModules() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => const _ResetModulesDialog(),
    );
    if (accepted != true) return;
    await _run(() async {
      final result = await _repository.resetModules();
      _show('已删除 ${result.removed.length} 个模块，恢复 ${result.bundled} 个内置站源');
    });
  }

  Future<void> _toggle(SourceModule module, bool value) {
    final repository = _repository;
    return saveSetting(context, () async {
      await _store.setSourceEnabled(module.id, value);
      if (!value && repository.supportsDownloads) {
        await repository.controlDownloads('pauseSource', id: module.id);
      }
    });
  }

  Future<void> _details(SourceModule module) => showDialog<void>(
    context: context,
    builder: (_) => _ModuleDialog(module: module, install: false),
  );

  Widget _list(List<Widget> children) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    itemCount: children.length,
    itemBuilder: (_, index) => children[index],
    separatorBuilder: (_, _) => const SizedBox(height: 12),
  );

  Future<void> _reorder(List<SourceModule> modules, int from, int to) async {
    final ids = [for (final module in modules) module.id];
    ids.insert(to, ids.removeAt(from));
    setState(() => _moving = ids);
    await saveSetting(context, () => _store.setSourceOrder(ids));
    if (mounted) setState(() => _moving = null);
  }

  Widget _reorderable(
    List<SourceModule> modules,
    List<Widget> header,
    Widget Function(SourceModule) card,
  ) => ReorderableListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    buildDefaultDragHandles: false,
    header: header.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(spacing: 12, children: header),
          ),
    onReorderItem: (from, to) => _reorder(modules, from, to),
    proxyDecorator: (child, _, animation) => ScaleTransition(
      scale: Tween(begin: 1.0, end: 1.03).animate(animation),
      child: Material(type: MaterialType.transparency, child: child),
    ),
    children: [
      for (final (index, module) in modules.indexed)
        ReorderableDelayedDragStartListener(
          key: ValueKey(module.id),
          index: index,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: card(module),
          ),
        ),
    ],
  );

  Widget _installedTab() {
    final modules = switch (_modules) {
      final loaded? => _arranged(
        loaded,
        _moving ?? [for (final site in SourceSite.allValues) site.id],
      ),
      null => null,
    };
    final enabled = _canInstall;
    final latest = <String, ModuleIndexEntry>{};
    for (final entry in _index?.entries ?? const <ModuleIndexEntry>[]) {
      final current = latest[entry.id];
      if (current == null ||
          isNewerModuleVersion(entry.version, current.version)) {
        latest[entry.id] = entry;
      }
    }
    Widget card(SourceModule module) => _InstalledCard(
      module: module,
      update: _updateFor(module, latest[module.id]),
      enabled: _store.sourceEnabled(module.id),
      onToggle: module.error.isEmpty && SourceSite.isAvailable(module.id)
          ? (value) => _toggle(module, value)
          : null,
      onDetails: () => _details(module),
      onUpdate: enabled ? () => _installIndexed(latest[module.id]!) : null,
      onUninstall: enabled ? () => _uninstall(module) : null,
      onExport: () => _exportModules(ids: [module.id]),
    );
    final header = [if (_error case final error?) _Note(error)];
    if (modules == null) {
      return _list([
        ...header,
        if (_error == null) const _Loading(),
      ]);
    }
    if (modules.isEmpty) {
      return _list([
        ...header,
        const _Note('还没有安装模块。站源以模块的形式提供，可以从在线仓库、内置或手动安装。'),
      ]);
    }
    // 装的模块一多，一长串列表很难找：按清单里的类目分段（短剧类 / 视频类 /
    // 黄果类 / 成人类），没有类目声明的老模块放最后一段。
    final groups = <String, List<SourceModule>>{};
    for (final module in modules) {
      final label = module.classLabel.isEmpty ? _unclassified : module.classLabel;
      (groups[label] ??= []).add(module);
    }
    final labels = groups.keys.toList()
      ..sort((a, b) => _classRank(a).compareTo(_classRank(b)));
    final reorderable =
        modules.length > 1 &&
        _store.profile.admin &&
        !_store.locked &&
        !AppScope.of(context).television;
    // 只有一个类目时不用分段，仍然是可拖动排序的整列表。
    if (labels.length <= 1 && reorderable) {
      return _reorderable(modules, header, card);
    }
    return _list([
      ...header,
      for (final label in labels) ...[
        if (labels.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: SectionHeader(
              title: '$label · ${groups[label]!.length}',
              padding: EdgeInsets.zero,
            ),
          ),
        for (final module in groups[label]!) card(module),
      ],
    ]);
  }

  /// 已安装列表的分段顺序：与站源菜单同一套类目，未分类排最后。
  int _classRank(String label) {
    final order = [
      for (final key in SourceClass.order)
        if (key != SourceClass.xbpq && key != SourceClass.other)
          SourceClass.labelOf(key),
      _unclassified,
    ];
    final index = order.indexOf(label);
    return index < 0 ? order.length : index;
  }

  Widget _catalogTab({required bool bundled}) {
    final enabled = _canInstall;
    final installed = {for (final module in _modules ?? const []) module.id};
    final missing = _missingSources(_store, _repository);
    final warning = bundled ? '' : _index?.warning ?? '';
    final listed = [
      for (final entry in _index?.entries ?? const <ModuleIndexEntry>[])
        if (entry.bundled == bundled) entry,
    ];
    final entries =
        [
          for (final entry in listed)
            if (!installed.contains(entry.id)) entry,
        ]..sort(
          (a, b) => (missing.containsKey(a.id) ? 0 : 1).compareTo(
            missing.containsKey(b.id) ? 0 : 1,
          ),
        );
    final repos = _repositories;
    final activeName =
        repos != null &&
            repos.active >= 0 &&
            repos.active < repos.repositories.length
        ? repos.repositories[repos.active].name
        : '';
    return _list([
      if (!bundled)
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.storefront_outlined,
              title: '在线仓库',
              subtitle: activeName.isEmpty
                  ? '添加 index.json 地址以切换应用商店'
                  : '当前：$activeName · 点击管理 / 切换',
              enabled: enabled,
              onTap: enabled ? _manageRepositories : null,
            ),
          ],
        ),
      if (!bundled && repos?.warning.isNotEmpty == true) _Note(repos!.warning),
      if (warning.isNotEmpty) _Note(warning),
      if (!bundled && entries.isNotEmpty)
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.download_rounded,
              title: '安装全部站源',
              subtitle: '在线仓库里还有 ${entries.length} 个未安装',
              enabled: enabled,
              onTap: enabled ? () => _installAll(entries) : null,
            ),
          ],
        ),
      if (_indexError ?? _error case final error?)
        _Note(error)
      else if (_index == null || _modules == null)
        const _Loading()
      else if (listed.isEmpty && warning.isEmpty)
        _Note(bundled ? '这个安装包没有内置模块。' : '仓库里还没有模块。')
      else if (entries.isEmpty && listed.isNotEmpty)
        _Note(bundled ? '内置模块都已安装。' : '仓库里的模块都已安装。')
      else
        for (final entry in entries)
          _IndexCard(
            entry: entry,
            records: missing[entry.id],
            onInstall: enabled ? () => _installIndexed(entry) : null,
          ),
    ]);
  }

  Widget _manualTab() {
    final enabled = _canInstall;
    final installed = _modules ?? const <SourceModule>[];
    final exportable = installed.isNotEmpty;
    return _list([
      GroupCard(
        children: [
          SettingsTile(
            title: '选择本地文件',
            subtitle: '可多选；合集包内置多个站源，安装时可勾选',
            enabled: enabled,
            onTap: enabled ? _installFile : null,
          ),
        ],
      ),
      GroupCard(
        children: [
          SettingsTile(
            title: '输入下载地址',
            subtitle: '每行一个地址，可一次填多个',
            enabled: enabled,
            onTap: enabled ? _installAddress : null,
          ),
        ],
      ),
      GroupCard(
        children: [
          SettingsTile(
            title: '导出模块',
            subtitle: exportable ? '可导出单个、多个或全部已安装模块' : '还没有可导出的模块',
            enabled: enabled && exportable,
            onTap: enabled && exportable
                ? () async {
                    final ids = await _chooseModulesToExport();
                    if (ids == null) return;
                    await _exportModules(ids: ids);
                  }
                : null,
          ),
        ],
      ),
      GroupCard(
        children: [
          SettingsTile(
            title: '恢复默认模块',
            subtitle: '删除全部已安装模块，只保留安装包内置的站源',
            enabled: enabled,
            onTap: enabled ? _resetModules : null,
          ),
        ],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('自定义模块'),
        actions: [
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
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
        ),
      ),
      body: Column(
        children: [
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
    ),
  );
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.name,
    required this.adult,
    required this.version,
    required this.id,
    required this.body,
    this.group = '',
    this.trailing,
    this.leading = const [],
    this.actions = const [],
    this.onTap,
  });
  final String name;
  final bool adult;
  final String version;
  final String id;

  /// 模块作为站源时的类目名（短剧类 / 视频类 / 黄果类 / 成人类），空则不显示。
  final String group;
  final List<Widget> body;
  final Widget? trailing;
  final List<Widget> leading;
  final List<Widget> actions;
  final VoidCallback? onTap;

  /// 电视端方向键线性遍历卡片内的可聚焦项。
  ///
  /// 卡片的开关在顶行右侧、操作按钮在底行右侧，按钮之间是水平排列。几何遍历
  /// 下「下」从开关能到第一个按钮，但从按钮再按「下」会跳过同排剩余按钮直接
  /// 跳到下一张卡片的开关。这里拦截上下方向键，改用阅读顺序的 next/previous
  /// 逐个移动，左右方向键仍走默认几何遍历，可在按钮之间横向移动。
  static KeyEventResult cardKeyEvent(FocusNode node, KeyEvent event) {
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
    final meta = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.35,
    );
    final footer = leading.isNotEmpty || actions.isNotEmpty;
    final hasMultiple = trailing != null && actions.isNotEmpty;
    final content = InkWell(
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
                      // 分组与站源菜单同一口径，装完就能看出它会落在哪个类目。
                      if (group.isNotEmpty) Text('分组：$group', style: meta),
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
                children: [...leading, const Spacer(), ...actions],
              ),
            ),
          ],
        ],
      ),
    );
    return GroupCard(
      children: [
        if (hasMultiple)
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: cardKeyEvent,
            child: content,
          )
        else
          content,
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
    required this.onExport,
  });
  final SourceModule module;
  final ModuleIndexEntry? update;
  final bool enabled;
  final ValueChanged<bool>? onToggle;
  final VoidCallback onDetails;
  final VoidCallback? onUpdate;
  final VoidCallback? onUninstall;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ModuleCard(
      name: module.name,
      adult: module.adult,
      version: module.version,
      id: module.id,
      group: module.classLabel,
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
      onTap: onDetails,
      leading: [
        if (module.id == 'sorani' && soraniAccountAvailable())
          SoraniAccountButton(style: _cardButton(colors)),
      ],
      actions: [
        FocusRing(
          radius: 20,
          child: IconButton.filledTonal(
            visualDensity: VisualDensity.compact,
            tooltip: '导出这个模块',
            onPressed: onExport,
            icon: const Icon(Icons.save_alt_rounded),
          ),
        ),
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
  const _IndexCard({
    required this.entry,
    required this.records,
    required this.onInstall,
  });
  final ModuleIndexEntry entry;
  final String? records;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ModuleCard(
      name: entry.name,
      adult: entry.adult,
      version: entry.version,
      id: entry.id,
      body: [
        if (entry.description.isNotEmpty) Text(entry.description),
        if (records != null)
          Text('待恢复：$records', style: TextStyle(color: colors.primary)),
      ],
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

class _ModuleDialog extends StatelessWidget {
  const _ModuleDialog({required this.module, required this.install});
  final SourceModule module;
  final bool install;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final version = module.version.isEmpty ? '未标注' : module.version;
    final capabilities = [
      for (final name in module.capabilities)
        if (!moduleBaseCapabilityNames.contains(name) &&
            !moduleIgnoredCapabilityNames.contains(name))
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
        !install
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
            section(
              '版本',
              install && module.installed
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
        if (install) ...[
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
        ] else
          FocusRing(
            radius: 20,
            child: TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ),
      ],
    );
  }
}

/// 地址输入结果：可一次填多个地址，每行一个或用逗号 / 空格分隔。
class _AddressInput {
  const _AddressInput(this.urls);
  final List<String> urls;
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

  /// 支持换行、逗号、空格分隔的多个地址；顺带去掉重复项。
  List<String> get _parsed {
    final seen = <String>{};
    for (final part in _controller.text.split(RegExp(r'[\s,，;；]+'))) {
      final value = part.trim();
      if (value.isNotEmpty) seen.add(value);
    }
    return seen.toList();
  }

  void _submit() {
    final urls = _parsed;
    if (urls.isEmpty) return;
    Navigator.pop(context, _AddressInput(urls));
  }

  @override
  Widget build(BuildContext context) {
    final television = AppScope.of(context).television;
    return AlertDialog(
      title: const Text('从地址安装'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 电视端没有软键盘，FormTextField 会切到原生输入框；
            // 这里与「自定义源」导入保持一致的做法。
            FormTextField(
              controller: _controller,
              autofocus: !television,
              url: true,
              decoration: const InputDecoration(
                labelText: '安装包地址',
                hintText: 'https://…/module.zip',
                helperText: '可一次填多个地址，每行一个；合集包识别后可勾选要安装的模块',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                final count = _parsed.length;
                if (count <= 1) return const SizedBox.shrink();
                return Text(
                  '已识别 $count 个地址',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        FocusRing(
          radius: 20,
          child: TextButton(
            autofocus: television,
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
        FocusRing(
          radius: 20,
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => FilledButton(
              onPressed: _parsed.isEmpty ? null : _submit,
              child: const Text('下一步'),
            ),
          ),
        ),
      ],
    );
  }
}

/// 在线仓库管理：新增 / 编辑 / 删除仓库名+地址，点击条目前圆点切换启用项。
/// 返回最终的仓库配置；返回 null 表示取消。
class _RepositoriesDialog extends StatefulWidget {
  const _RepositoriesDialog({required this.config});
  final ModuleRepositories config;

  @override
  State<_RepositoriesDialog> createState() => _RepositoriesDialogState();
}

class _RepositoriesDialogState extends State<_RepositoriesDialog> {
  late List<ModuleRepository> _items;
  late int _active;

  @override
  void initState() {
    super.initState();
    _items = [
      for (final repo in widget.config.repositories)
        ModuleRepository(name: repo.name, url: repo.url),
    ];
    _active = widget.config.active;
    if (_items.isEmpty) {
      _items = [const ModuleRepository(name: '默认仓库', url: '')];
      _active = 0;
    }
    if (_active < 0 || _active >= _items.length) _active = 0;
  }

  Future<void> _edit(int index) async {
    final existing = _items[index];
    final result = await showDialog<ModuleRepository>(
      context: context,
      builder: (_) => _RepositoryEditDialog(repository: existing),
    );
    if (result == null) return;
    setState(() => _items[index] = result);
  }

  Future<void> _add() async {
    final result = await showDialog<ModuleRepository>(
      context: context,
      builder: (_) => const _RepositoryEditDialog(),
    );
    if (result == null) return;
    setState(() {
      _items.add(result);
    });
  }

  void _remove(int index) {
    if (_items.length <= 1) {
      _showHint('至少保留一个在线仓库');
      return;
    }
    setState(() {
      _items.removeAt(index);
      if (_active >= _items.length) _active = _items.length - 1;
      if (_active < 0) _active = 0;
    });
  }

  void _showHint(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _valid {
    final urls = <String>{};
    for (final repo in _items) {
      if (repo.name.trim().isEmpty || repo.url.trim().isEmpty) return false;
      final uri = Uri.tryParse(repo.url.trim());
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        return false;
      }
      if (!urls.add(repo.url.trim().toLowerCase())) return false;
    }
    return true;
  }

  void _submit() {
    if (!_valid) {
      _showHint('请填写有效的仓库名与 http(s) 地址，且地址不重复');
      return;
    }
    final clean = [
      for (final repo in _items)
        ModuleRepository(name: repo.name.trim(), url: repo.url.trim()),
    ];
    Navigator.pop(
      context,
      ModuleRepositories(repositories: clean, active: _active),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('管理在线仓库'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '点击圆点切换启用的仓库；应用商店会从该地址的 index.json 读取模块列表。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < _items.length; i++)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
                          // 圆点、编辑、删除各成一个焦点站点：电视端左右键在
                          // 同一行内移动，上下键在仓库之间移动。原来整块 ListTile
                          // 是单个焦点节点，按钮落在它的矩形内部，几何遍历永远
                          // 找不到右侧按钮，只能上下跳。
                          child: Row(
                            children: [
                              FocusRing(
                                radius: 20,
                                child: Radio<int>(
                                  value: i,
                                  groupValue: _active,
                                  onChanged: (value) => setState(
                                    () => _active = value ?? _active,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: InkWell(
                                  canRequestFocus: false,
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () => setState(() => _active = i),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 8,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _items[i].name.isEmpty
                                              ? '未命名仓库'
                                              : _items[i].name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _items[i].url.isEmpty
                                              ? '未填写地址'
                                              : _items[i].url,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: _items[i].url.isEmpty
                                                ? colors.error
                                                : colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              FocusRing(
                                radius: 20,
                                child: IconButton(
                                  tooltip: '编辑',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _edit(i),
                                ),
                              ),
                              FocusRing(
                                radius: 20,
                                child: IconButton(
                                  tooltip: '删除',
                                  icon: Icon(
                                    Icons.delete_outline,
                                    color: colors.error,
                                  ),
                                  onPressed: () => _remove(i),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FocusRing(
                radius: 20,
                child: TextButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: const Text('添加仓库'),
                ),
              ),
            ),
          ],
        ),
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
          child: FilledButton(onPressed: _submit, child: const Text('保存')),
        ),
      ],
    );
  }
}

/// 新增 / 编辑单个仓库：仓库名 + index.json 地址。
class _RepositoryEditDialog extends StatefulWidget {
  const _RepositoryEditDialog({this.repository});
  final ModuleRepository? repository;

  @override
  State<_RepositoryEditDialog> createState() => _RepositoryEditDialogState();
}

class _RepositoryEditDialogState extends State<_RepositoryEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.repository?.name ?? '');
    _url = TextEditingController(text: widget.repository?.url ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  bool get _valid {
    if (_name.text.trim().isEmpty || _url.text.trim().isEmpty) return false;
    final uri = Uri.tryParse(_url.text.trim());
    return uri != null &&
        uri.host.isNotEmpty &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }

  void _submit() {
    if (!_valid) return;
    Navigator.pop(
      context,
      ModuleRepository(name: _name.text.trim(), url: _url.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final television = AppScope.of(context).television;
    return AlertDialog(
      title: Text(widget.repository == null ? '添加仓库' : '编辑仓库'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FormTextField(
              controller: _name,
              autofocus: !television,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: '仓库名',
                hintText: '例如：我的应用商店',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FormTextField(
              controller: _url,
              url: true,
              decoration: const InputDecoration(
                labelText: 'index.json 地址',
                hintText: 'https://…/index.json',
                helperText: '填写应用商店的 index.json 完整地址',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        FocusRing(
          radius: 20,
          child: TextButton(
            autofocus: television,
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
        FocusRing(
          radius: 20,
          child: ListenableBuilder(
            listenable: Listenable.merge([_name, _url]),
            builder: (context, _) => FilledButton(
              onPressed: _valid ? _submit : null,
              child: const Text('确定'),
            ),
          ),
        ),
      ],
    );
  }
}

/// 批量安装前的预览：逐项勾选要安装的模块，默认全选；确认后只安装选中的。
/// 返回选中的 PreparedModule 列表，返回 null 表示取消。
class _BatchInstallPreview extends StatefulWidget {
  const _BatchInstallPreview({required this.items, this.failures = const []});

  final List<PreparedModule> items;
  final List<PreparedModule> failures;

  @override
  State<_BatchInstallPreview> createState() => _BatchInstallPreviewState();
}

class _BatchInstallPreviewState extends State<_BatchInstallPreview> {
  final _scroll = ScrollController();
  late final Set<String> _selected = {
    for (final item in widget.items) item.module!.token,
  };

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _allSelected => _selected.length == widget.items.length;

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll({for (final item in widget.items) item.module!.token});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final items = widget.items;
    final failures = widget.failures;
    final adult = items
        .where(
          (item) =>
              item.module!.adult && _selected.contains(item.module!.token),
        )
        .length;
    final selectedCount = _selected.length;
    return AlertDialog(
      title: Text('选择要安装的站源（共 ${items.length} 个）'),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  spacing: 8,
                  children: [
                    FocusRing(
                      radius: 12,
                      child: TextButton.icon(
                        onPressed: _toggleAll,
                        icon: Icon(
                          _allSelected
                              ? Icons.check_box_outline_blank
                              : Icons.check_box,
                          size: 18,
                        ),
                        label: Text(_allSelected ? '全不选' : '全选'),
                      ),
                    ),
                    Text(
                      '已选 $selectedCount / ${items.length}',
                      style: TextStyle(fontSize: 12, color: colors.primary),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: ListView(
                    controller: _scroll,
                    shrinkWrap: true,
                    children: [
                      for (final item in items)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: FocusRing(
                            radius: 12,
                            child: CheckboxListTile(
                              dense: true,
                              value: _selected.contains(item.module!.token),
                              onChanged: (value) => setState(() {
                                if (value == true) {
                                  _selected.add(item.module!.token);
                                } else {
                                  _selected.remove(item.module!.token);
                                }
                              }),
                              title: Text(
                                '${item.module!.name} · ${item.module!.version}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: item.module!.installed
                                  ? Text(
                                      item.module!.previous.isEmpty
                                          ? '已安装'
                                          : '覆盖 ${item.module!.previous}',
                                      style: const TextStyle(fontSize: 12),
                                    )
                                  : null,
                              secondary: item.module!.adult
                                  ? Text(
                                      '限制级',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.error,
                                      ),
                                    )
                                  : null,
                              controlAffinity: ListTileControlAffinity.leading,
                            ),
                          ),
                        ),
                      if (failures.isNotEmpty) ...[
                        const Divider(),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '${failures.length} 项无法识别，将跳过',
                            style: TextStyle(fontSize: 12, color: colors.error),
                          ),
                        ),
                        for (final item in failures)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              '${item.displayName}：${item.error}',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.error,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      if (adult > 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          '包含 $adult 个勾选的限制级站源，安装后默认关闭。',
                          style: TextStyle(fontSize: 12, color: colors.error),
                        ),
                      ],
                    ],
                  ),
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
            onPressed: () => Navigator.pop(context, null),
            child: const Text('取消'),
          ),
        ),
        FocusRing(
          radius: 20,
          child: FilledButton(
            onPressed: selectedCount == 0
                ? null
                : () => Navigator.pop(context, [
                    for (final item in items)
                      if (_selected.contains(item.module!.token)) item,
                  ]),
            child: Text(selectedCount == 0 ? '请勾选模块' : '安装 $selectedCount 个'),
          ),
        ),
      ],
    );
  }
}

/// 选择要导出的模块：可单选、多选，也可一键全选。
class _ModuleExportPicker extends StatefulWidget {
  const _ModuleExportPicker({required this.modules});

  final List<SourceModule> modules;

  @override
  State<_ModuleExportPicker> createState() => _ModuleExportPickerState();
}

class _ModuleExportPickerState extends State<_ModuleExportPicker> {
  late final Set<String> _selected = {
    for (final module in widget.modules) module.id,
  };
  final _scroll = ScrollController();

  bool get _allSelected => _selected.length == widget.modules.length;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导出模块'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Text(
                    '已选 ${_selected.length} / ${widget.modules.length} 个',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                FocusRing(
                  radius: 20,
                  child: TextButton(
                    onPressed: () => setState(() {
                      if (_allSelected) {
                        _selected.clear();
                      } else {
                        _selected
                          ..clear()
                          ..addAll(widget.modules.map((module) => module.id));
                      }
                    }),
                    child: Text(_allSelected ? '全不选' : '全选'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: ListView(
                  controller: _scroll,
                  shrinkWrap: true,
                  children: [
                    for (final module in widget.modules)
                      CheckboxListTile(
                        value: _selected.contains(module.id),
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            _selected.add(module.id);
                          } else {
                            _selected.remove(module.id);
                          }
                        }),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          module.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${module.id} · ${module.version}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '导出的 zip 可以直接在「选择本地文件」里重新导入。',
              style: TextStyle(fontSize: 12),
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
        FocusRing(
          radius: 20,
          child: FilledButton(
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.pop(context, _selected.toList()),
            child: const Text('导出'),
          ),
        ),
      ],
    );
  }
}

/// 恢复默认模块前的确认。
class _ResetModulesDialog extends StatelessWidget {
  const _ResetModulesDialog();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('恢复默认模块？'),
      content: const Text(
        '会删除全部已安装的模块，只保留安装包内置的站源。'
        '各站源的追剧、观看记录和已下载视频会保留。'
        '如果还想留着现在装的模块，请先导出。',
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
            style: FilledButton.styleFrom(backgroundColor: colors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复默认'),
          ),
        ),
      ],
    );
  }
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
