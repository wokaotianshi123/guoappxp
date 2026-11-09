import 'package:flutter/material.dart';

import '../../download_collections.dart';
import '../../download_overview.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../player/playback_handle.dart';
import '../player/playback_page.dart';
import '../widgets/cover_image.dart';
import '../widgets/focus_ring.dart';
import '../widgets/status_view.dart';
import 'download_actions.dart';

class DownloadedDramaPage extends StatefulWidget {
  const DownloadedDramaPage({
    super.key,
    required this.store,
    required this.downloads,
    required this.drama,
  });
  final LocalStore store;
  final DownloadOverview downloads;
  final Drama drama;

  @override
  State<DownloadedDramaPage> createState() => _DownloadedDramaPageState();
}

class _DownloadedDramaPageState extends State<DownloadedDramaPage> {
  DownloadCollectionUpdater? _updater;
  Set<String>? _selection;
  bool _busy = false;
  bool _playing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updater ??= DownloadCollectionUpdater(
      AppScope.of(context).repository,
      widget.store,
    );
  }

  @override
  void dispose() {
    _updater?.dispose();
    super.dispose();
  }

  void _toggle(String id) => setState(() {
    final selection = {...?_selection};
    if (!selection.remove(id)) selection.add(id);
    _selection = selection;
  });

  Future<void> _fill(Drama drama) async {
    final updater = _updater!;
    final inspection = updater.inspect(drama, widget.downloads.jobs)..ignore();
    final plan = await showDialog<DownloadFill>(
      context: context,
      builder: (context) => _FillDialog(inspection: inspection),
    );
    if (plan == null || !mounted) return;
    await updater.fill(plan);
    if (!mounted) return;
    showMessage(context, updater.error ?? updater.status);
    await widget.downloads.refresh();
  }

  Future<void> _remove(DownloadedDrama item, Set<String> ids) async {
    if (ids.isEmpty ||
        !await confirmRemoval(
          context,
          title: '删除 ${ids.length} 集？',
          message: '视频文件会一起删除。',
          action: '删除',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    final removed = await removeDownloads(context, ids.toList(), done: '已删除');
    await widget.downloads.refresh();
    if (!mounted) return;
    if (removed && ids.length == item.episodes.length) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _selection = null;
      });
    }
  }

  Future<void> _play(DownloadedDrama item, int index) async {
    if (_playing) return;
    _playing = true;
    final episode = item.episodes[index].episode;
    final watch = widget.store.watched(item.drama.id);
    final position = watch?.episode == episode.number && !watch!.finished
        ? watch.position
        : 0.0;
    final handle = PlaybackHandle(
      repository: AppScope.of(context).repository,
      store: widget.store,
      detail: DramaDetail(item.drama, [
        for (final job in item.episodes) job.episode,
      ]),
      index: index,
      position: position,
    );
    handle.session.start(index, position: position);
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaybackPage(store: widget.store, handle: handle),
      ),
    );
    _playing = false;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.store, widget.downloads, _updater]),
    builder: (context, _) {
      final item = downloadedDramas(
        widget.downloads.jobs,
      ).where((entry) => entry.drama.id == widget.drama.id).firstOrNull;
      final selection = item == null
          ? null
          : _selection?.intersection({for (final job in item.episodes) job.id});
      final phone = AppScope.formFactorOf(context) == FormFactor.phone;
      return PopScope(
        canPop: _selection == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _selection = null);
        },
        child: phone
            ? _phone(context, item, selection)
            : _wide(context, item, selection),
      );
    },
  );

  Widget _textButton(String label, VoidCallback? onPressed, {IconData? icon}) =>
      FocusRing(
        radius: 20,
        child: icon == null
            ? TextButton(onPressed: onPressed, child: Text(label))
            : TextButton.icon(
                onPressed: onPressed,
                icon: Icon(icon, size: 18),
                label: Text(label),
              ),
      );

  Widget _fillButton(Drama drama, {bool icon = true}) => _textButton(
    '补齐缺集',
    _updater!.busy || _busy ? null : () => _fill(drama),
    icon: icon ? Icons.refresh_rounded : null,
  );

  Widget _editButton(DownloadedDrama? item, {bool icon = true}) => _textButton(
    '编辑',
    item == null ? null : () => setState(() => _selection = {}),
    icon: icon ? Icons.check_box_outlined : null,
  );

  Widget _selectAll(DownloadedDrama item, Set<String> selection) {
    final all = {for (final job in item.episodes) job.id};
    final everything = selection.length == all.length;
    return _textButton(
      everything ? '取消全选' : '全选',
      () => setState(() => _selection = everything ? {} : all),
    );
  }

  Widget _deleteButton(DownloadedDrama item, Set<String> selection) {
    final colors = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 20,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: colors.error,
          foregroundColor: colors.onError,
        ),
        onPressed: selection.isEmpty || _busy
            ? null
            : () => _remove(item, selection),
        icon: const Icon(Icons.delete_outline_rounded, size: 18),
        label: const Text('删除'),
      ),
    );
  }

  Widget _phone(
    BuildContext context,
    DownloadedDrama? item,
    Set<String>? selection,
  ) {
    final drama = item?.drama ?? widget.drama;
    return Scaffold(
      appBar: selection == null || item == null
          ? AppBar(
              title: Text(drama.title),
              actions: [
                _fillButton(drama, icon: false),
                _editButton(item, icon: false),
                const SizedBox(width: 8),
              ],
            )
          : AppBar(
              leading: IconButton(
                tooltip: '退出编辑',
                onPressed: () => setState(() => _selection = null),
                icon: const Icon(Icons.close_rounded),
              ),
              title: Text('已选择 ${selection.length} 集'),
              actions: [_selectAll(item, selection), const SizedBox(width: 8)],
            ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: _content(context, item, selection, inset: 16),
      ),
      bottomNavigationBar: selection == null || item == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  height: 48,
                  child: _deleteButton(item, selection),
                ),
              ),
            ),
    );
  }

  Widget _wide(
    BuildContext context,
    DownloadedDrama? item,
    Set<String>? selection,
  ) {
    final drama = item?.drama ?? widget.drama;
    final editing = selection != null && item != null;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 24, 8),
              child: SizedBox(
                height: 48,
                child: Row(
                  spacing: 8,
                  children: [
                    if (editing)
                      IconButton(
                        tooltip: '退出编辑',
                        onPressed: () => setState(() => _selection = null),
                        icon: const Icon(Icons.close_rounded),
                      )
                    else
                      const BackButton(),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          editing ? '已选择 ${selection.length} 集' : drama.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    if (editing) ...[
                      _selectAll(item, selection),
                      _deleteButton(item, selection),
                      _textButton(
                        '完成',
                        () => setState(() => _selection = null),
                      ),
                    ] else ...[
                      _fillButton(drama),
                      _editButton(item),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: _content(context, item, selection, inset: 24, lead: 68),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    DownloadedDrama? item,
    Set<String>? selection, {
    required double inset,
    double? lead,
  }) {
    final colors = Theme.of(context).colorScheme;
    final updater = _updater!;
    final header = <Widget>[
      if (item != null)
        Padding(
          padding: EdgeInsets.fromLTRB(lead ?? inset, 4, inset, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SourceTag(item.drama.source),
              Text(
                '已下载 ${item.episodes.length} 集 · ${formatBytes(item.bytes)}'
                '${item.pending > 0 ? ' · 另有 ${item.pending} 集在下载中' : ''}',
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      if (updater.busy)
        Padding(
          padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
          child: Material(
            color: colors.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: Text(
                      updater.status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                  ),
                  _textButton('停止', updater.cancel),
                ],
              ),
            ),
          ),
        ),
    ];
    if (item == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...header,
          const Expanded(
            child: StatusView(
              title: '没有已下载的剧集',
              icon: Icons.download_done_rounded,
            ),
          ),
        ],
      );
    }
    final watched = widget.store.watched(item.drama.id)?.episode;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final width = constraints.maxWidth - inset * 2;
        final columns = ((width + gap) / (inset == 16 ? 160 + gap : 220 + gap))
            .floor()
            .clamp(1, 99);
        return CustomScrollView(
          slivers: [
            SliverList.list(children: header),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 12, inset, 32),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: gap,
                  mainAxisSpacing: gap,
                  mainAxisExtent: 64,
                ),
                itemCount: item.episodes.length,
                itemBuilder: (context, index) {
                  final job = item.episodes[index];
                  return _EpisodeCard(
                    key: ValueKey(job.id),
                    job: job,
                    watching:
                        selection == null && job.episode.number == watched,
                    selected: selection?.contains(job.id),
                    onTap: selection == null
                        ? () => _play(item, index)
                        : () => _toggle(job.id),
                    // 长按 / 右键：直接进多选并选中这一集。
                    onMore: selection == null
                        ? () => setState(() => _selection = {job.id})
                        : null,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FillDialog extends StatelessWidget {
  const _FillDialog({required this.inspection});
  final Future<DownloadFill> inspection;

  Widget _button(
    BuildContext context,
    String label, {
    DownloadFill? result,
    bool primary = false,
  }) => FocusRing(
    radius: 20,
    child: primary
        ? FilledButton(
            onPressed: () => Navigator.pop(context, result),
            child: Text(label),
          )
        : TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, result),
            child: Text(label),
          ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<DownloadFill>(
    future: inspection,
    builder: (context, snapshot) {
      final plan = snapshot.data;
      final Widget content;
      final List<Widget> actions;
      if (snapshot.hasError) {
        content = Text('${snapshot.error}');
        actions = [_button(context, '关闭')];
      } else if (plan == null) {
        content = const Row(
          spacing: 16,
          children: [
            SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            Text('正在读取最新分集…'),
          ],
        );
        actions = [_button(context, '取消')];
      } else {
        final vip = plan.skippedVip > 0
            ? '\n另有 ${plan.skippedVip} 集 VIP，下载设置里没有包含 VIP 集，不会加入。'
            : '';
        content = Text(
          plan.missing == 0
              ? '本剧已全部下载，没有需要补齐的集。$vip'
              : '本剧还有 ${plan.missing} 集没有下载，确认后加入下载。$vip',
        );
        actions = plan.missing == 0
            ? [_button(context, '知道了')]
            : [
                _button(context, '取消'),
                _button(
                  context,
                  '补齐 ${plan.missing} 集',
                  result: plan,
                  primary: true,
                ),
              ];
      }
      return AlertDialog(
        title: const Text('补齐缺集'),
        content: content,
        actions: actions,
      );
    },
  );
}

class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({
    super.key,
    required this.job,
    required this.watching,
    required this.selected,
    required this.onTap,
    this.onMore,
  });
  final DownloadJob job;
  final bool watching;
  final bool? selected;
  final VoidCallback onTap;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final episode = job.episode;
    final meta = job.actualQuality > 0
        ? '${job.actualQuality}P · ${formatBytes(job.bytes)}'
        : formatBytes(job.bytes);
    return Semantics(
      button: true,
      checked: selected,
      label:
          '第 ${episode.number} 集${episode.vip ? '，VIP' : ''}'
          '${watching ? '，看到这里' : ''}，$meta',
      excludeSemantics: true,
      child: FocusRing(
        radius: 14,
        child: Material(
          color: colors.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: selected == true
                ? BorderSide(color: colors.primary, width: 2)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onMore,
            onSecondaryTap: onMore,
            child: Padding(
              padding: EdgeInsets.fromLTRB(selected == null ? 16 : 8, 8, 12, 8),
              child: Row(
                spacing: 8,
                children: [
                  if (selected case final selected?)
                    Checkbox(value: selected, onChanged: (_) => onTap()),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Row(
                          spacing: 6,
                          children: [
                            Text(
                              '第 ${episode.number} 集',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (episode.vip) const VipBadge(),
                            if (watching)
                              Flexible(
                                child: Text(
                                  '看到这里',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: colors.primary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected == null)
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 20,
                        color: colors.onSurface,
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
