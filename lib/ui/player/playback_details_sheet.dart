import 'dart:async';

import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../../playback_session.dart';
import 'episode_grid.dart';
import 'playback_sheets.dart';
import 'player_intro.dart';

/// 竖屏播放器底部面板：「选集」与「简介」共用一个 bottom sheet。
///
/// 竖屏是整屏视频 + 上下滑切集，所以这里刻意不新增任何常驻控件：面板只在
/// 用户点底部条时才出现，两个页签也放在原有标题行里、不额外占高度，
/// 播放层与手势层完全不动。
class PlaybackDetailsSheet extends StatefulWidget {
  const PlaybackDetailsSheet({
    super.key,
    required this.session,
    required this.store,
    required this.canDownload,
    required this.onDownload,
    this.initialTab = 0,
  });

  final PlaybackSession session;
  final LocalStore store;
  final bool canDownload;
  final ValueChanged<List<int>> onDownload;

  /// 0 = 选集（底部条的默认入口），1 = 简介。
  final int initialTab;

  @override
  State<PlaybackDetailsSheet> createState() => _PlaybackDetailsSheetState();
}

class _PlaybackDetailsSheetState extends State<PlaybackDetailsSheet> {
  final _selected = <int>{};
  late int _tab = widget.initialTab;
  bool _selecting = false;

  PlaybackSession get _session => widget.session;

  void _select(bool selecting) => setState(() {
    _selecting = selecting;
    _selected.clear();
  });

  void _switchTab(int tab) => setState(() {
    _tab = tab;
    // 多选态只属于选集页：切到简介时若还留着，PopScope 会误判成不能返回。
    _selecting = false;
    _selected.clear();
  });

  @override
  Widget build(BuildContext context) {
    final episodes = _session.detail.episodes;
    final drama = _session.detail.drama;
    final colors = Theme.of(context).colorScheme;
    final all = _selected.length == episodes.length;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(false);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            children: _selecting
                ? [
                    Expanded(
                      child: Text(
                        '已选 ${_selected.length} 集',
                        style: sheetTitle,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _select(false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        all
                            ? _selected.clear()
                            : _selected.addAll(
                                List.generate(episodes.length, (i) => i),
                              );
                      }),
                      child: Text(all ? '取消全选' : '全选'),
                    ),
                    FilledButton(
                      onPressed: _selected.isEmpty
                          ? null
                          : () {
                              final indexes = _selected.toList()..sort();
                              Navigator.pop(context);
                              widget.onDownload(indexes);
                            },
                      child: const Text('下载'),
                    ),
                  ]
                : [
                    _SheetTab(
                      label: '选集',
                      selected: _tab == 0,
                      onTap: () => _switchTab(0),
                    ),
                    _SheetTab(
                      label: '简介',
                      selected: _tab == 1,
                      onTap: () => _switchTab(1),
                    ),
                    Expanded(
                      child: Text(
                        _tab == 0
                            ? '${_status(drama)}共 ${episodes.length} 集'
                            : '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (widget.canDownload && _tab == 0)
                      IconButton(
                        onPressed: () => _select(true),
                        icon: const Icon(Icons.download_rounded),
                        tooltip: '下载选集',
                      ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                      tooltip: '关闭',
                    ),
                  ],
          ),
          Expanded(
            child: _tab == 1
                ? PlayerIntro(session: _session, store: widget.store)
                : ListenableBuilder(
                    listenable: _session,
                    builder: (context, _) => EpisodeGrid(
                      episodes: episodes,
                      current: _session.index,
                      selecting: _selecting,
                      selected: _selected,
                      touch: true,
                      onSelectionChanged: () => setState(() {}),
                      onPick: (index) {
                        Navigator.pop(context);
                        if (index != _session.index) {
                          unawaited(_session.play(index));
                        }
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

String _status(Drama drama) =>
    drama.releaseLabel == '状态未知' ? '' : '${drama.releaseLabel} · ';

/// 放在既有 SheetHeader 行内的小型页签：不额外增加面板高度。
class _SheetTab extends StatelessWidget {
  const _SheetTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: SizedBox(
        width: 56,
        height: 48,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
              if (selected)
                Positioned(
                  bottom: 4,
                  child: Container(
                    width: 22,
                    height: 3,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(3),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
