import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../shell/app_shell.dart';
import '../widgets/focus_ring.dart';
import '../widgets/form_text_field.dart';
import '../widgets/group_card.dart';
import '../widgets/page_header.dart';

/// 网盘与订阅：夸克网盘扫码登录 / 分享直解，以及饭太硬 / TVBox 接口订阅。
///
/// 说明：分享列表免登录即可解析；播放需要登录态（cookie 只存本机）。
class NetdiskPage extends StatefulWidget {
  const NetdiskPage({super.key, required this.store});
  final LocalStore store;

  @override
  State<NetdiskPage> createState() => _NetdiskPageState();
}

class _NetdiskPageState extends State<NetdiskPage> {
  final _link = TextEditingController();
  final _tvboxUrl = TextEditingController();
  bool _loading = false;
  bool _loggedIn = false;
  String _status = '';
  String _tvboxSummary = '未订阅饭太硬 / TVBox 接口';
  int _tvboxSupported = 0;
  List<Map<String, dynamic>> _episodes = const [];
  String _shareUrl = '';

  AppRepository get _repository => AppScope.of(context).repository;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshStatus());
  }

  @override
  void dispose() {
    _link.dispose();
    _tvboxUrl.dispose();
    super.dispose();
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _refreshStatus() async {
    try {
      final data = await _repository.netdiskStatus();
      final ready = data['ready'] as Map? ?? const {};
      final tvbox = await _repository.tvboxStatus();
      if (!mounted) return;
      final subUrl = tvbox['url'] as String? ?? '';
      final supported = tvbox['supportedCount'] as int? ?? 0;
      final skipped = tvbox['skippedCount'] as int? ?? 0;
      if (subUrl.isNotEmpty && _tvboxUrl.text.isEmpty) {
        _tvboxUrl.text = subUrl;
      }
      setState(() {
        _loggedIn = ready['quark'] == true;
        _status = _loggedIn ? '夸克已登录' : '夸克未登录';
        _tvboxSupported = supported;
        _tvboxSummary = subUrl.isEmpty
            ? '未订阅饭太硬 / TVBox 接口'
            : '已加载 $supported 个站源${skipped > 0 ? '，跳过 $skipped 个不支持的' : ''}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '$error');
    }
  }

  Future<void> _login() async {
    setState(() => _loading = true);
    try {
      final state = await _repository.netdiskLogin();
      final id = state['id'] as String? ?? '';
      final png = state['qrBase64'] as String? ?? '';
      if (id.isEmpty || png.isEmpty) {
        throw StateError('无法获取登录二维码');
      }
      if (!mounted) return;
      setState(() => _loading = false);
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _QrDialog(
          session: id,
          png: png,
          repository: _repository,
        ),
      );
      if (ok == true) await _refreshStatus();
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _show('$error');
    }
  }

  Future<void> _logout() async {
    await _repository.netdiskLogout('quark');
    await _refreshStatus();
  }

  Future<void> _cleanupTemp() async {
    setState(() => _loading = true);
    try {
      final res = await _repository.netdiskCleanup();
      final deleted = res['deleted'] as int? ?? 0;
      if (!mounted) return;
      setState(() => _loading = false);
      _show('已清理 $deleted 个临时转存文件');
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _show('$error');
    }
  }

  Future<void> _subscribeTVBox() async {
    final url = _tvboxUrl.text.trim();
    if (url.isEmpty) {
      setState(() => _tvboxSummary = '请先填写订阅地址（http/https 开头）');
      return;
    }
    setState(() {
      _loading = true;
      _tvboxSummary = '正在同步订阅…';
    });
    try {
      await _repository.tvboxSubscribe(url);
      await _refreshStatus();
      if (!mounted) return;
      // 结果留在页面上：国内直连失败时那句提示 4 秒就没了，用户没法排查。
      setState(() {
        _loading = false;
        _tvboxSummary = _tvboxSupported > 0
            ? '订阅成功：已注册 $_tvboxSupported 个站源，回到「发现」切换站源即可使用'
            : '订阅成功，但里面没有当前可用的站源（纯 .js / 解析型站点暂不支持）';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _tvboxSummary = '订阅失败：$error';
      });
    }
  }

  Future<void> _clearTVBox() async {
    setState(() => _loading = true);
    try {
      await _repository.tvboxClear();
      _tvboxUrl.clear();
      await _refreshStatus();
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _show('$error');
    }
  }

  Future<void> _parse() async {
    final url = _link.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _loading = true;
      _episodes = const [];
      _shareUrl = url;
    });    try {
      final data = await _repository.netdiskShare(url);
      final rows = (data['episodes'] as List? ?? const [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      if (!mounted) return;
      setState(() {
        _episodes = rows;
        _loading = false;
        _status = rows.isEmpty ? '这个分享里没有可播放的视频' : '共 ${rows.length} 集';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = '$error';
      });
    }
  }

  /// 把分享链接解析成标准剧集，进统一详情页播放（与主播放器打通）。
  Future<void> _openDetail() async {
    final url = _link.text.trim();
    if (url.isEmpty) return;
    await _openDetailFrom(url);
  }

  Future<void> _openDetailFrom(String url) async {
    if (url.isEmpty) return;
    setState(() => _loading = true);
    try {
      final drama = await _repository.netdiskOpenShare(url);
      if (!mounted) return;
      setState(() => _loading = false);
      openPage<void>(
        context,
        (_) => DetailPage(store: widget.store, drama: drama),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _show('$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final television = AppScope.of(context).television;
    return Scaffold(
      appBar: television ? null : AppBar(title: const Text('网盘与订阅')),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (television) const PageHeader(title: '网盘与订阅'),
            if (_loading) const LinearProgressIndicator(minHeight: 3),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  const SectionHeader(title: '夸克网盘账号'),
                  GroupCard(
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            _loggedIn
                                ? Icons.cloud_done_rounded
                                : Icons.cloud_outlined,
                            size: 20,
                            color: _loggedIn
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                        ),
                        title: const Text(
                          '夸克网盘',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(_status.isEmpty ? '正在检查登录态…' : _status),
                        trailing: _loggedIn
                            ? FocusRing(
                                radius: 20,
                                child: TextButton(
                                  onPressed: _logout,
                                  child: const Text('退出登录'),
                                ),
                              )
                            : FocusRing(
                                radius: 20,
                                child: FilledButton(
                                  onPressed: _loading ? null : _login,
                                  child: const Text('扫码登录'),
                                ),
                              ),
                      ),
                      if (_loggedIn)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 12, 10),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: FocusRing(
                              radius: 20,
                              child: TextButton.icon(
                                onPressed: _loading ? null : _cleanupTemp,
                                icon: const Icon(
                                  Icons.cleaning_services_outlined,
                                  size: 16,
                                ),
                                label: const Text('清理临时目录'),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const SectionHeader(title: '饭太硬 / TVBox 接口订阅'),
                  GroupCard(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _tvboxSummary,
                              style: text.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: FormTextField(
                                    controller: _tvboxUrl,
                                    url: true,
                                    autofocus: false,
                                    decoration: const InputDecoration(
                                      hintText: '输入订阅 JSON 地址 (http/https)',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FocusRing(
                                  radius: 20,
                                  child: FilledButton(
                                    onPressed: _loading ? null : _subscribeTVBox,
                                    child: const Text('同步'),
                                  ),
                                ),
                              ],
                            ),
                            if (_tvboxUrl.text.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerRight,
                                child: FocusRing(
                                  radius: 20,
                                  child: TextButton(
                                    onPressed: _loading ? null : _clearTVBox,
                                    child: const Text('清除订阅'),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const SectionHeader(title: '网盘分享链接直解'),
                  GroupCard(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            FormTextField(
                              controller: _link,
                              url: true,
                              autofocus: false,
                              decoration: const InputDecoration(
                                labelText: '粘贴夸克分享链接',
                                hintText: 'https://pan.quark.cn/s/xxxx',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              children: [
                                FocusRing(
                                  radius: 20,
                                  child: FilledButton.icon(
                                    onPressed: _loading ? null : _openDetail,
                                    icon: const Icon(
                                      Icons.play_circle_outline_rounded,
                                    ),
                                    label: const Text('打开剧集详情页播放'),
                                  ),
                                ),
                                FocusRing(
                                  radius: 20,
                                  child: FilledButton.tonalIcon(
                                    onPressed: _loading ? null : _parse,
                                    icon: const Icon(Icons.search_rounded),
                                    label: Text(_loading ? '处理中…' : '解析文件列表'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (_episodes.isNotEmpty) const Divider(height: 1),
                      for (var i = 0; i < _episodes.length; i++) ...[
                        if (i > 0) const Divider(height: 1, indent: 52),
                        ListTile(
                          dense: true,
                          leading: Text('${i + 1}'),
                          title: Text(
                            '${_episodes[i]['name'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(_sizeText(_episodes[i]['size'])),
                          trailing: const Icon(Icons.play_arrow_rounded),
                          onTap: () => _openDetailFrom(_shareUrl),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _sizeText(Object? raw) {
    final size = (raw as num?)?.toDouble() ?? 0;
    if (size <= 0) return '';
    if (size > 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
}

/// 显示二维码并轮询登录结果。
class _QrDialog extends StatefulWidget {
  const _QrDialog({
    required this.session,
    required this.png,
    required this.repository,
  });
  final String session;
  final String png;
  final AppRepository repository;

  @override
  State<_QrDialog> createState() => _QrDialogState();
}

class _QrDialogState extends State<_QrDialog> {
  Timer? _timer;
  String _hint = '用夸克 App 扫码并确认登录';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final state = await widget.repository.netdiskLoginPoll(widget.session);
      final status = state['status'] as String? ?? '';
      if (!mounted) return;
      if (status == 'done') {
        _timer?.cancel();
        Navigator.of(context).pop(true);
        return;
      }
      if (status == 'expired' || status == 'error') {
        _timer?.cancel();
        setState(() => _hint = state['message'] as String? ?? '登录失败，请重试');
        return;
      }
      if (status == 'scanned') {
        setState(() => _hint = '已扫码，正在保存登录态…');
      }
    } catch (_) {
      // 轮询失败不打断，下一轮继续。
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = base64Decode(widget.png);
    return AlertDialog(
      title: const Text('扫码登录夸克网盘'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 240,
            height: 240,
            child: Image.memory(Uint8List.fromList(bytes), fit: BoxFit.contain),
          ),
          const SizedBox(height: 12),
          Text(_hint, textAlign: TextAlign.center),
        ],
      ),
      actions: [
        FocusRing(
          radius: 20,
          child: TextButton(
            autofocus: true,
            onPressed: () {
              _timer?.cancel();
              Navigator.of(context).pop(false);
            },
            child: const Text('取消'),
          ),
        ),
      ],
    );
  }
}
