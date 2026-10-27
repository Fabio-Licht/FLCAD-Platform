import 'dart:io';
import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dll = Platform.environment['FLCAD_SOURCE_OCC_DLL'];

  Future<
    ({
      Directory directory,
      DesktopCadController cad,
      OperationalReverseEngineeringController controller,
    })
  >
  openReal(Directory directory, String id) async {
    final projects = ProjectRepository(
      storage: LocalStorageService(rootDirectory: directory),
    );
    final adapter = OpenCascadeKernelAdapter(
      bridge: OpenCascadeFFI.load(path: dll!),
    );
    final kernels = KernelManager()..register(adapter, makeDefault: true);
    final cad = DesktopCadController(
      kernels: kernels,
      projects: ProjectManager.instance,
      projectRepository: projects,
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
    await cad.runtime.open(id, directory);
    await controller.configureProject(
      projectId: id,
      projectDirectory: directory,
    );
    return (directory: directory, cad: cad, controller: controller);
  }

  Future<List<double>> bounds(
    DesktopCadController cad,
    String featureId,
  ) async {
    final entity = cad.runtime.document!.entities[featureId]!;
    final shape = await cad.runtime.loadShape(entity.shape!);
    final presentation =
        (cad.kernels.active as BrepPresentationGeometryKernelAPI)
            .inspectBrepPresentation(shape);
    final raw = (await presentation)!['bounds'] as List;
    return raw.cast<num>().map((value) => value.toDouble()).toList();
  }

  Future<void> prepare(
    OperationalReverseEngineeringController controller,
  ) async {
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch();
    await controller.drawRectangle(
      const SketchVector(0, 0),
      const SketchVector(20, 10),
    );
    await controller.finishSketch();
  }

  Future<void> dragFirstEndpoint(
    OperationalReverseEngineeringController controller,
  ) async {
    final line =
        controller.sketchApi!.entity(controller.activeSketch!.entityIds.first)!
            as SketchLine;
    final start = SketchVector.fromJson(line.parameters['start']);
    final camera = CadCameraController()..resize(1000, 700);
    final pick = CadViewportPick(
      entityId: line.id,
      hit: MeshHit(
        triangleIndex: 0,
        point: Vector3(start.x, start.y, start.z),
        distance: 0,
      ),
    );
    controller.beginSketchEntityDrag(pick, const Offset(500, 350), camera);
    await controller.finishSketchEntityDrag(const Offset(560, 350), camera);
  }

  test(
    'Controller drag rebuilds a real OCCT Extrude and survives Undo Redo Save/Open',
    () async {
      if (dll == null) return;
      final directory = await Directory.systemTemp.createTemp(
        'sketch-drag-occ-',
      );
      final harness = await openReal(directory, 'sketch-drag-occ');
      addTearDown(() async {
        harness.controller.dispose();
        harness.cad.dispose();
        await directory.delete(recursive: true);
      });
      await prepare(harness.controller);
      harness.controller.selectExtrudeSource(
        harness.controller.activeSketch!.id,
      );
      await harness.controller.previewProfessionalExtrude(distance: 5);
      final featureId =
          harness.controller.professionalExtrudePreview!['id'] as String;
      await harness.controller.confirmProfessionalExtrude();
      final before = await bounds(harness.cad, featureId);

      await dragFirstEndpoint(harness.controller);
      final after = await bounds(harness.cad, featureId);
      expect(after, isNot(equals(before)));
      await harness.controller.undo();
      final undone = await bounds(harness.cad, featureId);
      expect(undone, equals(before));
      await harness.controller.redo();
      final redone = await bounds(harness.cad, featureId);
      expect(redone, equals(after));

      await harness.cad.runtime.save();
      await harness.cad.runtime.open('sketch-drag-occ', directory);
      await harness.controller.configureProject(
        projectId: 'sketch-drag-occ',
        projectDirectory: directory,
      );
      final reopened = await bounds(harness.cad, featureId);
      expect(reopened, equals(after));
    },
    skip: dll == null ? 'FLCAD_SOURCE_OCC_DLL is not set' : false,
  );

  test(
    'failed Extrude refresh rolls back the real Controller transaction',
    () async {
      if (dll == null) return;
      final directory = await Directory.systemTemp.createTemp(
        'sketch-drag-fault-',
      );
      final harness = await openReal(directory, 'sketch-drag-fault');
      addTearDown(() async {
        OperationalReverseEngineeringController.testFailureInjector = null;
        harness.controller.dispose();
        harness.cad.dispose();
        await directory.delete(recursive: true);
      });
      await prepare(harness.controller);
      harness.controller.selectExtrudeSource(
        harness.controller.activeSketch!.id,
      );
      await harness.controller.previewProfessionalExtrude(distance: 5);
      final featureId =
          harness.controller.professionalExtrudePreview!['id'] as String;
      await harness.controller.confirmProfessionalExtrude();
      final before = await bounds(harness.cad, featureId);
      var injected = false;
      OperationalReverseEngineeringController.testFailureInjector =
          (phase) async {
            if (!injected && phase == 'afterExtrudeRefresh') {
              injected = true;
              throw StateError('injected:afterExtrudeRefresh');
            }
          };
      await expectLater(
        dragFirstEndpoint(harness.controller),
        throwsStateError,
      );
      final restored = await bounds(harness.cad, featureId);
      expect(restored, equals(before));
      expect(
        harness.cad.runtime.read<String>('sketch.transaction.phase'),
        'rolledBack',
      );
    },
    skip: dll == null ? 'FLCAD_SOURCE_OCC_DLL is not set' : false,
  );

  test(
    'persistence boundary failure rolls back the real Controller transaction',
    () async {
      if (dll == null) return;
      final directory = await Directory.systemTemp.createTemp(
        'sketch-drag-persist-fault-',
      );
      final harness = await openReal(directory, 'sketch-drag-persist-fault');
      addTearDown(() async {
        OperationalReverseEngineeringController.testFailureInjector = null;
        harness.controller.dispose();
        harness.cad.dispose();
        await directory.delete(recursive: true);
      });
      await prepare(harness.controller);
      harness.controller.selectExtrudeSource(
        harness.controller.activeSketch!.id,
      );
      await harness.controller.previewProfessionalExtrude(distance: 5);
      final featureId =
          harness.controller.professionalExtrudePreview!['id'] as String;
      await harness.controller.confirmProfessionalExtrude();
      final before = await bounds(harness.cad, featureId);
      var injected = false;
      OperationalReverseEngineeringController.testFailureInjector =
          (phase) async {
            if (!injected && phase == 'afterSketchPersistence') {
              injected = true;
              throw StateError('injected:afterSketchPersistence');
            }
          };
      await expectLater(
        dragFirstEndpoint(harness.controller),
        throwsStateError,
      );
      final restored = await bounds(harness.cad, featureId);
      expect(restored, equals(before));
      expect(
        harness.cad.runtime.read<String>('sketch.transaction.phase'),
        'rolledBack',
      );
    },
    skip: dll == null ? 'FLCAD_SOURCE_OCC_DLL is not set' : false,
  );
}
