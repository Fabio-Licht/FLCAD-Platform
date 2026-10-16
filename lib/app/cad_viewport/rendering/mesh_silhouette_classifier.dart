import 'dart:math' as math;

import 'mesh_triangle_topology.dart';

enum MeshSilhouetteEdgeKind { silhouette, openBoundary, ambiguous }

enum MeshSilhouetteProjection { orthographic, perspective }

class MeshSilhouetteCamera {
  const MeshSilhouetteCamera({
    required this.eye,
    required this.target,
    required this.up,
    this.projection = MeshSilhouetteProjection.perspective,
  });

  final List<double> eye;
  final List<double> target;
  final List<double> up;
  final MeshSilhouetteProjection projection;
}

class MeshSilhouetteClassifierConfig {
  const MeshSilhouetteClassifierConfig({
    this.weldTolerance,
    this.weldToleranceScale = 1e-7,
    this.minimumWeldTolerance = 1e-9,
    this.angularToleranceDegrees = 1,
    this.areaEpsilon = 1e-20,
    this.maxTriangles,
    this.maxEdges,
    this.transform,
  });

  final double? weldTolerance;
  final double weldToleranceScale;
  final double minimumWeldTolerance;
  final double angularToleranceDegrees;
  final double areaEpsilon;
  final int? maxTriangles;
  final int? maxEdges;
  final List<double>? transform;
}

class MeshSilhouetteSegment {
  const MeshSilhouetteSegment({
    required this.start,
    required this.end,
    required this.kind,
    this.topologyEdgeIndex,
  });

  final List<double> start;
  final List<double> end;
  final MeshSilhouetteEdgeKind kind;

  /// Presentation-only link to the immutable topology edge. It avoids
  /// rebuilding welding or adjacency for diagnostics.
  final int? topologyEdgeIndex;
}

class MeshSilhouetteStatistics {
  const MeshSilhouetteStatistics({
    required this.inputTriangles,
    required this.validTriangles,
    required this.degenerateTriangles,
    required this.invalidTriangles,
    required this.openBoundaryEdges,
    required this.silhouetteEdges,
    required this.ambiguousEdges,
    required this.coplanarEdges,
    required this.weldedVertices,
    required this.estimatedBytes,
    required this.truncated,
  });

  final int inputTriangles;
  final int validTriangles;
  final int degenerateTriangles;
  final int invalidTriangles;
  final int openBoundaryEdges;
  final int silhouetteEdges;
  final int ambiguousEdges;
  final int coplanarEdges;
  final int weldedVertices;
  final int estimatedBytes;
  final bool truncated;
}

class MeshSilhouetteClassification {
  const MeshSilhouetteClassification({
    required this.segments,
    required this.statistics,
    required this.diagnostics,
  });

  final List<MeshSilhouetteSegment> segments;
  final MeshSilhouetteStatistics statistics;
  final List<String> diagnostics;
}

/// Development-only observations derived from an already completed
/// classification. This does not participate in segment selection.
class MeshSilhouetteDiagnostic {
  const MeshSilhouetteDiagnostic({
    required this.silhouette,
    required this.openBoundary,
    required this.ambiguous,
    required this.degenerateFaces,
    required this.invalidFaces,
    required this.nonManifoldEdges,
    required this.windingInconsistencies,
    required this.windingStatus,
    required this.lengths,
    required this.shortByCategory,
    required this.shortLengthThreshold,
    required this.continuity,
    required this.diagnostics,
  });

  final int silhouette;
  final int openBoundary;
  final int ambiguous;
  final int degenerateFaces;
  final int invalidFaces;
  final int nonManifoldEdges;

  /// Null is intentional: face normals alone cannot distinguish a sharp
  /// feature from reversed winding without a surface-orientation authority.
  final int? windingInconsistencies;
  final String windingStatus;
  final Map<String, MeshSilhouetteLengthStatistics> lengths;
  final Map<String, int> shortByCategory;
  final double shortLengthThreshold;
  final MeshSilhouetteContinuity continuity;
  final List<String> diagnostics;

  Map<String, Object?> toJson() => {
    'silhouette': silhouette,
    'openBoundary': openBoundary,
    'ambiguous': ambiguous,
    'degenerateFaces': degenerateFaces,
    'invalidFaces': invalidFaces,
    'nonManifoldEdges': nonManifoldEdges,
    'windingInconsistencies': windingInconsistencies,
    'windingStatus': windingStatus,
    'lengths': {
      for (final entry in lengths.entries) entry.key: entry.value.toJson(),
    },
    'shortByCategory': shortByCategory,
    'shortLengthThreshold': shortLengthThreshold,
    'continuity': continuity.toJson(),
    'diagnostics': diagnostics,
  };
}

class MeshSilhouetteContinuity {
  const MeshSilhouetteContinuity({
    required this.componentCount,
    required this.openChains,
    required this.closedChains,
    required this.isolatedComponents,
    required this.branchingComponents,
    required this.nearNonManifoldComponents,
    required this.chainLengths,
  });

  final int componentCount;
  final int openChains;
  final int closedChains;
  final int isolatedComponents;
  final int branchingComponents;
  final int nearNonManifoldComponents;
  final MeshSilhouetteLengthStatistics chainLengths;

  Map<String, Object?> toJson() => {
    'components': componentCount,
    'openChains': openChains,
    'closedChains': closedChains,
    'isolatedComponents': isolatedComponents,
    'branchingComponents': branchingComponents,
    'nearNonManifoldComponents': nearNonManifoldComponents,
    'chainLengths': chainLengths.toJson(),
  };
}

class MeshSilhouetteLengthStatistics {
  const MeshSilhouetteLengthStatistics({
    required this.count,
    required this.minimum,
    required this.median,
    required this.p90,
    required this.maximum,
  });

  final int count;
  final double minimum;
  final double median;
  final double p90;
  final double maximum;

  Map<String, Object?> toJson() => {
    'count': count,
    'min': minimum,
    'p50': median,
    'p90': p90,
    'max': maximum,
  };
}

MeshSilhouetteDiagnostic diagnoseMeshSilhouette(
  MeshSilhouetteClassification classification,
  MeshTriangleTopology topology,
) {
  final diagonal = _topologyDiagonal(topology);
  // This is a reporting bucket only. It is deliberately not used by the
  // classifier or by the presentation payload.
  final shortThreshold = math.max(diagonal * 1e-4, 1e-12);
  final byCategory = <String, List<double>>{
    'silhouette': [],
    'openBoundary': [],
    'ambiguous': [],
  };
  for (final segment in classification.segments) {
    final length = _length(_sub(segment.end, segment.start));
    byCategory[segment.kind.name]!.add(length);
  }
  final shortByCategory = <String, int>{
    for (final entry in byCategory.entries)
      entry.key: entry.value.where((length) => length <= shortThreshold).length,
  };
  final edgeCounts = <int, int>{};
  for (final edge in topology.edges) {
    edgeCounts[edge.faces.length] = (edgeCounts[edge.faces.length] ?? 0) + 1;
  }
  final diagnostics = <String>[
    if (classification.statistics.truncated) 'classification_truncated',
    if (topology.statistics.truncated) 'topology_truncated',
    if (topology.statistics.degenerateTriangles > 0) 'degenerate_triangles',
    if (topology.statistics.invalidTriangles > 0) 'invalid_triangle_indices',
    if (edgeCounts.keys.any((count) => count > 2)) 'non_manifold_edges',
    'winding_inconsistency_not_authoritatively_measurable',
  ];
  final continuity = _analyzeSilhouetteContinuity(classification, topology);
  return MeshSilhouetteDiagnostic(
    silhouette: classification.statistics.silhouetteEdges,
    openBoundary: classification.statistics.openBoundaryEdges,
    ambiguous: classification.statistics.ambiguousEdges,
    degenerateFaces: topology.statistics.degenerateTriangles,
    invalidFaces: topology.statistics.invalidTriangles,
    nonManifoldEdges: topology.edges
        .where((edge) => edge.faces.length > 2)
        .length,
    windingInconsistencies: null,
    windingStatus: 'not_measured',
    lengths: {
      for (final entry in byCategory.entries)
        entry.key: _lengthStatistics(entry.value),
    },
    shortByCategory: Map.unmodifiable(shortByCategory),
    shortLengthThreshold: shortThreshold,
    continuity: continuity,
    diagnostics: List.unmodifiable(diagnostics),
  );
}

MeshSilhouetteContinuity _analyzeSilhouetteContinuity(
  MeshSilhouetteClassification classification,
  MeshTriangleTopology topology,
) {
  final indexed = [
    for (final segment in classification.segments)
      if (segment.topologyEdgeIndex != null &&
          segment.topologyEdgeIndex! >= 0 &&
          segment.topologyEdgeIndex! < topology.edges.length)
        (segment: segment, edge: topology.edges[segment.topologyEdgeIndex!]),
  ];
  if (indexed.isEmpty) {
    return MeshSilhouetteContinuity(
      componentCount: 0,
      openChains: 0,
      closedChains: 0,
      isolatedComponents: 0,
      branchingComponents: 0,
      nearNonManifoldComponents: 0,
      chainLengths: _lengthStatistics(const []),
    );
  }
  final parent = List<int>.generate(indexed.length, (index) => index);
  int find(int value) {
    var root = value;
    while (parent[root] != root) {
      root = parent[root];
    }
    while (parent[value] != value) {
      final next = parent[value];
      parent[value] = root;
      value = next;
    }
    return root;
  }

  void union(int first, int second) {
    final a = find(first), b = find(second);
    if (a != b) parent[b] = a;
  }

  final vertexToSegments = <int, List<int>>{};
  for (var index = 0; index < indexed.length; index++) {
    final edge = indexed[index].edge;
    (vertexToSegments[edge.firstVertex] ??= []).add(index);
    (vertexToSegments[edge.secondVertex] ??= []).add(index);
  }
  for (final members in vertexToSegments.values) {
    for (var index = 1; index < members.length; index++) {
      union(members.first, members[index]);
    }
  }
  final componentSegments = <int, List<int>>{};
  for (var index = 0; index < indexed.length; index++) {
    (componentSegments[find(index)] ??= []).add(index);
  }
  final lengths = <double>[];
  var openChains = 0;
  var closedChains = 0;
  var isolated = 0;
  var branching = 0;
  var nearNonManifold = 0;
  for (final members in componentSegments.values) {
    if (members.length == 1) isolated++;
    final degrees = <int, int>{};
    var touchesNonManifold = false;
    var totalLength = 0.0;
    for (final member in members) {
      final edge = indexed[member].edge;
      degrees[edge.firstVertex] = (degrees[edge.firstVertex] ?? 0) + 1;
      degrees[edge.secondVertex] = (degrees[edge.secondVertex] ?? 0) + 1;
      touchesNonManifold |= edge.faces.length > 2;
      totalLength += _length(
        _sub(indexed[member].segment.end, indexed[member].segment.start),
      );
    }
    lengths.add(totalLength);
    if (degrees.values.any((degree) => degree > 2)) {
      branching++;
    } else if (degrees.values.every((degree) => degree == 2)) {
      closedChains++;
    } else {
      openChains++;
    }
    if (touchesNonManifold) nearNonManifold++;
  }
  return MeshSilhouetteContinuity(
    componentCount: componentSegments.length,
    openChains: openChains,
    closedChains: closedChains,
    isolatedComponents: isolated,
    branchingComponents: branching,
    nearNonManifoldComponents: nearNonManifold,
    chainLengths: _lengthStatistics(lengths),
  );
}

MeshSilhouetteLengthStatistics _lengthStatistics(List<double> values) {
  if (values.isEmpty) {
    return const MeshSilhouetteLengthStatistics(
      count: 0,
      minimum: 0,
      median: 0,
      p90: 0,
      maximum: 0,
    );
  }
  final sorted = List<double>.from(values)..sort();
  double percentile(double fraction) {
    final position = (sorted.length - 1) * fraction;
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return sorted[lower];
    final weight = position - lower;
    return sorted[lower] * (1 - weight) + sorted[upper] * weight;
  }

  return MeshSilhouetteLengthStatistics(
    count: sorted.length,
    minimum: sorted.first,
    median: percentile(.5),
    p90: percentile(.9),
    maximum: sorted.last,
  );
}

double _topologyDiagonal(MeshTriangleTopology topology) {
  if (topology.vertices.isEmpty) return 0;
  final minimum = List<double>.from(topology.vertices.first);
  final maximum = List<double>.from(topology.vertices.first);
  for (final point in topology.vertices.skip(1)) {
    for (var axis = 0; axis < 3; axis++) {
      minimum[axis] = math.min(minimum[axis], point[axis]);
      maximum[axis] = math.max(maximum[axis], point[axis]);
    }
  }
  return _length(_sub(maximum, minimum));
}

class MeshSilhouetteClassifier {
  const MeshSilhouetteClassifier();

  MeshSilhouetteClassification classify({
    required List<num> vertices,
    required List<num> triangles,
    required MeshSilhouetteCamera camera,
    MeshSilhouetteClassifierConfig config =
        const MeshSilhouetteClassifierConfig(),
  }) {
    final diagnostics = <String>[];
    if (!_validPoint(camera.eye) ||
        !_validPoint(camera.target) ||
        !_validPoint(camera.up)) {
      diagnostics.add('camera_contains_invalid_values');
    }
    if (diagnostics.isNotEmpty) {
      return _empty(triangles.length ~/ 3, diagnostics);
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
        transform: config.transform,
      ),
    );
    return classifyTopology(
      topology: topology,
      camera: camera,
      config: config,
      diagnostics: [...diagnostics, ...topology.diagnostics],
    );
  }

  MeshSilhouetteClassification classifyTopology({
    required MeshTriangleTopology topology,
    required MeshSilhouetteCamera camera,
    MeshSilhouetteClassifierConfig config =
        const MeshSilhouetteClassifierConfig(),
    List<String> diagnostics = const [],
  }) {
    final classificationDiagnostics = <String>[...diagnostics];
    var open = 0;
    var silhouette = 0;
    var ambiguous = 0;
    var coplanar = 0;
    var truncated = topology.statistics.truncated;
    final result = <MeshSilhouetteSegment>[];
    final tolerance = math.sin(config.angularToleranceDegrees * math.pi / 180);
    for (var edgeIndex = 0; edgeIndex < topology.edges.length; edgeIndex++) {
      final edge = topology.edges[edgeIndex];
      MeshSilhouetteEdgeKind? kind;
      if (edge.faces.length == 1) {
        kind = MeshSilhouetteEdgeKind.openBoundary;
        open++;
      } else if (edge.faces.length != 2) {
        kind = MeshSilhouetteEdgeKind.ambiguous;
        ambiguous++;
      } else {
        final first = _facing(
          edge.faces[0].normal,
          edge.faces[0].centroid,
          camera,
        );
        final second = _facing(
          edge.faces[1].normal,
          edge.faces[1].centroid,
          camera,
        );
        if (first.abs() <= tolerance || second.abs() <= tolerance) {
          kind = MeshSilhouetteEdgeKind.ambiguous;
          ambiguous++;
        } else if (first.sign != second.sign) {
          kind = MeshSilhouetteEdgeKind.silhouette;
          silhouette++;
        } else {
          coplanar++;
        }
      }
      if (kind == null) continue;
      if (config.maxEdges != null && result.length >= config.maxEdges!) {
        truncated = true;
        continue;
      }
      result.add(
        MeshSilhouetteSegment(
          start: edge.start,
          end: edge.end,
          kind: kind,
          topologyEdgeIndex: edgeIndex,
        ),
      );
    }
    if (ambiguous > 0 &&
        !classificationDiagnostics.contains('ambiguous_edges')) {
      classificationDiagnostics.add('ambiguous_edges');
    }
    if (truncated &&
        !classificationDiagnostics.contains('classification_limits_reached')) {
      classificationDiagnostics.add('classification_limits_reached');
    }
    return MeshSilhouetteClassification(
      segments: List.unmodifiable(result),
      statistics: MeshSilhouetteStatistics(
        inputTriangles: topology.statistics.inputTriangles,
        validTriangles: topology.statistics.validTriangles,
        degenerateTriangles: topology.statistics.degenerateTriangles,
        invalidTriangles: topology.statistics.invalidTriangles,
        openBoundaryEdges: open,
        silhouetteEdges: silhouette,
        ambiguousEdges: ambiguous,
        coplanarEdges: coplanar,
        weldedVertices: topology.statistics.weldedVertices,
        estimatedBytes: topology.statistics.estimatedBytes + result.length * 48,
        truncated: truncated,
      ),
      diagnostics: List.unmodifiable(classificationDiagnostics),
    );
  }

  MeshSilhouetteClassification _empty(
    int triangles,
    List<String> diagnostics,
  ) => MeshSilhouetteClassification(
    segments: const [],
    statistics: MeshSilhouetteStatistics(
      inputTriangles: triangles,
      validTriangles: 0,
      degenerateTriangles: 0,
      invalidTriangles: 0,
      openBoundaryEdges: 0,
      silhouetteEdges: 0,
      ambiguousEdges: 0,
      coplanarEdges: 0,
      weldedVertices: 0,
      estimatedBytes: 0,
      truncated: false,
    ),
    diagnostics: List.unmodifiable(diagnostics),
  );
}

double _facing(
  List<double> normal,
  List<double> centroid,
  MeshSilhouetteCamera camera,
) {
  final towardCamera =
      camera.projection == MeshSilhouetteProjection.orthographic
      ? _sub(camera.eye, camera.target)
      : _sub(camera.eye, centroid);
  final length = _length(towardCamera);
  return length <= 1e-20 ? 0 : _dot(normal, _scale(towardCamera, 1 / length));
}

bool _validPoint(List<double> point) =>
    point.length == 3 && point.every((value) => value.isFinite);

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
