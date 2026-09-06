import 'dart:io';

import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/entities/entity_curve_service.dart';
import 'package:flcad_mobile/app/entities/entity_plane_service.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Entidades · Curvas', () {
    late Directory directory;
    late CadRuntime runtime;
    late EntityCurveService curves;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('entities_curves_');
      runtime = CadRuntime(kernels: KernelManager());
      await runtime.open('project', directory);
      curves = EntityCurveService(runtime);
    });

    tearDown(() async {
      runtime.dispose();
      await directory.delete(recursive: true);
    });

    test(
      'extracts and persists the external boundary of a face mesh',
      () async {
        runtime.scene.upsert(
          const CadSceneEntity(
            id: 'face:1',
            kind: CadSceneEntityKind.surface,
            geometry: {
              'nodes': [
                0.0,
                0.0,
                0.0,
                4.0,
                0.0,
                0.0,
                4.0,
                3.0,
                0.0,
                0.0,
                3.0,
                0.0,
              ],
              'triangles': [0, 1, 2, 0, 2, 3],
            },
          ),
        );

        final ids = await curves.create(
          method: ConstructionCurveMethod.externalBoundary,
          sourceEntityIds: const ['face:1'],
        );
        final entity = runtime.document!.entities[ids.single]!;
        expect(entity.data['sceneGeometry']['points'], hasLength(5));
        expect(entity.data['constructionEntity']['closed'], isTrue);
        expect(entity.data['sourceEntityIds'], ['face:1']);
        expect(runtime.canUndo, isTrue);
      },
    );

    test(
      'extracts exact U and V curves from a published parametric grid',
      () async {
        runtime.scene.upsert(
          const CadSceneEntity(
            id: 'surface:grid',
            kind: CadSceneEntityKind.surface,
            geometry: {
              'uCount': 3,
              'vCount': 3,
              'nodes': [
                0.0,
                0.0,
                0.0,
                1.0,
                0.0,
                1.0,
                2.0,
                0.0,
                0.0,
                0.0,
                1.0,
                0.0,
                1.0,
                1.0,
                1.0,
                2.0,
                1.0,
                0.0,
                0.0,
                2.0,
                0.0,
                1.0,
                2.0,
                1.0,
                2.0,
                2.0,
                0.0,
              ],
            },
          ),
        );

        final ids = await curves.create(
          method: ConstructionCurveMethod.isoBoth,
          sourceEntityIds: const ['surface:grid'],
          u: 0,
          v: 0,
          pickedPoint: const Vector3(1, 1, 1),
          locateByPickedPoint: true,
        );
        expect(ids, hasLength(2));
        expect(runtime.scene.find(ids[0])!.geometry['points'], [
          [1.0, 0.0, 1.0],
          [1.0, 1.0, 1.0],
          [1.0, 2.0, 1.0],
        ]);
        expect(runtime.scene.find(ids[1])!.geometry['points'], [
          [0.0, 1.0, 0.0],
          [1.0, 1.0, 1.0],
          [2.0, 1.0, 0.0],
        ]);
        expect(
          runtime
              .document!
              .entities[ids.first]!
              .data['constructionEntity']['locatedByPickedPoint'],
          isTrue,
        );
      },
    );

    test('intersects triangulated geometry with a selected plane', () async {
      runtime.scene.upsert(
        const CadSceneEntity(
          id: 'surface:vertical',
          kind: CadSceneEntityKind.surface,
          geometry: {
            'nodes': [
              -2.0,
              0.0,
              -1.0,
              2.0,
              0.0,
              -1.0,
              2.0,
              0.0,
              1.0,
              -2.0,
              0.0,
              1.0,
            ],
            'triangles': [0, 1, 2, 0, 2, 3],
          },
        ),
      );
      final plane = await EntityPlaneService(
        runtime,
      ).create(method: ConstructionPlaneMethod.xy);
      final ids = await curves.create(
        method: ConstructionCurveMethod.surfacePlaneIntersection,
        sourceEntityIds: ['surface:vertical', plane],
      );

      final points = runtime.scene.find(ids.single)!.geometry['points'] as List;
      expect(points.length, greaterThanOrEqualTo(2));
      for (final point in points.cast<List>()) {
        expect(point[2], closeTo(0, 1e-9));
      }
    });

    test('extracts an already published edge without approximation', () async {
      runtime.scene.upsert(
        const CadSceneEntity(
          id: 'edge:1',
          kind: CadSceneEntityKind.curve,
          geometry: {
            'points': [
              [0.0, 0.0, 0.0],
              [1.0, 2.0, 0.0],
              [3.0, 3.0, 1.0],
            ],
          },
        ),
      );
      final id = (await curves.create(
        method: ConstructionCurveMethod.extractEdge,
        sourceEntityIds: const ['edge:1'],
      )).single;

      expect(runtime.scene.find(id)!.geometry['points'], [
        [0.0, 0.0, 0.0],
        [1.0, 2.0, 0.0],
        [3.0, 3.0, 1.0],
      ]);
    });
  });
}
