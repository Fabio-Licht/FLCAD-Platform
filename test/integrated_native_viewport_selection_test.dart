import 'dart:async';

import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/native/integrated_native_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/professional_cad_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
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
  Future<void> sendInitial(CadSceneGraph scene) async {}
  @override
  Future<void> sendDelta(CadSceneGraph scene) async {}
  @override
  Future<void> setCamera(CadCameraController camera) async {}
  @override
  Future<void> clearHover() async {}
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

NativeViewportPick hit(String id, {List<double> point = const [1, 2, 3]}) =>
    NativeViewportPick(
      entityId: id,
      kind: NativePickKind.face,
      subId: 1,
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
        geometry: {},
      ),
    );

  Future<void> mount(
    WidgetTester tester, {
    OperationalEntityResolver? resolver,
    ValueChanged<Offset>? sketchTap,
    ValueChanged<CadViewportPick>? sketchEntity,
    ValueChanged<CadViewportPick>? sketchSupport,
    ValueChanged<CadViewportPick>? doublePick,
    void Function(CadViewportPick, Offset)? dragStart,
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
          onPick: picks.add,
          onSketchTap: sketchTap,
          onSketchEntityPick: sketchEntity,
          onSketchSupportPick: sketchSupport,
          onSketchEntityDoublePick: doublePick,
          onSketchEntityDragStart: dragStart,
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

  testWidgets('Canvas keeps Flutter picking without native pick', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await tester.tap(find.text('Flutter Canvas'));
    await tester.pump();
    await tap(tester);
    expect(f.bridge.positions, isEmpty);
    expect(f.selection.calls, 0);
    expect(f.picks.single.entityId, 'a');
  });

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
