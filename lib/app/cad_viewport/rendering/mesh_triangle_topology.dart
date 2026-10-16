import 'dart:math' as math;

/// Immutable, presentation-only topology shared by mesh edge classifiers.
/// It contains no camera, picking, CAD or persistence state.
class MeshTriangleTopologyConfig {
  const MeshTriangleTopologyConfig({
    this.weldTolerance,
    this.weldToleranceScale = 1e-7,
    this.minimumWeldTolerance = 1e-9,
    this.areaEpsilon = 1e-20,
    this.maxTriangles,
    this.transform,
  });

  final double? weldTolerance;
  final double weldToleranceScale;
  final double minimumWeldTolerance;
  final double areaEpsilon;
  final int? maxTriangles;
  final List<double>? transform;
}

class MeshTriangleTopologyFace {
  const MeshTriangleTopologyFace({
    required this.index,
    required this.vertices,
    required this.normal,
    required this.centroid,
  });

  final int index;
  final List<int> vertices;
  final List<double> normal;
  final List<double> centroid;
}

class MeshTriangleTopologyEdge {
  MeshTriangleTopologyEdge({
    required this.firstVertex,
    required this.secondVertex,
    required this.start,
    required this.end,
  }) : faces = [];

  MeshTriangleTopologyEdge._frozen(MeshTriangleTopologyEdge source)
    : firstVertex = source.firstVertex,
      secondVertex = source.secondVertex,
      start = source.start,
      end = source.end,
      faces = List.unmodifiable(source.faces);

  final int firstVertex;
  final int secondVertex;
  final List<double> start;
  final List<double> end;
  final List<MeshTriangleTopologyFace> faces;
}

class MeshTriangleTopologyStatistics {
  const MeshTriangleTopologyStatistics({
    required this.inputTriangles,
    required this.validTriangles,
    required this.degenerateTriangles,
    required this.invalidTriangles,
    required this.weldedVertices,
    required this.uniqueCandidateEdges,
    required this.weldTolerance,
    required this.estimatedBytes,
    required this.truncated,
  });

  final int inputTriangles;
  final int validTriangles;
  final int degenerateTriangles;
  final int invalidTriangles;
  final int weldedVertices;
  final int uniqueCandidateEdges;
  final double weldTolerance;
  final int estimatedBytes;
  final bool truncated;
}

class MeshTriangleTopology {
  const MeshTriangleTopology({
    required this.vertices,
    required this.weldedVertexIds,
    required this.faces,
    required this.edges,
    required this.statistics,
    required this.diagnostics,
  });

  final List<List<double>> vertices;
  final List<int> weldedVertexIds;
  final List<MeshTriangleTopologyFace> faces;
  final List<MeshTriangleTopologyEdge> edges;
  final MeshTriangleTopologyStatistics statistics;
  final List<String> diagnostics;
}

class MeshTriangleTopologyBuilder {
  const MeshTriangleTopologyBuilder();

  MeshTriangleTopology build({
    required List<num> vertices,
    required List<num> triangles,
    MeshTriangleTopologyConfig config = const MeshTriangleTopologyConfig(),
  }) {
    final diagnostics = <String>[];
    if (vertices.length % 3 != 0) {
      diagnostics.add('vertices_not_multiple_of_three');
    }
    if (triangles.length % 3 != 0) {
      diagnostics.add('triangles_not_multiple_of_three');
    }
    if (vertices.any((value) => !value.isFinite)) {
      diagnostics.add('vertices_contain_non_finite_values');
    }
    if (config.transform != null && config.transform!.length != 16) {
      diagnostics.add('transform_must_have_sixteen_values');
    }
    final inputTriangles = triangles.length ~/ 3;
    final vertexCount = vertices.length ~/ 3;
    if (vertexCount == 0 || inputTriangles == 0 || diagnostics.isNotEmpty) {
      return _empty(inputTriangles, diagnostics);
    }
    final points = [
      for (var index = 0; index < vertexCount; index++)
        _transform(_point(vertices, index), config.transform),
    ];
    final minimum = List<double>.from(points.first);
    final maximum = List<double>.from(points.first);
    for (final point in points.skip(1)) {
      for (var axis = 0; axis < 3; axis++) {
        minimum[axis] = math.min(minimum[axis], point[axis]);
        maximum[axis] = math.max(maximum[axis], point[axis]);
      }
    }
    final diagonal = _length(_sub(maximum, minimum));
    final weldTolerance =
        config.weldTolerance ??
        math.max(
          diagonal * config.weldToleranceScale,
          config.minimumWeldTolerance,
        );
    if (!weldTolerance.isFinite || weldTolerance <= 0) {
      return _empty(inputTriangles, [...diagnostics, 'invalid_weld_tolerance']);
    }
    final groups = <(int, int, int), int>{};
    final welded = List<int>.filled(vertexCount, -1);
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final key = (
        (point[0] / weldTolerance).round(),
        (point[1] / weldTolerance).round(),
        (point[2] / weldTolerance).round(),
      );
      welded[index] = groups.putIfAbsent(key, () => groups.length);
    }
    final limit = config.maxTriangles == null
        ? inputTriangles
        : math.min(inputTriangles, math.max(0, config.maxTriangles!));
    final edges = <(int, int), MeshTriangleTopologyEdge>{};
    final faces = <MeshTriangleTopologyFace>[];
    var degenerate = 0;
    var invalid = 0;
    for (var faceIndex = 0; faceIndex < limit; faceIndex++) {
      final offset = faceIndex * 3;
      final ia = triangles[offset].toInt();
      final ib = triangles[offset + 1].toInt();
      final ic = triangles[offset + 2].toInt();
      if (ia < 0 ||
          ib < 0 ||
          ic < 0 ||
          ia >= vertexCount ||
          ib >= vertexCount ||
          ic >= vertexCount) {
        invalid++;
        continue;
      }
      final a = points[ia], b = points[ib], c = points[ic];
      final cross = _cross(_sub(b, a), _sub(c, a));
      final area = _length(cross);
      final ga = welded[ia], gb = welded[ib], gc = welded[ic];
      if (area <= config.areaEpsilon || ga == gb || gb == gc || gc == ga) {
        degenerate++;
        continue;
      }
      final face = MeshTriangleTopologyFace(
        index: faceIndex,
        vertices: List.unmodifiable([ia, ib, ic]),
        normal: List.unmodifiable(_scale(cross, 1 / area)),
        centroid: List.unmodifiable(_scale(_add(_add(a, b), c), 1 / 3)),
      );
      faces.add(face);
      _addEdge(edges, ga, gb, a, b, face);
      _addEdge(edges, gb, gc, b, c, face);
      _addEdge(edges, gc, ga, c, a, face);
    }
    if (invalid > 0) diagnostics.add('invalid_triangle_indices');
    if (degenerate > 0) diagnostics.add('degenerate_triangles');
    if (limit < inputTriangles) {
      diagnostics.add('classification_limits_reached');
    }
    return MeshTriangleTopology(
      vertices: List.unmodifiable([
        for (final point in points) List<double>.unmodifiable(point),
      ]),
      weldedVertexIds: List.unmodifiable(welded),
      faces: List.unmodifiable(faces),
      edges: List.unmodifiable([
        for (final edge in edges.values) MeshTriangleTopologyEdge._frozen(edge),
      ]),
      statistics: MeshTriangleTopologyStatistics(
        inputTriangles: inputTriangles,
        validTriangles: faces.length,
        degenerateTriangles: degenerate,
        invalidTriangles: invalid,
        weldedVertices: groups.length,
        uniqueCandidateEdges: edges.length,
        weldTolerance: weldTolerance,
        estimatedBytes:
            groups.length * 16 + edges.length * 72 + faces.length * 64,
        truncated: limit < inputTriangles,
      ),
      diagnostics: List.unmodifiable(diagnostics),
    );
  }

  MeshTriangleTopology _empty(int triangles, List<String> diagnostics) =>
      MeshTriangleTopology(
        vertices: const [],
        weldedVertexIds: const [],
        faces: const [],
        edges: const [],
        statistics: MeshTriangleTopologyStatistics(
          inputTriangles: triangles,
          validTriangles: 0,
          degenerateTriangles: 0,
          invalidTriangles: 0,
          weldedVertices: 0,
          uniqueCandidateEdges: 0,
          weldTolerance: 0,
          estimatedBytes: 0,
          truncated: false,
        ),
        diagnostics: List.unmodifiable(diagnostics),
      );
}

void _addEdge(
  Map<(int, int), MeshTriangleTopologyEdge> edges,
  int first,
  int second,
  List<double> start,
  List<double> end,
  MeshTriangleTopologyFace face,
) {
  if (first == second) {
    return;
  }
  final ordered = first <= second;
  final key = ordered ? (first, second) : (second, first);
  final edge = edges[key] ??= MeshTriangleTopologyEdge(
    firstVertex: key.$1,
    secondVertex: key.$2,
    start: List.unmodifiable(ordered ? start : end),
    end: List.unmodifiable(ordered ? end : start),
  );
  edge.faces.add(face);
}

List<double> _point(List<num> values, int index) => [
  values[index * 3].toDouble(),
  values[index * 3 + 1].toDouble(),
  values[index * 3 + 2].toDouble(),
];

List<double> _transform(List<double> point, List<double>? matrix) {
  if (matrix == null) return List<double>.from(point);
  final x = point[0], y = point[1], z = point[2];
  final w = matrix[12] * x + matrix[13] * y + matrix[14] * z + matrix[15];
  final denominator = w.abs() <= 1e-20 ? 1 : w;
  return [
    (matrix[0] * x + matrix[1] * y + matrix[2] * z + matrix[3]) / denominator,
    (matrix[4] * x + matrix[5] * y + matrix[6] * z + matrix[7]) / denominator,
    (matrix[8] * x + matrix[9] * y + matrix[10] * z + matrix[11]) / denominator,
  ];
}

List<double> _add(List<double> a, List<double> b) => [
  a[0] + b[0],
  a[1] + b[1],
  a[2] + b[2],
];
List<double> _sub(List<double> a, List<double> b) => [
  a[0] - b[0],
  a[1] - b[1],
  a[2] - b[2],
];
List<double> _scale(List<double> a, double factor) => [
  a[0] * factor,
  a[1] * factor,
  a[2] * factor,
];
List<double> _cross(List<double> a, List<double> b) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
];
double _dot(List<double> a, List<double> b) =>
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
double _length(List<double> value) => math.sqrt(_dot(value, value));
