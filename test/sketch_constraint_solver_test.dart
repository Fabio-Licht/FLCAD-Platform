import 'dart:io';
import 'package:flcad_mobile/app/bootstrap/engineering_bootstrap.dart';
import 'package:flcad_mobile/core/engineering_studio/properties/property_inspector.dart';
import 'package:flcad_mobile/core/sketch_constraints/analytics/constraint_analytics.dart';
import 'package:flcad_mobile/core/sketch_constraints/api/constraint_api.dart';
import 'package:flcad_mobile/core/sketch_constraints/commands/fel_constraint_commands.dart';
import 'package:flcad_mobile/core/sketch_constraints/diagnostics/constraint_diagnostics.dart';
import 'package:flcad_mobile/core/sketch_constraints/graph/constraint_graph.dart';
import 'package:flcad_mobile/core/sketch_constraints/history/constraint_history.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/constraint_factory.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/constraint_selection.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/constraint_studio.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_constraints/repository/constraint_repository.dart';
import 'package:flcad_mobile/core/sketch_constraints/runtime/constraint_runtime.dart';
import 'package:flcad_mobile/core/sketch_engine/api/sketch_engine_api.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/sketch_factory.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory project;
  late SketchEngineApi sketch;
  late ConstraintApi api;
  setUp(() async {
    project = await Directory.systemTemp.createTemp('flcad_constraints_');
    sketch = const SketchEngineFactory().create(project)
      ..createSketch('Parametric');
    api = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
  });
  tearDown(() async {
    if (await project.exists()) await project.delete(recursive: true);
  });

  test(
    'solver applies horizontal, coincident and incremental dirty solve',
    () async {
      final line = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(4, 3),
      );
      final a = sketch.builders.point.build(const SketchVector(1, 2));
      final b = sketch.builders.point.build(const SketchVector(9, 9));
      final horizontal = api.builders.horizontal.build([line.id], priority: 10);
      final coincident = api.builders.coincident.build([a.id, b.id]);
      final result = await api.solve();
      expect(result.solvedIds, containsAll([horizontal.id, coincident.id]));
      expect(line.parameters['end'], [4.0, 0.0, 0.0]);
      expect(b.parameters['point'], a.parameters['point']);
      api.engine.solver.markDirty(
        horizontal.id,
        api.engine.graphs.dependencies,
      );
      final partial = await api.solve(only: [horizontal.id]);
      expect(partial.statistics.iterations, 1);
      expect(api.engine.solver.dirty, isNot(contains(horizontal.id)));
    },
  );

  test('G-125 corrects scanned geometry from reference to target', () async {
    final reference = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final parallelTarget = sketch.builders.line.build(
      const SketchVector(3, 4),
      const SketchVector(7, 7),
    );
    final perpendicularTarget = sketch.builders.line.build(
      const SketchVector(12, 2),
      const SketchVector(16, 5),
    );
    final parallelLength = (parallelTarget.parameters['length'] as num)
        .toDouble();
    final perpendicularLength =
        (perpendicularTarget.parameters['length'] as num).toDouble();
    api.builders.parallel.build([reference.id, parallelTarget.id]);
    api.builders.perpendicular.build([reference.id, perpendicularTarget.id]);

    await api.solve();

    expect(parallelTarget.parameters['angleDegrees'], closeTo(0, 1e-9));
    expect(parallelTarget.parameters['length'], closeTo(parallelLength, 1e-9));
    expect(perpendicularTarget.parameters['angleDegrees'], closeTo(90, 1e-9));
    expect(
      perpendicularTarget.parameters['length'],
      closeTo(perpendicularLength, 1e-9),
    );
    expect(reference.parameters['end'], [10.0, 0.0, 0.0]);
  });

  test('G-125 concentric preserves target radius', () async {
    final reference = sketch.builders.circle.build(
      const SketchVector(12, -4),
      7,
    );
    final target = sketch.builders.circle.build(
      const SketchVector(12.3, -3.8),
      2,
    );
    api.builders.of(SketchConstraintType.concentric).build([
      reference.id,
      target.id,
    ]);

    await api.solve();

    expect(target.parameters['center'], reference.parameters['center']);
    expect(target.parameters['radius'], 2);
  });

  test('G-125 endpoint coincidence moves only the target endpoint', () async {
    final reference = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(5, 0),
    );
    final target = sketch.builders.line.build(
      const SketchVector(5.2, 0.1),
      const SketchVector(8, 2),
    );
    final untouchedEnd = List<double>.from(
      (target.parameters['end'] as List).cast<num>().map((e) => e.toDouble()),
    );
    api.builders.coincident.build([
      '${reference.id}:end',
      '${target.id}:start',
    ]);

    await api.solve();

    expect(target.parameters['start'], reference.parameters['end']);
    expect(target.parameters['end'], untouchedEnd);
  });

  test('coincident supports spline endpoints from mesh sketches', () async {
    final reference = sketch.builders.spline.build([
      const SketchVector(0, 0),
      const SketchVector(5, 0),
    ]);
    final target = sketch.builders.spline.build([
      const SketchVector(5.2, 0.1),
      const SketchVector(8, 2),
    ]);
    api.builders.coincident.build([
      '${reference.id}:end',
      '${target.id}:start',
    ]);

    await api.solve();

    expect(
      (target.parameters['points'] as List).first,
      (reference.parameters['points'] as List).last,
    );
    expect(
      (target.parameters['sampledPoints'] as List).first,
      (reference.parameters['sampledPoints'] as List).last,
    );
  });

  test(
    'detects missing references, overdefinition and duplicate constraints',
    () async {
      final line = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(1, 1),
      );
      api.builders.horizontal.build([line.id]);
      api.builders.vertical.build([line.id]);
      api.builders.radius.build(['missing'], value: 2);
      api.builders.distance.build([line.id], value: 2, priority: 2);
      api.builders.distance.build([line.id], value: 3, priority: 1);
      final result = await api.solve();
      expect(
        result.diagnostics.map((d) => d.kind),
        containsAll([
          ConstraintDiagnosticKind.overConstraint,
          ConstraintDiagnosticKind.missingReference,
          ConstraintDiagnosticKind.conflict,
        ]),
      );
      expect(() => api.builders.horizontal.build([line.id]), throwsStateError);
      expect(api.engine.constraints, hasLength(5));
    },
  );

  test('constraint dependency graph rejects circular dependencies', () {
    final graph = ConstraintDependencyGraph()
      ..addNode('a')
      ..addNode('b')
      ..connect('a', 'b');
    expect(() => graph.connect('b', 'a'), throwsStateError);
  });

  test('transaction rollback and undo redo are atomic', () {
    final point = sketch.builders.point.build(const SketchVector(0, 0));
    final first = api.builders.of(SketchConstraintType.fixed).build([point.id]);
    expect(api.engine.undo(), isTrue);
    expect(api.engine.constraints, isEmpty);
    expect(api.engine.redo(), isTrue);
    expect(api.engine.constraints, contains(first.id));
    final count = api.engine.history.entries.length;
    expect(
      () => api.engine.transaction('bad', () {
        api.builders.radius.build([point.id], value: 2);
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    expect(api.engine.constraints, hasLength(1));
    expect(api.engine.history.entries.length, count + 1);
    expect(
      api.engine.history.entries.last.action,
      ConstraintHistoryAction.rollback,
    );
  });

  test('handles 1000 constraints deterministically', () async {
    for (var i = 0; i < 1000; i++) {
      final point = sketch.builders.point.build(SketchVector(i.toDouble(), 0));
      api.builders.of(SketchConstraintType.fixed).build([point.id]);
    }
    final result = await api.solve();
    expect(api.constraints, hasLength(1000));
    expect(result.statistics.iterations, 1000);
    expect(result.solvedIds, hasLength(1000));
    expect(api.engine.analytics.totalConstraints, 1000);
  });

  test('underdefined sketch is diagnosed', () async {
    sketch.builders.point.build(const SketchVector(0, 0));
    sketch.builders.point.build(const SketchVector(1, 1));
    final c = api.builders.of(SketchConstraintType.fixed).build([
      sketch.engine.entities.keys.first,
    ]);
    final result = await api.solve();
    expect(
      result.diagnostics.map((d) => d.kind),
      contains(ConstraintDiagnosticKind.underConstraint),
    );
    expect(c.status, ConstraintStatus.satisfied);
  });

  test(
    'repository persists constraints dimensions graphs history and analytics',
    () async {
      final point = sketch.builders.point.build(const SketchVector(0, 0));
      final constraint = api.builders.distance.build([point.id], value: 3);
      api.engine.addDimension(
        SketchDimension(
          type: SketchDimensionType.linear,
          constraintId: constraint.id,
          value: 3,
          references: [point.id],
          anchorReference: point.id,
          labelX: 4,
          labelY: 5,
        ),
      );
      final dimension = api.dimensions.single;
      api.updateDimension(dimension.id, value: 6, labelX: 8, labelY: 9);
      await api.engine.persist();
      for (final path in ConstraintRepository.paths) {
        expect(
          Directory(
            '${project.path}${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}',
          ).existsSync(),
          isTrue,
        );
      }
      final loaded = const ConstraintFactory().create(
        projectDirectory: project,
        sketch: sketch,
      );
      await loaded.engine.load();
      expect(loaded.constraints.single.id, constraint.id);
      expect(loaded.engine.dimensions, hasLength(1));
      expect(loaded.dimensions.single.value, 6);
      expect(loaded.dimensions.single.references, [point.id]);
      expect(loaded.dimensions.single.anchorReference, point.id);
      expect(loaded.dimensions.single.labelX, 8);
      expect(loaded.dimensions.single.labelY, 9);
    },
  );

  test(
    'selection FEL Studio inspector runtime factory and bootstrap integrate',
    () {
      final point = sketch.builders.point.build(const SketchVector(0, 0));
      final constraint = api.builders.of(SketchConstraintType.fixed).build([
        point.id,
      ]);
      final selection = ConstraintSelection()
        ..selectConstraint(constraint.id)
        ..highlightConflict([constraint.id])
        ..preview(constraint.id);
      expect(selection.selectedConstraints, contains(constraint.id));
      expect(
        createConstraintFelCommands(api).map((c) => c.name).toSet(),
        hasLength(25),
      );
      final node = const ConstraintStudioAdapter()
          .buildTree(api.engine, 'project')
          .firstWhere((n) => n.id == constraint.id);
      final section = const PropertyInspector()
          .inspect(node)
          .firstWhere((s) => s.name == 'Constraint');
      expect(
        section.values.keys,
        containsAll([
          'constraintType',
          'status',
          'driving',
          'driven',
          'priority',
          'solved',
          'references',
          'diagnostics',
          'timestamp',
          'persistentId',
        ]),
      );
      final runtime = ConstraintRuntime();
      expect(runtime.isInitialized, isFalse);
      runtime.initialize();
      expect(runtime.isInitialized, isTrue);
      final bootstrap = EngineeringBootstrap.instance..initialize();
      expect(bootstrap.services.get<ConstraintFactory>(), isNotNull);
      expect(bootstrap.services.get<ConstraintRuntime>(), isNotNull);
      expect(bootstrap.services.get<ConstraintRepository>(), isNotNull);
      expect(bootstrap.services.get<ConstraintAnalytics>(), isNotNull);
      expect(bootstrap.services.get<ConstraintHistory>(), isNotNull);
    },
  );
}
