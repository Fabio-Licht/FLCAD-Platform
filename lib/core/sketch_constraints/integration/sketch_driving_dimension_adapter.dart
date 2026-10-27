import 'dart:math' as math;

import '../../parametric_solver/parametric_solver.dart';
import '../../sketch_engine/api/sketch_engine_api.dart';
import '../../sketch_engine/entities/sketch_entities.dart';
import '../../sketch_engine/history/sketch_history.dart';
import '../../sketch_engine/models/sketch_models.dart';
import 'arc_radius_edit_planner.dart';
import '../models/constraint_models.dart';

class SketchDrivingDimensionSolution {
  const SketchDrivingDimensionSolution(
    this.anchorReference,
    this.movedReferences,
  );
  final String? anchorReference;
  final Set<String> movedReferences;
}

/// Applies a driving value without ever separating coincident endpoint groups.
/// It is deliberately deterministic: the explicit anchor wins, then a fixed
/// endpoint, then the start/centre convention.
class SketchDrivingDimensionAdapter {
  SketchDrivingDimensionAdapter({
    this.connectionTolerance = 1e-4,
    this.parametricSolver = const ParametricPropagationSolver(),
  });
  final double connectionTolerance;
  final ParametricPropagationSolver parametricSolver;

  /// Last pure radius plan produced by [apply], exposed for command feedback.
  /// It is diagnostic state only and is not part of the Sketch history.
  ArcRadiusEditPlan? lastArcRadiusEditPlan;

  ArcRadiusEditPlan? planRadiusDimension({
    required SketchEngineApi sketch,
    required Iterable<SketchConstraint> constraints,
    required SketchDimensionType type,
    required List<String> references,
    required double value,
    String? ignoredConstraintId,
  }) {
    if (references.isEmpty ||
        (type != SketchDimensionType.radius &&
            type != SketchDimensionType.diameter)) {
      return null;
    }
    final entityId = _entityId(references.first);
    final entity = sketch.entity(entityId);
    if (entity is! SketchArc) return null;
    final activeConstraints = constraints.where(
      (constraint) => constraint.id != ignoredConstraintId,
    );
    return _planArcRadiusEdit(
      sketch: sketch,
      constraints: activeConstraints,
      arc: entity,
      radius: type == SketchDimensionType.diameter ? value / 2 : value,
    );
  }

  SketchDrivingDimensionSolution apply({
    required SketchEngineApi sketch,
    required Iterable<SketchConstraint> constraints,
    required SketchDimensionType type,
    required List<String> references,
    required double value,
    String? anchorReference,
    double? orientationSign,
    bool allowAdjacentEndpointUpdates = false,
    ArcRadiusEditPlan? expectedRadiusPlan,
    bool deferDirectionalConstraints = false,
  }) {
    lastArcRadiusEditPlan = null;
    if (!value.isFinite ||
        (value <= 0 &&
            !const {
              SketchDimensionType.ordinateX,
              SketchDimensionType.ordinateY,
            }.contains(type))) {
      throw StateError('A driving dimension must be greater than zero.');
    }
    if (references.isEmpty) throw StateError('Dimension has no references.');
    final entity =
        sketch.entity(_entityId(references.first)) ??
        (throw StateError('Dimension references unknown geometry.'));
    final fixed = _fixedReferences(constraints);
    final groups = _coincidentGroups(sketch, constraints);
    final moved = <String>{};

    void moveGroup(String reference, SketchVector point) {
      final group = groups[reference] ?? {reference};
      final blocker = group.where(fixed.contains).firstOrNull;
      if (blocker != null) {
        throw StateError('Sketch over constrained: $blocker is fixed.');
      }
      for (final member in group) {
        _setEndpoint(sketch, member, point);
        moved.add(member);
      }
    }

    String? selectedAnchor = anchorReference;
    if (const {
          SketchDimensionType.ordinateX,
          SketchDimensionType.ordinateY,
        }.contains(type) &&
        references.length == 1) {
      final reference = references.single;
      final point = _endpoint(sketch, reference);
      if (point == null) {
        throw StateError(
          'A coordinate dimension requires one explicit point or endpoint.',
        );
      }
      moveGroup(
        reference,
        type == SketchDimensionType.ordinateX
            ? SketchVector(value, point.y, point.z)
            : SketchVector(point.x, value, point.z),
      );
      selectedAnchor = reference;
    } else if (const {
          SketchDimensionType.linear,
          SketchDimensionType.horizontal,
          SketchDimensionType.vertical,
        }.contains(type) &&
        references.length == 2) {
      final firstReference = references[0];
      final secondReference = references[1];
      final firstPoint = _endpoint(sketch, firstReference);
      final secondPoint = _endpoint(sketch, secondReference);
      if (firstPoint == null || secondPoint == null) {
        throw StateError(
          'A point-to-point dimension requires two explicit points or endpoints.',
        );
      }
      final allReferences = <String>{
        firstReference,
        secondReference,
        ...groups.values.expand((members) => members),
      };
      final relationKeys = <String>{};
      final dependencies = <ParametricDependency>[];
      for (final group in groups.values) {
        final key = (group.toList()..sort()).join('|');
        if (relationKeys.add(key) && group.length > 1) {
          dependencies.add(ParametricDependency('connection:$key', group));
        }
      }
      late final ParametricMotionPlan plan;
      try {
        plan = parametricSolver.solve(
          ParametricSolveRequest(
            first: firstReference,
            second: secondReference,
            degreesOfFreedom: [
              for (final reference in allReferences)
                ParametricDegreeOfFreedom(
                  reference,
                  fixed: fixed.contains(reference),
                ),
            ],
            parameters: [ParametricParameter('dimension:value', value)],
            dependencies: dependencies,
            anchors: fixed,
            preferredAnchor: selectedAnchor ?? firstReference,
          ),
        );
      } on ParametricSolveConflict catch (conflict) {
        throw StateError(conflict.message);
      }
      selectedAnchor = plan.anchor;
      final movingReference = plan.moving;
      final anchor = _endpoint(sketch, selectedAnchor)!;
      final moving = _endpoint(sketch, movingReference)!;
      final delta = moving - anchor;
      final currentLength = math.sqrt(delta.x * delta.x + delta.y * delta.y);
      if (type == SketchDimensionType.linear && currentLength <= 1e-12) {
        throw StateError(
          'A point-to-point dimension is undefined for coincident points.',
        );
      }
      final target = switch (type) {
        SketchDimensionType.horizontal => SketchVector(
          anchor.x + (delta.x < 0 ? -value : value),
          moving.y,
          moving.z,
        ),
        SketchDimensionType.vertical => SketchVector(
          moving.x,
          anchor.y + (delta.y < 0 ? -value : value),
          moving.z,
        ),
        _ => SketchVector(
          anchor.x + delta.x * value / currentLength,
          anchor.y + delta.y * value / currentLength,
          anchor.z + delta.z * value / currentLength,
        ),
      };
      moveGroup(movingReference, target);
    } else if (type == SketchDimensionType.parallelDistance &&
        references.length == 2) {
      final first = sketch.entity(_entityId(references[0]));
      final second = sketch.entity(_entityId(references[1]));
      if (first is! SketchLine || second is! SketchLine) {
        throw StateError('A line distance requires two lines.');
      }
      final firstStart = _endpoint(sketch, '${first.id}:start')!;
      final firstEnd = _endpoint(sketch, '${first.id}:end')!;
      final secondStart = _endpoint(sketch, '${second.id}:start')!;
      final secondEnd = _endpoint(sketch, '${second.id}:end')!;
      final direction = firstEnd - firstStart;
      final length = math.sqrt(
        direction.x * direction.x + direction.y * direction.y,
      );
      if (length <= 1e-12) {
        throw StateError('The reference line is degenerate.');
      }
      final secondDirection = secondEnd - secondStart;
      final cross =
          direction.x * secondDirection.y - direction.y * secondDirection.x;
      if (cross.abs() >
          connectionTolerance *
              length *
              math.max(
                1.0,
                math.sqrt(
                  secondDirection.x * secondDirection.x +
                      secondDirection.y * secondDirection.y,
                ),
              )) {
        throw StateError(
          'Distance between lines requires parallel lines. Use Angle between lines first.',
        );
      }
      final normal = SketchVector(-direction.y / length, direction.x / length);
      final current =
          (secondStart - firstStart).x * normal.x +
          (secondStart - firstStart).y * normal.y;
      final sign = current.abs() <= connectionTolerance ? 1.0 : current.sign;
      final delta = sign * value - current;
      moveGroup('${second.id}:start', secondStart + normal.scale(delta));
      moveGroup('${second.id}:end', secondEnd + normal.scale(delta));
      selectedAnchor ??= first.id;
    } else if (type == SketchDimensionType.angular && references.length == 2) {
      final referenceLine = sketch.entity(_entityId(references[0]));
      final targetLine = sketch.entity(_entityId(references[1]));
      if (referenceLine is! SketchLine || targetLine is! SketchLine) {
        throw StateError('An angular dimension requires two lines.');
      }
      final startReference = '${targetLine.id}:start';
      final endReference = '${targetLine.id}:end';
      if (fixed.contains(startReference) && fixed.contains(endReference)) {
        throw StateError('Sketch over constrained: target line is fixed.');
      }
      selectedAnchor ??= fixed.contains(endReference)
          ? endReference
          : startReference;
      if (selectedAnchor != startReference && selectedAnchor != endReference) {
        throw StateError(
          'Angular dimension anchor must belong to target line.',
        );
      }
      final movingReference = selectedAnchor == startReference
          ? endReference
          : startReference;
      final anchor = _endpoint(sketch, selectedAnchor)!;
      final moving = _endpoint(sketch, movingReference)!;
      final delta = moving - anchor;
      final length = math.sqrt(delta.x * delta.x + delta.y * delta.y);
      final referenceStart = _endpoint(sketch, '${referenceLine.id}:start')!;
      final referenceEnd = _endpoint(sketch, '${referenceLine.id}:end')!;
      final referenceAngle = math.atan2(
        referenceEnd.y - referenceStart.y,
        referenceEnd.x - referenceStart.x,
      );
      final targetAngle =
          referenceAngle +
          (orientationSign ?? 1) * value * math.pi / 180 +
          (selectedAnchor == endReference ? math.pi : 0);
      moveGroup(
        movingReference,
        SketchVector(
          anchor.x + length * math.cos(targetAngle),
          anchor.y + length * math.sin(targetAngle),
          moving.z,
        ),
      );
    } else if (entity is SketchLine &&
        (type == SketchDimensionType.linear ||
            type == SketchDimensionType.angular)) {
      final startRef = '${entity.id}:start', endRef = '${entity.id}:end';
      final allReferences = groups.values.expand((value) => value).toSet();
      final relationKeys = <String>{};
      final dependencies = <ParametricDependency>[];
      for (final group in groups.values) {
        final key = (group.toList()..sort()).join('|');
        if (relationKeys.add(key) && group.length > 1) {
          dependencies.add(ParametricDependency('connection:$key', group));
        }
      }
      late final ParametricMotionPlan plan;
      try {
        plan = parametricSolver.solve(
          ParametricSolveRequest(
            first: startRef,
            second: endRef,
            degreesOfFreedom: [
              for (final reference in allReferences)
                ParametricDegreeOfFreedom(
                  reference,
                  fixed: fixed.contains(reference),
                ),
            ],
            parameters: [ParametricParameter('dimension:value', value)],
            dependencies: dependencies,
            anchors: fixed,
            preferredAnchor: selectedAnchor,
          ),
        );
      } on ParametricSolveConflict catch (conflict) {
        throw StateError(conflict.message);
      }
      selectedAnchor = plan.anchor;
      final movingRef = plan.moving;
      final anchor = _endpoint(sketch, selectedAnchor)!;
      final moving = _endpoint(sketch, movingRef)!;
      final delta = moving - anchor;
      final currentLength = math.sqrt(delta.x * delta.x + delta.y * delta.y);
      final angle = type == SketchDimensionType.angular
          ? value * math.pi / 180 + (selectedAnchor == endRef ? math.pi : 0)
          : math.atan2(delta.y, delta.x);
      final length = type == SketchDimensionType.linear ? value : currentLength;
      moveGroup(
        movingRef,
        SketchVector(
          anchor.x + length * math.cos(angle),
          anchor.y + length * math.sin(angle),
          anchor.z,
        ),
      );
    } else if ((entity is SketchCircle || entity is SketchArc) &&
        (type == SketchDimensionType.radius ||
            type == SketchDimensionType.diameter)) {
      if (fixed.contains(entity.id) || fixed.contains('${entity.id}:center')) {
        throw StateError('Sketch over constrained: ${entity.id} is fixed.');
      }
      final radius = type == SketchDimensionType.diameter ? value / 2 : value;
      if (entity is SketchCircle) {
        sketch.engine.modify(entity.id, SketchHistoryAction.modify, (item) {
          item.parameters['radius'] = radius;
        });
      } else if (entity is SketchArc) {
        if (entity.locked) {
          throw StateError('Sketch over constrained: ${entity.id} is fixed.');
        }
        final computedPlan = _planArcRadiusEdit(
          sketch: sketch,
          constraints: constraints,
          arc: entity,
          radius: radius,
        );
        if (expectedRadiusPlan != null &&
            !computedPlan.equivalentTo(expectedRadiusPlan)) {
          throw StateError(
            'O preview da ediÃ§Ã£o do raio ficou obsoleto; gere um novo preview.',
          );
        }
        final plan = expectedRadiusPlan ?? computedPlan;
        lastArcRadiusEditPlan = plan;
        if (!plan.accepted || plan.arc == null) {
          throw StateError(
            plan.diagnostic ??
                'Não foi possível planejar a edição segura do raio.',
          );
        }
        if (plan.hasExternalUpdates && !allowAdjacentEndpointUpdates) {
          throw ArcRadiusEditConfirmationRequired(plan);
        }
        final geometry = plan.arc!;
        sketch.updateParameters(entity.id, {
          'centerX': geometry.center.x,
          'centerY': geometry.center.y,
          'radius': geometry.radius,
          'startAngleDegrees': geometry.startAngle * 180 / math.pi,
          'endAngleDegrees': geometry.endAngle * 180 / math.pi,
        });
        for (final entry in plan.endpointUpdates.entries) {
          sketch.updateParameters(entry.key, entry.value);
          for (final endpoint in const ['start', 'end']) {
            if (entry.value.containsKey('${endpoint}X')) {
              moved.add('${entry.key}:$endpoint');
            }
          }
        }
        moved.add(entity.id);
      }
      selectedAnchor ??= '${entity.id}:center';
    } else {
      throw StateError(
        '${type.name} is incompatible with ${entity.type.name}.',
      );
    }
    _validateGeometricConstraints(
      sketch,
      constraints,
      validateDirectional: !deferDirectionalConstraints,
    );
    return SketchDrivingDimensionSolution(selectedAnchor, moved);
  }

  ArcRadiusEditPlan _planArcRadiusEdit({
    required SketchEngineApi sketch,
    required Iterable<SketchConstraint> constraints,
    required SketchArc arc,
    required double radius,
  }) {
    final activeEntities = sketch.engine.activeSketch.entityIds
        .map(sketch.entity)
        .whereType<SketchEntity>();
    return const ArcRadiusEditPlanner().plan(
      arc: arc,
      radius: radius,
      context: ArcRadiusEditContext(
        entities: activeEntities,
        constraints: constraints,
        connectionTolerance: connectionTolerance,
      ),
    );
  }

  Set<String> _fixedReferences(Iterable<SketchConstraint> constraints) {
    final result = <String>{};
    for (final c in constraints) {
      if (!c.enabled ||
          c.suppressed ||
          (c.type != SketchConstraintType.fixed &&
              c.type != SketchConstraintType.lock)) {
        continue;
      }
      for (final reference in c.references) {
        result.add(reference);
        if (!RegExp(r':(start|end|center)$').hasMatch(reference)) {
          result.addAll([
            '$reference:start',
            '$reference:end',
            '$reference:center',
          ]);
        }
      }
    }
    return result;
  }

  Map<String, Set<String>> _coincidentGroups(
    SketchEngineApi sketch,
    Iterable<SketchConstraint> constraints,
  ) {
    final refs = <String, SketchVector>{};
    for (final entity in sketch.engine.entities.values) {
      if (entity is SketchLine) {
        refs['${entity.id}:start'] = SketchVector.fromJson(
          entity.parameters['start'],
        );
        refs['${entity.id}:end'] = SketchVector.fromJson(
          entity.parameters['end'],
        );
      } else if (entity is SketchArc) {
        refs['${entity.id}:start'] = _endpoint(sketch, '${entity.id}:start')!;
        refs['${entity.id}:end'] = _endpoint(sketch, '${entity.id}:end')!;
      } else if (entity is SketchPoint) {
        refs[entity.id] = SketchVector.fromJson(entity.parameters['point']);
      }
    }
    final adjacency = {
      for (final ref in refs.keys) ref: <String>{ref},
    };
    final entries = refs.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      for (var j = i + 1; j < entries.length; j++) {
        if (_distance(entries[i].value, entries[j].value) <=
            connectionTolerance) {
          adjacency[entries[i].key]!.add(entries[j].key);
          adjacency[entries[j].key]!.add(entries[i].key);
        }
      }
    }
    for (final c in constraints.where(
      (c) =>
          c.enabled &&
          !c.suppressed &&
          c.type == SketchConstraintType.coincident,
    )) {
      if (c.references.length < 2) continue;
      adjacency
          .putIfAbsent(c.references[0], () => {c.references[0]})
          .add(c.references[1]);
      adjacency
          .putIfAbsent(c.references[1], () => {c.references[1]})
          .add(c.references[0]);
    }
    final result = <String, Set<String>>{};
    for (final ref in adjacency.keys) {
      final group = <String>{}, queue = <String>[ref];
      while (queue.isNotEmpty) {
        final item = queue.removeLast();
        if (!group.add(item)) continue;
        queue.addAll(adjacency[item] ?? const <String>{});
      }
      result[ref] = group;
    }
    return result;
  }

  void _validateGeometricConstraints(
    SketchEngineApi sketch,
    Iterable<SketchConstraint> constraints, {
    bool validateDirectional = true,
  }) {
    const epsilon = 1e-6;
    for (final c in constraints.where((c) => c.enabled && !c.suppressed)) {
      if (!validateDirectional &&
          (c.type == SketchConstraintType.horizontal ||
              c.type == SketchConstraintType.vertical ||
              c.type == SketchConstraintType.parallel ||
              c.type == SketchConstraintType.perpendicular)) {
        continue;
      }
      final entities = c.references
          .map((r) => sketch.entity(_entityId(r)))
          .toList();
      bool valid = true;
      if (c.type == SketchConstraintType.coincident &&
          c.references.length > 1) {
        valid =
            _distance(
              _endpoint(sketch, c.references[0])!,
              _endpoint(sketch, c.references[1])!,
            ) <=
            connectionTolerance;
      } else if ((c.type == SketchConstraintType.horizontal ||
              c.type == SketchConstraintType.vertical) &&
          entities.first is SketchLine) {
        final line = entities.first as SketchLine;
        final a = SketchVector.fromJson(line.parameters['start']),
            b = SketchVector.fromJson(line.parameters['end']);
        valid = c.type == SketchConstraintType.horizontal
            ? (a.y - b.y).abs() <= epsilon
            : (a.x - b.x).abs() <= epsilon;
      } else if (c.type == SketchConstraintType.concentric &&
          entities.length > 1) {
        final a = SketchVector.fromJson(entities[0]!.parameters['center']);
        final b = SketchVector.fromJson(entities[1]!.parameters['center']);
        valid = _distance(a, b) <= epsilon;
      } else if ((c.type == SketchConstraintType.parallel ||
              c.type == SketchConstraintType.perpendicular) &&
          entities.length > 1 &&
          entities[0] is SketchLine &&
          entities[1] is SketchLine) {
        double angle(SketchEntity entity) =>
            (entity.parameters['angleDegrees'] as num).toDouble() *
            math.pi /
            180;
        final difference = angle(entities[1]!) - angle(entities[0]!);
        valid = c.type == SketchConstraintType.parallel
            ? math.sin(difference).abs() <= epsilon
            : math.cos(difference).abs() <= epsilon;
      } else if (c.type == SketchConstraintType.tangent &&
          entities.length > 1) {
        final line = entities.whereType<SketchLine>().firstOrNull;
        final radial = entities
            .where((e) => e is SketchCircle || e is SketchArc)
            .firstOrNull;
        if (line != null && radial != null) {
          final a = SketchVector.fromJson(line.parameters['start']);
          final b = SketchVector.fromJson(line.parameters['end']);
          final center = SketchVector.fromJson(radial.parameters['center']);
          final radius = (radial.parameters['radius'] as num).toDouble();
          final dx = b.x - a.x, dy = b.y - a.y;
          final length = math.sqrt(dx * dx + dy * dy);
          final distance = length <= epsilon
              ? double.infinity
              : ((center.x - a.x) * dy - (center.y - a.y) * dx).abs() / length;
          valid = (distance - radius).abs() <= epsilon;
        }
      }
      if (!valid) {
        throw StateError('${c.type.name} (${c.id}) prevents this dimension.');
      }
    }
  }

  SketchVector? _endpoint(SketchEngineApi sketch, String reference) {
    final entity = sketch.entity(_entityId(reference));
    if (entity is SketchLine) {
      return SketchVector.fromJson(
        entity.parameters[reference.endsWith(':start') ? 'start' : 'end'],
      );
    }
    if (entity is SketchArc) {
      final center = SketchVector.fromJson(entity.parameters['center']);
      final radius = (entity.parameters['radius'] as num).toDouble();
      final angle =
          (entity.parameters[reference.endsWith(':start')
                      ? 'startAngle'
                      : 'endAngle']
                  as num)
              .toDouble();
      return SketchVector(
        center.x + radius * math.cos(angle),
        center.y + radius * math.sin(angle),
      );
    }
    if (entity is SketchPoint) {
      return SketchVector.fromJson(entity.parameters['point']);
    }
    return null;
  }

  void _setEndpoint(
    SketchEngineApi sketch,
    String reference,
    SketchVector point,
  ) {
    final entity = sketch.entity(_entityId(reference));
    if (entity is SketchLine) {
      sketch.engine.modify(entity.id, SketchHistoryAction.modify, (item) {
        item.parameters[reference.endsWith(':start') ? 'start' : 'end'] = point
            .toJson();
      });
    } else if (entity is SketchArc) {
      final center = SketchVector.fromJson(entity.parameters['center']);
      sketch.engine.modify(entity.id, SketchHistoryAction.modify, (item) {
        item.parameters[reference.endsWith(':start')
            ? 'startAngle'
            : 'endAngle'] = math.atan2(
          point.y - center.y,
          point.x - center.x,
        );
      });
    } else if (entity is SketchPoint) {
      sketch.engine.modify(entity.id, SketchHistoryAction.modify, (item) {
        item.parameters['point'] = point.toJson();
      });
    }
  }

  String _entityId(String reference) =>
      reference.replaceFirst(RegExp(r':(start|end|center)$'), '');
  double _distance(SketchVector a, SketchVector b) =>
      math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
}
