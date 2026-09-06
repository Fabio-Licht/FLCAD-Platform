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
}
