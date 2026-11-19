import 'package:flutter/material.dart';

import '../../local_store.dart';
import 'sources_view.dart';

/// 自定义XBPQ 页：内置站源的开关 + 自定义源（MacCMS 站点 / XBPQ 规则）的
/// 导入与管理。
///
/// 早前这一页还套着一个「模块」页签，于是模块页变成「我的 › 站源 › 模块 ›
/// 四个页签」的三层嵌套，窗口尺寸变化时内层页签容易失去响应（issue #7）。
/// 模块已经提到「我的 › 自定义模块」独立入口，这一页只留站源本身，不再有
/// 页签，内容与原来「站源与自定义源」完全一致。
class SourcesPage extends StatelessWidget {
  const SourcesPage({super.key, required this.store});
  final LocalStore store;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('自定义XBPQ')),
    body: SourcesView(store: store),
  );
}
