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
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_assistant/sketch_reconstruction.dart';
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

      // A larger radius moves both tangent contacts beyond the original line
      // spans. The edit must extend the frontiers instead of falling back to
      // the old arc endpoints and losing C1 continuity.
      await controller.updateSketchEntityParameters(arc.id, {'radius': 3});
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
      await controller.updateSketchEntityParameters(arc.id, {'radius': .5});
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
      });
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
      });
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

      controller.highlightSketchReconstructionSuggestion(second);
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
