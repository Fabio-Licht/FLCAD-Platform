import 'dart:async';
import 'dart:collection';

import '../layout/panel_identity.dart';
import 'panel_protocol.dart';
import 'panel_session_source.dart';
import 'panel_transport.dart';
import 'panel_view_model.dart';

/// Per-panel state kept by the main process.
class PanelBridgeConnection {
  PanelBridgeConnection(this.panelId);

  final PanelId panelId;
  bool connected = false;
  bool ready = false;
  Set<String> capabilities = const {};
  String clientInstanceId = 'panel';
  int? sessionId;
  String? projectId;
  int lastRevisionSent = 0;
  Map<String, Object?> lastViewModel = const {};
  bool pendingFlush = false;
  final LinkedHashMap<String, PanelResult> results = LinkedHashMap();

  /// Fingerprint of the intent each cached requestId answered, so a reused id
  /// with a different payload is refused instead of replaying a wrong answer.
  final Map<String, String> requestFingerprints = {};
  int snapshotsSent = 0;
  int replayedIntents = 0;
}

/// Main-process side of the panel protocol.
///
/// It owns the authoritative state binding ([PanelSessionSource]), the outgoing
/// revision counter, coalescing, the intent whitelist and the idempotency cache.
/// It never creates a CAD controller: mutations are delegated to the session's
/// own APIs.
class PanelBridge {
  PanelBridge({
    required this.transport,
    required this.source,
    this.limits = const PanelProtocolLimits(),
    this.maxMessageDepth = 8,
  });

  final PanelTransport transport;
  final PanelSessionSource source;
  final PanelProtocolLimits limits;

  /// Re-entrancy guard: a snapshot that triggers another message would mean an
  /// update loop between the bridge and a panel.
  final int maxMessageDepth;

  final Map<PanelId, PanelBridgeConnection> _panels = {};
  int _revision = 0;
  int _sessionId = -1;
  String? _projectId;
  bool _started = false;
  bool _disposed = false;
  bool _flushScheduled = false;
  bool _flushing = false;
  int _messageDepth = 0;

  int coalescedFlushes = 0;
  int snapshotsSent = 0;
  int intentsHandled = 0;
  int intentsRejected = 0;
  int sessionChanges = 0;
  int messageLoopsDetected = 0;
  int snapshotsRefused = 0;

  int get revision => _revision;
  int get messageDepth => _messageDepth;
  Iterable<PanelBridgeConnection> get connections => _panels.values;
  PanelBridgeConnection? connectionFor(PanelId panelId) => _panels[panelId];

  void start() {
    if (_started) return;
    _started = true;
    transport.registerMainListener(_onPanelMessage);
    source.addListener(_onSourceChanged);
    _syncSession(initial: true);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    source.removeListener(_onSourceChanged);
    transport.unregisterMainListener();
    for (final connection in _panels.values) {
      transport.unregisterPanelListener(connection.panelId.name);
    }
    _panels.clear();
  }

  /// Delivers every coalesced change immediately (tests and shutdown paths).
  void flushPending() {
    if (_disposed || _flushing) return;
    _flushing = true;
    try {
      for (final connection in _panels.values) {
        if (!connection.connected || !connection.pendingFlush) continue;
        connection.pendingFlush = false;
        _deliver(connection, full: false);
      }
    } finally {
      _flushing = false;
    }
  }

  /// Ends a panel session from the main side.
  Future<void> disconnectPanel(
    PanelId panelId, {
    String reason = 'closed',
  }) async {
    final connection = _panels.remove(panelId);
    if (connection == null) return;
    connection.connected = false;
    transport.sendToPanel(
      panelId.name,
      PanelLifecycle(
        panelId: panelId,
        state: PanelLifecycleState.disconnected,
        reason: reason,
      ).toJson(),
    );
    transport.unregisterPanelListener(panelId.name);
    transport.disposePanel(panelId.name);
  }

  // ---------------------------------------------------------------- messages

  void _onPanelMessage(String panelId, Map<String, Object?> raw) {
    _messageDepth++;
    try {
      if (_messageDepth > maxMessageDepth) {
        messageLoopsDetected++;
        throw const PanelProtocolException(
          PanelErrorCode.internalError,
          'Message loop detected between the bridge and a panel.',
        );
      }
      final message = decodePanelMessage(raw, limits: limits);
      if (panelPayloadSize(raw) > limits.maxMessageBytes) {
        throw PanelProtocolException(
          PanelErrorCode.payloadTooLarge,
          'message exceeds ${limits.maxMessageBytes} bytes.',
        );
      }
      switch (message) {
        case PanelHello hello:
          _handleHello(hello);
        case PanelIntent intent:
          unawaited(_handleIntent(intent));
        case PanelResult():
        case PanelSnapshot():
        case PanelLifecycle():
          // The main process is the source of truth: those never come from a
          // panel. Ignoring them keeps the direction of the protocol strict.
          break;
      }
    } on PanelProtocolException {
      // Typed rejections are surfaced to the panel inside the handlers.
      rethrow;
    } finally {
      _messageDepth--;
    }
  }

  void _handleHello(PanelHello hello) {
    final connection = _panels.putIfAbsent(
      hello.panelId,
      () => PanelBridgeConnection(hello.panelId),
    );
    if (!PanelProtocolVersion.current.accepts(hello.protocolVersion)) {
      connection.connected = false;
      transport.sendToPanel(
        hello.panelId.name,
        PanelLifecycle(
          panelId: hello.panelId,
          state: PanelLifecycleState.disconnected,
          reason: 'unsupported-version ${hello.protocolVersion}',
        ).toJson(),
      );
      throw PanelProtocolException(
        PanelErrorCode.unsupportedVersion,
        'panel version ${hello.protocolVersion} is not accepted by '
        '${PanelProtocolVersion.current}.',
      );
    }

    // A hello is also the reconnect path: reset everything the panel had so the
    // full snapshot that follows is the single source of truth.
    connection
      ..connected = true
      ..capabilities = hello.capabilities.toSet()
      ..clientInstanceId = hello.clientInstanceId
      ..pendingFlush = false
      ..lastViewModel = const {};
    connection.results.clear();
    connection.requestFingerprints.clear();
    connection.sessionId = source.sessionId;
    connection.projectId = source.projectId;
    connection.ready = source.isReady;

    transport.sendToPanel(
      hello.panelId.name,
      PanelLifecycle(
        panelId: hello.panelId,
        state: source.isReady
            ? PanelLifecycleState.ready
            : PanelLifecycleState.connected,
        sessionId: source.sessionId,
        projectId: source.projectId,
      ).toJson(),
    );
    _deliver(connection, full: true);
  }

  Future<void> _handleIntent(PanelIntent intent) async {
    final connection = _panels[intent.panelId];
    if (connection == null || !connection.connected) {
      _reject(intent, PanelErrorCode.notReady, 'panel is not connected');
      return;
    }

    // Rule 5: idempotency by requestId - the same request is never applied
    // twice, even if the panel retries after a transport hiccup.
    final cached = connection.results[intent.requestId];
    if (cached != null) {
      final fingerprint = _intentFingerprint(intent);
      if (connection.requestFingerprints[intent.requestId] != fingerprint) {
        // Reusing a requestId for a different intent would replay the wrong
        // answer, so it is refused explicitly.
        connection.results.remove(intent.requestId);
        connection.requestFingerprints.remove(intent.requestId);
        _reject(
          intent,
          PanelErrorCode.conflictingRequestId,
          'requestId ${intent.requestId} was already used for another intent',
        );
        return;
      }
      connection.replayedIntents++;
      transport.sendToPanel(
        intent.panelId.name,
        PanelResult(
          requestId: cached.requestId,
          panelId: cached.panelId,
          ok: cached.ok,
          revision: cached.revision,
          sessionId: cached.sessionId,
          errorCode: cached.errorCode,
          message: cached.message,
          replayed: true,
        ).toJson(),
      );
      return;
    }

    // Rule 3: messages from an old session or project are refused.
    if (intent.sessionId != source.sessionId) {
      _reject(
        intent,
        PanelErrorCode.staleSession,
        'intent session ${intent.sessionId} is not the current '
        '${source.sessionId}',
      );
      return;
    }
    if (intent.projectId != source.projectId) {
      _reject(
        intent,
        PanelErrorCode.staleProject,
        'intent project ${intent.projectId} is not the current '
        '${source.projectId}',
      );
      return;
    }
    if (intent.baseRevision != null &&
        intent.baseRevision! > connection.lastRevisionSent) {
      _reject(
        intent,
        PanelErrorCode.outOfOrderRevision,
        'intent base revision ${intent.baseRevision} is ahead of '
        '${connection.lastRevisionSent}',
      );
      return;
    }
    if (panelPayloadSize(intent.toJson()) > limits.maxMessageBytes) {
      _reject(
        intent,
        PanelErrorCode.payloadTooLarge,
        'intent exceeds ${limits.maxMessageBytes} bytes',
      );
      return;
    }

    // Rules 6 and 7: whitelist, capability and payload validation run before
    // anything reaches the CAD session.
    try {
      validatePanelAction(
        action: intent.action,
        params: intent.params,
        grantedCapabilities: connection.capabilities,
        limits: limits,
      );
    } on PanelProtocolException catch (error) {
      _reject(intent, error.code, error.message);
      return;
    }

    final sessionAtValidation = source.sessionId;
    final projectAtValidation = source.projectId;
    try {
      switch (intent.action) {
        case panelActionSelectionSet:
          final ids = (intent.params['ids']! as List).cast<String>().toSet();
          await source.applySelection(ids);
        case panelActionVisibilitySet:
          if (!source.supportsVisibility) {
            _reject(
              intent,
              PanelErrorCode.unknownAction,
              'visibility is not available in this session',
            );
            return;
          }
          await source.setEntityVisibility(
            intent.params['id']! as String,
            visible: intent.params['visible']! as bool,
          );
      }
    } on Object catch (error) {
      _reject(intent, PanelErrorCode.internalError, '$error');
      return;
    }

    // Rule 3 (second half): a project switch while the intent was in flight
    // invalidates the answer - the panel must resync.
    if (source.sessionId != sessionAtValidation ||
        source.projectId != projectAtValidation) {
      _reject(
        intent,
        PanelErrorCode.staleSession,
        'the session changed while the intent was being applied',
      );
      return;
    }

    intentsHandled++;
    // Deliver the resulting state before the result so the revision it carries
    // is already observable by the panel.
    final connectionState = _panels[intent.panelId] ?? connection;
    connectionState.pendingFlush = false;
    _deliver(connectionState, full: false);
    final result = PanelResult(
      requestId: intent.requestId,
      panelId: intent.panelId,
      ok: true,
      revision: connectionState.lastRevisionSent,
      sessionId: source.sessionId,
    );
    _rememberResult(connectionState, result, _intentFingerprint(intent));
    transport.sendToPanel(intent.panelId.name, result.toJson());
  }

  void _reject(PanelIntent intent, PanelErrorCode code, String message) {
    intentsRejected++;
    final connection = _panels[intent.panelId];
    final result = PanelResult(
      requestId: intent.requestId,
      panelId: intent.panelId,
      ok: false,
      revision: connection?.lastRevisionSent ?? _revision,
      sessionId: source.sessionId,
      errorCode: code,
      message: message,
    );
    if (connection != null) {
      _rememberResult(connection, result, _intentFingerprint(intent));
    }
    transport.sendToPanel(intent.panelId.name, result.toJson());
  }

  void _rememberResult(
    PanelBridgeConnection connection,
    PanelResult result,
    String fingerprint,
  ) {
    connection.results[result.requestId] = result;
    connection.requestFingerprints[result.requestId] = fingerprint;
    while (connection.results.length > limits.maxResultCache) {
      final evicted = connection.results.keys.first;
      connection.results.remove(evicted);
      connection.requestFingerprints.remove(evicted);
    }
  }

  /// Canonical identity of an intent: same id + same payload means "the same
  /// request"; anything else is a conflicting reuse.
  String _intentFingerprint(PanelIntent intent) {
    final keys = intent.params.keys.toList()..sort();
    final buffer = StringBuffer(intent.action);
    for (final key in keys) {
      buffer
        ..write('|')
        ..write(key)
        ..write('=')
        ..write('${intent.params[key]}');
    }
    return buffer.toString();
  }

  // ------------------------------------------------------------------ state

  void _onSourceChanged() {
    if (_disposed) return;
    if (_syncSession()) return;
    for (final connection in _panels.values) {
      if (!connection.connected) continue;
      connection.pendingFlush = true;
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushScheduled || _disposed) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      coalescedFlushes++;
      flushPending();
    });
  }

  /// Returns true when the session/project changed and panels were resynced.
  bool _syncSession({bool initial = false}) {
    final sessionId = source.sessionId;
    final projectId = source.projectId;
    if (!initial && sessionId == _sessionId && projectId == _projectId) {
      return false;
    }
    final changed =
        !initial && (sessionId != _sessionId || projectId != _projectId);
    _sessionId = sessionId;
    _projectId = projectId;
    if (projectId == null || !source.isReady) {
      for (final connection in _panels.values) {
        if (!connection.connected) continue;
        connection.pendingFlush = false;
        connection.ready = false;
        // Keep the last projection on the panel (marked stale by the
        // lifecycle) instead of pushing an empty document.
        transport.sendToPanel(
          connection.panelId.name,
          PanelLifecycle(
            panelId: connection.panelId,
            state: PanelLifecycleState.suspended,
            sessionId: sessionId,
            reason: 'document-closed',
          ).toJson(),
        );
      }
      if (changed) sessionChanges++;
      return true;
    }
    if (!changed) return false;
    sessionChanges++;
    for (final connection in _panels.values) {
      if (!connection.connected) continue;
      // Rule 10: cancel pending deliveries and forget the previous session's
      // answers; the next snapshot is always complete.
      connection.pendingFlush = false;
      connection.lastViewModel = const {};
      connection.results.clear();
      connection.requestFingerprints.clear();
      connection.ready = true;
      transport.sendToPanel(
        connection.panelId.name,
        PanelLifecycle(
          panelId: connection.panelId,
          state: PanelLifecycleState.ready,
          sessionId: sessionId,
          projectId: projectId,
          reason: 'session-changed',
        ).toJson(),
      );
      _deliver(connection, full: true);
    }
    return true;
  }

  void _deliver(PanelBridgeConnection connection, {required bool full}) {
    if (!connection.connected || _disposed) return;
    final viewModel = source.viewModel(
      panelId: connection.panelId,
      limits: limits,
    );
    var changedKeys = full
        ? PanelViewModelKeys.all
        : PanelViewModel.changedKeys(connection.lastViewModel, viewModel);
    if (!full && changedKeys.isEmpty) return;
    if (full) changedKeys = PanelViewModelKeys.all;
    var payload = full
        ? viewModel
        : {for (final key in changedKeys) key: viewModel[key]};

    // Integrity: the *whole serialized message* must respect the budget, not
    // only the view-model field. Heavy keys are omitted explicitly (the panel
    // learns about it and can ask for a paginated projection later) instead of
    // being truncated in silence.
    final omitted = <String>[];
    if (_messageSize(connection, payload, full, changedKeys, omitted) >
        limits.maxMessageBytes) {
      final heavyKeys = [
        if (payload.containsKey(PanelViewModelKeys.entities))
          PanelViewModelKeys.entities,
        if (payload.containsKey(PanelViewModelKeys.selection))
          PanelViewModelKeys.selection,
      ];
      for (final key in heavyKeys) {
        payload = {...payload, PanelViewModelKeys.truncated: true}..remove(key);
        omitted.add(key);
        if (_messageSize(connection, payload, full, changedKeys, omitted) <=
            limits.maxMessageBytes) {
          break;
        }
      }
      if (_messageSize(connection, payload, full, changedKeys, omitted) >
          limits.maxMessageBytes) {
        // Even the minimal projection does not fit: refuse loudly instead of
        // delivering an unusable message.
        snapshotsRefused++;
        transport.sendToPanel(
          connection.panelId.name,
          PanelLifecycle(
            panelId: connection.panelId,
            state: PanelLifecycleState.suspended,
            sessionId: source.sessionId,
            projectId: source.projectId,
            reason: 'snapshot-too-large',
          ).toJson(),
        );
        return;
      }
    }
    _revision++;
    connection
      ..lastRevisionSent = _revision
      ..sessionId = source.sessionId
      ..projectId = source.projectId
      ..lastViewModel = Map<String, Object?>.unmodifiable({
        ...connection.lastViewModel,
        ...payload,
      });
    connection.snapshotsSent++;
    snapshotsSent++;
    transport.sendToPanel(
      connection.panelId.name,
      PanelSnapshot(
        panelId: connection.panelId,
        sessionId: source.sessionId,
        projectId: source.projectId,
        revision: _revision,
        full: full,
        changedKeys: changedKeys,
        omittedKeys: omitted,
        viewModel: payload,
      ).toJson(),
    );
  }

  /// Serialized size of the message that would carry [payload].
  int _messageSize(
    PanelBridgeConnection connection,
    Map<String, Object?> payload,
    bool full,
    List<String> changedKeys,
    List<String> omitted,
  ) => panelPayloadSize(
    PanelSnapshot(
      panelId: connection.panelId,
      sessionId: source.sessionId,
      projectId: source.projectId,
      revision: _revision + 1,
      full: full,
      changedKeys: changedKeys,
      omittedKeys: omitted,
      viewModel: payload,
    ).toJson(),
  );
}
