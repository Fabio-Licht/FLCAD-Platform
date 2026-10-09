import 'dart:math' as math;

import 'package:flcad_mobile/core/sketch_constraints/integration/arc_radius_edit_planner.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plans a two-line radius increase without mutating the entities', () {
    final fixture = _TwoLineFixture();
    final before = fixture.entities.map((entity) => entity.toJson()).toList();

    final plan = const ArcRadiusEditPlanner().plan(
      arc: fixture.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(entities: fixture.entities),
    );

    expect(plan.accepted, isTrue);
    expect(plan.boundaries.map((boundary) => boundary.kind), [
      ArcRadiusBoundaryKind.tangent,
      ArcRadiusBoundaryKind.tangent,
    ]);
    expect(
      plan.endpointUpdates.keys,
      containsAll([fixture.vertical.id, fixture.horizontal.id]),
    );
    expect(plan.maxEndpointDisplacement, greaterThan(0));
    expect(plan.maxTangencyResidual, lessThan(1e-9));
    expect(plan.requiresConfirmation, isFalse);
    expect(fixture.entities.map((entity) => entity.toJson()).toList(), before);
  });

  test(
    'plans both increasing and reducing radius with real C0/G1 contacts',
    () {
      final fixture = _TwoLineFixture();
      for (final radius in [0.5, 3.0]) {
        final plan = const ArcRadiusEditPlanner().plan(
          arc: fixture.arc,
          radius: radius,
          context: ArcRadiusEditContext(entities: fixture.entities),
        );

        expect(
          plan.accepted,
          isTrue,
          reason: 'radius=$radius diagnostic=${plan.diagnostic}',
        );
        expect(plan.maxCoincidenceResidual, closeTo(0, 1e-12));
        expect(plan.maxTangencyResidual, lessThan(1e-9));
        for (final boundary in plan.boundaries) {
          expect(boundary.endpointDisplacement, greaterThanOrEqualTo(0));
          expect(boundary.tangencyResidualAfter, lessThan(1e-9));
        }
      }
    },
  );

  test('preserves endpoints for an isolated arc', () {
    final arc = SketchArc(
      const SketchVector(0, 0),
      1,
      0,
      math.pi / 2,
      id: 'arc:isolated',
    );
    final plan = const ArcRadiusEditPlanner().plan(
      arc: arc,
      radius: 1.5,
      context: ArcRadiusEditContext(entities: [arc]),
    );

    expect(plan.accepted, isTrue);
    expect(plan.endpointUpdates, isEmpty);
    expect(plan.maxEndpointDisplacement, 0);
    expect(
      plan.boundaries.every(
        (boundary) => boundary.kind == ArcRadiusBoundaryKind.free,
      ),
      isTrue,
    );
  });

  test(
    'rejects an isolated near-zero radius without producing invalid geometry',
    () {
      final arc = SketchArc(
        const SketchVector(0, 0),
        1,
        0,
        math.pi / 2,
        id: 'arc:near-zero',
      );
      final plan = const ArcRadiusEditPlanner().plan(
        arc: arc,
        radius: 1e-12,
        context: ArcRadiusEditContext(entities: [arc]),
      );

      expect(plan.accepted, isFalse);
      expect(plan.diagnostic, isNotNull);
    },
  );

  test('preserves clockwise and major-arc orientation', () {
    final clockwise = _TangentArcFixture(endAngle: -math.pi / 2);
    final clockwisePlan = const ArcRadiusEditPlanner().plan(
      arc: clockwise.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(entities: clockwise.entities),
    );
    expect(clockwisePlan.accepted, isTrue);
    expect(
      clockwisePlan.arc!.endAngle,
      lessThan(clockwisePlan.arc!.startAngle),
    );

    final major = _TangentArcFixture(endAngle: 3 * math.pi / 2);
    final majorPlan = const ArcRadiusEditPlanner().plan(
      arc: major.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(entities: major.entities),
    );
    expect(majorPlan.accepted, isTrue, reason: majorPlan.diagnostic);
    expect(
      majorPlan.arc!.endAngle - majorPlan.arc!.startAngle,
      greaterThan(math.pi),
    );
  });

  test('handles acute and obtuse tangent-frontier angles', () {
    for (final endAngle in [math.pi / 3, 2 * math.pi / 3]) {
      final fixture = _TangentArcFixture(endAngle: endAngle);
      final plan = const ArcRadiusEditPlanner().plan(
        arc: fixture.arc,
        radius: 1.25,
        context: ArcRadiusEditContext(entities: fixture.entities),
      );
      expect(plan.accepted, isTrue, reason: plan.diagnostic);
      expect(plan.maxCoincidenceResidual, lessThan(1e-9));
      expect(plan.maxTangencyResidual, lessThan(1e-9));
    }
  });

  test('rejects parallel or nearly parallel tangent frontiers', () {
    final fixture = _TangentArcFixture(endAngle: math.pi);
    final plan = const ArcRadiusEditPlanner().plan(
      arc: fixture.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(entities: fixture.entities),
    );
    expect(plan.accepted, isFalse);

    final nearParallel = _TangentArcFixture(endAngle: math.pi - 1e-9);
    final nearPlan = const ArcRadiusEditPlanner().plan(
      arc: nearParallel.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(entities: nearParallel.entities),
    );
    expect(nearPlan.accepted, isFalse);
  });

  test('keeps endpoint identity when contacts extend near line extremes', () {
    final fixture = _TangentArcFixture(endAngle: math.pi / 2, length: .2);
    final plan = const ArcRadiusEditPlanner().plan(
      arc: fixture.arc,
      radius: 1.1,
      context: ArcRadiusEditContext(entities: fixture.entities),
    );

    expect(plan.accepted, isTrue, reason: plan.diagnostic);
    expect(
      plan.endpointUpdates[fixture.startLine.id],
      containsPair('endX', isA<double>()),
    );
    expect(
      plan.endpointUpdates[fixture.endLine.id],
      containsPair('startX', isA<double>()),
    );
    expect(plan.maxCoincidenceResidual, lessThan(1e-9));
  });

  test(
    'supports a single tangent frontier and preserves the other endpoint',
    () {
      final fixture = _TwoLineFixture();
      final plan = const ArcRadiusEditPlanner().plan(
        arc: fixture.arc,
        radius: 1.5,
        context: ArcRadiusEditContext(
          entities: [fixture.arc, fixture.vertical],
        ),
      );

      expect(plan.accepted, isTrue);
      expect(plan.endpointUpdates.keys, [fixture.vertical.id]);
      expect(plan.boundaries[1].kind, ArcRadiusBoundaryKind.free);
      expect(plan.maxTangencyResidual, lessThan(1e-9));
    },
  );

  test('reports C0-only compatibility for a non-tangent single frontier', () {
    final arc = SketchArc(
      const SketchVector(0, 0),
      1,
      0,
      math.pi / 2,
      id: 'arc:radial',
    );
    final radial = SketchLine(
      const SketchVector(1, 0),
      const SketchVector(3, 0),
      id: 'line:radial',
    );
    final plan = const ArcRadiusEditPlanner().plan(
      arc: arc,
      radius: 10,
      context: ArcRadiusEditContext(entities: [arc, radial]),
    );

    expect(plan.accepted, isTrue);
    expect(plan.maxCoincidenceResidual, closeTo(0, 1e-9));
    expect(plan.maxTangencyResidual, greaterThan(.9));
    expect(plan.diagnostic, contains('C0'));
    expect(plan.endpointUpdates[radial.id], containsPair('startX', 10.0));
  });

  test('rejects a pre-existing gap, spline frontier and fixed contact', () {
    final fixture = _TwoLineFixture();
    final gapLine = SketchLine(
      const SketchVector(1, -2),
      const SketchVector(1, 0.2),
      id: 'line:gap',
    );
    final gap = const ArcRadiusEditPlanner().plan(
      arc: fixture.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(entities: [fixture.arc, gapLine]),
    );
    expect(gap.accepted, isFalse);
    expect(gap.diagnostic, contains('gap'));

    final spline = SketchSpline(const [
      SketchVector(1, 0),
      SketchVector(1.5, -1),
      SketchVector(2, -2),
    ], id: 'spline:frontier');
    final splinePlan = const ArcRadiusEditPlanner().plan(
      arc: fixture.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(entities: [fixture.arc, spline]),
    );
    expect(splinePlan.accepted, isFalse);
    expect(splinePlan.diagnostic, contains('spline'));

    final fixed = SketchConstraint(
      type: SketchConstraintType.fixed,
      references: ['line:vertical:end'],
    );
    final fixedPlan = const ArcRadiusEditPlanner().plan(
      arc: fixture.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(
        entities: [fixture.arc, fixture.vertical, fixture.horizontal],
        constraints: [fixed],
      ),
    );
    expect(fixedPlan.accepted, isFalse);
    expect(fixedPlan.diagnostic, contains('fixada'));

    final dimensioned = SketchConstraint(
      type: SketchConstraintType.distance,
      references: [fixture.vertical.id],
      value: 5,
    );
    final dimensionedPlan = const ArcRadiusEditPlanner().plan(
      arc: fixture.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(
        entities: [fixture.arc, fixture.vertical, fixture.horizontal],
        constraints: [dimensioned],
      ),
    );
    expect(dimensionedPlan.accepted, isFalse);
    expect(dimensionedPlan.diagnostic, contains('cota'));
  });

  test(
    'recognizes explicit tangent and coincident constraints by full IDs',
    () {
      final fixture = _TwoLineFixture();
      final constraints = [
        SketchConstraint(
          type: SketchConstraintType.tangent,
          references: [fixture.arc.id, fixture.vertical.id],
        ),
        SketchConstraint(
          type: SketchConstraintType.coincident,
          references: [fixture.arc.id, '${fixture.vertical.id}:end'],
        ),
      ];
      final plan = const ArcRadiusEditPlanner().plan(
        arc: fixture.arc,
        radius: 1.5,
        context: ArcRadiusEditContext(
          entities: fixture.entities,
          constraints: constraints,
        ),
      );

      expect(plan.accepted, isTrue);
      expect(plan.boundaries.first.kind, ArcRadiusBoundaryKind.tangent);
    },
  );

  test('rejects ambiguous and degenerate frontiers deterministically', () {
    final fixture = _TwoLineFixture();
    final duplicate = SketchLine(
      const SketchVector(1, -5),
      const SketchVector(1, 0),
      id: 'line:duplicate',
    );
    final ambiguous = const ArcRadiusEditPlanner().plan(
      arc: fixture.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(
        entities: [fixture.arc, fixture.vertical, duplicate],
      ),
    );
    expect(ambiguous.accepted, isFalse);
    expect(ambiguous.diagnostic, contains('ambígua'));

    final degenerate = SketchLine(
      const SketchVector(1, 0),
      const SketchVector(1, 0),
      id: 'line:degenerate',
    );
    final rejected = const ArcRadiusEditPlanner().plan(
      arc: fixture.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(entities: [fixture.arc, degenerate]),
    );
    expect(rejected.accepted, isFalse);
  });

  test('is deterministic and exposes an explicit confirmation measurement', () {
    final fixture = _TwoLineFixture();
    final planner = const ArcRadiusEditPlanner();
    final first = planner.plan(
      arc: fixture.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(
        entities: fixture.entities.reversed,
        confirmationThreshold: .1,
      ),
    );
    final second = planner.plan(
      arc: fixture.arc,
      radius: 1.5,
      context: ArcRadiusEditContext(
        entities: fixture.entities,
        confirmationThreshold: .1,
      ),
    );

    expect(first.accepted, isTrue);
    expect(first.requiresConfirmation, isTrue);
    expect(first.arc!.center.toJson(), second.arc!.center.toJson());
    expect(first.endpointUpdates, second.endpointUpdates);
    expect(first.affectedEntityIds, second.affectedEntityIds);
  });

  test('keeps endpoints for an isolated reconstructed arc', () {
    final arc = SketchArc(
      const SketchVector(0, 0),
      7.216,
      0,
      math.pi / 2,
      id: 'arc:reconstructed-isolated',
    );
    arc.metadata['reconstructionKind'] = 'arc';
    final plan = const ArcRadiusEditPlanner().plan(
      arc: arc,
      radius: 7.5,
      context: ArcRadiusEditContext(entities: [arc]),
    );

    expect(plan.accepted, isTrue, reason: plan.diagnostic);
    expect(plan.endpointUpdates, isEmpty);
    expect(plan.hasExternalUpdates, isFalse);
    expect(plan.arc!.radius, 7.5);
    expect(plan.previousRadius, 7.216);
  });

  test(
    'does not drag C0 chord neighbors of a reconstructed assistant arc',
    () {
      const radius = 7.216;
      final arc = SketchArc(
        const SketchVector(0, 0),
        radius,
        0,
        0.6,
        id: 'arc:reconstructed-c0',
      );
      arc.metadata['reconstructionKind'] = 'arc';
      final before = SketchLine(
        SketchVector(radius * math.cos(-0.3), radius * math.sin(-0.3)),
        SketchVector(radius, 0),
        id: 'line:c0-before',
      );
      final after = SketchLine(
        SketchVector(radius * math.cos(0.6), radius * math.sin(0.6)),
        SketchVector(radius * math.cos(0.9), radius * math.sin(0.9)),
        id: 'line:c0-after',
      );
      final plan = const ArcRadiusEditPlanner().plan(
        arc: arc,
        radius: 7.5,
        context: ArcRadiusEditContext(entities: [arc, before, after]),
      );

      expect(plan.accepted, isTrue, reason: plan.diagnostic);
      expect(plan.endpointUpdates, isEmpty);
      expect(plan.hasExternalUpdates, isFalse);
      expect(plan.arc!.radius, 7.5);
      expect(before.parameters['end'], [radius, 0.0, 0.0]);
      expect(after.parameters['start'], [
        radius * math.cos(0.6),
        radius * math.sin(0.6),
        0.0,
      ]);
    },
  );

  test(
    'still requires both tangent frontiers of a reconstructed fillet',
    () {
      final fixture = _TwoLineFixture();
      fixture.arc.metadata['reconstructionKind'] = 'arc';
      final connected = const ArcRadiusEditPlanner().plan(
        arc: fixture.arc,
        radius: 1.5,
        context: ArcRadiusEditContext(entities: fixture.entities),
      );
      expect(connected.accepted, isTrue, reason: connected.diagnostic);
      expect(
        connected.endpointUpdates.keys,
        containsAll([fixture.vertical.id, fixture.horizontal.id]),
      );

      final oneFrontier = const ArcRadiusEditPlanner().plan(
        arc: fixture.arc,
        radius: 1.5,
        context: ArcRadiusEditContext(
          entities: [fixture.arc, fixture.vertical],
        ),
      );
      expect(oneFrontier.accepted, isFalse);
      expect(
        oneFrontier.diagnostic,
        contains('Não foi possível manter a tangência nas duas fronteiras.'),
      );
    },
  );
}

class _TwoLineFixture {
  _TwoLineFixture()
    : arc = SketchArc(
        const SketchVector(0, 0),
        1,
        0,
        math.pi / 2,
        id: 'arc:main',
      ),
      vertical = SketchLine(
        const SketchVector(1, -5),
        const SketchVector(1, 0),
        id: 'line:vertical',
      ),
      horizontal = SketchLine(
        const SketchVector(-5, 1),
        const SketchVector(0, 1),
        id: 'line:horizontal',
      );

  final SketchArc arc;
  final SketchLine vertical;
  final SketchLine horizontal;

  List<SketchEntity> get entities => [arc, vertical, horizontal];
}

class _TangentArcFixture {
  _TangentArcFixture({required this.endAngle, this.length = 5})
    : arc = SketchArc(
        const SketchVector(0, 0),
        1,
        0,
        endAngle,
        id: 'arc:tangent:${endAngle.toStringAsFixed(6)}',
      ),
      startLine = SketchLine(
        _pointAt(0, length, start: true),
        const SketchVector(1, 0),
        id: 'line:start:${endAngle.toStringAsFixed(6)}',
      ),
      endLine = SketchLine(
        _pointAt(endAngle, 0, start: false),
        _pointAt(endAngle, length, start: false),
        id: 'line:end:${endAngle.toStringAsFixed(6)}',
      );

  final double endAngle;
  final double length;
  final SketchArc arc;
  final SketchLine startLine;
  final SketchLine endLine;

  List<SketchEntity> get entities => [arc, startLine, endLine];

  static SketchVector _pointAt(
    double angle,
    double distance, {
    required bool start,
  }) {
    final point = SketchVector(math.cos(angle), math.sin(angle));
    final tangent = SketchVector(-math.sin(angle), math.cos(angle));
    final scale = start ? -distance : distance;
    return point + tangent.scale(scale);
  }
}
