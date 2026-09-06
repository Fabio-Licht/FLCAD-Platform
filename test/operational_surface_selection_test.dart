import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/operational_entities/operational_entity.dart';
import 'package:flcad_mobile/app/operational_entities/operational_entity_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native surface subshape pick resolves to its document edge', () async {
    final scene = CadSceneGraph()
      ..upsert(
        const CadSceneEntity(
          id: 'Surface001',
          kind: CadSceneEntityKind.surface,
          geometry: <String, dynamic>{},
        ),
      )
      ..upsert(
        const CadSceneEntity(
          id: 'Edge007',
          kind: CadSceneEntityKind.curve,
          geometry: <String, dynamic>{
            'parentSurfaceId': 'Surface001',
            'surfaceEdgeIndex': 3,
          },
        ),
      );
    final registry = OperationalEntityRegistry();
    final resolver = OperationalEntityResolver(registry);

    final result = await resolver.resolve(
      const NativeViewportPick(
        entityId: 'Surface001',
        kind: NativePickKind.edge,
        subId: 3,
        point: <double>[1, 2, 3],
      ),
      scene,
    );

    expect(result?.entity.ownerId, 'Edge007');
    expect(result?.entity.type, OperationalEntityType.topologicalEdge);
  });

  test('native face pick preserves the selectable document owner', () async {
    final scene = CadSceneGraph()
      ..upsert(
        const CadSceneEntity(
          id: 'Face001',
          kind: CadSceneEntityKind.surface,
          geometry: <String, dynamic>{},
        ),
      );
    final registry = OperationalEntityRegistry();
    final result = await OperationalEntityResolver(registry).resolve(
      const NativeViewportPick(
        entityId: 'Face001',
        kind: NativePickKind.face,
        subId: 1,
        point: <double>[2, 3, 0],
      ),
      scene,
    );

    expect(result?.entity.ownerId, 'Face001');
    expect(result?.entity.type, OperationalEntityType.cadFace);
  });

  test(
    'native vertex pick resolves to the published topology vertex',
    () async {
      final scene = CadSceneGraph()
        ..upsert(
          const CadSceneEntity(
            id: 'Surface001',
            kind: CadSceneEntityKind.surface,
            geometry: <String, dynamic>{},
          ),
        )
        ..upsert(
          const CadSceneEntity(
            id: 'Vertex004',
            kind: CadSceneEntityKind.point,
            geometry: <String, dynamic>{
              'parentSurfaceId': 'Surface001',
              'surfaceVertexIndex': 4,
            },
          ),
        );
      final registry = OperationalEntityRegistry();
      final result = await OperationalEntityResolver(registry).resolve(
        const NativeViewportPick(
          entityId: 'Surface001',
          kind: NativePickKind.vertex,
          subId: 4,
          point: <double>[1, 1, 0],
        ),
        scene,
      );

      expect(result?.entity.ownerId, 'Vertex004');
      expect(result?.entity.type, OperationalEntityType.topologicalVertex);
    },
  );

  test('mesh cache does not cross projects that reuse a scene id', () async {
    final registry = OperationalEntityRegistry();
    final resolver = OperationalEntityResolver(registry);
    final firstScene = _meshScene('mesh-v1');
    final first = await resolver.resolve(_meshPick, firstScene);

    expect(first, isNotNull);
    expect(resolver.presentation(first!.entity.id), isNotNull);

    resolver.clear();
    registry.clear();
    final second = await resolver.resolve(_meshPick, _meshScene('mesh-v2'));

    expect(second, isNotNull);
    expect(second!.entity.id, isNot(first.entity.id));
    expect(resolver.presentation(first.entity.id), isNull);
  });

  test('mesh cache invalidates a revised entity with the same id', () async {
    final registry = OperationalEntityRegistry();
    final resolver = OperationalEntityResolver(registry);
    final first = await resolver.resolve(_meshPick, _meshScene('mesh-v1'));
    final second = await resolver.resolve(_meshPick, _meshScene('mesh-v2'));

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(second!.entity.id, isNot(first!.entity.id));
    expect(resolver.presentation(first.entity.id), isNull);
    expect(registry.find(first.entity.id), isNull);
  });
}

const _meshPick = NativeViewportPick(
  entityId: 'Mesh001',
  kind: NativePickKind.face,
  subId: 1,
  point: <double>[0, 0, 0],
);

CadSceneGraph _meshScene(String fingerprint) => CadSceneGraph()
  ..upsert(
    CadSceneEntity(
      id: 'Mesh001',
      kind: CadSceneEntityKind.mesh,
      geometry: <String, dynamic>{
        'fingerprint': fingerprint,
        'nodes': const <double>[0, 0, 0, 1, 0, 0, 0, 1, 0],
        'triangles': const <int>[0, 1, 2],
      },
    ),
  );
