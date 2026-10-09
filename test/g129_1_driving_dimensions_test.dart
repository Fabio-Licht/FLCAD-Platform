import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/core/sketch_constraints/api/constraint_api.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/constraint_factory.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/arc_radius_edit_planner.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_engine/api/sketch_engine_api.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/sketch_factory.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory project;
  late SketchEngineApi sketch;
  late ConstraintApi dimensions;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('flcad_g129_1_');
    sketch = const SketchEngineFactory().create(project)
      ..createSketch('Driven');
    dimensions = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
  });
  tearDown(() async => project.delete(recursive: true));

  test('linear dimension moves the smallest legal endpoint group', () {
    final first = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    final second = sketch.builders.line.build(
      const SketchVector(4, 0),
      const SketchVector(4, 3),
    );
    final dimension = dimensions.createDrivingDimension(
      type: SketchDimensionType.linear,
      references: [first.id],
      value: 10,
    );
    final movedStart = (first.parameters['start'] as List).cast<num>();
    expect(movedStart[0], closeTo(-6, 1e-9));
    expect(movedStart[1], closeTo(0, 1e-9));
    expect(first.parameters['end'], [4.0, 0.0, 0.0]);
    expect(second.parameters['start'], [4.0, 0.0, 0.0]);
    expect(dimension.anchorReference, '${first.id}:end');
  });

  test('explicit line anchor is preserved and creation undo is atomic', () {
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    final dimension = dimensions.createDrivingDimension(
      type: SketchDimensionType.linear,
      references: [line.id],
      value: 10,
      anchorReference: '${line.id}:start',
    );
    expect(line.parameters['start'], [0.0, 0.0, 0.0]);
    expect(line.parameters['end'], [10.0, 0.0, 0.0]);
    expect(dimension.anchorReference, '${line.id}:start');
    expect(dimensions.undoDimensionEdit(), isTrue);
    expect(dimensions.dimensions, isEmpty);
    expect(sketch.entity(line.id)!.parameters['end'], [4.0, 0.0, 0.0]);
    expect(dimensions.redoDimensionEdit(), isTrue);
    expect(dimensions.dimensions.single.id, dimension.id);
    expect(sketch.entity(line.id)!.parameters['end'], [10.0, 0.0, 0.0]);
  });

  test('angular dimension preserves length and edits by persistent id', () {
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final dimension = dimensions.createDrivingDimension(
      type: SketchDimensionType.angular,
      references: [line.id],
      value: 90,
    );
    expect((line.parameters['length'] as num).toDouble(), closeTo(10, 1e-9));
    expect(
      (line.parameters['angleDegrees'] as num).toDouble(),
      closeTo(90, 1e-9),
    );
    dimensions.driveDimension(dimension.id, 45);
    expect(
      (line.parameters['angleDegrees'] as num).toDouble(),
      closeTo(45, 1e-9),
    );
    expect(dimensions.undoDimensionEdit(), isTrue);
    expect(
      ((sketch.entity(line.id)!.parameters['angleDegrees']) as num).toDouble(),
      closeTo(90, 1e-9),
    );
    expect(dimensions.redoDimensionEdit(), isTrue);
    expect(
      ((sketch.entity(line.id)!.parameters['angleDegrees']) as num).toDouble(),
      closeTo(45, 1e-9),
    );
  });

  test('radius and diameter drive circle geometry', () {
    final circle = sketch.builders.circle.build(const SketchVector(2, 3), 1);
    final radius = dimensions.createDrivingDimension(
      type: SketchDimensionType.radius,
      references: [circle.id],
      value: 8,
    );
    expect(circle.parameters['radius'], 8.0);
    dimensions.deleteDimension(radius.id);
    final diameter = dimensions.createDrivingDimension(
      type: SketchDimensionType.diameter,
      references: [circle.id],
      value: 20,
    );
    expect(circle.parameters['radius'], 10.0);
    expect(dimensions.dimensions.single.id, diameter.id);
  });

  test('conflicting radial drivers are rejected without changing geometry', () {
    final circle = sketch.builders.circle.build(const SketchVector(2, 3), 1);
    dimensions.createDrivingDimension(
      type: SketchDimensionType.radius,
      references: [circle.id],
      value: 8,
    );
    expect(
      () => dimensions.createDrivingDimension(
        type: SketchDimensionType.diameter,
        references: [circle.id],
        value: 40,
      ),
      throwsA(isA<StateError>()),
    );
    expect(circle.parameters['radius'], 8.0);
    expect(dimensions.dimensions, hasLength(1));
  });

  test('two fixed endpoints reject and roll back a driving edit', () {
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    dimensions.builders.of(SketchConstraintType.fixed).build([
      '${line.id}:start',
    ]);
    dimensions.builders.of(SketchConstraintType.fixed).build([
      '${line.id}:end',
    ]);
    expect(
      () => dimensions.createDrivingDimension(
        type: SketchDimensionType.linear,
        references: [line.id],
        value: 10,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('over constrained'),
        ),
      ),
    );
    expect(line.parameters['end'], [4.0, 0.0, 0.0]);
    expect(dimensions.dimensions, isEmpty);
  });

  test('an incompatible edit reports the blocking geometric constraint', () {
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    final horizontal = dimensions.builders
        .of(SketchConstraintType.horizontal)
        .build([line.id]);
    expect(
      () => dimensions.createDrivingDimension(
        type: SketchDimensionType.angular,
        references: [line.id],
        value: 45,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'diagnostic',
          contains(horizontal.id),
        ),
      ),
    );
    expect(sketch.entity(line.id)!.parameters['start'], [0.0, 0.0, 0.0]);
    expect(sketch.entity(line.id)!.parameters['end'], [4.0, 0.0, 0.0]);
    expect(dimensions.dimensions, isEmpty);
  });

  test('an explicit coincident constraint propagates without separation', () {
    final first = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    final second = sketch.builders.line.build(
      const SketchVector(4, 0),
      const SketchVector(8, 0),
    );
    dimensions.builders.of(SketchConstraintType.coincident).build([
      '${first.id}:end',
      '${second.id}:start',
    ]);
    dimensions.createDrivingDimension(
      type: SketchDimensionType.linear,
      references: [first.id],
      value: 10,
      anchorReference: '${first.id}:start',
    );
    expect(first.parameters['end'], [10.0, 0.0, 0.0]);
    expect(second.parameters['start'], [10.0, 0.0, 0.0]);
  });

  test('arc radius moves its connected endpoint group after confirmation', () {
    final arc = sketch.builders.arc.build(
      const SketchVector(0, 0),
      5,
      0,
      math.pi / 2,
    );
    final line = sketch.builders.line.build(
      const SketchVector(5, 0),
      const SketchVector(8, 0),
    );
    dimensions.createDrivingDimension(
      type: SketchDimensionType.radius,
      references: [arc.id],
      value: 10,
      confirmAdjacent: true,
    );
    expect(line.parameters['start'], [10.0, 0.0, 0.0]);
  });

  test('connected radius dimension is blocked before mutation', () {
    final arc = sketch.builders.arc.build(
      const SketchVector(0, 0),
      5,
      0,
      math.pi / 2,
    );
    final line = sketch.builders.line.build(
      const SketchVector(5, 0),
      const SketchVector(8, 0),
    );
    final historyBefore = dimensions.engine.history.entries.length;
    expect(
      () => dimensions.createDrivingDimension(
        type: SketchDimensionType.radius,
        references: [arc.id],
        value: 10,
      ),
      throwsA(
        isA<ArcRadiusEditConfirmationRequired>().having(
          (failure) => failure.details,
          'details',
          allOf(
            containsPair('previousRadiusMm', 5.0),
            containsPair('requestedRadiusMm', 10.0),
            containsPair('maxEndpointDisplacementMm', 5.0),
            containsPair('affectedEntityIds', contains(arc.id)),
          ),
        ),
      ),
    );
    expect(arc.parameters['radius'], 5.0);
    expect(line.parameters['start'], [5.0, 0.0, 0.0]);
    expect(dimensions.dimensions, isEmpty);
    expect(dimensions.engine.history.entries.length, historyBefore);
  });

  test('connected radius dimension edit requires confirmation', () {
    final arc = sketch.builders.arc.build(
      const SketchVector(0, 0),
      1,
      0,
      math.pi / 2,
    );
    final line = sketch.builders.line.build(
      const SketchVector(1, 0),
      const SketchVector(4, 0),
    );
    final dimension = dimensions.createDrivingDimension(
      type: SketchDimensionType.radius,
      references: [arc.id],
      value: 1,
      confirmAdjacent: true,
    );
    final historyBefore = dimensions.engine.history.entries.length;
    expect(
      () => dimensions.driveDimension(dimension.id, 2),
      throwsA(isA<ArcRadiusEditConfirmationRequired>()),
    );
    expect(arc.parameters['radius'], 1.0);
    expect(line.parameters['start'], [1.0, 0.0, 0.0]);
    expect(dimension.value, 1.0);
    expect(dimensions.engine.history.entries.length, historyBefore);
  });

  test('arc radius dimension uses the tangent planner for two frontiers', () {
    final arc = sketch.builders.arc.build(
      const SketchVector(0, 0),
      1,
      0,
      math.pi / 2,
    );
    final preceding = sketch.builders.line.build(
      const SketchVector(1, -5),
      const SketchVector(1, 0),
    );
    final following = sketch.builders.line.build(
      const SketchVector(0, 1),
      const SketchVector(-5, 1),
    );

    final dimension = dimensions.createDrivingDimension(
      type: SketchDimensionType.radius,
      references: [arc.id],
      value: 1,
      confirmAdjacent: true,
    );
    dimensions.driveDimension(dimension.id, 1.5, confirmAdjacent: true);

    expect(arc.parameters['radius'], 1.5);
    expect(preceding.parameters['end'], [1.0, -.5, 0.0]);
    expect(following.parameters['start'], [-.5, 1.0, 0.0]);
    expect(dimensions.undoDimensionEdit(), isTrue);
    expect(sketch.entity(arc.id)!.parameters['radius'], 1.0);
    expect(sketch.entity(preceding.id)!.parameters['end'], [1.0, 0.0, 0.0]);
    expect(dimensions.redoDimensionEdit(), isTrue);
    expect(sketch.entity(arc.id)!.parameters['radius'], 1.5);
    expect(sketch.entity(following.id)!.parameters['start'], [-.5, 1.0, 0.0]);
    expect(dimension.value, 1.5);
  });

  test('reconstructed arc dimension rejects one frontier atomically', () {
    final arc = sketch.builders.arc.build(
      const SketchVector(0, 0),
      1,
      0,
      math.pi / 2,
    );
    final frontier = sketch.builders.line.build(
      const SketchVector(1, -5),
      const SketchVector(1, 0),
    );

    final dimension = dimensions.createDrivingDimension(
      type: SketchDimensionType.radius,
      references: [arc.id],
      value: 1,
      confirmAdjacent: true,
    );
    arc.metadata['reconstructionKind'] = 'arc';

    expect(
      () => dimensions.driveDimension(dimension.id, 1.5),
      throwsA(
        isA<StateError>().having(
          (error) => error.toString(),
          'message',
          contains('Não foi possível manter a tangência nas duas fronteiras.'),
        ),
      ),
    );
    expect(arc.parameters['radius'], 1.0);
    expect(frontier.parameters['end'], [1.0, 0.0, 0.0]);
    expect(dimensions.dimensions.single.value, 1.0);
  });

  test('reconstructed isolated arc dimension drives radius in place', () {
    final arc = sketch.builders.arc.build(
      const SketchVector(0, 0),
      7.216,
      0,
      math.pi / 2,
    );
    arc.metadata['reconstructionKind'] = 'arc';
    final dimension = dimensions.createDrivingDimension(
      type: SketchDimensionType.radius,
      references: [arc.id],
      value: 7.216,
    );
    dimensions.driveDimension(dimension.id, 7.5);
    expect(
      (sketch.entity(arc.id)!.parameters['radius'] as num).toDouble(),
      closeTo(7.5, 1e-9),
    );
    expect(dimension.value, closeTo(7.5, 1e-9));
    expect(dimensions.undoDimensionEdit(), isTrue);
    expect(
      (sketch.entity(arc.id)!.parameters['radius'] as num).toDouble(),
      closeTo(7.216, 1e-9),
    );
    expect(dimensions.redoDimensionEdit(), isTrue);
    expect(
      (sketch.entity(arc.id)!.parameters['radius'] as num).toDouble(),
      closeTo(7.5, 1e-9),
    );
  });

  test('text move is graphical only and survives save and reopen', () async {
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    final dimension = dimensions.createDrivingDimension(
      type: SketchDimensionType.linear,
      references: [line.id],
      value: 8,
      labelX: 2,
      labelY: 3,
    );
    final geometryBefore = sketch.entity(line.id)!.toJson().toString();
    dimensions.updateDimension(dimension.id, labelX: 20, labelY: 30);
    expect(sketch.entity(line.id)!.toJson().toString(), geometryBefore);
    expect(dimensions.engine.undo(), isTrue);
    expect(dimensions.dimensions.single.labelX, 2);
    expect(dimensions.dimensions.single.labelY, 3);
    expect(dimensions.engine.redo(), isTrue);
    expect(dimensions.dimensions.single.labelX, 20);
    expect(dimensions.dimensions.single.labelY, 30);
    await sketch.persist();
    await dimensions.persist();
    final reopenedSketch = const SketchEngineFactory().create(project);
    await reopenedSketch.load();
    final reopened = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: reopenedSketch,
    );
    await reopened.load();
    expect(reopened.dimensions.single.id, dimension.id);
    expect(reopened.dimensions.single.labelX, 20);
    expect(reopened.dimensions.single.labelY, 30);
    expect(
      reopenedSketch.entity(line.id)!.parameters['length'],
      closeTo(8, 1e-9),
    );

    reopened.deleteDimension(dimension.id);
    await reopened.persist();
    final afterDelete = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: reopenedSketch,
    );
    await afterDelete.load();
    expect(afterDelete.dimensions, isEmpty);
  });

  test('isolated arc radius edit survives save and reopen', () async {
    final arc = sketch.builders.arc.build(
      const SketchVector(12, 8),
      2,
      .25,
      1.75,
    );
    final dimension = dimensions.createDrivingDimension(
      type: SketchDimensionType.radius,
      references: [arc.id],
      value: 2,
    );
    dimensions.driveDimension(dimension.id, 3);
    await sketch.persist();
    await dimensions.persist();

    final reopenedSketch = const SketchEngineFactory().create(project);
    await reopenedSketch.load();
    final reopened = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: reopenedSketch,
    );
    await reopened.load();

    expect(
      (reopenedSketch.entity(arc.id)!.parameters['radius'] as num).toDouble(),
      3.0,
    );
    expect(reopened.dimensions.single.id, dimension.id);
    expect(reopened.dimensions.single.value, 3.0);
  });

  test('isolated radius edit accepts 7.216 to 7.500 mm', () {
    final arc = sketch.builders.arc.build(
      const SketchVector(-12, 4),
      7.216,
      .4,
      1.8,
    );
    final dimension = dimensions.createDrivingDimension(
      type: SketchDimensionType.radius,
      references: [arc.id],
      value: 7.216,
    );
    dimensions.driveDimension(dimension.id, 7.5);
    expect(arc.parameters['radius'], 7.5);
    expect(dimension.value, 7.5);
  });

  test('dimension deletion supports undo and redo without moving geometry', () {
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    final dimension = dimensions.createDrivingDimension(
      type: SketchDimensionType.linear,
      references: [line.id],
      value: 8,
    );
    final geometry = sketch.entity(line.id)!.toJson().toString();
    dimensions.deleteDimension(dimension.id);
    expect(dimensions.dimensions, isEmpty);
    expect(dimensions.engine.undo(), isTrue);
    expect(dimensions.dimensions.single.id, dimension.id);
    expect(sketch.entity(line.id)!.toJson().toString(), geometry);
    expect(dimensions.engine.redo(), isTrue);
    expect(dimensions.dimensions, isEmpty);
    expect(sketch.entity(line.id)!.toJson().toString(), geometry);
  });

  test('load repairs sketch membership when the root list is stale', () async {
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    await sketch.persist();

    // Reproduce projects written by the older non-atomic section conversion:
    // the child entity exists on disk but the root list was saved empty.
    sketch.sketches.single.entityIds.clear();
    await sketch.persist();

    final reopened = const SketchEngineFactory().create(project);
    await reopened.load();
    expect(reopened.sketches.single.entityIds, contains(line.id));
    expect(reopened.entity(line.id), isNotNull);
  });
}
