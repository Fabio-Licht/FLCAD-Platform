import 'dart:io';

import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/native/integrated_native_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/professional_cad_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
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
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<
  ({
    DesktopCadController cad,
    OperationalReverseEngineeringController controller,
  })
>
_open(Directory directory, String projectId) async {
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
  await cad.runtime.open(projectId, directory);
  await controller.configureProject(
    projectId: projectId,
    projectDirectory: directory,
  );
  return (cad: cad, controller: controller);
}

int _overlayPointCount(CadSceneGraph scene) => scene.entities
    .where((entity) => entity.kind == CadSceneEntityKind.sketch)
    .map(
      (entity) =>
          (entity.geometry['points'] as List? ?? const []).length +
          (entity.geometry['segments'] as List? ?? const []).length,
    )
    .fold(0, (sum, value) => sum + value);

bool _isPickOnly(CadSceneEntity entity) =>
    entity.geometry['pickOnly'] == true ||
    entity.geometry['pickOnlyClosedProfile'] == true;

int _paintableOverlayPoints(CadSceneGraph scene, {required bool pickOnly}) =>
    scene.entities
        .where((entity) => entity.visible)
        .where((entity) => entity.kind == CadSceneEntityKind.sketch)
        .where((entity) => _isPickOnly(entity) == pickOnly)
        .map(
          (entity) =>
              (entity.geometry['points'] as List? ?? const []).length +
              (entity.geometry['segments'] as List? ?? const []).length,
        )
        .fold(0, (sum, value) => sum + value);

void main() {
  test(
    'sketch overlay visibility, hide/show and backend eligibility',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sketch-overlay_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final opened = await _open(directory, 'sketch-overlay');
      final cad = opened.cad;
      final controller = opened.controller;
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      final api = controller.sketchApi!;
      final first = api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final second = api.builders.line.build(
        const SketchVector(10, 0),
        const SketchVector(10, 10),
      );
      final point = api.builders.point.build(const SketchVector(2, 2));
      await controller.finishSketch();
      final sketchId = api.sketches.single.id;

      // 1. Visible sketch appears as Flutter overlay entities.
      final visibleOverlays = cad.runtime.scene.entities
          .where((entity) => entity.visible)
          .where((entity) => entity.kind == CadSceneEntityKind.sketch)
          .toList();
      expect(visibleOverlays, isNotEmpty);
      expect(cad.runtime.scene.find(first.id), isNotNull);
      expect(cad.runtime.scene.find(point.id), isNotNull);

      // 2. The Sketch must never be published to the native GPU: only real CAD
      //    geometry crosses the bridge.
      expect(
        CadSceneDisplayAdapter()
            .initial(cad.runtime.scene)
            .entities
            .map((entity) => entity['id']),
        isNot(contains(first.id)),
      );
      expect(nativeSceneUnsupportedReason(cad.runtime.scene, style: 0), isNull);

      final overlaysBeforeHide = _overlayPointCount(cad.runtime.scene);

      // 3. Hiding the Sketch root removes curves AND points immediately.
      await cad.runtime.setEntityVisibility(sketchId, false);
      expect(
        cad.runtime.scene.entities
            .where((entity) => entity.kind == CadSceneEntityKind.sketch)
            .where((entity) => entity.id == first.id || entity.id == point.id)
            .where((entity) => entity.visible),
        isEmpty,
        reason: 'Hide must remove the sketch curves and sampled points',
      );
      expect(nativeSceneUnsupportedReason(cad.runtime.scene, style: 0), isNull);

      // 4. Show restores each overlay exactly once.
      await cad.runtime.setEntityVisibility(sketchId, true);
      final restored = cad.runtime.scene.entities
          .where((entity) => entity.kind == CadSceneEntityKind.sketch)
          .where((entity) => entity.visible)
          .toList();
      expect(restored, isNotEmpty);
      expect(
        restored.where((entity) => entity.id == first.id),
        hasLength(1),
        reason: 'Show must not duplicate the same sketch overlay',
      );
      expect(_overlayPointCount(cad.runtime.scene), overlaysBeforeHide);

      // 5. The Sketch root is a pick target only; painting it would publish the
      //    same profile twice (root polyline + child curves).
      final root = cad.runtime.scene.find(sketchId);
      expect(root, isNotNull);
      expect(
        root!.geometry['pickOnly'],
        isTrue,
        reason: 'Sketch root pick geometry must be marked as pick-only',
      );

      expect(second.id, isNotEmpty);
    },
  );

  test(
    'one sketch publishes a single paintable overlay plus a pick-only target',
    () async {
      final directory = await Directory.systemTemp.createTemp('sketch-cost_');
      addTearDown(() => directory.delete(recursive: true));
      final opened = await _open(directory, 'sketch-cost');
      final cad = opened.cad;
      final controller = opened.controller;
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      final api = controller.sketchApi!;
      const segmentCount = 40;
      for (var index = 0; index < segmentCount; index++) {
        api.builders.line.build(
          SketchVector(index.toDouble(), 0),
          SketchVector(index + 1.0, 0),
        );
      }
      await controller.finishSketch();
      final sketchId = api.sketches.single.id;

      // The child curves paint 2 points each; the profile projection used for
      // Extrude picking adds 1 point per vertex and must never be painted.
      expect(_paintableOverlayPoints(cad.runtime.scene, pickOnly: false), 80);
      expect(_paintableOverlayPoints(cad.runtime.scene, pickOnly: true), 41);

      await cad.runtime.setEntityVisibility(sketchId, false);
      expect(_paintableOverlayPoints(cad.runtime.scene, pickOnly: false), 0);
      expect(_paintableOverlayPoints(cad.runtime.scene, pickOnly: true), 0);

      await cad.runtime.setEntityVisibility(sketchId, true);
      expect(_paintableOverlayPoints(cad.runtime.scene, pickOnly: false), 80);
      expect(_paintableOverlayPoints(cad.runtime.scene, pickOnly: true), 41);
    },
  );

  testWidgets(
    'camera movement never duplicates sketch overlays nor drops Native GPU',
    (tester) async {
      const channel = MethodChannel('flcad/native_viewport');
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      final scene = CadSceneGraph()
        ..upsert(_cadEntity())
        ..upsert(_sketchEntity('sketch:001'))
        ..upsert(_sketchEntity('sketch:line:001'));
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      );
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return call.method == 'initialize' ? 42 : null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: IntegratedCadViewportWidget(scene: scene, camera: camera),
        ),
      );
      await tester.pump();
      await tester.pump();
      final entitiesBefore = scene.entities.length;
      final overlaysBefore = scene.entities
          .where((entity) => entity.kind == CadSceneEntityKind.sketch)
          .length;
      final pointsBefore = _overlayPointCount(scene);
      for (var index = 0; index < 30; index++) {
        camera.orbit(.02, .01);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scene.entities.length, entitiesBefore);
      expect(
        scene.entities
            .where((entity) => entity.kind == CadSceneEntityKind.sketch)
            .length,
        overlaysBefore,
      );
      expect(_overlayPointCount(scene), pointsBefore);
      expect(nativeSceneUnsupportedReason(scene, style: 0), isNull);
      // Native GPU stays active, so Flutter must not paint meshes or edges.
      final viewport = tester.widget<ProfessionalCadViewportWidget>(
        find.byType(ProfessionalCadViewportWidget),
      );
      expect(viewport.renderMeshes, isFalse);
      // The Sketch never crosses the native bridge.
      expect(
        CadSceneDisplayAdapter()
            .initial(scene)
            .entities
            .map((entity) => entity['id']),
        ['cad:001'],
      );
      expect(calls, contains('snapshot'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      scene.dispose();
      camera.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'a transient unsupported preview must not strand the viewport on Canvas',
    (tester) async {
      const channel = MethodChannel('flcad/native_viewport');
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      final scene = CadSceneGraph()..upsert(_cadEntity());
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        return call.method == 'initialize' ? 42 : null;
      });
      Future<void> frames() async {
        for (var index = 0; index < 4; index++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          home: IntegratedCadViewportWidget(scene: scene, camera: camera),
        ),
      );
      await frames();
      expect(find.byType(Texture), findsOneWidget);

      // An Extrude preview is published before its display mesh exists.
      scene.upsert(
        const CadSceneEntity(
          id: 'preview:Extrude001',
          kind: CadSceneEntityKind.preview,
          transparent: true,
          geometry: {'featureId': 'Extrude001', 'tool': 'extrude'},
        ),
      );
      await frames();
      expect(find.byType(Texture), findsNothing);

      // Removing the transient preview must restore the Native GPU backend.
      scene.remove('preview:Extrude001');
      await frames();
      expect(
        find.byType(Texture),
        findsOneWidget,
        reason: 'Transient fallback must not be sticky',
      );
      await tester.pumpWidget(const SizedBox());
      await frames();
      scene.dispose();
      camera.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    },
    skip: !Platform.isWindows,
  );
}

CadSceneEntity _cadEntity() => const CadSceneEntity(
  id: 'cad:001',
  kind: CadSceneEntityKind.solid,
  geometry: {
    'nodes': [-1.0, -1.0, 0.0, 1.0, -1.0, 0.0, 0.0, 1.0, 0.0],
    'triangles': [0, 1, 2],
    'topologicalEdges': [
      [-1.0, -1.0, 0.0, 1.0, -1.0, 0.0],
    ],
  },
);

CadSceneEntity _sketchEntity(String id) => CadSceneEntity(
  id: id,
  kind: CadSceneEntityKind.sketch,
  geometry: const {
    'points': [
      [0.0, 0.0, 0.0],
      [1.0, 0.0, 0.0],
    ],
    'displayColor': 'sketchGreen',
    'strokeWidth': 2.0,
  },
);

class _HealthySurfaceKernel
    implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'sketch-overlay-test',
    name: 'sketch overlay kernel',
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
