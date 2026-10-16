import 'dart:io';

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/feature_lifecycle/feature_lifecycle.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/models/reference_entity.dart';
import 'package:flcad_mobile/core/reference_engine/models/reference_geometry.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/smart_regions/models/geometry.dart';
import 'package:flcad_mobile/core/surface_generation/models/surface_topology.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Surface001 follows one live Sketch through the complete lifecycle',
    () async {
      final root = await Directory.systemTemp.createTemp('flcad_g130_');
      addTearDown(() async => root.delete(recursive: true));
      final projects = ProjectRepository(
        storage: LocalStorageService(rootDirectory: root),
      );
      final projectDirectory = await projects.directoryFor('project');
      final references = ReferenceRepository(projects: projects);
      await references.save('project', [_planeReference]);
      final kernel = _PlanarSurfaceKernel();
      final kernels = KernelManager()..register(kernel, makeDefault: true);
      final cad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
        projectRepository: projects,
      );
      addTearDown(cad.dispose);
      await cad.runtime.open('project', projectDirectory);
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
        repository: projects,
      );
      final controller = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: commands,
        runtime: cad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(repository: references),
        ),
      );
      addTearDown(controller.dispose);
      await controller.configureProject(
        projectId: 'project',
        projectDirectory: projectDirectory,
      );
      await controller.openSketch();
      controller.beginLineCommand();
      controller.runtime.write('sketch.previewPoints', const [
        SketchVector(1, 2),
      ]);
      expect(
        await controller.commitDirectSketchValues(primary: 4, secondary: 0),
        isTrue,
      );
      expect(controller.previewPoints.single.x, 5);
      expect(controller.previewPoints.single.y, 2);
      expect(controller.lineCommandActive, isTrue);
      final chainedLineId = controller.sketchEntities.single.id;
      controller.finishLineCommand();
      controller.sketchApi!.deleteEntity(chainedLineId);
      final circle = controller.sketchApi!.builders.circle.build(
        const SketchVector(0, 0),
        5,
      );
      await controller.finishSketch();
      expect(controller.sketchReadyForSurface, isTrue);
      final sourceSketchId = controller.activeSketch!.id;

      await controller.previewPlanarSurface();
      expect(controller.error, isNull);
      expect(controller.surfaceCadCreationAvailable, isTrue);
      expect(cad.runtime.scene.find('surface-preview'), isNotNull);
      await controller.confirmSurface();

      expect(controller.activeSurface!.surfaceId, 'Surface001');
      expect(
        controller.activeSurface!.parameters['sourceSketchId'],
        sourceSketchId,
      );
      expect(cad.runtime.scene.find('surface-preview'), isNull);
      expect(cad.runtime.scene.find('Surface001'), isNotNull);
      expect(kernel.operations.single, 'CREATE PLANAR FACE');
      var documentSurface = cad.runtime.document!.entities['Surface001']!;
      var lifecycle = FeatureLifecycleContract.require(documentSurface);
      expect(lifecycle.featureId, 'Surface001');
      expect(lifecycle.dependencyIds, [sourceSketchId]);
      expect((documentSurface.data['sceneGeometry'] as Map)['shaded'], isTrue);
      var topology = SurfaceTopology.fromJson(
        (controller.activeSurface!.parameters['topology'] as Map)
            .cast<String, dynamic>(),
      );
      expect(topology.loops.single.id, 'Outer Loop');
      expect(topology.edges.single.id, 'Edge001');
      expect(topology.vertices.single.id, 'Vertex001');
      expect(topology.area, closeTo(3.141592653589793 * 25, .1));
      expect(topology.perimeter, closeTo(2 * 3.141592653589793 * 5, .1));
      expect(cad.runtime.document!.entities['Edge001'], isNotNull);
      expect(cad.runtime.document!.entities['Vertex001'], isNotNull);

      await controller.setSurfaceDisplayMode(
        'Surface001',
        SurfaceDisplayMode.wireframe,
      );
      expect(cad.runtime.scene.find('Surface001')!.geometry['shaded'], isFalse);
      expect(cad.runtime.scene.find('Edge001')!.visible, isTrue);
      await controller.setSurfaceDisplayMode(
        'Surface001',
        SurfaceDisplayMode.shaded,
      );
      expect(cad.runtime.scene.find('Surface001')!.geometry['shaded'], isTrue);
      expect(cad.runtime.scene.find('Edge001')!.visible, isFalse);
      await controller.setSurfaceDisplayMode(
        'Surface001',
        SurfaceDisplayMode.transparent,
      );
      expect(cad.runtime.scene.find('Surface001')!.transparent, isTrue);
      expect(cad.runtime.scene.find('Edge001')!.visible, isFalse);
      await controller.setSurfaceDisplayMode(
        'Surface001',
        SurfaceDisplayMode.shadedWithEdges,
      );
      cad.runtime.select({'Edge001'});
      expect(cad.runtime.scene.find('Edge001')!.selected, isTrue);
      expect(cad.runtime.scene.find('Surface001')!.selected, isFalse);
      cad.runtime.select({'Vertex001'});
      expect(cad.runtime.scene.find('Vertex001')!.selected, isTrue);

      await controller.undo();
      expect(cad.runtime.document!.entities['Surface001'], isNull);
      expect(cad.runtime.scene.find('surface-preview'), isNotNull);
      await controller.redo();
      expect(cad.runtime.document!.entities['Surface001'], isNotNull);
      expect(cad.runtime.scene.find('surface-preview'), isNull);

      final buildsBeforeVisibility = kernel.operations.length;
      await cad.runtime.setEntityVisibility('Surface001', false);
      expect(cad.runtime.scene.find('Surface001')!.visible, isFalse);
      await cad.runtime.setEntityVisibility('Surface001', true);
      expect(cad.runtime.scene.find('Surface001')!.visible, isTrue);
      expect(kernel.operations, hasLength(buildsBeforeVisibility));

      await controller.updateSketchEntityParameters(circle.id, {'radius': 8});
      expect(controller.activeSurface!.surfaceId, 'Surface001');
      expect(controller.activeSurface!.revision, 2);
      expect(kernel.operations, ['CREATE PLANAR FACE', 'CREATE PLANAR FACE']);
      documentSurface = cad.runtime.document!.entities['Surface001']!;
      topology = SurfaceTopology.fromJson(
        (controller.activeSurface!.parameters['topology'] as Map)
            .cast<String, dynamic>(),
      );
      expect(topology.edges.single.id, 'Edge001');
      expect(topology.vertices.single.id, 'Vertex001');
      expect(
        FeatureLifecycleContract.require(
          cad.runtime.document!.entities['Edge001']!,
        ).history.where((event) => event.action == 'updated'),
        isNotEmpty,
      );
      lifecycle = FeatureLifecycleContract.require(documentSurface);
      expect(lifecycle.featureId, 'Surface001');
      expect(
        lifecycle.history.where((event) => event.action == 'updated'),
        isNotEmpty,
      );

      await controller.undo();
      expect(cad.runtime.document!.entities['Surface001'], isNotNull);
      expect(controller.activeSurface!.surfaceId, 'Surface001');
      await controller.redo();
      expect(controller.activeSurface!.surfaceId, 'Surface001');

      await cad.runtime.save(recordLifecycle: true);
      await cad.runtime.close();
      final reopenedCad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
        projectRepository: projects,
      );
      addTearDown(reopenedCad.dispose);
      await reopenedCad.runtime.open('project', projectDirectory);
      final reopenedCommands = DesktopCommandCoordinator(
        cad: reopenedCad,
        projects: ProjectManager.instance,
        repository: projects,
      );
      final reopened = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: reopenedCommands,
        runtime: reopenedCad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(repository: references),
        ),
      );
      addTearDown(reopened.dispose);
      await reopened.configureProject(
        projectId: 'project',
        projectDirectory: projectDirectory,
      );
      expect(reopened.activeSurface!.surfaceId, 'Surface001');
      expect(reopenedCad.runtime.document!.entities['Edge001'], isNotNull);
      expect(reopenedCad.runtime.document!.entities['Vertex001'], isNotNull);
      expect(
        reopened.activeSurface!.parameters['sourceSketchId'],
        sourceSketchId,
      );
      final reopenedLifecycle = FeatureLifecycleContract.require(
        reopenedCad.runtime.document!.entities['Surface001']!,
      );
      expect(reopenedLifecycle.featureId, lifecycle.featureId);
      expect(
        reopenedLifecycle.history.length,
        greaterThanOrEqualTo(lifecycle.history.length),
      );
      await reopenedCad.runtime.transitionFeature(
        'Surface001',
        FeatureLifecycleState.editing,
        command: 'feature.reenter',
      );
      expect(
        FeatureLifecycleContract.require(
          reopenedCad.runtime.document!.entities['Surface001']!,
        ).state,
        FeatureLifecycleState.editing,
      );
      expect(
        reopenedCad.runtime.document!.entities.keys.where(
          (id) => id == 'Surface001',
        ),
        hasLength(1),
      );

      final normalBefore = List<num>.from(
        reopened.activeSurface!.parameters['normal'] as List,
      );
      await reopened.reverseSurfaceNormal('Surface001');
      expect(
        (reopened.activeSurface!.parameters['normal'] as List).last,
        -normalBefore.last,
      );
      expect(
        (reopened.activeSurface!.parameters['topology'] as Map)['edges']
            .first['id'],
        'Edge001',
      );
      await reopened.undo();
      expect(
        (reopened.activeSurface!.parameters['normal'] as List).last,
        normalBefore.last,
      );
      await reopened.redo();
      expect(
        (reopened.activeSurface!.parameters['normal'] as List).last,
        -normalBefore.last,
      );
      reopened.previewSurfaceOffset('Surface001', 2);
      expect(
        reopenedCad.runtime.scene.find('surface-offset-preview'),
        isNotNull,
      );
      expect(await reopened.confirmSurfaceOffset(), 'Surface002');
      expect(
        reopened.activeSurface!.parameters['sourceSurfaceId'],
        'Surface001',
      );
      expect(reopenedCad.runtime.document!.entities['Edge002'], isNotNull);
      await reopened.undo();
      expect(reopenedCad.runtime.document!.entities['Surface002'], isNull);
      await reopened.redo();
      expect(reopenedCad.runtime.document!.entities['Surface002'], isNotNull);
      await reopened.joinSurfaces('Surface001', 'Surface002');
      expect(
        reopenedCad
            .runtime
            .document!
            .entities['Surface001']!
            .data['parameters']['joinedSurfaceIds'],
        contains('Surface002'),
      );
      await reopened.undo();
      expect(
        reopenedCad
            .runtime
            .document!
            .entities['Surface001']!
            .data['parameters']['joinedSurfaceIds'],
        isNull,
      );
      await reopened.redo();
      expect(
        reopenedCad
            .runtime
            .document!
            .entities['Surface001']!
            .data['parameters']['joinedSurfaceIds'],
        contains('Surface002'),
      );
      await reopened.unjoinSurfaces('Surface001', 'Surface002');
      expect(
        reopenedCad
            .runtime
            .document!
            .entities['Surface001']!
            .data['parameters']['joinedSurfaceIds'],
        isEmpty,
      );
      final health = reopened.surfaceHealth('Surface002');
      expect(health.valid, isTrue);
      expect(health.kernelOk, isTrue);
      expect(health.topologyOk, isTrue);
      expect(health.boundariesOk, isTrue);
      expect(health.readyForLoft, isTrue);
      await reopened.joinSurfaces('Surface001', 'Surface002');
      await reopenedCad.runtime.save(recordLifecycle: true);
      await reopenedCad.runtime.close();

      final finalCad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
        projectRepository: projects,
      );
      addTearDown(finalCad.dispose);
      await finalCad.runtime.open('project', projectDirectory);
      final finalController = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: DesktopCommandCoordinator(
          cad: finalCad,
          projects: ProjectManager.instance,
          repository: projects,
        ),
        runtime: finalCad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(repository: references),
        ),
      );
      addTearDown(finalController.dispose);
      await finalController.configureProject(
        projectId: 'project',
        projectDirectory: projectDirectory,
      );
      expect(finalCad.runtime.document!.entities['Surface002'], isNotNull);
      expect(finalCad.runtime.document!.entities['Edge002'], isNotNull);
      expect(
        finalCad
            .runtime
            .document!
            .entities['Surface001']!
            .data['parameters']['joinedSurfaceIds'],
        contains('Surface002'),
      );
      expect(
        finalCad
            .runtime
            .document!
            .entities['Surface002']!
            .data['parameters']['sourceSurfaceId'],
        'Surface001',
      );
    },
  );
}

final _planeReference = ReferenceEntity(
  id: 'plane-reference',
  projectId: 'project',
  name: 'Base Plane',
  geometry: const PlaneGeometry(Vec3(0, 0, 0), Vec3(0, 0, 1)),
  mode: ReferenceMode.staticReference,
  status: ReferenceStatus.valid,
  dna: const ReferenceDNA('plane', 'region', 'z0', 'hash'),
  analytics: const ReferenceAnalytics(
    precision: 1,
    rmsError: 0,
    maxDeviation: 0,
    confidence: 1,
    fitQuality: 1,
    areaUsed: 1,
    coverage: 1,
    pointCount: 3,
  ),
  recipe: const ReferenceRecipe('plane', {}, ['region']),
  version: 1,
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  dependencies: const ['region'],
  metadata: const {},
);

class _PlanarSurfaceKernel
    implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  final operations = <String>[];
  final surfaceOperations = <String>[];

  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'g130-test',
    name: 'G-130 planar kernel',
    version: '1',
    capabilities: KernelCapabilities({KernelCapability.planeSurface}),
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
  }) async {
    operations.add(operation);
    expect(parameters['profilePoints'], isA<List>());
    return ShapeHandle.reference(
      persistentId: persistentId,
      kernelId: descriptor.id,
      type: expectedType,
      fingerprint: '$operation:${operations.length}',
    );
  }

  @override
  Future<List<String>> validate(ShapeHandle handle, Set<String> checks) async =>
      const [];

  @override
  Future<KernelSurfaceOperationResult> executeSurfaceOperation(
    ShapeHandle surface,
    String operation,
    Map<String, dynamic> parameters, {
    required String projectId,
  }) async {
    surfaceOperations.add(operation);
    return KernelSurfaceOperationResult(
      supported: true,
      diagnostic: 'ok',
      result: ShapeHandle.reference(
        persistentId: '$projectId:$operation:${surfaceOperations.length}',
        kernelId: descriptor.id,
        type: CADShapeType.face,
        fingerprint: '$operation:${surfaceOperations.length}',
      ),
      undoToken: 'undo:${surfaceOperations.length}',
      redoToken: 'redo:${surfaceOperations.length}',
    );
  }

  @override
  Future<void> rollbackSurfaceOperation(String undoToken) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
