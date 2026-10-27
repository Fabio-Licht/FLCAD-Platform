import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/core/sketch_constraints/api/constraint_api.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/constraint_factory.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_editor/api/sketch_editor_api.dart';
import 'package:flcad_mobile/core/sketch_editor/integration/editor_factory.dart';
import 'package:flcad_mobile/core/sketch_engine/api/sketch_engine_api.dart';
import 'package:flcad_mobile/core/sketch_editor/models/editor_models.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/sketch_factory.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory project;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('flcad_g126_');
  });

  tearDown(() async {
    if (await project.exists()) await project.delete(recursive: true);
  });

  test('Trim and Extend edit original geometry and support Undo/Redo', () {
    final sketch = const SketchEngineFactory().create(project)
      ..createSketch('Sketch001');
    final constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
    final editor = const SketchEditorFactory().create(
      projectDirectory: project,
      sketch: sketch,
      constraints: constraints,
    );
    final line = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );

    editor.preview(SketchToolType.trim, const []);
    editor.edit(
      SketchToolType.trim,
      [line.id],
      parameters: {'point': const SketchVector(3, 0).toJson()},
    );
    expect(line.parameters['start'], [3.0, 0.0, 0.0]);

    editor.preview(SketchToolType.extend, const []);
    editor.edit(
      SketchToolType.extend,
      [line.id],
      parameters: {'point': const SketchVector(15, 0).toJson()},
    );
    expect(line.parameters['end'], [15.0, 0.0, 0.0]);
    expect(editor.undo(), isTrue);
    expect(editor.redo(), isTrue);
  });

  test('Fillet and Chamfer remain editable features with stable IDs', () {
    final sketch = const SketchEngineFactory().create(project)
      ..createSketch('Sketch001');
    final constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
    final editor = const SketchEditorFactory().create(
      projectDirectory: project,
      sketch: sketch,
      constraints: constraints,
    );
    final a = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final b = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(0, 10),
    );
    editor.preview(SketchToolType.fillet, const []);
    editor.edit(SketchToolType.fillet, [a.id, b.id], value: 1);
    final fillet = sketch.engine.entities.values.whereType<SketchArc>().single;
    fillet.metadata.addAll({
      'featureType': 'fillet',
      'featureValue': 1.0,
      'sourceEntityIds': [a.id, b.id],
      'autoTrim': true,
    });
    final stableId = fillet.id;

    editor.editCornerFeature(stableId, 2);

    expect(sketch.entity(stableId), same(fillet));
    expect(fillet.parameters['radius'], 2);
    expect(fillet.metadata['featureValue'], 2);
    final sweep =
        ((fillet.parameters['endAngle'] as num) -
                (fillet.parameters['startAngle'] as num))
            .abs();
    expect(sweep, closeTo(math.pi / 2, 1e-8));
    expect(sweep, isNot(closeTo(3 * math.pi / 2, 1e-6)));
  });

  test('Geomagic-style Trim removes a clicked endpoint overhang', () {
    final sketch = const SketchEngineFactory().create(project)
      ..createSketch('Sketch001');
    final constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
    final editor = const SketchEditorFactory().create(
      projectDirectory: project,
      sketch: sketch,
      constraints: constraints,
    );
    final horizontal = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    sketch.builders.line.build(
      const SketchVector(4, -3),
      const SketchVector(4, 3),
    );

    editor.trimEndpointToNearestIntersection(
      horizontal.id,
      const SketchVector(0.1, 0),
    );

    expect(horizontal.parameters['start'], [4.0, 0.0, 0.0]);
    expect(horizontal.parameters['end'], [10.0, 0.0, 0.0]);
  });

  test('two-side Trim preserves the portions explicitly clicked', () {
    final sketch = const SketchEngineFactory().create(project)
      ..createSketch('Sketch001');
    final constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
    final editor = const SketchEditorFactory().create(
      projectDirectory: project,
      sketch: sketch,
      constraints: constraints,
    );
    final horizontal = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final vertical = sketch.builders.line.build(
      const SketchVector(4, -5),
      const SketchVector(4, 5),
    );

    editor.trimIntersection(
      horizontal.id,
      const SketchVector(8, 0),
      vertical.id,
      const SketchVector(4, -3),
    );

    expect(horizontal.parameters['start'], [4.0, 0.0, 0.0]);
    expect(horizontal.parameters['end'], [10.0, 0.0, 0.0]);
    expect(vertical.parameters['start'], [4.0, -5.0, 0.0]);
    expect(vertical.parameters['end'], [4.0, 0.0, 0.0]);
  });

  test('Fillet rejects a fixed source line without partial geometry', () {
    final sketch = const SketchEngineFactory().create(project)
      ..createSketch('Sketch001');
    final constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
    final editor = const SketchEditorFactory().create(
      projectDirectory: project,
      sketch: sketch,
      constraints: constraints,
    );
    final first = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final second = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(0, 10),
    );
    first.locked = true;
    final firstBefore = first.parameters.toString();
    final secondBefore = second.parameters.toString();

    editor.preview(SketchToolType.fillet, const []);
    expect(
      () => editor.edit(SketchToolType.fillet, [first.id, second.id], value: 5),
      throwsStateError,
    );
    expect(first.parameters.toString(), firstBefore);
    expect(second.parameters.toString(), secondBefore);
    expect(sketch.engine.entities.values.whereType<SketchArc>(), isEmpty);
    expect(editor.undo(), isFalse);
  });

  test('successive Trim cuts a T junction down to an L', () {
    final harness = _g126Harness(project);
    final editor = harness.editor;
    final horizontal = harness.sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final vertical = harness.sketch.builders.line.build(
      const SketchVector(4, -5),
      const SketchVector(4, 5),
    );
    // ignore: avoid_print
    print(
      'TRIM_TRACE crossing '
      'H ${horizontal.id} ${_xy(horizontal)} '
      'V ${vertical.id} ${_xy(vertical)}',
    );

    editor.trimEndpointToNearestIntersection(
      vertical.id,
      const SketchVector(4, -4),
    );
    expect(vertical.parameters['start'], [4.0, 0.0, 0.0]);
    expect(vertical.parameters['end'], [4.0, 5.0, 0.0]);
    expect(horizontal.parameters['start'], [0.0, 0.0, 0.0]);
    expect(horizontal.parameters['end'], [10.0, 0.0, 0.0]);
    expect(editor.hasEndpointBoundedTrimCut(horizontal.id), isTrue);
    expect(editor.hasEndpointBoundedTrimCut(vertical.id), isFalse);
    // ignore: avoid_print
    print(
      'TRIM_TRACE after lower vertical cut '
      'H ${horizontal.id} ${_xy(horizontal)} '
      'V ${vertical.id} ${_xy(vertical)}',
    );

    expect(
      editor.trimEndpointBoundedPortion(
        horizontal.id,
        const SketchVector(1, 0),
      ),
      isTrue,
      reason: 'clicked the left portion of ${horizontal.id}',
    );
    expect(horizontal.parameters['start'], [4.0, 0.0, 0.0]);
    expect(horizontal.parameters['end'], [10.0, 0.0, 0.0]);
    expect(vertical.parameters['start'], [4.0, 0.0, 0.0]);
    expect(vertical.parameters['end'], [4.0, 5.0, 0.0]);
    expect(
      harness.sketch.engine.entities.values.whereType<SketchLine>(),
      hasLength(2),
    );
    // ignore: avoid_print
    print(
      'TRIM_TRACE L after left portion '
      'H ${horizontal.id} ${_xy(horizontal)} '
      'V ${vertical.id} ${_xy(vertical)}',
    );

    expect(editor.undo(), isTrue);
    expect(harness.sketch.entity(horizontal.id)!.parameters['start'], [
      0.0,
      0.0,
      0.0,
    ]);
    expect(harness.sketch.entity(vertical.id)!.parameters['start'], [
      4.0,
      0.0,
      0.0,
    ]);
    expect(editor.undo(), isTrue);
    expect(harness.sketch.entity(vertical.id)!.parameters['start'], [
      4.0,
      -5.0,
      0.0,
    ]);
    expect(editor.redo(), isTrue);
    expect(harness.sketch.entity(vertical.id)!.parameters['end'], [
      4.0,
      5.0,
      0.0,
    ]);
    expect(editor.redo(), isTrue);
    expect(harness.sketch.entity(horizontal.id)!.parameters['start'], [
      4.0,
      0.0,
      0.0,
    ]);
  });

  test('T-junction Trim can remove the right portion', () {
    final harness = _g126Harness(project);
    final horizontal = harness.sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final vertical = harness.sketch.builders.line.build(
      const SketchVector(4, 0),
      const SketchVector(4, 6),
    );

    expect(
      harness.editor.trimEndpointBoundedPortion(
        horizontal.id,
        const SketchVector(9, 0),
      ),
      isTrue,
      reason: 'clicked the right portion of ${horizontal.id}',
    );

    expect(horizontal.parameters['start'], [0.0, 0.0, 0.0]);
    expect(horizontal.parameters['end'], [4.0, 0.0, 0.0]);
    expect(vertical.parameters['start'], [4.0, 0.0, 0.0]);
    expect(vertical.parameters['end'], [4.0, 6.0, 0.0]);
    expect(
      harness.sketch.engine.entities.values.whereType<SketchLine>(),
      hasLength(2),
    );
  });

  test('keep-side Trim at a T junction is independent of selection order', () {
    for (final verticalFirst in [false, true]) {
      final harness = _g126Harness(
        Directory('${project.path}/$verticalFirst')..createSync(),
      );
      final horizontal = harness.sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final vertical = harness.sketch.builders.line.build(
        const SketchVector(4, 0),
        const SketchVector(4, 6),
      );
      if (verticalFirst) {
        harness.editor.trimIntersection(
          vertical.id,
          const SketchVector(4, 3),
          horizontal.id,
          const SketchVector(8, 0),
        );
      } else {
        harness.editor.trimIntersection(
          horizontal.id,
          const SketchVector(8, 0),
          vertical.id,
          const SketchVector(4, 3),
        );
      }
      expect(
        horizontal.parameters['start'],
        [4.0, 0.0, 0.0],
        reason: 'verticalFirst=$verticalFirst kept the right portion',
      );
      expect(horizontal.parameters['end'], [10.0, 0.0, 0.0]);
      expect(vertical.parameters['start'], [4.0, 0.0, 0.0]);
      expect(vertical.parameters['end'], [4.0, 6.0, 0.0]);
    }
  });

  test('endpoint-endpoint and parallel trims change nothing', () {
    final harness = _g126Harness(project);
    final cornerA = harness.sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(5, 0),
    );
    final cornerB = harness.sketch.builders.line.build(
      const SketchVector(5, 0),
      const SketchVector(5, 5),
    );
    final cornerBefore = '${_xy(cornerA)}|${_xy(cornerB)}';
    expect(
      () => harness.editor.trimIntersection(
        cornerA.id,
        const SketchVector(2, 0),
        cornerB.id,
        const SketchVector(5, 2),
      ),
      throwsStateError,
    );
    expect('${_xy(cornerA)}|${_xy(cornerB)}', cornerBefore);
    expect(harness.editor.undo(), isFalse);

    final parallelA = harness.sketch.builders.line.build(
      const SketchVector(0, 2),
      const SketchVector(4, 2),
    );
    final parallelB = harness.sketch.builders.line.build(
      const SketchVector(0, 4),
      const SketchVector(4, 4),
    );
    final parallelBefore = '${_xy(parallelA)}|${_xy(parallelB)}';
    expect(
      () => harness.editor.trimIntersection(
        parallelA.id,
        const SketchVector(1, 2),
        parallelB.id,
        const SketchVector(1, 4),
      ),
      throwsStateError,
    );
    expect('${_xy(parallelA)}|${_xy(parallelB)}', parallelBefore);
  });

  test('a middle portion is removed without deleting the whole line', () {
    final harness = _g126Harness(project);
    final horizontal = harness.sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(12, 0),
    );
    harness.sketch.builders.line.build(
      const SketchVector(3, 0),
      const SketchVector(3, 4),
    );
    harness.sketch.builders.line.build(
      const SketchVector(8, 0),
      const SketchVector(8, 4),
    );
    final before = harness.sketch.engine.entities.length;

    expect(
      harness.editor.trimEndpointBoundedPortion(
        horizontal.id,
        const SketchVector(5, 0),
      ),
      isTrue,
    );

    expect(horizontal.parameters['start'], [0.0, 0.0, 0.0]);
    expect(horizontal.parameters['end'], [3.0, 0.0, 0.0]);
    final lines = harness.sketch.engine.entities.values.whereType<SketchLine>();
    expect(lines, hasLength(before + 1));
    expect(
      lines.where(
        (line) =>
            line.parameters['start'].toString() == '[8.0, 0.0, 0.0]' &&
            line.parameters['end'].toString() == '[12.0, 0.0, 0.0]',
      ),
      hasLength(1),
    );
    expect(
      lines.where(
        (line) =>
            line.parameters['start'].toString() == '[3.0, 0.0, 0.0]' &&
            line.parameters['end'].toString() == '[8.0, 0.0, 0.0]',
      ),
      isEmpty,
    );
  });

  test(
    'a middle portion keeps directional constraints on both remainders',
    () async {
      final harness = _g126Harness(
        Directory('${project.path}/middle-constraints')..createSync(),
      );
      final horizontal = harness.sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(12, 0),
      );
      harness.sketch.builders.line.build(
        const SketchVector(3, 0),
        const SketchVector(3, 4),
      );
      harness.sketch.builders.line.build(
        const SketchVector(8, 0),
        const SketchVector(8, 4),
      );
      harness.constraints.builders.horizontal.build(<String>[horizontal.id]);

      expect(
        harness.editor.trimEndpointBoundedPortion(
          horizontal.id,
          const SketchVector(5, 0),
        ),
        isTrue,
      );

      final remainder = harness.sketch.engine.entities.values
          .whereType<SketchLine>()
          .singleWhere(
            (line) =>
                line.parameters['start'].toString() == '[8.0, 0.0, 0.0]' &&
                line.parameters['end'].toString() == '[12.0, 0.0, 0.0]',
          );
      expect(
        harness.constraints.constraints
            .where((item) => item.type == SketchConstraintType.horizontal)
            .map((item) => item.references.single),
        containsAll([horizontal.id, remainder.id]),
      );

      expect(harness.editor.undo(), isTrue);
      final restored = harness.sketch.entity(horizontal.id)!;
      expect(restored.parameters['end'], [12.0, 0.0, 0.0]);
      expect(harness.sketch.engine.entities.containsKey(remainder.id), isFalse);
      expect(
        harness.constraints.constraints.where(
          (item) => item.references.contains(remainder.id),
        ),
        isEmpty,
      );
      expect(
        harness.constraints.constraints.where(
          (item) => item.type == SketchConstraintType.horizontal,
        ),
        hasLength(1),
      );

      expect(harness.editor.redo(), isTrue);
      expect(harness.sketch.engine.entities.containsKey(remainder.id), isTrue);
      expect(
        harness.constraints.constraints.where(
          (item) =>
              item.type == SketchConstraintType.horizontal &&
              item.references.contains(remainder.id),
        ),
        hasLength(1),
      );
      final solved = await harness.constraints.solve();
      expect(solved.success, isTrue, reason: '${solved.diagnostics}');
    },
  );

  test('FIX blocks Trim and directional constraints stay satisfied', () async {
    Directory nest(String name) =>
        Directory('${project.path}/$name')..createSync();
    final blocked = _g126Harness(nest('fixed'));
    final fixedLine = blocked.sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    blocked.sketch.builders.line.build(
      const SketchVector(4, 0),
      const SketchVector(4, 5),
    );
    blocked.constraints.builders.of(SketchConstraintType.fixed).build(<String>[
      fixedLine.id,
    ]);
    final fixedBefore = fixedLine.parameters.toString();
    expect(
      () => blocked.editor.trimEndpointBoundedPortion(
        fixedLine.id,
        const SketchVector(1, 0),
      ),
      throwsStateError,
    );
    expect(fixedLine.parameters.toString(), fixedBefore);
    expect(blocked.editor.undo(), isFalse);

    final harness = _g126Harness(nest('directional'));
    final horizontal = harness.sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final vertical = harness.sketch.builders.line.build(
      const SketchVector(4, -5),
      const SketchVector(4, 5),
    );
    final anchor = harness.sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(0, 3),
    );
    harness.constraints.builders.horizontal.build([horizontal.id]);
    harness.constraints.builders.vertical.build([vertical.id]);
    harness.constraints.builders.coincident.build([
      '${horizontal.id}:start',
      '${anchor.id}:start',
    ]);
    harness.editor.trimEndpointToNearestIntersection(
      vertical.id,
      const SketchVector(4, -4),
    );
    expect(
      harness.editor.trimEndpointBoundedPortion(
        horizontal.id,
        const SketchVector(8, 0),
      ),
      isTrue,
    );
    expect(horizontal.parameters['start'], [0.0, 0.0, 0.0]);
    expect(horizontal.parameters['end'], [4.0, 0.0, 0.0]);
    expect(anchor.parameters['start'], [0.0, 0.0, 0.0]);
    final solved = await harness.constraints.solve();
    expect(solved.success, isTrue);
    expect(
      harness.constraints.constraints.map((item) => item.type),
      containsAll([
        SketchConstraintType.horizontal,
        SketchConstraintType.vertical,
        SketchConstraintType.coincident,
      ]),
    );

    final meeting = _g126Harness(nest('coincident'));
    final carrier = meeting.sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    meeting.sketch.builders.line.build(
      const SketchVector(4, 0),
      const SketchVector(4, 5),
    );
    final tied = meeting.sketch.builders.line.build(
      const SketchVector(10, 0),
      const SketchVector(10, 2),
    );
    meeting.constraints.builders.coincident.build([
      '${carrier.id}:end',
      '${tied.id}:start',
    ]);
    final carrierBefore = carrier.parameters.toString();
    expect(
      () => meeting.editor.trimEndpointBoundedPortion(
        carrier.id,
        const SketchVector(9, 0),
      ),
      throwsStateError,
    );
    expect(carrier.parameters.toString(), carrierBefore);
    expect(meeting.editor.undo(), isFalse);
  });
}

({SketchEngineApi sketch, ConstraintApi constraints, SketchEditorApi editor})
_g126Harness(Directory project) {
  final sketch = const SketchEngineFactory().create(project)
    ..createSketch('Sketch001');
  final constraints = const ConstraintFactory().create(
    projectDirectory: project,
    sketch: sketch,
  );
  final editor = const SketchEditorFactory().create(
    projectDirectory: project,
    sketch: sketch,
    constraints: constraints,
  );
  return (sketch: sketch, constraints: constraints, editor: editor);
}

String _xy(SketchLine line) =>
    '${line.parameters['start']} -> ${line.parameters['end']}';
