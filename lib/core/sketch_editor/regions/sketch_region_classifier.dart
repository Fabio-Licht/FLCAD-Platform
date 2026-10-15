import 'dart:math' as math;

import '../../sketch_engine/models/sketch_models.dart';

enum SketchRegionRole { outer, hole, island }

enum SketchRegionOrientation { clockwise, counterClockwise, degenerate }

enum SketchRegionDiagnosticCode {
  duplicateLoopId,
  excludedLoop,
  openLoop,
  insufficientSamples,
  nonFinitePoint,
  degenerateLoop,
  selfIntersection,
  boundaryContact,
  ambiguousContainment,
}

/// Already-sampled, transient input to [SketchRegionClassifier].
///
/// Loop extraction remains owned by the Sketch/operation layer. This model
/// deliberately carries only presentation-time samples and source identity;
/// it never writes geometry or creates constraints.
class SketchRegionLoopInput {
  const SketchRegionLoopInput({
    required this.id,
    required this.entityIds,
    required this.points,
    this.closed = true,
    this.samplingSufficient = true,
    this.construction = false,
    this.reference = false,
  });

  final String id;
  final List<String> entityIds;
  final List<SketchVector> points;
  final bool closed;

  /// Supplied by the extractor when its arc/spline sample budget is adequate.
  final bool samplingSufficient;
  final bool construction;
  final bool reference;
}

class SketchRegionDiagnostic {
  const SketchRegionDiagnostic(this.code, this.loopIds, this.message);

  final SketchRegionDiagnosticCode code;
  final List<String> loopIds;
  final String message;
}

class SketchRegionLoop {
  const SketchRegionLoop({
    required this.id,
    required this.entityIds,
    required this.points,
    required this.signedArea,
    required this.absoluteArea,
    required this.orientation,
    this.parentLoopId,
    this.depth,
    this.role,
  });

  final String id;
  final List<String> entityIds;
  final List<SketchVector> points;
  final double signedArea, absoluteArea;
  final SketchRegionOrientation orientation;
  final String? parentLoopId;
  final int? depth;
  final SketchRegionRole? role;
}

class SketchRegionClassification {
  const SketchRegionClassification({
    required this.loops,
    required this.diagnostics,
    required this.excludedLoopIds,
  });

  final List<SketchRegionLoop> loops;
  final List<SketchRegionDiagnostic> diagnostics;
  final List<String> excludedLoopIds;

  bool get conclusive => diagnostics.isEmpty;
}

/// Deterministic, non-persistent classifier for nested Sketch regions.
///
/// Containment, rather than winding direction, determines material parity:
/// depth 0 is [SketchRegionRole.outer], odd depths are holes, and even depths
/// greater than zero are islands. Any contact or intersection that could make
/// containment ambiguous rejects the complete classification.
class SketchRegionClassifier {
  const SketchRegionClassifier({this.tolerance = 1e-6});

  final double tolerance;

  SketchRegionClassification classify(Iterable<SketchRegionLoopInput> source) {
    if (!tolerance.isFinite || tolerance <= 0) {
      throw ArgumentError.value(tolerance, 'tolerance');
    }
    final diagnostics = <SketchRegionDiagnostic>[];
    final excluded = <String>[];
    final candidates = <_PreparedLoop>[];
    final ids = <String>{};
    for (final input in source) {
      if (input.construction || input.reference) {
        excluded.add(input.id);
        continue;
      }
      if (!ids.add(input.id)) {
        diagnostics.add(
          SketchRegionDiagnostic(
            SketchRegionDiagnosticCode.duplicateLoopId,
            [input.id],
            'Loop identity is not unique.',
          ),
        );
        continue;
      }
      final prepared = _prepare(input, diagnostics);
      if (prepared != null) candidates.add(prepared);
    }
    if (diagnostics.isNotEmpty) {
      return _rejected(candidates, diagnostics, excluded);
    }

    for (var i = 0; i < candidates.length; i++) {
      for (var j = i + 1; j < candidates.length; j++) {
        if (_boundariesContact(candidates[i].points, candidates[j].points)) {
          diagnostics.add(
            SketchRegionDiagnostic(
              SketchRegionDiagnosticCode.boundaryContact,
              [candidates[i].id, candidates[j].id],
              'Loop boundaries cross or touch within tolerance.',
            ),
          );
        }
      }
    }
    if (diagnostics.isNotEmpty) {
      return _rejected(candidates, diagnostics, excluded);
    }

    final parents = <String, String?>{};
    final depths = <String, int>{};
    for (final child in candidates) {
      final containers =
          candidates
              .where(
                (parent) =>
                    parent.id != child.id &&
                    parent.absoluteArea > child.absoluteArea &&
                    _containsStrict(parent.points, child.points.first),
              )
              .toList()
            ..sort((a, b) => a.absoluteArea.compareTo(b.absoluteArea));
      parents[child.id] = containers.firstOrNull?.id;
    }
    int depthOf(_PreparedLoop loop, Set<String> visiting) {
      final known = depths[loop.id];
      if (known != null) return known;
      if (!visiting.add(loop.id)) {
        diagnostics.add(
          SketchRegionDiagnostic(
            SketchRegionDiagnosticCode.ambiguousContainment,
            [loop.id],
            'Loop containment is cyclic or ambiguous.',
          ),
        );
        return 0;
      }
      final parentId = parents[loop.id];
      final parent = parentId == null
          ? null
          : candidates.firstWhere((item) => item.id == parentId);
      final value = parent == null ? 0 : depthOf(parent, visiting) + 1;
      visiting.remove(loop.id);
      depths[loop.id] = value;
      return value;
    }

    for (final loop in candidates) {
      depthOf(loop, <String>{});
    }
    if (diagnostics.isNotEmpty) {
      return _rejected(candidates, diagnostics, excluded);
    }

    return SketchRegionClassification(
      loops: List.unmodifiable([
        for (final loop in candidates)
          SketchRegionLoop(
            id: loop.id,
            entityIds: loop.entityIds,
            points: loop.points,
            signedArea: loop.signedArea,
            absoluteArea: loop.absoluteArea,
            orientation: loop.orientation,
            parentLoopId: parents[loop.id],
            depth: depths[loop.id],
            role: _roleForDepth(depths[loop.id]!),
          ),
      ]),
      diagnostics: const [],
      excludedLoopIds: List.unmodifiable(excluded),
    );
  }

  _PreparedLoop? _prepare(
    SketchRegionLoopInput input,
    List<SketchRegionDiagnostic> diagnostics,
  ) {
    if (!input.closed) {
      diagnostics.add(
        SketchRegionDiagnostic(SketchRegionDiagnosticCode.openLoop, [
          input.id,
        ], 'Loop is open.'),
      );
      return null;
    }
    if (!input.samplingSufficient) {
      diagnostics.add(
        SketchRegionDiagnostic(
          SketchRegionDiagnosticCode.insufficientSamples,
          [input.id],
          'Loop sampling is insufficient for region classification.',
        ),
      );
      return null;
    }
    final points = <SketchVector>[];
    for (final point in input.points) {
      if (![point.x, point.y, point.z].every((value) => value.isFinite)) {
        diagnostics.add(
          SketchRegionDiagnostic(
            SketchRegionDiagnosticCode.nonFinitePoint,
            [input.id],
            'Loop contains a non-finite point.',
          ),
        );
        return null;
      }
      if (points.isEmpty || !_near(points.last, point)) points.add(point);
    }
    if (points.length > 1 && _near(points.first, points.last)) {
      points.removeLast();
    }
    if (points.length < 3) {
      diagnostics.add(
        SketchRegionDiagnostic(
          SketchRegionDiagnosticCode.insufficientSamples,
          [input.id],
          'Loop has fewer than three distinct samples.',
        ),
      );
      return null;
    }
    final signedArea = _area(points);
    if (signedArea.abs() <= tolerance * tolerance) {
      diagnostics.add(
        SketchRegionDiagnostic(
          SketchRegionDiagnosticCode.degenerateLoop,
          [input.id],
          'Loop area is below the classification tolerance.',
        ),
      );
      return null;
    }
    if (_selfIntersects(points)) {
      diagnostics.add(
        SketchRegionDiagnostic(
          SketchRegionDiagnosticCode.selfIntersection,
          [input.id],
          'Loop self-intersects or contains a non-adjacent contact.',
        ),
      );
      return null;
    }
    return _PreparedLoop(
      id: input.id,
      entityIds: List.unmodifiable(input.entityIds),
      points: List.unmodifiable(points),
      signedArea: signedArea,
    );
  }

  SketchRegionClassification _rejected(
    List<_PreparedLoop> loops,
    List<SketchRegionDiagnostic> diagnostics,
    List<String> excluded,
  ) => SketchRegionClassification(
    loops: List.unmodifiable([
      for (final loop in loops)
        SketchRegionLoop(
          id: loop.id,
          entityIds: loop.entityIds,
          points: loop.points,
          signedArea: loop.signedArea,
          absoluteArea: loop.absoluteArea,
          orientation: loop.orientation,
        ),
    ]),
    diagnostics: List.unmodifiable(diagnostics),
    excludedLoopIds: List.unmodifiable(excluded),
  );

  SketchRegionRole _roleForDepth(int depth) => depth.isEven
      ? (depth == 0 ? SketchRegionRole.outer : SketchRegionRole.island)
      : SketchRegionRole.hole;

  double _area(List<SketchVector> points) {
    var value = 0.0;
    for (var i = 0; i < points.length; i++) {
      final next = points[(i + 1) % points.length];
      value += points[i].x * next.y - next.x * points[i].y;
    }
    return value / 2;
  }

  bool _selfIntersects(List<SketchVector> points) {
    for (var i = 0; i < points.length; i++) {
      final a = points[i], b = points[(i + 1) % points.length];
      for (var j = i + 1; j < points.length; j++) {
        if (j == i + 1 || (i == 0 && j == points.length - 1)) continue;
        if (_segmentsContact(
          a,
          b,
          points[j],
          points[(j + 1) % points.length],
        )) {
          return true;
        }
      }
    }
    return false;
  }

  bool _boundariesContact(List<SketchVector> a, List<SketchVector> b) {
    for (var i = 0; i < a.length; i++) {
      final a0 = a[i], a1 = a[(i + 1) % a.length];
      for (var j = 0; j < b.length; j++) {
        if (_segmentsContact(a0, a1, b[j], b[(j + 1) % b.length])) return true;
      }
    }
    return false;
  }

  bool _segmentsContact(
    SketchVector a,
    SketchVector b,
    SketchVector c,
    SketchVector d,
  ) {
    final ab = b - a, cd = d - c;
    final values = [
      _cross(ab, c - a),
      _cross(ab, d - a),
      _cross(cd, a - c),
      _cross(cd, b - c),
    ];
    final proper = values[0] * values[1] < 0 && values[2] * values[3] < 0;
    if (proper) return true;
    return values.any((value) => value.abs() <= tolerance) &&
        _segmentDistance(a, b, c, d) <= tolerance;
  }

  double _segmentDistance(
    SketchVector a,
    SketchVector b,
    SketchVector c,
    SketchVector d,
  ) => math.min(
    math.min(_pointSegmentDistance(a, c, d), _pointSegmentDistance(b, c, d)),
    math.min(_pointSegmentDistance(c, a, b), _pointSegmentDistance(d, a, b)),
  );

  double _pointSegmentDistance(
    SketchVector point,
    SketchVector a,
    SketchVector b,
  ) {
    final dx = b.x - a.x, dy = b.y - a.y;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= tolerance * tolerance) return _distance(point, a);
    final t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared;
    final clamped = t.clamp(0.0, 1.0);
    return _distance(
      point,
      SketchVector(a.x + clamped * dx, a.y + clamped * dy),
    );
  }

  bool _containsStrict(List<SketchVector> polygon, SketchVector point) {
    for (var i = 0; i < polygon.length; i++) {
      if (_distanceToSegment(
            point,
            polygon[i],
            polygon[(i + 1) % polygon.length],
          ) <=
          tolerance) {
        return false;
      }
    }
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i], b = polygon[j];
      if ((a.y > point.y) != (b.y > point.y)) {
        final x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x;
        if (point.x < x) inside = !inside;
      }
    }
    return inside;
  }

  double _distanceToSegment(SketchVector p, SketchVector a, SketchVector b) =>
      _pointSegmentDistance(p, a, b);

  bool _near(SketchVector a, SketchVector b) => _distance(a, b) <= tolerance;

  double _distance(SketchVector a, SketchVector b) =>
      math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

  double _cross(SketchVector a, SketchVector b) => a.x * b.y - a.y * b.x;
}

class _PreparedLoop {
  _PreparedLoop({
    required this.id,
    required this.entityIds,
    required this.points,
    required this.signedArea,
  });

  final String id;
  final List<String> entityIds;
  final List<SketchVector> points;
  final double signedArea;

  double get absoluteArea => signedArea.abs();

  SketchRegionOrientation get orientation => signedArea > 0
      ? SketchRegionOrientation.counterClockwise
      : SketchRegionOrientation.clockwise;
}
