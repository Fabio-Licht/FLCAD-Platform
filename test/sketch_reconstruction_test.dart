import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/core/sketch_assistant/sketch_reconstruction.dart';
import 'package:flcad_mobile/core/sketch_engine/engine/sketch_engine.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/sketch_engine/repository/sketch_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('line and spline region fit', () {
    test('uses 2, 5 and 10 unordered fragments with large gaps', () {
      final engine = const SketchReconstructionEngine();
      for (final count in [2, 5, 10]) {
        for (final gap in [1.0, 5.0, 20.0]) {
          final fragments = <SketchLine>[
            for (var i = 0; i < count; i++)
              SketchLine(
                SketchVector(i * (5 + gap), i.isEven ? .05 : -.05),
                SketchVector(i * (5 + gap) + 5, i.isEven ? -.05 : .05),
              ),
          ];
          final fit = engine.fitSelectedLineOrSpline(fragments.reversed);
          expect(fit, isNotNull);
          expect(fit!.usedEntityIds, hasLength(count));
          expect(fit.maxGapMillimeters, closeTo(gap, .01));
          expect(fit.rmsError, lessThan(.1));
          // The chain may be oriented in either direction, but the two real
          // outer endpoints are projected onto the PCA line.
          final span = (count - 1) * (5 + gap) + 5;
          expect({fit.start.x, fit.end.x}.reduce(math.min), closeTo(0.0, 1e-3));
          expect(
            {fit.start.x, fit.end.x}.reduce(math.max),
            closeTo(span, 1e-3),
          );
          expect(fit.start.y.abs(), lessThan(0.02));
          expect(fit.end.y.abs(), lessThan(0.02));
        }
      }
    });

    test(
      'line endpoints lie on the PCA axis between the projected chain ends',
      () {
        final first = SketchLine(
          const SketchVector(0, 1),
          const SketchVector(10, 1),
        );
        final second = SketchLine(
          const SketchVector(12, -1),
          const SketchVector(22, -1),
        );
        final fit = const SketchReconstructionEngine().fitSelectedLineOrSpline([
          second,
          first,
        ]);
        expect(fit, isNotNull);

        const chainStart = SketchVector(0, 1);
        const chainEnd = SketchVector(22, -1);
        final samples = <SketchVector>[
          chainStart,
          const SketchVector(10, 1),
          const SketchVector(12, -1),
          chainEnd,
        ];
        final mean = samples
            .fold(const SketchVector(0, 0), (sum, point) => sum + point)
            .scale(1 / samples.length);
        var xx = 0.0, xy = 0.0, yy = 0.0;
        for (final point in samples) {
          final delta = point - mean;
          xx += delta.x * delta.x;
          xy += delta.x * delta.y;
          yy += delta.y * delta.y;
        }
        final angle = .5 * math.atan2(2 * xy, xx - yy);
        var direction = SketchVector(math.cos(angle), math.sin(angle));
        if ((chainEnd - chainStart).dot(direction) < 0) {
          direction = direction.scale(-1);
        }
        SketchVector project(SketchVector point) =>
            mean + direction.scale((point - mean).dot(direction));
        double cross(SketchVector point) {
          final delta = point - mean;
          return (delta.x * direction.y - delta.y * direction.x).abs();
        }

        final expectedStart = project(chainStart);
        final expectedEnd = project(chainEnd);
        expect(cross(fit!.start), lessThan(1e-9));
        expect(cross(fit.end), lessThan(1e-9));
        final lineDirection = fit.end - fit.start;
        expect(
          (lineDirection.x * direction.y - lineDirection.y * direction.x).abs(),
          lessThan(1e-9),
        );
        expect(
          (_distance(fit.start, expectedStart) < 1e-9 &&
                  _distance(fit.end, expectedEnd) < 1e-9) ||
              (_distance(fit.start, expectedEnd) < 1e-9 &&
                  _distance(fit.end, expectedStart) < 1e-9),
          isTrue,
        );
        expect(_distance(fit.start, chainStart), greaterThan(1e-6));
        expect(_distance(fit.end, chainEnd), greaterThan(1e-6));

        double param(SketchVector point) => (point - mean).dot(direction);
        final fittedParams = [param(fit.start), param(fit.end)]..sort();
        final expectedParams = [param(expectedStart), param(expectedEnd)]
          ..sort();
        expect(fittedParams[0], closeTo(expectedParams[0], 1e-9));
        expect(fittedParams[1], closeTo(expectedParams[1], 1e-9));

        var squared = 0.0, maximum = 0.0;
        for (final point in fit.referencePoints) {
          final error = cross(point);
          squared += error * error;
          maximum = math.max(maximum, error);
        }
        expect(
          fit.rmsError,
          closeTo(math.sqrt(squared / fit.referencePoints.length), 1e-12),
        );
        expect(fit.maxError, closeTo(maximum, 1e-12));
        expect(
          fit.points.any(
            (point) => (point.x - 0).abs() < 1e-9 && (point.y - 1).abs() < 1e-9,
          ),
          isTrue,
        );
        expect(
          fit.points.any(
            (point) =>
                (point.x - 22).abs() < 1e-9 && (point.y + 1).abs() < 1e-9,
          ),
          isTrue,
        );
      },
    );

    test(
      'preserves spline form and rejects insufficient or degenerate input',
      () {
        final spline = SketchSpline(const [
          SketchVector(0, 0),
          SketchVector(1, 1),
          SketchVector(2, 0),
        ]);
        final arc = SketchArc(
          const SketchVector(12, 0),
          2,
          math.pi,
          1.5 * math.pi,
        );
        final fit = const SketchReconstructionEngine().fitSelectedLineOrSpline([
          spline,
          arc,
        ]);
        expect(fit, isNotNull);
        // A spline contributes its stable interpolated samples, not just its
        // original control polygon; neither endpoint may be discarded.
        expect(fit!.points.length, greaterThanOrEqualTo(3));
        expect(
          fit.points.where(
            (point) => point.x.abs() < 1e-9 && point.y.abs() < 1e-9,
          ),
          isNotEmpty,
        );
        expect(
          fit.points.where(
            (point) => (point.x - 2).abs() < 1e-9 && point.y.abs() < 1e-9,
          ),
          isNotEmpty,
        );
        expect(fit.usedEntityIds, containsAll([spline.id, arc.id]));
        expect(
          const SketchReconstructionEngine().fitSelectedLineOrSpline([
            SketchLine(const SketchVector(1, 1), const SketchVector(1, 1)),
          ]),
          isNull,
        );
      },
    );

    test('rejects non-finite samples before PCA or spline creation', () {
      final diagnosis = const SketchReconstructionEngine()
          .diagnoseSelectedLineOrSpline([
            SketchLine(SketchVector(double.nan, 0), const SketchVector(1, 0)),
          ]);
      expect(diagnosis.result, isNull);
      expect(diagnosis.failure, SketchRegionFitFailure.invalidSamples);
    });

    test('limits dense spline knots while retaining endpoints and turns', () {
      final source = SketchSpline([
        for (var index = 0; index < 24; index++)
          SketchVector(index.toDouble(), index.isEven ? 0 : .5),
      ]);
      final fit = const SketchReconstructionEngine().fitSelectedLineOrSpline([
        source,
      ]);
      expect(fit, isNotNull);
      expect(
        fit!.points.length,
        lessThanOrEqualTo(SketchRegionFitResult.maxSplineKnots),
      );
      expect(fit.points.first.x, closeTo(0, 1e-9));
      expect(fit.points.last.x, closeTo(23, 1e-9));
      expect(
        fit.points.every((point) => point.x.isFinite && point.y.isFinite),
        isTrue,
      );
    });

    test('a large gap stays stable without spline overshoot', () {
      final fit = const SketchReconstructionEngine().fitSelectedLineOrSpline([
        SketchLine(const SketchVector(100, 0), const SketchVector(102, 0)),
        SketchLine(const SketchVector(0, 0), const SketchVector(2, 0)),
      ]);
      expect(fit, isNotNull);
      final spline = SketchSpline(fit!.points);
      final samples = (spline.parameters['sampledPoints'] as List)
          .whereType<List>()
          .map(SketchVector.fromJson);
      expect(samples.every((point) => point.y.abs() < 1e-9), isTrue);
      expect(
        samples.every((point) => point.x >= -1e-9 && point.x <= 102 + 1e-9),
        isTrue,
      );
      expect({fit.start.x, fit.end.x}, {0.0, 102.0});
    });
  });

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

  test('manual fit follows the selected samples, not the chord neighbours', () {
    // Chord neighbours of a Section are not reliable tangents, so the
    // automatic path fits the sample cloud and keeps both external endpoints;
    // the neighbours only label the continuity (see the manual tangency
    // group for the explicit C1 contract).
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
    expect(fit!.radius, closeTo(5, 1e-6));
    expect(fit.center!.x, closeTo(0, 1e-6));
    expect(fit.center!.y, closeTo(0, 1e-6));
    expect(_distance(fit.startPoint!, point(0)), lessThan(1e-9));
    expect(_distance(fit.endPoint!, point(.6)), lessThan(1e-9));
    // The chord neighbours are not tangent to the point fit, and that is
    // reported as a warning instead of rejecting the arc.
    expect(fit.circularFitQuality, SketchCircularFitQuality.geometricFallback);
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

  test('regions far apart still take part in the global fit', () {
    // Two arcs of the same circle separated by a big gap must be accepted:
    // the gap is only reported, never a rejection.
    const radius = 10.0;
    final chain = <SketchEntity>[
      SketchLine(_circlePoint(radius, 0.2), _circlePoint(radius, 0.4)),
      SketchLine(_circlePoint(radius, 1.2), _circlePoint(radius, 1.4)),
    ];
    final fit = const SketchReconstructionEngine().fitSelectedCircular(chain);

    expect(fit, isNotNull);
    expect(fit!.radius, closeTo(radius, 0.05));
    expect(fit.warnings.any((warning) => warning.contains('gap')), isTrue);
    expect(fit.maxGapMillimeters, greaterThan(1));
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
      hasLength(2),
    );
    expect(
      suggestions.any(
        (item) =>
            item.kind == SketchReconstructionKind.line &&
            item.entityIds.toSet().containsAll([horizontal.id, vertical.id]) &&
            item.confidence == 1.0,
      ),
      isFalse,
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

  test('automatic segmentation keeps collinear chains and splits corners', () {
    final collinear = [
      for (var index = 0; index < 5; index++)
        SketchLine(
          SketchVector(index * 10.0, 0),
          SketchVector((index + 1) * 10.0, 0),
        ),
    ];
    final collinearSuggestions = const SketchReconstructionEngine().analyze(
      collinear,
    );
    expect(
      collinearSuggestions.any(
        (item) =>
            item.kind == SketchReconstructionKind.line &&
            item.entityIds.toSet().length == 5 &&
            item.entityIds.toSet().containsAll(
              collinear.map((line) => line.id),
            ),
      ),
      isTrue,
    );

    final lShape = [
      SketchLine(const SketchVector(0, 0), const SketchVector(10, 0)),
      SketchLine(const SketchVector(10, 0), const SketchVector(20, 0)),
      SketchLine(const SketchVector(20, 0), const SketchVector(20, 10)),
      SketchLine(const SketchVector(20, 10), const SketchVector(20, 20)),
    ];
    final lSuggestions = const SketchReconstructionEngine().analyze(lShape);
    expect(
      lSuggestions.any(
        (item) =>
            item.kind == SketchReconstructionKind.line &&
            item.entityIds.toSet().containsAll(lShape.map((line) => line.id)) &&
            item.confidence == 1.0,
      ),
      isFalse,
    );
    expect(
      lSuggestions.where((item) => item.kind == SketchReconstructionKind.line),
      hasLength(2),
    );
  });

  test('automatic segmentation rejects U and S chains as one line', () {
    final uShape = [
      SketchLine(const SketchVector(0, 0), const SketchVector(0, 10)),
      SketchLine(const SketchVector(0, 10), const SketchVector(0, 20)),
      SketchLine(const SketchVector(0, 20), const SketchVector(10, 20)),
      SketchLine(const SketchVector(10, 20), const SketchVector(20, 20)),
      SketchLine(const SketchVector(20, 20), const SketchVector(20, 10)),
      SketchLine(const SketchVector(20, 10), const SketchVector(20, 0)),
    ];
    final sPoints = [
      for (var index = 0; index <= 12; index++)
        SketchVector(index * 2.0, math.sin(index * math.pi / 6) * 5),
    ];
    final sShape = [
      for (var index = 0; index + 1 < sPoints.length; index++)
        SketchLine(sPoints[index], sPoints[index + 1]),
    ];
    for (final shape in [uShape, sShape]) {
      final suggestions = const SketchReconstructionEngine().analyze(shape);
      expect(
        suggestions.any(
          (item) =>
              item.kind == SketchReconstructionKind.line &&
              item.entityIds.toSet().containsAll(
                shape.map((line) => line.id),
              ) &&
              item.confidence == 1.0,
        ),
        isFalse,
      );
    }
  });

  test('automatic segmentation keeps constant curvature as one arc region', () {
    final points = [
      for (var index = 0; index <= 8; index++)
        SketchVector(
          20 * math.cos(index * math.pi / 16),
          20 * math.sin(index * math.pi / 16),
        ),
    ];
    final arcFragments = [
      for (var index = 0; index + 1 < points.length; index++)
        SketchLine(points[index], points[index + 1]),
    ];
    final suggestions = const SketchReconstructionEngine().analyze(
      arcFragments,
    );
    expect(
      suggestions.any(
        (item) =>
            item.kind == SketchReconstructionKind.arc &&
            item.entityIds.toSet().length == arcFragments.length,
      ),
      isTrue,
    );
  });

  test(
    'automatic segmentation separates tangent line arc and line regions',
    () {
      final arcPoints = [
        for (var index = 0; index <= 6; index++)
          SketchVector(
            20 * math.cos(-math.pi / 2 + index * math.pi / 12),
            20 + 20 * math.sin(-math.pi / 2 + index * math.pi / 12),
          ),
      ];
      final mixed = <SketchLine>[
        SketchLine(const SketchVector(-20, 0), arcPoints.first),
        for (var index = 0; index + 1 < arcPoints.length; index++)
          SketchLine(arcPoints[index], arcPoints[index + 1]),
        SketchLine(arcPoints.last, const SketchVector(40, 20)),
      ];
      final suggestions = const SketchReconstructionEngine().analyze(mixed);
      expect(
        suggestions.any(
          (item) =>
              item.kind == SketchReconstructionKind.arc &&
              item.entityIds.toSet().length == arcPoints.length - 1,
        ),
        isTrue,
      );
      expect(
        suggestions.any(
          (item) =>
              item.kind == SketchReconstructionKind.line &&
              item.entityIds.toSet().containsAll(mixed.map((line) => line.id)),
        ),
        isFalse,
      );
    },
  );

  test(
    'automatic segmentation is deterministic and rejects a near-line arc',
    () {
      final chain = [
        SketchLine(const SketchVector(20, 0), const SketchVector(10, 0)),
        SketchLine(const SketchVector(0, 0), const SketchVector(10, 0)),
        SketchLine(const SketchVector(20, 0), const SketchVector(30, 0.001)),
        SketchLine(const SketchVector(10, 0), const SketchVector(20, 0)),
      ];
      final engine = const SketchReconstructionEngine();
      final forward = engine.analyze(chain);
      final reversed = engine.analyze(chain.reversed);
      String signature(Iterable<SketchReconstructionSuggestion> suggestions) =>
          suggestions
              .map((item) => '${item.kind}:${item.entityIds.join(',')}')
              .join('|');
      expect(signature(forward), signature(reversed));
      expect(
        forward.any(
          (item) =>
              (item.kind == SketchReconstructionKind.arc ||
                  item.kind == SketchReconstructionKind.circle) &&
              item.entityIds.length == chain.length,
        ),
        isFalse,
      );
    },
  );

  test('automatic segmentation separates gaps, branches and long chains', () {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final second = SketchLine(
      const SketchVector(10.2, 0),
      const SketchVector(20.2, 0),
    );
    final gapSuggestions = const SketchReconstructionEngine().analyze([
      first,
      second,
    ]);
    expect(
      gapSuggestions.where(
        (item) => item.kind == SketchReconstructionKind.line,
      ),
      hasLength(2),
    );
    final branch = [
      SketchLine(const SketchVector(0, 0), const SketchVector(10, 0)),
      SketchLine(const SketchVector(10, 0), const SketchVector(20, 0)),
      SketchLine(const SketchVector(10, 0), const SketchVector(10, 10)),
    ];
    final branchSuggestions = const SketchReconstructionEngine().analyze(
      branch,
    );
    expect(
      branchSuggestions.any(
        (item) =>
            item.kind == SketchReconstructionKind.line &&
            item.entityIds.toSet().containsAll(branch.map((line) => line.id)),
      ),
      isFalse,
    );

    final longChain = [
      for (var index = 0; index < 1000; index++)
        SketchLine(
          SketchVector(index.toDouble(), 0),
          SketchVector((index + 1).toDouble(), 0),
        ),
    ];
    final longSuggestions = const SketchReconstructionEngine().analyze(
      longChain,
    );
    expect(
      longSuggestions.any(
        (item) =>
            item.kind == SketchReconstructionKind.line &&
            item.entityIds.toSet().length == 1000,
      ),
      isTrue,
    );
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
    final reversedSuggestions = const SketchReconstructionEngine().analyze(
      lines.reversed,
    );
    expect(
      suggestions.any((item) => item.kind == SketchReconstructionKind.circle),
      isTrue,
    );
    expect(
      suggestions
          .map((item) => '${item.kind}:${item.entityIds.join(',')}')
          .toList(),
      reversedSuggestions
          .map((item) => '${item.kind}:${item.entityIds.join(',')}')
          .toList(),
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

  test('automatic recognition deduplicates IDs and skips invalid geometry', () {
    final line = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final invalid = SketchLine(
      const SketchVector(double.nan, 0),
      const SketchVector(10, 0),
    );
    final suggestions = const SketchReconstructionEngine().analyze([
      line,
      line,
      invalid,
    ]);
    expect(
      suggestions.every(
        (suggestion) =>
            suggestion.entityIds.toSet().length == suggestion.entityIds.length,
      ),
      isTrue,
    );
    expect(
      suggestions.expand((suggestion) => suggestion.entityIds),
      contains(line.id),
    );
    expect(
      suggestions.expand((suggestion) => suggestion.entityIds),
      isNot(contains(invalid.id)),
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

    test('a straight selection is rejected as collinear', () {
      final first = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(1, 0.0004),
      );
      final second = SketchLine(
        const SketchVector(1, 0.0004),
        const SketchVector(2, 0),
      );
      // The neighbours do not matter for the geometry any more: what rejects
      // this selection is that it is a straight line, not an arc.
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
        SketchCircularFitFailure.collinearPoints,
      );
      final fit = engine.fitSelectedCircular([first, second], context: context);
      expect(fit, isNull);
    });

    test('chord neighbours keep the endpoints without driving the arc', () {
      // Regression: a Section polyline replaces the real curve with chords, so
      // the neighbour directions are only approximately tangent.  The arc must
      // follow the selected samples - all of them - while keeping both external
      // endpoints, instead of collapsing onto a chord tangent interpretation.
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
      // The sample cloud is a real arc of the source circle.
      expect(fit!.radius, closeTo(radius, 1e-6));
      expect(_distance(fit.startPoint!, vertices[1]), lessThan(1e-9));
      expect(_distance(fit.endPoint!, vertices[4]), lessThan(1e-9));
      // Chord neighbours cannot be C1 with the point fit, and that is reported
      // as a non-blocking quality instead of a rejection or a visible break.
      expect(fit.circularFitQuality, isNotNull);
      expect(
        fit.circularFitQuality,
        isNot(SketchCircularFitQuality.c1Bilateral),
      );
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

    test(
      'a shallow chain is accepted instead of a radius/length rejection',
      () {
        // An 11 degree span on a 10 mm radius used to be discarded because the
        // radius is large next to the arc length.  It is a legitimate arc: only
        // the sagitta, sweep and fit error gates decide now.
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

        final fit = engine.fitSelectedCircular(
          chain,
          context: context,
          startTangencyId: startReference.id,
          endTangencyId: endReference.id,
        );

        expect(fit, isNotNull);
        expect(fit!.radius, closeTo(radius, 1e-6));
        expect(fit.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
        expect(_distance(fit.startPoint!, p0), lessThan(1e-9));
        expect(_distance(fit.endPoint!, p1), lessThan(1e-9));
      },
    );

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

  group('multi region section selection', () {
    test('4, 5 and 10 connected regions estimate the same arc', () {
      for (final regions in <int>[4, 5, 10]) {
        const radius = 12.0;
        final chain = _regionChain(radius, 0.4, 1.4, regions);
        final fit = const SketchReconstructionEngine().fitSelectedCircular(
          chain,
        );

        expect(fit, isNotNull, reason: '$regions regions');
        expect(fit!.radius, closeTo(radius, 1e-6), reason: '$regions regions');
        expect(
          _distance(fit.startPoint!, _circlePoint(radius, 0.4)),
          lessThan(1e-9),
        );
        expect(
          _distance(fit.endPoint!, _circlePoint(radius, 1.4)),
          lessThan(1e-9),
        );
        expect(fit.warnings, isEmpty);
      }
    });

    test('small gaps are accepted and reported as warnings', () {
      const radius = 20.0;
      final regions = _gappedChain(
        radius: radius,
        start: 0.3,
        end: 1.1,
        count: 4,
        gapMillimeters: 0.2,
      );

      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        regions,
      );

      expect(fit, isNotNull);
      expect(fit!.warnings, isNotEmpty);
      expect(fit.warnings.first, contains('gap'));
      expect(
        _distance(fit.startPoint!, _circlePoint(radius, 0.3)),
        lessThan(1e-9),
      );
      expect(fit.radius, closeTo(radius, 0.2));
    });

    test('two nearby groups are accepted as one arc', () {
      const radius = 25.0;
      final first = _regionChain(radius, 0.2, 0.6, 2);
      final second = _regionChain(radius, 0.6 + 0.35 / radius, 1.0, 2);

      final fit = const SketchReconstructionEngine().fitSelectedCircular([
        ...first,
        ...second,
      ]);

      expect(fit, isNotNull);
      expect(fit!.radius, closeTo(radius, 0.2));
      expect(fit.entityIds, hasLength(4));
    });

    test('selection order does not matter', () {
      const radius = 30.0;
      final chain = _regionChain(radius, 0.1, 1.2, 4);
      final engine = const SketchReconstructionEngine();

      final ordered = engine.fitSelectedCircular(chain);
      final shuffled = engine.fitSelectedCircular([
        chain[2],
        chain[0],
        chain[3],
        chain[1],
      ]);

      expect(ordered, isNotNull);
      expect(shuffled, isNotNull);
      expect(shuffled!.radius, closeTo(ordered!.radius!, 1e-9));
      expect(shuffled.center!.x, closeTo(ordered.center!.x, 1e-9));
      expect(
        _distance(shuffled.startPoint!, ordered.startPoint!),
        lessThan(1e-9),
      );
      expect(_distance(shuffled.endPoint!, ordered.endPoint!), lessThan(1e-9));
    });

    test('line, arc and spline regions share one fit', () {
      const radius = 8.0;
      const a0 = 0.2, a1 = 1.2;
      final third = (a1 - a0) / 3;
      final line = SketchLine(
        _circlePoint(radius, a0),
        _circlePoint(radius, a0 + third),
      );
      final arc = SketchArc(
        const SketchVector(0, 0),
        radius,
        a0 + third,
        a0 + 2 * third,
      );
      final spline = SketchSpline([
        for (var index = 0; index <= 6; index++)
          _circlePoint(radius, a0 + 2 * third + third * index / 6),
      ]);
      spline.parameters['sampledPoints'] = [
        for (var index = 0; index <= 6; index++)
          _circlePoint(radius, a0 + 2 * third + third * index / 6).toJson(),
      ];

      final fit = const SketchReconstructionEngine().fitSelectedCircular([
        spline,
        line,
        arc,
      ]);

      expect(fit, isNotNull);
      expect(fit!.radius, closeTo(radius, 1e-6));
      expect(fit.center!.x, closeTo(0, 1e-6));
      expect(
        _distance(fit.startPoint!, _circlePoint(radius, a0)),
        lessThan(1e-9),
      );
      expect(
        _distance(fit.endPoint!, _circlePoint(radius, a1)),
        lessThan(1e-9),
      );
    });

    test('a large radius over a short span is accepted', () {
      // The old guard rejected any radius larger than 8x the selection
      // diagonal; at 1500 mm over a 60 mm span that is a perfectly good arc.
      const radius = 1500.0;
      final span = 60.0 / radius;
      final chain = _regionChain(radius, 0.1, 0.1 + span, 3);

      final fit = const SketchReconstructionEngine().fitSelectedCircular(chain);

      expect(fit, isNotNull);
      expect(fit!.radius, closeTo(radius, 1e-3));
      expect(fit.circularFitQuality, isNotNull);
    });

    test('a non monotonic U selection keeps the real external endpoints', () {
      // A 240 degree arc is U shaped.  With six 40 degree regions the farthest
      // endpoint pair is the diagonal P(0)-P(160) at 1.970R, while the real
      // external endpoint P(240) sits at 1.732R: strictly shorter, so the
      // diagonal can never be mistaken for the chain end by rounding noise.
      // The external endpoints must be the free ends, never the diagonal.
      const radius = 10.0;
      const regions = 6;
      final a1 = 240 * math.pi / 180;
      final chain = _regionChain(radius, 0, a1, regions);

      final fit = const SketchReconstructionEngine().fitSelectedCircular(chain);

      expect(fit, isNotNull);
      expect(fit!.radius, closeTo(radius, 1e-6));
      expect(
        _distance(fit.startPoint!, _circlePoint(radius, 0)),
        lessThan(1e-9),
      );
      expect(
        _distance(fit.endPoint!, _circlePoint(radius, a1)),
        lessThan(1e-9),
      );
      // Diagonal picked by the farthest pair search: P(0)-P(160) at 1.970R,
      // which is strictly longer than the 1.732R chord to the real end.
      final diagonal = _circlePoint(radius, 160 * math.pi / 180);
      expect(
        _distance(_circlePoint(radius, 0), diagonal) -
            _distance(_circlePoint(radius, 0), _circlePoint(radius, a1)),
        greaterThan(1e-3),
      );
      expect(_distance(fit.endPoint!, diagonal), greaterThan(1e-3));
    });

    test('independent regions with 1, 5 and 20 mm gaps are all accepted', () {
      // Geomagic style: the selected regions are independent samples, so a big
      // miss between them is reported but never blocks the global fit.
      const radius = 200.0;
      for (final gap in <double>[1, 5, 20]) {
        final chain = _gappedChain(
          radius: radius,
          start: 0.2,
          end: 0.6,
          count: 3,
          gapMillimeters: gap,
        );
        final fit = const SketchReconstructionEngine().fitSelectedCircular(
          chain,
        );

        expect(fit, isNotNull, reason: 'gap $gap mm');
        expect(fit!.radius, closeTo(radius, 1.0), reason: 'gap $gap mm');
        expect(
          fit.maxGapMillimeters,
          closeTo(gap, math.max(0.05, gap * 0.05)),
          reason: 'gap $gap mm',
        );
        expect(
          fit.warnings.any((warning) => warning.contains('gap')),
          isTrue,
          reason: 'gap $gap mm',
        );
        // Every selected region still contributes to the fit.
        expect(fit.entityIds, hasLength(3));
      }
    });

    test('a large gap on a small part only warns', () {
      const radius = 5.0;
      final chain = _gappedChain(
        radius: radius,
        start: 0.2,
        end: 0.6,
        count: 2,
        gapMillimeters: 0.8,
      );
      final fit = const SketchReconstructionEngine().fitSelectedCircular(chain);

      expect(fit, isNotNull);
      expect(fit!.warnings.any((warning) => warning.contains('gap')), isTrue);
    });

    test('manual tangency accepts nearby references without contact', () {
      const radius = 6.0;
      const a0 = 0.5, a1 = 1.3;
      final chain = _regionChain(radius, a0, a1, 3);
      final p0 = _circlePoint(radius, a0);
      final p1 = _circlePoint(radius, a1);
      // Offset 0.2 mm away from the endpoints, as a mesh cut with a small gap
      // produces.  The reference is not connected to the chain at all and the
      // direction points forward along the walk.
      final startReference = SketchLine(
        p0 - _circleTangent(a0).scale(3) + _circleTangent(a0).scale(0.2),
        p0 + _circleTangent(a0).scale(0.2),
      );
      final endReference = SketchLine(
        p1 + _circleTangent(a1).scale(0.2),
        p1 + _circleTangent(a1).scale(3) + _circleTangent(a1).scale(0.2),
      );

      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        chain,
        context: [startReference, ...chain, endReference],
        startTangencyId: startReference.id,
        endTangencyId: endReference.id,
      );

      expect(fit, isNotNull);
      expect(fit!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      expect(fit.radius, closeTo(radius, 0.2));
    });

    test('compatible manual tangencies report near zero angular errors', () {
      const radius = 8.0;
      const a0 = 0.4, a1 = 1.2;
      final chain = _regionChain(radius, a0, a1, 3);
      final p0 = _circlePoint(radius, a0);
      final p1 = _circlePoint(radius, a1);
      final startReference = SketchLine(p0 - _circleTangent(a0).scale(4), p0);
      final endReference = SketchLine(p1, p1 + _circleTangent(a1).scale(4));

      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        chain,
        context: [startReference, ...chain, endReference],
        startTangencyId: startReference.id,
        endTangencyId: endReference.id,
      );

      expect(fit, isNotNull);
      expect(fit!.circularFitQuality, SketchCircularFitQuality.c1Bilateral);
      expect(fit.radius, closeTo(radius, 1e-3));
      // Both junctions are real C1: the measured angles are essentially zero.
      expect(fit.tangencyStartDegrees, isNotNull);
      expect(fit.tangencyEndDegrees, isNotNull);
      expect(fit.tangencyStartDegrees!, lessThan(0.05));
      expect(fit.tangencyEndDegrees!, lessThan(0.05));
      // The arc still meets the preserved endpoints.
      expect(_distance(fit.startPoint!, p0), lessThan(1e-3));
      expect(_distance(fit.endPoint!, p1), lessThan(1e-3));
    });

    test('incompatible manual tangencies are rejected with the angles', () {
      const radius = 8.0;
      const a0 = 0.4, a1 = 1.2;
      final chain = _regionChain(radius, a0, a1, 3);
      final p0 = _circlePoint(radius, a0);
      final p1 = _circlePoint(radius, a1);
      final startReference = SketchLine(p0 - _circleTangent(a0).scale(4), p0);
      // End reference rotated 25 degrees away from the true tangent: no circle
      // can be C1 with both references while keeping the endpoints.
      final rotated = _rotate(_circleTangent(a1), 25 * math.pi / 180);
      final endReference = SketchLine(p1, p1 + rotated.scale(4));
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
      final diagnosis = engine.diagnoseSelectedCircularDetailed(
        chain,
        context: context,
        startTangencyId: startReference.id,
        endTangencyId: endReference.id,
      );
      expect(diagnosis.failure, SketchCircularFitFailure.incompatibleTangency);
      expect(diagnosis.tangencyStartDegrees, isNotNull);
      expect(diagnosis.tangencyEndDegrees, isNotNull);
      expect(diagnosis.tangencyEndDegrees!, greaterThan(1));
      expect(diagnosis.radius, isNotNull);
    });

    test('really collinear points are rejected', () {
      final chain = <SketchEntity>[
        SketchLine(const SketchVector(0, 0), const SketchVector(1, 0)),
        SketchLine(const SketchVector(1, 0), const SketchVector(2, 0)),
        SketchLine(const SketchVector(2, 0), const SketchVector(3, 0)),
      ];
      final engine = const SketchReconstructionEngine();

      expect(engine.fitSelectedCircular(chain), isNull);
      expect(
        engine.diagnoseSelectedCircular(chain),
        SketchCircularFitFailure.collinearPoints,
      );
    });

    test('each rejection has its own diagnostic', () {
      final engine = const SketchReconstructionEngine();
      // Too few samples.
      expect(
        engine.diagnoseSelectedCircular([
          SketchLine(const SketchVector(0, 0), const SketchVector(1, 0)),
        ]),
        SketchCircularFitFailure.insufficientPoints,
      );
      // A large gap between independent regions is no longer a failure: it is
      // a warning and the fit still succeeds.
      final gapped = <SketchEntity>[
        SketchLine(_circlePoint(20, 0.2), _circlePoint(20, 0.5)),
        SketchLine(_circlePoint(20, 1.5), _circlePoint(20, 1.8)),
      ];
      final gappedFit = engine.fitSelectedCircular(gapped);
      expect(gappedFit, isNotNull);
      expect(
        gappedFit!.warnings.any((warning) => warning.contains('gap')),
        isTrue,
      );
      // Noisy samples no single circle follows (a zig-zag staircase).
      expect(
        engine.diagnoseSelectedCircular([
          SketchLine(const SketchVector(0, 0), const SketchVector(1, 1)),
          SketchLine(const SketchVector(1, 1), const SketchVector(2, 0)),
          SketchLine(const SketchVector(2, 0), const SketchVector(3, 1)),
          SketchLine(const SketchVector(3, 1), const SketchVector(4, 0)),
        ]),
        SketchCircularFitFailure.fitErrorAboveTolerance,
      );
      // Manual reference far from the endpoint.
      final chain = _regionChain(12.0, 0.2, 1.2, 3);
      final stray = SketchLine(
        const SketchVector(80, 80),
        const SketchVector(81, 80),
      );
      expect(
        engine.diagnoseSelectedCircular(
          chain,
          context: [...chain, stray],
          startTangencyId: stray.id,
          endTangencyId: chain.last.id,
        ),
        SketchCircularFitFailure.disconnectedTangency,
      );
    });
  });
}

SketchVector _circlePoint(double radius, double angle) =>
    SketchVector(radius * math.cos(angle), radius * math.sin(angle));

SketchVector _circleTangent(double angle) =>
    SketchVector(-math.sin(angle), math.cos(angle));

SketchVector _rotate(SketchVector vector, double angle) => SketchVector(
  vector.x * math.cos(angle) - vector.y * math.sin(angle),
  vector.x * math.sin(angle) + vector.y * math.cos(angle),
);

/// [regions] consecutive chords of the circle, sharing their endpoints.
List<SketchLine> _regionChain(
  double radius,
  double a0,
  double a1,
  int regions,
) => <SketchLine>[
  for (var index = 0; index < regions; index++)
    SketchLine(
      _circlePoint(radius, a0 + (a1 - a0) * index / regions),
      _circlePoint(radius, a0 + (a1 - a0) * (index + 1) / regions),
    ),
];

/// [count] chords of the circle separated by [gapMillimeters] along the arc,
/// which is what a mesh Section cut with small misses produces.
List<SketchLine> _gappedChain({
  required double radius,
  required double start,
  required double end,
  required int count,
  required double gapMillimeters,
}) {
  final gap = gapMillimeters / radius;
  final usable = (end - start) - gap * (count - 1);
  final step = usable / count;
  return <SketchLine>[
    for (var index = 0; index < count; index++)
      SketchLine(
        _circlePoint(radius, start + index * (step + gap)),
        _circlePoint(radius, start + index * (step + gap) + step),
      ),
  ];
}

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
