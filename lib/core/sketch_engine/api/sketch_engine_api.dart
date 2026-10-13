import 'dart:math' as math;

import '../builders/sketch_builders.dart';
import '../engine/sketch_engine.dart';
import '../entities/sketch_entities.dart';
import '../history/sketch_history.dart';
import '../models/sketch_models.dart';

class SketchEngineApi {
  SketchEngineApi(this.engine) : builders = SketchBuilders(engine);
  final SketchEngine engine;
  final SketchBuilders builders;
  Sketch createSketch(
    String name, {
    SketchPlane? plane,
    SketchCoordinateSystem? coordinates,
  }) => engine.createSketch(name, plane: plane, coordinates: coordinates);
  void deleteSketch(String id) => engine.deleteSketch(id);
  void openSketch(String id) => engine.openSketch(id);
  void restoreSketch(
    Sketch sketch, {
    Iterable<SketchEntity> entities = const <SketchEntity>[],
  }) => engine.restoreSketch(sketch, entities: entities);
  void closeSketch() => engine.closeSketch();
  void deleteEntity(String id) => engine.deleteEntity(id);

  /// Atomically edits the defining parameters of an existing professional
  /// Sketch primitive. Derived values are always recomputed from its true
  /// geometry, so the Inspector never leaves a partially updated entity.
  void updateParameters(String id, Map<String, double> values) => engine.modify(
    id,
    SketchHistoryAction.modify,
    (entity) => _updateProfessionalParameters(entity, values),
  );
  void move(String id, SketchVector delta) => engine.modify(
    id,
    SketchHistoryAction.move,
    (entity) => _transformPoints(entity, (point) => point + delta),
  );
  void rotate(
    String id,
    double angle, {
    SketchVector center = const SketchVector(0, 0),
  }) => engine.modify(id, SketchHistoryAction.rotate, (entity) {
    final cosine = math.cos(angle), sine = math.sin(angle);
    _transformPoints(entity, (point) {
      final x = point.x - center.x, y = point.y - center.y;
      return SketchVector(
        center.x + x * cosine - y * sine,
        center.y + x * sine + y * cosine,
      );
    });
    if (entity is SketchArc) {
      entity.parameters['startAngle'] =
          (entity.parameters['startAngle'] as num).toDouble() + angle;
      entity.parameters['endAngle'] =
          (entity.parameters['endAngle'] as num).toDouble() + angle;
    }
  });
  void scale(
    String id,
    double factor, {
    double? factorY,
    SketchVector center = const SketchVector(0, 0),
  }) => engine.modify(id, SketchHistoryAction.scale, (entity) {
    final sy = factorY ?? factor;
    _transformPoints(
      entity,
      (point) => SketchVector(
        center.x + (point.x - center.x) * factor,
        center.y + (point.y - center.y) * sy,
      ),
    );
    if (entity is SketchCircle || entity is SketchArc) {
      if ((factor - sy).abs() > 1e-12) {
        throw ArgumentError('Non-uniform scale is invalid for circles/arcs.');
      }
      entity.parameters['radius'] =
          (entity.parameters['radius'] as num).toDouble() * factor.abs();
    } else if (entity is SketchEllipse) {
      entity.parameters['radiusX'] =
          (entity.parameters['radiusX'] as num).toDouble() * factor.abs();
      entity.parameters['radiusY'] =
          (entity.parameters['radiusY'] as num).toDouble() * sy.abs();
    }
  });
  void mirror(
    String id, {
    SketchVector axisStart = const SketchVector(0, 0),
    SketchVector axisEnd = const SketchVector(1, 0),
  }) => engine.modify(id, SketchHistoryAction.mirror, (entity) {
    final dx = axisEnd.x - axisStart.x, dy = axisEnd.y - axisStart.y;
    final length2 = dx * dx + dy * dy;
    if (length2 <= 1e-24) throw ArgumentError('Mirror axis is degenerate.');
    _transformPoints(entity, (point) {
      final t =
          ((point.x - axisStart.x) * dx + (point.y - axisStart.y) * dy) /
          length2;
      final projection = SketchVector(
        axisStart.x + t * dx,
        axisStart.y + t * dy,
      );
      return SketchVector(
        2 * projection.x - point.x,
        2 * projection.y - point.y,
      );
    });
    if (entity is SketchArc) {
      final start = (entity.parameters['startAngle'] as num).toDouble();
      final end = (entity.parameters['endAngle'] as num).toDouble();
      final axisAngle = math.atan2(dy, dx);
      entity.parameters['startAngle'] = 2 * axisAngle - end;
      entity.parameters['endAngle'] = 2 * axisAngle - start;
    }
  });
  void setConstruction(String id, bool value) => engine.modify(
    id,
    SketchHistoryAction.construction,
    (e) => e.construction = value,
  );
  void setReference(String id, bool value) => engine.modify(
    id,
    SketchHistoryAction.reference,
    (e) => e.reference = value,
  );
  List<Sketch> get sketches => List.unmodifiable(engine.sketches.values);
  SketchEntity? entity(String id) => engine.entities[id];
  Future<void> load() => engine.load();
  Future<void> persist() => engine.persist();
  String? get activeSketchRestoreDiagnostic =>
      engine.activeSketchRestoreDiagnostic;

  static void _updateProfessionalParameters(
    SketchEntity entity,
    Map<String, double> values,
  ) {
    double finite(String name, double value) {
      if (!value.isFinite) throw ArgumentError('$name must be finite.');
      return value;
    }

    double positive(String name, double value) {
      finite(name, value);
      if (value <= 0) throw ArgumentError('$name must be greater than zero.');
      return value;
    }

    switch (entity) {
      case SketchLine():
        var start = SketchVector.fromJson(entity.parameters['start']);
        var end = SketchVector.fromJson(entity.parameters['end']);
        start = SketchVector(
          finite('startX', values['startX'] ?? start.x),
          finite('startY', values['startY'] ?? start.y),
          start.z,
        );
        end = SketchVector(
          finite('endX', values['endX'] ?? end.x),
          finite('endY', values['endY'] ?? end.y),
          end.z,
        );
        if (values.containsKey('length') ||
            values.containsKey('angleDegrees')) {
          final currentDx = end.x - start.x;
          final currentDy = end.y - start.y;
          final length = positive(
            'length',
            values['length'] ??
                math.sqrt(currentDx * currentDx + currentDy * currentDy),
          );
          final angle =
              finite(
                'angleDegrees',
                values['angleDegrees'] ??
                    math.atan2(currentDy, currentDx) * 180 / math.pi,
              ) *
              math.pi /
              180;
          end = SketchVector(
            start.x + length * math.cos(angle),
            start.y + length * math.sin(angle),
            start.z,
          );
        }
        entity.parameters
          ..clear()
          ..addAll(SketchLine.parametersFor(start, end));
      case SketchCircle():
        final old = SketchVector.fromJson(entity.parameters['center']);
        final center = SketchVector(
          finite('centerX', values['centerX'] ?? old.x),
          finite('centerY', values['centerY'] ?? old.y),
          old.z,
        );
        final radius = positive(
          'radius',
          values['diameter'] != null
              ? values['diameter']! / 2
              : values['radius'] ??
                    (entity.parameters['radius'] as num).toDouble(),
        );
        entity.parameters
          ..['center'] = center.toJson()
          ..['radius'] = radius;
      case SketchArc():
        final old = SketchVector.fromJson(entity.parameters['center']);
        entity.parameters
          ..['center'] = SketchVector(
            finite('centerX', values['centerX'] ?? old.x),
            finite('centerY', values['centerY'] ?? old.y),
            old.z,
          ).toJson()
          ..['radius'] = positive(
            'radius',
            values['radius'] ?? (entity.parameters['radius'] as num).toDouble(),
          )
          ..['startAngle'] =
              finite(
                'startAngleDegrees',
                values['startAngleDegrees'] ??
                    (entity.parameters['startAngle'] as num).toDouble() *
                        180 /
                        math.pi,
              ) *
              math.pi /
              180
          ..['endAngle'] =
              finite(
                'endAngleDegrees',
                values['endAngleDegrees'] ??
                    (entity.parameters['endAngle'] as num).toDouble() *
                        180 /
                        math.pi,
              ) *
              math.pi /
              180;
      default:
        throw StateError('${entity.type.name} is not editable by G-124.');
    }
  }

  static void _transformPoints(
    SketchEntity entity,
    SketchVector Function(SketchVector) transform,
  ) {
    void point(String key) {
      final value = entity.parameters[key];
      if (value != null) {
        entity.parameters[key] = transform(
          SketchVector.fromJson(value),
        ).toJson();
      }
    }

    switch (entity) {
      case SketchPoint():
        point('point');
      case SketchLine():
        point('start');
        point('end');
      case SketchCircle() || SketchArc() || SketchEllipse():
        point('center');
      case SketchSpline():
        for (final key in ['points', 'sampledPoints', 'bezierControls']) {
          final values = entity.parameters[key];
          if (values is List) {
            entity.parameters[key] = values
                .map(
                  (value) => transform(SketchVector.fromJson(value)).toJson(),
                )
                .toList();
          }
        }
      default:
        break;
    }
  }
}
