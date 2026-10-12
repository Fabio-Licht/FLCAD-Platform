import 'dart:io';

import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/sketch_scene_adapter.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_application.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_assistant/sketch_reconstruction.dart';
import 'package:flcad_mobile/core/sketch_engine/history/sketch_history.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';

Offset _project(CadCameraController camera, List<num> point) {
  final ndc = camera.viewProjectionMatrix.transformPoint(
    Vector3(point[0].toDouble(), point[1].toDouble(), point[2].toDouble()),
  );
  return Offset(
    (ndc.x + 1) * camera.viewportWidth / 2,
    (1 - ndc.y) * camera.viewportHeight / 2,
  );
}

({CadCameraController camera, CadSceneGraph scene, List<String> childIds})
_multiRegionFixture() {
  final camera = CadCameraController(
    eye: const Vector3(0, 0, 20),
    target: Vector3.zero,
    up: const Vector3(0, 1, 0),
  )..resize(800, 600);
  final scene = CadSceneGraph();
  const children = <(String, List<num>, List<num>)>[
    ('line-nw', [-6, 4, 0], [-2, 4, 0]),
    ('line-ne', [2, 4, 0], [6, 4, 0]),
    ('line-sw', [-6, -4, 0], [-2, -4, 0]),
    ('line-se', [2, -4, 0], [6, -4, 0]),
  ];
  for (final child in children) {
    scene.upsert(
      CadSceneEntity(
        id: child.$1,
        kind: CadSceneEntityKind.sketch,
        geometry: {
          'points': [child.$2, child.$3],
          'showEndpoints': true,
        },
      ),
    );
  }
  scene.upsert(
    const CadSceneEntity(
      id: 'sketch-root',
      kind: CadSceneEntityKind.sketch,
      geometry: {
        'points': [
          [-8, -6, 0],
          [8, -6, 0],
          [8, 6, 0],
          [-8, 6, 0],
          [-8, -6, 0],
        ],
        'pickOnly': true,
        'pickOnlyClosedProfile': true,
        'displayColor': 'sketchProfilePickTarget',
      },
    ),
  );
  return (
    camera: camera,
    scene: scene,
    childIds: [for (final child in children) child.$1],
  );
}

void main() {
  test(
    'pick-only closed profile must not steal hover from painted child segments',
    () {
      final fixture = _multiRegionFixture();
      final picking = ViewportPickingController();
      for (final id in fixture.childIds) {
        final entity = fixture.scene.find(id)!;
        final points = entity.geometry['points'] as List;
        final mid = [
          ((points[0][0] as num) + (points[1][0] as num)) / 2,
          ((points[0][1] as num) + (points[1][1] as num)) / 2,
          0,
        ];
        final hit = picking.pick(
          position: _project(fixture.camera, mid),
          camera: fixture.camera,
          scene: fixture.scene,
          includePickOnlyProfiles: false,
        );
        expect(
          hit?.entityId,
          id,
          reason: 'Visible $id must remain hoverable under the pick-only overlay',
        );
      }
      final interior = picking.pick(
        position: _project(fixture.camera, const [0, 0, 0]),
        camera: fixture.camera,
        scene: fixture.scene,
        includePickOnlyProfiles: true,
      );
      expect(
        interior?.entityId,
        'sketch-root',
        reason: 'Extrude still needs the closed profile in empty interior',
      );

      fixture.scene.upsert(
        const CadSceneEntity(
          id: 'xy-plane',
          kind: CadSceneEntityKind.plane,
          geometry: {
            'origin': [0, 0, 0],
            'normal': [0, 0, 1],
            'visualSize': 6,
          },
        ),
      );
      expect(
        picking
            .pick(
              position: _project(fixture.camera, const [0, 0, 0]),
              camera: fixture.camera,
              scene: fixture.scene,
              includePickOnlyProfiles: true,
            )
            ?.entityId,
        'sketch-root',
        reason:
            'World plane must not steal Extrude closed-profile interior pick',
      );
      expect(
        picking
            .pick(
              position: _project(fixture.camera, const [0, 0, 0]),
              camera: fixture.camera,
              scene: fixture.scene,
              includePickOnlyProfiles: false,
            )
            ?.entityId,
        'xy-plane',
        reason: 'Suggestion hover excludes pick-only and can still hit the plane',
      );
    },
  );

  test(
    'empty segments fall through to painted points so the child stays pickable',
    () {
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 10),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      )..resize(800, 600);
      final scene = CadSceneGraph()
        ..upsert(
          const CadSceneEntity(
            id: 'empty-segments-child',
            kind: CadSceneEntityKind.sketch,
            geometry: {
              'segments': <List<dynamic>>[],
              'points': [
                [-1, 0, 0],
                [1, 0, 0],
              ],
            },
          ),
        );
      final hit = ViewportPickingController().pick(
        position: const Offset(400, 300),
        camera: camera,
        scene: scene,
      );
      expect(hit?.entityId, 'empty-segments-child');
    },
  );

  test(
    'suggestion hover candidate filter wins over an overlapping Section reference',
    () {
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 10),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      )..resize(800, 600);
      final scene = CadSceneGraph()
        ..upsert(
          const CadSceneEntity(
            id: 'section-reference',
            kind: CadSceneEntityKind.curve,
            geometry: {
              'points': [
                [-4, 0, 0],
                [4, 0, 0],
              ],
              'displayColor': 'sectionReferenceLilac',
            },
          ),
        )
        ..upsert(
          const CadSceneEntity(
            id: 'suggestion-source',
            kind: CadSceneEntityKind.sketch,
            geometry: {
              'points': [
                [-4, 0, 0],
                [4, 0, 0],
              ],
              'displayColor': 'reconstructedLine',
            },
          ),
        );
      addTearDown(scene.dispose);
      addTearDown(camera.dispose);
      final hit = ViewportPickingController().pick(
        position: _project(camera, const [0, 0, 0]),
        camera: camera,
        scene: scene,
        eligibleEntityIds: const {'suggestion-source'},
        includePickOnlyProfiles: false,
      );
      expect(hit?.entityId, 'suggestion-source');
    },
  );

  test(
    'line arc and spline suggestions all have reachable hover geometry',
    () async {
      final directory = await Directory.systemTemp.createTemp('hover-types_');
      addTearDown(() => directory.delete(recursive: true));
      final kernels = KernelManager()
        ..register(_HoverKernel(), makeDefault: true);
      final cad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
      );
      addTearDown(cad.dispose);
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
      await cad.runtime.open('hover-types', directory);
      await controller.configureProject(
        projectId: 'hover-types',
        projectDirectory: directory,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      final api = controller.sketchApi!;
      final line = api.builders.line.build(
        const SketchVector(-20, 12),
        const SketchVector(-10, 12),
      );
      final arc = api.builders.arc.build(
        const SketchVector(0, 0),
        8,
        0,
        1.5707963267948966,
      );
      final spline = api.builders.spline.build([
        const SketchVector(10, -12),
        const SketchVector(15, -8),
        const SketchVector(20, -12),
      ]);
      final suggestions = [
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.line,
          entityIds: [line.id],
          usedEntityIds: [line.id],
          confidence: 1,
        ),
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.arc,
          entityIds: [arc.id],
          usedEntityIds: [arc.id],
          confidence: 1,
        ),
        SketchReconstructionSuggestion(
          // Spline hypotheses are represented as line-kind candidates by the
          // reconstruction engine and classified as Splines from source type.
          kind: SketchReconstructionKind.line,
          entityIds: [spline.id],
          usedEntityIds: [spline.id],
          confidence: 1,
        ),
      ];
      controller.debugReplaceSketchReconstructionSuggestions(suggestions);

      final camera = CadCameraController(
        eye: const Vector3(0, 0, 40),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      )..resize(900, 700);
      final scene = cad.runtime.scene;
      final adapter = const SketchSceneAdapter();
      for (final entity in [line, arc, spline]) {
        final visual = adapter.adapt(
          entity,
          coordinates: controller.activeSketch!.coordinates,
        );
        scene.upsert(visual);
      }
      addTearDown(camera.dispose);

      final candidates =
          controller.sketchReconstructionSuggestionPickCandidateIds;
      expect(candidates, containsAll([line.id, arc.id, spline.id]));
      final hoverPoints = <String, List<num>>{
        line.id: [-15, 12, 0],
        arc.id: [5.656854249, 5.656854249, 0],
        spline.id: [15, -8, 0],
      };
      final picking = ViewportPickingController();
      for (final suggestion in suggestions) {
        final id = suggestion.entityIds.single;
        final hit = picking.pick(
          position: _project(camera, hoverPoints[id]!),
          camera: camera,
          scene: scene,
          eligibleEntityIds: candidates,
          includePickOnlyProfiles: false,
        );
        expect(hit?.entityId, id, reason: 'Rendered $id must be pickable');
        expect(
          controller.hoverSketchReconstructionSuggestionForEntity(id),
          isTrue,
          reason: 'Rendered $id must resolve to its active suggestion',
        );
        expect(
          controller.isSketchReconstructionSuggestionHovered(suggestion),
          isTrue,
        );
      }
    },
  );

  test(
    'every active suggestion in a multi-region fixture is hoverable',
    () async {
      final directory = await Directory.systemTemp.createTemp('hover-regions_');
      addTearDown(() => directory.delete(recursive: true));
      final kernels = KernelManager()
        ..register(_HoverKernel(), makeDefault: true);
      final cad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
      );
      addTearDown(cad.dispose);
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
      await cad.runtime.open('hover-regions', directory);
      await controller.configureProject(
        projectId: 'hover-regions',
        projectDirectory: directory,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      final api = controller.sketchApi!;

      final fragments = [
        api.builders.line.build(
          const SketchVector(-30, 20),
          const SketchVector(-20, 20),
        ),
        api.builders.line.build(
          const SketchVector(20, 20),
          const SketchVector(30, 20),
        ),
        api.builders.line.build(
          const SketchVector(-30, -20),
          const SketchVector(-20, -20),
        ),
        api.builders.line.build(
          const SketchVector(20, -20),
          const SketchVector(30, -20),
        ),
      ];
      final covered = api.builders.line.build(
        const SketchVector(0, 8),
        const SketchVector(4, 8),
      );
      final invalidated = api.builders.line.build(
        const SketchVector(0, -8),
        const SketchVector(4, -8),
      );
      api.engine.modify(invalidated.id, SketchHistoryAction.modify, (entity) {
        entity.visible = false;
        entity.metadata['reconstructionHidden'] = true;
      });

      final regionSuggestions = [
        for (final fragment in fragments)
          SketchReconstructionSuggestion(
            kind: SketchReconstructionKind.line,
            entityIds: [fragment.id],
            usedEntityIds: [fragment.id],
            confidence: 1,
          ),
      ];
      final coveredSuggestion = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.line,
        entityIds: [fragments.first.id],
        usedEntityIds: [fragments.first.id],
        coveredEntityIds: [covered.id],
        confidence: 0.9,
      );
      final invalidatedSuggestion = SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.line,
        entityIds: [invalidated.id],
        usedEntityIds: [invalidated.id],
        confidence: 0.4,
      );
      controller.debugReplaceSketchReconstructionSuggestions([
        ...regionSuggestions,
        coveredSuggestion,
        invalidatedSuggestion,
      ]);

      cad.runtime.scene.upsert(
        CadSceneEntity(
          id: controller.activeSketch!.id,
          kind: CadSceneEntityKind.sketch,
          geometry: {
            'points': [
              [-40.0, -30.0, 0.0],
              [40.0, -30.0, 0.0],
              [40.0, 30.0, 0.0],
              [-40.0, 30.0, 0.0],
            ],
            'pickOnly': true,
            'pickOnlyClosedProfile': true,
          },
        ),
      );

      expect(regionSuggestions, hasLength(4));
      for (final suggestion in regionSuggestions) {
        expect(
          controller.hoverSketchReconstructionSuggestionForEntity(
            suggestion.entityIds.single,
          ),
          isTrue,
          reason:
              'Active ${suggestion.entityIds} must resolve from its painted source',
        );
        expect(
          controller.isSketchReconstructionSuggestionHovered(suggestion),
          isTrue,
        );
        expect(sketchReconstructionSuggestionUiKey(suggestion), isNotEmpty);
        expect(
          controller.sketchReconstructionSuggestionCategory(suggestion),
          SketchReconstructionSuggestionCategory.lines,
        );
      }
      expect(
        controller.hoverSketchReconstructionSuggestionForEntity(covered.id),
        isTrue,
        reason: 'A visible covered fragment of an active suggestion is hoverable',
      );

      expect(
        controller.hoverSketchReconstructionSuggestionForEntity(invalidated.id),
        isFalse,
        reason: 'Hidden/invalidated sources must not become hoverable',
      );
      expect(
        controller.hoverSketchReconstructionSuggestionForEntity(
          controller.activeSketch!.id,
        ),
        isFalse,
        reason: 'Pick-only profile must not invent a suggestion association',
      );

      controller.highlightSketchReconstructionSuggestion(
        regionSuggestions.first,
        persistent: true,
      );
      expect(
        controller.selectSketchReconstructionSuggestionForEntity(
          regionSuggestions[1].entityIds.single,
          additive: true,
        ),
        isTrue,
      );
      expect(controller.selectedSketchReconstructionSuggestions, hasLength(2));
    },
  );
}

class _HoverKernel implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'hover-test',
    name: 'Hover test kernel',
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
