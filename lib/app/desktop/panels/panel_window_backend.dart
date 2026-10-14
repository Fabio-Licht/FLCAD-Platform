import 'dart:async';

/// Window + channel seam used by the detachable-panel spike.
///
/// The real implementation talks to `desktop_multi_window` (one native window
/// per panel, each with its own engine) and to `window_manager` (size, position,
/// focus, close) from inside the panel window. The loopback implementation keeps
/// both in memory so the whole routing can be tested without native windows and
/// without a second engine.
abstract class PanelWindowBackend {
  /// Registers the handler that receives messages for [channelName].
  Future<void> setChannelHandler(
    String channelName,
    Future<Object?> Function(String method, Object? args) handler,
  );

  Future<void> clearChannelHandler(String channelName);

  /// Sends a message to a channel (any engine can invoke a unidirectional one).
  Future<Object?> invokeChannel(
    String channelName,
    String method, [
    Object? args,
  ]);

  /// Sends a window-control method to one panel window over the panel channel
  /// (title/geometry). Separate from [invokeChannel] because the panel owns the
  /// handler on that channel.
  Future<bool> sendWindowControl(
    String windowId,
    String method, [
    Map<String, Object?> args = const {},
  ]);

  /// Creates a native panel window and returns its generated id.
  Future<String?> createWindow({
    required String arguments,
    required String title,
    required RectData logicalBounds,
    required bool hiddenAtLaunch,
  });

  Future<void> closeWindow(String windowId);

  Future<void> focusWindow(String windowId);

  Future<void> showWindow(String windowId);

  Future<List<String>> listWindowIds();
}

/// Logical window rectangle (window_manager works in DPI-scaled units).
class RectData {
  const RectData({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  @override
  bool operator ==(Object other) =>
      other is RectData &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() =>
      'RectData(${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}, '
      '${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)})';
}

/// In-memory backend: channels and windows live in maps.
class LoopbackPanelWindowBackend implements PanelWindowBackend {
  final Map<String, Future<Object?> Function(String, Object?)> _handlers = {};
  final Map<String, RectData> windowBounds = {};
  final List<String> createdWindows = [];
  final List<String> closedWindows = [];
  int _nextWindowId = 1;

  /// Messages that could not be delivered (no handler registered), which models
  /// a broken channel.
  final List<String> undelivered = [];

  bool blockChannels = false;

  /// Window-control methods delivered to a panel window (`<windowId>:<method>`),
  /// mirroring the native window channel.
  final List<String> windowControls = [];

  /// Models a panel that honours `panel_close`: the real panel closes its own
  /// window, so it leaves the tracking map. Set to false to model a wedged
  /// engine that keeps its window alive.
  bool honorPanelClose = true;

  /// Number of channels with a registered handler (listener leak check).
  int get registeredHandlers => _handlers.length;

  Iterable<String> get registeredChannelNames => _handlers.keys;

  @override
  Future<void> setChannelHandler(
    String channelName,
    Future<Object?> Function(String method, Object? args) handler,
  ) async => _handlers[channelName] = handler;

  @override
  Future<void> clearChannelHandler(String channelName) async {
    _handlers.remove(channelName);
  }

  @override
  Future<Object?> invokeChannel(
    String channelName,
    String method, [
    Object? args,
  ]) async {
    if (blockChannels) {
      undelivered.add('$channelName:$method');
      return null;
    }
    final handler = _handlers[channelName];
    if (handler == null) {
      undelivered.add('$channelName:$method');
      return null;
    }
    return handler(method, args);
  }

  @override
  Future<bool> sendWindowControl(
    String windowId,
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final handler = _handlers['flcad.panel.window.$windowId'];
    if (handler == null || blockChannels) {
      undelivered.add('flcad.panel.window.$windowId:$method');
      return false;
    }
    windowControls.add('$windowId:$method');
    await handler(method, args);
    return true;
  }

  @override
  Future<String?> createWindow({
    required String arguments,
    required String title,
    required RectData logicalBounds,
    required bool hiddenAtLaunch,
  }) async {
    final id = 'loopback-window-${_nextWindowId++}';
    createdWindows.add(id);
    windowBounds[id] = logicalBounds;
    return id;
  }

  @override
  Future<void> closeWindow(String windowId) async {
    // The real backend asks the panel to close its own window; the panel owns
    // the HWND and releases its engine.
    await sendWindowControl(windowId, 'panel_close');
    if (!honorPanelClose) return;
    closedWindows.add(windowId);
    windowBounds.remove(windowId);
  }

  @override
  Future<void> focusWindow(String windowId) async {
    await sendWindowControl(windowId, 'panel_focus');
  }

  @override
  Future<void> showWindow(String windowId) async {}

  @override
  Future<List<String>> listWindowIds() async =>
      windowBounds.keys.toList(growable: false);
}
