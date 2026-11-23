import 'package:flutter/material.dart';

import 'fade_presence.dart';

/// 播放页的线路提示胶囊：切线路、刷新地址时短暂出现。
///
/// 单独做成一个小组件而不是塞进 PlaybackLoading：切线路时旧线路可能还在出图，
/// 画面不该被全屏遮罩挡住，只需要一个轻提示告诉用户「正在换线」。
class PlayerRouteNoticeBadge extends StatelessWidget {
  const PlayerRouteNoticeBadge({
    super.key,
    required this.text,
    this.bottom = 0,
  });

  /// 提示文案；为空时整块淡出。
  final String? text;

  /// 距离父容器底部的距离，横屏 / 竖屏各自的控件避让不同。
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final message = (text ?? '').trim();
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom,
      child: IgnorePointer(
        child: FadePresence(
          child: message.isEmpty
              ? null
              : Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .62),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.swap_horiz_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            message,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
