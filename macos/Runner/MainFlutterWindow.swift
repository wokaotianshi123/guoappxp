import CFNetwork
import Cocoa
import FlutterMacOS

#if arch(x86_64)
/// Intel Mac 上 Impeller 会出现主界面和视频花屏，这里把引擎的
/// enableImpeller 改回 false，退回 Skia 渲染（未在实机验证）。
private func useSkiaRendering() {
  guard let method = class_getInstanceMethod(
    FlutterDartProject.self, NSSelectorFromString("enableImpeller")) else { return }
  let disabled: @convention(block) (AnyObject) -> ObjCBool = { _ in false }
  method_setImplementation(method, imp_implementationWithBlock(disabled))
}
#endif

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    #if arch(x86_64)
    useSkiaRendering()
    #endif
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let channel = FlutterMethodChannel(
      name: "duanju/device", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "systemProxy" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
      func address(_ prefix: String) -> String {
        guard (settings["\(prefix)Enable"] as? NSNumber)?.boolValue == true,
              let host = settings["\(prefix)Proxy"] as? String,
              let port = settings["\(prefix)Port"] as? NSNumber,
              !host.isEmpty, port.intValue > 0 else { return "" }
        let name = host.contains(":") ? "[\(host)]" : host
        return "http://\(name):\(port.intValue)"
      }
      let http = address("HTTP")
      let https = address("HTTPS")
      result(["http": http, "https": https.isEmpty ? http : https,
              "bypass": settings["ExceptionsList"] as? [String] ?? [],
              "pac": (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true])
    }

    super.awakeFromNib()
  }
}
