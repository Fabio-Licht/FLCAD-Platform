import '../layout/panel_identity.dart';
import 'panel_protocol.dart';
import 'panel_transport.dart';
import 'panel_view_model.dart';

/// Panel-process side of the protocol.
///
/// It holds nothing but the received projection and the requests it sent: no
/// CAD runtime, no kernel, no project manager and no command registry. It never
/// writes files and never reacts to a snapshot by sending a new intent, which is
/// what makes an update loop between snapshot and intent impossible by
/// construction.
class PanelShellEndpoint {
  PanelShellEndpoint({
    required this.panelId,
    required this.transport,
    this.protocolVersion = PanelProtocolVersion.current,
    this.capabilities = PanelCapabilities.all,
    this.limits = const PanelProtocolLimits(),
    this.clientInstanceId = 'panel-shell',
  });

  final PanelId panelId;
  final PanelTransport transport;
  final PanelProtocolVersion protocolVersion;
  final List<String> capabilities;
  final PanelProtocolLimits limits;
  final String clientInstanceId;

  PanelLifecycleState lifecycle = PanelLifecycleState.disconnected;
  Map<String, Object?> viewModel = const {};
  int revision = 0;
  int? sessionId;
  String? projectId;
  bool viewModelIsStale = false;

  final List<PanelResult> results = [];
  final List<PanelProtocolException> protocolErrors = [];
  int droppedOutOfOrderSnapshots = 0;
  int droppedStaleResults = 0;
  int resyncRequests = 0;
  int snapshotsApplied = 0;

  /// Heavy keys the bridge had to omit in the last snapshot.
  List<String> lastOmittedKeys = const [];

  final List<void Function(Map<String, Object?> viewModel)>
  _viewModelListeners = [];
  final List<void Function(PanelLifecycleState state)> _lifecycleListeners = [];

  int _requestCounter = 0;
  bool _resyncPending = false;
  bool _connected = false;

  bool get isConnected => _connected;

  void onViewModelChanged(
    void Function(Map<String, Object?> viewModel) listener,
  ) => _viewModelListeners.add(listener);

  void onLifecycleChanged(void Function(PanelLifecycleState state) listener) =>
      _lifecycleListeners.add(listener);

  /// Registers with the main process and asks for the initial full snapshot.
  void connect({bool resync = false}) {
    if (!_connected) {
      transport.registerPanelListener(panelId.name, _handle);
      _connected = true;
    }
    if (resync) resyncRequests++;
    _send(
      PanelHello(
        panelId: panelId,
        protocolVersion: protocolVersion,
        capabilities: capabilities,
        clientInstanceId: clientInstanceId,
        resync: resync,
      ),
    );
  }

  /// Asks for a brand-new full snapshot (recovery path after a gap).
  void requestResync() {
    _resyncPending = true;
    connect(resync: true);
  }

  Future<String> setSelection(Iterable<String> ids) async {
    final requestId = _nextRequestId();
    _send(
      PanelIntent(
        panelId: panelId,
        sessionId: sessionId ?? -1,
        projectId: projectId,
        action: panelActionSelectionSet,
        params: {'ids': ids.toList(growable: false)},
        requestId: requestId,
        baseRevision: revision,
      ),
    );
    return requestId;
  }

  Future<String> setVisibility(String id, {required bool visible}) async {
    final requestId = _nextRequestId();
    _send(
      PanelIntent(
        panelId: panelId,
        sessionId: sessionId ?? -1,
        projectId: projectId,
        action: panelActionVisibilitySet,
        params: {'id': id, 'visible': visible},
        requestId: requestId,
        baseRevision: revision,
      ),
    );
    return requestId;
  }

  Future<String> editDrivingDimension({
    required String entityId,
    required double value,
  }) async {
    final requestId = _nextRequestId();
    _send(
      PanelIntent(
        panelId: panelId,
        sessionId: sessionId ?? -1,
        projectId: projectId,
        action: panelActionInspectorDimensionEdit,
        params: {'entityId': entityId, 'value': value},
        requestId: requestId,
        baseRevision: revision,
      ),
    );
    return requestId;
  }

  void dispose() {
    if (!_connected) return;
    _connected = false;
    transport.unregisterPanelListener(panelId.name);
    transport.disposePanel(panelId.name);
    lifecycle = PanelLifecycleState.disconnected;
    viewModel = const {};
    viewModelIsStale = true;
  }

  String _nextRequestId() => '${panelId.name}-${++_requestCounter}';

  void _send(PanelMessage message) =>
      transport.sendToMain(panelId.name, message.toJson());

  void _handle(Map<String, Object?> raw) {
    if (panelPayloadSize(raw) > limits.maxMessageBytes) {
      protocolErrors.add(
        PanelProtocolException(
          PanelErrorCode.payloadTooLarge,
          'message exceeds ${limits.maxMessageBytes} bytes.',
        ),
      );
      return;
    }
    final PanelMessage message;
    try {
      message = decodePanelMessage(raw, limits: limits);
    } on PanelProtocolException catch (error) {
      protocolErrors.add(error);
      return;
    }
    switch (message) {
      case PanelSnapshot snapshot:
        _applySnapshot(snapshot);
      case PanelLifecycle lifecycle:
        _applyLifecycle(lifecycle);
      case PanelResult result:
        if (result.panelId != panelId) return;
        if (result.sessionId != null &&
            sessionId != null &&
            result.sessionId != sessionId) {
          // A late answer from a previous session must not be mistaken for the
          // answer to a new request.
          droppedStaleResults++;
          return;
        }
        results.add(result);
      case PanelHello():
      case PanelIntent():
        // Panels never receive hellos/intents from the main process.
        break;
    }
  }

  void _applySnapshot(PanelSnapshot snapshot) {
    if (snapshot.panelId != panelId) return;
    if (snapshot.sessionId != sessionId) {
      // A new session only starts from a full snapshot.
      if (!snapshot.full) {
        droppedOutOfOrderSnapshots++;
        return;
      }
      sessionId = snapshot.sessionId;
      revision = 0;
      viewModel = const {};
    }
    if (!snapshot.full) {
      if (snapshot.revision <= revision) {
        // Rule 4: older revisions never overwrite newer state.
        droppedOutOfOrderSnapshots++;
        return;
      }
      if (snapshot.revision > revision + 1) {
        // A gap means a patch was lost: ask for a full snapshot instead of
        // applying a partial state.
        droppedOutOfOrderSnapshots++;
        if (!_resyncPending) requestResync();
        return;
      }
    }
    final update = PanelViewModel.merge(viewModel, snapshot);
    viewModel = Map<String, Object?>.unmodifiable(update.viewModel);
    revision = snapshot.revision;
    projectId = snapshot.projectId;
    lastOmittedKeys = snapshot.omittedKeys;
    viewModelIsStale = false;
    snapshotsApplied++;
    _resyncPending = false;
    for (final listener in List<void Function(Map<String, Object?>)>.of(
      _viewModelListeners,
    )) {
      listener(viewModel);
    }
  }

  void _applyLifecycle(PanelLifecycle message) {
    if (message.panelId != panelId) return;
    lifecycle = message.state;
    if (message.sessionId != null) sessionId = message.sessionId;
    if (message.projectId != null) projectId = message.projectId;
    switch (message.state) {
      case PanelLifecycleState.disconnected:
        viewModel = const {};
        viewModelIsStale = true;
      case PanelLifecycleState.suspended:
        // Keep the last projection for a fast redraw, but mark it stale.
        viewModelIsStale = true;
        _resyncPending = true;
      case PanelLifecycleState.ready:
        viewModelIsStale = false;
      case PanelLifecycleState.connected:
        break;
    }
    for (final listener in List<void Function(PanelLifecycleState)>.of(
      _lifecycleListeners,
    )) {
      listener(lifecycle);
    }
  }
}
