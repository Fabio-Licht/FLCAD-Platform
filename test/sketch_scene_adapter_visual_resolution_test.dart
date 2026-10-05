import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/sketch_scene_adapter.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';

void main() {
  const adapter = SketchSceneAdapter();

  List<SketchVector> overlayPoints(SketchEntity entity) =>
      (adapter.adapt(entity).geometry['points'] as List)
          .map(SketchVector.fromJson)
          .toList(growable: false);

  double distance(SketchVector a, SketchVector b) {
    final dx = a.x - b.x, dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  group('SketchSceneAdapter visual resolution', () {
    test('arc exposes at least 65 points', () {
      final arc = SketchArc(const SketchVector(0, 0), 100, 0, math.pi / 2);
      expect(overlayPoints(arc).length, greaterThanOrEqualTo(65));
      expect(overlayPoints(arc).length, SketchSceneAdapter.arcSampleCount);
    });

    test('circle and ellipse expose at least 129 points', () {
      final circle = SketchCircle(const SketchVector(0, 0), 100);
      final ellipse = SketchEllipse(const SketchVector(0, 0), 120, 60);
      expect(overlayPoints(circle).length, greaterThanOrEqualTo(129));
      expect(overlayPoints(ellipse).length, greaterThanOrEqualTo(129));
      expect(
        overlayPoints(ellipse).length,
        SketchSceneAdapter.ellipseSampleCount,
      );
    });

    test('chord sagitta stays within the visual tolerance at high zoom', () {
      const radius = 250.0; // a large section radius, worst case for chords
      final arc = SketchArc(const SketchVector(0, 0), radius, 0, math.pi * 2);
      final points = overlayPoints(arc);
      final segmentAngle = 2 * math.pi / (points.length - 1);
      final sagitta = SketchSceneAdapter.sagitta(radius, segmentAngle);
      expect(sagitta, lessThanOrEqualTo(SketchSceneAdapter.visualSagittaMm));

      // The sampled points must also lie (within tolerance) on the true circle.
      for (final point in points) {
        final radial = math.sqrt(point.x * point.x + point.y * point.y);
        expect((radial - radius).abs(), lessThan(1e-9));
      }
    });

    test('spline overlay does not reduce sampledPoints', () {
      final spline = SketchSpline(const [
        SketchVector(0, 0),
        SketchVector(10, 40),
        SketchVector(40, 10),
        SketchVector(50, 0),
      ]);
      final stored = (spline.parameters['sampledPoints'] as List).length;
      expect(overlayPoints(spline).length, stored);
      expect(overlayPoints(spline).length, greaterThanOrEqualTo(4));
    });

    test('analytic endpoints are preserved on the arc', () {
      const center = SketchVector(3, -2);
      const radius = 40.0;
      const start = 0.3;
      const end = 2.1;
      final points = overlayPoints(SketchArc(center, radius, start, end));

      final expectedStart = SketchVector(
        center.x + radius * math.cos(start),
        center.y + radius * math.sin(start),
      );
      final expectedEnd = SketchVector(
        center.x + radius * math.cos(end),
        center.y + radius * math.sin(end),
      );
      expect(distance(points.first, expectedStart), lessThan(1e-9));
      expect(distance(points.last, expectedEnd), lessThan(1e-9));
    });

    test('closed circle start and end coincide at angle zero', () {
      final points = overlayPoints(SketchCircle(const SketchVector(5, 5), 30));
      expect(distance(points.first, points.last), lessThan(1e-9));
      expect(points.first.x, closeTo(35, 1e-9));
      expect(points.first.y, closeTo(5, 1e-9));
    });
  });
}
