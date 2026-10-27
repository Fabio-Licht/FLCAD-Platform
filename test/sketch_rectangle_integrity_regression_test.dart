import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/core/sketch_constraints/integration/constraint_factory.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_constraints/api/constraint_api.dart';
import 'package:flcad_mobile/core/sketch_engine/api/sketch_engine_api.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/sketch_factory.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/sketch_engine/persistence/sketch_persistence_transaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory project;
  late SketchEngineApi sketch;
  late ConstraintApi constraints;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('flcad-rectangle-');
    sketch = const SketchEngineFactory().create(project)
      ..createSketch('Rectangle');
    constraints = const ConstraintFactory().create(
      projectDirectory: project,
      sketch: sketch,
    );
  });

  tearDown(() async {
    if (await project.exists()) await project.delete(recursive: true);
  });

  test(
    'four coincident vertices remain numerically connected through resize history',
    () async {
      final lines = [
        sketch.builders.line.build(
          const SketchVector(0, 0),
          const SketchVector(10, 0),
        ),
        sketch.builders.line.build(
          const SketchVector(10, 0),
          const SketchVector(10, 6),
        ),
        sketch.builders.line.build(
          const SketchVector(10, 6),
          const SketchVector(0, 6),
        ),
        sketch.builders.line.build(
          const SketchVector(0, 6),
          const SketchVector(0, 0),
        ),
      ];
      for (var i = 0; i < 4; i++) {
        final next = (i + 1) % 4;
        constraints.builders.coincident.build([
          '${lines[i].id}:end',
          '${lines[next].id}:start',
        ]);
        constraints.builders
            .of(
              i.isEven
                  ? SketchConstraintType.horizontal
                  : SketchConstraintType.vertical,
            )
            .build([lines[i].id]);
      }

      Future<void> resize(double width, double height) async {
        final targets = [
          [const SketchVector(0, 0), SketchVector(width, 0)],
          [SketchVector(width, 0), SketchVector(width, height)],
          [SketchVector(width, height), SketchVector(0, height)],
          [SketchVector(0, height), const SketchVector(0, 0)],
        ];
        sketch.engine.transaction('rectangle-resize', () {
          for (var i = 0; i < lines.length; i++) {
            sketch.updateParameters(lines[i].id, {
              'startX': targets[i][0].x,
              'startY': targets[i][0].y,
              'endX': targets[i][1].x,
              'endY': targets[i][1].y,
            });
          }
        });
        final result = await constraints.solve();
        expect(
          result.diagnostics.where((d) => d.message.contains('coincident')),
          isEmpty,
        );
        for (var i = 0; i < lines.length; i++) {
          final next = (i + 1) % 4;
          final end = SketchVector.fromJson(lines[i].parameters['end']);
          final start = SketchVector.fromJson(lines[next].parameters['start']);
          expect(
            math.sqrt(
              math.pow(end.x - start.x, 2) + math.pow(end.y - start.y, 2),
            ),
            closeTo(0, 1e-8),
          );
        }
      }

      await resize(4, 2);
      await resize(14, 9);
      expect(sketch.engine.undo(), isTrue);
      expect(sketch.engine.redo(), isTrue);
      await constraints.solve();
      for (var i = 0; i < lines.length; i++) {
        final next = (i + 1) % 4;
        final end = SketchVector.fromJson(lines[i].parameters['end']);
        final start = SketchVector.fromJson(lines[next].parameters['start']);
        expect(end.x, closeTo(start.x, 1e-8));
        expect(end.y, closeTo(start.y, 1e-8));
      }
    },
  );

  test(
    'rectangle constraints and driving dimensions survive a repository reopen',
    () async {
      final lines = [
        sketch.builders.line.build(
          const SketchVector(0, 0),
          const SketchVector(20, 0),
        ),
        sketch.builders.line.build(
          const SketchVector(20, 0),
          const SketchVector(20, 10),
        ),
        sketch.builders.line.build(
          const SketchVector(20, 10),
          const SketchVector(0, 10),
        ),
        sketch.builders.line.build(
          const SketchVector(0, 10),
          const SketchVector(0, 0),
        ),
      ];
      constraints.engine.transaction('rectangle', () {
        for (var index = 0; index < 4; index++) {
          constraints.builders
              .of(
                index.isEven
                    ? SketchConstraintType.horizontal
                    : SketchConstraintType.vertical,
              )
              .build([lines[index].id]);
        }
        for (var index = 0; index < 4; index++) {
          constraints.builders.coincident.build([
            '${lines[index].id}:end',
            '${lines[(index + 1) % 4].id}:start',
          ]);
        }
      });
      await constraints.solve();
      constraints.createDrivingDimension(
        type: SketchDimensionType.linear,
        references: [lines[0].id],
        value: 40,
        deferDirectionalConstraints: true,
      );
      await constraints.solve();
      final width = constraints.dimensions.single;
      constraints.driveDimension(
        width.id,
        60,
        deferDirectionalConstraints: true,
      );
      await constraints.solve();
      final height = constraints.createDrivingDimension(
        type: SketchDimensionType.linear,
        references: [lines[1].id],
        value: 25,
        deferDirectionalConstraints: true,
      );
      expect(height.id, isNotEmpty);
      await constraints.solve();
      _expectRectangle(lines, width: 60, height: 25);

      await const SketchPersistenceTransaction().run(project, () async {
        await sketch.persist();
        await constraints.persist();
      });
      final reopenedSketch = const SketchEngineFactory().create(project);
      await reopenedSketch.load();
      final reopenedConstraints = const ConstraintFactory().create(
        projectDirectory: project,
        sketch: reopenedSketch,
      );
      await reopenedConstraints.load();
      final reopenedLines = lines
          .map((line) => reopenedSketch.entity(line.id) as SketchLine)
          .toList();
      _expectRectangle(reopenedLines, width: 60, height: 25);
      expect(
        reopenedConstraints.constraints.where(
          (item) => item.type == SketchConstraintType.coincident,
        ),
        hasLength(4),
      );
      expect(
        reopenedConstraints.constraints.where(
          (item) => item.type == SketchConstraintType.horizontal,
        ),
        hasLength(2),
      );
      expect(
        reopenedConstraints.constraints.where(
          (item) => item.type == SketchConstraintType.vertical,
        ),
        hasLength(2),
      );
      expect(reopenedConstraints.dimensions, hasLength(2));
    },
  );
}

void _expectRectangle(
  List<SketchLine> lines, {
  required double width,
  required double height,
}) {
  double length(SketchLine line) {
    final start = SketchVector.fromJson(line.parameters['start']);
    final end = SketchVector.fromJson(line.parameters['end']);
    final delta = end - start;
    return math.sqrt(delta.x * delta.x + delta.y * delta.y);
  }

  expect(length(lines[0]), closeTo(width, 1e-6));
  expect(length(lines[2]), closeTo(width, 1e-6));
  expect(length(lines[1]), closeTo(height, 1e-6));
  expect(length(lines[3]), closeTo(height, 1e-6));
  for (var index = 0; index < 4; index++) {
    final start = SketchVector.fromJson(lines[index].parameters['start']);
    final end = SketchVector.fromJson(lines[index].parameters['end']);
    if (index.isEven) {
      expect(end.y, closeTo(start.y, 1e-6));
    } else {
      expect(end.x, closeTo(start.x, 1e-6));
    }
    final nextStart = SketchVector.fromJson(
      lines[(index + 1) % 4].parameters['start'],
    );
    expect(end.x, closeTo(nextStart.x, 1e-6));
    expect(end.y, closeTo(nextStart.y, 1e-6));
  }
}
