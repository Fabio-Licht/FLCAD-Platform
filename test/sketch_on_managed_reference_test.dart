import 'dart:io';

import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/managed_cad_reference.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';
import 'package:flcad_mobile/core/professional_extrude/professional_extrude.dart';
import 'package:flcad_mobile/core/professional_revolve/professional_revolve.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final caf = Platform.environment['FLCAD_CAD_ASSET_FS_DLL']!;
  final occ = Platform.environment['FLCAD_SOURCE_OCC_DLL']!;
  final bridge = Platform.environment['FLCAD_SOURCE_BRIDGE_DLL']!;
  final fixture = Platform.environment['FLCAD_STEP_FIXTURE_EXE']!;
  late Directory root, source, project;
  late OpenCascadeKernelAdapter adapter;
  late DesktopCadController cad;
  late OperationalReverseEngineeringController controller;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('managed-reference-sketch-');
    source = await Directory(p.join(root.path, 'source')).create();
    project = await Directory(p.join(root.path, 'project')).create();
    final generated = await Process.run(fixture, [caf, bridge, source.path]);
    expect(
      generated.exitCode,
      0,
      reason: '${generated.stdout}\n${generated.stderr}',
    );
    adapter = OpenCascadeKernelAdapter(bridge: OpenCascadeFFI.load(path: occ));
    final projects = ProjectRepository(
      storage: LocalStorageService(rootDirectory: root),
    );
    cad = DesktopCadController(
      kernels: KernelManager()..register(adapter, makeDefault: true),
      projects: ProjectManager.instance,
      projectRepository: projects,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
      repository: projects,
    );
    controller = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
      referenceApi: ReferenceApi(
        engine: ReferenceEngine(
          repository: ReferenceRepository(projects: projects),
        ),
      ),
    );
    await cad.runtime.open('managed-reference-sketch', project);
    await controller.configureProject(
      projectId: 'managed-reference-sketch',
      projectDirectory: project,
    );
  });

  tearDown(() async {
    controller.dispose();
    await cad.runtime.shutdown();
    cad.dispose();
    await adapter.unload();
    await root.delete(recursive: true);
  });

  test(
    'STEP/BREP references drive oriented Sketches and independent rectangle/circle Extrudes',
    () async {
      final step = await cad.runtime.importManagedStep(
        p.join(source.path, 'part-0.step'),
        nativeBridgePath: bridge,
      );
      final stepReferenceId = await cad.runtime.createManagedCadPlaneReference(
        sourceEntityId: step.id,
        presentationTriangleId: 1,
      );
      final stepReference = _reference(cad, stepReferenceId);
      expect(nativeSceneUnsupportedReason(cad.runtime.scene, style: 0), isNull);

      controller.selectSketchSupport(stepReferenceId);
      await controller.openSketch();
      final rectangleSketch = controller.activeSketch!;
      _expectFrame(rectangleSketch, stepReference, stepReferenceId);
      await controller.drawRectangle(
        const SketchVector(-5, -3),
        const SketchVector(5, 3),
      );
      expect(controller.error, isNull);
      expect(rectangleSketch.entityIds, hasLength(4));
      await controller.undo();
      expect(controller.activeSketch!.entityIds, isEmpty);
      await controller.redo();
      expect(controller.activeSketch!.entityIds, hasLength(4));
      final rectangleProfileId = controller.activeSketch!.entityIds.first;
      final circleProfile = controller.sketchApi!.builders.circle.build(
        const SketchVector(12, 0),
        2,
      );
      await controller.finishSketch();
      expect(nativeSceneUnsupportedReason(cad.runtime.scene, style: 0), isNull);
      final rectangleSolid = await _extrudeSketchProfile(
        controller,
        rectangleSketch,
        rectangleProfileId,
        8,
      );
      await cad.runtime.undoDocument();
      expect(cad.runtime.document!.entities[rectangleSolid], isNull);
      await cad.runtime.redoDocument();
      expect(
        cad.runtime.document!.entities[rectangleSolid]?.kind,
        CadDocumentEntityKind.solid,
      );
      final stepCircleSolid = await _extrudeSketchProfile(
        controller,
        rectangleSketch,
        circleProfile.id,
        4,
      );

      final stepAssets = ManagedStepAssets.fromJson(
        Map<String, dynamic>.from(step.data['managedStepAssets'] as Map),
      );
      final brepPath = p.join(
        project.path,
        'CAD',
        'Assets',
        'v1',
        stepAssets.shape.value,
        CadAssetFile.brep.relativePath,
      );
      final brep = await cad.runtime.importManagedBrep(
        brepPath,
        name: 'source-brep',
        nativeBridgePath: bridge,
      );
      final brepReferenceId = await cad.runtime.createManagedCadPlaneReference(
        sourceEntityId: brep.id,
        presentationTriangleId: 1,
      );
      final brepReference = _reference(cad, brepReferenceId);
      controller.selectSketchSupport(brepReferenceId);
      await controller.openSketch();
      final circleSketch = controller.activeSketch!;
      _expectFrame(circleSketch, brepReference, brepReferenceId);
      controller.sketchApi!.builders.circle.build(const SketchVector(0, 0), 4);
      await controller.finishSketch();
      final circleSolid = await _extrudeActiveSketch(controller, 6);

      for (final id in [rectangleSolid, stepCircleSolid, circleSolid]) {
        final solid = cad.runtime.document!.entities[id]!;
        expect(solid.kind, CadDocumentEntityKind.solid);
        expect(solid.shape, isNotNull);
        expect(solid.data['group'], 'Solids');
        expect((solid.data['extrudeFeature'] as Map)['status'], 'committed');
      }
      expect(
        cad.runtime.document!.entities[rectangleSolid]!.shape!.persistentId,
        isNot(step.id),
      );
      expect(
        cad.runtime.document!.entities[circleSolid]!.shape!.persistentId,
        isNot(brep.id),
      );

      await cad.runtime.save();
      final scratch = await Directory(p.join(root.path, 'scratch')).create();
      controller.detachProject();
      await cad.runtime.open('scratch', scratch);
      await cad.runtime.open('managed-reference-sketch', project);
      for (final id in [rectangleSolid, stepCircleSolid, circleSolid]) {
        expect(
          cad.runtime.document!.entities[id]?.kind,
          CadDocumentEntityKind.solid,
        );
        expect(cad.runtime.document!.entities[id]?.shape, isNotNull);
        expect(cad.runtime.scene.find(id), isNotNull);
      }
      expect(
        ((cad.runtime.document!.entities[rectangleSolid]!.data['extrudeFeature']
                as Map)['contract']
            as Map)['profileEntityId'],
        rectangleProfileId,
      );
      expect(
        ((cad
                    .runtime
                    .document!
                    .entities[stepCircleSolid]!
                    .data['extrudeFeature']
                as Map)['contract']
            as Map)['profileEntityId'],
        circleProfile.id,
      );
      final reopenedSketch = Sketch.fromJson(
        Map<String, dynamic>.from(
          cad.runtime.document!.entities[rectangleSketch.id]!.data['sketch']
              as Map,
        ),
      );
      _expectFrame(reopenedSketch, stepReference, stepReferenceId);
    },
  );

  test(
    'multiple closed Sketch profiles create a transient multi-loop preview',
    () async {
      final step = await cad.runtime.importManagedStep(
        p.join(source.path, 'part-0.step'),
        nativeBridgePath: bridge,
      );
      final supportId = await cad.runtime.createManagedCadPlaneReference(
        sourceEntityId: step.id,
        presentationTriangleId: 1,
      );
      controller.selectSketchSupport(supportId);
      await controller.openSketch();
      final outer = controller.sketchApi!.builders.circle.build(
        const SketchVector(0, 0),
        8,
      );
      final voidProfile = controller.sketchApi!.builders.circle.build(
        const SketchVector(0, 0),
        3,
      );
      final island = controller.sketchApi!.builders.circle.build(
        const SketchVector(20, 0),
        4,
      );
      await controller.finishSketch();

      final sketch = controller.sketchApi!.sketches.single;
      final outerHit = sketch.coordinates.localToGlobal(
        const SketchVector(8, 0),
      );
      // Native picking may report the Sketch owner. The hit resolves to the
      // individual circle so the first Extrude selection owns a profile wire.
      expect(
        controller.selectExtrudeSourceFromViewport(
          sketch.id,
          worldHit: outerHit.toJson(),
        ),
        isTrue,
      );
      expect(controller.selectedExtrudeProfileEntityIds, [outer.id]);
      controller.clearExtrudeSource();

      // Tree selection feeds the same transient profile list without the
      // launcher rewriting document selection; viewport capture appends to it.
      cad.runtime.select({outer.id});
      expect(controller.addSelectedExtrudeProfiles(), 1);
      expect(cad.runtime.selection, {outer.id});
      expect(
        controller.selectExtrudeSourceFromViewport(
          voidProfile.id,
          append: true,
        ),
        isTrue,
      );
      expect(
        controller.selectExtrudeSourceFromViewport(island.id, append: true),
        isTrue,
      );
      expect(controller.selectedExtrudeProfileEntityIds, [
        outer.id,
        voidProfile.id,
        island.id,
      ]);
      expect(controller.addExtrudeProfile(island.id), isFalse);
      expect(controller.removeExtrudeProfile(voidProfile.id), isTrue);
      expect(controller.addExtrudeProfile(voidProfile.id), isTrue);

      final entitiesBefore = cad.runtime.document!.entities.length;
      await controller.previewProfessionalExtrude(
        distance: 6,
        draftAngleDegrees: 3,
        extent: ProfessionalExtrudeExtent.symmetric,
      );
      final preview = controller.professionalExtrudePreview!;
      expect(preview['multiProfilePreview'], isTrue);
      expect(preview['profileEntityIds'], [
        outer.id,
        island.id,
        voidProfile.id,
      ]);
      expect((preview['handle'] as Map)['type'], 'compound');
      expect(preview['profileWireIds'], hasLength(3));
      expect(
        (preview['profileWireIds'] as List).any((id) => id == sketch.id),
        isFalse,
      );
      final previewId = preview['id'] as String;
      expect(cad.runtime.document!.entities.length, entitiesBefore);
      expect(cad.runtime.scene.find('preview:$previewId'), isNotNull);
      expect(nativeSceneUnsupportedReason(cad.runtime.scene, style: 0), isNull);
      await controller.updateProfessionalExtrudePreview(distance: 9);
      expect(
        ((controller.professionalExtrudePreview!['contract'] as Map)['distance']
            as num),
        9,
      );
      expect(controller.selectedExtrudeProfileGroups, hasLength(3));
      await controller.confirmProfessionalExtrude();
      expect(controller.professionalExtrudePreview, isNull);
      expect(cad.runtime.scene.find('preview:$previewId'), isNull);
      final committed = cad.runtime.document!.entities[previewId]!;
      expect(committed.kind, CadDocumentEntityKind.solid);
      final feature = Map<String, dynamic>.from(
        committed.data['extrudeFeature'] as Map,
      );
      expect(feature['status'], 'committed');
      expect(feature['profileSelectionEntityIds'], [
        outer.id,
        island.id,
        voidProfile.id,
      ]);
      final committedContract = Map<String, dynamic>.from(
        feature['contract'] as Map,
      );
      expect(committedContract['profileEntityIds'], [
        outer.id,
        island.id,
        voidProfile.id,
      ]);
      final documentCountAfterApply = cad.runtime.document!.entities.length;
      await controller.confirmProfessionalExtrude();
      expect(cad.runtime.document!.entities.length, documentCountAfterApply);

      await cad.runtime.undoDocument();
      expect(cad.runtime.document!.entities[previewId], isNull);
      await cad.runtime.redoDocument();
      expect(
        cad.runtime.document!.entities[previewId]?.shape?.type,
        CADShapeType.compound,
      );

      await cad.runtime.save();
      final scratch = await Directory(
        p.join(root.path, 'multi-scratch'),
      ).create();
      controller.detachProject();
      await cad.runtime.open('multi-scratch', scratch);
      await cad.runtime.open('managed-reference-sketch', project);
      await controller.configureProject(
        projectId: 'managed-reference-sketch',
        projectDirectory: project,
      );
      await controller.reenterProfessionalExtrude(previewId);
      expect(
        controller.professionalExtrudePreview?['multiProfilePreview'],
        isTrue,
      );
      expect(controller.selectedExtrudeProfileGroups, hasLength(3));
      controller.cancelProfessionalExtrude();

      final sourceEntity = cad.runtime.document!.entities[sketch.id]!;
      final orphanedData = Map<String, dynamic>.from(sourceEntity.data);
      final orphanedSketch = Map<String, dynamic>.from(
        orphanedData['sketch'] as Map,
      );
      orphanedSketch['entityIds'] = List<String>.from(
        orphanedSketch['entityIds'] as List,
      )..remove(voidProfile.id);
      orphanedData['sketch'] = orphanedSketch;
      await cad.runtime.mutate(
        command: 'test.multi-profile-removed',
        upsert: [
          CadDocumentEntity(
            id: sourceEntity.id,
            kind: sourceEntity.kind,
            shape: sourceEntity.shape,
            mesh: sourceEntity.mesh,
            data: orphanedData,
          ),
        ],
      );
      await expectLater(
        controller.reenterProfessionalExtrude(previewId),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('órfão'),
          ),
        ),
      );
    },
  );

  test(
    'open Sketch wires create walls but solids require a closed profile',
    () async {
      final step = await cad.runtime.importManagedStep(
        p.join(source.path, 'part-0.step'),
        nativeBridgePath: bridge,
      );
      final supportId = await cad.runtime.createManagedCadPlaneReference(
        sourceEntityId: step.id,
        presentationTriangleId: 1,
      );
      controller.selectSketchSupport(supportId);
      await controller.openSketch();
      final firstLine = controller.sketchApi!.builders.line.build(
        const SketchVector(-5, -3),
        const SketchVector(0, -3),
      );
      final secondLine = controller.sketchApi!.builders.line.build(
        const SketchVector(0, -3),
        const SketchVector(5, -3),
      );
      final lines = [firstLine.id, secondLine.id];
      await controller.finishSketch();

      expect(controller.selectExtrudeSourceFromViewport(lines[0]), isTrue);
      await controller.previewProfessionalExtrude(
        distance: 4,
        output: ProfessionalExtrudeOutput.surface,
      );
      expect(controller.professionalExtrudePreview, isNotNull);
      expect(
        controller.professionalExtrudePreview!['multiProfilePreview'],
        isNot(true),
      );
      expect(
        (controller.professionalExtrudePreview!['contract'] as Map)['output'],
        ProfessionalExtrudeOutput.surface.name,
      );
      controller.cancelProfessionalExtrude();

      expect(controller.selectExtrudeSourceFromViewport(lines[0]), isTrue);
      await expectLater(
        controller.previewProfessionalExtrude(distance: 4),
        throwsStateError,
      );
      expect(controller.error, contains('Solid / Cylinder'));
      expect(controller.professionalExtrudePreview, isNull);
      expect(cad.runtime.scene.find('preview:Extrude001'), isNull);
    },
  );

  test(
    'two disconnected open wires create one transient multi wall preview',
    () async {
      final step = await cad.runtime.importManagedStep(
        p.join(source.path, 'part-0.step'),
        nativeBridgePath: bridge,
      );
      final supportId = await cad.runtime.createManagedCadPlaneReference(
        sourceEntityId: step.id,
        presentationTriangleId: 1,
      );
      controller.selectSketchSupport(supportId);
      await controller.openSketch();
      final first = controller.sketchApi!.builders.line.build(
        const SketchVector(-8, -2),
        const SketchVector(-2, -2),
      );
      final second = controller.sketchApi!.builders.line.build(
        const SketchVector(2, 2),
        const SketchVector(8, 2),
      );
      await controller.finishSketch();

      expect(controller.selectExtrudeSourceFromViewport(first.id), isTrue);
      expect(
        controller.selectExtrudeSourceFromViewport(second.id, append: true),
        isTrue,
      );
      await controller.previewProfessionalExtrude(
        distance: 7,
        output: ProfessionalExtrudeOutput.surface,
        extent: ProfessionalExtrudeExtent.symmetric,
      );

      final preview = controller.professionalExtrudePreview!;
      expect(preview['multiProfilePreview'], isTrue);
      expect((preview['handle'] as Map)['type'], 'compound');
      expect(preview['profileWireIds'], hasLength(2));
      controller.cancelProfessionalExtrude();
      expect(controller.professionalExtrudePreview, isNull);
    },
  );

  test(
    'Extrude click selects an entire connected loop and Ctrl adds a loop',
    () async {
      final step = await cad.runtime.importManagedStep(
        p.join(source.path, 'part-0.step'),
        nativeBridgePath: bridge,
      );
      final supportId = await cad.runtime.createManagedCadPlaneReference(
        sourceEntityId: step.id,
        presentationTriangleId: 1,
      );
      controller.selectSketchSupport(supportId);
      await controller.openSketch();
      await controller.drawRectangle(
        const SketchVector(-8, -3),
        const SketchVector(-2, 3),
      );
      await controller.drawRectangle(
        const SketchVector(2, -3),
        const SketchVector(8, 3),
      );
      final lines = List<String>.from(controller.activeSketch!.entityIds);
      await controller.finishSketch();

      expect(controller.selectExtrudeSourceFromViewport(lines.first), isTrue);
      expect(controller.selectedExtrudeProfileGroups, hasLength(1));
      expect(controller.selectedExtrudeProfileGroups.single, hasLength(4));
      expect(
        controller.extrudeProfileGroupLabel(
          controller.selectedExtrudeProfileGroups.single,
        ),
        contains('loop fechado'),
      );
      expect(
        controller.selectExtrudeSourceFromViewport(lines[4], append: true),
        isTrue,
      );
      expect(controller.selectedExtrudeProfileGroups, hasLength(2));
      expect(
        controller.selectedExtrudeProfileGroups.expand((group) => group),
        hasLength(8),
      );
      expect(
        controller.selectExtrudeSourceFromViewport(lines[4], append: true),
        isTrue,
      );
      expect(controller.selectedExtrudeProfileGroups, hasLength(1));
    },
  );

  test(
    'changing Solid validation to Surface clears its stale diagnostic',
    () async {
      final step = await cad.runtime.importManagedStep(
        p.join(source.path, 'part-0.step'),
        nativeBridgePath: bridge,
      );
      final supportId = await cad.runtime.createManagedCadPlaneReference(
        sourceEntityId: step.id,
        presentationTriangleId: 1,
      );
      controller.selectSketchSupport(supportId);
      await controller.openSketch();
      final line = controller.sketchApi!.builders.line.build(
        const SketchVector(-3, 0),
        const SketchVector(3, 0),
      );
      await controller.finishSketch();
      expect(controller.selectExtrudeSourceFromViewport(line.id), isTrue);
      await expectLater(
        controller.previewProfessionalExtrude(distance: 4),
        throwsStateError,
      );
      expect(controller.error, contains('Solid / Cylinder'));
      controller.clearProfessionalExtrudeDiagnostic();
      expect(controller.error, isNull);
      await controller.previewProfessionalExtrude(
        distance: 4,
        output: ProfessionalExtrudeOutput.surface,
      );
      expect(controller.professionalExtrudePreview, isNotNull);
      controller.cancelProfessionalExtrude();
    },
  );

  test(
    'mixed open and closed wall profiles are rejected before OCCT',
    () async {
      final step = await cad.runtime.importManagedStep(
        p.join(source.path, 'part-0.step'),
        nativeBridgePath: bridge,
      );
      final supportId = await cad.runtime.createManagedCadPlaneReference(
        sourceEntityId: step.id,
        presentationTriangleId: 1,
      );
      controller.selectSketchSupport(supportId);
      await controller.openSketch();
      final circle = controller.sketchApi!.builders.circle.build(
        const SketchVector(0, 0),
        3,
      );
      final line = controller.sketchApi!.builders.line.build(
        const SketchVector(6, 0),
        const SketchVector(10, 0),
      );
      await controller.finishSketch();

      expect(controller.selectExtrudeSourceFromViewport(circle.id), isTrue);
      expect(
        controller.selectExtrudeSourceFromViewport(line.id, append: true),
        isTrue,
      );
      await expectLater(
        controller.previewProfessionalExtrude(
          distance: 5,
          output: ProfessionalExtrudeOutput.surface,
        ),
        throwsStateError,
      );
      expect(controller.error, contains('seleção é mista'));
      expect(controller.professionalExtrudePreview, isNull);
    },
  );

  test(
    'managed Sketch Draft previews, persists, reopens and cancels without residue',
    () async {
      final step = await cad.runtime.importManagedStep(
        p.join(source.path, 'part-0.step'),
        nativeBridgePath: bridge,
      );
      final supportId = await cad.runtime.createManagedCadPlaneReference(
        sourceEntityId: step.id,
        presentationTriangleId: 1,
      );
      controller.selectSketchSupport(supportId);
      await controller.openSketch();
      final sketch = controller.activeSketch!;
      await controller.drawRectangle(
        const SketchVector(-5, -3),
        const SketchVector(5, 3),
      );
      final profileId = sketch.entityIds.first;
      await controller.finishSketch();
      _selectClosedSketchProfile(controller, sketch, profileId);
      final selectionBeforePreview = Set<String>.from(cad.runtime.selection);

      await controller.previewProfessionalExtrude(
        distance: 8,
        draftAngleDegrees: 5,
      );
      final positivePreview = controller.professionalExtrudePreview!;
      final positiveId = positivePreview['id'] as String;
      expect(
        ((positivePreview['contract'] as Map)['draftAngleDegrees'] as num)
            .toDouble(),
        5,
      );
      expect(cad.runtime.scene.find('preview:$positiveId'), isNotNull);
      expect(cad.runtime.document!.entities[positiveId], isNull);
      expect(cad.runtime.selection, selectionBeforePreview);
      expect(nativeSceneUnsupportedReason(cad.runtime.scene, style: 0), isNull);
      controller.cancelProfessionalExtrude();
      expect(cad.runtime.scene.find('preview:$positiveId'), isNull);
      expect(controller.professionalExtrudePreview, isNull);
      expect(cad.runtime.document!.entities[positiveId], isNull);

      await controller.previewProfessionalExtrude(
        distance: 8,
        draftAngleDegrees: -4,
        direction: ProfessionalExtrudeDirection.reverse,
      );
      final negativePreview = controller.professionalExtrudePreview!;
      final extrudeId = negativePreview['id'] as String;
      expect(
        ((negativePreview['contract'] as Map)['draftAngleDegrees'] as num)
            .toDouble(),
        -4,
      );
      expect((negativePreview['contract'] as Map)['direction'], 'reverse');
      await controller.confirmProfessionalExtrude();
      final committed = cad.runtime.document!.entities[extrudeId]!;
      final committedContract = Map<String, dynamic>.from(
        ((committed.data['extrudeFeature'] as Map)['contract'] as Map),
      );
      expect(committedContract['profileEntityId'], profileId);
      expect(committedContract['draftAngleDegrees'], -4);
      expect(committedContract['direction'], 'reverse');
      expect(nativeSceneUnsupportedReason(cad.runtime.scene, style: 0), isNull);
      _expectExtrudeNativeEdgeModes(controller, extrudeId);

      await cad.runtime.undoDocument();
      expect(cad.runtime.document!.entities[extrudeId], isNull);
      await cad.runtime.redoDocument();
      expect(cad.runtime.document!.entities[extrudeId], isNotNull);

      // A source revision rebuilds the feature through the same Draft
      // contract; no parameter may silently fall back to its default.
      sketch.version += 1;
      final sourceEntity = cad.runtime.document!.entities[sketch.id]!;
      final revisedData = Map<String, dynamic>.from(sourceEntity.data);
      revisedData['sketch'] = {
        ...Map<String, dynamic>.from(sourceEntity.data['sketch'] as Map),
        'version': sketch.version,
      };
      await cad.runtime.mutate(
        command: 'test.draft-source-revision',
        upsert: [
          CadDocumentEntity(
            id: sourceEntity.id,
            kind: sourceEntity.kind,
            shape: sourceEntity.shape,
            mesh: sourceEntity.mesh,
            data: revisedData,
          ),
        ],
      );
      await controller.refreshDependentProfessionalExtrudes();
      final refreshedContract = Map<String, dynamic>.from(
        ((cad.runtime.document!.entities[extrudeId]!.data['extrudeFeature']
                as Map)['contract']
            as Map),
      );
      expect(refreshedContract['draftAngleDegrees'], -4);
      expect(refreshedContract['direction'], 'reverse');

      await cad.runtime.save();
      final scratch = await Directory(
        p.join(root.path, 'draft-scratch'),
      ).create();
      controller.detachProject();
      await cad.runtime.open('draft-scratch', scratch);
      await cad.runtime.open('managed-reference-sketch', project);
      await controller.configureProject(
        projectId: 'managed-reference-sketch',
        projectDirectory: project,
      );
      await controller.reenterProfessionalExtrude(extrudeId);
      final reentered = controller.professionalExtrudePreview!;
      final reenteredContract = Map<String, dynamic>.from(
        reentered['contract'] as Map,
      );
      expect(reenteredContract['draftAngleDegrees'], -4);
      expect(reenteredContract['direction'], 'reverse');
      expect(reenteredContract['profileEntityId'], profileId);
      controller.cancelProfessionalExtrude();
      expect(controller.professionalExtrudePreview, isNull);
      expect(cad.runtime.scene.find('preview:$extrudeId'), isNull);
    },
  );

  test(
    'managed Sketch symmetric Extrude keeps total distance, Draft and direction',
    () async {
      final step = await cad.runtime.importManagedStep(
        p.join(source.path, 'part-0.step'),
        nativeBridgePath: bridge,
      );
      final supportId = await cad.runtime.createManagedCadPlaneReference(
        sourceEntityId: step.id,
        presentationTriangleId: 1,
      );
      controller.selectSketchSupport(supportId);
      await controller.openSketch();
      final sketch = controller.activeSketch!;
      await controller.drawRectangle(
        const SketchVector(-5, -3),
        const SketchVector(5, 3),
      );
      final profileId = sketch.entityIds.first;
      await controller.finishSketch();
      _selectClosedSketchProfile(controller, sketch, profileId);
      cad.runtime.select({sketch.id});
      controller.clearExtrudeSource(clearDocumentSelection: true);
      expect(controller.selectedExtrudeSource, isNull);
      expect(cad.runtime.selection, isEmpty);
      _selectClosedSketchProfile(controller, sketch, profileId);

      await controller.previewProfessionalExtrude(
        distance: 10,
        extent: ProfessionalExtrudeExtent.symmetric,
      );
      final normalPreview = controller.professionalExtrudePreview!;
      final normalContract = Map<String, dynamic>.from(
        normalPreview['contract'] as Map,
      );
      expect(normalContract['extent'], 'symmetric');
      expect(normalContract['distance'], 10);
      expect(
        normalPreview['symmetricOffset'],
        (normalContract['directionVector'] as List)
            .cast<num>()
            .map((value) => -value * 10)
            .toList(),
      );
      final normalId = normalPreview['id'] as String;
      expect(cad.runtime.scene.find('preview:$normalId'), isNotNull);
      expect(cad.runtime.document!.entities[normalId], isNull);
      controller.cancelProfessionalExtrude();
      expect(cad.runtime.scene.find('preview:$normalId'), isNull);

      await controller.previewProfessionalExtrude(
        distance: 10,
        draftAngleDegrees: 3,
        direction: ProfessionalExtrudeDirection.reverse,
        extent: ProfessionalExtrudeExtent.symmetric,
      );
      final reversePreview = controller.professionalExtrudePreview!;
      final extrudeId = reversePreview['id'] as String;
      final reverseContract = Map<String, dynamic>.from(
        reversePreview['contract'] as Map,
      );
      expect(reverseContract['extent'], 'symmetric');
      expect(reverseContract['draftAngleDegrees'], 3);
      expect(reverseContract['direction'], 'reverse');
      expect(nativeSceneUnsupportedReason(cad.runtime.scene, style: 0), isNull);
      await controller.confirmProfessionalExtrude();
      final persisted = Map<String, dynamic>.from(
        ((cad.runtime.document!.entities[extrudeId]!.data['extrudeFeature']
                as Map)['contract']
            as Map),
      );
      expect(persisted['extent'], 'symmetric');
      expect(persisted['distance'], 10);
      expect(persisted['draftAngleDegrees'], 3);
      expect(persisted['direction'], 'reverse');
      _expectExtrudeNativeEdgeModes(controller, extrudeId);

      await cad.runtime.undoDocument();
      expect(cad.runtime.document!.entities[extrudeId], isNull);
      await cad.runtime.redoDocument();
      expect(cad.runtime.document!.entities[extrudeId], isNotNull);

      await cad.runtime.save();
      final scratch = await Directory(
        p.join(root.path, 'symmetric-scratch'),
      ).create();
      controller.detachProject();
      await cad.runtime.open('symmetric-scratch', scratch);
      await cad.runtime.open('managed-reference-sketch', project);
      await controller.configureProject(
        projectId: 'managed-reference-sketch',
        projectDirectory: project,
      );
      await controller.reenterProfessionalExtrude(extrudeId);
      final reentered = Map<String, dynamic>.from(
        controller.professionalExtrudePreview!['contract'] as Map,
      );
      expect(reentered['extent'], 'symmetric');
      expect(reentered['draftAngleDegrees'], 3);
      expect(reentered['direction'], 'reverse');
      controller.cancelProfessionalExtrude();

      _selectClosedSketchProfile(controller, sketch, profileId);
      await controller.previewProfessionalExtrude(
        distance: 10,
        output: ProfessionalExtrudeOutput.surface,
        extent: ProfessionalExtrudeExtent.symmetric,
        draftAngleDegrees: 5,
      );
      final wallsPreview = controller.professionalExtrudePreview!;
      expect((wallsPreview['handle'] as Map)['type'], 'shell');
      final wallsId = wallsPreview['id'] as String;
      final wallsScene = cad.runtime.scene.find('preview:$wallsId');
      expect(wallsScene, isNotNull);
      expect(wallsScene!.geometry['nodes'], isNotEmpty);
      expect(wallsScene.geometry['triangles'], isNotEmpty);
      expect(nativeSceneUnsupportedReason(cad.runtime.scene, style: 0), isNull);
      await controller.confirmProfessionalExtrude();
      final walls = cad.runtime.document!.entities[wallsId]!;
      expect(walls.kind, CadDocumentEntityKind.surface);
      expect(walls.shape!.type, CADShapeType.shell);

      await expectLater(
        controller.previewProfessionalExtrude(
          distance: 10,
          draftAngleDegrees: 89,
          extent: ProfessionalExtrudeExtent.symmetric,
        ),
        throwsArgumentError,
      );
      expect(controller.professionalExtrudePreview, isNull);
      expect(controller.error, contains('Valor de Draft inválido'));
    },
  );

  test(
    'orphaned managed CAD reference blocks Sketch creation clearly',
    () async {
      final step = await cad.runtime.importManagedStep(
        p.join(source.path, 'part-0.step'),
        nativeBridgePath: bridge,
      );
      final referenceId = await cad.runtime.createManagedCadPlaneReference(
        sourceEntityId: step.id,
        presentationTriangleId: 1,
      );
      controller.selectSketchSupport(referenceId);
      await cad.runtime.removeEntity(step.id, command: 'test.remove-source');

      await expectLater(
        controller.openSketch(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('órfã'),
          ),
        ),
      );
      expect(
        cad.runtime.document!.entities.values.where(
          (entity) => entity.kind == CadDocumentEntityKind.sketch,
        ),
        isEmpty,
      );
    },
  );

  test(
    'native Professional Revolve previews, applies, persists and reenters',
    () async {
      const projectId = 'managed-reference-sketch';
      const planeId = '$projectId:world:xy-plane';
      const axisId = '$projectId:world:x-axis';

      controller.selectSketchSupport(planeId);
      await controller.openSketch();
      await controller.drawRectangle(
        const SketchVector(-2, 2),
        const SketchVector(2, 5),
      );
      final closedSketch = controller.activeSketch!;
      await controller.finishSketch();
      controller.beginRevolveViewportCapture(axis: false);
      expect(controller.captureRevolveViewportEntity(closedSketch.id), isTrue);
      controller.beginRevolveViewportCapture(axis: true);
      expect(controller.captureRevolveViewportEntity(axisId), isTrue);
      expect(controller.selectedRevolveProfileId, closedSketch.id);
      expect(controller.selectedRevolveAxisId, axisId);
      expect(controller.revolveCaptureSlot, isNull);
      expect(controller.canPreviewRevolve, isTrue);

      await controller.previewProfessionalRevolve(
        angleDegrees: 120,
        output: RevolveOutput.solid,
      );
      final firstPreview = controller.professionalRevolvePreview!;
      final revolveId = firstPreview['id'] as String;
      expect((firstPreview['handle'] as Map)['type'], 'solid');
      expect(cad.runtime.document!.entities[revolveId], isNull);
      expect(cad.runtime.scene.find('preview:$revolveId'), isNotNull);
      controller.cancelProfessionalRevolve();
      expect(controller.professionalRevolvePreview, isNull);
      expect(cad.runtime.scene.find('preview:$revolveId'), isNull);

      // A healthy closed Sketch may also generate Surface/Walls. It must use
      // the same ordered connected loop as Solid, rather than the incidental
      // Sketch insertion order that can create a malformed native wire.
      await controller.previewProfessionalRevolve(
        angleDegrees: 120,
        output: RevolveOutput.surface,
      );
      expect(
        (controller.professionalRevolvePreview!['contract'] as Map)['output'],
        RevolveOutput.surface.name,
      );
      controller.cancelProfessionalRevolve();

      await controller.previewProfessionalRevolve(
        angleDegrees: 120,
        direction: RevolveDirection.clockwise,
        output: RevolveOutput.solid,
      );
      final signedContract = ProfessionalRevolveContract.fromJson(
        Map<String, dynamic>.from(
          controller.professionalRevolvePreview!['contract'] as Map,
        ),
      );
      expect(signedContract.signedAngle, -120);
      await controller.confirmProfessionalRevolve();
      final committed = cad.runtime.document!.entities[revolveId]!;
      expect(committed.kind, CadDocumentEntityKind.solid);
      expect((committed.data['revolveFeature'] as Map)['status'], 'committed');

      await cad.runtime.undoDocument();
      expect(cad.runtime.document!.entities[revolveId], isNull);
      await cad.runtime.redoDocument();
      expect(
        cad.runtime.document!.entities[revolveId]?.kind,
        CadDocumentEntityKind.solid,
      );

      await cad.runtime.save();
      final scratch = await Directory(
        p.join(root.path, 'revolve-scratch'),
      ).create();
      controller.detachProject();
      await cad.runtime.open('revolve-scratch', scratch);
      await cad.runtime.open(projectId, project);
      await controller.configureProject(
        projectId: projectId,
        projectDirectory: project,
      );
      expect(
        cad.runtime.document!.entities[revolveId]?.kind,
        CadDocumentEntityKind.solid,
      );
      await controller.reenterProfessionalRevolve(revolveId);
      expect(controller.professionalRevolvePreview, isNotNull);
      expect(
        ProfessionalRevolveContract.fromJson(
          Map<String, dynamic>.from(
            controller.professionalRevolvePreview!['contract'] as Map,
          ),
        ).direction,
        RevolveDirection.clockwise,
      );
      controller.cancelProfessionalRevolve();

      controller.selectSketchSupport(planeId);
      await controller.openSketch();
      controller.sketchApi!.builders.line.build(
        const SketchVector(-3, 7),
        const SketchVector(3, 7),
      );
      final openSketch = controller.activeSketch!;
      await controller.finishSketch();
      controller.selectRevolveProfile(openSketch.id);
      controller.selectRevolveAxis(axisId);
      await controller.previewProfessionalRevolve(
        angleDegrees: 90,
        output: RevolveOutput.surface,
      );
      expect(
        (controller.professionalRevolvePreview!['contract'] as Map)['output'],
        RevolveOutput.surface.name,
      );
      controller.cancelProfessionalRevolve();

      await expectLater(
        controller.previewProfessionalRevolve(
          angleDegrees: 90,
          output: RevolveOutput.solid,
        ),
        throwsStateError,
      );
      expect(controller.professionalRevolvePreview, isNull);

      const invalidAxisId = 'reference:invalid-revolve-axis';
      await cad.runtime.mutate(
        command: 'test.invalid-revolve-axis',
        upsert: [
          CadDocumentEntity(
            id: invalidAxisId,
            kind: CadDocumentEntityKind.reference,
            data: const {
              'name': 'Invalid Axis',
              'sceneKind': 'axis',
              'sceneGeometry': {
                'type': 'axis',
                'origin': [0.0, 0.0, 0.0],
                'direction': [0.0, 0.0, 0.0],
              },
            },
          ),
        ],
      );
      controller.selectRevolveProfile(closedSketch.id);
      controller.selectRevolveAxis(invalidAxisId);
      await expectLater(
        controller.previewProfessionalRevolve(
          angleDegrees: 90,
          output: RevolveOutput.solid,
        ),
        throwsStateError,
      );
      expect(controller.error, contains('zero axis direction'));
      expect(controller.professionalRevolvePreview, isNull);
    },
  );

  test(
    'driving dimension keeps scene synchronization available for later lines',
    () async {
      const planeId = 'managed-reference-sketch:world:xy-plane';
      controller.selectSketchSupport(planeId);
      await controller.openSketch();
      final first = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(4, 0),
      );
      controller.selectedSketchEntityIds.add(first.id);
      await controller.createDrivingDimension(
        SketchDimensionType.linear,
        20,
        anchorReference: '${first.id}:start',
      );

      expect(first.parameters['end'], [20.0, 0.0, 0.0]);
      final dimension = controller.dimensions.single;
      expect(
        controller.runtime.scene.find(dimension.id)?.kind,
        CadSceneEntityKind.sketch,
      );

      final second = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 5),
        const SketchVector(8, 5),
      );
      await controller.refreshSketchSceneAfterExit();
      expect(controller.runtime.scene.find(first.id), isNotNull);
      expect(controller.runtime.scene.find(second.id), isNotNull);
      expect(controller.runtime.scene.find(second.id)?.geometry['points'], [
        [0.0, 5.0, 0.0],
        [8.0, 5.0, 0.0],
      ]);
    },
  );

  test('construction Sketch line is an analytic Revolve axis', () async {
    const planeId = 'managed-reference-sketch:world:xy-plane';
    controller.selectSketchSupport(planeId);
    await controller.openSketch();
    await controller.drawRectangle(
      const SketchVector(2, 2),
      const SketchVector(5, 6),
    );
    final profileId = controller.activeSketch!.id;
    final line = controller.sketchApi!.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(0, 10),
    );
    controller.selectedSketchEntityIds.add(line.id);
    await controller.convertSelectedLineToConstruction();
    expect(controller.sketchApi!.entity(line.id)!.construction, isTrue);
    await controller.finishSketch();
    expect(
      controller.revolveAxes.map((entity) => entity.id),
      contains(line.id),
    );

    controller.selectRevolveProfile(profileId);
    controller.beginRevolveViewportCapture(axis: true);
    expect(controller.captureRevolveViewportEntity(line.id), isTrue);
    expect(controller.selectedRevolveAxisId, line.id);
    await controller.previewProfessionalRevolve(
      angleDegrees: 120,
      output: RevolveOutput.solid,
    );
    final preview = controller.professionalRevolvePreview!;
    expect((preview['contract'] as Map)['axisEntityId'], line.id);
    expect((preview['handle'] as Map)['type'], 'solid');
    controller.cancelProfessionalRevolve();
    expect(controller.professionalRevolvePreview, isNull);
  });

  test(
    'Sketch polyline, interpolated spline and tangent Blend stay transactional',
    () async {
      const planeId = 'managed-reference-sketch:world:xy-plane';
      controller.selectSketchSupport(planeId);
      await controller.openSketch();
      controller.beginPolylineCommand();
      controller.previewPoints = const [
        SketchVector(0, 0),
        SketchVector(8, 0),
        SketchVector(8, 8),
      ];
      expect(controller.sketchApi!.engine.entities, isEmpty);
      await controller.finishSketchCommandFromSecondaryTap();
      expect(controller.polylineCommandActive, isTrue);
      expect(controller.previewPoints, isEmpty);
      expect(
        controller.sketchApi!.engine.entities.values.whereType<SketchLine>(),
        hasLength(2),
      );
      await controller.undo();
      expect(controller.sketchApi!.engine.entities, isEmpty);
      await controller.redo();
      expect(
        controller.sketchApi!.engine.entities.values.whereType<SketchLine>(),
        hasLength(2),
      );

      controller.beginSplineCommand();
      controller.previewPoints = const [
        SketchVector(0, 12),
        SketchVector(4, 14),
        SketchVector(8, 12),
      ];
      await controller.finishSketchCommandFromSecondaryTap();
      expect(controller.splineCommandActive, isTrue);
      expect(controller.previewPoints, isEmpty);
      final interpolated = controller.sketchApi!.engine.entities.values
          .whereType<SketchSpline>()
          .single;
      expect(interpolated.parameters['interpolation'], 'centripetalCatmullRom');

      final first = controller.sketchApi!.builders.line.build(
        const SketchVector(12, 0),
        const SketchVector(18, 0),
      );
      final second = controller.sketchApi!.builders.line.build(
        const SketchVector(22, 4),
        const SketchVector(22, 10),
      );
      controller.beginSketchTangentBlend();
      await controller.captureSketchEditingPick(
        CadViewportPick(
          entityId: first.id,
          hit: MeshHit(
            triangleIndex: -1,
            point: Vector3(18, 0, 0),
            distance: 0,
          ),
        ),
      );
      expect(controller.sketchBlendFirstEndpoint, '${first.id}:end');
      expect(
        controller.runtime.scene.find('sketch-blend-first-endpoint'),
        isNotNull,
      );
      await controller.captureSketchEditingPick(
        CadViewportPick(
          entityId: second.id,
          hit: MeshHit(
            triangleIndex: -1,
            point: Vector3(22, 4, 0),
            distance: 0,
          ),
        ),
      );
      expect(controller.sketchBlendSecondEndpoint, '${second.id}:start');
      controller.setSketchEditingValue(3);
      expect(cad.runtime.scene.find('sketch-edit-preview'), isNotNull);
      expect(
        controller.sketchApi!.engine.entities.values.whereType<SketchSpline>(),
        hasLength(1),
      );
      controller.finishSketchEditingTool();
      expect(cad.runtime.scene.find('sketch-edit-preview'), isNull);
      expect(
        controller.runtime.scene.find('sketch-blend-first-endpoint'),
        isNull,
      );
      controller.beginSketchTangentBlend();
      await controller.captureSketchEditingPick(
        CadViewportPick(
          entityId: first.id,
          hit: MeshHit(
            triangleIndex: -1,
            point: Vector3(18, 0, 0),
            distance: 0,
          ),
        ),
      );
      await controller.captureSketchEditingPick(
        CadViewportPick(
          entityId: second.id,
          hit: MeshHit(
            triangleIndex: -1,
            point: Vector3(22, 4, 0),
            distance: 0,
          ),
        ),
      );
      controller.setSketchBlendTangentLength(firstEndpoint: true, value: 2);
      controller.setSketchBlendTangentLength(firstEndpoint: false, value: 5);
      await controller.commitSketchCorner();
      expect(controller.sketchTangentBlendActive, isTrue);
      expect(controller.selectedSketchEntityIds, isEmpty);
      final blend = controller.sketchApi!.engine.entities.values
          .whereType<SketchSpline>()
          .firstWhere(
            (entity) => entity.metadata['featureType'] == 'tangentBlend',
          );
      expect(blend.metadata['sourceEntityIds'], [first.id, second.id]);
      expect(blend.metadata['sourceEndpointReferences'], [
        '${first.id}:end',
        '${second.id}:start',
      ]);
      expect(blend.metadata['firstTangentLength'], 2.0);
      expect(blend.metadata['secondTangentLength'], 5.0);
      expect(blend.parameters['interpolation'], 'cubicBezierG1');
      expect(controller.sketchApi!.entity(first.id), isNotNull);
      expect(controller.sketchApi!.entity(second.id), isNotNull);
      expect(cad.runtime.scene.find('sketch-edit-preview'), isNull);
      await controller.undo();
      expect(controller.sketchApi!.entity(blend.id), isNull);
      await controller.redo();
      expect(controller.sketchApi!.entity(blend.id), isNotNull);
      await cad.runtime.save();
      controller.detachProject();
      await controller.configureProject(
        projectId: 'managed-reference-sketch',
        projectDirectory: project,
      );
      expect(
        controller.sketchApi!.entity(blend.id)?.parameters['interpolation'],
        'cubicBezierG1',
      );
      expect(nativeSceneUnsupportedReason(cad.runtime.scene, style: 0), isNull);
    },
  );

  test(
    'point constraints and professional point distance use explicit viewport picks',
    () async {
      const planeId = 'managed-reference-sketch:world:xy-plane';
      controller.selectSketchSupport(planeId);
      await controller.openSketch();
      final anchor = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final target = controller.sketchApi!.builders.line.build(
        const SketchVector(20, 5),
        const SketchVector(30, 5),
      );
      final selectionBefore = cad.runtime.selection.toSet();

      controller.beginSketchPointReferenceCapture('coincident');
      await controller.captureSketchPointReferencePick(
        CadViewportPick(
          entityId: anchor.id,
          hit: const MeshHit(
            triangleIndex: -1,
            point: Vector3(5, 0, 0),
            distance: 0,
          ),
        ),
      );
      expect(controller.sketchPointReferenceCaptureReferences, isEmpty);
      expect(
        controller.sketchPointReferenceCaptureDiagnostic,
        contains('extremidade'),
      );
      expect(cad.runtime.selection, selectionBefore);
      await controller.captureSketchPointReferencePick(
        CadViewportPick(
          entityId: anchor.id,
          hit: const MeshHit(
            triangleIndex: -1,
            point: Vector3(10, 0, 0),
            distance: 0,
          ),
        ),
      );
      await controller.captureSketchPointReferencePick(
        CadViewportPick(
          entityId: target.id,
          hit: const MeshHit(
            triangleIndex: -1,
            point: Vector3(20, 5, 0),
            distance: 0,
          ),
        ),
      );
      expect(controller.sketchPointReferenceCaptureReferences, [
        '${anchor.id}:end',
        '${target.id}:start',
      ]);
      expect(cad.runtime.selection, selectionBefore);
      await controller.confirmSketchPointReferenceCapture();
      expect(target.parameters['start'], [10.0, 0.0, 0.0]);
      expect(controller.sketchPointReferenceCaptureActive, isFalse);

      controller.beginSketchPointReferenceCapture('distance');
      await controller.captureSketchPointReferencePick(
        CadViewportPick(
          entityId: anchor.id,
          hit: const MeshHit(
            triangleIndex: -1,
            point: Vector3(0, 0, 0),
            distance: 0,
          ),
        ),
      );
      await controller.captureSketchPointReferencePick(
        CadViewportPick(
          entityId: target.id,
          hit: const MeshHit(
            triangleIndex: -1,
            point: Vector3(30, 5, 0),
            distance: 0,
          ),
        ),
      );
      await controller.confirmSketchPointReferenceCapture(value: 25);
      final dimension = controller.dimensions.single;
      expect(dimension.references, ['${anchor.id}:start', '${target.id}:end']);
      expect(dimension.value, 25);
      expect(cad.runtime.scene.find(dimension.id), isNotNull);

      final horizontalAnchor = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 20),
        const SketchVector(4, 20),
      );
      final horizontalTarget = controller.sketchApi!.builders.line.build(
        const SketchVector(7, 26),
        const SketchVector(12, 26),
      );
      controller.beginSketchPointReferenceCapture('horizontalDistance');
      for (final pick in [
        CadViewportPick(
          entityId: horizontalAnchor.id,
          hit: const MeshHit(
            triangleIndex: -1,
            point: Vector3(4, 20, 0),
            distance: 0,
          ),
        ),
        CadViewportPick(
          entityId: horizontalTarget.id,
          hit: const MeshHit(
            triangleIndex: -1,
            point: Vector3(7, 26, 0),
            distance: 0,
          ),
        ),
      ]) {
        await controller.captureSketchPointReferencePick(pick);
      }
      await controller.confirmSketchPointReferenceCapture(value: 14);
      expect(
        controller.dimensions.where(
          (item) => item.type == SketchDimensionType.horizontal,
        ),
        hasLength(1),
      );

      final angularReference = controller.sketchApi!.builders.line.build(
        const SketchVector(40, 0),
        const SketchVector(50, 0),
      );
      final angularTarget = controller.sketchApi!.builders.line.build(
        const SketchVector(40, 10),
        const SketchVector(40, 18),
      );
      controller.beginSketchPointReferenceCapture('angleBetweenLines');
      for (final pick in [
        CadViewportPick(
          entityId: angularReference.id,
          hit: const MeshHit(
            triangleIndex: -1,
            point: Vector3(45, 0, 0),
            distance: 0,
          ),
        ),
        CadViewportPick(
          entityId: angularTarget.id,
          hit: const MeshHit(
            triangleIndex: -1,
            point: Vector3(40, 14, 0),
            distance: 0,
          ),
        ),
      ]) {
        await controller.captureSketchPointReferencePick(pick);
      }
      await controller.confirmSketchPointReferenceCapture(value: 35);
      expect(
        controller.dimensions.where(
          (item) =>
              item.type == SketchDimensionType.angular &&
              item.references.length == 2,
        ),
        hasLength(1),
      );

      controller.beginSketchPointReferenceCapture('midpoint');
      final targetEnd = SketchVector.fromJson(target.parameters['end']);
      await controller.captureSketchPointReferencePick(
        CadViewportPick(
          entityId: target.id,
          hit: MeshHit(
            triangleIndex: -1,
            point: Vector3(targetEnd.x, targetEnd.y, targetEnd.z),
            distance: 0,
          ),
        ),
      );
      expect(cad.runtime.scene.find('sketch-point-capture-1'), isNotNull);
      controller.cancelPendingSketchOperation();
      expect(controller.sketchPointReferenceCaptureActive, isFalse);
      expect(cad.runtime.scene.find('sketch-point-capture-1'), isNull);
    },
  );

  test(
    'right click cancels incomplete polyline and spline without residue',
    () async {
      const planeId = 'managed-reference-sketch:world:xy-plane';
      controller.selectSketchSupport(planeId);
      await controller.openSketch();
      controller.beginPolylineCommand();
      controller.previewPoints = const [SketchVector(1, 2)];
      await controller.finishSketchCommandFromSecondaryTap();
      expect(controller.polylineCommandActive, isTrue);
      expect(controller.previewPoints, isEmpty);
      expect(controller.sketchApi!.engine.entities, isEmpty);

      controller.beginSplineCommand();
      controller.previewPoints = const [SketchVector(1, 2), SketchVector(3, 4)];
      await controller.finishSketchCommandFromSecondaryTap();
      expect(controller.splineCommandActive, isTrue);
      expect(controller.previewPoints, isEmpty);
      expect(controller.sketchApi!.engine.entities, isEmpty);
      expect(cad.runtime.scene.find('sketch-spline-preview'), isNull);
      controller.cancelPendingSketchOperation();
      expect(controller.splineCommandActive, isFalse);
      controller.beginLineCommand();
      controller.previewPoints = const [SketchVector(7, 8)];
      await controller.finishSketchCommandFromSecondaryTap();
      expect(controller.lineCommandActive, isTrue);
      expect(controller.previewPoints, isEmpty);
      controller.cancelPendingSketchOperation();
      expect(controller.lineCommandActive, isFalse);
    },
  );

  test('cylindrical axis reference is not treated as a Sketch plane', () async {
    final step = await cad.runtime.importManagedStep(
      p.join(source.path, 'cylinder.step'),
      nativeBridgePath: bridge,
    );
    final axisId = await cad.runtime.createManagedCadCylinderAxisReference(
      sourceEntityId: step.id,
      presentationTriangleId: 1,
    );

    expect(
      () => controller.selectSketchSupport(axisId),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('não é um suporte planar'),
        ),
      ),
    );
  });
}

ManagedCadReference _reference(DesktopCadController cad, String id) =>
    ManagedCadReference.fromJson(
      Map<String, dynamic>.from(
        cad.runtime.document!.entities[id]!.data[ManagedCadReference.dataKey]
            as Map,
      ),
    );

void _expectFrame(
  Sketch sketch,
  ManagedCadReference reference,
  String referenceId,
) {
  expect(sketch.metadata['supportEntityId'], referenceId);
  expect(sketch.plane.parameters['referenceId'], referenceId);
  expect(sketch.coordinates.origin.toJson(), reference.origin.toJson());
  expect(sketch.coordinates.normal.toJson(), reference.normal!.toJson());
  expect(sketch.coordinates.xAxis.toJson(), reference.xDirection!.toJson());
  expect(
    sketch.coordinates.xAxis.dot(sketch.coordinates.normal).abs(),
    lessThan(1e-12),
  );
  expect(
    sketch.coordinates.yAxis.dot(sketch.coordinates.normal).abs(),
    lessThan(1e-12),
  );
  expect(
    sketch.coordinates.xAxis.dot(sketch.coordinates.yAxis).abs(),
    lessThan(1e-12),
  );
}

Future<String> _extrudeActiveSketch(
  OperationalReverseEngineeringController controller,
  double distance,
) async {
  final sketch = controller.activeSketch!;
  controller.selectExtrudeSource(sketch.id);
  await controller.previewProfessionalExtrude(distance: distance);
  final preview = controller.professionalExtrudePreview!;
  final id = preview['id'] as String;
  expect(controller.runtime.scene.find('preview:$id'), isNotNull);
  await controller.confirmProfessionalExtrude();
  expect(controller.runtime.scene.find('preview:$id'), isNull);
  expect(controller.runtime.scene.find(id), isNotNull);
  return id;
}

Future<String> _extrudeSketchProfile(
  OperationalReverseEngineeringController controller,
  Sketch sketch,
  String profileEntityId,
  double distance,
) async {
  _selectClosedSketchProfile(controller, sketch, profileEntityId);
  expect(controller.selectedExtrudeSourceId, sketch.id);
  expect(controller.selectedExtrudeProfileEntityId, profileEntityId);
  await controller.previewProfessionalExtrude(distance: distance);
  final preview = controller.professionalExtrudePreview!;
  final contract = Map<String, dynamic>.from(preview['contract'] as Map);
  expect(contract['profileEntityId'], profileEntityId);
  final id = preview['id'] as String;
  final previewEntity = controller.runtime.scene.find('preview:$id');
  expect(previewEntity, isNotNull);
  expect(previewEntity!.geometry['nodes'], isNotEmpty);
  expect(previewEntity.geometry['triangles'], isNotEmpty);
  expect(
    nativeSceneUnsupportedReason(controller.runtime.scene, style: 0),
    isNull,
  );
  await controller.confirmProfessionalExtrude();
  expect(controller.runtime.scene.find('preview:$id'), isNull);
  expect(controller.runtime.scene.find(id), isNotNull);
  expect(
    nativeSceneUnsupportedReason(controller.runtime.scene, style: 0),
    isNull,
  );
  _expectExtrudeNativeEdgeModes(controller, id);
  return id;
}

void _expectExtrudeNativeEdgeModes(
  OperationalReverseEngineeringController controller,
  String id,
) {
  final solid = controller.runtime.document!.entities[id]!;
  final scene = controller.runtime.scene.find(id)!;
  final handle = scene.geometry['handle'] as Map;
  expect(solid.shape!.persistentId, handle['persistentId']);
  final brepPresentation = scene.geometry['brepPresentation'];
  expect(brepPresentation, isA<Map>());
  final edges = scene.geometry['topologicalEdges'];
  expect(edges, isA<List>());
  expect(edges, isNotEmpty);
  expect((brepPresentation as Map)['topologicalEdges'], same(edges));
  for (final style in [0, 1, 2, 3]) {
    expect(
      nativeSceneUnsupportedReason(controller.runtime.scene, style: style),
      isNull,
      reason: 'Extrude $id must remain eligible for Native GPU style $style',
    );
  }
}

void _selectClosedSketchProfile(
  OperationalReverseEngineeringController controller,
  Sketch sketch,
  String profileEntityId,
) {
  final profile = controller.sketchApi!.entity(profileEntityId);
  final ids = profile is SketchLine
      ? sketch.entityIds
            .where((id) => controller.sketchApi!.entity(id) is SketchLine)
            .toList(growable: false)
      : [profileEntityId];
  expect(controller.selectExtrudeSourceFromViewport(ids.first), isTrue);
  // Extrude resolves a clicked segment to its entire connected component;
  // Ctrl-clicking another segment of this same loop toggles that profile off.
  expect(controller.selectedExtrudeProfileEntityIds, containsAll(ids));
}
