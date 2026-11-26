package com.guoapp

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterSurfaceView
import android.Manifest
import android.app.UiModeManager
import android.app.ActivityManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.os.Build
import android.os.Bundle
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.res.Resources
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.media.MediaScannerConnection
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Rational
import android.view.InputDevice
import android.view.OrientationEventListener
import android.view.SurfaceHolder
import android.view.WindowManager
import android.provider.Settings
import android.util.Log
import androidx.annotation.ChecksSdkIntAtLeast
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

private const val SURFACE_RESIZE_REDRAW_WAIT_MS = 100L
private const val ORIENTATION_SETTLE_MS = 800L
private const val CREATE_DOCUMENT_REQUEST = 7301
private const val STORAGE_PERMISSION_REQUEST = 7302
private const val PICTURE_IN_PICTURE_ACTION = "com.guoapp.PICTURE_IN_PICTURE_ACTION"

private const val LARGE_CANVAS_DP = 1000f
private const val TARGET_CANVAS_DP = 720f

// 渲染 / 启动安全模式都写在这份 SharedPreferences 里（设置页的「兼容渲染模式」
// 读取的也是它，改键名会让老用户的选择丢失）。
private const val RENDERING_PREFS = "duanju_rendering"
private const val COMPATIBLE_RENDERING_KEY = "compatibleRendering"

// 用户是否在设置里亲手选过渲染方式。电视默认走 Skia，但用户显式关掉之后
// 必须真的回到 Impeller，不能被「电视默认」一直盖住。
private const val RENDERING_CHOICE_KEY = "renderingChoiceMade"
private const val STARTUP_ATTEMPTS_KEY = "startupAttempts"
private const val SAFE_MODE_KEY = "safeMode"
private const val STARTUP_SETTLE_MS = 8000L
private const val STARTUP_LOG_LIMIT = 256 * 1024L

private data class PlayerPictureInPicture(
    val width: Int,
    val height: Int,
    val playing: Boolean,
    val hasPrevious: Boolean,
    val hasNext: Boolean,
    val autoEnter: Boolean
)

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pictureInPicture: PlayerPictureInPicture? = null
    private var pictureInPictureReceiver: BroadcastReceiver? = null
    private var documentResult: MethodChannel.Result? = null
    private var permissionResult: MethodChannel.Result? = null
    private var textInput: TextInputBridge? = null
    private var mediaControls: MediaControls? = null
    private var webViewBridge: WebViewBridge? = null
    private var spiderBridge: SpiderBridge? = null
    private var headroomReadAt = 0L
    private var thermalHeadroom: Double? = null
    private var deviceChannel: MethodChannel? = null
    private var castChannel: MethodChannel? = null
    private var cast: DlnaCast? = null
    private var televisionMode = false
    private var orientationListener: OrientationEventListener? = null
    private var safeMode = false
    private var firstFrameShown = false

    /// 本进程真正使用的渲染方式（启动时定下来，运行中不变）。
    private var skiaActive = false

    private companion object {
        // 同一个进程里 Activity 可能被重建多次（旋转、分屏、从后台回来），
        // 那些都不算「又启动了一次」，否则正常使用也会把计数堆到安全模式。
        @Volatile
        private var startupEvaluated = false

        // 崩溃兜底每个进程只装一次：每次重建都往处理器链上挂一层，
        // 崩一次会重复写多行日志，旧 Activity 也会跟着泄漏。
        @Volatile
        private var crashHandlerInstalled = false
    }

    override fun attachBaseContext(newBase: Context) {
        installCrashHandler(newBase)
        super.attachBaseContext(runCatching { prepareStartup(newBase) }.getOrDefault(newBase))
    }

    /// 记录启动阶段的痕迹。崩溃发生在首帧之前时，这是唯一能带出来的信息。
    ///
    /// 写的是核心（Go）同一份 `files/logs/app.log`，每行一个 JSON：App 的
    /// 「播放调试日记」会把 `android.*` 事件翻成可读行，出问题时也可以直接取
    /// 这个文件。超过 256KB 时轮转成 `app.log.1`（日记两代都读）。
    private fun writeLogLine(base: Context, event: String, message: String) {
        runCatching {
            val directory = File(base.filesDir, "logs").apply { mkdirs() }
            val file = File(directory, "app.log")
            if (file.length() > STARTUP_LOG_LIMIT) {
                val backup = File(directory, "app.log.1")
                backup.delete()
                file.renameTo(backup)
            }
            val line = JSONObject()
                .put("event", event)
                .put(
                    "time",
                    SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).format(Date()),
                )
                .put("message", message)
                .toString()
            file.appendText("$line\n", Charsets.UTF_8)
        }
    }

    private fun startupLog(base: Context, message: String) =
        writeLogLine(base, "android.startup", message)

    /// Java / Kotlin 侧未捕获异常兜底：先落盘再交回系统，方便用户把日志发回来。
    private fun installCrashHandler(base: Context) {
        if (crashHandlerInstalled) return
        crashHandlerInstalled = true
        // 用 applicationContext 落盘，避免处理器一直持有 Activity。
        val app = base.applicationContext ?: base
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            writeLogLine(app, "android.crash", "${thread.name}:\n${Log.getStackTraceString(error)}")
            if (previous != null) {
                previous.uncaughtException(thread, error)
            } else {
                Runtime.getRuntime().halt(10)
            }
        }
    }

    /// 电视盒子 / 电视的 GPU 驱动参差不齐，Impeller 在部分机型上会在首帧前后
    /// 直接把进程带走。这里用启动次数兜底：连续两次没撑过首帧，第三次自动切到
    /// Skia（等同设置里的「兼容渲染模式」），用户至少能进到界面。
    ///
    /// 计数在首帧之后 8 秒清零：启动后就崩的情况仍然算失败，不会因为「画了一帧」
    /// 被误判成启动成功。进入安全模式后把设置项也置为开，界面与实际渲染一致；
    /// 用户手动改设置即视为不再需要兜底。
    private fun prepareStartup(base: Context): Context {
        val prefs = base.getSharedPreferences(RENDERING_PREFS, Context.MODE_PRIVATE)
        // 同一进程的重建只读当前状态，不累加计数。
        if (startupEvaluated) {
            safeMode = prefs.getBoolean(SAFE_MODE_KEY, false) ||
                prefs.getInt(STARTUP_ATTEMPTS_KEY, 0) > 2
            skiaActive = safeMode || prefs.getBoolean(COMPATIBLE_RENDERING_KEY, false)
            return scaleLargeCanvas(base)
        }
        startupEvaluated = true
        val attempts = prefs.getInt(STARTUP_ATTEMPTS_KEY, 0) + 1
        safeMode = prefs.getBoolean(SAFE_MODE_KEY, false) || attempts > 2
        val editor = prefs.edit().putInt(STARTUP_ATTEMPTS_KEY, attempts)
        if (safeMode) {
            editor.putBoolean(SAFE_MODE_KEY, true)
            editor.putBoolean(COMPATIBLE_RENDERING_KEY, true)
        }
        editor.commit()
        // attachBaseContext 阶段 Activity 还没 attach，不能用 isTelevisionDevice()；
        // 电视默认 Skia 会在 getFlutterShellArgs() 里补上。
        skiaActive = safeMode || prefs.getBoolean(COMPATIBLE_RENDERING_KEY, false)
        startupLog(
            base,
            if (safeMode) "启动尝试 #$attempts：进入安全模式（Skia）" else "启动尝试 #$attempts",
        )
        return scaleLargeCanvas(base)
    }

    /// 车机 / 电视 / 投影等 4K~6K 大屏的逻辑短边远超平板，Flutter 按原始 density
    /// 排版会让字号和按钮小到无法阅读、点击。这里只覆盖 density 相关字段，
    /// 把逻辑短边压到接近平板（720dp）；locale / uiMode / fontScale 等沿用
    /// 原配置（不能拿空 Configuration 去建上下文，部分电视 ROM 会因为宽高为 0
    /// 或语言丢失在启动阶段出问题）。
    private fun scaleLargeCanvas(base: Context): Context {
        val config = base.resources.configuration
        val metrics = base.resources.displayMetrics
        if (metrics.density <= 0f || config.densityDpi <= 0) return base
        val shortestDp = minOf(metrics.widthPixels, metrics.heightPixels) / metrics.density
        if (shortestDp <= LARGE_CANVAS_DP) return base
        val targetDpi = (config.densityDpi * shortestDp / TARGET_CANVAS_DP).roundToInt()
        if (targetDpi <= config.densityDpi) return base
        val targetDensity = targetDpi / 160f
        val override = Configuration(config).apply {
            densityDpi = targetDpi
            screenWidthDp = (metrics.widthPixels / targetDensity).roundToInt()
            screenHeightDp = (metrics.heightPixels / targetDensity).roundToInt()
            smallestScreenWidthDp =
                (minOf(metrics.widthPixels, metrics.heightPixels) / targetDensity).roundToInt()
        }
        return base.createConfigurationContext(override)
    }

    @Suppress("DEPRECATION")
    private fun isTelevisionDevice(): Boolean {
        val configuration = resources.configuration
        val mode = (getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)?.currentModeType
            ?: (configuration.uiMode and Configuration.UI_MODE_TYPE_MASK)
        if (mode == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK_ONLY) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION) ||
            packageManager.hasSystemFeature("amazon.hardware.fire_tv")) {
            return true
        }
        if (mode == Configuration.UI_MODE_TYPE_CAR ||
            mode == Configuration.UI_MODE_TYPE_WATCH ||
            mode == Configuration.UI_MODE_TYPE_VR_HEADSET ||
            configuration.touchscreen != Configuration.TOUCHSCREEN_NOTOUCH ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_SENSOR_ACCELEROMETER) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_WATCH) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_PC)) {
            return false
        }
        val remoteNavigation = configuration.navigation == Configuration.NAVIGATION_DPAD ||
            InputDevice.getDeviceIds().any { id ->
                val device = InputDevice.getDevice(id)
                device != null && !device.isVirtual && device.supportsSource(InputDevice.SOURCE_DPAD)
            }
        return remoteNavigation || packageManager.hasSystemFeature(PackageManager.FEATURE_LIVE_TV)
    }

    private fun renderingPreferences() =
        getSharedPreferences(RENDERING_PREFS, Context.MODE_PRIVATE)

    private fun compatibleRendering(): Boolean =
        renderingPreferences().getBoolean(COMPATIBLE_RENDERING_KEY, false)

    /// 这次启动是否应该用 Skia。
    ///
    /// 优先级：安全模式 > 用户显式选择 > 电视默认 Skia。只有用户没亲手选过
    /// 的电视设备才自动切 Skia；选过之后（哪怕是选 Impeller）都尊重设置。
    private fun shouldUseSkia(): Boolean {
        if (safeMode || compatibleRendering()) return true
        if (renderingPreferences().getBoolean(RENDERING_CHOICE_KEY, false)) return false
        return runCatching { televisionMode || isTelevisionDevice() }
            .getOrDefault(televisionMode)
    }

    override fun getFlutterShellArgs(): FlutterShellArgs {
        val args = super.getFlutterShellArgs()
        // 电视默认关掉 Impeller：部分电视盒子的 Vulkan / GLES 驱动会在首帧直接
        // 崩进程，而崩在启动阶段时用户根本没有机会去设置里打开兼容渲染。
        // 仍保留设置项：非电视设备可以手动开，进入过安全模式的设备会自动开。
        skiaActive = shouldUseSkia()
        if (skiaActive) args.add("--enable-impeller=false")
        return args
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        firstFrameShown = true
        startupLog(
            this,
            "首帧显示：${if (skiaActive) "Skia" else "Impeller"}${if (safeMode) "（安全模式）" else ""}",
        )
        // 首帧之后还要再活 8 秒才算启动成功，避免「闪一下再崩」被清掉计数。
        mainHandler.postDelayed({
            if (isFinishing || isDestroyed) return@postDelayed
            clearStartupAttempts("启动稳定")
        }, STARTUP_SETTLE_MS)
    }

    override fun onStop() {
        super.onStop()
        // 已经画出首帧、并且正常走到后台：这是用户在用它，不是启动失败。
        // 否则开了就退（或切走）两次也会被误算成崩溃，平白进安全模式。
        if (firstFrameShown) clearStartupAttempts("退到后台")
    }

    private fun clearStartupAttempts(reason: String) {
        val prefs = renderingPreferences()
        if (prefs.getInt(STARTUP_ATTEMPTS_KEY, 0) == 0) return
        prefs.edit().putInt(STARTUP_ATTEMPTS_KEY, 0).apply()
        startupLog(this, "$reason，清除崩溃计数")
    }

    private fun restartApplication() {
        startActivity(Intent.makeRestartActivityTask(ComponentName(this, MainActivity::class.java)))
        Runtime.getRuntime().exit(0)
    }

    override fun setRequestedOrientation(requestedOrientation: Int) {
        super.setRequestedOrientation(
            if (televisionMode) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else requestedOrientation
        )
    }

    private fun setPlayerOrientation(mode: String) {
        orientationListener?.disable()
        orientationListener = null
        val landscape = mode == "landscape"
        requestedOrientation = when (mode) {
            "landscape", "lockedLandscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            "lockedPortrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
        if (!landscape && mode != "portrait") return
        val listener = object : OrientationEventListener(this) {
            private var reachedAt = 0L

            override fun onOrientationChanged(angle: Int) {
                if (angle == ORIENTATION_UNKNOWN) return
                val reached = if (landscape) angle in 60..120 || angle in 240..300
                    else angle <= 30 || angle >= 330
                val rotation = Settings.System.getInt(
                    contentResolver, Settings.System.ACCELEROMETER_ROTATION, 0
                )
                if (!reached || rotation != 1) {
                    reachedAt = 0L
                    return
                }
                val now = SystemClock.uptimeMillis()
                if (reachedAt == 0L) reachedAt = now
                if (now - reachedAt < ORIENTATION_SETTLE_MS) return
                disable()
                orientationListener = null
                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            }
        }
        if (listener.canDetectOrientation()) {
            listener.enable()
            orientationListener = listener
        }
    }

    private fun battery(): Map<String, Any>? {
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null
        val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0) return null
        val status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return mapOf(
            "level" to level * 100 / scale,
            "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL)
        )
    }

    private fun playbackPower(): Map<String, Any?> {
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
        val activity = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val now = SystemClock.elapsedRealtime()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            (headroomReadAt == 0L || now - headroomReadAt >= 10000L)) {
            headroomReadAt = now
            thermalHeadroom = runCatching {
                power?.getThermalHeadroom(0)?.toDouble()?.takeIf { it.isFinite() }
            }.getOrNull()
        }
        val thermalStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            power?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE
        } else 0
        return mapOf(
            "batterySaver" to (power?.isPowerSaveMode ?: false),
            "onBattery" to ((battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1) <= 0),
            "thermalStatus" to thermalStatus,
            "headroom" to thermalHeadroom,
            "lowMemory" to (activity?.isLowRamDevice ?: true),
            "gles" to (activity?.deviceConfigurationInfo?.reqGlEsVersion ?: 0)
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        televisionMode = if (savedInstanceState?.containsKey("duanju.televisionMode") == true) {
            savedInstanceState.getBoolean("duanju.televisionMode")
        } else isTelevisionDevice()
        super.onCreate(savedInstanceState)
        if (televisionMode) requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        if (pictureInPictureSupported()) registerPictureInPictureReceiver()
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun registerPictureInPictureReceiver() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val action = intent.getStringExtra("action") ?: return
                deviceChannel?.invokeMethod("pictureInPictureAction", mapOf("action" to action))
            }
        }
        val filter = IntentFilter(PICTURE_IN_PICTURE_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }
        pictureInPictureReceiver = receiver
    }

    override fun onDestroy() {
        pictureInPictureReceiver?.let { unregisterReceiver(it) }
        pictureInPictureReceiver = null
        super.onDestroy()
    }

    override fun onFlutterSurfaceViewCreated(flutterSurfaceView: FlutterSurfaceView) {
        super.onFlutterSurfaceViewCreated(flutterSurfaceView)
        flutterSurfaceView.holder.addCallback(SurfaceResizeRedrawWait())
    }

    private class SurfaceResizeRedrawWait : SurfaceHolder.Callback2 {
        private val handler = Handler(Looper.getMainLooper())
        private var size: Pair<Int, Int>? = null
        private var resized = false

        override fun surfaceCreated(holder: SurfaceHolder) {}

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            val next = width to height
            resized = size != null && size != next
            size = next
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            size = null
            resized = false
        }

        override fun surfaceRedrawNeeded(holder: SurfaceHolder) {}

        override fun surfaceRedrawNeededAsync(holder: SurfaceHolder, drawingFinished: Runnable) {
            if (!resized) return drawingFinished.run()
            resized = false
            handler.postDelayed(drawingFinished, SURFACE_RESIZE_REDRAW_WAIT_MS)
        }
    }

    override fun onResume() {
        super.onResume()
        if (televisionMode) requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("duanju.televisionMode", televisionMode)
        super.onSaveInstanceState(outState)
    }

    /// 桥接对象构造失败的兜底：记一条启动日志，返回 null，不让一个可选功能
    /// 把整个启动流程带走。
    private fun <T : Any> startupBridge(name: String, block: () -> T): T? =
        runCatching(block).onFailure { error ->
            Log.w("guoapp", "$name 初始化失败", error)
            startupLog(this, "$name 初始化失败：${Log.getStackTraceString(error)}")
        }.getOrNull()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        textInput = startupBridge("文本输入") {
            TextInputBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        }
        mediaControls = startupBridge("媒体通知") {
            MediaControls(this, flutterEngine.dartExecutor.binaryMessenger)
        }
        // 人机验证与 TVBox .jar Spider 桥接：只在 Android 上可用。
        webViewBridge = startupBridge("网页验证") {
            WebViewBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        }
        spiderBridge = startupBridge("Spider") {
            SpiderBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        }
        // 投屏（DLNA）：Flutter 侧只负责选设备与按钮，搜索 / SOAP 下发都在
        // DlnaCast 的单线程里跑，网络耗时不能占主线程。
        val dlna = startupBridge("投屏") { DlnaCast(applicationContext) }
        cast = dlna
        castChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "duanju/cast")
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    val controller = dlna
                    if (controller == null) {
                        result.error("cast_unavailable", "投屏模块未初始化", null)
                        return@setMethodCallHandler
                    }
                    when (call.method) {
                        "discover" -> controller.discover { devices, error ->
                            result.success(
                                mapOf(
                                    "devices" to devices.map { it.toMap() },
                                    "error" to error
                                )
                            )
                        }
                        "play" -> {
                            val control = call.argument<String>("controlUrl").orEmpty()
                            val url = call.argument<String>("url").orEmpty()
                            val title = call.argument<String>("title").orEmpty()
                            val position = call.argument<Number>("positionMs")?.toLong() ?: 0L
                            // 直连投屏电视自己拉流，只有转发才需要手机保持唤醒。
                            val relay = call.argument<Boolean>("relay") ?: false
                            if (control.isEmpty() || url.isEmpty()) {
                                result.error("invalid_cast", "缺少投屏设备或播放地址", null)
                            } else {
                                controller.play(control, url, title, position, relay) { ok, message ->
                                    if (ok) result.success(null)
                                    else result.error("cast_failed", message, null)
                                }
                            }
                        }
                        "control" -> {
                            val control = call.argument<String>("controlUrl").orEmpty()
                            val command = call.argument<String>("command").orEmpty()
                            if (control.isEmpty() || command.isEmpty()) {
                                result.error("invalid_cast", "缺少投屏设备或操作", null)
                            } else {
                                controller.control(control, command) { ok, message ->
                                    if (ok) result.success(null)
                                    else result.error("cast_failed", message, null)
                                }
                            }
                        }
                        "status" -> {
                            val control = call.argument<String>("controlUrl").orEmpty()
                            if (control.isEmpty()) {
                                result.success(mapOf("state" to "UNKNOWN"))
                            } else {
                                controller.status(control) { state -> result.success(state) }
                            }
                        }
                        "close" -> {
                            controller.close()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        deviceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "duanju/device")
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "deviceInfo" -> {
                            val version = packageManager.getPackageInfo(packageName, 0).versionName
                            result.success(mapOf("television" to isTelevisionDevice(), "version" to version))
                        }
                        "setTelevisionMode" -> {
                            val enabled = call.argument<Boolean>("enabled")
                            if (enabled == null) {
                                result.error("invalid_display_mode", "缺少电视模式状态", null)
                            } else {
                                val changed = televisionMode != enabled
                                televisionMode = enabled
                                if (enabled || changed) {
                                    requestedOrientation = if (enabled) {
                                        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                    } else ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                                }
                                result.success(null)
                            }
                        }
                        "setPlayerOrientation" -> {
                            setPlayerOrientation(call.argument<String>("mode") ?: "auto")
                            result.success(null)
                        }
                        "battery" -> result.success(runCatching { battery() }.getOrNull())
                        "playbackPower" -> result.success(runCatching { playbackPower() }.getOrNull())
                        "compatibleRendering" -> result.success(skiaActive)
                        "setCompatibleRendering" -> {
                            val enabled = call.argument<Boolean>("enabled")
                            if (enabled == null) {
                                result.error("invalid_rendering_mode", "缺少兼容渲染模式状态", null)
                            } else if (!renderingPreferences().edit()
                                    .putBoolean(COMPATIBLE_RENDERING_KEY, enabled)
                                    // 用户亲手选了就以他为准：清掉安全模式与失败计数，
                                    // 下次启动按设置走。
                                    .putBoolean(RENDERING_CHOICE_KEY, true)
                                    .putInt(STARTUP_ATTEMPTS_KEY, 0)
                                    .remove(SAFE_MODE_KEY)
                                    .commit()) {
                                result.error("rendering_mode_not_saved", "兼容渲染模式未能保存", null)
                            } else {
                                result.success(null)
                                restartApplication()
                            }
                        }
                        "systemProxy" -> {
                            val connection = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                            val proxy = connection.defaultProxy
                            val host = proxy?.host.orEmpty()
                            val address = if (host.isNotEmpty() && (proxy?.port ?: 0) > 0) {
                                "http://${if (host.contains(':')) "[$host]" else host}:${proxy!!.port}"
                            } else ""
                            result.success(mapOf(
                                "http" to address,
                                "https" to address,
                                "bypass" to (proxy?.exclusionList?.toList() ?: emptyList<String>()),
                                "pac" to (proxy != null && proxy.pacFileUrl != Uri.EMPTY)
                            ))
                        }
                        "pictureInPictureStatus" -> result.success(pictureInPictureStatus())
                        "enterPictureInPicture" -> {
                            val width = call.argument<Int>("width") ?: 16
                            val height = call.argument<Int>("height") ?: 9
                            result.success(enterPlayerPictureInPicture(
                                width,
                                height,
                                call.argument<Int>("left"),
                                call.argument<Int>("top"),
                                call.argument<Int>("right"),
                                call.argument<Int>("bottom")
                            ))
                        }
                        "updatePictureInPicture" -> {
                            pictureInPicture = if (call.arguments == null) null else PlayerPictureInPicture(
                                call.argument<Int>("width") ?: 16,
                                call.argument<Int>("height") ?: 9,
                                call.argument<Boolean>("playing") ?: false,
                                call.argument<Boolean>("hasPrevious") ?: false,
                                call.argument<Boolean>("hasNext") ?: false,
                                call.argument<Boolean>("autoEnter") ?: false
                            )
                            if (pictureInPictureSupported()) {
                                runCatching { setPictureInPictureParams(pictureInPictureParams()) }
                            }
                            result.success(null)
                        }
                        "getBrightness" -> {
                            val lp = window.attributes
                            val current = if (lp.screenBrightness >= 0f) {
                                lp.screenBrightness.toDouble()
                            } else {
                                try {
                                    val sys = Settings.System.getInt(
                                        contentResolver,
                                        Settings.System.SCREEN_BRIGHTNESS
                                    )
                                    val resources = Resources.getSystem()
                                    val maxId = resources.getIdentifier(
                                        "config_screenBrightnessSettingMaximum", "integer", "android"
                                    )
                                    val max = if (maxId != 0) resources.getInteger(maxId) else 255
                                    (sys / max.coerceAtLeast(1).toDouble()).coerceIn(0.0, 1.0)
                                } catch (e: Exception) {
                                    0.5
                                }
                            }
                            result.success(current)
                        }
                        "setBrightness" -> {
                            val value = call.argument<Double>("brightness")?.toFloat()
                            if (value != null) {
                                val lp = window.attributes
                                lp.screenBrightness = value.coerceIn(0.01f, 1.0f)
                                window.attributes = lp
                                result.success(true)
                            } else {
                                result.error("invalid_arg", "缺少亮度数值", null)
                            }
                        }
                        "resetBrightness" -> {
                            val lp = window.attributes
                            lp.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                            window.attributes = lp
                            result.success(true)
                        }
                        "volume" -> {
                            val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            result.success(
                                if (max > 0) audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max
                                else null
                            )
                        }
                        "setVolume" -> {
                            val value = call.argument<Double>("volume")
                            if (value == null) {
                                result.error("invalid_arg", "缺少音量数值", null)
                            } else {
                                val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                                val index = (value.coerceIn(0.0, 1.0) * max).roundToInt()
                                if (index != audio.getStreamVolume(AudioManager.STREAM_MUSIC)) {
                                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0)
                                }
                                result.success(null)
                            }
                        }
                        "openExternalPlayer" -> {
                            val url = call.argument<String>("url")
                            val title = call.argument<String>("title") ?: "短剧"
                            if (!url.isNullOrEmpty()) {
                                try {
                                    val intent = Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(Uri.parse(url), "video/*")
                                        putExtra("title", title)
                                        putExtra("return_result", true)
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    startActivity(intent)
                                    result.success(true)
                                } catch (e: Exception) {
                                    result.error("no_player", "未找到外部播放器: ${e.message}", null)
                                }
                            } else {
                                result.error("invalid_url", "播放地址为空", null)
                            }
                        }
                        "createDocument" -> {
                            val name = call.argument<String>("name")
                            if (name.isNullOrEmpty() || documentResult != null) {
                                result.error("invalid_document", "无法创建文件", null)
                            } else {
                                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = call.argument<String>("mimeType") ?: "application/octet-stream"
                                    putExtra(Intent.EXTRA_TITLE, name)
                                }
                                try {
                                    documentResult = result
                                    startActivityForResult(intent, CREATE_DOCUMENT_REQUEST)
                                } catch (e: Exception) {
                                    documentResult = null
                                    result.error("no_document_picker", "系统没有可用的文件保存界面", null)
                                }
                            }
                        }
                        "deleteDocument" -> {
                            val uri = call.argument<String>("uri")
                            result.success(uri != null && runCatching {
                                DocumentsContract.deleteDocument(contentResolver, Uri.parse(uri))
                            }.getOrDefault(false))
                        }
                        "requestVideoExport" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
                                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                                PackageManager.PERMISSION_GRANTED) {
                                result.success(true)
                            } else if (permissionResult != null) {
                                result.error("permission_pending", "正在申请存储权限", null)
                            } else {
                                permissionResult = result
                                requestPermissions(
                                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                                    STORAGE_PERMISSION_REQUEST
                                )
                            }
                        }
                        "exportVideo" -> {
                            val source = call.argument<String>("source")
                            val folder = call.argument<String>("folder")
                            val name = call.argument<String>("name")
                            if (source.isNullOrEmpty() || folder.isNullOrEmpty() || name.isNullOrEmpty()) {
                                result.error("invalid_export", "导出参数无效", null)
                            } else {
                                Thread {
                                    val outcome = runCatching { exportVideo(File(source), folder, name) }
                                    runOnUiThread {
                                        outcome.fold(
                                            { result.success(null) },
                                            { result.error("export_failed", "导出失败：${it.message}", null) }
                                        )
                                    }
                                }.start()
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
            }
    }

    private fun exportVideo(source: File, folder: String, name: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            @Suppress("DEPRECATION")
            val movies = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
            val directory = File(movies, folder)
            if (!directory.isDirectory && !directory.mkdirs()) throw IOException("无法创建 Movies/$folder")
            val target = File(directory, name)
            source.copyTo(target, overwrite = true)
            MediaScannerConnection.scanFile(this, arrayOf(target.path), arrayOf("video/mp4"), null)
            return
        }
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val relativePath = "${Environment.DIRECTORY_MOVIES}/$folder/"
        val existing = contentResolver.query(
            collection,
            arrayOf(MediaStore.Video.Media._ID),
            "${MediaStore.Video.Media.RELATIVE_PATH}=? AND ${MediaStore.Video.Media.DISPLAY_NAME}=?",
            arrayOf(relativePath, name),
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) ContentUris.withAppendedId(collection, cursor.getLong(0)) else null
        }
        val uri = existing ?: contentResolver.insert(collection, ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, relativePath)
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }) ?: throw IOException("无法在 Movies 中创建文件")
        try {
            val output = contentResolver.openOutputStream(uri, "wt") ?: throw IOException("无法写入 Movies")
            output.use { stream -> source.inputStream().use { it.copyTo(stream) } }
            contentResolver.update(uri, ContentValues().apply {
                put(MediaStore.Video.Media.IS_PENDING, 0)
            }, null, null)
        } catch (e: Exception) {
            if (existing == null) runCatching { contentResolver.delete(uri, null, null) }
            throw e
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != STORAGE_PERMISSION_REQUEST) return
        val result = permissionResult ?: return
        permissionResult = null
        result.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    @ChecksSdkIntAtLeast(api = Build.VERSION_CODES.O)
    private fun pictureInPictureSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun pictureInPictureStatus(): Map<String, Any> {
        return mapOf(
            "supported" to pictureInPictureSupported(),
            "active" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode)
        )
    }

    private fun enterPlayerPictureInPicture(
        width: Int,
        height: Int,
        left: Int?,
        top: Int?,
        right: Int?,
        bottom: Int?
    ): Map<String, Any> {
        if (!pictureInPictureSupported()) return pictureInPictureStatus()
        pictureInPicture = pictureInPicture?.copy(width = width, height = height)
            ?: PlayerPictureInPicture(width, height, true, false, false, false)
        return runCatching {
            val sourceRect = if (left != null && top != null && right != null && bottom != null &&
                right > left && bottom > top) Rect(left, top, right, bottom) else null
            val entered = enterPictureInPictureMode(pictureInPictureParams(sourceRect))
            pictureInPictureStatus() + ("requested" to entered)
        }.getOrElse { pictureInPictureStatus() }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun pictureInPictureParams(sourceRect: Rect? = null): PictureInPictureParams {
        val state = pictureInPicture
        val builder = PictureInPictureParams.Builder()
        if (state != null) {
            builder.setAspectRatio(Rational(state.width.coerceIn(1, 10000), state.height.coerceIn(1, 10000)))
            builder.setActions(listOf(
                pictureInPictureAction(1, "previous", R.drawable.ic_pip_previous, "上一集", state.hasPrevious),
                if (state.playing) {
                    pictureInPictureAction(2, "toggle", R.drawable.ic_pip_pause, "暂停", true)
                } else {
                    pictureInPictureAction(2, "toggle", R.drawable.ic_pip_play, "播放", true)
                },
                pictureInPictureAction(3, "next", R.drawable.ic_pip_next, "下一集", state.hasNext)
            ))
        } else {
            builder.setActions(emptyList())
        }
        if (sourceRect != null) builder.setSourceRectHint(sourceRect)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(state?.autoEnter == true)
        }
        return builder.build()
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun pictureInPictureAction(
        request: Int,
        action: String,
        icon: Int,
        title: String,
        enabled: Boolean
    ): RemoteAction {
        val intent = Intent(PICTURE_IN_PICTURE_ACTION).setPackage(packageName).putExtra("action", action)
        val pending = PendingIntent.getBroadcast(
            this, request, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return RemoteAction(Icon.createWithResource(this, icon), title, title, pending).apply {
            isEnabled = enabled
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pictureInPicture?.autoEnter != true || !pictureInPictureSupported()) return
        deviceChannel?.invokeMethod("pictureInPicturePending", null)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
        val entered = runCatching { enterPictureInPictureMode(pictureInPictureParams()) }.getOrDefault(false)
        if (!entered) deviceChannel?.invokeMethod("pictureInPictureChanged", mapOf("active" to false))
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        deviceChannel?.invokeMethod(
            "pictureInPictureChanged",
            mapOf("active" to isInPictureInPictureMode)
        )
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != CREATE_DOCUMENT_REQUEST) {
            return super.onActivityResult(requestCode, resultCode, data)
        }
        val result = documentResult ?: return
        documentResult = null
        result.success(if (resultCode == RESULT_OK) data?.data?.toString() else null)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        orientationListener?.disable()
        orientationListener = null
        textInput?.dispose()
        textInput = null
        mediaControls?.dispose()
        mediaControls = null
        webViewBridge?.dispose()
        webViewBridge = null
        spiderBridge?.dispose()
        spiderBridge = null
        deviceChannel?.setMethodCallHandler(null)
        deviceChannel = null
        castChannel?.setMethodCallHandler(null)
        castChannel = null
        cast?.close()
        cast = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
