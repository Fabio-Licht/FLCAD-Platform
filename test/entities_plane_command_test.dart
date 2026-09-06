import 'dart:io';

import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/entities/entity_plane_service.dart';
import 'package:flcad_mobile/app/entities/entity_point_service.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Entidades · Planos', () {
    late Directory directory;
    late CadRuntime runtime;
    late EntityPlaneService planes;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('entities_planes_');
      runtime = CadRuntime(kernels: KernelManager());
      await runtime.open('project', directory);
      planes = EntityPlaneService(runtime);
    });

    tearDown(() async {
      runtime.dispose();
      await directory.delete(recursive: true);
    });

    test('creates the three principal planes persistently', () async {
      final xy = await planes.create(method: ConstructionPlaneMethod.xy);
      final yz = await planes.create(method: ConstructionPlaneMethod.yz);
      final zx = await planes.create(method: ConstructionPlaneMethod.zx);

      expect(runtime.scene.find(xy)!.geometry['normal'], [0.0, 0.0, 1.0]);
      expect(runtime.scene.find(yz)!.geometry['normal'], [1.0, 0.0, 0.0]);
      expect(runtime.scene.find(zx)!.geometry['normal'], [0.0, 1.0, 0.0]);
      expect(runtime.document!.entities[xy]!.data['workspace'], 'Entidades');
    });

    test('constructs a plane through three point entities', () async {
      final pointService = EntityPointService(runtime);
      final ids = <String>[];
      for (final point in const [
        Vector3(0, 0, 2),
        Vector3(4, 0, 2),
        Vector3(0, 5, 2),
      ]) {
        ids.addAll(
          await pointService.create(
            method: ConstructionPointMethod.coordinates,
            coordinates: point,
          ),
        );
      }

      final id = await planes.create(
        method: ConstructionPlaneMethod.threePoints,
        sourceEntityIds: ids,
      );

      expect(runtime.scene.find(id)!.geometry['origin'], [0.0, 0.0, 2.0]);
      expect(runtime.scene.find(id)!.geometry['normal'], [0.0, 0.0, 1.0]);
      expect(
        runtime
            .document!
            .entities[id]!
            .data['constructionEntity']['sourceEntityIds'],
        ids,
      );
    });

    test('creates an associative offset from a selected plane', () async {
      final base = await planes.create(method: ConstructionPlaneMethod.xy);
      final offset = await planes.create(
        method: ConstructionPlaneMethod.offset,
        sourceEntityIds: [base],
        distance: 12.5,
      );

      expect(runtime.scene.find(offset)!.geometry['origin'], [0.0, 0.0, 12.5]);
      expect(
        runtime
            .document!
            .entities[offset]!
            .data['constructionEntity']['distance'],
        12.5,
      );
    });

    test('best-fit extracts a plane and records quality metrics', () async {
      runtime.scene.upsert(
        const CadSceneEntity(
          id: 'mesh:planar',
          kind: CadSceneEntityKind.mesh,
          geometry: {
            'nodes': [
              0.0,
              0.0,
              3.0,
              10.0,
              0.0,
              3.0,
              0.0,
              10.0,
              3.0,
              10.0,
              10.0,
              3.0,
            ],
            'triangles': [0, 1, 2, 1, 3, 2],
          },
        ),
      );

      final id = await planes.create(
        method: ConstructionPlaneMethod.extractPlanar,
        sourceEntityIds: const ['mesh:planar'],
        planarTolerance: .001,
      );
      final contract =
          runtime.document!.entities[id]!.data['constructionEntity'];
      expect(contract['rmsError'], closeTo(0, 1e-9));
      expect(contract['pointCount'], 4);
      expect(runtime.scene.find(id)!.geometry['origin'][2], closeTo(3, 1e-9));
    });

    test('tangent plane uses the exact picked point and mesh normal', () async {
      runtime.scene.upsert(
        const CadSceneEntity(
          id: 'surface:1',
          kind: CadSceneEntityKind.surface,
          geometry: {
            'nodes': [0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 2.0, 0.0],
            'triangles': [0, 1, 2],
          },
        ),
      );
      final id = await planes.create(
        method: ConstructionPlaneMethod.tangentToSurface,
        sourceEntityIds: const ['surface:1'],
        pickedPoint: const Vector3(.5, .5, 0),
        pickedNormal: const Vector3(0, 0, 1),
      );

      expect(runtime.scene.find(id)!.geometry['origin'], [.5, .5, 0.0]);
      expect(runtime.scene.find(id)!.geometry['normal'], [0.0, 0.0, 1.0]);
    });
  });
}
