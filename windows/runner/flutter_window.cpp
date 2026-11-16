#include "flutter_window.h"

#include <commctrl.h>
#include <imm.h>

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace duanju {

// Flutter 3.47.x 的 Windows 嵌入层没有维护输入法上下文的生命周期：
// 窗口真实失焦再回到前台后，子窗口手里那个 HIMC 对应的 IMM32→TSF 会话已经过期。
// 此时键盘消息照常送达、输入法也能切换，但 Windows 不再发出
// WM_IME_STARTCOMPOSITION / WM_IME_COMPOSITION，表现为「搜索框只能输入字母、
// 中文候选框再也不出现」，只有退出应用重开（或反复切换焦点碰运气）才恢复。
// 上游 issue：flutter/flutter#190042。
//
// 修法按官方 issue 里给出的 workaround：在一次真实失焦之后重新获得焦点时，
// 若当前没有正在进行的组合输入，就把该窗口的输入法上下文按默认方式重新关联
// 一次（ImmAssociateContextEx + IACE_DEFAULT），并保留原来的打开状态。
// 组合输入进行中绝不动它，否则会把用户正在打的拼音打断。
class ImeContextRepair {
 public:
  void Attach(HWND view) { view_ = view; }

  void Detach() {
    view_ = nullptr;
    lost_focus_ = false;
  }

  // 供 Dart 侧在输入框获得焦点时主动调用。
  void RepairNow() { Repair(); }

  // 处理子窗口（Flutter 视图）的焦点消息。只做旁路修复，不拦截消息。
  // 返回 true 表示调用方应在把消息交给 Flutter 视图之后再执行修复。
  bool Handle(UINT message) {
    if (view_ == nullptr) {
      return false;
    }
    switch (message) {
      case WM_KILLFOCUS:
        // 只有真的丢过焦点，回来时才需要修：应用内部 widget 之间切换焦点
        // 不会触发这个子窗口级别的消息。
        lost_focus_ = true;
        break;
      case WM_SETFOCUS:
        if (lost_focus_) {
          lost_focus_ = false;
          // 修复要等 Flutter 自己处理完 WM_SETFOCUS 再做：那时引擎才把
          // 文本输入客户端接上，此时重建的输入法上下文才能被真正用起来。
          return true;
        }
        break;
      default:
        break;
    }
    return false;
  }

 private:
  // 把窗口的输入法上下文恢复成默认关联。没有正在组合的文本时才做。
  void Repair() {
    if (view_ == nullptr || !IsWindow(view_)) {
      return;
    }
    const HIMC context = ImmGetContext(view_);
    if (context == nullptr) {
      // 拿不到上下文说明这个窗口当前没有输入法会话，交给系统在下次
      // 真正需要时自己创建，这里强行关联反而可能清掉用户的选择。
      return;
    }
    // 正在组合（拼音还没上屏）时不能重置，否则用户正在输入的内容会丢。
    const bool composing = ImmGetCompositionStringW(context, GCS_COMPSTR,
                                                   nullptr, 0) > 0;
    const BOOL open = ImmGetOpenStatus(context);
    ImmReleaseContext(view_, context);
    if (composing) {
      return;
    }
    // 先解除旧的（可能已失效的）关联，再按默认方式重新关联：
    // 两步都做才能让系统为这个窗口重建 IMM32→TSF 会话。
    ImmAssociateContext(view_, nullptr);
    ImmAssociateContextEx(view_, nullptr, IACE_DEFAULT);
    // 保留用户原来的输入法开关状态，不要把中文输入法悄悄关掉。
    if (const HIMC restored = ImmGetContext(view_)) {
      ImmSetOpenStatus(restored, open);
      ImmReleaseContext(view_, restored);
    }
  }

  HWND view_ = nullptr;
  bool lost_focus_ = false;
};

}  // namespace duanju

namespace {

// 输入法、划词翻译、读屏等软件会通过 WM_GETOBJECT 查询应用内的辅助功能
// 控件树。Flutter 的 Windows 视图在最大化 / 全屏后回复该消息会触发闪退，
// 这里让 Flutter 视图直接走默认窗口过程，只对外暴露窗口本身。
//
// 同一个子类化回调顺带处理输入法上下文修复（见上方 ImeContextRepair）。
LRESULT CALLBACK ViewMessageProc(HWND window, UINT message, WPARAM wparam,
                                 LPARAM lparam, UINT_PTR, DWORD_PTR data) {
  if (message == WM_GETOBJECT) {
    return DefWindowProc(window, message, wparam, lparam);
  }
  auto* repair = reinterpret_cast<duanju::ImeContextRepair*>(data);
  if (message == WM_NCDESTROY) {
    if (repair != nullptr) {
      repair->Detach();
    }
    RemoveWindowSubclass(window, ViewMessageProc, 0);
    return DefSubclassProc(window, message, wparam, lparam);
  }
  // 焦点消息交给输入法上下文修复逻辑判断；它只做旁路处理，不拦截消息。
  const bool repair_after = repair != nullptr && repair->Handle(message);
  const LRESULT result = DefSubclassProc(window, message, wparam, lparam);
  if (repair_after) {
    repair->RepairNow();
  }
  return result;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    // 初始化列表顺序必须与头文件里的成员声明顺序一致，否则 /W4 会报 C5038，
    // 而本项目开着 /WX（警告即错误）。
    : ime_repair_(std::make_unique<duanju::ImeContextRepair>()),
      project_(project) {}

FlutterWindow::~FlutterWindow() {
  // 在拆 Flutter 视图之前先摘掉子类化：拆视图会触发 WM_NCDESTROY，而回调里
  // 存着指向 ime_repair_ 的裸指针。虽然成员顺序已经保证 ime_repair_ 最后销毁，
  // 这里再显式摘一次，不依赖顺序这种隐式约定。
  if (flutter_controller_ && flutter_controller_->view()) {
    const HWND view = flutter_controller_->view()->GetNativeWindow();
    if (ime_repair_) ime_repair_->Detach();
    RemoveWindowSubclass(view, ViewMessageProc, 0);
  }
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  device_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "duanju/device",
          &flutter::StandardMethodCodec::GetInstance());
  device_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        // Dart 侧输入框获得焦点时主动要求修一次输入法上下文。
        // 光靠 WM_SETFOCUS 覆盖不到「窗口一直有焦点、只是应用内换了输入框」
        // 的场景，而那种场景下 IMM32→TSF 会话同样可能已经失效。
        if (call.method_name() == "repairIme") {
          if (ime_repair_) ime_repair_->RepairNow();
          result->Success();
          return;
        }
        if (call.method_name() != "playbackPower") {
          result->NotImplemented();
          return;
        }
        SYSTEM_POWER_STATUS power{};
        const bool known = GetSystemPowerStatus(&power) != 0;
        MEMORYSTATUSEX memory{};
        memory.dwLength = sizeof(memory);
        const bool memory_known = GlobalMemoryStatusEx(&memory) != 0;
        flutter::EncodableMap values;
        values[flutter::EncodableValue("batterySaver")] =
            flutter::EncodableValue(known && power.SystemStatusFlag == 1);
        values[flutter::EncodableValue("onBattery")] =
            flutter::EncodableValue(!known || power.ACLineStatus != 1);
        values[flutter::EncodableValue("lowMemory")] =
            flutter::EncodableValue(!memory_known || memory.ullTotalPhys < 4ULL * 1024 * 1024 * 1024);
        result->Success(flutter::EncodableValue(values));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  ime_repair_->Attach(flutter_controller_->view()->GetNativeWindow());
  SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                    ViewMessageProc, 0,
                    reinterpret_cast<DWORD_PTR>(ime_repair_.get()));

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  device_channel_.reset();
  if (ime_repair_) ime_repair_->Detach();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
