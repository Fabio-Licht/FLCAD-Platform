import 'dart:math' as math;

import '../../sketch_engine/entities/sketch_entities.dart';
import '../../sketch_engine/geometry/sketch_spline_geometry.dart';
import '../../sketch_engine/models/sketch_models.dart';

/// Result of a geometric (non-associative) 2D Sketch offset.
sealed class SketchOffsetCurve {
  const SketchOffsetCurve();
}

final class SketchOffsetLine extends SketchOffsetCurve {
  const SketchOffsetLine(this.start, this.end);
  final SketchVector start;
  final SketchVector end;
}

final class SketchOffsetArc extends SketchOffsetCurve {
  const SketchOffsetArc(
    this.center,
    this.radius,
    this.startAngle,
    this.endAngle,
  );
  final SketchVector center;
  final double radius;
  final double startAngle;
  final double endAngle;
}

final class SketchOffsetCircle extends SketchOffsetCurve {
  const SketchOffsetCircle(this.center, this.radius);
  final SketchVector center;
  final double radius;
}

final class SketchOffsetEllipse extends SketchOffsetCurve {
  const SketchOffsetEllipse(this.center, this.radiusX, this.radiusY);
  final SketchVector center;
  final double radiusX;
  final double radiusY;
}

final class SketchOffsetSpline extends SketchOffsetCurve {
  const SketchOffsetSpline(
    this.points,
    this.estimatedMaxErrorMm,
    this.signedDistanceMm,
  );
  final List<SketchVector> points;

  /// Sampled Hausdorff estimate, not a mathematical global error bound.
  final double estimatedMaxErrorMm;
  final double signedDistanceMm;
}

/// Deterministic offset for a single arc or a connected line chain/profile.
/// Open chains use signed distance to the left of their directed path. Closed
/// line profiles use an explicit inside/outside choice. Joins are sharp miters.
final class SketchOffsetGeometry {
  const SketchOffsetGeometry._();

  static const double connectionTolerance = 1e-7;
  static const double minimumLength = 1e-10;
  static const double parallelTolerance = 1e-12;
  static const double splineErrorGoalMm = 0.05;
  static const int splineKnotLimit = 256;
  static const int splineRefinementLimit = 12;
  static const int splineIntersectionPairLimit = 250000;

  static List<SketchOffsetCurve> calculate(
    Iterable<SketchEntity> source, {
    required double distance,
    bool outward = true,
  }) {
    if (!distance.isFinite || distance.abs() <= minimumLength) {
      throw ArgumentError('Offset distance must be finite and non-zero.');
    }
    final entities = source.toList(growable: false);
    if (entities.isEmpty) throw StateError('Select Sketch geometry to offset.');
    if (entities.any((entity) => entity.locked || entity.reference)) {
      throw StateError('Locked or reference geometry cannot be offset.');
    }
    if (entities.length == 1 && entities.single is SketchArc) {
      return [
        _offsetArc(
          entities.single as SketchArc,
          outward ? distance : -distance,
        ),
      ];
    }
    if (entities.length == 1 && entities.single is SketchCircle) {
      final circle = entities.single as SketchCircle;
      final radius = (circle.parameters['radius'] as num).toDouble();
      final resultRadius = radius + (outward ? distance : -distance);
      if (!radius.isFinite ||
          radius <= minimumLength ||
          !resultRadius.isFinite ||
          resultRadius <= minimumLength) {
        throw StateError('Offset collapses the circle radius.');
      }
      return [
        SketchOffsetCircle(
          SketchVector.fromJson(circle.parameters['center']),
          resultRadius,
        ),
      ];
    }
    if (entities.length == 1 && entities.single is SketchEllipse) {
      final ellipse = entities.single as SketchEllipse;
      final center = SketchVector.fromJson(ellipse.parameters['center']);
      // Preserve the existing Sketch ellipse behavior: increase/decrease both
      // axis radii and create an independent ellipse. This is an axis-based
      // offset approximation, not an exact constant-distance ellipse curve.
      final direction = outward ? 1.0 : -1.0;
      final radiusX =
          (ellipse.parameters['radiusX'] as num).toDouble() +
          direction * distance;
      final radiusY =
          (ellipse.parameters['radiusY'] as num).toDouble() +
          direction * distance;
      if (!radiusX.isFinite ||
          !radiusY.isFinite ||
          radiusX <= minimumLength ||
          radiusY <= minimumLength) {
        throw StateError('Offset collapses the ellipse radii.');
      }
      return [SketchOffsetEllipse(center, radiusX, radiusY)];
    }
    if (entities.length == 1 && entities.single is SketchSpline) {
      return [
        _offsetSpline(
          entities.single as SketchSpline,
          outward ? distance : -distance,
        ),
      ];
    }
    if (entities.any((entity) => entity is! SketchLine)) {
      throw StateError(
        'Connected offsets currently support line chains; arcs must be offset individually.',
      );
    }
    final lines = entities.cast<SketchLine>();
    final path = _orderLines(lines);
    final closed = _same(path.last.end, path.first.start);
    final sourceArea = closed ? _signedArea(path) : 0.0;
    final effectiveDistance = closed
        ? _closedDistance(path, distance.abs(), outward)
        : (outward ? distance : -distance);
    final points = _miterPath(path, effectiveDistance, closed);
    _rejectReversedSegments(path, points, closed);
    _rejectSelfIntersections(points, closed, sourceArea: sourceArea);
    return [
      for (var index = 0; index < points.length - 1; index++)
        SketchOffsetLine(points[index], points[index + 1]),
    ];
  }

  static SketchOffsetSpline _offsetSpline(
    SketchSpline spline,
    double signedDistance,
  ) {
    if (spline.parameters['interpolation'] != 'centripetalCatmullRom') {
      throw StateError('Offset supports interpolated splines only.');
    }
    final raw = spline.parameters['points'];
    if (raw is! List || raw.length < 2) {
      throw StateError('Interpolated spline has invalid control knots.');
    }
    final knots = raw.map((point) => SketchVector.fromJson(point)).toList();
    final planeZ = knots.first.z;
    if (knots.any((point) => (point.z - planeZ).abs() > 1e-8)) {
      throw StateError('Spline Offset requires a planar Sketch spline.');
    }
    for (var index = 1; index < knots.length; index++) {
      if (_distance(knots[index - 1], knots[index]) <= 1e-9) {
        throw StateError('Spline contains repeated or degenerate knots.');
      }
    }

    SketchVector targetAt(double parameter) {
      final lastSpan = knots.length - 2;
      final clamped = parameter.clamp(0.0, (knots.length - 1).toDouble());
      final span = math.min(clamped.floor(), lastSpan);
      final u = clamped - span;
      final point = SketchSplineGeometry.evaluateSpan(knots, span, u);
      final derivatives = SketchSplineGeometry.derivativesAtSpan(
        knots,
        span,
        u,
      );
      final tangent = derivatives.first;
      final tangentLength = math.sqrt(
        tangent.x * tangent.x + tangent.y * tangent.y,
      );
      if (!tangentLength.isFinite || tangentLength <= 1e-9) {
        throw StateError('Spline Offset rejected a degenerate tangent.');
      }
      final speedSquared = tangentLength * tangentLength;
      final curvature =
          (tangent.x * derivatives.second.y -
              tangent.y * derivatives.second.x) /
          (speedSquared * tangentLength);
      final curvatureFactor = 1 - signedDistance * curvature;
      if (!curvature.isFinite || curvatureFactor <= 1e-5) {
        throw StateError(
          'Offset distance is incompatible with local spline curvature.',
        );
      }
      final nx = -tangent.y / tangentLength;
      final ny = tangent.x / tangentLength;
      return SketchVector(
        point.x + signedDistance * nx,
        point.y + signedDistance * ny,
        planeZ,
      );
    }

    // Adapt the target sampling density to offset-curve chord error. This
    // guards curvature peaks before the separate reconstruction refinement.
    const targetChordTolerance = splineErrorGoalMm * 0.2;
    const targetSubdivisionLimit = 12;
    const targetSampleLimit = 8192;
    final targetSamples = <({double parameter, SketchVector point})>[];
    double distanceToSegment(
      SketchVector point,
      SketchVector start,
      SketchVector end,
    ) {
      final direction = end - start;
      final lengthSquared = direction.dot(direction);
      final t = lengthSquared <= 1e-24
          ? 0.0
          : ((point - start).dot(direction) / lengthSquared).clamp(0.0, 1.0);
      return _distance(point, start + direction.scale(t));
    }

    void subdivideTarget(
      double startParameter,
      SketchVector startPoint,
      double endParameter,
      SketchVector endPoint,
      int depth,
    ) {
      final interval = endParameter - startParameter;
      final quarterParameter = startParameter + interval * 0.25;
      final middleParameter = startParameter + interval * 0.5;
      final threeQuarterParameter = startParameter + interval * 0.75;
      final quarterPoint = targetAt(quarterParameter);
      final middlePoint = targetAt(middleParameter);
      final threeQuarterPoint = targetAt(threeQuarterParameter);
      final deviation = math.max(
        distanceToSegment(quarterPoint, startPoint, endPoint),
        math.max(
          distanceToSegment(middlePoint, startPoint, endPoint),
          distanceToSegment(threeQuarterPoint, startPoint, endPoint),
        ),
      );
      if (deviation <= targetChordTolerance) {
        targetSamples.add((parameter: endParameter, point: endPoint));
        if (targetSamples.length > targetSampleLimit) {
          throw StateError('Spline Offset exceeded its adaptive sample limit.');
        }
        return;
      }
      if (depth >= targetSubdivisionLimit) {
        throw StateError(
          'Spline Offset target sampling could not meet its chord error '
          'within the subdivision limit.',
        );
      }
      subdivideTarget(
        startParameter,
        startPoint,
        middleParameter,
        middlePoint,
        depth + 1,
      );
      subdivideTarget(
        middleParameter,
        middlePoint,
        endParameter,
        endPoint,
        depth + 1,
      );
    }

    final startPoint = targetAt(0);
    targetSamples.add((parameter: 0, point: startPoint));
    for (var span = 0; span < knots.length - 1; span++) {
      subdivideTarget(
        span.toDouble(),
        span == 0 ? startPoint : targetSamples.last.point,
        (span + 1).toDouble(),
        targetAt((span + 1).toDouble()),
        0,
      );
    }
    final targetPolyline = targetSamples
        .map((sample) => sample.point)
        .toList(growable: false);
    _rejectSplineSelfIntersections(targetPolyline);

    final chosen = <({double parameter, SketchVector point})>[
      targetSamples.first,
      targetSamples.last,
    ];
    List<SketchVector> sampled(List<SketchVector> controls) =>
        SketchSplineGeometry.interpolate(controls, samplesPerSpan: 128);
    double pointPolylineDistance(
      SketchVector point,
      List<SketchVector> polyline,
    ) {
      var best = double.infinity;
      for (var index = 1; index < polyline.length; index++) {
        final a = polyline[index - 1], b = polyline[index];
        final ab = b - a;
        final lengthSquared = ab.dot(ab);
        final t = lengthSquared <= 1e-24
            ? 0.0
            : ((point - a).dot(ab) / lengthSquared).clamp(0.0, 1.0);
        final projection = a + ab.scale(t);
        best = math.min(best, _distance(point, projection));
      }
      return best;
    }

    var maxError = double.infinity;
    for (
      var refinement = 0;
      refinement <= splineRefinementLimit;
      refinement++
    ) {
      final controls = chosen.map((sample) => sample.point).toList();
      final approximation = sampled(controls);
      maxError = 0;
      var worst = targetSamples.first;
      for (final target in targetSamples) {
        final error = pointPolylineDistance(target.point, approximation);
        if (error > maxError) {
          maxError = error;
          worst = target;
        }
      }
      // Also sample the reconstructed curve against the independently sampled
      // target polyline to avoid measuring only one side of the deviation.
      for (final point in approximation) {
        maxError = math.max(
          maxError,
          pointPolylineDistance(point, targetPolyline),
        );
      }
      if (maxError <= splineErrorGoalMm) {
        _rejectSplineSelfIntersections(approximation);
        return SketchOffsetSpline(
          List.unmodifiable(controls),
          maxError,
          signedDistance,
        );
      }
      if (chosen.length >= splineKnotLimit ||
          refinement == splineRefinementLimit) {
        throw StateError(
          'Spline Offset could not meet the 0.05 mm sampled error goal '
          'within the $splineKnotLimit-knot computation limit '
          '(estimated error ${maxError.toStringAsFixed(6)} mm).',
        );
      }
      final insertion = chosen.indexWhere(
        (sample) => sample.parameter > worst.parameter,
      );
      if (insertion <= 0 || insertion >= chosen.length) {
        throw StateError('Spline Offset refinement stalled before tolerance.');
      }
      chosen.insert(insertion, worst);
    }
    throw StateError('Spline Offset refinement did not converge.');
  }

  static void _rejectSplineSelfIntersections(List<SketchVector> points) {
    final segments = <_SplineSegment>[];
    for (var index = 0; index + 1 < points.length; index++) {
      final a = points[index], b = points[index + 1];
      segments.add(
        _SplineSegment(
          index,
          a,
          b,
          math.min(a.x, b.x),
          math.max(a.x, b.x),
          math.min(a.y, b.y),
          math.max(a.y, b.y),
        ),
      );
    }
    segments.sort((a, b) => a.minX.compareTo(b.minX));
    final active = <_SplineSegment>[];
    var sweepVisits = 0;
    void accountSweepVisits(int count) {
      sweepVisits += count;
      if (sweepVisits > splineIntersectionPairLimit) {
        throw StateError(
          'Spline Offset exceeded its bounded self-intersection sweep '
          '($splineIntersectionPairLimit segment visits).',
        );
      }
    }

    for (final current in segments) {
      // removeWhere scans the complete active list, so count that work too.
      accountSweepVisits(active.length);
      active.removeWhere(
        (segment) => segment.maxX < current.minX - connectionTolerance,
      );
      for (final candidate in active) {
        accountSweepVisits(1);
        if ((candidate.index - current.index).abs() <= 1 ||
            candidate.maxY < current.minY - connectionTolerance ||
            current.maxY < candidate.minY - connectionTolerance) {
          continue;
        }
        if (_segmentsIntersect(
          candidate.start,
          candidate.end,
          current.start,
          current.end,
        )) {
          throw StateError('Spline Offset would create a self-intersection.');
        }
      }
      active.add(current);
    }
  }

  static SketchOffsetArc _offsetArc(SketchArc arc, double distance) {
    final radius = (arc.parameters['radius'] as num).toDouble();
    final start = (arc.parameters['startAngle'] as num).toDouble();
    final end = (arc.parameters['endAngle'] as num).toDouble();
    if (!radius.isFinite ||
        radius <= minimumLength ||
        !start.isFinite ||
        !end.isFinite ||
        (end - start).abs() <= 1e-12) {
      throw StateError('Cannot offset a degenerate arc.');
    }
    // Positive distance follows the left normal of the arc tangent.
    final resultRadius = radius - (end > start ? distance : -distance);
    if (!resultRadius.isFinite || resultRadius <= minimumLength) {
      throw StateError('Offset collapses the arc radius.');
    }
    return SketchOffsetArc(
      SketchVector.fromJson(arc.parameters['center']),
      resultRadius,
      start,
      end,
    );
  }

  static List<_DirectedLine> _orderLines(List<SketchLine> lines) {
    if (lines.any((line) => line.locked || line.reference)) {
      throw StateError('Locked or reference geometry cannot be offset.');
    }
    final edges = <_Edge>[];
    for (final line in lines) {
      final a = SketchVector.fromJson(line.parameters['start']);
      final b = SketchVector.fromJson(line.parameters['end']);
      if (_distance(a, b) <= minimumLength) {
        throw StateError('Offset rejects zero-length line ${line.id}.');
      }
      edges.add(_Edge(line, a, b));
    }
    for (var i = 0; i < edges.length; i++) {
      for (var j = i + 1; j < edges.length; j++) {
        if (_same(edges[i].a, edges[j].a) || _same(edges[i].a, edges[j].b)) {
          edges[i].neighbors++;
          edges[j].neighbors++;
        }
        if (_same(edges[i].b, edges[j].a) || _same(edges[i].b, edges[j].b)) {
          edges[i].neighbors++;
          edges[j].neighbors++;
        }
      }
    }
    if (edges.any((edge) => edge.neighbors > 2)) {
      throw StateError('Branching line selections are ambiguous for Offset.');
    }
    final endpoints = <SketchVector>[];
    for (final edge in edges) {
      for (final point in [edge.a, edge.b]) {
        final degree = edges.fold<int>(
          0,
          (count, candidate) =>
              count +
              ((_same(candidate.a, point) ? 1 : 0) +
                  (_same(candidate.b, point) ? 1 : 0)),
        );
        if (degree == 1 && !endpoints.any((item) => _same(item, point))) {
          endpoints.add(point);
        }
      }
    }
    final closed = endpoints.isEmpty;
    if ((!closed && endpoints.length != 2) ||
        (closed && edges.any((edge) => edge.neighbors != 2))) {
      throw StateError(
        'Selected lines must form one connected open or closed chain.',
      );
    }
    final firstEdge = edges.first;
    final start = closed
        ? firstEdge.a
        : endpoints.reduce((a, b) => _lexicographic(a, b) <= 0 ? a : b);
    final ordered = <_DirectedLine>[];
    final used = <_Edge>{};
    var current = start;
    while (used.length < edges.length) {
      final candidates = used.isEmpty && closed
          ? [firstEdge]
          : edges
                .where(
                  (edge) =>
                      !used.contains(edge) &&
                      (_same(edge.a, current) || _same(edge.b, current)),
                )
                .toList();
      if (candidates.length != 1) {
        throw StateError('Selected lines are disconnected or ambiguous.');
      }
      final edge = candidates.single;
      final forward = _same(edge.a, current);
      final next = forward ? edge.b : edge.a;
      ordered.add(_DirectedLine(current, next));
      used.add(edge);
      current = next;
    }
    if (closed && !_same(current, start)) {
      throw StateError('Closed profile does not return to its start point.');
    }
    if (!closed && _same(current, start)) {
      throw StateError('Open chain unexpectedly closes.');
    }
    return ordered;
  }

  static double _closedDistance(
    List<_DirectedLine> path,
    double distance,
    bool outward,
  ) {
    var area2 = 0.0;
    for (final edge in path) {
      area2 += edge.start.x * edge.end.y - edge.end.x * edge.start.y;
    }
    if (area2.abs() <= minimumLength) {
      throw StateError('Closed profile has zero signed area.');
    }
    // CCW interior lies left; CW interior lies right.
    final ccw = area2 > 0;
    return outward
        ? (ccw ? -distance : distance)
        : (ccw ? distance : -distance);
  }

  static List<SketchVector> _miterPath(
    List<_DirectedLine> path,
    double distance,
    bool closed,
  ) {
    final shifted = <_DirectedLine>[];
    for (final edge in path) {
      final dx = edge.end.x - edge.start.x;
      final dy = edge.end.y - edge.start.y;
      final length = math.sqrt(dx * dx + dy * dy);
      if (!length.isFinite || length <= minimumLength) {
        throw StateError('Offset contains a degenerate segment.');
      }
      final normal = SketchVector(
        -dy / length * distance,
        dx / length * distance,
      );
      shifted.add(_DirectedLine(edge.start + normal, edge.end + normal));
    }
    final result = <SketchVector>[];
    if (!closed) result.add(shifted.first.start);
    final vertexCount = closed ? path.length : path.length - 1;
    for (var i = 0; i < vertexCount; i++) {
      final previous = shifted[i];
      final next = shifted[(i + 1) % shifted.length];
      result.add(_intersection(previous, next));
    }
    if (!closed) {
      result.add(shifted.last.end);
    } else {
      result.add(result.first);
    }
    if (result.any(
      (point) => !point.x.isFinite || !point.y.isFinite || !point.z.isFinite,
    )) {
      throw StateError('Offset produced non-finite coordinates.');
    }
    for (var index = 0; index < result.length - 1; index++) {
      if (_distance(result[index], result[index + 1]) <= minimumLength) {
        throw StateError('Offset would create a zero-length segment.');
      }
    }
    return result;
  }

  static SketchVector _intersection(_DirectedLine a, _DirectedLine b) {
    final ax = a.end.x - a.start.x, ay = a.end.y - a.start.y;
    final bx = b.end.x - b.start.x, by = b.end.y - b.start.y;
    final determinant = ax * by - ay * bx;
    if (determinant.abs() <= parallelTolerance) {
      throw StateError(
        'Offset miter is undefined at parallel or reversing segments.',
      );
    }
    final t =
        ((b.start.x - a.start.x) * by - (b.start.y - a.start.y) * bx) /
        determinant;
    return SketchVector(a.start.x + t * ax, a.start.y + t * ay, a.start.z);
  }

  static void _rejectSelfIntersections(
    List<SketchVector> points,
    bool closed, {
    required double sourceArea,
  }) {
    final count = points.length - 1;
    for (var i = 0; i < count; i++) {
      for (var j = i + 1; j < count; j++) {
        if (j == i + 1 || (closed && i == 0 && j == count - 1)) continue;
        if (_segmentsIntersect(
          points[i],
          points[i + 1],
          points[j],
          points[j + 1],
        )) {
          throw StateError('Offset would create a self-intersecting profile.');
        }
      }
    }
    if (closed) {
      var area2 = 0.0;
      for (var i = 0; i < count; i++) {
        area2 += points[i].x * points[i + 1].y - points[i + 1].x * points[i].y;
      }
      if (area2.abs() <= minimumLength || area2 * sourceArea <= 0) {
        throw StateError('Offset collapses the closed profile.');
      }
    }
  }

  static void _rejectReversedSegments(
    List<_DirectedLine> source,
    List<SketchVector> offset,
    bool closed,
  ) {
    for (var index = 0; index < source.length; index++) {
      final outputIndex = closed
          ? (index + source.length - 1) % source.length
          : index;
      final sourceDirection = source[index].end - source[index].start;
      final offsetDirection = offset[outputIndex + 1] - offset[outputIndex];
      if (sourceDirection.dot(offsetDirection) <= minimumLength) {
        throw StateError('Offset collapses or reverses a profile segment.');
      }
    }
  }

  static double _signedArea(List<_DirectedLine> path) {
    var area2 = 0.0;
    for (final edge in path) {
      area2 += edge.start.x * edge.end.y - edge.end.x * edge.start.y;
    }
    return area2 / 2;
  }

  static bool _segmentsIntersect(
    SketchVector a,
    SketchVector b,
    SketchVector c,
    SketchVector d,
  ) {
    double cross(SketchVector p, SketchVector q, SketchVector r) =>
        (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x);
    final scale = math.max(_distance(a, b), _distance(c, d));
    final coordinateTolerance = math.max(connectionTolerance, scale * 1e-12);
    double orientation(SketchVector p, SketchVector q, SketchVector r) =>
        cross(p, q, r);
    bool onSegment(SketchVector p, SketchVector q, SketchVector r) {
      final length = _distance(p, q);
      final areaTolerance = coordinateTolerance * math.max(1, length);
      return orientation(p, q, r).abs() <= areaTolerance &&
          r.x >= math.min(p.x, q.x) - coordinateTolerance &&
          r.x <= math.max(p.x, q.x) + coordinateTolerance &&
          r.y >= math.min(p.y, q.y) - coordinateTolerance &&
          r.y <= math.max(p.y, q.y) + coordinateTolerance;
    }

    final abC = orientation(a, b, c), abD = orientation(a, b, d);
    final cdA = orientation(c, d, a), cdB = orientation(c, d, b);
    final areaTolerance = coordinateTolerance * math.max(1, scale);
    final crosses =
        ((abC > areaTolerance && abD < -areaTolerance) ||
            (abC < -areaTolerance && abD > areaTolerance)) &&
        ((cdA > areaTolerance && cdB < -areaTolerance) ||
            (cdA < -areaTolerance && cdB > areaTolerance));
    return crosses ||
        onSegment(a, b, c) ||
        onSegment(a, b, d) ||
        onSegment(c, d, a) ||
        onSegment(c, d, b);
  }

  static bool _same(SketchVector a, SketchVector b) =>
      _distance(a, b) <= connectionTolerance;
  static double _distance(SketchVector a, SketchVector b) => math.sqrt(
    math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2) + math.pow(a.z - b.z, 2),
  );
  static int _lexicographic(SketchVector a, SketchVector b) {
    final x = a.x.compareTo(b.x);
    return x == 0 ? a.y.compareTo(b.y) : x;
  }
}

final class _Edge {
  _Edge(this.entity, this.a, this.b);
  final SketchLine entity;
  final SketchVector a;
  final SketchVector b;
  int neighbors = 0;
}

final class _DirectedLine {
  const _DirectedLine(this.start, this.end);
  final SketchVector start;
  final SketchVector end;
}

final class _SplineSegment {
  const _SplineSegment(
    this.index,
    this.start,
    this.end,
    this.minX,
    this.maxX,
    this.minY,
    this.maxY,
  );
  final int index;
  final SketchVector start;
  final SketchVector end;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;
}
