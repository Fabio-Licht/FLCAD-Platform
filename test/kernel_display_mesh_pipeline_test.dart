import 'dart:io';

import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/kernel_display_mesh_pipeline.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late CadSceneGraph scene;
  late _DisplayKernel kernel;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('display-pipeline-');
    scene = CadSceneGraph();
    kernel = _DisplayKernel();
  });

  tearDown(() async {
    scene.dispose();
    await directory.delete(recursive: true);
  });

  test('BREP inspection failure preserves the published STL display mesh', () async {
    kernel.throwOnInspection = true;

    await _upsert(kernel, scene, directory, _shape('solid'));

    final geometry = scene.find('extrude')!.geometry;
    expect(geometry['nodes'], isNotEmpty);
    expect(geometry['triangles'], isNotEmpty);
    expect(geometry.containsKey('brepPresentation'), isFalse);
    expect(geometry.containsKey('topologicalEdges'), isFalse);
    expect(kernel.inspectionCalls, 1);
    expect(nativeSceneUnsupportedReason(scene, style: 0), isNull);
  });

  test('valid BREP cache for the same ShapeHandle avoids a new inspection', () async {
    final shape = _shape('solid', revision: 2, fingerprint: 'v2');
    await _upsert(kernel, scene, directory, shape);
    await _upsert(kernel, scene, directory, shape);

    expect(kernel.inspectionCalls, 1);
    expect(scene.find('extrude')!.geometry['topologicalEdges'], isNotEmpty);
  });

  test('different ShapeHandle invalidates cache even for the same entity id', () async {
    await _upsert(kernel, scene, directory, _shape('solid-a'));
    await _upsert(kernel, scene, directory, _shape('solid-b'));

    expect(kernel.inspectionCalls, 2);
    expect(
      (scene.find('extrude')!.geometry['brepPresentationHandle'] as Map)[
        'persistentId'
      ],
      'solid-b',
    );
  });

  test('invalid cached edges are discarded and inspected again', () async {
    final shape = _shape('solid');
    _seedCachedPresentation(scene, shape, const [[0, 0, 0, 1, 0]]);

    await _upsert(kernel, scene, directory, shape);

    expect(kernel.inspectionCalls, 1);
    expect(scene.find('extrude')!.geometry['topologicalEdges'], _edges);
  });

  test('cached edge with incompatible coordinate count is reinspected', () async {
    final shape = _shape('solid');
    _seedCachedPresentation(scene, shape, const [[0, 0, 0, 1, 0, 0, 2]]);

    await _upsert(kernel, scene, directory, shape);

    expect(kernel.inspectionCalls, 1);
    expect(scene.find('extrude')!.geometry['topologicalEdges'], _edges);
  });

  test('cached edge with NaN coordinate is reinspected', () async {
    final shape = _shape('solid');
    _seedCachedPresentation(scene, shape, [
      [0, 0, 0, double.nan, 0, 0],
    ]);

    await _upsert(kernel, scene, directory, shape);

    expect(kernel.inspectionCalls, 1);
    expect(scene.find('extrude')!.geometry['topologicalEdges'], _edges);
  });

  test('cached edge with infinite coordinate is reinspected', () async {
    final shape = _shape('solid');
    _seedCachedPresentation(scene, shape, [
      [0, 0, 0, double.infinity, 0, 0],
    ]);

    await _upsert(kernel, scene, directory, shape);

    expect(kernel.inspectionCalls, 1);
    expect(scene.find('extrude')!.geometry['topologicalEdges'], _edges);
  });

  test('current fingerprint without cached fingerprint invalidates cache', () async {
    await _upsert(kernel, scene, directory, _shape('solid'));
    await _upsert(kernel, scene, directory, _shape('solid', fingerprint: 'v2'));

    expect(kernel.inspectionCalls, 2);
  });

  test('different fingerprints invalidate cache', () async {
    await _upsert(kernel, scene, directory, _shape('solid', fingerprint: 'v1'));
    await _upsert(kernel, scene, directory, _shape('solid', fingerprint: 'v2'));

    expect(kernel.inspectionCalls, 2);
  });

  test('equal fingerprints reuse cache', () async {
    final shape = _shape('solid', fingerprint: 'stable');
    await _upsert(kernel, scene, directory, shape);
    await _upsert(kernel, scene, directory, shape);

    expect(kernel.inspectionCalls, 1);
  });

  test('invalidated cache falls back to STL when its new inspection fails', () async {
    final oldShape = _shape('solid', revision: 1, fingerprint: 'v1');
    await _upsert(kernel, scene, directory, oldShape);
    kernel.throwOnInspection = true;

    await _upsert(kernel, scene, directory, _shape('solid', revision: 2, fingerprint: 'v2'));

    final geometry = scene.find('extrude')!.geometry;
    expect(kernel.inspectionCalls, 2);
    expect(geometry['nodes'], isNotEmpty);
    expect(geometry['triangles'], isNotEmpty);
    expect(geometry.containsKey('brepPresentation'), isFalse);
    expect(geometry.containsKey('topologicalEdges'), isFalse);
  });
}

Future<void> _upsert(
  _DisplayKernel kernel,
  CadSceneGraph scene,
  Directory directory,
  ShapeHandle shape,
) => KernelDisplayMeshPipeline(
  kernel: kernel,
  projectId: 'test',
  projectDirectory: directory,
  scene: scene,
).upsert(entityId: 'extrude', shape: shape);

ShapeHandle _shape(
  String persistentId, {
  int revision = 1,
  String? fingerprint,
}) => ShapeHandle.reference(
  persistentId: persistentId,
  kernelId: 'fixture',
  type: CADShapeType.solid,
  revision: revision,
  fingerprint: fingerprint,
);

void _seedCachedPresentation(
  CadSceneGraph scene,
  ShapeHandle shape,
  List<List<num>> edges,
) {
  scene.upsert(
    CadSceneEntity(
      id: 'extrude',
      kind: CadSceneEntityKind.solid,
      geometry: {
        'brepPresentation': {'topologicalEdges': edges},
        'brepPresentationHandle': shape.toJson(),
        'topologicalEdges': edges,
      },
    ),
  );
}

const _edges = [
  [0.0, 0.0, 0.0, 1.0, 0.0, 0.0],
];

class _DisplayKernel extends UnavailableGeometryKernel
    implements
        InterchangeGeometryKernelAPI,
        MeshGeometryKernelAPI,
        BrepPresentationGeometryKernelAPI {
  var inspectionCalls = 0;
  var throwOnInspection = false;

  @override
  Future<KernelMeshResult> mesh(
    ShapeHandle handle, {
    required String outputPath,
    required double deflection,
  }) async => KernelMeshResult(
    source: handle,
    vertexCount: 3,
    triangleCount: 1,
    payloadPath: outputPath,
  );

  @override
  Future<KernelMeshHandle> importStl(
    String path, {
    required String projectId,
    KernelImportFormat format = KernelImportFormat.autoDetect,
    KernelCancellationToken cancellation = const NoKernelCancellation(),
    void Function(KernelProgress progress)? onProgress,
  }) async => const KernelMeshHandle(
    persistentId: 'mesh',
    kernelId: 'fixture',
    fingerprint: 'mesh',
    vertexCount: 3,
    triangleCount: 1,
    bounds: KernelBounds(0, 0, 0, 1, 1, 0),
    hasNormals: false,
    metadata: {},
  );

  @override
  Future<KernelMeshGeometry> inspectMesh(KernelMeshHandle handle) async =>
      const KernelMeshGeometry(
        nodes: [0, 0, 0, 1, 0, 0, 0, 1, 0],
        triangles: [0, 1, 2],
      );

  @override
  Future<void> closeMesh(KernelMeshHandle handle) async {}

  @override
  Future<Map<String, dynamic>?> inspectBrepPresentation(
    ShapeHandle handle,
  ) async {
    inspectionCalls++;
    if (throwOnInspection) throw StateError('Native BREP display unavailable');
    return const {'topologicalEdges': _edges};
  }

  @override
  Future<ShapeHandle> importFile(
    String path,
    KernelExchangeFormat format, {
    required String projectId,
    KernelCancellationToken cancellation = const NoKernelCancellation(),
    void Function(KernelProgress progress)? onProgress,
  }) => throw UnimplementedError();

  @override
  Future<void> exportFile(
    ShapeHandle handle,
    String path,
    KernelExchangeFormat format, {
    KernelCancellationToken cancellation = const NoKernelCancellation(),
    void Function(KernelProgress progress)? onProgress,
  }) => throw UnimplementedError();

  @override
  Future<List<GeometryDiagnostic>> diagnose(ShapeHandle handle) =>
      throw UnimplementedError();

  @override
  Future<List<HealingProposal>> proposeHealing(ShapeHandle handle) =>
      throw UnimplementedError();

  @override
  Future<ShapeHandle> sew(
    List<ShapeHandle> faces, {
    required String projectId,
    required double tolerance,
  }) => throw UnimplementedError();
}
