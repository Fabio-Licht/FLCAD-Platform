import 'dart:convert';
import 'dart:io';

import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/cad_document_repository.dart';
import 'package:flcad_mobile/core/sketch_constraints/api/constraint_api.dart';
import 'package:flcad_mobile/core/sketch_constraints/integration/constraint_factory.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_editor/api/sketch_editor_api.dart';
import 'package:flcad_mobile/core/sketch_editor/integration/editor_factory.dart';
import 'package:flcad_mobile/core/sketch_editor/models/editor_models.dart';
import 'package:flcad_mobile/core/sketch_engine/api/sketch_engine_api.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/sketch_factory.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/sketch_engine/persistence/sketch_persistence_transaction.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) exit(64);
  final mode = args[0];
  final project = Directory(args[1]);
  final sketch = const SketchEngineFactory().create(project);
  final constraints = const ConstraintFactory().create(
    projectDirectory: project,
    sketch: sketch,
  );
  final editor = const SketchEditorFactory().create(
    projectDirectory: project,
    sketch: sketch,
    constraints: constraints,
  );

  switch (mode) {
    case 'init':
      await _initialize(project, sketch, constraints, editor);
      stdout.writeln(jsonEncode(await _snapshot(project, sketch, constraints)));
    case 'crash-sketch':
    case 'crash-constraints':
    case 'crash-editor':
      await sketch.load();
      await constraints.load();
      final root = sketch.sketches.single;
      sketch.openSketch(root.id);
      final addedLine = sketch.builders.line.build(
        const SketchVector(9, 9),
        const SketchVector(12, 9),
      );
      editor.preview(SketchToolType.move, const []);
      editor.edit(SketchToolType.move, [
        addedLine.id,
      ], delta: const SketchVector(1, 0));
      constraints.builders.of(SketchConstraintType.horizontal).build([
        addedLine.id,
      ]);
      await const SketchPersistenceTransaction().run(project, () async {
        await sketch.persist();
        await _checkpoint(mode, 'after-sketch-write');
        await constraints.persist();
        await _checkpoint(mode, 'after-constraints-write');
        await editor.persist();
        await _checkpoint(mode, 'after-editor-write');
      });
      exit(70);
    case 'verify':
      // Loading the Sketch contract runs durable transaction recovery first.
      await sketch.load();
      await constraints.load();
      stdout.writeln(jsonEncode(await _snapshot(project, sketch, constraints)));
    default:
      exit(64);
  }
}

Future<void> _checkpoint(String mode, String phase) async {
  final expected = 'crash-${phase.split('-')[1]}';
  if (mode != expected) return;
  stdout.writeln('READY:$phase');
  await stdout.flush();
  stdin.readLineSync();
}

Future<void> _initialize(
  Directory project,
  SketchEngineApi sketch,
  ConstraintApi constraints,
  SketchEditorApi editor,
) async {
  final root = sketch.createSketch('Recovery Sketch');
  final line = sketch.builders.line.build(
    const SketchVector(0, 0),
    const SketchVector(5, 0),
  );
  constraints.builders.of(SketchConstraintType.fixed).build([line.id]);
  await const SketchPersistenceTransaction().run(project, () async {
    await sketch.persist();
    await constraints.persist();
    await editor.persist();
  });
  final document = CadDocument.empty('recovery-project').mutate(
    command: 'seed',
    upsert: [
      CadDocumentEntity(
        id: 'cad-seed',
        kind: CadDocumentEntityKind.sketch,
        data: {
          'marker': 'baseline',
          'sceneKind': 'sketch',
          'parentSketchId': root.id,
        },
      ),
    ],
  );
  final repository = const CadDocumentRepository();
  await repository.save(document, project);
  await repository.saveHistory(
    project,
    undo: [CadDocument.empty('recovery-project')],
    redo: const [],
  );
}

Future<Map<String, Object?>> _snapshot(
  Directory project,
  SketchEngineApi sketch,
  ConstraintApi constraints,
) async {
  final cad = await const CadDocumentRepository().load(
    'recovery-project',
    project,
  );
  final editorFiles = <String, String>{};
  for (final name in const [
    'CAD/SketchEditorHistory/history.json',
    'CAD/SketchEditorGraph/graph.json',
    'CAD/SketchEditorAnalytics/analytics.json',
  ]) {
    final file = File(
      '${project.path}${Platform.pathSeparator}'
      '${name.replaceAll('/', Platform.pathSeparator)}',
    );
    editorFiles[name] = file.existsSync()
        ? file.readAsStringSync()
        : '<missing>';
  }
  return {
    'sketchIds': sketch.sketches.map((item) => item.id).toList(),
    'lineIds': sketch.engine.entities.values
        .whereType<SketchLine>()
        .map((item) => item.id)
        .toList(),
    'constraints': constraints.constraints
        .map((item) => {'type': item.type.name, 'references': item.references})
        .toList(),
    'constraintCount': constraints.constraints.length,
    'fixedConstraintCount': constraints.constraints
        .where((item) => item.type == SketchConstraintType.fixed)
        .length,
    'editorFiles': editorFiles,
    'cadEntities': cad.entities.keys.toList(),
    'cadMarker': cad.entities['cad-seed']?.data['marker'],
  };
}
