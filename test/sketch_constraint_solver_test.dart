import 'dart:io';
import 'dart:math' as math;
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
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
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

  test('endpoint coincidence rigidly translates the target line', () async {
    final reference = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(5, 0),
    );
    final target = sketch.builders.line.build(
      const SketchVector(5.2, 0.1),
      const SketchVector(8, 2),
    );
    final originalDirection =
        SketchVector.fromJson(target.parameters['end']) -
        SketchVector.fromJson(target.parameters['start']);
    final originalLength = math.sqrt(originalDirection.dot(originalDirection));
    api.builders.coincident.build([
      '${reference.id}:end',
      '${target.id}:start',
    ]);

    await api.solve();

    expect(target.parameters['start'], reference.parameters['end']);
    final translatedDirection =
        SketchVector.fromJson(target.parameters['end']) -
        SketchVector.fromJson(target.parameters['start']);
    expect(translatedDirection.x, closeTo(originalDirection.x, 1e-8));
    expect(translatedDirection.y, closeTo(originalDirection.y, 1e-8));
    expect(
      math.sqrt(translatedDirection.dot(translatedDirection)),
      closeTo(originalLength, 1e-8),
    );
  });

  test(
    'coincidence order keeps the first selected line as the anchor',
    () async {
      final anchor = sketch.builders.line.build(
        const SketchVector(5.2, 0.1),
        const SketchVector(8, 2),
      );
      final target = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(5, 0),
      );
      final targetDirection =
          SketchVector.fromJson(target.parameters['end']) -
          SketchVector.fromJson(target.parameters['start']);
      api.builders.coincident.build(['${anchor.id}:start', '${target.id}:end']);

      final result = await api.solve();

      expect(result.success, isTrue);
      expect(anchor.parameters['start'], [5.2, 0.1, 0.0]);
      expect(anchor.parameters['end'], [8.0, 2.0, 0.0]);
      final solvedTargetDirection =
          SketchVector.fromJson(target.parameters['end']) -
          SketchVector.fromJson(target.parameters['start']);
      expect(solvedTargetDirection.x, closeTo(targetDirection.x, 1e-8));
      expect(solvedTargetDirection.y, closeTo(targetDirection.y, 1e-8));
      expect(target.parameters['end'], anchor.parameters['start']);
    },
  );

  test(
    'FIX on the anchor permits target translation but FIX on target rejects',
    () async {
      final anchor = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final target = sketch.builders.line.build(
        const SketchVector(20, 10),
        const SketchVector(20, 20),
      );
      api.builders.of(SketchConstraintType.fixed).build([anchor.id]);
      final anchorBefore = [
        (anchor.parameters['start'] as List)
            .cast<num>()
            .map((value) => value.toDouble())
            .toList(),
        (anchor.parameters['end'] as List)
            .cast<num>()
            .map((value) => value.toDouble())
            .toList(),
      ];
      final coincident = api.builders.coincident.build([
        '${anchor.id}:end',
        '${target.id}:end',
      ]);
      final accepted = await api.solve();
      expect(accepted.success, isTrue);
      expect(anchor.parameters['start'], anchorBefore.first);
      expect(anchor.parameters['end'], anchorBefore.last);
      expect(target.parameters['end'], anchor.parameters['end']);

      final targetBefore = [
        (target.parameters['start'] as List)
            .cast<num>()
            .map((value) => value.toDouble())
            .toList(),
        (target.parameters['end'] as List)
            .cast<num>()
            .map((value) => value.toDouble())
            .toList(),
      ];
      api.builders.of(SketchConstraintType.fixed).build([target.id]);
      final rejected = api.builders.coincident.build([
        '${anchor.id}:start',
        '${target.id}:start',
      ]);
      final failed = await api.solve(only: [rejected.id]);
      expect(failed.solvedIds, isNot(contains(rejected.id)));
      expect(target.parameters['start'], targetBefore.first);
      expect(target.parameters['end'], targetBefore.last);
      expect(coincident.status, ConstraintStatus.satisfied);
    },
  );

  test('rigid endpoint coincidence survives Save/Open', () async {
    final anchor = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final target = sketch.builders.line.build(
      const SketchVector(20, 10),
      const SketchVector(20, 20),
    );
    api.builders.coincident.build(['${anchor.id}:end', '${target.id}:end']);
    await api.solve();
    await sketch.persist();
    await api.persist();

    final reopenedSketch = const SketchEngineFactory().create(project);
    await reopenedSketch.load();
    final reopenedApi = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: reopenedSketch,
    );
    await reopenedApi.load();
    final reopenedAnchor = reopenedSketch.entity(anchor.id) as SketchLine;
    final reopenedTarget = reopenedSketch.entity(target.id) as SketchLine;
    expect(reopenedTarget.parameters['end'], reopenedAnchor.parameters['end']);
    expect(reopenedTarget.parameters['start'], [10.0, -10.0, 0.0]);
    expect(
      reopenedApi.constraints.where(
        (constraint) => constraint.type == SketchConstraintType.coincident,
      ),
      hasLength(1),
    );
  });

  test(
    'perpendicular and endpoint coincidence remain satisfied together',
    () async {
      final reference = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final target = sketch.builders.line.build(
        const SketchVector(20, 10),
        const SketchVector(20, 20),
      );
      api.builders.perpendicular.build([reference.id, target.id]);
      api.builders.coincident.build([
        '${reference.id}:end',
        '${target.id}:end',
      ]);

      final result = await api.solve();
      expect(result.success, isTrue);
      final start = SketchVector.fromJson(target.parameters['start']);
      final end = SketchVector.fromJson(target.parameters['end']);
      final referenceStart = SketchVector.fromJson(
        reference.parameters['start'],
      );
      final referenceEnd = SketchVector.fromJson(reference.parameters['end']);
      final referenceDirection = referenceEnd - referenceStart;
      final targetDirection = end - start;
      expect(
        (end - referenceEnd).dot(end - referenceEnd),
        lessThanOrEqualTo(1e-12),
        reason: 'the selected endpoints must remain coincident',
      );
      expect(
        referenceDirection.dot(targetDirection).abs(),
        lessThanOrEqualTo(1e-6),
        reason: 'the line directions must remain perpendicular',
      );
    },
  );

  test(
    'incremental coincidence revisits affected perpendicular relations',
    () async {
      final reference = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final target = sketch.builders.line.build(
        const SketchVector(20, 10),
        const SketchVector(20, 20),
      );
      final perpendicular = api.builders.perpendicular.build([
        reference.id,
        target.id,
      ]);
      await api.solve(only: [perpendicular.id]);
      final coincident = api.builders.coincident.build([
        '${reference.id}:end',
        '${target.id}:end',
      ]);

      final result = await api.solve(only: [coincident.id]);
      expect(result.success, isTrue);
      final start = SketchVector.fromJson(target.parameters['start']);
      final end = SketchVector.fromJson(target.parameters['end']);
      final referenceEnd = SketchVector.fromJson(reference.parameters['end']);
      final targetDirection = end - start;
      final referenceDirection =
          referenceEnd - SketchVector.fromJson(reference.parameters['start']);
      expect(
        (end - referenceEnd).dot(end - referenceEnd),
        lessThanOrEqualTo(1e-12),
      );
      expect(
        referenceDirection.dot(targetDirection).abs(),
        lessThanOrEqualTo(1e-6),
      );
    },
  );

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

  test('line-arc coincidence translates the arc and keeps the line', () async {
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(30, 0),
    );
    final arc = sketch.builders.arc.build(
      const SketchVector(10, 12),
      8,
      -math.pi / 2,
      0,
    );
    final lineBefore = [line.parameters['start'], line.parameters['end']];
    final radius = arc.parameters['radius'];
    final sweep =
        (arc.parameters['endAngle'] as num) -
        (arc.parameters['startAngle'] as num);
    api.builders.coincident.build(['${line.id}:end', '${arc.id}:start']);

    final result = await api.solve();

    expect(result.success, isTrue, reason: result.diagnostics.toString());
    expect(line.parameters['start'], lineBefore[0]);
    expect(line.parameters['end'], lineBefore[1]);
    expect(arc.parameters['radius'], radius);
    expect(
      (arc.parameters['endAngle'] as num) -
          (arc.parameters['startAngle'] as num),
      closeTo(sweep, 1e-12),
    );
    final gap = _arcPoint(arc, 'start') - const SketchVector(30, 0);
    expect(_sketchLength(gap), lessThanOrEqualTo(1e-8));
  });

  test(
    'inverted line-arc coincidence keeps the arc and translates the line',
    () async {
      final line = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(30, 0),
      );
      final arc = sketch.builders.arc.build(
        const SketchVector(10, 12),
        8,
        -math.pi / 2,
        math.pi / 2,
      );
      final arcBefore = Map<String, Object?>.from(arc.parameters);
      final direction =
          SketchVector.fromJson(line.parameters['end']) -
          SketchVector.fromJson(line.parameters['start']);
      api.builders.coincident.build(['${arc.id}:end', '${line.id}:start']);

      final result = await api.solve();

      expect(result.success, isTrue, reason: result.diagnostics.toString());
      expect(arc.parameters['center'], arcBefore['center']);
      expect(arc.parameters['radius'], arcBefore['radius']);
      expect(arc.parameters['startAngle'], arcBefore['startAngle']);
      expect(arc.parameters['endAngle'], arcBefore['endAngle']);
      final translated =
          SketchVector.fromJson(line.parameters['end']) -
          SketchVector.fromJson(line.parameters['start']);
      expect(translated.x, closeTo(direction.x, 1e-8));
      expect(translated.y, closeTo(direction.y, 1e-8));
      final gap =
          _arcPoint(arc, 'end') -
          SketchVector.fromJson(line.parameters['start']);
      expect(_sketchLength(gap), lessThanOrEqualTo(1e-8));
    },
  );

  test('isolated line-arc tangent is measured at the contact', () async {
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(30, 0),
    );
    final arc = sketch.builders.arc.build(
      const SketchVector(10, 12),
      8,
      -math.pi / 2,
      0,
    );
    final lineBefore = [line.parameters['start'], line.parameters['end']];
    api.builders.tangent.build([line.id, arc.id]);

    final result = await api.solve();

    expect(result.success, isTrue, reason: result.diagnostics.toString());
    expect(line.parameters['start'], lineBefore[0]);
    expect(line.parameters['end'], lineBefore[1]);
    expect(arc.parameters['radius'], 8);
    final measure = _lineArcTangent(line, arc);
    expect(measure.distanceResidual, lessThanOrEqualTo(1e-8));
    expect(measure.contactOnArc, isTrue);
    expect(measure.alignment, lessThanOrEqualTo(1e-8));
    expect(_endpointAlignment(line, arc, 'start'), lessThanOrEqualTo(1e-8));
    expect(
      _sketchLength(_arcPoint(arc, 'start') - const SketchVector(10, 0)),
      lessThanOrEqualTo(1e-8),
    );
  });

  test(
    'tangent and coincidence stay satisfied at the chosen arc endpoint',
    () async {
      final line = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(30, 0),
      );
      final arc = sketch.builders.arc.build(
        const SketchVector(10, 12),
        8,
        -math.pi / 2,
        math.pi / 2,
      );
      final lineBefore = [line.parameters['start'], line.parameters['end']];
      final sweep =
          (arc.parameters['endAngle'] as num) -
          (arc.parameters['startAngle'] as num);
      api.builders.tangent.build([line.id, arc.id]);
      api.builders.coincident.build(['${line.id}:end', '${arc.id}:end']);

      final result = await api.solve();

      expect(result.success, isTrue, reason: result.diagnostics.toString());
      expect(line.parameters['start'], lineBefore[0]);
      expect(line.parameters['end'], lineBefore[1]);
      expect(arc.parameters['radius'], 8);
      expect(
        (arc.parameters['endAngle'] as num) -
            (arc.parameters['startAngle'] as num),
        closeTo(sweep.toDouble(), 1e-9),
      );
      final gap =
          _arcPoint(arc, 'end') - SketchVector.fromJson(line.parameters['end']);
      expect(_sketchLength(gap), lessThanOrEqualTo(1e-8));
      expect(_lineArcTangent(line, arc).alignment, lessThanOrEqualTo(1e-8));
      expect(_endpointAlignment(line, arc, 'end'), lessThanOrEqualTo(1e-8));
      final tangent = api.constraints.singleWhere(
        (item) => item.type == SketchConstraintType.tangent,
      );
      final coincident = api.constraints.singleWhere(
        (item) => item.type == SketchConstraintType.coincident,
      );
      expect(tangent.status, ConstraintStatus.satisfied);
      expect(coincident.status, ConstraintStatus.satisfied);
      expect(coincident.references, ['${line.id}:end', '${arc.id}:end']);
    },
  );

  test(
    'FIX on the arc rejects line-arc coincidence without mutation',
    () async {
      final line = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(30, 0),
      );
      final arc = sketch.builders.arc.build(
        const SketchVector(10, 12),
        8,
        -math.pi / 2,
        0,
      );
      final arcBefore = Map<String, Object?>.from(arc.parameters);
      final lineBefore = [line.parameters['start'], line.parameters['end']];
      api.builders.of(SketchConstraintType.fixed).build([arc.id]);
      api.builders.coincident.build(['${line.id}:end', '${arc.id}:start']);

      final result = await api.solve();

      expect(result.success, isFalse);
      expect(arc.parameters['center'], arcBefore['center']);
      expect(arc.parameters['startAngle'], arcBefore['startAngle']);
      expect(arc.parameters['endAngle'], arcBefore['endAngle']);
      expect(line.parameters['start'], lineBefore[0]);
      expect(line.parameters['end'], lineBefore[1]);
      expect(
        api.constraints
            .singleWhere((item) => item.type == SketchConstraintType.coincident)
            .status,
        isNot(ConstraintStatus.satisfied),
      );
    },
  );

  test('arc-first tangent keeps the arc when a real contact exists', () async {
    final arc = sketch.builders.arc.build(
      const SketchVector(10, 12),
      8,
      -math.pi,
      math.pi,
    );
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(12, 4),
    );
    final arcBefore = Map<String, Object?>.from(arc.parameters);
    final length = line.parameters['length'];
    api.builders.tangent.build([arc.id, line.id]);

    final result = await api.solve();

    expect(result.success, isTrue, reason: result.diagnostics.toString());
    expect(arc.parameters['center'], arcBefore['center']);
    expect(arc.parameters['radius'], arcBefore['radius']);
    expect(arc.parameters['startAngle'], arcBefore['startAngle']);
    expect(arc.parameters['endAngle'], arcBefore['endAngle']);
    expect(line.parameters['length'], length);
    final measure = _lineArcTangent(line, arc);
    expect(measure.distanceResidual, lessThanOrEqualTo(1e-8));
    expect(measure.contactOnArc, isTrue);
    expect(measure.alignment, lessThanOrEqualTo(1e-8));
  });

  test(
    'tangent then coincidence closes every arc endpoint and sweep direction',
    () async {
      const endpoints = ['start', 'end'];
      for (var sweepIndex = 0; sweepIndex < 2; sweepIndex++) {
        final reverseSweep = sweepIndex == 1;
        for (var lineIndex = 0; lineIndex < endpoints.length; lineIndex++) {
          for (var arcIndex = 0; arcIndex < endpoints.length; arcIndex++) {
            final y = (sweepIndex * endpoints.length * endpoints.length +
                    lineIndex * endpoints.length +
                    arcIndex) *
                100.0;
            final line = sketch.builders.line.build(
              SketchVector(0, y),
              SketchVector(30, y),
            );
            final arc = sketch.builders.arc.build(
              SketchVector(10, y + 12),
              8,
              reverseSweep ? math.pi / 2 : -math.pi / 2,
              reverseSweep ? -math.pi / 2 : math.pi / 2,
            );
            final lineRef = '${line.id}:${endpoints[lineIndex]}';
            final arcRef = '${arc.id}:${endpoints[arcIndex]}';
            final tangent = api.builders.tangent.build([line.id, arc.id]);
            final coincident = api.builders.coincident.build([lineRef, arcRef]);

            final result = await api.solve();

            expect(
              result.success,
              isTrue,
              reason: '$lineRef + $arcRef: ${result.diagnostics}',
            );
            expect(
              _sketchLength(
                SketchVector.fromJson(
                      line.parameters[lineIndex == 0 ? 'start' : 'end'],
                    ) -
                    _arcPoint(arc, endpoints[arcIndex]),
              ),
              lessThanOrEqualTo(1e-8),
              reason: '$lineRef + $arcRef left a gap',
            );
            expect(_lineArcTangent(line, arc).distanceResidual, lessThanOrEqualTo(1e-8));
            expect(_lineArcTangent(line, arc).alignment, lessThanOrEqualTo(1e-8));
            expect(tangent.status, ConstraintStatus.satisfied);
            expect(coincident.status, ConstraintStatus.satisfied);
          }
        }
      }
    },
  );
}

SketchVector _arcPoint(SketchArc arc, String endpoint) {
  final center = SketchVector.fromJson(arc.parameters['center']);
  final radius = (arc.parameters['radius'] as num).toDouble();
  final angle =
      (arc.parameters[endpoint == 'start' ? 'startAngle' : 'endAngle'] as num)
          .toDouble();
  return SketchVector(
    center.x + radius * math.cos(angle),
    center.y + radius * math.sin(angle),
  );
}

double _sketchLength(SketchVector vector) =>
    math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z);

({double distanceResidual, double alignment, bool contactOnArc})
_lineArcTangent(SketchLine line, SketchArc arc) {
  final start = SketchVector.fromJson(line.parameters['start']);
  final end = SketchVector.fromJson(line.parameters['end']);
  final center = SketchVector.fromJson(arc.parameters['center']);
  final radius = (arc.parameters['radius'] as num).toDouble();
  final direction = end - start;
  final directionLength = _sketchLength(direction);
  final offset = center - start;
  final distance =
      (offset.x * direction.y - offset.y * direction.x).abs() / directionLength;
  final denominator = direction.x * direction.x + direction.y * direction.y;
  final t =
      ((center.x - start.x) * direction.x +
          (center.y - start.y) * direction.y) /
      denominator;
  final contact = start + direction.scale(t);
  final radial = contact - center;
  final radialLength = _sketchLength(radial);
  final alignment =
      radial.dot(direction).abs() / (radialLength * directionLength);
  final angle = math.atan2(contact.y - center.y, contact.x - center.x);
  final sweepStart = (arc.parameters['startAngle'] as num).toDouble();
  final sweepEnd = (arc.parameters['endAngle'] as num).toDouble();
  final sweep = sweepEnd - sweepStart;
  final turn = math.pi * 2;
  final relative = sweep >= 0
      ? ((angle - sweepStart) % turn + turn) % turn
      : ((sweepStart - angle) % turn + turn) % turn;
  return (
    distanceResidual: (distance - radius).abs(),
    alignment: alignment,
    contactOnArc: relative <= sweep.abs() + 1e-8,
  );
}

double _endpointAlignment(SketchLine line, SketchArc arc, String endpoint) {
  final radial =
      _arcPoint(arc, endpoint) -
      SketchVector.fromJson(arc.parameters['center']);
  final direction =
      SketchVector.fromJson(line.parameters['end']) -
      SketchVector.fromJson(line.parameters['start']);
  return radial.dot(direction).abs() /
      (_sketchLength(radial) * _sketchLength(direction));
}
