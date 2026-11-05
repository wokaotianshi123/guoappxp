import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../../playback_session.dart';
import '../widgets/follow_button.dart';

/// 播放器的「简介」面板，横屏侧边栏与竖屏底部面板共用同一份渲染。
///
/// 自己监听 [session]：底部面板是 modal，父页面重建不会重新执行它的
/// builder，面板里的内容得自己跟着 session 通知刷新。
class PlayerIntro extends StatelessWidget {
  const PlayerIntro({
    super.key,
    required this.session,
    required this.store,
  });

  final PlaybackSession session;
  final LocalStore store;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => _body(context),
  );

  Widget _body(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final drama = session.detail.drama;
    final meta = [
      SourceSite.byId(drama.source).name,
      '共 ${session.detail.episodes.length} 集',
      if (drama.releaseLabel != '状态未知') drama.releaseLabel,
      if (drama.category.isNotEmpty) drama.category,
    ];
    final description = drama.description.trim();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  drama.title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            Transform.translate(
              offset: const Offset(8, 0),
              child: FollowIcon(
                store: store,
                drama: drama,
                color: colors.onSurfaceVariant,
                activeColor: colors.primary,
                extent: 44,
              ),
            ),
          ],
        ),
        Text(
          meta.join(' · '),
          style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        Text(
          description.isEmpty ? '暂无简介' : description,
          style: TextStyle(
            fontSize: 14,
            height: 1.6,
            color: description.isEmpty
                ? colors.onSurfaceVariant
                : colors.onSurface,
          ),
        ),
      ],
    );
  }
}
