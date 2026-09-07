part of 'backend_provisioning.dart';

typedef ColmapExternalBackendPreparer =
    Future<ReconstructionBackend> Function(
      BackendInstallationRecord record, {
      required bool allowUncertifiedExternal,
    });

final class ColmapExternalActivationResult {
  const ColmapExternalActivationResult({
    required this.installation,
    required this.backend,
  });

  final BackendInstallationRecord installation;
  final ReconstructionBackend backend;
}

final class ColmapExternalActivationCoordinator {
  ColmapExternalActivationCoordinator({
    required BackendProvisioningManager provisioningManager,
    required ReconstructionBackendManager backendManager,
    required ColmapExternalBackendPreparer prepareBackend,
  }) : _provisioningManager = provisioningManager,
       _backendManager = backendManager,
       _prepareBackend = prepareBackend,
       _queue = _queueFor(provisioningManager, backendManager);

  static final Expando<Map<ReconstructionBackendManager, _SerialQueue>>
  _queues = Expando('COLMAP external activation queues');

  final BackendProvisioningManager _provisioningManager;
  final ReconstructionBackendManager _backendManager;
  final ColmapExternalBackendPreparer _prepareBackend;
  final _SerialQueue _queue;

  Future<ColmapExternalActivationResult?> activateExternal({
    required String executablePath,
    required bool authorized,
    required bool allowExperimental,
    bool Function()? shouldAbandonBeforeCommit,
  }) async {
    if (!authorized || !allowExperimental) {
      throw StateError('Explicit consent and experimental use are required');
    }
    final candidate = await _provisioningManager.prepareExisting(
      'colmap',
      executablePath: executablePath,
      authorized: authorized,
    );
    return activatePrepared(
      candidate,
      authorized: authorized,
      allowExperimental: allowExperimental,
      shouldAbandonBeforeCommit: shouldAbandonBeforeCommit,
    );
  }

  Future<ColmapExternalActivationResult?> activatePrepared(
    PreparedExternalBackendCandidate candidate, {
    required bool authorized,
    required bool allowExperimental,
    bool Function()? shouldAbandonBeforeCommit,
  }) async {
    if (!authorized || !allowExperimental) {
      throw StateError('Explicit consent and experimental use are required');
    }
    await _provisioningManager._verifyPreparedExisting(candidate);
    final backend = await _prepareBackend(
      candidate.record,
      allowUncertifiedExternal: true,
    );
    if (backend.id != 'colmap') {
      throw StateError('Activation returned a non-COLMAP backend');
    }
    if (shouldAbandonBeforeCommit?.call() ?? false) return null;

    return _queue.run(() async {
      await _provisioningManager._verifyPreparedExisting(candidate);
      if (shouldAbandonBeforeCommit?.call() ?? false) return null;

      // Point of commit: consumption, persistence, provisioning memory and
      // synchronous backend publication continue without cancellation.
      await _provisioningManager._commitPreparedExisting(
        candidate,
        authorized: authorized,
      );
      if (_backendManager.contains('colmap')) {
        _backendManager.replace(backend);
      } else {
        _backendManager.register(backend);
      }
      return ColmapExternalActivationResult(
        installation: candidate.record,
        backend: backend,
      );
    });
  }

  static _SerialQueue _queueFor(
    BackendProvisioningManager provisioningManager,
    ReconstructionBackendManager backendManager,
  ) {
    final managers = _queues[provisioningManager] ??=
        HashMap<ReconstructionBackendManager, _SerialQueue>.identity();
    return managers.putIfAbsent(backendManager, _SerialQueue.new);
  }
}

final class _SerialQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() operation) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
    }
  }
}
