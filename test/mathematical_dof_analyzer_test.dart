import 'dart:io';

import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/sketch_constraints/diagnostics/mathematical_dof_analyzer.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/constraint_factory.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/sketch_factory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory project;
  late final analyzer = const MathematicalDofAnalyzer();
  setUp(
    () async => project = await Directory.systemTemp.createTemp('dof-math-'),
  );
  tearDown(() async => project.delete(recursive: true));

  test('reports exact free and horizontal line DOF from Jacobian rank', () {
    final sketch = const SketchEngineFactory().create(project)
      ..createSketch('DOF');
    final constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    expect(analyzer.analyze(sketch, constraints), isA<MathematicalDofResult>());
    final free = analyzer.analyze(sketch, constraints);
    expect(free.isExact, isTrue);
    expect(free.variableCount, 4);
    expect(free.remainingDof, 4);
    constraints.builders.horizontal.build([line.id]);
    final horizontal = analyzer.analyze(sketch, constraints);
    expect(horizontal.rank, 1);
    expect(horizontal.remainingDof, 3);
    expect(horizontal.status, MathematicalDofStatus.partiallyConstrained);
  });

  test('distinguishes conflicting supported constraints', () {
    final sketch = const SketchEngineFactory().create(project)
      ..createSketch('Diagnostics');
    final constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
    final other = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(1, 1),
    );
    constraints.builders.vertical.build([other.id]);
    constraints.builders.horizontal.build([other.id]);
    final conflicting = analyzer.analyze(sketch, constraints);
    expect(conflicting.status, MathematicalDofStatus.conflicting);
    expect(conflicting.isExact, isTrue);
  });

  test('reports a fixed line as fully constrained', () {
    final sketch = const SketchEngineFactory().create(project)
      ..createSketch('Fixed');
    final constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    constraints.builders.of(SketchConstraintType.fixed).build([line.id]);
    final result = analyzer.analyze(sketch, constraints);
    expect(result.isExact, isTrue);
    expect(result.status, MathematicalDofStatus.fullyConstrained);
    expect(result.remainingDof, 0);
  });

  test('fixed circle and arc freeze every represented parameter', () {
    final sketch = const SketchEngineFactory().create(project)
      ..createSketch('Curves');
    final constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
    final circle = sketch.builders.circle.build(const SketchVector(2, 3), 5);
    final arc = sketch.builders.arc.build(const SketchVector(-2, 1), 4, 0, 1.5);
    constraints.builders.of(SketchConstraintType.lock).build([circle.id]);
    constraints.builders.of(SketchConstraintType.fixed).build([arc.id]);
    final result = analyzer.analyze(sketch, constraints);
    expect(result.isExact, isTrue);
    expect(result.remainingDof, 0);
    expect(result.status, MathematicalDofStatus.fullyConstrained);
  });

  test('does not claim exact DOF for unsupported entities or constraints', () {
    final sketch = const SketchEngineFactory().create(project)
      ..createSketch('Unsupported');
    final constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
    sketch.builders.ellipse.build(const SketchVector(0, 0), 3, 2);
    final result = analyzer.analyze(sketch, constraints);
    expect(result.isExact, isFalse);
    expect(result.status, MathematicalDofStatus.unsupported);
    expect(result.unsupported, contains('entity:ellipse'));
  });

  test('classifies independent redundant and inconsistent equations', () {
    final redundant = analyzer.analyzeLinearSystem(
      variableCount: 2,
      jacobian: const [
        [1, 0],
        [2, 0],
      ],
      residuals: const [0, 0],
    );
    expect(redundant.status, MathematicalDofStatus.redundant);
    expect(redundant.rank, 1);
    final conflict = analyzer.analyzeLinearSystem(
      variableCount: 2,
      jacobian: const [
        [1, 0],
        [2, 0],
      ],
      residuals: const [0, 1],
    );
    expect(conflict.status, MathematicalDofStatus.conflicting);
  });

  test('separates near singularity and remains stable across scales', () {
    final singular = analyzer.analyzeLinearSystem(
      variableCount: 2,
      jacobian: const [
        [1, 0],
        [1, 1e-9],
      ],
      residuals: const [0, 0],
    );
    expect(singular.status, MathematicalDofStatus.singular);
    final unit = analyzer.analyzeLinearSystem(
      variableCount: 2,
      jacobian: const [
        [1, 0],
        [0, 1],
      ],
      residuals: const [0, 0],
    );
    final large = analyzer.analyzeLinearSystem(
      variableCount: 2,
      jacobian: const [
        [1e9, 0],
        [0, 1e9],
      ],
      residuals: const [0, 0],
    );
    expect(unit.rank, large.rank);
    expect(unit.remainingDof, large.remainingDof);
    expect(large.status, MathematicalDofStatus.fullyConstrained);
  });
}
