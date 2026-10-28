import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/core/sketch_constraints/api/constraint_api.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/constraint_factory.dart';
import 'package:flcad_mobile/core/sketch_editor/api/sketch_editor_api.dart';
import 'package:flcad_mobile/core/sketch_editor/geometry/sketch_offset_geometry.dart';
import 'package:flcad_mobile/core/sketch_editor/integration/editor_factory.dart';
import 'package:flcad_mobile/core/sketch_editor/models/editor_models.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/sketch_factory.dart';
import 'package:flcad_mobile/core/sketch_engine/geometry/sketch_spline_geometry.dart';
import 'package:flcad_mobile/core/sketch_engine/api/sketch_engine_api.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('line offset supports both signed directions without moving source', () {
    final line = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final left =
        SketchOffsetGeometry.calculate([line], distance: 2).single
            as SketchOffsetLine;
    final right =
        SketchOffsetGeometry.calculate([line], distance: -2).single
            as SketchOffsetLine;
    expect(left.start.toJson(), [0.0, 2.0, 0.0]);
    expect(left.end.toJson(), [10.0, 2.0, 0.0]);
    expect(right.start.toJson(), [0.0, -2.0, 0.0]);
    expect(right.end.toJson(), [10.0, -2.0, 0.0]);
    final inverted =
        SketchOffsetGeometry.calculate(
              [line],
              distance: 2,
              outward: false,
            ).single
            as SketchOffsetLine;
    expect(inverted.start.toJson(), [0.0, -2.0, 0.0]);
    expect(line.parameters['start'], [0.0, 0.0, 0.0]);
  });

  test(
    'arc offset preserves center and angular sweep and rejects collapse',
    () {
      final arc = SketchArc(const SketchVector(4, 5), 10, 0.2, 1.7);
      final outer =
          SketchOffsetGeometry.calculate([arc], distance: -2).single
              as SketchOffsetArc;
      expect(outer.center.toJson(), [4.0, 5.0, 0.0]);
      expect(outer.radius, 12);
      expect(outer.startAngle, 0.2);
      expect(outer.endAngle, 1.7);
      final inner =
          SketchOffsetGeometry.calculate([arc], distance: 2).single
              as SketchOffsetArc;
      expect(inner.radius, 8);
      final inverted =
          SketchOffsetGeometry.calculate(
                [arc],
                distance: 2,
                outward: false,
              ).single
              as SketchOffsetArc;
      expect(inverted.radius, 12);
      expect(
        () => SketchOffsetGeometry.calculate([arc], distance: 10),
        throwsStateError,
      );
      final degenerate = SketchArc(const SketchVector(0, 0), 0, 0, 1);
      expect(
        () => SketchOffsetGeometry.calculate([degenerate], distance: 1),
        throwsStateError,
      );
      final clockwise = SketchArc(const SketchVector(4, 5), 10, 1.7, 0.2);
      final clockwisePositive =
          SketchOffsetGeometry.calculate([clockwise], distance: 2).single
              as SketchOffsetArc;
      final clockwiseNegative =
          SketchOffsetGeometry.calculate(
                [clockwise],
                distance: 2,
                outward: false,
              ).single
              as SketchOffsetArc;
      expect(clockwisePositive.radius, 12);
      expect(clockwiseNegative.radius, 8);
      expect(clockwisePositive.startAngle, 1.7);
      expect(clockwisePositive.endAngle, 0.2);
    },
  );

  test('open connected line chain is ordered and joined with sharp miters', () {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final second = SketchLine(
      const SketchVector(10, 0),
      const SketchVector(10, 10),
    );
    final result = SketchOffsetGeometry.calculate([
      second,
      first,
    ], distance: 1).cast<SketchOffsetLine>().toList();
    expect(result, hasLength(2));
    expect(result.first.start.toJson(), [0.0, 1.0, 0.0]);
    expect(result.first.end.toJson(), [9.0, 1.0, 0.0]);
    expect(result.last.start.toJson(), [9.0, 1.0, 0.0]);
    expect(result.last.end.toJson(), [9.0, 10.0, 0.0]);
  });

  test('circle offset preserves center and supports both directions', () {
    final circle = SketchCircle(const SketchVector(2, 3), 10);
    final outside =
        SketchOffsetGeometry.calculate([circle], distance: 2).single
            as SketchOffsetCircle;
    final inside =
        SketchOffsetGeometry.calculate(
              [circle],
              distance: 2,
              outward: false,
            ).single
            as SketchOffsetCircle;
    expect(outside.center.toJson(), [2.0, 3.0, 0.0]);
    expect(outside.radius, 12);
    expect(inside.radius, 8);
    expect(
      () => SketchOffsetGeometry.calculate(
        [circle],
        distance: 10,
        outward: false,
      ),
      throwsStateError,
    );
  });

  test('ellipse Offset remains available and does not mutate its source', () {
    final source = SketchEllipse(const SketchVector(2, 3), 10, 6);
    final outside =
        SketchOffsetGeometry.calculate([source], distance: 2).single
            as SketchOffsetEllipse;
    final inside =
        SketchOffsetGeometry.calculate(
              [source],
              distance: 2,
              outward: false,
            ).single
            as SketchOffsetEllipse;
    expect(outside.center.toJson(), [2.0, 3.0, 0.0]);
    expect((outside.radiusX, outside.radiusY), (12, 8));
    expect((inside.radiusX, inside.radiusY), (8, 4));
    expect(source.parameters['radiusX'], 10);
    expect(source.parameters['radiusY'], 6);
    expect(
      () =>
          SketchOffsetGeometry.calculate([source], distance: 6, outward: false),
      throwsStateError,
    );
  });

  test('interpolated spline offset approximates both signed normals', () {
    final source = SketchSpline([
      const SketchVector(0, 0, 3),
      const SketchVector(8, 1, 3),
      const SketchVector(15, 8, 3),
      const SketchVector(24, 9, 3),
    ]);
    for (final signed in [1.25, -1.25]) {
      final result =
          SketchOffsetGeometry.calculate([source], distance: signed).single
              as SketchOffsetSpline;
      expect(result.points.length, greaterThan(2));
      expect(result.estimatedMaxErrorMm, lessThanOrEqualTo(.05));
      expect(
        result.points.every((point) => (point.z - 3).abs() < 1e-9),
        isTrue,
      );

      // Independent dense reference: interpolate the source at much higher
      // density, estimate each tangent from neighboring samples, then measure
      // distance to the reconstructed output's independently sampled polyline.
      final reconstructed = SketchSplineGeometry.interpolate(result.points);
      var maximumResidual = 0.0;
      const countPerSpan = 500;
      final sourceKnots = source.parameters['points']
          .map<SketchVector>(SketchVector.fromJson)
          .toList();
      for (var span = 0; span < sourceKnots.length - 1; span++) {
        for (var index = 0; index <= countPerSpan; index++) {
          final u = index / countPerSpan;
          final p = SketchSplineGeometry.evaluateSpan(sourceKnots, span, u);
          final h = 1e-4;
          final before = SketchSplineGeometry.evaluateSpan(
            sourceKnots,
            span,
            (u - h).clamp(0, 1),
          );
          final after = SketchSplineGeometry.evaluateSpan(
            sourceKnots,
            span,
            (u + h).clamp(0, 1),
          );
          final tangent = after - before;
          final length = math.sqrt(
            tangent.x * tangent.x + tangent.y * tangent.y,
          );
          final expected = SketchVector(
            p.x - signed * tangent.y / length,
            p.y + signed * tangent.x / length,
            p.z,
          );
          maximumResidual = math.max(
            maximumResidual,
            _distanceToPolyline(expected, reconstructed),
          );
        }
      }
      expect(maximumResidual, lessThanOrEqualTo(.05));
    }
  });

  test('spline offset rejects Bezier, nonplanar, and degenerate inputs', () {
    final bezier = SketchSpline(
      const [SketchVector(0, 0), SketchVector(10, 0)],
      bezierControls: const [
        SketchVector(0, 0),
        SketchVector(2, 5),
        SketchVector(8, 5),
        SketchVector(10, 0),
      ],
    );
    expect(
      () => SketchOffsetGeometry.calculate([bezier], distance: 1),
      throwsStateError,
    );
    final nonplanar = SketchSpline(const [
      SketchVector(0, 0, 0),
      SketchVector(2, 1, 1),
      SketchVector(4, 0, 0),
    ]);
    expect(
      () => SketchOffsetGeometry.calculate([nonplanar], distance: 1),
      throwsStateError,
    );
    final repeated =
        SketchSpline(const [SketchVector(0, 0), SketchVector(1, 1)])
          ..parameters['points'] = const [
            [0.0, 0.0, 0.0],
            [0.0, 0.0, 0.0],
          ];
    expect(
      () => SketchOffsetGeometry.calculate([repeated], distance: 1),
      throwsStateError,
    );
  });

  test('spline offset rejects an incompatible local curvature radius', () {
    final tight = SketchSpline(const [
      SketchVector(0, 0),
      SketchVector(1, 0),
      SketchVector(1, 1),
      SketchVector(0, 1),
    ]);
    expect(
      () => SketchOffsetGeometry.calculate([tight], distance: 100),
      throwsStateError,
    );
  });

  test('spline offset rejects a loop or self-crossing result', () {
    final crossing = SketchSpline(const [
      SketchVector(-1, -1),
      SketchVector(1, 1),
      SketchVector(2, -1),
      SketchVector(-1, 1),
    ]);
    expect(
      () => SketchOffsetGeometry.calculate([crossing], distance: 0.01),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('self-intersection'),
        ),
      ),
    );
  });

  test(
    'spline self-intersection sweep rejects work beyond its visit budget',
    () {
      final vertical = SketchSpline(
        List.generate(
          800,
          (index) => SketchVector(index.isEven ? 0 : 1e-5, index.toDouble()),
        ),
      );
      expect(
        () => SketchOffsetGeometry.calculate([vertical], distance: 0.01),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('bounded self-intersection sweep'),
          ),
        ),
      );
    },
  );

  test('spline offset remains local to the Sketch plane for rotated WCS', () {
    final source = SketchSpline(const [
      SketchVector(0, 0),
      SketchVector(8, 1),
      SketchVector(15, 8),
      SketchVector(24, 9),
    ]);
    final offset =
        SketchOffsetGeometry.calculate([source], distance: 0.5).single
            as SketchOffsetSpline;
    const coordinates = SketchCoordinateSystem(
      origin: SketchVector(100, 20, 30),
      xAxis: SketchVector(0, 0, 1),
      yAxis: SketchVector(0, 1, 0),
      normal: SketchVector(-1, 0, 0),
    );
    final sourceKnots = source.parameters['points']
        .map<SketchVector>(SketchVector.fromJson)
        .toList();
    final localDelta = offset.points.first - sourceKnots.first;
    final worldDelta =
        coordinates.xAxis.scale(localDelta.x) +
        coordinates.yAxis.scale(localDelta.y);
    final tangent = SketchSplineGeometry.derivativesAtSpan(
      sourceKnots,
      0,
      0,
    ).first;
    final worldTangent =
        coordinates.xAxis.scale(tangent.x) + coordinates.yAxis.scale(tangent.y);
    expect(worldDelta.dot(worldTangent).abs(), lessThan(1e-8));
    final worldPoint = coordinates.localToGlobal(offset.points.first);
    expect(worldPoint.x, closeTo(100 - offset.points.first.z, 1e-10));
    expect(worldPoint.y, closeTo(20 + offset.points.first.y, 1e-10));
    expect(worldPoint.z, closeTo(30 + offset.points.first.x, 1e-10));
  });

  test(
    'closed rectangular profile offsets outward and inward deterministically',
    () {
      final edges = [
        SketchLine(const SketchVector(0, 0), const SketchVector(10, 0)),
        SketchLine(const SketchVector(10, 0), const SketchVector(10, 8)),
        SketchLine(const SketchVector(10, 8), const SketchVector(0, 8)),
        SketchLine(const SketchVector(0, 8), const SketchVector(0, 0)),
      ];
      final outer = SketchOffsetGeometry.calculate(
        edges,
        distance: 1,
      ).cast<SketchOffsetLine>().toList();
      expect(outer, hasLength(4));
      final outerCoordinates = outer
          .expand((edge) => [edge.start, edge.end])
          .map((point) => (point.x, point.y))
          .toSet();
      expect(outerCoordinates, containsAll({(-1.0, -1.0), (11.0, 9.0)}));

      final inner = SketchOffsetGeometry.calculate(
        edges,
        distance: 1,
        outward: false,
      ).cast<SketchOffsetLine>().toList();
      final innerCoordinates = inner
          .expand((edge) => [edge.start, edge.end])
          .map((point) => (point.x, point.y))
          .toSet();
      expect(innerCoordinates, containsAll({(1.0, 1.0), (9.0, 7.0)}));
      expect(
        () =>
            SketchOffsetGeometry.calculate(edges, distance: 5, outward: false),
        throwsStateError,
      );
    },
  );

  test('closed concave profile resolves miters and rejects collapse', () {
    final points = [
      const SketchVector(0, 0),
      const SketchVector(4, 0),
      const SketchVector(4, 1),
      const SketchVector(1, 1),
      const SketchVector(1, 4),
      const SketchVector(0, 4),
    ];
    final edges = [
      for (var index = 0; index < points.length; index++)
        SketchLine(points[index], points[(index + 1) % points.length]),
    ];
    expect(
      SketchOffsetGeometry.calculate(edges, distance: 0.25),
      hasLength(points.length),
    );
    expect(
      () => SketchOffsetGeometry.calculate(edges, distance: 2, outward: false),
      throwsStateError,
    );
    expect(
      () =>
          SketchOffsetGeometry.calculate(edges, distance: 0.75, outward: false),
      throwsStateError,
    );
  });

  test(
    'rejects invalid distance, disconnected, branched and unsupported inputs',
    () {
      final line = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      expect(
        () => SketchOffsetGeometry.calculate([line], distance: 0),
        throwsArgumentError,
      );
      expect(
        () => SketchOffsetGeometry.calculate([line], distance: double.nan),
        throwsArgumentError,
      );
      expect(
        () => SketchOffsetGeometry.calculate([
          line,
          SketchLine(const SketchVector(5, 0), const SketchVector(6, 0)),
        ], distance: 1),
        throwsStateError,
      );
      expect(
        () => SketchOffsetGeometry.calculate([
          line,
          SketchLine(const SketchVector(1, 0), const SketchVector(1, 1)),
          SketchLine(const SketchVector(1, 0), const SketchVector(2, 0)),
        ], distance: 1),
        throwsStateError,
      );
      expect(
        () => SketchOffsetGeometry.calculate([
          ConstructionGeometry({
            'point': [0, 0, 0],
          }),
        ], distance: 1),
        throwsStateError,
      );
      expect(
        () => SketchOffsetGeometry.calculate([
          SketchLine(const SketchVector(0, 0), const SketchVector(1, 0)),
          SketchArc(const SketchVector(2, 0), 1, 0, math.pi),
        ], distance: 1),
        throwsStateError,
      );
    },
  );

  group('canonical editor transaction', () {
    late Directory project;
    late SketchEngineApi sketch;
    late SketchEditorApi editor;
    late ConstraintApi constraints;

    setUp(() async {
      project = await Directory.systemTemp.createTemp('sketch_offset_');
      sketch = const SketchEngineFactory().create(project)
        ..createSketch('Offset');
      constraints = const ConstraintFactory().create(
        projectDirectory: project,
        sketch: sketch,
      );
      editor = const SketchEditorFactory().create(
        projectDirectory: project,
        sketch: sketch,
        constraints: constraints,
      );
    });
    tearDown(() async {
      if (await project.exists()) await project.delete(recursive: true);
    });

    test(
      'preview and cancel are non-mutating; apply is one undo and redo',
      () async {
        final source = sketch.builders.line.build(
          const SketchVector(0, 0),
          const SketchVector(10, 0),
        );
        final before = sketch.engine.entities.length;
        final preview = editor.preview(SketchToolType.offset, const []);
        editor.cancel(preview.id);
        expect(sketch.engine.entities, hasLength(before));
        expect(source.parameters['start'], [0.0, 0.0, 0.0]);

        editor.preview(SketchToolType.offset, const []);
        editor.edit(SketchToolType.offset, [source.id], value: 2);
        expect(sketch.engine.entities, hasLength(before + 1));
        final generated = sketch.engine.entities.values
            .whereType<SketchLine>()
            .last;
        expect(generated.parameters['start'], [0.0, 2.0, 0.0]);
        expect(source.parameters['start'], [0.0, 0.0, 0.0]);
        expect(generated.metadata['sourceEntityIds'], [source.id]);
        expect(generated.metadata['associative'], isFalse);
        expect(editor.undo(), isTrue);
        expect(sketch.engine.entities, hasLength(before));
        expect(editor.redo(), isTrue);
        expect(sketch.engine.entities, hasLength(before + 1));
        await sketch.engine.persist();
        final reopened = const SketchEngineFactory().create(project);
        await reopened.load();
        reopened.openSketch(sketch.engine.activeSketch.id);
        final restored = reopened.entity(generated.id) as SketchLine;
        expect(restored.parameters['start'], [0.0, 2.0, 0.0]);
        expect(restored.metadata['featureType'], 'geometricOffset');
        expect(restored.metadata['sourceEntityIds'], [source.id]);
        expect(restored.metadata['associative'], isFalse);
      },
    );

    test('failed offset rolls back geometry and leaves source untouched', () {
      final source = sketch.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
      );
      final before = sketch.engine.entities.length;
      final preview = editor.preview(SketchToolType.offset, const []);
      expect(
        () => editor.edit(SketchToolType.offset, [
          source.id,
        ], value: double.infinity),
        throwsArgumentError,
      );
      expect(sketch.engine.entities, hasLength(before));
      expect(source.parameters['start'], [0.0, 0.0, 0.0]);
      expect(preview.status, EditorOperationStatus.failed);
    });

    test(
      'bounded spline rejection preserves geometry and history atomically',
      () {
        final source = sketch.builders.spline.build(
          List.generate(
            800,
            (index) => SketchVector(index.isEven ? 0 : 1e-5, index.toDouble()),
          ),
        );
        final sourceSnapshot = source.parameters.toString();
        final entityCount = sketch.engine.entities.length;
        final undoDepth = sketch.engine.undoDepth;
        editor.preview(SketchToolType.offset, const []);
        expect(
          () => editor.edit(SketchToolType.offset, [source.id], value: 0.01),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('bounded self-intersection sweep'),
            ),
          ),
        );
        expect(sketch.engine.entities, hasLength(entityCount));
        expect(source.parameters.toString(), sourceSnapshot);
        expect(sketch.engine.undoDepth, undoDepth);
      },
    );

    test('circle Apply creates a concentric independent circle entity', () {
      final source = sketch.builders.circle.build(const SketchVector(2, 3), 10);
      editor.preview(SketchToolType.offset, const []);
      editor.edit(
        SketchToolType.offset,
        [source.id],
        value: 2,
        parameters: {'outward': false},
      );
      final generated = sketch.engine.entities.values
          .whereType<SketchCircle>()
          .singleWhere((circle) => circle.id != source.id);
      expect(source.parameters['radius'], 10);
      expect(generated.parameters['center'], [2.0, 3.0, 0.0]);
      expect(generated.parameters['radius'], 8);
      expect(editor.undo(), isTrue);
      expect(sketch.engine.entities.containsKey(generated.id), isFalse);
    });

    test('ellipse Apply creates independent geometry in one undoable edit', () {
      final source = sketch.builders.ellipse.build(
        const SketchVector(2, 3),
        10,
        6,
      );
      editor.preview(SketchToolType.offset, const []);
      editor.edit(SketchToolType.offset, [source.id], value: 2);
      final generated = sketch.engine.entities.values
          .whereType<SketchEllipse>()
          .singleWhere((ellipse) => ellipse.id != source.id);
      expect(generated.parameters['center'], [2.0, 3.0, 0.0]);
      expect(generated.parameters['radiusX'], 12);
      expect(generated.parameters['radiusY'], 8);
      expect(source.parameters['radiusX'], 10);
      expect(source.parameters['radiusY'], 6);
      expect(generated.metadata['sourceEntityIds'], [source.id]);
      expect(generated.metadata['associative'], isFalse);
      expect(editor.undo(), isTrue);
      expect(sketch.engine.entities.containsKey(generated.id), isFalse);
      expect(editor.redo(), isTrue);
      expect(sketch.engine.entities.containsKey(generated.id), isTrue);
    });

    test(
      'arc offset survives Sketch Save/Open with analytic parameters',
      () async {
        final source = sketch.builders.arc.build(
          const SketchVector(4, 5),
          10,
          1.7,
          0.2,
        );
        editor.preview(SketchToolType.offset, const []);
        editor.edit(
          SketchToolType.offset,
          [source.id],
          value: 2,
          parameters: {'outward': false},
        );
        final generated = sketch.engine.entities.values
            .whereType<SketchArc>()
            .singleWhere((arc) => arc.id != source.id);
        expect(generated.parameters['radius'], 8);
        expect(generated.parameters['startAngle'], 1.7);
        expect(generated.parameters['endAngle'], 0.2);
        await sketch.engine.persist();

        final reopened = const SketchEngineFactory().create(project);
        await reopened.load();
        reopened.openSketch(sketch.engine.activeSketch.id);
        final restored = reopened.entity(generated.id) as SketchArc;
        expect(restored.parameters['center'], [4.0, 5.0, 0.0]);
        expect(restored.parameters['radius'], 8);
        expect(restored.parameters['startAngle'], 1.7);
        expect(restored.parameters['endAngle'], 0.2);
        expect(restored.metadata['featureType'], 'geometricOffset');
        expect(restored.metadata['sourceEntityIds'], [source.id]);
        expect(restored.metadata['associative'], isFalse);
      },
    );

    test('spline offset is one transaction and survives Save/Open', () async {
      final source = sketch.builders.spline.build(const [
        SketchVector(0, 0),
        SketchVector(8, 1),
        SketchVector(15, 8),
        SketchVector(24, 9),
      ]);
      editor.preview(SketchToolType.offset, const []);
      editor.edit(SketchToolType.offset, [source.id], value: 1.25);
      final generated = sketch.engine.entities.values
          .whereType<SketchSpline>()
          .singleWhere((spline) => spline.id != source.id);
      expect(generated.parameters['interpolation'], 'centripetalCatmullRom');
      expect(generated.metadata['featureType'], 'geometricOffset');
      expect(generated.metadata['sourceEntityIds'], [source.id]);
      expect(generated.metadata['associative'], isFalse);
      expect(generated.metadata['offsetSignedDistanceMm'], 1.25);
      expect(
        generated.metadata['offsetEstimatedMaxErrorMm'],
        lessThanOrEqualTo(.05),
      );
      expect(editor.undo(), isTrue);
      expect(sketch.engine.entities.containsKey(generated.id), isFalse);
      expect(editor.redo(), isTrue);
      expect(sketch.engine.entities.containsKey(generated.id), isTrue);
      await sketch.engine.persist();
      final reopened = const SketchEngineFactory().create(project);
      await reopened.load();
      reopened.openSketch(sketch.engine.activeSketch.id);
      final restored = reopened.entity(generated.id) as SketchSpline;
      expect(restored.id, generated.id);
      expect(restored.parameters['interpolation'], 'centripetalCatmullRom');
      expect(restored.metadata['sourceEntityIds'], [source.id]);
      expect(restored.metadata['associative'], isFalse);
    });
  });
}

double _distanceToPolyline(SketchVector point, List<SketchVector> line) {
  var best = double.infinity;
  for (var index = 1; index < line.length; index++) {
    final a = line[index - 1], b = line[index];
    final ab = b - a;
    final lengthSquared = ab.dot(ab);
    final t = lengthSquared == 0
        ? 0.0
        : ((point - a).dot(ab) / lengthSquared).clamp(0.0, 1.0);
    final delta = point - (a + ab.scale(t));
    best = math.min(best, math.sqrt(delta.dot(delta)));
  }
  return best;
}
