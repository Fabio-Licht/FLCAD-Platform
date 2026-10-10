import 'dart:math' as math;

import 'package:flcad_mobile/core/sketch_assistant/sketch_reconstruction.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const diagnostic = SketchContinuityDiagnostic();

  SketchContinuityJoinDiagnostic joinOf(
    SketchContinuityAnalysis result,
    String a,
    String b,
  ) => result.joins.singleWhere(
    (item) => {item.first.entityId, item.second.entityId}.containsAll({a, b}),
  );

  test('measures C0 and G1 for line-line, including reversed endpoints', () {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
      id: 'line:first',
    );
    final reversed = SketchLine(
      const SketchVector(20, 0),
      const SketchVector(10, 0),
      id: 'line:reversed',
    );

    final result = diagnostic.analyze([first, reversed]);
    final join = result.joins.single;

    expect(join.measuredC0, isTrue);
    expect(join.measuredG1, isTrue);
    expect(join.orientedG1, isTrue);
    expect(join.continuity, SketchContinuityLevel.g1);
    expect(join.gapMillimeters, closeTo(0, 1e-12));
    expect({join.first.name, join.second.name}, {'end'});
  });

  test('start-start pairing stays G1 when both stored directions leave the join', () {
    final left = SketchLine(
      const SketchVector(10, 0),
      const SketchVector(0, 0),
      id: 'left',
    );
    final right = SketchLine(
      const SketchVector(10, 0),
      const SketchVector(20, 0),
      id: 'right',
    );

    final join = diagnostic.analyze([right, left]).joins.single;
    expect(join.measuredC0, isTrue);
    expect(join.measuredG1, isTrue);
    expect({join.first.name, join.second.name}, {'start'});
  });

  test('measures line-arc and distinguishes a declared false tangent', () {
    final line = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
      id: 'line',
    );
    final arc = SketchArc(
      const SketchVector(5, 5),
      math.sqrt(50),
      -math.pi / 4,
      0,
      id: 'arc',
    );
    final tangent = SketchConstraint(
      type: SketchConstraintType.tangent,
      references: [line.id, arc.id],
    );

    final result = diagnostic.analyze([line, arc], constraints: [tangent]);
    final join = result.joins.single;

    expect(join.measuredC0, isTrue);
    expect(join.measuredG1, isFalse);
    expect(join.declaredTangent, isTrue);
    expect(join.issue, SketchContinuityIssue.constraintMismatch);
    expect(join.tangentAngleDegrees, greaterThan(20));
    expect(join.continuity, SketchContinuityLevel.c0);

    final tangentArc = SketchArc(
      const SketchVector(10, 5),
      5,
      -math.pi / 2,
      0,
      id: 'arc:tangent',
    );
    final tangentJoin = diagnostic.analyze([line, tangentArc]).joins.single;
    expect(tangentJoin.measuredC0, isTrue);
    expect(tangentJoin.measuredG1, isTrue);
    expect(tangentJoin.issue, SketchContinuityIssue.none);

    final clockwiseArc = SketchArc(
      const SketchVector(10, -5),
      5,
      math.pi / 2,
      0,
      id: 'arc:clockwise',
    );
    final clockwiseJoin = diagnostic.analyze([line, clockwiseArc]).joins.single;
    expect(clockwiseJoin.measuredC0, isTrue);
    expect(clockwiseJoin.measuredG1, isTrue);
  });

  test('does not classify G1 for a 180° fold with parallel tangents', () {
    final line = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
      id: 'line',
    );
    // Clockwise from (10,0) back toward -X: incoming line +X, outgoing -X.
    final fold = SketchArc(
      const SketchVector(10, 5),
      5,
      -math.pi / 2,
      -math.pi,
      id: 'arc:fold',
    );

    final join = diagnostic.analyze([line, fold]).joins.single;
    expect(join.measuredC0, isTrue);
    expect(join.tangentAngleRadians, closeTo(0, 1e-9));
    expect(join.orientedTangentAngleRadians, closeTo(math.pi, 1e-9));
    expect(join.orientedG1, isFalse);
    expect(join.measuredG1, isFalse);
    expect(join.continuity, SketchContinuityLevel.c0);
  });

  test('covers the six type pairs with measured C0 and G1', () {
    final line = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
      id: 'line',
    );
    final arcA = SketchArc(
      const SketchVector(10, 5),
      5,
      -math.pi / 2,
      0,
      id: 'arc:a',
    );
    final arcB = SketchArc(
      const SketchVector(20, 5),
      5,
      math.pi,
      math.pi / 2,
      id: 'arc:b',
    );
    final verticalSpline = SketchSpline(const [
      SketchVector(15, 5),
      SketchVector(15, 15),
    ], id: 'spline:vertical');
    final splineA = SketchSpline(const [
      SketchVector(20, 5),
      SketchVector(30, 5),
    ], id: 'spline:a');
    final splineB = SketchSpline(const [
      SketchVector(30, 5),
      SketchVector(40, 5),
    ], id: 'spline:b');

    final isolated = {
      'line-line': diagnostic.analyze([
        line,
        SketchLine(
          const SketchVector(10, 0),
          const SketchVector(20, 0),
          id: 'line:b',
        ),
      ]).joins.single,
      'line-arc': diagnostic.analyze([line, arcA]).joins.single,
      'line-spline': diagnostic
          .analyze([
            line,
            SketchSpline(const [
              SketchVector(10, 0),
              SketchVector(20, 0),
            ], id: 'spline:line'),
          ])
          .joins
          .single,
      'arc-arc': diagnostic.analyze([arcA, arcB]).joins.single,
      'arc-spline': diagnostic.analyze([arcA, verticalSpline]).joins.single,
      'spline-spline': diagnostic.analyze([splineA, splineB]).joins.single,
    };

    isolated.forEach((pair, join) {
      expect(join.measuredC0, isTrue, reason: '$pair C0');
      expect(join.measuredG1, isTrue, reason: '$pair G1');
      expect(join.continuity, SketchContinuityLevel.g1, reason: '$pair level');
    });
  });

  test('uses sampled spline points, not a misleading control polygon', () {
    final line = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
      id: 'line',
    );
    final spline = SketchSpline(const [
      SketchVector(10, 0),
      SketchVector(20, 0),
    ], id: 'spline');
    spline.parameters['points'] = const [
      [10.0, 0.0, 0.0],
      [10.0, 50.0, 0.0],
      [20.0, 0.0, 0.0],
    ];

    final join = diagnostic.analyze([line, spline]).joins.single;
    expect(join.measuredC0, isTrue);
    expect(join.measuredG1, isTrue);
    expect(join.gapMillimeters, closeTo(0, 1e-12));
  });

  test('reports gaps below and above the existing gap tolerance', () {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
      id: 'first',
    );
    final smallGap = SketchLine(
      const SketchVector(1.1, 0),
      const SketchVector(2, 0),
      id: 'small-gap',
    );
    final largeGap = SketchLine(
      const SketchVector(3, 0),
      const SketchVector(4, 0),
      id: 'large-gap',
    );

    final result = diagnostic.analyze([first, smallGap, largeGap]);

    expect(joinOf(result, 'first', 'small-gap').measuredC0, isFalse);
    expect(joinOf(result, 'first', 'small-gap').measuredG1, isFalse);
    expect(joinOf(result, 'first', 'small-gap').continuity, SketchContinuityLevel.disconnected);
    expect(joinOf(result, 'first', 'small-gap').issue, SketchContinuityIssue.gap);
    expect(joinOf(result, 'first', 'large-gap').nearby, isFalse);
    expect(joinOf(result, 'first', 'large-gap').gapMillimeters, closeTo(2, 1e-12));
    expect(joinOf(result, 'first', 'large-gap').measuredG1, isFalse);
  });

  test(
    'reports crossings, branches, degeneracy and preserves constraints separately',
    () {
      final horizontal = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
        id: 'horizontal',
      );
      final vertical = SketchLine(
        const SketchVector(5, -5),
        const SketchVector(5, 5),
        id: 'vertical',
      );
      final branch = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(0, 5),
        id: 'branch',
      );
      final branchTwo = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(-5, 0),
        id: 'branch:two',
      );
      final degenerate = SketchLine(
        const SketchVector(99, 99),
        const SketchVector(99, 99),
        id: 'degenerate',
      );
      final nanLine = SketchLine(
        const SketchVector(double.nan, 0),
        const SketchVector(1, 0),
        id: 'nan',
      );

      final result = diagnostic.analyze([
        horizontal,
        vertical,
        branch,
        branchTwo,
        degenerate,
        nanLine,
      ]);

      expect(result.invalidEntityIds, containsAll(['degenerate', 'nan']));
      expect(
        result.joins.any(
          (join) => join.issue == SketchContinuityIssue.crossing,
        ),
        isTrue,
      );
      expect(result.branchingEndpoints, contains('horizontal:start'));
      expect(
        result.joins.every((join) => join.declaredTangent == false),
        isTrue,
      );
    },
  );

  test('does not mutate entities or constraints', () {
    final line = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
      id: 'line',
    );
    final other = SketchLine(
      const SketchVector(1, 0),
      const SketchVector(2, 0),
      id: 'other',
    );
    final constraint = SketchConstraint(
      type: SketchConstraintType.coincident,
      references: [line.id, other.id],
      status: ConstraintStatus.satisfied,
    );
    final beforeEntities = [line.toJson(), other.toJson()];
    final beforeConstraint = constraint.toJson();

    diagnostic.analyze([line, other], constraints: [constraint]);

    expect([line.toJson(), other.toJson()], beforeEntities);
    expect(constraint.toJson(), beforeConstraint);
  });

  test('is deterministic when entity input order changes', () {
    final entities = [
      SketchLine(const SketchVector(0, 0), const SketchVector(1, 0), id: 'a'),
      SketchLine(const SketchVector(1, 0), const SketchVector(2, 0), id: 'b'),
      SketchLine(const SketchVector(2, 0), const SketchVector(3, 0), id: 'c'),
    ];
    String signature(SketchContinuityAnalysis result) => result.joins
        .map(
          (join) =>
              '${join.first.entityId}:${join.second.entityId}:${join.first.name}:${join.second.name}:${join.issue.name}',
        )
        .join('|');

    expect(
      signature(diagnostic.analyze(entities)),
      signature(diagnostic.analyze(entities.reversed)),
    );
  });

  test('reuses the 1° circular tangency budget, not reconstruction 0.10 mm', () {
    const tolerance = SketchCircularFitTolerance();
    expect(tolerance.endpointCoincidenceMillimeters, 0.05);
    expect(tolerance.tangencyAngleRadians, closeTo(0.0175, 1e-9));
    expect(const SketchLineReconstructionTolerance().reconstructionToleranceMm, 0.10);

    final join = diagnostic
        .analyze([
          SketchLine(
            const SketchVector(0, 0),
            const SketchVector(10, 0),
            id: 'a',
          ),
          SketchLine(
            const SketchVector(10, 0),
            const SketchVector(20, 0),
            id: 'b',
          ),
        ])
        .joins
        .single;
    expect(join.gapToleranceMillimeters, 0.05);
    expect(join.tangencyToleranceRadians, closeTo(0.0175, 1e-9));
  });
}
