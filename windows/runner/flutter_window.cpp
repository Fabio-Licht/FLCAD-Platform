#include "flutter_window.h"

#include <optional>

#include <desktop_multi_window/desktop_multi_window_plugin.h>

#include "flutter/generated_plugin_registrant.h"
#include "panel_window_native.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
  RegisterPanelWindowNativePlugin(
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "PanelWindowNativePlugin"),
      true);
  // G124-UX.MM4.1A: every window created by desktop_multi_window owns its own
  // Flutter engine, and method channels are not shared between engines. The
  // plugin exposes the documented hook below so the application plugins
  // (window_manager, screen_retriever, ...) exist in the secondary engine too.
  // The callback runs once per created window, before the plugin registers its
  // own internal channel, and never for this main window.
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    if (controller == nullptr) return;
    auto* flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    auto* registry = flutter_view_controller->engine();
    if (registry == nullptr) return;
    // Panel windows render the projection only: the native CAD viewport host is
    // deliberately not created here, it stays owned by the main window.
    RegisterPlugins(registry);
    RegisterPanelWindowNativePlugin(
        flutter_view_controller->engine()->GetRegistrarForPlugin(
            "PanelWindowNativePlugin"),
        false);
  });
  native_viewport_registrar_ =
      std::make_unique<flutter::PluginRegistrarWindows>(
          flutter_controller_->engine()->GetRegistrarForPlugin(
              "FLCADNativeViewportHost"));
  native_viewport_host_ = std::make_unique<NativeViewportHost>(
      native_viewport_registrar_->messenger(),
      native_viewport_registrar_->texture_registrar());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // The production shell must remain visible even when Dart fails before its
  // first frame. Waiting exclusively for SetNextFrameCallback left a healthy
  // Windows process with no window and no actionable diagnostic.
  Show();

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
  native_viewport_host_.reset();
  native_viewport_registrar_.reset();
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
