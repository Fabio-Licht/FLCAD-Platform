import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'mesh_derived_edge_classifier.dart';

/// Development-only switch. Commercial builds keep the original classification.
const bool kFlcadDevMeshDerivedEdgeRefinement =
    kDebugMode &&
    bool.fromEnvironment(
      'FLCAD_DEV_MESH_DERIVED_EDGE_REFINEMENT',
      defaultValue: false,
    );

class MeshDerivedEdgeRefinerConfig {
  const MeshDerivedEdgeRefinerConfig({
    this.directionContinuityDegrees = 42,
    this.shortIsolatedLengthFactor = 0.35,
    this.clusterRadiusFactor = 2.5,
    this.clusterMinNeighbors = 3,
    this.maxCreaseSuppressionRatio = 0.20,
  });

  final double directionContinuityDegrees;
  final double shortIsolatedLengthFactor;
  final double clusterRadiusFactor;
  final int clusterMinNeighbors;

  /// If more than this fraction of crease segments would be dropped, keep all.
  final double maxCreaseSuppressionRatio;
}

class MeshDerivedEdgeChain {
  const MeshDerivedEdgeChain({
    required this.segmentIndices,
    required this.totalLength,
    required this.closed,
    required this.meanTurningDegrees,
    required this.isolated,
    required this.hasOpenBoundary,
    required this.hasAmbiguous,
    required this.hasCrease,
  });

  final List<int> segmentIndices;
  final double totalLength;
  final bool closed;
  final double meanTurningDegrees;
  final bool isolated;
  final bool hasOpenBoundary;
  final bool hasAmbiguous;
  final bool hasCrease;
}

class MeshDerivedEdgeRefinement {
  const MeshDerivedEdgeRefinement({
    required this.segments,
    required this.originalSegments,
    required this.refinedSegments,
    required this.openBoundaryEdges,
    required this.creaseEdges,
    required this.ambiguousEdges,
    required this.chains,
    required this.closedLoopCount,
    required this.isolatedCount,
    required this.suppressionCandidates,
    required this.suppressed,
    required this.preserved,
    required this.applied,
    required this.skippedReason,
    required this.turningAngleHistogram,
    required this.elapsedMicros,
    required this.estimatedBytes,
  });

  final List<MeshDerivedEdgeSegment> segments;
  final int originalSegments;
  final int refinedSegments;
  final int openBoundaryEdges;
  final int creaseEdges;
  final int ambiguousEdges;
  final int chains;
  final int closedLoopCount;
  final int isolatedCount;
  final int suppressionCandidates;
  final int suppressed;
  final int preserved;
  final bool applied;
  final String? skippedReason;
  final List<int> turningAngleHistogram;
  final int elapsedMicros;
  final int estimatedBytes;

  Map<String, Object?> toDiagnostics({required bool experimentalFlag}) => {
    'experimentalFlag': experimentalFlag,
    'appliedToPresentation': experimentalFlag && applied,
    'originalSegments': originalSegments,
    'refinedSegments': refinedSegments,
    'openBoundary': openBoundaryEdges,
    'crease': creaseEdges,
    'ambiguous': ambiguousEdges,
    'chains': chains,
    'closedLoops': closedLoopCount,
    'isolated': isolatedCount,
    'suppressionCandidates': suppressionCandidates,
    'suppressed': suppressed,
    'preserved': preserved,
    'applied': applied,
    'skippedReason': skippedReason,
    'turningAngleHistogram': turningAngleHistogram,
    'elapsedMicros': elapsedMicros,
    'estimatedBytes': estimatedBytes,
  };
}

final Expando<MeshDerivedEdgeRefinement> _refinementCache = Expando(
  'mesh-derived-edge-refinement',
);

MeshDerivedEdgeRefinement? cachedMeshDerivedEdgeRefinement(
  MeshDerivedEdgeClassification classification,
) {
  if (!kFlcadDevMeshDerivedEdgeRefinement) return null;
  return _refinementCache[classification] ??= const MeshDerivedEdgeRefiner()
      .refine(classification);
}

List<MeshDerivedEdgeSegment> meshDerivedPresentationSegments(
  MeshDerivedEdgeClassification classification,
) {
  final refinement = cachedMeshDerivedEdgeRefinement(classification);
  if (refinement != null && refinement.applied) return refinement.segments;
  return classification.segments;
}

class MeshDerivedEdgeRefiner {
  const MeshDerivedEdgeRefiner();

  MeshDerivedEdgeRefinement refine(
    MeshDerivedEdgeClassification classification, {
    MeshDerivedEdgeLengthStatistics? lengthStatistics,
    MeshDerivedEdgeRefinerConfig config = const MeshDerivedEdgeRefinerConfig(),
  }) {
    final stopwatch = Stopwatch()..start();
    final original = classification.segments;
    if (original.isEmpty) {
      stopwatch.stop();
      return MeshDerivedEdgeRefinement(
        segments: original,
        originalSegments: 0,
        refinedSegments: 0,
        openBoundaryEdges: 0,
        creaseEdges: 0,
        ambiguousEdges: 0,
        chains: 0,
        closedLoopCount: 0,
        isolatedCount: 0,
        suppressionCandidates: 0,
        suppressed: 0,
        preserved: 0,
        applied: true,
        skippedReason: null,
        turningAngleHistogram: const [0, 0, 0, 0, 0, 0, 0, 0, 0],
        elapsedMicros: stopwatch.elapsedMicroseconds,
        estimatedBytes: 0,
      );
    }

    final lengths = lengthStatistics ?? _refinerLengthStatistics(original);
    final scale = lengths.p50 > 0 ? lengths.p50 : 1;
    final weldTolerance = classification.statistics.weldTolerance > 0
        ? classification.statistics.weldTolerance
        : 1e-9;

    final ids = <(int, int, int), int>{};
    final startId = List<int>.filled(original.length, 0);
    final endId = List<int>.filled(original.length, 0);
    for (var index = 0; index < original.length; index++) {
      startId[index] = _weldId(original[index].start, weldTolerance, ids);
      endId[index] = _weldId(original[index].end, weldTolerance, ids);
    }
    final adjacency = List<List<int>>.generate(ids.length, (_) => <int>[]);
    for (var index = 0; index < original.length; index++) {
      adjacency[startId[index]].add(index);
      adjacency[endId[index]].add(index);
    }

    final used = List<bool>.filled(original.length, false);
    final chains = <MeshDerivedEdgeChain>[];
    final turningHistogram = List<int>.filled(9, 0);
    final continuity = config.directionContinuityDegrees * math.pi / 180;
    for (var index = 0; index < original.length; index++) {
      if (used[index]) continue;
      final path = _walkChain(
        start: index,
        original: original,
        startId: startId,
        endId: endId,
        adjacency: adjacency,
        used: used,
        continuity: continuity,
        histogram: turningHistogram,
      );
      chains.add(_describeChain(path, original, startId, endId, adjacency));
    }

    final componentOf = List<int>.filled(original.length, -1);
    var componentCount = 0;
    final componentClosed = <int, bool>{};
    final componentHasBoundary = <int, bool>{};
    final componentHasAmbiguous = <int, bool>{};
    final visited = List<bool>.filled(original.length, false);
    for (var index = 0; index < original.length; index++) {
      if (visited[index]) continue;
      final queue = [index];
      visited[index] = true;
      var size = 0;
      var closed = true;
      var hasBoundary = false;
      var hasAmbiguous = false;
      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        componentOf[current] = componentCount;
        size++;
        final a = adjacency[startId[current]].length;
        final b = adjacency[endId[current]].length;
        if (a != 2 || b != 2) closed = false;
        final kind = original[current].kind;
        if (kind == MeshDerivedEdgeKind.openBoundary) hasBoundary = true;
        if (kind == MeshDerivedEdgeKind.ambiguous) hasAmbiguous = true;
        for (final vertex in [startId[current], endId[current]]) {
          for (final next in adjacency[vertex]) {
            if (visited[next]) continue;
            visited[next] = true;
            queue.add(next);
          }
        }
      }
      componentClosed[componentCount] = closed && size >= 3;
      componentHasBoundary[componentCount] = hasBoundary;
      componentHasAmbiguous[componentCount] = hasAmbiguous;
      componentCount++;
    }

    final shortLimit = config.shortIsolatedLengthFactor * scale;
    final clusterRadius = config.clusterRadiusFactor * scale;
    final candidate = List<bool>.filled(original.length, false);
    for (final chain in chains) {
      for (final index in chain.segmentIndices) {
        if (original[index].kind != MeshDerivedEdgeKind.crease) continue;
        final component = componentOf[index];
        if (componentHasBoundary[component] == true) continue;
        if (componentHasAmbiguous[component] == true) continue;
        if (componentClosed[component] == true) continue;
        if (chain.closed) continue;
        if (!chain.isolated) continue;
        if (chain.totalLength >= shortLimit) continue;
        candidate[index] = true;
      }
    }

    final midpoints = [
      for (final segment in original)
        _scale(_add(segment.start, segment.end), 0.5),
    ];
    final clusterBin = clusterRadius > 0 ? clusterRadius : 1.0;
    final bins = <(int, int, int), List<int>>{};
    for (var index = 0; index < original.length; index++) {
      if (original[index].kind != MeshDerivedEdgeKind.crease) continue;
      bins.putIfAbsent(_bin(midpoints[index], clusterBin), () => []).add(index);
    }
    for (var index = 0; index < original.length; index++) {
      if (!candidate[index]) continue;
      var neighbors = 0;
      final origin = _bin(midpoints[index], clusterBin);
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          for (var dz = -1; dz <= 1; dz++) {
            final cell = bins[(origin.$1 + dx, origin.$2 + dy, origin.$3 + dz)];
            if (cell == null) continue;
            for (final other in cell) {
              if (other == index) continue;
              if (_length(_subtract(midpoints[index], midpoints[other])) <=
                  clusterRadius) {
                neighbors++;
              }
            }
          }
        }
      }
      if (neighbors >= config.clusterMinNeighbors) {
        candidate[index] = false;
      }
    }

    var candidateCount = 0;
    var creaseCount = 0;
    for (var index = 0; index < original.length; index++) {
      if (original[index].kind == MeshDerivedEdgeKind.crease) creaseCount++;
      if (candidate[index]) candidateCount++;
    }
    final ratio = creaseCount == 0 ? 0.0 : candidateCount / creaseCount;
    final capExceeded =
        creaseCount >= 16 && ratio > config.maxCreaseSuppressionRatio;
    final applied = !capExceeded;
    final keep = [
      for (var index = 0; index < original.length; index++)
        if (!applied || !candidate[index]) original[index],
    ];
    var openBoundary = 0, crease = 0, ambiguous = 0;
    for (final segment in keep) {
      switch (segment.kind) {
        case MeshDerivedEdgeKind.openBoundary:
          openBoundary++;
        case MeshDerivedEdgeKind.crease:
          crease++;
        case MeshDerivedEdgeKind.ambiguous:
          ambiguous++;
      }
    }
    var closedLoops = 0;
    for (final closed in componentClosed.values) {
      if (closed) closedLoops++;
    }
    var isolated = 0;
    for (final chain in chains) {
      if (chain.isolated) isolated++;
    }
    final suppressed = applied ? candidateCount : 0;
    stopwatch.stop();
    final estimatedBytes =
        ids.length * 16 +
        original.length * 40 +
        chains.length * 32 +
        keep.length * 24;
    return MeshDerivedEdgeRefinement(
      segments: List.unmodifiable(keep),
      originalSegments: original.length,
      refinedSegments: keep.length,
      openBoundaryEdges: openBoundary,
      creaseEdges: crease,
      ambiguousEdges: ambiguous,
      chains: chains.length,
      closedLoopCount: closedLoops,
      isolatedCount: isolated,
      suppressionCandidates: candidateCount,
      suppressed: suppressed,
      preserved: keep.length,
      applied: applied,
      skippedReason: capExceeded
          ? 'suppression_ratio_exceeds_conservative_cap'
          : null,
      turningAngleHistogram: List.unmodifiable(turningHistogram),
      elapsedMicros: stopwatch.elapsedMicroseconds,
      estimatedBytes: estimatedBytes,
    );
  }
}

(int, int, int) _bin(List<double> point, double size) => (
  (point[0] / size).round(),
  (point[1] / size).round(),
  (point[2] / size).round(),
);

int _weldId(
  List<double> point,
  double tolerance,
  Map<(int, int, int), int> ids,
) {
  final key = (
    (point[0] / tolerance).round(),
    (point[1] / tolerance).round(),
    (point[2] / tolerance).round(),
  );
  return ids.putIfAbsent(key, () => ids.length);
}

int _otherVertex(int segment, int vertex, List<int> startId, List<int> endId) =>
    startId[segment] == vertex ? endId[segment] : startId[segment];

List<double> _direction(
  MeshDerivedEdgeSegment segment,
  int fromVertex,
  int start,
  int end,
) {
  final forward = _subtract(segment.end, segment.start);
  return start == fromVertex ? forward : _scale(forward, -1);
}

List<int> _walkChain({
  required int start,
  required List<MeshDerivedEdgeSegment> original,
  required List<int> startId,
  required List<int> endId,
  required List<List<int>> adjacency,
  required List<bool> used,
  required double continuity,
  required List<int> histogram,
}) {
  used[start] = true;
  final backward = _extend(
    segment: start,
    vertex: startId[start],
    original: original,
    startId: startId,
    endId: endId,
    adjacency: adjacency,
    used: used,
    continuity: continuity,
    histogram: histogram,
  );
  final forward = _extend(
    segment: start,
    vertex: endId[start],
    original: original,
    startId: startId,
    endId: endId,
    adjacency: adjacency,
    used: used,
    continuity: continuity,
    histogram: histogram,
  );
  return [...backward.reversed, start, ...forward];
}

List<int> _extend({
  required int segment,
  required int vertex,
  required List<MeshDerivedEdgeSegment> original,
  required List<int> startId,
  required List<int> endId,
  required List<List<int>> adjacency,
  required List<bool> used,
  required double continuity,
  required List<int> histogram,
}) {
  final path = <int>[];
  var current = segment;
  var currentVertex = vertex;
  while (true) {
    var incoming = _direction(
      original[current],
      currentVertex,
      startId[current],
      endId[current],
    );
    incoming = _scale(incoming, -1);
    final incomingLength = _length(incoming);
    if (incomingLength <= 1e-20) break;
    incoming = _scale(incoming, 1 / incomingLength);
    int? best;
    var bestAngle = double.infinity;
    for (final next in adjacency[currentVertex]) {
      if (used[next] || next == current) continue;
      final outgoing = _direction(
        original[next],
        currentVertex,
        startId[next],
        endId[next],
      );
      final outgoingLength = _length(outgoing);
      if (outgoingLength <= 1e-20) continue;
      final cosine = _dot(
        incoming,
        _scale(outgoing, 1 / outgoingLength),
      ).clamp(-1.0, 1.0);
      final angle = math.acos(cosine);
      if (angle < bestAngle || (angle == bestAngle && next < (best ?? next))) {
        bestAngle = angle;
        best = next;
      }
    }
    if (best == null || bestAngle > continuity) break;
    final bucket = math.min(8, (bestAngle * 180 / math.pi).floor() ~/ 10);
    histogram[bucket]++;
    used[best] = true;
    path.add(best);
    final nextVertex = _otherVertex(best, currentVertex, startId, endId);
    current = best;
    currentVertex = nextVertex;
  }
  return path;
}

MeshDerivedEdgeChain _describeChain(
  List<int> path,
  List<MeshDerivedEdgeSegment> original,
  List<int> startId,
  List<int> endId,
  List<List<int>> adjacency,
) {
  var total = 0.0;
  var turning = 0.0;
  var turns = 0;
  var openBoundary = false;
  var ambiguous = false;
  var crease = false;
  for (var i = 0; i < path.length; i++) {
    final segment = original[path[i]];
    total += _length(_subtract(segment.end, segment.start));
    switch (segment.kind) {
      case MeshDerivedEdgeKind.openBoundary:
        openBoundary = true;
      case MeshDerivedEdgeKind.ambiguous:
        ambiguous = true;
      case MeshDerivedEdgeKind.crease:
        crease = true;
    }
    if (i == 0) continue;
    final previous = original[path[i - 1]];
    final shared = _sharedVertex(path[i - 1], path[i], startId, endId);
    if (shared == null) continue;
    final a = _direction(
      previous,
      shared,
      startId[path[i - 1]],
      endId[path[i - 1]],
    );
    final b = _direction(segment, shared, startId[path[i]], endId[path[i]]);
    final la = _length(a), lb = _length(b);
    if (la <= 1e-20 || lb <= 1e-20) continue;
    turning += math.acos(
      _dot(_scale(a, -1 / la), _scale(b, 1 / lb)).clamp(-1.0, 1.0),
    );
    turns++;
  }
  final first = path.first;
  final last = path.last;
  final closed =
      path.length >= 3 &&
      (startId[first] == startId[last] ||
          startId[first] == endId[last] ||
          endId[first] == startId[last] ||
          endId[first] == endId[last]);
  final isolated =
      path.length == 1 &&
      adjacency[startId[first]].length == 1 &&
      adjacency[endId[first]].length == 1;
  return MeshDerivedEdgeChain(
    segmentIndices: List.unmodifiable(path),
    totalLength: total,
    closed: closed,
    meanTurningDegrees: turns == 0 ? 0 : turning * 180 / math.pi / turns,
    isolated: isolated,
    hasOpenBoundary: openBoundary,
    hasAmbiguous: ambiguous,
    hasCrease: crease,
  );
}

int? _sharedVertex(int first, int second, List<int> startId, List<int> endId) {
  if (startId[first] == startId[second] || startId[first] == endId[second]) {
    return startId[first];
  }
  if (endId[first] == startId[second] || endId[first] == endId[second]) {
    return endId[first];
  }
  return null;
}

MeshDerivedEdgeLengthStatistics _refinerLengthStatistics(
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
    p50: percentile(.5),
    p90: percentile(.9),
    p95: percentile(.95),
    p99: percentile(.99),
  );
}

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

double _dot(List<double> a, List<double> b) =>
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

double _length(List<double> value) => math.sqrt(_dot(value, value));
