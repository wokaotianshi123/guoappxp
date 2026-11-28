import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../subscription_models.dart';
// 只用它的 `revealFocus`：把焦点移过去并保证滚动到可见位置。
import '../widgets/focus_ring.dart';

/// 订阅导入的勾选弹层：JS 沙箱与 PY 沙箱共用。
///
/// 三个要点：
/// 1. **逐条勾选 + 全选**：每条一个复选框，顶部一个全选开关；
/// 2. **TV 方向键**：上下在条目间移动，左右在全选 / 取消 / 导入之间移动，
///    不依赖 Flutter 默认的几何遍历（弹层里几何遍历常常跳位）；
/// 3. **防焦点丢失**：任何一次重建后若焦点落在已删除的节点上，立即把焦点
///    拉回列表；弹层被别的路由盖住时不抢焦点。
///
/// 导入过程中的进度显示在右上角标题栏：`已导入 3，剩余 5，共 8`。
class SubscriptionPickerDialog extends StatefulWidget {
  const SubscriptionPickerDialog({
    super.key,
    required this.candidates,
    required this.title,
    this.notice = '',
    this.onImport,
  });

  final List<SubscriptionCandidate> candidates;
  final String title;

  /// 顶部提示（例如「3 条地址越界已跳过」）。
  final String notice;

  /// 实际导入动作。传 null 表示只做勾选（测试用）。
  ///
  /// [isCancelled] 每导入一条前都会被调用一次；返回 true 就立刻停止后续条目。
  /// 这样用户在导入中点「取消」时最多只需等当前这一条结束，不会把剩下的
  /// 全部跑完。
  final Future<SubscriptionImportReport> Function(
    List<SubscriptionCandidate> selected,
    void Function(SubscriptionProgress) onProgress,
    bool Function() isCancelled,
  )?
  onImport;

  @override
  State<SubscriptionPickerDialog> createState() =>
      _SubscriptionPickerDialogState();
}

class _SubscriptionPickerDialogState extends State<SubscriptionPickerDialog> {
  late final Set<int> _selected = {
    for (var index = 0; index < widget.candidates.length; index++) index,
  };

  /// 每条一个焦点节点，全选 / 取消 / 导入各一个。
  late final List<FocusNode> _itemNodes = [
    for (var index = 0; index < widget.candidates.length; index++) FocusNode(),
  ];
  final _allNode = FocusNode(debugLabel: 'subscription-all');
  final _cancelNode = FocusNode(debugLabel: 'subscription-cancel');
  final _confirmNode = FocusNode(debugLabel: 'subscription-confirm');
  final _listScope = FocusNode(debugLabel: 'subscription-list');

  SubscriptionProgress? _progress;
  bool _busy = false;
  String _error = '';

  /// 用户点了取消：后续条目不再开始，当前这一条跑完就收尾。
  bool _cancelled = false;

  bool get _allSelected => _selected.length == widget.candidates.length;
  bool get _noneSelected => _selected.isEmpty;

  @override
  void initState() {
    super.initState();
    // 打开就把焦点放到第一行：TV 上不用先按一次方向键。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_itemNodes.isNotEmpty) {
        revealFocus(_itemNodes.first);
      } else {
        revealFocus(_allNode);
      }
    });
  }

  @override
  void dispose() {
    for (final node in _itemNodes) {
      node.dispose();
    }
    _allNode.dispose();
    _cancelNode.dispose();
    _confirmNode.dispose();
    _listScope.dispose();
    super.dispose();
  }

  void _toggle(int index) {
    if (_busy) return;
    setState(() {
      if (!_selected.remove(index)) _selected.add(index);
    });
  }

  void _toggleAll() {
    if (_busy) return;
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(
            List<int>.generate(widget.candidates.length, (index) => index),
          );
      }
    });
  }

  /// 焦点是否还落在本弹层的某个节点上。
  ///
  /// 弹层重建（例如全选后列表项变化）时，原节点可能已被移除，此时
  /// `primaryFocus` 会变成 null 或指向弹层外的组件，方向键就再也点不动。
  bool _focusInside() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    if (identical(primary, _allNode) ||
        identical(primary, _cancelNode) ||
        identical(primary, _confirmNode)) {
      return true;
    }
    return _itemNodes.any((node) => identical(node, primary));
  }

  /// 焦点丢了就拉回列表第一项（没有条目时回到全选）。
  void _restoreFocus() {
    if (!mounted || _busy) return;
    if (_focusInside()) return;
    if (_itemNodes.isNotEmpty) {
      revealFocus(_itemNodes.first);
    } else {
      revealFocus(_allNode);
    }
  }

  /// 上下键在条目间线性移动，跳过被禁用的按钮。
  ///
  /// 为什么不用默认几何遍历：弹层里条目高度不一致、又混着按钮，几何遍历
  /// 会从最后一条直接跳到「取消」，用户看不到中间项。
  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final index = _itemNodes.indexWhere((item) => identical(item, node));
    if (index < 0) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        if (index + 1 < _itemNodes.length) {
          revealFocus(_itemNodes[index + 1]);
        } else {
          revealFocus(_confirmNode);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (index > 0) {
          revealFocus(_itemNodes[index - 1]);
        } else {
          revealFocus(_allNode);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        revealFocus(_allNode);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        revealFocus(_confirmNode);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  Future<void> _confirm() async {
    if (_busy || _noneSelected || widget.onImport == null) return;
    final chosen = [
      for (var index = 0; index < widget.candidates.length; index++)
        if (_selected.contains(index)) widget.candidates[index],
    ];
    setState(() {
      _busy = true;
      _cancelled = false;
      _error = '';
      _progress = SubscriptionProgress(
        done: 0,
        total: chosen.length,
        name: chosen.isEmpty ? '' : chosen.first.label,
      );
    });
    // 导入期间把焦点留在「取消」上：它是唯一还能用的按钮，
    // 焦点停在会被禁用的「导入」上，TV 遥控器会失去落点。
    revealFocus(_cancelNode);
    try {
      final report = await widget.onImport!(
        chosen,
        (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
        () => _cancelled,
      );
      if (!mounted) return;
      if (report.failed.isEmpty) {
        Navigator.pop(context, report);
        return;
      }
      setState(() {
        _busy = false;
        _error = report.failed.join('；');
        _progress = null;
      });
      _restoreFocus();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
        _progress = null;
      });
      _restoreFocus();
    }
  }

  /// 取消键：导入中先请求停止（当前条跑完即止），再点一次直接关闭弹层。
  ///
  /// 为什么要两级：正在下载的那一条无法从外部打断（HttpClient 在
  /// `importCandidates` 内部），直接 pop 会让它在后台继续写盘、把刚装的
  /// 源写进列表，用户却以为取消了。先停止后续条目是「立刻能用」的做法；
  /// 再点一次强制关闭，是为了应对某一条彻底卡住（比如站点不响应）的情况。
  void _cancel() {
    if (!_busy) {
      Navigator.pop(context);
      return;
    }
    if (!_cancelled) {
      setState(() => _cancelled = true);
      return;
    }
    Navigator.pop(context);
  }

  String get _progressLabel {
    final progress = _progress;
    if (progress == null) return '';
    return '已导入 ${progress.done}，剩余 ${progress.remaining}，共 ${progress.total}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final progress = _progress;
    return PopScope(
      // 导入中按返回键等同于点「停止导入」：先停后续条目，再按一次才关闭。
      // 完全不响应会让人以为界面卡死。
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _cancel();
      },
      child: AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
        title: Row(
          children: [
            Expanded(
              child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (progress != null)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  _progressLabel,
                  key: const ValueKey('subscription-progress'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.notice.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    widget.notice,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                      height: 1.4,
                    ),
                  ),
                ),
              _allRow(theme, colors),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: _itemList(theme, colors),
              ),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('subscription-cancel'),
            focusNode: _cancelNode,
            // 导入中也要能点：这是「防止被卡死」的唯一出口。
            onPressed: _cancel,
            child: Text(_cancelLabel),
          ),
          FilledButton(
            focusNode: _confirmNode,
            onPressed: _busy || _noneSelected ? null : _confirm,
            child: Text(_busy ? '导入中…' : '导入 ${_selected.length} 个'),
          ),
        ],
      ),
    );
  }

  /// 取消键的文案随状态变化，让用户知道这一下会发生什么。
  String get _cancelLabel {
    if (!_busy) return '取消';
    return _cancelled ? '强制关闭' : '停止导入';
  }

  Widget _allRow(ThemeData theme, ColorScheme colors) {
    final focused = _allNode.hasPrimaryFocus;
    return Focus(
      focusNode: _allNode,
      onKeyEvent: (node, event) {
        if (event is KeyUpEvent) return KeyEventResult.ignored;
        switch (event.logicalKey) {
          case LogicalKeyboardKey.arrowDown:
            if (_itemNodes.isNotEmpty) {
              revealFocus(_itemNodes.first);
            } else {
              revealFocus(_confirmNode);
            }
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowRight:
            revealFocus(_confirmNode);
            return KeyEventResult.handled;
          default:
            return KeyEventResult.ignored;
        }
      },
      child: InkWell(
        onTap: _busy ? null : _toggleAll,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: focused
                ? Border.all(color: colors.primary, width: 2)
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Checkbox(
                value: _allSelected,
                tristate: false,
                onChanged: _busy ? null : (_) => _toggleAll(),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _allSelected
                      ? '全选（共 ${widget.candidates.length} 个）'
                      : '全选（已选 ${_selected.length} / ${widget.candidates.length}）',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _itemList(ThemeData theme, ColorScheme colors) {
    if (widget.candidates.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text('订阅里没有可导入的条目'),
      );
    }
    return Focus(
      focusNode: _listScope,
      // 列表容器本身不参与遍历，只用来兜住「焦点丢了」的情况。
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyUpEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _restoreFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: widget.candidates.length,
        itemBuilder: (context, index) {
          final candidate = widget.candidates[index];
          final node = _itemNodes[index];
          final checked = _selected.contains(index);
          final focused = node.hasPrimaryFocus;
          return Focus(
            focusNode: node,
            onKeyEvent: (n, event) => _onListKey(n, event),
            child: InkWell(
              onTap: _busy ? null : () => _toggle(index),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: focused
                      ? Border.all(color: colors.primary, width: 2)
                      : null,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                child: Row(
                  children: [
                    Checkbox(
                      value: checked,
                      onChanged: _busy ? null : (_) => _toggle(index),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            candidate.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            candidate.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
