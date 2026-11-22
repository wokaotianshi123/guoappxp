package com.guoapp

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.github.catvod.crawler.Spider
import dalvik.system.DexClassLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Android TVBox .jar Spider 插件桥接。
 *
 * 饭太硬等订阅站点把抓取逻辑编译成 .jar，运行时靠 DexClassLoader 加载并继承
 * com.github.catvod.crawler.Spider。这里负责下载 jar、加载类、按 action 调用
 * 对应方法，把结果 JSON 交回 Go 核心。
 */
class SpiderBridge(
    private val context: Context,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "guoapp/spider")
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val loaders = ConcurrentHashMap<String, DexClassLoader>()
    private val spiders = ConcurrentHashMap<String, Spider>()
    private val loaderLock = Any()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "callSpider") {
            result.notImplemented()
            return
        }
        val spiderUrl = call.argument<String>("spider").orEmpty().trim()
        val api = call.argument<String>("api").orEmpty().trim()
        val ext = call.argument<String>("ext").orEmpty()
        val action = call.argument<String>("action").orEmpty().trim()
        val tid = call.argument<String>("tid").orEmpty()
        val pg = call.argument<String>("pg").orEmpty().ifEmpty { "1" }
        val wd = call.argument<String>("wd").orEmpty()
        val id = call.argument<String>("id").orEmpty()
        val flag = call.argument<String>("flag").orEmpty()
        val extendRaw = call.argument<String>("extend").orEmpty()

        if (spiderUrl.isEmpty() || api.isEmpty() || action.isEmpty()) {
            result.success(mapOf("ok" to false, "error" to "缺少 spider 或 api 参数"))
            return
        }

        executor.execute {
            try {
                val loader = ensureLoader(spiderUrl)
                val spider = ensureSpider(loader, spiderUrl, api, ext)
                val json = when (action) {
                    "home" -> mergeHome(
                        runCatching { spider.homeContent(true) }.getOrNull(),
                        runCatching { spider.homeVideoContent() }.getOrNull(),
                    )
                    "category" -> spider.categoryContent(tid, pg, false, parseExtend(extendRaw))
                    "search" -> {
                        try {
                            spider.searchContent(wd, false, pg)
                        } catch (_: Throwable) {
                            spider.searchContent(wd, false)
                        }
                    }
                    "detail" -> spider.detailContent(listOf(id))
                    "player" -> spider.playerContent(flag, id, emptyList())
                    else -> throw IllegalArgumentException("不支持的 spider 动作: $action")
                }
                mainHandler.post {
                    result.success(mapOf("ok" to true, "json" to (json ?: "")))
                }
            } catch (t: Throwable) {
                val rootCause = generateSequence(t) { it.cause }.last()
                val msg = rootCause.message ?: rootCause.javaClass.simpleName
                mainHandler.post {
                    result.success(mapOf("ok" to false, "error" to "Spider 执行失败: $msg"))
                }
            }
        }
    }

    // 二级筛选：Go 侧把 extend 序列化成 JSON 传过来，还原成 TVBox 要的 HashMap。
    private fun parseExtend(raw: String): HashMap<String, String> {
        val map = HashMap<String, String>()
        if (raw.isBlank()) return map
        runCatching {
            val obj = JSONObject(raw)
            for (key in obj.keys()) map[key] = obj.optString(key)
        }
        return map
    }

    // 很多 jar 站源的首页推荐放在 homeVideoContent，class/filters 在 homeContent。
    // 只取其中一个就会「有分类但没剧」，所以把两边的 list 合并。
    private fun mergeHome(home: String?, video: String?): String {
        if (video.isNullOrBlank()) return home ?: ""
        val videoList = runCatching {
            JSONObject(video).optJSONArray("list")
        }.getOrNull() ?: return home ?: ""
        if (videoList.length() == 0) return home ?: ""
        if (home.isNullOrBlank()) return video
        val homeObj = runCatching { JSONObject(home) }.getOrNull() ?: return video
        val homeList = homeObj.optJSONArray("list")
        if (homeList != null && homeList.length() > 0) return home
        homeObj.put("list", videoList)
        return homeObj.toString()
    }

    private fun parseSpiderURL(raw: String): Pair<String, String> {
        val parts = raw.split(";")
        val url = parts.first().trim()
        var md5 = ""
        val idx = parts.indexOfFirst { it.equals("md5", ignoreCase = true) }
        if (idx >= 0 && idx + 1 < parts.size) {
            md5 = parts[idx + 1].trim().lowercase()
        }
        return url to md5
    }

    private fun ensureLoader(spiderRaw: String): DexClassLoader {
        loaders[spiderRaw]?.let { return it }
        synchronized(loaderLock) {
            loaders[spiderRaw]?.let { return it }
            val (downloadUrl, expectedMd5) = parseSpiderURL(spiderRaw)
            val cacheDir = File(context.codeCacheDir, "tvbox_spider").apply { mkdirs() }
            val key = if (expectedMd5.isNotEmpty()) expectedMd5 else sha256Hex(downloadUrl).take(24)
            val jarFile = File(cacheDir, "$key.jar")
            val optDir = File(cacheDir, "opt_$key").apply { mkdirs() }

            if (!jarFile.exists() || jarFile.length() == 0L) {
                val bytes = downloadBytes(downloadUrl)
                val zipBytes = extractZipPayload(bytes)
                jarFile.writeBytes(zipBytes)
                jarFile.setReadOnly()
            }

            val loader = DexClassLoader(
                jarFile.absolutePath,
                optDir.absolutePath,
                null,
                context.classLoader
            )
            runCatching {
                val initClass = loader.loadClass("com.github.catvod.spider.Init")
                val initMethod = initClass.getMethod("init", Context::class.java)
                initMethod.invoke(null, context.applicationContext)
            }
            loaders[spiderRaw] = loader
            return loader
        }
    }

    private fun ensureSpider(
        loader: DexClassLoader,
        spiderRaw: String,
        api: String,
        ext: String
    ): Spider {
        val cacheKey = "$spiderRaw|$api|$ext"
        spiders[cacheKey]?.let { return it }
        synchronized(loaderLock) {
            spiders[cacheKey]?.let { return it }
            val className = when {
                api.startsWith("csp_") -> "com.github.catvod.spider." + api.removePrefix("csp_")
                api.contains(".") -> api
                else -> "com.github.catvod.spider.$api"
            }
            val clazz = loader.loadClass(className)
            val instance = clazz.getDeclaredConstructor().newInstance() as Spider
            instance.siteKey = api
            try {
                instance.init(context.applicationContext, ext)
            } catch (_: NoSuchMethodError) {
                instance.init(context.applicationContext)
            }
            spiders[cacheKey] = instance
            return instance
        }
    }

    private fun downloadBytes(url: String): ByteArray {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 30_000
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", "okhttp/3.15")
        }
        try {
            val code = conn.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("下载 spider 失败（HTTP $code）")
            }
            return conn.inputStream.use { it.readBytes() }
        } finally {
            conn.disconnect()
        }
    }

    private fun extractZipPayload(raw: ByteArray): ByteArray {
        if (raw.size >= 4 && raw[0] == 0x50.toByte() && raw[1] == 0x4B.toByte() &&
            raw[2] == 0x03.toByte() && raw[3] == 0x04.toByte()
        ) {
            return raw
        }
        for (i in 0..raw.size - 4) {
            if (raw[i] == 0x50.toByte() && raw[i + 1] == 0x4B.toByte() &&
                raw[i + 2] == 0x03.toByte() && raw[i + 3] == 0x04.toByte()
            ) {
                return raw.copyOfRange(i, raw.size)
            }
        }
        return raw
    }

    private fun sha256Hex(text: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        spiders.clear()
        loaders.clear()
        executor.shutdownNow()
    }
}
