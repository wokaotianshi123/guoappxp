import Cocoa
import FlutterMacOS
import WebKit

/// 应用内 WebView 验证与人机验证页面抓取（macOS）。
///
/// - openChallenge：弹出独立窗口让用户走完 Cloudflare 验证，
///   完成后把 Cookie / UA 交回 Dart，再转给 Go 核心复用同一套指纹。
/// - fetchHtml：用隐藏 WKWebView 抓页面 HTML，供 Go 核心在遇到挑战域名时
///   通过回环 HTTP 服务间接调用。
final class WebViewBridge: NSObject, WKNavigationDelegate {
  private weak var window: NSWindow?
  private let channel: FlutterMethodChannel
  private var hiddenWebView: WKWebView?
  private var fetchQueue: [(url: String, result: FlutterResult)] = []
  private var fetchBusy = false
  private var activeFetch: (url: String, result: FlutterResult)?
  private var fetchTimeout: DispatchWorkItem?
  private var activeChallenge: ChallengeWindowController?

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
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

  private func presentChallenge(url: URL, result: @escaping FlutterResult) {
    if activeChallenge != nil {
      result(["ok": false])
      return
    }
    let controller = ChallengeWindowController(url: url) { [weak self] ok, cookies, userAgent in
      self?.activeChallenge = nil
      if ok {
        result(["ok": true, "cookies": cookies, "userAgent": userAgent])
      } else {
        result(["ok": false])
      }
    }
    activeChallenge = controller
    controller.present(from: window)
  }

  private func ensureHiddenWebView() -> WKWebView {
    if let existing = hiddenWebView { return existing }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
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

private final class ChallengeWindowController: NSObject, WKNavigationDelegate, NSWindowDelegate {
  private let targetURL: URL
  private let completion: (Bool, String, String) -> Void
  private weak var parentWindow: NSWindow?
  private let sheetWindow: NSWindow
  private let titleLabel: NSTextField
  private let webView: WKWebView
  private var finished = false

  init(url: URL, completion: @escaping (Bool, String, String) -> Void) {
    self.targetURL = url
    self.completion = completion

    let rect = NSRect(x: 0, y: 0, width: 900, height: 640)
    self.sheetWindow = NSWindow(
      contentRect: rect,
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    self.sheetWindow.title = "人机验证"
    self.sheetWindow.isReleasedWhenClosed = false

    self.titleLabel = NSTextField(labelWithString: "完成验证后点「完成」")
    self.titleLabel.alignment = .center
    self.titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    self.titleLabel.textColor = .white

    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    self.webView = WKWebView(frame: .zero, configuration: config)

    super.init()
    self.sheetWindow.delegate = self
    self.webView.navigationDelegate = self
    setupLayout()
  }

  private func setupLayout() {
    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1).cgColor

    let toolbar = NSView()
    toolbar.wantsLayer = true
    toolbar.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1).cgColor
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
    cancelButton.bezelStyle = .rounded
    cancelButton.keyEquivalent = "\u{1b}"
    cancelButton.translatesAutoresizingMaskIntoConstraints = false

    let doneButton = NSButton(title: "完成", target: self, action: #selector(doneTapped))
    doneButton.bezelStyle = .rounded
    doneButton.keyEquivalent = "\r"
    doneButton.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    webView.translatesAutoresizingMaskIntoConstraints = false

    toolbar.addSubview(cancelButton)
    toolbar.addSubview(titleLabel)
    toolbar.addSubview(doneButton)
    root.addSubview(toolbar)
    root.addSubview(webView)
    sheetWindow.contentView = root

    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: root.topAnchor),
      toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 48),

      cancelButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
      cancelButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

      doneButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
      doneButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

      titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
      titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: cancelButton.trailingAnchor, constant: 12),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: doneButton.leadingAnchor, constant: -12),
      titleLabel.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),

      webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
  }

  func present(from parent: NSWindow?) {
    self.parentWindow = parent
    webView.load(URLRequest(url: targetURL))
    if let parent {
      parent.beginSheet(sheetWindow) { _ in }
    } else {
      sheetWindow.center()
      sheetWindow.makeKeyAndOrderFront(nil)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let host = (webView.url ?? targetURL).host ?? ""
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
      let hasClearance = cookies.contains {
        $0.name == "cf_clearance" &&
          (host.isEmpty || $0.domain.contains(host) || host.contains($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))))
      }
      let pageTitle = (webView.title ?? "").lowercased()
      if hasClearance && !pageTitle.contains("just a moment") {
        DispatchQueue.main.async {
          self?.titleLabel.stringValue = "验证已通过，可点「完成」"
          self?.titleLabel.textColor = NSColor(red: 1.0, green: 0.62, blue: 0.17, alpha: 1)
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

  func windowWillClose(_ notification: Notification) {
    finish(ok: false)
  }

  private func closeSheet() {
    if let parent = parentWindow, sheetWindow.sheetParent != nil {
      parent.endSheet(sheetWindow)
    }
    sheetWindow.orderOut(nil)
  }

  private func finish(ok: Bool) {
    guard !finished else { return }
    finished = true
    if !ok {
      closeSheet()
      completion(false, "", "")
      return
    }
    let host = (webView.url ?? targetURL).host ?? ""
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      let matched = cookies.filter { cookie in
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.isEmpty || host == domain || host.hasSuffix("." + domain)
      }
      let cookieHeader = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      DispatchQueue.main.async {
        self.webView.evaluateJavaScript("navigator.userAgent") { uaVal, _ in
          let ua = uaVal as? String ?? ""
          DispatchQueue.main.async {
            self.closeSheet()
            self.completion(true, cookieHeader, ua)
          }
        }
      }
    }
  }
}
