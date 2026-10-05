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
