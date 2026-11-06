package com.guoapp

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import java.io.StringReader
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.net.URL
import java.util.Locale
import java.util.concurrent.Executors
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory

// DLNA 投屏控制器：SSDP 搜索局域网里的 MediaRenderer（电视 / 盒子 / 投影仪），
// 再按 AVTransport 服务下发地址并控制播放。实现对齐 V影（com.vicedev.vmovie）
// 里的 Cling 方案，但只用 JDK 自带的 socket 与 XML 解析，不引入第三方依赖。
private const val SSDP_HOST = "239.255.255.250"
private const val SSDP_PORT = 1900
private const val SSDP_WINDOW_MS = 2600L
private const val MEDIA_RENDERER = "urn:schemas-upnp-org:device:MediaRenderer:1"
private const val AV_TRANSPORT = "urn:schemas-upnp-org:service:AVTransport:1"
private const val REQUEST_TIMEOUT_MS = 5000

class DlnaDevice(
    val name: String,
    val udn: String,
    val location: String,
    val controlUrl: String
) {
    fun toMap(): Map<String, Any> = mapOf(
        "name" to name,
        "udn" to udn,
        "location" to location,
        "controlUrl" to controlUrl
    )
}

class DlnaCast(context: Context) {
    private val appContext = context.applicationContext
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "duanju-dlna").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null

    // 是否经手机转发。直连原始线路时电视自己上网拉流，手机不需要维持任何
    // 后台资源，也就不能持唤醒锁白耗电。
    private var relaying = false

    fun discover(done: (List<DlnaDevice>, String) -> Unit) {
        executor.execute {
            var error = ""
            val found = LinkedHashMap<String, DlnaDevice>()
            val lock = acquireMulticastLock()
            try {
                for (location in searchLocations()) {
                    val device = runCatching { loadDevice(location) }.getOrNull() ?: continue
                    if (!found.containsKey(device.udn)) found[device.udn] = device
                }
            } catch (failure: Exception) {
                error = failure.message ?: "搜索投屏设备失败"
            } finally {
                runCatching { lock?.release() }
            }
            if (error.isEmpty() && found.isEmpty()) {
                error = "没有搜索到可投屏的设备，请确认电视已开机并与手机处于同一 Wi-Fi"
            }
            val devices = found.values.sortedBy { it.name.lowercase(Locale.ROOT) }
            main.post { done(devices, error) }
        }
    }

    /** 下发地址并起播；[positionMs] 大于 1 秒时先定位到该进度再播。 */
    fun play(
        controlUrl: String,
        url: String,
        title: String,
        positionMs: Long,
        relay: Boolean,
        done: (Boolean, String) -> Unit
    ) = submit(done) {
        relaying = relay
        if (relay) {
            acquireWakeLock()
        } else {
            releaseWakeLock()
        }
        setTransportUri(controlUrl, url, title)
        if (positionMs > 1500) {
            runCatching {
                soap(
                    controlUrl,
                    "Seek",
                    "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>${clock(positionMs)}</Target>"
                )
            }
        }
        soap(controlUrl, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    /** [command] 取 pause / resume / stop。 */
    fun control(controlUrl: String, command: String, done: (Boolean, String) -> Unit) =
        submit(done) {
            when (command) {
                "pause" -> soap(controlUrl, "Pause", "<InstanceID>0</InstanceID>")
                "resume" -> {
                    if (relaying) acquireWakeLock()
                    soap(controlUrl, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
                }
                "stop" -> {
                    soap(controlUrl, "Stop", "<InstanceID>0</InstanceID>")
                    releaseWakeLock()
                }
                else -> throw IllegalStateException("不支持的投屏操作")
            }
        }

    fun status(controlUrl: String, done: (Map<String, Any?>) -> Unit) {
        executor.execute {
            val state = runCatching {
                val info = soap(controlUrl, "GetTransportInfo", "<InstanceID>0</InstanceID>")
                val position = runCatching {
                    soap(controlUrl, "GetPositionInfo", "<InstanceID>0</InstanceID>")
                }.getOrDefault("")
                mapOf(
                    "state" to tag(info, "CurrentTransportState"),
                    "positionMs" to parseClock(tag(position, "RelTime")),
                    "durationMs" to parseClock(tag(position, "TrackDuration"))
                )
            }.getOrElse { mapOf("state" to "UNKNOWN", "positionMs" to 0L, "durationMs" to 0L) }
            main.post { done(state) }
        }
    }

    fun close() {
        releaseWakeLock()
        executor.shutdownNow()
    }

    // 只有经手机转发时才需要：本机在后台持续给电视供流，不持锁很容易让系统
    // 休眠后断流。直连投屏不持锁，用户关屏 / 退出 App 都不影响电视播放。
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val power = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        wakeLock = runCatching {
            power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "duanju:cast").apply {
                setReferenceCounted(false)
                acquire(6 * 60 * 60 * 1000L)
            }
        }.getOrNull()
    }

    private fun releaseWakeLock() {
        runCatching { wakeLock?.release() }
        wakeLock = null
    }

    private fun submit(done: (Boolean, String) -> Unit, action: () -> Unit) {
        executor.execute {
            val outcome = runCatching { action() }
            val message = outcome.exceptionOrNull()?.let { it.message ?: "投屏失败" } ?: ""
            main.post { done(outcome.isSuccess, message) }
        }
    }

    // ---- SSDP ----

    private fun acquireMulticastLock(): WifiManager.MulticastLock? {
        val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        return runCatching {
            wifi.createMulticastLock("duanju-cast").apply {
                setReferenceCounted(false)
                acquire()
            }
        }.getOrNull()
    }

    private fun searchLocations(): List<String> {
        val locations = LinkedHashSet<String>()
        DatagramSocket().use { socket ->
            socket.reuseAddress = true
            socket.soTimeout = 400
            val message = (
                "M-SEARCH * HTTP/1.1\r\n" +
                    "HOST: $SSDP_HOST:$SSDP_PORT\r\n" +
                    "MAN: \"ssdp:discover\"\r\n" +
                    "MX: 2\r\n" +
                    "ST: $MEDIA_RENDERER\r\n\r\n"
                ).toByteArray(Charsets.UTF_8)
            val group = InetAddress.getByName(SSDP_HOST)
            repeat(3) { socket.send(DatagramPacket(message, message.size, group, SSDP_PORT)) }
            val deadline = System.currentTimeMillis() + SSDP_WINDOW_MS
            val buffer = ByteArray(4096)
            while (System.currentTimeMillis() < deadline) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    socket.receive(packet)
                } catch (timeout: SocketTimeoutException) {
                    continue
                }
                val text = String(packet.data, 0, packet.length, Charsets.UTF_8)
                header(text, "location")?.let { locations.add(it) }
            }
        }
        return locations.toList()
    }

    private fun header(text: String, name: String): String? {
        for (line in text.lineSequence()) {
            val index = line.indexOf(':')
            if (index <= 0) continue
            if (line.substring(0, index).trim().equals(name, ignoreCase = true)) {
                return line.substring(index + 1).trim()
            }
        }
        return null
    }

    // ---- 设备描述 ----

    private fun loadDevice(location: String): DlnaDevice? {
        val xml = httpGet(location)
        val parser = XmlPullParserFactory.newInstance().newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
        parser.setInput(StringReader(xml))
        var deviceType = ""
        var name = ""
        var udn = ""
        var serviceType = ""
        var control = ""
        var inService = false
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> when (parser.name) {
                    "deviceType" -> if (deviceType.isEmpty()) deviceType = parser.nextText().trim()
                    "friendlyName" -> if (name.isEmpty()) name = parser.nextText().trim()
                    "UDN" -> if (udn.isEmpty()) udn = parser.nextText().trim()
                    "service" -> {
                        inService = true
                        serviceType = ""
                    }
                    "serviceType" -> if (inService) serviceType = parser.nextText().trim()
                    "controlURL" -> {
                        val text = parser.nextText().trim()
                        if (inService && serviceType == AV_TRANSPORT && control.isEmpty()) {
                            control = resolve(location, text)
                        }
                    }
                }
                XmlPullParser.END_TAG -> if (parser.name == "service") {
                    inService = false
                    serviceType = ""
                }
            }
            event = parser.next()
        }
        if (control.isEmpty()) return null
        if (deviceType.isNotEmpty() && !deviceType.contains("MediaRenderer")) return null
        return DlnaDevice(
            name = name.ifEmpty { "投屏设备" },
            udn = udn.ifEmpty { location },
            location = location,
            controlUrl = control
        )
    }

    private fun resolve(base: String, reference: String): String =
        runCatching { URL(URL(base), reference).toString() }.getOrDefault(reference)

    private fun httpGet(address: String): String {
        val connection = URL(address).openConnection() as HttpURLConnection
        connection.connectTimeout = 3000
        connection.readTimeout = REQUEST_TIMEOUT_MS
        connection.setRequestProperty("User-Agent", "Android UPnP/1.1 Duanju/1.0")
        return try {
            connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }

    // ---- AVTransport ----

    private fun setTransportUri(controlUrl: String, url: String, title: String) {
        val metadata = xmlEscape(buildDidl(url, title))
        val body = "<InstanceID>0</InstanceID><CurrentURI>${xmlEscape(url)}</CurrentURI>" +
            "<CurrentURIMetaData>$metadata</CurrentURIMetaData>"
        // 一部分电视不接受 DIDL 元数据，退回空元数据再试一次。
        runCatching { soap(controlUrl, "SetAVTransportURI", body) }.onFailure {
            soap(
                controlUrl,
                "SetAVTransportURI",
                "<InstanceID>0</InstanceID><CurrentURI>${xmlEscape(url)}</CurrentURI>" +
                    "<CurrentURIMetaData></CurrentURIMetaData>"
            )
        }
    }

    private fun soap(controlUrl: String, action: String, body: String): String {
        val envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"" +
            " s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>" +
            "<u:$action xmlns:u=\"$AV_TRANSPORT\">$body</u:$action></s:Body></s:Envelope>"
        val connection = URL(controlUrl).openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.connectTimeout = REQUEST_TIMEOUT_MS
        connection.readTimeout = REQUEST_TIMEOUT_MS
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "text/xml; charset=\"utf-8\"")
        connection.setRequestProperty("SOAPACTION", "\"$AV_TRANSPORT#$action\"")
        return try {
            connection.outputStream.use { it.write(envelope.toByteArray(Charsets.UTF_8)) }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (code !in 200..299) {
                val reason = tag(text, "errorDescription")
                throw IllegalStateException(
                    when {
                        reason.isNotEmpty() -> "电视拒绝了投屏：$reason"
                        code == 500 -> "电视不支持这个视频源（HTTP 500）"
                        else -> "电视拒绝了投屏请求（HTTP $code）"
                    }
                )
            }
            text
        } finally {
            connection.disconnect()
        }
    }

    private fun buildDidl(url: String, title: String): String {
        val mime = mimeFor(url)
        val name = xmlEscape(title.ifEmpty { "短剧" })
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"" +
            " xmlns:dc=\"http://purl.org/dc/elements/1.1/\"" +
            " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">" +
            "<item id=\"1\" parentID=\"0\" restricted=\"1\">" +
            "<dc:title>$name</dc:title>" +
            "<upnp:class>object.item.videoItem</upnp:class>" +
            "<res protocolInfo=\"http-get:*:$mime:*\">${xmlEscape(url)}</res>" +
            "</item></DIDL-Lite>"
    }

    private fun mimeFor(url: String): String {
        val path = url.substringBefore('?').lowercase(Locale.ROOT)
        return when {
            path.endsWith(".m3u8") -> "application/vnd.apple.mpegurl"
            path.endsWith(".ts") -> "video/mp2t"
            path.endsWith(".flv") -> "video/x-flv"
            else -> "video/mp4"
        }
    }

    private fun xmlEscape(text: String): String = text
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&apos;")

    private fun tag(text: String, name: String): String =
        Regex("<$name[^>]*>([^<]*)</$name>").find(text)?.groupValues?.get(1)?.trim().orEmpty()

    private fun clock(milliseconds: Long): String {
        val seconds = (milliseconds / 1000).coerceAtLeast(0)
        return String.format(
            Locale.US,
            "%02d:%02d:%02d",
            seconds / 3600,
            seconds % 3600 / 60,
            seconds % 60
        )
    }

    private fun parseClock(text: String): Long {
        val parts = text.split(':')
        if (parts.size != 3) return 0
        val hours = parts[0].toLongOrNull() ?: return 0
        val minutes = parts[1].toLongOrNull() ?: return 0
        val seconds = parts[2].substringBefore('.').toLongOrNull() ?: return 0
        return ((hours * 3600 + minutes * 60 + seconds) * 1000).coerceAtLeast(0)
    }
}
