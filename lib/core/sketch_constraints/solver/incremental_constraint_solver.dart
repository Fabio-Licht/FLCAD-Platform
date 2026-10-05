import 'dart:math' as math;

import '../../sketch_engine/entities/sketch_entities.dart';
import '../../sketch_engine/models/sketch_models.dart';
import '../diagnostics/constraint_diagnostics.dart';
import '../graph/constraint_graph.dart';
import '../models/constraint_models.dart';

/// Deterministic planar projection solver used by the professional Sketcher.
///
/// The first reference is the trusted anchor and the following reference is
/// corrected. Repeated sweeps allow connected relations to converge while a
/// finite tolerance and iteration ceiling keep malformed sketches safe.
class IncrementalConstraintSolver {
  IncrementalConstraintSolver({this.tolerance = 1e-8, this.maximumSweeps = 16});

  final double tolerance;
  final int maximumSweeps;
  final Set<String> _dirty = {};

  Set<String> get dirty => Set.unmodifiable(_dirty);

  void markDirty(String id, ConstraintGraph dependencies) {
    _dirty
      ..add(id)
      ..addAll(dependencies.downstream(id));
  }

  void clear() => _dirty.clear();

  Future<ConstraintSolveResult> solve({
    required Map<String, SketchConstraint> constraints,
    required Map<String, SketchEntity> entities,
    required ConstraintGraphSet graphs,
    Iterable<String>? only,
  }) async {
    final watch = Stopwatch()..start();
    final requested = only?.toSet();
    final queue =
        constraints.values
            .where(
              (constraint) =>
                  requested == null ||
                  requested.contains(constraint.id) ||
                  _dirty.contains(constraint.id),
            )
            .toList()
          ..sort((a, b) {
            final fixedOrder = (_isFixing(b) ? 1 : 0).compareTo(
              _isFixing(a) ? 1 : 0,
            );
            return fixedOrder != 0
                ? fixedOrder
                : b.priority.compareTo(a.priority);
          });
    final diagnostics = <ConstraintDiagnostic>[];
    final candidates = <SketchConstraint>[];
    final solved = <String>{};
    final signatures = <String, String>{};
    final drivingValues = <String, SketchConstraint>{};
    final directional = <String, SketchConstraintType>{};
    final projectionFailures = <String, _ConstraintProjectionFailure>{};
    final fixed = _fixedReferences(constraints.values, entities);

    for (final constraint in queue) {
      constraint.diagnostics.clear();
      if (!constraint.enabled || constraint.suppressed) continue;
      final validation = _validate(constraint, entities);
      if (validation != null) {
        constraint.status =
            validation.kind == ConstraintDiagnosticKind.missingReference
            ? ConstraintStatus.invalid
            : ConstraintStatus.unsatisfied;
        diagnostics.add(validation);
        constraint.diagnostics.add(validation.message);
        continue;
      }
      final duplicate = signatures[constraint.signature];
      if (duplicate != null) {
        constraint.status = ConstraintStatus.conflicting;
        final diagnostic = ConstraintDiagnostic(
          ConstraintDiagnosticKind.duplicate,
          'Duplicate constraint',
          constraintIds: [duplicate, constraint.id],
          suggestedFix: 'Delete the duplicate constraint',
        );
        diagnostics.add(diagnostic);
        constraint.diagnostics.add(diagnostic.message);
        continue;
      }
      signatures[constraint.signature] = constraint.id;
      if (constraint.value != null) {
        final key =
            '${constraint.type.name}:${constraint.references.join('|')}';
        final prior = drivingValues[key];
        if (prior != null &&
            (prior.value! - constraint.value!).abs() > tolerance) {
          constraint.status = ConstraintStatus.conflicting;
          final diagnostic = ConstraintDiagnostic(
            ConstraintDiagnosticKind.conflict,
            'Conflicting driving values ${prior.value} and '
            '${constraint.value}',
            constraintIds: [prior.id, constraint.id],
            suggestedFix:
                'Suppress or change the lower-priority driving constraint',
          );
          diagnostics.add(diagnostic);
          constraint.diagnostics.add(diagnostic.message);
          continue;
        }
        drivingValues[key] = constraint;
      }
      if ((constraint.type == SketchConstraintType.horizontal ||
              constraint.type == SketchConstraintType.vertical) &&
          constraint.references.isNotEmpty) {
        final entity = _entityId(constraint.references.first);
        final prior = directional[entity];
        if (prior != null && prior != constraint.type) {
          constraint.status = ConstraintStatus.overdefined;
          final diagnostic = ConstraintDiagnostic(
            ConstraintDiagnosticKind.overConstraint,
            'Horizontal and vertical constraints overdefine the same entity',
            constraintIds: [constraint.id],
            suggestedFix: 'Suppress one directional constraint',
          );
          diagnostics.add(diagnostic);
          constraint.diagnostics.add(diagnostic.message);
          continue;
        }
        directional[entity] = constraint.type;
      }
      candidates.add(constraint);
    }

    var sweep = 0;
    var changed = true;
    while (changed && sweep < maximumSweeps) {
      changed = false;
      sweep++;
      for (final constraint in candidates) {
        try {
          changed = _apply(constraint, entities, fixed) || changed;
          solved.add(constraint.id);
          projectionFailures.remove(constraint.id);
        } on _ConstraintProjectionFailure catch (failure) {
          projectionFailures[constraint.id] = failure;
          solved.remove(constraint.id);
        }
      }
    }

    for (final entry in projectionFailures.entries) {
      final constraint = constraints[entry.key]!;
      final failure = entry.value;
      constraint.status = failure.overdefined
          ? ConstraintStatus.overdefined
          : ConstraintStatus.unsatisfied;
      constraint.diagnostics.add(failure.message);
      diagnostics.add(
        ConstraintDiagnostic(
          failure.overdefined
              ? ConstraintDiagnosticKind.overConstraint
              : ConstraintDiagnosticKind.failure,
          failure.message,
          constraintIds: [constraint.id],
          suggestedFix: failure.suggestedFix,
        ),
      );
    }

    for (final constraint in candidates.where(
      (constraint) => solved.contains(constraint.id),
    )) {
      constraint.status = constraint.driven
          ? ConstraintStatus.driven
          : constraint.driving
          ? ConstraintStatus.driving
          : ConstraintStatus.satisfied;
    }

    final unconstrained = _remainingDegreesOfFreedom(
      entities,
      constraints.values,
    );
    if (unconstrained > 0) {
      diagnostics.add(
        ConstraintDiagnostic(
          ConstraintDiagnosticKind.underConstraint,
          'Sketch retains $unconstrained degree(s) of freedom',
          suggestedFix: 'Add driving dimensions or fixed constraints',
        ),
      );
    }
    _dirty.removeAll(queue.map((constraint) => constraint.id));
    watch.stop();
    return ConstraintSolveResult(
      statistics: SolverStatistics(
        executionTime: watch.elapsed,
        iterations: queue.length,
        solved: solved.length,
        failed: queue.length - solved.length,
        failureReason: diagnostics
            .where(
              (diagnostic) =>
                  diagnostic.kind == ConstraintDiagnosticKind.conflict ||
                  diagnostic.kind == ConstraintDiagnosticKind.failure,
            )
            .firstOrNull
            ?.message,
      ),
      diagnostics: diagnostics,
      solvedIds: solved,
    );
  }

  ConstraintDiagnostic? _validate(
    SketchConstraint constraint,
    Map<String, SketchEntity> entities,
  ) {
    final missing = constraint.references
        .where((reference) => !entities.containsKey(_entityId(reference)))
        .toList();
    if (missing.isNotEmpty) {
      return ConstraintDiagnostic(
        ConstraintDiagnosticKind.missingReference,
        'Missing references: ${missing.join(', ')}',
        constraintIds: [constraint.id],
        suggestedFix: 'Restore or replace the referenced entity',
      );
    }
    final required = switch (constraint.type) {
      SketchConstraintType.coincident ||
      SketchConstraintType.parallel ||
      SketchConstraintType.perpendicular ||
      SketchConstraintType.equal ||
      SketchConstraintType.concentric ||
      SketchConstraintType.collinear ||
      SketchConstraintType.midpoint ||
      SketchConstraintType.pointOnLine ||
      SketchConstraintType.pointOnCurve ||
      SketchConstraintType.symmetric ||
      SketchConstraintType.tangent => 2,
      _ => 1,
    };
    if (constraint.references.length < required) {
      return ConstraintDiagnostic(
        ConstraintDiagnosticKind.failure,
        '${constraint.type.name} requires $required reference(s)',
        constraintIds: [constraint.id],
        suggestedFix: 'Select compatible Sketch geometry',
      );
    }
    if (constraint.value != null && !constraint.value!.isFinite) {
      return ConstraintDiagnostic(
        ConstraintDiagnosticKind.failure,
        '${constraint.type.name} requires a finite value',
        constraintIds: [constraint.id],
      );
    }
    return null;
  }

  bool _apply(
    SketchConstraint constraint,
    Map<String, SketchEntity> entities,
    Set<String> fixed,
  ) {
    if (constraint.references.isEmpty) return false;
    final first = entities[_entityId(constraint.references.first)]!;
    switch (constraint.type) {
      case SketchConstraintType.fixed:
      case SketchConstraintType.lock:
        if (constraint.references.first != first.id) return false;
        if (first.locked) return false;
        first.locked = true;
        first.version++;
        return true;
      case SketchConstraintType.horizontal:
      case SketchConstraintType.vertical:
        final line = _requireLine(first, constraint.type.name);
        _ensureMovable(line.id, fixed, constraint.type.name);
        final start = _start(line), end = _end(line);
        return _setLineEnd(
          line,
          constraint.type == SketchConstraintType.horizontal
              ? SketchVector(end.x, start.y, start.z)
              : SketchVector(start.x, end.y, start.z),
        );
      case SketchConstraintType.coincident:
        final targetReference = constraint.references[1];
        _ensureMovable(targetReference, fixed, 'coincident');
        final anchor = _point(constraint.references[0], entities);
        if (anchor == null || _point(targetReference, entities) == null) {
          throw const _ConstraintProjectionFailure(
            'Coincident requires point or endpoint references.',
            suggestedFix: 'Select two points or explicit line endpoints',
          );
        }
        return _setPoint(targetReference, anchor, entities, tolerance);
      case SketchConstraintType.parallel:
      case SketchConstraintType.perpendicular:
      case SketchConstraintType.collinear:
        final anchor = _requireLine(first, constraint.type.name);
        final target = _requireLine(
          entities[_entityId(constraint.references[1])]!,
          constraint.type.name,
        );
        _ensureMovable(target.id, fixed, constraint.type.name);
        final angle =
            _lineAngle(anchor) +
            (constraint.type == SketchConstraintType.perpendicular
                ? math.pi / 2
                : 0);
        final changed = _setLineDirection(target, angle);
        if (constraint.type == SketchConstraintType.collinear) {
          final projected = _projectPointOnLine(_start(target), anchor);
          return _translateLine(target, projected - _start(target)) || changed;
        }
        return changed;
      case SketchConstraintType.concentric:
        final target = entities[_entityId(constraint.references[1])]!;
        _ensureMovable(target.id, fixed, 'concentric');
        final anchorCenter = _center(first);
        if (anchorCenter == null || _center(target) == null) {
          throw const _ConstraintProjectionFailure(
            'Concentric requires circles or arcs.',
          );
        }
        return _setCenter(target, anchorCenter);
      case SketchConstraintType.equal:
        final target = entities[_entityId(constraint.references[1])]!;
        _ensureMovable(target.id, fixed, 'equal');
        if (first is SketchLine && target is SketchLine) {
          return _setLineLength(target, _lineLength(first));
        }
        final sourceRadius = _radius(first);
        if (sourceRadius != null && _radius(target) != null) {
          return _setRadius(target, sourceRadius);
        }
        throw const _ConstraintProjectionFailure(
          'Equal requires two lines or two circular entities.',
          suggestedFix: 'Select compatible geometry of the same family',
        );
      case SketchConstraintType.tangent:
        final target = entities[_entityId(constraint.references[1])]!;
        _ensureMovable(target.id, fixed, 'tangent');
        return _applyTangent(first, target);
      case SketchConstraintType.midpoint:
        final candidate = entities[_entityId(constraint.references[1])]!;
        final line = first is SketchLine
            ? first
            : candidate is SketchLine
            ? candidate
            : null;
        if (line == null) {
          throw const _ConstraintProjectionFailure(
            'Midpoint requires a line and a point.',
          );
        }
        final pointReference = first is SketchLine
            ? constraint.references[1]
            : constraint.references[0];
        _ensureMovable(pointReference, fixed, 'midpoint');
        final midpoint = (_start(line) + _end(line)).scale(0.5);
        return _setPoint(pointReference, midpoint, entities, tolerance);
      case SketchConstraintType.pointOnLine:
      case SketchConstraintType.pointOnCurve:
        final candidate = entities[_entityId(constraint.references[1])]!;
        final line = first is SketchLine
            ? first
            : candidate is SketchLine
            ? candidate
            : null;
        if (line == null) {
          throw const _ConstraintProjectionFailure(
            'Point on line requires one point and one line.',
            suggestedFix: 'Select an explicit point followed by a line',
          );
        }
        final pointReference = first is SketchLine
            ? constraint.references[1]
            : constraint.references[0];
        final point = _point(pointReference, entities);
        if (point == null) {
          throw const _ConstraintProjectionFailure(
            'Point on line requires a point or explicit endpoint.',
            suggestedFix: 'Select a Sketch point or a line endpoint',
          );
        }
        _ensureMovable(pointReference, fixed, 'point on line');
        return _setPoint(
          pointReference,
          _projectPointOnLine(point, line),
          entities,
          tolerance,
        );
      case SketchConstraintType.angle:
      case SketchConstraintType.distance:
      case SketchConstraintType.radius:
      case SketchConstraintType.diameter:
      case SketchConstraintType.drivingDimension:
        // Driving dimensions are applied transactionally by
        // SketchDrivingDimensionAdapter. The solver validates and reports them
        // without applying a second, potentially contradictory movement.
        return false;
      case SketchConstraintType.drivenDimension:
      case SketchConstraintType.reference:
      case SketchConstraintType.construction:
        return false;
      default:
        throw _ConstraintProjectionFailure(
          '${constraint.type.name} is not implemented by the planar solver.',
          suggestedFix: 'Use a supported constraint or suppress this relation',
        );
    }
  }

  bool _applyTangent(SketchEntity first, SketchEntity target) {
    if (first is SketchLine && target is SketchLine) {
      return _setLineDirection(target, _lineAngle(first));
    }
    if (first is SketchLine && _center(target) != null) {
      final center = _center(target)!;
      final radius = _radius(target)!;
      final projection = _projectPointOnLine(center, first);
      var normal = center - projection;
      if (_length(normal) <= tolerance) {
        final direction = _end(first) - _start(first);
        normal = SketchVector(-direction.y, direction.x);
      }
      normal = normal.scale(radius / _length(normal));
      return _setCenter(target, projection + normal);
    }
    if (_center(first) != null && target is SketchLine) {
      final center = _center(first)!;
      final radius = _radius(first)!;
      final start = _start(target);
      final toCenter = center - start;
      final distance = _length(toCenter);
      if (distance <= radius + tolerance) {
        throw const _ConstraintProjectionFailure(
          'A line endpoint inside a circle has no real tangent.',
          suggestedFix: 'Move the line endpoint outside the circular entity',
        );
      }
      final base = math.atan2(toCenter.y, toCenter.x);
      final offset = math.asin(radius / distance);
      final candidates = [base + offset, base - offset];
      final current = _lineAngle(target);
      candidates.sort(
        (a, b) =>
            _angleDistance(a, current).compareTo(_angleDistance(b, current)),
      );
      return _setLineDirection(target, candidates.first);
    }
    final firstCenter = _center(first), targetCenter = _center(target);
    if (firstCenter != null && targetCenter != null) {
      final required = _radius(first)! + _radius(target)!;
      var direction = targetCenter - firstCenter;
      if (_length(direction) <= tolerance) {
        direction = const SketchVector(1, 0);
      }
      return _setCenter(
        target,
        firstCenter + direction.scale(required / _length(direction)),
      );
    }
    throw const _ConstraintProjectionFailure(
      'Tangent supports line/line, line/circle, line/arc or circular pairs.',
    );
  }

  Set<String> _fixedReferences(
    Iterable<SketchConstraint> constraints,
    Map<String, SketchEntity> entities,
  ) {
    final fixed = <String>{
      for (final entity in entities.values)
        if (entity.locked) entity.id,
    };
    for (final constraint in constraints.where(
      (constraint) =>
          constraint.enabled && !constraint.suppressed && _isFixing(constraint),
    )) {
      fixed.addAll(constraint.references);
    }
    return fixed;
  }

  void _ensureMovable(String reference, Set<String> fixed, String operation) {
    final entityId = _entityId(reference);
    if (fixed.contains(reference) || fixed.contains(entityId)) {
      throw _ConstraintProjectionFailure(
        '$operation cannot move fixed geometry $entityId.',
        overdefined: true,
        suggestedFix: 'Remove or suppress the fixed constraint',
      );
    }
  }

  int _remainingDegreesOfFreedom(
    Map<String, SketchEntity> entities,
    Iterable<SketchConstraint> constraints,
  ) {
    var total = 0;
    for (final entity in entities.values) {
      total += switch (entity) {
        SketchPoint() => entity.locked ? 0 : 2,
        SketchLine() => entity.locked ? 0 : 4,
        SketchCircle() => entity.locked ? 0 : 3,
        SketchArc() => entity.locked ? 0 : 5,
        SketchEllipse() => entity.locked ? 0 : 4,
        SketchSpline() =>
          entity.locked
              ? 0
              : ((entity.parameters['points'] as List?)?.length ?? 0) * 2,
        _ => entity.locked ? 0 : 2,
      };
    }
    for (final constraint in constraints.where(
      (constraint) =>
          constraint.enabled &&
          !constraint.suppressed &&
          constraint.status != ConstraintStatus.invalid &&
          constraint.status != ConstraintStatus.conflicting &&
          constraint.status != ConstraintStatus.overdefined,
    )) {
      total -= switch (constraint.type) {
        SketchConstraintType.fixed || SketchConstraintType.lock => 0,
        SketchConstraintType.coincident ||
        SketchConstraintType.concentric ||
        SketchConstraintType.midpoint ||
        SketchConstraintType.symmetric => 2,
        SketchConstraintType.horizontal ||
        SketchConstraintType.vertical ||
        SketchConstraintType.parallel ||
        SketchConstraintType.perpendicular ||
        SketchConstraintType.equal ||
        SketchConstraintType.tangent ||
        SketchConstraintType.collinear ||
        SketchConstraintType.distance ||
        SketchConstraintType.radius ||
        SketchConstraintType.diameter ||
        SketchConstraintType.angle ||
        SketchConstraintType.offset ||
        SketchConstraintType.pointOnCurve ||
        SketchConstraintType.pointOnCircle ||
        SketchConstraintType.pointOnArc ||
        SketchConstraintType.pointOnLine ||
        SketchConstraintType.drivingDimension => 1,
        _ => 0,
      };
    }
    return total.clamp(0, 1 << 30);
  }

  static bool _isFixing(SketchConstraint constraint) =>
      constraint.type == SketchConstraintType.fixed ||
      constraint.type == SketchConstraintType.lock;

  static String _entityId(String reference) {
    final marker = reference.lastIndexOf(':');
    if (marker <= 0) return reference;
    final suffix = reference.substring(marker + 1);
    return const {'start', 'end', 'point', 'center'}.contains(suffix)
        ? reference.substring(0, marker)
        : reference;
  }

  SketchLine _requireLine(SketchEntity entity, String operation) {
    if (entity is SketchLine) return entity;
    throw _ConstraintProjectionFailure('$operation requires line geometry.');
  }

  static SketchVector _start(SketchLine line) =>
      SketchVector.fromJson(line.parameters['start']);
  static SketchVector _end(SketchLine line) =>
      SketchVector.fromJson(line.parameters['end']);
  static double _lineLength(SketchLine line) =>
      _length(_end(line) - _start(line));
  static double _lineAngle(SketchLine line) {
    final delta = _end(line) - _start(line);
    return math.atan2(delta.y, delta.x);
  }

  bool _setLineEnd(SketchLine line, SketchVector end) {
    if (_near(_end(line), end)) return false;
    line.parameters['end'] = end.toJson();
    line.version++;
    line.refreshDerivedParameters();
    return true;
  }

  bool _setLineDirection(SketchLine line, double angle) {
    final start = _start(line), length = _lineLength(line);
    if (length <= tolerance) {
      throw const _ConstraintProjectionFailure(
        'A degenerate line cannot receive a directional constraint.',
      );
    }
    // Parallel/perpendicular relations are undirected. Keep the current
    // endpoint orientation by choosing the equivalent angle nearest to it;
    // applying an inference must never visually reverse the line.
    final current = _lineAngle(line);
    var resolved = angle;
    while ((resolved - current).abs() > math.pi / 2) {
      resolved += resolved > current ? -math.pi : math.pi;
    }
    return _setLineEnd(
      line,
      SketchVector(
        start.x + length * math.cos(resolved),
        start.y + length * math.sin(resolved),
        start.z,
      ),
    );
  }

  bool _setLineLength(SketchLine line, double length) {
    final currentLength = _lineLength(line);
    if (length <= tolerance || currentLength <= tolerance) {
      throw const _ConstraintProjectionFailure(
        'Equal cannot use a degenerate line length.',
      );
    }
    final end =
        _start(line) +
        (_end(line) - _start(line)).scale(length / currentLength);
    return _setLineEnd(line, end);
  }

  bool _translateLine(SketchLine line, SketchVector delta) {
    if (_length(delta) <= tolerance) return false;
    line.parameters['start'] = (_start(line) + delta).toJson();
    line.parameters['end'] = (_end(line) + delta).toJson();
    line.version++;
    line.refreshDerivedParameters();
    return true;
  }

  static SketchVector? _point(
    String reference,
    Map<String, SketchEntity> entities,
  ) {
    final entity = entities[_entityId(reference)];
    if (entity is SketchPoint) {
      return SketchVector.fromJson(entity.parameters['point']);
    }
    if (entity is SketchLine) {
      final endpoint = reference.endsWith(':start') ? 'start' : 'end';
      return SketchVector.fromJson(entity.parameters[endpoint]);
    }
    if (entity is SketchSpline) {
      final points =
          (entity.parameters['sampledPoints'] ?? entity.parameters['points'])
              as List?;
      if (points == null || points.length < 2) return null;
      return SketchVector.fromJson(
        reference.endsWith(':start') ? points.first : points.last,
      );
    }
    if (entity is SketchArc &&
        (reference.endsWith(':start') || reference.endsWith(':end'))) {
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
    if (entity != null && reference.endsWith(':center')) {
      return _center(entity);
    }
    return null;
  }

  static bool _setPoint(
    String reference,
    SketchVector point,
    Map<String, SketchEntity> entities,
    double tolerance,
  ) {
    final entity = entities[_entityId(reference)];
    final current = _point(reference, entities);
    if (entity == null ||
        current == null ||
        _length(current - point) <= tolerance) {
      return false;
    }
    if (entity is SketchPoint) {
      entity.parameters['point'] = point.toJson();
    } else if (entity is SketchLine) {
      entity.parameters[reference.endsWith(':start') ? 'start' : 'end'] = point
          .toJson();
      entity.refreshDerivedParameters();
    } else if (entity is SketchSpline) {
      final key = reference.endsWith(':start') ? 0 : -1;
      final points = (entity.parameters['points'] as List?)?.toList();
      if (points == null || points.length < 2) return false;
      final index = key == 0 ? 0 : points.length - 1;
      points[index] = point.toJson();
      entity.parameters['points'] = points;
      final sampled = (entity.parameters['sampledPoints'] as List?)?.toList();
      if (sampled != null && sampled.length >= 2) {
        sampled[key == 0 ? 0 : sampled.length - 1] = point.toJson();
        entity.parameters['sampledPoints'] = sampled;
      }
    } else if (entity is SketchArc &&
        (reference.endsWith(':start') || reference.endsWith(':end'))) {
      final center = SketchVector.fromJson(entity.parameters['center']);
      final dx = point.x - center.x;
      final dy = point.y - center.y;
      entity.parameters[reference.endsWith(':start')
          ? 'startAngle'
          : 'endAngle'] = math.atan2(
        dy,
        dx,
      );
    } else {
      return false;
    }
    entity.version++;
    return true;
  }

  static SketchVector? _center(SketchEntity entity) {
    if (entity is SketchCircle ||
        entity is SketchArc ||
        entity is SketchEllipse) {
      return SketchVector.fromJson(entity.parameters['center']);
    }
    return null;
  }

  bool _setCenter(SketchEntity entity, SketchVector center) {
    final current = _center(entity);
    if (current == null || _near(current, center)) return false;
    entity.parameters['center'] = center.toJson();
    entity.version++;
    return true;
  }

  static double? _radius(SketchEntity entity) =>
      entity is SketchCircle || entity is SketchArc
      ? (entity.parameters['radius'] as num).toDouble()
      : null;

  bool _setRadius(SketchEntity entity, double radius) {
    final current = _radius(entity);
    if (current == null || (current - radius).abs() <= tolerance) return false;
    entity.parameters['radius'] = radius;
    entity.version++;
    return true;
  }

  static SketchVector _projectPointOnLine(SketchVector point, SketchLine line) {
    final start = _start(line), delta = _end(line) - start;
    final denominator = delta.x * delta.x + delta.y * delta.y;
    if (denominator <= 1e-20) return start;
    final offset = point - start;
    final t = (offset.x * delta.x + offset.y * delta.y) / denominator;
    return start + delta.scale(t);
  }

  bool _near(SketchVector a, SketchVector b) => _length(a - b) <= tolerance;
  static double _length(SketchVector vector) => math.sqrt(
    vector.x * vector.x + vector.y * vector.y + vector.z * vector.z,
  );
  static double _angleDistance(double a, double b) {
    final difference = (a - b).abs() % (2 * math.pi);
    return math.min(difference, 2 * math.pi - difference);
  }
}

class _ConstraintProjectionFailure implements Exception {
  const _ConstraintProjectionFailure(
    this.message, {
    this.overdefined = false,
    this.suggestedFix,
  });

  final String message;
  final bool overdefined;
  final String? suggestedFix;
}
