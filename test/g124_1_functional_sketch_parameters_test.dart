import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/desktop/desktop_application.dart';
import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/managed_cad_reference.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/arc_radius_edit_planner.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/import_export/api/import_export_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_assistant/sketch_reconstruction.dart';
import 'package:flcad_mobile/core/sketch_assistant/sketch_continuity_repair_planner.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/engine/sketch_engine.dart';
import 'package:flcad_mobile/core/sketch_engine/history/sketch_history.dart';
import 'package:flcad_mobile/core/sketch_engine/repository/sketch_repository.dart';
import 'package:flcad_mobile/core/sketch_editor/health/sketch_health_analyzer.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/app/runtime/world_coordinate_system.dart';
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
      final historyBeforeConfirmation =
          controller.sketchApi!.engine.history.entries.length;
      final commandHistoryBeforeConfirmation =
          controller.commands.manager.history.length;
      await expectLater(
        controller.updateSketchEntityParameters(arc.id, {'radius': 1.5}),
        throwsA(
          isA<ArcRadiusEditConfirmationRequired>().having(
            (failure) => failure.details,
            'details',
            containsPair('requestedRadiusMm', 1.5),
          ),
        ),
      );
      expect(arc.parameters['radius'], 1.0);
      expect(
        controller.sketchApi!.engine.history.entries.length,
        historyBeforeConfirmation,
      );
      expect(
        controller.commands.manager.history.length,
        commandHistoryBeforeConfirmation,
      );
      final firstPreview = controller.arcRadiusEditPreview;
      expect(firstPreview, isNotNull);
      expect(
        cad.runtime.scene.find('arc-radius-preview-${firstPreview!.token}'),
        isNotNull,
      );
      controller.cancelArcRadiusEditPreview();
      expect(controller.arcRadiusEditPreview, isNull);
      expect(
        cad.runtime.scene.find('arc-radius-preview-${firstPreview.token}'),
        isNull,
      );
      await expectLater(
        controller.updateSketchEntityParameters(arc.id, {'radius': 1.5}),
        throwsA(isA<ArcRadiusEditConfirmationRequired>()),
      );
      await controller.confirmArcRadiusEditPreview();
      expect(controller.arcRadiusEditPreview, isNull);
      expect(controller.sketchApi!.entity(arc.id)!.parameters['radius'], 1.5);
      await controller.undo();
      expect(controller.sketchApi!.entity(arc.id)!.parameters['radius'], 1);
      await controller.redo();
      expect(controller.sketchApi!.entity(arc.id)!.parameters['radius'], 1.5);
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
      await controller.updateSketchEntityParameters(arc.id, {
        'radius': 1.5,
      }, confirmAdjacent: true);
      expect(controller.sketchApi!.entity(arc.id)!.parameters['radius'], 1.5);

      // A larger radius moves both tangent contacts beyond the original line
      // spans. The edit must extend the frontiers instead of falling back to
      // the old arc endpoints and losing C1 continuity.
      await controller.updateSketchEntityParameters(arc.id, {
        'radius': 3,
      }, confirmAdjacent: true);
      expect(arcEnd('start').x, closeTo(1, 1e-9));
      expect(arcEnd('start').y, closeTo(-2, 1e-9));
      expect(arcEnd('end').x, closeTo(-2, 1e-9));
      expect(arcEnd('end').y, closeTo(1, 1e-9));
      final extendedPreviousEnd = SketchVector.fromJson(
        controller.sketchApi!.entity(preceding.id)!.parameters['end'],
      );
      final extendedNextStart = SketchVector.fromJson(
        controller.sketchApi!.entity(following.id)!.parameters['start'],
      );
      expect(extendedPreviousEnd.y, closeTo(-2, 1e-9));
      expect(extendedNextStart.x, closeTo(-2, 1e-9));
      final centerAtThree = SketchVector.fromJson(
        controller.sketchApi!.entity(arc.id)!.parameters['center'],
      );
      final extendedBeforeDirection =
          extendedPreviousEnd -
          SketchVector.fromJson(
            controller.sketchApi!.entity(preceding.id)!.parameters['start'],
          );
      final extendedAfterDirection =
          SketchVector.fromJson(
            controller.sketchApi!.entity(following.id)!.parameters['end'],
          ) -
          extendedNextStart;
      expect(
        (arcEnd('start') - centerAtThree).dot(extendedBeforeDirection),
        closeTo(0, 1e-9),
      );
      expect(
        (arcEnd('end') - centerAtThree).dot(extendedAfterDirection),
        closeTo(0, 1e-9),
      );
      await controller.undo();
      expect(controller.sketchApi!.entity(arc.id)!.parameters['radius'], 1.5);
      await controller.redo();
      expect(controller.sketchApi!.entity(arc.id)!.parameters['radius'], 3);

      // Reducing the radius shortens the same frontiers and keeps the contact
      // perpendicular to both line directions.
      await controller.updateSketchEntityParameters(arc.id, {
        'radius': .5,
      }, confirmAdjacent: true);
      expect(arcEnd('start').y, closeTo(.5, 1e-9));
      expect(arcEnd('end').x, closeTo(.5, 1e-9));

      // A reconstructed arc with only one discoverable frontier must reject
      // the edit atomically instead of falling back to isolated endpoints.
      final rejectedArc = controller.sketchApi!.builders.arc.build(
        const SketchVector(20, 20),
        1,
        0,
        math.pi / 2,
      );
      rejectedArc.metadata['reconstructionKind'] = 'arc';
      final onlyFrontier = controller.sketchApi!.builders.line.build(
        const SketchVector(21, 19),
        const SketchVector(21, 20),
      );
      await expectLater(
        controller.updateSketchEntityParameters(rejectedArc.id, {
          'radius': 1.5,
        }),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            contains(
              'Não foi possível manter a tangência nas duas fronteiras.',
            ),
          ),
        ),
      );
      expect(
        controller.sketchApi!.entity(rejectedArc.id)!.parameters['radius'],
        1,
      );
      expect(
        SketchVector.fromJson(
          controller.sketchApi!.entity(onlyFrontier.id)!.parameters['end'],
        ).y,
        20,
      );

      // Frontier endpoints from a scanned Section can miss the old arc by a
      // small amount and still must be extended to the new tangent contacts.
      final gappedArc = controller.sketchApi!.builders.arc.build(
        const SketchVector(40, 40),
        1,
        0,
        math.pi / 2,
      );
      controller.sketchApi!.builders.line.build(
        const SketchVector(41, 39),
        const SketchVector(41, 40.05),
      );
      controller.sketchApi!.builders.line.build(
        const SketchVector(39.95, 41),
        const SketchVector(39, 41),
      );
      await controller.updateSketchEntityParameters(gappedArc.id, {
        'radius': 1.5,
      }, confirmAdjacent: true);
      expect(
        controller.sketchApi!.entity(gappedArc.id)!.parameters['radius'],
        1.5,
      );

      // Clockwise (concave) arcs use the same bilateral tangent solution.
      final concaveArc = controller.sketchApi!.builders.arc.build(
        const SketchVector(60, 0),
        1,
        0,
        -math.pi / 2,
      );
      controller.sketchApi!.builders.line.build(
        const SketchVector(61, 1),
        const SketchVector(61, 0),
      );
      controller.sketchApi!.builders.line.build(
        const SketchVector(60, -1),
        const SketchVector(59, -1),
      );
      await controller.updateSketchEntityParameters(concaveArc.id, {
        'radius': 1.5,
      }, confirmAdjacent: true);
      expect(
        controller.sketchApi!.entity(concaveArc.id)!.parameters['radius'],
        1.5,
      );

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
    'real STL Section publishes an exact non-pickable reference overlay',
    () async {
      final harness = await _g124Harness('g124-7f-real-section');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      const mesh = KernelMeshHandle(
        persistentId: 'mesh-shape',
        kernelId: 'test',
        fingerprint: 'mesh',
        vertexCount: 4,
        triangleCount: 4,
        bounds: KernelBounds(-1, -1, -1, 1, 1, 1),
        hasNormals: false,
        metadata: {},
      );
      await harness.cad.runtime.registerImport(
        const ImportedCadDocument(
          id: 'Mesh001',
          projectId: 'g124-7f-real-section',
          sourcePath: 'mesh.stl',
          format: CadImportFormat.stl,
          registeredPath: 'CAD/Imports/mesh.stl',
          validation: [],
          mesh: mesh,
        ),
        geometry: const KernelMeshGeometry(
          nodes: [-1, -1, -1, 1, -1, 1, 0, 1, -1, 0, 0, 1],
          triangles: [0, 1, 2, 0, 3, 1, 1, 3, 2, 2, 3, 0],
        ),
      );
      final section = await harness.controller.sections.create(
        planeId:
            '${WorldCoordinateSystem.prefix('g124-7f-real-section')}xy-plane',
        origin: Vector3.zero,
        normal: const Vector3(0, 0, 1),
      );
      final raw = section.data['section'] as Map;
      final sourceSegments = raw['segments'] as List;
      expect(sourceSegments, isNotEmpty);
      await harness.cad.runtime.setEntityVisibility(section.id, false);

      final api = harness.controller.sketchApi!;
      final sketch = api.createSketch('Real Section comparison');
      sketch.metadata['sourceSectionId'] = section.id;
      api.openSketch(sketch.id);
      api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      await harness.controller.reopenSketchForEditing(sketch.id);
      final overlay = harness.cad.runtime.scene.find(
        '$sketchOriginalSectionReferencePrefix${section.id}',
      );
      expect(overlay, isNotNull);
      expect(overlay!.kind, CadSceneEntityKind.preview);
      expect(overlay.geometry['displayColor'], 'originalSectionReference');
      expect(overlay.geometry['segments'], sourceSegments);
      expect(overlay.geometry['nonSelectable'], isTrue);
      expect(
        harness.cad.runtime.document!.entities.containsKey(overlay.id),
        isFalse,
      );
    },
  );

  test(
    'open Section reference uses the original samples without fitting',
    () async {
      final harness = await _g124Harness('g124-7f-open-section');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final controller = harness.controller;
      final api = controller.sketchApi!;
      const sectionId = 'ReferenceCurveOpen';
      const segments = <List<List<double>>>[
        [
          [0, 0, 0],
          [4, 1, 0],
        ],
        [
          [4, 1, 0],
          [8, 0, 0],
        ],
      ];
      await harness.cad.runtime.mutate(
        command: 'test.original-open-section',
        upsert: [
          CadDocumentEntity(
            id: sectionId,
            kind: CadDocumentEntityKind.section,
            data: {
              'referenceCurve': true,
              'sceneKind': 'curve',
              'sceneVisible': false,
              'sceneGeometry': {'segments': segments},
              'section': {'segments': segments, 'closed': false, 'open': true},
            },
          ),
        ],
      );
      final sketch = api.createSketch('Open Section comparison');
      sketch.metadata['sourceSectionId'] = sectionId;
      api.openSketch(sketch.id);
      api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(8, 0),
      );
      await controller.reopenSketchForEditing(sketch.id);
      final overlay = harness.cad.runtime.scene.find(
        '$sketchOriginalSectionReferencePrefix$sectionId',
      );
      expect(overlay, isNotNull);
      expect(overlay!.geometry['segments'], segments);
      expect(overlay.geometry['displayColor'], 'originalSectionReference');
      expect(
        controller.activeSketchSourceSection!.data['section']['open'],
        isTrue,
      );
    },
  );

  test(
    'original Section reference overlay stays exact, hidden from picking, and persists',
    () async {
      final harness = await _g124Harness('g124-7f-section-reference');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final controller = harness.controller;
      final cad = harness.cad;
      const sectionId = 'ReferenceCurve001';
      const segments = <List<List<double>>>[
        [
          [0, 0, 0],
          [10, 0, 0],
        ],
        [
          [10, 0, 0],
          [10, 10, 0],
        ],
        [
          [10, 10, 0],
          [0, 10, 0],
        ],
        [
          [0, 10, 0],
          [0, 0, 0],
        ],
      ];
      await cad.runtime.mutate(
        command: 'test.original-section',
        upsert: [
          CadDocumentEntity(
            id: sectionId,
            kind: CadDocumentEntityKind.section,
            data: {
              'name': 'Original STL Section',
              'referenceCurve': true,
              'sceneKind': 'curve',
              'sceneVisible': false,
              'sceneGeometry': {'segments': segments, 'referenceCurve': true},
              'section': {'segments': segments, 'closed': true, 'open': false},
            },
          ),
        ],
      );

      final api = controller.sketchApi!;
      final sketch = api.createSketch(
        'Section comparison',
        plane: SketchPlane(type: SketchPlaneType.xy),
        coordinates: const SketchCoordinateSystem(),
      );
      sketch.metadata['sourceSectionId'] = sectionId;
      sketch.metadata['originalSectionReferenceVisible'] = true;
      api.openSketch(sketch.id);
      api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      await controller.reopenSketchForEditing(sketch.id);

      final overlayId = '$sketchOriginalSectionReferencePrefix$sectionId';
      final overlay = cad.runtime.scene.find(overlayId);
      expect(overlay, isNotNull);
      expect(overlay!.kind, CadSceneEntityKind.preview);
      expect(overlay.visible, isTrue);
      expect(overlay.geometry['displayColor'], 'originalSectionReference');
      expect(overlay.geometry['strokeWidth'], 0.9);
      expect(overlay.geometry['nonSelectable'], isTrue);
      expect(overlay.geometry['segments'], segments);
      expect(cad.runtime.document!.entities.containsKey(overlayId), isFalse);
      expect(api.entity(overlayId), isNull);
      expect(
        cad.runtime.document!.entities[sectionId]!.data['sceneVisible'],
        isFalse,
      );
      expect(controller.sketchHealth.issues, isNot(contains(overlayId)));

      await controller.toggleOriginalSectionReferenceVisibility();
      expect(cad.runtime.scene.find(overlayId), isNull);
      await controller.undo();
      expect(cad.runtime.scene.find(overlayId)!.visible, isTrue);
      await controller.redo();
      expect(cad.runtime.scene.find(overlayId), isNull);
      await controller.toggleOriginalSectionReferenceVisibility();
      expect(cad.runtime.scene.find(overlayId)!.visible, isTrue);

      await controller.toggleActiveSketchVisibility();
      expect(cad.runtime.scene.find(overlayId), isNull);
      await controller.toggleActiveSketchVisibility();
      expect(cad.runtime.scene.find(overlayId)!.visible, isTrue);
      await controller.persist();

      final reopenedKernels = KernelManager()
        ..register(_HealthySurfaceKernel(), makeDefault: true);
      final reopenedCad = DesktopCadController(
        kernels: reopenedKernels,
        projects: ProjectManager.instance,
      );
      final reopenedCommands = DesktopCommandCoordinator(
        cad: reopenedCad,
        projects: ProjectManager.instance,
      );
      final reopened = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: reopenedCommands,
        runtime: reopenedCad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(
            repository: ReferenceRepository(projects: harness.projects),
          ),
        ),
      );
      addTearDown(reopened.dispose);
      addTearDown(reopenedCad.dispose);
      await reopenedCad.runtime.open(
        'g124-7f-section-reference',
        harness.directory,
      );
      await reopened.configureProject(
        projectId: 'g124-7f-section-reference',
        projectDirectory: harness.directory,
      );
      await reopened.reopenSketchForEditing(sketch.id);
      expect(reopened.activeSketchSourceSection!.id, sectionId);
      expect(reopened.originalSectionReferenceVisible, isTrue);
      expect(reopenedCad.runtime.scene.find(overlayId), isNotNull);
      expect(
        reopenedCad.runtime.scene.find(overlayId)!.geometry['segments'],
        segments,
      );
      expect(
        reopenedCad.runtime.scene.find(overlayId)!.kind,
        CadSceneEntityKind.preview,
      );
      expect(
        reopenedCad.runtime.document!.entities[sectionId]!.data['sceneVisible'],
        isFalse,
      );
      expect(
        reopenedCad.runtime.document!.entities.containsKey(overlayId),
        isFalse,
      );
      await reopened.toggleOriginalSectionReferenceVisibility();
      expect(reopenedCad.runtime.scene.find(overlayId), isNull);
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
    // Directed radius dimensions use the same transient preview contract as
    // the Inspector and only create the dimension after explicit confirmation.
    final dimensionArc = controller.sketchApi!.builders.arc.build(
      const SketchVector(100, 100),
      1,
      0,
      math.pi / 2,
    );
    controller.sketchApi!.builders.line.build(
      const SketchVector(101, 99),
      const SketchVector(101, 100),
    );
    controller.sketchApi!.builders.line.build(
      const SketchVector(99, 101),
      const SketchVector(98, 101),
    );
    controller.selectedSketchEntityIds
      ..clear()
      ..add(dimensionArc.id);
    controller.runtime.select({dimensionArc.id});
    await controller.createDrivingDimension(SketchDimensionType.radius, 1.5);
    expect(controller.arcRadiusEditPreview, isNotNull);
    expect(controller.dimensions, isEmpty);
    controller.cancelArcRadiusEditPreview();
    expect(controller.arcRadiusEditPreview, isNull);
    await controller.createDrivingDimension(SketchDimensionType.radius, 1.5);
    expect(controller.arcRadiusEditPreview, isNotNull);
    await controller.confirmArcRadiusEditPreview();
    expect(controller.arcRadiusEditPreview, isNull);
    expect(controller.dimensions, hasLength(1));

    // A geometry change between preview and Apply invalidates the token and
    // leaves the original arc untouched instead of silently replanning.
    final staleArc = controller.sketchApi!.builders.arc.build(
      const SketchVector(120, 120),
      1,
      0,
      math.pi / 2,
    );
    final staleLine = controller.sketchApi!.builders.line.build(
      const SketchVector(121, 119),
      const SketchVector(121, 120),
    );
    controller.sketchApi!.builders.line.build(
      const SketchVector(119, 121),
      const SketchVector(118, 121),
    );
    await expectLater(
      controller.updateSketchEntityParameters(staleArc.id, {'radius': 1.5}),
      throwsA(isA<ArcRadiusEditConfirmationRequired>()),
    );
    expect(controller.arcRadiusEditPreview, isNotNull);
    controller.sketchApi!.updateParameters(staleLine.id, {'endY': 120.1});
    await controller.confirmArcRadiusEditPreview();
    expect(controller.arcRadiusEditPreview, isNull);
    expect(controller.error, contains('obsoleto'));
    expect(staleArc.parameters['radius'], 1.0);
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
    'multi region line fit promotes only selected regions and resets the session',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'g124_1_line_fit_',
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
      await cad.runtime.open('g124-line-fit', directory);
      await controller.configureProject(
        projectId: 'g124-line-fit',
        projectDirectory: directory,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();

      final sources = <SketchLine>[
        for (var index = 0; index < 5; index++)
          controller.sketchApi!.builders.line.build(
            SketchVector(index * 25.0, 0),
            SketchVector(index * 25.0 + 5, 0),
          ),
      ];
      final untouched = controller.sketchApi!.builders.line.build(
        const SketchVector(300, 10),
        const SketchVector(310, 10),
      );

      controller.beginSketchCircularSelection();
      for (final source in [
        sources[3],
        sources[0],
        sources[4],
        sources[1],
        sources[2],
      ]) {
        controller.selectSketchEntity(source.id);
      }
      controller.setSketchRegionFitOutput(SketchRegionFitOutput.line);
      await controller.fitSelectedSketchLineOrSpline();

      final fittedId = controller.selectedSketchEntityIds.single;
      final fitted = controller.sketchApi!.entity(fittedId);
      expect(fitted, isA<SketchLine>());
      expect(controller.sketchCircularSelectionMode, isFalse);
      expect(controller.sketchRegionFitMessage, contains('5 regi'));
      expect(controller.sketchRegionFitMessage, contains('RMS'));
      expect(sources.every((source) => source.visible == false), isTrue);
      expect(untouched.visible, isTrue);
      expect(cad.runtime.scene.find(fittedId)!.visible, isTrue);
      expect(cad.runtime.scene.find(fittedId)!.selected, isTrue);
      expect(
        cad.runtime.scene.find(fittedId)!.geometry['displayColor'],
        'regionFitNavy',
      );
      final referenceId = 'region-fit-reference-$fittedId';
      expect(cad.runtime.scene.find(referenceId)!.visible, isTrue);
      expect(
        cad.runtime.scene.find(referenceId)!.geometry['displayColor'],
        'referenceCurve',
      );
      expect(cad.runtime.document!.entities.containsKey(referenceId), isFalse);
      expect(controller.activeSketch!.entityIds, isNot(contains(referenceId)));
      expect(controller.sketchRegionFitComparison!.rms, closeTo(0, 1e-9));
      expect(controller.sketchRegionFitComparison!.maximum, closeTo(0, 1e-9));

      // A completed session must not consume the promoted line on a second run.
      await controller.fitSelectedSketchLineOrSpline();
      expect(controller.selectedSketchEntityIds, {fittedId});
      expect(
        controller.sketchRegionFitMessage,
        contains('Selecione novamente as regi'),
      );

      final fittedStart = SketchVector.fromJson(
        (controller.sketchApi!.entity(fittedId)! as SketchLine)
            .parameters['start'],
      );
      final fittedEnd = SketchVector.fromJson(
        (controller.sketchApi!.entity(fittedId)! as SketchLine)
            .parameters['end'],
      );

      Future<void> expectFitApplied() async {
        expect(controller.sketchApi!.entity(fittedId), isA<SketchLine>());
        expect(
          SketchVector.fromJson(
            controller.sketchApi!.entity(fittedId)!.parameters['start'],
          ).x,
          closeTo(fittedStart.x, 1e-9),
        );
        expect(
          SketchVector.fromJson(
            controller.sketchApi!.entity(fittedId)!.parameters['end'],
          ).x,
          closeTo(fittedEnd.x, 1e-9),
        );
        expect(
          sources.every(
            (source) =>
                controller.sketchApi!.entity(source.id)?.visible == false,
          ),
          isTrue,
        );
        expect(
          sources.every(
            (source) =>
                cad
                    .runtime
                    .document!
                    .entities[source.id]!
                    .data['sceneVisible'] ==
                false,
          ),
          isTrue,
        );
        expect(untouched.visible, isTrue);
        expect(cad.runtime.scene.find(fittedId)!.visible, isTrue);
        expect(cad.runtime.scene.find(referenceId)!.visible, isTrue);
        expect(
          cad.runtime.document!.entities.containsKey(referenceId),
          isFalse,
        );
      }

      Future<void> expectFitUndone() async {
        expect(controller.sketchApi!.entity(fittedId), isNull);
        expect(cad.runtime.document!.entities.containsKey(fittedId), isFalse);
        expect(cad.runtime.scene.find(fittedId), isNull);
        expect(cad.runtime.scene.find(referenceId), isNull);
        expect(
          sources.every(
            (source) =>
                controller.sketchApi!.entity(source.id)?.visible == true,
          ),
          isTrue,
        );
        expect(
          sources.every(
            (source) => cad.runtime.scene.find(source.id)?.visible == true,
          ),
          isTrue,
        );
        expect(untouched.visible, isTrue);
      }

      // Global history (Ctrl+Z / Ctrl+Y) is in-session only. The command
      // manager never restores _undo/_redo from persist()+close+reopen.
      await controller.undo();
      await expectFitUndone();
      await controller.redo();
      await expectFitApplied();
      await controller.undo();
      await expectFitUndone();
      await controller.redo();
      await expectFitApplied();

      final engine = controller.sketchApi!.engine;
      await controller.toggleActiveSketchVisibility();
      await controller.toggleActiveSketchVisibility();
      expect(
        sources.every(
          (source) => controller.sketchApi!.entity(source.id)?.visible == false,
        ),
        isTrue,
      );
      await controller.toggleActiveSketchVisibility();
      expect(cad.runtime.scene.find(referenceId), isNull);
      await controller.toggleActiveSketchVisibility();
      expect(cad.runtime.scene.find(referenceId)!.visible, isTrue);

      // Region-fit dragging is a rigid translation of the promoted entity only.
      final camera = CadCameraController()..resize(1000, 700);
      final pick = CadViewportPick(
        entityId: fittedId,
        hit: const MeshHit(
          triangleIndex: 0,
          point: Vector3(0, 0, 0),
          distance: 0,
        ),
      );
      final lineBeforeCancel = SketchVector.fromJson(
        controller.sketchApi!.entity(fittedId)!.parameters['start'],
      );
      controller.beginSketchEntityDrag(pick, const Offset(500, 350), camera);
      controller.updateSketchEntityDrag(const Offset(580, 350), camera);
      expect(controller.sketchRegionFitComparison!.maximum, greaterThan(0));
      controller.cancelSketchEntityDrag();
      expect(
        SketchVector.fromJson(
          controller.sketchApi!.entity(fittedId)!.parameters['start'],
        ).x,
        closeTo(lineBeforeCancel.x, 1e-9),
      );
      controller.beginSketchEntityDrag(pick, const Offset(500, 350), camera);
      await controller.finishSketchEntityDrag(const Offset(580, 350), camera);
      final lineAfterDrag = SketchVector.fromJson(
        controller.sketchApi!.entity(fittedId)!.parameters['start'],
      );
      expect(lineAfterDrag.x, isNot(closeTo(lineBeforeCancel.x, 1e-9)));
      expect(sources.every((source) => source.visible == false), isTrue);
      expect(controller.sketchRegionFitComparison!.maximum, greaterThan(0));
      expect(engine.undo(), isTrue);
      expect(
        SketchVector.fromJson(
          controller.sketchApi!.entity(fittedId)!.parameters['start'],
        ).x,
        closeTo(lineBeforeCancel.x, 1e-9),
      );
      expect(engine.redo(), isTrue);
      expect(
        SketchVector.fromJson(
          controller.sketchApi!.entity(fittedId)!.parameters['start'],
        ).x,
        closeTo(lineAfterDrag.x, 1e-9),
      );

      // The other output mode promotes a real SketchSpline, without consuming
      // the visible reference outside this second selection.
      final splineSources = <SketchLine>[
        controller.sketchApi!.builders.line.build(
          const SketchVector(0, 30),
          const SketchVector(5, 31),
        ),
        controller.sketchApi!.builders.line.build(
          const SketchVector(12, 33),
          const SketchVector(18, 32),
        ),
        controller.sketchApi!.builders.line.build(
          const SketchVector(25, 30),
          const SketchVector(30, 30),
        ),
      ];
      controller.beginSketchCircularSelection();
      for (final source in [
        splineSources[2],
        splineSources[0],
        splineSources[1],
      ]) {
        controller.selectSketchEntity(source.id);
      }
      controller.setSketchRegionFitOutput(SketchRegionFitOutput.spline);
      await controller.fitSelectedSketchLineOrSpline();
      final splineId = controller.selectedSketchEntityIds.single;
      expect(controller.sketchApi!.entity(splineId), isA<SketchSpline>());
      expect(controller.sketchRegionFitMessage, contains('pontos'));
      expect(splineSources.every((source) => source.visible == false), isTrue);
      expect(untouched.visible, isTrue);
      expect(cad.runtime.scene.find(splineId)!.visible, isTrue);
      expect(cad.runtime.scene.find(splineId)!.selected, isTrue);
      expect(
        cad.runtime.scene.find(splineId)!.geometry['displayColor'],
        'regionFitNavy',
      );
      expect(
        cad.runtime.scene.find('region-fit-reference-$splineId')!.visible,
        isTrue,
      );
      final splineReferenceId = 'region-fit-reference-$splineId';

      Future<void> expectSplineApplied() async {
        expect(controller.sketchApi!.entity(splineId), isA<SketchSpline>());
        expect(
          splineSources.every(
            (source) =>
                controller.sketchApi!.entity(source.id)?.visible == false,
          ),
          isTrue,
        );
        expect(
          splineSources.every(
            (source) =>
                cad
                    .runtime
                    .document!
                    .entities[source.id]!
                    .data['sceneVisible'] ==
                false,
          ),
          isTrue,
        );
        expect(untouched.visible, isTrue);
        expect(cad.runtime.scene.find(splineId)!.visible, isTrue);
        expect(cad.runtime.scene.find(splineReferenceId)!.visible, isTrue);
        expect(
          cad.runtime.document!.entities.containsKey(splineReferenceId),
          isFalse,
        );
        // The earlier line fit stays on the same in-session stack.
        expect(controller.sketchApi!.entity(fittedId), isA<SketchLine>());
        expect(cad.runtime.scene.find(fittedId), isNotNull);
      }

      Future<void> expectSplineUndone() async {
        expect(controller.sketchApi!.entity(splineId), isNull);
        expect(cad.runtime.document!.entities.containsKey(splineId), isFalse);
        expect(cad.runtime.scene.find(splineId), isNull);
        expect(cad.runtime.scene.find(splineReferenceId), isNull);
        expect(
          splineSources.every(
            (source) =>
                controller.sketchApi!.entity(source.id)?.visible == true,
          ),
          isTrue,
        );
        expect(
          splineSources.every(
            (source) => cad.runtime.scene.find(source.id)?.visible == true,
          ),
          isTrue,
        );
        expect(untouched.visible, isTrue);
        expect(controller.sketchApi!.entity(fittedId), isA<SketchLine>());
        expect(cad.runtime.document!.entities.containsKey(fittedId), isTrue);
        expect(cad.runtime.scene.find(fittedId), isNotNull);
      }

      await controller.undo();
      await expectSplineUndone();
      await controller.redo();
      await expectSplineApplied();
      await controller.undo();
      await expectSplineUndone();
      await controller.redo();
      await expectSplineApplied();
      await controller.toggleActiveSketchVisibility();
      await controller.toggleActiveSketchVisibility();
      expect(
        splineSources.every(
          (source) => controller.sketchApi!.entity(source.id)?.visible == false,
        ),
        isTrue,
      );

      // Save/Open must rebuild the visual-only comparison from the promoted
      // entity metadata, rather than from hidden source geometry or a document
      // entity. This is the same project/controller lifecycle used by users.
      // Command-manager Undo/Redo is in-session only (history.jsonl is an audit
      // log, not a restored stack), so reopening does not re-enable Ctrl+Z.
      await controller.persist();
      final reopenedKernels = KernelManager()
        ..register(_HealthySurfaceKernel(), makeDefault: true);
      final reopenedCad = DesktopCadController(
        kernels: reopenedKernels,
        projects: ProjectManager.instance,
      );
      final reopenedCommands = DesktopCommandCoordinator(
        cad: reopenedCad,
        projects: ProjectManager.instance,
      );
      final reopened = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: reopenedCommands,
        runtime: reopenedCad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(
            repository: ReferenceRepository(projects: projects),
          ),
        ),
      );
      addTearDown(reopened.dispose);
      addTearDown(reopenedCad.dispose);
      await reopenedCad.runtime.open('g124-line-fit', directory);
      await reopened.configureProject(
        projectId: 'g124-line-fit',
        projectDirectory: directory,
      );

      final restoredLine = reopened.sketchApi!.entity(fittedId);
      final restoredSpline = reopened.sketchApi!.entity(splineId);
      expect(restoredLine, isA<SketchLine>());
      expect(restoredSpline, isA<SketchSpline>());
      for (final fitted in [restoredLine!, restoredSpline!]) {
        expect(fitted.metadata['regionFitReferencePoints'], isA<List>());
        expect(fitted.metadata['regionFitReferenceRegions'], isA<List>());
        expect(fitted.metadata['regionFitVisualComparison'], isTrue);
        expect(
          reopenedCad.runtime.scene.find(fitted.id)!.geometry['displayColor'],
          'regionFitNavy',
        );
        expect(reopenedCad.runtime.scene.find(fitted.id)!.visible, isTrue);
        expect(
          reopenedCad.runtime.scene
              .find('region-fit-reference-${fitted.id}')!
              .visible,
          isTrue,
        );
        expect(
          reopenedCad.runtime.document!.entities.containsKey(
            'region-fit-reference-${fitted.id}',
          ),
          isFalse,
        );
      }
      expect(
        [...sources, ...splineSources].every(
          (source) => reopened.sketchApi!.entity(source.id)?.visible == false,
        ),
        isTrue,
      );
      expect(reopened.sketchApi!.entity(untouched.id)!.visible, isTrue);

      reopened.selectSketchEntity(fittedId);
      await reopened.toggleActiveSketchVisibility();
      expect(reopenedCad.runtime.scene.find(referenceId), isNull);
      await reopened.toggleActiveSketchVisibility();
      expect(reopenedCad.runtime.scene.find(referenceId)!.visible, isTrue);
      expect(reopenedCad.runtime.scene.find(fittedId)!.selected, isTrue);
      final restoredComparison = reopened.sketchRegionFitComparison;
      expect(restoredComparison, isNotNull);
      expect(restoredComparison!.rms, greaterThan(0));
      expect(restoredComparison.mean, greaterThan(0));
      expect(restoredComparison.maximum, greaterThan(0));
      expect(restoredComparison.deviations, isNotEmpty);
      expect(
        reopened.sketchEntities.any((entity) => entity.id == referenceId),
        isFalse,
      );
    },
  );

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

      // 5. Global Undo/Redo (Ctrl+Z / Ctrl+Y) restores sources and drops the
      //    arc from the document/scene. Circular fit has no region-fit overlay.
      expect(cad.runtime.scene.find('region-fit-reference-$arcId'), isNull);
      expect(cad.runtime.scene.find('region-fit-deviation-$arcId'), isNull);

      Future<void> expectCircularApplied() async {
        expect(controller.sketchApi!.entity(arcId), isA<SketchArc>());
        expect(cad.runtime.document!.entities.containsKey(arcId), isTrue);
        expect(cad.runtime.scene.find(arcId)!.visible, isTrue);
        expect(cad.runtime.scene.find(arcId)!.selected, isTrue);
        expect(
          sources.every(
            (entity) =>
                controller.sketchApi!.entity(entity.id)?.visible == false,
          ),
          isTrue,
        );
        expect(
          sources.every(
            (entity) => cad.runtime.scene.find(entity.id)?.visible == false,
          ),
          isTrue,
        );
        expect(controller.sketchApi!.entity(overlapping.id)?.visible, isFalse);
        expect(controller.sketchApi!.entity(untouched.id)?.visible, isTrue);
        expect(controller.sketchApi!.entity(longChord.id)?.visible, isTrue);
        expect(cad.runtime.scene.find('region-fit-reference-$arcId'), isNull);
        expect(cad.runtime.scene.find('region-fit-deviation-$arcId'), isNull);
      }

      Future<void> expectCircularUndone() async {
        expect(controller.sketchApi!.entity(arcId), isNull);
        expect(cad.runtime.document!.entities.containsKey(arcId), isFalse);
        expect(cad.runtime.scene.find(arcId), isNull);
        expect(
          sources.every(
            (entity) =>
                controller.sketchApi!.entity(entity.id)?.visible == true,
          ),
          isTrue,
        );
        expect(
          sources.every(
            (entity) => cad.runtime.scene.find(entity.id)?.visible == true,
          ),
          isTrue,
        );
        expect(controller.sketchApi!.entity(overlapping.id)?.visible, isTrue);
        expect(controller.sketchApi!.entity(untouched.id)?.visible, isTrue);
        expect(controller.sketchApi!.entity(longChord.id)?.visible, isTrue);
        expect(cad.runtime.scene.find('region-fit-reference-$arcId'), isNull);
        expect(cad.runtime.scene.find('region-fit-deviation-$arcId'), isNull);
      }

      await controller.undo();
      await expectCircularUndone();
      await controller.redo();
      await expectCircularApplied();
      await controller.undo();
      await expectCircularUndone();
      await controller.redo();
      await expectCircularApplied();
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

  test(
    'assistant reconstruction joins global Undo/Redo without a second circularFit command',
    () async {
      final harness = await _g124Harness('g124-2-assistant');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final controller = harness.controller;
      final cad = harness.cad;

      SketchVector arcPoint(
        double cx,
        double cy,
        double radius,
        double angle,
      ) => SketchVector(
        cx + radius * math.cos(angle),
        cy + radius * math.sin(angle),
      );
      List<SketchLine> chain({
        required double cx,
        required double cy,
        required double radius,
        required double a0,
        required double a1,
        int count = 5,
      }) => [
        for (var index = 0; index < count; index++)
          controller.sketchApi!.builders.line.build(
            arcPoint(cx, cy, radius, a0 + (a1 - a0) * index / count),
            arcPoint(cx, cy, radius, a0 + (a1 - a0) * (index + 1) / count),
          ),
      ];

      final firstSources = chain(cx: 40, cy: 0, radius: 18, a0: 0.4, a1: 1.7);
      final secondSources = chain(cx: 140, cy: 0, radius: 16, a0: 0.3, a1: 1.5);
      final lineSources = [
        controller.sketchApi!.builders.line.build(
          const SketchVector(300, 0),
          const SketchVector(310, 0),
        ),
        controller.sketchApi!.builders.line.build(
          const SketchVector(310, 0),
          const SketchVector(320, 0),
        ),
      ];
      final horizontal = controller.sketchApi!.builders.line.build(
        const SketchVector(400, 0),
        const SketchVector(430, 0),
      );
      final vertical = controller.sketchApi!.builders.line.build(
        const SketchVector(500, 0),
        const SketchVector(500, 20),
      );

      controller.analyzeSketchReconstruction();
      final firstSuggestion = controller.sketchReconstructionSuggestions
          .firstWhere(
            (item) =>
                (item.kind == SketchReconstructionKind.arc ||
                    item.kind == SketchReconstructionKind.circle) &&
                item.entityIds.every(
                  (id) => firstSources.any((source) => source.id == id),
                ) &&
                item.center != null,
          );
      expect(firstSuggestion.confidence, greaterThanOrEqualTo(.75));
      final promotedId = await controller.acceptSketchReconstructionSuggestion(
        firstSuggestion,
      );
      expect(promotedId, isNotNull);
      expect(
        controller.commands.manager.history
            .where((record) => record.operation == 'execute')
            .last
            .commandId,
        'reverse.sketch.acceptReconstruction',
      );
      expect(
        controller.sketchReconstructionMessage,
        contains('criada e selecionada'),
      );
      Future<void> expectAssistantApplied(
        String createdId,
        List<SketchLine> sources, {
        bool selected = true,
      }) async {
        expect(controller.sketchApi!.entity(createdId), isNotNull);
        expect(cad.runtime.document!.entities.containsKey(createdId), isTrue);
        expect(cad.runtime.scene.find(createdId)!.visible, isTrue);
        if (selected) {
          expect(controller.selectedSketchEntityIds, {createdId});
          expect(cad.runtime.scene.find(createdId)!.selected, isTrue);
        }
        expect(
          sources.every(
            (source) =>
                controller.sketchApi!.entity(source.id)?.visible == false,
          ),
          isTrue,
        );
        expect(
          sources.every(
            (source) =>
                cad
                    .runtime
                    .document!
                    .entities[source.id]!
                    .data['sceneVisible'] ==
                false,
          ),
          isTrue,
        );
        expect(
          sources.every(
            (source) => cad.runtime.scene.find(source.id)?.visible == false,
          ),
          isTrue,
        );
      }

      Future<void> expectAssistantUndone(
        String createdId,
        List<SketchLine> sources,
      ) async {
        expect(controller.sketchApi!.entity(createdId), isNull);
        expect(cad.runtime.document!.entities.containsKey(createdId), isFalse);
        expect(cad.runtime.scene.find(createdId), isNull);
        expect(
          sources.every(
            (source) =>
                controller.sketchApi!.entity(source.id)?.visible == true,
          ),
          isTrue,
        );
        expect(
          sources.every(
            (source) => cad.runtime.scene.find(source.id)?.visible == true,
          ),
          isTrue,
        );
        expect(
          sources.every(
            (source) =>
                cad
                    .runtime
                    .document!
                    .entities[source.id]!
                    .data['sceneVisible'] !=
                false,
          ),
          isTrue,
        );
      }

      await expectAssistantApplied(promotedId!, firstSources);
      await controller.undo();
      await expectAssistantUndone(promotedId, firstSources);
      await controller.redo();
      await expectAssistantApplied(promotedId, firstSources);
      await controller.undo();
      await expectAssistantUndone(promotedId, firstSources);
      await controller.redo();
      await expectAssistantApplied(promotedId, firstSources);

      controller.analyzeSketchReconstruction();
      final secondSuggestion = controller.sketchReconstructionSuggestions
          .firstWhere(
            (item) =>
                (item.kind == SketchReconstructionKind.arc ||
                    item.kind == SketchReconstructionKind.circle) &&
                item.entityIds.every(
                  (id) => secondSources.any((source) => source.id == id),
                ) &&
                item.center != null,
          );
      final secondId = await controller.acceptSketchReconstructionSuggestion(
        secondSuggestion,
      );
      expect(secondId, isNotNull);
      await expectAssistantApplied(secondId!, secondSources);
      await expectAssistantApplied(promotedId, firstSources, selected: false);
      await controller.undo();
      await expectAssistantUndone(secondId, secondSources);
      await expectAssistantApplied(promotedId, firstSources, selected: false);
      await controller.redo();
      await expectAssistantApplied(secondId, secondSources);

      controller.analyzeSketchReconstruction();
      final lineSuggestion = controller.sketchReconstructionSuggestions
          .firstWhere(
            (item) =>
                item.kind == SketchReconstructionKind.line &&
                item.entityIds.length == lineSources.length &&
                item.entityIds.every(
                  (id) => lineSources.any((source) => source.id == id),
                ),
          );
      final expectedLineFit = const SketchReconstructionEngine()
          .diagnoseSelectedLineOrSpline(lineSources)
          .result!;
      final lineCreatedId = await controller
          .acceptSketchReconstructionSuggestion(lineSuggestion);
      expect(lineCreatedId, isNotNull);
      final promotedLine =
          controller.sketchApi!.entity(lineCreatedId!)! as SketchLine;
      expect(promotedLine.metadata['reconstructionKind'], 'line');
      expect(
        promotedLine.metadata.containsKey('regionFitReferencePoints'),
        isFalse,
      );
      expect(promotedLine.metadata.containsKey('regionFitSourceIds'), isFalse);
      final promotedEnds = [
        SketchVector.fromJson(promotedLine.parameters['start']),
        SketchVector.fromJson(promotedLine.parameters['end']),
      ];
      expect(
        promotedEnds.any(
          (point) =>
              (point.x - expectedLineFit.start.x).abs() < 1e-9 &&
              (point.y - expectedLineFit.start.y).abs() < 1e-9,
        ),
        isTrue,
      );
      expect(
        promotedEnds.any(
          (point) =>
              (point.x - expectedLineFit.end.x).abs() < 1e-9 &&
              (point.y - expectedLineFit.end.y).abs() < 1e-9,
        ),
        isTrue,
      );
      await expectAssistantApplied(lineCreatedId, lineSources);
      expect(controller.sketchApi!.entity(promotedId), isNotNull);
      await controller.undo();
      await expectAssistantUndone(lineCreatedId, lineSources);
      expect(controller.sketchApi!.entity(promotedId), isNotNull);
      await controller.redo();
      await expectAssistantApplied(lineCreatedId, lineSources);
      await controller.undo();
      await controller.redo();
      await expectAssistantApplied(lineCreatedId, lineSources);

      controller.analyzeSketchReconstruction();
      final perpendicular = controller.sketchReconstructionSuggestions
          .firstWhere(
            (item) =>
                item.kind == SketchReconstructionKind.perpendicular &&
                item.entityIds.contains(horizontal.id) &&
                item.entityIds.contains(vertical.id),
          );
      await controller.acceptSketchReconstructionSuggestion(perpendicular);
      final constraintId = controller.constraints
          .firstWhere(
            (item) =>
                item.type == SketchConstraintType.perpendicular &&
                item.references.contains(horizontal.id) &&
                item.references.contains(vertical.id),
          )
          .id;
      await controller.undo();
      expect(
        controller.constraints.any((item) => item.id == constraintId),
        isFalse,
      );
      await controller.redo();
      expect(
        controller.constraints.any((item) => item.id == constraintId),
        isTrue,
      );
      await controller.undo();
      await controller.redo();
      expect(
        controller.constraints.any((item) => item.id == constraintId),
        isTrue,
      );

      final regionSources = [
        controller.sketchApi!.builders.line.build(
          const SketchVector(600, 0),
          const SketchVector(605, 0),
        ),
        controller.sketchApi!.builders.line.build(
          const SketchVector(625, 0),
          const SketchVector(630, 0),
        ),
      ];
      controller.beginSketchCircularSelection();
      for (final source in regionSources) {
        controller.selectSketchEntity(source.id);
      }
      controller.setSketchRegionFitOutput(SketchRegionFitOutput.line);
      await controller.fitSelectedSketchLineOrSpline();
      final regionId = controller.selectedSketchEntityIds.single;
      expect(controller.sketchApi!.entity(regionId), isA<SketchLine>());
      await controller.undo();
      expect(controller.sketchApi!.entity(regionId), isNull);
      expect(
        regionSources.every(
          (source) => controller.sketchApi!.entity(source.id)?.visible == true,
        ),
        isTrue,
      );
      await expectAssistantApplied(promotedId, firstSources, selected: false);
      await expectAssistantApplied(secondId, secondSources, selected: false);

      final acceptCount = controller.commands.manager.history
          .where(
            (record) =>
                record.operation == 'execute' &&
                record.commandId == 'reverse.sketch.acceptReconstruction',
          )
          .length;
      final circularSources = chain(
        cx: 80,
        cy: 80,
        radius: 14,
        a0: 0.2,
        a1: 1.4,
      );
      controller.beginSketchCircularSelection();
      for (final source in circularSources) {
        controller.selectSketchEntity(source.id);
      }
      await controller.fitSelectedSketchCircularGeometry();
      expect(controller.sketchCircularFitConfirmed, isTrue);
      expect(
        controller.commands.manager.history
            .where((record) => record.operation == 'execute')
            .last
            .commandId,
        'reverse.sketch.circularFit',
      );
      expect(
        controller.commands.manager.history
            .where(
              (record) =>
                  record.operation == 'execute' &&
                  record.commandId == 'reverse.sketch.acceptReconstruction',
            )
            .length,
        acceptCount,
      );
      final circularId = controller.selectedSketchEntityIds.single;
      await controller.undo();
      expect(controller.sketchApi!.entity(circularId), isNull);
      expect(
        circularSources.every(
          (source) => controller.sketchApi!.entity(source.id)?.visible == true,
        ),
        isTrue,
      );
      await expectAssistantApplied(promotedId, firstSources, selected: false);

      final canUndo = controller.commands.manager.canUndo;
      final missing = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.arc,
        entityIds: const ['missing-a', 'missing-b'],
        confidence: 0.99,
        center: const SketchVector(0, 0),
        radius: 10,
        startAngle: 0,
        endAngle: 1,
      );
      expect(
        await controller.acceptSketchReconstructionSuggestion(missing),
        isNull,
      );
      expect(controller.commands.manager.canUndo, canUndo);

      final weak = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.arc,
        entityIds: firstSources.map((source) => source.id).toList(),
        confidence: 0.2,
        center: const SketchVector(40, 0),
        radius: 18,
        startAngle: 0.4,
        endAngle: 1.7,
      );
      expect(
        await controller.acceptSketchReconstructionSuggestion(weak),
        isNull,
      );
      expect(controller.error, contains('não estão mais visíveis'));
      expect(controller.sketchReconstructionMessage, controller.error);
      expect(controller.commands.manager.canUndo, canUndo);
      await expectAssistantApplied(promotedId, firstSources, selected: false);

      await controller.persist();
      final reopenedKernels = KernelManager()
        ..register(_HealthySurfaceKernel(), makeDefault: true);
      final reopenedCad = DesktopCadController(
        kernels: reopenedKernels,
        projects: ProjectManager.instance,
      );
      final reopenedCommands = DesktopCommandCoordinator(
        cad: reopenedCad,
        projects: ProjectManager.instance,
      );
      final reopened = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: reopenedCommands,
        runtime: reopenedCad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(
            repository: ReferenceRepository(projects: harness.projects),
          ),
        ),
      );
      addTearDown(reopened.dispose);
      addTearDown(reopenedCad.dispose);
      await reopenedCad.runtime.open('g124-2-assistant', harness.directory);
      await reopened.configureProject(
        projectId: 'g124-2-assistant',
        projectDirectory: harness.directory,
      );
      expect(reopened.sketchApi!.entity(promotedId), isNotNull);
      expect(reopened.sketchApi!.entity(secondId), isNotNull);
      expect(reopened.sketchApi!.entity(lineCreatedId), isA<SketchLine>());
      expect(
        firstSources.every(
          (source) => reopened.sketchApi!.entity(source.id)?.visible == false,
        ),
        isTrue,
      );
      expect(
        lineSources.every(
          (source) => reopened.sketchApi!.entity(source.id)?.visible == false,
        ),
        isTrue,
      );
      expect(reopened.commands.manager.canUndo, isFalse);
    },
  );

  test(
    'assistant suggestion hover highlights sources and click persists without a command',
    () async {
      final harness = await _g124Harness('g124-5a-highlight');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final controller = harness.controller;
      final cad = harness.cad;

      final firstSources = [
        controller.sketchApi!.builders.line.build(
          const SketchVector(0, 0),
          const SketchVector(10, 0),
        ),
        controller.sketchApi!.builders.line.build(
          const SketchVector(10, 0),
          const SketchVector(20, 0),
        ),
      ];
      final secondSources = [
        controller.sketchApi!.builders.line.build(
          const SketchVector(0, 40),
          const SketchVector(12, 40),
        ),
        controller.sketchApi!.builders.line.build(
          const SketchVector(12, 40),
          const SketchVector(24, 40),
        ),
      ];
      controller.analyzeSketchReconstruction();
      final first = controller.sketchReconstructionSuggestions.firstWhere(
        (item) =>
            item.kind == SketchReconstructionKind.line &&
            item.entityIds.length == firstSources.length &&
            item.entityIds.every(
              (id) => firstSources.any((source) => source.id == id),
            ),
      );
      final second = controller.sketchReconstructionSuggestions.firstWhere(
        (item) =>
            item.kind == SketchReconstructionKind.line &&
            item.entityIds.length == secondSources.length &&
            item.entityIds.every(
              (id) => secondSources.any((source) => source.id == id),
            ),
      );
      expect(first.rmsError, isNotNull);
      expect(first.maxError, isNotNull);
      final firstBounds = controller.sketchReconstructionSuggestionBounds(
        first,
      )!;
      expect(firstBounds.minimum.x, closeTo(0, 1e-9));
      expect(firstBounds.maximum.x, closeTo(20, 1e-9));
      expect(firstBounds.minimum.y, closeTo(0, 1e-9));
      expect(firstBounds.maximum.y, closeTo(0, 1e-9));
      final arc = controller.sketchApi!.builders.arc.build(
        const SketchVector(100, 20),
        5,
        0,
        math.pi / 2,
      );
      final spline = controller.sketchApi!.builders.spline.build(const [
        SketchVector(200, 30),
        SketchVector(205, 35),
        SketchVector(210, 30),
      ]);
      final arcBounds = controller.sketchReconstructionSuggestionBounds(
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.arc,
          entityIds: [arc.id],
          confidence: 1,
        ),
      )!;
      final splineBounds = controller.sketchReconstructionSuggestionBounds(
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.line,
          entityIds: [spline.id],
          confidence: 1,
        ),
      )!;
      expect(arcBounds.minimum.x, closeTo(100, 1e-9));
      expect(arcBounds.maximum.x, closeTo(105, 1e-9));
      expect(splineBounds.minimum.x, closeTo(200, 1e-9));
      expect(splineBounds.maximum.x, closeTo(210, 1e-9));

      dynamic overlay() =>
          cad.runtime.scene.find(sketchReconstructionHighlightId);
      final historyBefore = controller.commands.manager.history.length;
      final selectionBefore = Set<String>.from(
        controller.selectedSketchEntityIds,
      );

      controller.highlightSketchReconstructionSuggestion(first);
      expect(overlay(), isNotNull);
      expect(overlay()!.geometry['reconstructionHighlight'], 'hover');
      expect(overlay()!.geometry['displayColor'], 'assistantSuggestion');
      expect(overlay()!.geometry['entityIds'], first.entityIds);
      expect(overlay()!.geometry['segments'], isNotEmpty);
      expect(controller.selectedSketchEntityIds, selectionBefore);
      expect(controller.commands.manager.history.length, historyBefore);

      controller.clearHoveredSketchReconstructionSuggestion();
      expect(overlay(), isNull);
      expect(controller.selectedSketchEntityIds, selectionBefore);

      controller.highlightSketchReconstructionSuggestion(
        first,
        persistent: true,
      );
      expect(overlay()!.geometry['reconstructionHighlight'], 'persistent');
      expect(overlay()!.geometry['displayColor'], 'conflictRed');
      expect(controller.selectedSketchEntityIds, first.entityIds.toSet());
      expect(
        controller.isSketchReconstructionSuggestionSelected(first),
        isTrue,
      );
      expect(controller.commands.manager.history.length, historyBefore);

      // Viewport hover resolves through the same source IDs as the list. It
      // must keep the persistent selection overlay and add only a transient
      // accent for the hovered, already-selected suggestion.
      expect(
        controller.hoverSketchReconstructionSuggestionForEntity(
          first.entityIds.first,
        ),
        isTrue,
      );
      expect(controller.isSketchReconstructionSuggestionHovered(first), isTrue);
      expect(
        cad.runtime.scene
            .find(sketchReconstructionHighlightId)!
            .geometry['reconstructionHighlight'],
        'persistent',
      );
      final selectedHover = cad.runtime.scene.find(
        sketchReconstructionHoverHighlightId,
      );
      expect(selectedHover, isNotNull);
      expect(selectedHover!.geometry['hoverLabel'], startsWith('Linha '));
      expect(controller.selectedSketchEntityIds, first.entityIds.toSet());
      controller.clearHoveredSketchReconstructionSuggestion();
      expect(
        cad.runtime.scene.find(sketchReconstructionHoverHighlightId),
        isNull,
      );

      expect(
        controller.hoverSketchReconstructionSuggestionForEntity(
          second.entityIds.first,
        ),
        isTrue,
      );
      expect(
        controller.isSketchReconstructionSuggestionHovered(second),
        isTrue,
      );
      expect(overlay()!.geometry['reconstructionHighlight'], 'hover');
      expect(overlay()!.geometry['entityIds'], second.entityIds);
      expect(controller.selectedSketchEntityIds, first.entityIds.toSet());

      controller.clearHoveredSketchReconstructionSuggestion();
      expect(overlay()!.geometry['reconstructionHighlight'], 'persistent');
      expect(overlay()!.geometry['entityIds'], first.entityIds);
      expect(controller.selectedSketchEntityIds, first.entityIds.toSet());

      controller.highlightSketchReconstructionSuggestion(
        second,
        persistent: true,
      );
      expect(overlay()!.geometry['entityIds'], second.entityIds);
      expect(controller.selectedSketchEntityIds, second.entityIds.toSet());
      expect(
        controller.isSketchReconstructionSuggestionSelected(first),
        isFalse,
      );
      expect(
        controller.isSketchReconstructionSuggestionSelected(second),
        isTrue,
      );

      controller.clearSketchReconstructionSuggestions();
      expect(overlay(), isNull);
      expect(controller.selectedSketchEntityIds, isEmpty);
      expect(controller.sketchReconstructionSuggestions, isEmpty);
      expect(controller.commands.manager.history.length, historyBefore);

      controller.analyzeSketchReconstruction();
      final restored = controller.sketchReconstructionSuggestions.firstWhere(
        (item) =>
            item.kind == SketchReconstructionKind.line &&
            item.entityIds.every(
              (id) => firstSources.any((source) => source.id == id),
            ),
      );
      controller.highlightSketchReconstructionSuggestion(
        restored,
        persistent: true,
      );
      expect(overlay(), isNotNull);

      final weak = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.arc,
        entityIds: restored.entityIds,
        confidence: 0.2,
        center: const SketchVector(0, 0),
        radius: 10,
        startAngle: 0,
        endAngle: 1,
      );
      expect(
        await controller.acceptSketchReconstructionSuggestion(weak),
        isNull,
      );
      expect(controller.error, contains('confiança'));
      expect(overlay(), isNull);
      expect(controller.selectedSketchEntityIds, isEmpty);
      expect(controller.commands.manager.history.length, historyBefore);

      controller.highlightSketchReconstructionSuggestion(
        restored,
        persistent: true,
      );
      expect(overlay(), isNotNull);
      final promotedId = await controller.acceptSketchReconstructionSuggestion(
        restored,
      );
      expect(promotedId, isNotNull);
      expect(overlay(), isNull);
      expect(
        firstSources.every(
          (source) => controller.sketchApi!.entity(source.id)?.visible == false,
        ),
        isTrue,
      );
      expect(controller.selectedSketchEntityIds, {promotedId});

      await controller.undo();
      expect(overlay(), isNull);
      await controller.redo();
      expect(overlay(), isNull);

      await controller.persist();
      final reopenedKernels = KernelManager()
        ..register(_HealthySurfaceKernel(), makeDefault: true);
      final reopenedCad = DesktopCadController(
        kernels: reopenedKernels,
        projects: ProjectManager.instance,
      );
      final reopenedCommands = DesktopCommandCoordinator(
        cad: reopenedCad,
        projects: ProjectManager.instance,
      );
      final reopened = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: reopenedCommands,
        runtime: reopenedCad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(
            repository: ReferenceRepository(projects: harness.projects),
          ),
        ),
      );
      addTearDown(reopened.dispose);
      addTearDown(reopenedCad.dispose);
      await reopenedCad.runtime.open('g124-5a-highlight', harness.directory);
      await reopened.configureProject(
        projectId: 'g124-5a-highlight',
        projectDirectory: harness.directory,
      );
      expect(
        reopenedCad.runtime.scene.find(sketchReconstructionHighlightId),
        isNull,
      );
    },
  );

  test(
    'assistant accepts a valid arc when an overlapped covered fragment was hidden',
    () async {
      final harness = await _g124Harness('g124-4-arc-covered-source');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final controller = harness.controller;
      final api = controller.sketchApi!;
      SketchVector point(double angle) =>
          SketchVector(20 + 12 * math.cos(angle), 12 * math.sin(angle));
      final sources = [
        for (var index = 0; index < 5; index++)
          api.builders.line.build(
            point(.2 + 1.3 * index / 5),
            point(.2 + 1.3 * (index + 1) / 5),
          ),
      ];
      final covered = api.builders.arc.build(
        const SketchVector(20, 0),
        12,
        .65,
        .95,
      );
      final suggestion = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.arc,
        entityIds: sources.map((source) => source.id).toList(),
        confidence: 1.0,
        center: const SketchVector(20, 0),
        radius: 12,
        startAngle: .2,
        endAngle: 1.5,
        coveredEntityIds: [covered.id],
      );

      // A prior overlapping promotion may already have hidden this visual
      // fragment. It must not invalidate the arc's actual fitting sources.
      api.engine.modify(covered.id, SketchHistoryAction.modify, (entity) {
        entity.visible = false;
        entity.metadata['reconstructionHidden'] = true;
      });
      final createdId = await controller.acceptSketchReconstructionSuggestion(
        suggestion,
      );
      expect(createdId, isNotNull);
      expect(controller.sketchApi!.entity(createdId!), isA<SketchArc>());
      expect(controller.sketchReconstructionMessage, contains('criada'));
      expect(controller.error, isNull);
    },
  );

  test(
    'assistant highlight copies every source even when the list shows eight tiles',
    () async {
      final harness = await _g124Harness('g124-5a-highlight-128');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final controller = harness.controller;
      final cad = harness.cad;
      const count = 128;
      final ids = <String>[];
      for (var index = 0; index < count; index++) {
        final start = SketchVector(index.toDouble(), 0);
        final end = SketchVector(index + 1.0, 0);
        final line = controller.sketchApi!.builders.line.build(start, end);
        ids.add(line.id);
        cad.runtime.scene.upsert(
          CadSceneEntity(
            id: line.id,
            kind: CadSceneEntityKind.sketch,
            geometry: {
              'points': [start.toJson(), end.toJson()],
              // Empty segments used to hide a one-by-one scene copy that
              // replaced the same transient id and kept only the last curve.
              'segments': const <List<dynamic>>[],
            },
          ),
        );
      }
      cad.runtime.showTransient(
        CadSceneEntity(
          id: 'sketch-health-highlight',
          kind: CadSceneEntityKind.preview,
          transparent: true,
          geometry: {
            'points': [
              [0.0, 0.0, 0.0],
            ],
            'displayColor': 'conflictRed',
          },
        ),
      );
      cad.runtime.showTransient(
        CadSceneEntity(
          id: 'region-fit-reference-g124',
          kind: CadSceneEntityKind.preview,
          transparent: true,
          geometry: {
            'segments': [
              [
                [0.0, 1.0, 0.0],
                [1.0, 1.0, 0.0],
              ],
            ],
            'displayColor': 'referenceCurve',
          },
        ),
      );
      final suggestion = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.line,
        entityIds: ids,
        confidence: 1.0,
      );
      final historyBefore = controller.commands.manager.history.length;
      final selectionBefore = Set<String>.from(
        controller.selectedSketchEntityIds,
      );
      final documentBefore = cad.runtime.document?.entities.keys.toSet();

      controller.highlightSketchReconstructionSuggestion(suggestion);
      final overlay = cad.runtime.scene.find(sketchReconstructionHighlightId);
      expect(overlay, isNotNull);
      expect(overlay!.geometry['entityIds'], ids);
      expect(overlay.geometry['entityIds'], hasLength(count));
      expect(overlay.geometry['segments'], hasLength(count));
      expect(overlay.geometry['reconstructionHighlight'], 'hover');
      expect(controller.selectedSketchEntityIds, selectionBefore);
      expect(controller.commands.manager.history.length, historyBefore);
      expect(cad.runtime.document?.entities.keys.toSet(), documentBefore);
      expect(cad.runtime.scene.find('sketch-health-highlight'), isNotNull);
      expect(cad.runtime.scene.find('region-fit-reference-g124'), isNotNull);

      controller.highlightSketchReconstructionSuggestion(
        suggestion,
        persistent: true,
      );
      expect(
        cad.runtime.scene
            .find(sketchReconstructionHighlightId)!
            .geometry['segments'],
        hasLength(count),
      );
      expect(controller.selectedSketchEntityIds, ids.toSet());
      expect(controller.commands.manager.history.length, historyBefore);
      expect(cad.runtime.document?.entities.keys.toSet(), documentBefore);
      expect(cad.runtime.scene.find('sketch-health-highlight'), isNotNull);
      expect(cad.runtime.scene.find('region-fit-reference-g124'), isNotNull);
    },
  );

  test(
    'assistant reconstruction highlight overlay is removed on dispose',
    () async {
      final harness = await _g124Harness('g124-5a-highlight-dispose');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.cad.dispose);
      addTearDown(() {
        try {
          harness.controller.dispose();
        } on Object {
          // Disposed in the test body after hideTransient is asserted.
        }
      });
      final controller = harness.controller;
      final cad = harness.cad;
      final line = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final suggestion = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.line,
        entityIds: [line.id],
        confidence: 1.0,
      );
      controller.highlightSketchReconstructionSuggestion(
        suggestion,
        persistent: true,
      );
      expect(
        cad.runtime.scene.find(sketchReconstructionHighlightId),
        isNotNull,
      );
      controller.dispose();
      expect(cad.runtime.scene.find(sketchReconstructionHighlightId), isNull);
    },
  );

  test(
    'assistant line promotion creates geometry only with collinear evidence',
    () async {
      final harness = await _g124Harness('g124-3-line-promotion');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final controller = harness.controller;
      final cad = harness.cad;
      final engine = const SketchReconstructionEngine();
      const lineTolerance = SketchLineReconstructionTolerance();
      expect(lineTolerance.reconstructionToleranceMm, 0.10);
      final limitMm = lineTolerance.reconstructionToleranceMm.toStringAsFixed(
        3,
      );

      void expectLineToleranceMessage(String? message, double maxError) {
        expect(message, isNotNull);
        expect(
          message,
          contains(
            'erro máx ${maxError.toStringAsFixed(3)} mm (limite $limitMm mm)',
          ),
        );
      }

      Future<void> expectSourcesHidden(Iterable<SketchEntity> sources) async {
        expect(
          sources.every(
            (source) =>
                controller.sketchApi!.entity(source.id)?.visible == false &&
                controller.sketchApi!
                        .entity(source.id)
                        ?.metadata['reconstructionHidden'] ==
                    true &&
                cad
                        .runtime
                        .document!
                        .entities[source.id]!
                        .data['sceneVisible'] ==
                    false &&
                cad.runtime.scene.find(source.id)?.visible == false,
          ),
          isTrue,
        );
      }

      Future<void> expectSourcesRestored(Iterable<SketchEntity> sources) async {
        expect(
          sources.every(
            (source) =>
                controller.sketchApi!.entity(source.id)?.visible == true &&
                controller.sketchApi!
                        .entity(source.id)
                        ?.metadata['reconstructionHidden'] !=
                    true &&
                cad.runtime.scene.find(source.id)?.visible == true,
          ),
          isTrue,
        );
      }

      final isolated = controller.sketchApi!.builders.line.build(
        const SketchVector(900, 0),
        const SketchVector(920, 0),
      );
      final collinear = [
        controller.sketchApi!.builders.line.build(
          const SketchVector(300, 80),
          const SketchVector(310, 80),
        ),
        controller.sketchApi!.builders.line.build(
          const SketchVector(310, 80),
          const SketchVector(320, 80),
        ),
      ];
      final elbowHorizontal = controller.sketchApi!.builders.line.build(
        const SketchVector(500, 80),
        const SketchVector(530, 80),
      );
      final elbowVertical = controller.sketchApi!.builders.line.build(
        const SketchVector(530, 80),
        const SketchVector(530, 100),
      );
      final straightSpline = controller.sketchApi!.builders.spline.build(const [
        SketchVector(0, 200),
        SketchVector(8, 200.04),
        SketchVector(16, 199.98),
        SketchVector(24, 200),
      ]);
      final curvedSpline = controller.sketchApi!.builders.spline.build(const [
        SketchVector(0, 260),
        SketchVector(12, 272),
        SketchVector(24, 260),
      ]);
      final degenerateSpline = controller.sketchApi!.builders.spline.build(
        const [
          SketchVector(700, 0),
          SketchVector(710, 0),
          SketchVector(700, 0),
        ],
      );
      // PCA of the four endpoints is exactly 0.10 mm (mean y offset 0.10).
      final exactLines = [
        controller.sketchApi!.builders.line.build(
          const SketchVector(1000, 500),
          const SketchVector(1020, 500),
        ),
        controller.sketchApi!.builders.line.build(
          const SketchVector(1000, 500.20),
          const SketchVector(1020, 500.20),
        ),
      ];
      // Chord residual ~0.14 mm yields Assistant confidence < 0.75; PCA of
      // the interpolating samples stays inside the 0.10 mm budget.
      final weakSpline = controller.sketchApi!.builders.spline.build(const [
        SketchVector(0, 320),
        SketchVector(10, 320.14),
        SketchVector(20, 320),
      ]);
      // PCA of the four endpoints is 0.15 mm, above the 0.10 mm budget.
      final overLines = [
        controller.sketchApi!.builders.line.build(
          const SketchVector(1100, 600),
          const SketchVector(1120, 600),
        ),
        controller.sketchApi!.builders.line.build(
          const SketchVector(1100, 600.30),
          const SketchVector(1120, 600.30),
        ),
      ];
      final regionOver = [
        controller.sketchApi!.builders.line.build(
          const SketchVector(800, 0),
          const SketchVector(820, 0),
        ),
        controller.sketchApi!.builders.line.build(
          const SketchVector(820, 0.5),
          const SketchVector(840, 0.5),
        ),
      ];
      SketchVector arcPoint(double angle) =>
          SketchVector(80 + 14 * math.cos(angle), 40 + 14 * math.sin(angle));
      final arcSources = [
        for (var index = 0; index < 5; index++)
          controller.sketchApi!.builders.line.build(
            arcPoint(0.2 + 1.2 * index / 5),
            arcPoint(0.2 + 1.2 * (index + 1) / 5),
          ),
      ];
      final entityCountBefore = controller.sketchEntities.length;

      controller.analyzeSketchReconstruction();
      final isolatedSuggestion = controller.sketchReconstructionSuggestions
          .firstWhere(
            (item) =>
                item.kind == SketchReconstructionKind.line &&
                item.entityIds.length == 1 &&
                item.entityIds.single == isolated.id,
          );
      expect(
        await controller.acceptSketchReconstructionSuggestion(
          isolatedSuggestion,
        ),
        isNull,
      );
      expect(controller.sketchEntities.length, entityCountBefore);
      expect(controller.sketchApi!.entity(isolated.id), isNotNull);
      expect(isolated.visible, isTrue);
      expect(isolated.metadata['reconstructionKind'], 'line');
      expect(isolated.metadata['reconstructionHidden'], isNot(true));
      expect(cad.runtime.scene.find(isolated.id)!.visible, isTrue);
      expect(
        controller.sketchReconstructionMessage,
        contains('nenhuma entidade foi duplicada'),
      );
      expect(
        controller.sketchReconstructionSuggestions.any(
          (item) =>
              item.kind == isolatedSuggestion.kind &&
              item.entityIds.length == isolatedSuggestion.entityIds.length &&
              item.entityIds.every(isolatedSuggestion.entityIds.contains),
        ),
        isFalse,
      );

      controller.analyzeSketchReconstruction();
      final chainSuggestion = controller.sketchReconstructionSuggestions
          .firstWhere(
            (item) =>
                item.kind == SketchReconstructionKind.line &&
                item.entityIds.length == collinear.length &&
                item.entityIds.every(
                  (id) => collinear.any((source) => source.id == id),
                ),
          );
      final chainDiagnosis = engine.diagnoseSelectedLineOrSpline(collinear);
      expect(chainDiagnosis.failure, isNull);
      final chainFit = chainDiagnosis.result!;
      expect(
        chainFit.maxError,
        lessThan(lineTolerance.reconstructionToleranceMm),
      );
      final chainId = (await controller.acceptSketchReconstructionSuggestion(
        chainSuggestion,
      ))!;
      expect(controller.sketchApi!.entity(chainId), isA<SketchLine>());
      expectLineToleranceMessage(controller.error, chainFit.maxError);
      expect(controller.error, contains('RMS'));
      expect(
        controller.sketchReconstructionMessage,
        contains('criada e selecionada'),
      );
      expect(
        controller.commands.manager.history
            .where((record) => record.operation == 'execute')
            .last
            .commandId,
        'reverse.sketch.acceptReconstruction',
      );
      await expectSourcesHidden(collinear);
      expect(controller.selectedSketchEntityIds, {chainId});
      expect(cad.runtime.scene.find(chainId)!.visible, isTrue);
      expect(cad.runtime.scene.find(chainId)!.selected, isTrue);

      await controller.undo();
      expect(controller.sketchApi!.entity(chainId), isNull);
      await expectSourcesRestored(collinear);
      await controller.redo();
      expect(controller.sketchApi!.entity(chainId), isA<SketchLine>());
      await expectSourcesHidden(collinear);
      await controller.undo();
      await expectSourcesRestored(collinear);
      await controller.redo();
      await expectSourcesHidden(collinear);

      controller.analyzeSketchReconstruction();
      final elbowSuggestions = controller.sketchReconstructionSuggestions
          .where(
            (item) =>
                item.kind == SketchReconstructionKind.line &&
                item.entityIds.contains(elbowHorizontal.id) &&
                item.entityIds.contains(elbowVertical.id),
          )
          .toList();
      // Geometric segmentation rejects the L as one line before the list is
      // shown; the two arms remain available as independent regions.
      expect(elbowSuggestions, isEmpty);
      final elbowDiagnosis = engine.diagnoseSelectedLineOrSpline([
        elbowHorizontal,
        elbowVertical,
      ]);
      expect(elbowDiagnosis.failure, isNull);
      expect(
        elbowDiagnosis.result!.maxError,
        greaterThan(lineTolerance.reconstructionToleranceMm),
      );
      final canUndoBeforeElbow = controller.commands.manager.canUndo;
      final historyBeforeElbow = controller.commands.manager.history.length;
      expect(controller.commands.manager.canUndo, canUndoBeforeElbow);
      expect(controller.commands.manager.history.length, historyBeforeElbow);
      expect(
        controller.sketchReconstructionSuggestions.any(
          (item) =>
              item.kind == SketchReconstructionKind.line &&
              item.entityIds.contains(elbowHorizontal.id) &&
              item.entityIds.contains(elbowVertical.id),
        ),
        isFalse,
      );
      expect(controller.sketchApi!.entity(elbowHorizontal.id)!.visible, isTrue);
      expect(controller.sketchApi!.entity(elbowVertical.id)!.visible, isTrue);
      expect(controller.sketchApi!.entity(chainId), isA<SketchLine>());

      controller.analyzeSketchReconstruction();
      final splineSuggestion = controller.sketchReconstructionSuggestions
          .firstWhere(
            (item) =>
                item.kind == SketchReconstructionKind.line &&
                item.entityIds.length == 1 &&
                item.entityIds.single == straightSpline.id,
          );
      expect(splineSuggestion.confidence, greaterThanOrEqualTo(.75));
      final splineFit = engine.diagnoseSelectedLineOrSpline([
        straightSpline,
      ]).result!;
      expect(
        splineFit.maxError,
        lessThan(lineTolerance.reconstructionToleranceMm),
      );
      final splineLineId = (await controller
          .acceptSketchReconstructionSuggestion(splineSuggestion))!;
      expect(controller.sketchApi!.entity(splineLineId), isA<SketchLine>());
      expect(
        controller.sketchApi!.entity(straightSpline.id),
        isA<SketchSpline>(),
      );
      expectLineToleranceMessage(controller.error, splineFit.maxError);
      expect(controller.error, contains('RMS'));
      await expectSourcesHidden([straightSpline]);
      expect(controller.selectedSketchEntityIds, {splineLineId});

      final canUndoBeforeCurve = controller.commands.manager.canUndo;
      final curvedSuggestion = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.line,
        entityIds: [curvedSpline.id],
        confidence: 0.99,
      );
      final curvedDiagnosis = engine.diagnoseSelectedLineOrSpline([
        curvedSpline,
      ]);
      expect(curvedDiagnosis.failure, isNull);
      expect(
        curvedDiagnosis.result!.maxError,
        greaterThan(lineTolerance.reconstructionToleranceMm),
      );
      expect(
        await controller.acceptSketchReconstructionSuggestion(curvedSuggestion),
        isNull,
      );
      expect(controller.commands.manager.canUndo, canUndoBeforeCurve);
      expectLineToleranceMessage(
        controller.error,
        curvedDiagnosis.result!.maxError,
      );
      expect(controller.error, contains('Linha rejeitada'));
      expect(controller.sketchApi!.entity(curvedSpline.id), isNotNull);
      expect(curvedSpline.visible, isTrue);
      expect(
        controller.sketchEntities.whereType<SketchLine>().any(
          (line) => line.id == splineLineId,
        ),
        isTrue,
      );

      final degenerateSuggestion = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.line,
        entityIds: [degenerateSpline.id],
        confidence: 0.99,
      );
      expect(
        engine.diagnoseSelectedLineOrSpline([degenerateSpline]).failure,
        SketchRegionFitFailure.degenerateGeometry,
      );
      expect(
        await controller.acceptSketchReconstructionSuggestion(
          degenerateSuggestion,
        ),
        isNull,
      );
      expect(controller.commands.manager.canUndo, canUndoBeforeCurve);
      expect(degenerateSpline.visible, isTrue);

      final exactSuggestion = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.line,
        entityIds: exactLines.map((source) => source.id).toList(),
        confidence: 1.0,
      );
      final exactFit = engine.diagnoseSelectedLineOrSpline(exactLines).result!;
      expect(
        exactFit.maxError,
        closeTo(lineTolerance.reconstructionToleranceMm, 1e-12),
      );
      final exactLineId = (await controller
          .acceptSketchReconstructionSuggestion(exactSuggestion))!;
      expect(controller.sketchApi!.entity(exactLineId), isA<SketchLine>());
      expectLineToleranceMessage(controller.error, exactFit.maxError);
      await expectSourcesHidden(exactLines);
      expect(controller.selectedSketchEntityIds, {exactLineId});

      controller.analyzeSketchReconstruction();
      final weakSuggestion = controller.sketchReconstructionSuggestions
          .firstWhere(
            (item) =>
                item.kind == SketchReconstructionKind.line &&
                item.entityIds.length == 1 &&
                item.entityIds.single == weakSpline.id,
          );
      expect(weakSuggestion.confidence, lessThan(.75));
      final weakFit = engine.diagnoseSelectedLineOrSpline([weakSpline]).result!;
      expect(
        weakFit.maxError,
        lessThanOrEqualTo(lineTolerance.reconstructionToleranceMm),
      );
      final weakLineId = (await controller.acceptSketchReconstructionSuggestion(
        weakSuggestion,
      ))!;
      expect(controller.sketchApi!.entity(weakLineId), isA<SketchLine>());
      expectLineToleranceMessage(controller.error, weakFit.maxError);
      await expectSourcesHidden([weakSpline]);
      expect(controller.selectedSketchEntityIds, {weakLineId});

      final canUndoBeforeOver = controller.commands.manager.canUndo;
      final historyBeforeOver = controller.commands.manager.history.length;
      final overSuggestion = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.line,
        entityIds: overLines.map((source) => source.id).toList(),
        confidence: 0.99,
      );
      final overFit = engine.diagnoseSelectedLineOrSpline(overLines).result!;
      expect(overFit.maxError, closeTo(0.15, 1e-12));
      expect(
        overFit.maxError,
        greaterThan(lineTolerance.reconstructionToleranceMm),
      );
      expect(
        await controller.acceptSketchReconstructionSuggestion(overSuggestion),
        isNull,
      );
      expect(controller.commands.manager.canUndo, canUndoBeforeOver);
      expect(controller.commands.manager.history.length, historyBeforeOver);
      expectLineToleranceMessage(controller.error, overFit.maxError);
      expect(controller.error, contains('Linha rejeitada'));
      expect(
        overLines.every(
          (source) => controller.sketchApi!.entity(source.id)!.visible,
        ),
        isTrue,
      );
      expect(controller.sketchApi!.entity(splineLineId), isA<SketchLine>());
      expect(controller.sketchApi!.entity(exactLineId), isA<SketchLine>());
      expect(controller.sketchApi!.entity(weakLineId), isA<SketchLine>());

      controller.analyzeSketchReconstruction();
      final arcSuggestion = controller.sketchReconstructionSuggestions
          .firstWhere(
            (item) =>
                (item.kind == SketchReconstructionKind.arc ||
                    item.kind == SketchReconstructionKind.circle) &&
                item.entityIds.every(
                  (id) => arcSources.any((source) => source.id == id),
                ) &&
                item.center != null &&
                item.confidence >= .75,
          );
      final arcId = (await controller.acceptSketchReconstructionSuggestion(
        arcSuggestion,
      ))!;
      expect(controller.sketchApi!.entity(chainId), isA<SketchLine>());
      expect(controller.sketchApi!.entity(splineLineId), isA<SketchLine>());
      expect(controller.sketchApi!.entity(exactLineId), isA<SketchLine>());
      expect(controller.sketchApi!.entity(weakLineId), isA<SketchLine>());
      expect(controller.sketchApi!.entity(arcId), isNotNull);
      await expectSourcesHidden(collinear);
      await expectSourcesHidden([straightSpline]);
      await expectSourcesHidden(exactLines);
      await expectSourcesHidden([weakSpline]);
      await expectSourcesHidden(arcSources);
      expect(isolated.visible, isTrue);
      expect(elbowHorizontal.visible, isTrue);
      expect(curvedSpline.visible, isTrue);
      expect(overLines.every((source) => source.visible), isTrue);
      expect(
        controller.sketchEntities
            .where(
              (entity) =>
                  entity.visible &&
                  entity.metadata['reconstructionHidden'] != true &&
                  (entity.id == chainId ||
                      entity.id == splineLineId ||
                      entity.id == exactLineId ||
                      entity.id == weakLineId ||
                      entity.id == arcId),
            )
            .map((entity) => entity.id)
            .toSet(),
        {chainId, splineLineId, exactLineId, weakLineId, arcId},
      );

      final regionDiagnosis = engine.diagnoseSelectedLineOrSpline(regionOver);
      expect(regionDiagnosis.failure, isNull);
      expect(
        regionDiagnosis.result!.maxError,
        greaterThan(lineTolerance.reconstructionToleranceMm),
      );
      controller.beginSketchCircularSelection();
      for (final source in regionOver) {
        controller.selectSketchEntity(source.id);
      }
      controller.setSketchRegionFitOutput(SketchRegionFitOutput.line);
      await controller.fitSelectedSketchLineOrSpline();
      final regionId = controller.selectedSketchEntityIds.single;
      expect(controller.sketchApi!.entity(regionId), isA<SketchLine>());
      await expectSourcesHidden(regionOver);
      await controller.undo();
      expect(controller.sketchApi!.entity(regionId), isNull);
      await expectSourcesRestored(regionOver);
      expect(controller.sketchApi!.entity(chainId), isA<SketchLine>());
      expect(controller.sketchApi!.entity(exactLineId), isA<SketchLine>());
      expect(controller.sketchApi!.entity(weakLineId), isA<SketchLine>());

      await controller.persist();
      final reopenedKernels = KernelManager()
        ..register(_HealthySurfaceKernel(), makeDefault: true);
      final reopenedCad = DesktopCadController(
        kernels: reopenedKernels,
        projects: ProjectManager.instance,
      );
      final reopenedCommands = DesktopCommandCoordinator(
        cad: reopenedCad,
        projects: ProjectManager.instance,
      );
      final reopened = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: reopenedCommands,
        runtime: reopenedCad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(
            repository: ReferenceRepository(projects: harness.projects),
          ),
        ),
      );
      addTearDown(reopened.dispose);
      addTearDown(reopenedCad.dispose);
      await reopenedCad.runtime.open(
        'g124-3-line-promotion',
        harness.directory,
      );
      await reopened.configureProject(
        projectId: 'g124-3-line-promotion',
        projectDirectory: harness.directory,
      );
      expect(reopened.sketchApi!.entity(chainId), isA<SketchLine>());
      expect(reopened.sketchApi!.entity(splineLineId), isA<SketchLine>());
      expect(reopened.sketchApi!.entity(exactLineId), isA<SketchLine>());
      expect(reopened.sketchApi!.entity(weakLineId), isA<SketchLine>());
      expect(reopened.sketchApi!.entity(arcId), isNotNull);
      expect(reopened.sketchApi!.entity(isolated.id)!.visible, isTrue);
      expect(
        collinear.every(
          (source) => reopened.sketchApi!.entity(source.id)?.visible == false,
        ),
        isTrue,
      );
      expect(reopened.sketchApi!.entity(straightSpline.id)?.visible, isFalse);
      expect(
        exactLines.every(
          (source) => reopened.sketchApi!.entity(source.id)?.visible == false,
        ),
        isTrue,
      );
      expect(reopened.sketchApi!.entity(weakSpline.id)?.visible, isFalse);
      expect(reopened.commands.manager.canUndo, isFalse);
    },
  );

  test(
    'assistant recognition uses eligible sources and rejects stale suggestions',
    () async {
      final harness = await _g124Harness('g124-6a-eligible-sources');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final controller = harness.controller;
      final visible = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final duplicate = controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final hidden = controller.sketchApi!.builders.line.build(
        const SketchVector(20, 0),
        const SketchVector(30, 0),
      )..visible = false;
      hidden.metadata['reconstructionHidden'] = true;
      final promoted = controller.sketchApi!.builders.line.build(
        const SketchVector(40, 0),
        const SketchVector(50, 0),
      );
      promoted.metadata['reconstructionKind'] = 'line';
      final construction = controller.sketchApi!.builders.line.build(
        const SketchVector(60, 0),
        const SketchVector(70, 0),
      )..construction = true;

      controller.analyzeSketchReconstruction();
      final ids = controller.sketchReconstructionSuggestions
          .expand((suggestion) => suggestion.entityIds)
          .toSet();
      expect(ids, contains(visible.id));
      expect(ids, contains(promoted.id));
      expect(ids, isNot(contains(hidden.id)));
      expect(ids, isNot(contains(duplicate.id)));
      expect(ids, isNot(contains(construction.id)));

      final geometryStale = controller.sketchReconstructionSuggestions
          .firstWhere(
            (suggestion) =>
                suggestion.kind == SketchReconstructionKind.line &&
                suggestion.entityIds.length == 1 &&
                suggestion.entityIds.single == promoted.id,
          );
      final historyBeforeGeometry = controller.commands.manager.history.length;
      promoted.parameters['end'] = const SketchVector(50, 1).toJson();
      promoted.refreshDerivedParameters();
      expect(
        await controller.acceptSketchReconstructionSuggestion(geometryStale),
        isNull,
      );
      expect(controller.error, contains('geometria de origem foi alterada'));
      expect(controller.commands.manager.history.length, historyBeforeGeometry);

      final stale = controller.sketchReconstructionSuggestions.firstWhere(
        (suggestion) =>
            suggestion.kind == SketchReconstructionKind.line &&
            suggestion.entityIds.length == 1 &&
            suggestion.entityIds.single == visible.id,
      );
      final historyBefore = controller.commands.manager.history.length;
      visible.visible = false;
      final accepted = await controller.acceptSketchReconstructionSuggestion(
        stale,
      );
      expect(accepted, isNull);
      expect(controller.error, contains('não estão mais visíveis'));
      expect(controller.commands.manager.history.length, historyBefore);
      expect(controller.sketchApi!.entity(visible.id), isNotNull);
    },
  );

  test(
    'line reconstruction preserves valid external boundaries atomically',
    () async {
      final harness = await _g124Harness('g124-7a-boundaries');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final controller = harness.controller;
      final api = controller.sketchApi!;

      Future<String> promote(List<SketchEntity> sources, String label) async {
        final suggestion = SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.line,
          entityIds: sources.map((entity) => entity.id).toList(),
          confidence: 1,
        );
        final id = await controller.acceptSketchReconstructionSuggestion(
          suggestion,
        );
        expect(id, isNotNull, reason: label);
        return id!;
      }

      final lineBefore = api.builders.line.build(
        const SketchVector(-10, 0),
        const SketchVector(0, 0),
      );
      final lineA = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(5, .05),
      );
      final lineB = api.builders.line.build(
        const SketchVector(5, .05),
        const SketchVector(10, 0),
      );
      final lineAfter = api.builders.line.build(
        const SketchVector(10, 0),
        const SketchVector(20, 0),
      );
      final lineId = await promote([lineA, lineB], 'line-line');
      final rebuiltLine = api.entity(lineId)! as SketchLine;
      final rebuiltLineEnds = [
        SketchVector.fromJson(rebuiltLine.parameters['start']),
        SketchVector.fromJson(rebuiltLine.parameters['end']),
      ];
      expect(
        rebuiltLineEnds.any(
          (point) =>
              (point - const SketchVector(0, 0)).dot(
                point - const SketchVector(0, 0),
              ) <
              1e-18,
        ),
        isTrue,
      );
      expect(
        rebuiltLineEnds.any(
          (point) =>
              (point - const SketchVector(10, 0)).dot(
                point - const SketchVector(10, 0),
              ) <
              1e-18,
        ),
        isTrue,
      );
      expect(lineBefore.visible, isTrue);
      expect(lineAfter.visible, isTrue);
      expect(lineA.visible, isFalse);
      expect(lineB.visible, isFalse);
      expect(
        controller.sketchHealth
            .ofType(SketchHealthIssueType.gap)
            .where((issue) => issue.entityIds.contains(lineId)),
        isEmpty,
      );
      await controller.undo();
      expect(api.entity(lineId), isNull);
      expect(api.entity(lineA.id)!.visible, isTrue);
      expect(api.entity(lineB.id)!.visible, isTrue);
      await controller.redo();
      expect(api.entity(lineId), isA<SketchLine>());
      await controller.undo();
      await controller.redo();

      final arc = api.builders.arc.build(
        const SketchVector(105, 0),
        5,
        math.pi,
        2 * math.pi,
      );
      final arcA = api.builders.line.build(
        const SketchVector(100, 0),
        const SketchVector(105, .05),
      );
      final arcB = api.builders.line.build(
        const SketchVector(105, .05),
        const SketchVector(110, 0),
      );
      final arcId = await promote([arcA, arcB], 'line-arc');
      final rebuiltArcLine = api.entity(arcId)! as SketchLine;
      final arcEnds = [
        SketchVector.fromJson(rebuiltArcLine.parameters['start']),
        SketchVector.fromJson(rebuiltArcLine.parameters['end']),
      ];
      expect(
        arcEnds.any(
          (point) =>
              (point - const SketchVector(100, 0)).dot(
                point - const SketchVector(100, 0),
              ) <
              1e-18,
        ),
        isTrue,
      );
      expect(
        arcEnds.any(
          (point) =>
              (point - const SketchVector(110, 0)).dot(
                point - const SketchVector(110, 0),
              ) <
              1e-18,
        ),
        isTrue,
      );
      expect(api.entity(arc.id)!.visible, isTrue);

      final spline = api.builders.spline.build([
        const SketchVector(200, 0),
        const SketchVector(205, -1),
        const SketchVector(210, 0),
      ]);
      final splineA = api.builders.line.build(
        const SketchVector(200, 0),
        const SketchVector(205, .05),
      );
      final splineB = api.builders.line.build(
        const SketchVector(205, .05),
        const SketchVector(210, 0),
      );
      final splineId = await promote([splineA, splineB], 'line-spline');
      final rebuiltSplineLine = api.entity(splineId)! as SketchLine;
      final splineEnds = [
        SketchVector.fromJson(rebuiltSplineLine.parameters['start']),
        SketchVector.fromJson(rebuiltSplineLine.parameters['end']),
      ];
      expect(
        splineEnds.any(
          (point) =>
              (point - const SketchVector(200, 0)).dot(
                point - const SketchVector(200, 0),
              ) <
              1e-18,
        ),
        isTrue,
      );
      expect(
        splineEnds.any(
          (point) =>
              (point - const SketchVector(210, 0)).dot(
                point - const SketchVector(210, 0),
              ) <
              1e-18,
        ),
        isTrue,
      );
      expect(api.entity(spline.id)!.visible, isTrue);

      final gapNeighbor = api.builders.line.build(
        const SketchVector(299.9, 0),
        const SketchVector(299.95, 0),
      );
      final gapA = api.builders.line.build(
        const SketchVector(300, 0),
        const SketchVector(305, .05),
      );
      final gapB = api.builders.line.build(
        const SketchVector(305, .05),
        const SketchVector(310, 0),
      );
      final gapId = await promote([gapA, gapB], 'preexisting gap');
      expect(controller.error, contains('gap preexistente'));
      expect(api.entity(gapNeighbor.id)!.visible, isTrue);
      expect(api.entity(gapId), isA<SketchLine>());

      final freeA = api.builders.line.build(
        const SketchVector(600, 0),
        const SketchVector(605, .05),
      );
      final freeB = api.builders.line.build(
        const SketchVector(605, .05),
        const SketchVector(610, 0),
      );
      final freeId = await promote([freeA, freeB], 'sem fronteiras');
      expect(api.entity(freeId), isA<SketchLine>());

      final oneNeighbor = api.builders.line.build(
        const SketchVector(690, 0),
        const SketchVector(700, 0),
      );
      final oneA = api.builders.line.build(
        const SketchVector(700, 0),
        const SketchVector(705, .05),
      );
      final oneB = api.builders.line.build(
        const SketchVector(705, .05),
        const SketchVector(710, 0),
      );
      final oneId = await promote([oneA, oneB], 'uma fronteira');
      final oneLine = api.entity(oneId)! as SketchLine;
      final oneEnds = [
        SketchVector.fromJson(oneLine.parameters['start']),
        SketchVector.fromJson(oneLine.parameters['end']),
      ];
      expect(
        oneEnds.any(
          (point) =>
              (point - const SketchVector(700, 0)).dot(
                point - const SketchVector(700, 0),
              ) <
              1e-18,
        ),
        isTrue,
      );
      expect(api.entity(oneNeighbor.id)!.visible, isTrue);

      final incompatibleNeighbor = api.builders.line.build(
        const SketchVector(790, 0),
        const SketchVector(800, 0),
      );
      final incompatibleA = api.builders.line.build(
        const SketchVector(800, 0),
        const SketchVector(805, 1),
      );
      final incompatibleB = api.builders.line.build(
        const SketchVector(805, 1),
        const SketchVector(810, 0),
      );
      final historyBeforeIncompatible =
          controller.commands.manager.history.length;
      final incompatibleId = await controller
          .acceptSketchReconstructionSuggestion(
            SketchReconstructionSuggestion(
              kind: SketchReconstructionKind.line,
              entityIds: [incompatibleA.id, incompatibleB.id],
              confidence: 1,
            ),
          );
      expect(incompatibleId, isNull);
      expect(controller.error, contains('condicionado'));
      expect(
        controller.commands.manager.history.length,
        historyBeforeIncompatible,
      );
      expect(api.entity(incompatibleNeighbor.id)!.visible, isTrue);
      expect(api.entity(incompatibleA.id)!.visible, isTrue);
      expect(api.entity(incompatibleB.id)!.visible, isTrue);

      final branchA = api.builders.line.build(
        const SketchVector(400, 0),
        const SketchVector(405, .05),
      );
      final branchB = api.builders.line.build(
        const SketchVector(405, .05),
        const SketchVector(410, 0),
      );
      final branchOne = api.builders.line.build(
        const SketchVector(390, 0),
        const SketchVector(400, 0),
      );
      final branchTwo = api.builders.line.build(
        const SketchVector(390, 1),
        const SketchVector(400, 0),
      );
      final historyBeforeBranch = controller.commands.manager.history.length;
      final branchId = await controller.acceptSketchReconstructionSuggestion(
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.line,
          entityIds: [branchA.id, branchB.id],
          confidence: 1,
        ),
      );
      expect(branchId, isNull);
      expect(controller.error, contains('ramificação ambígua'));
      expect(controller.commands.manager.history.length, historyBeforeBranch);
      expect(api.entity(branchA.id)!.visible, isTrue);
      expect(api.entity(branchB.id)!.visible, isTrue);
      expect(api.entity(branchOne.id)!.visible, isTrue);
      expect(api.entity(branchTwo.id)!.visible, isTrue);
    },
  );

  test(
    'line reconstruction blocks incident constraints without partial edits',
    () async {
      final harness = await _g124Harness('g124-7a-constraints');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final controller = harness.controller;
      final api = controller.sketchApi!;
      final external = api.builders.line.build(
        const SketchVector(-10, 0),
        const SketchVector(0, 0),
      );
      final first = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(5, .05),
      );
      final second = api.builders.line.build(
        const SketchVector(5, .05),
        const SketchVector(10, 0),
      );
      final constraints = controller.constraintApi!;
      constraints.builders.coincident.build([
        '${external.id}:end',
        '${first.id}:start',
      ]);
      constraints.builders.of(SketchConstraintType.fixed).build([first.id]);
      constraints.builders.distance.build([second.id], value: 5);
      constraints.createDrivingDimension(
        type: SketchDimensionType.angular,
        references: [first.id, second.id],
        value: math.pi / 4,
      );
      final historyBefore = controller.commands.manager.history.length;
      final accepted = await controller.acceptSketchReconstructionSuggestion(
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.line,
          entityIds: [first.id, second.id],
          confidence: 1,
        ),
      );
      expect(accepted, isNull);
      expect(controller.error, contains('constraints impedem'));
      expect(controller.error, contains('coincident'));
      expect(controller.error, contains('fixed'));
      expect(controller.error, contains('distance'));
      expect(controller.error, contains('angular'));
      expect(controller.commands.manager.history.length, historyBefore);
      expect(api.entity(external.id)!.visible, isTrue);
      expect(api.entity(first.id)!.visible, isTrue);
      expect(api.entity(second.id)!.visible, isTrue);
      expect(
        api.engine.entities.values.where(
          (entity) => entity.metadata['reconstructionHidden'] == true,
        ),
        isEmpty,
      );
    },
  );

  test('reconstructed assistant arc accepts Inspector radius edits', () async {
    final harness = await _g124Harness('g124-recon-arc-radius');
    addTearDown(() => harness.directory.delete(recursive: true));
    addTearDown(harness.controller.dispose);
    addTearDown(harness.cad.dispose);
    final controller = harness.controller;
    final cad = harness.cad;
    final api = controller.sketchApi!;

    SketchVector arcPoint(double radius, double angle) =>
        SketchVector(radius * math.cos(angle), radius * math.sin(angle));
    List<SketchLine> chordChain({
      required double radius,
      required double a0,
      required double a1,
      int count = 5,
    }) => [
      for (var index = 0; index < count; index++)
        api.builders.line.build(
          arcPoint(radius, a0 + (a1 - a0) * index / count),
          arcPoint(radius, a0 + (a1 - a0) * (index + 1) / count),
        ),
    ];

    SketchVector arcEnd(SketchEntity entity, String key) {
      final center = SketchVector.fromJson(entity.parameters['center']);
      final radius = (entity.parameters['radius'] as num).toDouble();
      final angle = (entity.parameters['${key}Angle'] as num).toDouble();
      return SketchVector(
        center.x + radius * math.cos(angle),
        center.y + radius * math.sin(angle),
      );
    }

    const reconstructedRadius = 7.216;
    final isolatedSources = chordChain(
      radius: reconstructedRadius,
      a0: 0.2,
      a1: 1.4,
    );
    controller.analyzeSketchReconstruction();
    final isolatedSuggestion = controller.sketchReconstructionSuggestions
        .firstWhere(
          (item) =>
              (item.kind == SketchReconstructionKind.arc ||
                  item.kind == SketchReconstructionKind.circle) &&
              item.entityIds.every(
                (id) => isolatedSources.any((source) => source.id == id),
              ) &&
              item.center != null &&
              item.confidence >= .75,
        );
    final isolatedId = (await controller.acceptSketchReconstructionSuggestion(
      isolatedSuggestion,
    ))!;
    final isolatedArc = api.entity(isolatedId)! as SketchArc;
    expect(isolatedArc.metadata['reconstructionKind'], 'arc');
    expect(isolatedArc.metadata['reconstructionHidden'], isNot(true));
    expect(
      (isolatedArc.parameters['radius'] as num).toDouble(),
      closeTo(reconstructedRadius, 1e-3),
    );
    for (final source in isolatedSources) {
      expect(api.entity(source.id)!.visible, isFalse);
      expect(api.entity(source.id)!.metadata['reconstructionHidden'], isTrue);
    }

    await controller.updateSketchEntityParameters(isolatedId, {'radius': 7.5});
    expect(
      (api.entity(isolatedId)!.parameters['radius'] as num).toDouble(),
      closeTo(7.5, 1e-9),
    );
    expect(controller.arcRadiusEditPreview, isNull);
    expect(cad.runtime.scene.find(isolatedId), isNotNull);
    expect(
      cad
          .runtime
          .document!
          .entities[isolatedId]!
          .data['sketchEntity']['parameters']['radius'],
      closeTo(7.5, 1e-9),
    );
    await controller.updateSketchEntityParameters(isolatedId, {'radius': 6.8});
    expect(
      (api.entity(isolatedId)!.parameters['radius'] as num).toDouble(),
      closeTo(6.8, 1e-9),
    );
    await controller.undo();
    expect(
      (api.entity(isolatedId)!.parameters['radius'] as num).toDouble(),
      closeTo(7.5, 1e-9),
    );
    await controller.redo();
    expect(
      (api.entity(isolatedId)!.parameters['radius'] as num).toDouble(),
      closeTo(6.8, 1e-9),
    );
    await controller.undo();
    await controller.redo();
    expect(
      (api.entity(isolatedId)!.parameters['radius'] as num).toDouble(),
      closeTo(6.8, 1e-9),
    );

    final manual = api.builders.arc.build(
      const SketchVector(80, 0),
      7.216,
      0,
      math.pi / 2,
    );
    await controller.updateSketchEntityParameters(manual.id, {'radius': 7.5});
    expect(
      (api.entity(manual.id)!.parameters['radius'] as num).toDouble(),
      closeTo(7.5, 1e-9),
    );

    final neighborRadius = 7.216;
    final beforeChord = api.builders.line.build(
      arcPoint(neighborRadius, -0.3),
      arcPoint(neighborRadius, 0),
    );
    final c0Sources = chordChain(
      radius: neighborRadius,
      a0: 0,
      a1: 0.6,
      count: 4,
    );
    final afterChord = api.builders.line.build(
      arcPoint(neighborRadius, 0.6),
      arcPoint(neighborRadius, 0.9),
    );
    controller.beginSketchCircularSelection();
    for (final source in c0Sources) {
      controller.selectSketchEntity(source.id);
    }
    await controller.fitSelectedSketchCircularGeometry();
    final c0Id = controller.selectedSketchEntityIds.single;
    expect(api.entity(c0Id), isA<SketchArc>());
    expect(api.entity(c0Id)!.metadata['reconstructionKind'], 'arc');
    expect(api.entity(beforeChord.id)!.visible, isTrue);
    expect(api.entity(afterChord.id)!.visible, isTrue);
    final beforeSnapshot = List<double>.from(
      (api.entity(beforeChord.id)!.parameters['end'] as List).cast<num>().map(
        (value) => value.toDouble(),
      ),
    );
    final afterSnapshot = List<double>.from(
      (api.entity(afterChord.id)!.parameters['start'] as List).cast<num>().map(
        (value) => value.toDouble(),
      ),
    );
    await controller.updateSketchEntityParameters(c0Id, {'radius': 7.5});
    expect(
      (api.entity(c0Id)!.parameters['radius'] as num).toDouble(),
      closeTo(7.5, 1e-9),
    );
    expect(controller.arcRadiusEditPreview, isNull);
    expect(
      (api.entity(beforeChord.id)!.parameters['end'] as List).cast<num>().map(
        (value) => value.toDouble(),
      ),
      beforeSnapshot,
    );
    expect(
      (api.entity(afterChord.id)!.parameters['start'] as List).cast<num>().map(
        (value) => value.toDouble(),
      ),
      afterSnapshot,
    );

    final fillet = api.builders.arc.build(
      const SketchVector(40, 40),
      1,
      0,
      math.pi / 2,
    );
    fillet.metadata['reconstructionKind'] = 'arc';
    final preceding = api.builders.line.build(
      const SketchVector(41, 39),
      const SketchVector(41, 40),
    );
    final following = api.builders.line.build(
      const SketchVector(40, 41),
      const SketchVector(39, 41),
    );
    await expectLater(
      controller.updateSketchEntityParameters(fillet.id, {'radius': 1.5}),
      throwsA(isA<ArcRadiusEditConfirmationRequired>()),
    );
    expect(api.entity(fillet.id)!.parameters['radius'], 1.0);
    expect(controller.arcRadiusEditPreview, isNotNull);
    expect(
      cad.runtime.scene.find(
        'arc-radius-preview-${controller.arcRadiusEditPreview!.token}',
      ),
      isNotNull,
    );
    controller.cancelArcRadiusEditPreview();
    expect(controller.arcRadiusEditPreview, isNull);
    expect(api.entity(fillet.id)!.parameters['radius'], 1.0);
    await expectLater(
      controller.updateSketchEntityParameters(fillet.id, {'radius': 1.5}),
      throwsA(isA<ArcRadiusEditConfirmationRequired>()),
    );
    await controller.confirmArcRadiusEditPreview();
    expect(controller.arcRadiusEditPreview, isNull);
    expect(
      (api.entity(fillet.id)!.parameters['radius'] as num).toDouble(),
      closeTo(1.5, 1e-9),
    );
    expect(arcEnd(api.entity(fillet.id)!, 'start').x, closeTo(41, 1e-9));
    expect(
      SketchVector.fromJson(api.entity(preceding.id)!.parameters['end']).y,
      closeTo(arcEnd(api.entity(fillet.id)!, 'start').y, 1e-9),
    );
    expect(
      SketchVector.fromJson(api.entity(following.id)!.parameters['start']).x,
      closeTo(arcEnd(api.entity(fillet.id)!, 'end').x, 1e-9),
    );

    final rejected = api.builders.arc.build(
      const SketchVector(60, 60),
      1,
      0,
      math.pi / 2,
    );
    rejected.metadata['reconstructionKind'] = 'arc';
    final onlyFrontier = api.builders.line.build(
      const SketchVector(61, 59),
      const SketchVector(61, 60),
    );
    await expectLater(
      controller.updateSketchEntityParameters(rejected.id, {'radius': 1.5}),
      throwsA(
        isA<StateError>().having(
          (error) => error.toString(),
          'message',
          contains('Não foi possível manter a tangência nas duas fronteiras.'),
        ),
      ),
    );
    expect(controller.error, contains('tangência nas duas fronteiras'));
    expect(api.entity(rejected.id)!.parameters['radius'], 1.0);
    expect(
      SketchVector.fromJson(api.entity(onlyFrontier.id)!.parameters['end']).y,
      60,
    );

    await controller.persist();
    final reopenedKernels = KernelManager()
      ..register(_HealthySurfaceKernel(), makeDefault: true);
    final reopenedCad = DesktopCadController(
      kernels: reopenedKernels,
      projects: ProjectManager.instance,
    );
    final reopenedCommands = DesktopCommandCoordinator(
      cad: reopenedCad,
      projects: ProjectManager.instance,
    );
    final reopened = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: reopenedCommands,
      runtime: reopenedCad.runtime,
      referenceApi: ReferenceApi(
        engine: ReferenceEngine(
          repository: ReferenceRepository(projects: harness.projects),
        ),
      ),
    );
    addTearDown(reopened.dispose);
    addTearDown(reopenedCad.dispose);
    await reopenedCad.runtime.open('g124-recon-arc-radius', harness.directory);
    await reopened.configureProject(
      projectId: 'g124-recon-arc-radius',
      projectDirectory: harness.directory,
    );
    expect(
      (reopened.sketchApi!.entity(isolatedId)!.parameters['radius'] as num)
          .toDouble(),
      closeTo(6.8, 1e-9),
    );
    expect(
      (reopened.sketchApi!.entity(c0Id)!.parameters['radius'] as num)
          .toDouble(),
      closeTo(7.5, 1e-9),
    );
    expect(
      reopened.sketchApi!.entity(isolatedId)!.metadata['reconstructionKind'],
      'arc',
    );
  });

  testWidgets(
    'Inspector radius field submits 7.216 to 7.500 with comma decimals',
    (tester) async {
      double? submitted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SketchInspectorNumberProperty(
              label: 'Radius',
              value: 7.216,
              suffix: 'mm',
              onSubmitted: (value) async => submitted = value,
            ),
          ),
        ),
      );
      expect(find.text('7.216'), findsOneWidget);
      await tester.tap(find.byType(TextFormField));
      await tester.enterText(find.byType(TextFormField), '7,500');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(submitted, 7.5);
    },
  );

  test(
    'Assistant keeps ordered Ctrl-style multi-selection and blocks multi-accept',
    () async {
      final harness = await _g124Harness('g124-reconstruction-multiselect');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final first = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final second = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(10, 0),
        const SketchVector(20, 0),
      );
      final third = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(20, 0),
        const SketchVector(30, 0),
      );
      final suggestions = [
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.line,
          entityIds: [first.id],
          confidence: 1,
        ),
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.line,
          entityIds: [second.id],
          confidence: 1,
        ),
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.line,
          entityIds: [third.id],
          confidence: 1,
        ),
      ];

      harness.controller.highlightSketchReconstructionSuggestion(
        suggestions[0],
        persistent: true,
      );
      harness.controller.selectSketchReconstructionSuggestion(
        suggestions[1],
        additive: true,
      );
      harness.controller.selectSketchReconstructionSuggestion(
        suggestions[2],
        additive: true,
      );
      expect(
        harness.controller.selectedSketchReconstructionSuggestions,
        suggestions,
      );
      expect(
        harness
            .controller
            .sketchReconstructionSelectionAnalysis
            ?.classification,
        SketchReconstructionSelectionClassification.openChain,
      );
      final ordered = harness
          .controller
          .sketchReconstructionSelectionAnalysis!
          .orderedSuggestions
          .map((item) => item.entityIds.single)
          .toList();
      expect(
        ordered.join('|') == [first.id, second.id, third.id].join('|') ||
            ordered.join('|') == [third.id, second.id, first.id].join('|'),
        isTrue,
      );
      expect(
        harness.controller.sketchReconstructionSelectionOrder(suggestions[1]),
        2,
      );
      expect(
        harness.cad.runtime.scene
            .find(sketchReconstructionHighlightId)!
            .geometry['entityIds'],
        containsAll([first.id, second.id, third.id]),
      );
      harness.controller.selectSketchReconstructionSuggestion(
        suggestions[1],
        additive: true,
      );
      expect(harness.controller.selectedSketchReconstructionSuggestions, [
        suggestions[0],
        suggestions[2],
      ]);
      final historyBefore = harness.controller.commands.manager.history.length;
      expect(
        await harness.controller.acceptSketchReconstructionSuggestion(
          suggestions[0],
        ),
        isNull,
      );
      expect(
        harness.controller.sketchReconstructionMessage,
        contains('aplicação conjunta'),
      );
      expect(harness.controller.commands.manager.history.length, historyBefore);
    },
  );

  test(
    'joint acceptance preview is transient, cancellable and does not mutate the Sketch',
    () async {
      final harness = await _g124Harness('g124-joint-acceptance-preview');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final first = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final second = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(10, 0),
        const SketchVector(20, 0),
      );
      final third = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(20, 0),
        const SketchVector(30, 0),
      );
      final suggestions = [
        for (final entity in [first, second, third])
          SketchReconstructionSuggestion(
            kind: SketchReconstructionKind.line,
            entityIds: [entity.id],
            confidence: 1,
          ),
      ];
      for (final suggestion in suggestions) {
        harness.controller.selectSketchReconstructionSuggestion(
          suggestion,
          additive: true,
        );
      }
      final historyBefore = harness.controller.commands.manager.history.length;
      final documentBefore = harness.cad.runtime.document!.entities.keys
          .toSet();

      harness.controller.previewSketchReconstructionAcceptance();

      final preview = harness.controller.sketchReconstructionJointPreview;
      expect(preview, isNotNull);
      expect(preview!.canApply, isTrue);
      expect(
        harness.controller.canConfirmSketchReconstructionJointAcceptance,
        isTrue,
      );
      expect(
        harness.cad.runtime.scene.find(
          '${sketchReconstructionJointPreviewPrefix}0',
        ),
        isNotNull,
      );
      expect(
        harness.cad.runtime.scene.find(
          sketchReconstructionJointConnectionsPreviewId,
        ),
        isNotNull,
      );
      expect(harness.controller.commands.manager.history.length, historyBefore);
      expect(
        harness.cad.runtime.document!.entities.keys.toSet(),
        documentBefore,
      );
      expect(first.visible, isTrue);
      expect(second.visible, isTrue);
      expect(third.visible, isTrue);

      // Any selection change invalidates the preview before it can become
      // stale, while leaving the source entities untouched.
      harness.controller.selectSketchReconstructionSuggestion(
        suggestions[1],
        additive: true,
      );
      expect(harness.controller.sketchReconstructionJointPreview, isNull);
      expect(
        harness.controller.canConfirmSketchReconstructionJointAcceptance,
        isFalse,
      );
      expect(
        harness.cad.runtime.scene.find(
          '${sketchReconstructionJointPreviewPrefix}0',
        ),
        isNull,
      );
      harness.controller.selectSketchReconstructionSuggestion(
        suggestions[1],
        additive: true,
      );

      harness.controller.previewSketchReconstructionAcceptance();
      expect(harness.controller.sketchReconstructionJointPreview, isNotNull);
      harness.controller.cancelSketchReconstructionJointPreview();
      expect(harness.controller.sketchReconstructionJointPreview, isNull);
      expect(
        harness.cad.runtime.scene.find(
          '${sketchReconstructionJointPreviewPrefix}0',
        ),
        isNull,
      );
      expect(
        harness.cad.runtime.scene.find(
          sketchReconstructionJointConnectionsPreviewId,
        ),
        isNull,
      );
      expect(harness.controller.selectedSketchReconstructionSuggestions, [
        suggestions[0],
        suggestions[2],
        suggestions[1],
      ]);
      expect(
        harness.controller.canConfirmSketchReconstructionJointAcceptance,
        isFalse,
      );

      harness.controller.clearSketchReconstructionSelection();
      final conflicting = [
        suggestions.first,
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.arc,
          entityIds: [first.id],
          confidence: 1,
          center: const SketchVector(5, 5),
          radius: 5,
          startAngle: -math.pi / 2,
          endAngle: math.pi / 2,
        ),
      ];
      for (final suggestion in conflicting) {
        harness.controller.selectSketchReconstructionSuggestion(
          suggestion,
          additive: true,
        );
      }
      harness.controller.previewSketchReconstructionAcceptance();
      expect(harness.controller.sketchReconstructionJointPreview, isNotNull);
      expect(
        harness.controller.sketchReconstructionJointPreview!.blockers,
        isNotEmpty,
      );
      expect(
        harness.controller.canConfirmSketchReconstructionJointAcceptance,
        isFalse,
      );
      harness.controller.cancelSketchReconstructionJointPreview();
    },
  );

  test(
    'Undo of accepted reconstruction clears the removed entity from CAD selection',
    () async {
      final harness = await _g124Harness('g124-selection-after-undo');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final first = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final second = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(10, 0),
        const SketchVector(20, 0),
      );
      final historyBeforeSelect =
          harness.controller.commands.manager.history.length;
      harness.controller.selectSketchEntity(first.id);
      harness.controller.selectSketchEntity(second.id, additive: true);
      expect(harness.controller.selectedSketchEntityIds, {
        first.id,
        second.id,
      });
      expect(
        harness.controller.commands.manager.history.length,
        historyBeforeSelect,
      );

      final beforeIds = harness.controller.activeSketch!.entityIds.toSet();
      await harness.controller.commands.dispatch(
        'reverse.sketch.draw',
        {
          'tool': 'line',
          'points': [
            const SketchVector(30, 0).toJson(),
            const SketchVector(32, 2).toJson(),
          ],
        },
      );
      final createdId = harness.controller.activeSketch!.entityIds
          .firstWhere((id) => !beforeIds.contains(id));
      final historyAfterDraw =
          harness.controller.commands.manager.history.length;
      harness.controller.selectSketchEntity(createdId);
      expect(harness.controller.selectedSketchEntityIds, {createdId});
      expect(
        harness.controller.commands.manager.history.length,
        historyAfterDraw,
      );

      await harness.controller.undo();
      expect(harness.controller.sketchApi!.entity(createdId), isNull);
      expect(
        harness.controller.selectedSketchEntityIds.contains(createdId),
        isFalse,
      );
      final historyAfterUndo =
          harness.controller.commands.manager.history.length;
      harness.controller.selectSketchEntity(first.id, additive: true);
      expect(harness.controller.selectedSketchEntityIds, {first.id});
      expect(
        harness.controller.commands.manager.history.length,
        historyAfterUndo,
      );

      await harness.controller.redo();
      expect(harness.controller.sketchApi!.entity(createdId), isNotNull);
      expect(
        harness.controller.selectedSketchEntityIds.contains(createdId),
        isFalse,
      );
      expect(harness.controller.selectedSketchEntityIds, {first.id});
      final historyAfterRedo =
          harness.controller.commands.manager.history.length;
      harness.controller.selectSketchEntity(createdId, additive: true);
      expect(harness.controller.selectedSketchEntityIds, {
        first.id,
        createdId,
      });
      expect(
        harness.controller.commands.manager.history.length,
        historyAfterRedo,
      );

      final firstSketchId = harness.controller.activeSketch!.id;
      final other = harness.controller.sketchApi!.createSketch('other-sketch');
      harness.controller.selectSketch(other.id);
      expect(harness.controller.selectedSketchEntityIds, isEmpty);
      harness.controller.selectSketch(firstSketchId);
      expect(harness.controller.selectedSketchEntityIds, isEmpty);

      harness.controller.selectSketchEntity(first.id);
      expect(harness.controller.selectedSketchEntityIds, {first.id});
      harness.controller.detachProject();
      expect(harness.controller.selectedSketchEntityIds, isEmpty);
    },
  );

  test(
    'Save/Open preserves independent manual and Section-derived Sketch roots',
    () async {
      final harness = await _g124Harness('g124-multiple-sketch-rehydration');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final controller = harness.controller;
      final api = controller.sketchApi!;
      final manual = controller.activeSketch!;
      final manualLine = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      api.builders.arc.build(
        const SketchVector(10, 2),
        2,
        -math.pi / 2,
        math.pi / 2,
      );

      CadDocumentEntity section(String id, double offset) => CadDocumentEntity(
        id: id,
        kind: CadDocumentEntityKind.section,
        data: {
          'name': id,
          'sceneKind': 'curve',
          'sceneVisible': true,
          'sceneGeometry': {
            'segments': [
              [
                [offset, 0, 0],
                [offset + 5, 0, 0],
              ],
              [
                [offset + 5, 0, 0],
                [offset + 5, 5, 0],
              ],
            ],
          },
          'section': {
            'origin': [offset, 0, 0],
            'normal': [0, 0, 1],
            'planeId': 'xy-plane',
            'segments': [
              [
                [offset, 0, 0],
                [offset + 5, 0, 0],
              ],
              [
                [offset + 5, 0, 0],
                [offset + 5, 5, 0],
              ],
            ],
          },
        },
      );
      await harness.cad.runtime.mutate(
        command: 'test.sections',
        upsert: [section('SectionA', 20), section('SectionB', 40)],
      );

      harness.cad.runtime.select({'SectionA'});
      await controller.createSketchFromSelectedSection();
      final derivedA = controller.activeSketch!;
      harness.cad.runtime.select({'SectionB'});
      await controller.createSketchFromSelectedSection();
      final derivedB = controller.activeSketch!;
      expect({manual.id, derivedA.id, derivedB.id}, hasLength(3));
      expect(api.sketches, hasLength(3));
      final idsBefore = api.sketches.map((sketch) => sketch.id).toSet();
      final membershipsBefore = {
        for (final sketch in api.sketches)
          sketch.id: List<String>.of(sketch.entityIds),
      };
      // Persist an active identity that is not the last-created Sketch. This
      // is the regression case for the old `sketches.last` restoration.
      controller.selectSketch(manual.id);
      await controller.persist();
      final activeMetadata = jsonDecode(
        await File(
          '${harness.directory.path}${Platform.pathSeparator}CAD${Platform.pathSeparator}'
          'SketchHistory${Platform.pathSeparator}active-sketch.json',
        ).readAsString(),
      ) as Map<String, dynamic>;
      expect(activeMetadata['schema'], 'flcad.sketch-active');
      expect(activeMetadata['version'], 1);
      expect(activeMetadata['projectId'], 'g124-multiple-sketch-rehydration');
      expect(activeMetadata['activeSketchId'], manual.id);

      final reopenedKernels = KernelManager()
        ..register(_HealthySurfaceKernel(), makeDefault: true);
      final reopenedCad = DesktopCadController(
        kernels: reopenedKernels,
        projects: ProjectManager.instance,
      );
      final reopenedCommands = DesktopCommandCoordinator(
        cad: reopenedCad,
        projects: ProjectManager.instance,
      );
      final reopened = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: reopenedCommands,
        runtime: reopenedCad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(
            repository: ReferenceRepository(projects: harness.projects),
          ),
        ),
      );
      addTearDown(reopened.dispose);
      addTearDown(reopenedCad.dispose);
      await reopenedCad.runtime.open(
        'g124-multiple-sketch-rehydration',
        harness.directory,
      );
      await reopened.configureProject(
        projectId: 'g124-multiple-sketch-rehydration',
        projectDirectory: harness.directory,
      );
      expect(reopened.sketchApi!.sketches, hasLength(3));
      expect(reopened.sketchApi!.sketches.map((s) => s.id).toSet(), idsBefore);
      expect(reopened.activeSketch!.id, manual.id);
      expect(reopened.sketchApi!.engine.activeSketchId, manual.id);
      expect(reopened.sketchOpenDiagnostic, contains('identidade persistida'));
      for (final sketch in reopened.sketchApi!.sketches) {
        final documentRoot = reopenedCad.runtime.document!.entities[sketch.id];
        expect(documentRoot?.kind, CadDocumentEntityKind.sketch);
        expect(documentRoot?.data['sketch'], isA<Map>());
        expect(
          documentRoot?.data['geometricEntities'],
          membershipsBefore[sketch.id],
        );
        expect(sketch.entityIds, membershipsBefore[sketch.id]);
        await reopened.reopenSketchForEditing(sketch.id);
        expect(reopened.stage, SketchSurfaceStage.sketchActive);
        expect(reopened.sketchApi!.engine.activeSketchId, sketch.id);
        // Entering the editor must target the same root, not merely its
        // previously published scene projection.
        expect(reopened.activeSketch!.id, sketch.id);
      }
      await reopened.reopenSketchForEditing(manual.id);
      final restoredManualLine = reopened.sketchApi!.entity(manualLine.id);
      expect(restoredManualLine, isNotNull);
      expect(reopened.sketchEntities, isNotEmpty);
    },
  );

  test(
    'document Sketch roots are rehydrated when the engine loses the root',
    () async {
      final harness = await _g124Harness('g124-orphan-sketch-root');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final sketch = harness.controller.activeSketch!;
      final line = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(5, 0),
      );
      await harness.controller.reopenSketchForEditing(sketch.id);
      await harness.controller.persist();
      expect(
        harness
            .cad
            .runtime
            .document!
            .entities[sketch.id]
            ?.data['geometricEntities'],
        contains(line.id),
      );

      // Simulate the observed document/engine split without touching a real
      // project: the CAD projection still contains the root and child, while
      // the in-memory Sketch Engine has lost both canonical objects.
      harness.controller.sketchApi!.engine.sketches.remove(sketch.id);
      harness.controller.sketchApi!.engine.entities.remove(line.id);
      harness.controller.sketchApi!.engine.activeSketchId = null;

      await harness.controller.reopenSketchForEditing(sketch.id);
      expect(harness.controller.activeSketch!.id, sketch.id);
      expect(harness.controller.sketchApi!.engine.activeSketchId, sketch.id);
      expect(harness.controller.sketchApi!.entity(line.id), isA<SketchLine>());
      expect(harness.controller.stage, SketchSurfaceStage.sketchActive);
    },
  );

  test(
    'Plane YZ is transferred to Create Section instead of the previous plane',
    () async {
      final harness = await _g124Harness('g124-section-plane-transfer');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      const mesh = KernelMeshHandle(
        persistentId: 'plane-transfer-mesh',
        kernelId: 'test',
        fingerprint: 'plane-transfer',
        vertexCount: 4,
        triangleCount: 4,
        bounds: KernelBounds(-1, -1, -1, 1, 1, 1),
        hasNormals: false,
        metadata: {},
      );
      await harness.cad.runtime.registerImport(
        const ImportedCadDocument(
          id: 'Mesh001',
          projectId: 'g124-section-plane-transfer',
          sourcePath: 'mesh.stl',
          format: CadImportFormat.stl,
          registeredPath: 'CAD/Imports/mesh.stl',
          validation: [],
          mesh: mesh,
        ),
        geometry: const KernelMeshGeometry(
          nodes: [-1, -1, -1, 1, -1, 1, 0, 1, -1, 0, 0, 1],
          triangles: [0, 1, 2, 0, 3, 1, 1, 3, 2, 2, 3, 0],
        ),
      );

      await harness.controller.createWorldReferenceCurve(SketchPlaneType.yz);
      expect(harness.controller.activeSketchPlaneId, endsWith('yz-plane'));
      expect(harness.controller.activeSketchPlane!.normal.x, closeTo(1, 1e-12));
      await harness.controller.createSection();
      final sections = harness.controller.sections.sections;
      expect(sections, hasLength(2));
      final created = sections.last.data['section'] as Map;
      expect(created['planeId'], endsWith('yz-plane'));
      expect(created['normal'], [1.0, 0.0, 0.0]);
    },
  );

  test(
    'dense Section display decimation never joins unrelated segments',
    () async {
      final harness = await _g124Harness('g124-dense-section-display');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      const count = 1001;
      final nodes = <double>[];
      final triangles = <int>[];
      for (var index = 0; index < count; index++) {
        final x = index * .01;
        final base = nodes.length ~/ 3;
        nodes.addAll([x, 0, -1, x + .004, 0, 1, x, .004, -1]);
        triangles.addAll([base, base + 1, base + 2]);
      }
      const mesh = KernelMeshHandle(
        persistentId: 'dense-section-mesh',
        kernelId: 'test',
        fingerprint: 'dense-section',
        vertexCount: count * 3,
        triangleCount: count,
        bounds: KernelBounds(0, 0, -1, 10.1, .004, 1),
        hasNormals: false,
        metadata: {},
      );
      await harness.cad.runtime.registerImport(
        const ImportedCadDocument(
          id: 'Mesh001',
          projectId: 'g124-dense-section-display',
          sourcePath: 'dense.stl',
          format: CadImportFormat.stl,
          registeredPath: 'CAD/Imports/dense.stl',
          validation: [],
          mesh: mesh,
        ),
        geometry: KernelMeshGeometry(nodes: nodes, triangles: triangles),
      );
      final section = await harness.controller.sections.create(
        planeId:
            '${WorldCoordinateSystem.prefix('g124-dense-section-display')}xy-plane',
        origin: Vector3.zero,
        normal: const Vector3(0, 0, 1),
      );
      final raw = (section.data['section'] as Map)['segments'] as List;
      final display =
          (section.data['sceneGeometry'] as Map)['segments'] as List;
      expect(raw.length, greaterThan(1000));
      final source = raw.map(jsonEncode).toSet();
      expect(
        display.every((segment) => source.contains(jsonEncode(segment))),
        isTrue,
      );
      final conversionTimer = Stopwatch()..start();
      await harness.controller.createSketchFromSelectedSection();
      conversionTimer.stop();
      expect(harness.controller.activeSketch, isNotNull);
      expect(harness.controller.sketchEntities, isNotEmpty);
      expect(conversionTimer.elapsed, lessThan(const Duration(seconds: 10)));
    },
  );

  test('legacy Sketch projects use a deterministic active-root fallback', () async {
    final directory = await Directory.systemTemp.createTemp(
      'g124-legacy-active-sketch-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final repository = SketchRepository(directory);
    final engine = SketchEngine(repository: repository);
    engine.projectId = 'legacy-project';
    final first = engine.createSketch('first');
    engine.createSketch('second');
    await engine.persist();
    await File(
      '${directory.path}${Platform.pathSeparator}CAD${Platform.pathSeparator}'
      'SketchHistory${Platform.pathSeparator}active-sketch.json',
    ).delete();

    final restored = SketchEngine(repository: repository)
      ..projectId = 'legacy-project';
    await restored.load();
    final expected = [first, ...engine.sketches.values.where((s) => s != first)]
      ..sort((a, b) {
        final timestamp = a.timestamp.compareTo(b.timestamp);
        return timestamp != 0 ? timestamp : a.id.compareTo(b.id);
      });
    expect(restored.activeSketchId, expected.first.id);
    expect(restored.activeSketchRestoreDiagnostic, contains('legado'));

    engine.closeSketch();
    await engine.persist();
    final restoredWithoutActive = SketchEngine(repository: repository)
      ..projectId = 'legacy-project';
    await restoredWithoutActive.load();
    expect(restoredWithoutActive.activeSketchId, isNull);
    expect(
      restoredWithoutActive.activeSketchRestoreDiagnostic,
      contains('sem Sketch ativo'),
    );

    await File(
      '${directory.path}${Platform.pathSeparator}CAD${Platform.pathSeparator}'
      'SketchHistory${Platform.pathSeparator}active-sketch.json',
    ).writeAsString(
      '{"schema":"flcad.sketch-active","version":1,'
      '"activeSketchId":"sketch:missing"}',
    );
    final restoredWithMissingId = SketchEngine(repository: repository)
      ..projectId = 'legacy-project';
    await restoredWithMissingId.load();
    expect(restoredWithMissingId.activeSketchId, expected.first.id);
    await File(
      '${directory.path}${Platform.pathSeparator}CAD${Platform.pathSeparator}'
      'SketchHistory${Platform.pathSeparator}active-sketch.json',
    ).writeAsString(
      '{"schema":"flcad.sketch-active","version":1,'
      '"projectId":"other-project",'
      '"activeSketchId":"${expected.first.id}"}',
    );
    final restoredWithOtherProject = SketchEngine(repository: repository)
      ..projectId = 'legacy-project';
    await restoredWithOtherProject.load();
    expect(restoredWithOtherProject.activeSketchId, expected.first.id);
    expect(
      restoredWithOtherProject.activeSketchRestoreDiagnostic,
      contains('inv'),
    );

    await File(
      '${directory.path}${Platform.pathSeparator}CAD${Platform.pathSeparator}'
      'SketchHistory${Platform.pathSeparator}active-sketch.json',
    ).writeAsString(
      '{"schema":"flcad.sketch-active","version":99,'
      '"activeSketchId":"${expected.first.id}"}',
    );
    final restoredWithUnknownVersion = SketchEngine(repository: repository)
      ..projectId = 'legacy-project';
    await restoredWithUnknownVersion.load();
    expect(restoredWithUnknownVersion.activeSketchId, expected.first.id);
    expect(
      restoredWithUnknownVersion.activeSketchRestoreDiagnostic,
      contains('inv'),
    );

    final failureDirectory = await Directory.systemTemp.createTemp(
      'g124-active-sketch-write-failure-',
    );
    addTearDown(() => failureDirectory.delete(recursive: true));
    final failureRepository = SketchRepository(failureDirectory);
    final failureEngine = SketchEngine(repository: failureRepository);
    failureEngine.createSketch('survives metadata failure');
    await failureEngine.persist();
    final failureMetadata = File(
      '${failureDirectory.path}${Platform.pathSeparator}CAD${Platform.pathSeparator}'
      'SketchHistory${Platform.pathSeparator}active-sketch.json',
    );
    await failureMetadata.delete();
    await Directory(failureMetadata.path).create();
    await expectLater(
      failureEngine.persist(),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      (await Directory(
        '${failureDirectory.path}${Platform.pathSeparator}CAD${Platform.pathSeparator}'
        'Sketch',
      ).list().toList()),
      isNotEmpty,
    );
    expect(
      restoredWithMissingId.activeSketchRestoreDiagnostic,
      contains('indisponível'),
    );
  });

  test(
    'joint acceptance applies a validated mixed plan atomically and supports undo redo',
    () async {
      final harness = await _g124Harness('g124-joint-acceptance-apply');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final line = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final arc = harness.controller.sketchApi!.builders.arc.build(
        const SketchVector(15, 0),
        5,
        math.pi,
        math.pi * 2,
      );
      final spline = harness.controller.sketchApi!.builders.spline.build([
        const SketchVector(20, 0),
        const SketchVector(25, 2),
        const SketchVector(30, 0),
      ]);
      final suggestions = [
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.line,
          entityIds: [line.id],
          confidence: 1,
        ),
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.arc,
          entityIds: [arc.id],
          confidence: 1,
          center: const SketchVector(15, 0),
          radius: 5,
          startAngle: math.pi,
          endAngle: math.pi * 2,
        ),
        SketchReconstructionSuggestion(
          // Spline sources are represented by the existing line recognition
          // kind, but the immutable plan carries their samples and promotes
          // them back to a SketchSpline.
          kind: SketchReconstructionKind.line,
          entityIds: [spline.id],
          confidence: 1,
        ),
      ];
      for (final suggestion in suggestions) {
        harness.controller.selectSketchReconstructionSuggestion(
          suggestion,
          additive: true,
        );
      }
      harness.controller.previewSketchReconstructionAcceptance();
      final token = harness.controller.sketchReconstructionJointPreviewToken;
      expect(token, isNotNull);
      final historyBefore = harness.controller.commands.manager.history.length;

      final firstConfirmation = harness.controller
          .confirmSketchReconstructionJointAcceptance(token!);
      final duplicateConfirmation = harness.controller
          .confirmSketchReconstructionJointAcceptance(token);
      final created = await firstConfirmation;
      expect(await duplicateConfirmation, isNull);
      expect(created, hasLength(3));
      expect(
        harness.controller.commands.manager.history.length,
        historyBefore + 1,
      );
      expect(harness.controller.sketchReconstructionJointPreviewToken, isNull);
      expect(
        harness.controller.canConfirmSketchReconstructionJointAcceptance,
        isFalse,
      );
      expect(
        harness.controller.sketchReconstructionMessage,
        contains('conclu'),
      );
      final createdEntities = created!
          .map((id) => harness.controller.sketchApi!.entity(id))
          .toList();
      expect(createdEntities.whereType<SketchLine>(), hasLength(1));
      expect(createdEntities.whereType<SketchArc>(), hasLength(1));
      expect(createdEntities.whereType<SketchSpline>(), hasLength(1));
      expect(line.visible, isFalse);
      expect(arc.visible, isFalse);
      expect(spline.visible, isFalse);
      expect(harness.controller.selectedSketchEntityIds, created.toSet());
      expect(
        harness.controller.selectedSketchReconstructionSuggestions,
        isEmpty,
      );

      final reused = await harness.controller
          .confirmSketchReconstructionJointAcceptance(token);
      expect(reused, isNull);
      expect(
        harness.controller.sketchReconstructionMessage,
        contains('expirou'),
      );

      await harness.controller.undo();
      for (final id in created) {
        expect(harness.controller.sketchApi!.entity(id), isNull);
      }
      expect(harness.controller.sketchApi!.entity(line.id)!.visible, isTrue);
      expect(harness.controller.sketchApi!.entity(arc.id)!.visible, isTrue);
      expect(harness.controller.sketchApi!.entity(spline.id)!.visible, isTrue);

      await harness.controller.redo();
      final redoneEntities = created
          .map((id) => harness.controller.sketchApi!.entity(id))
          .toList();
      expect(redoneEntities.whereType<SketchLine>(), hasLength(1));
      expect(redoneEntities.whereType<SketchArc>(), hasLength(1));
      expect(redoneEntities.whereType<SketchSpline>(), hasLength(1));
      expect(harness.controller.sketchApi!.entity(line.id)!.visible, isFalse);
      expect(harness.controller.sketchApi!.entity(arc.id)!.visible, isFalse);
      expect(harness.controller.sketchApi!.entity(spline.id)!.visible, isFalse);
      expect(
        harness.controller.selectedSketchReconstructionSuggestions,
        isEmpty,
      );

      // The confirmed geometry and source visibility are persisted as
      // ordinary Sketch entity state; the transient plan/token must not be.
      await harness.controller.persist();
      final reopenedKernels = KernelManager()
        ..register(_HealthySurfaceKernel(), makeDefault: true);
      final reopenedCad = DesktopCadController(
        kernels: reopenedKernels,
        projects: ProjectManager.instance,
      );
      final reopenedCommands = DesktopCommandCoordinator(
        cad: reopenedCad,
        projects: ProjectManager.instance,
      );
      final reopened = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: reopenedCommands,
        runtime: reopenedCad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(
            repository: ReferenceRepository(projects: harness.projects),
          ),
        ),
      );
      addTearDown(reopened.dispose);
      addTearDown(reopenedCad.dispose);
      await reopenedCad.runtime.open(
        'g124-joint-acceptance-apply',
        harness.directory,
      );
      await reopened.configureProject(
        projectId: 'g124-joint-acceptance-apply',
        projectDirectory: harness.directory,
      );
      await reopened.reopenSketchForEditing(
        harness.controller.activeSketch!.id,
      );
      for (final id in created) {
        final restored = reopened.sketchApi!.entity(id);
        expect(restored, isNotNull);
        expect(restored!.visible, isTrue);
        expect(restored.metadata['reconstructionJoint'], isTrue);
      }
      for (final id in [line.id, arc.id, spline.id]) {
        expect(reopened.sketchApi!.entity(id)!.visible, isFalse);
      }
      expect(reopened.sketchReconstructionJointPreviewToken, isNull);
    },
  );

  test(
    'joint acceptance rejects an obsolete plan without creating or hiding sources',
    () async {
      final harness = await _g124Harness('g124-joint-acceptance-stale');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final first = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final second = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(10, 0),
        const SketchVector(20, 0),
      );
      final suggestions = [
        for (final entity in [first, second])
          SketchReconstructionSuggestion(
            kind: SketchReconstructionKind.line,
            entityIds: [entity.id],
            confidence: 1,
          ),
      ];
      for (final suggestion in suggestions) {
        harness.controller.selectSketchReconstructionSuggestion(
          suggestion,
          additive: true,
        );
      }
      harness.controller.previewSketchReconstructionAcceptance();
      final token = harness.controller.sketchReconstructionJointPreviewToken!;
      first.parameters['start'] = const SketchVector(0, 1).toJson();
      first.version++;

      final created = await harness.controller
          .confirmSketchReconstructionJointAcceptance(token);
      expect(created, isNull);
      expect(first.visible, isTrue);
      expect(second.visible, isTrue);
      expect(
        harness.controller.sketchApi!.sketches
            .expand((sketch) => sketch.entityIds)
            .where((id) => id != first.id && id != second.id),
        isEmpty,
      );
    },
  );

  test(
    'joint acceptance rolls back a failure after an earlier proposal was prepared',
    () async {
      final harness = await _g124Harness('g124-joint-acceptance-rollback');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final first = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final second = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(10, 0),
        const SketchVector(20, 0),
      );
      final suggestions = [
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.line,
          entityIds: [first.id],
          confidence: 1,
        ),
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.parallel,
          entityIds: [second.id],
          confidence: 1,
        ),
      ];
      for (final suggestion in suggestions) {
        harness.controller.selectSketchReconstructionSuggestion(
          suggestion,
          additive: true,
        );
      }
      harness.controller.previewSketchReconstructionAcceptance();
      final token = harness.controller.sketchReconstructionJointPreviewToken!;
      final beforeIds = harness.controller.activeSketch!.entityIds.toSet();
      final created = await harness.controller
          .confirmSketchReconstructionJointAcceptance(token);

      expect(created, isNull);
      expect(harness.controller.activeSketch!.entityIds.toSet(), beforeIds);
      expect(first.visible, isTrue);
      expect(second.visible, isTrue);
      expect(harness.controller.sketchReconstructionJointPreviewToken, isNull);
    },
  );

  test(
    'C0 repair preview lists alternatives without mutating Sketch or history',
    () async {
      final harness = await _g124Harness('g124-continuity-repair-preview');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final api = harness.controller.sketchApi!;
      final first = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final second = api.builders.line.build(
        const SketchVector(1.05, 0),
        const SketchVector(2, 0),
      );
      final before = [first.toJson(), second.toJson()];

      harness.controller.selectedSketchEntityIds
        ..clear()
        ..addAll({first.id, second.id});
      harness.controller.selectSketchContinuityJoinFromSketchSelection();
      expect(harness.controller.selectedSketchContinuityJoin, isNotNull);
      harness.controller.previewSketchContinuityRepair();

      final preview = harness.controller.sketchContinuityRepairPreview;
      expect(preview, isNotNull);
      expect(preview!.alternatives, isNotEmpty);
      expect(harness.controller.canConfirmSketchContinuityRepair, isTrue);
      expect(harness.controller.sketchContinuityRepairPreviewToken, isNotNull);
      expect(
        harness.cad.runtime.scene.find(
          '${sketchContinuityRepairPreviewPrefix}original',
        ),
        isNotNull,
      );
      expect(
        harness.cad.runtime.scene.find(
          '${sketchContinuityRepairPreviewPrefix}proposed',
        ),
        isNotNull,
      );
      expect([first.toJson(), second.toJson()], before);

      harness.controller.selectSketchContinuityRepairAlternative(1);
      expect(harness.controller.sketchContinuityRepairPreview, isNotNull);
      harness.controller.cancelSketchContinuityRepairPreview();
      expect(harness.controller.sketchContinuityRepairPreview, isNull);
      expect(harness.controller.sketchContinuityRepairPreviewToken, isNull);
      expect(
        harness.cad.runtime.scene.find(
          '${sketchContinuityRepairPreviewPrefix}original',
        ),
        isNull,
      );
      expect([first.toJson(), second.toJson()], before);
    },
  );

  test(
    'G1 line-arc preview shows both metrics and transient proposed geometry',
    () async {
      final harness = await _g124Harness('g124-g1-line-arc-preview');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final api = harness.controller.sketchApi!;
      final line = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final arc = api.builders.arc.build(
        const SketchVector(1.05, 1),
        1,
        -math.pi / 2,
        0,
      );
      final before = [line.toJson(), arc.toJson()];
      harness.controller.selectedSketchEntityIds
        ..clear()
        ..addAll({line.id, arc.id});
      harness.controller.selectSketchContinuityJoinFromSketchSelection();
      harness.controller.previewSketchContinuityRepair();

      final preview = harness.controller.sketchG1ContinuityRepairPreview;
      expect(preview, isNotNull);
      expect(
        preview!.alternatives.where((alternative) => alternative.isViable),
        isNotEmpty,
      );
      expect(preview.currentGapMillimeters, closeTo(.05, 1e-9));
      expect(preview.currentG1ResidualRadians, isNotNull);
      final viableAlternatives = preview.alternatives
          .where((alternative) => alternative.isViable)
          .toList();
      final firstAlternative = viableAlternatives.first;
      expect(firstAlternative.beforeGapMillimeters, closeTo(.05, 1e-9));
      expect(firstAlternative.afterGapMillimeters, lessThan(1e-8));
      expect(firstAlternative.beforeG1ResidualRadians, isNotNull);
      expect(firstAlternative.afterG1ResidualRadians, isNotNull);
      expect(firstAlternative.maxDisplacementMillimeters, isNonNegative);
      expect(firstAlternative.affectedEntityIds, isNotEmpty);
      expect(
        harness.controller.sketchG1ContinuityRepairPreviewToken,
        isNotNull,
      );
      expect(
        harness.cad.runtime.scene.find(
          '${sketchG1ContinuityRepairPreviewPrefix}original',
        ),
        isNotNull,
      );
      expect(
        harness.cad.runtime.scene.find(
          '${sketchG1ContinuityRepairPreviewPrefix}proposed',
        ),
        isNotNull,
      );
      expect([line.toJson(), arc.toJson()], before);
      expect(harness.controller.canConfirmSketchContinuityRepair, isTrue);

      final viableIndex = preview.alternatives.indexWhere(
        (alternative) => alternative.isViable,
      );
      harness.controller.selectSketchG1ContinuityRepairAlternative(viableIndex);
      expect(harness.controller.selectedSketchG1RepairAlternative, isNotNull);
      if (viableAlternatives.length > 1) {
        final secondIndex = preview.alternatives.indexWhere(
          (alternative) => alternative.isViable && alternative != firstAlternative,
        );
        expect(secondIndex, greaterThanOrEqualTo(0));
        harness.controller.selectSketchG1ContinuityRepairAlternative(secondIndex);
        expect(
          harness.controller.selectedSketchG1RepairAlternative,
          isNot(same(firstAlternative)),
        );
        expect(
          harness.cad.runtime.scene.find(
            '${sketchG1ContinuityRepairPreviewPrefix}proposed',
          ),
          isNotNull,
        );
      }
      expect([line.toJson(), arc.toJson()], before);
      await harness.controller.updateSketchEntityParameters(line.id, {
        'length': 1.1,
      });
      expect(harness.controller.sketchG1ContinuityRepairPreview, isNull);
      expect(
        harness.cad.runtime.scene.find(
          '${sketchG1ContinuityRepairPreviewPrefix}proposed',
        ),
        isNull,
      );
      harness.controller.cancelSketchContinuityRepairPreview();
      expect(harness.controller.sketchG1ContinuityRepairPreviewToken, isNull);
      expect(
        harness.cad.runtime.scene.find(
          '${sketchG1ContinuityRepairPreviewPrefix}proposed',
        ),
        isNull,
      );
      expect(
        SketchVector.fromJson(line.parameters['end']).x,
        closeTo(1.1, 1e-9),
      );
      expect(arc.toJson(), before[1]);
    },
  );

  test(
    'G1 confirmation rolls back when a new external connection would break',
    () async {
      final harness = await _g124Harness('g124-g1-external-rollback');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final api = harness.controller.sketchApi!;
      final line = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final arc = api.builders.arc.build(
        const SketchVector(1.05, 1),
        1,
        -math.pi / 2,
        0,
      );
      harness.controller.selectedSketchEntityIds
        ..clear()
        ..addAll({line.id, arc.id});
      harness.controller.selectSketchContinuityJoinFromSketchSelection();
      harness.controller.previewSketchContinuityRepair();
      final preview = harness.controller.sketchG1ContinuityRepairPreview!;
      final lineAlternativeIndex = preview.alternatives.indexWhere(
        (alternative) =>
            alternative.isViable &&
            alternative.updates.any((update) => update.entityId == line.id),
      );
      expect(lineAlternativeIndex, greaterThanOrEqualTo(0));
      harness.controller.selectSketchG1ContinuityRepairAlternative(
        lineAlternativeIndex,
      );
      expect(
        harness.controller.selectedSketchG1RepairAlternative!.updates
            .any((update) => update.entityId == arc.id),
        isTrue,
      );
      final beforeLine = Map<String, dynamic>.from(line.parameters);
      final beforeArc = Map<String, dynamic>.from(arc.parameters);
      final external = api.builders.line.build(
        const SketchVector(1, 0),
        const SketchVector(1, -1),
      );
      expect(
        harness.controller.sketchContinuityAnalysis.joins.any(
          (join) => {
            join.first.entityId,
            join.second.entityId,
          }.containsAll({external.id, line.id}) && join.measuredC0,
        ),
        isTrue,
      );
      final historyBefore = api.engine.history.entries.length;
      final commandHistory = harness.controller.commands.manager.history.length;
      await expectLater(
        harness.controller.confirmSketchG1ContinuityRepairPreview(
          token: harness.controller.sketchG1ContinuityRepairPreviewToken!,
        ),
        throwsStateError,
      );
      expect(api.entity(line.id)!.toJson()['parameters'], beforeLine);
      expect(api.entity(arc.id)!.toJson()['parameters'], beforeArc);
      expect(api.entity(external.id), isNotNull);
      expect(api.engine.history.entries.length, historyBefore);
      expect(harness.controller.commands.manager.history.length, commandHistory);
      expect(harness.controller.sketchG1ContinuityRepairPreview, isNull);
    },
  );

  test(
    'G1 line-arc confirmation applies one transaction and supports undo redo',
    () async {
      final harness = await _g124Harness('g124-g1-line-arc-apply');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final api = harness.controller.sketchApi!;
      final line = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final arc = api.builders.arc.build(
        const SketchVector(1.05, 1),
        1,
        -math.pi / 2,
        0,
      );
      final beforeLine = Map<String, dynamic>.from(line.parameters);
      final beforeArc = Map<String, dynamic>.from(arc.parameters);
      harness.controller.selectedSketchEntityIds
        ..clear()
        ..addAll({line.id, arc.id});
      harness.controller.selectSketchContinuityJoinFromSketchSelection();
      harness.controller.previewSketchContinuityRepair();
      final preview = harness.controller.sketchG1ContinuityRepairPreview!;
      final token = harness.controller.sketchG1ContinuityRepairPreviewToken!;
      final commandHistory = harness.controller.commands.manager.history.length;
      final historyBefore = api.engine.history.entries.length;
      await expectLater(
        harness.controller.confirmSketchG1ContinuityRepairPreview(
          token: '$token-stale',
        ),
        throwsStateError,
      );
      expect(api.entity(line.id)!.toJson()['parameters'], beforeLine);
      expect(api.entity(arc.id)!.toJson()['parameters'], beforeArc);
      expect(harness.controller.sketchG1ContinuityRepairPreview, isNotNull);
      final affected = await harness.controller
        .confirmSketchG1ContinuityRepairPreview(token: token);

      expect(affected, isNotEmpty);
      expect(
        harness.controller.commands.manager.history.length,
        commandHistory + 1,
      );
      expect(api.engine.history.entries.length, historyBefore + 1);
      expect(harness.controller.sketchG1ContinuityRepairPreview, isNull);
      final repairedJoin = harness.controller.sketchContinuityAnalysis.joins
          .where(
            (join) => {
              join.first.entityId,
              join.second.entityId,
            }.containsAll({line.id, arc.id}),
          )
          .firstOrNull;
      expect(repairedJoin, isNotNull);
      expect(repairedJoin!.measuredC0, isTrue);
      expect(repairedJoin.measuredG1, isTrue);
      expect(
        repairedJoin.gapMillimeters,
        lessThanOrEqualTo(preview.connectionToleranceMillimeters + 1e-9),
      );
      expect(
        repairedJoin.tangentAngleRadians,
        lessThanOrEqualTo(preview.tangencyToleranceRadians + 1e-9),
      );

      await harness.controller.undo();
      expect(api.entity(line.id)!.toJson()['parameters'], beforeLine);
      expect(api.entity(arc.id)!.toJson()['parameters'], beforeArc);
      await harness.controller.redo();
      final redoneJoin = harness.controller.sketchContinuityAnalysis.joins
          .where(
            (join) => {
              join.first.entityId,
              join.second.entityId,
            }.containsAll({line.id, arc.id}),
          )
          .firstOrNull;
      expect(redoneJoin?.measuredG1, isTrue);
      await expectLater(
        harness.controller.confirmSketchG1ContinuityRepairPreview(token: token),
        throwsStateError,
      );
    },
  );

  test(
    'G1 arc-arc preview supports both contact-preserving alternatives',
    () async {
      final harness = await _g124Harness('g124-g1-arc-arc-preview');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final api = harness.controller.sketchApi!;
      final first = api.builders.arc.build(
        const SketchVector(0, 0),
        2,
        0,
        math.pi / 2,
      );
      final second = api.builders.arc.build(
        SketchVector(-math.sqrt(2), 2 + math.sqrt(2)),
        2,
        -math.pi / 4,
        math.pi / 4,
      );
      final before = [first.toJson(), second.toJson()];
      harness.controller.selectedSketchEntityIds
        ..clear()
        ..addAll({first.id, second.id});
      harness.controller.selectSketchContinuityJoinFromSketchSelection();
      harness.controller.previewSketchContinuityRepair();

      final preview = harness.controller.sketchG1ContinuityRepairPreview;
      expect(preview, isNotNull);
      final viable = preview!.alternatives
          .where((alternative) => alternative.isViable)
          .toList();
      expect(viable.length, greaterThanOrEqualTo(2));
      expect(
        viable.map((alternative) => alternative.kind).toSet(),
        hasLength(2),
      );
      expect(
        harness.cad.runtime.scene.find(
          '${sketchG1ContinuityRepairPreviewPrefix}proposed',
        ),
        isNotNull,
      );
      expect([first.toJson(), second.toJson()], before);
      expect(harness.controller.canConfirmSketchContinuityRepair, isFalse);
      harness.controller.cancelSketchContinuityRepairPreview();
      expect([first.toJson(), second.toJson()], before);
      expect(harness.controller.sketchG1ContinuityRepairPreview, isNull);
    },
  );

  test('G1 arc-arc confirmation preserves both arc identities', () async {
    final harness = await _g124Harness('g124-g1-arc-arc-apply');
    addTearDown(() => harness.directory.delete(recursive: true));
    addTearDown(harness.controller.dispose);
    addTearDown(harness.cad.dispose);
    final api = harness.controller.sketchApi!;
    final first = api.builders.arc.build(
      const SketchVector(0, 0),
      2,
      0,
      math.pi / 2,
    );
    final second = api.builders.arc.build(
      SketchVector(-math.sqrt(2), 2 + math.sqrt(2)),
      2,
      -math.pi / 4,
      math.pi / 4,
    );
    final firstId = first.id;
    final secondId = second.id;
    harness.controller.selectedSketchEntityIds
      ..clear()
      ..addAll({firstId, secondId});
    harness.controller.selectSketchContinuityJoinFromSketchSelection();
    harness.controller.previewSketchContinuityRepair();
    expect(harness.controller.canConfirmSketchG1ContinuityRepair, isTrue);
    final token = harness.controller.sketchG1ContinuityRepairPreviewToken!;
    final affected = await harness.controller
        .confirmSketchG1ContinuityRepairPreview(token: token);
    expect(affected, anyOf(contains(firstId), contains(secondId)));
    expect(api.entity(firstId), isNotNull);
    expect(api.entity(secondId), isNotNull);
    final join = harness.controller.sketchContinuityAnalysis.joins
        .where(
          (candidate) => {
            candidate.first.entityId,
            candidate.second.entityId,
          }.containsAll({firstId, secondId}),
        )
        .firstOrNull;
    expect(join?.measuredG1, isTrue);
  });

  test('G1 line-arc confirmation persists through Save/Open', () async {
    final harness = await _g124Harness('g124-g1-line-arc-save');
    addTearDown(() => harness.directory.delete(recursive: true));
    addTearDown(harness.controller.dispose);
    addTearDown(harness.cad.dispose);
    final api = harness.controller.sketchApi!;
    final line = api.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
    );
    final arc = api.builders.arc.build(
      const SketchVector(1.05, 1),
      1,
      -math.pi / 2,
      0,
    );
    final sketchId = harness.controller.activeSketch!.id;
    harness.controller.selectedSketchEntityIds
      ..clear()
      ..addAll({line.id, arc.id});
    harness.controller.selectSketchContinuityJoinFromSketchSelection();
    harness.controller.previewSketchContinuityRepair();
    await harness.controller.confirmSketchG1ContinuityRepairPreview(
      token: harness.controller.sketchG1ContinuityRepairPreviewToken!,
    );
    await harness.controller.persist();

    final reopenedKernels = KernelManager()
      ..register(_HealthySurfaceKernel(), makeDefault: true);
    final reopenedCad = DesktopCadController(
      kernels: reopenedKernels,
      projects: ProjectManager.instance,
    );
    final reopenedCommands = DesktopCommandCoordinator(
      cad: reopenedCad,
      projects: ProjectManager.instance,
    );
    final reopened = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: reopenedCommands,
      runtime: reopenedCad.runtime,
      referenceApi: ReferenceApi(
        engine: ReferenceEngine(
          repository: ReferenceRepository(projects: harness.projects),
        ),
      ),
    );
    addTearDown(reopened.dispose);
    addTearDown(reopenedCad.dispose);
    await reopenedCad.runtime.open('g124-g1-line-arc-save', harness.directory);
    await reopened.configureProject(
      projectId: 'g124-g1-line-arc-save',
      projectDirectory: harness.directory,
    );
    await reopened.reopenSketchForEditing(sketchId);
    final restoredJoin = reopened.sketchContinuityAnalysis.joins
        .where(
          (join) => {
            join.first.entityId,
            join.second.entityId,
          }.containsAll({line.id, arc.id}),
        )
        .firstOrNull;
    expect(restoredJoin?.measuredC0, isTrue);
    expect(restoredJoin?.measuredG1, isTrue);
    expect(reopened.sketchG1ContinuityRepairPreview, isNull);
  });

  test('G1 spline repair is blocked with an explicit diagnostic', () async {
    final harness = await _g124Harness('g124-g1-spline-blocked');
    addTearDown(() => harness.directory.delete(recursive: true));
    addTearDown(harness.controller.dispose);
    addTearDown(harness.cad.dispose);
    final api = harness.controller.sketchApi!;
    final line = api.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
    );
    final spline = api.builders.spline.build([
      const SketchVector(1, 0),
      const SketchVector(2, .2),
    ]);
    harness.controller.selectedSketchEntityIds
      ..clear()
      ..addAll({line.id, spline.id});
    harness.controller.selectSketchContinuityJoinFromSketchSelection();
    harness.controller.previewSketchContinuityRepair();

    final preview = harness.controller.sketchG1ContinuityRepairPreview;
    expect(preview, isNotNull);
    expect(preview!.alternatives, isEmpty);
    expect(preview.status, SketchContinuityRepairStatus.impossible);
    expect(harness.controller.canConfirmSketchG1ContinuityRepair, isFalse);
    await expectLater(
      harness.controller.confirmSketchG1ContinuityRepairPreview(
        token: harness.controller.sketchG1ContinuityRepairPreviewToken!,
      ),
      throwsStateError,
    );
    expect(preview.diagnostics.join(' '), contains('Spline'));
    expect(
      harness.cad.runtime.scene.find(
        '${sketchG1ContinuityRepairPreviewPrefix}proposed',
      ),
      isNull,
    );
    harness.controller.cancelSketchContinuityRepairPreview();
  });

  test(
    'C0 panel data hides healthy joins and keeps friendly entity labels',
    () async {
      final harness = await _g124Harness('g124-continuity-panel-filter');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final api = harness.controller.sketchApi!;
      final first = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final coincident = api.builders.line.build(
        const SketchVector(1, 0),
        const SketchVector(2, 0),
      );
      final gapped = api.builders.line.build(
        const SketchVector(2.2, 0),
        const SketchVector(3, 0),
      );

      final all = harness.controller.sketchContinuityRepairAllJoins;
      final attention = harness.controller.sketchContinuityRepairAttentionJoins;
      expect(all, isNotEmpty);
      expect(attention, isNotEmpty);
      expect(
        attention.every((join) => join.hasProblem),
        isTrue,
      );
      expect(
        all.where((join) => {
          join.first.entityId,
          join.second.entityId,
        }.containsAll({first.id, coincident.id})),
        isNotEmpty,
      );
      expect(
        attention.where((join) => {
          join.first.entityId,
          join.second.entityId,
        }.containsAll({first.id, coincident.id})),
        isEmpty,
      );
      expect(
        harness.controller.sketchContinuityEntityDisplayLabel(first.id),
        startsWith('Linha '),
      );
      expect(
        harness.controller.sketchContinuityEntityDisplayLabel(gapped.id),
        startsWith('Linha '),
      );
    },
  );

  test(
    'C0 repair preview invalidates when a source geometry changes',
    () async {
      final harness = await _g124Harness('g124-continuity-repair-stale');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final api = harness.controller.sketchApi!;
      final first = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final second = api.builders.line.build(
        const SketchVector(1.05, 0),
        const SketchVector(2, 0),
      );
      final join = harness.controller.sketchContinuityRepairJoins.singleWhere(
        (candidate) => {
          candidate.first.entityId,
          candidate.second.entityId,
        }.containsAll({first.id, second.id}),
      );
      harness.controller.selectSketchContinuityJoin(join);
      harness.controller.previewSketchContinuityRepair();
      expect(harness.controller.sketchContinuityRepairPreview, isNotNull);

      await harness.controller.updateSketchEntityParameters(first.id, {
        'length': 1.2,
      });

      expect(harness.controller.sketchContinuityRepairPreview, isNull);
      expect(harness.controller.sketchContinuityRepairPreviewToken, isNull);
      expect(
        harness.cad.runtime.scene.find(
          '${sketchContinuityRepairPreviewPrefix}proposed',
        ),
        isNull,
      );
    },
  );

  test('C0 repair keeps confirmation disabled for an impossible gap', () async {
    final harness = await _g124Harness('g124-continuity-repair-blocked');
    addTearDown(() => harness.directory.delete(recursive: true));
    addTearDown(harness.controller.dispose);
    addTearDown(harness.cad.dispose);
    final api = harness.controller.sketchApi!;
    final first = api.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
    );
    final second = api.builders.line.build(
      const SketchVector(1.2, 0),
      const SketchVector(2.2, 0),
    );
    harness.controller.selectedSketchEntityIds
      ..clear()
      ..addAll({first.id, second.id});
    harness.controller.selectSketchContinuityJoinFromSketchSelection();
    harness.controller.previewSketchContinuityRepair();

    expect(
      harness.controller.sketchContinuityRepairPreview?.status,
      SketchContinuityRepairStatus.impossible,
    );
    expect(harness.controller.canConfirmSketchContinuityRepair, isFalse);
  });

  test(
    'C0 repair applies one exact line-line transaction and supports undo redo',
    () async {
      final harness = await _g124Harness('g124-continuity-repair-apply');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final api = harness.controller.sketchApi!;
      final first = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final second = api.builders.line.build(
        const SketchVector(1.05, 0),
        const SketchVector(2, 0),
      );
      harness.controller.selectedSketchEntityIds
        ..clear()
        ..addAll({first.id, second.id});
      harness.controller.selectSketchContinuityJoinFromSketchSelection();
      harness.controller.previewSketchContinuityRepair();
      final token = harness.controller.sketchContinuityRepairPreviewToken!;
      final commandHistory = harness.controller.commands.manager.history.length;
      final engineHistory = api.engine.history.entries.length;

      final affected = await harness.controller
          .confirmSketchContinuityRepairPreview(token: token);

      expect(affected, hasLength(1));
      expect({first.id, second.id}, contains(affected.single));
      final appliedFirstEnd =
          (api.entity(first.id) as SketchLine).parameters['end'];
      final appliedSecondStart =
          (api.entity(second.id) as SketchLine).parameters['start'];
      expect(appliedFirstEnd, appliedSecondStart);
      expect((appliedFirstEnd as List).first, closeTo(1, .051));
      expect(harness.controller.sketchContinuityRepairPreview, isNull);
      expect(harness.controller.sketchContinuityRepairPreviewToken, isNull);
      expect(
        harness.controller.commands.manager.history.length,
        commandHistory + 1,
      );
      expect(api.engine.history.entries.length, engineHistory + 1);

      await harness.controller.undo();
      expect((api.entity(first.id) as SketchLine).parameters['end'], const [
        1.0,
        0.0,
        0.0,
      ]);
      expect((api.entity(second.id) as SketchLine).parameters['start'], const [
        1.05,
        0.0,
        0.0,
      ]);
      await harness.controller.redo();
      expect(
        (api.entity(first.id) as SketchLine).parameters['end'],
        appliedFirstEnd,
      );
      expect(
        (api.entity(second.id) as SketchLine).parameters['start'],
        appliedSecondStart,
      );
      await expectLater(
        harness.controller.confirmSketchContinuityRepairPreview(token: token),
        throwsStateError,
      );
    },
  );

  test(
    'C0 repair rejects an obsolete token without mutating the Sketch',
    () async {
      final harness = await _g124Harness('g124-continuity-repair-token');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final api = harness.controller.sketchApi!;
      final first = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final second = api.builders.line.build(
        const SketchVector(1.05, 0),
        const SketchVector(2, 0),
      );
      harness.controller.selectedSketchEntityIds
        ..clear()
        ..addAll({first.id, second.id});
      harness.controller.selectSketchContinuityJoinFromSketchSelection();
      harness.controller.previewSketchContinuityRepair();
      final token = harness.controller.sketchContinuityRepairPreviewToken!;
      final beforeFirst = first.toJson();
      final beforeSecond = second.toJson();
      final commandHistory = harness.controller.commands.manager.history.length;
      final canUndo = harness.controller.commands.manager.canUndo;

      await expectLater(
        harness.controller.confirmSketchContinuityRepairPreview(
          token: '$token-stale',
        ),
        throwsStateError,
      );
      expect(first.toJson(), beforeFirst);
      expect(second.toJson(), beforeSecond);
      expect(
        harness.controller.commands.manager.history.length,
        commandHistory,
      );
      expect(harness.controller.commands.manager.canUndo, canUndo);
      expect(harness.controller.sketchContinuityRepairPreview, isNotNull);
    },
  );

  test(
    'C0 repair applies a two-entity alternative as one undoable transaction',
    () async {
      final harness = await _g124Harness('g124-continuity-repair-both');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final api = harness.controller.sketchApi!;
      final first = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final second = api.builders.line.build(
        const SketchVector(1.05, 0),
        const SketchVector(2, 0),
      );
      harness.controller.selectedSketchEntityIds
        ..clear()
        ..addAll({first.id, second.id});
      harness.controller.selectSketchContinuityJoinFromSketchSelection();
      harness.controller.previewSketchContinuityRepair();
      final preview = harness.controller.sketchContinuityRepairPreview!;
      final bothIndex = preview.alternatives.indexWhere(
        (alternative) => alternative.updates.length == 2,
      );
      expect(bothIndex, greaterThanOrEqualTo(0));
      harness.controller.selectSketchContinuityRepairAlternative(bothIndex);
      final token = harness.controller.sketchContinuityRepairPreviewToken!;
      final beforeFirst = first.toJson()['parameters'];
      final beforeSecond = second.toJson()['parameters'];
      final historyBefore = api.engine.history.entries.length;

      final affected = await harness.controller
          .confirmSketchContinuityRepairPreview(token: token);

      expect(affected, containsAll(<String>[first.id, second.id]));
      expect(api.engine.history.entries.length, historyBefore + 1);
      final afterFirst = first.toJson()['parameters'];
      final afterSecond = second.toJson()['parameters'];
      expect(
        (api.entity(first.id) as SketchLine).parameters['end'],
        (api.entity(second.id) as SketchLine).parameters['start'],
      );

      await harness.controller.undo();
      expect(first.toJson()['parameters'], beforeFirst);
      expect(second.toJson()['parameters'], beforeSecond);
      await harness.controller.redo();
      expect(first.toJson()['parameters'], afterFirst);
      expect(second.toJson()['parameters'], afterSecond);
    },
  );

  test(
    'C0 repair applies a supported line-arc alternative without changing arc radius',
    () async {
      final harness = await _g124Harness('g124-continuity-repair-arc');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      final api = harness.controller.sketchApi!;
      final line = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final arc = api.builders.arc.build(
        const SketchVector(1.05, 1),
        1,
        -math.pi / 2,
        0,
      );
      harness.controller.selectedSketchEntityIds
        ..clear()
        ..addAll({line.id, arc.id});
      harness.controller.selectSketchContinuityJoinFromSketchSelection();
      harness.controller.previewSketchContinuityRepair();
      final token = harness.controller.sketchContinuityRepairPreviewToken!;
      final originalCenter =
          (api.entity(arc.id) as SketchArc).parameters['center'];
      final originalRadius =
          (api.entity(arc.id) as SketchArc).parameters['radius'];

      await harness.controller.confirmSketchContinuityRepairPreview(
        token: token,
      );

      final repairedArc = api.entity(arc.id) as SketchArc;
      expect(repairedArc.parameters['center'], originalCenter);
      expect(repairedArc.parameters['radius'], originalRadius);
      final repairedJoin = harness.controller.sketchContinuityAnalysis.joins
          .where(
            (join) => {
              join.first.entityId,
              join.second.entityId,
            }.containsAll({line.id, arc.id}),
          )
          .firstOrNull;
      expect(repairedJoin, isNotNull);
      expect(
        repairedJoin!.gapMillimeters,
        lessThanOrEqualTo(
          const SketchHealthAnalyzer().connectionTolerance + 1e-9,
        ),
      );
    },
  );

  test('C0 repair persists the confirmed geometry across Save/Open', () async {
    final harness = await _g124Harness('g124-continuity-repair-save');
    addTearDown(() => harness.directory.delete(recursive: true));
    addTearDown(harness.controller.dispose);
    addTearDown(harness.cad.dispose);
    final api = harness.controller.sketchApi!;
    final first = api.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
    );
    final second = api.builders.line.build(
      const SketchVector(1.05, 0),
      const SketchVector(2, 0),
    );
    final sketchId = harness.controller.activeSketch!.id;
    harness.controller.selectedSketchEntityIds
      ..clear()
      ..addAll({first.id, second.id});
    harness.controller.selectSketchContinuityJoinFromSketchSelection();
    harness.controller.previewSketchContinuityRepair();
    await harness.controller.confirmSketchContinuityRepairPreview(
      token: harness.controller.sketchContinuityRepairPreviewToken!,
    );
    await harness.controller.undo();
    await harness.controller.redo();
    await harness.controller.persist();

    final reopenedKernels = KernelManager()
      ..register(_HealthySurfaceKernel(), makeDefault: true);
    final reopenedCad = DesktopCadController(
      kernels: reopenedKernels,
      projects: ProjectManager.instance,
    );
    final reopenedCommands = DesktopCommandCoordinator(
      cad: reopenedCad,
      projects: ProjectManager.instance,
    );
    final reopened = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: reopenedCommands,
      runtime: reopenedCad.runtime,
      referenceApi: ReferenceApi(
        engine: ReferenceEngine(
          repository: ReferenceRepository(projects: harness.projects),
        ),
      ),
    );
    addTearDown(reopened.dispose);
    addTearDown(reopenedCad.dispose);
    await reopenedCad.runtime.open(
      'g124-continuity-repair-save',
      harness.directory,
    );
    await reopened.configureProject(
      projectId: 'g124-continuity-repair-save',
      projectDirectory: harness.directory,
    );
    await reopened.reopenSketchForEditing(sketchId);
    final restoredFirst = reopened.sketchApi!.entity(first.id) as SketchLine;
    final restoredSecond = reopened.sketchApi!.entity(second.id) as SketchLine;
    expect(restoredFirst.parameters['end'], restoredSecond.parameters['start']);
    expect(reopened.sketchContinuityRepairPreview, isNull);
    expect(reopened.sketchContinuityRepairPreviewToken, isNull);
    expect(reopenedCad.runtime.scene.find(first.id), isNotNull);
    expect(reopenedCad.runtime.scene.find(second.id), isNotNull);
  });
}

Future<
  ({
    Directory directory,
    DesktopCadController cad,
    OperationalReverseEngineeringController controller,
    ProjectRepository projects,
  })
>
_g124Harness(String name) async {
  final directory = await Directory.systemTemp.createTemp('${name}_');
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
  await cad.runtime.open(name, directory);
  await controller.configureProject(
    projectId: name,
    projectDirectory: directory,
  );
  controller.selectWorldSketchPlane(SketchPlaneType.xy);
  await controller.openSketch();
  return (
    directory: directory,
    cad: cad,
    controller: controller,
    projects: projects,
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
