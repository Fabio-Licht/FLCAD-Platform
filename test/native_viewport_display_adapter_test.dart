import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

void main() {
  test(
    'native display adapter emits initial snapshot and incremental delta',
    () {
      final scene = CadSceneGraph();
      final geometry = <String, dynamic>{
        'nodes': <double>[0, 0, 0, 1, 0, 0, 0, 1, 0],
        'triangles': <int>[0, 1, 2],
      };
      scene.upsert(
        CadSceneEntity(
          id: 'mesh:1',
          kind: CadSceneEntityKind.mesh,
          geometry: geometry,
        ),
      );
      final adapter = CadSceneDisplayAdapter();
      final initial = adapter.initial(scene);
      expect(initial.entities, hasLength(1));
      expect(initial.entities.single['nodes'], geometry['nodes']);
      expect(initial.entities.single['normals'], [0, 0, 1, 0, 0, 1, 0, 0, 1]);
      final derived = initial.entities.single['meshDerivedEdges'] as Map;
      expect(derived['source'], 'meshDerived');
      expect(derived['segments'], hasLength(3));
      expect(
        (derived['segments'] as List).every(
          (segment) => segment['kind'] is String,
        ),
        isTrue,
      );

      expect(adapter.delta(scene).entities, isEmpty);
      scene.select({'mesh:1'});
      final selectionDelta = adapter.delta(scene);
      expect(selectionDelta.entities, hasLength(1));
      expect(selectionDelta.entities.single['selected'], isTrue);
      expect(selectionDelta.entities.single.containsKey('nodes'), isFalse);

      scene.remove('mesh:1');
      expect(adapter.delta(scene).entities.single['removed'], isTrue);
    },
  );

  test('mesh-derived edges stay separate from BREP topology', () {
    final mesh = CadSceneEntity(
      id: 'stl:1',
      kind: CadSceneEntityKind.mesh,
      geometry: const {
        'nodes': [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
        'triangles': [0, 1, 2],
      },
    );
    final brep = CadSceneEntity(
      id: 'brep:1',
      kind: CadSceneEntityKind.surface,
      geometry: const {
        'nodes': [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
        'triangles': [0, 1, 2],
        'topologicalEdges': [
          [0.0, 0.0, 0.0, 1.0, 0.0, 0.0],
        ],
      },
    );
    final snapshot = CadSceneDisplayAdapter().initial(
      CadSceneGraph()
        ..upsert(mesh)
        ..upsert(brep),
    );
    final stl = snapshot.entities.firstWhere(
      (entity) => entity['id'] == 'stl:1',
    );
    final cad = snapshot.entities.firstWhere(
      (entity) => entity['id'] == 'brep:1',
    );
    expect(stl['meshDerivedEdges'], isA<Map>());
    expect(stl['topologicalEdges'], isNull);
    expect(cad['topologicalEdges'], isNotNull);
    expect(cad['meshDerivedEdges'], isNull);
  });

  test('managed B-Rep face ranges publish once and never in display delta', () {
    final scene = CadSceneGraph()
      ..upsert(
        const CadSceneEntity(
          id: 'step:1',
          kind: CadSceneEntityKind.mesh,
          geometry: {
            'nodes': [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
            'triangles': [0, 1, 2],
            'brepPresentation': {
              'nodes': [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
              'normals': [0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0],
              'triangles': [0, 1, 2],
              'faceTriangleRanges': [
                [1, 1],
              ],
            },
          },
        ),
      );
    final adapter = CadSceneDisplayAdapter();
    final initial = adapter.initial(scene).entities.single;
    expect(initial['faceTriangleRanges'], [
      [1, 1],
    ]);
    scene.select({'step:1'});
    final delta = adapter.delta(scene).entities.single;
    expect(delta['selected'], isTrue);
    expect(delta, isNot(contains('nodes')));
    expect(delta, isNot(contains('faceTriangleRanges')));
  });

  testWidgets('managed face interaction sends only lightweight host state', (
    tester,
  ) async {
    const channel = MethodChannel('flcad/native_viewport');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final bridge = NativeViewportBridge()..available = true;
    await bridge.setManagedCadFaceHover(
      entityId: 'step:1',
      presentationSubId: 17,
    );
    await bridge.setManagedCadFaceSelection(
      entityId: 'step:1',
      presentationSubId: 17,
    );
    await bridge.clearManagedCadFaceSelection();
    expect(calls.map((call) => call.method), [
      'setManagedCadFaceHover',
      'setManagedCadFaceSelection',
      'clearManagedCadFaceSelection',
    ]);
    for (final call in calls.take(2)) {
      expect(call.arguments, {'entityId': 'step:1', 'presentationSubId': 17});
      expect((call.arguments as Map).containsKey('nodes'), isFalse);
      expect((call.arguments as Map).containsKey('triangles'), isFalse);
    }
  });
}
