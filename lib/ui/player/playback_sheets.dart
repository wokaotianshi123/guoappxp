import 'package:flutter/material.dart';

import '../../cast/cast_controller.dart';
import '../../cast/cast_sheet.dart';
import '../../playback_preferences.dart';
import '../../playback_session.dart';
import '../theme/app_theme.dart';
import 'danmaku_settings.dart';

ThemeData playerTheme(BuildContext context) {
  final theme = Theme.of(context);
  return theme.brightness == Brightness.dark
      ? theme
      : AppTheme.build(
          theme.colorScheme.primary,
          Brightness.dark,
          television: false,
        );
}

Future<void> showPlayerSheet(
  BuildContext context,
  WidgetBuilder builder, {
  bool dark = true,
}) {
  final theme = dark ? playerTheme(context) : Theme.of(context);
  final height = MediaQuery.sizeOf(context).height * .6;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: theme.colorScheme.surfaceContainerLow,
    constraints: BoxConstraints.tightFor(height: height),
    builder: (context) => Theme(
      data: theme,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: theme.colorScheme.onSurface),
        child: Builder(builder: builder),
      ),
    ),
  );
}

class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(spacing: 8, children: children),
    ),
  );
}

const sheetTitle = TextStyle(fontSize: 20, fontWeight: FontWeight.w700);

class PlaybackSettings extends StatelessWidget {
  const PlaybackSettings({
    super.key,
    required this.session,
    required this.onFailure,
    this.showHeader = true,
    this.onClose,
  });
  final PlaybackSession session;
  final VoidCallback onFailure;

  /// 横屏播放器自己带了面板标题栏，这里只要设置项本体。
  final bool showHeader;

  /// 面板里的关闭按钮回调（横屏要点的是关闭侧边面板，不是 Navigator.pop）。
  final VoidCallback? onClose;

  Future<void> _change(Future<void> Function() change) async {
    try {
      await change();
    } catch (_) {
      onFailure();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final label = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
      final list = ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text('倍速', style: label),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final speed in playbackSpeeds)
                _Choice(
                  label: '${speed}x',
                  selected: speed == session.speed,
                  onSelected: () => _change(() => session.setSpeed(speed)),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text('清晰度', style: label),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: session.local
                ? [
                    _Choice(
                      label: session.qualityLabel,
                      selected: true,
                      onSelected: null,
                    ),
                  ]
                : [
                    for (final quality in [...session.qualities, 0])
                      _Choice(
                        label: quality == 0
                            ? (session.quality == 0
                                  ? session.qualityLabel
                                  : '自动')
                            : '${quality}P',
                        selected: quality == session.quality,
                        onSelected: session.ready
                            ? () => _change(() => session.setQuality(quality))
                            : null,
                      ),
                  ],
          ),
          if (!session.local) ...[
            const SizedBox(height: 18),
            Text('播放线路', style: label),
            const SizedBox(height: 4),
            if (session.routeCount <= 1)
              Text('本集只有一条可用线路', style: label)
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '当前第 ${session.routeIndex + 1} / ${session.routeCount} 条，切换后从原进度继续，后续集数沿用这条线路',
                    style: label,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (
                        var route = 0;
                        route < session.routeCount;
                        route += 1
                      )
                        _Choice(
                          label: '线路 ${route + 1}',
                          selected: route == session.routeIndex,
                          onSelected: session.ready
                              ? () => _change(() => session.setRoute(route))
                              : null,
                        ),
                    ],
                  ),
                ],
              ),
            const SizedBox(height: 8),
          ],
          if (CastController.instance.supported) ...[
            const SizedBox(height: 18),
            Text('投屏', style: label),
            const SizedBox(height: 4),
            ListenableBuilder(
              listenable: CastController.instance,
              builder: (context, _) {
                final cast = CastController.instance;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: !session.local,
                  leading: Icon(
                    cast.casting ? Icons.tv_rounded : Icons.cast_rounded,
                  ),
                  title: Text(
                    cast.casting ? (cast.device?.name ?? '投屏设备') : '投屏到电视',
                  ),
                  subtitle: Text(
                    cast.casting
                        ? '${cast.playing ? '正在投屏' : '已暂停'} · '
                              '${cast.relayed ? '经手机转发' : '电视直连，可退出 App'}'
                        : session.local
                        ? '本地文件不支持投屏'
                        : '同一 Wi-Fi 下搜索电视、盒子或投影仪',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: session.local
                      ? null
                      : () => showCastSheet(context, session: session),
                );
              },
            ),
            if (!session.local) const SizedBox(height: 8),
          ],
          if (!session.local) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('去广告'),
              subtitle: Text(session.adBlock ? '解析时尝试跳过源站片头广告' : '直接播放源站原始视频流'),
              value: session.adBlock,
              onChanged: session.ready
                  ? (value) => _change(() => session.setAdBlock(value))
                  : null,
            ),
          ],
          if (session.danmakuSupported) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('弹幕'),
              value: session.danmakuEnabled,
              onChanged: (_) => _change(session.toggleDanmaku),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              shape: const Border(),
              collapsedShape: const Border(),
              leading: const Icon(Icons.text_fields_rounded),
              title: const Text('弹幕样式'),
              subtitle: Text(
                '字号、颜色、透明度与显示区域',
                style: TextStyle(fontSize: 12, color: label.color),
              ),
              children: [
                DanmakuSettings(
                  session: session,
                  onFailure: onFailure,
                  dense: true,
                ),
              ],
            ),
          ],
        ],
      );
      if (!showHeader) return list;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            children: [
              const Expanded(child: Text('播放设置', style: sheetTitle)),
              IconButton(
                onPressed: onClose ?? () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
                tooltip: '关闭',
              ),
            ],
          ),
          Expanded(child: list),
        ],
      );
    },
  );
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onSelected,
  });
  final String label;
  final bool selected;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    selected: selected,
    showCheckmark: false,
    shape: const StadiumBorder(),
    onSelected: onSelected == null ? null : (_) => onSelected!(),
  );
}
