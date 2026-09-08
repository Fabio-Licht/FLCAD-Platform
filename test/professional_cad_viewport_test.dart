import 'dart:io';
import 'dart:convert';

import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/professional_cad_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/cad_canvas_normal_pipeline.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/cad_tonal_separation.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_scene_adapter.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_context.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/import_export/api/import_export_api.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/models/reference_entity.dart';
import 'package:flcad_mobile/core/reference_engine/models/reference_geometry.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/smart_regions/models/geometry.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flcad_mobile/app/navigation/navigation_contracts.dart';
import 'package:flcad_mobile/app/navigation/navigation_debug_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Canvas normals smooth continuity and preserve a hard edge', () {
    final smooth = CadCanvasNormalPipeline.build(
      const [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0],
      const [0, 1, 2, 0, 2, 3],
    ).single;
    for (var offset = 0; offset < smooth.normals.length; offset += 3) {
      expect(smooth.normals[offset].abs(), lessThan(1e-6));
      expect(smooth.normals[offset + 1].abs(), lessThan(1e-6));
      expect(smooth.normals[offset + 2], closeTo(1, 1e-6));
    }

    final hard = CadCanvasNormalPipeline.build(
      const [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
      const [0, 1, 2, 0, 3, 1],
    ).single;
    final first = Vector3(hard.normals[0], hard.normals[1], hard.normals[2]);
    final second = Vector3(hard.normals[9], hard.normals[10], hard.normals[11]);
    expect(first.dot(second).abs(), lessThan(1e-6));
  });

  test('Canvas normals weld duplicated STL positions before smoothing', () {
    final chunk = CadCanvasNormalPipeline.build(
      const [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, .8660254, .5],
      const [0, 1, 2, 3, 4, 5],
    ).single;
    final first = Vector3(chunk.normals[0], chunk.normals[1], chunk.normals[2]);
    final duplicate = Vector3(
      chunk.normals[9],
      chunk.normals[10],
      chunk.normals[11],
    );
    expect(first.distanceTo(duplicate), lessThan(1e-6));
    expect(first.y, lessThan(-.1));
    expect(first.z, greaterThan(.8));
  });

  test('RENDER-001 separates geometry tones without producing bands', () {
    const base = Color(0xff7899ad);
    final dark = CadTonalSeparation.shade(base, .15);
    final middle = CadTonalSeparation.shade(base, .5);
    final light = CadTonalSeparation.shade(base, .85);
    final adjacentA = CadTonalSeparation.shade(base, .500);
    final adjacentB = CadTonalSeparation.shade(base, .501);

    double luminance(Color color) => color.computeLuminance();
    expect(luminance(dark), lessThan(luminance(middle)));
    expect(luminance(middle), lessThan(luminance(light)));
    expect(luminance(middle) - luminance(dark), greaterThan(.08));
    expect(luminance(light) - luminance(middle), greaterThan(.08));
    expect((luminance(adjacentB) - luminance(adjacentA)).abs(), lessThan(.002));
  });

  const mesh = KernelMeshGeometry(
    nodes: [-1, -1, 0, 1, -1, 0, 0, 1, 0],
    triangles: [0, 1, 2],
  );
  const bounds = KernelBounds(-1, -1, 0, 1, 1, 0);

  test('camera exposes stable invertible matrices and both projections', () {
    final camera = CadCameraController();
    camera.resize(800, 600);
    camera.fit(const Vector3(-1, -1, -1), const Vector3(1, 1, 1));
    final point = const Vector3(.25, -.4, .1);
    final projected = camera.viewProjectionMatrix.transformPoint(point);
    final restored = camera.inverseViewProjectionMatrix.transformPoint(
      projected,
    );
    expect(restored.distanceTo(point), lessThan(1e-8));
    final perspective = camera.projectionMatrix.values;
    camera.toggleProjection();
    expect(camera.projectionMode, CadProjectionMode.orthographic);
    expect(camera.projectionMatrix.values, isNot(perspective));
  });

  test('Fit always clears temporary navigation displacement and recovers', () {
    final camera = CadCameraController(
      eye: const Vector3(4, -6, 8),
      target: Vector3.zero,
      up: const Vector3(0, 0, 1),
    )..resize(1000, 700);
    const minimum = Vector3(-2, -1, -3);
    const maximum = Vector3(6, 5, 1);
    camera.translateOperationalScene(const Vector3(500, -350, 0));
    expect(camera.presentationOffsetNdcX.abs(), greaterThan(1));

    camera.fit(minimum, maximum);

    final center = (minimum + maximum) / 2;
    final projectedCenter = camera.viewProjectionMatrix.transformPoint(center);
    expect(camera.presentationTranslation, Vector3.zero);
    expect(camera.presentationOffsetNdcX, 0);
    expect(camera.presentationOffsetNdcY, 0);
    expect(projectedCenter.x, closeTo(0, 1e-10));
    expect(projectedCenter.y, closeTo(0, 1e-10));
  });

  test('all standard views preserve center, projection and safe framing', () {
    const minimum = Vector3(-4, -2, -3);
    const maximum = Vector3(6, 8, 5);
    final center = (minimum + maximum) / 2;
    final expectedDirections = <CadStandardView, Vector3>{
      CadStandardView.perspective: const Vector3(1, -1, .75).normalized,
      CadStandardView.top: const Vector3(0, 0, 1),
      CadStandardView.bottom: const Vector3(0, 0, -1),
      CadStandardView.front: const Vector3(0, -1, 0),
      CadStandardView.back: const Vector3(0, 1, 0),
      CadStandardView.right: const Vector3(1, 0, 0),
      CadStandardView.left: const Vector3(-1, 0, 0),
      CadStandardView.isometric: const Vector3(1, -1, 1).normalized,
    };

    for (final entry in expectedDirections.entries) {
      final camera = CadCameraController()..resize(1000, 700);
      final projectionBefore = camera.projectionMode;
      camera.translateOperationalScene(const Vector3(50, -30, 0));

      camera.setStandardView(entry.key, minimum, maximum);

      final direction = (camera.eye - center).normalized;
      final projectedCenter = camera.viewProjectionMatrix.transformPoint(
        center,
      );
      expect(direction.dot(entry.value), greaterThan(.999999));
      expect(camera.target.distanceTo(center), lessThan(1e-12));
      expect(camera.rotationCenter.distanceTo(center), lessThan(1e-12));
      expect(camera.focusPoint.distanceTo(center), lessThan(1e-12));
      expect(camera.projectionMode, projectionBefore);
      expect(projectedCenter.x, closeTo(0, 1e-10));
      expect(projectedCenter.y, closeTo(0, 1e-10));
      expect(camera.presentationOffsetNdcX, 0);
      expect(camera.presentationOffsetNdcY, 0);
    }
  });

  test('camera zoom cannot cross the target or enter the near plane', () {
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
    );
    for (var i = 0; i < 100; i++) {
      camera.zoom(.01);
    }
    expect((camera.eye - camera.target).length, greaterThanOrEqualTo(.04));
    expect(camera.eye.z, greaterThan(0));
  });

  test('camera zoom can preserve a picked cursor anchor', () {
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 10),
      target: Vector3.zero,
    );
    camera.zoom(.5, anchor: const Vector3(2, 0, 0));
    expect(camera.eye.distanceTo(const Vector3(1, 0, 5)), lessThan(1e-9));
    expect(camera.target.distanceTo(const Vector3(1, 0, 0)), lessThan(1e-9));
    expect(camera.rotationCenter.distanceTo(Vector3.zero), lessThan(1e-9));
    camera.setRotationCenter(const Vector3(3, 2, 1));
    expect(
      camera.rotationCenter.distanceTo(const Vector3(3, 2, 1)),
      lessThan(1e-9),
    );
    expect(camera.target.distanceTo(const Vector3(1, 0, 0)), lessThan(1e-9));
  });

  test('viewport pan translates eye and target without any rotation', () {
    for (final orthographic in [false, true]) {
      final camera = CadCameraController(
        eye: const Vector3(8, -6, 4),
        target: const Vector3(1, 2, -3),
        up: const Vector3(.1, .2, 1),
      )..resize(1200, 800);
      if (orthographic) camera.toggleProjection();
      final eyeBefore = camera.eye;
      final targetBefore = camera.target;
      final centerBefore = camera.rotationCenter;
      final focusBefore = camera.focusPoint;
      final viewBefore = camera.target - camera.eye;

      camera.panViewportPixels(140, -85);

      final eyeDelta = camera.eye - eyeBefore;
      final targetDelta = camera.target - targetBefore;
      final centerDelta = camera.rotationCenter - centerBefore;
      expect(eyeDelta.length, greaterThan(0));
      expect(eyeDelta.distanceTo(targetDelta), lessThan(1e-10));
      expect(eyeDelta.distanceTo(centerDelta), lessThan(1e-10));
      final focusDelta = camera.focusPoint - focusBefore;
      expect(eyeDelta.distanceTo(focusDelta), lessThan(1e-10));
      expect(
        (camera.target - camera.eye).distanceTo(viewBefore),
        lessThan(1e-10),
      );
      expect(eyeDelta.dot(viewBefore.normalized).abs(), lessThan(1e-10));
    }
  });

  test('continuous pan has zero accumulated angular drift', () {
    for (final orthographic in [false, true]) {
      final camera = CadCameraController(
        eye: const Vector3(100000008, -99999994, 100000004),
        target: const Vector3(100000001, -100000002, 100000003),
        up: const Vector3(.1, .2, 1),
      )..resize(1920, 1080);
      if (orthographic) camera.toggleProjection();
      final forwardBefore = (camera.target - camera.eye).normalized;
      final viewBefore = camera.viewMatrix.values;

      for (var index = 0; index < 5000; index++) {
        final dx = ((index % 17) - 8) * .37;
        final dy = ((index % 13) - 6) * .29;
        camera.panViewportPixels(dx, dy);
      }

      final forwardAfter = (camera.target - camera.eye).normalized;
      final viewAfter = camera.viewMatrix.values;
      expect(forwardAfter.distanceTo(forwardBefore), lessThan(1e-12));
      for (final index in [0, 1, 2, 4, 5, 6, 8, 9, 10]) {
        expect(viewAfter[index], closeTo(viewBefore[index], 1e-12));
      }
    }
  });

  test('pan result depends only on total gesture displacement', () {
    final single = CadCameraController()..resize(1200, 800);
    final stepped = CadCameraController()..resize(1200, 800);
    final singleBaseline = single.snapshot();
    final steppedBaseline = stepped.snapshot();

    single.panViewportPixelsFrom(singleBaseline, 240, -125);
    for (var step = 1; step <= 200; step++) {
      stepped.panViewportPixelsFrom(
        steppedBaseline,
        240 * step / 200,
        -125 * step / 200,
      );
    }

    expect(stepped.eye.distanceTo(single.eye), lessThan(1e-12));
    expect(stepped.target.distanceTo(single.target), lessThan(1e-12));
    expect(
      stepped.rotationCenter.distanceTo(single.rotationCenter),
      lessThan(1e-12),
    );
    expect(stepped.focusPoint.distanceTo(single.focusPoint), lessThan(1e-12));
    expect(stepped.up.distanceTo(singleBaseline.up), lessThan(1e-12));
    expect(
      (stepped.target - stepped.eye).distanceTo(
        singleBaseline.target - singleBaseline.eye,
      ),
      lessThan(1e-12),
    );
    expect(stepped.viewScale, singleBaseline.viewScale);
    expect(stepped.fieldOfViewRadians, singleBaseline.fieldOfViewRadians);
    expect(stepped.nearPlane, singleBaseline.nearPlane);
    expect(stepped.farPlane, singleBaseline.farPlane);
  });

  test('surface anchored pan keeps the captured point under the cursor', () {
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 10),
      target: Vector3.zero,
    )..resize(1000, 800);
    const anchor = Vector3(1.2, -.7, 2.5);
    final baseline = camera.snapshot();

    Offset screenPoint(Vector3 point) {
      final projected = camera.viewProjectionMatrix.transformPoint(point);
      return Offset(
        (projected.x + 1) * camera.viewportWidth / 2,
        (1 - projected.y) * camera.viewportHeight / 2,
      );
    }

    final before = screenPoint(anchor);
    camera.panViewportPixelsFrom(baseline, 175, -90, surfaceAnchor: anchor);
    final after = screenPoint(anchor);

    expect(after.dx - before.dx, closeTo(175, 1e-9));
    expect(after.dy - before.dy, closeTo(-90, 1e-9));
  });

  test('orbit preserves the explicit rotation center', () {
    final camera = CadCameraController(
      eye: const Vector3(6, -6, 4),
      target: const Vector3(1, 0, 0),
      rotationCenter: const Vector3(0, 0, 0),
    );
    final centerBefore = camera.rotationCenter;
    final eyeRadius = (camera.eye - centerBefore).length;
    final targetRadius = (camera.target - centerBefore).length;

    camera.orbit(.4, -.25);

    expect(camera.rotationCenter.distanceTo(centerBefore), lessThan(1e-12));
    expect((camera.eye - centerBefore).length, closeTo(eyeRadius, 1e-10));
    expect((camera.target - centerBefore).length, closeTo(targetRadius, 1e-10));
  });

  test('orbit follows the selected working region', () {
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 10),
      target: Vector3.zero,
      rotationCenter: Vector3.zero,
    );
    const region = Vector3(2, 0, 0);
    camera.focusOn(region);
    final eyeRadius = (camera.eye - region).length;
    final targetRadius = (camera.target - region).length;

    camera.orbit(.25, .1);

    expect(camera.focusPoint.distanceTo(region), lessThan(1e-12));
    expect(camera.rotationCenter.distanceTo(Vector3.zero), lessThan(1e-12));
    expect((camera.eye - region).length, closeTo(eyeRadius, 1e-10));
    expect((camera.target - region).length, closeTo(targetRadius, 1e-10));
  });

  test('continuous orbit keeps the perceptive pivot fixed on screen', () {
    final camera = CadCameraController(
      eye: const Vector3(7, -5, 6),
      target: const Vector3(1, .5, 0),
      rotationCenter: const Vector3(1, .5, 0),
      focusPoint: const Vector3(2.2, -.4, 1.1),
      up: const Vector3(0, 0, 1),
    )..resize(1280, 720);
    camera.translateOperationalScene(const Vector3(.8, -.35, .2));
    final before = camera.viewProjectionMatrix.transformPoint(
      camera.focusPoint,
    );

    for (var frame = 0; frame < 240; frame++) {
      camera.orbit(.004, -.0015);
    }

    final after = camera.viewProjectionMatrix.transformPoint(camera.focusPoint);
    expect(after.x, closeTo(before.x, 1e-10));
    expect(after.y, closeTo(before.y, 1e-10));
    expect(camera.focusPoint, const Vector3(2.2, -.4, 1.1));
  });

  test('sketch mode restores the complete professional camera state', () {
    final camera = CadCameraController(
      eye: const Vector3(8, -3, 5),
      target: const Vector3(2, 1, 0),
      rotationCenter: const Vector3(1, 1, 1),
      up: const Vector3(0, 0, 1),
    );
    camera.viewScale = 23;
    camera.fieldOfViewRadians = .81;
    camera.presentationTranslation = const Vector3(3, -2, 1);
    camera.presentationOffsetNdcX = .18;
    camera.presentationOffsetNdcY = -.12;
    final before = camera.snapshot();

    camera.enterSketch(
      origin: const Vector3(10, 20, 30),
      normal: const Vector3(0, 0, 1),
      xDirection: const Vector3(1, 0, 0),
    );
    expect(
      camera.rotationCenter.distanceTo(before.rotationCenter),
      greaterThan(1),
    );
    camera.translateOperationalScene(const Vector3(14, -9, 0));
    camera.presentationOffsetNdcX = -.6;
    camera.presentationOffsetNdcY = .4;
    camera.exitSketch();

    expect(camera.eye.distanceTo(before.eye), lessThan(1e-12));
    expect(camera.target.distanceTo(before.target), lessThan(1e-12));
    expect(
      camera.rotationCenter.distanceTo(before.rotationCenter),
      lessThan(1e-12),
    );
    expect(camera.focusPoint.distanceTo(before.focusPoint), lessThan(1e-12));
    expect(camera.up.distanceTo(before.up), lessThan(1e-12));
    expect(camera.viewScale, before.viewScale);
    expect(camera.projectionMode, before.projectionMode);
    expect(camera.nearPlane, before.nearPlane);
    expect(camera.farPlane, before.farPlane);
    expect(camera.fieldOfViewRadians, before.fieldOfViewRadians);
    expect(
      camera.presentationTranslation.distanceTo(before.presentationTranslation),
      lessThan(1e-12),
    );
    expect(camera.presentationOffsetNdcX, before.presentationOffsetNdcX);
    expect(camera.presentationOffsetNdcY, before.presentationOffsetNdcY);
  });

  test('mesh adapter is the single kernel-to-scene boundary', () {
    final entity = MeshSceneAdapter.fromKernel(
      id: 'mesh-1',
      geometry: mesh,
      bounds: bounds,
    );
    expect(entity.kind, CadSceneEntityKind.mesh);
    expect(entity.geometry['nodes'], mesh.nodes);
    expect(entity.geometry['triangles'], mesh.triangles);
    expect((entity.geometry['bounds'] as Map)['min'], [-1, -1, 0]);
  });

  test('viewport picking uses the camera ray and mesh BVH', () {
    final scene = CadSceneGraph()
      ..upsert(
        MeshSceneAdapter.fromKernel(
          id: 'mesh-1',
          geometry: mesh,
          bounds: bounds,
        ),
      );
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);
    final hit = ViewportPickingController().pick(
      position: const Offset(400, 300),
      camera: camera,
      scene: scene,
    );
    expect(hit?.entityId, 'mesh-1');
    expect(hit?.hit.triangleIndex, 0);
  });

  test('viewport picking recognizes tessellated surfaces and solids', () {
    for (final kind in [CadSceneEntityKind.surface, CadSceneEntityKind.solid]) {
      final scene = CadSceneGraph()
        ..upsert(
          CadSceneEntity(
            id: kind.name,
            kind: kind,
            geometry: {'nodes': mesh.nodes, 'triangles': mesh.triangles},
          ),
        );
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      )..resize(800, 600);

      final hit = ViewportPickingController().pick(
        position: const Offset(400, 300),
        camera: camera,
        scene: scene,
      );

      expect(hit?.entityId, kind.name);
    }
  });

  test('viewport picking prioritizes sketches and selects world planes', () {
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 10),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);
    final scene = CadSceneGraph()
      ..upsert(
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
    final picking = ViewportPickingController();

    expect(
      picking
          .pick(position: const Offset(400, 300), camera: camera, scene: scene)
          ?.entityId,
      'xy-plane',
    );

    scene.upsert(
      const CadSceneEntity(
        id: 'section-curve',
        kind: CadSceneEntityKind.curve,
        geometry: {
          'points': [
            [-1, 0, 0],
            [1, 0, 0],
          ],
        },
      ),
    );
    final curveHit = picking.pick(
      position: const Offset(400, 300),
      camera: camera,
      scene: scene,
    );
    expect(curveHit?.entityId, 'section-curve');
    expect(curveHit!.hit.point.x, closeTo(0, 1e-9));
    expect(curveHit.hit.point.y, closeTo(0, 1e-9));
  });

  test(
    'empty-project world planes use a discrete camera-relative footprint',
    () {
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 10),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      )..resize(800, 600);
      final scene = CadSceneGraph()
        ..upsert(
          const CadSceneEntity(
            id: 'project:world:xy-plane',
            kind: CadSceneEntityKind.plane,
            geometry: {
              'origin': [0, 0, 0],
              'normal': [0, 0, 1],
              'visualSize': 60,
            },
          ),
        );
      final picking = ViewportPickingController();

      expect(
        picking.pick(
          position: const Offset(400, 300),
          camera: camera,
          scene: scene,
        ),
        isNotNull,
      );
      expect(
        picking.pick(
          position: const Offset(700, 300),
          camera: camera,
          scene: scene,
        ),
        isNull,
      );
    },
  );

  testWidgets('professional viewport renders scene controls', (tester) async {
    final scene = CadSceneGraph()
      ..upsert(
        MeshSceneAdapter.fromKernel(
          id: 'mesh-1',
          geometry: mesh,
          bounds: bounds,
        ),
      );
    final camera = CadCameraController();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: ProfessionalCadViewportWidget(scene: scene, camera: camera),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Shaded'), findsOneWidget);
    expect(find.text('Wire'), findsOneWidget);
    expect(find.byTooltip('Fit View'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('professional-view-cube')),
      findsOneWidget,
    );
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets(
    'ViewCube ISO uses the shared camera and fits the visible scene',
    (tester) async {
      final scene = CadSceneGraph()
        ..upsert(
          MeshSceneAdapter.fromKernel(
            id: 'mesh-1',
            geometry: mesh,
            bounds: bounds,
          ),
        );
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: ProfessionalCadViewportWidget(scene: scene, camera: camera),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('professional-view-cube')));
      await tester.pump();

      final direction = (camera.eye - camera.target).normalized;
      expect(direction.x, closeTo(0.5773502691896258, 1e-9));
      expect(direction.y, closeTo(-0.5773502691896258, 1e-9));
      expect(direction.z, closeTo(0.5773502691896258, 1e-9));
      final projectedCenter = camera.viewProjectionMatrix.transformPoint(
        Vector3.zero,
      );
      expect(projectedCenter.x, closeTo(0, 1e-9));
      expect(projectedCenter.y, closeTo(0, 1e-9));
    },
  );

  testWidgets('dragging the ViewCube continuously orients the shared camera', (
    tester,
  ) async {
    final scene = CadSceneGraph()
      ..upsert(
        MeshSceneAdapter.fromKernel(
          id: 'mesh-1',
          geometry: mesh,
          bounds: bounds,
        ),
      );
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: ProfessionalCadViewportWidget(scene: scene, camera: camera),
        ),
      ),
    );
    final before = (camera.eye - camera.target).normalized;

    await tester.drag(
      find.byKey(const ValueKey('professional-view-cube')),
      const Offset(36, 24),
    );
    await tester.pump();

    final after = (camera.eye - camera.target).normalized;
    expect((after - before).length, greaterThan(0.01));
    expect((camera.eye - camera.target).length, closeTo(5, 1e-9));
  });

  testWidgets(
    'production viewport middle-pan moves camera and preserves presentation',
    (tester) async {
      final scene = CadSceneGraph()
        ..upsert(
          MeshSceneAdapter.fromKernel(
            id: 'mesh-1',
            geometry: mesh,
            bounds: bounds,
          ),
        );
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: ProfessionalCadViewportWidget(
              scene: scene,
              camera: camera,
              showNavigationDebug: true,
            ),
          ),
        ),
      );
      await tester.pump();
      final engine = tester
          .widget<NavigationDebugPanel>(find.byType(NavigationDebugPanel))
          .engine;
      expect(engine.profile, NavigationProfile.flcadReverseEngineering);
      final targetBefore = camera.target;
      final offsetXBefore = camera.presentationOffsetNdcX;
      final offsetYBefore = camera.presentationOffsetNdcY;
      final viewBefore = camera.target - camera.eye;
      final eyeBefore = camera.eye;
      final presentationBefore = camera.presentationTranslation;
      final mouse = TestPointer(7, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        mouse.down(const Offset(400, 300), buttons: kMiddleMouseButton),
      );
      await tester.sendEventToBinding(
        mouse.move(const Offset(470, 340), buttons: kMiddleMouseButton),
      );
      await tester.sendEventToBinding(mouse.up());
      await tester.pump();

      expect(camera.eye.distanceTo(eyeBefore), greaterThan(0));
      expect(camera.target.distanceTo(targetBefore), greaterThan(0));
      expect(camera.presentationOffsetNdcX, offsetXBefore);
      expect(camera.presentationOffsetNdcY, offsetYBefore);
      expect(
        camera.presentationTranslation.distanceTo(presentationBefore),
        lessThan(1e-12),
      );
      expect(
        (camera.target - camera.eye).distanceTo(viewBefore),
        lessThan(1e-10),
      );
    },
  );

  testWidgets('CATIA chord transitions continuously from orbit to zoom', (
    tester,
  ) async {
    final scene = CadSceneGraph()
      ..upsert(
        MeshSceneAdapter.fromKernel(
          id: 'mesh-1',
          geometry: mesh,
          bounds: bounds,
        ),
      );
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: ProfessionalCadViewportWidget(scene: scene, camera: camera),
        ),
      ),
    );
    await tester.pump();
    const start = Offset(400, 300);
    const orbitEnd = Offset(460, 330);
    const zoomEnd = Offset(460, 250);
    const pointer = 31;
    const device = 31;

    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: pointer,
        device: device,
        kind: PointerDeviceKind.mouse,
        position: start,
        buttons: kMiddleMouseButton,
      ),
    );
    await tester.sendEventToBinding(
      const PointerMoveEvent(
        pointer: pointer,
        device: device,
        kind: PointerDeviceKind.mouse,
        position: orbitEnd,
        delta: Offset(60, 30),
        buttons: kMiddleMouseButton | kPrimaryMouseButton,
      ),
    );
    final distanceAfterOrbit = (camera.eye - camera.target).length;
    await tester.sendEventToBinding(
      const PointerMoveEvent(
        pointer: pointer,
        device: device,
        kind: PointerDeviceKind.mouse,
        position: zoomEnd,
        delta: Offset(0, -80),
        buttons: kMiddleMouseButton,
      ),
    );

    expect((camera.eye - camera.target).length, lessThan(distanceAfterOrbit));
  });

  testWidgets('selection transfers navigation to the selected region', (
    tester,
  ) async {
    final scene = CadSceneGraph()
      ..upsert(
        MeshSceneAdapter.fromKernel(
          id: 'mesh-1',
          geometry: mesh,
          bounds: bounds,
        ),
      );
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      focusPoint: const Vector3(9, 9, 9),
      up: const Vector3(0, 1, 0),
    );
    CadViewportPick? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: ProfessionalCadViewportWidget(
            scene: scene,
            camera: camera,
            onPick: (pick) => selected = pick,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tapAt(const Offset(400, 300));
    await tester.pump();

    expect(selected?.entityId, 'mesh-1');
    expect(camera.focusPoint.distanceTo(selected!.hit.point), lessThan(1e-12));
  });

  testWidgets(
    'active Sketch tool receives clicks while preserving pan and wheel zoom',
    (tester) async {
      final scene = CadSceneGraph();
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      );
      Offset? sketchClick;
      var sketchFinished = false;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: ProfessionalCadViewportWidget(
              scene: scene,
              camera: camera,
              enablePicking: false,
              onSketchTap: (position) => sketchClick = position,
              onSketchSecondaryTap: () => sketchFinished = true,
            ),
          ),
        ),
      );
      await tester.pump();

      final eyeBefore = camera.eye;
      final targetBefore = camera.target;
      final presentationBefore = camera.presentationTranslation;
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();

      expect(sketchClick, isNotNull);

      await tester.tapAt(
        const Offset(420, 320),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      expect(sketchFinished, isTrue);

      final mouse = TestPointer(41, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        mouse.down(const Offset(400, 300), buttons: kMiddleMouseButton),
      );
      await tester.sendEventToBinding(
        mouse.move(const Offset(470, 340), buttons: kMiddleMouseButton),
      );
      await tester.sendEventToBinding(mouse.up());
      await tester.pump();

      expect(
        camera.presentationTranslation.distanceTo(presentationBefore),
        lessThan(1e-12),
      );
      expect(camera.eye.distanceTo(eyeBefore), greaterThan(1e-6));
      expect(camera.target.distanceTo(targetBefore), greaterThan(1e-6));
      expect(camera.presentationOffsetNdcX, 0);
      expect(camera.presentationOffsetNdcY, 0);
      final scaleBeforeZoom = camera.viewScale;
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(400, 300),
          scrollDelta: Offset(0, -120),
        ),
      );
      await tester.pump();
      expect(camera.viewScale, isNot(scaleBeforeZoom));
    },
  );

  testWidgets(
    'active Sketch command prioritizes an existing entity for selection',
    (tester) async {
      final scene = CadSceneGraph()
        ..upsert(
          const CadSceneEntity(
            id: 'line-1',
            kind: CadSceneEntityKind.sketch,
            geometry: {
              'points': [
                [-1.0, 0.0, 0.0],
                [1.0, 0.0, 0.0],
              ],
            },
          ),
        );
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      );
      Offset? creationClick;
      CadViewportPick? entityPick;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: ProfessionalCadViewportWidget(
              scene: scene,
              camera: camera,
              onSketchTap: (position) => creationClick = position,
              onSketchEntityPick: (pick) {
                entityPick = pick;
                scene.select({pick.entityId});
              },
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tapAt(const Offset(400, 300));
      await tester.pump();

      expect(entityPick?.entityId, 'line-1');
      expect(creationClick, isNull);
      expect(scene.find('line-1')!.selected, isTrue);
    },
  );

  testWidgets('Sketch entity click does not open an empty drag transaction', (
    tester,
  ) async {
    final scene = CadSceneGraph()
      ..upsert(
        const CadSceneEntity(
          id: 'line-1',
          kind: CadSceneEntityKind.sketch,
          geometry: {
            'points': [
              [-1.0, 0.0, 0.0],
              [1.0, 0.0, 0.0],
            ],
          },
        ),
      );
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    );
    var starts = 0;
    var updates = 0;
    var ends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: ProfessionalCadViewportWidget(
            scene: scene,
            camera: camera,
            onSketchEntityDragStart: (_, _) => starts += 1,
            onSketchEntityDragUpdate: (_) => updates += 1,
            onSketchEntityDragEnd: (_) => ends += 1,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tapAt(const Offset(400, 300));
    await tester.pump();

    expect(starts, 0);
    expect(updates, 0);
    expect(ends, 0);
  });

  testWidgets('Sketch mode keeps two-pointer pinch zoom available', (
    tester,
  ) async {
    final scene = CadSceneGraph();
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: ProfessionalCadViewportWidget(
            scene: scene,
            camera: camera,
            enablePicking: false,
            onSketchTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    final scaleBeforePinch = camera.viewScale;
    final first = await tester.startGesture(
      const Offset(360, 300),
      pointer: 51,
    );
    final second = await tester.startGesture(
      const Offset(440, 300),
      pointer: 52,
    );
    await first.moveTo(const Offset(320, 300));
    await second.moveTo(const Offset(480, 300));
    await tester.pump();
    await first.up();
    await second.up();

    expect(camera.viewScale, isNot(scaleBeforePinch));
  });

  testWidgets('double click on a graphical dimension opens its editor route', (
    tester,
  ) async {
    final scene = CadSceneGraph()
      ..upsert(
        const CadSceneEntity(
          id: 'dimension-1',
          kind: CadSceneEntityKind.sketch,
          geometry: {
            'points': [
              [-1.0, 0.0, 0.0],
              [1.0, 0.0, 0.0],
            ],
            'dimensionLabel': '10.000',
            'labelPosition': [0.0, 0.0, 0.0],
          },
        ),
      );
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    );
    CadViewportPick? doublePick;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: ProfessionalCadViewportWidget(
            scene: scene,
            camera: camera,
            onSketchEntityDoublePick: (pick) => doublePick = pick,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();

    expect(doublePick?.entityId, 'dimension-1');
  });

  testWidgets(
    'Sketch support selection picks a plane without changing camera state',
    (tester) async {
      final scene = CadSceneGraph()
        ..upsert(
          const CadSceneEntity(
            id: 'project:world:xy-plane',
            kind: CadSceneEntityKind.plane,
            geometry: {
              'type': 'plane',
              'origin': [0, 0, 0],
              'normal': [0, 0, 1],
              'visualSize': 60,
            },
          ),
        );
      final camera = CadCameraController(
        eye: const Vector3(4, -6, 8),
        target: Vector3.zero,
        up: const Vector3(0, 0, 1),
      )..resize(800, 600);
      final before = camera.snapshot();
      CadViewportPick? support;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: ProfessionalCadViewportWidget(
              scene: scene,
              camera: camera,
              enablePicking: false,
              onSketchSupportPick: (pick) => support = pick,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tapAt(const Offset(400, 300));
      await tester.pump();

      expect(support?.entityId, 'project:world:xy-plane');
      expect(camera.eye.distanceTo(before.eye), lessThan(1e-12));
      expect(camera.target.distanceTo(before.target), lessThan(1e-12));
      expect(camera.up.distanceTo(before.up), lessThan(1e-12));
      expect(camera.viewScale, before.viewScale);
      expect(camera.projectionMode, before.projectionMode);
    },
  );

  testWidgets('a continuous wheel sequence keeps one stable anchor', (
    tester,
  ) async {
    final scene = CadSceneGraph()
      ..upsert(
        MeshSceneAdapter.fromKernel(
          id: 'mesh-1',
          geometry: mesh,
          bounds: bounds,
        ),
      );
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: ProfessionalCadViewportWidget(scene: scene, camera: camera),
        ),
      ),
    );
    await tester.pump();
    const firstPosition = Offset(400, 300);
    const secondPosition = Offset(420, 300);

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: firstPosition,
        scrollDelta: Offset(0, -120),
      ),
    );
    final firstAnchor = camera.focusPoint;
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: secondPosition,
        scrollDelta: Offset(0, -120),
      ),
    );

    expect(camera.focusPoint.distanceTo(firstAnchor), lessThan(1e-12));
  });

  test('operational controller coordinates picking and recognition', () async {
    final cad = DesktopCadController(
      kernels: KernelManager(),
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
    );
    addTearDown(controller.dispose);
    addTearDown(cad.dispose);
    const handle = KernelMeshHandle(
      persistentId: 'mesh',
      kernelId: 'kernel',
      fingerprint: 'fingerprint',
      vertexCount: 3,
      triangleCount: 1,
      bounds: bounds,
      hasNormals: false,
      metadata: {},
    );
    const document = ImportedCadDocument(
      id: 'document',
      projectId: 'project',
      sourcePath: r'C:\Imports\CALOTA_INOXX.StL',
      format: CadImportFormat.stl,
      registeredPath: 'CAD/part.stl',
      validation: [],
      mesh: handle,
    );
    final runtimeDirectory = await Directory.systemTemp.createTemp(
      'flcad-runtime-',
    );
    addTearDown(() => runtimeDirectory.delete(recursive: true));
    await cad.runtime.open('project', runtimeDirectory);
    await cad.runtime.registerImport(document, geometry: mesh);
    final importedEntity = cad.runtime.document!.entities['document']!;
    expect(importedEntity.data['name'], 'CALOTA_INOXX.StL');
    expect(importedEntity.data['originalFileName'], 'CALOTA_INOXX.StL');
    await controller.recognizePick(
      pick: const CadViewportPick(
        entityId: 'mesh-1',
        hit: MeshHit(triangleIndex: 0, point: Vector3.zero, distance: 5),
      ),
    );
    expect(controller.error, isNull);
    expect(controller.hypotheses, isNotEmpty);
    final id = controller.hypotheses.first.recognition.id;
    controller.decide(id, RecognitionDecision.accepted);
    expect(controller.decisions[id], RecognitionDecision.accepted);
    await cad.runtime.registerImport(document, geometry: mesh);
    final importNames = cad.runtime.document!.entities.values
        .where((entity) => entity.kind == CadDocumentEntityKind.import)
        .map((entity) => entity.data['name'])
        .toList();
    expect(
      importNames,
      containsAll(['CALOTA_INOXX.StL', 'CALOTA_INOXX 1.StL']),
    );
    expect(
      cad.runtime.document!.entities.values
          .where((entity) => entity.kind == CadDocumentEntityKind.import)
          .map((entity) => entity.data['originalFileName'])
          .toSet(),
      {'CALOTA_INOXX.StL'},
    );
  });

  test('operational controller completes rectangle to CAD surface', () async {
    final root = await Directory.systemTemp.createTemp('flcad_g102_');
    addTearDown(() => root.delete(recursive: true));
    final projects = ProjectRepository(
      storage: LocalStorageService(rootDirectory: root),
    );
    final projectDirectory = await projects.directoryFor('project');
    final references = ReferenceRepository(projects: projects);
    await references.save('project', [_planeReference]);
    final registeredStl = File(
      '${projectDirectory.path}${Platform.pathSeparator}CAD${Platform.pathSeparator}Imports${Platform.pathSeparator}part.stl',
    );
    await registeredStl.parent.create(recursive: true);
    await registeredStl.writeAsString('solid restored\nendsolid restored');
    final importHistory = File(
      '${projectDirectory.path}${Platform.pathSeparator}CAD${Platform.pathSeparator}ImportHistory${Platform.pathSeparator}history.jsonl',
    );
    await importHistory.parent.create(recursive: true);
    await importHistory.writeAsString(
      '${jsonEncode({'sourcePath': 'original.stl', 'registeredPath': registeredStl.path, 'format': 'stl', 'validation': <String>[]})}\n',
    );
    final referenceApi = ReferenceApi(
      engine: ReferenceEngine(repository: references),
    );
    final kernels = KernelManager()
      ..register(_OperationalSurfaceKernel(), makeDefault: true);
    final cad = DesktopCadController(
      kernels: kernels,
      projects: ProjectManager.instance,
      projectRepository: projects,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
      repository: projects,
    );
    expect(
      commands.registry.commands.map((command) => command.id),
      contains('workspace.sketch'),
    );
    await commands.dispatch('workspace.sketch');
    expect(commands.workspace.state.workspace, 'Sketch');
    await cad.restoreProjectGeometry('project');
    expect(cad.document?.isMesh, isTrue);
    expect(cad.meshGeometry?.triangles, [0, 1, 2]);
    final scene = cad.runtime.scene;
    final controller = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
      referenceApi: referenceApi,
    );
    addTearDown(controller.dispose);
    addTearDown(cad.dispose);
    await controller.configureProject(
      projectId: 'project',
      projectDirectory: projectDirectory,
    );
    controller.activeContext = BridgeContext(
      projectId: 'project',
      meshId: 'mesh',
      meshFingerprint: 'fingerprint',
      userConfirmed: true,
      region: MeshRegion(
        id: 'region',
        meshId: 'mesh',
        triangleIndices: const [0],
        vertexIndices: const [0, 1, 2],
        points: const [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)],
        normals: const [Vector3(0, 0, 1)],
        bounds: bounds,
        area: .5,
        connectivity: const {0: {}},
        fingerprint: 'region-fingerprint',
      ),
    );
    expect(scene.find(_planeReference.id), isNotNull);
    await controller.openSketch();
    await controller.drawRectangle(
      const SketchVector(-2, -1),
      const SketchVector(2, 1),
    );
    await controller.constrainRectangle();
    await controller.finishSketch();
    await controller.previewPlanarSurface();
    expect(scene.find('surface-preview'), isNotNull);
    await controller.confirmSurface();
    expect(controller.error, isNull);
    expect(controller.activeSurface?.valid, isTrue);
    expect(scene.find(controller.activeSurface!.surfaceId), isNotNull);
    await controller.undo();
    expect(scene.find(controller.activeSurface!.surfaceId), isNull);
    await controller.redo();
    expect(scene.find(controller.activeSurface!.surfaceId), isNotNull);
    await controller.persist();
    final reopenedScene = cad.runtime.scene;
    final reopened = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
      referenceApi: ReferenceApi(
        engine: ReferenceEngine(repository: references),
      ),
    );
    addTearDown(reopened.dispose);
    await reopened.configureProject(
      projectId: 'project',
      projectDirectory: projectDirectory,
    );
    expect(reopened.sketchEntities, hasLength(4));
    expect(reopened.activeSurface?.handle, controller.activeSurface?.handle);
    expect(reopened.activeReference?.id, _planeReference.id);
    expect(reopenedScene.find(_planeReference.id), isNotNull);
    expect(reopenedScene.find(controller.activeSurface!.surfaceId), isNotNull);
  });
}

final _planeReference = ReferenceEntity(
  id: 'plane-reference',
  projectId: 'project',
  name: 'Base Plane',
  geometry: const PlaneGeometry(Vec3(0, 0, 0), Vec3(0, 0, 1)),
  mode: ReferenceMode.staticReference,
  status: ReferenceStatus.valid,
  dna: const ReferenceDNA('plane', 'region', 'z0', 'hash'),
  analytics: const ReferenceAnalytics(
    precision: 1,
    rmsError: 0,
    maxDeviation: 0,
    confidence: 1,
    fitQuality: 1,
    areaUsed: 1,
    coverage: 1,
    pointCount: 3,
  ),
  recipe: const ReferenceRecipe('plane', {}, ['region']),
  version: 1,
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  dependencies: const ['region'],
  metadata: const {},
);

class _OperationalSurfaceKernel
    implements
        GeometryKernelAPI,
        MeshGeometryKernelAPI,
        SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'g102-test',
    name: 'G-102 contract kernel',
    version: '1',
    capabilities: KernelCapabilities({KernelCapability.planeSurface}),
    vendor: 'FLCAD',
  );
  @override
  Future<KernelHealth> healthCheck() async =>
      KernelHealth(KernelHealthStatus.healthy, 'ok', DateTime(2000));
  @override
  Future<void> begin(KernelTransaction transaction) async {}
  @override
  Future<void> commit(KernelTransaction transaction) async {}
  @override
  Future<void> rollback(KernelTransaction transaction) async {}
  @override
  Future<void> unload() async {}
  @override
  Future<ShapeHandle> create(
    String operation,
    Map<String, dynamic> parameters, {
    required String persistentId,
    required CADShapeType expectedType,
    required KernelTransaction transaction,
  }) async => ShapeHandle.reference(
    persistentId: persistentId,
    kernelId: descriptor.id,
    type: expectedType,
    fingerprint: 'surface-fingerprint',
  );
  @override
  Future<List<String>> validate(ShapeHandle handle, Set<String> checks) async =>
      const [];
  @override
  Future<KernelMeshHandle> importStl(
    String path, {
    required String projectId,
    KernelImportFormat format = KernelImportFormat.autoDetect,
    KernelCancellationToken cancellation = const NoKernelCancellation(),
    void Function(KernelProgress progress)? onProgress,
  }) async => const KernelMeshHandle(
    persistentId: 'restored-mesh',
    kernelId: 'g102-test',
    fingerprint: 'restored-fingerprint',
    vertexCount: 3,
    triangleCount: 1,
    bounds: KernelBounds(-1, -1, 0, 1, 1, 0),
    hasNormals: false,
    metadata: {},
  );
  @override
  Future<KernelMeshGeometry> inspectMesh(KernelMeshHandle handle) async =>
      const KernelMeshGeometry(
        nodes: [-1, -1, 0, 1, -1, 0, 0, 1, 0],
        triangles: [0, 1, 2],
      );
  @override
  Future<void> closeMesh(KernelMeshHandle handle) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
