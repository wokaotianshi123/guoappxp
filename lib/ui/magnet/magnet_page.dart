import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../app_scope.dart';
import 'magnet_play_tab.dart';
import 'magnet_search_tab.dart';
import 'magnet_sources_tab.dart';

/// 磁力页：一级 Tab 下再分三个横向标签。
/// 「磁力搜索」是原来的多站聚合搜索；「磁力播放」支持粘贴链接直播 +
/// 按磁力站分类浏览；「磁力源管理」参照新增 xbpq 网页源的模式管理搜索源。
///
/// 三个子页都用 [Visibility] + `maintainState` 常驻：在三个标签之间来回切换时，
/// 已加载的分类、结果列表与滚动位置都还在，不会每次都重新拉一遍。
/// 未显示的子页是 offstage 的，既不参与命中测试，也不会被 finder / 读屏软件看到。
/// 同时用 [active] 让子页「第一次被显示时才加载」，避免一进磁力页就并发三个请求。
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
  void initState() {
    super.initState();
    // 切换标签要触发重建，子页的 active 才会跟着变。
    _tabs.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (!_tabs.indexIsChanging && mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _sitesVersion.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = _tabs.index;
    // 电视端外壳顶栏已经有一级「磁力」标签，这里再放一条「磁力」AppBar
    // 属于重复，而且固定吃掉 56px，把下面的分类、列表和「加载更多」挤出
    // 可视区。电视端直接省掉，把高度全留给内容。
    final television = AppScope.of(context).television;
    return Scaffold(
      appBar: television ? null : AppBar(title: const Text('磁力')),
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
            child: Stack(
              children: [
                // 每个子页只在「已经显示过」之后才去加载数据，但一旦显示过就常驻：
                // 切走再切回来不会重新请求，也不会丢滚动位置。
                _pane(
                  index: 0,
                  active: index == 0,
                  child: MagnetSearchTab(
                    store: widget.store,
                    sitesVersion: _sitesVersion,
                    active: index == 0,
                  ),
                ),
                _pane(
                  index: 1,
                  active: index == 1,
                  child: MagnetPlayTab(
                    store: widget.store,
                    sitesVersion: _sitesVersion,
                    active: index == 1,
                  ),
                ),
                _pane(
                  index: 2,
                  active: index == 2,
                  child: MagnetSourcesTab(
                    active: index == 2,
                    onChanged: () =>
                        _sitesVersion.value = _sitesVersion.value + 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 用 Visibility 而不是 IndexedStack：不可见时子页 offstage，既不参与命中
  /// 测试也不被 finder 看到，但 `maintainState` 保证 State 与滚动位置都留着。
  Widget _pane({
    required int index,
    required bool active,
    required Widget child,
  }) => Visibility(
    visible: active,
    maintainState: true,
    maintainAnimation: true,
    maintainSize: false,
    child: child,
  );
}
