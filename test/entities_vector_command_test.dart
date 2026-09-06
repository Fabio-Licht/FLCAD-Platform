import 'dart:io';

import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/entities/entity_plane_service.dart';
import 'package:flcad_mobile/app/entities/entity_point_service.dart';
import 'package:flcad_mobile/app/entities/entity_vector_service.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Entidades · Vetores', () {
    late Directory directory;
    late CadRuntime runtime;
    late EntityVectorService vectors;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('entities_vectors_');
      runtime = CadRuntime(kernels: KernelManager());
      await runtime.open('project', directory);
      vectors = EntityVectorService(runtime);
    });

    tearDown(() async {
      runtime.dispose();
      await directory.delete(recursive: true);
    });

    test('creates principal and component vectors with magnitude', () async {
      final x = await vectors.create(method: ConstructionVectorMethod.xAxis);
      final custom = await vectors.create(
        method: ConstructionVectorMethod.components,
        origin: const Vector3(1, 2, 3),
        components: const Vector3(0, 3, 4),
      );

      expect(runtime.scene.find(x)!.geometry['direction'], [1.0, 0.0, 0.0]);
      expect(runtime.scene.find(custom)!.geometry['origin'], [1.0, 2.0, 3.0]);
      expect(runtime.scene.find(custom)!.geometry['direction'], [0.0, .6, .8]);
      expect(
        runtime
            .document!
            .entities[custom]!
            .data['constructionEntity']['magnitude'],
        5,
      );
    });

    test('creates an associative vector between two points', () async {
      final points = EntityPointService(runtime);
      final a = (await points.create(
        method: ConstructionPointMethod.coordinates,
        coordinates: const Vector3(2, 3, 4),
      )).single;
      final b = (await points.create(
        method: ConstructionPointMethod.coordinates,
        coordinates: const Vector3(2, 3, 14),
      )).single;

      final id = await vectors.create(
        method: ConstructionVectorMethod.twoPoints,
        sourceEntityIds: [a, b],
      );

      expect(runtime.scene.find(id)!.geometry['origin'], [2.0, 3.0, 4.0]);
      expect(runtime.scene.find(id)!.geometry['direction'], [0.0, 0.0, 1.0]);
      expect(
        runtime
            .document!
            .entities[id]!
            .data['constructionEntity']['sourceEntityIds'],
        [a, b],
      );
    });

    test('extracts plane normal and plane intersection direction', () async {
      final planes = EntityPlaneService(runtime);
      final xy = await planes.create(method: ConstructionPlaneMethod.xy);
      final yz = await planes.create(method: ConstructionPlaneMethod.yz);
      final normal = await vectors.create(
        method: ConstructionVectorMethod.planeNormal,
        sourceEntityIds: [xy],
      );
      final intersection = await vectors.create(
        method: ConstructionVectorMethod.planeIntersection,
        sourceEntityIds: [xy, yz],
      );

      expect(runtime.scene.find(normal)!.geometry['direction'], [
        0.0,
        0.0,
        1.0,
      ]);
      expect(runtime.scene.find(intersection)!.geometry['direction'], [
        0.0,
        1.0,
        0.0,
      ]);
    });

    test('uses local clicked normal from a surface', () async {
      runtime.scene.upsert(
        const CadSceneEntity(
          id: 'mesh:face',
          kind: CadSceneEntityKind.mesh,
          geometry: {
            'nodes': [0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 3.0, 0.0],
            'triangles': [0, 1, 2],
          },
        ),
      );
      final id = await vectors.create(
        method: ConstructionVectorMethod.surfaceNormal,
        sourceEntityIds: const ['mesh:face'],
        pickedPoint: const Vector3(1, 1, 0),
        pickedNormal: const Vector3(0, 0, 1),
      );

      expect(runtime.scene.find(id)!.geometry['origin'], [1.0, 1.0, 0.0]);
      expect(runtime.scene.find(id)!.geometry['direction'], [0.0, 0.0, 1.0]);
    });

    test('best-fit direction records real fitting metrics', () async {
      runtime.scene.upsert(
        const CadSceneEntity(
          id: 'scan:linear',
          kind: CadSceneEntityKind.mesh,
          geometry: {
            'nodes': [
              0.0,
              1.0,
              2.0,
              5.0,
              1.0,
              2.0,
              10.0,
              1.0,
              2.0,
              15.0,
              1.0,
              2.0,
            ],
            'triangles': <int>[],
          },
        ),
      );
      final id = await vectors.create(
        method: ConstructionVectorMethod.bestFitDirection,
        sourceEntityIds: const ['scan:linear'],
      );
      final contract =
          runtime.document!.entities[id]!.data['constructionEntity'];

      expect(contract['rmsError'], closeTo(0, 1e-9));
      expect(contract['pointCount'], 4);
      final direction = runtime.scene.find(id)!.geometry['direction'] as List;
      expect((direction[0] as num).abs(), closeTo(1, 1e-9));
    });
  });
}
