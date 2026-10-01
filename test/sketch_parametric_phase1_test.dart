import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/core/sketch_constraints/api/constraint_api.dart';
import 'package:flcad_mobile/core/sketch_constraints/diagnostics/constraint_diagnostics.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/constraint_factory.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_editor/analytics/editor_analytics.dart';
import 'package:flcad_mobile/core/sketch_editor/editing/degrees_of_freedom.dart';
import 'package:flcad_mobile/core/sketch_engine/api/sketch_engine_api.dart';
import 'package:flcad_mobile/core/sketch_engine/constraints/constraints_scope.dart';
import 'package:flcad_mobile/core/sketch_engine/geometry/sketch_spline_geometry.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/sketch_factory.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory project;
  late SketchEngineApi sketch;
  late ConstraintApi constraints;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('flcad_parametric_phase1_');
    sketch = const SketchEngineFactory().create(project)
      ..createSketch('Parametric Phase 1');
    constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
  });

  tearDown(() async {
    if (await project.exists()) await project.delete(recursive: true);
  });

  test('Sketch declares the durable constraint solver capability', () {
    expect(SketchConstraintsScope.implemented, isTrue);
  });

  test(
    'Equal drives line length and circular radius deterministically',
    () async {
      final referenceLine = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(12, 0),
      );
      final targetLine = sketch.builders.line.build(
        const SketchVector(20, 5),
        const SketchVector(23, 9),
      );
      final referenceCircle = sketch.builders.circle.build(
        const SketchVector(0, 20),
        8,
      );
      final targetCircle = sketch.builders.circle.build(
        const SketchVector(20, 20),
        2,
      );
      constraints.builders.equal.build([referenceLine.id, targetLine.id]);
      constraints.builders.equal.build([referenceCircle.id, targetCircle.id]);

      final result = await constraints.solve();

      expect(result.statistics.failed, 0);
      expect(targetLine.parameters['length'], closeTo(12, 1e-8));
      expect(targetCircle.parameters['radius'], closeTo(8, 1e-8));
    },
  );

  test(
    'Tangent projects a circle to a trusted line without changing radius',
    () async {
      final line = sketch.builders.line.build(
        const SketchVector(-10, 0),
        const SketchVector(10, 0),
      );
      final circle = sketch.builders.circle.build(const SketchVector(3, 7), 2);
      constraints.builders.tangent.build([line.id, circle.id]);

      await constraints.solve();

      final center = SketchVector.fromJson(circle.parameters['center']);
      expect(center.x, closeTo(3, 1e-8));
      expect(center.y, closeTo(2, 1e-8));
      expect(circle.parameters['radius'], 2.0);
    },
  );

  test('Tangent rotates a target line to a trusted circle', () async {
    final circle = sketch.builders.circle.build(const SketchVector(5, 0), 1);
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    constraints.builders.tangent.build([circle.id, line.id]);

    await constraints.solve();

    final start = SketchVector.fromJson(line.parameters['start']);
    final end = SketchVector.fromJson(line.parameters['end']);
    final center = SketchVector.fromJson(circle.parameters['center']);
    final delta = end - start;
    final numerator =
        ((center.x - start.x) * delta.y - (center.y - start.y) * delta.x).abs();
    final distance =
        numerator / math.sqrt(delta.x * delta.x + delta.y * delta.y);
    expect(distance, closeTo(1, 1e-8));
  });

  test(
    'connected constraints converge independently of priority order',
    () async {
      final reference = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 4),
      );
      final second = sketch.builders.line.build(
        const SketchVector(0, 10),
        const SketchVector(4, 15),
      );
      final third = sketch.builders.line.build(
        const SketchVector(0, 20),
        const SketchVector(3, 28),
      );
      constraints.builders.parallel.build([
        reference.id,
        second.id,
      ], priority: 20);
      constraints.builders.parallel.build([second.id, third.id], priority: 10);
      constraints.builders.horizontal.build([reference.id], priority: 0);

      await constraints.solve();

      for (final line in [reference, second, third]) {
        expect(
          (line.parameters['angleDegrees'] as num).toDouble().abs(),
          lessThan(1e-7),
        );
      }
    },
  );

  test('fixed target rejects movement and preserves exact geometry', () async {
    final anchor = sketch.builders.point.build(const SketchVector(0, 0));
    final target = sketch.builders.point.build(const SketchVector(9, 7));
    constraints.builders.of(SketchConstraintType.fixed).build([target.id]);
    constraints.builders.coincident.build([anchor.id, target.id]);

    final result = await constraints.solve();

    expect(target.parameters['point'], [9.0, 7.0, 0.0]);
    expect(target.locked, isTrue);
    expect(result.success, isFalse);
    expect(
      result.diagnostics.map((diagnostic) => diagnostic.kind),
      contains(ConstraintDiagnosticKind.overConstraint),
    );
  });

  test(
    'constraint undo restores geometry before removing its contract',
    () async {
      final line = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(4, 3),
      );
      final originalEnd = List<double>.from(
        (line.parameters['end'] as List).cast<num>().map(
          (value) => value.toDouble(),
        ),
      );
      final horizontal = constraints.builders.horizontal.build([line.id]);
      await constraints.solve(only: [horizontal.id]);
      expect(sketch.entity(line.id)!.parameters['end'], [4.0, 0.0, 0.0]);

      expect(constraints.engine.undo(), isTrue);
      expect(sketch.entity(line.id)!.parameters['end'], originalEnd);
      expect(constraints.engine.constraints, contains(horizontal.id));
      expect(constraints.engine.undo(), isTrue);
      expect(constraints.engine.constraints, isNot(contains(horizontal.id)));
    },
  );

  test('fixed endpoint still permits the opposite endpoint to be driven', () {
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    constraints.builders.of(SketchConstraintType.fixed).build([
      '${line.id}:start',
    ]);

    constraints.createDrivingDimension(
      type: SketchDimensionType.linear,
      references: [line.id],
      value: 25,
      anchorReference: '${line.id}:start',
    );

    expect(line.parameters['start'], [0.0, 0.0, 0.0]);
    expect(line.parameters['end'], [25.0, 0.0, 0.0]);
    expect(line.locked, isFalse);
  });

  test(
    'unsupported relations are diagnosed instead of reported as solved',
    () async {
      final first = sketch.builders.point.build(const SketchVector(-2, 0));
      final second = sketch.builders.point.build(const SketchVector(2, 0));
      final symmetric = constraints.builders
          .of(SketchConstraintType.symmetric)
          .build([first.id, second.id]);

      final result = await constraints.solve(only: [symmetric.id]);

      expect(result.solvedIds, isNot(contains(symmetric.id)));
      expect(result.success, isFalse);
      expect(
        result.diagnostics.map((diagnostic) => diagnostic.message),
        contains(contains('not implemented')),
      );
    },
  );

  test(
    'degrees of freedom reflect entity semantics and full definition',
    () async {
      final point = sketch.builders.point.build(const SketchVector(4, 9));
      final before = const DegreesOfFreedomReader().read(
        sketch,
        constraints,
        EditorAnalytics(),
      );
      expect(before.remaining, 2);
      expect(before.constraintStatus, 'underdefined');

      constraints.builders.of(SketchConstraintType.fixed).build([point.id]);
      await constraints.solve();
      final after = const DegreesOfFreedomReader().read(
        sketch,
        constraints,
        EditorAnalytics(),
      );
      expect(after.remaining, 0);
      expect(after.constraintStatus, 'fully-defined');
    },
  );

  test('driving angle remains finite and survives persistence', () async {
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final dimension = constraints.createDrivingDimension(
      type: SketchDimensionType.angular,
      references: [line.id],
      value: 35,
      anchorReference: '${line.id}:start',
    );
    await sketch.persist();
    await constraints.persist();

    final reopenedSketch = const SketchEngineFactory().create(project);
    await reopenedSketch.load();
    final reopenedConstraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: reopenedSketch,
    );
    await reopenedConstraints.load();

    expect(reopenedConstraints.dimensions.single.id, dimension.id);
    expect(reopenedConstraints.dimensions.single.value, 35);
    final reopenedLine = reopenedSketch.entity(line.id)!;
    expect(
      (reopenedLine.parameters['angleDegrees'] as num).toDouble(),
      closeTo(35, 1e-8),
    );
    expect(
      (reopenedLine.parameters['length'] as num).toDouble(),
      closeTo(10, 1e-8),
    );
    expect(math.sin(35 * math.pi / 180), isNotNaN);
  });

  test('explicit Blend uses tangent controls at both selected endpoints', () {
    final controls = SketchTangentBlendGeometry.betweenSelectedEndpoints(
      const SketchVector(0, 0),
      const SketchVector(-10, 0),
      const SketchVector(20, 10),
      const SketchVector(20, 20),
      firstTangentLength: 3,
      secondTangentLength: 7,
    );

    expect(controls[0].toJson(), [0.0, 0.0, 0.0]);
    expect(controls[1].toJson(), [3.0, 0.0, 0.0]);
    // P3-P2 follows the selected line direction at the second endpoint.
    expect(controls[2].toJson(), [20.0, 3.0, 0.0]);
    expect(controls[3].toJson(), [20.0, 10.0, 0.0]);
  });

  test(
    'explicit endpoint coincidence moves only the selected endpoint',
    () async {
      final anchor = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final target = sketch.builders.line.build(
        const SketchVector(30, 5),
        const SketchVector(40, 5),
      );
      constraints.builders.coincident.build([
        '${anchor.id}:end',
        '${target.id}:start',
      ]);

      final result = await constraints.solve();

      expect(result.success, isTrue);
      expect(target.parameters['start'], [10.0, 0.0, 0.0]);
      expect(target.parameters['end'], [40.0, 5.0, 0.0]);
    },
  );

  test('midpoint and point on line use explicit point references', () async {
    final support = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(20, 0),
    );
    final midpoint = sketch.builders.point.build(const SketchVector(3, 9));
    final projected = sketch.builders.point.build(const SketchVector(16, 7));
    constraints.builders.of(SketchConstraintType.midpoint).build([
      midpoint.id,
      support.id,
    ]);
    constraints.builders.of(SketchConstraintType.pointOnLine).build([
      projected.id,
      support.id,
    ]);

    final result = await constraints.solve();

    expect(result.success, isTrue);
    expect(midpoint.parameters['point'], [10.0, 0.0, 0.0]);
    expect(projected.parameters['point'], [16.0, 0.0, 0.0]);
  });

  test('point-to-point driving dimension keeps first point as anchor', () {
    final first = sketch.builders.point.build(const SketchVector(2, 3));
    final second = sketch.builders.point.build(const SketchVector(5, 7));

    final dimension = constraints.createDrivingDimension(
      type: SketchDimensionType.linear,
      references: [first.id, second.id],
      value: 10,
      anchorReference: first.id,
      labelX: 4,
      labelY: 6,
    );

    expect(first.parameters['point'], [2.0, 3.0, 0.0]);
    final moved = SketchVector.fromJson(second.parameters['point']);
    expect(
      (moved - const SketchVector(2, 3)).dot(moved - const SketchVector(2, 3)),
      closeTo(100, 1e-8),
    );
    expect(dimension.references, [first.id, second.id]);
    expect(dimension.anchorReference, first.id);
  });

  test('point-to-point dimension survives save open and undo redo', () async {
    final first = sketch.builders.point.build(const SketchVector(0, 0));
    final second = sketch.builders.point.build(const SketchVector(3, 4));
    final dimension = constraints.createDrivingDimension(
      type: SketchDimensionType.linear,
      references: [first.id, second.id],
      value: 12,
      anchorReference: first.id,
    );
    expect(constraints.undoDimensionEdit(), isTrue);
    expect(constraints.redoDimensionEdit(), isTrue);
    await sketch.persist();
    await constraints.persist();

    final reopenedSketch = const SketchEngineFactory().create(project);
    await reopenedSketch.load();
    final reopenedConstraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: reopenedSketch,
    );
    await reopenedConstraints.load();

    final restored = reopenedConstraints.dimensions.singleWhere(
      (item) => item.id == dimension.id,
    );
    expect(restored.references, [first.id, second.id]);
    expect(restored.anchorReference, first.id);
    expect(restored.value, 12);
  });

  test('horizontal and vertical point dimensions preserve the other axis', () {
    final horizontalAnchor = sketch.builders.point.build(
      const SketchVector(0, 0),
    );
    final horizontalTarget = sketch.builders.point.build(
      const SketchVector(3, 4),
    );
    constraints.createDrivingDimension(
      type: SketchDimensionType.horizontal,
      references: [horizontalAnchor.id, horizontalTarget.id],
      value: 12,
      anchorReference: horizontalAnchor.id,
    );
    expect(horizontalTarget.parameters['point'], [12.0, 4.0, 0.0]);

    final verticalAnchor = sketch.builders.point.build(
      const SketchVector(20, 1),
    );
    final verticalTarget = sketch.builders.point.build(
      const SketchVector(24, 6),
    );
    constraints.createDrivingDimension(
      type: SketchDimensionType.vertical,
      references: [verticalAnchor.id, verticalTarget.id],
      value: 9,
      anchorReference: verticalAnchor.id,
    );
    expect(verticalTarget.parameters['point'], [24.0, 10.0, 0.0]);
  });

  test('angular dimension uses first line as reference and rotates target', () {
    final reference = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final target = sketch.builders.line.build(
      const SketchVector(20, 0),
      const SketchVector(20, 8),
    );
    constraints.createDrivingDimension(
      type: SketchDimensionType.angular,
      references: [reference.id, target.id],
      value: 30,
      anchorReference: '${target.id}:start',
    );

    expect(target.parameters['start'], [20.0, 0.0, 0.0]);
    expect(
      (target.parameters['angleDegrees'] as num).toDouble(),
      closeTo(30, 1e-8),
    );
    expect((target.parameters['length'] as num).toDouble(), closeTo(8, 1e-8));
  });

  test('editing an angular dimension preserves its original side', () async {
    final reference = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final target = sketch.builders.line.build(
      const SketchVector(20, 0),
      const SketchVector(20, -8),
    );
    final dimension = constraints.createDrivingDimension(
      type: SketchDimensionType.angular,
      references: [reference.id, target.id],
      value: 30,
      anchorReference: '${target.id}:start',
    );
    expect(dimension.orientationSign, -1);
    expect(SketchVector.fromJson(target.parameters['end']).y, lessThan(0));

    constraints.driveDimension(dimension.id, 60);
    expect(
      (target.parameters['angleDegrees'] as num).toDouble(),
      closeTo(-60, 1e-8),
    );
    expect(SketchVector.fromJson(target.parameters['end']).y, lessThan(0));
    await sketch.persist();
    await constraints.persist();

    final reopenedSketch = const SketchEngineFactory().create(project);
    await reopenedSketch.load();
    final reopenedConstraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: reopenedSketch,
    );
    await reopenedConstraints.load();
    final restored = reopenedConstraints.dimensions.singleWhere(
      (item) => item.id == dimension.id,
    );
    expect(restored.orientationSign, -1);
  });

  test('ordinate dimensions drive signed X and Y coordinates', () {
    final point = sketch.builders.point.build(const SketchVector(8, -3));
    final x = constraints.createDrivingDimension(
      type: SketchDimensionType.ordinateX,
      references: [point.id],
      value: -12,
      anchorReference: point.id,
    );
    expect(x.value, -12);
    expect(point.parameters['point'], [-12.0, -3.0, 0.0]);

    final y = constraints.createDrivingDimension(
      type: SketchDimensionType.ordinateY,
      references: [point.id],
      value: 0,
      anchorReference: point.id,
    );
    expect(y.value, 0);
    expect(point.parameters['point'], [-12.0, 0.0, 0.0]);
  });

  test(
    'parallel line distance drives the second line without changing angle',
    () {
      final reference = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final target = sketch.builders.line.build(
        const SketchVector(0, 4),
        const SketchVector(10, 4),
      );
      final dimension = constraints.createDrivingDimension(
        type: SketchDimensionType.parallelDistance,
        references: [reference.id, target.id],
        value: 12,
        anchorReference: reference.id,
      );
      expect(dimension.value, 12);
      expect(SketchVector.fromJson(target.parameters['start']).y, 12);
      expect(SketchVector.fromJson(target.parameters['end']).y, 12);
    },
  );
}
