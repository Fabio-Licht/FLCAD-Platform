import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/desktop/desktop_application.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/managed_cad_reference.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_editor/health/sketch_health_analyzer.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  testWidgets('Inspector field owns ENTER before the Workspace shortcut', (
    tester,
  ) async {
    double? submitted;
    var workspaceEnter = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter): () {
              workspaceEnter++;
            },
          },
          child: Scaffold(
            body: SketchInspectorNumberProperty(
              label: 'Length',
              value: 10,
              onSubmitted: (value) async => submitted = value,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextFormField));
    await tester.enterText(find.byType(TextFormField), '100');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(submitted, 100);
    expect(workspaceEnter, 0);

    submitted = null;
    await tester.enterText(find.byType(TextFormField), '125');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(submitted, 125);
  });

  test(
    'Inspector command updates viewport, document and Undo/Redo in place',
    () async {
      final directory = await Directory.systemTemp.createTemp('g124_1_');
      addTearDown(() => directory.delete(recursive: true));
      final kernels = KernelManager()
        ..register(_HealthySurfaceKernel(), makeDefault: true);
      final cad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
      );
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
      );
      final projects = ProjectRepository(
        storage: LocalStorageService(rootDirectory: directory),
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
      await cad.runtime.open('g124-project', directory);
      await controller.configureProject(
        projectId: 'g124-project',
        projectDirectory: directory,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      final firstSupport = controller.activeSketchPlaneId;
      controller.selectWorldSketchPlane(SketchPlaneType.yz);
      expect(controller.activeSketchPlaneId, isNot(firstSupport));
      expect(controller.activeSketchPlaneId, endsWith('yz-plane'));
      expect(controller.activeSketchPlane!.normal.x.abs(), closeTo(1, 1e-12));
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      final line = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      controller.toggleSketchSelection(line.id);

      await controller.updateSketchEntityParameters(line.id, {'length': 100});
      final edited = controller.sketchApi!.entity(line.id)! as SketchLine;
      expect(edited.id, line.id);
      expect(edited.parameters['length'], closeTo(100, 1e-10));
      expect(cad.runtime.scene.find(line.id), isNotNull);
      expect(
        cad.runtime.document!.entities[line.id]!.data['sketchEntity']['id'],
        line.id,
      );

      // The controller must toggle from the effective scene state.  Exercise
      // both directions on a normal new Sketch and repair a stale scene root
      // without changing its already-correct persisted visibility.
      final newSketchId = controller.activeSketch!.id;
      expect(controller.activeSketchVisible, isTrue);
      await controller.toggleActiveSketchVisibility();
      expect(controller.activeSketchVisible, isFalse);
      expect(cad.runtime.scene.find(newSketchId)!.visible, isFalse);
      expect(cad.runtime.scene.find(line.id)!.visible, isFalse);
      await controller.toggleActiveSketchVisibility();
      expect(controller.activeSketchVisible, isTrue);
      expect(cad.runtime.scene.find(newSketchId)!.visible, isTrue);
      expect(cad.runtime.scene.find(line.id)!.visible, isTrue);
      final rootScene = cad.runtime.scene.find(newSketchId)!;
      cad.runtime.scene.upsert(rootScene.copyWith(visible: false));
      expect(controller.activeSketchVisible, isFalse);
      await controller.toggleActiveSketchVisibility();
      expect(controller.activeSketchVisible, isTrue);
      expect(cad.runtime.scene.find(newSketchId)!.visible, isTrue);

      // Manual circular reconstruction replaces a connected chain while
      // retaining its two external vertices and selecting the native arc.
      SketchVector circularPoint(double angle) =>
          SketchVector(100 + 5 * math.cos(angle), 5 * math.sin(angle));
      final sourceA = controller.sketchApi!.builders.line.build(
        circularPoint(0),
        circularPoint(.3),
      );
      final sourceB = controller.sketchApi!.builders.line.build(
        circularPoint(.3),
        circularPoint(.6),
      );
      final followingSource = controller.sketchApi!.builders.line.build(
        circularPoint(.6),
        circularPoint(.9),
      );
      final closingSource = controller.sketchApi!.builders.line.build(
        circularPoint(-.3),
        circularPoint(0),
      );
      // This follows the viewport's multi-selection flow rather than writing
      // directly to the selection set: both picked section curves must reach
      // the fit command in insertion order.
      controller.beginSketchCircularSelection();
      controller.selectSketchEntity(sourceA.id);
      controller.selectSketchEntity(sourceB.id);
      expect(controller.selectedSketchEntityIds, {sourceA.id, sourceB.id});
      await controller.fitSelectedSketchCircularGeometry();
      final fittedId = controller.selectedSketchEntityIds.single;
      final fitted = controller.sketchApi!.entity(fittedId)! as SketchArc;
      // Chord neighbours of a Section are not reliable tangents: the arc now
      // follows the selected samples and reports the continuity honestly.
      expect(
        controller.sketchCircularFitMessage,
        contains('mínimos quadrados'),
      );
      expect(
        controller.sketchApi!.entity(fittedId)!.parameters['radius'],
        closeTo(5, 1e-6),
      );
      expect(sourceA.visible, isFalse);
      expect(sourceB.visible, isFalse);
      expect(controller.selectedSketchEntityIds, {fitted.id});
      expect(
        controller.sketchHealth
            .ofType(SketchHealthIssueType.gap)
            .where((issue) => issue.entityIds.contains(fitted.id)),
        isEmpty,
      );
      expect(
        controller.sketchHealth
            .ofType(SketchHealthIssueType.openEnd)
            .where((issue) => issue.entityIds.contains(fitted.id)),
        isEmpty,
      );
      expect(followingSource.visible, isTrue);
      expect(closingSource.visible, isTrue);

      // Hidden reconstruction inputs must not keep raising health issues,
      // and a later synchronisation must not resurrect them from stale
      // scene state while the native arc stays the active profile.
      for (final hidden in [sourceA.id, sourceB.id]) {
        expect(
          controller.sketchHealth.issues.any(
            (issue) => issue.entityIds.contains(hidden),
          ),
          isFalse,
        );
      }
      // Blocking issues belong to the active profile only; entities outside
      // it (for example the unrelated edited line) may surface as warnings
      // but must never become blocking errors for the active edit.
      final health = controller.sketchHealth;
      final activeProfileIds = health.activeProfileEntityIds;
      expect(activeProfileIds, contains(fitted.id));
      for (final issue in health.issues) {
        final insideActiveProfile = issue.entityIds.any(
          activeProfileIds.contains,
        );
        expect(
          issue.blocking,
          insideActiveProfile,
          reason: '${issue.type.name}: ${issue.entityIds}',
        );
        expect(
          issue.scope,
          insideActiveProfile
              ? SketchHealthIssueScope.activeProfile
              : SketchHealthIssueScope.sketch,
        );
      }
      final externalIssues = health.issues.where(
        (issue) => issue.entityIds.contains(line.id),
      );
      expect(externalIssues, isNotEmpty);
      expect(externalIssues.every((issue) => !issue.blocking), isTrue);
      await controller.updateSketchEntityParameters(line.id, {
        'angleDegrees': 45,
      });
      expect(sourceA.visible, isFalse);
      expect(sourceB.visible, isFalse);
      expect(edited.parameters['angleDegrees'], closeTo(45, 1e-10));

      await controller.undo();
      expect(
        controller.sketchApi!.entity(line.id)!.parameters['angleDegrees'],
        closeTo(0, 1e-10),
      );
      await controller.redo();
      expect(
        controller.sketchApi!.entity(line.id)!.parameters['angleDegrees'],
        closeTo(45, 1e-10),
      );

      // A root toggle must restore the promoted arc after a synchronization,
      // without resurrecting the source curves hidden by reconstruction.
      // Remove the new marker to simulate a project persisted before this
      // migration.  The sources retain reconstructionKind + visible=false.
      final legacySourceA = controller.sketchApi!.entity(sourceA.id)!;
      final legacySourceB = controller.sketchApi!.entity(sourceB.id)!;
      legacySourceA.metadata.remove('reconstructionHidden');
      legacySourceB.metadata.remove('reconstructionHidden');
      await cad.runtime.setEntityVisibility(line.id, false);
      await controller.toggleActiveSketchVisibility();
      expect(controller.activeSketchVisible, isFalse);
      expect(
        cad
            .runtime
            .document!
            .entities[controller.activeSketch!.id]!
            .data['sceneVisible'],
        isFalse,
      );
      await controller.updateSketchEntityParameters(line.id, {
        'angleDegrees': 44,
      });
      await controller.toggleActiveSketchVisibility();
      expect(controller.activeSketchVisible, isTrue);
      expect(fitted.visible, isTrue);
      expect(sourceA.visible, isFalse);
      expect(sourceB.visible, isFalse);
      expect(
        controller.sketchApi!
            .entity(sourceA.id)!
            .metadata['reconstructionHidden'],
        isTrue,
      );
      expect(
        controller.sketchApi!
            .entity(sourceB.id)!
            .metadata['reconstructionHidden'],
        isTrue,
      );
      expect(
        controller.sketchApi!
            .entity(fitted.id)!
            .metadata['reconstructionHidden'],
        isNull,
      );
      expect(
        controller.sketchApi!.entity(line.id)!.metadata['reconstructionHidden'],
        isNull,
      );
      expect(
        cad.runtime.document!.entities[fitted.id]!.data['sceneVisible'],
        isTrue,
      );
      expect(
        cad.runtime.document!.entities[sourceA.id]!.data['sceneVisible'],
        isFalse,
      );
      await controller.toggleActiveSketchVisibility();
      expect(controller.activeSketchVisible, isFalse);
      await controller.toggleActiveSketchVisibility();
      expect(controller.activeSketchVisible, isTrue);
      expect(fitted.visible, isTrue);
      expect(sourceA.visible, isFalse);
      // Repeating synchronization preserves the migrated marker without
      // converting a manually hidden normal Sketch entity into a source.
      await controller.updateSketchEntityParameters(line.id, {
        'angleDegrees': 43,
      });
      expect(
        controller.sketchApi!
            .entity(sourceA.id)!
            .metadata['reconstructionHidden'],
        isTrue,
      );
      expect(
        controller.sketchApi!
            .entity(fitted.id)!
            .metadata['reconstructionHidden'],
        isNull,
      );
      expect(
        controller.sketchApi!.entity(line.id)!.metadata['reconstructionHidden'],
        isNull,
      );

      // Three real viewport-style selections also reach the fit command and
      // create the native arc before C1 is evaluated by the reconstruction.
      SketchVector threePoint(double angle) =>
          SketchVector(200 + 5 * math.cos(angle), 5 * math.sin(angle));
      final threeA = controller.sketchApi!.builders.line.build(
        threePoint(0),
        threePoint(.2),
      );
      final threeB = controller.sketchApi!.builders.line.build(
        threePoint(.2),
        threePoint(.4),
      );
      final threeC = controller.sketchApi!.builders.line.build(
        threePoint(.4),
        threePoint(.6),
      );
      controller.beginSketchCircularSelection();
      for (final selected in [threeA, threeB, threeC]) {
        controller.selectSketchEntity(selected.id);
      }
      expect(controller.selectedSketchEntityIds, {
        threeA.id,
        threeB.id,
        threeC.id,
      });
      await controller.fitSelectedSketchCircularGeometry();
      final threeFit = controller.sketchApi!.entity(
        controller.selectedSketchEntityIds.single,
      );
      expect(threeFit, isA<SketchArc>());

      // A continuous chain with real but incompatible continuations still
      // replaces the selected sources and exposes a non-blocking warning.
      final fallbackBefore = controller.sketchApi!.builders.line.build(
        const SketchVector(399, 0),
        const SketchVector(400, 0),
      );
      final fallbackA = controller.sketchApi!.builders.line.build(
        const SketchVector(400, 0),
        const SketchVector(401, 1),
      );
      final fallbackB = controller.sketchApi!.builders.line.build(
        const SketchVector(401, 1),
        const SketchVector(402, 0),
      );
      final fallbackAfter = controller.sketchApi!.builders.line.build(
        const SketchVector(402, 0),
        const SketchVector(403, 0),
      );
      controller.beginSketchCircularSelection();
      controller.selectSketchEntity(fallbackA.id);
      controller.selectSketchEntity(fallbackB.id);
      await controller.fitSelectedSketchCircularGeometry();
      expect(
        controller.sketchApi!.entity(controller.selectedSketchEntityIds.single),
        isA<SketchArc>(),
      );
      expect(
        controller.sketchCircularFitMessage,
        contains('mínimos quadrados'),
      );
      expect(fallbackA.visible, isFalse);
      expect(fallbackB.visible, isFalse);
      expect(fallbackBefore.visible, isTrue);
      expect(fallbackAfter.visible, isTrue);

      // A rejected disconnected chain leaves its diagnostic available to the
      // panel instead of looking like a failed/cleared selection.
      final invalidA = controller.sketchApi!.builders.line.build(
        const SketchVector(300, 0),
        const SketchVector(301, 0),
      );
      final invalidB = controller.sketchApi!.builders.line.build(
        const SketchVector(304, 0),
        const SketchVector(305, 0),
      );
      controller.beginSketchCircularSelection();
      controller.selectSketchEntity(invalidA.id);
      controller.selectSketchEntity(invalidB.id);
      await controller.fitSelectedSketchCircularGeometry();
      expect(controller.sketchCircularFitMessage, contains('colineares'));
      // The measured gap is reported with the diagnostic.
      expect(controller.sketchCircularFitMessage, contains('gap máx'));

      controller.beginCircleCommand();
      expect(controller.selectedSketchEntityIds, isEmpty);
      expect(cad.runtime.scene.find(line.id)!.selected, isFalse);
      final circle = controller.sketchApi!.builders.circle.build(
        const SketchVector(20, 20),
        5,
      );
      await controller.updateSketchEntityParameters(circle.id, {'radius': 12});
      controller.selectSketchEntity(circle.id);
      expect(controller.selectedSketchEntityIds, {circle.id});
      expect(cad.runtime.scene.find(line.id)!.selected, isFalse);
      expect(cad.runtime.scene.find(circle.id)!.selected, isTrue);

      // A radius-only edit trims the two neighbors to tangent contact points.
      // One Undo must restore only that edit, not an earlier profile operation.
      final arc = controller.sketchApi!.builders.arc.build(
        const SketchVector(0, 0),
        1,
        0,
        math.pi / 2,
      );
      final preceding = controller.sketchApi!.builders.line.build(
        const SketchVector(1, -1),
        const SketchVector(1, 0),
      );
      final following = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 1),
        const SketchVector(-1, 1),
      );
      await controller.updateSketchEntityParameters(arc.id, {'radius': 1.5});
      SketchVector arcEnd(String key) {
        final current = controller.sketchApi!.entity(arc.id)!;
        final center = SketchVector.fromJson(current.parameters['center']);
        final radius = (current.parameters['radius'] as num).toDouble();
        final angle = (current.parameters['${key}Angle'] as num).toDouble();
        return SketchVector(
          center.x + radius * math.cos(angle),
          center.y + radius * math.sin(angle),
        );
      }

      expect(arcEnd('start').x, closeTo(1, 1e-9));
      expect(arcEnd('start').y, closeTo(-.5, 1e-9));
      expect(arcEnd('end').x, closeTo(-.5, 1e-9));
      expect(arcEnd('end').y, closeTo(1, 1e-9));
      final previousEnd = SketchVector.fromJson(
        controller.sketchApi!.entity(preceding.id)!.parameters['end'],
      );
      final nextStart = SketchVector.fromJson(
        controller.sketchApi!.entity(following.id)!.parameters['start'],
      );
      expect(previousEnd.y, closeTo(arcEnd('start').y, 1e-9));
      expect(nextStart.x, closeTo(arcEnd('end').x, 1e-9));
      final center = SketchVector.fromJson(
        controller.sketchApi!.entity(arc.id)!.parameters['center'],
      );
      final beforeDirection =
          previousEnd -
          SketchVector.fromJson(
            controller.sketchApi!.entity(preceding.id)!.parameters['start'],
          );
      final afterDirection =
          SketchVector.fromJson(
            controller.sketchApi!.entity(following.id)!.parameters['end'],
          ) -
          nextStart;
      expect((arcEnd('start') - center).dot(beforeDirection), closeTo(0, 1e-9));
      expect((arcEnd('end') - center).dot(afterDirection), closeTo(0, 1e-9));
      await controller.undo();
      expect(controller.sketchApi!.entity(arc.id), isNotNull);
      expect(controller.sketchApi!.entity(preceding.id), isNotNull);
      expect(controller.sketchApi!.entity(following.id), isNotNull);
      expect(controller.sketchApi!.entity(arc.id)!.parameters['radius'], 1);
      await controller.updateSketchEntityParameters(arc.id, {'radius': 1.5});
      expect(controller.sketchApi!.entity(arc.id)!.parameters['radius'], 1.5);

      await controller.setSketchEntityVisibility(circle.id, false);
      final gapLineA = controller.sketchApi!.builders.line.build(
        const SketchVector(200, 200),
        const SketchVector(201, 200),
      );
      final gapLineB = controller.sketchApi!.builders.line.build(
        const SketchVector(201.05, 200),
        const SketchVector(201.05, 201),
      );
      bool hasTestGap() => controller.sketchHealth
          .ofType(SketchHealthIssueType.gap)
          .any(
            (issue) =>
                issue.entityIds.contains(gapLineA.id) &&
                issue.entityIds.contains(gapLineB.id),
          );
      final gap = controller.sketchHealth
          .ofType(SketchHealthIssueType.gap)
          .firstWhere(
            (issue) =>
                issue.entityIds.contains(gapLineA.id) &&
                issue.entityIds.contains(gapLineB.id),
          );
      await controller.autoHealSketchGap(gap);
      expect(hasTestGap(), isFalse);
      await controller.undo();
      expect(hasTestGap(), isTrue);
      await controller.redo();
      expect(hasTestGap(), isFalse);
    },
  );

  test(
    'managed BREP reference is recognized as planar and blocks when orphaned',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'managed-reference-sketch-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final kernels = KernelManager()
        ..register(_HealthySurfaceKernel(), makeDefault: true);
      final cad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
      );
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
      );
      final projects = ProjectRepository(
        storage: LocalStorageService(rootDirectory: directory),
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
      await cad.runtime.open('managed-reference-sketch', directory);
      const hash =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const sourceId = 'managed-brep:source';
      const referenceId = 'managed-plane:source-face-3';
      const reference = ManagedCadReference.plane(
        sourceEntityId: sourceId,
        sourceFormat: 'brep',
        sourceShapeSha256: hash,
        faceIndex: 3,
        origin: Vector3(12, -8, 4),
        normal: Vector3(0, 1, 0),
        xDirection: Vector3(1, 0, 0),
      );
      await cad.runtime.mutate(
        command: 'test.managed-reference-support',
        upsert: [
          CadDocumentEntity(
            id: referenceId,
            kind: CadDocumentEntityKind.reference,
            data: {
              'name': 'Plano Source BREP F3',
              ManagedCadReference.dataKey: reference.toJson(),
              'sceneKind': 'plane',
              'sceneGeometry': {
                'origin': reference.origin.toJson(),
                'normal': reference.normal!.toJson(),
                'xDirection': reference.xDirection!.toJson(),
              },
            },
          ),
        ],
      );
      await controller.configureProject(
        projectId: 'managed-reference-sketch',
        projectDirectory: directory,
      );

      expect(controller.isPlanarSketchSupport(referenceId), isTrue);
      expect(
        () => controller.selectSketchSupport(referenceId),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('órfã'),
          ),
        ),
      );
    },
  );

  test(
    'preview persists, invalidates on edit, and section visibility undoes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sketch-stabilization-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final projects = ProjectRepository(
        storage: LocalStorageService(rootDirectory: directory),
      );

      Future<(DesktopCadController, OperationalReverseEngineeringController)>
      open() async {
        final kernels = KernelManager()
          ..register(_HealthySurfaceKernel(), makeDefault: true);
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
        await cad.runtime.open('stabilization-project', directory);
        await controller.configureProject(
          projectId: 'stabilization-project',
          projectDirectory: directory,
        );
        return (cad, controller);
      }

      final (cad, controller) = await open();
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      await controller.drawRectangle(
        const SketchVector(0, 0),
        const SketchVector(2, 2),
      );
      final constrainedLine = controller.sketchEntities
          .whereType<SketchLine>()
          .first;
      controller.constraintApi!.builders.horizontal.build([constrainedLine.id]);
      controller.constraintApi!.createDrivingDimension(
        type: SketchDimensionType.linear,
        references: [constrainedLine.id],
        value: 2,
      );
      expect(controller.constraints, isNotEmpty);
      expect(controller.dimensions, isNotEmpty);
      expect(controller.sketchReadyForSurface, isTrue);
      await controller.previewPlanarSurface();
      expect(controller.surfacePreviewActive, isTrue);
      expect(cad.runtime.scene.find('surface-preview'), isNotNull);
      await controller.undo();
      expect(controller.surfacePreviewActive, isFalse);
      expect(cad.runtime.scene.find('surface-preview'), isNull);
      await controller.redo();
      expect(controller.surfacePreviewActive, isTrue);
      expect(cad.runtime.scene.find('surface-preview'), isNotNull);
      await controller.persist();

      final (reopenedCad, reopened) = await open();
      expect(reopened.activeSketch, isNotNull);
      expect(reopened.constraints, isNotEmpty);
      expect(reopened.dimensions, isNotEmpty);
      expect(reopened.surfacePreviewActive, isTrue);
      expect(reopenedCad.runtime.scene.find('surface-preview'), isNotNull);

      final line = reopened.sketchEntities.whereType<SketchLine>().last;
      await reopened.updateSketchEntityParameters(line.id, {'length': 2.05});
      expect(reopened.surfacePreviewActive, isFalse);
      expect(reopenedCad.runtime.scene.find('surface-preview'), isNull);
      expect(reopened.previewPlanarSurface, throwsStateError);
      await reopened.undo();
      expect(reopened.surfacePreviewActive, isTrue);
      expect(reopenedCad.runtime.scene.find('surface-preview'), isNotNull);
      await reopened.redo();
      expect(reopened.surfacePreviewActive, isFalse);
      const sectionId = 'test-section';
      await reopenedCad.runtime.mutate(
        command: 'test.section',
        upsert: [
          CadDocumentEntity(
            id: sectionId,
            kind: CadDocumentEntityKind.section,
            data: {
              'name': 'Test Section',
              'sceneKind': 'curve',
              'sceneVisible': true,
              'sceneGeometry': {'segments': <List<List<double>>>[]},
            },
          ),
        ],
      );
      reopened.activeSketch!.metadata['sourceSectionId'] = sectionId;
      await reopened.persist();
      await reopened.toggleSourceSectionVisibility();
      expect(
        reopenedCad.runtime.document!.entities[sectionId]!.data['sceneVisible'],
        isFalse,
      );
      await reopened.undo();
      expect(
        reopenedCad.runtime.document!.entities[sectionId]!.data['sceneVisible'],
        isTrue,
      );
      await reopened.redo();
      expect(
        reopenedCad.runtime.document!.entities[sectionId]!.data['sceneVisible'],
        isFalse,
      );
    },
  );

  test(
    'surface preview uses the active closed profile when section leftovers exist',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'surface-leftovers-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final kernels = KernelManager()
        ..register(_HealthySurfaceKernel(), makeDefault: true);
      final cad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
      );
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
      );
      final projects = ProjectRepository(
        storage: LocalStorageService(rootDirectory: directory),
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
      await cad.runtime.open('surface-leftovers-project', directory);
      await controller.configureProject(
        projectId: 'surface-leftovers-project',
        projectDirectory: directory,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      await controller.drawRectangle(
        const SketchVector(0, 0),
        const SketchVector(4, 2),
      );
      final profileIds = controller.sketchEntities
          .map((entity) => entity.id)
          .toSet();
      final loose = controller.sketchApi!.builders.line.build(
        const SketchVector(20, 20),
        const SketchVector(21, 20),
      );

      final health = controller.sketchHealth;
      expect(health.readyForSurface, isTrue);
      expect(health.hasDisconnectedWarnings, isTrue);
      expect(health.activeProfileEntityIds, profileIds);
      expect(health.diagnosticEntityIds, contains(loose.id));

      await controller.previewPlanarSurface();
      expect(controller.surfacePreviewActive, isTrue);
      expect(cad.runtime.scene.find('surface-preview'), isNotNull);
    },
  );

  test('explicit tangency references drive the circular adjustment', () async {
    final directory = await Directory.systemTemp.createTemp('g124_1_tangency_');
    addTearDown(() => directory.delete(recursive: true));
    final kernels = KernelManager()
      ..register(_HealthySurfaceKernel(), makeDefault: true);
    final cad = DesktopCadController(
      kernels: kernels,
      projects: ProjectManager.instance,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    final projects = ProjectRepository(
      storage: LocalStorageService(rootDirectory: directory),
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
    await cad.runtime.open('g124-tangency', directory);
    await controller.configureProject(
      projectId: 'g124-tangency',
      projectDirectory: directory,
    );
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch();

    const radius = 8.0;
    const a0 = 0.9;
    const a1 = 1.5;
    SketchVector point(double angle) =>
        SketchVector(radius * math.cos(angle), radius * math.sin(angle));
    SketchVector tangent(double angle) =>
        SketchVector(-math.sin(angle), math.cos(angle));
    final middle = (a0 + a1) / 2;
    final chainA = controller.sketchApi!.builders.line.build(
      point(a0),
      point(middle),
    );
    final chainB = controller.sketchApi!.builders.line.build(
      point(middle),
      point(a1),
    );
    final startReference = controller.sketchApi!.builders.line.build(
      point(a0) - tangent(a0).scale(4),
      point(a0),
    );
    final endReference = controller.sketchApi!.builders.line.build(
      point(a1),
      point(a1) + tangent(a1).scale(4),
    );
    // Radial decoy on the start endpoint: the automatic inference would see a
    // branch, so the explicit reference is what makes the fit reliable.
    final decoy = controller.sketchApi!.builders.line.build(
      point(a0),
      point(a0) + SketchVector(math.cos(a0), math.sin(a0)).scale(3),
    );

    controller.beginSketchCircularSelection();
    controller.selectSketchEntity(chainA.id);
    controller.selectSketchEntity(chainB.id);
    expect(controller.selectedSketchEntityIds, {chainA.id, chainB.id});

    // Capturing a reference must not disturb the 2-3 curves being replaced.
    controller.beginSketchTangencyPick('start');
    expect(controller.sketchTangencyPickActive, isTrue);
    controller.selectSketchEntity(startReference.id);
    expect(controller.sketchTangencyStartId, startReference.id);
    expect(controller.sketchTangencyPickActive, isFalse);
    expect(controller.selectedSketchEntityIds, {chainA.id, chainB.id});
    controller.beginSketchTangencyPick('end');
    controller.selectSketchEntity(endReference.id);
    expect(controller.sketchTangencyEndId, endReference.id);
    expect(controller.selectedSketchEntityIds, {chainA.id, chainB.id});

    await controller.fitSelectedSketchCircularGeometry();
    final fitted = controller.sketchApi!.entity(
      controller.selectedSketchEntityIds.single,
    );
    expect(fitted, isA<SketchArc>());
    expect((fitted! as SketchArc).parameters['radius'], closeTo(radius, 1e-6));
    expect(
      controller.sketchCircularFitMessage,
      contains('C1 bilateral aplicado'),
    );
    expect(controller.sketchCircularFitMessage, contains('tangência manual'));
    expect(chainA.visible, isFalse);
    expect(chainB.visible, isFalse);
    expect(startReference.visible, isTrue);
    expect(endReference.visible, isTrue);
    expect(decoy.visible, isTrue);
    // A confirmed reconstruction never leaks its manual references into the
    // next one; the next multi-selection starts from a clean command state.
    expect(controller.sketchTangencyStartId, isNull);
    expect(controller.sketchTangencyEndId, isNull);
    expect(cad.runtime.scene.find(fitted.id)!.selected, isTrue);

    // The promotion is still recorded as a single sketch transaction, which is
    // the undo/redo boundary the command had before the manual references.
    expect(
      controller.sketchApi!.engine.history.entries
          .where((entry) => entry.targetId == 'sketch.reconstruction.accept')
          .isNotEmpty,
      isTrue,
    );

    // Toggle Sketch keeps hiding and showing the promoted arc root.
    await controller.toggleActiveSketchVisibility();
    expect(controller.activeSketchVisible, isFalse);
    await controller.toggleActiveSketchVisibility();
    expect(controller.activeSketchVisible, isTrue);

    // A reference that is not attached to the endpoint is rejected clearly.
    final stray = controller.sketchApi!.builders.line.build(
      const SketchVector(60, 60),
      const SketchVector(62, 60),
    );
    controller.beginSketchCircularSelection();
    controller.selectSketchEntity(chainA.id);
    controller.selectSketchEntity(chainB.id);
    controller.beginSketchTangencyPick('start');
    controller.selectSketchEntity(stray.id);
    await controller.fitSelectedSketchCircularGeometry();
    expect(
      controller.sketchCircularFitMessage,
      contains('próxima do endpoint'),
    );
    expect(chainA.visible, isFalse, reason: 'rejection must not replace');

    // Clearing the fields restores the automatic mode for the next fit.
    controller.clearSketchTangencyReferences();
    expect(controller.sketchTangencyStartId, isNull);
    expect(controller.sketchTangencyEndId, isNull);
    expect(controller.sketchTangencyPickActive, isFalse);

    // A reference whose curve is deleted is cleared with a specific message
    // instead of silently dropping back to the automatic inference.
    controller.beginSketchCircularSelection();
    controller.selectSketchEntity(chainA.id);
    controller.selectSketchEntity(chainB.id);
    final doomed = controller.sketchApi!.builders.line.build(
      const SketchVector(70, 70),
      const SketchVector(72, 70),
    );
    controller.beginSketchTangencyPick('start');
    controller.selectSketchEntity(doomed.id);
    expect(controller.sketchTangencyStartId, doomed.id);
    controller.sketchApi!.deleteEntity(doomed.id);
    await controller.fitSelectedSketchCircularGeometry();
    expect(controller.sketchCircularFitMessage, contains('não existe mais'));
    expect(controller.sketchTangencyStartId, isNull);
    expect(controller.sketchTangencyPickActive, isFalse);
  });

  test('multi region selection drives one arc through the command', () async {
    final directory = await Directory.systemTemp.createTemp('g124_1_regions_');
    addTearDown(() => directory.delete(recursive: true));
    final kernels = KernelManager()
      ..register(_HealthySurfaceKernel(), makeDefault: true);
    final cad = DesktopCadController(
      kernels: kernels,
      projects: ProjectManager.instance,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    final projects = ProjectRepository(
      storage: LocalStorageService(rootDirectory: directory),
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
    await cad.runtime.open('g124-regions', directory);
    await controller.configureProject(
      projectId: 'g124-regions',
      projectDirectory: directory,
    );
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch();

    const radius = 40.0;
    const a0 = 0.3;
    const a1 = 1.5;
    SketchVector point(double angle) =>
        SketchVector(200 + radius * math.cos(angle), radius * math.sin(angle));
    final sources = <SketchLine>[
      for (var index = 0; index < 5; index++)
        controller.sketchApi!.builders.line.build(
          point(a0 + (a1 - a0) * index / 5),
          point(a0 + (a1 - a0) * (index + 1) / 5),
        ),
    ];

    controller.beginSketchCircularSelection();
    // Deliberately out of order, like real viewport picking.
    for (final entity in [
      sources[2],
      sources[0],
      sources[4],
      sources[1],
      sources[3],
    ]) {
      controller.selectSketchEntity(entity.id);
    }
    expect(controller.selectedSketchEntityIds, hasLength(5));
    expect(controller.sketchCircularMaxRegions, greaterThanOrEqualTo(5));

    await controller.fitSelectedSketchCircularGeometry();
    final fitted = controller.sketchApi!.entity(
      controller.selectedSketchEntityIds.single,
    );
    expect(fitted, isA<SketchArc>());
    expect((fitted! as SketchArc).parameters['radius'], closeTo(radius, 1e-6));
    expect(controller.sketchCircularFitMessage, contains('raio 40.000 mm'));
    for (final source in sources) {
      expect(source.visible, isFalse);
    }
    expect(cad.runtime.scene.find(fitted.id)!.selected, isTrue);

    // A rejected selection never replaces the sources.
    final collinear = [
      controller.sketchApi!.builders.line.build(
        const SketchVector(300, 0),
        const SketchVector(301, 0),
      ),
      controller.sketchApi!.builders.line.build(
        const SketchVector(301, 0),
        const SketchVector(302, 0),
      ),
    ];
    controller.beginSketchCircularSelection();
    for (final entity in collinear) {
      controller.selectSketchEntity(entity.id);
    }
    await controller.fitSelectedSketchCircularGeometry();
    expect(controller.sketchCircularFitMessage, contains('colineares'));
    expect(collinear.every((entity) => entity.visible), isTrue);
  });

  test(
    'confirmation hides every used region and keeps the rest visible',
    () async {
      final directory = await Directory.systemTemp.createTemp('g124_1_visib_');
      addTearDown(() => directory.delete(recursive: true));
      final kernels = KernelManager()
        ..register(_HealthySurfaceKernel(), makeDefault: true);
      final cad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
      );
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
      );
      final projects = ProjectRepository(
        storage: LocalStorageService(rootDirectory: directory),
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
      await cad.runtime.open('g124-visibility', directory);
      await controller.configureProject(
        projectId: 'g124-visibility',
        projectDirectory: directory,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();

      const radius = 30.0;
      const a0 = 0.4;
      const a1 = 1.6;
      SketchVector point(double angle) => SketchVector(
        150 + radius * math.cos(angle),
        radius * math.sin(angle),
      );
      SketchVector tangent(double angle) =>
          SketchVector(-math.sin(angle), math.cos(angle));
      final sources = <SketchLine>[
        for (var index = 0; index < 5; index++)
          controller.sketchApi!.builders.line.build(
            point(a0 + (a1 - a0) * index / 5),
            point(a0 + (a1 - a0) * (index + 1) / 5),
          ),
      ];
      // A curve that is NOT part of the selection must stay visible.
      final untouched = controller.sketchApi!.builders.line.build(
        const SketchVector(400, 200),
        const SketchVector(430, 210),
      );
      // This is an unselected Section fragment inside the span. It duplicates
      // the future arc and must be cleaned with the selected source chain.
      final overlapping = controller.sketchApi!.builders.line.build(
        point(.85),
        point(1.05),
      );
      // Its endpoints lie on the same arc, but this long chord cuts through
      // the interior. The intermediate coverage sample must keep it visible.
      final longChord = controller.sketchApi!.builders.line.build(
        point(a0 + .05),
        point(a1 - .05),
      );
      final startReference = controller.sketchApi!.builders.line.build(
        point(a0) - tangent(a0).scale(6),
        point(a0),
      );
      final endReference = controller.sketchApi!.builders.line.build(
        point(a1),
        point(a1) + tangent(a1).scale(6),
      );

      controller.beginSketchCircularSelection();
      for (final entity in sources) {
        controller.selectSketchEntity(entity.id);
      }
      expect(controller.selectedSketchEntityIds, hasLength(5));

      await controller.fitSelectedSketchCircularGeometry();
      expect(controller.sketchCircularFitConfirmed, isTrue);
      final arcId = controller.selectedSketchEntityIds.single;
      final arc = controller.sketchApi!.entity(arcId);
      expect(arc, isA<SketchArc>());

      // 1. Every selected region that took part in the fit is hidden, in the
      //    engine and in the document/scene state.
      for (final source in sources) {
        expect(source.visible, isFalse, reason: source.id);
        expect(cad.runtime.scene.find(source.id)!.visible, isFalse);
        expect(
          cad.runtime.document!.entities[source.id]!.data['sceneVisible'],
          isFalse,
        );
      }
      // 2. Geometry outside the selection, including the tangent references,
      //    keeps its visibility.
      expect(untouched.visible, isTrue);
      expect(cad.runtime.scene.find(untouched.id)!.visible, isTrue);
      expect(overlapping.visible, isFalse);
      expect(cad.runtime.scene.find(overlapping.id)!.visible, isFalse);
      expect(longChord.visible, isTrue);
      expect(cad.runtime.scene.find(longChord.id)!.visible, isTrue);
      expect(startReference.visible, isTrue);
      expect(endReference.visible, isTrue);
      // 3. The new arc is the only active geometry on that stretch.
      expect(cad.runtime.scene.find(arcId)!.visible, isTrue);
      expect(cad.runtime.scene.find(arcId)!.selected, isTrue);
      expect(controller.sketchCircularFitMessage, contains('confirmado'));
      expect(controller.sketchCircularFitMessage, contains('usada(s)'));
      expect(controller.sketchCircularFitMessage, contains('ocultas 5/5'));

      // 4. Tangency measured on the FINAL arc against the reference lines: both
      //    junctions must be below the 1 deg tolerance.
      final arcEntity = arc! as SketchArc;
      final center = SketchVector.fromJson(arcEntity.parameters['center']);
      final arcRadius = (arcEntity.parameters['radius'] as num).toDouble();
      double lineAngleDegrees(
        double angle,
        SketchVector referenceStart,
        SketchVector referenceEnd,
      ) {
        final arcTangent = SketchVector(-math.sin(angle), math.cos(angle));
        final reference = referenceEnd - referenceStart;
        final cosine =
            (arcTangent.dot(reference) /
                    (math.sqrt(arcTangent.dot(arcTangent)) *
                        math.sqrt(reference.dot(reference))))
                .abs()
                .clamp(0.0, 1.0);
        return math.acos(cosine) * 180 / math.pi;
      }

      final startAngle = (arcEntity.parameters['startAngle'] as num).toDouble();
      final endAngle = (arcEntity.parameters['endAngle'] as num).toDouble();
      expect(
        lineAngleDegrees(
          startAngle,
          point(a0) - tangent(a0).scale(6),
          point(a0),
        ),
        lessThan(1.0),
      );
      expect(
        lineAngleDegrees(endAngle, point(a1), point(a1) + tangent(a1).scale(6)),
        lessThan(1.0),
      );
      // The preserved endpoints are where the arc meets the references.
      final startPoint = SketchVector(
        center.x + arcRadius * math.cos(startAngle),
        center.y + arcRadius * math.sin(startAngle),
      );
      final endPoint = SketchVector(
        center.x + arcRadius * math.cos(endAngle),
        center.y + arcRadius * math.sin(endAngle),
      );
      expect(
        [startPoint, endPoint].any(
          (candidate) =>
              (candidate.x - point(a0).x).abs() < 1e-3 &&
              (candidate.y - point(a0).y).abs() < 1e-3,
        ),
        isTrue,
      );
      expect(
        [startPoint, endPoint].any(
          (candidate) =>
              (candidate.x - point(a1).x).abs() < 1e-3 &&
              (candidate.y - point(a1).y).abs() < 1e-3,
        ),
        isTrue,
      );

      // 5. Undo/Redo and Toggle Sketch keep working with the hidden sources.
      final engine = controller.sketchApi!.engine;
      expect(engine.undo(), isTrue);
      // Undo/Redo restore deserialized entities, so re-read them by id.
      bool sourcesVisible() => sources.every(
        (entity) => controller.sketchApi!.entity(entity.id)?.visible == true,
      );
      expect(sourcesVisible(), isTrue);
      expect(engine.redo(), isTrue);
      expect(
        sources.every(
          (entity) => controller.sketchApi!.entity(entity.id)?.visible == false,
        ),
        isTrue,
      );
      await controller.toggleActiveSketchVisibility();
      expect(controller.activeSketchVisible, isFalse);
      await controller.toggleActiveSketchVisibility();
      expect(controller.activeSketchVisible, isTrue);
      expect(
        sources.every(
          (entity) => controller.sketchApi!.entity(entity.id)?.visible == false,
        ),
        isTrue,
      );

      // Confirmation leaves the created arc selected for inspection, but a
      // second click without starting a fresh multi-selection must not reuse it.
      await controller.fitSelectedSketchCircularGeometry();
      expect(controller.sketchCircularFitConfirmed, isTrue);
      expect(controller.selectedSketchEntityIds, {arcId});
      expect(cad.runtime.scene.find(arcId)!.visible, isTrue);
      expect(cad.runtime.scene.find(arcId)!.selected, isTrue);
      expect(
        controller.sketchCircularFitMessage,
        'Selecione novamente as regiões para criar outro arco',
      );

      // A new attempt that fails must drop the confirmed state (without going
      // through a fresh multi selection first) while keeping its own message.
      final flatA = controller.sketchApi!.builders.line.build(
        const SketchVector(600, 0),
        const SketchVector(601, 0),
      );
      final flatB = controller.sketchApi!.builders.line.build(
        const SketchVector(601, 0),
        const SketchVector(602, 0),
      );
      controller.beginSketchCircularSelection();
      controller.selectSketchEntity(flatA.id);
      controller.selectSketchEntity(flatB.id);
      await controller.fitSelectedSketchCircularGeometry();
      expect(controller.sketchCircularFitConfirmed, isFalse);
      expect(controller.sketchCircularFitMessage, contains('colineares'));
    },
  );
}

class _HealthySurfaceKernel
    implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'g124-test',
    name: 'G-124 test kernel',
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
