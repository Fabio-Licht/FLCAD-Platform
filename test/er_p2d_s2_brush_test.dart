import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/professional_cad_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_scene_adapter.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/cad_selection_palette.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_context.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/editable_surface_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/mesh_bvh.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/mesh_region_builder.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/surface_selection_engine.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/surface_selection_policy.dart';
import 'package:flcad_mobile/app/engineering_bridge/widgets/recognition_workspace_panel.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/import_export/api/import_export_api.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/test_output_path.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'visible-only rejects occluded back layers while through-mesh sees them',
    () {
      final geometry = _twoLayerGeometry();
      final selection = _selectionFor(geometry);
      final bvh = MeshBvh(geometry);
      final seed = 0;
      final center = triangleCentroid(geometry, seed);
      final frontCount = _gridTriangleCount;

      final visible = const SurfaceSelectionEngine().collect(
        geometry: geometry,
        bvh: bvh,
        tool: SphereSelectionTool(center: center, radius: 6),
        seedTriangle: seed,
        cameraOrigin: const Vector3(2.5, 2.5, 10),
        visibility: SelectionVisibilityPolicy.visibleOnly,
        connectivity: SelectionConnectivityPolicy.connectedSurface,
        neighborsOf: selection.neighborsOf,
      );
      expect(visible.triangles, isNotEmpty);
      expect(
        visible.triangles.every((triangle) => triangle < frontCount),
        isTrue,
      );
      expect(visible.occludedCandidates, greaterThan(0));

      final through = const SurfaceSelectionEngine().collect(
        geometry: geometry,
        bvh: bvh,
        tool: SphereSelectionTool(center: center, radius: 6),
        seedTriangle: seed,
        cameraOrigin: const Vector3(2.5, 2.5, 10),
        visibility: SelectionVisibilityPolicy.throughMesh,
        connectivity: SelectionConnectivityPolicy.local,
        neighborsOf: selection.neighborsOf,
      );
      expect(
        through.triangles.any((triangle) => triangle >= frontCount),
        isTrue,
      );

      final throughConnected = const SurfaceSelectionEngine().collect(
        geometry: geometry,
        bvh: bvh,
        tool: SphereSelectionTool(center: center, radius: 6),
        seedTriangle: seed,
        cameraOrigin: const Vector3(2.5, 2.5, 10),
        visibility: SelectionVisibilityPolicy.throughMesh,
        connectivity: SelectionConnectivityPolicy.connectedSurface,
        neighborsOf: selection.neighborsOf,
      );
      expect(
        throughConnected.triangles.any((triangle) => triangle >= frontCount),
        isFalse,
      );
    },
  );

  test('camera rotation changes which layer is visible', () {
    final geometry = _twoLayerGeometry(reverseBack: true);
    final selection = _selectionFor(geometry);
    final bvh = MeshBvh(geometry);
    const frontSeed = 0;
    final backSeed = _gridTriangleCount;

    final fromAbove = const SurfaceSelectionEngine().collect(
      geometry: geometry,
      bvh: bvh,
      tool: SphereSelectionTool(
        center: triangleCentroid(geometry, frontSeed),
        radius: 6,
      ),
      seedTriangle: frontSeed,
      cameraOrigin: const Vector3(2.5, 2.5, 10),
      visibility: SelectionVisibilityPolicy.visibleOnly,
      connectivity: SelectionConnectivityPolicy.connectedSurface,
      neighborsOf: selection.neighborsOf,
    );
    expect(
      fromAbove.triangles.every((triangle) => triangle < _gridTriangleCount),
      isTrue,
    );

    final fromBelow = const SurfaceSelectionEngine().collect(
      geometry: geometry,
      bvh: bvh,
      tool: SphereSelectionTool(
        center: triangleCentroid(geometry, backSeed),
        radius: 6,
      ),
      seedTriangle: backSeed,
      cameraOrigin: const Vector3(2.5, 2.5, -10),
      visibility: SelectionVisibilityPolicy.visibleOnly,
      connectivity: SelectionConnectivityPolicy.connectedSurface,
      neighborsOf: selection.neighborsOf,
    );
    expect(
      fromBelow.triangles.any((triangle) => triangle >= _gridTriangleCount),
      isTrue,
    );
  });

  test('back-facing triangles are not painted in visible-only mode', () {
    final geometry = _reverseWinding(_gridGeometry());
    final selection = _selectionFor(geometry);
    final seed = 0;
    final result = const SurfaceSelectionEngine().collect(
      geometry: geometry,
      bvh: MeshBvh(geometry),
      tool: SphereSelectionTool(
        center: triangleCentroid(geometry, seed),
        radius: 5,
      ),
      seedTriangle: seed,
      cameraOrigin: const Vector3(2.5, 2.5, 10),
      visibility: SelectionVisibilityPolicy.visibleOnly,
      connectivity: SelectionConnectivityPolicy.connectedSurface,
      neighborsOf: selection.neighborsOf,
    );
    expect(result.triangles, {seed});
    expect(result.backfaceCandidates, greaterThan(0));
  });

  test('connected policy does not jump to a nearby disconnected island', () {
    final geometry = _twoIslandGeometry();
    final selection = _selectionFor(geometry);
    final bvh = MeshBvh(geometry);
    final seed = 0;
    final center = triangleCentroid(geometry, seed);

    final connected = const SurfaceSelectionEngine().collect(
      geometry: geometry,
      bvh: bvh,
      tool: SphereSelectionTool(center: center, radius: 9),
      seedTriangle: seed,
      cameraOrigin: const Vector3(2.5, 2.5, 10),
      visibility: SelectionVisibilityPolicy.throughMesh,
      connectivity: SelectionConnectivityPolicy.connectedSurface,
      neighborsOf: selection.neighborsOf,
    );
    final local = const SurfaceSelectionEngine().collect(
      geometry: geometry,
      bvh: bvh,
      tool: SphereSelectionTool(center: center, radius: 9),
      seedTriangle: seed,
      cameraOrigin: const Vector3(2.5, 2.5, 10),
      visibility: SelectionVisibilityPolicy.throughMesh,
      connectivity: SelectionConnectivityPolicy.local,
      neighborsOf: selection.neighborsOf,
    );
    expect(
      connected.triangles.every((triangle) => triangle < _gridTriangleCount),
      isTrue,
    );
    expect(
      local.triangles.any((triangle) => triangle >= _gridTriangleCount),
      isTrue,
    );
  });

  test('closed mesh front and back faces obey the visibility policy', () {
    final geometry = _boxGeometry();
    final selection = _selectionFor(geometry);
    final bvh = MeshBvh(geometry);
    const seed = 0;
    final center = triangleCentroid(geometry, seed);
    const backFace = {2, 3};
    final camera = CadCameraController(
      eye: Vector3(center.x, center.y, 10),
      target: center,
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);

    final visible = const SurfaceSelectionEngine().collect(
      geometry: geometry,
      bvh: bvh,
      tool: SphereSelectionTool(center: center, radius: 3),
      seedTriangle: seed,
      cameraOrigin: const Vector3(0.5, 0.5, 10),
      visibility: SelectionVisibilityPolicy.visibleOnly,
      connectivity: SelectionConnectivityPolicy.connectedSurface,
      neighborsOf: selection.neighborsOf,
    );
    expect(visible.triangles.intersection(backFace), isEmpty);

    final through = const SurfaceSelectionEngine().collect(
      geometry: geometry,
      bvh: bvh,
      tool: ProjectedBrushTool(
        ray: MeshRay(camera.eye, (center - camera.eye).normalized),
        referencePoint: center,
        radiusMm: 3,
        orthographic: false,
        viewProjection: camera.viewProjectionMatrix,
        viewportWidth: 800,
        viewportHeight: 600,
        centerScreen: Offset(
          (camera.viewProjectionMatrix.transformPoint(center).x + 1) * 400,
          (1 - camera.viewProjectionMatrix.transformPoint(center).y) * 300,
        ),
        radiusPx: brushCursorRadiusPixels(
          camera: camera,
          point: center,
          radiusWorld: 3,
        ),
      ),
      seedTriangle: seed,
      cameraOrigin: camera.eye,
      visibility: SelectionVisibilityPolicy.throughMesh,
      connectivity: SelectionConnectivityPolicy.local,
      neighborsOf: selection.neighborsOf,
    );
    expect(through.triangles.containsAll(backFace), isTrue);
  });

  test(
    'projected through-mesh volume reaches a plate beyond the sphere radius',
    () {
      final geometry = _twoLayerGeometry(backZ: -10);
      final selection = _selectionFor(geometry);
      final bvh = MeshBvh(geometry);
      const seed = 24;
      final reference = triangleCentroid(geometry, seed);
      final camera = CadCameraController(
        eye: reference + const Vector3(0, 0, 10),
        target: reference,
        up: const Vector3(0, 1, 0),
      )..resize(800, 600);
      final ndc = camera.viewProjectionMatrix.transformPoint(reference);
      final centerScreen = Offset((ndc.x + 1) * 400, (1 - ndc.y) * 300);
      final radiusPx = brushCursorRadiusPixels(
        camera: camera,
        point: reference,
        radiusWorld: 2,
      );
      ProjectedBrushTool tool({required bool orthographic}) =>
          ProjectedBrushTool(
            ray: MeshRay(camera.eye, (reference - camera.eye).normalized),
            referencePoint: reference,
            radiusMm: 2,
            orthographic: orthographic,
            viewProjection: camera.viewProjectionMatrix,
            viewportWidth: 800,
            viewportHeight: 600,
            centerScreen: centerScreen,
            radiusPx: radiusPx,
          );

      final through = const SurfaceSelectionEngine().collect(
        geometry: geometry,
        bvh: bvh,
        tool: tool(orthographic: false),
        seedTriangle: seed,
        cameraOrigin: camera.eye,
        visibility: SelectionVisibilityPolicy.throughMesh,
        connectivity: SelectionConnectivityPolicy.local,
        neighborsOf: selection.neighborsOf,
      );
      expect(
        through.triangles.any((triangle) => triangle >= _gridTriangleCount),
        isTrue,
      );

      final connected = const SurfaceSelectionEngine().collect(
        geometry: geometry,
        bvh: bvh,
        tool: tool(orthographic: false),
        seedTriangle: seed,
        cameraOrigin: camera.eye,
        visibility: SelectionVisibilityPolicy.throughMesh,
        connectivity: SelectionConnectivityPolicy.connectedSurface,
        neighborsOf: selection.neighborsOf,
      );
      expect(
        connected.triangles.any((triangle) => triangle >= _gridTriangleCount),
        isFalse,
      );

      final visible = const SurfaceSelectionEngine().collect(
        geometry: geometry,
        bvh: bvh,
        tool: SphereSelectionTool(center: reference, radius: 2),
        seedTriangle: seed,
        cameraOrigin: camera.eye,
        visibility: SelectionVisibilityPolicy.visibleOnly,
        connectivity: SelectionConnectivityPolicy.local,
        neighborsOf: selection.neighborsOf,
      );
      expect(
        visible.triangles.any((triangle) => triangle >= _gridTriangleCount),
        isFalse,
      );

      camera.toggleProjection();
      final orthoNdc = camera.viewProjectionMatrix.transformPoint(reference);
      final orthoCenter = Offset(
        (orthoNdc.x + 1) * 400,
        (1 - orthoNdc.y) * 300,
      );
      final orthoRadius = brushCursorRadiusPixels(
        camera: camera,
        point: reference,
        radiusWorld: 2,
      );
      final orthoTool = ProjectedBrushTool(
        ray: MeshRay(camera.eye, (reference - camera.eye).normalized),
        referencePoint: reference,
        radiusMm: 2,
        orthographic: true,
        viewProjection: camera.viewProjectionMatrix,
        viewportWidth: 800,
        viewportHeight: 600,
        centerScreen: orthoCenter,
        radiusPx: orthoRadius,
      );
      final orthographic = const SurfaceSelectionEngine().collect(
        geometry: geometry,
        bvh: bvh,
        tool: orthoTool,
        seedTriangle: seed,
        cameraOrigin: camera.eye,
        visibility: SelectionVisibilityPolicy.throughMesh,
        connectivity: SelectionConnectivityPolicy.local,
        neighborsOf: selection.neighborsOf,
      );
      expect(
        orthographic.triangles.any(
          (triangle) => triangle >= _gridTriangleCount,
        ),
        isTrue,
      );
    },
  );

  test(
    'controller paints a continuous brush stroke into fitting and history',
    () async {
      final geometry = _gridGeometry();
      final harness = await _BrushHarness.create(
        geometry: geometry,
        initialTriangles: const {0, 1, 3},
      );
      addTearDown(harness.dispose);

      await harness.controller.detectAutomatically();
      final initialCount = harness.controller.selectionTriangleCount;
      final seed = _adjacentTriangle(harness.controller);
      harness.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
      harness.controller.setBrushDiameterMm(3);
      harness.controller.setBrushConnectivity(
        SelectionConnectivityPolicy.connectedSurface,
      );

      await harness.controller.startBrushStroke(
        _pick(geometry, seed, camera: const Vector3(2.5, 2.5, 10)),
      );
      final beforeForeignPick = harness.controller.selectionTriangleCount;
      await harness.controller.addBrushSample(
        CadViewportPick(
          entityId: 'other',
          hit: MeshHit(
            triangleIndex: seed,
            point: triangleCentroid(geometry, seed),
            distance: 1,
          ),
        ),
      );
      expect(harness.controller.selectionTriangleCount, beforeForeignPick);
      final second = _adjacentTriangle(harness.controller, exclude: {seed});
      await harness.controller.addBrushSample(
        _pick(geometry, second, camera: const Vector3(2.5, 2.5, 10)),
      );
      await harness.controller.finishBrushStroke();

      expect(
        harness.controller.selectionTriangleCount,
        greaterThan(initialCount),
      );
      expect(harness.controller.selectionIsEdited, isTrue);
      expect(harness.controller.canUndoSelectionEdit, isTrue);
      expect(harness.commands.manager.canUndo, isFalse);
      expect(harness.controller.activeRecognitionResult, isNotNull);
      expect(
        harness.controller.activeContext!.region!.triangleIndices.toSet(),
        harness.controller.editableSelection!.currentTriangles,
      );

      final paintedCount = harness.controller.selectionTriangleCount;
      await harness.controller.undoRecognitionSelection();
      expect(harness.controller.selectionTriangleCount, initialCount);
      await harness.controller.redoRecognitionSelection();
      expect(harness.controller.selectionTriangleCount, paintedCount);

      harness.controller.setSelectionTool(RecognitionSelectionTool.brushRemove);
      harness.controller.setBrushDiameterMm(2);
      final removeSeed = harness.controller.selectionTriangleCount > 0
          ? harness.controller.editableSelection!.currentTriangles.first
          : 0;
      await harness.controller.startBrushStroke(
        _pick(geometry, removeSeed, camera: const Vector3(2.5, 2.5, 10)),
      );
      await harness.controller.finishBrushStroke();
      expect(harness.controller.selectionTriangleCount, lessThan(paintedCount));
      final removedCount = harness.controller.selectionTriangleCount;
      await harness.controller.undoRecognitionSelection();
      expect(harness.controller.selectionTriangleCount, paintedCount);
      await harness.controller.redoRecognitionSelection();
      expect(harness.controller.selectionTriangleCount, removedCount);
    },
  );

  test(
    'cancelling a stroke restores selection and creates no history entry',
    () async {
      final geometry = _gridGeometry();
      final harness = await _BrushHarness.create(
        geometry: geometry,
        initialTriangles: const {0, 1, 3},
      );
      addTearDown(harness.dispose);
      await harness.controller.detectAutomatically();
      final initialCount = harness.controller.selectionTriangleCount;
      final seed = _adjacentTriangle(harness.controller);
      harness.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
      harness.controller.setBrushDiameterMm(3);
      await harness.controller.startBrushStroke(
        _pick(geometry, seed, camera: const Vector3(2.5, 2.5, 10)),
      );
      expect(
        harness.controller.selectionTriangleCount,
        greaterThan(initialCount),
      );
      expect(harness.controller.cancelBrushStroke(), isTrue);
      expect(harness.controller.selectionTriangleCount, initialCount);
      expect(harness.controller.canUndoSelectionEdit, isFalse);
      expect(harness.controller.brushStrokeActive, isFalse);
    },
  );

  test('a stroke records every spatial sample', () async {
    final geometry = _gridGeometry();
    final harness = await _BrushHarness.create(
      geometry: geometry,
      initialTriangles: const {0, 1, 2, 3, 4, 5, 6, 7, 8, 9},
    );
    addTearDown(harness.dispose);
    await harness.controller.detectAutomatically();
    final selection = harness.controller.editableSelection!;
    final current = {...selection.currentTriangles};
    final boundary =
        current
            .map(selection.neighborsOf)
            .expand((values) => values)
            .where((triangle) => !current.contains(triangle))
            .toSet()
            .toList()
          ..sort();
    expect(boundary.length, greaterThanOrEqualTo(4));
    harness.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
    harness.controller.setBrushDiameterMm(1.5);
    await harness.controller.startBrushStroke(
      _pick(geometry, boundary[0], camera: const Vector3(2.5, 2.5, 10)),
    );
    for (final triangle in boundary.skip(1).take(3)) {
      await harness.controller.addBrushSample(
        _pick(geometry, triangle, camera: const Vector3(2.5, 2.5, 10)),
      );
    }
    expect(harness.controller.brushSampleCount, 4);
    await harness.controller.finishBrushStroke();
  });

  test(
    'selection preview updates during pointer move and survives fitting',
    () async {
      final geometry = _gridGeometry();
      final harness = await _BrushHarness.create(
        geometry: geometry,
        initialTriangles: const {0, 1, 3},
      );
      addTearDown(harness.dispose);
      await harness.controller.detectAutomatically();
      final seed = _adjacentTriangle(harness.controller);
      harness.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
      harness.controller.setBrushDiameterMm(3);
      await harness.controller.startBrushStroke(
        _pick(geometry, seed, camera: const Vector3(2.5, 2.5, 10)),
      );
      final preview = harness.cad.runtime.scene.find(
        'recognition-region-preview',
      )!;
      expect(preview.geometry['selectionPreview'], isTrue);
      expect(preview.geometry['rootLinearRgb'], kCadSelectionLinearRgb);
      expect(preview.geometry['topologicalEdges'], isNotEmpty);
      expect(
        (preview.geometry['nodes'] as List).length,
        lessThan(geometry.nodes.length),
      );
      final countAfterDown = preview.geometry['triangleCount'] as int;
      expect(countAfterDown, harness.controller.selectionTriangleCount);

      final second = _adjacentTriangle(harness.controller, exclude: {seed});
      await harness.controller.addBrushSample(
        _pick(geometry, second, camera: const Vector3(2.5, 2.5, 10)),
      );
      final moved = harness.cad.runtime.scene.find(
        'recognition-region-preview',
      )!;
      expect(
        moved.geometry['triangleCount'] as int,
        greaterThanOrEqualTo(countAfterDown),
      );

      await harness.controller.finishBrushStroke();
      final fitted = harness.cad.runtime.scene.find(
        'recognition-region-preview',
      );
      expect(fitted, isNotNull);
      expect(fitted!.geometry['selectionPreview'], isTrue);
      expect(harness.controller.activeRecognitionResult, isNotNull);
      final afterFitCount = fitted.geometry['triangleCount'] as int;

      harness.controller.setSelectionTool(RecognitionSelectionTool.brushRemove);
      harness.controller.setBrushDiameterMm(2);
      final removeSeed =
          harness.controller.editableSelection!.currentTriangles.first;
      await harness.controller.startBrushStroke(
        _pick(geometry, removeSeed, camera: const Vector3(2.5, 2.5, 10)),
      );
      final removedPreview = harness.cad.runtime.scene.find(
        'recognition-region-preview',
      )!;
      expect(
        removedPreview.geometry['triangleCount'] as int,
        lessThan(afterFitCount),
      );
      await harness.controller.finishBrushStroke();
    },
  );

  test('a new selection cancels an active stroke', () async {
    final geometry = _gridGeometry();
    final harness = await _BrushHarness.create(
      geometry: geometry,
      initialTriangles: const {0, 1, 3},
    );
    addTearDown(harness.dispose);
    await harness.controller.detectAutomatically();
    final seed = _adjacentTriangle(harness.controller);
    harness.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
    await harness.controller.startBrushStroke(
      _pick(geometry, seed, camera: const Vector3(2.5, 2.5, 10)),
    );
    await harness.controller.recognizePick(
      pick: _pick(geometry, 30, camera: const Vector3(2.5, 2.5, 10)),
      allowTechnicalStl: false,
    );
    expect(harness.controller.brushStrokeActive, isFalse);
    expect(harness.controller.hasEditableSelection, isTrue);
    expect(harness.controller.canUndoSelectionEdit, isFalse);
    await harness.controller.finishBrushStroke();
    expect(harness.controller.brushStrokeActive, isFalse);
  });

  test('brush preserves directed plane mode and updates fitting', () async {
    final geometry = _gridGeometry();
    final harness = await _BrushHarness.create(
      geometry: geometry,
      initialTriangles: const {0, 1, 3},
    );
    addTearDown(harness.dispose);
    await harness.controller.detectAutomatically();
    await harness.controller.recognizeDirected(PrimitiveType.plane);
    harness.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
    harness.controller.setBrushDiameterMm(2.5);
    final seed = _adjacentTriangle(harness.controller);
    await harness.controller.startBrushStroke(
      _pick(geometry, seed, camera: const Vector3(2.5, 2.5, 10)),
    );
    await harness.controller.finishBrushStroke();
    expect(
      harness.controller.requestedRecognitionPrimitive,
      PrimitiveType.plane,
    );
    expect(harness.controller.activeRecognitionResult?.type.name, 'plane');
    expect(
      harness
          .controller
          .activeRecognitionResult!
          .parameters['planarClassification'],
      'planarCadCandidate',
    );
    expect(
      harness
          .controller
          .activeRecognitionResult!
          .parameters['cadSurfaceApproved'],
      isTrue,
    );
  });

  test(
    'through-mesh hidden faces are undoable and never authorize stale CAD',
    () async {
      final geometry = _twoLayerGeometry(backZ: -10);
      final harness = await _BrushHarness.create(
        geometry: geometry,
        initialTriangles: const {0, 1, 3},
      );
      addTearDown(harness.dispose);
      await harness.controller.detectAutomatically();
      final seed = _adjacentTriangle(harness.controller);
      harness.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
      harness.controller.setBrushDiameterMm(4);
      harness.controller.setBrushVisibility(
        SelectionVisibilityPolicy.throughMesh,
      );
      harness.controller.setBrushConnectivity(
        SelectionConnectivityPolicy.local,
      );
      final camera = triangleCentroid(geometry, seed) + const Vector3(0, 0, 10);
      await harness.controller.startBrushStroke(
        _pick(geometry, seed, camera: camera),
      );
      await harness.controller.finishBrushStroke();
      final hiddenSelection = {
        ...harness.controller.editableSelection!.currentTriangles,
      };
      expect(
        hiddenSelection.any((triangle) => triangle >= _gridTriangleCount),
        isTrue,
      );
      final hiddenResult = harness.controller.activeRecognitionResult;
      expect(hiddenResult, isNotNull);
      expect(
        hiddenResult!.parameters['selectionComponentCount'],
        greaterThan(1),
      );
      if (hiddenResult.type.name == 'plane') {
        expect(hiddenResult.parameters['planarClassification'], 'ambiguous');
        expect(hiddenResult.parameters['cadSurfaceApproved'], isFalse);
        expect(harness.controller.canCreatePlaneReference, isFalse);
      }

      await harness.controller.undoRecognitionSelection();
      expect(
        harness.controller.editableSelection!.currentTriangles.any(
          (triangle) => triangle >= _gridTriangleCount,
        ),
        isFalse,
      );
      expect(harness.controller.activeRecognitionResult, isNotNull);
      await harness.controller.redoRecognitionSelection();
      expect(
        harness.controller.editableSelection!.currentTriangles.any(
          (triangle) => triangle >= _gridTriangleCount,
        ),
        isTrue,
      );
      final redoResult = harness.controller.activeRecognitionResult;
      expect(redoResult, isNotNull);
      expect(redoResult!.parameters['selectionComponentCount'], greaterThan(1));

      final hiddenTriangle = hiddenSelection.firstWhere(
        (triangle) => triangle >= _gridTriangleCount,
      );
      final beforeRemove = harness.controller.selectionTriangleCount;
      harness.controller.setSelectionTool(RecognitionSelectionTool.brushRemove);
      harness.controller.setBrushDiameterMm(2);
      await harness.controller.startBrushStroke(
        _pick(geometry, hiddenTriangle, camera: camera),
      );
      await harness.controller.finishBrushStroke();
      final afterRemove = harness.controller.selectionTriangleCount;
      expect(afterRemove, lessThan(beforeRemove));
      await harness.controller.undoRecognitionSelection();
      expect(harness.controller.selectionTriangleCount, beforeRemove);
      await harness.controller.redoRecognitionSelection();
      expect(harness.controller.selectionTriangleCount, afterRemove);
    },
  );

  test('curved edited region remains curved or ambiguous', () async {
    final geometry = _cylinderPatchGeometry();
    final harness = await _BrushHarness.create(
      geometry: geometry,
      initialTriangles: const {0, 1, 3},
    );
    addTearDown(harness.dispose);
    await harness.controller.detectAutomatically();
    await harness.controller.expandRecognitionSelection();
    await harness.controller.expandRecognitionSelection();
    await harness.controller.recognizeDirected(PrimitiveType.plane);
    final result = harness.controller.activeRecognitionResult!;
    final classification = result.parameters['planarClassification'];
    expect(classification, anyOf('curvedPatch', 'ambiguous'));
    expect(classification, isNot('planarCadCandidate'));
    expect(result.parameters['cadSurfaceApproved'], isFalse);
    expect(harness.controller.canCreatePlaneReference, isFalse);
  });

  test('tessellated prism face stays planarCadCandidate after editing', () async {
    final geometry = _twoLayerGeometry(backZ: -1);
    final harness = await _BrushHarness.create(
      geometry: geometry,
      initialTriangles: const {24, 25},
    );
    addTearDown(harness.dispose);
    await harness.controller.detectAutomatically();
    final initialCount = harness.controller.selectionTriangleCount;
    final initialResult = harness.controller.activeRecognitionResult;
    await harness.controller.expandRecognitionSelection();
    await harness.controller.expandRecognitionSelection();
    await harness.controller.contractRecognitionSelection();
    await harness.controller.recognizeDirected(PrimitiveType.plane);
    final result = harness.controller.activeRecognitionResult!;
    expect(result.parameters['planarClassification'], 'planarCadCandidate');
    expect(result.parameters['cadSurfaceApproved'], isTrue);
    expect(harness.controller.canCreatePlaneReference, isTrue);
    harness.controller.previewActiveRecognition();
    expect(harness.controller.canCreateSurfaceFromAssistant, isTrue);
    harness.controller.ignoreSurfaceAssistantSuggestion();
    final report = StringBuffer()
      ..writeln('ER-P2D-S3 tessellated prism face reclassification')
      ..writeln('mesh_source=two-layer tessellated prism face')
      ..writeln('initial_triangles=$initialCount')
      ..writeln('edited_triangles=${harness.controller.selectionTriangleCount}')
      ..writeln(
        'initial_classification='
        '${initialResult?.parameters['planarClassification']}',
      )
      ..writeln('initial_rms=${initialResult?.parameters['rmsDeviation']}')
      ..writeln(
        'initial_maximum=${initialResult?.parameters['maximumDeviation']}',
      )
      ..writeln('initial_confidence=${initialResult?.confidence}')
      ..writeln(
        'edited_classification='
        '${result.parameters['planarClassification']}',
      )
      ..writeln('edited_rms=${result.parameters['rmsDeviation']}')
      ..writeln('edited_maximum=${result.parameters['maximumDeviation']}')
      ..writeln('edited_confidence=${result.confidence}')
      ..writeln(
        'edited_components=${result.parameters['selectionComponentCount']}',
      )
      ..writeln(
        'cad_surface_approved=${result.parameters['cadSurfaceApproved']}',
      )
      ..writeln(
        'region_build_ms='
        '${(harness.controller.lastRegionBuildMicros / 1000).toStringAsFixed(3)}',
      )
      ..writeln(
        'fitting_ms='
        '${(harness.controller.lastRecognitionMicros / 1000).toStringAsFixed(3)}',
      )
      ..writeln(
        'classification_compute_ms='
        '${(harness.controller.lastClassificationComputeMicros / 1000).toStringAsFixed(3)}',
      )
      ..writeln(
        'publication_ms='
        '${(harness.controller.lastPublishMicros / 1000).toStringAsFixed(3)}',
      )
      ..writeln(
        'classification_cache_hits='
        '${harness.controller.editedClassificationCacheHits}',
      );
    final output = File(testOutputPath(
      r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-S3\er_p2d_s3_prism_report.txt',
    ));
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(report.toString());
  });

  test(
    'edited planar classification is reused for the same selection revision',
    () async {
      final geometry = _gridGeometry();
      final harness = await _BrushHarness.create(
        geometry: geometry,
        initialTriangles: const {0, 1, 3},
      );
      addTearDown(harness.dispose);
      await harness.controller.detectAutomatically();
      await harness.controller.expandRecognitionSelection();
      final seed = harness.controller.editableSelection!.currentTriangles.first;
      harness.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
      await harness.controller.startBrushStroke(
        _pick(geometry, seed, camera: const Vector3(2.5, 2.5, 10)),
      );
      await harness.controller.finishBrushStroke();
      final hitsBefore = harness.controller.editedClassificationCacheHits;
      await harness.controller.recognizeDirected(PrimitiveType.plane);
      expect(
        harness.controller.editedClassificationCacheHits,
        greaterThan(hitsBefore),
      );
    },
  );

  test('diameter in millimetres controls brush reach', () async {
    final geometry = _gridGeometry();
    final harness = await _BrushHarness.create(
      geometry: geometry,
      initialTriangles: const {0, 1, 3},
    );
    addTearDown(harness.dispose);
    await harness.controller.detectAutomatically();
    final seed = _adjacentTriangle(harness.controller);
    harness.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
    harness.controller.setBrushDiameterMm(0.4);
    await harness.controller.startBrushStroke(
      _pick(geometry, seed, camera: const Vector3(2.5, 2.5, 10)),
    );
    await harness.controller.finishBrushStroke();
    final narrowCount = harness.controller.selectionTriangleCount;
    await harness.controller.restoreAutomaticRecognitionSelection();
    harness.controller.setBrushDiameterMm(4);
    await harness.controller.startBrushStroke(
      _pick(geometry, seed, camera: const Vector3(2.5, 2.5, 10)),
    );
    await harness.controller.finishBrushStroke();
    expect(harness.controller.selectionTriangleCount, greaterThan(narrowCount));
  });

  testWidgets(
    'primary drag paints only in brush mode and preserves orbit otherwise',
    (tester) async {
      final scene = CadSceneGraph()
        ..upsert(
          MeshSceneAdapter.fromKernel(
            id: 'mesh-1',
            geometry: _gridGeometry(columns: 4),
            bounds: const KernelBounds(0, 0, 0, 3, 3, 0),
          ),
        );
      final camera = CadCameraController(
        eye: const Vector3(1.5, 1.5, 10),
        target: const Vector3(1.5, 1.5, 0),
        up: const Vector3(0, 1, 0),
      );
      var down = 0;
      var move = 0;
      var up = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: ProfessionalCadViewportWidget(
              scene: scene,
              camera: camera,
              brushActive: true,
              onBrushDown: (_) => down++,
              onBrushMove: (_) => move++,
              onBrushUp: () => up++,
            ),
          ),
        ),
      );
      await tester.pump();
      final eyeBefore = camera.eye;
      final pointer = TestPointer(41, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.down(const Offset(400, 300), buttons: kPrimaryMouseButton),
      );
      await tester.sendEventToBinding(pointer.move(const Offset(440, 300)));
      await tester.sendEventToBinding(pointer.up());
      await tester.pump();
      expect(down, 1);
      expect(move, greaterThan(0));
      expect(up, 1);
      expect((camera.eye - eyeBefore).length, lessThan(1e-9));

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: ProfessionalCadViewportWidget(
              scene: scene,
              camera: camera,
              brushActive: false,
            ),
          ),
        ),
      );
      await tester.pump();
      final eyeBeforeOrbit = camera.eye;
      final orbitPointer = TestPointer(42, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        orbitPointer.down(
          const Offset(400, 300),
          buttons: kMiddleMouseButton | kPrimaryMouseButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 42,
          device: 42,
          kind: PointerDeviceKind.mouse,
          position: Offset(450, 330),
          delta: Offset(50, 30),
          buttons: kMiddleMouseButton | kPrimaryMouseButton,
        ),
      );
      await tester.sendEventToBinding(orbitPointer.up());
      await tester.pump();
      expect((camera.eye - eyeBeforeOrbit).length, greaterThan(1e-3));

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: ProfessionalCadViewportWidget(
              scene: scene,
              camera: camera,
              brushActive: true,
              onBrushDown: (_) => down++,
              onBrushMove: (_) => move++,
              onBrushUp: () => up++,
            ),
          ),
        ),
      );
      await tester.pump();
      final eyeBeforeBrushOrbit = camera.eye;
      final brushOrbitPointer = TestPointer(43, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        brushOrbitPointer.down(
          const Offset(400, 300),
          buttons: kMiddleMouseButton | kPrimaryMouseButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerMoveEvent(
          pointer: 43,
          device: 43,
          kind: PointerDeviceKind.mouse,
          position: Offset(450, 330),
          delta: Offset(50, 30),
          buttons: kMiddleMouseButton | kPrimaryMouseButton,
        ),
      );
      await tester.sendEventToBinding(brushOrbitPointer.up());
      await tester.pump();
      expect((camera.eye - eyeBeforeBrushOrbit).length, greaterThan(1e-3));
    },
  );

  testWidgets('brush panel exposes reach controls and captures diagnostics', (
    tester,
  ) async {
    final harness = (await tester.runAsync(
      () => _BrushHarness.create(
        geometry: _gridGeometry(),
        initialTriangles: const {0, 1, 3},
      ),
    ))!;
    addTearDown(harness.dispose);
    await tester.runAsync(harness.controller.detectAutomatically);
    harness.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
    harness.controller.setBrushDiameterMm(3);
    await tester.binding.setSurfaceSize(const Size(460, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final systemFont = File(r'C:\Windows\Fonts\segoeui.ttf');
    if (systemFont.existsSync()) {
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(ByteData.sublistView(systemFont.readAsBytesSync())),
        );
      await loader.load();
    }
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: RepaintBoundary(
            key: captureKey,
            child: SingleChildScrollView(
              child: SizedBox(
                width: 460,
                child: RecognitionWorkspacePanel(
                  controller: harness.controller,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Pincel +'), findsOneWidget);
    expect(find.text('Pincel −'), findsOneWidget);
    expect(find.text('Somente visível'), findsOneWidget);
    expect(find.text('Através da malha'), findsOneWidget);
    expect(find.text('Diâmetro do pincel (mm)'), findsOneWidget);
    expect(find.text('Somente superfície conectada'), findsOneWidget);

    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File(testOutputPath(
        r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-S2\recognition_brush_panel_DIAGNOSTIC.png',
      ));
      file.parent.createSync(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    });
  });
}

final class _BrushHarness {
  _BrushHarness({
    required this.cad,
    required this.commands,
    required this.controller,
    required this.directory,
  });

  final DesktopCadController cad;
  final DesktopCommandCoordinator commands;
  final OperationalReverseEngineeringController controller;
  final Directory directory;

  static Future<_BrushHarness> create({
    required KernelMeshGeometry geometry,
    required Set<int> initialTriangles,
  }) async {
    final directory = await Directory.systemTemp.createTemp('flcad-brush-');
    final cad = DesktopCadController(
      kernels: KernelManager(),
      projects: ProjectManager.instance,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    await cad.runtime.open('project', directory);
    await cad.runtime.registerImport(
      ImportedCadDocument(
        id: 'mesh',
        projectId: 'project',
        sourcePath: 'mesh.stl',
        format: CadImportFormat.stl,
        registeredPath: 'CAD/mesh.stl',
        validation: const [],
        mesh: KernelMeshHandle(
          persistentId: 'mesh',
          kernelId: 'kernel',
          fingerprint: 'grid-fingerprint',
          vertexCount: geometry.nodes.length ~/ 3,
          triangleCount: geometry.triangles.length ~/ 3,
          bounds: const KernelBounds(0, 0, 0, 1, 1, 1),
          hasNormals: false,
          metadata: const {},
        ),
      ),
      geometry: geometry,
    );
    final selection = BridgeSelection(
      id: 'initial',
      entityId: 'mesh',
      kind: BridgeSelectionKind.meshRegion,
      geometry: geometry,
      triangleIndices: initialTriangles,
    );
    final region = const MeshRegionBuilder().build(
      meshId: 'mesh',
      selection: selection,
    );
    final controller = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
    );
    controller.configuredProjectId = 'project';
    controller.activeSelection = selection;
    controller.activeContext = BridgeContext(
      projectId: 'project',
      meshId: 'mesh',
      meshFingerprint: 'grid-fingerprint',
      userConfirmed: false,
      region: region,
    );
    controller.activePick = _pick(
      geometry,
      initialTriangles.first,
      camera: const Vector3(2.5, 2.5, 10),
    );
    return _BrushHarness(
      cad: cad,
      commands: commands,
      controller: controller,
      directory: directory,
    );
  }

  void dispose() {
    controller.dispose();
    cad.dispose();
    directory.deleteSync(recursive: true);
  }
}

int _adjacentTriangle(
  OperationalReverseEngineeringController controller, {
  Set<int> exclude = const {},
}) {
  final selection = controller.editableSelection!;
  final current = selection.currentTriangles;
  return current
      .map(selection.neighborsOf)
      .expand((values) => values)
      .firstWhere(
        (value) => !current.contains(value) && !exclude.contains(value),
      );
}

CadViewportPick _pick(
  KernelMeshGeometry geometry,
  int triangle, {
  required Vector3 camera,
}) {
  final centroid = triangleCentroid(geometry, triangle);
  final cameraController = CadCameraController(
    eye: camera,
    target: centroid,
    up: const Vector3(0, 1, 0),
  )..resize(800, 600);
  final ndc = cameraController.viewProjectionMatrix.transformPoint(centroid);
  return CadViewportPick(
    entityId: 'mesh',
    hit: MeshHit(triangleIndex: triangle, point: centroid, distance: 1),
    ray: MeshRay(camera, (centroid - camera).normalized),
    projection: ViewportSelectionProjection(
      viewProjection: cameraController.viewProjectionMatrix,
      viewportWidth: 800,
      viewportHeight: 600,
      centerScreen: Offset((ndc.x + 1) * 400, (1 - ndc.y) * 300),
      radiusPx: brushCursorRadiusPixels(
        camera: cameraController,
        point: centroid,
        radiusWorld: 2,
      ),
      orthographic: false,
    ),
  );
}

EditableSurfaceSelection _selectionFor(KernelMeshGeometry geometry) =>
    EditableSurfaceSelection(
      projectId: 'project',
      meshId: 'mesh',
      meshFingerprint: 'grid',
      entityId: 'mesh',
      geometry: geometry,
      initialTriangles: const {0},
      area: 0,
    );

const _gridTriangleCount = 50;

KernelMeshGeometry _gridGeometry({double z = 0, int columns = 6}) {
  final nodes = <double>[];
  for (var y = 0; y < columns; y++) {
    for (var x = 0; x < columns; x++) {
      nodes.addAll([x.toDouble(), y.toDouble(), z]);
    }
  }
  final triangles = <int>[];
  for (var y = 0; y < columns - 1; y++) {
    for (var x = 0; x < columns - 1; x++) {
      final a = y * columns + x;
      triangles.addAll([a, a + 1, a + columns + 1]);
      triangles.addAll([a, a + columns + 1, a + columns]);
    }
  }
  return KernelMeshGeometry(nodes: nodes, triangles: triangles);
}

KernelMeshGeometry _twoLayerGeometry({
  bool reverseBack = false,
  double backZ = -2,
}) {
  final front = _gridGeometry();
  final back = _gridGeometry(z: backZ);
  final offset = front.nodes.length ~/ 3;
  final triangles = [...front.triangles];
  for (var index = 0; index < back.triangles.length; index += 3) {
    final a = back.triangles[index] + offset;
    final b = back.triangles[index + 1] + offset;
    final c = back.triangles[index + 2] + offset;
    triangles.addAll(reverseBack ? [a, c, b] : [a, b, c]);
  }
  return KernelMeshGeometry(
    nodes: [...front.nodes, ...back.nodes],
    triangles: triangles,
  );
}

KernelMeshGeometry _twoIslandGeometry() {
  final first = _gridGeometry();
  final second = _gridGeometry();
  final offset = first.nodes.length ~/ 3;
  final nodes = [...first.nodes, ...second.nodes];
  for (var index = 0; index < second.nodes.length; index += 3) {
    nodes[first.nodes.length + index] += 6;
  }
  final triangles = [...first.triangles];
  for (var index = 0; index < second.triangles.length; index += 3) {
    triangles.addAll([
      second.triangles[index] + offset,
      second.triangles[index + 1] + offset,
      second.triangles[index + 2] + offset,
    ]);
  }
  return KernelMeshGeometry(nodes: nodes, triangles: triangles);
}

KernelMeshGeometry _reverseWinding(KernelMeshGeometry geometry) {
  final triangles = <int>[];
  for (var index = 0; index < geometry.triangles.length; index += 3) {
    triangles.addAll([
      geometry.triangles[index],
      geometry.triangles[index + 2],
      geometry.triangles[index + 1],
    ]);
  }
  return KernelMeshGeometry(nodes: geometry.nodes, triangles: triangles);
}

KernelMeshGeometry _boxGeometry() => const KernelMeshGeometry(
  nodes: [
    0,
    0,
    0,
    1,
    0,
    0,
    1,
    1,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
    1,
    0,
    1,
    1,
    1,
    1,
    0,
    1,
    1,
  ],
  triangles: [
    4,
    5,
    6,
    4,
    6,
    7,
    0,
    2,
    1,
    0,
    3,
    2,
    0,
    4,
    7,
    0,
    7,
    3,
    1,
    2,
    6,
    1,
    6,
    5,
    0,
    1,
    5,
    0,
    5,
    4,
    3,
    7,
    6,
    3,
    6,
    2,
  ],
);

KernelMeshGeometry _cylinderPatchGeometry({
  int columns = 10,
  int rows = 6,
  double radius = 18,
}) {
  final nodes = <double>[];
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < columns; x++) {
      final angle = x / (columns - 1) * math.pi / 2;
      nodes.addAll([
        radius * math.cos(angle),
        y.toDouble(),
        radius * math.sin(angle),
      ]);
    }
  }
  final triangles = <int>[];
  for (var y = 0; y < rows - 1; y++) {
    for (var x = 0; x < columns - 1; x++) {
      final a = y * columns + x;
      triangles.addAll([a, a + 1, a + columns + 1]);
      triangles.addAll([a, a + columns + 1, a + columns]);
    }
  }
  return KernelMeshGeometry(nodes: nodes, triangles: triangles);
}
