import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/core/sketch_assistant/sketch_reconstruction.dart';
import 'package:flcad_mobile/core/sketch_engine/engine/sketch_engine.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/sketch_engine/repository/sketch_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual fit creates a bounded arc from two adjacent section lines', () {
    SketchVector point(double angle) =>
        SketchVector(5 * math.cos(angle), 5 * math.sin(angle));
    final first = SketchLine(point(0), point(.3));
    final second = SketchLine(point(.3), point(.6));

    final fit = const SketchReconstructionEngine().fitSelectedCircular([
      second,
      first,
    ]);

    expect(fit, isNotNull);
    expect(fit!.kind, SketchReconstructionKind.arc);
    expect(fit.entityIds, containsAll([first.id, second.id]));
    expect(fit.radius, closeTo(5, 1e-5));
    expect(fit.endAngle! - fit.startAngle!, closeTo(.6, 1e-5));
    final start = SketchVector(
      fit.center!.x + fit.radius! * math.cos(fit.startAngle!),
      fit.center!.y + fit.radius! * math.sin(fit.startAngle!),
    );
    final end = SketchVector(
      fit.center!.x + fit.radius! * math.cos(fit.endAngle!),
      fit.center!.y + fit.radius! * math.sin(fit.endAngle!),
    );
    expect(
      [start, end].any(
        (value) =>
            (value.x - point(0).x).abs() < 1e-8 &&
            (value.y - point(0).y).abs() < 1e-8,
      ),
      isTrue,
    );
    expect(
      [start, end].any(
        (value) =>
            (value.x - point(.6).x).abs() < 1e-8 &&
            (value.y - point(.6).y).abs() < 1e-8,
      ),
      isTrue,
    );
    expect(fit.startPoint, isNotNull);
    expect(fit.endPoint, isNotNull);
  });

  test('manual fit uses the neighboring lines for C1 tangent endpoints', () {
    SketchVector point(double angle) =>
        SketchVector(5 * math.cos(angle), 5 * math.sin(angle));
    final before = SketchLine(point(-.3), point(0));
    final first = SketchLine(point(0), point(.3));
    final second = SketchLine(point(.3), point(.6));
    final after = SketchLine(point(.6), point(.9));

    final fit = const SketchReconstructionEngine().fitSelectedCircular(
      [first, second],
      context: [before, first, second, after],
    );

    expect(fit, isNotNull);
    expect(fit!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
    final center = fit.center!;
    SketchVector radiusAt(SketchVector point) =>
        SketchVector(point.x - center.x, point.y - center.y);
    double dot(SketchVector a, SketchVector b) => a.x * b.x + a.y * b.y;
    final startRadius = radiusAt(fit.startPoint!);
    final endRadius = radiusAt(fit.endPoint!);
    final beforeDirection = SketchVector(
      point(0).x - point(-.3).x,
      point(0).y - point(-.3).y,
    );
    final afterDirection = SketchVector(
      point(.9).x - point(.6).x,
      point(.9).y - point(.6).y,
    );
    expect(dot(startRadius, beforeDirection).abs(), lessThan(1e-7));
    expect(dot(endRadius, afterDirection).abs(), lessThan(1e-7));
    final startTangent = SketchVector(
      -math.sin(fit.startAngle!),
      math.cos(fit.startAngle!),
    );
    final endTangent = SketchVector(
      -math.sin(fit.endAngle!),
      math.cos(fit.endAngle!),
    );
    double normalizedDot(SketchVector a, SketchVector b) =>
        dot(a, b) / math.sqrt(dot(a, a) * dot(b, b));
    expect(normalizedDot(startTangent, beforeDirection), closeTo(1, 1e-6));
    expect(normalizedDot(endTangent, afterDirection), closeTo(1, 1e-6));
  });

  test('manual fit recognizes an arc then a line as real C1 neighbours', () {
    SketchVector point(double angle) =>
        SketchVector(5 * math.cos(angle), 5 * math.sin(angle));
    SketchVector tangent(double angle) =>
        SketchVector(-math.sin(angle), math.cos(angle));
    final before = SketchArc(const SketchVector(0, 0), 5, -.3, 0);
    final first = SketchLine(point(0), point(.3));
    final second = SketchLine(point(.3), point(.6));
    final after = SketchLine(point(.6), point(.6) + tangent(.6).scale(2));

    final fit = const SketchReconstructionEngine().fitSelectedCircular(
      [first, second],
      context: [before, first, second, after],
    );

    expect(fit, isNotNull);
  });

  test('manual fit recognizes a line then an arc as real C1 neighbours', () {
    SketchVector point(double angle) =>
        SketchVector(5 * math.cos(angle), 5 * math.sin(angle));
    SketchVector tangent(double angle) =>
        SketchVector(-math.sin(angle), math.cos(angle));
    final before = SketchLine(point(0) - tangent(0).scale(2), point(0));
    final first = SketchLine(point(0), point(.3));
    final second = SketchLine(point(.3), point(.6));
    final after = SketchArc(const SketchVector(0, 0), 5, .6, .9);

    final fit = const SketchReconstructionEngine().fitSelectedCircular(
      [first, second],
      context: [before, first, second, after],
    );

    expect(fit, isNotNull);
  });

  test('manual fit honors a clockwise arc at its final endpoint', () {
    SketchVector point(double angle) =>
        SketchVector(5 * math.cos(angle), 5 * math.sin(angle));
    SketchVector tangent(double angle) =>
        SketchVector(-math.sin(angle), math.cos(angle));
    // This arc ends clockwise at point(0), but its analytical derivative at
    // that endpoint still enters the selected CCW replacement tangent.
    final before = SketchArc(
      const SketchVector(10, 0),
      5,
      math.pi + .3,
      math.pi,
    );
    final first = SketchLine(point(0), point(.3));
    final second = SketchLine(point(.3), point(.6));
    final after = SketchLine(point(.6), point(.6) + tangent(.6).scale(2));

    final fit = const SketchReconstructionEngine().fitSelectedCircular(
      [first, second],
      context: [before, first, second, after],
    );

    expect(fit, isNotNull);
  });

  test('manual fit honors a clockwise arc at its initial endpoint', () {
    SketchVector point(double angle) =>
        SketchVector(5 * math.cos(angle), 5 * math.sin(angle));
    SketchVector tangent(double angle) =>
        SketchVector(-math.sin(angle), math.cos(angle));
    final before = SketchLine(point(0) - tangent(0).scale(2), point(0));
    final first = SketchLine(point(0), point(.3));
    final second = SketchLine(point(.3), point(.6));
    final endCenter =
        point(.6) + SketchVector(2 * math.cos(.6), 2 * math.sin(.6));
    final after = SketchArc(endCenter, 2, math.pi + .6, math.pi + .3);

    final fit = const SketchReconstructionEngine().fitSelectedCircular(
      [first, second],
      context: [before, first, second, after],
    );

    expect(fit, isNotNull);
  });

  test('manual fit uses a sampled spline tangent as a real neighbour', () {
    SketchVector point(double angle) =>
        SketchVector(5 * math.cos(angle), 5 * math.sin(angle));
    final before = SketchSpline([point(-.3), point(0)]);
    before.parameters['sampledPoints'] = [
      point(-.3).toJson(),
      point(0).toJson(),
    ];
    final first = SketchLine(point(0), point(.3));
    final second = SketchLine(point(.3), point(.6));
    final after = SketchLine(point(.6), point(.9));

    final fit = const SketchReconstructionEngine().fitSelectedCircular(
      [first, second],
      context: [before, first, second, after],
    );

    expect(fit, isNotNull);
  });

  test(
    'manual fit keeps a continuous chain when bilateral C1 is unavailable',
    () {
      final first = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(1, 1),
      );
      final second = SketchLine(
        const SketchVector(1, 1),
        const SketchVector(2, 0),
      );
      final before = SketchLine(
        const SketchVector(-1, 0),
        const SketchVector(0, 0),
      );
      final after = SketchLine(
        const SketchVector(2, 0),
        const SketchVector(3, 0),
      );

      // The real neighbours cannot both be C1. The external chain endpoints
      // still define a usable geometric arc, which must be promoted with a
      // non-blocking warning instead of leaving the selection without result.
      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        [first, second],
        context: [before, first, second, after],
      );

      expect(fit, isNotNull);
      expect(
        fit!.circularFitQuality,
        SketchCircularFitQuality.geometricFallback,
      );
      expect({fit.startPoint!.x, fit.endPoint!.x}, {0.0, 2.0});
    },
  );

  test('invalid chains are diagnosed without a tangency failure', () {
    final engine = const SketchReconstructionEngine();
    final failure = engine.diagnoseSelectedCircular([
      SketchLine(const SketchVector(0, 0), const SketchVector(1, 0)),
      SketchLine(const SketchVector(4, 0), const SketchVector(5, 0)),
    ]);

    expect(failure, SketchCircularFitFailure.invalidChain);
  });

  test('an ambiguous branch never falls back when the other end is open', () {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 1),
    );
    final second = SketchLine(
      const SketchVector(1, 1),
      const SketchVector(2, 0),
    );
    final branchA = SketchLine(
      const SketchVector(-1, 0),
      const SketchVector(0, 0),
    );
    final branchB = SketchLine(
      const SketchVector(0, -1),
      const SketchVector(0, 0),
    );
    final engine = const SketchReconstructionEngine();

    expect(
      engine.fitSelectedCircular(
        [first, second],
        context: [branchA, branchB, first, second],
      ),
      isNull,
    );
    expect(
      engine.diagnoseSelectedCircular(
        [first, second],
        context: [branchA, branchB, first, second],
      ),
      SketchCircularFitFailure.ambiguousBranch,
    );
  });

  test(
    'manual fit keeps the three point fallback when only one end has a neighbor',
    () {
      final first = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(1, 1),
      );
      final second = SketchLine(
        const SketchVector(1, 1),
        const SketchVector(2, 0),
      );
      final before = SketchLine(
        const SketchVector(-1, 0),
        const SketchVector(0, 0),
      );

      // Only boundary.start continues into another line, so a C1 fit is
      // underdetermined: the pre-existing three point fit must stay available
      // instead of rejecting a chain that used to be reconstructed.
      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        [first, second],
        context: [before, first, second],
      );

      expect(fit, isNotNull);
      expect(fit!.center, isNotNull);
      expect(fit.radius, closeTo(1, 1e-9));
    },
  );

  test('manual fit rejects a continuous chain longer than three segments', () {
    final fit = const SketchReconstructionEngine().fitSelectedCircular([
      SketchLine(const SketchVector(0, 0), const SketchVector(1, 0)),
      SketchLine(const SketchVector(1, 0), const SketchVector(2, 0)),
      SketchLine(const SketchVector(2, 0), const SketchVector(3, 0)),
      SketchLine(const SketchVector(3, 0), const SketchVector(4, 0)),
    ]);

    expect(fit, isNull);
  });

  test('manual fit rejects selected segments that are not one chain', () {
    final fit = const SketchReconstructionEngine().fitSelectedCircular([
      SketchLine(const SketchVector(0, 0), const SketchVector(1, 1)),
      SketchLine(const SketchVector(4, 0), const SketchVector(5, 1)),
    ]);

    expect(fit, isNull);
  });

  test(
    'manual fit rejects nearly straight segments instead of a giant arc',
    () {
      final fit = const SketchReconstructionEngine().fitSelectedCircular([
        SketchLine(const SketchVector(0, 0), const SketchVector(1, 0)),
        SketchLine(const SketchVector(1, 0), const SketchVector(2, .001)),
      ]);
      expect(fit, isNull);
    },
  );

  test('recognizes primitive entities and directional relations', () {
    final engine = SketchEngine(
      repository: SketchRepository(Directory.systemTemp),
    )..createSketch('Recognition');
    final horizontal = engine.addEntity(
      SketchLine(const SketchVector(0, 0), const SketchVector(10, 0)),
    );
    final vertical = engine.addEntity(
      SketchLine(const SketchVector(10, 0), const SketchVector(10, 5)),
    );
    final circle = engine.addEntity(SketchCircle(const SketchVector(2, 2), 1));

    final suggestions = const SketchReconstructionEngine().analyze(
      engine.entities.values,
    );
    expect(
      suggestions.where((item) => item.kind == SketchReconstructionKind.line),
      hasLength(1),
    );
    expect(
      suggestions.where(
        (item) => item.kind == SketchReconstructionKind.perpendicular,
      ),
      hasLength(1),
    );
    expect(
      suggestions.where(
        (item) =>
            item.kind == SketchReconstructionKind.circle &&
            item.entityIds.single == circle.id,
      ),
      hasLength(1),
    );
    expect(horizontal.id, isNotEmpty);
    expect(vertical.id, isNotEmpty);
  });

  test('recognizes a circular best-fit spline as a circle', () {
    final points = [
      for (var index = 0; index < 16; index++)
        SketchVector(
          10 * math.cos(index * 2 * math.pi / 16),
          10 * math.sin(index * 2 * math.pi / 16),
        ),
    ];
    final spline = SketchSpline(points);
    final suggestions = const SketchReconstructionEngine().analyze([spline]);
    final circle = suggestions.where(
      (item) =>
          item.kind == SketchReconstructionKind.circle &&
          item.entityIds.single == spline.id,
    );
    expect(circle, isNotEmpty);
    expect(circle.first.center, isNotNull);
    expect(circle.first.radius, closeTo(10, .1));
  });

  test('recognizes a circular polyline region as a circle', () {
    final points = [
      for (var index = 0; index <= 16; index++)
        SketchVector(
          5 * math.cos(index * 2 * math.pi / 16),
          5 * math.sin(index * 2 * math.pi / 16),
        ),
    ];
    final lines = [
      for (var index = 0; index < points.length - 1; index++)
        SketchLine(points[index], points[index + 1]),
    ];
    final suggestions = const SketchReconstructionEngine().analyze(lines);
    expect(
      suggestions.any((item) => item.kind == SketchReconstructionKind.circle),
      isTrue,
    );
  });

  test('recognizes a straight best-fit spline as a line', () {
    final spline = SketchSpline([
      const SketchVector(0, 0),
      const SketchVector(5, 0),
      const SketchVector(10, 0),
    ]);
    final suggestions = const SketchReconstructionEngine().analyze([spline]);
    expect(
      suggestions.any(
        (item) =>
            item.kind == SketchReconstructionKind.line &&
            item.entityIds.single == spline.id,
      ),
      isTrue,
    );
  });

  group('automatic circular adjustment is C1 at both extremities', () {
    test('two tangent neighbour lines', () {
      const radius = 1.5;
      const a0 = 1.9, a1 = 2.5;
      final chain = _chainOnCircle(radius, a0, a1);
      final before = SketchLine(
        _circlePoint(radius, a0) - _circleTangent(a0).scale(3),
        _circlePoint(radius, a0),
      );
      final after = SketchLine(
        _circlePoint(radius, a1),
        _circlePoint(radius, a1) + _circleTangent(a1).scale(3),
      );

      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        chain,
        context: [..._withNeighbours(chain, before, after)],
      );

      expect(fit, isNotNull);
      expect(fit!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      expect(fit.radius, closeTo(radius, 1e-6));
      expect(fit.center!.x, closeTo(0, 1e-6));
      expect(fit.center!.y, closeTo(0, 1e-6));
      _expectPreservedEndpoints(fit, radius, a0, a1);
      // Endpoint coincidence alone is not enough: the tangent direction must
      // also match the neighbour at both extremities.
      _expectTangentDirections(fit, a0, a1);
    });

    test('two neighbour lines with a known radius', () {
      const radius = 12.5;
      const a0 = 0.7, a1 = 1.2;
      final chain = _chainOnCircle(radius, a0, a1);
      final before = SketchLine(
        _circlePoint(radius, a0) - _circleTangent(a0).scale(4),
        _circlePoint(radius, a0),
      );
      final after = SketchLine(
        _circlePoint(radius, a1),
        _circlePoint(radius, a1) + _circleTangent(a1).scale(4),
      );

      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        chain,
        context: [..._withNeighbours(chain, before, after)],
      );

      expect(fit, isNotNull);
      expect(fit!.radius, closeTo(radius, 1e-6));
      expect(fit.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      _expectPreservedEndpoints(fit, radius, a0, a1);
    });

    test('automatic arc matches the manual 1,5 mm radius', () {
      const radius = 1.5;
      const a0 = 0.2, a1 = 1.4;
      final chain = _chainOnCircle(radius, a0, a1);
      final before = SketchLine(
        _circlePoint(radius, a0) - _circleTangent(a0).scale(2),
        _circlePoint(radius, a0),
      );
      final after = SketchLine(
        _circlePoint(radius, a1),
        _circlePoint(radius, a1) + _circleTangent(a1).scale(2),
      );

      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        chain,
        context: [..._withNeighbours(chain, before, after)],
      );

      // The manual reference is a 1.5 mm fillet; the automatic centre/radius
      // must reproduce it instead of a three point chord approximation.
      expect(fit, isNotNull);
      expect(fit!.radius, closeTo(1.5, 1e-6));
      expect(fit.center!.x, closeTo(0, 1e-6));
      expect(fit.center!.y, closeTo(0, 1e-6));
      // Both extremities must lie on the manual 1.5 mm fillet circle.
      for (final point in <SketchVector>[fit.startPoint!, fit.endPoint!]) {
        expect(_distance(point, fit.center!), closeTo(1.5, 1e-6));
      }
    });

    test('arc neighbour supplies its analytical tangent', () {
      const radius = 2.0;
      const a0 = 1.1, a1 = 1.75;
      final chain = _chainOnCircle(radius, a0, a1);
      final before = SketchArc(const SketchVector(0, 0), radius, a0 - 0.4, a0);
      final after = SketchArc(const SketchVector(0, 0), radius, a1, a1 + 0.4);

      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        chain,
        context: [..._withNeighbours(chain, before, after)],
      );

      expect(fit, isNotNull);
      expect(fit!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      expect(fit.radius, closeTo(radius, 1e-6));
      _expectPreservedEndpoints(fit, radius, a0, a1);
      _expectTangentDirections(fit, a0, a1);
    });

    test('spline neighbour supplies its oriented sampled tangent', () {
      const radius = 3.0;
      const a0 = 0.6, a1 = 1.3;
      final chain = _chainOnCircle(radius, a0, a1);
      final p0 = _circlePoint(radius, a0);
      final p1 = _circlePoint(radius, a1);
      final before = SketchSpline([p0 - _circleTangent(a0).scale(0.4), p0]);
      before.parameters['sampledPoints'] = [
        (p0 - _circleTangent(a0).scale(0.4)).toJson(),
        p0.toJson(),
      ];
      final after = SketchSpline([p1, p1 + _circleTangent(a1).scale(0.4)]);
      after.parameters['sampledPoints'] = [
        p1.toJson(),
        (p1 + _circleTangent(a1).scale(0.4)).toJson(),
      ];

      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        chain,
        context: [..._withNeighbours(chain, before, after)],
      );

      expect(fit, isNotNull);
      expect(fit!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      expect(fit.radius, closeTo(radius, 1e-6));
      _expectPreservedEndpoints(fit, radius, a0, a1);
    });

    test('clockwise neighbour arc keeps the C1 continuation', () {
      SketchVector point(double angle) =>
          SketchVector(5 * math.cos(angle), 5 * math.sin(angle));
      SketchVector tangent(double angle) =>
          SketchVector(-math.sin(angle), math.cos(angle));
      // Ends clockwise at point(0); its analytical derivative still enters the
      // counter-clockwise replacement tangent.
      final before = SketchArc(
        const SketchVector(10, 0),
        5,
        math.pi + .3,
        math.pi,
      );
      final first = SketchLine(point(0), point(.3));
      final second = SketchLine(point(.3), point(.6));
      final after = SketchLine(point(.6), point(.6) + tangent(.6).scale(2));

      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        [first, second],
        context: [before, first, second, after],
      );

      expect(fit, isNotNull);
      expect(fit!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      expect(fit.radius, closeTo(5, 1e-5));
    });

    test('incompatible neighbours are rejected with a diagnostic', () {
      final first = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(1, 0.0004),
      );
      final second = SketchLine(
        const SketchVector(1, 0.0004),
        const SketchVector(2, 0),
      );
      // Parallel neighbour lines cannot bound a tangent circle; the chain is
      // also too straight for the three point fallback.
      final before = SketchLine(
        const SketchVector(-1, 0),
        const SketchVector(0, 0),
      );
      final after = SketchLine(
        const SketchVector(2, 0),
        const SketchVector(3, 0),
      );
      final context = [before, first, second, after];
      final engine = const SketchReconstructionEngine();

      expect(
        engine.diagnoseSelectedCircular([first, second], context: context),
        SketchCircularFitFailure.incompatibleTangency,
      );
      final fit = engine.fitSelectedCircular([first, second], context: context);
      expect(fit, isNull);
    });

    test('chord neighbours stay C1 with preserved endpoints', () {
      // Regression: a Section polyline replaces the real curve with chords, so
      // the neighbour directions are only approximately tangent.  The automatic
      // arc must still be bilateral C1 and must not drift into the three point
      // fallback that produced the visible break at both extremities.
      const radius = 1.5;
      const stepDeg = 5.0;
      final step = stepDeg * math.pi / 180;
      final angles = <double>[-step, 0];
      for (final factor in <double>[0.95, 1.05, 1.0]) {
        angles.add(angles.last + factor * step);
      }
      angles.add(angles.last + 0.5 * step);
      final vertices = [
        for (final angle in angles) _circlePoint(radius, angle),
      ];
      final lines = <SketchLine>[
        for (var i = 0; i + 1 < vertices.length; i++)
          SketchLine(vertices[i], vertices[i + 1]),
      ];
      final selected = [lines[1], lines[2], lines[3]];
      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        selected,
        context: lines,
      );

      expect(fit, isNotNull);
      expect(fit!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      expect(_distance(fit.startPoint!, vertices[1]), lessThan(1e-9));
      expect(_distance(fit.endPoint!, vertices[4]), lessThan(1e-9));
      // The neighbour chords are not exactly tangent, so a small residual is
      // expected.  It is balanced between the two extremities and must stay
      // well inside the accepted 1 deg C1 budget, far from the visible break
      // the three point fallback produced.
      final residuals = <double>[];
      for (final endpoint in <(SketchVector, SketchVector)>[
        (fit.startPoint!, vertices[0] - vertices[1]),
        (fit.endPoint!, vertices[5] - vertices[4]),
      ]) {
        final radiusVector = endpoint.$1 - fit.center!;
        final sine =
            (radiusVector.dot(endpoint.$2) /
                    (_norm(radiusVector) * _norm(endpoint.$2)))
                .abs();
        residuals.add(math.asin(sine.clamp(0.0, 1.0)) * 180 / math.pi);
      }
      expect(residuals.every((value) => value < 0.8), isTrue);
      // Neither junction carries the whole break.
      expect((residuals.first - residuals.last).abs(), lessThan(0.35));
    });
  });

  group('manual tangency references', () {
    test('two named lines drive the C1 solution', () {
      final scene = _manualScene();
      final engine = const SketchReconstructionEngine();

      // Without a reference the extra curve on the start endpoint is a branch,
      // which is exactly why the automatic Section inference is unreliable.
      expect(
        engine.fitSelectedCircular(scene.chain, context: scene.context),
        isNull,
      );
      expect(
        engine.diagnoseSelectedCircular(scene.chain, context: scene.context),
        SketchCircularFitFailure.ambiguousBranch,
      );

      final fit = engine.fitSelectedCircular(
        scene.chain,
        context: scene.context,
        startTangencyId: scene.startReference.id,
        endTangencyId: scene.endReference.id,
      );

      expect(fit, isNotNull);
      expect(fit!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      expect(fit.radius, closeTo(scene.radius, 1e-6));
      _expectPreservedEndpoints(fit, scene.radius, scene.a0, scene.a1);
      _expectTangentDirections(fit, scene.a0, scene.a1);
      expect(_c1ResidualDegrees(fit, scene), lessThan(0.5));
    });

    test('arc reference supplies its analytical tangent', () {
      final scene = _manualScene();
      final arc = SketchArc(
        const SketchVector(0, 0),
        scene.radius,
        scene.a0 - 0.4,
        scene.a0,
      );
      final context = [
        arc,
        scene.startReference,
        ...scene.chain,
        scene.endReference,
      ];

      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        scene.chain,
        context: context,
        startTangencyId: arc.id,
        endTangencyId: scene.endReference.id,
      );

      expect(fit, isNotNull);
      expect(fit!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      expect(fit.radius, closeTo(scene.radius, 1e-6));
      _expectPreservedEndpoints(fit, scene.radius, scene.a0, scene.a1);
      _expectTangentDirections(fit, scene.a0, scene.a1);
    });

    test('spline reference supplies its oriented sampled tangent', () {
      final scene = _manualScene();
      final p0 = _circlePoint(scene.radius, scene.a0);
      final spline = SketchSpline([
        p0 - _circleTangent(scene.a0).scale(0.5),
        p0,
      ]);
      spline.parameters['sampledPoints'] = [
        (p0 - _circleTangent(scene.a0).scale(0.5)).toJson(),
        p0.toJson(),
      ];
      final context = [
        spline,
        scene.startReference,
        ...scene.chain,
        scene.endReference,
      ];

      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        scene.chain,
        context: context,
        startTangencyId: spline.id,
        endTangencyId: scene.endReference.id,
      );

      expect(fit, isNotNull);
      expect(fit!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      expect(fit.radius, closeTo(scene.radius, 1e-6));
      _expectPreservedEndpoints(fit, scene.radius, scene.a0, scene.a1);
    });

    test('a disconnected reference is rejected', () {
      final scene = _manualScene();
      final stray = SketchLine(
        const SketchVector(80, 80),
        const SketchVector(82, 80),
      );
      final context = [stray, ...scene.context];
      final engine = const SketchReconstructionEngine();

      expect(
        engine.fitSelectedCircular(
          scene.chain,
          context: context,
          startTangencyId: stray.id,
          endTangencyId: scene.endReference.id,
        ),
        isNull,
      );
      expect(
        engine.diagnoseSelectedCircular(
          scene.chain,
          context: context,
          startTangencyId: stray.id,
          endTangencyId: scene.endReference.id,
        ),
        SketchCircularFitFailure.disconnectedTangency,
      );
    });

    test('a reference attached to the wrong side is rejected as reversed', () {
      final scene = _manualScene();
      final p0 = _circlePoint(scene.radius, scene.a0);
      // Attached to the start endpoint but running forward, the same way the
      // chain goes: the reference would force the arc to double back.
      final reversed = SketchLine(p0, p0 + _circleTangent(scene.a0).scale(3));
      final context = [
        reversed,
        scene.startReference,
        ...scene.chain,
        scene.endReference,
      ];
      final engine = const SketchReconstructionEngine();

      expect(
        engine.fitSelectedCircular(
          scene.chain,
          context: context,
          startTangencyId: reversed.id,
          endTangencyId: scene.endReference.id,
        ),
        isNull,
      );
      expect(
        engine.diagnoseSelectedCircular(
          scene.chain,
          context: context,
          startTangencyId: reversed.id,
          endTangencyId: scene.endReference.id,
        ),
        SketchCircularFitFailure.reversedTangency,
      );
    });

    test('a chain curve cannot double as a tangency reference', () {
      final scene = _manualScene();
      final engine = const SketchReconstructionEngine();

      expect(
        engine.fitSelectedCircular(
          scene.chain,
          context: scene.context,
          startTangencyId: scene.chain.first.id,
          endTangencyId: scene.endReference.id,
        ),
        isNull,
      );
      expect(
        engine.diagnoseSelectedCircular(
          scene.chain,
          context: scene.context,
          startTangencyId: scene.chain.first.id,
          endTangencyId: scene.endReference.id,
        ),
        SketchCircularFitFailure.disconnectedTangency,
      );
    });

    test('no references keeps the automatic behaviour identical', () {
      final scene = _manualScene();
      final context = [
        scene.startReference,
        ...scene.chain,
        scene.endReference,
      ];
      final engine = const SketchReconstructionEngine();

      final automatic = engine.fitSelectedCircular(
        scene.chain,
        context: context,
      );
      final named = engine.fitSelectedCircular(
        scene.chain,
        context: context,
        startTangencyId: scene.startReference.id,
        endTangencyId: scene.endReference.id,
      );

      // Naming the very curves the inference would pick is a no-op.
      expect(automatic, isNotNull);
      expect(named, isNotNull);
      expect(automatic!.circularFitQuality, named!.circularFitQuality);
      expect(named.radius, closeTo(automatic.radius!, 1e-9));
      expect(named.center!.x, closeTo(automatic.center!.x, 1e-9));
      expect(named.center!.y, closeTo(automatic.center!.y, 1e-9));
    });

    test('a shallow chain rejects the manual pair instead of falling back', () {
      // Span below the 0.2 rad arc gate: the three point fallback could still
      // build a circle here, but an explicit pair of references is a strict
      // contract and must never be downgraded to that arc.
      const radius = 10.0;
      const a0 = 0.5;
      final span = 11 * math.pi / 180;
      final chain = _chainOnCircle(radius, a0, a0 + span);
      final p0 = _circlePoint(radius, a0);
      final p1 = _circlePoint(radius, a0 + span);
      final startReference = SketchLine(p0 - _circleTangent(a0).scale(2), p0);
      final endReference = SketchLine(
        p1,
        p1 + _circleTangent(a0 + span).scale(2),
      );
      final context = [startReference, ...chain, endReference];
      final engine = const SketchReconstructionEngine();

      expect(
        engine.fitSelectedCircular(
          chain,
          context: context,
          startTangencyId: startReference.id,
          endTangencyId: endReference.id,
        ),
        isNull,
      );
      expect(
        engine.diagnoseSelectedCircular(
          chain,
          context: context,
          startTangencyId: startReference.id,
          endTangencyId: endReference.id,
        ),
        SketchCircularFitFailure.incompatibleTangency,
      );
    });

    test('a clockwise chain keeps C1 with two named references', () {
      // Concave profile: the chain is walked clockwise about the fitted centre.
      const radius = 4.0;
      const aStart = 1.6;
      const aEnd = 1.0;
      final chain = _chainOnCircle(radius, aStart, aEnd);
      final pStart = _circlePoint(radius, aStart);
      final pEnd = _circlePoint(radius, aEnd);
      // True tangent lines: the previous neighbour runs forward for a
      // clockwise walk, so its outward direction is +tangent at the start.
      final startReference = SketchLine(
        pStart,
        pStart + _circleTangent(aStart).scale(3),
      );
      final endReference = SketchLine(
        pEnd,
        pEnd - _circleTangent(aEnd).scale(3),
      );
      final context = [startReference, ...chain, endReference];
      final engine = const SketchReconstructionEngine();

      final manual = engine.fitSelectedCircular(
        chain,
        context: context,
        startTangencyId: startReference.id,
        endTangencyId: endReference.id,
      );
      expect(manual, isNotNull);
      expect(manual!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      expect(manual.radius, closeTo(radius, 1e-6));
      final endpoints = [manual.startPoint!, manual.endPoint!];
      expect(endpoints.any((point) => _distance(point, pStart) < 1e-9), isTrue);
      expect(endpoints.any((point) => _distance(point, pEnd) < 1e-9), isTrue);

      // The same geometry now resolves automatically as well: the traversal
      // sense comes from the chain, not from an assumed counter-clockwise arc.
      final automatic = engine.fitSelectedCircular(chain, context: context);
      expect(automatic, isNotNull);
      expect(
        automatic!.circularFitQuality,
        SketchCircularFitQuality.c1Bilateral,
      );
      expect(automatic.radius, closeTo(radius, 1e-6));
    });
  });
}

SketchVector _circlePoint(double radius, double angle) =>
    SketchVector(radius * math.cos(angle), radius * math.sin(angle));

SketchVector _circleTangent(double angle) =>
    SketchVector(-math.sin(angle), math.cos(angle));

/// Two chord chain on a circle plus a correct tangency curve at each endpoint.
///
/// A decoy curve is attached to the start endpoint on purpose, so the automatic
/// inference sees a branch while an explicit reference resolves it.
class _ManualScene {
  _ManualScene({
    required this.radius,
    required this.a0,
    required this.a1,
    required this.chain,
    required this.startReference,
    required this.endReference,
    required this.decoy,
  });

  final double radius;
  final double a0;
  final double a1;
  final List<SketchLine> chain;
  final SketchLine startReference;
  final SketchLine endReference;
  final SketchLine decoy;

  List<SketchEntity> get context => [
    decoy,
    startReference,
    ...chain,
    endReference,
  ];
}

_ManualScene _manualScene() {
  const radius = 4.0;
  const a0 = 1.0;
  const a1 = 1.6;
  final chain = _chainOnCircle(radius, a0, a1);
  final p0 = _circlePoint(radius, a0);
  final p1 = _circlePoint(radius, a1);
  return _ManualScene(
    radius: radius,
    a0: a0,
    a1: a1,
    chain: chain,
    startReference: SketchLine(p0 - _circleTangent(a0).scale(3), p0),
    endReference: SketchLine(p1, p1 + _circleTangent(a1).scale(3)),
    // Radial decoy: attached to the start endpoint but not tangent.
    decoy: SketchLine(
      p0,
      p0 + SketchVector(math.cos(a0), math.sin(a0)).scale(2),
    ),
  );
}

double _c1ResidualDegrees(
  SketchReconstructionSuggestion fit,
  _ManualScene scene,
) {
  final neighbourStart = _circleTangent(scene.a0);
  final neighbourEnd = _circleTangent(scene.a1);
  double residual(SketchVector point, SketchVector direction) {
    final radiusVector = point - fit.center!;
    final sine =
        (radiusVector.dot(direction) / (_norm(radiusVector) * _norm(direction)))
            .abs();
    return math.asin(sine.clamp(0.0, 1.0)) * 180 / math.pi;
  }

  return math.max(
    residual(fit.startPoint!, neighbourStart),
    residual(fit.endPoint!, neighbourEnd),
  );
}

double _distance(SketchVector first, SketchVector second) {
  final dx = first.x - second.x, dy = first.y - second.y;
  return math.sqrt(dx * dx + dy * dy);
}

double _norm(SketchVector value) => math.sqrt(value.dot(value));

/// Two adjacent chords of the circle through (radius, a0..a1).
List<SketchLine> _chainOnCircle(double radius, double a0, double a1) => [
  SketchLine(_circlePoint(radius, a0), _circlePoint(radius, (a0 + a1) / 2)),
  SketchLine(_circlePoint(radius, (a0 + a1) / 2), _circlePoint(radius, a1)),
];

Iterable<SketchEntity> _withNeighbours(
  List<SketchLine> chain,
  SketchEntity before,
  SketchEntity after,
) => [before, ...chain, after];

void _expectPreservedEndpoints(
  SketchReconstructionSuggestion fit,
  double radius,
  double a0,
  double a1,
) {
  expect(fit.startPoint, isNotNull);
  expect(fit.endPoint, isNotNull);
  final expected = {_circlePoint(radius, a0), _circlePoint(radius, a1)};
  expect(
    expected.any((point) => _distance(point, fit.startPoint!) < 1e-9),
    isTrue,
  );
  expect(
    expected.any((point) => _distance(point, fit.endPoint!) < 1e-9),
    isTrue,
  );
}

void _expectTangentDirections(
  SketchReconstructionSuggestion fit,
  double a0,
  double a1,
) {
  final center = fit.center!;
  final startRadius = fit.startPoint! - center;
  final endRadius = fit.endPoint! - center;
  expect(startRadius.dot(_circleTangent(a0)).abs(), lessThan(1e-5));
  expect(endRadius.dot(_circleTangent(a1)).abs(), lessThan(1e-5));
  final startTangent = SketchVector(
    -math.sin(fit.startAngle!),
    math.cos(fit.startAngle!),
  );
  final endTangent = SketchVector(
    -math.sin(fit.endAngle!),
    math.cos(fit.endAngle!),
  );
  expect(
    startTangent.dot(_circleTangent(a0)) / _norm(startTangent),
    closeTo(1, 1e-5),
  );
  expect(
    endTangent.dot(_circleTangent(a1)) / _norm(endTangent),
    closeTo(1, 1e-5),
  );
}
