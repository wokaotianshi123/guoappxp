import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import 'focus_ring.dart';

Future<void> _toggle(BuildContext context, LocalStore store, Drama drama) =>
    store.toggleFavorite(drama).catchError((Object failure) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$failure')));
      }
    });

/// 长按海报 / 搜索结果的快捷追剧：直接切换追剧状态，底部提示可撤销。
/// 电视端没有长按，桌面上右键等效。
Future<void> quickFollow(
  BuildContext context,
  LocalStore store,
  Drama drama,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final followed = store.isFavorite(drama.id);
  try {
    await store.toggleFavorite(drama);
  } catch (failure) {
    messenger.showSnackBar(SnackBar(content: Text('$failure')));
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          followed ? '已取消追剧「${drama.title}」' : '已追剧「${drama.title}」',
        ),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => store
              .toggleFavorite(drama)
              .catchError(
                (Object failure) =>
                    messenger.showSnackBar(SnackBar(content: Text('$failure'))),
              ),
        ),
      ),
    );
}

class FollowPill extends StatelessWidget {
  const FollowPill({
    super.key,
    required this.store,
    required this.drama,
    this.height = 40,
    this.radius,
    this.onToggled,
    this.focusNode,
  });
  final LocalStore store;
  final Drama drama;
  final double height;
  final double? radius;
  final VoidCallback? onToggled;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final followed = store.isFavorite(drama.id);
      final corner = radius ?? height / 2;
      return FocusRing(
        radius: corner,
        child: FilledButton.tonalIcon(
          key: const ValueKey('follow-toggle'),
          focusNode: focusNode,
          onPressed: () {
            _toggle(context, store, drama);
            onToggled?.call();
          },
          style: FilledButton.styleFrom(
            minimumSize: Size(0, height),
            padding: EdgeInsets.fromLTRB(height / 4, 0, height * 0.35, 0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(corner),
            ),
            iconSize: height * 0.45,
            textStyle: TextStyle(
              fontSize: height >= 44 ? 15 : 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: Icon(
            followed ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          ),
          label: Stack(
            alignment: Alignment.center,
            children: [
              const Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Text('已追剧'),
              ),
              Text(followed ? '已追剧' : '追剧'),
            ],
          ),
        ),
      );
    },
  );
}

class FollowIcon extends StatelessWidget {
  const FollowIcon({
    super.key,
    required this.store,
    required this.drama,
    required this.color,
    required this.activeColor,
    this.size = 24,
    this.extent = 48,
  });
  final LocalStore store;
  final Drama drama;
  final Color color;
  final Color activeColor;
  final double size;
  final double extent;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final followed = store.isFavorite(drama.id);
      return Semantics(
        label: followed ? '已追剧，轻点取消' : '追剧',
        button: true,
        excludeSemantics: true,
        child: IconButton(
          key: const ValueKey('follow-toggle'),
          onPressed: () => _toggle(context, store, drama),
          style: IconButton.styleFrom(fixedSize: Size.square(extent)),
          icon: Icon(
            followed ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
            size: size,
            color: followed ? activeColor : color,
          ),
        ),
      );
    },
  );
}
