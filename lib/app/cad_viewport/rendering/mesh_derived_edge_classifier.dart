import 'dart:math' as math;

/// The visual origin of an edge. This is deliberately not a CAD topology
/// contract and must never be serialized as `topologicalEdges`.
const String meshDerivedEdgeSource = 'meshDerived';

enum MeshDerivedEdgeKind { openBoundary, crease, ambiguous }

@pragma('vm:prefer-inline')
double _component(List<num> values, int index) => values[index].toDouble();

class MeshDerivedEdgeClassifierConfig {
  const MeshDerivedEdgeClassifierConfig({
    this.weldTolerance,
    this.weldToleranceScale = 1e-7,
    this.minimumWeldTolerance = 1e-9,
    this.creaseAngleDegrees = 25,
    this.areaEpsilon = 1e-20,
    this.maxTriangles,
    this.maxEdges,
  });

  /// Absolute tolerance. When omitted, the existing display-mesh policy is
  /// used: diagonal * [weldToleranceScale], bounded by the minimum.
  final double? weldTolerance;
  final double weldToleranceScale;
  final double minimumWeldTolerance;
  final double creaseAngleDegrees;
  final double areaEpsilon;
  final int? maxTriangles;
  final int? maxEdges;
}

class MeshDerivedEdgeSegment {
  const MeshDerivedEdgeSegment({
    required this.start,
    required this.end,
    required this.kind,
    this.source = meshDerivedEdgeSource,
  });

  final List<double> start;
  final List<double> end;
  final MeshDerivedEdgeKind kind;
  final String source;
}

class MeshDerivedEdgeStatistics {
  const MeshDerivedEdgeStatistics({
    required this.inputTriangles,
    required this.validTriangles,
    required this.degenerateTriangles,
    required this.invalidTriangles,
    required this.uniqueCandidateEdges,
    required this.openBoundaryEdges,
    required this.creaseEdges,
    required this.coplanarEdgesDiscarded,
    required this.ambiguousEdges,
    required this.weldedVertices,
    required this.segments,
    required this.weldTolerance,
    required this.normalsAvailable,
    required this.inconsistentNormalFaces,
    required this.creaseAngleHistogram,
    required this.estimatedBytes,
    required this.truncated,
  });

  final int inputTriangles;
  final int validTriangles;
  final int degenerateTriangles;
  final int invalidTriangles;
  final int uniqueCandidateEdges;
  final int openBoundaryEdges;
  final int creaseEdges;
  final int coplanarEdgesDiscarded;
  final int ambiguousEdges;
  final int weldedVertices;
  final int segments;
  final double weldTolerance;
  final bool normalsAvailable;
  final int inconsistentNormalFaces;

  /// Counts classified crease edges in 10-degree buckets over [0, 90].
  final List<int> creaseAngleHistogram;
  final int estimatedBytes;
  final bool truncated;
}

class MeshDerivedEdgeClassification {
  const MeshDerivedEdgeClassification({
    required this.segments,
    required this.statistics,
    required this.diagnostics,
  });

  final List<MeshDerivedEdgeSegment> segments;
  final MeshDerivedEdgeStatistics statistics;
  final List<String> diagnostics;
}

/// Cached, presentation-only measurements for one classification pass.
/// This is deliberately separate from the mesh and is never sent to native.
class MeshDerivedEdgeObservation {
  MeshDerivedEdgeObservation({
    required this.classification,
    required this.elapsedMicros,
  }) : lengthStatistics = _lengthStatistics(classification.segments);

  final MeshDerivedEdgeClassification classification;
  final int elapsedMicros;
  final MeshDerivedEdgeLengthStatistics lengthStatistics;
}

class MeshDerivedEdgeLengthStatistics {
  const MeshDerivedEdgeLengthStatistics({
    required this.minimum,
    required this.average,
    required this.maximum,
    required this.p50,
    required this.p90,
    required this.p95,
    required this.p99,
  });

  final double minimum;
  final double average;
  final double maximum;
  final double p50;
  final double p90;
  final double p95;
  final double p99;
}

MeshDerivedEdgeLengthStatistics _lengthStatistics(
  List<MeshDerivedEdgeSegment> segments,
) {
  if (segments.isEmpty) {
    return const MeshDerivedEdgeLengthStatistics(
      minimum: 0,
      average: 0,
      maximum: 0,
      p50: 0,
      p90: 0,
      p95: 0,
      p99: 0,
    );
  }
  final lengths = [
    for (final segment in segments)
      _length(_subtract(segment.end, segment.start)),
  ]..sort();
  double percentile(double fraction) {
    final position = (lengths.length - 1) * fraction;
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return lengths[lower];
    final weight = position - lower;
    return lengths[lower] + (lengths[upper] - lengths[lower]) * weight;
  }

  return MeshDerivedEdgeLengthStatistics(
    minimum: lengths.first,
    average: lengths.reduce((a, b) => a + b) / lengths.length,
    maximum: lengths.last,
    p50: percentile(.50),
    p90: percentile(.90),
    p95: percentile(.95),
    p99: percentile(.99),
  );
}

class MeshDerivedEdgeClassifier {
  const MeshDerivedEdgeClassifier();

  MeshDerivedEdgeClassification classify({
    required List<num> vertices,
    required List<num> triangles,
    List<num>? normals,
    MeshDerivedEdgeClassifierConfig config =
        const MeshDerivedEdgeClassifierConfig(),
  }) {
    final diagnostics = <String>[];
    final vertexCount = vertices.length ~/ 3;
    final inputTriangles = triangles.length ~/ 3;
    if (vertices.length % 3 != 0) {
      diagnostics.add('vertices_not_multiple_of_three');
    }
    if (triangles.length % 3 != 0) {
      diagnostics.add('triangles_not_multiple_of_three');
    }
    if (vertices.any((value) => !value.isFinite)) {
      diagnostics.add('vertices_contain_non_finite_values');
    }
    final normalsAvailable =
        normals != null &&
        normals.length == vertices.length &&
        normals.every((value) => value.isFinite);
    if (normals != null && !normalsAvailable) {
      diagnostics.add('normals_invalid_or_misaligned');
    }

    if (vertexCount == 0 || inputTriangles == 0) {
      return _emptyResult(
        inputTriangles: inputTriangles,
        normalsAvailable: normalsAvailable,
        diagnostics: diagnostics,
      );
    }

    var minimum = _point(vertices, 0);
    var maximum = minimum;
    for (var index = 1; index < vertexCount; index++) {
      final point = _point(vertices, index);
      minimum = _min(minimum, point);
      maximum = _max(maximum, point);
    }
    final diagonal = _length(_subtract(maximum, minimum));
    final weldTolerance =
        config.weldTolerance ??
        math.max(
          diagonal * config.weldToleranceScale,
          config.minimumWeldTolerance,
        );
    if (!weldTolerance.isFinite || weldTolerance <= 0) {
      diagnostics.add('invalid_weld_tolerance');
      return _emptyResult(
        inputTriangles: inputTriangles,
        normalsAvailable: normalsAvailable,
        diagnostics: diagnostics,
      );
    }

    final weldedGroups = List<int>.filled(vertexCount, -1);
    final groups = <(int, int, int), int>{};
    for (var index = 0; index < vertexCount; index++) {
      final point = _point(vertices, index);
      final key = (
        (point[0] / weldTolerance).round(),
        (point[1] / weldTolerance).round(),
        (point[2] / weldTolerance).round(),
      );
      weldedGroups[index] = groups.putIfAbsent(key, () => groups.length);
    }

    final limit = config.maxTriangles == null
        ? inputTriangles
        : math.min(inputTriangles, math.max(0, config.maxTriangles!));
    final edges = <(int, int), _EdgeAccumulator>{};
    var validTriangles = 0;
    var degenerateTriangles = 0;
    var invalidTriangles = 0;
    var inconsistentNormalFaces = 0;
    for (var face = 0; face < limit; face++) {
      final offset = face * 3;
      final ia = triangles[offset].toInt();
      final ib = triangles[offset + 1].toInt();
      final ic = triangles[offset + 2].toInt();
      if (ia < 0 ||
          ib < 0 ||
          ic < 0 ||
          ia >= vertexCount ||
          ib >= vertexCount ||
          ic >= vertexCount) {
        invalidTriangles++;
        continue;
      }
      final a = _point(vertices, ia);
      final b = _point(vertices, ib);
      final c = _point(vertices, ic);
      final cross = _cross(_subtract(b, a), _subtract(c, a));
      final area = _length(cross);
      final ga = weldedGroups[ia], gb = weldedGroups[ib], gc = weldedGroups[ic];
      if (area <= config.areaEpsilon || ga == gb || gb == gc || gc == ga) {
        degenerateTriangles++;
        continue;
      }
      final faceNormal = _scale(cross, 1 / area);
      if (normalsAvailable) {
        final supplied = _add(
          _add(_point(normals, ia), _point(normals, ib)),
          _point(normals, ic),
        );
        final suppliedLength = _length(supplied);
        if (suppliedLength <= config.areaEpsilon ||
            _dot(faceNormal, _scale(supplied, 1 / suppliedLength)) < 0) {
          inconsistentNormalFaces++;
        }
      }
      validTriangles++;
      _addEdge(edges, ga, gb, a, b, faceNormal);
      _addEdge(edges, gb, gc, b, c, faceNormal);
      _addEdge(edges, gc, ga, c, a, faceNormal);
    }

    final segments = <MeshDerivedEdgeSegment>[];
    var openBoundaryEdges = 0;
    var creaseEdges = 0;
    var coplanarEdgesDiscarded = 0;
    var ambiguousEdges = 0;
    final creaseAngleHistogram = List<int>.filled(9, 0);
    final creaseCosine = math.cos(config.creaseAngleDegrees * math.pi / 180);
    var truncated = limit < inputTriangles;
    for (final entry in edges.entries) {
      final incident = entry.value.incident;
      MeshDerivedEdgeKind? kind;
      if (incident.length == 1) {
        kind = MeshDerivedEdgeKind.openBoundary;
        openBoundaryEdges++;
      } else if (incident.length == 2) {
        final cosine = _dot(incident[0], incident[1]).abs();
        if (cosine < creaseCosine) {
          kind = MeshDerivedEdgeKind.crease;
          creaseEdges++;
          final angleDegrees =
              math.acos(cosine.clamp(-1.0, 1.0)) * 180 / math.pi;
          final bucket = math.min(8, angleDegrees ~/ 10);
          creaseAngleHistogram[bucket]++;
        } else {
          coplanarEdgesDiscarded++;
        }
      } else {
        kind = MeshDerivedEdgeKind.ambiguous;
        ambiguousEdges++;
      }
      if (kind == null) continue;
      if (config.maxEdges != null && segments.length >= config.maxEdges!) {
        truncated = true;
        continue;
      }
      segments.add(
        MeshDerivedEdgeSegment(
          start: List.unmodifiable(entry.value.start),
          end: List.unmodifiable(entry.value.end),
          kind: kind,
        ),
      );
    }
    if (invalidTriangles > 0) diagnostics.add('invalid_triangle_indices');
    if (degenerateTriangles > 0) diagnostics.add('degenerate_triangles');
    if (inconsistentNormalFaces > 0) {
      diagnostics.add('inconsistent_supplied_normals');
    }
    if (truncated) diagnostics.add('classification_limits_reached');
    final estimatedBytes =
        groups.length * 16 + edges.length * 64 + segments.length * 24;
    return MeshDerivedEdgeClassification(
      segments: List.unmodifiable(segments),
      statistics: MeshDerivedEdgeStatistics(
        inputTriangles: inputTriangles,
        validTriangles: validTriangles,
        degenerateTriangles: degenerateTriangles,
        invalidTriangles: invalidTriangles,
        uniqueCandidateEdges: edges.length,
        openBoundaryEdges: openBoundaryEdges,
        creaseEdges: creaseEdges,
        coplanarEdgesDiscarded: coplanarEdgesDiscarded,
        ambiguousEdges: ambiguousEdges,
        weldedVertices: groups.length,
        segments: segments.length,
        weldTolerance: weldTolerance,
        normalsAvailable: normalsAvailable,
        inconsistentNormalFaces: inconsistentNormalFaces,
        creaseAngleHistogram: List.unmodifiable(creaseAngleHistogram),
        estimatedBytes: estimatedBytes,
        truncated: truncated,
      ),
      diagnostics: List.unmodifiable(diagnostics),
    );
  }

  static MeshDerivedEdgeClassification _emptyResult({
    required int inputTriangles,
    required bool normalsAvailable,
    required List<String> diagnostics,
  }) => MeshDerivedEdgeClassification(
    segments: const [],
    statistics: MeshDerivedEdgeStatistics(
      inputTriangles: inputTriangles,
      validTriangles: 0,
      degenerateTriangles: 0,
      invalidTriangles: 0,
      uniqueCandidateEdges: 0,
      openBoundaryEdges: 0,
      creaseEdges: 0,
      coplanarEdgesDiscarded: 0,
      ambiguousEdges: 0,
      weldedVertices: 0,
      segments: 0,
      weldTolerance: 0,
      normalsAvailable: normalsAvailable,
      inconsistentNormalFaces: 0,
      creaseAngleHistogram: const [],
      estimatedBytes: 0,
      truncated: false,
    ),
    diagnostics: List.unmodifiable(diagnostics),
  );
}

class _EdgeAccumulator {
  _EdgeAccumulator(this.start, this.end, _Normal normal) : incident = [normal];
  final List<double> start;
  final List<double> end;
  final List<_Normal> incident;
}

void _addEdge(
  Map<(int, int), _EdgeAccumulator> edges,
  int first,
  int second,
  List<double> start,
  List<double> end,
  _Normal normal,
) {
  if (first == second) return;
  final ordered = first <= second;
  final key = ordered ? (first, second) : (second, first);
  final existing = edges[key];
  if (existing == null) {
    edges[key] = _EdgeAccumulator(
      ordered ? List<double>.from(start) : List<double>.from(end),
      ordered ? List<double>.from(end) : List<double>.from(start),
      normal,
    );
  } else {
    existing.incident.add(normal);
  }
}

typedef _Normal = List<double>;

List<double> _point(List<num> values, int index) => [
  _component(values, index * 3),
  _component(values, index * 3 + 1),
  _component(values, index * 3 + 2),
];

List<double> _add(List<double> a, List<double> b) => [
  a[0] + b[0],
  a[1] + b[1],
  a[2] + b[2],
];

List<double> _subtract(List<double> a, List<double> b) => [
  a[0] - b[0],
  a[1] - b[1],
  a[2] - b[2],
];

List<double> _scale(List<double> value, double factor) => [
  value[0] * factor,
  value[1] * factor,
  value[2] * factor,
];

List<double> _cross(List<double> a, List<double> b) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
];

double _dot(List<double> a, List<double> b) =>
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

double _length(List<double> value) => math.sqrt(_dot(value, value));

List<double> _min(List<double> a, List<double> b) => [
  math.min(a[0], b[0]),
  math.min(a[1], b[1]),
  math.min(a[2], b[2]),
];

List<double> _max(List<double> a, List<double> b) => [
  math.max(a[0], b[0]),
  math.max(a[1], b[1]),
  math.max(a[2], b[2]),
];
