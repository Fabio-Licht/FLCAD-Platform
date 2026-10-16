import 'dart:io';

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flcad_mobile/features/projects/models/project.dart';
import 'package:flcad_mobile/features/projects/models/project_status.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  test(
    'New A → Exit A → New B uses a new identity on the same plane',
    () async {
      final harness = await _harness('sk-p4d-same-plane');
      final controller = harness.controller;
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final sketchA = controller.activeSketch!;
      final lineA = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(4, 0),
      );
      controller.selectedSketchEntityIds.add(lineA.id);
      await controller.finishSketch();
      expect(controller.sketchEditSessionActive, isFalse);
      expect(controller.stage, SketchSurfaceStage.sketchFinished);
      expect(controller.sketchApi!.engine.activeSketchId, isNull);
      expect(controller.lineCommandActive, isFalse);
      expect(controller.selectedSketchEntityIds, isEmpty);

      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final sketchB = controller.activeSketch!;
      expect(sketchB.id, isNot(sketchA.id));
      expect(controller.sketchApi!.engine.activeSketchId, sketchB.id);
      expect(sketchB.entityIds, isEmpty);
      expect(sketchA.entityIds, contains(lineA.id));
      expect(controller.selectedSketchEntityIds, isEmpty);
      expect(controller.sketchEntities, isEmpty);
    },
  );

  test('New A and New B on different planes stay independent', () async {
    final harness = await _harness('sk-p4d-planes');
    final controller = harness.controller;
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch(forceNew: true);
    final sketchA = controller.activeSketch!;
    final planeA = controller.activeSketchPlaneId;
    controller.sketchApi!.builders.line.build(
      const SketchVector(1, 0),
      const SketchVector(2, 0),
    );
    await controller.finishSketch();

    controller.selectWorldSketchPlane(SketchPlaneType.yz);
    await controller.openSketch(forceNew: true);
    final sketchB = controller.activeSketch!;
    expect(sketchB.id, isNot(sketchA.id));
    expect(controller.activeSketchPlaneId, isNot(planeA));
    expect(sketchB.entityIds, isEmpty);
    expect(controller.activeSketchPlane!.normal.x.abs(), closeTo(1, 1e-12));
  });

  test('Edit A → Exit → New C does not resume A', () async {
    final harness = await _harness('sk-p4d-edit-then-new');
    final controller = harness.controller;
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch(forceNew: true);
    final sketchA = controller.activeSketch!;
    final lineA = controller.sketchApi!.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(3, 0),
    );
    await controller.finishSketch();

    await controller.reopenSketchForEditing(sketchA.id);
    expect(controller.activeSketch!.id, sketchA.id);
    expect(controller.sketchEditSessionActive, isTrue);
    expect(controller.sketchApi!.engine.activeSketchId, sketchA.id);
    await controller.finishSketch();

    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch(forceNew: true);
    final sketchC = controller.activeSketch!;
    expect(sketchC.id, isNot(sketchA.id));
    expect(sketchC.entityIds, isEmpty);
    expect(sketchA.entityIds, contains(lineA.id));
  });

  test(
    'Exit with an active tool clears the tool and keeps the Sketch',
    () async {
      final harness = await _harness('sk-p4d-exit-tool');
      final controller = harness.controller;
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final sketch = controller.activeSketch!;
      controller.beginLineCommand();
      controller.previewPoints = const [SketchVector(0, 0)];
      expect(controller.lineCommandActive, isTrue);
      await controller.finishSketch();
      expect(controller.lineCommandActive, isFalse);
      expect(controller.previewPoints, isEmpty);
      expect(controller.sketchEditSessionActive, isFalse);
      expect(
        controller.sketchApi!.sketches.any((item) => item.id == sketch.id),
        isTrue,
      );
    },
  );

  test('Exit with Preview Surface ends the edit session', () async {
    final harness = await _harness('sk-p4d-exit-preview');
    final controller = harness.controller;
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch(forceNew: true);
    await controller.drawRectangle(
      const SketchVector(0, 0),
      const SketchVector(4, 4),
    );
    await controller.previewPlanarSurface();
    expect(controller.surfacePreviewActive, isTrue);
    expect(controller.stage, SketchSurfaceStage.surfacePreview);
    await controller.finishSketch();
    expect(controller.sketchEditSessionActive, isFalse);
    expect(controller.stage, SketchSurfaceStage.sketchFinished);
    expect(controller.surfacePreviewActive, isFalse);
    expect(controller.sketchApi!.engine.activeSketchId, isNull);

    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch(forceNew: true);
    expect(controller.activeSketch!.entityIds, isEmpty);
    expect(controller.surfacePreviewActive, isFalse);
  });

  test('Escape cancels the tool without ending the Sketch session', () async {
    final harness = await _harness('sk-p4d-esc');
    final controller = harness.controller;
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch(forceNew: true);
    final id = controller.activeSketch!.id;
    controller.beginLineCommand();
    controller.previewPoints = const [SketchVector(1, 1)];
    controller.cancelPendingSketchOperation();
    expect(controller.sketchEditSessionActive, isTrue);
    expect(controller.activeSketch!.id, id);
    expect(controller.stage, SketchSurfaceStage.sketchActive);
    expect(controller.sketchApi!.engine.activeSketchId, id);
  });

  test(
    'Edit restores the Sketch support plane, not a leftover plane',
    () async {
      final harness = await _harness('sk-p4d-edit-plane');
      final controller = harness.controller;
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final sketchA = controller.activeSketch!;
      final planeA = controller.activeSketchPlaneId;
      await controller.finishSketch();

      controller.selectWorldSketchPlane(SketchPlaneType.yz);
      await controller.openSketch(forceNew: true);
      expect(controller.activeSketchPlaneId, isNot(planeA));
      await controller.finishSketch();

      await controller.reopenSketchForEditing(sketchA.id);
      expect(controller.activeSketch!.id, sketchA.id);
      expect(controller.activeSketchPlaneId, planeA);
    },
  );

  test(
    'Save/Open keeps multiple Sketches; Explorer reopens one explicitly',
    () async {
      final harness = await _harness('sk-p4d-save-open');
      final controller = harness.controller;
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final first = controller.activeSketch!;
      controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(2, 0),
      );
      await controller.finishSketch();
      controller.selectWorldSketchPlane(SketchPlaneType.yz);
      await controller.openSketch(forceNew: true);
      final second = controller.activeSketch!;
      controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(0, 3),
      );
      await controller.finishSketch();
      await controller.saveProject();

      final reopened = await _reopen(harness);
      addTearDown(reopened.cad.dispose);
      addTearDown(reopened.controller.dispose);
      expect(
        reopened.controller.sketchApi!.sketches.map((item) => item.id),
        containsAll([first.id, second.id]),
      );
      expect(reopened.controller.sketchEditSessionActive, isFalse);

      await reopened.controller.reopenSketchForEditing(first.id);
      expect(reopened.controller.activeSketch!.id, first.id);
      expect(reopened.controller.sketchApi!.engine.activeSketchId, first.id);
      expect(reopened.controller.sketchEntities, hasLength(1));
    },
  );

  test(
    'New Sketch after Undo/Redo does not reuse the previous identity',
    () async {
      final harness = await _harness('sk-p4d-undo');
      final controller = harness.controller;
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final sketchA = controller.activeSketch!;
      final lineA = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(5, 0),
      );
      await controller.finishSketch();
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final sketchB = controller.activeSketch!;
      expect(sketchB.id, isNot(sketchA.id));
      await controller.undo();
      expect(
        controller.sketchApi!.sketches.any((item) => item.id == sketchA.id),
        isTrue,
      );
      expect(controller.sketchApi!.entity(lineA.id), isA<SketchLine>());
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final sketchC = controller.activeSketch!;
      expect(sketchC.id, isNot(sketchA.id));
      expect(sketchC.entityIds, isEmpty);
    },
  );

  test(
    'openSketch without an explicit Sketch id does not invent Edit',
    () async {
      final harness = await _harness('sk-p4d-edit-contract');
      final controller = harness.controller;
      await expectLater(
        controller.reopenSketchForEditing('sketch:missing'),
        throwsA(isA<StateError>()),
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final created = controller.activeSketch!.id;
      await controller.finishSketch();
      final count = controller.sketchApi!.sketches.length;
      await controller.reopenSketchForEditing(created);
      expect(controller.activeSketch!.id, created);
      expect(controller.sketchApi!.sketches, hasLength(count));
    },
  );

  test('rapid Exit → New reentry keeps independent sessions', () async {
    final harness = await _harness('sk-p4d-rapid');
    final controller = harness.controller;
    final ids = <String>[];
    for (var index = 0; index < 4; index++) {
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final id = controller.activeSketch!.id;
      expect(ids, isNot(contains(id)));
      ids.add(id);
      controller.sketchApi!.builders.line.build(
        SketchVector(index.toDouble(), 0),
        SketchVector(index + 1.0, 0),
      );
      await controller.finishSketch();
      expect(controller.sketchEditSessionActive, isFalse);
    }
    expect(ids.toSet(), hasLength(4));
    expect(
      controller.sketchApi!.sketches.map((item) => item.id),
      containsAll(ids),
    );
  });

  test('document Explorer still lists finished Sketch roots', () async {
    final harness = await _harness('sk-p4d-explorer');
    final controller = harness.controller;
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch(forceNew: true);
    final id = controller.activeSketch!.id;
    await controller.finishSketch();
    final root = harness.cad.runtime.document!.entities[id];
    expect(root, isNotNull);
    expect(root!.kind, CadDocumentEntityKind.sketch);
    expect(root.data['sketch'], isA<Map>());
  });

  test(
    'Sketch edit isolates sibling presentation without changing document visibility',
    () async {
      final harness = await _harness('sk-p4e-isolation');
      final controller = harness.controller;
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final first = controller.activeSketch!;
      final firstLine = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(2, 0),
      );
      await controller.finishSketch();
      expect(harness.cad.runtime.scene.find(first.id)!.visible, isTrue);

      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final second = controller.activeSketch!;
      expect(harness.cad.runtime.scene.find(first.id)!.visible, isFalse);
      expect(harness.cad.runtime.scene.find(firstLine.id)!.visible, isFalse);
      expect(
        harness.cad.runtime.document!.entities[first.id]!.data['sceneVisible'],
        isTrue,
      );
      expect(harness.cad.runtime.scene.find(second.id)!.visible, isTrue);
      await controller.finishSketch();
      expect(harness.cad.runtime.scene.find(first.id)!.visible, isTrue);
      expect(harness.cad.runtime.scene.find(second.id)!.visible, isTrue);

      await harness.cad.runtime.setEntityVisibility(first.id, false);
      expect(
        harness.cad.runtime.document!.entities[first.id]!.data['sceneVisible'],
        isFalse,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      expect(harness.cad.runtime.scene.find(first.id)!.visible, isFalse);
      await controller.finishSketch();
      expect(harness.cad.runtime.scene.find(first.id)!.visible, isFalse);
    },
  );
}

typedef _Harness = ({
  Directory directory,
  DesktopCadController cad,
  OperationalReverseEngineeringController controller,
  ProjectRepository projects,
  ProjectManager projectManager,
});

Future<_Harness> _harness(String name) async {
  final directory = await Directory.systemTemp.createTemp('${name}_');
  addTearDown(() => directory.delete(recursive: true));
  final projects = ProjectRepository(
    storage: LocalStorageService(rootDirectory: directory),
  );
  final projectManager = ProjectManager(repository: projects);
  await projectManager.open(
    Project(
      id: name,
      name: name,
      client: 'SK-P4D',
      description: 'Sketch lifecycle',
      createdAt: DateTime(2020),
      status: ProjectStatus.created,
    ),
  );
  final kernels = KernelManager()..register(_Kernel(), makeDefault: true);
  final cad = DesktopCadController(kernels: kernels, projects: projectManager);
  addTearDown(cad.dispose);
  final commands = DesktopCommandCoordinator(
    cad: cad,
    projects: projectManager,
    repository: projects,
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
  await cad.runtime.open(name, directory);
  await controller.configureProject(
    projectId: name,
    projectDirectory: directory,
  );
  await commands.refreshContext();
  return (
    directory: directory,
    cad: cad,
    controller: controller,
    projects: projects,
    projectManager: projectManager,
  );
}

Future<
  ({
    DesktopCadController cad,
    OperationalReverseEngineeringController controller,
  })
>
_reopen(_Harness harness) async {
  final project = await harness.projects.findById(
    harness.controller.configuredProjectId!,
  );
  final projectManager = ProjectManager(repository: harness.projects);
  await projectManager.open(project!);
  final kernels = KernelManager()..register(_Kernel(), makeDefault: true);
  final cad = DesktopCadController(kernels: kernels, projects: projectManager);
  final commands = DesktopCommandCoordinator(
    cad: cad,
    projects: projectManager,
    repository: harness.projects,
  );
  final controller = OperationalReverseEngineeringController(
    recognition: ProfessionalRecognitionApi(),
    commands: commands,
    runtime: cad.runtime,
    referenceApi: ReferenceApi(
      engine: ReferenceEngine(
        repository: ReferenceRepository(projects: harness.projects),
      ),
    ),
  );
  await cad.runtime.open(project.id, harness.directory);
  await controller.configureProject(
    projectId: project.id,
    projectDirectory: harness.directory,
  );
  await commands.refreshContext();
  return (cad: cad, controller: controller);
}

class _Kernel implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'sk-p4d-test',
    name: 'SK-P4D test kernel',
    version: '1',
    capabilities: KernelCapabilities({KernelCapability.planeSurface}),
    vendor: 'FLCAD',
  );

  @override
  Future<KernelHealth> healthCheck() async =>
      KernelHealth(KernelHealthStatus.healthy, 'ok', DateTime(2000));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
