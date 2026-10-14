import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_panel_window_backend.dart';
import 'multi_window_panel_transport.dart';
import 'panel_shell_window.dart';
import 'panel_window_native_bridge.dart';

/// Entry point for detached panel windows.
///
/// `desktop_multi_window` starts every sub-window with the same Dart entrypoint
/// (`main`) and the arguments `["multi_window", windowId, payload]`, so `main`
/// must branch *before* any bootstrap. Nothing CAD-related is imported here: no
/// kernels, no `ProjectManager`, no `CadRuntime`, no command registry.
abstract final class PanelShellEntry {
  static const String _marker = 'multi_window';

  static bool isPanelWindow(List<String> arguments) =>
      arguments.length == 3 && arguments.first == _marker;

  static PanelShellWindowConfig? configFor(List<String> arguments) =>
      isPanelWindow(arguments) ? PanelShellWindowConfig.parse(arguments) : null;

  /// Runs the minimal panel window. Returns false when the arguments do not
  /// describe a panel window, so the caller can fall back to the main app.
  static Future<bool> run(List<String> arguments) async {
    final config = configFor(arguments);
    if (config == null) return false;

    WidgetsFlutterBinding.ensureInitialized();
    // G124-UX.MM4.1A: the runner registers the application plugins in every
    // engine `desktop_multi_window` creates. The hook is
    // `DesktopMultiWindowSetWindowCreatedCallback` in
    // windows/runner/flutter_window.cpp, so window_manager is available here.
    // A build without that hook still runs: the panel shows the limitation
    // instead of dying with a blank window.
    var windowControlAvailable = false;
    try {
      await windowManager.ensureInitialized();
      windowControlAvailable = true;
    } on Object catch (error) {
      debugPrint('[panel-window] window control unavailable: $error');
    }
    final backend = DesktopPanelWindowBackend(isMainWindow: false);
    final transport = MultiWindowPanelTransport(
      backend: backend,
      isMainWindow: false,
      windowId: config.windowId,
    );
    if (windowControlAvailable) {
      try {
        await PanelWindowNativeBridge.registerPanel(config.panelId);
        await windowManager.setTitle('Explorer — painel destacado');
        // The plugin already shows the window (`SW_SHOW`), and this makes the
        // freshly detached panel come to the front even if a build starts it
        // hidden.
        await windowManager.show();
      } on Object {
        windowControlAvailable = false;
      }
    }
    runApp(
      PanelShellWindowApp(
        config: config,
        transport: transport,
        windowControlAvailable: windowControlAvailable,
      ),
    );
    return true;
  }
}
