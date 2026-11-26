import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../download_converter.dart';
import '../../merge_queue.dart';
import '../../download_overview.dart';
import '../../local_store.dart';
import '../app_scope.dart';
import '../../live/live_page.dart';
import '../audiobook/audiobook_page.dart';
import '../downloads/downloads_page.dart';
import '../modules/modules_page.dart';
import '../netdisk/netdisk_page.dart';
import '../settings/js_sandbox_page.dart';
import '../settings/sources_page.dart';
import '../shell/app_shell.dart';
import '../settings/settings_page.dart';
import '../widgets/focus_ring.dart';
import '../widgets/page_header.dart';

class MinePage extends StatelessWidget {
  const MinePage({
    super.key,
    required this.store,
    required this.downloads,
    required this.converter,
    required this.merges,
    required this.entryFocus,
    required this.onExitUp,
  });
  final LocalStore store;
  final DownloadOverview downloads;
  final DownloadConverter converter;
  final MergeQueue merges;
  final FocusNode entryFocus;
  final VoidCallback onExitUp;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) => switch (AppScope.formFactorOf(context)) {
          FormFactor.phone => _phone(context),
          FormFactor.pad || FormFactor.window => _wide(context),
          FormFactor.television => _television(context),
        },
      ),
    ),
  );

  void _openDownloads(BuildContext context) => openPage<void>(
    context,
    (_) => DownloadsPage(
      store: store,
      downloads: downloads,
      converter: converter,
      merges: merges,
    ),
  );

  /// 自定义模块入口：站源模块的安装、更新、导出与在线仓库。模块曾经藏在
  /// 「站源 › 模块」里面，改成和 下载 / 直播 / 设置 平级的独立入口，
  /// 模块页不再套在站源页的页签里（issue #7）。
  void _openModules(BuildContext context) =>
      openPage<void>(context, (_) => ModulesPage(store: store));

  /// 自定义XBPQ 入口：内置站源的开关与自定义源管理。原来这一项叫「站源」，
  /// 还兼着模块商店的入口；模块独立之后按实际内容改名。
  void _openSources(BuildContext context) =>
      openPage<void>(context, (_) => SourcesPage(store: store));

  /// JS 沙箱：导入 / 启用 .js 脚本源。脚本在端侧独立上下文里跑，与内核
  /// 站源完全解耦——与「自定义XBPQ」并列，一个管规则源，一个管脚本源。
  void _openJsSandbox(BuildContext context) =>
      openPage<void>(context, (_) => JsSandboxPage(store: store));

  /// 听书：找书 / 书架 / 历史。原来是底部一级标签，现在收进「我的」，
  /// 功能不变，只是不再常驻首屏。
  void _openAudiobook(BuildContext context) => openPage<void>(
    context,
    (_) => AudiobookPage(
      repository: AppScope.of(context).repository,
      store: store,
    ),
  );

  /// 网盘与订阅：夸克扫码登录、分享直解，以及饭太硬 / TVBox 订阅。
  void _openNetdisk(BuildContext context) =>
      openPage<void>(context, (_) => NetdiskPage(store: store));

  void _openSettings(BuildContext context) =>
      openPage<void>(context, (_) => SettingsPage(store: store));

  Widget _entries(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 12,
    children: _entryWidgets(context),
  );

  /// 「我的」里的入口，顺序即用户看到的自上而下顺序。
  ///
  /// 「最近观看」由页面上方的海报区承担（标题右侧「全部」进完整记录），
  /// 所以这里从「直播」开始，避免出现两个同名入口。
  List<Widget> _entryWidgets(BuildContext context) => [
    _Entry(
      icon: Icons.live_tv_rounded,
      title: '直播',
      onTap: () => unawaited(openLive(context, store: store)),
    ),
    _Entry(
      icon: Icons.headphones_rounded,
      title: '听书',
      onTap: () => _openAudiobook(context),
    ),
    _Entry(
      icon: Icons.extension_outlined,
      title: '自定义模块',
      onTap: () => _openModules(context),
    ),
    _Entry(
      icon: Icons.dns_outlined,
      title: '自定义XBPQ',
      onTap: () => _openSources(context),
    ),
    _Entry(
      icon: Icons.javascript_rounded,
      title: 'JS 沙箱',
      onTap: () => _openJsSandbox(context),
    ),
    _Entry(
      icon: Icons.cloud_outlined,
      title: '网盘与订阅',
      onTap: () => _openNetdisk(context),
    ),
    if (store.canDownload)
      _Entry(
        icon: Icons.download_rounded,
        title: '下载',
        onTap: () => _openDownloads(context),
      ),
    _Entry(
      icon: Icons.settings_outlined,
      title: '设置',
      onTap: () => _openSettings(context),
    ),
  ];

  Widget _phone(BuildContext context) => ListView(
    padding: const EdgeInsets.only(bottom: 24),
    children: [
      const PageHeader(title: '我的'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: _entries(context),
      ),
    ],
  );

  Widget _wide(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - 48;
        return ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const PageHeader(title: '我的'),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  // 宽屏只是把同一份入口列表排成两列，读序仍是行优先。
                  _wideEntries(context, width),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 宽屏下的入口列表：两列行优先排布，顺序与手机端完全一致。
  ///
  /// 这里刻意不用 [CrossAxisAlignment.stretch]：`_wide` 的 Column 处在
  /// ListView 里，垂直方向是无界的，而 Row 的交叉轴正是垂直方向——
  /// stretch 会要求子项高度等于 infinity，直接触发布局断言失败，
  /// 表现为「我的」页只剩最近观看、入口全部消失。用 start 让每行按
  /// 卡片自身的固定高度（60）排布即可。
  Widget _wideEntries(BuildContext context, double width) {
    final twoColumn = width >= 720;
    final entries = _entryWidgets(context);
    if (!twoColumn) return _entries(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final columnWidth = (constraints.maxWidth - gap) / 2;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: gap,
          children: [
            for (var start = 0; start < entries.length; start += 2)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: gap,
                children: [
                  SizedBox(width: columnWidth, child: entries[start]),
                  SizedBox(
                    width: columnWidth,
                    child: start + 1 < entries.length
                        ? entries[start + 1]
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }

  Widget _television(BuildContext context) {
    // 电视模式可以手动开到手机 / 平板（外观 › 显示模式）。这些设备横过来
    // 也可能只有 640~800dp 宽，把 8 个入口固定塞进一行会把图标压成一团、
    // 标题完全看不见。这里按可用宽度算列数：电视上仍然是一整行，窄屏则
    // 自动折成 2~4 列，左右留白也一起收窄。
    final entries = <_TelevisionEntry>[
      _TelevisionEntry(
        icon: Icons.live_tv_rounded,
        primary: true,
        focusNode: entryFocus,
        title: '直播',
        subtitle: '卫视与直播频道',
        onTap: () => unawaited(openLive(context, store: store)),
      ),
      _TelevisionEntry(
        icon: Icons.headphones_rounded,
        title: '听书',
        subtitle: '找书、书架与收听历史',
        onTap: () => _openAudiobook(context),
      ),
      _TelevisionEntry(
        icon: Icons.extension_outlined,
        title: '自定义模块',
        subtitle: '安装、更新与在线仓库',
        onTap: () => _openModules(context),
      ),
      _TelevisionEntry(
        icon: Icons.dns_outlined,
        title: '自定义XBPQ',
        subtitle: '内置站源开关与自定义XBPQ',
        onTap: () => _openSources(context),
      ),
      _TelevisionEntry(
        icon: Icons.javascript_rounded,
        title: 'JS 沙箱',
        subtitle: '导入与启用 .js 脚本源',
        onTap: () => _openJsSandbox(context),
      ),
      _TelevisionEntry(
        icon: Icons.cloud_outlined,
        title: '网盘与订阅',
        subtitle: '夸克登录、分享直解与 TVBox 订阅',
        onTap: () => _openNetdisk(context),
      ),
      if (store.canDownload)
        _TelevisionEntry(
          icon: Icons.download_rounded,
          title: '下载',
          subtitle: '缓存、导出与合并',
          onTap: () => _openDownloads(context),
        ),
      _TelevisionEntry(
        icon: Icons.settings_outlined,
        title: '设置',
        subtitle: '外观、播放、站源与网络',
        onTap: () => _openSettings(context),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 900;
        final horizontal = compact ? 16.0 : televisionInset;
        final contentWidth = constraints.maxWidth - horizontal * 2;
        final safeWidth = contentWidth < 1 ? 1.0 : contentWidth;
        const gap = 20.0;
        final columns = (safeWidth / 210)
            .floor()
            .clamp(1, entries.length)
            .toInt();
        final itemWidth =
            ((safeWidth - gap * (columns - 1)) / columns).floorToDouble();
        final page = SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(horizontal, 14, horizontal, 27),
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final entry in entries)
                SizedBox(width: itemWidth, child: entry),
            ],
          ),
        );
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) {
            if (event is KeyUpEvent ||
                event.logicalKey != LogicalKeyboardKey.arrowUp) {
              return KeyEventResult.ignored;
            }
            final moved = FocusManager.instance.primaryFocus?.focusInDirection(
              TraversalDirection.up,
            );
            if (moved != true) onExitUp();
            return KeyEventResult.handled;
          },
          child: page,
        );
      },
    );
  }

}

class _Entry extends StatelessWidget {
  const _Entry({required this.icon, required this.title, required this.onTap});
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 20,
      child: Material(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 60,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                spacing: 14,
                children: [
                  Icon(icon, size: 22, color: colors.onSurfaceVariant),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TelevisionEntry extends StatelessWidget {
  const _TelevisionEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
    this.focusNode,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 20,
      scale: 1,
      child: Material(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: focusNode,
          focusColor: Colors.transparent,
          onTap: onTap,
          child: SizedBox(
            height: 84,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                spacing: 16,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: primary
                          ? colors.primaryContainer
                          : colors.secondaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      size: primary ? 26 : 24,
                      color: primary
                          ? colors.onPrimaryContainer
                          : colors.onSecondaryContainer,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 2,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

