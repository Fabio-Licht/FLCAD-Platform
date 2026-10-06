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
    final center = fit!.center!;
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
  });

  test(
    'manual fit falls back to the three point circle when tangencies disagree',
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

      // No circle can stay C1 with both neighbours, but the chain still
      // defines a valid circular arc: refusing to build it left the operator
      // without any result at all.
      final fit = const SketchReconstructionEngine().fitSelectedCircular(
        [first, second],
        context: [before, first, second, after],
      );

      expect(fit, isNotNull);
      expect(fit!.center!.x, closeTo(1, 1e-9));
      expect(fit.center!.y, closeTo(0, 1e-9));
      expect(fit.radius, closeTo(1, 1e-9));
    },
  );

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
}
