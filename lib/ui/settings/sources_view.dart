import 'dart:async';

import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../shell/app_shell.dart';
import '../widgets/focus_ring.dart';
import '../widgets/group_card.dart';
import 'custom_sources_view.dart';
import 'settings_rows.dart';
import 'sorani_account_view.dart';

/// 站源管理：内置源的显示开关 + 自定义源（MacCMS 站点 / XBPQ 规则）管理入口。
///
/// 源显示属于「谁用谁看」的本机偏好，所有用户都能调整，不再要求管理员身份。
/// 每台设备、每个用户各自保存自己的开关状态，互不影响。
class SourcesView extends StatefulWidget {
  const SourcesView({super.key, required this.store});
  final LocalStore store;

  @override
  State<SourcesView> createState() => _SourcesViewState();
}

class _SourcesViewState extends State<SourcesView> {
  var _syncing = false;
  var _synced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_synced) return;
    _synced = true;
    unawaited(_syncCustom());
  }

  /// 自定义源以原生核心为准，这里拉一次同步到本地缓存，
  /// 让源栏、搜索、追剧等处能立刻按真实名称与开关展示。
  Future<void> _syncCustom() async {
    if (_syncing || !mounted) return;
    _syncing = true;
    try {
      final repository = AppScope.of(context).repository;
      await widget.store.syncCustomSources(await repository.customSources());
    } catch (_) {
      // 读取失败不影响内置源开关，页面上自定义源区域会显示为空。
    } finally {
      _syncing = false;
    }
  }

  Future<void> _toggle(String id, bool value, bool downloadable) {
    final repository = AppScope.of(context).repository;
    return saveSetting(context, () async {
      await widget.store.setSourceEnabled(id, value);
      if (!value && downloadable && repository.supportsDownloads) {
        await repository.controlDownloads('pauseSource', id: id);
      }
    });
  }

  Future<void> _openManager() async {
    final repository = AppScope.of(context).repository;
    await openPage<void>(
      context,
      (_) => CustomSourcesPage(repository: repository, store: widget.store),
    );
    if (mounted) unawaited(_syncCustom());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final store = widget.store;
      final customs = store.customSources;
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          SettingsCard(
            children: [
              for (final site in SourceSite.values)
                _SourceTile(
                  title: site.name,
                  subtitle: site.description,
                  enabled: store.sourceEnabled(site.id),
                  onChanged: (value) => _toggle(site.id, value, true),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const _Note(
            '关闭的站源不在发现、搜索、追剧、观看记录和下载中显示，记录保留，重新开启后恢复。正在下载的集会暂停，重新开启后可在下载页继续。',
          ),
          const SizedBox(height: 20),
          const SectionHeader(title: '自定义源', padding: EdgeInsets.zero),
          const SizedBox(height: 8),
          SettingsCard(
            children: [
              if (customs.isNotEmpty)
                for (final site in customs)
                  _SourceTile(
                    title: site.name,
                    subtitle: site.hasRule
                        ? 'XBPQ 规则 · ${site.base}'
                        : site.base,
                    enabled: store.sourceEnabled(site.id),
                    onChanged: (value) => _toggle(site.id, value, false),
                  ),
              SettingsTile(
                icon: Icons.tune_rounded,
                title: '管理自定义源',
                subtitle: customs.isEmpty
                    ? '添加 MacCMS 站点或 XBPQ 爬虫规则'
                    : '共 ${customs.length} 个 · 新增、编辑、导入导出',
                onTap: _openManager,
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _Note(
            '自定义源由你自行添加，支持 MacCMS 规范的站点地址或 XBPQ 爬虫规则 JSON。'
            '所有用户都可以添加、修改和删除，内容保存在本机。',
          ),
        ],
      );
    },
  );
}

/// 站源账号：部分站源（目前是青空次元）要求登录后才能取流。
/// 登录状态保存在本机、对这台设备上的所有用户生效，因此所有用户都能登录或退出。
class SourceAccountsView extends StatelessWidget {
  const SourceAccountsView({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    children: const [
      SettingsCard(children: [SoraniAccountTile()]),
      SizedBox(height: 12),
      _Note('登录状态保存在本机，这台设备上的所有用户共用同一个青空账号。'),
    ],
  );
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onChanged,
  });
  final String title;
  final String subtitle;
  final bool enabled;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: TileFocus(
      builder: (focusNode) => ListTile(
        focusNode: focusNode,
        minTileHeight: 68,
        contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: onChanged == null ? null : () => onChanged!(!enabled),
        trailing: ExcludeFocus(
          child: Switch(value: enabled, onChanged: onChanged),
        ),
      ),
    ),
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
