package com.guoapp

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowInsets
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import java.util.ArrayDeque

/**
 * 应用内 WebView 验证与人机验证页面抓取。
 *
 * - openChallenge：弹一个可见的浏览器页让用户走完 Cloudflare 验证，
 *   完成后把 Cookie / UA 交回 Dart，再转给 Go 核心复用同一套指纹。
 * - fetchHtml：用隐藏 WebView 抓页面 HTML，供 Go 核心在遇到挑战域名时
 *   通过回环 HTTP 服务间接调用。
 */
class WebViewBridge(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "guoapp/webview")
    private val mainHandler = Handler(Looper.getMainLooper())
    private var hiddenWebView: WebView? = null
    private val fetchQueue = ArrayDeque<FetchRequest>()
    private var fetchBusy = false

    private data class FetchRequest(
        val url: String,
        val result: MethodChannel.Result
    )

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openChallenge" -> {
                val url = call.argument<String>("url")?.trim().orEmpty()
                if (url.isEmpty()) {
                    result.error("invalid_args", "缺少验证地址", null)
                    return
                }
                mainHandler.post { showChallengeDialog(url, result) }
            }
            "fetchHtml" -> {
                val url = call.argument<String>("url")?.trim().orEmpty()
                if (url.isEmpty()) {
                    result.error("invalid_args", "缺少请求地址", null)
                    return
                }
                mainHandler.post {
                    fetchQueue.addLast(FetchRequest(url, result))
                    pumpFetchQueue()
                }
            }
            else -> result.notImplemented()
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun showChallengeDialog(url: String, result: MethodChannel.Result) {
        if (activity.isFinishing || activity.isDestroyed) {
            result.success(mapOf("ok" to false))
            return
        }
        var settled = false
        val dialog = Dialog(activity, android.R.style.Theme_DeviceDefault_NoActionBar)
        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#0A0A0C"))
        }

        val dp = activity.resources.displayMetrics.density
        val resId = activity.resources.getIdentifier("status_bar_height", "dimen", "android")
        val fallbackTopInset = if (resId > 0) activity.resources.getDimensionPixelSize(resId) else (28 * dp).toInt()
        val hPad = (14 * dp).toInt()
        val vPad = (10 * dp).toInt()
        val toolbar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Color.parseColor("#141418"))
            setPadding(hPad, fallbackTopInset + vPad, hPad, vPad)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            root.setOnApplyWindowInsetsListener { _, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                val top = maxOf(bars.top, fallbackTopInset)
                toolbar.setPadding(hPad + bars.left, top + vPad, hPad + bars.right, vPad)
                insets
            }
        }

        val cancelBtn = TextView(activity).apply {
            text = "取消"
            setTextColor(Color.parseColor("#B0B0BC"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            gravity = Gravity.CENTER
            minHeight = (44 * dp).toInt()
            minWidth = (56 * dp).toInt()
            setPadding((12 * dp).toInt(), (8 * dp).toInt(), (12 * dp).toInt(), (8 * dp).toInt())
        }
        val titleView = TextView(activity).apply {
            text = "完成验证后点击「完成」"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val doneBtn = TextView(activity).apply {
            text = "完成"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            gravity = Gravity.CENTER
            minHeight = (40 * dp).toInt()
            minWidth = (68 * dp).toInt()
            setPadding((16 * dp).toInt(), (8 * dp).toInt(), (16 * dp).toInt(), (8 * dp).toInt())
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#FF2E54"))
                cornerRadius = 999f
            }
        }

        toolbar.addView(cancelBtn)
        toolbar.addView(titleView)
        toolbar.addView(doneBtn)

        val webView = WebView(activity).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.useWideViewPort = true
            settings.loadWithOverviewMode = true
            settings.javaScriptCanOpenWindowsAutomatically = true
        }
        val cookieManager = CookieManager.getInstance()
        cookieManager.setAcceptCookie(true)
        cookieManager.setAcceptThirdPartyCookies(webView, true)

        fun finishChallenge(ok: Boolean) {
            if (settled) return
            settled = true
            cookieManager.flush()
            val cookies = cookieManager.getCookie(webView.url ?: url) ?: ""
            val ua = webView.settings.userAgentString ?: ""
            runCatching {
                webView.stopLoading()
                webView.destroy()
            }
            runCatching { dialog.dismiss() }
            if (ok) {
                result.success(mapOf("ok" to true, "cookies" to cookies, "userAgent" to ua))
            } else {
                result.success(mapOf("ok" to false))
            }
        }

        webView.webChromeClient = WebChromeClient()
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, loadedUrl: String?) {
                val current = loadedUrl ?: url
                val cookies = cookieManager.getCookie(current).orEmpty()
                val pageTitle = view?.title.orEmpty().lowercase()
                if (cookies.contains("cf_clearance=") && !pageTitle.contains("just a moment")) {
                    titleView.text = "验证已通过，可点击「完成」"
                    titleView.setTextColor(Color.parseColor("#FF9E2C"))
                }
            }
        }

        cancelBtn.setOnClickListener { finishChallenge(false) }
        doneBtn.setOnClickListener { finishChallenge(true) }
        dialog.setOnCancelListener { finishChallenge(false) }

        root.addView(toolbar)
        root.addView(webView)
        dialog.setContentView(root)
        dialog.show()
        webView.loadUrl(url)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun ensureHiddenWebView(): WebView {
        hiddenWebView?.let { return it }
        val wv = WebView(activity.applicationContext).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.loadsImagesAutomatically = false
            settings.blockNetworkImage = true
        }
        val cm = CookieManager.getInstance()
        cm.setAcceptCookie(true)
        cm.setAcceptThirdPartyCookies(wv, true)
        hiddenWebView = wv
        return wv
    }

    private fun pumpFetchQueue() {
        if (fetchBusy || fetchQueue.isEmpty()) return
        fetchBusy = true
        val req = fetchQueue.removeFirst()
        val wv = ensureHiddenWebView()
        var done = false
        val timeoutRunnable = Runnable {
            if (!done) {
                done = true
                wv.stopLoading()
                req.result.error("timeout", "WebView 请求超时", null)
                fetchBusy = false
                pumpFetchQueue()
            }
        }
        mainHandler.postDelayed(timeoutRunnable, 22_000L)

        wv.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, loadedUrl: String?) {
                if (done) return
                mainHandler.postDelayed({
                    if (done) return@postDelayed
                    wv.evaluateJavascript("document.documentElement ? document.documentElement.outerHTML : ''") { raw ->
                        if (done) return@evaluateJavascript
                        done = true
                        mainHandler.removeCallbacks(timeoutRunnable)
                        val html = runCatching {
                            if (raw == null || raw == "null") "" else JSONArray("[$raw]").getString(0)
                        }.getOrDefault("")
                        req.result.success(
                            mapOf(
                                "ok" to true,
                                "html" to html,
                                "url" to (view?.url ?: req.url)
                            )
                        )
                        fetchBusy = false
                        pumpFetchQueue()
                    }
                }, 250L)
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?
            ) {
                if (done || request?.isForMainFrame != true) return
                done = true
                mainHandler.removeCallbacks(timeoutRunnable)
                req.result.error(
                    "load_error",
                    error?.description?.toString() ?: "WebView 加载失败",
                    null
                )
                fetchBusy = false
                pumpFetchQueue()
            }
        }
        wv.loadUrl(req.url)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        runCatching {
            hiddenWebView?.stopLoading()
            hiddenWebView?.destroy()
        }
        hiddenWebView = null
        fetchQueue.clear()
    }
}
