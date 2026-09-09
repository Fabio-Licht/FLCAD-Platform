part of 'cad_runtime.dart';

class StaleCadTransaction implements Exception {
  const StaleCadTransaction();
}

/// Pure origin check; grants no runtime or native authority.
@visibleForTesting
void validateCadTransactionOrigin({
  required int session,
  required int revision,
  required int currentSession,
  required int currentRevision,
}) {
  if (session != currentSession || revision != currentRevision) {
    throw const StaleCadTransaction();
  }
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

// A standalone identity has no back-reference to its runtime or document.
class _CadCapability {
  _CadCapability(this.runtimeIdentity, this.id);
  final Object runtimeIdentity;
  final int id;
  bool _active = true;
  bool get active => _active;
  void _revoke() => _active = false;
}

class _CadTransaction {
  _CadTransaction(this.owner, this.id, this.lifecycle)
    : capability = _CadCapability(owner._runtimeIdentity, id),
      revision = owner._runtimeRevision,
      session = owner._sessionIdentity,
      document = owner._document,
      directory = owner._projectDirectory;
  final CadRuntime owner;
  final int id, revision, session, lifecycle;
  final CadDocument? document;
  final Directory? directory;
  final _CadCapability capability;
  bool isActiveFor(CadRuntime runtime) =>
      capability.active &&
      identical(capability.runtimeIdentity, runtime._runtimeIdentity) &&
      identical(owner, runtime) &&
      identical(runtime._transaction, this) &&
      runtime._transaction?.id == id;

  bool notify = false, boundary = false, committed = false;
  bool selectionChanged = false;
  bool operationalSelectionChanged = false;

  void validate() {
    if (!isActiveFor(owner)) {
      throw StateError('Transaction is not owned by this runtime execution.');
    }
    if (owner._closingAdmission ||
        lifecycle != owner._lifecycleGeneration ||
        !identical(document, owner._document) ||
        !identical(directory, owner._projectDirectory)) {
      throw const StaleCadTransaction();
    }
    validateCadTransactionOrigin(
      session: session,
      revision: revision,
      currentSession: owner._sessionIdentity,
      currentRevision: owner._runtimeRevision,
    );
  }
}

extension _CadTransactions on CadRuntime {
  _CadTransaction? get _callingTransaction {
    final inherited = Zone.current[_transactionZone];
    final current = _transaction;
    return inherited is _CadCapability &&
            current != null &&
            identical(inherited, current.capability) &&
            current.isActiveFor(this)
        ? current
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
        await runZoned(
          () => action(tx),
          zoneValues: {_transactionZone: tx.capability},
        );
      } finally {
        tx.capability._revoke();
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
            if (tx.selectionChanged && !_closingAdmission) {
              geometrySelection.publishReconciliation();
            }
            if (tx.operationalSelectionChanged && !_closingAdmission) {
              operationalSelection.publishReconciliation();
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
        final rebuild = <CadDocumentEntity>[];
        for (final entity in candidate.entities.values) {
          final old = previous.entities[entity.id];
          final visual = staging.find(entity.id);
          if (old != null &&
              visual != null &&
              entity.data['deleted'] != true &&
              _sameJson(_renderDefinition(old), _renderDefinition(entity))) {
            staging.upsert(
              visual.copyWith(
                visible: entity.data['sceneVisible'] as bool? ?? true,
                transparent: entity.data['sceneTransparent'] as bool? ?? false,
              ),
            );
          } else if (!_sameJson(old?.toJson(), entity.toJson())) {
            rebuild.add(entity);
          }
        }
        await stagedProjection.synchronizeChanges(
          candidate,
          upsert: rebuild,
          remove: previous.entities.keys.where(
            (id) => !candidate.entities.containsKey(id),
          ),
          displayMeshes: meshes,
        );
      } else {
        await stagedProjection.synchronize(candidate, displayMeshes: meshes);
      }
      tx.validate();
      return staging.entities
          .map((visual) {
            final entity = candidate.entities[visual.id];
            final collection = candidate.entities[entity?.data['collectionId']];
            return visual.copyWith(
              visible:
                  entity?.data['deleted'] != true &&
                  (entity?.data['sceneVisible'] as bool? ?? true) &&
                  collection?.data['visible'] != false &&
                  collection?.data['deleted'] != true,
            );
          })
          .toList(growable: false);
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
    tx.selectionChanged = geometrySelection.retainVisible(notify: false);
    tx.operationalSelectionChanged = operationalSelection.retainWhere(
      (entity) => scene.find(entity.ownerId)?.visible == true,
      notify: false,
    );
    // Correct pruned flags without callbacks; unchanged selection needs no second pass.
    if (tx.selectionChanged) {
      projection.installPrepared(prepared, boundary ? const {} : selection);
    }
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
    final diagnostics = _legacyIntegrityDiagnostics(candidate);
    void publish() {
      _install(
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
      // Existing runtime state/notification channel; an opening diagnostic, not
      // a repair or a strict writer validation. Prepared before publication.
      write('document.integrityDiagnostics', diagnostics);
    }

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

Object _renderDefinition(CadDocumentEntity entity) => {
  'kind': entity.kind.name,
  'shape': entity.shape?.toJson(),
  'mesh': entity.toJson()['mesh'],
  'sceneKind': entity.data['sceneKind'],
  'sceneGeometry': entity.data['sceneGeometry'],
};

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
