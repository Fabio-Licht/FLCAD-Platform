import 'cad_asset_fs_native.dart';
import 'cad_step_diagnostics.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Color, RootIsolateToken;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../core/cad_document/cad_document.dart';
import '../../core/cad_document/entity_placement.dart';
import '../../core/cad_document/managed_step_contract.dart';
import '../../core/cad_document/managed_cad_identity.dart';
import '../../core/cad_document/managed_cad_reference.dart';
import '../../core/cad_document/plane_axis_intersection_point.dart';
import '../../core/cad_document/alignment_coordinate_system.dart';
import '../../core/cad_document/dependency_walk.dart';
import '../../core/cad_document/cad_document_repository.dart';
import '../cad_viewport/rendering/cad_selection_palette.dart';
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
import '../cad_viewport/rendering/stl_display_lod.dart';
import '../engineering_bridge/selection/geometry_selection_manager.dart';
import '../operational_entities/operational_entity.dart';
import '../operational_entities/operational_entity_resolver.dart';
import 'world_coordinate_system.dart';
import 'notification_gate.dart';
import 'managed_placement_projection.dart';

part 'cad_runtime_transactions.dart';
part 'cad_runtime_snapshots.dart';
part 'cad_runtime_integrity.dart';
part 'cad_asset_staging.dart';
part 'cad_asset_storage.dart';

/// Ephemeral viewport request emitted only after a managed import's durable
/// commit and publication confirmation. It is deliberately not document data.
@immutable
final class CadManagedImportPublication {
  const CadManagedImportPublication({
    required this.id,
    required this.session,
    required this.revision,
    required this.bounds,
  });

  final int id, session, revision;
  final KernelBounds bounds;
}

@immutable
final class PlaneAxisIntersectionPreview {
  const PlaneAxisIntersectionPreview({
    required this.point,
    required this.plane,
    required this.axis,
  });

  final Vector3 point;
  final ReferenceParentIdentity plane;
  final ReferenceParentIdentity axis;
}

@immutable
final class AlignmentCoordinateSystemPreview {
  const AlignmentCoordinateSystemPreview({
    required this.origin,
    required this.xAxis,
    required this.yAxis,
    required this.zAxis,
    required this.plane,
    required this.axis,
    required this.originKind,
    this.point,
  });

  final Vector3 origin;
  final Vector3 xAxis;
  final Vector3 yAxis;
  final Vector3 zAxis;
  final ReferenceParentIdentity plane;
  final ReferenceParentIdentity axis;
  final AlignmentCoordinateSystemOriginKind originKind;
  final ReferenceParentIdentity? point;
}

/// Ephemeral result for G105A2.  [placement] maps the managed entity's local
/// coordinates directly into the selected alignment coordinate system.
@immutable
final class ManagedAlignmentPreview {
  const ManagedAlignmentPreview({
    required this.entityId,
    required this.coordinateSystemId,
    required this.placement,
  });

  final String entityId;
  final String coordinateSystemId;
  final EntityPlacement placement;
}

/// In-memory documentary state captured before a command execute.
final class CadRuntimeCommandCheckpoint {
  const CadRuntimeCommandCheckpoint({
    required this.document,
    required this.runtimeRevision,
    required this.undo,
    required this.redo,
    required this.recoveryRequired,
  });

  final CadDocument? document;
  final int runtimeRevision;
  final List<CadDocument> undo;
  final List<CadDocument> redo;
  final bool recoveryRequired;
}

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
    // `selection` is a view over the geometry selection manager, but that
    // manager only notifies its own listeners. Projections (the MM3 panel
    // bridge, and any future one) observe the runtime, so a selection made
    // directly through the manager - Inspector inputs, entity lists, viewport
    // picks - used to leave a detached panel showing a stale selection until
    // some unrelated notification arrived. Forwarding keeps a single
    // notification surface without touching selection semantics.
    geometrySelection.addListener(_forwardSelectionChange);
  }

  /// True when a forwarded selection notification is already queued.
  bool _selectionForwardPending = false;

  /// Forwards geometry-selection changes to the runtime notification surface.
  ///
  /// The forward is coalesced by a microtask and is superseded by any explicit
  /// [notifyListeners] - a document transaction publishes the reconciled
  /// selection itself, and the writers depend on that ordering and on the exact
  /// notification count - so only selection changes that no other path would
  /// publish get an extra notification.
  void _forwardSelectionChange() {
    if (_selectionForwardPending) return;
    _selectionForwardPending = true;
    scheduleMicrotask(() {
      if (!_selectionForwardPending) return;
      _selectionForwardPending = false;
      if (_notifierDisposed || _closingAdmission) return;
      notifyListeners();
    });
  }

  @override
  void notifyListeners() {
    _selectionForwardPending = false;
    super.notifyListeners();
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

  /// Document last written, or the opened document when the file already
  /// matched. In-memory inserts that keep the revision list do not replace
  /// it, so the next commit still detects an external file change.
  CadDocument? _persistedDocumentBaseline;
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

  /// Local display captured before rigid placement. Placement projects this
  /// map and does not tessellate the native owner again.
  final Map<String, Map<String, dynamic>> _managedLocalScene = {};

  // Native producers remain outside this documentary transaction protocol.
  final Object _runtimeIdentity = Object();
  final _snapshots = _CadSnapshots();
  Future<void> _transactionTail = Future<void>.value();
  _CadTransaction? _transaction;
  int _nextTransaction = 0, _runtimeRevision = 0, _lifecycleGeneration = 0;
  int _nextManagedImportPublication = 0;
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
  CadManagedImportPublication? get managedImportPublication =>
      _managedImportPublication;
  CadManagedImportPublication? _managedImportPublication;

  CadDocument? get document => _document;

  /// Snapshot used when a command mutates state and then throws.
  /// Restoring it does not publish a new revision.
  CadRuntimeCommandCheckpoint captureCommandCheckpoint() =>
      CadRuntimeCommandCheckpoint(
        document: _document?.detachedCheckpoint(),
        runtimeRevision: _runtimeRevision,
        undo: [for (final item in _undo) item.detachedCheckpoint()],
        redo: [for (final item in _redo) item.detachedCheckpoint()],
        recoveryRequired: _recoveryRequired,
      );

  void restoreCommandCheckpoint(CadRuntimeCommandCheckpoint checkpoint) {
    _document = checkpoint.document;
    _runtimeRevision = checkpoint.runtimeRevision;
    _undo
      ..clear()
      ..addAll(checkpoint.undo);
    _redo
      ..clear()
      ..addAll(checkpoint.redo);
    _recoveryRequired = checkpoint.recoveryRequired;
  }

  @visibleForTesting
  void debugInstallDocument(CadDocument document) {
    _document = document;
  }

  ImportedCadDocument? get activeImport => _activeImport;
  KernelMeshGeometry? get activeMeshGeometry => _activeMeshGeometry;
  KernelBounds? get workspaceBounds => _workspaceBounds;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  Set<String> get selection => geometrySelection.selectedIds;

  @visibleForTesting
  bool hasManagedGeometry(String entityId) =>
      _managedGeometry.containsKey(entityId);

  @visibleForTesting
  void debugPutEntity(CadDocumentEntity entity) {
    final current = _requireDocument();
    _document = CadDocument(
      projectId: current.projectId,
      entities: Map.unmodifiable({...current.entities, entity.id: entity}),
      revisions: current.revisions,
      parameters: current.parameters,
      officialExportShapeId: current.officialExportShapeId,
    );
  }

  Future<KernelMeshGeometry?> managedMeshGeometryFor(String entityId) async {
    final geometry = _managedGeometry[entityId];
    if (geometry is! ManagedMeshEntityGeometry) return null;
    final kernel = kernels.active;
    if (kernel is! OpenCascadeKernelAdapter) return null;
    return geometry.displayMesh.inspectGeometry(kernel);
  }

  @visibleForTesting
  Map<String, dynamic>? managedGeometryDiagnostics(String entityId) {
    final value = _managedGeometry[entityId];
    if (value == null) return null;
    return {
      if (value is ManagedBrepEntityGeometry)
        'shape': value.shape.descriptor.toManagedMetadata(),
      'displayMesh': value.displayMesh.descriptor.toManagedMetadata(),
      'meshOnly': value.meshOnly,
    };
  }

  /// Returns the world-space analytic data behind a transient presentation
  /// triangle. This is read-only capability discovery: the returned value is
  /// intentionally limited to drawing a transient preview and must never be
  /// persisted with the presentation triangle id.
  Future<Map<String, Object?>?> managedCadFaceAnalyticGeometry({
    required String sourceEntityId,
    required int presentationTriangleId,
  }) async {
    if (presentationTriangleId <= 0) return null;
    Map<String, Object?>? result;
    await _enqueue((tx) async {
      final source = _requireDocument().entities[sourceEntityId];
      final geometry = _managedGeometry[sourceEntityId];
      final kernel = kernels.active;
      final hasManagedBrep =
          source?.data['managedStepAssets'] is Map ||
          source?.data['managedBrepAssets'] is Map;
      if (source == null ||
          source.data['deleted'] == true ||
          !hasManagedBrep ||
          source.data['managedStlAssets'] != null ||
          geometry is! ManagedBrepEntityGeometry ||
          kernel is! OpenCascadeKernelAdapter) {
        return;
      }
      final inspected = await geometry.shape.inspectManagedCadFace(
        kernel,
        presentationTriangleId,
      );
      tx.validate();
      final surfaceType = inspected['surfaceType'];
      if (surfaceType is! String) return;

      Vector3? vector(String key) {
        final raw = inspected[key];
        if (raw is! List ||
            raw.length != 3 ||
            raw.any((value) => value is! num || !value.isFinite)) {
          return null;
        }
        return Vector3(
          (raw[0] as num).toDouble(),
          (raw[1] as num).toDouble(),
          (raw[2] as num).toDouble(),
        );
      }

      final faceIndex = inspected['faceIndex'];
      if (faceIndex is! int || faceIndex <= 0) return;
      if (surfaceType == 'plane') {
        var origin = vector('origin');
        var normal = vector('normal');
        var xDirection = vector('xDirection');
        if (origin == null || normal == null || xDirection == null) return;
        final placement = source.placement;
        if (placement != null && placement.operations.isNotEmpty) {
          final matrix = placement.matrix;
          final transformedZero = matrix.transformPoint(Vector3.zero);
          origin = matrix.transformPoint(origin);
          normal = matrix.transformPoint(normal) - transformedZero;
          xDirection = matrix.transformPoint(xDirection) - transformedZero;
        }
        normal = normal.normalized;
        xDirection = (xDirection - normal * normal.dot(xDirection)).normalized;
        if (normal.length <= 1e-12 || xDirection.length <= 1e-12) return;
        result = {
          'surfaceType': surfaceType,
          'faceIndex': faceIndex,
          'origin': origin.toJson(),
          'normal': normal.toJson(),
          'xDirection': xDirection.toJson(),
        };
        return;
      }
      if (surfaceType == 'cylinder') {
        var origin = vector('origin');
        var direction = vector('direction');
        final radius = inspected['radius'];
        if (origin == null ||
            direction == null ||
            radius is! num ||
            !radius.isFinite ||
            radius <= 0) {
          return;
        }
        final placement = source.placement;
        if (placement != null && placement.operations.isNotEmpty) {
          final matrix = placement.matrix;
          final transformedZero = matrix.transformPoint(Vector3.zero);
          origin = matrix.transformPoint(origin);
          direction = matrix.transformPoint(direction) - transformedZero;
        }
        direction = ManagedCadReference.canonicalAxisDirection(direction);
        if (direction.length <= 1e-12) return;
        result = {
          'surfaceType': surfaceType,
          'faceIndex': faceIndex,
          'origin': origin.toJson(),
          'direction': direction.toJson(),
          'radius': radius.toDouble(),
        };
        return;
      }
      result = {'surfaceType': surfaceType, 'faceIndex': faceIndex};
    });
    return result;
  }

  /// Reads the OCCT surface category behind a transient presentation face.
  /// This is capability discovery only: it creates no document entity and
  /// retains no viewport-local identifier.
  Future<String?> managedCadFaceSurfaceType({
    required String sourceEntityId,
    required int presentationTriangleId,
  }) async =>
      (await managedCadFaceAnalyticGeometry(
            sourceEntityId: sourceEntityId,
            presentationTriangleId: presentationTriangleId,
          ))?['surfaceType']
          as String?;

  /// Resolves a transient presentation triangle to its owning OCCT face and
  /// creates a durable world-space plane reference in one document transaction.
  Future<String> createManagedCadPlaneReference({
    required String sourceEntityId,
    required int presentationTriangleId,
    double visualSize = 60,
  }) async {
    if (presentationTriangleId <= 0 ||
        !visualSize.isFinite ||
        visualSize <= 0) {
      throw const FormatException('Invalid managed CAD face selection');
    }
    late String referenceId;
    await _enqueue((tx) async {
      final document = _requireDocument();
      final source = document.entities[sourceEntityId];
      final rawAssets =
          source?.data['managedStepAssets'] ??
          source?.data['managedBrepAssets'];
      final geometry = _managedGeometry[sourceEntityId];
      final kernel = kernels.active;
      if (source == null ||
          source.data['deleted'] == true ||
          source.kind != CadDocumentEntityKind.import ||
          rawAssets is! Map ||
          source.data['managedStlAssets'] != null ||
          geometry is! ManagedBrepEntityGeometry ||
          kernel is! OpenCascadeKernelAdapter) {
        throw StateError('Selecione uma face de um STEP/BREP managed ativo.');
      }
      final inspected = await geometry.shape.inspectManagedCadFace(
        kernel,
        presentationTriangleId,
      );
      tx.validate();
      if (inspected['surfaceType'] != 'plane') {
        throw StateError('A face selecionada não é planar.');
      }
      Vector3 vector(String key) {
        final raw = inspected[key];
        if (raw is! List ||
            raw.length != 3 ||
            raw.any((value) => value is! num || !value.isFinite)) {
          throw const FormatException('Invalid native face geometry');
        }
        return Vector3(
          (raw[0] as num).toDouble(),
          (raw[1] as num).toDouble(),
          (raw[2] as num).toDouble(),
        );
      }

      var origin = vector('origin');
      var normal = vector('normal').normalized;
      var xDirection = vector('xDirection').normalized;
      final placement = source.placement;
      if (placement != null && placement.operations.isNotEmpty) {
        final matrix = placement.matrix;
        final transformedZero = matrix.transformPoint(Vector3.zero);
        origin = matrix.transformPoint(origin);
        normal = (matrix.transformPoint(normal) - transformedZero).normalized;
        xDirection =
            (matrix.transformPoint(xDirection) - transformedZero).normalized;
      }
      xDirection = (xDirection - normal * normal.dot(xDirection)).normalized;
      final faceIndex = inspected['faceIndex'];
      final shapeSha256 = rawAssets['shapeSha256'];
      if (faceIndex is! int ||
          faceIndex <= 0 ||
          shapeSha256 is! String ||
          normal.length <= 1e-12 ||
          xDirection.length <= 1e-12) {
        throw const FormatException('Invalid managed CAD face result');
      }
      final format = source.data['managedStepAssets'] != null ? 'step' : 'brep';
      final definition = ManagedCadReference.plane(
        sourceEntityId: sourceEntityId,
        sourceFormat: format,
        sourceShapeSha256: shapeSha256,
        faceIndex: faceIndex,
        origin: origin,
        normal: normal,
        xDirection: xDirection,
      );
      final sourceName = source.data['name'] as String? ?? source.id;
      final baseName = 'Plano $sourceName F$faceIndex';
      final names = document.entities.values
          .map((entity) => entity.data['name'])
          .whereType<String>()
          .toSet();
      var name = baseName;
      for (var suffix = 2; names.contains(name); suffix++) {
        name = '$baseName ($suffix)';
      }
      referenceId = 'managed-plane:${DateTime.now().microsecondsSinceEpoch}';
      await _mutateDocument(
        tx,
        command: 'references.managedCad.planeFromFace',
        requested: [
          CadDocumentEntity(
            id: referenceId,
            kind: CadDocumentEntityKind.reference,
            data: {
              'name': name,
              'collectionId': 'collection:references',
              'sceneKind': CadSceneEntityKind.plane.name,
              'sceneGeometry': {
                'origin': origin.toJson(),
                'normal': normal.toJson(),
                'xDirection': xDirection.toJson(),
                'visualSize': visualSize.clamp(1.0, 1000000.0),
                'displayColor': 'constructionPlane',
              },
              'sceneVisible': true,
              'sceneTransparent': true,
              ManagedCadReference.dataKey: definition.toJson(),
            },
          ),
        ],
      );
    });
    geometrySelection.select(referenceId);
    return referenceId;
  }

  /// Resolves the selected presentation triangle to its OCCT face, then
  /// persists only the cylinder's durable topological and analytic identity.
  Future<String> createManagedCadCylinderAxisReference({
    required String sourceEntityId,
    required int presentationTriangleId,
  }) async {
    if (presentationTriangleId <= 0) {
      throw const FormatException('Invalid managed CAD face selection');
    }
    late String referenceId;
    await _enqueue((tx) async {
      final document = _requireDocument();
      final source = document.entities[sourceEntityId];
      final rawAssets =
          source?.data['managedStepAssets'] ??
          source?.data['managedBrepAssets'];
      final geometry = _managedGeometry[sourceEntityId];
      final kernel = kernels.active;
      if (source == null ||
          source.data['deleted'] == true ||
          source.kind != CadDocumentEntityKind.import ||
          rawAssets is! Map ||
          source.data['managedStlAssets'] != null ||
          geometry is! ManagedBrepEntityGeometry ||
          kernel is! OpenCascadeKernelAdapter) {
        throw StateError('Selecione uma face de um STEP/BREP managed ativo.');
      }
      final inspected = await geometry.shape.inspectManagedCadFace(
        kernel,
        presentationTriangleId,
      );
      tx.validate();
      final surfaceType = inspected['surfaceType'];
      if (surfaceType != 'cylinder') {
        const labels = {
          'plane': 'plana',
          'cone': 'cônica',
          'sphere': 'esférica',
          'torus': 'toroidal',
          'unsupported': 'não cilíndrica',
        };
        throw StateError(
          'A face selecionada não é cilíndrica '
          '(tipo OCCT: ${labels[surfaceType] ?? surfaceType ?? 'desconhecido'}).',
        );
      }
      Vector3 vector(String key) {
        final raw = inspected[key];
        if (raw is! List ||
            raw.length != 3 ||
            raw.any((value) => value is! num || !value.isFinite)) {
          throw const FormatException('Invalid native cylinder geometry');
        }
        return Vector3(
          (raw[0] as num).toDouble(),
          (raw[1] as num).toDouble(),
          (raw[2] as num).toDouble(),
        );
      }

      var origin = vector('origin');
      var direction = vector('direction');
      final rawRadius = inspected['radius'];
      final placement = source.placement;
      if (placement != null && placement.operations.isNotEmpty) {
        final matrix = placement.matrix;
        final transformedZero = matrix.transformPoint(Vector3.zero);
        origin = matrix.transformPoint(origin);
        direction = matrix.transformPoint(direction) - transformedZero;
      }
      direction = ManagedCadReference.canonicalAxisDirection(direction);
      final faceIndex = inspected['faceIndex'];
      final shapeSha256 = rawAssets['shapeSha256'];
      if (faceIndex is! int ||
          faceIndex <= 0 ||
          shapeSha256 is! String ||
          rawRadius is! num ||
          !rawRadius.isFinite ||
          rawRadius <= 0) {
        throw const FormatException('Invalid managed CAD cylinder result');
      }
      final radius = rawRadius.toDouble();
      final format = source.data['managedStepAssets'] != null ? 'step' : 'brep';
      final definition = ManagedCadReference.cylindricalAxis(
        sourceEntityId: sourceEntityId,
        sourceFormat: format,
        sourceShapeSha256: shapeSha256,
        faceIndex: faceIndex,
        origin: origin,
        direction: direction,
        radius: radius,
      );
      final sourceName = source.data['name'] as String? ?? source.id;
      final baseName = 'Eixo $sourceName F$faceIndex';
      final names = document.entities.values
          .map((entity) => entity.data['name'])
          .whereType<String>()
          .toSet();
      var name = baseName;
      for (var suffix = 2; names.contains(name); suffix++) {
        name = '$baseName ($suffix)';
      }
      referenceId = 'managed-axis:${DateTime.now().microsecondsSinceEpoch}';
      await _mutateDocument(
        tx,
        command: 'references.managedCad.axisFromCylindricalFace',
        requested: [
          CadDocumentEntity(
            id: referenceId,
            kind: CadDocumentEntityKind.reference,
            data: {
              'name': name,
              'collectionId': 'collection:references',
              'sceneKind': CadSceneEntityKind.axis.name,
              'sceneGeometry': {
                'origin': origin.toJson(),
                'direction': direction.toJson(),
                'displayColor': 'constructionVector',
              },
              'sceneVisible': true,
              'sceneTransparent': true,
              ManagedCadReference.dataKey: definition.toJson(),
            },
          ),
        ],
      );
    });
    geometrySelection.select(referenceId);
    return referenceId;
  }

  bool managedCadReferenceIsOrphaned(ManagedCadReference reference) {
    final source = _document?.entities[reference.sourceEntityId];
    if (source == null || source.data['deleted'] == true) return true;
    final assets =
        source.data['managedStepAssets'] ?? source.data['managedBrepAssets'];
    return assets is! Map ||
        assets['shapeSha256'] != reference.sourceShapeSha256;
  }

  List<CadDocumentEntity> planeIntersectionCandidates() =>
      _referenceCandidates('plane');

  List<CadDocumentEntity> axisIntersectionCandidates() =>
      _referenceCandidates('axis');

  List<CadDocumentEntity> pointReferenceCandidates() =>
      _pointReferenceCandidates();

  /// Systems that can be selected as G105A2 destinations.  Orphan status is
  /// checked again when previewing/applying so a stale UI list cannot apply a
  /// transform to an invalid frame.
  List<CadDocumentEntity> alignmentCoordinateSystemCandidates() {
    final document = _document;
    if (document == null) return const [];
    return document.entities.values
        .where((entity) {
          final raw = entity.data[AlignmentCoordinateSystem.dataKey];
          if (raw is! Map || entity.data['deleted'] == true) return false;
          try {
            final system = AlignmentCoordinateSystem.fromJson(
              Map<String, dynamic>.from(raw),
            );
            return !alignmentCoordinateSystemIsOrphaned(system);
          } catch (_) {
            return false;
          }
        })
        .toList(growable: false);
  }

  Future<ManagedAlignmentPreview> previewManagedAlignment({
    required String entityId,
    required String coordinateSystemId,
  }) async {
    late ManagedAlignmentPreview result;
    await _enqueue((tx) async {
      final document = _requireDocument();
      final entity = _managedAlignmentEntity(document, entityId);
      final placement = _alignmentPlacement(document, coordinateSystemId);
      final current =
          entity.placement ?? EntityPlacement.identity(const [0, 0, 0]);
      final delta = placement.matrix * current.matrix.inverse();
      EntityPlacement.validateRigidMatrix(delta);
      final sourceScene = scene.find(entityId);
      if (sourceScene == null) {
        throw StateError(
          'A apresentação da entidade selecionada não está disponível.',
        );
      }
      projection.upsertTransient(
        CadSceneEntity(
          id: 'alignment-wcs-preview-$entityId',
          kind: CadSceneEntityKind.preview,
          transparent: true,
          geometry: {
            ...projectManagedPlacement(
              sourceScene.geometry,
              EntityPlacement.fromRigidMatrix(delta),
            ),
            'displayColor': 'previewOrange',
          },
        ),
      );
      _state['alignment.wcsPreviewEntityId'] = entityId;
      result = ManagedAlignmentPreview(
        entityId: entityId,
        coordinateSystemId: coordinateSystemId,
        placement: placement,
      );
      tx.validate();
    });
    return result;
  }

  void clearManagedAlignmentPreview([String? entityId]) {
    final id = entityId ?? _state['alignment.wcsPreviewEntityId'];
    if (id is String) projection.removeTransient('alignment-wcs-preview-$id');
    _state.remove('alignment.wcsPreviewEntityId');
  }

  /// Applies one G105A2 placement transaction.  Assets remain shared CAF
  /// assets; a Working Copy receives its own document identity and records its
  /// immutable provenance in [alignmentByCoordinateSystem].
  Future<String> applyManagedAlignment({
    required String entityId,
    required String coordinateSystemId,
    required bool createWorkingCopy,
  }) async {
    late String outputId;
    await _enqueue((tx) async {
      final document = _requireDocument();
      final entity = _managedAlignmentEntity(document, entityId);
      final placement = _alignmentPlacement(document, coordinateSystemId);
      final system = document.entities[coordinateSystemId]!;
      final data = <String, dynamic>{...entity.data};
      final suffix = createWorkingCopy ? ' (Working Copy)' : '';
      outputId = createWorkingCopy
          ? _nextManagedAlignmentCopyId(document, entity.id)
          : entity.id;
      data['name'] = '${entity.data['name'] ?? entity.id}$suffix';
      data['collectionId'] = createWorkingCopy
          ? 'collection:working-copy'
          : 'collection:modified';
      data['alignmentByCoordinateSystem'] = {
        'schema': 'flcad.alignment-by-coordinate-system',
        'version': 1,
        'coordinateSystemId': coordinateSystemId,
        'sourceEntityId': entity.id,
        'mode': createWorkingCopy ? 'workingCopy' : 'original',
        'rotation': [
          placement.matrix.values[0],
          placement.matrix.values[1],
          placement.matrix.values[2],
          placement.matrix.values[4],
          placement.matrix.values[5],
          placement.matrix.values[6],
          placement.matrix.values[8],
          placement.matrix.values[9],
          placement.matrix.values[10],
        ],
        'translation': [
          placement.matrix.values[3],
          placement.matrix.values[7],
          placement.matrix.values[11],
        ],
      };
      await _mutateDocument(
        tx,
        command: createWorkingCopy
            ? 'placement.alignmentCoordinateSystem.copy'
            : 'placement.alignmentCoordinateSystem',
        requested: [
          CadDocumentEntity(
            id: outputId,
            kind: entity.kind,
            data: data,
            placement: placement,
          ),
        ],
      );
      // Keep the system in scope only through its durable ID; its full frame
      // is already encoded by placement. This also catches a deleted WCS before
      // the document mutation is published.
      if (system.data['deleted'] == true) {
        throw StateError('O sistema de coordenadas de destino foi removido.');
      }
    });
    clearManagedAlignmentPreview(entityId);
    geometrySelection.select(outputId);
    return outputId;
  }

  Future<AlignmentCoordinateSystemPreview> previewAlignmentCoordinateSystem({
    required String planeEntityId,
    required String axisEntityId,
    String? pointEntityId,
    Vector3? manualOrigin,
    AlignmentCoordinateSystemOriginKind originKind =
        AlignmentCoordinateSystemOriginKind.referencePoint,
  }) async {
    late AlignmentCoordinateSystemPreview result;
    await _enqueue((tx) async {
      result = _resolveAlignmentCoordinateSystem(
        _requireDocument(),
        planeEntityId,
        axisEntityId,
        pointEntityId,
        manualOrigin,
        originKind,
      );
      tx.validate();
    });
    return result;
  }

  Future<String> createAlignmentCoordinateSystemReference({
    required String planeEntityId,
    required String axisEntityId,
    String? pointEntityId,
    Vector3? manualOrigin,
    AlignmentCoordinateSystemOriginKind originKind =
        AlignmentCoordinateSystemOriginKind.referencePoint,
  }) async {
    late String referenceId;
    await _enqueue((tx) async {
      final document = _requireDocument();
      final result = _resolveAlignmentCoordinateSystem(
        document,
        planeEntityId,
        axisEntityId,
        pointEntityId,
        manualOrigin,
        originKind,
      );
      final definition = AlignmentCoordinateSystem(
        origin: result.origin,
        xAxis: result.xAxis,
        yAxis: result.yAxis,
        zAxis: result.zAxis,
        plane: result.plane,
        axis: result.axis,
        originKind: result.originKind,
        point: result.point,
      );
      const baseName = 'Sistema de Coordenadas de Alinhamento';
      final names = document.entities.values
          .map((entity) => entity.data['name'])
          .whereType<String>()
          .toSet();
      var name = baseName;
      for (var suffix = 2; names.contains(name); suffix++) {
        name = '$baseName ($suffix)';
      }
      referenceId =
          'alignment-coordinate-system:${DateTime.now().microsecondsSinceEpoch}';
      await _mutateDocument(
        tx,
        command: 'references.coordinateSystem.alignment',
        requested: [
          CadDocumentEntity(
            id: referenceId,
            kind: CadDocumentEntityKind.reference,
            data: {
              'name': name,
              'collectionId': 'collection:references',
              'sceneKind': CadSceneEntityKind.coordinateSystem.name,
              'sceneGeometry': {
                'type': 'coordinateSystem',
                'origin': result.origin.toJson(),
                'xAxis': result.xAxis.toJson(),
                'yAxis': result.yAxis.toJson(),
                'zAxis': result.zAxis.toJson(),
                'visualLength': 30.0,
              },
              'sceneVisible': true,
              'sceneTransparent': true,
              'sourceEntityIds': [planeEntityId, axisEntityId, ?pointEntityId],
              AlignmentCoordinateSystem.dataKey: definition.toJson(),
            },
          ),
        ],
      );
    });
    geometrySelection.select(referenceId);
    return referenceId;
  }

  bool alignmentCoordinateSystemIsOrphaned(
    AlignmentCoordinateSystem reference,
  ) {
    final document = _document;
    if (document == null) return true;
    try {
      final plane = _referenceGeometry(
        document.entities[reference.plane.entityId],
        'plane',
      );
      final axis = _referenceGeometry(
        document.entities[reference.axis.entityId],
        'axis',
      );
      final point = reference.point == null
          ? null
          : _referencePoint(document.entities[reference.point!.entityId]);
      return plane.identity != reference.plane.identitySha256 ||
          axis.identity != reference.axis.identitySha256 ||
          (point != null && point.identity != reference.point!.identitySha256);
    } catch (_) {
      return true;
    }
  }

  Future<PlaneAxisIntersectionPreview> previewPlaneAxisIntersectionPoint({
    required String planeEntityId,
    required String axisEntityId,
  }) async {
    late PlaneAxisIntersectionPreview result;
    await _enqueue((tx) async {
      result = _resolvePlaneAxisIntersection(
        _requireDocument(),
        planeEntityId,
        axisEntityId,
      );
      tx.validate();
    });
    return result;
  }

  Future<String> createPlaneAxisIntersectionPointReference({
    required String planeEntityId,
    required String axisEntityId,
  }) async {
    late String referenceId;
    await _enqueue((tx) async {
      final document = _requireDocument();
      final result = _resolvePlaneAxisIntersection(
        document,
        planeEntityId,
        axisEntityId,
      );
      final definition = PlaneAxisIntersectionPoint(
        point: result.point,
        plane: result.plane,
        axis: result.axis,
      );
      const baseName = 'Ponto Plano + Eixo';
      final names = document.entities.values
          .map((entity) => entity.data['name'])
          .whereType<String>()
          .toSet();
      var name = baseName;
      for (var suffix = 2; names.contains(name); suffix++) {
        name = '$baseName ($suffix)';
      }
      referenceId = 'plane-axis-point:${DateTime.now().microsecondsSinceEpoch}';
      await _mutateDocument(
        tx,
        command: 'references.point.planeAxisIntersection',
        requested: [
          CadDocumentEntity(
            id: referenceId,
            kind: CadDocumentEntityKind.reference,
            data: {
              'name': name,
              'collectionId': 'collection:references',
              'sceneKind': CadSceneEntityKind.point.name,
              'sceneGeometry': {
                'type': 'point',
                'position': result.point.toJson(),
                'markerRadius': 5.0,
                'displayColor': 'constructionPoint',
              },
              'sceneVisible': true,
              'sourceEntityIds': [planeEntityId, axisEntityId],
              PlaneAxisIntersectionPoint.dataKey: definition.toJson(),
            },
          ),
        ],
      );
    });
    geometrySelection.select(referenceId);
    return referenceId;
  }

  bool planeAxisIntersectionPointIsOrphaned(
    PlaneAxisIntersectionPoint reference,
  ) {
    final document = _document;
    if (document == null) return true;
    try {
      final plane = _referenceGeometry(
        document.entities[reference.plane.entityId],
        'plane',
      );
      final axis = _referenceGeometry(
        document.entities[reference.axis.entityId],
        'axis',
      );
      return plane.identity != reference.plane.identitySha256 ||
          axis.identity != reference.axis.identitySha256;
    } catch (_) {
      return true;
    }
  }

  List<CadDocumentEntity> _referenceCandidates(String sceneKind) {
    final document = _document;
    if (document == null) return const [];
    return document.entities.values
        .where((entity) {
          try {
            _referenceGeometry(entity, sceneKind);
            return true;
          } catch (_) {
            return false;
          }
        })
        .toList(growable: false);
  }

  List<CadDocumentEntity> _pointReferenceCandidates() {
    final document = _document;
    if (document == null) return const [];
    return document.entities.values
        .where((entity) {
          try {
            _referencePoint(entity);
            return true;
          } catch (_) {
            return false;
          }
        })
        .toList(growable: false);
  }

  AlignmentCoordinateSystemPreview _resolveAlignmentCoordinateSystem(
    CadDocument document,
    String planeEntityId,
    String axisEntityId,
    String? pointEntityId,
    Vector3? manualOrigin,
    AlignmentCoordinateSystemOriginKind originKind,
  ) {
    final plane = _referenceGeometry(document.entities[planeEntityId], 'plane');
    final axis = _referenceGeometry(document.entities[axisEntityId], 'axis');
    if (originKind == AlignmentCoordinateSystemOriginKind.referencePoint &&
        pointEntityId == null) {
      throw StateError('Selecione um ponto de origem válido.');
    }
    if (originKind != AlignmentCoordinateSystemOriginKind.referencePoint &&
        manualOrigin == null) {
      throw StateError('Informe coordenadas de origem válidas.');
    }
    final point =
        originKind == AlignmentCoordinateSystemOriginKind.referencePoint
        ? _referencePoint(document.entities[pointEntityId!])
        : null;
    final origin = point?.position ?? manualOrigin!;
    final zAxis = plane.direction;
    final projectedY = axis.direction - zAxis * zAxis.dot(axis.direction);
    if (projectedY.length <=
        AlignmentCoordinateSystem.angularToleranceDefault) {
      throw StateError(
        'O eixo/vetor é paralelo à normal do plano; não define Y no plano.',
      );
    }
    // Right-handed convention: X = Y × Z, then Y = Z × X. Therefore
    // X × Y = Z while the supplied axis direction remains the Y orientation.
    final suppliedY = projectedY.normalized;
    final xAxis = suppliedY.cross(zAxis).normalized;
    final yAxis = zAxis.cross(xAxis).normalized;
    if ([
      xAxis.x,
      xAxis.y,
      xAxis.z,
      yAxis.x,
      yAxis.y,
      yAxis.z,
      zAxis.x,
      zAxis.y,
      zAxis.z,
      origin.x,
      origin.y,
      origin.z,
    ].any((value) => !value.isFinite)) {
      throw const FormatException('O sistema de coordenadas não é finito.');
    }
    return AlignmentCoordinateSystemPreview(
      origin: origin,
      xAxis: xAxis,
      yAxis: yAxis,
      zAxis: zAxis,
      plane: ReferenceParentIdentity(
        entityId: planeEntityId,
        identitySha256: plane.identity,
      ),
      axis: ReferenceParentIdentity(
        entityId: axisEntityId,
        identitySha256: axis.identity,
      ),
      originKind: originKind,
      point: point == null
          ? null
          : ReferenceParentIdentity(
              entityId: pointEntityId!,
              identitySha256: point.identity,
            ),
    );
  }

  CadDocumentEntity _managedAlignmentEntity(CadDocument document, String id) {
    final entity = document.entities[id];
    final isManaged =
        entity?.data['managedStepAssets'] is Map ||
        entity?.data['managedBrepAssets'] is Map ||
        entity?.data['managedStlAssets'] is Map;
    if (entity == null || entity.data['deleted'] == true || !isManaged) {
      throw StateError(
        'Selecione uma entidade managed STEP, BREP ou STL ativa.',
      );
    }
    final collection = document.entities[entity.data['collectionId']];
    if (collection?.data['locked'] == true) {
      throw StateError('A coleção da entidade está bloqueada.');
    }
    return entity;
  }

  EntityPlacement _alignmentPlacement(
    CadDocument document,
    String coordinateSystemId,
  ) {
    final entity = document.entities[coordinateSystemId];
    final raw = entity?.data[AlignmentCoordinateSystem.dataKey];
    if (entity == null || entity.data['deleted'] == true || raw is! Map) {
      throw StateError(
        'Selecione um Sistema de Coordenadas de Alinhamento válido.',
      );
    }
    final system = AlignmentCoordinateSystem.fromJson(
      Map<String, dynamic>.from(raw),
    );
    if (alignmentCoordinateSystemIsOrphaned(system)) {
      throw StateError('O Sistema de Coordenadas de Alinhamento está órfão.');
    }
    // G105A2 convention: the selected entity's local origin maps to WCS
    // origin and its local X/Y/Z basis maps to the WCS X/Y/Z basis. Matrix
    // columns are the destination frame directions; no scale is introduced.
    final x = system.xAxis,
        y = system.yAxis,
        z = system.zAxis,
        o = system.origin;
    return EntityPlacement.fromRigidMatrix(
      Matrix4([
        x.x,
        y.x,
        z.x,
        o.x,
        x.y,
        y.y,
        z.y,
        o.y,
        x.z,
        y.z,
        z.z,
        o.z,
        0,
        0,
        0,
        1,
      ]),
    );
  }

  String _nextManagedAlignmentCopyId(CadDocument document, String sourceId) {
    var suffix = 1;
    var id = 'working-copy:$sourceId:$suffix';
    while (document.entities.containsKey(id)) {
      id = 'working-copy:$sourceId:${++suffix}';
    }
    return id;
  }

  PlaneAxisIntersectionPreview _resolvePlaneAxisIntersection(
    CadDocument document,
    String planeEntityId,
    String axisEntityId,
  ) {
    final plane = _referenceGeometry(document.entities[planeEntityId], 'plane');
    final axis = _referenceGeometry(document.entities[axisEntityId], 'axis');
    final normal = plane.direction;
    final direction = axis.direction;
    final denominator = normal.dot(direction);
    final signedDistance = normal.dot(plane.origin - axis.origin);
    if (denominator.abs() <=
        PlaneAxisIntersectionPoint.angularToleranceDefault) {
      if (signedDistance.abs() <=
          PlaneAxisIntersectionPoint.linearToleranceDefault) {
        throw StateError(
          'O eixo está contido no plano; a interseção não é única.',
        );
      }
      throw StateError('O eixo é paralelo ao plano; não há interseção única.');
    }
    final parameter = signedDistance / denominator;
    final point = axis.origin + direction * parameter;
    if (![
      point.x,
      point.y,
      point.z,
      parameter,
    ].every((value) => value.isFinite)) {
      throw const FormatException('A interseção Plano + Eixo não é finita.');
    }
    return PlaneAxisIntersectionPreview(
      point: point,
      plane: ReferenceParentIdentity(
        entityId: planeEntityId,
        identitySha256: plane.identity,
      ),
      axis: ReferenceParentIdentity(
        entityId: axisEntityId,
        identitySha256: axis.identity,
      ),
    );
  }

  ({Vector3 origin, Vector3 direction, String identity}) _referenceGeometry(
    CadDocumentEntity? entity,
    String sceneKind,
  ) {
    if (entity == null ||
        entity.data['deleted'] == true ||
        entity.kind != CadDocumentEntityKind.reference ||
        entity.data['sceneKind'] != sceneKind ||
        (entity.data['systemProtected'] != true &&
            entity.data['collectionId'] != 'collection:references')) {
      throw StateError('Referência $sceneKind inválida ou removida.');
    }
    final managed = entity.data[ManagedCadReference.dataKey];
    if (managed is Map &&
        managedCadReferenceIsOrphaned(
          ManagedCadReference.fromJson(Map<String, dynamic>.from(managed)),
        )) {
      throw StateError('Referência $sceneKind órfã ou inválida.');
    }
    final geometry = entity.data['sceneGeometry'];
    if (geometry is! Map) {
      throw StateError('Referência $sceneKind sem geometria válida.');
    }
    Vector3 vector(String key) {
      final raw = geometry[key];
      if (raw is! List ||
          raw.length != 3 ||
          raw.any((value) => value is! num || !value.isFinite)) {
        throw StateError('Referência $sceneKind sem geometria finita.');
      }
      return Vector3(
        (raw[0] as num).toDouble(),
        (raw[1] as num).toDouble(),
        (raw[2] as num).toDouble(),
      );
    }

    final origin = vector('origin');
    final direction = vector(sceneKind == 'plane' ? 'normal' : 'direction');
    if (direction.length <= 1e-12) {
      throw StateError('Referência $sceneKind com direção degenerada.');
    }
    final normalized = direction.normalized;
    final identityPayload = {
      'entityId': entity.id,
      'sceneKind': sceneKind,
      'origin': origin.toJson(),
      sceneKind == 'plane' ? 'normal' : 'direction': normalized.toJson(),
      if (entity.data['systemProtected'] == true) 'systemProtected': true,
      if (entity.data[ManagedCadReference.dataKey] case final Map managed)
        ManagedCadReference.dataKey: managed,
      if (entity.data['constructionEntity'] case final Map construction)
        'constructionEntity': construction,
    };
    final identity = sha256
        .convert(utf8.encode(jsonEncode(_orderedJson(identityPayload))))
        .toString();
    return (origin: origin, direction: normalized, identity: identity);
  }

  ({Vector3 position, String identity}) _referencePoint(
    CadDocumentEntity? entity,
  ) {
    if (entity == null ||
        entity.data['deleted'] == true ||
        (entity.kind != CadDocumentEntityKind.reference &&
            entity.kind != CadDocumentEntityKind.vertex) ||
        entity.data['sceneKind'] != CadSceneEntityKind.point.name ||
        (entity.data['systemProtected'] != true &&
            entity.data['collectionId'] != 'collection:references')) {
      throw StateError('Referência ponto inválida ou removida.');
    }
    final intersection = entity.data[PlaneAxisIntersectionPoint.dataKey];
    if (intersection is Map &&
        planeAxisIntersectionPointIsOrphaned(
          PlaneAxisIntersectionPoint.fromJson(
            Map<String, dynamic>.from(intersection),
          ),
        )) {
      throw StateError('Referência ponto órfã ou inválida.');
    }
    final geometry = entity.data['sceneGeometry'];
    final rawPosition = geometry is Map ? geometry['position'] : null;
    if (rawPosition is! List ||
        rawPosition.length != 3 ||
        rawPosition.any((value) => value is! num || !value.isFinite)) {
      throw StateError('Referência ponto sem geometria finita.');
    }
    final position = Vector3(
      (rawPosition[0] as num).toDouble(),
      (rawPosition[1] as num).toDouble(),
      (rawPosition[2] as num).toDouble(),
    );
    final identityPayload = {
      'entityId': entity.id,
      'sceneKind': CadSceneEntityKind.point.name,
      'position': position.toJson(),
      if (entity.data['systemProtected'] == true) 'systemProtected': true,
      if (intersection is Map) PlaneAxisIntersectionPoint.dataKey: intersection,
      if (entity.data['constructionEntity'] case final Map construction)
        'constructionEntity': construction,
    };
    final identity = sha256
        .convert(utf8.encode(jsonEncode(_orderedJson(identityPayload))))
        .toString();
    return (position: position, identity: identity);
  }

  /// Managed imports install this only after their documentary commit. It is
  /// process-local and therefore deliberately has no document representation.
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
    _managedLocalScene.remove(entityId);
    if (value != null) await value.dispose();
  }

  void attachCommands(CommandManager value) {
    final current = _commands;
    if (current != null && !identical(current, value)) {
      throw StateError('CadRuntime already owns a CommandManager.');
    }
    _commands = value;
  }

  Future<void> undoCommand({String? operationId}) async {
    final commands = _commands;
    if (commands != null &&
        (commands.canUndo || commands.hasPendingOperations)) {
      await commands.undo(operationId);
    } else if (canUndo) {
      await undoDocument();
    } else {
      throw StateError('There is no command to undo.');
    }
  }

  Future<void> redoCommand({String? operationId}) async {
    final commands = _commands;
    if (commands != null &&
        (commands.canRedo || commands.hasPendingOperations)) {
      await commands.redo(operationId);
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

  Future<void> open(
    String projectId,
    Directory directory, {
    CadAssetCancellation? cancellation,
  }) {
    if (_closingAdmission) return Future.error(const CadRuntimeShuttingDown());
    if (_callingTransaction != null) {
      return Future.error(StateError('Reentrant runtime transaction.'));
    }
    if (cancellation?.isCancelled == true) {
      return Future.error(const CadAssetCancelled());
    }
    _transaction?.requestRevocation();
    final generation = ++_lifecycleGeneration;
    return _enqueue((tx) async {
      if (cancellation?.isCancelled == true) throw const CadAssetCancelled();
      if (cancellation != null) {
        unawaited(
          Future.any<void>([
            cancellation._done.future,
            tx.revocation.future,
          ]).then((_) {
            if (cancellation.isCancelled && !tx.committed) {
              tx.requestRevocation();
            }
          }),
        );
      }
      await _openInTransaction(tx, projectId, directory);
    }, lifecycle: generation);
  }

  Future<void> close() {
    if (_closingAdmission) return Future.error(const CadRuntimeShuttingDown());
    if (_callingTransaction != null) {
      return Future.error(StateError('Reentrant runtime transaction.'));
    }
    _transaction?.requestRevocation();
    final generation = ++_lifecycleGeneration;
    return _enqueue((tx) async {
      try {
        await _saveInTransaction(tx);
        tx.validate();
        final managed = Map<String, ManagedEntityGeometry>.of(_managedGeometry);
        try {
          // Scene and document disappear in the same synchronous section as
          // native residency. Native destruction happens only afterwards and
          // therefore cannot leave a visible entity backed by a dead owner.
          _install(
            tx,
            null,
            null,
            const [],
            const [],
            const [],
            boundary: true,
          );
          _managedGeometry.clear();
          _managedLocalScene.clear();
        } catch (_) {
          _managedGeometry.addAll(managed);
          rethrow;
        }
        await _disposeManagedGeometry(managed.values);
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
        placement: entity.placement,
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

  List<double> _nextImportedMeshColor(CadDocument document) {
    final existing = <Color>[];
    for (final entity in document.entities.values.where(
      (candidate) => candidate.kind == CadDocumentEntityKind.import,
    )) {
      final scene = entity.data['sceneGeometry'];
      final color =
          colorFromLinearRgb(entity.data['rootLinearRgb']) ??
          (scene is Map ? colorFromLinearRgb(scene['rootLinearRgb']) : null);
      if (color != null) existing.add(color);
    }
    return linearRgbForColor(
      chooseImportedMeshColor(existing: existing, offset: existing.length),
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
    if (imported.shape == null && geometry != null) {
      sceneGeometry['rootLinearRgb'] = _nextImportedMeshColor(current);
    }
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

  /// Imports one BREP through the managed transactional path. The picker path
  /// is only an initial locator: after CAF opens it, every read is anchored to
  /// that object and no pathname reaches OpenCascade.
  Future<CadDocumentEntity> importManagedBrep(
    String locator, {
    String? name,
    @visibleForTesting String? nativeBridgePath,
  }) async {
    final rejection = _admissionError;
    if (rejection != null) return Future<CadDocumentEntity>.error(rejection);
    // The locator loses authority here, before this operation waits behind any
    // previously admitted transaction. A later directory-entry replacement
    // cannot redirect the already-open CAF object.
    final openedSource = CadAssetNativeFs.openExternal(locator);
    final openedDisplayName = openedSource.displayName;
    final openedIdentity = Map<String, dynamic>.unmodifiable({
      ...openedSource.identity,
    });
    late CadDocumentEntity committedEntity;
    var sourceDisposeAttempted = false;
    Object? primaryFailure;
    StackTrace? primaryStack;
    try {
      await _enqueue((tx) async {
        tx.validate();
        final kernel = kernels.active;
        if (kernel is! OpenCascadeKernelAdapter) {
          throw UnsupportedError(
            'Managed BREP import requires the OpenCascade kernel',
          );
        }
        ManagedNativeShape? shape;
        ManagedNativeDisplayMesh? displayMesh;
        ManagedEntityGeometry? operationGeometry;
        try {
          final sourceCancellation = NativeSourceCancellation();
          unawaited(
            Future.any<void>([
              tx.revocation.future,
              _assetShutdown.future,
            ]).then((_) => sourceCancellation.revoke()),
          );
          NativeSourceResource sourceResource;
          try {
            sourceResource = await kernel.readOwnedAsset(
              filesystem: openedSource.filesystem,
              file: openedSource.file,
              expected: openedIdentity,
              kind: NativeResourceKind.shape,
              cancellation: sourceCancellation,
              bridgePath: nativeBridgePath,
            );
          } on NativeSourcePublicationFailure catch (error, stack) {
            shape = error.resource.claimShape();
            Error.throwWithStackTrace(error.failure, stack);
          }
          try {
            shape = sourceResource.claimShape();
          } finally {
            await sourceResource.dispose();
          }
          tx.validate();
          // The source capability has served its only purpose. Closing it here
          // keeps source cleanup on the pre-promotion side of the transaction.
          sourceDisposeAttempted = true;
          openedSource.dispose();
          final managedShape = shape;

          committedEntity = await _withGeometryStagingTransaction(tx, (
            operation,
          ) async {
            final shapeAssetId = await operation.planAsset();
            final displayAssetId = await operation.planAsset();
            final shapeAsset = await operation._writeManagedShape(
              shapeAssetId,
              CadAssetFile.brep,
              kernel,
              managedShape,
              bridgePath: nativeBridgePath,
            );
            final displayAsset = await operation._writeManagedShape(
              displayAssetId,
              CadAssetFile.display,
              kernel,
              managedShape,
              bridgePath: nativeBridgePath,
            );
            final meshCancellation = NativeSourceCancellation();
            unawaited(
              Future.any<void>([
                tx.revocation.future,
                _assetShutdown.future,
              ]).then((_) => meshCancellation.revoke()),
            );
            final meshResource = await displayAsset.readAs(
              kernel,
              kind: NativeResourceKind.mesh,
              cancellation: meshCancellation,
              bridgePath: nativeBridgePath,
            );
            try {
              displayMesh = meshResource.claimMesh();
            } finally {
              await meshResource.dispose();
            }
            final managedDisplayMesh = displayMesh!;
            operationGeometry = ManagedBrepEntityGeometry(
              managedShape,
              managedDisplayMesh,
            );
            final sceneGeometry = await managedDisplayMesh.prepareSceneGeometry(
              kernel,
              presentationShape: managedShape,
            );
            await operation.prepare();

            final current = _snapshots.document(_requireDocument());
            var entityId = _assetId('e1');
            while (current.entities.containsKey(entityId) ||
                _managedGeometry.containsKey(entityId)) {
              entityId = _assetId('e1');
            }
            final assets = ManagedBrepAssets(
              shape: shapeAssetId,
              display: displayAssetId,
              shapeSha256: shapeAsset.metadata['sha256'] as String,
              displaySha256: displayAsset.metadata['sha256'] as String,
            );
            final identity = ManagedCadIdentity.shape(
              format: 'brep',
              shapeType: managedShape.descriptor.resourceType,
            );
            final entity = CadDocumentEntity(
              id: entityId,
              kind: CadDocumentEntityKind.import,
              data: {
                'name': name?.trim().isNotEmpty == true
                    ? name!.trim()
                    : managedCadImportName(
                        path.basenameWithoutExtension(openedDisplayName),
                        current.entities.values
                            .map((candidate) => candidate.data['name'])
                            .whereType<String>(),
                      ),
                'format': 'brep',
                ...identity.toDocumentData(),
                'collectionId': 'collection:original',
                'sceneKind': CadSceneEntityKind.mesh.name,
                'managedBrepAssets': assets.toJson(),
                'sourceIdentity': openedIdentity,
                'shapeDescriptor': managedShape.descriptor.toManagedMetadata(),
                'displayMeshDescriptor': managedDisplayMesh.descriptor
                    .toManagedMetadata(),
              },
            );
            final candidate = FeatureLifecycleProjector.normalize(
              current.mutate(command: 'import.brep.managed', upsert: [entity]),
              command: 'import.brep.managed',
              previousDocument: current,
              touchedIds: {entityId},
            );
            final managedScene = CadSceneEntity(
              id: entityId,
              kind: CadSceneEntityKind.mesh,
              geometry: sceneGeometry,
            );
            final prepared = _prepareManagedCommit(
              tx,
              candidate: candidate,
              undo: [..._undo, current],
              redo: const [],
              managedScene: managedScene,
              geometry: operationGeometry!,
              phasePrefix: 'managedBrep',
            );

            // Descendant file capabilities must be closed before the anchored
            // directory rename used by promotion.
            await shapeAsset.release();
            await displayAsset.release();
            tx.validate();
            await _assetStorage.checkpoint('managedBrep:beforePromotion');
            tx.validate();
            await operation.promote();
            await _assetStorage.checkpoint('managedBrep:afterPromotion');
            tx.validate();
            await _commitPreparedManaged(tx, prepared);
            await operation._confirmDocumentPublished();
            _recordManagedImportPublication(tx, prepared.bounds);
            committedEntity = prepared.candidate.entities[entityId]!;
            return committedEntity;
          });
        } finally {
          final geometry = operationGeometry;
          if (geometry != null) {
            await geometry.dispose();
          } else {
            await Future.wait([
              if (displayMesh != null) displayMesh!.dispose(),
              if (shape != null) shape.dispose(),
            ]);
          }
        }
      });
    } catch (error, stack) {
      primaryFailure = error;
      primaryStack = stack;
    }
    if (!sourceDisposeAttempted) {
      try {
        openedSource.dispose();
      } catch (cleanup, cleanupStack) {
        if (primaryFailure != null) {
          Error.throwWithStackTrace(
            CadAssetOperationFailure(
              primaryFailure,
              cleanup,
              primaryStack!,
              cleanupStack,
            ),
            primaryStack,
          );
        }
        Error.throwWithStackTrace(cleanup, cleanupStack);
      }
    }
    if (primaryFailure != null) {
      Error.throwWithStackTrace(primaryFailure, primaryStack!);
    }
    return committedEntity;
  }

  /// Single-part STEP import through the admitted CAF source. Appearance is
  /// stored independently; native geometry is already canonical millimeters.
  Future<CadDocumentEntity> importManagedStep(
    String locator, {
    CadAssetCancellation? cancellation,
    @visibleForTesting String? nativeBridgePath,
  }) async {
    final rejection = _admissionError;
    if (rejection != null) return Future<CadDocumentEntity>.error(rejection);
    // The locator loses authority here, before this operation waits behind any
    // previously admitted transaction. A later directory-entry replacement
    // cannot redirect the already-open CAF object.
    if (cancellation?.isCancelled == true) throw const CadAssetCancelled();
    late final NativeOpenedSource openedSource;
    try {
      openedSource = CadAssetNativeFs.openExternal(locator);
    } catch (error) {
      logManagedStepFailure(error);
      rethrow;
    }
    final openedIdentity = Map<String, dynamic>.unmodifiable({
      ...openedSource.identity,
    });
    final openedDisplayName = openedSource.displayName;
    late CadDocumentEntity committedEntity;
    var sourceDisposeAttempted = false;
    var documentCommitted = false;
    Object? primaryFailure;
    StackTrace? primaryStack;
    try {
      await _enqueue((tx) async {
        if (cancellation?.isCancelled == true) throw const CadAssetCancelled();
        if (cancellation != null) {
          unawaited(
            cancellation._done.future.then((_) {
              if (!tx.committed) tx.requestRevocation();
            }),
          );
        }
        tx.validate();
        final kernel = kernels.active;
        if (kernel is! OpenCascadeKernelAdapter) {
          throw UnsupportedError(
            'Managed STEP import requires the OpenCascade kernel',
          );
        }
        late StepAppearanceManifest appearance;
        ManagedNativeShape? shape;
        ManagedNativeDisplayMesh? displayMesh;
        ManagedEntityGeometry? operationGeometry;
        try {
          final sourceCancellation = NativeSourceCancellation();
          unawaited(
            Future.any<void>([
              tx.revocation.future,
              _assetShutdown.future,
            ]).then((_) => sourceCancellation.revoke()),
          );
          NativeSourceResource sourceResource;
          try {
            sourceResource = await kernel.readOwnedAsset(
              filesystem: openedSource.filesystem,
              file: openedSource.file,
              expected: openedIdentity,
              kind: NativeResourceKind.shape,
              step: true,
              cancellation: sourceCancellation,
              bridgePath: nativeBridgePath,
            );
          } on NativeSourcePublicationFailure catch (error, stack) {
            shape = error.resource.claimShape();
            Error.throwWithStackTrace(error.failure, stack);
          }
          try {
            shape = sourceResource.claimShape();
            appearance =
                sourceResource.stepAppearance ??
                (throw StateError('STEP metadata missing'));
          } finally {
            await sourceResource.dispose();
          }
          tx.validate();
          // The source capability has served its only purpose. Closing it here
          // keeps source cleanup on the pre-promotion side of the transaction.
          sourceDisposeAttempted = true;
          openedSource.dispose();
          final managedShape = shape;

          committedEntity = await _withGeometryStagingTransaction(tx, (
            operation,
          ) async {
            final shapeAssetId = await operation.planAsset();
            final displayAssetId = await operation.planAsset();
            final appearanceAssetId = await operation.planAsset();
            await _assetStorage.checkpoint('managedStep:beforeShapeWrite');
            tx.validate();
            final shapeAsset = await operation._writeManagedShape(
              shapeAssetId,
              CadAssetFile.brep,
              kernel,
              managedShape,
              bridgePath: nativeBridgePath,
            );
            await _assetStorage.checkpoint('managedStep:beforeDisplayWrite');
            tx.validate();
            final displayAsset = await operation._writeManagedShape(
              displayAssetId,
              CadAssetFile.display,
              kernel,
              managedShape,
              bridgePath: nativeBridgePath,
            );
            final meshCancellation = NativeSourceCancellation();
            unawaited(
              Future.any<void>([
                tx.revocation.future,
                _assetShutdown.future,
              ]).then((_) => meshCancellation.revoke()),
            );
            final meshResource = await displayAsset.readAs(
              kernel,
              kind: NativeResourceKind.mesh,
              cancellation: meshCancellation,
              bridgePath: nativeBridgePath,
            );
            try {
              displayMesh = meshResource.claimMesh();
            } finally {
              await meshResource.dispose();
            }
            final managedDisplayMesh = displayMesh!;
            operationGeometry = ManagedBrepEntityGeometry(
              managedShape,
              managedDisplayMesh,
            );
            final sceneGeometry = await managedDisplayMesh.prepareSceneGeometry(
              kernel,
              presentationShape: managedShape,
            );
            final appearanceBytes = appearance.encode();
            await _assetStorage.checkpoint('managedStep:beforeAppearance');
            tx.validate();
            await operation.write(
              appearanceAssetId,
              CadAssetFile.appearance,
              Stream.value(appearanceBytes),
            );
            await operation.prepare();

            final current = _snapshots.document(_requireDocument());
            var entityId = _assetId('e1');
            while (current.entities.containsKey(entityId) ||
                _managedGeometry.containsKey(entityId)) {
              entityId = _assetId('e1');
            }
            final assets = ManagedStepAssets(
              shape: shapeAssetId,
              display: displayAssetId,
              appearance: appearanceAssetId,
              appearanceSha256: sha256.convert(appearanceBytes).toString(),
              shapeSha256: shapeAsset.metadata['sha256'] as String,
              displaySha256: displayAsset.metadata['sha256'] as String,
            );
            final identity = ManagedCadIdentity.shape(
              format: 'step',
              shapeType: managedShape.descriptor.resourceType,
              technicalName: appearance.name,
            );
            final entity = CadDocumentEntity(
              id: entityId,
              kind: CadDocumentEntityKind.import,
              data: {
                'name': managedCadImportName(
                  path.basenameWithoutExtension(openedDisplayName),
                  current.entities.values
                      .map((candidate) => candidate.data['name'])
                      .whereType<String>(),
                ),
                'format': 'step',
                ...identity.toDocumentData(),
                'collectionId': 'collection:original',
                'sceneKind': CadSceneEntityKind.mesh.name,
                'managedStepAssets': assets.toJson(),
              },
            );
            final candidate = FeatureLifecycleProjector.normalize(
              current.mutate(command: 'import.step.managed', upsert: [entity]),
              command: 'import.step.managed',
              previousDocument: current,
              touchedIds: {entityId},
            );
            final managedScene = CadSceneEntity(
              id: entityId,
              kind: CadSceneEntityKind.mesh,
              geometry: {
                ...sceneGeometry,
                if (appearance.hasColor) 'rootLinearRgb': appearance.linearRgb,
                if (appearance.usedCompatibility) 'stepCompatibility': true,
              },
            );
            final prepared = _prepareManagedCommit(
              tx,
              candidate: candidate,
              undo: [..._undo, current],
              redo: const [],
              managedScene: managedScene,
              geometry: operationGeometry!,
              phasePrefix: 'managedStep',
            );

            // Descendant file capabilities must be closed before the anchored
            // directory rename used by promotion.
            await shapeAsset.release();
            await displayAsset.release();
            tx.validate();
            await _assetStorage.checkpoint('managedStep:beforePromotion');
            tx.validate();
            await operation.promote();
            await _assetStorage.checkpoint('managedStep:afterPromotion');
            tx.validate();
            await _commitPreparedManaged(tx, prepared);
            await operation._confirmDocumentPublished();
            _recordManagedImportPublication(tx, prepared.bounds);
            committedEntity = prepared.candidate.entities[entityId]!;
            return committedEntity;
          }, cancellation: cancellation);
        } finally {
          documentCommitted = tx.committed;
          final geometry = operationGeometry;
          if (geometry != null) {
            await geometry.dispose();
          } else {
            await Future.wait([
              if (displayMesh != null) displayMesh!.dispose(),
              if (shape != null) shape.dispose(),
            ]);
          }
        }
      });
    } catch (error, stack) {
      if (error is CadAssetOperationFailure) {
        logManagedStepFailure(error.cause);
        logManagedStepFailure(error.cleanup);
      } else {
        logManagedStepFailure(error);
      }
      if (documentCommitted) {
        _recoveryRequired = true;
        primaryFailure = CadManagedStepPostCommitFailure(error);
      } else {
        primaryFailure = error;
      }
      primaryStack = stack;
    }
    if (!sourceDisposeAttempted) {
      try {
        openedSource.dispose();
      } catch (cleanup, cleanupStack) {
        if (primaryFailure != null) {
          Error.throwWithStackTrace(
            CadAssetOperationFailure(
              primaryFailure,
              cleanup,
              primaryStack!,
              cleanupStack,
            ),
            primaryStack,
          );
        }
        Error.throwWithStackTrace(cleanup, cleanupStack);
      }
    }
    if (primaryFailure != null) {
      Error.throwWithStackTrace(primaryFailure, primaryStack!);
    }
    return committedEntity;
  }

  /// Imports an STL through CAF and retains it as one managed mesh-only entity.
  /// The locator is consumed once at admission and never reaches OpenCascade.
  Future<CadDocumentEntity> importManagedStl(
    String locator, {
    String? name,
    CadAssetCancellation? cancellation,
    @visibleForTesting String? nativeBridgePath,
  }) async {
    final rejection = _admissionError;
    if (rejection != null) return Future<CadDocumentEntity>.error(rejection);
    if (cancellation?.isCancelled == true) throw const CadAssetCancelled();
    final openedSource = CadAssetNativeFs.openExternal(locator);
    final openedDisplayName = openedSource.displayName;
    final openedIdentity = Map<String, dynamic>.unmodifiable({
      ...openedSource.identity,
    });
    late CadDocumentEntity committedEntity;
    var sourceDisposeAttempted = false;
    Object? primaryFailure;
    StackTrace? primaryStack;
    try {
      await _enqueue((tx) async {
        if (cancellation?.isCancelled == true) throw const CadAssetCancelled();
        if (cancellation != null) {
          unawaited(
            cancellation._done.future.then((_) {
              if (!tx.committed) tx.requestRevocation();
            }),
          );
        }
        tx.validate();
        final kernel = kernels.active;
        if (kernel is! OpenCascadeKernelAdapter) {
          throw UnsupportedError(
            'Managed STL import requires the OpenCascade kernel',
          );
        }
        ManagedNativeDisplayMesh? displayMesh;
        ManagedEntityGeometry? operationGeometry;
        try {
          final cancellation = NativeSourceCancellation();
          unawaited(
            Future.any<void>([
              tx.revocation.future,
              _assetShutdown.future,
            ]).then((_) => cancellation.revoke()),
          );
          NativeSourceResource sourceResource;
          try {
            sourceResource = await kernel.readOwnedAsset(
              filesystem: openedSource.filesystem,
              file: openedSource.file,
              expected: openedIdentity,
              kind: NativeResourceKind.mesh,
              cancellation: cancellation,
              bridgePath: nativeBridgePath,
            );
          } on NativeSourcePublicationFailure catch (error, stack) {
            displayMesh = error.resource.claimMesh();
            Error.throwWithStackTrace(error.failure, stack);
          }
          try {
            displayMesh = sourceResource.claimMesh();
          } finally {
            await sourceResource.dispose();
          }
          tx.validate();
          sourceDisposeAttempted = true;
          openedSource.dispose();
          final managedDisplayMesh = displayMesh;

          committedEntity = await _withGeometryStagingTransaction(tx, (
            operation,
          ) async {
            final displayAssetId = await operation.planAsset();
            final displayAsset = await operation._writeManagedMesh(
              displayAssetId,
              kernel,
              managedDisplayMesh,
              bridgePath: nativeBridgePath,
            );
            operationGeometry = ManagedMeshEntityGeometry(managedDisplayMesh);
            final sceneGeometry = await managedDisplayMesh.prepareSceneGeometry(
              kernel,
            );
            await operation.prepare();

            final current = _snapshots.document(_requireDocument());
            var entityId = _assetId('e1');
            while (current.entities.containsKey(entityId) ||
                _managedGeometry.containsKey(entityId)) {
              entityId = _assetId('e1');
            }
            final assets = ManagedStlAssets(
              display: displayAssetId,
              displaySha256: displayAsset.metadata['sha256'] as String,
            );
            final identity = ManagedCadIdentity.stl();
            final importedColor = _nextImportedMeshColor(current);
            final entity = CadDocumentEntity(
              id: entityId,
              kind: CadDocumentEntityKind.import,
              data: {
                'name': name?.trim().isNotEmpty == true
                    ? name!.trim()
                    : managedCadImportName(
                        path.basenameWithoutExtension(openedDisplayName),
                        current.entities.values
                            .map((candidate) => candidate.data['name'])
                            .whereType<String>(),
                      ),
                'format': 'stl',
                ...identity.toDocumentData(),
                'collectionId': 'collection:original',
                'sceneKind': CadSceneEntityKind.mesh.name,
                'rootLinearRgb': importedColor,
                'managedStlAssets': assets.toJson(),
              },
            );
            final candidate = FeatureLifecycleProjector.normalize(
              current.mutate(command: 'import.stl.managed', upsert: [entity]),
              command: 'import.stl.managed',
              previousDocument: current,
              touchedIds: {entityId},
            );
            final prepared = _prepareManagedCommit(
              tx,
              candidate: candidate,
              undo: [..._undo, current],
              redo: const [],
              managedScene: CadSceneEntity(
                id: entityId,
                kind: CadSceneEntityKind.mesh,
                geometry: {...sceneGeometry, 'rootLinearRgb': importedColor},
              ),
              geometry: operationGeometry!,
              phasePrefix: 'managedStl',
            );

            await displayAsset.release();
            tx.validate();
            await _assetStorage.checkpoint('managedStl:beforePromotion');
            tx.validate();
            await operation.promote();
            await _assetStorage.checkpoint('managedStl:afterPromotion');
            tx.validate();
            await _commitPreparedManaged(tx, prepared);
            await operation._confirmDocumentPublished();
            _recordManagedImportPublication(tx, prepared.bounds);
            committedEntity = prepared.candidate.entities[entityId]!;
            return committedEntity;
          });
        } finally {
          final geometry = operationGeometry;
          if (geometry != null) {
            await geometry.dispose();
          } else if (displayMesh != null) {
            await displayMesh.dispose();
          }
        }
      });
    } catch (error, stack) {
      primaryFailure = error;
      primaryStack = stack;
    }
    if (!sourceDisposeAttempted) {
      try {
        openedSource.dispose();
      } catch (cleanup, cleanupStack) {
        if (primaryFailure != null) {
          Error.throwWithStackTrace(
            CadAssetOperationFailure(
              primaryFailure,
              cleanup,
              primaryStack!,
              cleanupStack,
            ),
            primaryStack,
          );
        }
        Error.throwWithStackTrace(cleanup, cleanupStack);
      }
    }
    if (primaryFailure != null) {
      Error.throwWithStackTrace(primaryFailure, primaryStack!);
    }
    return committedEntity;
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
    if (!displayOnly &&
        stateOverrides.isEmpty &&
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
    if (!displayOnly && _sameJson(candidateContent, previousContent)) return;
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

  /// Publishes an accepted authoring Feature already in its closed lifecycle
  /// state. Preview confirmation is one user action and therefore one durable
  /// Undo/Redo step.
  Future<void> upsertClosedEntity({
    required String command,
    required CadDocumentEntityKind kind,
    required CadSceneEntity entity,
    required ShapeHandle shape,
    Map<String, dynamic> data = const {},
    bool officialShape = false,
  }) async {
    await _persistNativeShape(shape);
    final requested = CadDocumentEntity(
      id: entity.id,
      kind: kind,
      shape: shape,
      data: {
        ...data,
        'collectionId': data['collectionId'] ?? _defaultCollectionFor(kind),
        'sceneKind': entity.kind.name,
        'sceneGeometry': entity.geometry,
        'sceneVisible': entity.visible,
        'sceneTransparent': entity.transparent,
      },
    );
    await _enqueue(
      (tx) => _mutateDocument(
        tx,
        command: command,
        requested: [requested],
        stateOverrides: {entity.id: FeatureLifecycleState.closed},
        officialExport: officialShape
            ? OfficialExportUpdate.set(entity.id)
            : const OfficialExportUpdate.keep(),
      ),
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
            placement: member.placement,
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

  Future<void> setEntityVisibility(String id, bool visible) => _enqueue((
    tx,
  ) async {
    final document = _requireDocument();
    final entity =
        document.entities[id] ??
        (throw StateError('Unknown document entity: $id'));
    if (entity.kind == CadDocumentEntityKind.collection) {
      await _updateCollection(tx, id, visible: visible);
      return;
    }
    // A Sketch root owns its curves and sampled points. Hiding or showing
    // the root must move the whole overlay, otherwise the green curves and
    // endpoints stay painted above the native texture.
    final children = document.entities.values
        .where((child) => child.data['parentSketchId'] == id)
        .toList(growable: false);
    final alreadyVisible = (entity.data['sceneVisible'] ?? true) == visible;
    final childrenMatch = children.every(
      (child) => (child.data['sceneVisible'] ?? true) == visible,
    );
    if (alreadyVisible && childrenMatch) {
      // A display-only synchronization can leave a stale scene entry even
      // though the persisted root and child flags are already correct.
      // Reconcile that presentation state instead of treating a Show as a
      // second Hide on the next controller toggle.
      final collection = document.entities[entity.data['collectionId']];
      final effectiveVisible =
          visible &&
          collection?.data['visible'] != false &&
          collection?.data['deleted'] != true;
      var repaired = false;
      void repair(String entityId) {
        final sceneEntity = scene.find(entityId);
        if (sceneEntity != null && sceneEntity.visible != effectiveVisible) {
          scene.upsert(sceneEntity.copyWith(visible: effectiveVisible));
          repaired = true;
        }
      }

      repair(entity.id);
      for (final child in children) {
        repair(child.id);
      }
      if (repaired) notifyListeners();
      return;
    }
    await _mutateDocument(
      tx,
      command: 'display.visibility',
      displayOnly: true,
      requested: [
        CadDocumentEntity(
          id: entity.id,
          kind: entity.kind,
          placement: entity.placement,
          shape: entity.shape,
          mesh: entity.mesh,
          data: {...entity.data, 'sceneVisible': visible},
        ),
        for (final child in children)
          CadDocumentEntity(
            id: child.id,
            kind: child.kind,
            placement: child.placement,
            shape: child.shape,
            mesh: child.mesh,
            data: {...child.data, 'sceneVisible': visible},
          ),
      ],
    );
  });

  /// World-axis translation (mm), then X/Y/Z rotations (degrees) about the
  /// original local bounds center. One call is one transaction/history entry.
  Future<void> transformManagedEntity(
    String id, {
    double translateX = 0,
    double translateY = 0,
    double translateZ = 0,
    double rotateX = 0,
    double rotateY = 0,
    double rotateZ = 0,
  }) => _enqueue((tx) async {
    final document = _requireDocument();
    final entity = document.entities[id];
    if (entity == null ||
        entity.data['deleted'] == true ||
        !_managedGeometry.containsKey(id)) {
      throw StateError('Select an active managed STEP, BREP or STL entity');
    }
    final collection = document.entities[entity.data['collectionId']];
    if (collection?.data['locked'] == true) {
      throw StateError('Managed entity collection is locked');
    }
    final values = [
      translateX,
      translateY,
      translateZ,
      rotateX,
      rotateY,
      rotateZ,
    ];
    if (values.any((v) => !v.isFinite)) {
      throw const FormatException('Placement values must be finite');
    }
    if (values.every((v) => v == 0)) return;
    final bounds = _managedGeometry[id]!.displayMesh.descriptor.bounds;
    var placement =
        entity.placement ??
        EntityPlacement.identity([
          for (var axis = 0; axis < 3; axis++)
            (bounds[axis] + bounds[axis + 3]) / 2,
        ]);
    if (translateX != 0 || translateY != 0 || translateZ != 0) {
      placement = placement.translate(translateX, translateY, translateZ);
    }
    if (rotateX != 0) placement = placement.rotate(1, 0, 0, rotateX);
    if (rotateY != 0) placement = placement.rotate(0, 1, 0, rotateY);
    if (rotateZ != 0) placement = placement.rotate(0, 0, 1, rotateZ);
    await _mutateDocument(
      tx,
      command: 'placement.rigid',
      requested: [
        CadDocumentEntity(
          id: entity.id,
          kind: entity.kind,
          data: entity.data,
          placement: placement,
        ),
      ],
    );
  });

  Future<void> resetManagedPlacement(String id) => _enqueue((tx) async {
    final entity = _requireDocument().entities[id];
    if (entity == null ||
        !_managedGeometry.containsKey(id) ||
        entity.data['deleted'] == true) {
      throw StateError('Select an active managed entity');
    }
    if (_requireDocument()
            .entities[entity.data['collectionId']]
            ?.data['locked'] ==
        true) {
      throw StateError('Managed entity collection is locked');
    }
    await _mutateDocument(
      tx,
      command: 'placement.reset',
      requested: [
        CadDocumentEntity(id: entity.id, kind: entity.kind, data: entity.data),
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
    if (entityIds.any((id) {
      final data = current.entities[id]?.data;
      return data?['managedBrepAssets'] != null ||
          data?['managedStlAssets'] != null ||
          data?['managedStepAssets'] != null;
    })) {
      throw UnsupportedError(
        'Managed geometry requires rigid placement commands',
      );
    }
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
          placement: entity.placement,
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
    var meshes = _displayMeshes;
    final document = _document;
    final directory = _projectDirectory;
    if (meshes == null && document != null && directory != null) {
      meshes = KernelDisplayMeshPipeline(
        kernel: kernels.active,
        projectId: document.projectId,
        projectDirectory: directory,
        scene: scene,
      );
      if (meshes.supported) _displayMeshes = meshes;
    }
    if (meshes == null || !meshes.supported) {
      projection.upsertTransient(entity);
      return;
    }
    await meshes.upsert(
      entityId: entity.id,
      shape: shape,
      presentation: entity,
    );
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
          placement: entity.placement,
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
                placement: item.placement,
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
                placement: item.placement,
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
        placement: member.placement,
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
          placement: entity.placement,
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
    final ownedSketchIds = <String>{};
    final sketchRoot =
        target.data['sketch'] is Map ||
        target.kind == CadDocumentEntityKind.sketch;
    if (sketchRoot) {
      for (final entity in document.entities.values) {
        if (entity.data['deleted'] == true) continue;
        if (entity.data['parentSketchId'] == entityId) {
          ownedSketchIds.add(entity.id);
        }
      }
    }
    final dependencySources = <String>{entityId, ...ownedSketchIds};
    final dependentEntities = <CadDocumentEntity>{
      for (final sourceId in dependencySources) ...dependencyImpact(sourceId),
    };
    final entities = <CadDocumentEntity>[
      if (target.data['deleted'] != true) target,
      for (final id in ownedSketchIds)
        if (document.entities[id] case final CadDocumentEntity owned) owned,
      if (includeDependencies)
        ...dependentEntities.where(
          (entity) =>
              entity.data['deleted'] != true &&
              entity.id != entityId &&
              !ownedSketchIds.contains(entity.id),
        ),
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
            placement: entity.placement,
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
              placement: entity.placement,
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

  Future<void> redoDocument({CadAssetCancellation? cancellation}) {
    if (cancellation?.isCancelled == true) {
      return Future.error(const CadAssetCancelled());
    }
    return _enqueue((tx) async {
      if (cancellation?.isCancelled == true) throw const CadAssetCancelled();
      if (cancellation != null) {
        unawaited(
          Future.any<void>([
            cancellation._done.future,
            tx.revocation.future,
          ]).then((_) {
            if (cancellation.isCancelled && !tx.committed) {
              tx.requestRevocation();
            }
          }),
        );
      }
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
  }

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
        .where(
          (entity) =>
              entity.kind == CadDocumentEntityKind.import &&
              entity.data['managedBrepAssets'] == null &&
              entity.data['managedStlAssets'] == null &&
              entity.data['managedStepAssets'] == null,
        )
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
    _transaction?.requestRevocation();
    if (!_assetShutdown.isCompleted) _assetShutdown.complete();
    _lifecycleGeneration++;
    _sessionActive = false;
    final done = Completer<void>();
    _shutdownFuture = done.future;
    unawaited(
      _transactionTail
          .then((_) async {
            final managed = _managedGeometry.values.toList();
            _managedGeometry.clear();
            _managedLocalScene.clear();
            await Future.wait(managed.map((value) => value.dispose()));
            geometrySelection.removeListener(_forwardSelectionChange);
            _selectionForwardPending = false;
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
