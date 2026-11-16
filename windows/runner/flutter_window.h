#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// 输入法上下文修复：Flutter 视图重新获得焦点后重建 IMM32 会话。
// 完整定义在 flutter_window.cpp 里（只给这个窗口用），头文件只需要类型名，
// 所以放具名命名空间做前置声明——不能放匿名命名空间，否则与 .cpp 里的定义
// 不是同一个类型。
namespace duanju {
class ImeContextRepair;
}  // namespace duanju

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 输入法上下文修复状态。
  //
  // 刻意声明在 flutter_controller_ **之前**：成员按声明逆序销毁，放最前面才能
  // 最后被销毁。销毁 flutter_controller_ 会连带拆掉 Flutter 视图子窗口并触发
  // WM_NCDESTROY，那个回调还持有指向本对象的指针；若本对象先没了就是 use-after-free。
  std::unique_ptr<duanju::ImeContextRepair> ime_repair_;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> device_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
