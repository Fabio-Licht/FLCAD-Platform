import 'dart:collection';

import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/professional_cad_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/stl_display_lod.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/operational_entities/operational_entity.dart';
import 'package:flcad_mobile/app/operational_entities/operational_entity_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

class _LengthOnly extends ListBase<num> {
  _LengthOnly(this.length);
  @override
  int length;
  @override
  num operator [](int i) => throw StateError('Preflight accessed geometry');
  @override
  void operator []=(int i, num value) => throw UnsupportedError('read only');
}

void main() {
  test(
    'dense STL preflight rejects on lengths before allocation or traversal',
    () {
      expect(
        () => StlDisplayLod.preflight({
          'stlPresentation': true,
          'nodes': _LengthOnly(980120 * 3),
          'triangles': _LengthOnly(1956958 * 3),
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'cause',
            'STL presentation budget exceeded',
          ),
        ),
      );
    },
  );
  final geometry = <String, dynamic>{
    'nodes': <double>[0, 0, 0, 1, 0, 0, 0, 1, 0],
    'normals': <double>[0, 0, 1, 0, 0, 1, 0, 0, 1],
    'triangles': <int>[0, 1, 2],
    'bounds': <double>[0, 0, 0, 1, 1, 0],
    'stlPresentation': true,
    'presentationLod': {
      'version': 1,
      'method': 'spatial-clustering-v1',
      'measurementSafe': false,
      'originalTriangles': 1956958,
      'originalVertices': 980120,
      'displayTriangles': 1,
      'displayVertices': 3,
    },
  };
  test('LOD GPU snapshot remains indexed and shares bounded lists', () {
    final scene = CadSceneGraph();
    addTearDown(scene.dispose);
    scene.upsert(
      CadSceneEntity(
        id: 'stl',
        kind: CadSceneEntityKind.mesh,
        geometry: geometry,
      ),
    );
    final message = CadSceneDisplayAdapter().initial(scene).entities.single;
    expect(identical(message['nodes'], geometry['nodes']), isTrue);
    expect(identical(message['normals'], geometry['normals']), isTrue);
    expect(identical(message['triangles'], geometry['triangles']), isTrue);
    expect(message['presentationLod'], geometry['presentationLod']);
  });
  testWidgets(
    'real viewport observes LOD publication and removes its warning',
    (tester) async {
      final scene = CadSceneGraph();
      final camera = CadCameraController();
      addTearDown(scene.dispose);
      addTearDown(camera.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfessionalCadViewportWidget(
            scene: scene,
            camera: camera,
            renderMeshes: false,
            enablePicking: false,
          ),
        ),
      );
      expect(find.textContaining('Visualização simplificada'), findsNothing);
      scene.upsert(
        CadSceneEntity(
          id: 'stl',
          kind: CadSceneEntityKind.mesh,
          geometry: geometry,
        ),
      );
      await tester.pump();
      expect(find.textContaining('1956958 → 1 triângulos'), findsOneWidget);
      expect(
        find.textContaining(
          'Medição convencional e seleção de região indisponíveis.',
        ),
        findsOneWidget,
      );
      scene.remove('stl');
      await tester.pump();
      expect(find.textContaining('Visualização simplificada'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('recognition workspace keeps technical STL recognition available', (
    tester,
  ) async {
    final scene = CadSceneGraph();
    final camera = CadCameraController();
    addTearDown(scene.dispose);
    addTearDown(camera.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ProfessionalCadViewportWidget(
          scene: scene,
          camera: camera,
          renderMeshes: false,
          enablePicking: false,
          technicalRecognitionAvailable: true,
        ),
      ),
    );
    scene.upsert(
      CadSceneEntity(
        id: 'stl',
        kind: CadSceneEntityKind.mesh,
        geometry: geometry,
      ),
    );
    await tester.pump();
    expect(
      find.textContaining('Medição convencional indisponível.'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Reconhecimento técnico disponível na STL original no workspace Reconhecimento.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('LOD rejects contradictory counts and missing normals', () {
    for (final invalid in [
      {...geometry, 'normals': null},
      {
        ...geometry,
        'presentationLod': {
          ...geometry['presentationLod'] as Map,
          'displayTriangles': 2,
        },
      },
    ]) {
      expect(() => StlDisplayLod.preflight(invalid), throwsFormatException);
    }
  });
  test(
    'LOD resolves entity selection without region/measurement claims',
    () async {
      final registry = OperationalEntityRegistry();
      final resolver = OperationalEntityResolver(registry);
      final scene = CadSceneGraph();
      addTearDown(scene.dispose);
      scene.upsert(
        CadSceneEntity(
          id: 'stl',
          kind: CadSceneEntityKind.mesh,
          geometry: geometry,
        ),
      );
      resolver.prepare(scene);
      final result = await resolver.resolve(
        const NativeViewportPick(
          entityId: 'stl',
          kind: NativePickKind.face,
          subId: 1,
          point: [0, 0, 0],
        ),
        scene,
      );
      expect(result!.entity.ownerId, 'stl');
      expect(result.entity.capabilities, {OperationalCapability.selectable});
      expect(result.entity.properties['measurementSafe'], isFalse);
      expect(result.triangleIndices, isEmpty);
    },
  );
}
