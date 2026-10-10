import 'dart:math' as math;

import 'package:flcad_mobile/core/sketch_assistant/sketch_continuity_repair_planner.dart';
import 'package:flcad_mobile/core/sketch_assistant/sketch_reconstruction.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const continuity = SketchContinuityDiagnostic();
  const planner = SketchContinuityRepairPlanner();

  SketchContinuityRepairPlan planFor(
    List<SketchEntity> entities, {
    List<SketchConstraint> constraints = const [],
  }) {
    final firstId = entities[0].id;
    final secondId = entities[1].id;
    final join = continuity
        .analyze(entities, constraints: constraints)
        .joins
        .singleWhere(
          (candidate) => {
            candidate.first.entityId,
            candidate.second.entityId,
          }.containsAll({firstId, secondId}),
        );
    return planner.plan(
      join,
      entities: {for (final entity in entities) entity.id: entity},
      constraints: constraints,
    );
  }

  test('plans line-line endpoint repair alternatives without mutation', () {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
      id: 'line:first',
    );
    final second = SketchLine(
      const SketchVector(1.05, 0),
      const SketchVector(2, 0),
      id: 'line:second',
    );
    final before = [first.toJson(), second.toJson()];

    final result = planFor([first, second]);

    expect(result.status, SketchContinuityRepairStatus.requiresConfirmation);
    expect(result.currentGapMillimeters, closeTo(.05, 1e-12));
    expect(result.repairGapToleranceMillimeters, closeTo(.1, 1e-12));
    expect(result.alternatives, isNotEmpty);
    expect(
      result.alternatives.any(
        (alternative) =>
            alternative.kind ==
                SketchContinuityRepairAlternativeKind.extendFirstLine ||
            alternative.kind ==
                SketchContinuityRepairAlternativeKind.trimFirstLine,
      ),
      isTrue,
    );
    expect(
      result.alternatives.any(
        (alternative) =>
            alternative.kind ==
                SketchContinuityRepairAlternativeKind.extendSecondLine ||
            alternative.kind ==
                SketchContinuityRepairAlternativeKind.trimSecondLine,
      ),
      isTrue,
    );
    expect(
      result.alternatives.every(
        (alternative) => alternative.c0ResidualMillimeters <= 1e-12,
      ),
      isTrue,
    );
    final signatures = result.alternatives
        .map(
          (alternative) => alternative.updates
              .map(
                (update) =>
                    '${update.entityId}:${update.endpoint}:${update.after.x},'
                    '${update.after.y},${update.after.z}',
              )
              .join('|'),
        )
        .toList();
    expect(signatures.toSet(), hasLength(signatures.length));
    expect([first.toJson(), second.toJson()], before);
  });

  test(
    'revalidates a selected join even when its endpoint order is inverted',
    () {
      final first = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
        id: 'line:first',
      );
      final second = SketchLine(
        const SketchVector(1.05, 0),
        const SketchVector(2, 0),
        id: 'line:second',
      );
      final join = continuity.analyze([first, second]).joins.single;
      final reversed = SketchContinuityJoinDiagnostic(
        first: join.second,
        second: join.first,
        gapMillimeters: join.gapMillimeters,
        gapToleranceMillimeters: join.gapToleranceMillimeters,
        tangencyToleranceRadians: join.tangencyToleranceRadians,
        tangentAngleRadians: join.tangentAngleRadians,
        orientedTangentAngleRadians: join.orientedTangentAngleRadians,
        measuredC0: join.measuredC0,
        measuredG1: join.measuredG1,
        orientedG1: join.orientedG1,
        declaredCoincident: join.declaredCoincident,
        declaredTangent: join.declaredTangent,
        continuity: join.continuity,
        issue: join.issue,
        nearby: join.nearby,
        overlapping: join.overlapping,
        crossing: join.crossing,
      );

      final result = planner.plan(
        reversed,
        entities: {first.id: first, second.id: second},
      );

      expect(result.status, SketchContinuityRepairStatus.requiresConfirmation);
      expect(result.firstEntityId, join.first.entityId);
      expect(result.secondEntityId, join.second.entityId);
    },
  );

  test('protects fixed and dimensioned endpoints before proposing a move', () {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
      id: 'fixed-line',
    );
    final second = SketchLine(
      const SketchVector(1.05, 0),
      const SketchVector(2, 0),
      id: 'free-line',
    );
    final fixed = SketchConstraint(
      type: SketchConstraintType.fixed,
      references: ['${first.id}:end'],
    );
    final plan = planFor([first, second], constraints: [fixed]);

    expect(plan.protectedEntityIds, contains(first.id));
    expect(
      plan.alternatives.any(
        (alternative) =>
            alternative.updates.any((update) => update.entityId == first.id),
      ),
      isFalse,
    );
    expect(plan.alternatives, isNotEmpty);
    expect(plan.diagnostics.join(' '), contains('protegido'));
  });

  test('protects a dimensioned endpoint without blocking the free side', () {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
      id: 'free-line',
    );
    final second = SketchLine(
      const SketchVector(1.05, 0),
      const SketchVector(2, 0),
      id: 'dimensioned-line',
    );
    final dimension = SketchConstraint(
      type: SketchConstraintType.distance,
      references: ['${second.id}:start'],
      value: 1,
    );
    final plan = planFor([first, second], constraints: [dimension]);

    expect(plan.protectedEntityIds, contains(second.id));
    expect(
      plan.alternatives.every(
        (alternative) =>
            alternative.updates.every((update) => update.entityId != second.id),
      ),
      isTrue,
    );
    expect(plan.alternatives, isNotEmpty);
  });

  test('rejects gaps above Sketch Health repair tolerance', () {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
      id: 'first',
    );
    final second = SketchLine(
      const SketchVector(1.101, 0),
      const SketchVector(2, 0),
      id: 'second',
    );
    final result = planFor([first, second]);

    expect(result.status, SketchContinuityRepairStatus.impossible);
    expect(result.alternatives, isEmpty);
    expect(result.diagnostics.join(' '), contains('excede a tolerância'));
  });

  test('keeps a valid arc circular and oriented when a line moves to it', () {
    final line = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(9.95, 0),
      id: 'line',
    );
    final arc = SketchArc(
      const SketchVector(10, 5),
      5,
      -math.pi / 2,
      0,
      id: 'arc',
    );
    final plan = planFor([line, arc]);
    final lineMoves = plan.alternatives.where(
      (alternative) =>
          alternative.updates.every((update) => update.entityId == line.id),
    );

    expect(lineMoves, isNotEmpty);
    expect(
      lineMoves.every(
        (alternative) =>
            alternative.updates.every((update) => update.entityId != arc.id),
      ),
      isTrue,
    );
    expect(
      lineMoves.every((alternative) => alternative.g1ResidualRadians != null),
      isTrue,
    );
  });

  test(
    'handles line-spline and rejects arc-only or arc-spline endpoint moves',
    () {
      final line = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(9.95, 0),
        id: 'line',
      );
      final spline = SketchSpline(const [
        SketchVector(10.04, 0),
        SketchVector(11, 0),
      ], id: 'spline');
      final lineSpline = planFor([line, spline]);
      expect(
        lineSpline.status,
        SketchContinuityRepairStatus.requiresConfirmation,
      );
      expect(lineSpline.alternatives, isNotEmpty);

      final firstArc = SketchArc(
        const SketchVector(10, 5),
        5,
        -math.pi / 2,
        0,
        id: 'arc:first',
      );
      final secondArc = SketchArc(
        const SketchVector(10.05, 5),
        5,
        -math.pi / 2,
        0,
        id: 'arc:second',
      );
      final arcArc = planFor([firstArc, secondArc]);
      expect(arcArc.status, SketchContinuityRepairStatus.impossible);
      expect(arcArc.alternatives, isEmpty);

      final arcSpline = planFor([
        firstArc,
        SketchSpline(const [
          SketchVector(10.05, 0),
          SketchVector(11, 0),
        ], id: 'spline:arc'),
      ]);
      expect(arcSpline.status, SketchContinuityRepairStatus.impossible);
      expect(arcSpline.diagnostics.join(' '), contains('Spline'));
    },
  );

  test(
    'repairs an arc-to-arc gap without changing circularity or orientation',
    () {
      final first = SketchArc(
        const SketchVector(0, 0),
        5,
        0,
        math.pi / 2,
        id: 'arc:first',
      );
      final second = SketchArc(
        const SketchVector(0, 0),
        5,
        math.pi / 2 + .01,
        math.pi,
        id: 'arc:second',
      );

      final result = planFor([first, second]);
      expect(result.status, SketchContinuityRepairStatus.requiresConfirmation);
      expect(result.alternatives, isNotEmpty);
      expect(
        result.alternatives.every(
          (alternative) => alternative.updates.every(
            (update) =>
                update.entityId == first.id || update.entityId == second.id,
          ),
        ),
        isTrue,
      );
      expect(
        result.alternatives.every(
          (alternative) => alternative.c0ResidualMillimeters <= 1e-12,
        ),
        isTrue,
      );
    },
  );

  test('unwraps arc endpoint angles across the 2pi boundary', () {
    final first = SketchArc(
      const SketchVector(0, 0),
      5,
      1.9 * math.pi,
      2 * math.pi,
      id: 'arc:wrap:first',
    );
    final second = SketchArc(
      const SketchVector(0, 0),
      5,
      .01,
      math.pi / 2,
      id: 'arc:wrap:second',
    );

    final result = planFor([first, second]);
    expect(result.status, SketchContinuityRepairStatus.requiresConfirmation);
    expect(result.alternatives, isNotEmpty);
  });

  test(
    'does not move spline controls and rejects unsupported curve-only repairs',
    () {
      final splineA = SketchSpline(const [
        SketchVector(0, 0),
        SketchVector(1, 0),
      ], id: 'spline:a');
      final splineB = SketchSpline(const [
        SketchVector(1.05, 0),
        SketchVector(2, 0),
      ], id: 'spline:b');
      final before = [splineA.toJson(), splineB.toJson()];
      final result = planFor([splineA, splineB]);

      expect(result.status, SketchContinuityRepairStatus.impossible);
      expect(result.alternatives, isEmpty);
      expect(result.diagnostics.join(' '), contains('Spline'));
      expect([splineA.toJson(), splineB.toJson()], before);
    },
  );

  test('reports external connections that a candidate would break', () {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
      id: 'first',
    );
    final second = SketchLine(
      const SketchVector(1.05, 0),
      const SketchVector(2, 0),
      id: 'second',
    );
    final external = SketchLine(
      const SketchVector(1, 0),
      const SketchVector(1, 1),
      id: 'external',
    );
    final result = planFor([first, second, external]);

    expect(
      result.alternatives.any(
        (alternative) => alternative.adjacentEffects.any(
          (effect) => {
            effect.firstEntityId,
            effect.secondEntityId,
          }.containsAll({first.id, external.id}),
        ),
      ),
      isTrue,
    );
    expect(
      result.alternatives.any(
        (alternative) =>
            alternative.status == SketchContinuityRepairStatus.impossible,
      ),
      isTrue,
    );
    expect(
      result.alternatives.any(
        (alternative) =>
            alternative.status != SketchContinuityRepairStatus.impossible,
      ),
      isTrue,
    );
  });

  test('rejects an obsolete join before producing alternatives', () {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
      id: 'first',
    );
    final second = SketchLine(
      const SketchVector(1.05, 0),
      const SketchVector(2, 0),
      id: 'second',
    );
    final join = continuity.analyze([first, second]).joins.single;
    final moved = SketchLine(
      const SketchVector(1.2, 0),
      const SketchVector(3, 0),
      id: 'second',
    );
    final result = planner.plan(
      join,
      entities: {first.id: first, moved.id: moved},
    );

    expect(result.status, SketchContinuityRepairStatus.impossible);
    expect(result.alternatives, isEmpty);
    expect(result.diagnostics.join(' '), contains('obsoleta'));
  });
}
