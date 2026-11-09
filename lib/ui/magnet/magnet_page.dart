import 'package:flutter/material.dart';

import '../../local_store.dart';
import 'magnet_play_tab.dart';
import 'magnet_search_tab.dart';
import 'magnet_sources_tab.dart';

/// 磁力页：一级 Tab 下再分三个横向标签。
/// 「磁力搜索」是原来的多站聚合搜索；「磁力播放」支持粘贴链接直播 +
/// 按磁力站分类浏览；「磁力源管理」参照新增 xbpq 网页源的模式管理搜索源。
class MagnetPage extends StatefulWidget {
  const MagnetPage({super.key, required this.store});

  final LocalStore store;

  @override
  State<MagnetPage> createState() => _MagnetPageState();
}

class _MagnetPageState extends State<MagnetPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  // 源管理里新增/删除后 +1，通知搜索与播放标签重新拉站源清单。
  final ValueNotifier<int> _sitesVersion = ValueNotifier<int>(0);

  @override
  void dispose() {
    _sitesVersion.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('磁力')),
    body: Column(
      children: [
        TabBar(
          controller: _tabs,
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          tabs: const [
            Tab(text: '磁力搜索'),
            Tab(text: '磁力播放'),
            Tab(text: '磁力源管理'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              MagnetSearchTab(
                store: widget.store,
                sitesVersion: _sitesVersion,
              ),
              MagnetPlayTab(
                store: widget.store,
                sitesVersion: _sitesVersion,
              ),
              MagnetSourcesTab(
                onChanged: () => _sitesVersion.value = _sitesVersion.value + 1,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
