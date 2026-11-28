package com.guoapp

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/// PY 沙箱原生桥（Chaquopy）。
///
/// 通道 `guoapp/py`：status / validate / call / dispose / disposeAll。
/// 所有调用都丢到后台线程执行，主线程只负责回包。
class PyBridge(context: Context, messenger: BinaryMessenger) {
    private val appContext = context.applicationContext
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "guoapp/py")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> runAsync(result) { status() }
                "validate" -> {
                    val source = call.argument<String>("source")
                    if (source == null) {
                        result.error("invalid_argument", "缺少蜘蛛源码", null)
                    } else {
                        runAsync(result) { validate(source) }
                    }
                }
                "call" -> {
                    val path = call.argument<String>("path")
                    val request = call.argument<String>("request")
                    if (path == null || request == null) {
                        result.error("invalid_argument", "缺少蜘蛛路径或请求", null)
                    } else {
                        runAsync(result) { dispatch(path, request) }
                    }
                }
                "dispose" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("invalid_argument", "缺少蜘蛛路径", null)
                    } else {
                        runAsync(result) { dispose(path) }
                    }
                }
                "disposeAll" -> runAsync(result) { disposeAll() }
                else -> result.notImplemented()
            }
        }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> String) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                val message = error.message ?: error.toString()
                mainHandler.post { result.error("py_runtime_error", message, null) }
            }
        }
    }

    private val pythonLock = Any()

    private fun python(): Python {
        synchronized(pythonLock) {
            if (!Python.isStarted()) {
                try {
                    Python.start(AndroidPlatform(appContext))
                } catch (error: IllegalStateException) {
                    if (!Python.isStarted()) throw error
                }
            }
            return Python.getInstance()
        }
    }

    private fun host() = python().getModule("py_spider_host")

    private fun status(): String {
        val py = python()
        val version = py.getModule("sys").get("version")?.toString()?.lineSequence()?.firstOrNull() ?: ""
        return """{"available":true,"python":${jsonString(version)}}"""
    }

    private fun validate(source: String): String =
        host().callAttr("validate_source_json", source).toString()

    private fun dispatch(path: String, request: String): String =
        host().callAttr("handle", path, request).toString()

    private fun dispose(path: String): String =
        host().callAttr("dispose", path).toString()

    private fun disposeAll(): String =
        host().callAttr("dispose_all").toString()

    private fun jsonString(value: String): String {
        val escaped = value
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
        return "\"$escaped\""
    }

    fun shutdown() {
        executor.shutdownNow()
        channel.setMethodCallHandler(null)
    }
}
