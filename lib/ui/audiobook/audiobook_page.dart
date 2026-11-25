import 'package:flutter/material.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import 'audiobook_screen.dart';

/// 我的 › 听书。
///
/// 听书原来是底部导航的一个一级标签，现在收进「我的」里。内容与功能完全不变
/// （找书 / 书架 / 历史、播放条、下载都在），只是外面补一层页面骨架和标题栏。
/// 这样也顺带解决了首屏问题：听书不再常驻 IndexedStack，不会在启动时抢限流。
class AudiobookPage extends StatelessWidget {
  const AudiobookPage({
    super.key,
    required this.repository,
    required this.store,
  });
  final AppRepository repository;
  final LocalStore store;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('听书')),
    body: AudiobookScreen(
      repository: repository,
      profileId: store.profile.id,
    ),
  );
}
