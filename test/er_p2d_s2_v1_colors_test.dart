import 'dart:io';
import 'dart:ui' as ui;

import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/professional_cad_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/cad_selection_palette.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_scene_adapter.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/import_export/api/import_export_api.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'imported mesh palette keeps selection contrast and avoids duplicates',
    () {
      for (final color in kImportedMeshPalette) {
        expect(
          contrastRatio(color, kCadSelectionColor),
          greaterThanOrEqualTo(kMinimumSelectionContrast),
        );
        expect(isSelectionReservedColor(color), isFalse);
      }
      expect(isSelectionReservedColor(Colors.white), isTrue);
      expect(isSelectionReservedColor(kCadSelectionColor), isTrue);

      final first = chooseImportedMeshColor(existing: const []);
      final second = chooseImportedMeshColor(existing: [first]);
      final third = chooseImportedMeshColor(existing: [first, second]);
      expect(colorDistance(first, second), greaterThan(.04));
      expect(colorDistance(second, third), greaterThan(.04));
      expect(colorDistance(first, third), greaterThan(.04));

      final linear = linearRgbForColor(first);
      final roundTrip = colorFromLinearRgb(linear)!;
      expect(colorDistance(roundTrip, first), lessThan(1e-6));
    },
  );

  test(
    'new mesh imports persist distinct colors through save and open',
    () async {
      final directory = await Directory.systemTemp.createTemp('flcad-colors-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cad = DesktopCadController(
        kernels: KernelManager(),
        projects: ProjectManager.instance,
      );
      addTearDown(cad.dispose);
      await cad.runtime.open('project', directory);

      final geometryA = _triangleGeometry(0);
      final geometryB = _triangleGeometry(1);
      await cad.runtime.registerImport(
        _import('mesh-a', geometryA),
        geometry: geometryA,
      );
      await cad.runtime.registerImport(
        _import('mesh-b', geometryB),
        geometry: geometryB,
      );
      final before = _sceneMeshColors(cad.runtime.scene);
      expect(before, hasLength(2));
      expect(colorDistance(before[0], before[1]), greaterThan(.04));
      for (final color in before) {
        expect(
          contrastRatio(color, kCadSelectionColor),
          greaterThanOrEqualTo(kMinimumSelectionContrast),
        );
      }

      await cad.runtime.save();
      await cad.runtime.open('project', directory);
      final after = _sceneMeshColors(cad.runtime.scene);
      expect(after, hasLength(2));
      expect(colorDistance(after[0], before[0]), lessThan(1e-4));
      expect(colorDistance(after[1], before[1]), lessThan(1e-4));
    },
  );

  test('brush cursor radius follows perspective distance', () {
    final near = CadCameraController(
      eye: const Vector3(0, 0, 10),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);
    final far = CadCameraController(
      eye: const Vector3(0, 0, 20),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);
    final nearRadius = brushCursorRadiusPixels(
      camera: near,
      point: Vector3.zero,
      radiusWorld: 2,
    );
    final farRadius = brushCursorRadiusPixels(
      camera: far,
      point: Vector3.zero,
      radiusWorld: 2,
    );
    expect(nearRadius, greaterThan(0));
    expect(farRadius, greaterThan(0));
    expect(nearRadius, greaterThan(farRadius));
  });

  testWidgets('brush cursor follows hit, hides without hit and shows mode', (
    tester,
  ) async {
    final geometry = _gridGeometry(columns: 4);
    final scene = CadSceneGraph()
      ..upsert(
        MeshSceneAdapter.fromKernel(
          id: 'mesh-1',
          geometry: geometry,
          bounds: const KernelBounds(0, 0, 0, 3, 3, 0),
        ),
      );
    final camera = CadCameraController(
      eye: const Vector3(1.5, 1.5, 10),
      target: const Vector3(1.5, 1.5, 0),
      up: const Vector3(0, 1, 0),
    );
    Widget build(CadBrushCursorMode mode) => MaterialApp(
      home: SizedBox(
        width: 800,
        height: 600,
        child: ProfessionalCadViewportWidget(
          scene: scene,
          camera: camera,
          brushActive: true,
          brushCandidateIds: const {'mesh-1'},
          brushDiameterMm: 20,
          brushCursorMode: mode,
          onBrushDown: (_) {},
          onBrushMove: (_) {},
          onBrushUp: () {},
        ),
      ),
    );

    await tester.pumpWidget(build(CadBrushCursorMode.add));
    await tester.pump();
    await tester.pump();
    await tester.sendEventToBinding(
      const PointerHoverEvent(
        pointer: 71,
        device: 71,
        kind: PointerDeviceKind.mouse,
        position: Offset(400, 300),
      ),
    );
    await tester.pump();
    var canvas = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('brush-cursor-canvas')),
    );
    var painter = canvas.foregroundPainter as BrushCursorPainter;
    expect(painter.state.mode, CadBrushCursorMode.add);
    expect(painter.state.radius, greaterThan(0));

    await tester.sendEventToBinding(
      const PointerHoverEvent(
        pointer: 71,
        device: 71,
        kind: PointerDeviceKind.mouse,
        position: Offset(10, 10),
      ),
    );
    await tester.pump();
    canvas = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('brush-cursor-canvas')),
    );
    expect(canvas.foregroundPainter, isNull);

    await tester.pumpWidget(build(CadBrushCursorMode.remove));
    await tester.pump();
    await tester.sendEventToBinding(
      const PointerHoverEvent(
        pointer: 71,
        device: 71,
        kind: PointerDeviceKind.mouse,
        position: Offset(400, 300),
      ),
    );
    await tester.pump();
    canvas = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('brush-cursor-canvas')),
    );
    painter = canvas.foregroundPainter as BrushCursorPainter;
    expect(painter.state.mode, CadBrushCursorMode.remove);
  });

  testWidgets('brush cursor and selection diagnostic capture', (tester) async {
    final geometry = _gridGeometry(columns: 4);
    final scene = CadSceneGraph()
      ..upsert(
        CadSceneEntity(
          id: 'mesh-1',
          kind: CadSceneEntityKind.mesh,
          geometry: {
            'nodes': geometry.nodes,
            'triangles': geometry.triangles,
            'rootLinearRgb': linearRgbForColor(kImportedMeshPalette.first),
          },
        ),
      )
      ..upsert(_selectionPreview(geometry, const {0, 1, 2, 3}));
    final camera = CadCameraController(
      eye: const Vector3(1.5, 1.5, 10),
      target: const Vector3(1.5, 1.5, 0),
      up: const Vector3(0, 1, 0),
    );
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: RepaintBoundary(
          key: key,
          child: ProfessionalCadViewportWidget(
            scene: scene,
            camera: camera,
            brushActive: true,
            brushCandidateIds: const {'mesh-1'},
            brushDiameterMm: 20,
            brushCursorMode: CadBrushCursorMode.add,
            onBrushDown: (_) {},
            onBrushMove: (_) {},
            onBrushUp: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.sendEventToBinding(
      const PointerHoverEvent(
        pointer: 81,
        device: 81,
        kind: PointerDeviceKind.mouse,
        position: Offset(400, 300),
      ),
    );
    await tester.pump();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File(
        r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-S2-V1\brush_cursor_selection_DIAGNOSTIC.png',
      );
      file.parent.createSync(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    });
  });
}

CadSceneEntity _selectionPreview(
  KernelMeshGeometry geometry,
  Set<int> triangles,
) {
  final remap = <int, int>{};
  final nodes = <double>[];
  int mapped(int vertex) => remap.putIfAbsent(vertex, () {
    final offset = vertex * 3;
    nodes.addAll([
      geometry.nodes[offset],
      geometry.nodes[offset + 1],
      geometry.nodes[offset + 2],
    ]);
    return remap.length;
  });
  final previewTriangles = <int>[];
  final edgeCounts = <(int, int), int>{};
  for (final triangle in triangles) {
    final offset = triangle * 3;
    final a = geometry.triangles[offset];
    final b = geometry.triangles[offset + 1];
    final c = geometry.triangles[offset + 2];
    previewTriangles.addAll([mapped(a), mapped(b), mapped(c)]);
    for (final edge in [(a, b), (b, c), (c, a)]) {
      final key = edge.$1 < edge.$2 ? (edge.$1, edge.$2) : (edge.$2, edge.$1);
      edgeCounts[key] = (edgeCounts[key] ?? 0) + 1;
    }
  }
  final boundary = <List<double>>[];
  for (final entry in edgeCounts.entries) {
    if (entry.value != 1) continue;
    final first = entry.key.$1 * 3;
    final second = entry.key.$2 * 3;
    boundary.add([
      geometry.nodes[first],
      geometry.nodes[first + 1],
      geometry.nodes[first + 2],
      geometry.nodes[second],
      geometry.nodes[second + 1],
      geometry.nodes[second + 2],
    ]);
  }
  return CadSceneEntity(
    id: 'selection-preview',
    kind: CadSceneEntityKind.preview,
    geometry: {
      'nodes': nodes,
      'triangles': previewTriangles,
      'rootLinearRgb': kCadSelectionLinearRgb,
      'selectionPreview': true,
      'editableSelection': true,
      'triangleCount': triangles.length,
      'area': 0,
      'topologicalEdges': boundary,
    },
  );
}

List<Color> _sceneMeshColors(CadSceneGraph scene) => scene.entities
    .where((entity) => entity.kind == CadSceneEntityKind.mesh)
    .map(
      (entity) =>
          colorFromLinearRgb(entity.geometry['rootLinearRgb']) ??
          kCadDefaultMeshColor,
    )
    .toList(growable: false);

ImportedCadDocument _import(String id, KernelMeshGeometry geometry) =>
    ImportedCadDocument(
      id: id,
      projectId: 'project',
      sourcePath: '$id.stl',
      format: CadImportFormat.stl,
      registeredPath: 'CAD/$id.stl',
      validation: const [],
      mesh: KernelMeshHandle(
        persistentId: id,
        kernelId: 'kernel',
        fingerprint: id,
        vertexCount: geometry.nodes.length ~/ 3,
        triangleCount: geometry.triangles.length ~/ 3,
        bounds: const KernelBounds(0, 0, 0, 1, 1, 0),
        hasNormals: false,
        metadata: const {},
      ),
    );

KernelMeshGeometry _triangleGeometry(double x) => KernelMeshGeometry(
  nodes: [x, 0, 0, x + 1, 0, 0, x, 1, 0],
  triangles: const [0, 1, 2],
);

KernelMeshGeometry _gridGeometry({int columns = 4}) {
  final nodes = <double>[];
  for (var y = 0; y < columns; y++) {
    for (var x = 0; x < columns; x++) {
      nodes.addAll([x.toDouble(), y.toDouble(), 0]);
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
