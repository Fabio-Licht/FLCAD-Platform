import 'dart:io';
import 'dart:math' as math;
import 'package:flcad_mobile/app/bootstrap/engineering_bootstrap.dart';
import 'package:flcad_mobile/core/engineering_studio/properties/property_inspector.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/constraint_factory.dart';
import 'package:flcad_mobile/core/sketch_constraints/api/constraint_api.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_editor/analytics/editor_analytics.dart';
import 'package:flcad_mobile/core/sketch_editor/api/sketch_editor_api.dart';
import 'package:flcad_mobile/core/sketch_editor/commands/fel_editor_commands.dart';
import 'package:flcad_mobile/core/sketch_editor/history/editor_history.dart';
import 'package:flcad_mobile/core/sketch_editor/integration/editor_factory.dart';
import 'package:flcad_mobile/core/sketch_editor/integration/editor_studio.dart';
import 'package:flcad_mobile/core/sketch_editor/models/editor_models.dart';
import 'package:flcad_mobile/core/sketch_editor/render/editor_render.dart';
import 'package:flcad_mobile/core/sketch_editor/repository/editor_repository.dart';
import 'package:flcad_mobile/core/sketch_editor/runtime/editor_runtime.dart';
import 'package:flcad_mobile/core/sketch_editor/selection/editor_selection.dart';
import 'package:flcad_mobile/core/sketch_editor/snapping/editor_snapping.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/sketch_factory.dart';
import 'package:flcad_mobile/core/sketch_engine/api/sketch_engine_api.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory project;
  late SketchEngineApi sketch;
  late ConstraintApi constraints;
  late SketchEditorApi editor;
  setUp(() async {
    project = await Directory.systemTemp.createTemp('flcad_editor_');
    sketch = const SketchEngineFactory().create(project)
      ..createSketch('Interactive');
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

  test('creation tools require preview and commit parametric geometry', () {
    final line = editor.preview(SketchToolType.line, const [
      SketchVector(0, 0),
      SketchVector(2, 2),
    ]);
    expect(editor.engine.preview.active, hasLength(1));
    final created = editor.confirm(line.id);
    expect(created.single, isA<SketchLine>());
    expect(created.single.parameters['length'], closeTo(math.sqrt(8), 1e-12));
    expect(created.single.parameters['direction'], isA<List<double>>());
    expect(created.single.parameters['angleDegrees'], closeTo(45, 1e-12));
    expect(line.status, EditorOperationStatus.committed);
    final rectangle = editor.preview(SketchToolType.rectangle, const [
      SketchVector(0, 0),
      SketchVector(4, 3),
    ]);
    expect(editor.confirm(rectangle.id), hasLength(4));
    final circle = editor.preview(SketchToolType.circle, const [
      SketchVector(0, 0),
      SketchVector(2, 0),
    ]);
    expect(editor.confirm(circle.id).single, isA<SketchCircle>());
    final polygon = editor.preview(
      SketchToolType.polygon,
      const [SketchVector(0, 0), SketchVector(2, 0)],
      parameters: {'sides': 6},
    );
    expect(editor.confirm(polygon.id), hasLength(6));
  });

  test('professional Line snapping is limited to endpoint origin and grid', () {
    final settings = editor.engine.snapping.settings
      ..tolerance = .5
      ..gridSpacing = 1;
    settings.enabled
      ..clear()
      ..addAll(const {
        EditorSnapType.endpoint,
        EditorSnapType.origin,
        EditorSnapType.grid,
      });
    settings.priority.addAll(const {
      EditorSnapType.endpoint: 30,
      EditorSnapType.origin: 20,
      EditorSnapType.grid: 10,
    });
    final line = editor.confirm(
      editor.preview(SketchToolType.line, const [
        SketchVector(2, 2),
        SketchVector(4, 2),
      ]).id,
    );
    expect(line.single, isA<SketchLine>());
    expect(
      editor.snap(const SketchVector(2.1, 2.05))?.type,
      EditorSnapType.endpoint,
    );
    expect(
      editor.snap(const SketchVector(.1, .1))?.type,
      EditorSnapType.origin,
    );
    final grid = editor.snap(const SketchVector(7.7, 3.2));
    expect(grid?.type, EditorSnapType.grid);
    expect(grid?.position.toJson(), [8.0, 3.0, 0.0]);
  });

  test('professional Line snaps to both real Arc endpoints', () {
    final settings = editor.engine.snapping.settings
      ..tolerance = .5
      ..gridSpacing = 1;
    settings.enabled
      ..clear()
      ..addAll(const {
        EditorSnapType.endpoint,
        EditorSnapType.origin,
        EditorSnapType.grid,
      });
    settings.priority.addAll(const {
      EditorSnapType.endpoint: 30,
      EditorSnapType.origin: 20,
      EditorSnapType.grid: 10,
    });
    final arc = sketch.builders.arc.build(
      const SketchVector(5, 5),
      5,
      0,
      math.pi / 2,
    );

    final start = editor.snap(const SketchVector(9.9, 5.05));
    expect(start?.type, EditorSnapType.endpoint);
    expect(start?.entityId, arc.id);
    expect(start?.position.toJson(), [10.0, 5.0, 0.0]);

    final end = editor.snap(const SketchVector(5.05, 9.9));
    expect(end?.type, EditorSnapType.endpoint);
    expect(end?.entityId, arc.id);
    expect(end?.position.x, closeTo(5, 1e-12));
    expect(end?.position.y, closeTo(10, 1e-12));
  });

  test('editing preview rollback and undo redo sequence', () {
    final p = editor.preview(SketchToolType.point, const [SketchVector(0, 0)]);
    final point = editor.confirm(p.id).single;
    expect(
      () => editor.edit(SketchToolType.move, [
        point.id,
      ], delta: const SketchVector(1, 1)),
      throwsStateError,
    );
    editor.preview(SketchToolType.move, const []);
    editor.edit(SketchToolType.move, [
      point.id,
    ], delta: const SketchVector(1, 1));
    expect(point.parameters['point'], [1.0, 1.0, 0.0]);
    expect(editor.undo(), isTrue);
    expect(editor.redo(), isTrue);
    final bad = editor.preview(SketchToolType.circle, const [
      SketchVector(0, 0),
      SketchVector(0, 0),
    ]);
    expect(() => editor.confirm(bad.id), throwsArgumentError);
    expect(
      editor.engine.history.entries.last.action,
      EditorHistoryAction.rollback,
    );
  });

  test('professional editing tools change real sketch geometry', () {
    void edit(
      SketchToolType tool,
      Iterable<String> ids, {
      SketchVector? delta,
      double value = 1,
      Map<String, dynamic> parameters = const {},
    }) {
      editor.preview(tool, const []);
      editor.edit(
        tool,
        ids,
        delta: delta,
        value: value,
        parameters: parameters,
      );
    }

    final transformed = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(2, 0),
    );
    edit(SketchToolType.move, [
      transformed.id,
    ], delta: const SketchVector(1, 2));
    expect(transformed.parameters['start'], [1.0, 2.0, 0.0]);
    edit(
      SketchToolType.rotate,
      [transformed.id],
      value: math.pi / 2,
      parameters: {'center': const SketchVector(1, 2).toJson()},
    );
    expect((transformed.parameters['end'] as List)[0], closeTo(1, 1e-9));
    edit(
      SketchToolType.scale,
      [transformed.id],
      value: 2,
      parameters: {'center': const SketchVector(1, 2).toJson()},
    );
    edit(
      SketchToolType.mirror,
      [transformed.id],
      parameters: {
        'axisStart': const SketchVector(0, 0).toJson(),
        'axisEnd': const SketchVector(1, 0).toJson(),
      },
    );
    expect((transformed.parameters['end'] as List)[1], closeTo(-6, 1e-9));

    final offsetSource = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final countBeforeOffset = sketch.engine.entities.length;
    edit(SketchToolType.offset, [offsetSource.id], value: 2);
    expect(offsetSource.parameters['start'], [0.0, 0.0, 0.0]);
    expect(sketch.engine.entities.length, countBeforeOffset + 1);
    var offset = sketch.engine.entities.values.whereType<SketchLine>().last;
    expect(offset.parameters['start'], [0.0, 2.0, 0.0]);
    expect(offset.parameters['end'], [10.0, 2.0, 0.0]);
    expect(offset.metadata['featureType'], 'geometricOffset');
    expect(offset.metadata['associative'], isFalse);
    expect(editor.undo(), isTrue);
    expect(sketch.engine.entities.containsKey(offset.id), isFalse);
    expect(editor.redo(), isTrue);
    offset = sketch.engine.entities[offset.id]! as SketchLine;
    edit(
      SketchToolType.trim,
      [offset.id],
      parameters: {'point': const SketchVector(3, 5).toJson()},
    );
    expect(offset.parameters['start'], [3.0, 2.0, 0.0]);
    edit(
      SketchToolType.extend,
      [offset.id],
      parameters: {'point': const SketchVector(15, 8).toJson()},
    );
    expect(offset.parameters['end'], [15.0, 2.0, 0.0]);

    final split = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final countBeforeSplit = sketch.engine.entities.length;
    edit(
      SketchToolType.split,
      [split.id],
      parameters: {'point': const SketchVector(4, 3).toJson()},
    );
    expect(split.parameters['end'], [4.0, 0.0, 0.0]);
    expect(sketch.engine.entities.length, countBeforeSplit + 1);

    final joinA = sketch.builders.line.build(
      const SketchVector(0, 5),
      const SketchVector(2, 5),
    );
    final joinB = sketch.builders.line.build(
      const SketchVector(2, 5),
      const SketchVector(5, 5),
    );
    edit(SketchToolType.join, [joinA.id, joinB.id]);
    expect(sketch.entity(joinB.id), isNull);
    expect(joinA.parameters['end'], [5.0, 5.0, 0.0]);

    final filletA = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(5, 0),
    );
    final filletB = sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(0, 5),
    );
    edit(SketchToolType.fillet, [filletA.id, filletB.id], value: 1);
    expect(sketch.engine.entities.values.whereType<SketchArc>(), isNotEmpty);

    final chamferA = sketch.builders.line.build(
      const SketchVector(10, 0),
      const SketchVector(15, 0),
    );
    final chamferB = sketch.builders.line.build(
      const SketchVector(10, 0),
      const SketchVector(10, 5),
    );
    final countBeforeChamfer = sketch.engine.entities.length;
    edit(SketchToolType.chamfer, [chamferA.id, chamferB.id], value: 1);
    expect(sketch.engine.entities.length, countBeforeChamfer + 1);
    expect(editor.undo(), isTrue);
    expect(editor.redo(), isTrue);
  });

  test('1000 selections groups persistence hover preview and filters', () {
    final point = sketch.builders.point.build(const SketchVector(0, 0));
    for (var i = 0; i < 1000; i++) {
      editor.engine.selection.select(point, multi: true, persist: true);
    }
    editor.engine.selection
      ..createGroup('primary', [point.id])
      ..hover(point)
      ..preselect(point)
      ..preview(point.id)
      ..highlight(point.id)
      ..restorePersistent();
    expect(editor.engine.selection.history, hasLength(1001));
    expect(editor.engine.selection.groups['primary'], contains(point.id));
    expect(
      editor.engine.selection.window([
        point,
      ], const EditorSelectionFilter(types: {SketchEntityType.point})),
      [point],
    );
  });

  test('1000 snaps produce endpoint preview diagnostics architecture', () {
    final point = sketch.builders.point.build(const SketchVector(1, 1));
    for (var i = 0; i < 1000; i++) {
      expect(
        editor.engine.snapping.snap(const SketchVector(1, 1), [point])?.type,
        EditorSnapType.endpoint,
      );
    }
    expect(editor.engine.analytics.snapCount, 1000);
    expect(editor.engine.snapping.preview, isNotNull);
    expect(EditorSnapType.values, hasLength(13));
  });

  test('1000 dynamic previews can be cancelled without mutation', () {
    final ids = <String>[];
    for (var i = 0; i < 1000; i++) {
      ids.add(
        editor.preview(SketchToolType.line, [
          SketchVector(i.toDouble(), 0),
          SketchVector(i.toDouble(), 1),
        ]).id,
      );
    }
    expect(editor.engine.preview.active, hasLength(1000));
    for (final id in ids) {
      editor.cancel(id);
    }
    expect(editor.engine.preview.active, isEmpty);
    expect(sketch.engine.entities, isEmpty);
  });

  test('DOF quality and advisor only read solver results', () async {
    final a = sketch.builders.point.build(const SketchVector(0, 0));
    final b = sketch.builders.point.build(const SketchVector(1, 1));
    constraints.builders.of(SketchConstraintType.fixed).build([a.id]);
    await constraints.solve();
    final dof = editor.dof,
        quality = editor.quality,
        recommendations = editor.recommendations;
    expect(dof.remaining, greaterThan(0));
    expect(quality.score, inInclusiveRange(0, 100));
    expect(SketchQualityGrade.values, contains(quality.grade));
    expect(recommendations, isNotEmpty);
    expect(
      recommendations.every((r) => r.confidence >= 0 && r.confidence <= 100),
      isTrue,
    );
    expect(b.parameters['point'], [1.0, 1.0, 0.0]);
  });

  test(
    'repository toolbar render styles analytics and runtime are explicit',
    () async {
      expect(editor.engine.runtime.isInitialized, isFalse);
      editor.engine.runtime.initialize();
      editor.engine.toolbar.activate(SketchToolType.line);
      expect(editor.engine.toolbar.activeTool, SketchToolType.line);
      expect(
        SketchStylePalette.styles.keys.toSet(),
        SketchVisualState.values.toSet(),
      );
      await editor.engine.persist();
      for (final path in EditorRepository.paths) {
        expect(
          Directory(
            '${project.path}${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}',
          ).existsSync(),
          isTrue,
        );
      }
      expect(editor.engine.analytics.toJson(), contains('sketchQuality'));
    },
  );

  test('FEL Studio tree inspector factory and bootstrap integrate', () {
    final point = sketch.builders.point.build(const SketchVector(0, 0));
    editor.engine.selection.select(point);
    expect(
      createSketchEditorFelCommands(editor).map((c) => c.name).toSet(),
      hasLength(30),
    );
    final nodes = const SketchEditorStudioAdapter().buildTree(
      sketch,
      constraints,
      editor.engine,
      'project',
    );
    expect(nodes.any((n) => n.name == 'Entities'), isTrue);
    expect(nodes.any((n) => n.name == 'Constraints'), isFalse);
    final section = const PropertyInspector()
        .inspect(nodes.firstWhere((n) => n.id == point.id))
        .firstWhere((s) => s.name == 'Sketch Editor');
    expect(
      section.values.keys,
      containsAll([
        'coordinates',
        'length',
        'radius',
        'diameter',
        'angle',
        'construction',
        'reference',
        'driving',
        'driven',
        'constraintCount',
        'degreesOfFreedom',
        'selectionState',
        'persistentId',
        'history',
        'diagnostics',
      ]),
    );
    final bootstrap = EngineeringBootstrap.instance..initialize();
    expect(bootstrap.services.get<SketchEditorFactory>(), isNotNull);
    expect(bootstrap.services.get<EditorRuntime>(), isNotNull);
    expect(bootstrap.services.get<EditorRepository>(), isNotNull);
    expect(bootstrap.services.get<EditorAnalytics>(), isNotNull);
    expect(bootstrap.services.get<EditorHistory>(), isNotNull);
  });
}
