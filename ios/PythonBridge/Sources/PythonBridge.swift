import Flutter
import Foundation

/// `guoapp/py` 通道桥：契约与安卓 PyBridge.kt 逐字一致——
/// status/validate/call/dispose 四方法、参数校验错误码 invalid_argument、
/// 运行时错误码 py_runtime_error、结果一律为宿主脚本返回的 JSON 串，
/// 且全部在后台串行队列执行、回调切回主线程，不阻塞平台主线程。
public final class PythonBridge: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "guoapp/py", binaryMessenger: registrar.messenger())
    let instance = PythonBridge()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "status":
      runAsync(result) { try self.statusJson() }
    case "validate":
      guard let source = arguments["source"] as? String else {
        result(FlutterError(code: "invalid_argument", message: "缺少蜘蛛源码", details: nil))
        return
      }
      runAsync(result) { try PythonRuntime.shared.callHost("validate_source_json", arguments: [source]) }
    case "call":
      guard let path = arguments["path"] as? String,
            let request = arguments["request"] as? String else {
        result(FlutterError(code: "invalid_argument", message: "缺少蜘蛛路径或请求", details: nil))
        return
      }
      runAsync(result) { try PythonRuntime.shared.callHost("handle", arguments: [path, request]) }
    case "dispose":
      guard let path = arguments["path"] as? String else {
        result(FlutterError(code: "invalid_argument", message: "缺少蜘蛛路径", details: nil))
        return
      }
      runAsync(result) { try PythonRuntime.shared.callHost("dispose", arguments: [path]) }
    case "disposeAll":
      runAsync(result) { try PythonRuntime.shared.callHost("dispose_all", arguments: []) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func statusJson() throws -> String {
    let runtime = PythonRuntime.shared
    // status 只做文件级探测（框架/stdlib 里程碑/宿主脚本是否在位），不启动
    // 解释器：CPython 真启动只发生在 validate/call/dispose 首次调用时，
    // 启动失败也只以 py_runtime_error 回到 py 功能本身，不拖垮状态查询与主流程。
    guard runtime.probeAvailable() else {
      return "{\"available\":false,\"python\":\"\",\"detail\":\(jsonString("未找到 Python.framework 或宿主脚本（请先跑 scripts/prepare_ios_python.py）"))}"
    }
    // iOS 嵌入式 CPython 无 pip，requests 由备料时生成的 PythonVendor.bundle
    // 提供；缺包时如实写入 detail（Dart 侧只读 available/python，多余字段无碍），供界面与排查使用。
    // 未启动前不探 requests（探活需要解释器），启动后才给该提示。
    let detail = runtime.isInitialized() && !runtime.moduleAvailable("requests")
      ? "iOS 运行时未带 requests 兼容包；蜘蛛须按全协议标准 try 导入并回退 urllib"
      : ""
    return "{\"available\":true,\"python\":\(jsonString(runtime.version())),\"detail\":\(jsonString(detail))}"
  }

  private func runAsync(_ result: @escaping FlutterResult, _ block: @escaping () throws -> String) {
    PythonRuntime.shared.queue.async {
      do {
        let value = try block()
        DispatchQueue.main.async { result(value) }
      } catch let error as PythonRuntimeError {
        DispatchQueue.main.async {
          result(FlutterError(code: "py_runtime_error", message: error.message, details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "py_runtime_error", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func jsonString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let text = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(text.dropFirst().dropLast())
  }
}
