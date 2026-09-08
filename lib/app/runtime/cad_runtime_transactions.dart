part of 'cad_runtime.dart';

class StaleCadTransaction implements Exception {
  const StaleCadTransaction();
}

class CadRuntimeShuttingDown implements Exception {
  const CadRuntimeShuttingDown();
}

class CadRecoveryFailure implements Exception {
  const CadRecoveryFailure(
    this.original,
    this.recovery,
    this.originalStack,
    this.recoveryStack,
  );
  final Object original, recovery;
  final StackTrace originalStack, recoveryStack;
  @override
  String toString() => 'CAD recovery required: $original; recovery: $recovery';
}

final Object _transactionZone = Object();

class _CadTransaction {
  _CadTransaction(this.owner, this.id, this.lifecycle)
    : revision = owner._runtimeRevision,
      session = owner._sessionIdentity,
      document = owner._document,
      directory = owner._projectDirectory;
  final CadRuntime owner;
  final int id, revision, session, lifecycle;
  final CadDocument? document;
  final Directory? directory;
  bool active = true;
  bool isActiveFor(CadRuntime runtime) =>
      active &&
      identical(owner, runtime) &&
      identical(runtime._transaction, this) &&
      runtime._transaction?.id == id;

  bool notify = false, boundary = false, committed = false;

  void validate() {
    if (!isActiveFor(owner)) {
      throw StateError('Transaction is not owned by this runtime execution.');
    }
    if (owner._closingAdmission ||
        lifecycle != owner._lifecycleGeneration ||
        revision != owner._runtimeRevision ||
        session != owner._sessionIdentity ||
        !identical(document, owner._document) ||
        !identical(directory, owner._projectDirectory)) {
      throw const StaleCadTransaction();
    }
  }
}

extension _CadTransactions on CadRuntime {
  _CadTransaction? get _callingTransaction {
    final inherited = Zone.current[_transactionZone];
    return inherited is _CadTransaction && inherited.isActiveFor(this)
        ? inherited
        : null;
  }

  Object? get _admissionError {
    if (_closingAdmission) return const CadRuntimeShuttingDown();
    if (_recoveryRequired) {
      return StateError('CAD runtime requires verified recovery.');
    }
    if (_callingTransaction != null) {
      return StateError('Use the existing transaction internally.');
    }
    return null;
  }

  Future<void> _enqueue(
    Future<void> Function(_CadTransaction) action, {
    int? lifecycle,
  }) {
    final rejection = _admissionError;
    if (rejection != null) return Future<void>.error(rejection);
    final generation = lifecycle ?? _lifecycleGeneration;
    final admittedSession = _sessionIdentity;
    final result = _transactionTail.then((_) async {
      if (_closingAdmission) throw const CadRuntimeShuttingDown();
      if (_recoveryRequired) throw StateError('CAD runtime requires recovery.');
      if (lifecycle == null && admittedSession != _sessionIdentity) {
        throw const StaleCadTransaction();
      }
      if (generation != _lifecycleGeneration) throw const StaleCadTransaction();
      final tx = _CadTransaction(this, ++_nextTransaction, generation);
      _transaction = tx;
      try {
        await runZoned(() => action(tx), zoneValues: {_transactionZone: tx});
      } finally {
        tx.active = false;
        _transaction = null;
        // No listener runs while the document/scene/history are being installed.
        // This continuation is outside the transaction Zone: listeners enqueue.
        if (tx.notify && !_closingAdmission) {
          try {
            if (tx.boundary) {
              geometrySelection.clear();
              if (!_closingAdmission) operationalSelection.clear();
              if (!_closingAdmission) operationalResolver.clear();
              if (!_closingAdmission) operationalEntities.clear();
            }
            if (!_closingAdmission) scene.invalidatePresentation();
            if (!_closingAdmission) _notifyTransactionComplete();
          } catch (error, stack) {
            // Observational errors must never replace success or the original
            // pre-commit exception propagating through this finally block.
            scheduleMicrotask(
              () => FlutterError.reportError(
                FlutterErrorDetails(
                  exception: error,
                  stack: stack,
                  library: 'CAD transaction notification',
                  context: ErrorDescription(
                    tx.committed
                        ? 'after confirmed commit'
                        : 'after failed transaction',
                  ),
                ),
              ),
            );
          }
        }
      }
    });
    _transactionTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<List<CadSceneEntity>> _prepareScene(
    _CadTransaction tx,
    CadDocument candidate,
    Directory directory, {
    bool incremental = false,
  }) async {
    final staging = CadSceneGraph();
    try {
      if (incremental) {
        staging.replaceAll(projection.permanentEntities, notify: false);
      }
      final meshes = KernelDisplayMeshPipeline(
        kernel: kernels.active,
        projectId: candidate.projectId,
        projectDirectory: directory,
        scene: staging,
      );
      final stagedProjection = CadDocumentSceneProjection(staging);
      if (incremental) {
        final previous = tx.document!;
        await stagedProjection.synchronizeChanges(
          candidate,
          upsert: candidate.entities.values.where(
            (entity) =>
                jsonEncode(previous.entities[entity.id]?.toJson()) !=
                jsonEncode(entity.toJson()),
          ),
          remove: previous.entities.keys.where(
            (id) => !candidate.entities.containsKey(id),
          ),
          displayMeshes: meshes,
        );
      } else {
        await stagedProjection.synchronize(candidate, displayMeshes: meshes);
      }
      tx.validate();
      return staging.entities.toList(growable: false);
    } finally {
      staging.dispose();
    }
  }

  Future<void> _persistSnapshot(
    _CadTransaction tx,
    CadDocument candidate,
    Directory directory,
    List<CadDocument> undo,
    List<CadDocument> redo, {
    void Function()? publish,
  }) async {
    tx.validate();
    final backup = await _repository.captureFiles(directory);
    tx.validate();
    try {
      await _repository.save(candidate, directory);
      tx.validate();
      await _repository.saveHistory(directory, undo: undo, redo: redo);
      tx.validate();
      publish?.call();
    } catch (error, stack) {
      try {
        await _repository.restoreFiles(directory, backup);
      } catch (recovery, recoveryStack) {
        _recoveryRequired = true;
        throw CadRecoveryFailure(error, recovery, stack, recoveryStack);
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> _saveInTransaction(_CadTransaction tx) async {
    tx.validate();
    final current = tx.document, directory = tx.directory;
    if (current == null || directory == null) return;
    await _persistSnapshot(
      tx,
      _snapshots.document(current),
      directory,
      _snapshots.history(_undo),
      _snapshots.history(_redo),
    );
  }

  Future<void> _commitDocument(
    _CadTransaction tx,
    CadDocument candidate,
    List<CadDocument> undo,
    List<CadDocument> redo,
  ) async {
    tx.validate();
    candidate = _snapshots.document(candidate, normalized: true);
    undo = _snapshots.history(undo);
    redo = _snapshots.history(redo);
    final directory = tx.directory!;
    // Validate derived import data before persistence or active publication.
    final imported = _readImport(candidate);
    final prepared = await _prepareScene(
      tx,
      candidate,
      directory,
      incremental: true,
    );
    final bounds = _recalculateWorkspaceBounds(entities: prepared);
    await _persistSnapshot(
      tx,
      candidate,
      directory,
      undo,
      redo,
      publish: () {
        _install(
          tx,
          candidate,
          directory,
          undo,
          redo,
          prepared,
          imported: imported,
          bounds: bounds,
        );
      },
    );
  }

  void _install(
    _CadTransaction tx,
    CadDocument? candidate,
    Directory? directory,
    List<CadDocument> undo,
    List<CadDocument> redo,
    List<CadSceneEntity> prepared, {
    bool boundary = false,
    (ImportedCadDocument?, KernelMeshGeometry?)? imported,
    KernelBounds? bounds,
  }) {
    tx.validate();
    // Everything that can await/parse/mesh has already completed.
    _document = candidate;
    _projectDirectory = directory;
    _undo
      ..clear()
      ..addAll(undo);
    _redo
      ..clear()
      ..addAll(redo);
    _activeImport = imported?.$1;
    _activeMeshGeometry = imported?.$2;
    if (boundary) {
      projection.discardTransient();
      _state.clear();
      recognitionSession = sketchSession = surfaceSession = null;
      _sessionIdentity++;
      _sessionActive = candidate != null;
    }
    projection.installPrepared(prepared, boundary ? const {} : selection);
    _displayMeshes = candidate == null
        ? null
        : KernelDisplayMeshPipeline(
            kernel: kernels.active,
            projectId: candidate.projectId,
            projectDirectory: directory!,
            scene: scene,
          );
    _workspaceBounds = bounds;
    _runtimeRevision++;
    tx.committed = true;
    tx.boundary = boundary;
    tx.notify = true;
  }

  Future<void> _openInTransaction(
    _CadTransaction tx,
    String projectId,
    Directory directory,
  ) async {
    final loaded = await _repository.load(projectId, directory);
    tx.validate();
    final candidate = _snapshots.document(
      FeatureLifecycleProjector.normalize(
        _ensureProfessionalCollections(
          WorldCoordinateSystem.ensure(_sanitizeLegacyWorkspaceState(loaded)),
        ),
        command: 'project.open.lifecycle-migration',
      ),
      normalized: true,
    );
    final history = await _repository.loadHistory(directory);
    tx.validate();
    final undo = _snapshots.history(
      history.undo.where((d) => d.projectId == projectId),
    );
    final redo = _snapshots.history(
      history.redo.where((d) => d.projectId == projectId),
    );
    final imported = _readImport(candidate);
    final prepared = await _prepareScene(tx, candidate, directory);
    final bounds = _recalculateWorkspaceBounds(entities: prepared);
    void publish() => _install(
      tx,
      candidate,
      directory,
      undo,
      redo,
      prepared,
      boundary: true,
      imported: imported,
      bounds: bounds,
    );
    if (jsonEncode(candidate.toJson()) != jsonEncode(loaded.toJson())) {
      await _persistSnapshot(
        tx,
        candidate,
        directory,
        undo,
        redo,
        publish: publish,
      );
    } else {
      tx.validate();
      publish();
    }
  }
}

Object? _orderedJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _orderedJson(value[key])};
  }
  if (value is List) return value.map(_orderedJson).toList();
  return value;
}

bool _sameJson(Object? a, Object? b) =>
    jsonEncode(_orderedJson(a)) == jsonEncode(_orderedJson(b));
