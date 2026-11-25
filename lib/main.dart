import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app_device.dart';
import 'boss_key.dart';
import 'core_bridge.dart';
import 'diary_service.dart';
import 'local_files.dart';
import 'js_source/js_source_gateway.dart';
import 'js_source/js_source_service.dart';
import 'local_store.dart';
import 'picture_in_picture.dart';
import 'portable_data.dart';
import 'ui/app.dart';
import 'ui/theme/app_theme.dart';
import 'webview_bridge.dart';
import 'window_frame.dart';
import 'window_on_top.dart';
import 'windows_data_migration.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(AppTheme.systemBars(Brightness.dark));
  }
  if (Platform.isWindows) {
    enablePortableData();
    if (portableDataPath == null) await migrateWindowsData();
    await windowManager.ensureInitialized();
    await rememberWindowFrame();
  }
  if (Platform.isMacOS) {
    await windowManager.ensureInitialized();
    try {
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          size: Size(1280, 800),
          minimumSize: desktopMinimumSize,
          center: true,
        ),
        () async {
          await rememberWindowFrame();
          await windowManager.show();
        },
      );
    } catch (_) {}
  }
  if (Platform.isWindows || Platform.isMacOS) {
    await restoreWindowOnTop();
    await restoreBossKey();
  }
  MediaKit.ensureInitialized();
  final device = await AppDevice.detect();
  final rendering = Platform.isAndroid
      ? ', 渲染: ${await AppDevice.compatibleRendering() ? 'skia' : 'impeller'}'
      : '';
  DiaryService.add(
    '[App] 应用启动，版本: ${device.version}, '
    '平台: ${Platform.operatingSystem}$rendering',
  );
  runApp(AppBootstrap(device: device));
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key, this.device = const AppDevice()});
  final AppDevice device;
  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap>
    with WidgetsBindingObserver {
  final repository = NativeRepository();
  LocalStore? store;
  Object? error;
  late AppDevice device = widget.device;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    DiaryService.add('[App] 生命周期：${state.name}');
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_refreshDevice());
    }
    if (!Platform.isIOS) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
        NativeRepository(
          background: true,
        ).controlDownloads('pauseAll').catchError((Object _) {}),
      );
    }
  }

  Future<void> _refreshDevice() async {
    final detected = await AppDevice.detect(fallback: device);
    if (!mounted ||
        (device.television == detected.television &&
            device.version == detected.version)) {
      return;
    }
    setState(() => device = detected);
  }

  Future<void> _initialize() async {
    setState(() => error = null);
    try {
      final preferences = await SharedPreferences.getInstance();
      await _refreshDevice();
      await repository.initialize();
      // Android 上把 TVBox .jar Spider 插件桥接的端口登记给核心；
      // 其它平台没有 DexClassLoader，这里会直接跳过。
      await WebViewBridge.ensureSpiderBridge(repository);
      final support = await getApplicationSupportDirectory();
      final local = await LocalStore.open(
        preferences,
        LocalFiles(Directory(path.join(support.path, 'store'))),
      );
      // JS 沙箱：装载脚本源并挂成站源。失败不该挡启动——沙箱没有脚本时
      // 只是一类空站源，内核源照常可用。
      try {
        final jsService = JsSourceService();
        await JsSourceGateway.instance.attach(jsService);
        JsSourceService.current ??= jsService;
        // 官方免费短剧是内置主源，首页默认用它。老用户之前存的是模块红果，
        // 这里一次性升到脚本版；用户自己选过别的源则保持不变。
        await local.adoptJsDefaultSource();
      } catch (error) {
        DiaryService.add('[JS] 沙箱初始化失败：$error');
      }
      if (!mounted) return;
      setState(() {
        store = local;
        repository.access = local;
        // 沙箱站源是在 LocalStore 打开之后才挂上的，唤醒一次让源栏重排。
        local.sourcesChanged();
      });
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    }
  }

  @override
  Widget build(BuildContext context) => DuanjuApp(
    repository: repository,
    store: store,
    bootstrapError: error?.toString(),
    onRetry: _initialize,
    television: device.television,
    version: device.version,
  );
}
