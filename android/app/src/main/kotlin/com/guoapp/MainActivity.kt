package com.guoapp

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterSurfaceView
import android.app.UiModeManager
import android.app.ActivityManager
import android.app.PictureInPictureParams
import android.os.Build
import android.os.Bundle
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.net.ConnectivityManager
import android.net.Uri
import android.util.Rational
import android.view.InputDevice
import android.view.OrientationEventListener
import android.view.SurfaceHolder
import android.view.WindowManager
import android.provider.Settings
import androidx.annotation.ChecksSdkIntAtLeast
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

private const val SURFACE_RESIZE_REDRAW_WAIT_MS = 100L
private const val ORIENTATION_SETTLE_MS = 800L

// 车机 / 电视 / 投影等 4K~6K 大屏的逻辑短边远超平板，Flutter 按原始 density
// 排版会让字号和按钮小到无法阅读、点击。这里只覆盖 densityDpi，把逻辑短边
// 压到接近平板（720dp），布局仍按平板 / 电视排列；手机和平板不受影响。
private const val LARGE_CANVAS_DP = 1000f
private const val TARGET_CANVAS_DP = 720f

class MainActivity : FlutterActivity() {
    private var headroomReadAt = 0L
    private var thermalHeadroom: Double? = null
    private var deviceChannel: MethodChannel? = null
    private var castChannel: MethodChannel? = null
    private var cast: DlnaCast? = null
    // 电视端搜索框的系统输入法桥：Flutter 的 TextField 在部分电视（小米等）
    // 上按确认键唤不出输入法，改成挂一个 1x1 的隐藏 EditText 来拉起键盘。
    private var textInput: TextInputBridge? = null
    private var televisionMode = false
    private var orientationListener: OrientationEventListener? = null

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(scaleLargeCanvas(newBase))
    }

    private fun scaleLargeCanvas(base: Context): Context {
        val metrics = base.resources.displayMetrics
        if (metrics.density <= 0f) return base
        val shortestDp = minOf(metrics.widthPixels, metrics.heightPixels) / metrics.density
        if (shortestDp <= LARGE_CANVAS_DP) return base
        // 只覆盖 density 一项，locale / uiMode / fontScale 仍从 base 继承；
        // 配合 Manifest 的 configChanges，运行中切换深色、字号、语言照常生效。
        val densityOnly = Configuration().apply {
            densityDpi = (base.resources.configuration.densityDpi * shortestDp / TARGET_CANVAS_DP).roundToInt()
        }
        return runCatching { base.createConfigurationContext(densityOnly) }.getOrDefault(base)
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
        getSharedPreferences("duanju_rendering", Context.MODE_PRIVATE)

    private fun compatibleRendering(): Boolean =
        renderingPreferences().getBoolean("compatibleRendering", false)

    override fun getFlutterShellArgs(): FlutterShellArgs {
        val args = super.getFlutterShellArgs()
        if (compatibleRendering()) args.add("--enable-impeller=false")
        return args
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                        // 播放器手势的亮度调节：只改本窗口的 screenBrightness，
                        // 不动系统设置，退出播放器时用 resetBrightness 还原。
                        "getBrightness" -> {
                            val lp = window.attributes
                            val current = if (lp.screenBrightness >= 0f) {
                                lp.screenBrightness.toDouble()
                            } else {
                                runCatching {
                                    val sys = Settings.System.getInt(
                                        contentResolver,
                                        Settings.System.SCREEN_BRIGHTNESS
                                    )
                                    (sys / 255.0).coerceIn(0.0, 1.0)
                                }.getOrDefault(0.5)
                            }
                            result.success(current)
                        }
                        "setBrightness" -> {
                            val value = call.argument<Double>("brightness")?.toFloat()
                            if (value == null) {
                                result.error("invalid_arg", "缺少亮度数值", null)
                            } else {
                                val lp = window.attributes
                                lp.screenBrightness = value.coerceIn(0.01f, 1.0f)
                                window.attributes = lp
                                result.success(true)
                            }
                        }
                        "resetBrightness" -> {
                            val lp = window.attributes
                            lp.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                            window.attributes = lp
                            result.success(true)
                        }
                        "playbackPower" -> result.success(runCatching { playbackPower() }.getOrNull())
                        "compatibleRendering" -> result.success(compatibleRendering())
                        "setCompatibleRendering" -> {
                            val enabled = call.argument<Boolean>("enabled")
                            if (enabled == null) {
                                result.error("invalid_rendering_mode", "缺少兼容渲染模式状态", null)
                            } else if (!renderingPreferences().edit()
                                    .putBoolean("compatibleRendering", enabled).commit()) {
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
                                    (sys / 255.0).coerceIn(0.0, 1.0)
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
                        else -> result.notImplemented()
                    }
                }
            }
        // 电视端搜索框的系统输入法桥（见 TextInputBridge）。
        textInput = TextInputBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        // 投屏（DLNA）：Flutter 侧只负责选设备与按钮，搜索 / SOAP 下发都在
        // DlnaCast 的单线程里跑，网络耗时不能占主线程。
        val dlna = DlnaCast(applicationContext)
        cast = dlna
        castChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "duanju/cast")
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "discover" -> dlna.discover { devices, error ->
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
                                dlna.play(control, url, title, position, relay) { ok, message ->
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
                                dlna.control(control, command) { ok, message ->
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
                                dlna.status(control) { state -> result.success(state) }
                            }
                        }
                        "close" -> {
                            dlna.close()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
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
        val safeWidth = width.coerceIn(1, 10000)
        val safeHeight = height.coerceIn(1, 10000)
        return runCatching {
            val builder = PictureInPictureParams.Builder()
            builder.setAspectRatio(Rational(safeWidth, safeHeight))
            if (left != null && top != null && right != null && bottom != null &&
                right > left && bottom > top) {
                builder.setSourceRectHint(Rect(left, top, right, bottom))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(true)
            }
            val entered = enterPictureInPictureMode(builder.build())
            pictureInPictureStatus() + ("requested" to entered)
        }.getOrElse { pictureInPictureStatus() }
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        orientationListener?.disable()
        orientationListener = null
        deviceChannel?.setMethodCallHandler(null)
        deviceChannel = null
        textInput?.dispose()
        textInput = null
        castChannel?.setMethodCallHandler(null)
        castChannel = null
        cast?.close()
        cast = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
