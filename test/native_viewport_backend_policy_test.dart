import 'dart:async';
import 'dart:io';

import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/native/integrated_native_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/professional_cad_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('flcad/native_viewport');
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Sketch and line previews remain safe overlays over Native CAD', () {
    final scene = CadSceneGraph()
      ..upsert(entity())
      ..upsert(
        const CadSceneEntity(
          id: 'Sketch001',
          kind: CadSceneEntityKind.sketch,
          geometry: {
            'points': [
              [0.0, 0.0, 0.0],
              [1.0, 0.0, 0.0],
            ],
          },
        ),
      )
      ..upsert(
        const CadSceneEntity(
          id: 'sketch-rectangle-preview',
          kind: CadSceneEntityKind.preview,
          geometry: {
            'segments': [
              [
                [0.0, 0.0, 0.0],
                [1.0, 1.0, 0.0],
              ],
            ],
          },
        ),
      );
    expect(nativeSceneUnsupportedReason(scene, style: 0), isNull);
    expect(
      CadSceneDisplayAdapter().initial(scene).entities.map((e) => e['id']),
      ['a'],
    );
    scene.dispose();
  });

  test(
    'managed Sections remain Flutter overlays without global Canvas fallback',
    () {
      final scene = CadSceneGraph()
        ..upsert(entity())
        ..upsert(
          const CadSceneEntity(
            id: 'section:001',
            kind: CadSceneEntityKind.curve,
            geometry: {
              'referenceCurve': true,
              'segments': [
                [
                  [0.0, 0.0, 0.0],
                  [1.0, 0.0, 0.0],
                ],
              ],
            },
          ),
        );
      expect(nativeSceneUnsupportedReason(scene, style: 0), isNull);
      expect(
        CadSceneDisplayAdapter().initial(scene).entities.map((e) => e['id']),
        ['a'],
      );
      scene.dispose();
    },
  );

  test('invalid solid preview still forces categorized Canvas fallback', () {
    final scene = CadSceneGraph()
      ..upsert(entity())
      ..upsert(
        const CadSceneEntity(
          id: 'preview:Extrude001',
          kind: CadSceneEntityKind.preview,
          geometry: {'handle': 'transient-without-display-mesh'},
        ),
      );
    expect(
      nativeSceneUnsupportedReason(scene, style: 0),
      contains('pré-visualização CAD'),
    );
    scene.dispose();
  });

  test(
    'new window bridge waits for retirement and inactive dispose cannot stop its successor',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final gate = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'shutdown' && !gate.isCompleted) await gate.future;
        return call.method == 'initialize' ? 42 : null;
      });
      final first = NativeViewportBridge();
      final second = NativeViewportBridge();
      expect(await first.initialize(800, 600), isTrue);
      final draining = first.deactivate();
      final starting = second.initialize(800, 600);
      await Future<void>.value();
      expect(calls.where((c) => c == 'initialize'), hasLength(1));
      expect(second.available, isFalse);
      gate.complete();
      await draining;
      expect(await starting, isTrue);
      final shutdowns = calls.where((c) => c == 'shutdown').length;
      first.dispose();
      await Future<void>.value();
      expect(calls.where((c) => c == 'shutdown').length, shutdowns);
      expect(second.available, isTrue);
      await second.deactivate();
      second.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    },
    skip: !Platform.isWindows,
  );

  test(
    'native interaction borrows arrays without copying Canvas mesh buffers',
    () {
      final scene = CadSceneGraph()..upsert(entity());
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      )..resize(800, 600);
      final picking = ViewportPickingController();
      final original = picking.pick(
        position: const Offset(400, 300),
        camera: camera,
        scene: scene,
      );
      expect(picking.copiedMeshCount, 1);
      picking.clear();
      picking.copyMeshArrays = false;
      final borrowed = picking.pick(
        position: const Offset(400, 300),
        camera: camera,
        scene: scene,
      );
      expect(borrowed!.entityId, original!.entityId);
      expect(borrowed.hit.point.x, original.hit.point.x);
      expect(borrowed.hit.point.y, original.hit.point.y);
      expect(borrowed.hit.point.z, original.hit.point.z);
      expect(picking.copiedMeshCount, 0);
      camera.dispose();
      scene.dispose();
    },
  );

  test('inactive bridge never encodes or retains scene geometry', () async {
    final bridge = NativeViewportBridge();
    final scene = CadSceneGraph()..upsert(entity());
    await bridge.sendInitial(scene);
    await bridge.sendDelta(scene);
    expect(bridge.adapter.retainedGeometryCount, 0);
    bridge.dispose();
    scene.dispose();
  });

  testWidgets(
    'STL mesh edge modes use Canvas without resetting mode or diagnostic preference',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      final scene = CadSceneGraph()
        ..upsert(
          CadSceneEntity(
            id: 'mesh',
            kind: CadSceneEntityKind.mesh,
            geometry: {
              'nodes': entity().geometry['nodes'],
              'triangles': [0, 1, 2],
            },
          ),
        );
      final camera = CadCameraController();
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
      await tester.tap(find.text('Wireframe'));
      await tester.pump();
      await tester.pump();
      ProfessionalCadViewportWidget viewport() =>
          tester.widget(find.byType(ProfessionalCadViewportWidget));
      expect(viewport().renderMeshes, isTrue);
      expect(viewport().renderStyle, CadRenderStyle.wireframe);
      expect(find.textContaining('toda a cena'), findsOneWidget);
      final snapshots = calls.where((c) => c == 'snapshot').length;
      await tester.tap(find.text('Shaded'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(viewport().renderMeshes, isFalse);
      expect(calls.where((c) => c == 'snapshot').length, snapshots + 1);
      await tester.tap(find.text('Flutter Canvas'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Transparência'));
      await tester.pump();
      expect(find.textContaining('toda a cena'), findsNothing);
      expect(
        viewport().renderMeshes,
        isTrue,
        reason: 'Explicit diagnostic preference persists across styles',
      );
      expect(viewport().renderStyle, CadRenderStyle.transparent);
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
    'shutdown during initialization never publishes a late snapshot',
    (tester) async {
      final gate = Completer<int>();
      final calls = <String>[];
      final scene = CadSceneGraph()..upsert(entity());
      final camera = CadCameraController();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return call.method == 'initialize' ? gate.future : null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: IntegratedCadViewportWidget(scene: scene, camera: camera),
        ),
      );
      expect(calls, contains('initialize'));
      await tester.pumpWidget(const SizedBox());
      gate.complete(42);
      await tester.pump();
      expect(calls, contains('shutdown'));
      expect(calls, isNot(contains('snapshot')));
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
    'interaction during camera delivery is not overwritten by initialization',
    (tester) async {
      final gate = Completer<void>();
      final cameras = <Map<dynamic, dynamic>>[];
      final scene = CadSceneGraph()..upsert(entity());
      final camera = CadCameraController();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'setCamera') {
          cameras.add(call.arguments as Map);
          if (cameras.length == 1) await gate.future;
        }
        return call.method == 'initialize' ? 42 : null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: IntegratedCadViewportWidget(scene: scene, camera: camera),
        ),
      );
      await tester.pump();
      expect(cameras, hasLength(1));
      camera.orbit(.2, .1);
      final expected = [
        camera.presentationEye.x,
        camera.presentationEye.y,
        camera.presentationEye.z,
      ];
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(cameras.last['eye'], expected);
      expect(cameras.length, greaterThanOrEqualTo(2));
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
    'Windows defaults to native, hands off once and drains inactive backend',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      final calls = <MethodCall>[];
      final bridge = NativeViewportBridge();
      final scene = CadSceneGraph()..upsert(entity());
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return call.method == 'initialize' ? 42 : null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: IntegratedCadViewportWidget(
            scene: scene,
            camera: camera,
            nativeBridgeFactory: () => bridge,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(calls.where((c) => c.method == 'snapshot'), hasLength(1));
      ProfessionalCadViewportWidget viewport() =>
          tester.widget(find.byType(ProfessionalCadViewportWidget));
      dynamic state() =>
          tester.state(find.byType(ProfessionalCadViewportWidget));
      expect(viewport().renderMeshes, isFalse);
      expect(state().meshRenderCaches, isEmpty);
      await tester.tap(find.text('Arestas'));
      await tester.pump();
      final eye = camera.eye;
      final target = camera.target;
      await tester.tap(find.text('Flutter Canvas'));
      await tester.pump();
      await tester.pump();
      expect(calls.where((c) => c.method == 'shutdown'), hasLength(1));
      expect(bridge.available, isFalse);
      expect(bridge.adapter.retainedGeometryCount, 0);
      expect(viewport().renderMeshes, isTrue);
      final count = calls.length;
      scene.upsert(entity(selected: true));
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        calls.length,
        count,
        reason: 'Canvas changes must not cross MethodChannel',
      );
      await tester.tap(find.text('Native GPU'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(calls.where((c) => c.method == 'snapshot'), hasLength(2));
      expect(viewport().renderMeshes, isFalse);
      expect(state().meshRenderCaches, isEmpty);
      expect(viewport().renderStyle, CadRenderStyle.hiddenLine);
      expect(camera.eye, eye);
      expect(camera.target, target);
      expect(scene.entities.single.selected, isTrue);
      expect(bridge.renderStyle, 1);
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
    'revoked initialization cannot publish and Canvas waits for shutdown gate',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      final initialized = Completer<int>();
      final shutdown = Completer<void>();
      final calls = <String>[];
      final scene = CadSceneGraph()..upsert(entity());
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'initialize') return initialized.future;
        if (call.method == 'shutdown') await shutdown.future;
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: IntegratedCadViewportWidget(scene: scene, camera: camera),
        ),
      );
      expect(calls, contains('initialize'));
      await tester.tap(find.text('Flutter Canvas'));
      await tester.pump();
      initialized.complete(42);
      await tester.pump();
      expect(calls, contains('shutdown'));
      expect(calls, isNot(contains('snapshot')));
      expect(
        tester
            .widget<ProfessionalCadViewportWidget>(
              find.byType(ProfessionalCadViewportWidget),
            )
            .renderMeshes,
        isFalse,
      );
      shutdown.complete();
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<ProfessionalCadViewportWidget>(
              find.byType(ProfessionalCadViewportWidget),
            )
            .renderMeshes,
        isTrue,
      );
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
    'native error drains host then recovers Canvas without changing scene',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      final calls = <String>[];
      var fail = false;
      final scene = CadSceneGraph()..upsert(entity());
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        if (fail && call.method == 'setCamera') {
          throw PlatformException(code: 'device_removed');
        }
        return call.method == 'initialize' ? 42 : null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: IntegratedCadViewportWidget(scene: scene, camera: camera),
        ),
      );
      await tester.pump();
      await tester.pump();
      fail = true;
      await tester.tap(find.text('Transparência'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(calls, contains('shutdown'));
      expect(find.textContaining('Native GPU indisponível'), findsOneWidget);
      final viewport = tester.widget<ProfessionalCadViewportWidget>(
        find.byType(ProfessionalCadViewportWidget),
      );
      expect(viewport.renderMeshes, isTrue);
      expect(viewport.renderStyle, CadRenderStyle.transparent);
      expect(scene.entities.single.id, 'a');
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
}

CadSceneEntity entity({bool selected = false}) => CadSceneEntity(
  id: 'a',
  kind: CadSceneEntityKind.solid,
  selected: selected,
  geometry: const {
    'nodes': [-1.0, -1.0, 0.0, 1.0, -1.0, 0.0, 0.0, 1.0, 0.0],
    'triangles': [0, 1, 2],
    'topologicalEdges': [
      [-1.0, -1.0, 0.0, 1.0, -1.0, 0.0],
    ],
  },
);
