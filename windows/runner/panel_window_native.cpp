#include "panel_window_native.h"

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr char kChannel[] = "flcad.panel.native_window";

std::mutex g_mutex;
HWND g_main_window = nullptr;
std::unordered_map<std::string, HWND> g_panel_windows;

const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                    const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::string StringArgument(const flutter::EncodableMap* arguments,
                           const char* key) {
  if (arguments == nullptr) return {};
  const auto* value = Find(*arguments, key);
  const auto* string = value == nullptr ? nullptr
                                        : std::get_if<std::string>(value);
  return string == nullptr ? std::string() : *string;
}

bool BindPanel(const std::string& panel_id) {
  std::scoped_lock lock(g_mutex);
  const auto panel = g_panel_windows.find(panel_id);
  if (g_main_window == nullptr || !IsWindow(g_main_window) ||
      panel == g_panel_windows.end() || !IsWindow(panel->second)) {
    return false;
  }

  const HWND panel_window = panel->second;
  LONG_PTR style = GetWindowLongPtr(panel_window, GWL_EXSTYLE);
  style = (style | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW;
  SetWindowLongPtr(panel_window, GWL_EXSTYLE, style);

  // For a top-level window, GWLP_HWNDPARENT is the owner relationship. The
  // owner keeps the tool window above the FLCAD window and hides/minimizes it
  // with the owner, while still allowing it to fall behind other applications.
  SetWindowLongPtr(panel_window, GWLP_HWNDPARENT,
                   reinterpret_cast<LONG_PTR>(g_main_window));
  SetWindowPos(panel_window, g_main_window, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  return true;
}

void UnregisterPanel(const std::string& panel_id, HWND window) {
  std::scoped_lock lock(g_mutex);
  const auto it = g_panel_windows.find(panel_id);
  if (it != g_panel_windows.end() &&
      (window == nullptr || it->second == window)) {
    g_panel_windows.erase(it);
  }
}

void HandleMethod(
    HWND window, bool is_main_window,
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  const auto panel_id = StringArgument(arguments, "panelId");

  if (call.method_name() == "registerPanel") {
    if (is_main_window || panel_id.empty()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    {
      std::scoped_lock lock(g_mutex);
      g_panel_windows[panel_id] = window;
    }
    result->Success(flutter::EncodableValue(BindPanel(panel_id)));
    return;
  }
  if (call.method_name() == "bindPanel") {
    if (!is_main_window || panel_id.empty()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    result->Success(flutter::EncodableValue(BindPanel(panel_id)));
    return;
  }
  if (call.method_name() == "unregisterPanel") {
    if (!is_main_window && !panel_id.empty()) {
      UnregisterPanel(panel_id, window);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  result->NotImplemented();
}

}  // namespace

void RegisterPanelWindowNativePlugin(FlutterDesktopPluginRegistrarRef registrar,
                                     bool is_main_window) {
  auto* plugin_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  const HWND window = GetAncestor(plugin_registrar->GetView()->GetNativeWindow(),
                                  GA_ROOT);
  if (is_main_window) {
    std::scoped_lock lock(g_mutex);
    g_main_window = window;
  }

  static std::vector<std::unique_ptr<
      flutter::MethodChannel<flutter::EncodableValue>>>
      channels;
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      plugin_registrar->messenger(), kChannel,
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [window, is_main_window](const auto& call, auto result) {
        HandleMethod(window, is_main_window, call, std::move(result));
      });
  channels.push_back(std::move(channel));
}
