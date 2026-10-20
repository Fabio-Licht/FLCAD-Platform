import 'dart:async';

import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/native/integrated_native_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/professional_cad_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/desktop/desktop_application.dart';
import 'package:flcad_mobile/app/operational_entities/operational_entity.dart';
import 'package:flcad_mobile/app/operational_entities/operational_entity_resolver.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends NativeViewportBridge {
  _Bridge() {
    available = true;
    textureId = 1;
  }
  final positions = <Offset>[];
  final managedFaceHovers = <(String, int)>[];
  final managedFaceSelections = <(String, int)>[];
  var managedFaceSelectionClears = 0;
  var hoverClears = 0;
  var scenePublications = 0;
  Future<NativeViewportPick?> Function(Offset)? answer;
  @override
  Future<NativeViewportPick?> pick(double x, double y) async {
    final position = Offset(x, y);
    positions.add(position);
    return answer == null ? hit('a') : await answer!(position);
  }

  @override
  Future<void> resize(double width, double height) async {}
  @override
  Future<void> sendInitial(CadSceneGraph scene) async {
    scenePublications++;
  }

  @override
  Future<void> sendDelta(CadSceneGraph scene) async {
    scenePublications++;
  }

  @override
  Future<void> setCamera(CadCameraController camera) async {}
  @override
  Future<void> clearHover() async {
    hoverClears++;
  }

  @override
  Future<void> setManagedCadFaceHover({
    required String entityId,
    required int presentationSubId,
  }) async {
    managedFaceHovers.add((entityId, presentationSubId));
  }

  @override
  Future<void> setManagedCadFaceSelection({
    required String entityId,
    required int presentationSubId,
  }) async {
    managedFaceSelections.add((entityId, presentationSubId));
  }

  @override
  Future<void> clearManagedCadFaceSelection() async {
    managedFaceSelectionClears++;
  }

  @override
  Future<void> setOperationalHover({
    required String operationalEntityId,
    required String entityId,
    required List<int> triangleIndices,
  }) async {}
  @override
  Future<void> clearOperationalSelection() async {}
  @override
  Future<void> setOperationalSelection({
    required String operationalEntityId,
    required String entityId,
    required List<int> triangleIndices,
  }) async {}
  @override
  void dispose() {
    available = false;
    super.dispose();
  }
}

NativeViewportPick hit(
  String id, {
  int subId = 1,
  List<double> point = const [1, 2, 3],
}) => NativeViewportPick(
  entityId: id,
  kind: NativePickKind.face,
  subId: subId,
  point: point,
);

class _Selection extends OperationalSelectionManager {
  _Selection(super.registry);
  int calls = 0;
  @override
  void select(String id, {bool additive = false, bool toggle = false}) {
    calls++;
    super.select(id, additive: additive, toggle: toggle);
  }
}

class _DelayedResolver extends OperationalEntityResolver {
  _DelayedResolver(super.registry);
  final gate = Completer<void>();
  bool started = false;
  @override
  Future<OperationalResolution?> resolve(
    NativeViewportPick raw,
    CadSceneGraph scene,
  ) async {
    started = true;
    await gate.future;
    return super.resolve(raw, scene);
  }
}

class _Fixture {
  final bridge = _Bridge();
  final registry = OperationalEntityRegistry();
  late final selection = _Selection(registry);
  final managedFaceSelection = CadManagedFaceSelectionController();
  final picks = <CadViewportPick>[];
  final camera = CadCameraController(
    eye: const Vector3(0, 0, 5),
    target: Vector3.zero,
    up: const Vector3(0, 1, 0),
  );
  CadSceneGraph scene = CadSceneGraph()
    ..upsert(
      const CadSceneEntity(
        id: 'a',
        kind: CadSceneEntityKind.solid,
        geometry: {
          'nodes': [-2.0, -2.0, 0.0, 2.0, -2.0, 0.0, 0.0, 2.0, 0.0],
          'triangles': [0, 1, 2],
        },
      ),
    )
    ..upsert(
      const CadSceneEntity(
        id: 'b',
        kind: CadSceneEntityKind.solid,
        geometry: {
          'nodes': [3.0, -2.0, 0.0, 7.0, -2.0, 0.0, 3.0, 2.0, 0.0],
          'triangles': [0, 1, 2],
        },
      ),
    );

  void makeManagedCad() {
    scene.upsert(
      const CadSceneEntity(
        id: 'a',
        kind: CadSceneEntityKind.mesh,
        geometry: {
          'nodes': [-2.0, -2.0, 0.0, 2.0, -2.0, 0.0, 0.0, 2.0, 0.0],
          'triangles': [0, 1, 2],
          'brepPresentation': {
            'nodes': [
              -2.0,
              -2.0,
              0.0,
              2.0,
              -2.0,
              0.0,
              2.0,
              2.0,
              0.0,
              -2.0,
              -2.0,
              0.0,
              2.0,
              2.0,
              0.0,
              -2.0,
              2.0,
              0.0,
            ],
            'triangles': [0, 1, 2, 3, 4, 5],
            'normals': [
              0.0,
              0.0,
              1.0,
              0.0,
              0.0,
              1.0,
              0.0,
              0.0,
              1.0,
              0.0,
              0.0,
              1.0,
              0.0,
              0.0,
              1.0,
              0.0,
              0.0,
              1.0,
            ],
            'faceTriangleRanges': [
              [1, 1],
              [2, 1],
            ],
          },
        },
      ),
    );
  }

  Future<void> mount(
    WidgetTester tester, {
    OperationalEntityResolver? resolver,
    ValueChanged<Offset>? sketchTap,
    ValueChanged<CadViewportPick>? sketchEntity,
    ValueChanged<CadViewportPick>? sketchSupport,
    ValueChanged<CadViewportPick>? doublePick,
    void Function(CadViewportPick, Offset)? dragStart,
    VoidCallback? onViewportSelectionCleared,
    bool Function(CadViewportPick)? onPickCapture,
    Set<String>? pickCaptureCandidateIds,
    ValueChanged<CadViewportPick?>? onPickCaptureHover,
    ValueChanged<CadViewportPick?>? onSketchSuggestionHover,
    ValueChanged<Offset?>? onSketchSuggestionHoverPosition,
    Set<String>? sketchSuggestionPickCandidateIds,
    bool technicalRecognitionAvailable = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(
      MaterialApp(
        home: IntegratedCadViewportWidget(
          key: const ValueKey('integrated'),
          scene: scene,
          camera: camera,
          nativeBridgeFactory: () => bridge,
          operationalEntities: registry,
          operationalSelection: selection,
          operationalResolver: resolver,
          managedFaceSelectionController: managedFaceSelection,
          onPick: picks.add,
          onPickCapture: onPickCapture,
          pickCaptureCandidateIds: pickCaptureCandidateIds,
          onPickCaptureHover: onPickCaptureHover,
          onSketchSuggestionHover: onSketchSuggestionHover,
          onSketchSuggestionHoverPosition: onSketchSuggestionHoverPosition,
          sketchSuggestionPickCandidateIds: sketchSuggestionPickCandidateIds,
          onSketchTap: sketchTap,
          onSketchEntityPick: sketchEntity,
          onSketchSupportPick: sketchSupport,
          onSketchEntityDoublePick: doublePick,
          onSketchEntityDragStart: dragStart,
          onViewportSelectionCleared: onViewportSelectionCleared,
          technicalRecognitionAvailable: technicalRecognitionAvailable,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Native GPU'));
    await tester.pump();
  }
}

Future<void> tap(
  WidgetTester tester, [
  Offset position = const Offset(600, 400),
]) async {
  await tester.tapAt(position);
  await tester.pump();
}

void main() {
  testWidgets(
    'viewport pointer restores global history shortcut focus after text editing',
    (tester) async {
      final fixture = _Fixture();
      var undoCalls = 0;
      var redoCalls = 0;
      final text = TextEditingController(text: 'editable');
      addTearDown(text.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopHistoryShortcuts(
            onUndo: () async => undoCalls++,
            onRedo: () async => redoCalls++,
            child: Scaffold(
              body: Column(
                children: [
                  SizedBox(
                    height: 56,
                    child: TextField(controller: text),
                  ),
                  Expanded(
                    child: IntegratedCadViewportWidget(
                      scene: fixture.scene,
                      camera: fixture.camera,
                      nativeBridgeFactory: () => fixture.bridge,
                      operationalEntities: fixture.registry,
                      operationalSelection: fixture.selection,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(undoCalls, 0);

      await tester.tapAt(const Offset(600, 400));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(undoCalls, 1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlRight);
      await tester.pump();
      expect(redoCalls, 1);
    },
  );

  testWidgets(
    'native tap has one owner, uses exact click and ignores prior hover',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final mouse = TestPointer(9, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(500, 350)));
      await tester.pump();
      f.bridge.answer = (_) async => hit('b', point: [4, 5, 6]);
      f.bridge.positions.clear();
      const clicked = Offset(610.25, 420.75);
      await tap(tester, clicked);
      expect(f.bridge.positions, [clicked]);
      expect(f.selection.calls, 1);
      expect(f.selection.activeId, 'operational:b');
      expect(f.picks, hasLength(1));
      expect(f.picks.single.entityId, 'b');
      expect(f.picks.single.subentityKind, CadViewportSubentityKind.face);
      expect(f.picks.single.presentationSubId, 1);
      expect(
        f.picks.single.hit.point.distanceTo(const Vector3(4, 5, 6)),
        lessThan(1e-12),
      );
      expect(
        find.ancestor(
          of: find.byType(ProfessionalCadViewportWidget),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('out of order native taps publish only the newest', (
    tester,
  ) async {
    final f = _Fixture();
    final first = Completer<NativeViewportPick?>();
    final second = Completer<NativeViewportPick?>();
    f.bridge.answer = (p) => p.dx == 600 ? first.future : second.future;
    await f.mount(tester);
    await tap(tester);
    await tap(tester, const Offset(650, 400));
    second.complete(hit('b'));
    await tester.pump();
    first.complete(hit('a'));
    await tester.pump();
    expect(f.selection.calls, 1);
    expect(f.picks.single.entityId, 'b');
  });

  for (final invalidation in [
    'dispose',
    'navigation',
    'backend',
    'scene',
    'scene mutation',
  ]) {
    testWidgets('late native pick ignored after $invalidation', (tester) async {
      final f = _Fixture();
      final pending = Completer<NativeViewportPick?>();
      f.bridge.answer = (_) => pending.future;
      await f.mount(tester);
      await tap(tester);
      switch (invalidation) {
        case 'dispose':
          await tester.pumpWidget(const SizedBox.shrink());
        case 'navigation':
          final mouse = TestPointer(5, PointerDeviceKind.mouse);
          await tester.sendEventToBinding(
            mouse.down(const Offset(600, 400), buttons: kMiddleMouseButton),
          );
          await tester.sendEventToBinding(
            mouse.move(const Offset(640, 420), buttons: kMiddleMouseButton),
          );
          await tester.sendEventToBinding(mouse.up());
        case 'backend':
          await tester.tap(find.text('Flutter Canvas'));
          await tester.pump();
          await tester.tap(find.text('Native GPU'));
          await tester.pump();
        case 'scene':
          f.scene = CadSceneGraph();
          await f.mount(tester);
        case 'scene mutation':
          f.scene.remove('a');
      }
      pending.complete(hit('a'));
      await tester.pump();
      expect(f.selection.calls, 0);
      expect(f.picks, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'invalidation during asynchronous resolution also suppresses publication',
    (tester) async {
      final f = _Fixture();
      final resolver = _DelayedResolver(f.registry);
      await f.mount(tester, resolver: resolver);
      await tap(tester);
      expect(resolver.started, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      resolver.gate.complete();
      await tester.pump();
      expect(f.selection.calls, 0);
      expect(f.picks, isEmpty);
    },
  );

  testWidgets('Shift additive and Ctrl toggle are captured at click time', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await tap(tester);
    final pending = Completer<NativeViewportPick?>();
    f.bridge.answer = (_) => pending.future;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tap(tester);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    pending.complete(hit('b'));
    await tester.pump();
    expect(f.selection.selectedIds, ['operational:a', 'operational:b']);
    f.bridge.answer = (_) async => hit('a');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tap(tester);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(f.selection.selectedIds, ['operational:b']);
    expect(f.selection.calls, 3);
    expect(f.picks, hasLength(3));
  });

  testWidgets(
    'technical recognition forwards managed LOD picks without a native point',
    (tester) async {
      final f = _Fixture();
      f.scene.upsert(
        const CadSceneEntity(
          id: 'b',
          kind: CadSceneEntityKind.mesh,
          geometry: {
            'presentationLod': {'triangleCount': 1},
          },
        ),
      );
      f.bridge.answer = (_) async => const NativeViewportPick(
        entityId: 'b',
        kind: NativePickKind.face,
        subId: 0,
        point: [],
      );
      await f.mount(tester, technicalRecognitionAvailable: true);
      await tap(tester);
      expect(f.picks, hasLength(1));
      expect(f.picks.single.entityId, 'b');
      expect(f.picks.single.ray, isNotNull);
    },
  );

  testWidgets(
    'no hit leaves selection unchanged and invalid point emits no onPick',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await tap(tester);
      for (final result in [
        null,
        hit('missing'),
        const NativeViewportPick(
          entityId: 'a',
          kind: NativePickKind.none,
          subId: 0,
          point: [],
        ),
      ]) {
        f.bridge.answer = (_) async => result;
        await tap(tester);
      }
      expect(f.selection.calls, 1);
      expect(f.picks, hasLength(1));
      expect(f.selection.activeId, 'operational:a');
      f.bridge.answer = (_) async => hit('b', point: [double.nan, 0, 0]);
      await tap(tester);
      expect(f.selection.calls, 2);
      expect(f.picks, hasLength(1));
    },
  );

  testWidgets(
    'Native GPU resolves a visible reference overlay through Flutter picking',
    (tester) async {
      final f = _Fixture();
      f.scene.upsert(
        const CadSceneEntity(
          id: 'world:xy-plane',
          kind: CadSceneEntityKind.plane,
          geometry: {
            'origin': [0.0, 0.0, 0.0],
            'normal': [0.0, 0.0, 1.0],
            'xDirection': [1.0, 0.0, 0.0],
            'visualSize': 30.0,
          },
        ),
      );
      f.bridge.answer = (_) async => null;
      await f.mount(tester);

      await tap(tester);

      expect(f.picks.single.entityId, 'world:xy-plane');
      expect(f.selection.activeId, 'operational:world:xy-plane');
      expect(f.bridge.positions, hasLength(1));
      expect(find.text('Native GPU'), findsOneWidget);
    },
  );

  testWidgets('Native GPU resolves a local coordinate system overlay', (
    tester,
  ) async {
    final f = _Fixture();
    f.scene.upsert(
      const CadSceneEntity(
        id: 'reference:alignment-wcs',
        kind: CadSceneEntityKind.coordinateSystem,
        geometry: {
          'type': 'coordinateSystem',
          'origin': [0.0, 0.0, 0.0],
          'xAxis': [1.0, 0.0, 0.0],
          'yAxis': [0.0, 1.0, 0.0],
          'zAxis': [0.0, 0.0, 1.0],
        },
      ),
    );
    f.bridge.answer = (_) async => null;
    await f.mount(tester);

    await tap(tester);

    expect(f.picks.single.entityId, 'reference:alignment-wcs');
    expect(f.selection.activeId, 'operational:reference:alignment-wcs');
  });

  testWidgets('Canvas resolves the same local coordinate system overlay', (
    tester,
  ) async {
    final f = _Fixture();
    f.scene.upsert(
      const CadSceneEntity(
        id: 'reference:alignment-wcs',
        kind: CadSceneEntityKind.coordinateSystem,
        geometry: {
          'type': 'coordinateSystem',
          'origin': [0.0, 0.0, 0.0],
          'xAxis': [1.0, 0.0, 0.0],
          'yAxis': [0.0, 1.0, 0.0],
          'zAxis': [0.0, 0.0, 1.0],
        },
      ),
    );
    await f.mount(tester);
    await tester.tap(find.text('Flutter Canvas'));
    await tester.pumpAndSettle();

    await tap(tester);

    expect(f.picks.single.entityId, 'reference:alignment-wcs');
    expect(f.selection.activeId, isNull);
  });

  testWidgets(
    'transient command captures a WCS overlay without global selection',
    (tester) async {
      final f = _Fixture();
      f.scene.upsert(
        const CadSceneEntity(
          id: 'world:xy-plane',
          kind: CadSceneEntityKind.plane,
          geometry: {
            'origin': [0.0, 0.0, 0.0],
            'normal': [0.0, 0.0, 1.0],
            'xDirection': [1.0, 0.0, 0.0],
            'visualSize': 30.0,
          },
        ),
      );
      final captured = <CadViewportPick>[];
      f.bridge.answer = (_) async => null;
      await f.mount(
        tester,
        onPickCapture: (pick) {
          captured.add(pick);
          return true;
        },
      );

      await tap(tester);

      expect(captured.single.entityId, 'world:xy-plane');
      expect(f.selection.calls, 0);
      expect(f.selection.activeId, isNull);
      expect(f.picks, isEmpty);
    },
  );

  testWidgets('transient command consumes an incompatible native CAD click', (
    tester,
  ) async {
    final f = _Fixture();
    final captured = <CadViewportPick>[];
    await f.mount(
      tester,
      onPickCapture: (pick) {
        captured.add(pick);
        return true;
      },
    );

    await tap(tester);

    expect(captured.single.entityId, 'a');
    expect(f.selection.calls, 0);
    expect(f.picks, isEmpty);
  });

  testWidgets('Canvas uses the same transient overlay capture', (tester) async {
    final f = _Fixture();
    f.scene.upsert(
      const CadSceneEntity(
        id: 'world:xy-plane',
        kind: CadSceneEntityKind.plane,
        geometry: {
          'origin': [0.0, 0.0, 0.0],
          'normal': [0.0, 0.0, 1.0],
          'xDirection': [1.0, 0.0, 0.0],
          'visualSize': 30.0,
        },
      ),
    );
    final captured = <CadViewportPick>[];
    await f.mount(
      tester,
      onPickCapture: (pick) {
        captured.add(pick);
        return true;
      },
    );
    await tester.tap(find.text('Flutter Canvas'));
    await tester.pumpAndSettle();

    await tap(tester);

    expect(captured.single.entityId, 'world:xy-plane');
    expect(f.selection.calls, 0);
    expect(f.picks, isEmpty);
  });

  testWidgets(
    'axis capture and hover win over an overlapping plane in Native GPU',
    (tester) async {
      final f = _Fixture();
      f.scene
        ..upsert(
          const CadSceneEntity(
            id: 'world:xy-plane',
            kind: CadSceneEntityKind.plane,
            geometry: {
              'origin': [0.0, 0.0, 0.0],
              'normal': [0.0, 0.0, 1.0],
            },
          ),
        )
        ..upsert(
          const CadSceneEntity(
            id: 'world:y-axis',
            kind: CadSceneEntityKind.axis,
            geometry: {
              'origin': [0.0, 0.0, 0.0],
              'direction': [0.0, 1.0, 0.0],
            },
          ),
        );
      final captured = <CadViewportPick>[];
      final hovered = <String?>[];
      await f.mount(
        tester,
        pickCaptureCandidateIds: const {'world:y-axis'},
        onPickCaptureHover: (pick) => hovered.add(pick?.entityId),
        onPickCapture: (pick) {
          captured.add(pick);
          return true;
        },
      );
      final mouse = TestPointer(44, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(600, 400)));
      await tester.pump();
      expect(hovered.last, 'world:y-axis');

      await tap(tester);
      expect(captured.single.entityId, 'world:y-axis');
      expect(f.selection.calls, 0);
    },
  );

  testWidgets('Canvas captures the exact geometry hit without selection', (
    tester,
  ) async {
    final f = _Fixture();
    final captured = <CadViewportPick>[];
    await f.mount(
      tester,
      pickCaptureCandidateIds: const {'a'},
      onPickCapture: (pick) {
        captured.add(pick);
        return true;
      },
    );
    await tester.tap(find.text('Flutter Canvas'));
    await tester.pumpAndSettle();

    await tap(tester);

    expect(captured.single.entityId, 'a');
    expect(captured.single.hit.point.x, closeTo(0, 1e-9));
    expect(captured.single.hit.point.y, closeTo(0, 1e-9));
    expect(captured.single.hit.point.z, closeTo(0, 1e-9));
    expect(f.selection.calls, 0);
    expect(f.picks, isEmpty);
  });

  testWidgets('an empty native click publishes a viewport selection clear', (
    tester,
  ) async {
    final f = _Fixture();
    var clears = 0;
    f.bridge.answer = (_) async => null;
    await f.mount(tester, onViewportSelectionCleared: () => clears++);

    await tap(tester, const Offset(1100, 700));

    expect(clears, 1);
    expect(f.picks, isEmpty);
  });

  testWidgets('Canvas keeps Flutter picking without native pick', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await tester.tap(find.text('Flutter Canvas'));
    await tester.pumpAndSettle();
    await tap(tester);
    expect(f.bridge.positions, isEmpty);
    expect(f.selection.calls, 0);
    expect(f.picks.single.entityId, 'a');
  });

  testWidgets(
    'managed B-Rep hover is face-only and clears without scene data',
    (tester) async {
      final f = _Fixture()..makeManagedCad();
      f.bridge.answer = (_) async => hit('a');
      await f.mount(tester);
      final mouse = TestPointer(17, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(560, 390)));
      await tester.pump();
      expect(f.bridge.managedFaceHovers, [('a', 1)]);
      expect(f.managedFaceSelection.selection, isNull);
      f.bridge.answer = (_) async => null;
      await tester.sendEventToBinding(mouse.hover(const Offset(900, 700)));
      await tester.pump();
      expect(f.bridge.hoverClears, greaterThan(0));
    },
  );

  testWidgets(
    'managed B-Rep click replaces and clears one persistent face selection',
    (tester) async {
      final f = _Fixture()..makeManagedCad();
      f.bridge.answer = (_) async => hit('a');
      await f.mount(tester);
      await tap(tester);
      expect(f.managedFaceSelection.selection?.faceIndex, 1);
      expect(f.selection.active?.type, OperationalEntityType.cadFace);
      expect(f.bridge.managedFaceSelections, [('a', 1)]);

      f.bridge.answer = (_) async => hit('a', subId: 2);
      await tap(tester, const Offset(620, 420));
      expect(f.managedFaceSelection.selection?.faceIndex, 2);
      expect(f.bridge.managedFaceSelections.last, ('a', 2));
      expect(f.bridge.managedFaceSelections, hasLength(2));

      f.bridge.answer = (_) async => null;
      await tap(tester, const Offset(1000, 700));
      expect(f.managedFaceSelection.selection, isNull);
      expect(f.bridge.managedFaceSelectionClears, 1);
    },
  );

  testWidgets('Escape controller clears managed B-Rep selected face', (
    tester,
  ) async {
    final f = _Fixture()..makeManagedCad();
    await f.mount(tester);
    await tap(tester);
    expect(f.managedFaceSelection.selection, isNotNull);
    f.managedFaceSelection.clear();
    await tester.pump();
    expect(f.bridge.managedFaceSelectionClears, 1);
    expect(f.managedFaceSelection.selection, isNull);
  });

  testWidgets('Canvas uses the same managed B-Rep face contract', (
    tester,
  ) async {
    final f = _Fixture()..makeManagedCad();
    await f.mount(tester);
    await tester.tap(find.text('Flutter Canvas'));
    await tester.pumpAndSettle();
    await tap(tester, const Offset(600, 400));
    expect(f.bridge.positions, isEmpty);
    expect(f.picks.single.subentityKind, CadViewportSubentityKind.face);
    expect(f.picks.single.presentationSubId, isNotNull);
    expect(f.managedFaceSelection.selection?.faceIndex, isNotNull);
    await tap(tester, const Offset(1100, 400));
    expect(f.managedFaceSelection.selection, isNull);
  });

  test('STL presentation cannot resolve a managed B-Rep face', () {
    const stl = CadSceneEntity(
      id: 'stl',
      kind: CadSceneEntityKind.mesh,
      geometry: {
        'nodes': [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
        'triangles': [0, 1, 2],
        'stlPresentation': true,
      },
    );
    expect(managedCadFaceHighlight(stl, 1), isNull);
  });

  testWidgets('Sketch suggestion hover is published without changing selection', (
    tester,
  ) async {
    final f = _Fixture();
    f.scene.upsert(
      const CadSceneEntity(
        id: 'suggestion-source',
        kind: CadSceneEntityKind.sketch,
        geometry: {
          'segments': [
            [
              [-1.0, 0.0, 0.0],
              [1.0, 0.0, 0.0],
            ],
          ],
        },
      ),
    );
    final hovered = <CadViewportPick?>[];
    final mouse = TestPointer(71, PointerDeviceKind.mouse);
    await f.mount(tester, onSketchSuggestionHover: hovered.add);
    await tester.sendEventToBinding(mouse.hover(const Offset(600, 400)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(hovered.last?.entityId, 'suggestion-source');
    expect(f.selection.calls, 0);
    await tester.sendEventToBinding(mouse.hover(const Offset(1100, 700)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(hovered.last, isNull);
  });

  testWidgets('Sketch suggestion hover publishes cursor position independently', (
    tester,
  ) async {
    final f = _Fixture();
    f.scene.upsert(
      const CadSceneEntity(
        id: 'suggestion-source',
        kind: CadSceneEntityKind.sketch,
        geometry: {
          'segments': [
            [
              [-1.0, 0.0, 0.0],
              [1.0, 0.0, 0.0],
            ],
          ],
        },
      ),
    );
    final positions = <Offset?>[];
    final mouse = TestPointer(72, PointerDeviceKind.mouse);
    await f.mount(
      tester,
      onSketchSuggestionHoverPosition: positions.add,
    );
    const hoverPoint = Offset(600, 400);
    await tester.sendEventToBinding(mouse.hover(hoverPoint));
    await tester.pump(const Duration(milliseconds: 50));
    expect(positions.last, hoverPoint);
    await tester.sendEventToBinding(mouse.hover(const Offset(1100, 700)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(positions.last, const Offset(1100, 700));
  });

  testWidgets(
    'native empty suggestion filter must not pick mesh, Section, or sketch',
    (tester) async {
      final f = _Fixture();
      f.scene
        ..upsert(
          const CadSceneEntity(
            id: 'imported-mesh',
            kind: CadSceneEntityKind.mesh,
            geometry: {
              'nodes': [-4.0, -4.0, 0.0, 4.0, -4.0, 0.0, 0.0, 4.0, 0.0],
              'triangles': [0, 1, 2],
            },
          ),
        )
        ..upsert(
          const CadSceneEntity(
            id: 'section-reference',
            kind: CadSceneEntityKind.curve,
            geometry: {
              'points': [
                [-4.0, 0.0, 0.0],
                [4.0, 0.0, 0.0],
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
              'segments': [
                [
                  [-1.0, 0.0, 0.0],
                  [1.0, 0.0, 0.0],
                ],
              ],
            },
          ),
        );
      final hovered = <CadViewportPick?>[];
      final mouse = TestPointer(73, PointerDeviceKind.mouse);
      await f.mount(
        tester,
        onSketchSuggestionHover: hovered.add,
        sketchSuggestionPickCandidateIds: const <String>{},
      );
      await tester.sendEventToBinding(mouse.hover(const Offset(600, 400)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(hovered, isNotEmpty);
      expect(
        hovered.last?.entityId,
        isNull,
        reason:
            'Empty Assistant filter must miss mesh/Section/unrelated overlay',
      );
    },
  );

  for (final backendLabel in ['Native GPU', 'Flutter Canvas']) {
    testWidgets(
      'viewport Ctrl-click accumulates and toggles reconstruction suggestions on $backendLabel',
      (tester) async {
        final f = _Fixture();
        final picked = <String>[];
        final selected = <String>{};
        final hovered = <String>[];
        f.scene
          ..upsert(
            const CadSceneEntity(
              id: 'section-reference',
              kind: CadSceneEntityKind.curve,
              geometry: {
                'segments': [
                  [
                    [-2.0, 0.0, 0.0],
                    [-1.0, 0.0, 0.0],
                  ],
                ],
              },
            ),
          )
          ..upsert(
            const CadSceneEntity(
              id: 'suggestion-a',
              kind: CadSceneEntityKind.sketch,
              geometry: {
                'segments': [
                  [
                    [-2.0, 0.0, 0.0],
                    [-1.0, 0.0, 0.0],
                  ],
                ],
              },
            ),
          )
          ..upsert(
            const CadSceneEntity(
              id: 'suggestion-b',
              kind: CadSceneEntityKind.sketch,
              geometry: {
                'segments': [
                  [
                    [1.0, 0.0, 0.0],
                    [2.0, 0.0, 0.0],
                  ],
                ],
              },
            ),
          );
        await f.mount(
          tester,
          sketchEntity: (pick) {
            picked.add(pick.entityId);
            if (HardwareKeyboard.instance.isControlPressed) {
              if (!selected.add(pick.entityId)) selected.remove(pick.entityId);
            } else {
              selected
                ..clear()
                ..add(pick.entityId);
            }
          },
          onSketchSuggestionHover: (pick) {
            if (pick != null) hovered.add(pick.entityId);
          },
          sketchSuggestionPickCandidateIds: const {
            'suggestion-a',
            'suggestion-b',
          },
        );
        expect(f.camera.viewportWidth, greaterThan(1));
        expect(f.camera.viewportHeight, greaterThan(1));
        if (backendLabel == 'Flutter Canvas') {
          await tester.tap(find.text('Flutter Canvas'));
          await tester.pump(const Duration(milliseconds: 100));
        } else {
          await tester.pump(const Duration(milliseconds: 100));
        }

        final pointer = TestPointer(23, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(const Offset(300, 400)));
        await tester.pump();
        await tester.tapAt(const Offset(300, 400));
        await tester.pump();
        if (backendLabel == 'Native GPU') expect(hovered, isNotEmpty);
        expect(selected, {'suggestion-a'});
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tapAt(const Offset(900, 400));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(picked, ['suggestion-a', 'suggestion-b']);
        expect(selected, {'suggestion-a', 'suggestion-b'});

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tapAt(const Offset(300, 400));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(picked, ['suggestion-a', 'suggestion-b', 'suggestion-a']);
        expect(selected, {'suggestion-b'});
      },
    );
  }

  testWidgets(
    'native suggestion hover publishes overlay hit before a slow GPU pick',
    (tester) async {
      final f = _Fixture();
      f.scene.upsert(
        const CadSceneEntity(
          id: 'suggestion-source',
          kind: CadSceneEntityKind.sketch,
          geometry: {
            'segments': [
              [
                [-1.0, 0.0, 0.0],
                [1.0, 0.0, 0.0],
              ],
            ],
          },
        ),
      );
      final gate = Completer<void>();
      f.bridge.answer = (_) async {
        await gate.future;
        return null;
      };
      final hovered = <CadViewportPick?>[];
      final mouse = TestPointer(74, PointerDeviceKind.mouse);
      await f.mount(
        tester,
        onSketchSuggestionHover: hovered.add,
        sketchSuggestionPickCandidateIds: const {'suggestion-source'},
      );
      await tester.sendEventToBinding(mouse.hover(const Offset(600, 400)));
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        hovered.where((hit) => hit?.entityId == 'suggestion-source'),
        isNotEmpty,
        reason: 'Overlay hover must not wait for native.pick',
      );
      gate.complete();
      await tester.pump(const Duration(milliseconds: 50));
    },
  );

  testWidgets(
    'stale native GPU pick cannot replace the latest overlay hover',
    (tester) async {
      final f = _Fixture();
      f.scene.upsert(
        const CadSceneEntity(
          id: 'suggestion-source',
          kind: CadSceneEntityKind.sketch,
          geometry: {
            'segments': [
              [
                [-1.0, 0.0, 0.0],
                [1.0, 0.0, 0.0],
              ],
            ],
          },
        ),
      );
      final gate = Completer<void>();
      f.bridge.answer = (_) async {
        await gate.future;
        return null;
      };
      final hovered = <CadViewportPick?>[];
      final mouse = TestPointer(76, PointerDeviceKind.mouse);
      await f.mount(
        tester,
        onSketchSuggestionHover: hovered.add,
        sketchSuggestionPickCandidateIds: const {'suggestion-source'},
      );
      await tester.sendEventToBinding(mouse.hover(const Offset(600, 400)));
      await tester.pump(const Duration(milliseconds: 20));
      expect(hovered.last?.entityId, 'suggestion-source');
      await tester.sendEventToBinding(mouse.hover(const Offset(1100, 700)));
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        hovered.last,
        isNull,
        reason: 'Overlay must follow the latest pointer before the first GPU pick returns',
      );
      gate.complete();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        hovered.last,
        isNull,
        reason: 'A late GPU result must not resurrect the previous overlay hit',
      );
    },
  );

  testWidgets(
    'canvas suggestion hover with candidates still hits the painted source',
    (tester) async {
      final f = _Fixture();
      f.scene.upsert(
        const CadSceneEntity(
          id: 'suggestion-source',
          kind: CadSceneEntityKind.sketch,
          geometry: {
            'segments': [
              [
                [-1.0, 0.0, 0.0],
                [1.0, 0.0, 0.0],
              ],
            ],
          },
        ),
      );
      final hovered = <CadViewportPick?>[];
      final mouse = TestPointer(75, PointerDeviceKind.mouse);
      await f.mount(
        tester,
        onSketchSuggestionHover: hovered.add,
        sketchSuggestionPickCandidateIds: const {'suggestion-source'},
      );
      await tester.tap(find.text('Flutter Canvas'));
      await tester.pumpAndSettle();
      await tester.sendEventToBinding(mouse.hover(const Offset(600, 400)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(hovered.last?.entityId, 'suggestion-source');
    },
  );

  for (final mode in ['entity', 'support', 'tap', 'double', 'drag']) {
    testWidgets('Sketch $mode retains priority over native selection', (
      tester,
    ) async {
      final f = _Fixture();
      f.scene.upsert(
        const CadSceneEntity(
          id: 'line',
          kind: CadSceneEntityKind.sketch,
          geometry: {
            'points': [
              [-1.0, 0.0, 0.0],
              [1.0, 0.0, 0.0],
            ],
          },
        ),
      );
      var calls = 0;
      var normalSketchCalls = 0;
      await f.mount(
        tester,
        sketchEntity: mode == 'entity' ? (_) => calls++ : null,
        sketchSupport: mode == 'support' ? (_) => calls++ : null,
        sketchTap: mode == 'tap' ? (_) => calls++ : (_) => normalSketchCalls++,
        doublePick: mode == 'double' ? (_) => calls++ : null,
        dragStart: mode == 'drag' ? (_, _) => calls++ : null,
      );
      if (mode == 'drag') {
        await tester.dragFrom(const Offset(600, 400), const Offset(80, 0));
      } else if (mode == 'double') {
        await tap(tester);
        await tester.pump(const Duration(milliseconds: 50));
        await tap(tester);
      } else {
        await tap(tester);
      }
      await tester.pump(const Duration(milliseconds: 350));
      expect(calls, 1);
      expect(normalSketchCalls, 0);
      expect(f.bridge.positions, isEmpty);
      expect(f.selection.calls, 0);
      expect(f.picks, isEmpty);
    });
  }
}
