import 'dart:math' as math;
import '../../feature_lifecycle/feature_update_solver.dart';
import '../../parametric_solver/parametric_solver.dart';
import '../../sketch_constraints/api/constraint_api.dart';
import '../../sketch_engine/api/sketch_engine_api.dart';
import '../../sketch_engine/entities/sketch_entities.dart';
import '../../sketch_engine/history/sketch_history.dart';
import '../../sketch_engine/models/sketch_models.dart';
import '../analytics/editor_analytics.dart';
import '../analytics/sketch_quality.dart';
import '../editing/degrees_of_freedom.dart';
import '../graph/editor_graph.dart';
import '../history/editor_history.dart';
import '../integration/sketch_advisor.dart';
import '../models/editor_models.dart';
import '../preview/preview_engine.dart';
import '../repository/editor_repository.dart';
import '../runtime/editor_runtime.dart';
import '../selection/editor_selection.dart';
import '../snapping/editor_snapping.dart';
import '../toolbar/sketch_toolbar.dart';

class SketchEditorEngine {
  SketchEditorEngine({
    required this.sketch,
    required this.constraints,
    required this.repository,
    EditorRuntime? runtime,
    EditorAnalytics? analytics,
    EditorHistory? history,
  }) : runtime = runtime ?? EditorRuntime(),
       analytics = analytics ?? EditorAnalytics(),
       history = history ?? EditorHistory() {
    selection = EditorSelectionEngine(this.analytics);
    snapping = EditorSnappingEngine(this.analytics);
    preview = PreviewEngine(this.analytics);
  }
  final SketchEngineApi sketch;
  final ConstraintApi constraints;
  final EditorRepository repository;
  final EditorRuntime runtime;
  final EditorAnalytics analytics;
  final EditorHistory history;
  final graph = EditorGraph();
  final toolbar = SketchToolbar();
  late final EditorSelectionEngine selection;
  late final EditorSnappingEngine snapping;
  late final PreviewEngine preview;
  final _undoCounts = <int>[], _redoCounts = <int>[];
  final FeatureUpdateSolver featureUpdates = const FeatureUpdateSolver();

  EditorOperation start(
    SketchToolType tool,
    List<SketchVector> points, {
    Map<String, dynamic>? parameters,
  }) {
    toolbar.activate(tool);
    final op = EditorOperation(tool, points: points, parameters: parameters);
    history.record(EditorHistoryAction.preview, op.id);
    return preview.begin(op);
  }

  List<SketchEntity> confirm(String previewId) {
    final watch = Stopwatch()..start();
    final operation = preview.confirm(previewId);
    final created = <SketchEntity>[];
    try {
      sketch.engine.transaction(
        'editor:${operation.id}',
        () => _create(operation, created),
      );
      graph.record(operation.id, created.map((e) => e.id));
      // `_create` is wrapped by one SketchEngine transaction even when a tool
      // emits several entities (rectangle, polygon or slot). Undo/Redo must
      // therefore move one engine snapshot, not one snapshot per entity.
      _undoCounts.add(1);
      _redoCounts.clear();
      history.record(EditorHistoryAction.commit, operation.id);
      analytics.editCount++;
      analytics.entities = sketch.engine.entities.length;
      return created;
    } catch (_) {
      operation.status = EditorOperationStatus.failed;
      history.record(EditorHistoryAction.rollback, operation.id);
      rethrow;
    } finally {
      watch.stop();
      analytics.totalEditMicros += watch.elapsedMicroseconds;
    }
  }

  void cancel(String id) {
    preview.cancel(id);
    history.record(EditorHistoryAction.cancel, id);
  }

  void _create(EditorOperation op, List<SketchEntity> out) {
    final p = op.points, b = sketch.builders;
    switch (op.tool) {
      case SketchToolType.point:
        out.add(b.point.build(p.first));
      case SketchToolType.line:
        out.add(b.line.build(p[0], p[1]));
      case SketchToolType.polyline:
        for (var i = 1; i < p.length; i++) {
          out.add(b.line.build(p[i - 1], p[i]));
        }
      case SketchToolType.rectangle:
      case SketchToolType.centerRectangle:
        final a = p[0],
            c = p[1],
            corners = [a, SketchVector(c.x, a.y), c, SketchVector(a.x, c.y)];
        for (var i = 0; i < 4; i++) {
          out.add(b.line.build(corners[i], corners[(i + 1) % 4]));
        }
      case SketchToolType.circle:
      case SketchToolType.centerCircle:
      case SketchToolType.threePointCircle:
        out.add(b.circle.build(p[0], _distance(p[0], p[1])));
      case SketchToolType.arc:
      case SketchToolType.threePointArc:
      case SketchToolType.tangentArc:
        out.add(
          b.arc.build(
            p[0],
            _distance(p[0], p[1]),
            op.parameters['startAngle'] as double? ?? 0,
            op.parameters['endAngle'] as double? ?? math.pi,
          ),
        );
      case SketchToolType.ellipse:
        out.add(
          b.ellipse.build(p[0], _distance(p[0], p[1]), _distance(p[0], p[2])),
        );
      case SketchToolType.spline:
        final controls = op.parameters['bezierControls'];
        final spline = b.spline.build(
          p,
          bezierControls: controls is List
              ? controls.map(SketchVector.fromJson).toList()
              : null,
        );
        final sourceIds = op.parameters['sourceEntityIds'];
        if (sourceIds is List) {
          spline.metadata.addAll({
            'featureType': 'tangentBlend',
            'sourceEntityIds': sourceIds.cast<String>(),
            if (op.parameters['sourceEndpointReferences'] is List)
              'sourceEndpointReferences':
                  (op.parameters['sourceEndpointReferences'] as List)
                      .whereType<String>()
                      .toList(growable: false),
            'tangentLength': op.parameters['tangentLength'],
            'firstTangentLength': op.parameters['firstTangentLength'],
            'secondTangentLength': op.parameters['secondTangentLength'],
          });
        }
        out.add(spline);
      case SketchToolType.slot:
        out
          ..add(b.line.build(p[0], p[1]))
          ..add(
            b.arc.build(
              p[0],
              op.parameters['radius'] as double? ?? 1,
              0,
              math.pi,
            ),
          )
          ..add(
            b.arc.build(
              p[1],
              op.parameters['radius'] as double? ?? 1,
              math.pi,
              math.pi * 2,
            ),
          );
      case SketchToolType.polygon:
        final sides = op.parameters['sides'] as int? ?? p.length;
        if (sides < 3) {
          throw ArgumentError('Polygon needs at least three sides');
        }
        final center = p[0], radius = _distance(p[0], p[1]);
        final vertices = List.generate(
          sides,
          (i) => SketchVector(
            center.x + radius * math.cos(2 * math.pi * i / sides),
            center.y + radius * math.sin(2 * math.pi * i / sides),
          ),
        );
        for (var i = 0; i < sides; i++) {
          out.add(b.line.build(vertices[i], vertices[(i + 1) % sides]));
        }
      case SketchToolType.construction:
        out.add(b.construction.build(op.parameters));
      case SketchToolType.reference:
        out.add(b.reference.build(op.parameters));
      default:
        throw StateError('${op.tool.name} is an editing tool');
    }
  }

  void edit(
    SketchToolType tool,
    Iterable<String> ids, {
    SketchVector? delta,
    double value = 1,
    Map<String, dynamic> parameters = const {},
    bool confirmConstrained = false,
  }) {
    if (preview.active.isEmpty) {
      throw StateError('Editing requires preview before confirmation');
    }
    final op = preview.confirm(preview.active.last.id), targets = ids.toList();
    final affectedConstraints = constraints.constraints
        .where(
          (constraint) => constraint.references.any((reference) {
            final entityId = reference.replaceFirst(
              RegExp(r':(start|end|point)$'),
              '',
            );
            return targets.contains(entityId);
          }),
        )
        .toList();
    if (affectedConstraints.isNotEmpty && !confirmConstrained) {
      throw StateError(
        'Editing affects ${affectedConstraints.length} constraint(s); confirmation is required.',
      );
    }
    final historyBefore = sketch.engine.history.entries.length;
    sketch.engine.transaction('edit:${op.id}', () {
      if (tool == SketchToolType.join) {
        _join(targets);
        return;
      }
      if (tool == SketchToolType.fillet || tool == SketchToolType.chamfer) {
        _corner(
          tool,
          targets,
          value,
          autoTrim: parameters['autoTrim'] as bool? ?? true,
        );
        return;
      }
      for (final id in targets) {
        switch (tool) {
          case SketchToolType.move:
            sketch.move(id, delta ?? const SketchVector(0, 0));
            analytics.movements++;
          case SketchToolType.rotate:
            sketch.rotate(id, value, center: _vector(parameters['center']));
          case SketchToolType.scale:
            sketch.scale(
              id,
              value,
              factorY: (parameters['factorY'] as num?)?.toDouble(),
              center: _vector(parameters['center']),
            );
          case SketchToolType.stretch:
            _stretch(id, delta ?? const SketchVector(0, 0), parameters);
          case SketchToolType.mirror:
            sketch.mirror(
              id,
              axisStart: _vector(parameters['axisStart']),
              axisEnd: _vector(
                parameters['axisEnd'],
                fallback: const SketchVector(1, 0),
              ),
            );
          case SketchToolType.offset:
            _offset(id, value);
          case SketchToolType.trim:
            _trimOrExtend(id, _vector(parameters['point']), trim: true);
          case SketchToolType.extend:
            _trimOrExtend(id, _vector(parameters['point']), trim: false);
          case SketchToolType.breakEntity:
          case SketchToolType.split:
            _split(id, _vector(parameters['point']));
          case SketchToolType.delete:
            sketch.deleteEntity(id);
          case SketchToolType.convertConstruction:
            sketch.setConstruction(id, true);
            analytics.conversions++;
          case SketchToolType.convertReference:
            sketch.setReference(id, true);
            analytics.conversions++;
          case SketchToolType.lock:
            sketch.engine.modify(
              id,
              SketchHistoryAction.modify,
              (e) => e.locked = true,
            );
          case SketchToolType.unlock:
            final e = sketch.entity(id) ?? (throw StateError('Unknown entity'));
            e.locked = false;
            e.version++;
          default:
            throw StateError(
              'Editing tool is not geometrically implemented: ${tool.name}',
            );
        }
      }
    });
    graph.record(op.id, targets);
    _undoCounts.add(sketch.engine.history.entries.length - historyBefore);
    _redoCounts.clear();
    history.record(EditorHistoryAction.edit, op.id);
    analytics.editCount++;
  }

  bool undo() {
    if (_undoCounts.isEmpty) return false;
    final count = _undoCounts.removeLast();
    var changed = false;
    for (var i = 0; i < count; i++) {
      changed = sketch.engine.undo() || changed;
    }
    _redoCounts.add(count);
    analytics.undo++;
    history.record(EditorHistoryAction.undo, 'editor');
    return changed;
  }

  bool redo() {
    if (_redoCounts.isEmpty) return false;
    final count = _redoCounts.removeLast();
    var changed = false;
    for (var i = 0; i < count; i++) {
      changed = sketch.engine.redo() || changed;
    }
    _undoCounts.add(count);
    analytics.redo++;
    history.record(EditorHistoryAction.redo, 'editor');
    return changed;
  }

  void editCornerFeature(String id, double value) {
    final feature =
        sketch.entity(id) ?? (throw StateError('Unknown Sketch feature: $id'));
    final typeName = feature.metadata['featureType'] as String?;
    final tool = typeName == SketchToolType.fillet.name
        ? SketchToolType.fillet
        : typeName == SketchToolType.chamfer.name
        ? SketchToolType.chamfer
        : throw StateError('$id is not a Fillet or Chamfer feature.');
    final sources =
        (feature.metadata['sourceEntityIds'] as List?)
            ?.whereType<String>()
            .toList(growable: false) ??
        const <String>[];
    final historyBefore = sketch.engine.history.entries.length;
    featureUpdates.update(
      request: ParametricSolveRequest(
        first: '$id:definition',
        second: '$id:parameter',
        degreesOfFreedom: [
          ParametricDegreeOfFreedom('$id:definition', fixed: true),
          ParametricDegreeOfFreedom(
            '$id:parameter',
            parameterIds: {'$id:value'},
          ),
        ],
        parameters: [ParametricParameter('$id:value', value)],
        anchors: {'$id:definition'},
        priorities: [ParametricPriority('$id:parameter', 1)],
      ),
      apply: (_) => sketch.engine.transaction('edit-feature:$id', () {
        _corner(
          tool,
          sources,
          value,
          autoTrim: feature.metadata['autoTrim'] as bool? ?? true,
          featureId: id,
        );
        feature.metadata['featureValue'] = value;
      }),
    );
    _undoCounts.add(sketch.engine.history.entries.length - historyBefore);
    _redoCounts.clear();
    history.record(EditorHistoryAction.edit, id);
  }

  void trimIntersection(
    String firstId,
    SketchVector firstKeepPoint,
    String secondId,
    SketchVector secondKeepPoint,
  ) {
    _ensureEditableWithoutConstraints([firstId, secondId]);
    final first = sketch.entity(firstId), second = sketch.entity(secondId);
    if (first is! SketchLine || second is! SketchLine) {
      throw StateError('Intersection Trim requires two lines.');
    }
    final intersection = _lineIntersectionParameters(first, second);
    final firstKeep = _projectOnLine(
      firstKeepPoint,
      SketchVector.fromJson(first.parameters['start']),
      SketchVector.fromJson(first.parameters['end']),
    ).$2;
    final secondKeep = _projectOnLine(
      secondKeepPoint,
      SketchVector.fromJson(second.parameters['start']),
      SketchVector.fromJson(second.parameters['end']),
    ).$2;
    final historyBefore = sketch.engine.history.entries.length;
    sketch.engine.transaction('trim-intersection', () {
      _keepLineSide(first, intersection.$1, firstKeep, intersection.$2);
      _keepLineSide(second, intersection.$1, secondKeep, intersection.$3);
    });
    _recordExternalEdit('trim-intersection', historyBefore);
  }

  void trimEndpointToNearestIntersection(String id, SketchVector clickedPoint) {
    _ensureEditableWithoutConstraints([id]);
    final line = sketch.entity(id);
    if (line is! SketchLine) {
      throw StateError('Endpoint Trim requires a line.');
    }
    final start = SketchVector.fromJson(line.parameters['start']);
    final end = SketchVector.fromJson(line.parameters['end']);
    final clickedT = _projectOnLine(clickedPoint, start, end).$2;
    final removeStart = clickedT <= .5;
    (SketchVector, double)? best;
    for (final other in sketch.engine.entities.values.whereType<SketchLine>()) {
      if (other.id == id) continue;
      try {
        final candidate = _lineIntersectionParameters(line, other);
        final t = candidate.$2, otherT = candidate.$3;
        if (t <= 1e-8 || t >= 1 - 1e-8 || otherT < -1e-8 || otherT > 1 + 1e-8) {
          continue;
        }
        final distance = removeStart ? t : 1 - t;
        if (distance < 0 || (best != null && distance >= best.$2)) continue;
        best = (candidate.$1, distance);
      } catch (_) {
        // Parallel lines are not valid cutting boundaries.
      }
    }
    if (best == null) {
      throw StateError('No valid intersection was found for this endpoint.');
    }
    final historyBefore = sketch.engine.history.entries.length;
    sketch.engine.transaction('trim-endpoint', () {
      sketch.engine.modify(id, SketchHistoryAction.modify, (entity) {
        entity.parameters[removeStart ? 'start' : 'end'] = best!.$1.toJson();
        entity.refreshDerivedParameters();
      });
    });
    _recordExternalEdit('trim-endpoint', historyBefore);
  }

  void _keepLineSide(
    SketchLine line,
    SketchVector intersection,
    double keepT,
    double intersectionT,
  ) {
    sketch.engine.modify(line.id, SketchHistoryAction.modify, (entity) {
      entity.parameters[keepT < intersectionT ? 'end' : 'start'] = intersection
          .toJson();
      entity.refreshDerivedParameters();
    });
  }

  (SketchVector, double, double) _lineIntersectionParameters(
    SketchLine first,
    SketchLine second,
  ) {
    final a = SketchVector.fromJson(first.parameters['start']);
    final b = SketchVector.fromJson(first.parameters['end']);
    final c = SketchVector.fromJson(second.parameters['start']);
    final d = SketchVector.fromJson(second.parameters['end']);
    final abx = b.x - a.x, aby = b.y - a.y;
    final cdx = d.x - c.x, cdy = d.y - c.y;
    final determinant = abx * cdy - aby * cdx;
    if (determinant.abs() <= 1e-12) {
      throw StateError('The selected lines do not have a unique intersection.');
    }
    final acx = c.x - a.x, acy = c.y - a.y;
    final t = (acx * cdy - acy * cdx) / determinant;
    final u = (acx * aby - acy * abx) / determinant;
    return (SketchVector(a.x + abx * t, a.y + aby * t), t, u);
  }

  void _ensureEditableWithoutConstraints(Iterable<String> ids) {
    final targets = ids.toSet();
    final affected = constraints.constraints.where(
      (constraint) => constraint.references.any(
        (reference) => targets.contains(
          reference.replaceFirst(RegExp(r':(start|end|point)$'), ''),
        ),
      ),
    );
    if (affected.isNotEmpty) {
      throw StateError(
        'Trim is blocked by ${affected.first.type.name} '
        '(${affected.first.id}). Delete or suppress that constraint first.',
      );
    }
  }

  void _recordExternalEdit(String id, int historyBefore) {
    _undoCounts.add(sketch.engine.history.entries.length - historyBefore);
    _redoCounts.clear();
    history.record(EditorHistoryAction.edit, id);
    analytics.editCount++;
  }

  DegreesOfFreedom readDof() =>
      const DegreesOfFreedomReader().read(sketch, constraints, analytics);
  SketchQuality quality() {
    final q = const SketchQualityCalculator().calculate(sketch, constraints);
    analytics.sketchQuality = q.score;
    return q;
  }

  List<SketchRecommendation> recommendations() =>
      const SketchAdvisor().analyze(sketch, constraints, readDof());
  Future<void> persist() =>
      repository.save(history: history, graph: graph, analytics: analytics);

  SketchVector _vector(
    Object? value, {
    SketchVector fallback = const SketchVector(0, 0),
  }) => value == null ? fallback : SketchVector.fromJson(value);

  void _stretch(
    String id,
    SketchVector delta,
    Map<String, dynamic> parameters,
  ) {
    final entity =
        sketch.entity(id) ?? (throw StateError('Unknown entity: $id'));
    if (entity is! SketchLine) {
      throw StateError('Stretch currently requires a line endpoint.');
    }
    final endpoint = parameters['endpoint'] == 'start' ? 'start' : 'end';
    sketch.engine.modify(id, SketchHistoryAction.modify, (value) {
      final point = SketchVector.fromJson(value.parameters[endpoint]);
      value.parameters[endpoint] = (point + delta).toJson();
    });
  }

  void _offset(String id, double distance) {
    sketch.engine.modify(id, SketchHistoryAction.modify, (entity) {
      if (entity is SketchLine) {
        final start = SketchVector.fromJson(entity.parameters['start']);
        final end = SketchVector.fromJson(entity.parameters['end']);
        final dx = end.x - start.x, dy = end.y - start.y;
        final length = math.sqrt(dx * dx + dy * dy);
        if (length <= 1e-12) {
          throw StateError('Cannot offset a degenerate line.');
        }
        final shift = SketchVector(
          -dy / length * distance,
          dx / length * distance,
        );
        entity.parameters['start'] = (start + shift).toJson();
        entity.parameters['end'] = (end + shift).toJson();
      } else if (entity is SketchCircle || entity is SketchArc) {
        final radius =
            (entity.parameters['radius'] as num).toDouble() + distance;
        if (radius <= 0) throw StateError('Offset collapses the radius.');
        entity.parameters['radius'] = radius;
      } else if (entity is SketchEllipse) {
        final rx = (entity.parameters['radiusX'] as num).toDouble() + distance;
        final ry = (entity.parameters['radiusY'] as num).toDouble() + distance;
        if (rx <= 0 || ry <= 0) {
          throw StateError('Offset collapses the ellipse.');
        }
        entity.parameters['radiusX'] = rx;
        entity.parameters['radiusY'] = ry;
      } else if (entity is SketchSpline) {
        final points = (entity.parameters['points'] as List)
            .map(SketchVector.fromJson)
            .toList();
        if (points.length < 2) throw StateError('Spline has too few points.');
        final shifted = <SketchVector>[];
        for (var i = 0; i < points.length; i++) {
          final before = points[i == 0 ? i : i - 1];
          final after = points[i == points.length - 1 ? i : i + 1];
          final dx = after.x - before.x, dy = after.y - before.y;
          final length = math.sqrt(dx * dx + dy * dy);
          shifted.add(
            length <= 1e-12
                ? points[i]
                : points[i] +
                      SketchVector(
                        -dy / length * distance,
                        dx / length * distance,
                      ),
          );
        }
        entity.parameters['points'] = shifted
            .map((point) => point.toJson())
            .toList();
        entity.parameters.remove('sampledPoints');
      } else {
        throw StateError('Offset is unavailable for ${entity.type.name}.');
      }
    });
  }

  void _trimOrExtend(String id, SketchVector point, {required bool trim}) {
    final entity =
        sketch.entity(id) ?? (throw StateError('Unknown entity: $id'));
    if (entity is SketchLine) {
      final start = SketchVector.fromJson(entity.parameters['start']);
      final end = SketchVector.fromJson(entity.parameters['end']);
      final projected = _projectOnLine(point, start, end);
      if (trim && (projected.$2 <= 0 || projected.$2 >= 1)) {
        throw StateError('Trim point must lie inside the line.');
      }
      if (!trim && projected.$2 > 0 && projected.$2 < 1) {
        throw StateError('Extend point must lie outside the line.');
      }
      sketch.engine.modify(id, SketchHistoryAction.modify, (value) {
        value.parameters[_distance(start, projected.$1) <
                _distance(end, projected.$1)
            ? 'start'
            : 'end'] = projected.$1
            .toJson();
        value.refreshDerivedParameters();
      });
      return;
    }
    if (entity is SketchArc) {
      final center = SketchVector.fromJson(entity.parameters['center']);
      final angle = math.atan2(point.y - center.y, point.x - center.x);
      final start = (entity.parameters['startAngle'] as num).toDouble();
      final end = (entity.parameters['endAngle'] as num).toDouble();
      sketch.engine.modify(id, SketchHistoryAction.modify, (value) {
        value.parameters[_angleDistance(angle, start) <
                    _angleDistance(angle, end)
                ? 'startAngle'
                : 'endAngle'] =
            angle;
      });
      return;
    }
    if (entity is SketchSpline) {
      final points = (entity.parameters['points'] as List)
          .map(SketchVector.fromJson)
          .toList();
      if (points.length < 3) throw StateError('Spline has too few points.');
      if (trim) {
        final index = _nearestPointIndex(points, point);
        final left = points.sublist(0, index + 1);
        final right = points.sublist(index);
        points
          ..clear()
          ..addAll(left.length >= right.length ? left : right);
      } else if (_distance(point, points.first) <
          _distance(point, points.last)) {
        points.insert(0, point);
      } else {
        points.add(point);
      }
      sketch.engine.modify(id, SketchHistoryAction.modify, (value) {
        value.parameters['points'] = points
            .map((item) => item.toJson())
            .toList();
        value.parameters.remove('sampledPoints');
      });
      return;
    }
    throw StateError(
      '${trim ? 'Trim' : 'Extend'} is unavailable for ${entity.type.name}.',
    );
  }

  void _split(String id, SketchVector point) {
    final entity =
        sketch.entity(id) ?? (throw StateError('Unknown entity: $id'));
    if (entity is SketchLine) {
      final start = SketchVector.fromJson(entity.parameters['start']);
      final end = SketchVector.fromJson(entity.parameters['end']);
      final projected = _projectOnLine(point, start, end);
      if (projected.$2 <= 0 || projected.$2 >= 1) {
        throw StateError('Split point must lie inside the line.');
      }
      sketch.engine.modify(id, SketchHistoryAction.modify, (value) {
        value.parameters['end'] = projected.$1.toJson();
      });
      sketch.builders.line.build(projected.$1, end);
      return;
    }
    if (entity is SketchCircle || entity is SketchArc) {
      final center = SketchVector.fromJson(entity.parameters['center']);
      final radius = (entity.parameters['radius'] as num).toDouble();
      final angle = math.atan2(point.y - center.y, point.x - center.x);
      if (entity is SketchCircle) {
        sketch.deleteEntity(id);
        sketch.builders.arc.build(center, radius, angle, angle + math.pi);
        sketch.builders.arc.build(
          center,
          radius,
          angle + math.pi,
          angle + 2 * math.pi,
        );
      } else {
        final start = (entity.parameters['startAngle'] as num).toDouble();
        final end = (entity.parameters['endAngle'] as num).toDouble();
        if (!_angleWithin(angle, start, end)) {
          throw StateError('Split point must lie on the arc span.');
        }
        sketch.engine.modify(id, SketchHistoryAction.modify, (value) {
          value.parameters['endAngle'] = angle;
        });
        sketch.builders.arc.build(center, radius, angle, end);
      }
      return;
    }
    if (entity is SketchSpline) {
      final points = (entity.parameters['points'] as List)
          .map(SketchVector.fromJson)
          .toList();
      final index = _nearestPointIndex(points, point);
      if (index == 0 || index == points.length - 1) {
        throw StateError('Split point must lie inside the Spline.');
      }
      final left = points.sublist(0, index + 1);
      final right = points.sublist(index);
      sketch.engine.modify(id, SketchHistoryAction.modify, (value) {
        value.parameters['points'] = left.map((item) => item.toJson()).toList();
        value.parameters.remove('sampledPoints');
      });
      sketch.builders.spline.build(right);
      return;
    }
    throw StateError('Break/Split is unavailable for ${entity.type.name}.');
  }

  void _join(List<String> ids) {
    if (ids.length != 2) {
      throw StateError('Join requires exactly two entities.');
    }
    final first = sketch.entity(ids[0]), second = sketch.entity(ids[1]);
    if (first is SketchSpline && second is SketchSpline) {
      final firstPoints = (first.parameters['points'] as List)
          .map(SketchVector.fromJson)
          .toList();
      var secondPoints = (second.parameters['points'] as List)
          .map(SketchVector.fromJson)
          .toList();
      if (_distance(firstPoints.last, secondPoints.last) <
          _distance(firstPoints.last, secondPoints.first)) {
        secondPoints = secondPoints.reversed.toList();
      }
      if (_distance(firstPoints.last, secondPoints.first) > 1e-6) {
        throw StateError('Spline endpoints are not coincident.');
      }
      sketch.engine.modify(first.id, SketchHistoryAction.modify, (value) {
        value.parameters['points'] = [
          ...firstPoints,
          ...secondPoints.skip(1),
        ].map((item) => item.toJson()).toList();
        value.parameters.remove('sampledPoints');
      });
      sketch.deleteEntity(second.id);
      return;
    }
    if (first is! SketchLine || second is! SketchLine) {
      throw StateError('Join requires two collinear lines or two Splines.');
    }
    final a = SketchVector.fromJson(first.parameters['start']);
    final b = SketchVector.fromJson(first.parameters['end']);
    final c = SketchVector.fromJson(second.parameters['start']);
    final d = SketchVector.fromJson(second.parameters['end']);
    final pairs = [(a, c, b, d), (a, d, b, c), (b, c, a, d), (b, d, a, c)]
      ..sort(
        (left, right) => _distance(
          left.$1,
          left.$2,
        ).compareTo(_distance(right.$1, right.$2)),
      );
    final best = pairs.first;
    final firstDirection = b - a, secondDirection = d - c;
    final cross =
        firstDirection.x * secondDirection.y -
        firstDirection.y * secondDirection.x;
    if (cross.abs() > 1e-8 || _distance(best.$1, best.$2) > 1e-6) {
      throw StateError('Lines must be collinear and coincident to Join.');
    }
    sketch.engine.modify(first.id, SketchHistoryAction.modify, (value) {
      value.parameters['start'] = best.$3.toJson();
      value.parameters['end'] = best.$4.toJson();
    });
    sketch.deleteEntity(second.id);
  }

  void _corner(
    SketchToolType tool,
    List<String> ids,
    double value, {
    required bool autoTrim,
    String? featureId,
  }) {
    if (ids.length != 2 || value <= 0) {
      throw StateError('${tool.name} requires two lines and a positive value.');
    }
    final first = sketch.entity(ids[0]), second = sketch.entity(ids[1]);
    if (first is! SketchLine || second is! SketchLine) {
      throw StateError('${tool.name} requires two lines.');
    }
    final a = SketchVector.fromJson(first.parameters['start']);
    final b = SketchVector.fromJson(first.parameters['end']);
    final c = SketchVector.fromJson(second.parameters['start']);
    final d = SketchVector.fromJson(second.parameters['end']);
    final pairs =
        [
          (a, c, 'start', 'start'),
          (a, d, 'start', 'end'),
          (b, c, 'end', 'start'),
          (b, d, 'end', 'end'),
        ]..sort(
          (left, right) => _distance(
            left.$1,
            left.$2,
          ).compareTo(_distance(right.$1, right.$2)),
        );
    final corner = _lineIntersection(a, b, c, d);
    SketchVector direction(SketchVector far) {
      final dx = far.x - corner.x, dy = far.y - corner.y;
      final length = math.sqrt(dx * dx + dy * dy);
      if (length <= 1e-12) {
        throw StateError('Corner contains a degenerate line.');
      }
      return SketchVector(dx / length, dy / length);
    }

    final far1 = pairs.first.$3 == 'start' ? b : a;
    final far2 = pairs.first.$4 == 'start' ? d : c;
    final u1 = direction(far1), u2 = direction(far2);
    final dot = (u1.x * u2.x + u1.y * u2.y).clamp(-1.0, 1.0);
    final theta = math.acos(dot);
    if (theta <= 1e-6 || (math.pi - theta).abs() <= 1e-6) {
      throw StateError('${tool.name} requires two non-collinear lines.');
    }
    final insetDistance = tool == SketchToolType.fillet
        ? value / math.tan(theta / 2)
        : value;
    if (_distance(corner, far1) <= insetDistance ||
        _distance(corner, far2) <= insetDistance) {
      throw StateError('Corner distance exceeds line length.');
    }
    final p1 = SketchVector(
      corner.x + u1.x * insetDistance,
      corner.y + u1.y * insetDistance,
    );
    final p2 = SketchVector(
      corner.x + u2.x * insetDistance,
      corner.y + u2.y * insetDistance,
    );
    if (autoTrim) {
      sketch.engine.modify(
        first.id,
        SketchHistoryAction.modify,
        (entity) => entity.parameters[pairs.first.$3] = p1.toJson(),
      );
      sketch.engine.modify(
        second.id,
        SketchHistoryAction.modify,
        (entity) => entity.parameters[pairs.first.$4] = p2.toJson(),
      );
      first.refreshDerivedParameters();
      second.refreshDerivedParameters();
    }
    if (tool == SketchToolType.chamfer) {
      if (featureId == null) {
        sketch.builders.line.build(p1, p2);
      } else {
        sketch.engine.modify(featureId, SketchHistoryAction.modify, (entity) {
          entity.parameters['start'] = p1.toJson();
          entity.parameters['end'] = p2.toJson();
          entity.refreshDerivedParameters();
        });
      }
    } else {
      final bisectorX = u1.x + u2.x, bisectorY = u1.y + u2.y;
      final bisectorLength = math.sqrt(
        bisectorX * bisectorX + bisectorY * bisectorY,
      );
      final centerDistance = value / math.sin(theta / 2);
      final center = SketchVector(
        corner.x + bisectorX / bisectorLength * centerDistance,
        corner.y + bisectorY / bisectorLength * centerDistance,
      );
      final startAngle = math.atan2(p1.y - center.y, p1.x - center.x);
      final endAngle = math.atan2(p2.y - center.y, p2.x - center.x);
      if (featureId == null) {
        sketch.builders.arc.build(center, value, startAngle, endAngle);
      } else {
        sketch.engine.modify(featureId, SketchHistoryAction.modify, (entity) {
          entity.parameters['center'] = center.toJson();
          entity.parameters['radius'] = value;
          entity.parameters['startAngle'] = startAngle;
          entity.parameters['endAngle'] = endAngle;
        });
      }
    }
  }

  double _distance(SketchVector a, SketchVector b) =>
      math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

  (SketchVector, double) _projectOnLine(
    SketchVector point,
    SketchVector start,
    SketchVector end,
  ) {
    final dx = end.x - start.x, dy = end.y - start.y;
    final length2 = dx * dx + dy * dy;
    if (length2 <= 1e-24) throw StateError('Line is degenerate.');
    final t = ((point.x - start.x) * dx + (point.y - start.y) * dy) / length2;
    return (SketchVector(start.x + dx * t, start.y + dy * t), t);
  }

  SketchVector _lineIntersection(
    SketchVector a,
    SketchVector b,
    SketchVector c,
    SketchVector d,
  ) {
    final abx = b.x - a.x, aby = b.y - a.y;
    final cdx = d.x - c.x, cdy = d.y - c.y;
    final determinant = abx * cdy - aby * cdx;
    if (determinant.abs() <= 1e-12) {
      throw StateError('Fillet/Chamfer requires intersecting lines.');
    }
    final acx = c.x - a.x, acy = c.y - a.y;
    final t = (acx * cdy - acy * cdx) / determinant;
    return SketchVector(a.x + abx * t, a.y + aby * t);
  }

  int _nearestPointIndex(List<SketchVector> points, SketchVector point) {
    var best = 0;
    var distance = double.infinity;
    for (var index = 0; index < points.length; index++) {
      final candidate = _distance(points[index], point);
      if (candidate < distance) {
        best = index;
        distance = candidate;
      }
    }
    return best;
  }

  double _angleDistance(double left, double right) {
    final value = (left - right).abs() % (2 * math.pi);
    return math.min(value, 2 * math.pi - value);
  }

  bool _angleWithin(double value, double start, double end) {
    double normalized(double angle) =>
        (angle % (2 * math.pi) + 2 * math.pi) % (2 * math.pi);
    final angle = normalized(value);
    final first = normalized(start), last = normalized(end);
    return first <= last
        ? angle > first && angle < last
        : angle > first || angle < last;
  }
}
