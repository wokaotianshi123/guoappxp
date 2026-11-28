import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core_bridge.dart';

/// Python 运行时状态。
class PyRuntimeStatus {
  const PyRuntimeStatus({
    required this.available,
    this.python = '',
    this.detail = '',
  });

  final bool available;
  final String python;
  final String detail;

  String get notReadyMessage =>
      'Python 运行时不可用：当前平台的安装包没有内嵌 CPython。'
      'py 源可以导入和浏览，但不能执行。'
      '${detail.isEmpty ? '' : '（$detail）'}';
}

class PyValidation {
  const PyValidation({
    required this.ok,
    required this.hasSpider,
    required this.missing,
    required this.error,
    this.degraded = false,
  });

  const PyValidation.degraded()
    : ok = true,
      hasSpider = true,
      missing = const [],
      error = '',
      degraded = true;

  final bool ok;
  final bool hasSpider;
  final List<String> missing;
  final String error;
  final bool degraded;

  factory PyValidation.fromJson(Map<String, dynamic> json) => PyValidation(
    ok: json['ok'] == true,
    hasSpider: json['hasSpider'] == true,
    missing: (json['missing'] as List? ?? const [])
        .map((value) => value.toString())
        .toList(),
    error: json['error'] as String? ?? '',
  );
}

/// 平台后端：把「跑 Python」这件事收敛成四个动作。
abstract class PyBackend {
  Future<PyRuntimeStatus> status();
  Future<PyValidation?> validate(String source);
  Future<dynamic> call(String path, Map<String, dynamic> request);
  Future<void> dispose(String path);
  Future<void> disposeAll();
}

/// 不支持的平台。
class _UnavailablePyBackend implements PyBackend {
  const _UnavailablePyBackend(this.reason);
  final String reason;

  @override
  Future<PyRuntimeStatus> status() async =>
      PyRuntimeStatus(available: false, detail: reason);

  @override
  Future<PyValidation?> validate(String source) async => null;

  @override
  Future<dynamic> call(String path, Map<String, dynamic> request) async =>
      throw AppFailure('py 源在当前平台不可用：$reason', code: 'py_unavailable');

  @override
  Future<void> dispose(String path) async {}

  @override
  Future<void> disposeAll() async {}
}

/// Android（Chaquopy）/ iOS（内嵌 CPython）走原生 MethodChannel。
class ChannelPyBackend implements PyBackend {
  static const _channel = MethodChannel('guoapp/py');

  @override
  Future<PyRuntimeStatus> status() async {
    try {
      final raw = await _channel.invokeMethod<String>('status');
      final decoded = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
      if (decoded['available'] == true) {
        return PyRuntimeStatus(
          available: true,
          python: decoded['python'] as String? ?? '',
        );
      }
      return const PyRuntimeStatus(available: false, detail: '桥未报告可用');
    } on MissingPluginException {
      return const PyRuntimeStatus(available: false, detail: '安装包未集成 Python 桥');
    } on PlatformException catch (error) {
      return PyRuntimeStatus(
        available: false,
        detail: error.message ?? '桥启动失败',
      );
    } catch (error) {
      return PyRuntimeStatus(available: false, detail: error.toString());
    }
  }

  @override
  Future<PyValidation?> validate(String source) async {
    try {
      final raw = await _channel.invokeMethod<String>('validate', {'source': source});
      return PyValidation.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw ?? '{}') as Map),
      );
    } on PlatformException catch (error) {
      throw AppFailure('蜘蛛校验失败：${error.message ?? error.code}');
    }
  }

  @override
  Future<dynamic> call(String path, Map<String, dynamic> request) async {
    final raw = await _channel
        .invokeMethod<String>('call', {
          'path': path,
          'request': jsonEncode(request),
        })
        .timeout(const Duration(seconds: 70));
    final decoded = Map<String, dynamic>.from(jsonDecode(raw ?? '{}') as Map);
    if (decoded['ok'] != true) {
      throw AppFailure(
        '${decoded['error'] ?? '未知错误'}',
        code: 'py_exec',
      );
    }
    return decoded['data'];
  }

  @override
  Future<void> dispose(String path) async {
    try {
      await _channel.invokeMethod<String>('dispose', {'path': path});
    } catch (_) {}
  }

  @override
  Future<void> disposeAll() async {
    try {
      await _channel.invokeMethod<String>('disposeAll');
    } catch (_) {}
  }
}

/// Windows / macOS：启动随安装包分发（或系统自带）的 Python，
/// 通过 stdin/stdout 上的行分隔 JSON-RPC 通信。
class ProcessPyBackend implements PyBackend {
  Process? _process;
  StreamSubscription<String>? _lines;
  int _seq = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  PyRuntimeStatus? _status;

  /// 启动中的解释器。首次调用常有多个并发（状态探测 + 目录 + 详情），
  /// 没有这道闸时每个调用都会各起一个 python.exe：后启动的把 `_process`
  /// 与 `_lines` 覆盖掉，先启动那个进程的 stdout 再没人读，它的回复永远
  /// 到不了 `_pending`，请求只能挂到 70 秒超时（Windows 版「加载超时」）。
  Future<Process?>? _starting;

  Future<Process?> _ensure() {
    final existing = _process;
    if (existing != null) return Future.value(existing);
    return _starting ??= _start()
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            throw AppFailure('py 解释器启动超时', code: 'py_start_timeout');
          },
        )
        .whenComplete(() => _starting = null);
  }

  Future<Process?> _start() async {
    final executable = _pythonExecutable();
    final host = _hostScript();
    if (executable == null || host == null) return null;
    try {
      final process = await Process.start(
        executable,
        // -u 关掉缓冲：否则 stdout 是管道时会整块缓冲，回复迟迟不刷出来。
        ['-u', host, '--rpc'],
        workingDirectory: File(host).parent.path,
        // 强制解释器用 UTF-8 做 IO。中文 Windows 的默认编码是 cp936，
        // 路径、日志里的中文都会在管道上互相解错；宿主脚本自己也做了
        // 同样的处理，这里再兜一层，避免环境变量被外部改掉。
        environment: const {
          'PYTHONIOENCODING': 'utf-8',
          'PYTHONUTF8': '1',
        },
      );
      _process = process;
      // allowMalformed：即使某一行混进了非 UTF-8 字节（脚本日志、系统
      // 编码残留），也只坏这一行，不能让整个 stream 抛异常断开——那样后面
      // 所有 RPC 回复都收不到，请求只能挂到超时。
      _lines = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(_onLine);
      process.stderr.drain<void>();
      // 解释器意外退出时，把还在等的请求全部唤醒，避免一路等到超时。
      process.exitCode.then((_) {
        if (!identical(_process, process)) return;
        _process = null;
        final pending = List.of(_pending.entries);
        _pending.clear();
        for (final entry in pending) {
          entry.value.completeError(
            AppFailure('py 运行时已退出', code: 'py_unavailable'),
          );
        }
      });
      return process;
    } catch (_) {
      _process = null;
      return null;
    }
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      final id = decoded['id'];
      if (id is! int) return;
      final completer = _pending.remove(id);
      completer?.complete(Map<String, dynamic>.from(decoded));
    } catch (_) {}
  }

  String? _pythonExecutable() {
    final env = Platform.environment['GUOAPP_PYTHON'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = <String>[
      if (Platform.isWindows) '${exeDir.path}\\python\\python.exe',
      if (Platform.isWindows) '${exeDir.path}\\python\\python3.exe',
    ];
    if (!Platform.isWindows) {
      candidates.addAll(['/usr/bin/python3', '/usr/local/bin/python3', '/opt/homebrew/bin/python3']);
    }
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  String? _hostScript() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = <String>[
      '${exeDir.path}${Platform.pathSeparator}python${Platform.pathSeparator}py_spider_host.py',
      '${exeDir.path}${Platform.pathSeparator}data${Platform.pathSeparator}py_spider_host.py',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  Future<Map<String, dynamic>> _rpc(String method, Map<String, dynamic> params) async {
    final process = await _ensure();
    if (process == null) {
      throw AppFailure('未找到可用的 Python 运行时', code: 'py_unavailable');
    }
    final id = ++_seq;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      process.stdin.writeln(jsonEncode({'id': id, 'method': method, 'params': params}));
    } catch (error) {
      // 管道已断（解释器被系统杀掉等）：立刻失败，不要挂到超时。
      _pending.remove(id);
      _process = null;
      throw AppFailure('py 运行时写入失败：$error', code: 'py_unavailable');
    }
    return completer.future.timeout(
      const Duration(seconds: 70),
      onTimeout: () {
        _pending.remove(id);
        throw AppFailure(
          'py 蜘蛛执行超时（70 秒）。脚本可能在等网络或卡在某个循环里。',
          code: 'py_timeout',
        );
      },
    );
  }

  @override
  Future<PyRuntimeStatus> status() async {
    final cached = _status;
    if (cached != null) return cached;
    try {
      final reply = await _rpc('status', {});
      final data = reply['data'];
      final available = reply['ok'] == true && data is Map && data['available'] == true;
      return _status = PyRuntimeStatus(
        available: available,
        python: data is Map ? (data['python']?.toString() ?? '') : '',
        detail: available ? '' : '内置 Python 未就绪',
      );
    } catch (error) {
      return _status = PyRuntimeStatus(available: false, detail: error.toString());
    }
  }

  @override
  Future<PyValidation?> validate(String source) async {
    final reply = await _rpc('validate', {'source': source});
    final data = reply['data'];
    return data is Map
        ? PyValidation.fromJson(Map<String, dynamic>.from(data))
        : null;
  }

  @override
  Future<dynamic> call(String path, Map<String, dynamic> request) async {
    final reply = await _rpc('call', {'path': path, 'request': request});
    if (reply['ok'] != true) {
      throw AppFailure('${reply['error'] ?? '未知错误'}', code: 'py_exec');
    }
    return reply['data'];
  }

  @override
  Future<void> dispose(String path) async {
    try {
      await _rpc('dispose', {'path': path});
    } catch (_) {}
  }

  @override
  Future<void> disposeAll() async {
    try {
      await _rpc('disposeAll', {});
    } catch (_) {}
  }
}

/// 统一的 Python 桥：状态探测缓存 + 按平台选后端。
class PyBridge {
  PyBridge._();

  static const probeTimeout = Duration(seconds: 10);
  static const negativeStatusTtl = Duration(seconds: 5);

  static PyBackend? _backend;
  static PyRuntimeStatus? _statusCache;
  static DateTime? _statusCachedAt;
  static Future<PyRuntimeStatus>? _statusInflight;

  static PyBackend get backend => _backend ??= _createBackend();

  static PyBackend _createBackend() {
    if (Platform.isAndroid || Platform.isIOS) return ChannelPyBackend();
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return ProcessPyBackend();
    }
    return const _UnavailablePyBackend('当前平台不支持');
  }

  static Future<PyRuntimeStatus> status({bool force = false}) async {
    if (!force && _statusCache != null && _statusCachedAt != null) {
      final cached = _statusCache!;
      final fresh =
          cached.available ||
          DateTime.now().difference(_statusCachedAt!) < negativeStatusTtl;
      if (fresh) return cached;
    }
    final inflight = _statusInflight;
    if (inflight != null) return inflight;
    final future = _probeBounded();
    _statusInflight = future;
    try {
      final result = await future;
      _statusCache = result;
      _statusCachedAt = DateTime.now();
      return result;
    } finally {
      if (identical(_statusInflight, future)) _statusInflight = null;
    }
  }

  static Future<PyRuntimeStatus> _probeBounded() async {
    try {
      return await backend.status().timeout(
        probeTimeout,
        onTimeout: () =>
            const PyRuntimeStatus(available: false, detail: '桥状态探测超时'),
      );
    } catch (error) {
      return PyRuntimeStatus(available: false, detail: error.toString());
    }
  }

  static Future<void> ensureReady() async {
    final value = await status();
    if (!value.available) throw AppFailure(value.notReadyMessage, code: 'py_unavailable');
  }

  static Future<PyValidation?> validate(String source) async {
    final value = await status();
    if (!value.available) return null;
    try {
      return await backend.validate(source).timeout(
        Duration(seconds: 30 + (source.length ~/ (512 * 1024)) * 15),
      );
    } on TimeoutException {
      return const PyValidation.degraded();
    }
  }

  static Future<Map<String, dynamic>> call(
    String path,
    Map<String, dynamic> request,
  ) async {
    await ensureReady();
    final data = await backend.call(path, request);
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  static Future<void> dispose(String path) => backend.dispose(path);
  static Future<void> disposeAll() => backend.disposeAll();
}
