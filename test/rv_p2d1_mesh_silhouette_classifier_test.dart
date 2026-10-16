import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_silhouette_classifier.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_triangle_topology.dart';

const camera = MeshSilhouetteCamera(
  eye: [4, 4, 6],
  target: [0, 0, 0],
  up: [0, 1, 0],
  projection: MeshSilhouetteProjection.perspective,
);

MeshSilhouetteClassification classify(
  List<num> vertices,
  List<num> triangles, {
  MeshSilhouetteCamera view = camera,
  MeshSilhouetteClassifierConfig config =
      const MeshSilhouetteClassifierConfig(),
}) => const MeshSilhouetteClassifier().classify(
  vertices: vertices,
  triangles: triangles,
  camera: view,
  config: config,
);

void main() {
  test('cubo produz silhuetas e é invariável à inversão global', () {
    final vertices = <num>[
      -1,
      -1,
      -1,
      1,
      -1,
      -1,
      1,
      1,
      -1,
      -1,
      1,
      -1,
      -1,
      -1,
      1,
      1,
      -1,
      1,
      1,
      1,
      1,
      -1,
      1,
      1,
    ];
    final triangles = <num>[
      0,
      1,
      2,
      0,
      2,
      3,
      4,
      6,
      5,
      4,
      7,
      6,
      0,
      4,
      5,
      0,
      5,
      1,
      3,
      2,
      6,
      3,
      6,
      7,
      0,
      3,
      7,
      0,
      7,
      4,
      1,
      5,
      6,
      1,
      6,
      2,
    ];
    final original = classify(vertices, triangles);
    final reversed = classify(vertices, [
      for (var i = 0; i < triangles.length; i += 3) ...[
        triangles[i],
        triangles[i + 2],
        triangles[i + 1],
      ],
    ]);
    expect(original.statistics.silhouetteEdges, greaterThan(0));
    expect(
      original.statistics.silhouetteEdges,
      reversed.statistics.silhouetteEdges,
    );
    expect(original.statistics.openBoundaryEdges, 0);
  });

  test('malha aberta preserva bordas abertas', () {
    final result = classify(
      [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0],
      [0, 1, 2, 0, 2, 3],
    );
    expect(result.statistics.openBoundaryEdges, 4);
    expect(
      result.segments.where(
        (s) => s.kind == MeshSilhouetteEdgeKind.openBoundary,
      ),
      hasLength(4),
    );
  });

  test(
    'ortográfica e perspectiva produzem conjuntos dependentes da câmera',
    () {
      final vertices = [-1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1];
      final triangles = [0, 1, 2, 0, 2, 3];
      final ortho = classify(
        vertices,
        triangles,
        view: const MeshSilhouetteCamera(
          eye: [0, 0, 5],
          target: [0, 0, 0],
          up: [0, 1, 0],
          projection: MeshSilhouetteProjection.orthographic,
        ),
      );
      final perspective = classify(
        vertices,
        triangles,
        view: const MeshSilhouetteCamera(
          eye: [0, 0, 5],
          target: [0, 0, 0],
          up: [0, 1, 0],
        ),
      );
      expect(ortho.statistics.openBoundaryEdges, 4);
      expect(perspective.statistics.openBoundaryEdges, 4);
    },
  );

  test('face quase tangente é ambígua com tolerância angular', () {
    final result = classify(
      [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1],
      [0, 1, 2, 0, 3, 4],
      config: const MeshSilhouetteClassifierConfig(angularToleranceDegrees: 20),
    );
    expect(result.statistics.ambiguousEdges, greaterThanOrEqualTo(0));
  });

  test('descarta diagonais coplanares e diagnostica degeneração', () {
    final result = classify(
      [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 2, 2, 2],
      [0, 1, 2, 0, 2, 3, 0, 0, 4],
    );
    expect(result.statistics.coplanarEdges, greaterThan(0));
    expect(result.statistics.degenerateTriangles, 1);
    expect(result.diagnostics, contains('degenerate_triangles'));
  });

  test('não-manifold e limites são diagnosticados sem alterar entradas', () {
    final vertices = <num>[0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 1];
    final triangles = <num>[0, 1, 2, 1, 0, 3, 0, 1, 4];
    final originalVertices = List<num>.from(vertices);
    final originalTriangles = List<num>.from(triangles);
    final result = classify(
      vertices,
      triangles,
      config: const MeshSilhouetteClassifierConfig(maxEdges: 1),
    );
    expect(result.statistics.ambiguousEdges, greaterThan(0));
    expect(result.statistics.truncated, isTrue);
    expect(vertices, originalVertices);
    expect(triangles, originalTriangles);
  });

  test('diagnóstico separa categorias, comprimentos e não-manifold', () {
    final topology = const MeshTriangleTopologyBuilder().build(
      vertices: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 1],
      triangles: [0, 1, 2, 1, 0, 3, 0, 1, 4],
    );
    final result = const MeshSilhouetteClassifier().classifyTopology(
      topology: topology,
      camera: camera,
    );
    final diagnostic = diagnoseMeshSilhouette(result, topology);
    expect(diagnostic.ambiguous, greaterThan(0));
    expect(diagnostic.nonManifoldEdges, 1);
    expect(diagnostic.lengths['ambiguous']!.count, greaterThan(0));
    expect(diagnostic.lengths['ambiguous']!.median, greaterThan(0));
    expect(
      diagnostic.shortByCategory.keys,
      containsAll(['silhouette', 'openBoundary', 'ambiguous']),
    );
    expect(diagnostic.windingInconsistencies, isNull);
    expect(diagnostic.toJson()['windingStatus'], 'not_measured');
  });

  test('transformação é aplicada apenas à apresentação', () {
    final vertices = <num>[0, 0, 0, 1, 0, 0, 0, 1, 0];
    final before = List<num>.from(vertices);
    final result = classify(
      vertices,
      [0, 1, 2],
      config: const MeshSilhouetteClassifierConfig(
        transform: [2, 0, 0, 10, 0, 2, 0, 20, 0, 0, 2, 30, 0, 0, 0, 1],
      ),
    );
    expect(result.segments, isNotEmpty);
    expect(vertices, before);
  });

  test('escala comparável à CALOTA mantém custo linear e estatísticas', () {
    final vertices = <num>[];
    final triangles = <num>[];
    for (var i = 0; i < 145216; i++) {
      final base = vertices.length ~/ 3;
      vertices.addAll([
        i.toDouble(),
        0,
        0,
        i.toDouble() + 1,
        0,
        0,
        i.toDouble(),
        1,
        0,
      ]);
      triangles.addAll([base, base + 1, base + 2]);
    }
    final stopwatch = Stopwatch()..start();
    final result = classify(
      vertices,
      triangles,
      config: const MeshSilhouetteClassifierConfig(
        maxTriangles: 145216,
        maxEdges: 500000,
      ),
    );
    stopwatch.stop();
    expect(result.statistics.inputTriangles, 145216);
    expect(result.statistics.estimatedBytes, greaterThan(0));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
  });
}
