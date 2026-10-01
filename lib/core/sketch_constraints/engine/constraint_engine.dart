import 'dart:convert';
import 'dart:math' as math;
import '../../sketch_engine/api/sketch_engine_api.dart';
import '../../sketch_engine/entities/sketch_entities.dart';
import '../analytics/constraint_analytics.dart';
import '../diagnostics/constraint_diagnostics.dart';
import '../graph/constraint_graph.dart';
import '../history/constraint_history.dart';
import '../models/constraint_models.dart';
import '../repository/constraint_repository.dart';
import '../runtime/constraint_runtime.dart';
import '../solver/incremental_constraint_solver.dart';
import '../integration/sketch_driving_dimension_adapter.dart';

class ConstraintEngine {
  ConstraintEngine({
    required this.sketch,
    required this.repository,
    ConstraintRuntime? runtime,
    ConstraintAnalytics? analytics,
    ConstraintHistory? history,
    IncrementalConstraintSolver? solver,
  }) : runtime = runtime ?? ConstraintRuntime(),
       analytics = analytics ?? ConstraintAnalytics(),
       history = history ?? ConstraintHistory(),
       solver = solver ?? IncrementalConstraintSolver();
  final SketchEngineApi sketch;
  final ConstraintRepository repository;
  final ConstraintRuntime runtime;
  final ConstraintAnalytics analytics;
  final ConstraintHistory history;
  final IncrementalConstraintSolver solver;
  final graphs = ConstraintGraphSet();
  final Map<String, SketchConstraint> constraints = {};
  final Map<String, SketchDimension> dimensions = {};
  final SketchDrivingDimensionAdapter dimensionAdapter =
      const SketchDrivingDimensionAdapter();
  final List<_ConstraintSnapshot> _undo = [], _redo = [];
  ConstraintSolveResult? lastResult;

  SketchConstraint add(SketchConstraint constraint) => _change(
    ConstraintHistoryAction.create,
    constraint.id,
    () {
      if (constraints.containsKey(constraint.id)) {
        throw StateError('Duplicate constraint id: ${constraint.id}');
      }
      if (constraints.values.any((c) => c.signature == constraint.signature)) {
        throw StateError('Duplicate constraint: ${constraint.signature}');
      }
      constraint.graphNode = constraint.id;
      constraints[constraint.id] = constraint;
      graphs.constraints.addNode(constraint.id);
      graphs.dependencies.addNode(constraint.id);
      if (constraint.type == SketchConstraintType.reference) {
        graphs.references.addNode(constraint.id);
      }
      if (constraint.type == SketchConstraintType.construction) {
        graphs.construction.addNode(constraint.id);
      }
      analytics.totalConstraints++;
      analytics.constraintTypes.update(
        constraint.type,
        (v) => v + 1,
        ifAbsent: () => 1,
      );
      solver.markDirty(constraint.id, graphs.dependencies);
      return constraint;
    },
  );
  void delete(String id) => _change(ConstraintHistoryAction.delete, id, () {
    final c =
        constraints.remove(id) ?? (throw StateError('Unknown constraint: $id'));
    graphs.constraints.removeNode(id);
    graphs.dependencies.removeNode(id);
    graphs.references.removeNode(id);
    graphs.construction.removeNode(id);
    analytics.totalConstraints--;
    analytics.constraintTypes.update(c.type, (v) => v - 1);
  });
  void enable(String id) => _setStatus(
    id,
    ConstraintStatus.unsatisfied,
    ConstraintHistoryAction.enable,
  );
  void disable(String id) => _setStatus(
    id,
    ConstraintStatus.disabled,
    ConstraintHistoryAction.disable,
  );
  void suppress(String id) => _setStatus(
    id,
    ConstraintStatus.suppressed,
    ConstraintHistoryAction.suppress,
  );
  void setVisible(String id, bool visible) =>
      _change(ConstraintHistoryAction.modify, id, () {
        final c =
            constraints[id] ?? (throw StateError('Unknown constraint: $id'));
        c.metadata['visible'] = visible;
        c.version++;
        c.history.add('visibility');
      });
  void _setStatus(
    String id,
    ConstraintStatus status,
    ConstraintHistoryAction action,
  ) => _change(action, id, () {
    final c = constraints[id] ?? (throw StateError('Unknown constraint: $id'));
    c.status = status;
    c.version++;
    c.history.add(action.name);
    solver.markDirty(id, graphs.dependencies);
  });
  void depend(String dependency, String dependent) =>
      transaction('dependency', () {
        graphs.dependencies.connect(dependency, dependent);
        solver.markDirty(dependency, graphs.dependencies);
      });
  SketchDimension addDimension(SketchDimension dimension) =>
      _change(ConstraintHistoryAction.create, dimension.id, () {
        if (!constraints.containsKey(dimension.constraintId)) {
          throw StateError('Unknown dimension constraint');
        }
        dimensions[dimension.id] = dimension;
        return dimension;
      });

  SketchDimension createDrivingDimension({
    required SketchDimensionType type,
    required List<String> references,
    required double value,
    String? anchorReference,
    double labelX = 0,
    double labelY = 0,
  }) => transaction(
    'create-driving-dimension',
    () => sketch.engine.transaction('create-driving-dimension', () {
      final orientationSign = _angularOrientationSign(type, references);
      final duplicate = dimensions.values.where((dimension) {
        if (dimension.references.isEmpty || references.isEmpty) return false;
        final existingRadial =
            dimension.type == SketchDimensionType.radius ||
            dimension.type == SketchDimensionType.diameter;
        final requestedRadial =
            type == SketchDimensionType.radius ||
            type == SketchDimensionType.diameter;
        if (existingRadial && requestedRadial) {
          return dimension.references.first == references.first;
        }
        if (dimension.type != type ||
            dimension.references.length != references.length) {
          return false;
        }
        if (const {
              SketchDimensionType.linear,
              SketchDimensionType.horizontal,
              SketchDimensionType.vertical,
              SketchDimensionType.parallelDistance,
              SketchDimensionType.ordinateX,
              SketchDimensionType.ordinateY,
            }.contains(type) &&
            references.length == 2) {
          final existing = dimension.references.toSet();
          return existing.length == 2 && existing.containsAll(references);
        }
        return dimension.references.first == references.first;
      }).firstOrNull;
      if (duplicate != null) {
        throw StateError(
          'Geometry is already controlled by ${duplicate.id}. '
          'Edit or delete the existing driving dimension.',
        );
      }
      final constraintType = switch (type) {
        SketchDimensionType.linear ||
        SketchDimensionType.horizontal ||
        SketchDimensionType.vertical ||
        SketchDimensionType.parallelDistance ||
        SketchDimensionType.ordinateX ||
        SketchDimensionType.ordinateY => SketchConstraintType.distance,
        SketchDimensionType.angular => SketchConstraintType.angle,
        SketchDimensionType.radius => SketchConstraintType.radius,
        SketchDimensionType.diameter => SketchConstraintType.diameter,
        _ => throw StateError('${type.name} is not a driving dimension.'),
      };
      final constraint = add(
        SketchConstraint(
          type: constraintType,
          references: references,
          value: value,
          status: ConstraintStatus.driving,
        ),
      );
      final solution = _applyDrivingDimension(
        type: type,
        references: references,
        value: value,
        anchorReference: anchorReference,
        orientationSign: orientationSign,
      );
      return addDimension(
        SketchDimension(
          type: type,
          constraintId: constraint.id,
          value: value,
          references: references,
          anchorReference: solution.anchorReference,
          orientationSign: orientationSign,
          labelX: labelX,
          labelY: labelY,
        ),
      );
    }),
  );

  SketchDimension driveDimension(
    String id,
    double value, {
    String? anchorReference,
  }) => transaction(
    'edit-driving-dimension',
    () => sketch.engine.transaction('edit-driving-dimension', () {
      final dimension =
          dimensions[id] ?? (throw StateError('Unknown dimension: $id'));
      final solution = _applyDrivingDimension(
        type: dimension.type,
        references: dimension.references,
        value: value,
        anchorReference: anchorReference ?? dimension.anchorReference,
        orientationSign:
            dimension.orientationSign ??
            _angularOrientationSign(dimension.type, dimension.references),
        ignoredConstraintId: dimension.constraintId,
      );
      return updateDimension(
        id,
        value: value,
        anchorReference: solution.anchorReference,
      );
    }),
  );

  SketchDrivingDimensionSolution _applyDrivingDimension({
    required SketchDimensionType type,
    required List<String> references,
    required double value,
    String? anchorReference,
    double? orientationSign,
    String? ignoredConstraintId,
  }) {
    final active = constraints.values
        .where((constraint) => constraint.id != ignoredConstraintId)
        .toList(growable: false);
    SketchDrivingDimensionSolution attempt(String? anchor) =>
        sketch.engine.transaction(
          'dimension-adapter-attempt',
          () => dimensionAdapter.apply(
            sketch: sketch,
            constraints: active,
            type: type,
            references: references,
            value: value,
            anchorReference: anchor,
            orientationSign: orientationSign,
          ),
        );
    if (anchorReference != null) return attempt(anchorReference);
    try {
      return attempt(null);
    } on StateError catch (automaticFailure) {
      if (references.length == 2) rethrow;
      final entity = references.isEmpty
          ? null
          : sketch.entity(references.first);
      if (entity is! SketchLine) rethrow;
      final diagnostics = <String>[automaticFailure.message];
      for (final suffix in const ['start', 'end']) {
        try {
          return attempt('${entity.id}:$suffix');
        } on StateError catch (failure) {
          diagnostics.add(failure.message);
        }
      }
      throw StateError(
        'Sketch over constrained. No legal anchor preserves all relations. '
        '${diagnostics.toSet().join(' ')}',
      );
    }
  }

  double? _angularOrientationSign(
    SketchDimensionType type,
    List<String> references,
  ) {
    if (type != SketchDimensionType.angular || references.length != 2) {
      return null;
    }
    final first = sketch.entity(references[0]);
    final second = sketch.entity(references[1]);
    if (first is! SketchLine || second is! SketchLine) return null;
    final firstAngle =
        (first.parameters['angleDegrees'] as num).toDouble() * math.pi / 180;
    final secondAngle =
        (second.parameters['angleDegrees'] as num).toDouble() * math.pi / 180;
    final cross = math.sin(secondAngle - firstAngle);
    return cross < 0 ? -1 : 1;
  }

  SketchDimension updateDimension(
    String id, {
    double? value,
    double? labelX,
    double? labelY,
    String? anchorReference,
  }) => _change(ConstraintHistoryAction.modify, id, () {
    final dimension =
        dimensions[id] ?? (throw StateError('Unknown dimension: $id'));
    if (value != null) {
      if (!value.isFinite ||
          (value <= 0 &&
              !const {
                SketchDimensionType.ordinateX,
                SketchDimensionType.ordinateY,
              }.contains(dimension.type))) {
        throw StateError('A driving dimension must be greater than zero.');
      }
      dimension.value = value;
      constraints[dimension.constraintId]?.value = value;
    }
    if (labelX != null) dimension.labelX = labelX;
    if (labelY != null) dimension.labelY = labelY;
    if (anchorReference != null) dimension.anchorReference = anchorReference;
    return dimension;
  });

  void deleteDimension(String id) => _change(
    ConstraintHistoryAction.delete,
    id,
    () {
      final dimension =
          dimensions.remove(id) ?? (throw StateError('Unknown dimension: $id'));
      final constraint = constraints.remove(dimension.constraintId);
      if (constraint != null) {
        graphs.constraints.removeNode(constraint.id);
        graphs.dependencies.removeNode(constraint.id);
        analytics.totalConstraints--;
      }
    },
  );

  Future<ConstraintSolveResult> solve({Iterable<String>? only}) async {
    final before = _capture('solve');
    try {
      final result = await solver.solve(
        constraints: constraints,
        entities: sketch.engine.entities,
        graphs: graphs,
        only: only,
      );
      lastResult = result;
      _undo.add(before);
      _redo.clear();
      history.record(
        ConstraintHistoryAction.solve,
        sketch.engine.activeSketchId ?? 'sketch',
      );
      analytics.solveCount++;
      analytics.totalSolveMicros +=
          result.statistics.executionTime.inMicroseconds;
      analytics.iterations += result.statistics.iterations;
      analytics.solved += result.statistics.solved;
      analytics.conflicts += result.diagnostics
          .where(
            (d) =>
                d.kind == ConstraintDiagnosticKind.conflict ||
                d.kind == ConstraintDiagnosticKind.duplicate,
          )
          .length;
      analytics.overdefined += result.diagnostics
          .where((d) => d.kind == ConstraintDiagnosticKind.overConstraint)
          .length;
      analytics.underdefined += result.diagnostics
          .where((d) => d.kind == ConstraintDiagnosticKind.underConstraint)
          .length;
      if (!result.success) analytics.failures++;
      return result;
    } catch (_) {
      _restore(before);
      history.record(ConstraintHistoryAction.rollback, 'solve');
      rethrow;
    }
  }

  Future<ConstraintSolveResult> rebuild() {
    for (final id in constraints.keys) {
      solver.markDirty(id, graphs.dependencies);
    }
    return solve();
  }

  T transaction<T>(String label, T Function() operation) {
    final before = _capture(label);
    final h = history.entries.length, u = _undo.length, r = _redo.length;
    try {
      final result = operation();
      if (_undo.length > u) {
        _undo.removeRange(u, _undo.length);
        _undo.add(before);
        _redo.clear();
        history.truncate(h);
        history.record(ConstraintHistoryAction.modify, label);
      }
      return result;
    } catch (_) {
      _restore(before);
      history.truncate(h);
      _undo.removeRange(u, _undo.length);
      _redo.removeRange(r, _redo.length);
      history.record(ConstraintHistoryAction.rollback, label);
      rethrow;
    }
  }

  bool undo() {
    if (_undo.isEmpty) return false;
    final current = _capture('redo');
    _restore(_undo.removeLast());
    _redo.add(current);
    history.record(ConstraintHistoryAction.undo, 'constraint');
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    final current = _capture('undo');
    _restore(_redo.removeLast());
    _undo.add(current);
    history.record(ConstraintHistoryAction.redo, 'constraint');
    return true;
  }

  T _change<T>(
    ConstraintHistoryAction action,
    String target,
    T Function() operation,
  ) {
    final before = _capture(target);
    try {
      final result = operation();
      _undo.add(before);
      _redo.clear();
      history.record(action, target);
      return result;
    } catch (_) {
      _restore(before);
      rethrow;
    }
  }

  Future<void> persist() => repository.save(
    constraints: constraints.values,
    dimensions: dimensions.values,
    graphs: graphs,
    history: history,
    analytics: analytics,
  );
  Future<void> load() async {
    for (final c in await repository.loadConstraints()) {
      constraints[c.id] = c;
      graphs.constraints.addNode(c.id);
      graphs.dependencies.addNode(c.id);
    }
    for (final d in await repository.loadDimensions()) {
      dimensions[d.id] = d;
    }
    analytics.totalConstraints = constraints.length;
  }

  _ConstraintSnapshot _capture(String target) => _ConstraintSnapshot(
    target,
    (jsonDecode(jsonEncode(constraints.map((k, v) => MapEntry(k, v.toJson()))))
            as Map)
        .cast<String, dynamic>(),
    (jsonDecode(jsonEncode(dimensions.map((k, v) => MapEntry(k, v.toJson()))))
            as Map)
        .cast<String, dynamic>(),
    (jsonDecode(
              jsonEncode(
                sketch.engine.entities.map((k, v) => MapEntry(k, v.toJson())),
              ),
            )
            as Map)
        .cast<String, dynamic>(),
    (jsonDecode(jsonEncode(graphs.toJson())) as Map).cast<String, dynamic>(),
    [
      analytics.totalConstraints,
      analytics.solved,
      analytics.conflicts,
      analytics.iterations,
      analytics.failures,
      analytics.solveCount,
      analytics.totalSolveMicros,
      analytics.overdefined,
      analytics.underdefined,
    ],
  );
  void _restore(_ConstraintSnapshot s) {
    constraints.clear();
    for (final e in s.constraints.entries) {
      constraints[e.key] = SketchConstraint.fromJson(
        (e.value as Map).cast<String, dynamic>(),
      );
    }
    dimensions.clear();
    for (final e in s.dimensions.entries) {
      dimensions[e.key] = SketchDimension.fromJson(
        (e.value as Map).cast<String, dynamic>(),
      );
    }
    sketch.engine.entities.removeWhere((id, _) => !s.entities.containsKey(id));
    for (final e in s.entities.entries) {
      final restored = SketchEntity.fromJson(
        (e.value as Map).cast<String, dynamic>(),
      );
      final current = sketch.engine.entities[e.key];
      if (current == null || current.type != restored.type) {
        sketch.engine.entities[e.key] = restored;
        continue;
      }
      current.version = restored.version;
      current.history
        ..clear()
        ..addAll(restored.history);
      current
        ..graphNode = restored.graphNode
        ..selectionState = restored.selectionState
        ..visible = restored.visible
        ..locked = restored.locked
        ..construction = restored.construction
        ..reference = restored.reference;
      current.metadata
        ..clear()
        ..addAll(restored.metadata);
      current.diagnostics
        ..clear()
        ..addAll(restored.diagnostics);
      current.parameters
        ..clear()
        ..addAll(restored.parameters);
    }
    graphs.restore(s.graphs);
    analytics.totalConstraints = s.analytics[0];
    analytics.solved = s.analytics[1];
    analytics.conflicts = s.analytics[2];
    analytics.iterations = s.analytics[3];
    analytics.failures = s.analytics[4];
    analytics.solveCount = s.analytics[5];
    analytics.totalSolveMicros = s.analytics[6];
    analytics.overdefined = s.analytics[7];
    analytics.underdefined = s.analytics[8];
  }
}

class _ConstraintSnapshot {
  const _ConstraintSnapshot(
    this.target,
    this.constraints,
    this.dimensions,
    this.entities,
    this.graphs,
    this.analytics,
  );
  final String target;
  final Map<String, dynamic> constraints, dimensions, entities, graphs;
  final List<int> analytics;
}
