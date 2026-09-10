import 'cad_asset_fs_native.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show RootIsolateToken;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../core/cad_document/cad_document.dart';
import '../../core/cad_document/dependency_walk.dart';
import '../../core/cad_document/cad_document_repository.dart';
import '../../core/cad_kernel/api/geometry_kernel_api.dart';
import '../../core/cad_kernel/io/kernel_io_models.dart';
import '../../core/cad_kernel/models/kernel_models.dart';
import '../../core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';
import '../../core/cad_kernel/manager/kernel_manager.dart';
import '../../core/feature_lifecycle/feature_lifecycle.dart';
import '../../core/feature_lifecycle/feature_dependencies.dart';
import '../../core/feature_lifecycle/feature_lifecycle_projector.dart';
import '../../core/geometric_kernel/geometry/vectors.dart';
import '../../core/geometric_kernel/linear_algebra/matrices.dart';
import '../../core/import_export/api/import_export_api.dart';
import '../cad_viewport/scene/cad_scene_graph.dart';
import '../commands/command_manager.dart';
import 'cad_document_scene_projection.dart';
import '../cad_viewport/rendering/kernel_display_mesh_pipeline.dart';
import '../engineering_bridge/selection/geometry_selection_manager.dart';
import '../operational_entities/operational_entity.dart';
import '../operational_entities/operational_entity_resolver.dart';
import 'world_coordinate_system.dart';
import 'notification_gate.dart';

part 'cad_runtime_transactions.dart';
part 'cad_runtime_snapshots.dart';
part 'cad_runtime_integrity.dart';
part 'cad_asset_staging.dart';
part 'cad_asset_storage.dart';

class CadRuntime extends ChangeNotifier with NotificationGate {
  CadRuntime({
    required this.kernels,
    CadDocumentRepository repository = const CadDocumentRepository(),
    CadAssetStorage assetStorage = const CadAssetStorage(),
  }) : _repository = repository,
       _assetStorage = assetStorage,
       scene = CadSceneGraph() {
    notificationAllowed = () => !_closingAdmission;
    scene.notificationAllowed = () => !_closingAdmission;
    projection = CadDocumentSceneProjection(scene);
    geometrySelection = GeometrySelectionManager(scene)
      ..notificationAllowed = () => !_closingAdmission;
    operationalEntities = OperationalEntityRegistry()
      ..notificationAllowed = () => !_closingAdmission;
    operationalResolver = OperationalEntityResolver(operationalEntities);
    operationalSelection = OperationalSelectionManager(operationalEntities)
      ..notificationAllowed = () => !_closingAdmission;
  }

  final CadDocumentRepository _repository;
  final CadAssetStorage _assetStorage;
  final String _assetInstance = _assetId('i1');
  final _assetShutdown = Completer<void>();
  final KernelManager kernels;
  final CadSceneGraph scene;
  late final CadDocumentSceneProjection projection;
  late final GeometrySelectionManager geometrySelection;
  late final OperationalEntityRegistry operationalEntities;
  late final OperationalEntityResolver operationalResolver;
  late final OperationalSelectionManager operationalSelection;
  CadDocument? _document;
  Directory? _projectDirectory;
  ImportedCadDocument? _activeImport;
  KernelMeshGeometry? _activeMeshGeometry;
  KernelBounds? _workspaceBounds;
  KernelDisplayMeshPipeline? _displayMeshes;
  final List<CadDocument> _undo = [], _redo = [];
  CommandManager? _commands;
  Object? recognitionSession, sketchSession, surfaceSession;
  final Map<String, Object?> _state = {};
  final Map<String, ManagedEntityGeometry> _managedGeometry = {};

  // Native producers remain outside this documentary transaction protocol.
  final Object _runtimeIdentity = Object();
  final _snapshots = _CadSnapshots();
  Future<void> _transactionTail = Future<void>.value();
  _CadTransaction? _transaction;
  int _nextTransaction = 0, _runtimeRevision = 0, _lifecycleGeneration = 0;
  int _sessionIdentity = 0;
  bool _sessionActive = false, _closingAdmission = false;
  bool _recoveryRequired = false, _notifierDisposed = false;
  bool _shutdownFinished = false;
  Future<void>? _shutdownFuture;
  void _notifyTransactionComplete() => notifyListeners();

  int get runtimeRevision => _runtimeRevision;
  int get lifecycleGeneration => _lifecycleGeneration;
  int get sessionIdentity => _sessionIdentity;
  bool get sessionActive => _sessionActive;
  bool get recoveryRequired => _recoveryRequired;

  CadDocument? get document => _document;
  ImportedCadDocument? get activeImport => _activeImport;
  KernelMeshGeometry? get activeMeshGeometry => _activeMeshGeometry;
  KernelBounds? get workspaceBounds => _workspaceBounds;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  Set<String> get selection => geometrySelection.selectedIds;

  /// Managed imports install this only after their documentary commit. It is
  /// process-local and therefore deliberately has no document representation.
  // ignore: unused_element
  void _installManagedGeometry(String entityId, ManagedEntityGeometry value) {
    if (_managedGeometry.containsKey(entityId)) {
      throw StateError('Managed geometry already installed for entity');
    }
    _managedGeometry[entityId] = value;
  }

  // ignore: unused_element
  Future<void> _removeManagedGeometry(String entityId) async {
    // Scene removal is performed by the caller before releasing native state.
    final value = _managedGeometry.remove(entityId);
    if (value != null) await value.dispose();
  }

  void attachCommands(CommandManager value) {
    final current = _commands;
    if (current != null && !identical(current, value)) {
      throw StateError('CadRuntime already owns a CommandManager.');
    }
    _commands = value;
  }

  Future<void> undoCommand() async {
    final commands = _commands;
    if (commands?.canUndo == true) {
      await commands!.undo();
    } else if (canUndo) {
      await undoDocument();
    } else {
      throw StateError('There is no command to undo.');
    }
  }

  Future<void> redoCommand() async {
    final commands = _commands;
    if (commands?.canRedo == true) {
      await commands!.redo();
    } else if (canRedo) {
      await redoDocument();
    } else {
      throw StateError('There is no command to redo.');
    }
  }

  Future<ShapeHandle?> officialExportShape() async {
    final shape = _document?.officialExportShape;
    if (shape == null) return null;
    final kernel = kernels.active;
    final directory = _projectDirectory;
    if (kernel is! PersistentGeometryKernelAPI || directory == null) {
      return shape;
    }
    final nativePath = path.join(
      directory.path,
      'NativeShapes',
      _nativeShapeFileName(shape.persistentId),
    );
    if (!await File(nativePath).exists()) return shape;
    try {
      return await kernel.restoreShape(
        nativePath,
        persistentId: shape.persistentId,
      );
    } on StateError {
      return shape;
    }
  }

  T? read<T>(String key) => _state[key] as T?;
  T readOrCreate<T>(String key, T Function() create) =>
      (_state[key] ??= create()) as T;
  void write<T>(String key, T? value, {bool notify = false}) {
    if (value == null) {
      _state.remove(key);
    } else {
      _state[key] = value;
    }
    if (notify) notifyListeners();
  }

  Future<void> open(String projectId, Directory directory) {
    if (_closingAdmission) return Future.error(const CadRuntimeShuttingDown());
    if (_callingTransaction != null) {
      return Future.error(StateError('Reentrant runtime transaction.'));
    }
    final generation = ++_lifecycleGeneration;
    return _enqueue(
      (tx) => _openInTransaction(tx, projectId, directory),
      lifecycle: generation,
    );
  }

  Future<void> close() {
    if (_closingAdmission) return Future.error(const CadRuntimeShuttingDown());
    if (_callingTransaction != null) {
      return Future.error(StateError('Reentrant runtime transaction.'));
    }
    final generation = ++_lifecycleGeneration;
    return _enqueue((tx) async {
      try {
        await _saveInTransaction(tx);
        tx.validate();
        _install(tx, null, null, const [], const [], const [], boundary: true);
      } catch (_) {
        if (!_closingAdmission && _lifecycleGeneration == generation) {
          _sessionIdentity++;
          _sessionActive = _document != null;
          tx.notify = true;
        }
        rethrow;
      }
    }, lifecycle: generation);
  }

  KernelBounds? _recalculateWorkspaceBounds({
    Iterable<CadSceneEntity>? entities,
  }) {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;

    void include(Object? raw) {
      if (raw is! List || raw.length < 3) return;
      final x = (raw[0] as num?)?.toDouble();
      final y = (raw[1] as num?)?.toDouble();
      final z = (raw[2] as num?)?.toDouble();
      if (x == null ||
          y == null ||
          z == null ||
          !x.isFinite ||
          !y.isFinite ||
          !z.isFinite) {
        return;
      }
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      minZ = math.min(minZ, z);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
      maxZ = math.max(maxZ, z);
    }

    for (final entity in entities ?? scene.entities) {
      if (!entity.visible ||
          entity.id.contains(':world:') ||
          entity.kind == CadSceneEntityKind.preview) {
        continue;
      }
      final geometry = entity.geometry;
      final nodes = geometry['nodes'];
      if (nodes is List) {
        for (var index = 0; index + 2 < nodes.length; index += 3) {
          include([nodes[index], nodes[index + 1], nodes[index + 2]]);
        }
      }
      final points = geometry['points'];
      if (points is List) {
        for (final point in points) {
          include(point);
        }
      }
      final segments = geometry['segments'];
      if (segments is List) {
        for (final segment in segments.whereType<List>()) {
          for (final point in segment) {
            include(point);
          }
        }
      }
    }
    if (!minX.isFinite || !maxX.isFinite) return null;
    return KernelBounds(minX, minY, minZ, maxX, maxY, maxZ);
  }

  CadDocument _sanitizeLegacyWorkspaceState(CadDocument document) {
    var changed = false;

    Object? sanitize(Object? value) {
      if (value is List) return value.map(sanitize).toList(growable: false);
      if (value is! Map) return value;
      final output = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        if (const {
          'sketchState',
          'sketchOffset',
          'presentationOffset',
          'presentationOffsetNdcX',
          'presentationOffsetNdcY',
          'presentationTranslation',
          'temporaryCameraState',
          'dynamicTransformPreview',
          'hoverState',
        }.contains(key)) {
          changed = true;
          continue;
        }
        if (key == 'selectionState' && entry.value != 'none') {
          output[key] = 'none';
          changed = true;
          continue;
        }
        output[key] = sanitize(entry.value);
      }
      return output;
    }

    final entities = <String, CadDocumentEntity>{};
    for (final entity in document.entities.values) {
      final data = Map<String, dynamic>.from(sanitize(entity.data)! as Map);
      entities[entity.id] = CadDocumentEntity(
        id: entity.id,
        kind: entity.kind,
        data: data,
        shape: entity.shape,
        mesh: entity.mesh,
      );
    }
    final parameters = Map<String, dynamic>.from(
      sanitize(document.parameters)! as Map,
    );
    if (!changed) return document;
    return CadDocument(
      projectId: document.projectId,
      entities: Map.unmodifiable(entities),
      revisions: document.revisions,
      parameters: parameters,
      officialExportShapeId: document.officialExportShapeId,
    );
  }

  Future<void> registerImport(
    ImportedCadDocument imported, {
    KernelMeshGeometry? geometry,
  }) async {
    projection.clearTransient();
    geometrySelection.clear();
    for (final key in const [
      'selection.pick',
      'selection.bridge',
      'session.context',
      'recognition.report',
      'recognition.filter',
      'recognition.decisions',
      'sections.meshBvh',
    ]) {
      _state.remove(key);
    }
    final current = _requireDocument();
    final existingImports = current.entities.values
        .where((entity) => entity.kind == CadDocumentEntityKind.import)
        .toList();
    final originalFileName = path.basename(imported.sourcePath);
    final extension = path.extension(originalFileName);
    final stem = path.basenameWithoutExtension(originalFileName);
    final occupiedNames = existingImports
        .map(
          (entity) =>
              (entity.data['name'] as String? ??
                      path.basename(entity.data['sourcePath'] as String? ?? ''))
                  .toLowerCase(),
        )
        .toSet();
    var displayName = originalFileName;
    var copyNumber = 1;
    while (occupiedNames.contains(displayName.toLowerCase())) {
      displayName = '$stem $copyNumber$extension';
      copyNumber++;
    }
    var entityId = imported.id;
    var idCopyNumber = 1;
    while (current.entities.containsKey(entityId)) {
      entityId = '${imported.id}:import-$idCopyNumber';
      idCopyNumber++;
    }
    final sceneGeometry = geometry == null
        ? <String, dynamic>{}
        : {
            'nodes': geometry.nodes,
            'triangles': geometry.triangles,
            'bounds': imported.mesh!.bounds.toJson(),
          };
    await mutate(
      command: 'import.${imported.format.name}',
      upsert: [
        CadDocumentEntity(
          id: entityId,
          kind: CadDocumentEntityKind.import,
          shape: imported.shape,
          mesh: imported.mesh,
          data: {
            'name': displayName,
            'originalFileName': originalFileName,
            'sourcePath': imported.sourcePath,
            'registeredPath': imported.registeredPath,
            'format': imported.format.name,
            'collectionId': 'collection:original',
            'validation': imported.validation,
            'sceneKind': imported.mesh == null ? 'solid' : 'mesh',
            'sceneGeometry': {
              ...sceneGeometry,
              if (imported.shape != null) 'handle': imported.shape!.toJson(),
            },
          },
        ),
      ],
      officialExportShapeId: imported.shape == null
          ? current.officialExportShapeId
          : imported.id,
    );
    _activeImport = imported;
    _activeMeshGeometry = geometry;
    _workspaceBounds = _recalculateWorkspaceBounds();
    notifyListeners();
  }

  Future<void> mutate({
    required String command,
    Iterable<CadDocumentEntity> upsert = const [],
    Iterable<String> remove = const [],
    String? officialExportShapeId,
    OfficialExportUpdate officialExport = const OfficialExportUpdate.keep(),
  }) {
    final rejection = _admissionError;
    if (rejection != null) return Future<void>.error(rejection);
    try {
      if (officialExportShapeId != null &&
          officialExport.action != OfficialExportAction.keep) {
        throw ArgumentError('Specify only one official export update.');
      }
      final exportUpdate = officialExportShapeId == null
          ? officialExport
          : OfficialExportUpdate.set(officialExportShapeId);
      final requested = upsert
          .map(_snapshots.captureEntity)
          .toList(growable: false);
      final removed = remove.toList(growable: false);
      return _enqueue(
        (tx) => _mutateDocument(
          tx,
          command: command,
          requested: requested,
          removed: removed,
          officialExport: exportUpdate,
        ),
      );
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
  }

  Future<void> _mutateDocument(
    _CadTransaction tx, {
    required String command,
    List<CadDocumentEntity> requested = const [],
    List<String> removed = const [],
    OfficialExportUpdate officialExport = const OfficialExportUpdate.keep(),
    Set<String> restoredIds = const {},
    Map<String, FeatureLifecycleState> stateOverrides = const {},
    bool displayOnly = false,
  }) async {
    tx.validate();
    final before = _snapshots.document(_requireDocument());
    // Only known normalized snapshots can bypass normalization safely.
    if (stateOverrides.isEmpty &&
        officialExport.action != OfficialExportAction.set &&
        _snapshots.isNormalized(before) &&
        !removed.any(before.entities.containsKey) &&
        (officialExport.resolve(before.officialExportShapeId) ==
            before.officialExportShapeId) &&
        requested.every(
          (entity) =>
              before.entities[entity.id] != null &&
              _sameJson(before.entities[entity.id]!.toJson(), entity.toJson()),
        )) {
      return;
    }
    final touchedIds =
        requested
            .where((entity) {
              final previous = before.entities[entity.id];
              return !displayOnly &&
                  (previous == null ||
                      _definitionJson(previous) != _definitionJson(entity));
            })
            .map((entity) => entity.id)
            .toSet()
          ..addAll(stateOverrides.keys);
    final mutated = _detachRetiredCollections(
      before,
      before.mutate(
        command: command,
        upsert: requested,
        remove: removed,
        officialExport: _exportUpdateForDelta(
          before,
          requested,
          removed,
          officialExport,
        ),
      ),
    );
    final candidate = FeatureLifecycleProjector.normalize(
      mutated,
      command: command,
      previousDocument: before,
      touchedIds: touchedIds,
      stateOverrides: stateOverrides,
    );
    _validateAssociations(before, candidate, requested);
    _validateDependencyDelta(
      before,
      candidate,
      requested,
      removed,
      restoredIds,
    );
    final candidateContent = candidate.toJson()..remove('revisions');
    final previousContent = before.toJson()..remove('revisions');
    if (_sameJson(candidateContent, previousContent)) return;
    await _commitDocument(tx, candidate, [..._undo, before], const []);
  }

  Future<void> transitionFeature(
    String id,
    FeatureLifecycleState state, {
    required String command,
  }) => _enqueue((tx) async {
    final current =
        _requireDocument().entities[id] ??
        (throw StateError('Unknown Feature: $id'));
    if (!FeatureLifecycleContract.appliesTo(current)) {
      throw StateError(
        '$id does not implement the Feature Lifecycle Contract.',
      );
    }
    if (FeatureLifecycleContract.require(current).state == state) return;
    await _mutateDocument(
      tx,
      command: command,
      requested: [current],
      stateOverrides: {id: state},
    );
  });

  Future<void> upsertEntity({
    required String command,
    required CadDocumentEntityKind kind,
    required CadSceneEntity entity,
    ShapeHandle? shape,
    KernelMeshHandle? mesh,
    Map<String, dynamic> data = const {},
    bool officialShape = false,
  }) async {
    if (shape != null) await _persistNativeShape(shape);
    await mutate(
      command: command,
      upsert: [
        CadDocumentEntity(
          id: entity.id,
          kind: kind,
          shape: shape,
          mesh: mesh,
          data: {
            ...data,
            'collectionId': data['collectionId'] ?? _defaultCollectionFor(kind),
            'sceneKind': entity.kind.name,
            'sceneGeometry': entity.geometry,
            'sceneVisible': entity.visible,
            'sceneTransparent': entity.transparent,
          },
        ),
      ],
      officialExportShapeId: officialShape ? entity.id : null,
    );
  }

  /// Publishes one Feature and its persistent topology in a single document
  /// transaction, so Undo/Redo can never separate a face from its boundaries.
  Future<void> upsertEntityBatch({
    required String command,
    required List<CadDocumentEntity> entities,
    Iterable<String> remove = const [],
    String? officialExportShapeId,
  }) async {
    for (final entity in entities) {
      if (entity.shape != null) await _persistNativeShape(entity.shape!);
    }
    await mutate(
      command: command,
      upsert: entities,
      remove: remove,
      officialExportShapeId: officialExportShapeId,
    );
  }

  /// Resolves a persisted kernel shape into the active native kernel session.
  Future<ShapeHandle> loadShape(ShapeHandle handle) => _loadedShape(handle);

  Future<void> persistShape(ShapeHandle handle) => _persistNativeShape(handle);

  String _defaultCollectionFor(CadDocumentEntityKind kind) => switch (kind) {
    CadDocumentEntityKind.reference => 'collection:references',
    CadDocumentEntityKind.curve => 'collection:modified',
    CadDocumentEntityKind.vertex ||
    CadDocumentEntityKind.edge ||
    CadDocumentEntityKind.wire ||
    CadDocumentEntityKind.face ||
    CadDocumentEntityKind.shell ||
    CadDocumentEntityKind.solid => 'collection:modified',
    CadDocumentEntityKind.import => 'collection:original',
    CadDocumentEntityKind.collection => 'collection:modified',
    CadDocumentEntityKind.recognition => 'collection:modified',
    _ => 'collection:modified',
  };

  Future<void> removeEntity(String id, {required String command}) =>
      _enqueue((tx) => _removeDocumentEntities(tx, [id], command: command));

  Future<void> _removeDocumentEntities(
    _CadTransaction tx,
    List<String> ids, {
    required String command,
  }) {
    final document = _requireDocument();
    for (final id in ids) {
      final entity = document.entities[id];
      if (entity != null && WorldCoordinateSystem.isProtected(entity)) {
        throw StateError(
          '${entity.data['name']} is a protected system entity.',
        );
      }
    }
    final removedCollections = ids
        .where(
          (id) =>
              document.entities[id]?.kind == CadDocumentEntityKind.collection,
        )
        .toSet();
    final detached = <CadDocumentEntity>[];
    for (final member in document.entities.values) {
      if (!ids.contains(member.id) &&
          removedCollections.contains(member.data['collectionId'])) {
        final data = {...member.data, 'collectionId': null};
        detached.add(
          CadDocumentEntity(
            id: member.id,
            kind: member.kind,
            shape: member.shape,
            mesh: member.mesh,
            data: data,
          ),
        );
      }
    }
    return _mutateDocument(
      tx,
      command: command,
      removed: ids,
      requested: detached,
    );
  }

  Future<void> setEntityVisibility(String id, bool visible) =>
      _enqueue((tx) async {
        final entity =
            _requireDocument().entities[id] ??
            (throw StateError('Unknown document entity: $id'));
        if (entity.kind == CadDocumentEntityKind.collection) {
          await _updateCollection(tx, id, visible: visible);
          return;
        }
        if ((entity.data['sceneVisible'] ?? true) == visible) return;
        await _mutateDocument(
          tx,
          command: 'display.visibility',
          displayOnly: true,
          requested: [
            CadDocumentEntity(
              id: entity.id,
              kind: entity.kind,
              shape: entity.shape,
              mesh: entity.mesh,
              data: {...entity.data, 'sceneVisible': visible},
            ),
          ],
        );
      });

  Future<void> applyAlignmentTransform(Matrix4 matrix) async {
    final ids = _requireDocument().entities.values
        .where(
          (entity) =>
              entity.kind != CadDocumentEntityKind.collection &&
              !WorldCoordinateSystem.isProtected(entity),
        )
        .map((entity) => entity.id)
        .toSet();
    await applyEntityTransform(ids, matrix, command: 'alignment.apply');
  }

  /// Applies the official document transform to a selected set of entities.
  ///
  /// Geometry stays owned by [CadDocument]; the scene graph receives only the
  /// incremental projection emitted by [mutate]. Kernel-backed BRep entities
  /// are transformed through the active kernel's native shape-transform
  /// contract, preventing display-only transforms from diverging from the
  /// official export shape.
  Future<void> applyEntityTransform(
    Set<String> entityIds,
    Matrix4 matrix, {
    String command = 'transform.apply',
    bool createCopy = false,
  }) async {
    if (entityIds.isEmpty) {
      throw StateError('Select at least one entity to transform.');
    }
    final current = _requireDocument();
    final transformed = <CadDocumentEntity>[];
    String? exportEntityId;
    String? workingCollectionId;
    if (createCopy) {
      workingCollectionId = _nextWorkingCollectionId(current);
      transformed.add(
        _collectionEntity(
          workingCollectionId,
          'Working Copy ${workingCollectionId.split('-').last}',
          color: 'blue',
          active: true,
        ),
      );
      for (final collection in current.entities.values.where(
        (item) => item.kind == CadDocumentEntityKind.collection,
      )) {
        if (collection.data['active'] == true) {
          transformed.add(
            CadDocumentEntity(
              id: collection.id,
              kind: collection.kind,
              data: {...collection.data, 'active': false},
            ),
          );
        }
      }
    }
    for (final id in entityIds) {
      final entity = current.entities[id];
      if (entity == null) throw StateError('Unknown document entity: $id');
      if (WorldCoordinateSystem.isProtected(entity)) {
        throw StateError(
          '${entity.data['name']} is a protected system entity.',
        );
      }
      final collection = current.entities[entity.data['collectionId']];
      if (collection?.data['locked'] == true) {
        throw StateError(
          '${collection!.data['name']} is locked. Unlock it before transforming entities.',
        );
      }
      final data = _transformEntityData(entity.data, matrix);
      ShapeHandle? shape = entity.shape;
      if (shape != null) {
        final kernel = kernels.active;
        if (kernel is! ShapeTransformGeometryKernelAPI) {
          throw StateError(
            '${kernel.descriptor.name} does not implement ShapeTransformGeometryKernelAPI.',
          );
        }
        shape = await kernel.transformShape(
          await _loadedShape(shape),
          matrix.values,
          projectId: current.projectId,
          copyGeometry: true,
        );
        await _persistNativeShape(shape);
        data['sceneGeometry'] = {
          ...Map<String, dynamic>.from(
            data['sceneGeometry'] as Map? ?? const {},
          ),
          'handle': shape.toJson(),
        };
      }
      final outputId = createCopy
          ? 'copy:${shape?.persistentId ?? '${entity.id}:${DateTime.now().microsecondsSinceEpoch}'}'
          : entity.id;
      if (createCopy) {
        data['name'] = '${entity.data['name'] ?? entity.id} (Working Copy)';
        data['sourceEntityId'] = entity.id;
        data['collectionId'] = workingCollectionId;
      } else {
        data['collectionId'] = 'collection:modified';
      }
      transformed.add(
        CadDocumentEntity(
          id: outputId,
          kind: entity.kind,
          shape: shape,
          mesh: _alignedMeshHandle(entity.mesh, data),
          data: data,
        ),
      );
      if (shape != null) exportEntityId = outputId;
    }
    await mutate(
      command: createCopy ? '$command.copy' : command,
      upsert: transformed,
      officialExportShapeId: exportEntityId,
    );
    _restoreActiveImport();
    notifyListeners();
  }

  Future<ShapeHandle> _loadedShape(ShapeHandle handle) async {
    final kernel = kernels.active;
    final directory = _projectDirectory;
    if (kernel is! PersistentGeometryKernelAPI || directory == null) {
      return handle;
    }
    final payload = path.join(
      directory.path,
      'NativeShapes',
      _nativeShapeFileName(handle.persistentId),
    );
    if (!await File(payload).exists()) return handle;
    try {
      return await kernel.restoreShape(
        payload,
        persistentId: handle.persistentId,
      );
    } on StateError {
      return handle;
    }
  }

  Future<void> _persistNativeShape(ShapeHandle handle) async {
    final kernel = kernels.active;
    final directory = _projectDirectory;
    if (kernel is! PersistentGeometryKernelAPI || directory == null) return;
    final folder = Directory(path.join(directory.path, 'NativeShapes'));
    await folder.create(recursive: true);
    await kernel.persistShape(
      handle,
      path.join(folder.path, _nativeShapeFileName(handle.persistentId)),
    );
  }

  /// Persistent IDs are CAD identities, not filesystem names. In particular,
  /// generated entities use ':' separators, which Windows rejects in paths.
  String _nativeShapeFileName(String persistentId) {
    final safe = persistentId
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '_');
    return '${safe.isEmpty ? 'shape' : safe}.brep';
  }

  String _nextWorkingCollectionId(CadDocument document) {
    var index = 1;
    while (document.entities.containsKey(
      'collection:working-copy-${index.toString().padLeft(3, '0')}',
    )) {
      index++;
    }
    return 'collection:working-copy-${index.toString().padLeft(3, '0')}';
  }

  KernelMeshHandle? _alignedMeshHandle(
    KernelMeshHandle? handle,
    Map<String, dynamic> data,
  ) {
    if (handle == null) return null;
    final scene = data['sceneGeometry'];
    final bounds = scene is Map ? scene['bounds'] : null;
    if (bounds is! Map || bounds['min'] is! List || bounds['max'] is! List) {
      return handle;
    }
    final minimum = (bounds['min'] as List).cast<num>();
    final maximum = (bounds['max'] as List).cast<num>();
    return KernelMeshHandle(
      persistentId: handle.persistentId,
      kernelId: handle.kernelId,
      fingerprint: handle.fingerprint,
      vertexCount: handle.vertexCount,
      triangleCount: handle.triangleCount,
      bounds: KernelBounds(
        minimum[0].toDouble(),
        minimum[1].toDouble(),
        minimum[2].toDouble(),
        maximum[0].toDouble(),
        maximum[1].toDouble(),
        maximum[2].toDouble(),
      ),
      hasNormals: handle.hasNormals,
      metadata: {...handle.metadata, 'aligned': true},
      degenerateTriangleCount: handle.degenerateTriangleCount,
    );
  }

  Map<String, dynamic> _transformEntityData(
    Map<String, dynamic> source,
    Matrix4 matrix,
  ) {
    final result = Map<String, dynamic>.from(source);
    final scene = source['sceneGeometry'];
    if (scene is Map) {
      result['sceneGeometry'] = _transformGeometry(
        Map<String, dynamic>.from(scene),
        matrix,
      );
    }
    final reference = source['reference'];
    if (reference is Map && reference['geometry'] is Map) {
      final copy = Map<String, dynamic>.from(reference);
      copy['geometry'] = _transformGeometry(
        Map<String, dynamic>.from(reference['geometry'] as Map),
        matrix,
      );
      result['reference'] = copy;
    }
    final sketch = source['sketch'];
    if (sketch is Map && sketch['coordinates'] is Map) {
      final copy = Map<String, dynamic>.from(sketch);
      copy['coordinates'] = _transformGeometry(
        Map<String, dynamic>.from(sketch['coordinates'] as Map),
        matrix,
      );
      result['sketch'] = copy;
    }
    final localCoordinates = source['localCoordinateSystem'];
    if (localCoordinates is Map) {
      result['localCoordinateSystem'] = _transformGeometry(
        Map<String, dynamic>.from(localCoordinates),
        matrix,
      );
    }
    final section = source['section'];
    if (section is Map) {
      result['section'] = _transformGeometry(
        Map<String, dynamic>.from(section),
        matrix,
      );
    }
    final previous = source['transformMatrix'];
    final cumulative = previous is List && previous.length == 16
        ? matrix *
              Matrix4(previous.cast<num>().map((v) => v.toDouble()).toList())
        : matrix;
    result['transformMatrix'] = cumulative.values;
    result['alignmentMatrix'] = cumulative.values;
    return result;
  }

  Map<String, dynamic> transformedSceneGeometry(
    CadDocumentEntity entity,
    Matrix4 matrix,
  ) {
    final geometry = entity.data['sceneGeometry'];
    if (geometry is! Map) {
      throw StateError('${entity.id} has no projectable geometry.');
    }
    return _transformGeometry(Map<String, dynamic>.from(geometry), matrix);
  }

  Map<String, dynamic> _transformGeometry(
    Map<String, dynamic> geometry,
    Matrix4 matrix,
  ) {
    final result = Map<String, dynamic>.from(geometry);
    Vector3 point(List value) => Vector3(
      (value[0] as num).toDouble(),
      (value[1] as num).toDouble(),
      (value[2] as num).toDouble(),
    );
    List<double> transformedPoint(List value) {
      final p = matrix.transformPoint(point(value));
      return [p.x, p.y, p.z];
    }

    List<double> transformedDirection(List value) {
      final origin = matrix.transformPoint(Vector3.zero);
      final p = matrix.transformPoint(point(value));
      final direction = (p - origin).normalized;
      return [direction.x, direction.y, direction.z];
    }

    final nodes = geometry['nodes'];
    if (nodes is List) {
      final values = nodes.cast<num>();
      final output = <double>[];
      for (var i = 0; i + 2 < values.length; i += 3) {
        output.addAll(transformedPoint(values.sublist(i, i + 3)));
      }
      result['nodes'] = output;
      if (output.isNotEmpty) {
        final xs = <double>[], ys = <double>[], zs = <double>[];
        for (var i = 0; i < output.length; i += 3) {
          xs.add(output[i]);
          ys.add(output[i + 1]);
          zs.add(output[i + 2]);
        }
        xs.sort();
        ys.sort();
        zs.sort();
        result['bounds'] = {
          'min': [xs.first, ys.first, zs.first],
          'max': [xs.last, ys.last, zs.last],
        };
      }
    }
    final points = geometry['points'];
    if (points is List) {
      result['points'] = [
        for (final value in points)
          if (value is List) transformedPoint(value),
      ];
    }
    final segments = geometry['segments'];
    if (segments is List) {
      result['segments'] = [
        for (final raw in segments)
          if (raw is List && raw.length >= 2)
            [
              transformedPoint(raw[0] as List),
              transformedPoint(raw[1] as List),
            ],
      ];
    }
    for (final key in const ['origin', 'position', 'center']) {
      final value = geometry[key];
      if (value is List && value.length >= 3) {
        result[key] = transformedPoint(value);
      }
    }
    for (final key in const [
      'normal',
      'direction',
      'xDirection',
      'xAxis',
      'yAxis',
      'zAxis',
    ]) {
      final value = geometry[key];
      if (value is List && value.length >= 3) {
        result[key] = transformedDirection(value);
      }
    }
    return result;
  }

  void showTransient(CadSceneEntity entity) =>
      projection.upsertTransient(entity);

  Future<void> showTransientShape(
    CadSceneEntity entity,
    ShapeHandle shape,
  ) async {
    projection.upsertTransient(entity);
    final meshes = _displayMeshes;
    if (meshes == null) return;
    await meshes.upsert(entityId: entity.id, shape: shape);
    final rendered = scene.find(entity.id);
    if (rendered != null) projection.upsertTransient(rendered);
  }

  Future<ShapeHandle> previewNativeShapeTransform(
    ShapeHandle source,
    Matrix4 matrix,
  ) async {
    final kernel = kernels.active;
    if (kernel is! ShapeTransformGeometryKernelAPI) {
      throw StateError(
        '${kernel.descriptor.name} does not support native shape transforms.',
      );
    }
    return kernel.transformShape(
      await _loadedShape(source),
      matrix.values,
      projectId: _requireDocument().projectId,
      copyGeometry: true,
    );
  }

  void hideTransient(String id) => projection.removeTransient(id);

  CadDocument _ensureProfessionalCollections(CadDocument document) {
    const definitions = [
      ('collection:original', 'Original', 'gray'),
      ('collection:working-copy', 'Working Copy', 'blue'),
      ('collection:modified', 'Modified', 'orange'),
      ('collection:inspection', 'Inspection', 'purple'),
      ('collection:references', 'References', 'teal'),
      ('collection:recycle-bin', 'Recycle Bin', 'red'),
    ];
    final missing = <CadDocumentEntity>[];
    for (final definition in definitions) {
      if (!document.entities.containsKey(definition.$1)) {
        missing.add(
          _collectionEntity(
            definition.$1,
            definition.$2,
            color: definition.$3,
            active: definition.$1 == 'collection:original',
          ),
        );
      }
    }
    for (final entity in document.entities.values) {
      if (entity.kind == CadDocumentEntityKind.collection ||
          entity.data.containsKey('collectionId')) {
        continue;
      }
      missing.add(
        CadDocumentEntity(
          id: entity.id,
          kind: entity.kind,
          shape: entity.shape,
          mesh: entity.mesh,
          data: {
            ...entity.data,
            'collectionId': _defaultCollectionFor(entity.kind),
          },
        ),
      );
    }
    if (missing.isEmpty) return document;
    return document.mutate(command: 'collections.initialize', upsert: missing);
  }

  CadDocumentEntity _collectionEntity(
    String id,
    String name, {
    required String color,
    bool active = false,
  }) => CadDocumentEntity(
    id: id,
    kind: CadDocumentEntityKind.collection,
    data: {
      'name': name,
      'color': color,
      'visible': true,
      'locked': id == 'collection:recycle-bin',
      'active': active,
      'systemCollection':
          id.startsWith('collection:') &&
          !id.startsWith('collection:working-copy-'),
    },
  );

  Future<void> updateCollection(
    String id, {
    String? name,
    bool? visible,
    bool? locked,
    bool? active,
    Iterable<String> addMembers = const [],
    Iterable<String> removeMembers = const [],
  }) {
    final rejection = _admissionError;
    if (rejection != null) return Future<void>.error(rejection);
    try {
      final added = addMembers.toList(growable: false);
      final removed = removeMembers.toList(growable: false);
      return _enqueue(
        (tx) => _updateCollection(
          tx,
          id,
          name: name,
          visible: visible,
          locked: locked,
          active: active,
          addMembers: added,
          removeMembers: removed,
        ),
      );
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
  }

  Future<void> _updateCollection(
    _CadTransaction tx,
    String id, {
    String? name,
    bool? visible,
    bool? locked,
    bool? active,
    List<String> addMembers = const [],
    List<String> removeMembers = const [],
  }) async {
    final document = _requireDocument();
    final collection = document.entities[id];
    if (collection?.kind != CadDocumentEntityKind.collection) {
      throw StateError('Unknown Collection: $id');
    }
    if (addMembers.isNotEmpty && collection!.data['deleted'] == true) {
      throw StateError('Recycled collection cannot receive members: $id');
    }
    final collectionData = Map<String, dynamic>.from(collection!.data);
    if (name != null) collectionData['name'] = name;
    if (visible != null) collectionData['visible'] = visible;
    if (locked != null) collectionData['locked'] = locked;
    if (active != null) collectionData['active'] = active;
    final updates = <CadDocumentEntity>[
      CadDocumentEntity(id: id, kind: collection.kind, data: collectionData),
    ];
    if (active == true) {
      updates.addAll(
        document.entities.values
            .where(
              (item) =>
                  item.kind == CadDocumentEntityKind.collection &&
                  item.id != id &&
                  item.data['active'] == true,
            )
            .map(
              (item) => CadDocumentEntity(
                id: item.id,
                kind: item.kind,
                data: {...item.data, 'active': false},
              ),
            ),
      );
    }
    if (visible != null) {
      updates.addAll(
        document.entities.values
            .where((item) => item.data['collectionId'] == id)
            .map(
              (item) => CadDocumentEntity(
                id: item.id,
                kind: item.kind,
                shape: item.shape,
                mesh: item.mesh,
                data: {...item.data, 'sceneVisible': visible},
              ),
            ),
      );
    }
    final members = <String, CadDocumentEntity>{
      for (final e in updates) e.id: e,
    };
    for (final memberId in {...removeMembers, ...addMembers}) {
      final member = document.entities[memberId];
      if (member == null ||
          member.kind == CadDocumentEntityKind.collection ||
          WorldCoordinateSystem.isProtected(member) ||
          member.data['deleted'] == true) {
        throw StateError('Invalid collection member: $memberId');
      }
      final added = addMembers.contains(memberId);
      if (!added && member.data['collectionId'] != id) continue;
      final data = {...(members[memberId] ?? member).data};
      if (added) {
        data['collectionId'] = id;
        if (visible != null) data['sceneVisible'] = visible;
      } else {
        data['collectionId'] = null;
      }
      members[memberId] = CadDocumentEntity(
        id: member.id,
        kind: member.kind,
        shape: member.shape,
        mesh: member.mesh,
        data: data,
      );
    }
    final visibilityOnly =
        visible != null &&
        name == null &&
        locked == null &&
        active == null &&
        addMembers.isEmpty &&
        removeMembers.isEmpty;
    await _mutateDocument(
      tx,
      command: visibilityOnly ? 'collection.visibility' : 'collection.update',
      displayOnly: visibilityOnly,
      requested: members.values.toList(),
    );
  }

  Future<void> duplicateCollection(String id) async {
    final document = _requireDocument();
    final source = document.entities[id];
    if (source?.kind != CadDocumentEntityKind.collection) {
      throw StateError('Unknown Collection: $id');
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final copyId = 'collection:copy-$stamp';
    final copies = <CadDocumentEntity>[
      _collectionEntity(
        copyId,
        '${source!.data['name']} Copy',
        color: source.data['color'] as String? ?? 'blue',
      ),
    ];
    for (final entity in document.entities.values.where(
      (item) => item.data['collectionId'] == id && item.data['deleted'] != true,
    )) {
      ShapeHandle? shape = entity.shape;
      if (shape != null) {
        final kernel = kernels.active;
        if (kernel is! ShapeTransformGeometryKernelAPI) {
          throw StateError(
            '${kernel.descriptor.name} cannot duplicate native shapes.',
          );
        }
        shape = await kernel.transformShape(
          await _loadedShape(shape),
          Matrix4.identity().values,
          projectId: document.projectId,
          copyGeometry: true,
        );
        await _persistNativeShape(shape);
      }
      final entityId = 'copy:${shape?.persistentId ?? '${entity.id}:$stamp'}';
      copies.add(
        CadDocumentEntity(
          id: entityId,
          kind: entity.kind,
          shape: shape,
          mesh: entity.mesh,
          data: {
            ...entity.data,
            'name': '${entity.data['name'] ?? entity.id} Copy',
            'sourceEntityId': entity.id,
            'collectionId': copyId,
            if (shape != null)
              'sceneGeometry': {
                ...Map<String, dynamic>.from(
                  entity.data['sceneGeometry'] as Map? ?? const {},
                ),
                'handle': shape.toJson(),
              },
          },
        ),
      );
    }
    await mutate(command: 'collection.duplicate', upsert: copies);
  }

  List<CadDocumentEntity> dependencyImpact(String entityId) {
    final document = _requireDocument();
    final reverse = _reverseDependencies(document);
    final seen = {entityId}, pending = [entityId];
    while (pending.isNotEmpty) {
      for (final id in reverse[pending.removeLast()] ?? const <String>{}) {
        if (seen.add(id)) pending.add(id);
      }
    }
    seen.remove(entityId);
    return seen.map((id) => document.entities[id]!).toList();
  }

  Future<void> moveToRecycleBin(
    String entityId, {
    required bool includeDependencies,
  }) => _enqueue((tx) async {
    final document = _requireDocument();
    final target =
        document.entities[entityId] ??
        (throw StateError('Unknown document entity: $entityId'));
    if (WorldCoordinateSystem.isProtected(target)) {
      throw StateError('World Coordinate System entities cannot be deleted.');
    }
    final entities = <CadDocumentEntity>[
      if (target.data['deleted'] != true) target,
      if (includeDependencies)
        ...dependencyImpact(entityId).where((e) => e.data['deleted'] != true),
    ];
    if (entities.any(WorldCoordinateSystem.isProtected)) {
      throw StateError('Protected entities cannot be recycled.');
    }
    await _mutateDocument(
      tx,
      command: 'recycle.delete',
      requested: [
        for (final entity in entities)
          CadDocumentEntity(
            id: entity.id,
            kind: entity.kind,
            shape: entity.shape,
            mesh: entity.mesh,
            data: {
              ...entity.data,
              'deleted': true,
              'deletedAt': DateTime.now().toUtc().toIso8601String(),
              'previousCollectionId': entity.data['collectionId'],
              'collectionId': 'collection:recycle-bin',
              'sceneVisible': false,
            },
          ),
      ],
    );
  });

  Future<void> restoreFromRecycleBin(
    String entityId, {
    Iterable<String> additionalIds = const [],
  }) {
    final rejection = _admissionError;
    if (rejection != null) return Future<void>.error(rejection);
    try {
      final ids = {entityId, ...additionalIds}.toList(growable: false);
      return _enqueue((tx) async {
        final updates = <CadDocumentEntity>[];
        final restoring = <String>{};
        for (final entityId in ids) {
          final entity =
              _requireDocument().entities[entityId] ??
              (throw StateError('Unknown document entity: $entityId'));
          if (entity.data['deleted'] != true) {
            continue;
          }
          restoring.add(entityId);
          final data = Map<String, dynamic>.from(entity.data)
            ..remove('deleted')
            ..remove('deletedAt');
          final previousId = data.remove('previousCollectionId');
          final collection = _requireDocument().entities[previousId];
          data['collectionId'] =
              collection?.kind == CadDocumentEntityKind.collection &&
                  collection?.data['deleted'] != true
              ? previousId
              : null;
          data['sceneVisible'] = true;
          updates.add(
            CadDocumentEntity(
              id: entity.id,
              kind: entity.kind,
              shape: entity.shape,
              mesh: entity.mesh,
              data: data,
            ),
          );
        }
        await _mutateDocument(
          tx,
          command: 'recycle.restore',
          requested: updates,
          restoredIds: restoring,
        );
      });
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
  }

  Future<void> permanentlyDelete(String entityId) => _enqueue((tx) async {
    final entity = _requireDocument().entities[entityId];
    if (entity == null) return;
    if (entity.data['deleted'] != true) {
      throw StateError('Only Recycle Bin entities can be permanently deleted.');
    }
    // Physical cleanup is deferred: undo/redo still own the resource references.
    await _removeDocumentEntities(tx, [entityId], command: 'recycle.purge');
  });

  Future<void> undoDocument() => _enqueue((tx) async {
    if (_undo.isEmpty) return;
    final candidate = FeatureLifecycleProjector.normalize(
      _undo.last,
      command: 'document.undo.lifecycle-restore',
    );
    await _commitDocument(tx, candidate, _undo.sublist(0, _undo.length - 1), [
      ..._redo,
      _requireDocument(),
    ]);
  });

  Future<void> redoDocument() => _enqueue((tx) async {
    if (_redo.isEmpty) return;
    final candidate = FeatureLifecycleProjector.normalize(
      _redo.last,
      command: 'document.redo.lifecycle-restore',
    );
    await _commitDocument(tx, candidate, [
      ..._undo,
      _requireDocument(),
    ], _redo.sublist(0, _redo.length - 1));
  });

  Future<void> save({bool recordLifecycle = false}) => _enqueue((tx) async {
    final document = _document;
    if (recordLifecycle && document != null) {
      final featureIds = document.entities.values
          .where(FeatureLifecycleContract.appliesTo)
          .map((e) => e.id)
          .toSet();
      final candidate = FeatureLifecycleProjector.normalize(
        document,
        command: 'project.save',
        previousDocument: document,
        touchedIds: featureIds,
        actionOverrides: {for (final id in featureIds) id: 'saved'},
      );
      await _commitDocument(tx, candidate, List.of(_undo), List.of(_redo));
    } else {
      await _saveInTransaction(tx);
    }
  });

  void select(Set<String> ids) {
    geometrySelection.replace(ids);
    notifyListeners();
  }

  CadDocument _requireDocument() =>
      _document ?? (throw StateError('CadRuntime has no active document.'));

  String _definitionJson(CadDocumentEntity entity) {
    final json = entity.toJson();
    final data = Map<String, dynamic>.from(json['data'] as Map)
      ..remove(FeatureLifecycleContract.dataKey);
    json['data'] = data;
    return jsonEncode(_orderedJson(json));
  }

  void _restoreActiveImport() {
    final state = _readImport(_document!);
    _activeImport = state.$1;
    _activeMeshGeometry = state.$2;
  }

  (ImportedCadDocument?, KernelMeshGeometry?) _readImport(
    CadDocument document,
  ) {
    ImportedCadDocument? imported;
    KernelMeshGeometry? geometry;
    final imports = document.entities.values
        .where((entity) => entity.kind == CadDocumentEntityKind.import)
        .toList();
    if (imports.isEmpty) return (null, null);
    final value = imports.last, data = value.data;
    imported = ImportedCadDocument(
      id: value.id,
      projectId: document.projectId,
      sourcePath: data['sourcePath'] as String,
      registeredPath: data['registeredPath'] as String,
      format: CadImportFormat.values.byName(data['format'] as String),
      validation: (data['validation'] as List? ?? const []).cast<String>(),
      shape: value.shape,
      mesh: value.mesh,
    );
    final sceneGeometry = data['sceneGeometry'];
    if (sceneGeometry is Map && sceneGeometry['nodes'] is List) {
      geometry = KernelMeshGeometry(
        nodes: (sceneGeometry['nodes'] as List)
            .cast<num>()
            .map((value) => value.toDouble())
            .toList(),
        triangles: (sceneGeometry['triangles'] as List).cast<int>(),
      );
    }
    return (imported, geometry);
  }

  /// Public completion always means drainage, never internal acknowledgement.
  Future<void> shutdown() {
    final tx = _callingTransaction;
    if (tx != null) {
      _requestTransactionShutdown(tx);
      return Future<void>.error(
        StateError(
          'The active transaction cannot await its own shutdown drainage.',
        ),
      );
    }
    _requestShutdown();
    return _shutdownFuture!;
  }

  void _requestTransactionShutdown(_CadTransaction tx) {
    if (!tx.isActiveFor(this)) throw const StaleCadTransaction();
    _requestShutdown();
  }

  void _requestShutdown() {
    if (_shutdownFuture != null) return;
    _closingAdmission = true;
    if (!_assetShutdown.isCompleted) _assetShutdown.complete();
    _lifecycleGeneration++;
    _sessionActive = false;
    final done = Completer<void>();
    _shutdownFuture = done.future;
    unawaited(
      _transactionTail
          .then((_) {
            operationalSelection.dispose();
            operationalEntities.dispose();
            geometrySelection.dispose();
            scene.dispose();
            _shutdownFinished = true;
            dispose();
          })
          .then(done.complete, onError: done.completeError),
    );
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    if (!_shutdownFinished) {
      _requestShutdown();
      return;
    }
    _notifierDisposed = true;
    super.dispose();
  }
}
