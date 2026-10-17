import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/surface_recognition/models/surface_recognition_models.dart';
import 'package:flcad_mobile/core/surface_recognition/segmentation/region_growing.dart';

void main() {
  test('planar prism face remains CAD candidate at a mechanical boundary', () {
    const n = 20;
    final vertices = <Vector3>[];
    final triangles = <(int, int, int)>[];
    Vector3 top(int x, int y) => Vector3(x.toDouble(), y.toDouble(), 4);
    Vector3 bottom(int x, int y) => Vector3(x.toDouble(), y.toDouble(), 0);
    for (var y = 0; y <= n; y++) {
      for (var x = 0; x <= n; x++) {
        vertices.add(top(x, y));
      }
    }
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final a = y * (n + 1) + x;
        final b = a + 1;
        final c = a + n + 2;
        final d = a + n + 1;
        triangles..add((a, c, b))..add((a, d, c));
      }
    }
    for (var x = 0; x < n; x++) {
      final p0 = x;
      final p1 = x + 1;
      final o0 = vertices.length;
      vertices.add(Vector3(x.toDouble(), -1, 5));
      final o1 = vertices.length;
      vertices.add(Vector3((x + 1).toDouble(), -1, 5));
      triangles..add((p0, p1, o1))..add((p0, o1, o0));
    }
    final base = vertices.length;
    for (var y = 0; y <= n; y++) {
      for (var x = 0; x <= n; x++) {
        vertices.add(bottom(x, y));
      }
    }
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final a = base + y * (n + 1) + x;
        final b = a + 1;
        final c = a + n + 2;
        final d = a + n + 1;
        triangles..add((a, b, c))..add((a, c, d));
      }
    }
    final result = const ProfessionalRegionGrowing().segment(
      MeshSurfaceData(vertices: vertices, triangles: triangles),
      'prism-boundary',
      settings: const SurfaceRecognitionSettings(
        planar: true,
        planarToleranceMm: .5,
        seedTriangle: 420,
        seedNeighborhoodTriangles: 24,
        minimumTriangles: 8,
      ),
    );
    expect(result.diagnostics['planarClassification'], 'planarCadCandidate');
    expect(result.diagnostics['planarBoundaryTransitionEdges'], greaterThan(0));
    expect(result.diagnostics['planarInteriorStableScales'], greaterThanOrEqualTo(3));
  });
}
