import 'dart:math' as math;

import '../../../core/sketch_engine/entities/sketch_entities.dart';
import '../../../core/sketch_engine/models/sketch_models.dart';
import '../scene/cad_scene_graph.dart';

class SketchSceneAdapter {
  const SketchSceneAdapter();
  static const double technicalStrokeWidth = 2.0;

  CadSceneEntity adapt(
    SketchEntity entity, {
    bool preview = false,
    SketchCoordinateSystem? coordinates,
  }) => CadSceneEntity(
    id: entity.id,
    kind: preview ? CadSceneEntityKind.preview : CadSceneEntityKind.sketch,
    geometry: {
      'points': _points(entity)
          .map((point) => coordinates?.localToGlobal(point) ?? point)
          .map((point) => point.toJson())
          .toList(),
      'entityType': entity.type.name,
      'showEndpoints': entity is SketchLine || entity is SketchArc,
      'displayColor': preview
          ? 'previewOrange'
          : _reconstructionColor(entity) ??
                (entity is SketchSpline ? 'splineMagenta' : 'sketchGreen'),
      // Screen-space width: sketch readability must not depend on zoom or on
      // the angle of its support plane.
      'strokeWidth': technicalStrokeWidth,
      'construction': entity.construction,
      'reference': entity.reference,
    },
    selected: entity.selectionState == SketchSelectionState.selected,
    transparent: preview,
  );

  String? _reconstructionColor(SketchEntity entity) {
    if (entity.metadata['regionFitVisualComparison'] == true) {
      return 'regionFitNavy';
    }
    return switch (entity.metadata['reconstructionKind']) {
      'line' => 'reconstructedLine',
      'spline' => 'reconstructedSpline',
      'circle' => 'reconstructedCircle',
      'arc' => 'reconstructedArc',
      _ => null,
    };
  }

  List<SketchVector> _points(SketchEntity entity) => switch (entity) {
    SketchPoint() => [SketchVector.fromJson(entity.parameters['point'])],
    SketchLine() => [
      SketchVector.fromJson(entity.parameters['start']),
      SketchVector.fromJson(entity.parameters['end']),
    ],
    SketchCircle() => _ellipse(
      SketchVector.fromJson(entity.parameters['center']),
      (entity.parameters['radius'] as num).toDouble(),
      (entity.parameters['radius'] as num).toDouble(),
    ),
    SketchArc() => _arc(entity),
    SketchEllipse() => _ellipse(
      SketchVector.fromJson(entity.parameters['center']),
      (entity.parameters['radiusX'] as num).toDouble(),
      (entity.parameters['radiusY'] as num).toDouble(),
    ),
    // The persisted sampledPoints are already an analytical approximation of
    // the curve. The overlay must never reduce them: doing so would make a
    // correctly reconstructed profile look polygonal at high zoom. They are
    // forwarded verbatim so the drawn contour always matches the stored data.
    SketchSpline() =>
      ((entity.parameters['sampledPoints'] ?? entity.parameters['points'])
              as List)
          .map(SketchVector.fromJson)
          .toList(growable: false),
    _ => const [],
  };

  /// Minimum number of sampled points used to draw an arc analytically.
  /// 65 points (64 chords) keep the visible sagitta below [visualSagittaMm]
  /// for the radii used in reverse-engineered sections, avoiding a polygonal
  /// silhouette at high zoom without generating unbounded geometry.
  static const int arcSampleCount = 65;

  /// Minimum number of sampled points used to draw a circle/ellipse. 129
  /// points (128 chords) halve the chord error of the previous 64-segment
  /// approximation, matching the arc resolution at the same radius.
  static const int ellipseSampleCount = 129;

  /// Maximum guaranteed chord deviation (mm) between the drawn polyline and
  /// the true analytic curve. With 64 chords this is only reached on large
  /// section radii (~250 mm) and stays visually negligible at high zoom while
  /// keeping the point count bounded. Used as the regression guard for the
  /// resolution tests.
  static const double visualSagittaMm = 0.35;

  /// Sagitta (mid-chord deviation) of a circular chord sampled every
  /// [segmentAngle] radians at [radius]: r * (1 - cos(theta / 2)).
  static double sagitta(double radius, double segmentAngle) =>
      radius * (1 - math.cos(segmentAngle.abs() / 2));

  List<SketchVector> _arc(SketchEntity entity) {
    final center = SketchVector.fromJson(entity.parameters['center']);
    final radius = (entity.parameters['radius'] as num).toDouble();
    final start = (entity.parameters['startAngle'] as num).toDouble();
    final end = (entity.parameters['endAngle'] as num).toDouble();
    final segments = arcSampleCount - 1;
    // Endpoints are preserved exactly: index 0 is the analytic start angle and
    // the last index is the analytic end angle, so the drawn arc shares its
    // mathematical endpoints and only the interior resolution increases.
    return List.generate(arcSampleCount, (index) {
      final angle = start + (end - start) * index / segments;
      return SketchVector(
        center.x + radius * math.cos(angle),
        center.y + radius * math.sin(angle),
      );
    });
  }

  List<SketchVector> _ellipse(SketchVector center, double rx, double ry) {
    final segments = ellipseSampleCount - 1;
    // Full closed loop: index 0 and the last index coincide at angle 0, which
    // is the expected closure for a circle/ellipse overlay.
    return List.generate(ellipseSampleCount, (index) {
      final angle = math.pi * 2 * index / segments;
      return SketchVector(
        center.x + rx * math.cos(angle),
        center.y + ry * math.sin(angle),
      );
    });
  }
}
