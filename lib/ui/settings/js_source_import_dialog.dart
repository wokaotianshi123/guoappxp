import 'package:flutter/material.dart';

import '../../js_source/js_source_presets.dart';
import '../widgets/focus_ring.dart';

/// 「从网址导入」脚本源的弹层。
///
/// 输入框默认留空：用户可以粘贴任意脚本直链 / 订阅地址，也可以先点内置
/// 订阅（如「小果」）把地址填进来再导入。返回值为最终地址，取消时返回 null。
class JsSourceImportDialog extends StatefulWidget {
  const JsSourceImportDialog({super.key});

  @override
  State<JsSourceImportDialog> createState() => _JsSourceImportDialogState();
}

class _JsSourceImportDialogState extends State<JsSourceImportDialog> {
  final _url = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _apply(PresetJsSubscription preset) {
    setState(() {
      _url.text = preset.url;
      _url.selection = TextSelection.collapsed(offset: preset.url.length);
    });
  }

  void _submit() {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    Navigator.pop(context, url);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('从网址导入'),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '可以填脚本直链（GitHub Raw / Gist / 自建 CDN），也可以填订阅地址：'
              '订阅是一个 JSON，里面列出若干脚本源的名称与地址。地址支持相对写法'
              '（如 ./sub/a.js 或 .\\sub\\a.js），会按订阅所在目录解析。',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
            if (kPresetJsSubscriptions.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('内置订阅（点击填入，仍可手动修改）', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in kPresetJsSubscriptions)
                    _PresetButton(
                      key: ValueKey('js-subscription-${preset.id}'),
                      preset: preset,
                      selected: _url.text.trim() == preset.url,
                      onPressed: () => _apply(preset),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('js-subscription-url'),
              controller: _url,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '脚本或订阅地址',
                hintText: 'https://example.com/source.js',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '内置订阅只填入地址，导入前可以换成自己的镜像或分支。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FocusRing(
          radius: 20,
          child: FilledButton(
            key: const ValueKey('js-subscription-import'),
            onPressed: _submit,
            child: const Text('下载并导入'),
          ),
        ),
      ],
    );
  }
}

class _PresetButton extends StatelessWidget {
  const _PresetButton({
    super.key,
    required this.preset,
    required this.selected,
    required this.onPressed,
  });

  final PresetJsSubscription preset;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: preset.description.isEmpty ? preset.url : preset.description,
      child: FocusRing(
        radius: 999,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            backgroundColor: selected ? colors.primaryContainer : null,
            side: BorderSide(
              color: selected ? colors.primary : colors.outlineVariant,
            ),
          ),
          icon: Icon(
            selected
                ? Icons.check_circle_rounded
                : Icons.cloud_download_rounded,
            size: 18,
          ),
          label: Text(preset.name, style: const TextStyle(fontSize: 13)),
        ),
      ),
    );
  }
}
