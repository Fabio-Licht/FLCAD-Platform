import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_derived_edge_classifier.dart';

const _classifier = MeshDerivedEdgeClassifier();

List<num> _squareVertices() => const [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0];

void main() {
  test('remove diagonal interna de plano triangulado e preserva bordas', () {
    final result = _classifier.classify(
      vertices: _squareVertices(),
      triangles: const [0, 1, 2, 0, 2, 3],
    );

    expect(result.statistics.coplanarEdgesDiscarded, 1);
    expect(result.statistics.openBoundaryEdges, 4);
    expect(result.statistics.creaseEdges, 0);
    expect(result.segments, hasLength(4));
    expect(
      result.segments.every((edge) => edge.source == meshDerivedEdgeSource),
      isTrue,
    );
  });

  test('classifica as doze arestas nítidas de um cubo', () {
    const vertices = [
      0,
      0,
      0,
      1,
      0,
      0,
      1,
      1,
      0,
      0,
      1,
      0,
      0,
      0,
      1,
      1,
      0,
      1,
      1,
      1,
      1,
      0,
      1,
      1,
    ];
    const triangles = [
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
      1,
      5,
      6,
      1,
      6,
      2,
      2,
      6,
      7,
      2,
      7,
      3,
      3,
      7,
      4,
      3,
      4,
      0,
    ];
    final result = _classifier.classify(
      vertices: vertices,
      triangles: triangles,
    );

    expect(result.statistics.creaseEdges, 12);
    expect(result.statistics.coplanarEdgesDiscarded, 6);
    expect(result.segments, hasLength(12));
  });

  test('cilindro suave não transforma cada triângulo em aresta', () {
    const sides = 64;
    final vertices = <num>[];
    final triangles = <int>[];
    for (var ring = 0; ring < 2; ring++) {
      final z = ring.toDouble();
      for (var side = 0; side < sides; side++) {
        final angle = side * 2 * math.pi / sides;
        vertices.addAll([math.cos(angle), math.sin(angle), z]);
      }
    }
    for (var side = 0; side < sides; side++) {
      final next = (side + 1) % sides;
      final lower = side;
      final lowerNext = next;
      final upper = sides + side;
      final upperNext = sides + next;
      triangles.addAll([lower, lowerNext, upperNext, lower, upperNext, upper]);
    }
    final result = _classifier.classify(
      vertices: vertices,
      triangles: triangles,
    );

    expect(result.statistics.inputTriangles, sides * 2);
    expect(result.statistics.creaseEdges, 0);
    expect(result.statistics.openBoundaryEdges, sides * 2);
    expect(result.segments, hasLength(sides * 2));
  });

  test('trata borda aberta, duplicação de vértices e normais invertidas', () {
    final vertices = [..._squareVertices(), 0, 0, 0, 1, 0, 0, 0, 1, 0];
    final normals = List<num>.filled(vertices.length, 0);
    for (var index = 2; index < normals.length; index += 3) {
      normals[index] = -1;
    }
    final result = _classifier.classify(
      vertices: vertices,
      triangles: const [0, 1, 2, 4, 5, 6],
      normals: normals,
    );

    expect(result.statistics.openBoundaryEdges, 4);
    expect(result.statistics.weldedVertices, 4);
    expect(result.statistics.inconsistentNormalFaces, greaterThan(0));
    expect(result.diagnostics, contains('inconsistent_supplied_normals'));
  });

  test('diagnostica degenerado, não-manifold e índices inválidos', () {
    final result = _classifier.classify(
      vertices: const [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0],
      triangles: const [0, 1, 2, 0, 1, 3, 1, 0, 2, 0, 1, 0, 0, 1, 99],
    );

    expect(result.statistics.degenerateTriangles, 1);
    expect(result.statistics.invalidTriangles, 1);
    expect(result.statistics.ambiguousEdges, greaterThan(0));
    expect(result.diagnostics, contains('degenerate_triangles'));
    expect(result.diagnostics, contains('invalid_triangle_indices'));
  });

  test('é determinístico e não modifica as entradas', () {
    final vertices = _squareVertices();
    final triangles = <num>[0, 1, 2, 0, 2, 3];
    final originalVertices = List<num>.from(vertices);
    final originalTriangles = List<num>.from(triangles);
    final first = _classifier.classify(
      vertices: vertices,
      triangles: triangles,
    );
    final second = _classifier.classify(
      vertices: vertices,
      triangles: triangles,
    );

    expect(
      first.segments.map((edge) => edge.start).toList(),
      second.segments.map((edge) => edge.start).toList(),
    );
    expect(vertices, originalVertices);
    expect(triangles, originalTriangles);
  });

  test('escala para uma malha comparável à CALOTA', () {
    const side = 270;
    final vertices = Float64List((side + 1) * (side + 1) * 3);
    final triangles = Int32List(side * side * 6);
    var vertexOffset = 0;
    for (var y = 0; y <= side; y++) {
      for (var x = 0; x <= side; x++) {
        vertices[vertexOffset++] = x / side;
        vertices[vertexOffset++] = y / side;
        vertices[vertexOffset++] = 0;
      }
    }
    var triangleOffset = 0;
    int vertex(int x, int y) => y * (side + 1) + x;
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final a = vertex(x, y);
        final b = vertex(x + 1, y);
        final c = vertex(x + 1, y + 1);
        final d = vertex(x, y + 1);
        triangles[triangleOffset++] = a;
        triangles[triangleOffset++] = b;
        triangles[triangleOffset++] = c;
        triangles[triangleOffset++] = a;
        triangles[triangleOffset++] = c;
        triangles[triangleOffset++] = d;
      }
    }
    final stopwatch = Stopwatch()..start();
    final result = _classifier.classify(
      vertices: vertices,
      triangles: triangles,
    );
    stopwatch.stop();

    expect(result.statistics.inputTriangles, 145800);
    expect(result.statistics.coplanarEdgesDiscarded, greaterThan(0));
    expect(result.statistics.creaseEdges, 0);
    expect(result.statistics.segments, greaterThan(0));
    expect(result.statistics.estimatedBytes, greaterThan(0));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
    // Keep the benchmark visible in CI output without making the threshold
    // part of the presentation contract.
    debugPrint(
      'RV-P1c.1 benchmark: ${stopwatch.elapsedMilliseconds} ms, '
      '${result.statistics.segments} segmentos, '
      '${result.statistics.estimatedBytes} bytes estimados',
    );
  });
}
