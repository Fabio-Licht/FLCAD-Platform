import 'dart:math' as math;

import 'package:flcad_mobile/core/sketch_assistant/sketch_continuity_repair_planner.dart';
import 'package:flcad_mobile/core/sketch_assistant/sketch_g1_continuity_repair_planner.dart';
import 'package:flcad_mobile/core/sketch_assistant/sketch_reconstruction.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const diagnostic = SketchContinuityDiagnostic();
  const planner = SketchG1ContinuityRepairPlanner();

  SketchG1RepairPlan planFor(
    List<SketchEntity> entities, {
    List<SketchConstraint> constraints = const [],
  }) {
    final analysis = diagnostic.analyze(entities, constraints: constraints);
    final join = analysis.joins.single;
    return planner.plan(
      join,
      entities: {for (final entity in entities) entity.id: entity},
      constraints: constraints,
    );
  }

  SketchArc nonTangentArc({String id = 'arc'}) =>
      SketchArc(const SketchVector(5, 3), 2, -math.pi / 3, math.pi / 3, id: id);

  test('plans a valid line-arc G1 repair with exact C0 and metrics', () {
    final arc = nonTangentArc();
    arc.metadata['tag'] = 'original';
    final before = arc.toJson();
    // Use the arc's actual start point as the line endpoint.  The contact is
    // C0 while the horizontal line and 30-degree arc tangent are not G1.
    final start = SketchVector.fromJson(arc.parameters['center']);
    final radius = (arc.parameters['radius'] as num).toDouble();
    final angle = (arc.parameters['startAngle'] as num).toDouble();
    final contact = SketchVector(
      start.x + radius * math.cos(angle),
      start.y + radius * math.sin(angle),
    );
    final actualLine = SketchLine(
      SketchVector(0, contact.y),
      contact,
      id: 'line',
    );
    final result = planFor([actualLine, arc]);

    expect(result.status, SketchContinuityRepairStatus.requiresConfirmation);
    expect(result.currentGapMillimeters, closeTo(0, 1e-10));
    expect(result.currentG1ResidualRadians, closeTo(math.pi / 6, 1e-6));
    expect(result.alternatives, isNotEmpty);
    expect(result.canRepair, isTrue);
    expect(result.alternatives.where((item) => item.isViable), isNotEmpty);
    final alternative = result.alternatives.firstWhere((item) => item.isViable);
    expect(alternative.afterGapMillimeters, lessThan(1e-8));
    expect(alternative.afterG1ResidualRadians, lessThan(1e-8));
    expect(alternative.maxDisplacementMillimeters, greaterThan(0));
    expect(arc.toJson(), before);
    expect(
      alternative.updates.first.proposedEntity.metadata,
      equals(arc.metadata),
    );
  });

  test('preserves a clockwise arc sweep while planning line tangency', () {
    final arc = SketchArc(
      const SketchVector(5, -3),
      2,
      math.pi / 3,
      -math.pi / 3,
      id: 'arc:cw',
    );
    final center = SketchVector.fromJson(arc.parameters['center']);
    final radius = (arc.parameters['radius'] as num).toDouble();
    final angle = (arc.parameters['startAngle'] as num).toDouble();
    final contact = SketchVector(
      center.x + radius * math.cos(angle),
      center.y + radius * math.sin(angle),
    );
    final line = SketchLine(SketchVector(0, contact.y), contact, id: 'line:cw');
    final result = planFor([line, arc]);

    expect(result.canRepair, isTrue);
    final update = result.alternatives
        .firstWhere((alternative) => alternative.isViable)
        .updates
        .firstWhere((item) => item.entityId == arc.id);
    final proposed = update.proposedEntity as SketchArc;
    final start = (proposed.parameters['startAngle'] as num).toDouble();
    final end = (proposed.parameters['endAngle'] as num).toDouble();
    expect((end - start).sign, lessThan(0));
  });

  test('plans arc-arc tangency while preserving radii and signed sweeps', () {
    final first = SketchArc(
      const SketchVector(0, 0),
      5,
      0,
      math.pi / 2,
      id: 'arc:first',
    );
    final second = SketchArc(
      const SketchVector(5, 3),
      3,
      -math.pi / 2,
      0,
      id: 'arc:second',
    );
    final result = planFor([second, first]);

    expect(result.status, SketchContinuityRepairStatus.requiresConfirmation);
    expect(result.canRepair, isTrue);
    final viable = result.alternatives.where((item) => item.isViable);
    expect(viable, isNotEmpty);
    for (final alternative in viable) {
      for (final update in alternative.updates) {
        final proposed = update.proposedEntity;
        expect(proposed, isA<SketchArc>());
        final arc = proposed as SketchArc;
        expect(arc.parameters['radius'], anyOf(5, 3));
        final start = (arc.parameters['startAngle'] as num).toDouble();
        final end = (arc.parameters['endAngle'] as num).toDouble();
        expect((end - start).sign, greaterThan(0));
      }
      expect(alternative.afterGapMillimeters, lessThan(1e-8));
      expect(alternative.afterG1ResidualRadians, lessThan(1e-8));
    }
  });

  test('blocks spline joins with an explicit non-deformation diagnosis', () {
    final line = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
      id: 'line',
    );
    final spline = SketchSpline(const [
      SketchVector(1, 0),
      SketchVector(2, .2),
    ], id: 'spline');
    final result = planFor([line, spline]);

    expect(result.status, SketchContinuityRepairStatus.impossible);
    expect(result.alternatives, isEmpty);
    expect(result.diagnostics.join(' '), contains('Spline'));
  });

  test('fixed, dimensional and tangent constraints block mutation', () {
    final arc = nonTangentArc();
    final center = SketchVector.fromJson(arc.parameters['center']);
    final radius = (arc.parameters['radius'] as num).toDouble();
    final angle = (arc.parameters['startAngle'] as num).toDouble();
    final contact = SketchVector(
      center.x + radius * math.cos(angle),
      center.y + radius * math.sin(angle),
    );
    final line = SketchLine(const SketchVector(0, 0), contact, id: 'line');
    final constraints = [
      SketchConstraint(
        id: 'fixed-arc',
        type: SketchConstraintType.fixed,
        references: [arc.id],
      ),
    ];
    final result = planFor([line, arc], constraints: constraints);

    expect(result.status, SketchContinuityRepairStatus.impossible);
    expect(result.alternatives, isEmpty);
    expect(result.protectedEntityIds, contains(arc.id));
    expect(result.diagnostics.join(' '), contains('protegido'));
  });

  test('rejects a gap beyond the existing repair tolerance', () {
    final arc = nonTangentArc();
    final line = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(6.2, 0),
      id: 'line',
    );
    final result = planFor([line, arc]);

    expect(result.status, SketchContinuityRepairStatus.impossible);
    expect(result.alternatives, isEmpty);
    expect(result.diagnostics.join(' '), contains('excede'));
  });

  test('rejects an obsolete join after an endpoint changed', () {
    final arc = nonTangentArc();
    final center = SketchVector.fromJson(arc.parameters['center']);
    final radius = (arc.parameters['radius'] as num).toDouble();
    final angle = (arc.parameters['startAngle'] as num).toDouble();
    final contact = SketchVector(
      center.x + radius * math.cos(angle),
      center.y + radius * math.sin(angle),
    );
    final line = SketchLine(
      SketchVector(0, contact.y),
      contact,
      id: 'line:stale',
    );
    final join = diagnostic.analyze([line, arc]).joins.single;
    final moved = SketchLine(
      SketchVector(0, contact.y),
      contact + const SketchVector(.01, 0),
      id: line.id,
    );
    final result = planner.plan(join, entities: {moved.id: moved, arc.id: arc});
    expect(result.status, SketchContinuityRepairStatus.impossible);
    expect(result.alternatives, isEmpty);
    expect(result.diagnostics.join(' '), contains('obsoleta'));
  });

  test('rejects a candidate that would break an external C0 connection', () {
    final arc = nonTangentArc();
    final center = SketchVector.fromJson(arc.parameters['center']);
    final radius = (arc.parameters['radius'] as num).toDouble();
    final startAngle = (arc.parameters['startAngle'] as num).toDouble();
    final contact = SketchVector(
      center.x + radius * math.cos(startAngle),
      center.y + radius * math.sin(startAngle),
    );
    final line = SketchLine(
      SketchVector(0, contact.y),
      contact,
      id: 'line:selected',
    );
    final external = SketchLine(
      SketchVector(
        center.x +
            radius * math.cos((arc.parameters['endAngle'] as num).toDouble()),
        center.y +
            radius * math.sin((arc.parameters['endAngle'] as num).toDouble()),
      ),
      const SketchVector(8, 4),
      id: 'line:external',
    );
    final entities = [line, arc, external];
    final join = diagnostic
        .analyze(entities)
        .joins
        .firstWhere(
          (candidate) => {
            candidate.first.entityId,
            candidate.second.entityId,
          }.containsAll({line.id, arc.id}),
        );
    final result = planner.plan(
      join,
      entities: {for (final entity in entities) entity.id: entity},
    );

    expect(result.alternatives, isNotEmpty);
    expect(
      result.alternatives.every(
        (alternative) =>
            alternative.status == SketchContinuityRepairStatus.impossible,
      ),
      isTrue,
    );
    expect(
      result.alternatives.expand((alternative) => alternative.diagnostics),
      contains(
        isA<String>().having((value) => value, 'message', contains('rompe')),
      ),
    );
  });

  test('rejects degenerate, crossing and ambiguous joins', () {
    final degenerate = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(0, 0),
      id: 'degenerate',
    );
    final arc = nonTangentArc();
    expect(
      diagnostic.analyze([degenerate, arc]).invalidEntityIds,
      contains(degenerate.id),
    );

    final first = SketchArc(
      const SketchVector(0, 0),
      5,
      0,
      math.pi / 2,
      id: 'first',
    );
    final second = SketchArc(
      const SketchVector(0, 0),
      5,
      0,
      math.pi / 2,
      id: 'second',
    );
    final before = [first.toJson(), second.toJson()];
    final result = planFor([first, second]);
    expect(result.diagnostics, isNotEmpty);
    expect([first.toJson(), second.toJson()], before);
  });

  test('selection order does not change the deterministic alternatives', () {
    final arc = nonTangentArc();
    final center = SketchVector.fromJson(arc.parameters['center']);
    final radius = (arc.parameters['radius'] as num).toDouble();
    final angle = (arc.parameters['startAngle'] as num).toDouble();
    final contact = SketchVector(
      center.x + radius * math.cos(angle),
      center.y + radius * math.sin(angle),
    );
    final line = SketchLine(const SketchVector(0, 0), contact, id: 'line');
    final one = planFor([line, arc]);
    final two = planFor([arc, line]);
    String signature(SketchG1RepairPlan plan) => plan.alternatives
        .map(
          (alternative) => alternative.updates
              .map((update) => '${update.entityId}:${update.operation}')
              .join('|'),
        )
        .join(';');
    expect(signature(one), signature(two));
  });

  test(
    'accepts semicircular, major and small sweeps without complementing them',
    () {
      for (final entry in <(String, double)>[
        ('semi', math.pi),
        ('major', 1.5 * math.pi),
        ('small', .05),
        ('cw-major', -1.5 * math.pi),
      ]) {
        final arc = SketchArc(
          const SketchVector(0, 0),
          2,
          0,
          entry.$2,
          id: 'arc:${entry.$1}',
        );
        final contact = SketchVector(2, 0);
        final line = SketchLine(
          const SketchVector(0, 0),
          contact,
          id: 'line:${entry.$1}',
        );
        final result = planFor([line, arc]);
        expect(result.canRepair, isTrue, reason: entry.$1);
        for (final alternative in result.alternatives.where(
          (item) => item.isViable,
        )) {
          for (final update in alternative.updates.where(
            (item) => item.entityId == arc.id,
          )) {
            final original = update.originalEntity as SketchArc;
            final proposed = update.proposedEntity as SketchArc;
            final originalSweep =
                (original.parameters['endAngle'] as num).toDouble() -
                (original.parameters['startAngle'] as num).toDouble();
            final proposedSweep =
                (proposed.parameters['endAngle'] as num).toDouble() -
                (proposed.parameters['startAngle'] as num).toDouble();
            expect(proposedSweep.sign, originalSweep.sign, reason: entry.$1);
            expect(proposedSweep.abs(), closeTo(originalSweep.abs(), 1e-9));
            expect(
              (proposed.parameters['radius'] as num).toDouble(),
              closeTo((original.parameters['radius'] as num).toDouble(), 1e-9),
            );
          }
        }
      }
    },
  );

  test(
    'reports the maximum displacement inside an arc, not only endpoints',
    () {
      final arc = nonTangentArc();
      final center = SketchVector.fromJson(arc.parameters['center']);
      final radius = (arc.parameters['radius'] as num).toDouble();
      final angle = (arc.parameters['startAngle'] as num).toDouble();
      final contact = SketchVector(
        center.x + radius * math.cos(angle),
        center.y + radius * math.sin(angle),
      );
      final line = SketchLine(const SketchVector(0, 0), contact, id: 'line');
      final result = planFor([line, arc]);
      for (final alternative in result.alternatives.where(
        (item) => item.isViable,
      )) {
        for (final update in alternative.updates.where(
          (item) => item.entityId == arc.id,
        )) {
          final original = update.originalEntity as SketchArc;
          final proposed = update.proposedEntity as SketchArc;
          double pointDistance(double parameter) {
            SketchVector point(SketchArc value) {
              final c = SketchVector.fromJson(value.parameters['center']);
              final r = (value.parameters['radius'] as num).toDouble();
              final start = (value.parameters['startAngle'] as num).toDouble();
              final end = (value.parameters['endAngle'] as num).toDouble();
              final angle = start + (end - start) * parameter;
              return SketchVector(
                c.x + r * math.cos(angle),
                c.y + r * math.sin(angle),
                c.z,
              );
            }

            final delta = point(proposed) - point(original);
            return math.sqrt(delta.dot(delta));
          }

          var sampledMaximum = 0.0;
          for (var index = 0; index <= 2000; index++) {
            sampledMaximum = math.max(
              sampledMaximum,
              pointDistance(index / 2000),
            );
          }
          expect(
            update.displacementMillimeters,
            greaterThanOrEqualTo(sampledMaximum - 1e-9),
          );
        }
      }
    },
  );

  test('preserves a counter-clockwise sweep that crosses the 2-pi branch', () {
    final startAngle = 1.75 * math.pi;
    final endAngle = 2.25 * math.pi;
    final arc = SketchArc(
      const SketchVector(0, 0),
      2,
      startAngle,
      endAngle,
      id: 'arc:wrapped',
    );
    final contact = SketchVector(
      2 * math.cos(startAngle),
      2 * math.sin(startAngle),
    );
    final line = SketchLine(
      SketchVector(contact.x - 2, contact.y),
      contact,
      id: 'line:wrapped',
    );
    final result = planFor([line, arc]);
    expect(result.canRepair, isTrue);
    final update = result.alternatives
        .firstWhere((alternative) => alternative.isViable)
        .updates
        .firstWhere((item) => item.entityId == arc.id);
    final proposed = update.proposedEntity as SketchArc;
    final sweep =
        (proposed.parameters['endAngle'] as num).toDouble() -
        (proposed.parameters['startAngle'] as num).toDouble();
    expect(sweep, closeTo(endAngle - startAngle, 1e-9));
  });

  test(
    'accepts an explicitly reversed diagnostic without changing the plan',
    () {
      final arc = nonTangentArc();
      final center = SketchVector.fromJson(arc.parameters['center']);
      final radius = (arc.parameters['radius'] as num).toDouble();
      final angle = (arc.parameters['startAngle'] as num).toDouble();
      final contact = SketchVector(
        center.x + radius * math.cos(angle),
        center.y + radius * math.sin(angle),
      );
      final line = SketchLine(SketchVector(0, contact.y), contact, id: 'line');
      final join = diagnostic.analyze([line, arc]).joins.single;
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
      final entities = {line.id: line, arc.id: arc};
      final direct = planner.plan(join, entities: entities);
      final inverse = planner.plan(reversed, entities: entities);
      expect(inverse.status, direct.status);
      expect(inverse.canRepair, direct.canRepair);
      expect(
        inverse.alternatives
            .expand((alternative) => alternative.affectedEntityIds)
            .toSet(),
        equals(
          direct.alternatives
              .expand((alternative) => alternative.affectedEntityIds)
              .toSet(),
        ),
      );
    },
  );
}
