import 'dart:io';

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  test('preview keeps a hole and Create Surface blocks it', () async {
    final root = await Directory.systemTemp.createTemp('flcad_sk_p4c6_');
    addTearDown(() async => root.delete(recursive: true));
    final projects = ProjectRepository(
      storage: LocalStorageService(rootDirectory: root),
    );
    final directory = await projects.directoryFor('project');
    final references = ReferenceRepository(projects: projects);
    final kernel = _PreviewKernel();
    final kernels = KernelManager()..register(kernel, makeDefault: true);
    final cad = DesktopCadController(
      kernels: kernels,
      projects: ProjectManager.instance,
      projectRepository: projects,
    );
    addTearDown(cad.dispose);
    await cad.runtime.open('project', directory);
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
      projectDirectory: directory,
    );
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch();
    final api = controller.sketchApi!;
    api.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    api.builders.line.build(
      const SketchVector(10, 0),
      const SketchVector(10, 10),
    );
    api.builders.line.build(
      const SketchVector(10, 10),
      const SketchVector(0, 10),
    );
    api.builders.line.build(
      const SketchVector(0, 10),
      const SketchVector(0, 0),
    );
    api.builders.circle.build(const SketchVector(5, 5), 2);

    await controller.finishSketch();
    expect(controller.sketchReadyForSurface, isTrue);

    await controller.previewPlanarSurface();
    expect(controller.surfacePlan!.boundaryReport.loops, 2);
    expect(controller.surfacePlan!.boundaryReport.holes, 1);
    expect(controller.surfacePlan!.valid, isFalse);
    expect(controller.surfaceCadCreationAvailable, isFalse);
    expect(
      controller.surfaceCadCreationBlockReason,
      contains('holes and multiple regions'),
    );
    expect(cad.runtime.scene.find('surface-preview'), isNotNull);
    expect(kernel.operations, isEmpty);

    await controller.confirmSurface();
    expect(controller.error, contains('holes and multiple Sketch regions'));
    expect(kernel.operations, isEmpty);
    expect(
      cad.runtime.document!.entities.values.any(
        (entity) => entity.id == 'Surface001',
      ),
      isFalse,
    );
  });
}

class _PreviewKernel implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  final operations = <String>[];

  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'sk-p4c6-test',
    name: 'SK-P4C6 test kernel',
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
  }) async => KernelSurfaceOperationResult(
    supported: true,
    diagnostic: 'ok',
    result: ShapeHandle.reference(
      persistentId: '$projectId:$operation',
      kernelId: descriptor.id,
      type: CADShapeType.face,
      fingerprint: operation,
    ),
    undoToken: 'undo',
    redoToken: 'redo',
  );

  @override
  Future<void> rollbackSurfaceOperation(String undoToken) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
