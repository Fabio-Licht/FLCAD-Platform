import 'dart:convert';
import 'dart:io';

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/adaptive_surface/models/surface_geometry.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/professional_recognition/models/professional_recognition_models.dart';
import 'package:flcad_mobile/core/recognition_engine/recognition_result.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/models/reference_entity.dart';
import 'package:flcad_mobile/core/reference_engine/models/reference_geometry.dart';
import 'package:flcad_mobile/core/smart_regions/models/geometry.dart';
import 'package:flcad_mobile/core/smart_regions/models/smart_region.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reference axis creation is globally undoable and redoable', () async {
    final directory = Directory.systemTemp.createTempSync('flcad-u1-ref-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final kernels = KernelManager();
    final cad = DesktopCadController(
      kernels: kernels,
      projects: ProjectManager.instance,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    addTearDown(cad.dispose);
    await cad.runtime.open('project', directory);
    final referenceApi = _HistoryReferenceApi();
    final controller = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
      referenceApi: referenceApi,
    );
    addTearDown(controller.dispose);
    controller.configuredProjectId = 'project';
    controller.activeReference = _reference(
      id: 'base-plane',
      name: 'Base Plane',
      geometry: const PlaneGeometry(Vec3(0, 0, 0), Vec3(0, 0, 1)),
    );

    await commands.dispatch('reverse.reference.axis');

    final created = cad.runtime.document!.entities.values
        .where((entity) => entity.kind == CadDocumentEntityKind.reference)
        .last;
    expect(created, isNotNull);
    expect(created.data['reference'], isNotNull);
    await controller.undo();
    expect(cad.runtime.document!.entities[created.id], isNull);
    await controller.redo();
    expect(cad.runtime.document!.entities[created.id], isNotNull);
  });

  test(
    'surface assistant confirmation is globally undoable and redoable',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'flcad-u1-surface-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final kernels = KernelManager()
        ..register(_SurfaceKernel(), makeDefault: true);
      final cad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
      );
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
      );
      addTearDown(cad.dispose);
      await cad.runtime.open('project', directory);
      final controller = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: commands,
        runtime: cad.runtime,
        referenceApi: _HistoryReferenceApi(),
      );
      addTearDown(controller.dispose);
      await controller.configureProject(
        projectId: 'project',
        projectDirectory: directory,
      );
      final result = RecognitionResult(
        id: 'Recognition001',
        type: RecognitionResultType.plane,
        meshId: 'mesh',
        regionId: 'region-1',
        confidence: .95,
        parameters: const {
          'origin': [0.0, 0.0, 0.0],
          'normal': [0.0, 0.0, 1.0],
          'area': 4.0,
          'rmsDeviation': .001,
          'maximumDeviation': .002,
          'dimensionalToleranceMm': .5,
          'dimensionalStatus': 'approved',
          'dimensionalApproved': true,
          'referenceApproved': true,
          'cadSurfaceApproved': true,
        },
        quality: 'fixture',
        suggestion: 'fixture',
        createdAt: DateTime(2026, 1, 1),
      );
      cad.runtime.debugPutEntity(
        CadDocumentEntity(
          id: result.id,
          kind: CadDocumentEntityKind.recognition,
          data: {'name': result.id, 'recognitionResult': result.toJson()},
        ),
      );
      controller.openSurfaceAssistant(result.id);
      expect(controller.activeSurfaceAssistantSuggestion?.canCreate, isTrue);

      await controller.confirmSurfaceAssistantSuggestion();

      final created = controller.activeSurface!;
      expect(cad.runtime.document!.entities[created.surfaceId], isNotNull);
      expect(
        jsonEncode(cad.runtime.document!.toJson()),
        contains(created.surfaceId),
      );
      await commands.undo();
      expect(cad.runtime.document!.entities[created.surfaceId], isNull);
      expect(controller.activeRecognitionResult, isNull);
      expect(cad.runtime.scene.find('surface-assistant-preview'), isNull);
      expect(
        jsonEncode(cad.runtime.document!.toJson()),
        isNot(contains(created.surfaceId)),
      );
      await commands.redo();
      expect(cad.runtime.document!.entities[created.surfaceId], isNotNull);
      expect(controller.activeSurface?.surfaceId, created.surfaceId);
      expect(controller.activeRecognitionResult, isNull);
      expect(
        cad.runtime.document!.entities[created.surfaceId]!.data['surface'],
        isNotNull,
      );
      expect(cad.runtime.scene.find('surface-assistant-preview'), isNull);
      await cad.runtime.save();
      final savedDocument = File(
        '${directory.path}${Platform.pathSeparator}cad-document.json',
      );
      expect(savedDocument.existsSync(), isTrue);
      expect(savedDocument.readAsStringSync(), contains(created.surfaceId));
      final reopenedCad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
      );
      addTearDown(reopenedCad.dispose);
      await reopenedCad.runtime.open('project', directory);
      expect(
        reopenedCad.runtime.document!.entities[created.surfaceId],
        isNotNull,
      );
      expect(
        reopenedCad.runtime.scene.find('surface-assistant-preview'),
        isNull,
      );
    },
  );

  test(
    'recognized surface creation is globally undoable and redoable',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'flcad-u1-recognized-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final kernels = KernelManager()
        ..register(_SurfaceKernel(), makeDefault: true);
      final cad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
      );
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
      );
      addTearDown(cad.dispose);
      await cad.runtime.open('project', directory);
      final controller = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: commands,
        runtime: cad.runtime,
        referenceApi: _HistoryReferenceApi(),
      );
      addTearDown(controller.dispose);
      await controller.configureProject(
        projectId: 'project',
        projectDirectory: directory,
      );
      final primitive = _spherePrimitive();
      controller.report = ProfessionalRecognitionReport(
        projectId: 'project',
        primitives: [primitive],
        relations: const [],
        features: const [],
        patterns: const [],
        functions: const [],
        manufacturing: const [],
        advice: const [],
        elapsed: const Duration(milliseconds: 1),
        pendingRegionIds: const [],
        createdAt: DateTime(2026, 1, 1),
      );
      controller.decisions[primitive.recognition.id] =
          RecognitionDecision.accepted;

      await controller.createRecognizedSurface(SurfaceKind.sphere);

      final created = controller.activeSurface!;
      expect(cad.runtime.document!.entities[created.surfaceId], isNotNull);
      await controller.undo();
      expect(cad.runtime.document!.entities[created.surfaceId], isNull);
      await controller.redo();
      expect(cad.runtime.document!.entities[created.surfaceId], isNotNull);
      expect(controller.activeSurface?.surfaceId, created.surfaceId);
    },
  );
}

ReferenceEntity _reference({
  required String id,
  required String name,
  required ReferenceGeometry geometry,
}) {
  final now = DateTime(2026, 1, 1);
  return ReferenceEntity(
    id: id,
    projectId: 'project',
    name: name,
    geometry: geometry,
    mode: ReferenceMode.staticReference,
    status: ReferenceStatus.valid,
    dna: const ReferenceDNA('fixture', 'fingerprint', 'signature', 'hash'),
    analytics: const ReferenceAnalytics(
      precision: .001,
      rmsError: 0,
      maxDeviation: 0,
      confidence: 1,
      fitQuality: 1,
      areaUsed: 1,
      coverage: 1,
      pointCount: 1,
    ),
    recipe: const ReferenceRecipe('fixture', {}, []),
    version: 1,
    createdAt: now,
    updatedAt: now,
    dependencies: const [],
    metadata: const {},
  );
}

final class _HistoryReferenceApi extends ReferenceApi {
  final Map<String, ReferenceEntity> values = {};
  int sequence = 0;

  @override
  Future<ReferenceEntity> create({
    required String projectId,
    required String name,
    required ReferenceMode mode,
    required ReferenceRecipe recipe,
    Map<String, MeshTopology> meshes = const {},
    Map<String, SmartRegion> regions = const {},
  }) async {
    final id = 'HistoryReference${++sequence}';
    final entity = _reference(
      id: id,
      name: name,
      geometry: recipe.builderId == 'axis'
          ? const AxisGeometry(Vec3(0, 0, 0), Vec3(0, 0, 1))
          : const PointGeometry(Vec3(0, 0, 0)),
    );
    values[id] = entity;
    return entity;
  }

  @override
  Future<void> delete(ReferenceEntity reference) async {
    values.remove(reference.id);
  }

  @override
  Future<void> restore(ReferenceEntity reference) async {
    values[reference.id] = reference;
  }

  @override
  Future<List<ReferenceEntity>> list(String projectId) async =>
      values.values.toList();

  @override
  Future<bool> validate(ReferenceEntity reference) async => true;
}

ProfessionalPrimitive _spherePrimitive() {
  const statistics = FitStatistics(
    rms: .001,
    maximum: .002,
    mean: .001,
    coverage: 1,
    stability: 1,
    score: .99,
  );
  const candidate = RecognitionCandidate(
    id: 'candidate:sphere',
    type: PrimitiveType.sphere,
    regionId: 'region-1',
    parameters: {
      'center': [0.0, 0.0, 0.0],
      'radius': 1.0,
    },
    statistics: statistics,
    evidence: [],
    origin: 'test',
  );
  return ProfessionalPrimitive(
    recognition: PrimitiveRecognitionResult(
      id: 'recognition:sphere',
      projectId: 'project',
      meshId: 'mesh',
      winner: candidate,
      alternatives: const [],
      dna: const RecognitionDNA(
        type: PrimitiveType.sphere,
        parameters: {
          'center': [0.0, 0.0, 0.0],
          'radius': 1.0,
        },
        regionId: 'region-1',
        geometricSignature: 'sphere',
        quality: .99,
        confidence: .95,
        evidence: [],
        origin: 'test',
        version: '1',
      ),
      explanation: const RecognitionExplanation(
        why: 'fixture',
        evidence: [],
        regions: ['region-1'],
        parameters: {},
        losingCandidates: [],
        score: .99,
        confidence: .95,
      ),
      createdAt: DateTime(2026, 1, 1),
    ),
    residualMap: const ResidualMap([], [], []),
    pass: 1,
    auditTrail: const ['fixture'],
  );
}

final class _SurfaceKernel
    implements
        GeometryKernelAPI,
        MeshGeometryKernelAPI,
        SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'u1-test',
    name: 'U1 test kernel',
    version: '1',
    capabilities: KernelCapabilities({
      KernelCapability.planeSurface,
      KernelCapability.cylinderSurface,
      KernelCapability.coneSurface,
      KernelCapability.sphereSurface,
      KernelCapability.torusSurface,
    }),
    vendor: 'FLCAD',
  );
  @override
  Future<KernelHealth> healthCheck() async =>
      KernelHealth(KernelHealthStatus.healthy, 'ok', DateTime(2000));
  @override
  Future<void> begin(KernelTransaction transaction) async {}
  @override
  Future<void> commit(KernelTransaction transaction) async {}
  @override
  Future<void> rollback(KernelTransaction transaction) async {}
  @override
  Future<void> unload() async {}
  @override
  Future<ShapeHandle> create(
    String operation,
    Map<String, dynamic> parameters, {
    required String persistentId,
    required CADShapeType expectedType,
    required KernelTransaction transaction,
  }) async => ShapeHandle.reference(
    persistentId: persistentId,
    kernelId: descriptor.id,
    type: expectedType,
    fingerprint: 'u1-fingerprint',
  );
  @override
  Future<List<String>> validate(ShapeHandle handle, Set<String> checks) async =>
      const [];
  @override
  Future<KernelMeshHandle> importStl(
    String path, {
    required String projectId,
    KernelImportFormat format = KernelImportFormat.autoDetect,
    KernelCancellationToken cancellation = const NoKernelCancellation(),
    void Function(KernelProgress progress)? onProgress,
  }) async => const KernelMeshHandle(
    persistentId: 'u1-mesh',
    kernelId: 'u1-test',
    fingerprint: 'u1-fingerprint',
    vertexCount: 3,
    triangleCount: 1,
    bounds: KernelBounds(-1, -1, 0, 1, 1, 0),
    hasNormals: false,
    metadata: {},
  );
  @override
  Future<KernelMeshGeometry> inspectMesh(KernelMeshHandle handle) async =>
      const KernelMeshGeometry(
        nodes: [-1, -1, 0, 1, -1, 0, 0, 1, 0],
        triangles: [0, 1, 2],
      );
  @override
  Future<void> closeMesh(KernelMeshHandle handle) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
