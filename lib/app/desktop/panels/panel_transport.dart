/// Transport seam between the main process and panel endpoints.
///
/// MM3 ships an in-memory implementation used by tests and by the two-endpoint
/// harness. A future MethodChannel/isolate transport implements the same
/// interface, so the bridge and the panel shell never learn how messages
/// actually travel.
abstract class PanelTransport {
  void registerMainListener(
    void Function(String panelId, Map<String, Object?> message) listener,
  );

  void registerPanelListener(
    String panelId,
    void Function(Map<String, Object?> message) listener,
  );

  /// Removes the main endpoint listener (bridge disposal).
  void unregisterMainListener();

  /// Removes one panel endpoint listener (panel disposal).
  void unregisterPanelListener(String panelId);

  void sendToPanel(String panelId, Map<String, Object?> message);

  void sendToMain(String panelId, Map<String, Object?> message);

  /// Called when a panel endpoint goes away; the bridge stops delivering.
  void disposePanel(String panelId);

  Future<void> close();
}

/// In-memory transport with synchronous delivery.
///
/// Synchronous delivery keeps the protocol deterministic (no hidden
/// microtasks), which is what the update-loop and cancellation tests need. The
/// log lists are bounded so a long test cannot grow without limit.
class InMemoryPanelTransport implements PanelTransport {
  InMemoryPanelTransport({this.logLimit = 256});

  final int logLimit;

  void Function(String panelId, Map<String, Object?> message)? _mainListener;
  final Map<String, void Function(Map<String, Object?> message)>
  _panelListeners = {};

  final List<Map<String, Object?>> toPanelLog = [];
  final List<Map<String, Object?>> toMainLog = [];
  final List<String> disposedPanels = [];

  bool closed = false;

  /// Test hook: when true the transport logs messages but delivers nothing,
  /// which models a broken channel (the panel must recover by resyncing).
  bool blockDeliveries = false;

  /// Number of messages the bridge delivered to each panel.
  int deliveredTo(String panelId) =>
      toPanelLog.where((message) => message['panelId'] == panelId).length;

  /// Messages of one type sent from the main process.
  Iterable<Map<String, Object?>> toPanelOfType(String type) =>
      toPanelLog.where((message) => message['type'] == type);

  Iterable<Map<String, Object?>> toMainOfType(String type) =>
      toMainLog.where((message) => message['type'] == type);

  @override
  void registerMainListener(
    void Function(String panelId, Map<String, Object?> message) listener,
  ) => _mainListener = listener;

  @override
  void registerPanelListener(
    String panelId,
    void Function(Map<String, Object?> message) listener,
  ) => _panelListeners[panelId] = listener;

  @override
  void unregisterMainListener() => _mainListener = null;

  @override
  void unregisterPanelListener(String panelId) {
    _panelListeners.remove(panelId);
  }

  @override
  void sendToPanel(String panelId, Map<String, Object?> message) {
    if (closed) return;
    _log(toPanelLog, message);
    if (blockDeliveries) return;
    final listener = _panelListeners[panelId];
    if (listener == null) return;
    listener(message);
  }

  @override
  void sendToMain(String panelId, Map<String, Object?> message) {
    if (closed) return;
    _log(toMainLog, message);
    if (blockDeliveries) return;
    _mainListener?.call(panelId, message);
  }

  @override
  void disposePanel(String panelId) {
    _panelListeners.remove(panelId);
    if (!disposedPanels.contains(panelId)) disposedPanels.add(panelId);
  }

  @override
  Future<void> close() async {
    closed = true;
    _panelListeners.clear();
    _mainListener = null;
  }

  void _log(List<Map<String, Object?>> log, Map<String, Object?> message) {
    if (log.length >= logLimit) log.removeAt(0);
    log.add(Map<String, Object?>.unmodifiable(message));
  }
}
