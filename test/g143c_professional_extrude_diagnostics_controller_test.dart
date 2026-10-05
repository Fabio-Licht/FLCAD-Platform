import 'dart:io';

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/professional_extrude/professional_extrude.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<(DesktopCadController, OperationalReverseEngineeringController)> open(
    Directory directory,
    String projectId,
  ) async {
    final projects = ProjectRepository(
      storage: LocalStorageService(rootDirectory: directory),
    );
    final kernels = KernelManager()
      ..register(_UnsupportedKernel(), makeDefault: true);
    final cad = DesktopCadController(
      kernels: kernels,
      projects: ProjectManager.instance,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    final controller = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
      referenceApi: ReferenceApi(
        engine: ReferenceEngine(
          repository: ReferenceRepository(projects: projects),
        ),
      ),
    );
    addTearDown(controller.dispose);
    addTearDown(cad.dispose);
    await cad.runtime.open(projectId, directory);
    await controller.configureProject(
      projectId: projectId,
      projectDirectory: directory,
    );
    return (cad, controller);
  }

  Future<OperationalReverseEngineeringController> openWithSketch(
    Directory directory,
    String projectId,
  ) async {
    final (_, controller) = await open(directory, projectId);
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch();
    await controller.drawRectangle(
      const SketchVector(0, 0),
      const SketchVector(2, 2),
    );
    return controller;
  }

  test(
    'no selected source reports a clear diagnostic before any kernel use',
    () async {
      final directory = await Directory.systemTemp.createTemp('g143c_none_');
      addTearDown(() => directory.delete(recursive: true));
      final (_, controller) = await open(directory, 'g143c-none');

      expect(controller.selectedExtrudeSource, isNull);
      expect(controller.canPreviewExtrude, isFalse);

      await expectLater(
        controller.previewProfessionalExtrude(),
        throwsA(isA<StateError>()),
      );
      expect(
        controller.error,
        'Select one Sketch or Surface to start Extrude.',
      );
    },
  );

  test('a valid Sketch is accepted as an Extrude source', () async {
    final directory = await Directory.systemTemp.createTemp('g143c_src_');
    addTearDown(() => directory.delete(recursive: true));
    final controller = await openWithSketch(directory, 'g143c-src');

    final sketchId = controller.activeSketch!.id;
    controller.selectExtrudeSource(sketchId);

    expect(controller.selectedExtrudeSource, isNotNull);
    expect(controller.selectedExtrudeSource!.id, sketchId);
    expect(controller.canPreviewExtrude, isTrue);
  });

  test('changing a parameter keeps a still-relevant diagnostic', () async {
    final directory = await Directory.systemTemp.createTemp('g143c_keep_');
    addTearDown(() => directory.delete(recursive: true));
    final controller = await openWithSketch(directory, 'g143c-keep');

    // A failed attempt publishes a diagnostic.
    controller.error = 'Solid / Cylinder exige um perfil fechado.';
    await controller.updateProfessionalExtrudePreview(distance: 25);

    // No preview yet, so the update is a no-op, and the diagnostic must remain
    // visible until a new attempt, a new selection, or Cancel.
    expect(controller.error, 'Solid / Cylinder exige um perfil fechado.');
  });

  test('selecting a new source clears the previous diagnostic', () async {
    final directory = await Directory.systemTemp.createTemp('g143c_sel_');
    addTearDown(() => directory.delete(recursive: true));
    final controller = await openWithSketch(directory, 'g143c-sel');

    controller.error = 'diagnostico antigo';
    controller.selectExtrudeSource(controller.activeSketch!.id);
    expect(controller.error, isNull);
  });

  test('Cancel clears the diagnostic and the transient preview', () async {
    final directory = await Directory.systemTemp.createTemp('g143c_cancel_');
    addTearDown(() => directory.delete(recursive: true));
    final controller = await openWithSketch(directory, 'g143c-cancel');

    controller.error = 'diagnostico pendente';
    controller.cancelProfessionalExtrude();
    expect(controller.error, isNull);
    expect(controller.professionalExtrudePreview, isNull);
  });

  test('a native/kernel failure surfaces through controller.error', () async {
    final directory = await Directory.systemTemp.createTemp('g143c_kern_');
    addTearDown(() => directory.delete(recursive: true));
    final controller = await openWithSketch(directory, 'g143c-kern');

    final sketchId = controller.activeSketch!.id;
    controller.selectExtrudeSource(sketchId);

    // The registered kernel does not implement WIRE/EXTRUDE, so the attempt
    // fails; the failure must be published instead of swallowed.
    await expectLater(
      controller.previewProfessionalExtrude(
        output: ProfessionalExtrudeOutput.surface,
      ),
      throwsA(anything),
    );
    expect(controller.error, isNotNull);
    expect(controller.error, isNotEmpty);
  });
}

class _UnsupportedKernel
    implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'g143c-unsupported',
    name: 'G-143C unsupported kernel',
    version: '1',
    capabilities: KernelCapabilities({}),
    vendor: 'FLCAD',
  );

  @override
  Future<KernelHealth> healthCheck() async =>
      KernelHealth(KernelHealthStatus.healthy, 'ok', DateTime(2000));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
