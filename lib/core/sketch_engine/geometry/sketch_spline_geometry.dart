import 'dart:math' as math;

import '../models/sketch_models.dart';

/// Interpolating centripetal Catmull-Rom curve. Every supplied knot lies on
/// the curve; the samples are presentation points, not replacement controls.
class SketchSplineGeometry {
  const SketchSplineGeometry._();

  static List<SketchVector> interpolate(
    List<SketchVector> knots, {
    int samplesPerSpan = 24,
  }) {
    if (knots.length < 2 || samplesPerSpan < 2) {
      throw ArgumentError(
        'Spline requires at least two knots and two samples.',
      );
    }
    for (var index = 1; index < knots.length; index++) {
      if (_distance(knots[index - 1], knots[index]) <= 1e-9) {
        throw ArgumentError('Spline knots must be distinct.');
      }
    }
    if (knots.length == 2) return List.of(knots);
    final output = <SketchVector>[knots.first];
    for (var index = 0; index + 1 < knots.length; index++) {
      final p1 = knots[index], p2 = knots[index + 1];
      final p0 = index == 0 ? p1 + (p1 - p2) : knots[index - 1];
      final p3 = index + 2 == knots.length ? p2 + (p2 - p1) : knots[index + 2];
      final t0 = 0.0;
      final t1 = t0 + math.sqrt(_distance(p0, p1));
      final t2 = t1 + math.sqrt(_distance(p1, p2));
      final t3 = t2 + math.sqrt(_distance(p2, p3));
      for (var sample = 1; sample <= samplesPerSpan; sample++) {
        if (sample == samplesPerSpan) {
          output.add(p2);
          continue;
        }
        final t = t1 + (t2 - t1) * sample / samplesPerSpan;
        final a1 = _blend(p0, p1, t0, t1, t);
        final a2 = _blend(p1, p2, t1, t2, t);
        final a3 = _blend(p2, p3, t2, t3, t);
        final b1 = _blend(a1, a2, t0, t2, t);
        final b2 = _blend(a2, a3, t1, t3, t);
        output.add(_blend(b1, b2, t1, t2, t));
      }
    }
    return output;
  }

  static List<SketchVector> cubicBezier(
    List<SketchVector> controls, {
    int samples = 48,
  }) {
    if (controls.length != 4 || samples < 2) {
      throw ArgumentError('Cubic Blend requires four Bezier controls.');
    }
    return List.generate(samples + 1, (index) {
      final t = index / samples;
      final u = 1 - t;
      return controls[0].scale(u * u * u) +
          controls[1].scale(3 * u * u * t) +
          controls[2].scale(3 * u * t * t) +
          controls[3].scale(t * t * t);
    });
  }

  static SketchVector _blend(
    SketchVector a,
    SketchVector b,
    double ta,
    double tb,
    double t,
  ) => a.scale((tb - t) / (tb - ta)) + b.scale((t - ta) / (tb - ta));

  static double _distance(SketchVector a, SketchVector b) {
    final d = a - b;
    return math.sqrt(d.dot(d));
  }
}

/// Connects the closest endpoints of two independent lines with a cubic G1
/// Blend. The lines are never trimmed or otherwise modified.
class SketchTangentBlendGeometry {
  const SketchTangentBlendGeometry._();

  static List<SketchVector> betweenLines(
    SketchVector firstStart,
    SketchVector firstEnd,
    SketchVector secondStart,
    SketchVector secondEnd, {
    required double tangentLength,
  }) {
    if (!tangentLength.isFinite || tangentLength <= 0) {
      throw ArgumentError('Tangency length must be positive and finite.');
    }
    final pairs =
        [
          (firstStart, firstEnd, secondStart, secondEnd),
          (firstStart, firstEnd, secondEnd, secondStart),
          (firstEnd, firstStart, secondStart, secondEnd),
          (firstEnd, firstStart, secondEnd, secondStart),
        ]..sort(
          (a, b) => SketchSplineGeometry._distance(
            a.$1,
            a.$3,
          ).compareTo(SketchSplineGeometry._distance(b.$1, b.$3)),
        );
    final chosen = pairs.first;
    final gap = SketchSplineGeometry._distance(chosen.$1, chosen.$3);
    final firstLength = SketchSplineGeometry._distance(chosen.$1, chosen.$2);
    final secondLength = SketchSplineGeometry._distance(chosen.$3, chosen.$4);
    if (gap <= 1e-9 || firstLength <= 1e-9 || secondLength <= 1e-9) {
      throw ArgumentError(
        'Blend needs two distinct, non-degenerate endpoints.',
      );
    }
    final departing = (chosen.$1 - chosen.$2).scale(1 / firstLength);
    final arriving = (chosen.$4 - chosen.$3).scale(1 / secondLength);
    return [
      chosen.$1,
      chosen.$1 + departing.scale(tangentLength),
      chosen.$3 - arriving.scale(tangentLength),
      chosen.$3,
    ];
  }

  /// Builds a G1 Blend from the two endpoints explicitly chosen by the user.
  /// [firstAdjacent] and [secondAdjacent] must be the opposite endpoints of
  /// their respective source lines. This intentionally does not infer the
  /// closest pair: a polyline may expose several valid corners.
  static List<SketchVector> betweenSelectedEndpoints(
    SketchVector firstEndpoint,
    SketchVector firstAdjacent,
    SketchVector secondEndpoint,
    SketchVector secondAdjacent, {
    required double firstTangentLength,
    required double secondTangentLength,
  }) {
    if (!firstTangentLength.isFinite ||
        firstTangentLength <= 0 ||
        !secondTangentLength.isFinite ||
        secondTangentLength <= 0) {
      throw ArgumentError('Tangency lengths must be positive and finite.');
    }
    final gap = SketchSplineGeometry._distance(firstEndpoint, secondEndpoint);
    final firstLength = SketchSplineGeometry._distance(
      firstEndpoint,
      firstAdjacent,
    );
    final secondLength = SketchSplineGeometry._distance(
      secondEndpoint,
      secondAdjacent,
    );
    if (gap <= 1e-9 || firstLength <= 1e-9 || secondLength <= 1e-9) {
      throw ArgumentError(
        'Blend needs two distinct, non-degenerate endpoints.',
      );
    }
    final departing = (firstEndpoint - firstAdjacent).scale(1 / firstLength);
    // P3 - P2 follows the tangent from the selected endpoint toward the
    // remainder of its source line, matching the established Sketch G1 rule.
    final arriving = (secondAdjacent - secondEndpoint).scale(1 / secondLength);
    return [
      firstEndpoint,
      firstEndpoint + departing.scale(firstTangentLength),
      secondEndpoint - arriving.scale(secondTangentLength),
      secondEndpoint,
    ];
  }
}
