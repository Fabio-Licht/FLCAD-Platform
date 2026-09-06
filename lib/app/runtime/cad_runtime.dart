import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../core/cad_document/cad_document.dart';
import '../../core/cad_document/cad_document_repository.dart';
import '../../core/cad_kernel/api/geometry_kernel_api.dart';
import '../../core/cad_kernel/io/kernel_io_models.dart';
import '../../core/cad_kernel/models/kernel_models.dart';
import '../../core/cad_kernel/manager/kernel_manager.dart';
import '../../core/feature_lifecycle/feature_lifecycle.dart';
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

class CadRuntime extends ChangeNotifier {
  CadRuntime({
    required this.kernels,
    CadDocumentRepository repository = const CadDocumentRepository(),
  }) : _repository = repository,
       scene = CadSceneGraph() {
    projection = CadDocumentSceneProjection(scene);
    geometrySelection = GeometrySelectionManager(scene);
    operationalEntities = OperationalEntityRegistry();
    operationalResolver = OperationalEntityResolver(operationalEntities);
    operationalSelection = OperationalSelectionManager(operationalEntities);
  }

  final CadDocumentRepository _repository;
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

  CadDocument? get document => _document;
  ImportedCadDocument? get activeImport => _activeImport;
  KernelMeshGeometry? get activeMeshGeometry => _activeMeshGeometry;
  KernelBounds? get workspaceBounds => _workspaceBounds;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  Set<String> get selection => geometrySelection.selectedIds;

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

  Future<void> open(String projectId, Directory directory) async {
    // A project boundary is also a hard boundary for every interaction-only
    // state. None of these values belongs to the durable CAD document.
    projection.clearTransient();
    geometrySelection.clear();
    operationalSelection.clear();
    operationalEntities.clear();
    recognitionSession = sketchSession = surfaceSession = null;
    _state.clear();
    _workspaceBounds = null;
    scene.clear();

    // 1. Load permanent document geometry and engineering entities.
    _projectDirectory = directory;
    _document = await _repository.load(projectId, directory);
    final sanitized = _sanitizeLegacyWorkspaceState(_document!);
    if (!identical(sanitized, _document)) {
      _document = sanitized;
      await _repository.save(_document!, directory);
    }
    final initialized = _ensureProfessionalCollections(
      WorldCoordinateSystem.ensure(_document!),
    );
    if (!identical(initialized, _document)) {
      _document = initialized;
      await _repository.save(_document!, directory);
    }
    final lifecycleDocument = FeatureLifecycleProjector.normalize(
      _document!,
      command: 'project.open.lifecycle-migration',
    );
    if (jsonEncode(lifecycleDocument.toJson()) !=
        jsonEncode(_document!.toJson())) {
      _document = lifecycleDocument;
      await _repository.save(_document!, directory);
    }
    final history = await _repository.loadHistory(directory);
    _displayMeshes = KernelDisplayMeshPipeline(
      kernel: kernels.active,
      projectId: projectId,
      projectDirectory: directory,
      scene: scene,
    );
    _restoreActiveImport();

    // 2. Rebuild the complete SceneGraph before publishing the project.
    await projection.synchronize(_document!, displayMeshes: _displayMeshes);

    // 3. Never trust a persisted display bound for camera recovery. Derive it
    // again from the rebuilt, permanent scene geometry.
    _workspaceBounds = _recalculateWorkspaceBounds();

    // 4. Enforce an empty transient layer after reconstruction as well. This
    // prevents a producer invoked during loading from leaking a preview.
    projection.clearTransient();
    geometrySelection.clear();
    operationalSelection.clear();
    _undo
      ..clear()
      ..addAll(history.undo.where((item) => item.projectId == projectId));
    _redo
      ..clear()
      ..addAll(history.redo.where((item) => item.projectId == projectId));
    notifyListeners();
  }

  Future<void> close() async {
    await save();
    _document = null;
    _projectDirectory = null;
    _activeImport = null;
    _activeMeshGeometry = null;
    _displayMeshes = null;
    _workspaceBounds = null;
    geometrySelection.clear();
    recognitionSession = sketchSession = surfaceSession = null;
    _state.clear();
    projection.clearTransient();
    await projection.synchronize(CadDocument.empty('closed'));
    notifyListeners();
  }

  KernelBounds? _recalculateWorkspaceBounds() {
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

    for (final entity in scene.entities) {
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
  }) async {
    final requested = upsert.toList(growable: false);
    final removed = remove.toList(growable: false);
    final before = _requireDocument();
    final touchedIds = requested
        .where((entity) {
          final previous = before.entities[entity.id];
          return previous == null ||
              _definitionJson(previous) != _definitionJson(entity);
        })
        .map((entity) => entity.id)
        .toSet();
    _undo.add(before);
    _redo.clear();
    final mutated = before.mutate(
      command: command,
      upsert: requested,
      remove: removed,
      officialExportShapeId: officialExportShapeId,
    );
    _document = FeatureLifecycleProjector.normalize(
      mutated,
      command: command,
      previousDocument: before,
      touchedIds: touchedIds,
    );
    final changed = _document!.entities.values
        .where((entity) {
          final previous = before.entities[entity.id];
          return previous == null ||
              jsonEncode(previous.toJson()) != jsonEncode(entity.toJson());
        })
        .toList(growable: false);
    await projection.synchronizeChanges(
      _document!,
      upsert: changed,
      remove: removed,
      displayMeshes: _displayMeshes,
    );
    await save();
    notifyListeners();
  }

  Future<void> transitionFeature(
    String id,
    FeatureLifecycleState state, {
    required String command,
  }) async {
    final current =
        _requireDocument().entities[id] ??
        (throw StateError('Unknown Feature: $id'));
    if (!FeatureLifecycleContract.appliesTo(current)) {
      throw StateError(
        '$id does not implement the Feature Lifecycle Contract.',
      );
    }
    final before = _requireDocument();
    _undo.add(before);
    _redo.clear();
    final mutated = before.mutate(command: command, upsert: [current]);
    _document = FeatureLifecycleProjector.normalize(
      mutated,
      command: command,
      previousDocument: before,
      touchedIds: {id},
      stateOverrides: {id: state},
    );
    final changed = _document!.entities.values
        .where((entity) {
          final previous = before.entities[entity.id];
          return previous == null ||
              jsonEncode(previous.toJson()) != jsonEncode(entity.toJson());
        })
        .toList(growable: false);
    await projection.synchronizeChanges(
      _document!,
      upsert: changed,
      remove: const [],
      displayMeshes: _displayMeshes,
    );
    await save();
    notifyListeners();
  }

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

  Future<void> removeEntity(String id, {required String command}) {
    final entity = _requireDocument().entities[id];
    if (entity != null && WorldCoordinateSystem.isProtected(entity)) {
      throw StateError('${entity.data['name']} is a protected system entity.');
    }
    return mutate(command: command, remove: [id]);
  }

  Future<void> setEntityVisibility(String id, bool visible) async {
    final entity =
        _requireDocument().entities[id] ??
        (throw StateError('Unknown document entity: $id'));
    final sceneEntity = scene.find(id);
    if (sceneEntity != null && sceneEntity.visible != visible) {
      scene.upsert(sceneEntity.copyWith(visible: visible));
    }
    final before = _requireDocument();
    try {
      // Visibility is a display-state delta. Do not route it through the
      // general projection synchronizer: that path may republish/tessellate a
      // native shape even though no geometry changed.
      _undo.add(before);
      _redo.clear();
      _document = before.mutate(
        command: 'display.visibility',
        upsert: [
          CadDocumentEntity(
            id: entity.id,
            kind: entity.kind,
            shape: entity.shape,
            mesh: entity.mesh,
            data: {...entity.data, 'sceneVisible': visible},
          ),
        ],
      );
      await save();
      notifyListeners();
    } catch (_) {
      _document = before;
      if (_undo.isNotEmpty && identical(_undo.last, before)) _undo.removeLast();
      if (sceneEntity != null) scene.upsert(sceneEntity);
      rethrow;
    }
  }

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
          entity.data['collectionId'] != null) {
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
  }) async {
    final document = _requireDocument();
    final collection = document.entities[id];
    if (collection?.kind != CadDocumentEntityKind.collection) {
      throw StateError('Unknown Collection: $id');
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
    if (visible != null && name == null && locked == null && active == null) {
      final before = _requireDocument();
      _undo.add(before);
      _redo.clear();
      try {
        _document = before.mutate(
          command: 'collection.visibility',
          upsert: updates,
        );
        for (final update in updates.skip(1)) {
          final visual = scene.find(update.id);
          if (visual != null && visual.visible != visible) {
            scene.upsert(visual.copyWith(visible: visible));
          }
        }
        await save();
        notifyListeners();
      } catch (_) {
        _document = before;
        if (_undo.isNotEmpty && identical(_undo.last, before)) {
          _undo.removeLast();
        }
        for (final update in updates.skip(1)) {
          final visual = scene.find(update.id);
          if (visual != null && visual.visible == visible) {
            scene.upsert(visual.copyWith(visible: !visible));
          }
        }
        rethrow;
      }
      return;
    }
    await mutate(command: 'collection.update', upsert: updates);
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
    final impacted = <String>{};
    var changed = true;
    while (changed) {
      changed = false;
      final sources = {entityId, ...impacted};
      for (final entity in document.entities.values) {
        if (entity.id == entityId || impacted.contains(entity.id)) continue;
        if (sources.any((source) => _containsReference(entity.data, source))) {
          changed = impacted.add(entity.id) || changed;
        }
      }
    }
    return impacted.map((id) => document.entities[id]!).toList();
  }

  bool _containsReference(Object? value, String id) {
    if (value == id) return true;
    if (value is Map) {
      return value.values.any((item) => _containsReference(item, id));
    }
    if (value is Iterable) {
      return value.any((item) => _containsReference(item, id));
    }
    return false;
  }

  Future<void> moveToRecycleBin(
    String entityId, {
    required bool includeDependencies,
  }) async {
    final document = _requireDocument();
    final target =
        document.entities[entityId] ??
        (throw StateError('Unknown document entity: $entityId'));
    if (WorldCoordinateSystem.isProtected(target)) {
      throw StateError('World Coordinate System entities cannot be deleted.');
    }
    final entities = <CadDocumentEntity>[
      target,
      if (includeDependencies) ...dependencyImpact(entityId),
    ];
    await mutate(
      command: 'recycle.delete',
      upsert: [
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
  }

  Future<void> restoreFromRecycleBin(String entityId) async {
    final entity =
        _requireDocument().entities[entityId] ??
        (throw StateError('Unknown document entity: $entityId'));
    if (entity.data['deleted'] != true) {
      throw StateError('${entity.data['name'] ?? entity.id} is not deleted.');
    }
    final data = Map<String, dynamic>.from(entity.data)
      ..remove('deleted')
      ..remove('deletedAt');
    data['collectionId'] =
        data.remove('previousCollectionId') ?? 'collection:original';
    data['sceneVisible'] = true;
    await mutate(
      command: 'recycle.restore',
      upsert: [
        CadDocumentEntity(
          id: entity.id,
          kind: entity.kind,
          shape: entity.shape,
          mesh: entity.mesh,
          data: data,
        ),
      ],
    );
  }

  Future<void> permanentlyDelete(String entityId) async {
    final entity =
        _requireDocument().entities[entityId] ??
        (throw StateError('Unknown document entity: $entityId'));
    if (entity.data['deleted'] != true) {
      throw StateError('Only Recycle Bin entities can be permanently deleted.');
    }
    await removeEntity(entityId, command: 'recycle.purge');
  }

  Future<void> undoDocument() async {
    if (_undo.isEmpty) return;
    final current = _requireDocument();
    _redo.add(current);
    _document = FeatureLifecycleProjector.normalize(
      _undo.removeLast(),
      command: 'document.undo.lifecycle-restore',
    );
    _restoreActiveImport();
    await projection.synchronize(_document!, displayMeshes: _displayMeshes);
    await save();
    notifyListeners();
  }

  Future<void> redoDocument() async {
    if (_redo.isEmpty) return;
    final current = _requireDocument();
    _undo.add(current);
    _document = FeatureLifecycleProjector.normalize(
      _redo.removeLast(),
      command: 'document.redo.lifecycle-restore',
    );
    _restoreActiveImport();
    await projection.synchronize(_document!, displayMeshes: _displayMeshes);
    await save();
    notifyListeners();
  }

  Future<void> save({bool recordLifecycle = false}) async {
    var document = _document;
    final directory = _projectDirectory;
    if (document != null && directory != null) {
      if (recordLifecycle) {
        final featureIds = document.entities.values
            .where(FeatureLifecycleContract.appliesTo)
            .map((entity) => entity.id)
            .toSet();
        document = FeatureLifecycleProjector.normalize(
          document,
          command: 'project.save',
          previousDocument: document,
          touchedIds: featureIds,
          actionOverrides: {for (final id in featureIds) id: 'saved'},
        );
        _document = document;
      }
      await _repository.save(document, directory);
      await _repository.saveHistory(directory, undo: _undo, redo: _redo);
    }
  }

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
    return jsonEncode(json);
  }

  void _restoreActiveImport() {
    _activeImport = null;
    _activeMeshGeometry = null;
    final imports = _document!.entities.values
        .where((entity) => entity.kind == CadDocumentEntityKind.import)
        .toList();
    if (imports.isEmpty) return;
    final value = imports.last, data = value.data;
    _activeImport = ImportedCadDocument(
      id: value.id,
      projectId: _document!.projectId,
      sourcePath: data['sourcePath'] as String,
      registeredPath: data['registeredPath'] as String,
      format: CadImportFormat.values.byName(data['format'] as String),
      validation: (data['validation'] as List? ?? const []).cast<String>(),
      shape: value.shape,
      mesh: value.mesh,
    );
    final sceneGeometry = data['sceneGeometry'];
    if (sceneGeometry is Map && sceneGeometry['nodes'] is List) {
      _activeMeshGeometry = KernelMeshGeometry(
        nodes: (sceneGeometry['nodes'] as List)
            .cast<num>()
            .map((value) => value.toDouble())
            .toList(),
        triangles: (sceneGeometry['triangles'] as List).cast<int>(),
      );
    }
  }

  @override
  void dispose() {
    operationalSelection.dispose();
    operationalEntities.dispose();
    geometrySelection.dispose();
    scene.dispose();
    super.dispose();
  }
}
