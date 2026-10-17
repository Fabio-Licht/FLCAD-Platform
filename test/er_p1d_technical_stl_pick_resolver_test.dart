import 'dart:async';

import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/technical_stl_pick_resolver.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/entity_placement.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final geometry = KernelMeshGeometry(
    nodes: const [0, 0, 0, 10, 0, 0, 0, 10, 0, 100, 100, 100],
    triangles: const [0, 1, 2],
  );

  CadDocumentEntity entity(String sha, {EntityPlacement? placement}) =>
      CadDocumentEntity(
        id: 'stl',
        kind: CadDocumentEntityKind.import,
        placement: placement,
        data: {
          'managedStlAssets': {'displayMeshSha256': sha},
        },
      );

  test('returns original triangle and normal, never a LOD index', () async {
    var loads = 0;
    final resolver = TechnicalStlPickResolver(
      null,
      entityProvider: (_) => entity('sha-a'),
      geometryLoader: (_) async {
        loads++;
        return geometry;
      },
    );
    final hit = await resolver.resolve(
      entityId: 'stl',
      worldRay: const MeshRay(Vector3(2, 2, 10), Vector3(0, 0, -1)),
    );
    expect(hit?.triangleIndex, 0);
    expect(hit?.point.x, 2);
    expect(hit?.point.y, 2);
    expect(hit?.point.z, 0);
    expect(hit?.normal.z, 1);
    expect(loads, 1);
    expect(resolver.cachedMeshCount, 1);
  });

  test('cache hit, revision invalidation and miss are safe', () async {
    var sha = 'sha-a';
    var loads = 0;
    final resolver = TechnicalStlPickResolver(
      null,
      entityProvider: (_) => entity(sha),
      geometryLoader: (_) async {
        loads++;
        return geometry;
      },
    );
    final ray = const MeshRay(Vector3(2, 2, 10), Vector3(0, 0, -1));
    await resolver.resolve(entityId: 'stl', worldRay: ray);
    await resolver.resolve(entityId: 'stl', worldRay: ray);
    expect(loads, 1);
    sha = 'sha-b';
    await resolver.resolve(entityId: 'stl', worldRay: ray);
    expect(loads, 2);
    expect(
      await resolver.resolve(
        entityId: 'stl',
        worldRay: const MeshRay(Vector3(50, 50, 10), Vector3(0, 0, -1)),
      ),
      isNull,
    );
  });

  test('applies rigid translation to the ray and returned hit', () async {
    final placement = EntityPlacement.identity(const [
      0,
      0,
      0,
    ]).translate(10, 20, 30);
    final resolver = TechnicalStlPickResolver(
      null,
      entityProvider: (_) => entity('sha-a', placement: placement),
      geometryLoader: (_) async => geometry,
    );
    final hit = await resolver.resolve(
      entityId: 'stl',
      worldRay: const MeshRay(Vector3(12, 22, 40), Vector3(0, 0, -1)),
    );
    expect(hit?.point.x, 12);
    expect(hit?.point.y, 22);
    expect(hit?.point.z, 30);
    expect(hit?.triangleIndex, 0);
  });

  test('stale request is discarded after invalidation', () async {
    final gate = Completer<KernelMeshGeometry?>();
    final resolver = TechnicalStlPickResolver(
      null,
      entityProvider: (_) => entity('sha-a'),
      geometryLoader: (_) => gate.future,
    );
    final pending = resolver.resolve(
      entityId: 'stl',
      worldRay: const MeshRay(Vector3(2, 2, 10), Vector3(0, 0, -1)),
    );
    resolver.invalidate('stl');
    gate.complete(geometry);
    expect(await pending, isNull);
  });

  test(
    'invalid geometry and entity removal do not retain technical cache',
    () async {
      var present = true;
      var valid = false;
      final resolver = TechnicalStlPickResolver(
        null,
        entityProvider: (_) => present ? entity('sha-a') : null,
        geometryLoader: (_) async => valid
            ? geometry
            : const KernelMeshGeometry(nodes: [0, 0, 0], triangles: [0, 1, 2]),
      );
      final ray = const MeshRay(Vector3(2, 2, 10), Vector3(0, 0, -1));
      expect(await resolver.resolve(entityId: 'stl', worldRay: ray), isNull);
      expect(resolver.cachedMeshCount, 0);
      valid = true;
      expect(await resolver.resolve(entityId: 'stl', worldRay: ray), isNotNull);
      present = false;
      expect(await resolver.resolve(entityId: 'stl', worldRay: ray), isNull);
      expect(resolver.cachedMeshCount, 0);
    },
  );
}
