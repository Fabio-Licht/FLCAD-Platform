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
          : entity is SketchSpline
          ? 'splineMagenta'
          : 'sketchGreen',
      // Screen-space width: sketch readability must not depend on zoom or on
      // the angle of its support plane.
      'strokeWidth': technicalStrokeWidth,
      'construction': entity.construction,
      'reference': entity.reference,
    },
    selected: entity.selectionState == SketchSelectionState.selected,
    transparent: preview,
  );

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
    SketchSpline() =>
      ((entity.parameters['sampledPoints'] ?? entity.parameters['points'])
              as List)
          .map(SketchVector.fromJson)
          .toList(),
    _ => const [],
  };

  List<SketchVector> _arc(SketchEntity entity) {
    final center = SketchVector.fromJson(entity.parameters['center']);
    final radius = (entity.parameters['radius'] as num).toDouble();
    final start = (entity.parameters['startAngle'] as num).toDouble();
    final end = (entity.parameters['endAngle'] as num).toDouble();
    return List.generate(33, (index) {
      final angle = start + (end - start) * index / 32;
      return SketchVector(
        center.x + radius * math.cos(angle),
        center.y + radius * math.sin(angle),
      );
    });
  }

  List<SketchVector> _ellipse(SketchVector center, double rx, double ry) =>
      List.generate(65, (index) {
        final angle = math.pi * 2 * index / 64;
        return SketchVector(
          center.x + rx * math.cos(angle),
          center.y + ry * math.sin(angle),
        );
      });
}
