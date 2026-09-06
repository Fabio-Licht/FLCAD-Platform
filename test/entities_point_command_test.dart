import 'dart:io';

import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/entities/entity_point_service.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Entidades · Pontos', () {
    late Directory directory;
    late CadRuntime runtime;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('entities_points_');
      runtime = CadRuntime(kernels: KernelManager());
      await runtime.open('project', directory);
    });

    tearDown(() async {
      runtime.dispose();
      await directory.delete(recursive: true);
    });

    test('creates a persistent point from absolute coordinates', () async {
      final ids = await EntityPointService(runtime).create(
        method: ConstructionPointMethod.coordinates,
        coordinates: const Vector3(1, 2, 3),
      );

      final entity = runtime.document!.entities[ids.single]!;
      expect(entity.data['sceneGeometry']['position'], [1.0, 2.0, 3.0]);
      expect(entity.data['constructionEntity']['method'], 'coordinates');
      expect(runtime.scene.find(ids.single), isNotNull);
      expect(runtime.canUndo, isTrue);
    });

    test('uses arc length for midpoint and equidistant points', () async {
      runtime.scene.upsert(
        const CadSceneEntity(
          id: 'curve:source',
          kind: CadSceneEntityKind.curve,
          geometry: {
            'points': [
              [0.0, 0.0, 0.0],
              [8.0, 0.0, 0.0],
              [8.0, 2.0, 0.0],
            ],
          },
        ),
      );
      final service = EntityPointService(runtime);
      final midpoint = await service.create(
        method: ConstructionPointMethod.midpoint,
        sourceEntityId: 'curve:source',
      );
      final divided = await service.create(
        method: ConstructionPointMethod.equidistant,
        sourceEntityId: 'curve:source',
        divisionCount: 3,
      );

      expect(
        runtime
            .document!
            .entities[midpoint.single]!
            .data['sceneGeometry']['position'],
        [5.0, 0.0, 0.0],
      );
      expect(divided, hasLength(3));
      expect(
        runtime
            .document!
            .entities[divided[1]]!
            .data['sceneGeometry']['position'],
        [5.0, 0.0, 0.0],
      );
      expect(
        runtime
            .document!
            .entities[divided[1]]!
            .data['constructionEntity']['sourceEntityId'],
        'curve:source',
      );
    });

    test('accepts mesh nodes as source geometry', () async {
      runtime.scene.upsert(
        const CadSceneEntity(
          id: 'mesh:source',
          kind: CadSceneEntityKind.mesh,
          geometry: {
            'nodes': [0.0, 0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 4.0, 6.0],
            'triangles': [0, 1, 2],
          },
        ),
      );

      final ids = await EntityPointService(runtime).create(
        method: ConstructionPointMethod.onEntity,
        sourceEntityId: 'mesh:source',
        parameter: 1,
        pickedPoint: const Vector3(0, 1, 1.5),
      );

      expect(
        runtime
            .document!
            .entities[ids.single]!
            .data['sceneGeometry']['position'],
        [0.0, 1.0, 1.5],
      );
      expect(
        runtime
            .document!
            .entities[ids.single]!
            .data['constructionEntity']['pickedOnGeometry'],
        isTrue,
      );
    });
  });
}
