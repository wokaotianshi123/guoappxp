import Flutter
import UIKit
import WebKit

/// 应用内 WebView 验证与人机验证页面抓取（iOS）。
///
/// - openChallenge：弹出可见的浏览器页让用户走完 Cloudflare 验证，
///   完成后把 Cookie / UA 交回 Dart，再转给 Go 核心复用同一套指纹。
/// - fetchHtml：用隐藏 WKWebView 抓页面 HTML，供 Go 核心在遇到挑战域名时
///   通过回环 HTTP 服务间接调用。
final class WebViewBridge: NSObject, WKNavigationDelegate {
  private let channel: FlutterMethodChannel
  private var hiddenWebView: WKWebView?
  private var fetchQueue: [(url: String, result: FlutterResult)] = []
  private var fetchBusy = false
  private var activeFetch: (url: String, result: FlutterResult)?
  private var fetchTimeout: DispatchWorkItem?

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(name: "guoapp/webview", binaryMessenger: messenger)
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let urlString = (args?["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !urlString.isEmpty, let url = URL(string: urlString) else {
      result(FlutterError(code: "invalid_args", message: "缺少有效地址", details: nil))
      return
    }
    switch call.method {
    case "openChallenge":
      DispatchQueue.main.async { self.presentChallenge(url: url, result: result) }
    case "fetchHtml":
      DispatchQueue.main.async {
        self.fetchQueue.append((url.absoluteString, result))
        self.pumpFetchQueue()
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  private func presentChallenge(url: URL, result: @escaping FlutterResult) {
    guard let presenter = topViewController() else {
      result(["ok": false])
      return
    }
    let controller = ChallengeViewController(url: url) { ok, cookies, userAgent in
      if ok {
        result(["ok": true, "cookies": cookies, "userAgent": userAgent])
      } else {
        result(["ok": false])
      }
    }
    let nav = UINavigationController(rootViewController: controller)
    nav.modalPresentationStyle = .pageSheet
    presenter.present(nav, animated: true)
  }

  private func ensureHiddenWebView() -> WKWebView {
    if let existing = hiddenWebView { return existing }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
    wv.navigationDelegate = self
    hiddenWebView = wv
    return wv
  }

  private func pumpFetchQueue() {
    guard !fetchBusy, !fetchQueue.isEmpty else { return }
    fetchBusy = true
    let item = fetchQueue.removeFirst()
    activeFetch = item
    guard let url = URL(string: item.url) else {
      activeFetch = nil
      fetchBusy = false
      item.result(FlutterError(code: "invalid_args", message: "无效地址", details: nil))
      pumpFetchQueue()
      return
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self, let pending = self.activeFetch else { return }
      self.activeFetch = nil
      self.hiddenWebView?.stopLoading()
      pending.result(FlutterError(code: "timeout", message: "WebView 请求超时", details: nil))
      self.fetchBusy = false
      self.pumpFetchQueue()
    }
    fetchTimeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 22, execute: work)
    ensureHiddenWebView().load(URLRequest(url: url))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard activeFetch != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self, let pending = self.activeFetch else { return }
      webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''") { value, _ in
        guard let current = self.activeFetch, current.url == pending.url else { return }
        self.activeFetch = nil
        self.fetchTimeout?.cancel()
        self.fetchTimeout = nil
        let html = value as? String ?? ""
        current.result(["ok": true, "html": html, "url": webView.url?.absoluteString ?? pending.url])
        self.fetchBusy = false
        self.pumpFetchQueue()
      }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finishWithError(error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    finishWithError(error)
  }

  private func finishWithError(_ error: Error) {
    guard let pending = activeFetch else { return }
    activeFetch = nil
    fetchTimeout?.cancel()
    fetchTimeout = nil
    pending.result(FlutterError(code: "load_error", message: error.localizedDescription, details: nil))
    fetchBusy = false
    pumpFetchQueue()
  }
}

private final class ChallengeViewController: UIViewController, WKNavigationDelegate {
  private let targetURL: URL
  private let completion: (Bool, String, String) -> Void
  private var webView: WKWebView!
  private var finished = false

  init(url: URL, completion: @escaping (Bool, String, String) -> Void) {
    self.targetURL = url
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "完成验证后点「完成」"
    view.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancelTapped))
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(doneTapped))

    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    webView = WKWebView(frame: view.bounds, configuration: config)
    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.navigationDelegate = self
    view.addSubview(webView)
    webView.load(URLRequest(url: targetURL))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let host = (webView.url ?? targetURL).host ?? ""
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
      let hasClearance = cookies.contains { $0.name == "cf_clearance" && (host.isEmpty || $0.domain.contains(host) || host.contains($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))) }
      let pageTitle = (webView.title ?? "").lowercased()
      if hasClearance && !pageTitle.contains("just a moment") {
        DispatchQueue.main.async {
          self?.title = "验证已通过，可点「完成」"
        }
      }
    }
  }

  @objc private func cancelTapped() {
    finish(ok: false)
  }

  @objc private func doneTapped() {
    finish(ok: true)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed && !finished {
      finish(ok: false)
    }
  }

  private func finish(ok: Bool) {
    guard !finished else { return }
    finished = true
    if !ok {
      dismiss(animated: true) { self.completion(false, "", "") }
      return
    }
    let host = (webView.url ?? targetURL).host ?? ""
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      let matched = cookies.filter { cookie in
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.isEmpty || host == domain || host.hasSuffix("." + domain)
      }
      let cookieHeader = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      self.webView.evaluateJavaScript("navigator.userAgent") { uaVal, _ in
        let ua = uaVal as? String ?? ""
        DispatchQueue.main.async {
          self.dismiss(animated: true) { self.completion(true, cookieHeader, ua) }
        }
      }
    }
  }
}
