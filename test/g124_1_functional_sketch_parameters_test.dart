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
      controller.selectSketchEntity(sourceA.id);
      controller.toggleSketchSelection(sourceB.id);
      await controller.fitSelectedSketchCircularGeometry();
      final fittedId = controller.selectedSketchEntityIds.single;
      final fitted = controller.sketchApi!.entity(fittedId)! as SketchArc;
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
