import 'dart:ffi';
import 'dart:io';

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final source = Platform.environment['FLCAD_REAL_STL'];
  final release = Platform.environment['FLCAD_RELEASE_DIR'];

  test(
    'real managed STL creates a durable Section and editable Sketch',
    () async {
      final setDllDirectory = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Utf16>),
            int Function(Pointer<Utf16>)
          >('SetDllDirectoryW');
      final dllDirectory = release!.toNativeUtf16();
      try {
        expect(setDllDirectory(dllDirectory), 1);
      } finally {
        calloc.free(dllDirectory);
      }
      final project = await Directory.systemTemp.createTemp(
        'reverse-real-stl-',
      );
      addTearDown(() => project.delete(recursive: true));
      final adapter = OpenCascadeKernelAdapter(
        bridge: OpenCascadeFFI.load(path: '$release\\flcad_opencascade.dll'),
      );
      final cad = DesktopCadController(
        kernels: KernelManager()..register(adapter, makeDefault: true),
        projects: ProjectManager.instance,
      );
      final projects = ProjectRepository(
        storage: LocalStorageService(rootDirectory: project),
      );
      final controller = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: DesktopCommandCoordinator(
          cad: cad,
          projects: ProjectManager.instance,
        ),
        runtime: cad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(
            repository: ReferenceRepository(projects: projects),
          ),
        ),
      );
      addTearDown(() async {
        controller.dispose();
        await cad.runtime.shutdown();
        cad.dispose();
        await adapter.unload();
      });
      await cad.runtime.open('reverse-real-stl', project);
      final imported = await cad.runtime.importManagedStl(
        source!,
        nativeBridgePath: '$release\\cad_occ_bridge.dll',
      );
      await controller.configureProject(
        projectId: 'reverse-real-stl',
        projectDirectory: project,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.yz);
      cad.runtime.select({imported.id});
      await controller.createSection();
      final section = controller.selectedSection!;
      expect((section.data['section'] as Map)['segments'], isNotEmpty);
      await controller.createSketchFromSelectedSection();
      expect(controller.activeSketch!.metadata['sourceSectionId'], section.id);
      expect(controller.sketchApi!.sketches, hasLength(1));
      expect(controller.stage, SketchSurfaceStage.sketchActive);
      expect(controller.sketchEntities, isNotEmpty);
      final sketch = controller.activeSketch!;
      expect(
        cad.runtime.document!.entities[sketch.id]!.data['sceneVisible'],
        isTrue,
        reason: 'A newly projected Section must enter editable Sketch mode',
      );
      expect(
        sketch.entityIds
            .map((id) => cad.runtime.document!.entities[id])
            .every((entity) => entity?.data['sceneVisible'] == true),
        isTrue,
      );
      // A Section-derived Sketch is a regular Sketch root for Hide/Show.
      await controller.toggleActiveSketchVisibility();
      expect(
        cad.runtime.document!.entities[sketch.id]!.data['sceneVisible'],
        isFalse,
      );
      await controller.toggleActiveSketchVisibility();
      expect(
        cad.runtime.document!.entities[sketch.id]!.data['sceneVisible'],
        isTrue,
      );
      final health = controller.sketchHealth;
      expect(health.readyForSurface, controller.sketchReadyForSurface);
      if (!health.readyForSurface) {
        expect(controller.previewPlanarSurface, throwsStateError);
        expect(cad.runtime.scene.find('surface-preview'), isNull);
      }
      expect(
        cad.runtime.document!.entities[section.id]!.data['sceneVisible'],
        isFalse,
      );
      await controller.persist();
      controller.detachProject();
      await cad.runtime.close();
      await cad.runtime.open('reverse-real-stl', project);
      await controller.configureProject(
        projectId: 'reverse-real-stl',
        projectDirectory: project,
      );
      expect(cad.runtime.document!.entities[imported.id], isNotNull);
      expect(cad.runtime.document!.entities[section.id], isNotNull);
      expect(controller.activeSketch!.metadata['sourceSectionId'], section.id);
      expect(controller.sketchApi!.sketches, hasLength(1));
      expect(controller.sketchEntities, isNotEmpty);
      expect(
        cad.runtime.document!.entities[section.id]!.data['sceneVisible'],
        isFalse,
      );
      await controller.toggleSourceSectionVisibility();
      expect(
        cad.runtime.document!.entities[section.id]!.data['sceneVisible'],
        isTrue,
      );
      await controller.undo();
      expect(
        cad.runtime.document!.entities[section.id]!.data['sceneVisible'],
        isFalse,
      );
      await controller.redo();
      expect(
        cad.runtime.document!.entities[section.id]!.data['sceneVisible'],
        isTrue,
      );
    },
    skip:
        !Platform.isWindows ||
        source == null ||
        release == null ||
        !File(source).existsSync(),
  );
}
