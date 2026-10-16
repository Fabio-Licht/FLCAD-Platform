import 'dart:math' as math;

import 'mesh_triangle_topology.dart';

/// The visual origin of an edge. This is deliberately not a CAD topology
/// contract and must never be serialized as `topologicalEdges`.
const String meshDerivedEdgeSource = 'meshDerived';

enum MeshDerivedEdgeKind { openBoundary, crease, ambiguous }

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
    final normalsAvailable =
        normals != null &&
        normals.length == vertices.length &&
        normals.every((value) => value.isFinite);
    if (normals != null && !normalsAvailable) {
      diagnostics.add('normals_invalid_or_misaligned');
    }
    final topology = const MeshTriangleTopologyBuilder().build(
      vertices: vertices,
      triangles: triangles,
      config: MeshTriangleTopologyConfig(
        weldTolerance: config.weldTolerance,
        weldToleranceScale: config.weldToleranceScale,
        minimumWeldTolerance: config.minimumWeldTolerance,
        areaEpsilon: config.areaEpsilon,
        maxTriangles: config.maxTriangles,
      ),
    );
    return classifyTopology(
      topology: topology,
      normals: normals,
      config: config,
      normalsAvailableOverride: normalsAvailable,
      diagnostics: [...diagnostics, ...topology.diagnostics],
    );
  }

  MeshDerivedEdgeClassification classifyTopology({
    required MeshTriangleTopology topology,
    List<num>? normals,
    MeshDerivedEdgeClassifierConfig config =
        const MeshDerivedEdgeClassifierConfig(),
    bool? normalsAvailableOverride,
    List<String> diagnostics = const [],
  }) {
    final classificationDiagnostics = <String>[...diagnostics];
    final normalsAvailable =
        normalsAvailableOverride ??
        (normals != null &&
            normals.length == topology.vertices.length * 3 &&
            normals.every((value) => value.isFinite));
    if (normals != null &&
        !normalsAvailable &&
        !classificationDiagnostics.contains('normals_invalid_or_misaligned')) {
      classificationDiagnostics.add('normals_invalid_or_misaligned');
    }
    var inconsistentNormalFaces = 0;
    final suppliedNormals = normals;
    if (normalsAvailable && suppliedNormals != null) {
      for (final face in topology.faces) {
        final supplied = _add(
          _add(
            _point(suppliedNormals, face.vertices[0]),
            _point(suppliedNormals, face.vertices[1]),
          ),
          _point(suppliedNormals, face.vertices[2]),
        );
        final length = _length(supplied);
        if (length <= config.areaEpsilon ||
            _dot(face.normal, _scale(supplied, 1 / length)) < 0) {
          inconsistentNormalFaces++;
        }
      }
    }
    if (inconsistentNormalFaces > 0) {
      classificationDiagnostics.add('inconsistent_supplied_normals');
    }
    var openBoundaryEdges = 0;
    var creaseEdges = 0;
    var coplanarEdgesDiscarded = 0;
    var ambiguousEdges = 0;
    final histogram = List<int>.filled(9, 0);
    final creaseCosine = math.cos(config.creaseAngleDegrees * math.pi / 180);
    final segments = <MeshDerivedEdgeSegment>[];
    var truncated = topology.statistics.truncated;
    for (final edge in topology.edges) {
      MeshDerivedEdgeKind? kind;
      if (edge.faces.length == 1) {
        kind = MeshDerivedEdgeKind.openBoundary;
        openBoundaryEdges++;
      } else if (edge.faces.length == 2) {
        final cosine = _dot(edge.faces[0].normal, edge.faces[1].normal).abs();
        if (cosine < creaseCosine) {
          kind = MeshDerivedEdgeKind.crease;
          creaseEdges++;
          final angle = math.acos(cosine.clamp(-1.0, 1.0)) * 180 / math.pi;
          histogram[math.min(8, angle ~/ 10)]++;
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
        MeshDerivedEdgeSegment(start: edge.start, end: edge.end, kind: kind),
      );
    }
    if (truncated &&
        !classificationDiagnostics.contains('classification_limits_reached')) {
      classificationDiagnostics.add('classification_limits_reached');
    }
    return MeshDerivedEdgeClassification(
      segments: List.unmodifiable(segments),
      statistics: MeshDerivedEdgeStatistics(
        inputTriangles: topology.statistics.inputTriangles,
        validTriangles: topology.statistics.validTriangles,
        degenerateTriangles: topology.statistics.degenerateTriangles,
        invalidTriangles: topology.statistics.invalidTriangles,
        uniqueCandidateEdges: topology.statistics.uniqueCandidateEdges,
        openBoundaryEdges: openBoundaryEdges,
        creaseEdges: creaseEdges,
        coplanarEdgesDiscarded: coplanarEdgesDiscarded,
        ambiguousEdges: ambiguousEdges,
        weldedVertices: topology.statistics.weldedVertices,
        segments: segments.length,
        weldTolerance: topology.statistics.weldTolerance,
        normalsAvailable: normalsAvailable,
        inconsistentNormalFaces: inconsistentNormalFaces,
        creaseAngleHistogram: List.unmodifiable(histogram),
        estimatedBytes:
            topology.statistics.weldedVertices * 16 +
            topology.statistics.uniqueCandidateEdges * 64 +
            segments.length * 24,
        truncated: truncated,
      ),
      diagnostics: List.unmodifiable(classificationDiagnostics),
    );
  }
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
    for (final segment in segments) _length(_sub(segment.end, segment.start)),
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
    p50: percentile(.5),
    p90: percentile(.9),
    p95: percentile(.95),
    p99: percentile(.99),
  );
}

List<double> _point(List<num> values, int index) => [
  values[index * 3].toDouble(),
  values[index * 3 + 1].toDouble(),
  values[index * 3 + 2].toDouble(),
];
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
double _dot(List<double> a, List<double> b) =>
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
double _length(List<double> value) => math.sqrt(_dot(value, value));
