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
  final revocation = Completer<void>();
  void requestRevocation() {
    if (!revocation.isCompleted) revocation.complete();
  }

  void finish() {
    requestRevocation();
    capability._revoke();
  }

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
    if (revocation.isCompleted ||
        owner._closingAdmission ||
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

/// Fully materialized managed commit. It contains no producer callback and no
/// operation capable of awaiting: persistence is the final asynchronous
/// boundary, followed by one controlled synchronous installation section.
final class _PreparedManagedCadCommit {
  _PreparedManagedCadCommit({
    required this.candidate,
    required this.undo,
    required this.redo,
    required this.scene,
    required this.entityId,
    required this.geometry,
    required this.bounds,
  });
  final CadDocument candidate;
  final List<CadDocument> undo, redo;
  final List<CadSceneEntity> scene;
  final String entityId;
  final ManagedEntityGeometry geometry;
  final KernelBounds? bounds;
  bool installed = false;
  ManagedEntityGeometry? transferredGeometry;
}

/// Fully materialized native residency for an open operation. Nothing in this
/// object is published until every managed entity, scene entry and durable
/// asset has been validated.
final class _PreparedManagedOpen {
  _PreparedManagedOpen({
    required this.geometry,
    required this.scene,
    required this.assets,
  });
  final Map<String, ManagedEntityGeometry> geometry;
  final Map<String, CadSceneEntity> scene;
  final List<_VerifiedManagedAsset> assets;
  final Map<String, ManagedEntityGeometry> transferred = {};
  _AssetPaths? _paths;
  Map<String, ManagedEntityGeometry>? replaced;
  bool installed = false;
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
        tx.finish();
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
    bool useDisplayPipeline = true,
  }) async {
    final staging = CadSceneGraph();
    try {
      if (incremental) {
        staging.replaceAll(projection.permanentEntities, notify: false);
      }
      final meshes = useDisplayPipeline
          ? KernelDisplayMeshPipeline(
              kernel: kernels.active,
              projectId: candidate.projectId,
              projectDirectory: directory,
              scene: staging,
            )
          : null;
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

  _PreparedManagedCadCommit _prepareManagedCommit(
    _CadTransaction tx, {
    required CadDocument candidate,
    required List<CadDocument> undo,
    required List<CadDocument> redo,
    required CadSceneEntity managedScene,
    required ManagedEntityGeometry geometry,
  }) {
    tx.validate();
    final normalized = _snapshots.document(candidate, normalized: true);
    final preparedUndo = _snapshots.history(undo);
    final preparedRedo = _snapshots.history(redo);
    final entity = normalized.entities[managedScene.id];
    if (entity == null ||
        entity.kind != CadDocumentEntityKind.import ||
        entity.shape != null ||
        entity.mesh != null ||
        entity.data['managedBrepAssets'] is! Map ||
        managedScene.kind != CadSceneEntityKind.mesh) {
      throw StateError('Managed scene does not match its document entity');
    }
    ManagedBrepAssets.fromJson(
      Map<String, dynamic>.from(entity.data['managedBrepAssets'] as Map),
    );
    if (_managedGeometry.containsKey(entity.id)) {
      throw StateError('Managed geometry already installed for entity');
    }
    geometry.validateTransfer();
    final nodes = managedScene.geometry['nodes'];
    final triangles = managedScene.geometry['triangles'];
    if (nodes is! List ||
        triangles is! List ||
        nodes.length != geometry.displayMesh.descriptor.vertices * 3 ||
        triangles.length != geometry.displayMesh.descriptor.triangles * 3) {
      throw StateError('Prepared managed scene has invalid geometry');
    }
    final preparedScene = <CadSceneEntity>[
      for (final existing in projection.permanentEntities)
        if (existing.id != entity.id) existing,
      managedScene,
    ];
    if (preparedScene.map((item) => item.id).toSet().length !=
        preparedScene.length) {
      throw StateError('Prepared scene contains duplicate entity IDs');
    }
    tx.validate();
    return _PreparedManagedCadCommit(
      candidate: normalized,
      undo: preparedUndo,
      redo: preparedRedo,
      scene: List.unmodifiable(preparedScene),
      entityId: entity.id,
      geometry: geometry,
      bounds: _recalculateWorkspaceBounds(entities: preparedScene),
    );
  }

  Future<void> _commitPreparedManaged(
    _CadTransaction tx,
    _PreparedManagedCadCommit prepared,
  ) async {
    tx.validate();
    if (prepared.installed ||
        _managedGeometry.containsKey(prepared.entityId) ||
        prepared.candidate.entities[prepared.entityId] == null) {
      throw StateError('Managed commit is no longer installable');
    }
    prepared.geometry.validateTransfer();
    await _assetStorage.checkpoint('managedBrep:beforePersistence');
    tx.validate();
    try {
      await _persistSnapshot(
        tx,
        prepared.candidate,
        tx.directory!,
        prepared.undo,
        prepared.redo,
        publish: () {
          // All parsing, projection, collision and ownership checks completed
          // before persistence. These operations are synchronous and invoke no
          // producer, renderer or listener callback.
          prepared.geometry.validateTransfer();
          final runtimeGeometry = prepared.geometry.transfer();
          prepared.transferredGeometry = runtimeGeometry;
          try {
            _installManagedGeometry(prepared.entityId, runtimeGeometry);
            _install(
              tx,
              prepared.candidate,
              tx.directory!,
              prepared.undo,
              prepared.redo,
              prepared.scene,
              imported: (_activeImport, _activeMeshGeometry),
              bounds: prepared.bounds,
              refreshDisplayPipeline: false,
            );
            prepared.installed = true;
            prepared.transferredGeometry = null;
          } catch (_) {
            if (identical(
              _managedGeometry[prepared.entityId],
              runtimeGeometry,
            )) {
              _managedGeometry.remove(prepared.entityId);
            }
            rethrow;
          }
        },
      );
    } catch (_) {
      final detached = prepared.transferredGeometry;
      prepared.transferredGeometry = null;
      if (detached != null) await detached.dispose();
      rethrow;
    }
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
    bool refreshDisplayPipeline = true,
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
    if (candidate == null || !refreshDisplayPipeline) {
      _displayMeshes = null;
    } else {
      _displayMeshes = KernelDisplayMeshPipeline(
        kernel: kernels.active,
        projectId: candidate.projectId,
        projectDirectory: directory!,
        scene: scene,
      );
    }
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
    final managedEntities = candidate.entities.values
        .where((entity) => entity.data['managedBrepAssets'] != null)
        .toList(growable: false);
    _PreparedManagedOpen? managed;
    Map<String, ManagedEntityGeometry>? replacedByLegacyOpen;
    try {
      if (managedEntities.isNotEmpty) {
        managed = await _prepareManagedOpen(
          tx,
          candidate,
          directory,
          managedEntities,
        );
      }
      final needsLegacyDisplayPipeline = candidate.entities.values.any(
        (entity) =>
            entity.data['managedBrepAssets'] == null &&
            entity.shape != null &&
            entity.data['sceneGeometry'] is Map,
      );
      final baseScene = await _prepareScene(
        tx,
        candidate,
        directory,
        // Managed documents are reconstructed from captured native meshes.
        // The projection still handles ordinary serialized scene geometry,
        // but no pathname-oriented mesh pipeline is instantiated.
        useDisplayPipeline: managed == null || needsLegacyDisplayPipeline,
      );
      final prepared = managed == null
          ? baseScene
          : [
              for (final entity in baseScene)
                if (!managed.scene.containsKey(entity.id)) entity,
              ...managed.scene.values,
            ];
      if (prepared.map((entity) => entity.id).toSet().length !=
          prepared.length) {
        throw StateError('Prepared open scene contains duplicate IDs');
      }
      final bounds = _recalculateWorkspaceBounds(entities: prepared);
      final diagnostics = _legacyIntegrityDiagnostics(candidate);
      if (managed != null) {
        await _assetStorage.checkpoint('managedOpen:beforePublish');
        tx.validate();
      }
      void publish() {
        if (managed != null) {
          _publishManagedOpen(
            tx,
            managed,
            candidate: candidate,
            directory: directory,
            undo: undo,
            redo: redo,
            scene: prepared,
            imported: imported,
            bounds: bounds,
            refreshDisplayPipeline: needsLegacyDisplayPipeline,
          );
        } else {
          replacedByLegacyOpen = Map<String, ManagedEntityGeometry>.of(
            _managedGeometry,
          );
          _managedGeometry.clear();
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
        }
        // Existing runtime state/notification channel; an opening diagnostic,
        // not a repair or a strict writer validation. Prepared before publish.
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
      final replaced =
          managed?.replaced?.values.toList() ??
          replacedByLegacyOpen?.values.toList() ??
          const [];
      managed?.replaced = null;
      replacedByLegacyOpen = null;
      Object? cleanupFailure;
      StackTrace? cleanupStack;
      try {
        managed?._paths?.dispose();
      } catch (cleanup, cleanupTrace) {
        cleanupFailure = cleanup;
        cleanupStack = cleanupTrace;
      }
      if (managed != null) managed._paths = null;
      try {
        await _disposeManagedGeometry(replaced);
      } catch (cleanup, cleanupTrace) {
        cleanupFailure ??= cleanup;
        cleanupStack ??= cleanupTrace;
      }
      if (cleanupFailure != null) {
        Error.throwWithStackTrace(cleanupFailure, cleanupStack!);
      }
    } catch (error, stack) {
      final detachedOld = <ManagedEntityGeometry>[
        ...?managed?.replaced?.values,
        if (tx.committed) ...?replacedByLegacyOpen?.values,
      ];
      managed?.replaced = null;
      if (replacedByLegacyOpen != null && !tx.committed) {
        _managedGeometry
          ..clear()
          ..addAll(replacedByLegacyOpen!);
      }
      replacedByLegacyOpen = null;
      Object? cleanupFailure;
      StackTrace? cleanupStack;
      try {
        await _disposePreparedManagedOpen(managed);
      } catch (cleanup, cleanupTrace) {
        cleanupFailure = cleanup;
        cleanupStack = cleanupTrace;
      }
      try {
        await _disposeManagedGeometry(detachedOld);
      } catch (cleanup, cleanupTrace) {
        cleanupFailure ??= cleanup;
        cleanupStack ??= cleanupTrace;
      }
      if (cleanupFailure != null) {
        Error.throwWithStackTrace(
          CadAssetOperationFailure(error, cleanupFailure, stack, cleanupStack!),
          stack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<_PreparedManagedOpen> _prepareManagedOpen(
    _CadTransaction tx,
    CadDocument candidate,
    Directory directory,
    List<CadDocumentEntity> entities,
  ) async {
    final kernel = kernels.active;
    if (kernel is! OpenCascadeKernelAdapter) {
      throw UnsupportedError(
        'Managed BREP restoration requires the OpenCascade kernel',
      );
    }
    final paths = await _AssetPaths.open(directory);
    final geometry = <String, ManagedEntityGeometry>{};
    final scenes = <String, CadSceneEntity>{};
    final verified = <_VerifiedManagedAsset>[];
    try {
      for (final entity in entities) {
        await _assetStorage.checkpoint('managedOpen:beforeEntity');
        tx.validate();
        if (entity.kind != CadDocumentEntityKind.import ||
            entity.shape != null ||
            entity.mesh != null ||
            entity.data['sceneKind'] != CadSceneEntityKind.mesh.name ||
            geometry.containsKey(entity.id)) {
          throw const FormatException('Invalid managed BREP document entity');
        }
        final assets = ManagedBrepAssets.fromJson(
          Map<String, dynamic>.from(entity.data['managedBrepAssets'] as Map),
        );
        final shapeAsset = await paths.openManagedAsset(
          projectId: candidate.projectId,
          asset: assets.shape,
          kind: CadAssetFile.brep,
          expectedSha256: assets.shapeSha256,
        );
        verified.add(shapeAsset);
        final shape = await _restoreManagedShape(tx, kernel, shapeAsset);
        ManagedNativeDisplayMesh? display;
        try {
          await _assetStorage.checkpoint('managedOpen:afterShape');
          tx.validate();
          final displayAsset = await paths.openManagedAsset(
            projectId: candidate.projectId,
            asset: assets.display,
            kind: CadAssetFile.display,
            expectedSha256: assets.displaySha256,
          );
          verified.add(displayAsset);
          display = await _restoreManagedMesh(tx, kernel, displayAsset);
          await _assetStorage.checkpoint('managedOpen:afterMesh');
          tx.validate();
          _validateManagedDescriptor(
            entity.data['shapeDescriptor'],
            shape.descriptor,
          );
          _validateManagedDescriptor(
            entity.data['displayMeshDescriptor'],
            display.descriptor,
          );
          final sceneGeometry = await display.prepareSceneGeometry(kernel);
          tx.validate();
          final collection = candidate.entities[entity.data['collectionId']];
          scenes[entity.id] = CadSceneEntity(
            id: entity.id,
            kind: CadSceneEntityKind.mesh,
            geometry: sceneGeometry,
            visible:
                entity.data['deleted'] != true &&
                (entity.data['sceneVisible'] as bool? ?? true) &&
                collection?.data['visible'] != false &&
                collection?.data['deleted'] != true,
            transparent: entity.data['sceneTransparent'] as bool? ?? false,
          );
          geometry[entity.id] = ManagedEntityGeometry(shape, display);
          display = null;
        } catch (error, stack) {
          Object? cleanupFailure;
          StackTrace? cleanupStack;
          for (final cleanup in [
            shape.dispose,
            if (display != null) display.dispose,
          ]) {
            try {
              await cleanup();
            } catch (cleanupError, cleanupTrace) {
              cleanupFailure ??= cleanupError;
              cleanupStack ??= cleanupTrace;
            }
          }
          if (cleanupFailure != null) {
            Error.throwWithStackTrace(
              CadAssetOperationFailure(
                error,
                cleanupFailure,
                stack,
                cleanupStack!,
              ),
              stack,
            );
          }
          Error.throwWithStackTrace(error, stack);
        }
      }
      if (geometry.length != entities.length ||
          scenes.length != entities.length) {
        throw StateError('Managed open preparation is incomplete');
      }
      return _PreparedManagedOpen(
        geometry: geometry,
        scene: scenes,
        assets: verified,
      ).._paths = paths;
    } catch (error, stack) {
      Object? cleanupFailure;
      StackTrace? cleanupStack;
      try {
        paths.dispose();
      } catch (cleanup, cleanupTrace) {
        cleanupFailure = cleanup;
        cleanupStack = cleanupTrace;
      }
      try {
        await _disposeManagedGeometry(geometry.values);
      } catch (cleanup, cleanupTrace) {
        cleanupFailure ??= cleanup;
        cleanupStack ??= cleanupTrace;
      }
      if (cleanupFailure != null) {
        Error.throwWithStackTrace(
          CadAssetOperationFailure(error, cleanupFailure, stack, cleanupStack!),
          stack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<ManagedNativeShape> _restoreManagedShape(
    _CadTransaction tx,
    OpenCascadeKernelAdapter kernel,
    _VerifiedManagedAsset asset,
  ) => _restoreManagedResource(
    tx,
    kernel,
    asset,
    NativeResourceKind.shape,
  ).then((resource) => resource as ManagedNativeShape);

  Future<ManagedNativeDisplayMesh> _restoreManagedMesh(
    _CadTransaction tx,
    OpenCascadeKernelAdapter kernel,
    _VerifiedManagedAsset asset,
  ) => _restoreManagedResource(
    tx,
    kernel,
    asset,
    NativeResourceKind.mesh,
  ).then((resource) => resource as ManagedNativeDisplayMesh);

  Future<Object> _restoreManagedResource(
    _CadTransaction tx,
    OpenCascadeKernelAdapter kernel,
    _VerifiedManagedAsset asset,
    NativeResourceKind kind,
  ) async {
    final cancellation = NativeSourceCancellation();
    unawaited(
      Future.any<void>([
        tx.revocation.future,
        _assetShutdown.future,
      ]).then((_) => cancellation.revoke()),
    );
    NativeSourceResource resource;
    try {
      resource = await kernel.readOwnedAsset(
        filesystem: asset.native,
        file: asset.file,
        expected: asset.expected,
        kind: kind,
        cancellation: cancellation,
      );
    } on NativeSourcePublicationFailure catch (error, stack) {
      try {
        await error.resource.dispose();
      } catch (cleanup, cleanupStack) {
        Error.throwWithStackTrace(
          CadAssetOperationFailure(error.failure, cleanup, stack, cleanupStack),
          stack,
        );
      }
      Error.throwWithStackTrace(error.failure, stack);
    }
    try {
      return kind == NativeResourceKind.shape
          ? resource.claimShape()
          : resource.claimMesh();
    } finally {
      await resource.dispose();
    }
  }

  void _validateManagedDescriptor(
    Object? encoded,
    NativeGeometryDescriptor actual,
  ) {
    if (encoded is! Map) {
      throw const FormatException('Missing managed native descriptor');
    }
    final expected = Map<String, dynamic>.from(encoded);
    final current = actual.toManagedMetadata();
    const stableFields = {
      'schema',
      'version',
      'kind',
      'type',
      'vertices',
      'triangles',
      'bounds',
      'hasNormals',
    };
    // Source ABI v1 derives a shape fingerprint from std::hash<TopoDS_Shape>;
    // it identifies one native residence and is expected to change after a
    // BREP round trip. Durable identity is the CAF-verified payload SHA-256.
    // Keep the original fingerprint as document metadata, but do not pretend
    // that it is a cross-session content fingerprint.
    if (expected.keys.toSet().difference({
          ...stableFields,
          'fingerprint',
        }).isNotEmpty ||
        expected['fingerprint'] is! String ||
        (expected['fingerprint'] as String).isEmpty ||
        stableFields.any((key) => !_sameJson(expected[key], current[key]))) {
      throw StateError('Restored native descriptor does not match document');
    }
  }

  void _publishManagedOpen(
    _CadTransaction tx,
    _PreparedManagedOpen prepared, {
    required CadDocument candidate,
    required Directory directory,
    required List<CadDocument> undo,
    required List<CadDocument> redo,
    required List<CadSceneEntity> scene,
    required (ImportedCadDocument?, KernelMeshGeometry?) imported,
    required KernelBounds? bounds,
    required bool refreshDisplayPipeline,
  }) {
    tx.validate();
    if (prepared.installed ||
        prepared.geometry.keys.any((id) => candidate.entities[id] == null)) {
      throw StateError('Managed open is no longer installable');
    }
    for (final asset in prepared.assets) {
      asset.revalidate();
    }
    for (final geometry in prepared.geometry.values) {
      geometry.validateTransfer();
    }
    for (final entry in prepared.geometry.entries) {
      // Record custody immediately; if a later entity cannot transfer, the
      // cleanup path still owns every already-transferred resource.
      prepared.transferred[entry.key] = entry.value.transfer();
    }
    prepared.replaced = Map<String, ManagedEntityGeometry>.of(_managedGeometry);
    _managedGeometry
      ..clear()
      ..addAll(prepared.transferred);
    try {
      _install(
        tx,
        candidate,
        directory,
        undo,
        redo,
        scene,
        boundary: true,
        imported: imported,
        bounds: bounds,
        refreshDisplayPipeline: refreshDisplayPipeline,
      );
      prepared.installed = true;
      prepared.transferred.clear();
    } catch (_) {
      _managedGeometry
        ..clear()
        ..addAll(prepared.replaced!);
      prepared.replaced = null;
      rethrow;
    }
  }

  Future<void> _disposePreparedManagedOpen(
    _PreparedManagedOpen? prepared,
  ) async {
    if (prepared == null) return;
    Object? pathsFailure;
    StackTrace? pathsStack;
    try {
      prepared._paths?.dispose();
    } catch (error, stack) {
      pathsFailure = error;
      pathsStack = stack;
    }
    prepared._paths = null;
    Object? geometryFailure;
    StackTrace? geometryStack;
    try {
      if (!prepared.installed) {
        await _disposeManagedGeometry([
          ...prepared.geometry.values,
          ...prepared.transferred.values,
        ]);
      }
    } catch (error, stack) {
      geometryFailure = error;
      geometryStack = stack;
    }
    if (pathsFailure != null && geometryFailure != null) {
      throw CadAssetOperationFailure(
        pathsFailure,
        geometryFailure,
        pathsStack!,
        geometryStack!,
      );
    }
    if (pathsFailure != null) {
      Error.throwWithStackTrace(pathsFailure, pathsStack!);
    }
    if (geometryFailure != null) {
      Error.throwWithStackTrace(geometryFailure, geometryStack!);
    }
  }

  Future<void> _disposeManagedGeometry(
    Iterable<ManagedEntityGeometry> values,
  ) async {
    Object? first;
    StackTrace? firstStack;
    for (final value in values.toSet()) {
      try {
        await value.dispose();
      } catch (error, stack) {
        first ??= error;
        firstStack ??= stack;
      }
    }
    if (first != null) Error.throwWithStackTrace(first, firstStack!);
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
