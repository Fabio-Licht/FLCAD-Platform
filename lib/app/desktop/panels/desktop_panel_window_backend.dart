import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'panel_window_backend.dart';

/// Channel prefix shared by the bridge and the panel windows.
const String panelIntentsChannel = 'flcad.panel.intents';

String panelWindowChannel(String windowId) => 'flcad.panel.window.$windowId';

/// Real backend: `desktop_multi_window` for windows/channels and
/// `window_manager` for the window that runs this isolate.
///
/// Every panel window runs its own engine and controls itself; the main window
/// only creates/closes/focuses it and exchanges messages over versioned
/// channels.
class DesktopPanelWindowBackend implements PanelWindowBackend {
  DesktopPanelWindowBackend({this.isMainWindow = true});

  final bool isMainWindow;
  final Map<String, WindowMethodChannel> _channels = {};

  WindowMethodChannel _channel(String name) => _channels.putIfAbsent(
    name,
    () => WindowMethodChannel(name, mode: ChannelMode.unidirectional),
  );

  @override
  Future<void> setChannelHandler(
    String channelName,
    Future<Object?> Function(String method, Object? args) handler,
  ) async {
    await _channel(
      channelName,
    ).setMethodCallHandler((call) => handler(call.method, call.arguments));
  }

  @override
  Future<void> clearChannelHandler(String channelName) async {
    await _channel(channelName).setMethodCallHandler(null);
  }

  @override
  Future<Object?> invokeChannel(
    String channelName,
    String method, [
    Object? args,
  ]) => _channel(channelName).invokeMethod(method, args);

  @override
  Future<bool> sendWindowControl(
    String windowId,
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      await _channel(
        panelWindowChannel(windowId),
      ).invokeMethod<void>(method, args);
      return true;
    } on Object {
      // The panel window may still be starting: the caller retries.
      return false;
    }
  }

  @override
  Future<String?> createWindow({
    required String arguments,
    required String title,
    required RectData logicalBounds,
    required bool hiddenAtLaunch,
  }) async {
    final String windowId;
    try {
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: arguments,
          hiddenAtLaunch: hiddenAtLaunch,
        ),
      );
      windowId = controller.windowId;
    } on Object catch (error) {
      // Diagnostics for the spike: a failed native window creation must be
      // visible instead of leaving the operator with a stuck panel.
      debugPrint('[panel-window] createWindow failed: $error');
      return null;
    }
    if (windowId.isEmpty) {
      debugPrint('[panel-window] createWindow returned an empty window id');
      return null;
    }
    debugPrint('[panel-window] created window $windowId ($title)');
    return windowId;
  }

  @override
  Future<void> closeWindow(String windowId) async {
    // The panel owns the handler on its own channel and tears *itself* down
    // (`setPreventClose(false)` + `close()`), which destroys the HWND and
    // releases the secondary engine. Hiding would keep a live engine behind an
    // invisible window; `window_manager.destroy()` would post WM_QUIT on the
    // process main thread and take the whole application down.
    final delivered = await sendWindowControl(windowId, 'panel_close');
    if (!delivered) {
      debugPrint('[panel-window] closeWindow could not reach $windowId');
    }
  }

  @override
  Future<void> focusWindow(String windowId) async {
    // The panel focuses itself: window_manager resolves the HWND of the window
    // it runs in, so this restores and raises the right window.
    if (await sendWindowControl(windowId, 'panel_focus')) return;
    try {
      await WindowController.fromWindowId(windowId).show();
    } on Object {
      // Window already gone.
    }
  }

  @override
  Future<void> showWindow(String windowId) async {
    try {
      await WindowController.fromWindowId(windowId).show();
    } on Object {
      // Window already gone.
    }
  }

  @override
  Future<List<String>> listWindowIds() async {
    final windows = await WindowController.getAll();
    return windows.map((controller) => controller.windowId).toList();
  }

  @override
  Future<List<PanelWindowRef>> listWindows() async {
    try {
      final windows = await WindowController.getAll();
      return [
        for (final controller in windows)
          PanelWindowRef(
            windowId: controller.windowId,
            panelId: panelIdFromWindowArguments(controller.arguments),
          ),
      ];
    } on Object catch (error) {
      // A backend that cannot enumerate windows must not break the caller: an
      // empty answer only means "nothing to adopt".
      debugPrint('[panel-window] listWindows failed: $error');
      return const [];
    }
  }

  /// Applies the geometry requested by the main window (runs in the panel).
  static Future<void> applyPanelConfiguration(
    Map<Object?, Object?> arguments,
  ) async {
    final bounds = arguments['bounds'];
    if (bounds is Map) {
      final left = (bounds['left'] as num?)?.toDouble();
      final top = (bounds['top'] as num?)?.toDouble();
      final width = (bounds['width'] as num?)?.toDouble();
      final height = (bounds['height'] as num?)?.toDouble();
      if (left != null &&
          top != null &&
          width != null &&
          height != null &&
          width > 0 &&
          height > 0) {
        await windowManager.setBounds(Rect.fromLTWH(left, top, width, height));
      }
    }
    final title = arguments['title'];
    if (title is String && title.isNotEmpty) {
      await windowManager.setTitle(title);
    }
  }
}
