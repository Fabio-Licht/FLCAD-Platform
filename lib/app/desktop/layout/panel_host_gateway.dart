import 'panel_identity.dart';
import 'panel_layout.dart';

/// Request to materialize one panel as its own OS window.
class PanelWindowRequest {
  const PanelWindowRequest({
    required this.panelId,
    required this.title,
    required this.geometry,
    required this.displaySignature,
    required this.displayDevice,
  });

  final PanelId panelId;
  final String title;
  final PanelGeometry geometry;
  final String displaySignature;
  final String displayDevice;

  /// Builds a request from a *detached* layout entry, or `null` when the entry
  /// has no screen geometry (nothing to materialize).
  static PanelWindowRequest? fromEntry(PanelLayoutEntry entry) {
    final geometry = entry.geometry;
    if (!entry.isDetached || geometry == null) return null;
    return PanelWindowRequest(
      panelId: entry.panelId,
      title: panelDescriptor(entry.panelId).title,
      geometry: geometry,
      displaySignature: entry.monitorSignature ?? '',
      displayDevice: entry.monitorDevice ?? '',
    );
  }

  Map<String, Object?> toJson() => {
    'panelId': panelId.name,
    'title': title,
    'geometry': geometry.toJson(),
    'displaySignature': displaySignature,
    'displayDevice': displayDevice,
  };
}

/// One materialized panel window.
class PanelWindowState {
  const PanelWindowState({
    required this.windowId,
    required this.panelId,
    required this.geometry,
    required this.displaySignature,
  });

  final String windowId;
  final PanelId panelId;
  final PanelGeometry geometry;
  final String displaySignature;

  Map<String, Object?> toJson() => {
    'windowId': windowId,
    'panelId': panelId.name,
    'geometry': geometry.toJson(),
    'displaySignature': displaySignature,
  };
}

/// Seam for the secondary-window backend that arrives in a later milestone.
///
/// MM2 ships the layout model only: the default implementation never opens a
/// window, so "detached" stays a modeled state (testable, persisted) instead of
/// a promise of a working window.
abstract class PanelHostGateway {
  List<PanelWindowState> get windows;

  Future<PanelWindowState?> createPanelWindow(PanelWindowRequest request);

  Future<void> movePanelWindow(String windowId, PanelGeometry geometry);

  Future<void> closePanelWindow(String windowId);

  Future<void> closeAllWindows();
}

/// Default backend for this milestone: records nothing, opens nothing.
class NoopPanelHostGateway implements PanelHostGateway {
  const NoopPanelHostGateway();

  @override
  List<PanelWindowState> get windows => const [];

  @override
  Future<PanelWindowState?> createPanelWindow(
    PanelWindowRequest request,
  ) async => null;

  @override
  Future<void> movePanelWindow(String windowId, PanelGeometry geometry) async {}

  @override
  Future<void> closePanelWindow(String windowId) async {}

  @override
  Future<void> closeAllWindows() async {}
}

/// Test/dry-run backend: keeps an in-memory window list so the layout can be
/// validated against a host without creating real windows.
class RecordingPanelHostGateway implements PanelHostGateway {
  RecordingPanelHostGateway();

  final List<PanelWindowRequest> requests = [];
  final Map<String, PanelWindowState> _windows = {};
  int _nextId = 1;

  @override
  List<PanelWindowState> get windows =>
      List<PanelWindowState>.unmodifiable(_windows.values);

  @override
  Future<PanelWindowState?> createPanelWindow(
    PanelWindowRequest request,
  ) async {
    requests.add(request);
    final windowId = 'panel-window-${_nextId++}';
    final state = PanelWindowState(
      windowId: windowId,
      panelId: request.panelId,
      geometry: request.geometry,
      displaySignature: request.displaySignature,
    );
    _windows[windowId] = state;
    return state;
  }

  @override
  Future<void> movePanelWindow(String windowId, PanelGeometry geometry) async {
    final existing = _windows[windowId];
    if (existing == null) return;
    _windows[windowId] = PanelWindowState(
      windowId: existing.windowId,
      panelId: existing.panelId,
      geometry: geometry,
      displaySignature: existing.displaySignature,
    );
  }

  @override
  Future<void> closePanelWindow(String windowId) async {
    _windows.remove(windowId);
  }

  @override
  Future<void> closeAllWindows() async => _windows.clear();
}

/// Applies a layout to a host gateway (used by MM3+ and by tests today).
Future<List<PanelWindowState>> materializeDetachedPanels({
  required PanelLayout layout,
  required PanelHostGateway gateway,
}) async {
  final created = <PanelWindowState>[];
  for (final id in PanelId.values) {
    final request = PanelWindowRequest.fromEntry(layout.entryFor(id));
    if (request == null) continue;
    final state = await gateway.createPanelWindow(request);
    if (state != null) created.add(state);
  }
  return created;
}
