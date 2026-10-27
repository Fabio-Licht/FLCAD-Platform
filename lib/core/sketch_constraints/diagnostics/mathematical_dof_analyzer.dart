import 'dart:math' as math;

import '../../sketch_engine/api/sketch_engine_api.dart';
import '../../sketch_engine/entities/sketch_entities.dart';
import '../../sketch_engine/models/sketch_models.dart';
import '../api/constraint_api.dart';
import '../models/constraint_models.dart';

enum MathematicalDofStatus {
  fullyConstrained,
  partiallyConstrained,
  redundant,
  conflicting,
  singular,
  unsupported,
}

/// Computes DOF from the numerical rank of the supported constraint Jacobian.
///
/// This deliberately does not replace the production solver. It is a diagnostic
/// oracle: callers must treat [isExact] as false whenever an entity or
/// constraint is outside the implemented residual model.
final class MathematicalDofAnalyzer {
  const MathematicalDofAnalyzer({
    this.rankTolerance = 1e-8,
    this.residualTolerance = 1e-7,
    this.differenceStep = 1e-6,
  });

  final double rankTolerance;
  final double residualTolerance;
  final double differenceStep;

  MathematicalDofResult analyze(
    SketchEngineApi sketch,
    ConstraintApi constraints,
  ) {
    final variables = <_Variable>[];
    final unsupported = <String>[];
    for (final entity in sketch.engine.entities.values) {
      if (entity.locked) continue;
      switch (entity) {
        case SketchPoint():
          variables.addAll(_pointVariables(entity));
        case SketchLine():
          variables.addAll(_lineVariables(entity));
        case SketchCircle():
          variables.addAll(_circleVariables(entity));
        case SketchArc():
          variables.addAll(_arcVariables(entity));
        default:
          unsupported.add('entity:${entity.type.name}');
      }
    }

    final residuals = <double Function()>[];
    final active = constraints.constraints.where(
      (c) =>
          c.enabled &&
          !c.suppressed &&
          c.type != SketchConstraintType.reference,
    );
    for (final constraint in active) {
      final added = _addResiduals(constraint, sketch, residuals);
      if (!added) {
        unsupported.add('constraint:${constraint.type.name}:${constraint.id}');
      }
    }

    final baseline = variables.map((v) => v.read()).toList(growable: false);
    final values = residuals.map((r) => r()).toList(growable: false);
    final jacobian = <List<double>>[];
    for (final residual in residuals) {
      final row = <double>[];
      for (var i = 0; i < variables.length; i++) {
        final x = baseline[i];
        final step = differenceStep * math.max(1.0, x.abs());
        variables[i].write(x + step);
        final plus = residual();
        variables[i].write(x - step);
        final minus = residual();
        variables[i].write(x);
        row.add((plus - minus) / (2 * step));
      }
      jacobian.add(row);
    }
    for (var i = 0; i < variables.length; i++) {
      variables[i].write(baseline[i]);
    }

    final rank = _rank(jacobian, rankTolerance);
    final maxResidual = values.isEmpty
        ? 0.0
        : values.map((v) => v.abs()).reduce(math.max);
    final exact = unsupported.isEmpty;
    final consistent = maxResidual <= residualTolerance;
    final independent = rank;
    final status = !exact
        ? MathematicalDofStatus.unsupported
        : !consistent
        ? MathematicalDofStatus.conflicting
        : variables.isEmpty
        ? MathematicalDofStatus.fullyConstrained
        : independent < residuals.length
        ? MathematicalDofStatus.redundant
        : rank < variables.length
        ? MathematicalDofStatus.partiallyConstrained
        : MathematicalDofStatus.fullyConstrained;
    return MathematicalDofResult(
      status: status,
      isExact: exact,
      variableCount: variables.length,
      equationCount: residuals.length,
      rank: rank,
      remainingDof: math.max(0, variables.length - rank),
      maximumResidual: maxResidual,
      unsupported: List.unmodifiable(unsupported),
    );
  }

  /// Test-level entry point for independently specified equation systems.
  /// This is intentionally separate from the Sketch model so redundant and
  /// near-singular fixtures do not require invalid persisted documents.
  MathematicalDofResult analyzeLinearSystem({
    required int variableCount,
    required List<List<double>> jacobian,
    required List<double> residuals,
  }) {
    final rank = _rank(jacobian, rankTolerance);
    final tightRank = _rank(jacobian, rankTolerance * 1e-4);
    final maximumResidual = residuals.isEmpty
        ? 0.0
        : residuals.map((v) => v.abs()).reduce(math.max);
    final consistent = maximumResidual <= residualTolerance;
    final exact = jacobian.every(
      (row) => row.length == variableCount && row.every((v) => v.isFinite),
    );
    final status = !exact
        ? MathematicalDofStatus.unsupported
        : !consistent
        ? MathematicalDofStatus.conflicting
        : tightRank > rank
        ? MathematicalDofStatus.singular
        : rank < jacobian.length
        ? MathematicalDofStatus.redundant
        : rank < variableCount
        ? MathematicalDofStatus.partiallyConstrained
        : MathematicalDofStatus.fullyConstrained;
    return MathematicalDofResult(
      status: status,
      isExact: exact,
      variableCount: variableCount,
      equationCount: jacobian.length,
      rank: rank,
      remainingDof: math.max(0, variableCount - rank),
      maximumResidual: maximumResidual,
      unsupported: const [],
    );
  }

  List<_Variable> _pointVariables(SketchPoint e) => [
    _Variable(() => _point(e).x, (v) => _setPoint(e, v, _point(e).y)),
    _Variable(() => _point(e).y, (v) => _setPoint(e, _point(e).x, v)),
  ];

  List<_Variable> _lineVariables(SketchLine e) => [
    _Variable(
      () => _lineStart(e).x,
      (v) => _setLine(e, v, _lineStart(e).y, _lineEnd(e).x, _lineEnd(e).y),
    ),
    _Variable(
      () => _lineStart(e).y,
      (v) => _setLine(e, _lineStart(e).x, v, _lineEnd(e).x, _lineEnd(e).y),
    ),
    _Variable(
      () => _lineEnd(e).x,
      (v) => _setLine(e, _lineStart(e).x, _lineStart(e).y, v, _lineEnd(e).y),
    ),
    _Variable(
      () => _lineEnd(e).y,
      (v) => _setLine(e, _lineStart(e).x, _lineStart(e).y, _lineEnd(e).x, v),
    ),
  ];

  List<_Variable> _circleVariables(SketchCircle e) => [
    _Variable(
      () => _circleCenter(e).x,
      (v) => _setCircle(e, v, _circleCenter(e).y, _radius(e)),
    ),
    _Variable(
      () => _circleCenter(e).y,
      (v) => _setCircle(e, _circleCenter(e).x, v, _radius(e)),
    ),
    _Variable(
      () => _radius(e),
      (v) => _setCircle(e, _circleCenter(e).x, _circleCenter(e).y, v),
    ),
  ];

  List<_Variable> _arcVariables(SketchArc e) => [
    _Variable(
      () => _circleCenter(e).x,
      (v) => _setCircle(e, v, _circleCenter(e).y, _radius(e)),
    ),
    _Variable(
      () => _circleCenter(e).y,
      (v) => _setCircle(e, _circleCenter(e).x, v, _radius(e)),
    ),
    _Variable(
      () => _radius(e),
      (v) => _setCircle(e, _circleCenter(e).x, _circleCenter(e).y, v),
    ),
    _Variable(
      () => _number(e.parameters['startAngle']),
      (v) => e.parameters['startAngle'] = v,
    ),
    _Variable(
      () => _number(e.parameters['endAngle']),
      (v) => e.parameters['endAngle'] = v,
    ),
  ];

  bool _addResiduals(
    SketchConstraint c,
    SketchEngineApi sketch,
    List<double Function()> out,
  ) {
    final before = out.length;
    final a = c.references.isEmpty ? null : _entity(sketch, c.references.first);
    final b = c.references.length < 2 ? null : _entity(sketch, c.references[1]);
    switch (c.type) {
      case SketchConstraintType.horizontal:
        if (a is SketchLine) out.add(() => _lineEnd(a).y - _lineStart(a).y);
      case SketchConstraintType.vertical:
        if (a is SketchLine) out.add(() => _lineEnd(a).x - _lineStart(a).x);
      case SketchConstraintType.coincident:
        final p = _referencePoint(a, c.references.first);
        final q = b == null || c.references.length < 2
            ? null
            : _referencePoint(b, c.references[1]);
        if (p != null && q != null) {
          out
            ..add(() => p().x - q().x)
            ..add(() => p().y - q().y);
        }
      case SketchConstraintType.fixed:
      case SketchConstraintType.lock:
        if (a != null) {
          final frozen = _freeze(a);
          out.addAll(frozen);
        }
      case SketchConstraintType.radius:
      case SketchConstraintType.diameter:
        if (a is SketchCircle) {
          out.add(
            () =>
                _radius(a) * (c.type == SketchConstraintType.diameter ? 2 : 1) -
                (c.value ?? 0),
          );
        } else if (a is SketchArc) {
          out.add(
            () =>
                _radius(a) * (c.type == SketchConstraintType.diameter ? 2 : 1) -
                (c.value ?? 0),
          );
        }
      case SketchConstraintType.distance:
      case SketchConstraintType.drivingDimension:
        if (a is SketchLine) {
          out.add(() => _distance(_lineStart(a), _lineEnd(a)) - (c.value ?? 0));
        }
      case SketchConstraintType.equal:
        if (a is SketchLine && b is SketchLine) {
          out.add(
            () =>
                _distance(_lineStart(a), _lineEnd(a)) -
                _distance(_lineStart(b), _lineEnd(b)),
          );
        }
      case SketchConstraintType.parallel:
        if (a is SketchLine && b is SketchLine) {
          out.add(
            () => _cross(
              _lineEnd(a) - _lineStart(a),
              _lineEnd(b) - _lineStart(b),
            ),
          );
        }
      case SketchConstraintType.perpendicular:
        if (a is SketchLine && b is SketchLine) {
          out.add(
            () =>
                (_lineEnd(a) - _lineStart(a)).dot(_lineEnd(b) - _lineStart(b)),
          );
        }
      default:
        return false;
    }
    return out.length > before;
  }

  SketchEntity? _entity(SketchEngineApi s, String ref) =>
      s.entity(ref.replaceFirst(RegExp(r':(start|end|point|center)$'), ''));
  SketchVector _point(SketchPoint e) =>
      SketchVector.fromJson(e.parameters['point']);
  SketchVector _lineStart(SketchLine e) =>
      SketchVector.fromJson(e.parameters['start']);
  SketchVector _lineEnd(SketchLine e) =>
      SketchVector.fromJson(e.parameters['end']);
  SketchVector _circleCenter(SketchEntity e) =>
      SketchVector.fromJson(e.parameters['center']);
  double _radius(SketchEntity e) => _number(e.parameters['radius']);
  double _number(dynamic v) => (v as num).toDouble();
  double _distance(SketchVector a, SketchVector b) {
    final d = a - b;
    return math.sqrt(d.dot(d));
  }

  double _cross(SketchVector a, SketchVector b) => a.x * b.y - a.y * b.x;

  List<double Function()> _freeze(SketchEntity entity) {
    switch (entity) {
      case SketchPoint():
        final p = _point(entity);
        return [() => p.x - _point(entity).x, () => p.y - _point(entity).y];
      case SketchLine():
        final s = _lineStart(entity), e = _lineEnd(entity);
        return [
          () => s.x - _lineStart(entity).x,
          () => s.y - _lineStart(entity).y,
          () => e.x - _lineEnd(entity).x,
          () => e.y - _lineEnd(entity).y,
        ];
      case SketchCircle():
        final c = _circleCenter(entity), r = _radius(entity);
        return [
          () => c.x - _circleCenter(entity).x,
          () => c.y - _circleCenter(entity).y,
          () => r - _radius(entity),
        ];
      case SketchArc():
        final c = _circleCenter(entity), r = _radius(entity);
        final start = _number(entity.parameters['startAngle']);
        final end = _number(entity.parameters['endAngle']);
        return [
          () => c.x - _circleCenter(entity).x,
          () => c.y - _circleCenter(entity).y,
          () => r - _radius(entity),
          () => start - _number(entity.parameters['startAngle']),
          () => end - _number(entity.parameters['endAngle']),
        ];
      default:
        return const [];
    }
  }

  SketchVector Function()? _referencePoint(SketchEntity? e, String ref) {
    if (e == null) return null;
    final suffix = ref.split(':').last;
    return () {
      if (e is SketchPoint) return _point(e);
      if (e is SketchLine) return suffix == 'end' ? _lineEnd(e) : _lineStart(e);
      if (e is SketchCircle || e is SketchArc) return _circleCenter(e);
      throw StateError('Unsupported point reference ${e.type.name}:$suffix');
    };
  }

  void _setPoint(SketchPoint e, double x, double y) =>
      e.parameters['point'] = SketchVector(x, y).toJson();
  void _setLine(SketchLine e, double sx, double sy, double ex, double ey) {
    e.parameters['start'] = SketchVector(sx, sy).toJson();
    e.parameters['end'] = SketchVector(ex, ey).toJson();
    e.refreshDerivedParameters();
  }

  void _setCircle(SketchEntity e, double x, double y, double r) {
    e.parameters['center'] = SketchVector(x, y).toJson();
    e.parameters['radius'] = r;
  }

  int _rank(List<List<double>> matrix, double tolerance) {
    if (matrix.isEmpty || matrix.first.isEmpty) return 0;
    final a = matrix.map((row) {
      final scale = row.fold<double>(0, (m, v) => math.max(m, v.abs()));
      return scale == 0
          ? List<double>.from(row)
          : row.map((v) => v / scale).toList();
    }).toList();
    var row = 0, rank = 0;
    final cols = a.first.length;
    for (var col = 0; col < cols && row < a.length; col++) {
      var pivot = row;
      for (var r = row + 1; r < a.length; r++) {
        if (a[r][col].abs() > a[pivot][col].abs()) {
          pivot = r;
        }
      }
      if (a[pivot][col].abs() <= tolerance) continue;
      final temp = a[row];
      a[row] = a[pivot];
      a[pivot] = temp;
      final scale = a[row][col];
      for (var c = col; c < cols; c++) {
        a[row][c] /= scale;
      }
      for (var r = 0; r < a.length; r++) {
        if (r != row) {
          final factor = a[r][col];
          for (var c = col; c < cols; c++) {
            a[r][c] -= factor * a[row][c];
          }
        }
      }
      row++;
      rank++;
    }
    return rank;
  }
}

final class MathematicalDofResult {
  const MathematicalDofResult({
    required this.status,
    required this.isExact,
    required this.variableCount,
    required this.equationCount,
    required this.rank,
    required this.remainingDof,
    required this.maximumResidual,
    required this.unsupported,
  });
  final MathematicalDofStatus status;
  final bool isExact;
  final int variableCount, equationCount, rank, remainingDof;
  final double maximumResidual;
  final List<String> unsupported;
}

final class _Variable {
  _Variable(this.read, this.write);
  final double Function() read;
  final void Function(double) write;
}
