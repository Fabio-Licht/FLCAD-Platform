import '../../sketch_constraints/api/constraint_api.dart';
import '../../sketch_constraints/models/constraint_models.dart';
import '../../sketch_engine/api/sketch_engine_api.dart';
import '../../sketch_engine/entities/sketch_entities.dart';
import '../analytics/editor_analytics.dart';
import '../models/editor_models.dart';

class DegreesOfFreedomReader {
  const DegreesOfFreedomReader();
  DegreesOfFreedom read(
    SketchEngineApi sketch,
    ConstraintApi constraints,
    EditorAnalytics analytics,
  ) {
    final active = constraints.constraints
        .where(
          (c) =>
              c.enabled &&
              !c.suppressed &&
              c.status != ConstraintStatus.invalid &&
              c.status != ConstraintStatus.conflicting &&
              c.status != ConstraintStatus.overdefined,
        )
        .toList(growable: false);
    final entityDof = sketch.engine.entities.values.fold<int>(
      0,
      (sum, entity) => sum + _entityDegreesOfFreedom(entity),
    );
    final removed = active.fold<int>(
      0,
      (sum, constraint) => sum + _removedDegreesOfFreedom(constraint, sketch),
    );
    final remaining = (entityDof - removed).clamp(0, entityDof);
    final conflicts = constraints.constraints
        .where(
          (c) =>
              c.status == ConstraintStatus.conflicting ||
              c.status == ConstraintStatus.overdefined,
        )
        .length;
    analytics.dofSamples++;
    analytics.totalDof += remaining;
    return DegreesOfFreedom(
      remaining: remaining,
      translationX: remaining > 0,
      translationY: remaining > 1,
      rotation: remaining > 2,
      constraintStatus: conflicts > 0
          ? 'conflicting'
          : remaining == 0
          ? 'fully-defined'
          : 'underdefined',
      diagnostics: [if (conflicts > 0) '$conflicts conflicting constraints'],
    );
  }

  int _entityDegreesOfFreedom(SketchEntity entity) => switch (entity) {
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

  int _removedDegreesOfFreedom(
    SketchConstraint constraint,
    SketchEngineApi sketch,
  ) {
    final first = constraint.references.isEmpty
        ? null
        : sketch.entity(_entityId(constraint.references.first));
    return switch (constraint.type) {
      SketchConstraintType.fixed || SketchConstraintType.lock =>
        first == null
            ? 0
            : constraint.references.first == first.id
            ? _entityDegreesOfFreedom(first)
            : 2,
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

  String _entityId(String reference) =>
      reference.replaceFirst(RegExp(r':(start|end|point|center)$'), '');
}
