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
  bool notify = false, boundary = false;

  void validate() {
    if (!identical(owner._transaction, this)) {
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
  Future<void> _enqueue(
    Future<void> Function(_CadTransaction) action, {
    int? lifecycle,
  }) {
    if (_closingAdmission) return Future.error(const CadRuntimeShuttingDown());
    if (_recoveryRequired) {
      return Future.error(
        StateError('CAD runtime requires verified recovery.'),
      );
    }
    if (Zone.current[_transactionZone] == this) {
      return Future.error(
        StateError('Use the existing transaction internally.'),
      );
    }
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
        await runZoned(() => action(tx), zoneValues: {_transactionZone: this});
      } finally {
        _transaction = null;
        // No listener runs while the document/scene/history are being installed.
        // This continuation is outside the transaction Zone: listeners enqueue.
        if (tx.notify && !_closingAdmission) {
          if (tx.boundary) {
            geometrySelection.clear();
            operationalSelection.clear();
            operationalResolver.clear();
            operationalEntities.clear();
          }
          scene.invalidatePresentation();
          _notifyTransactionComplete();
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
    // Freeze document AND history before the first write/await.
    final frozen = CadDocument.fromJson(
      jsonDecode(jsonEncode(candidate.toJson())),
    );
    List<CadDocument> freeze(List<CadDocument> values) => values
        .map((d) => CadDocument.fromJson(jsonDecode(jsonEncode(d.toJson()))))
        .toList(growable: false);
    final undoSnapshot = freeze(undo), redoSnapshot = freeze(redo);
    final backup = await _repository.captureFiles(directory);
    tx.validate();
    try {
      await _repository.save(frozen, directory);
      tx.validate();
      await _repository.saveHistory(
        directory,
        undo: undoSnapshot,
        redo: redoSnapshot,
      );
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
      current,
      directory,
      List.of(_undo),
      List.of(_redo),
    );
  }

  Future<void> _commitDocument(
    _CadTransaction tx,
    CadDocument candidate,
    List<CadDocument> undo,
    List<CadDocument> redo,
  ) async {
    tx.validate();
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
    final candidate = FeatureLifecycleProjector.normalize(
      _ensureProfessionalCollections(
        WorldCoordinateSystem.ensure(_sanitizeLegacyWorkspaceState(loaded)),
      ),
      command: 'project.open.lifecycle-migration',
    );
    final history = await _repository.loadHistory(directory);
    tx.validate();
    final undo = history.undo.where((d) => d.projectId == projectId).toList();
    final redo = history.redo.where((d) => d.projectId == projectId).toList();
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
