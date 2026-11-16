import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../modules/modules_page.dart';
import 'sources_view.dart';

/// 站源页：把「站源开关 / 自定义源」和「站源模块」收在同一个入口下。
///
/// 原来「模块」是一个独立入口，站源开关藏在设置里，自定义源又要再进一层，
/// 三处都在管同一件事。这里按页签合并，入口改名「站源」。
///
/// 可见性：站源开关、自定义源与模块都属于本机内容（自定义源存在本机、
/// 模块装在设备上），谁用谁配，所有用户都能进，不限制管理员。
class SourcesPage extends StatelessWidget {
  const SourcesPage({super.key, required this.store});
  final LocalStore store;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('站源'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(48),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              unselectedLabelStyle: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              tabs: [
                Tab(text: '站源与自定义源'),
                Tab(text: '模块'),
              ],
            ),
          ),
        ),
      ),
      body: TabBarView(
        children: [SourcesView(store: store), ModulesPage(store: store)],
      ),
    ),
  );
}
