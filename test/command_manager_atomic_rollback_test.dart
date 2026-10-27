import 'dart:io';

import 'package:flcad_mobile/app/commands/command_context.dart';
import 'package:flcad_mobile/app/commands/command_manager.dart';
import 'package:flcad_mobile/app/commands/command_registry.dart';
import 'package:flcad_mobile/app/commands/command_validation.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory stand-in for the domains a failed command must restore together.
class _Domain {
  _Domain()
    : document = 'document-a',
      geometry = 'line-a',
      constraints = 'coincident-a',
      ids = ['ske:a'],
      history = ['create'],
      undo = ['baseline'],
      redo = ['later'],
      dirty = false,
      revision = 3,
      previews = ['idle'];

  String document;
  String geometry;
  String constraints;
  List<String> ids;
  List<String> history;
  List<String> undo;
  List<String> redo;
  bool dirty;
  int revision;
  List<String> previews;

  Map<String, Object> snapshot() => {
    'document': document,
    'geometry': geometry,
    'constraints': constraints,
    'ids': List<String>.of(ids),
    'history': List<String>.of(history),
    'undo': List<String>.of(undo),
    'redo': List<String>.of(redo),
    'dirty': dirty,
    'revision': revision,
    'previews': List<String>.of(previews),
  };

  void corrupt() {
    document = 'partial';
    geometry = 'moved';
    constraints = 'dropped';
    ids = ['ske:partial'];
    history = ['create', 'partial'];
    undo = ['baseline', 'partial'];
    redo = [];
    dirty = true;
    revision = 4;
    previews = ['dangling'];
  }

  void restore(Map<String, Object> saved) {
    document = saved['document']! as String;
    geometry = saved['geometry']! as String;
    constraints = saved['constraints']! as String;
    ids = List<String>.of(saved['ids']! as List<String>);
    history = List<String>.of(saved['history']! as List<String>);
    undo = List<String>.of(saved['undo']! as List<String>);
    redo = List<String>.of(saved['redo']! as List<String>);
    dirty = saved['dirty']! as bool;
    revision = saved['revision']! as int;
    previews = List<String>.of(saved['previews']! as List<String>);
  }
}

void main() {
  test(
    'a mutation that then throws is rolled back atomically',
    () async {
      final domain = _Domain();
      final before = domain.snapshot();
      final registry = CommandRegistry();
      registry.register(
        RegisteredEngineeringCommand(
          id: 'sketch.partial',
          module: 'Sketch',
          execute: (_, _) async {
            domain.corrupt();
            throw StateError('persistence failed after mutation');
          },
          undo: (_, _) async => 'unused when execute throws',
          redo: (_, _) async => 'unused when execute throws',
          checkpoint: (_, _) async {
            final saved = domain.snapshot();
            return () async => domain.restore(saved);
          },
        ),
      );
      final manager = CommandManager(registry: registry);
      final context = CommandContext(
        projectId: null,
        projectDirectory: null,
      );

      await expectLater(
        manager.execute('sketch.partial', context),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'persistence failed after mutation',
          ),
        ),
      );

      expect(domain.snapshot(), before);
      expect(manager.canUndo, isFalse);
      expect(manager.canRedo, isFalse);
      expect(manager.undoDepth, 0);
      expect(manager.redoDepth, 0);
      expect(manager.history, isEmpty);
    },
  );

  test(
    'without a checkpoint the same failure leaves the mutation',
    () async {
      final domain = _Domain();
      final registry = CommandRegistry();
      registry.register(
        RegisteredEngineeringCommand(
          id: 'sketch.partial',
          module: 'Sketch',
          execute: (_, _) async {
            domain.corrupt();
            throw StateError('persistence failed after mutation');
          },
          undo: (_, _) async {
            domain.restore({
              'document': 'document-a',
              'geometry': 'line-a',
              'constraints': 'coincident-a',
              'ids': ['ske:a'],
              'history': ['create'],
              'undo': ['baseline'],
              'redo': ['later'],
              'dirty': false,
              'revision': 3,
              'previews': ['idle'],
            });
            return 'would have restored';
          },
          redo: (_, _) async => 'unused when execute throws',
        ),
      );
      final manager = CommandManager(registry: registry);

      await expectLater(
        manager.execute(
          'sketch.partial',
          CommandContext(projectId: null, projectDirectory: null),
        ),
        throwsA(isA<StateError>()),
      );

      expect(domain.document, 'partial');
      expect(domain.geometry, 'moved');
      expect(domain.dirty, isTrue);
      expect(domain.revision, 4);
      expect(manager.canUndo, isFalse);
      expect(manager.lastUncheckpointedFailure, isA<CommandUncheckpointedFailure>());
      expect(
        (manager.lastUncheckpointedFailure! as CommandUncheckpointedFailure)
            .original,
        isA<StateError>(),
      );
    },
  );

  test('a successful command still commits undo and keeps the mutation', () async {
    final domain = _Domain();
    final registry = CommandRegistry();
    registry.register(
      RegisteredEngineeringCommand(
        id: 'sketch.ok',
        module: 'Sketch',
        execute: (_, _) async {
          domain.geometry = 'line-b';
          domain.dirty = true;
          domain.revision = 4;
          return 'ok';
        },
        undo: (_, _) async {
          domain.geometry = 'line-a';
          domain.dirty = false;
          domain.revision = 3;
          return 'undone';
        },
        redo: (_, _) async {
          domain.geometry = 'line-b';
          domain.dirty = true;
          domain.revision = 4;
          return 'redone';
        },
        checkpoint: (_, _) async {
          final saved = domain.snapshot();
          return () async => domain.restore(saved);
        },
      ),
    );
    final manager = CommandManager(registry: registry);
    final directory = await Directory.systemTemp.createTemp('cmd-atomic-');
    addTearDown(() => directory.delete(recursive: true));

    final result = await manager.execute(
      'sketch.ok',
      CommandContext(projectId: 'p', projectDirectory: directory),
    );

    expect(result, 'ok');
    expect(domain.geometry, 'line-b');
    expect(domain.dirty, isTrue);
    expect(manager.canUndo, isTrue);
    expect(manager.history, hasLength(1));
  });

  test(
    'a failed command restores the CAD document, revision and shape handle',
    () async {
      final shape = ShapeHandle.reference(
        persistentId: 'shape-a',
        kernelId: 'kernel-a',
        type: CADShapeType.edge,
      );
      final runtime = CadRuntime(kernels: KernelManager());
      addTearDown(runtime.dispose);
      final original = CadDocument(
        projectId: 'p',
        entities: {
          'e1': CadDocumentEntity(
            id: 'e1',
            kind: CadDocumentEntityKind.curve,
            data: {'name': 'line'},
            shape: shape,
          ),
        },
        revisions: [
          CadDocumentRevision(1, 'create', DateTime.utc(2026, 1, 1)),
        ],
        parameters: {'units': 'mm'},
      );
      runtime.debugInstallDocument(original);
      final registry = CommandRegistry();
      registry.register(
        RegisteredEngineeringCommand(
          id: 'sketch.partial',
          module: 'Sketch',
          execute: (_, _) async {
            runtime.document!.entities['e1']!.data['name'] = 'partial';
            runtime.debugInstallDocument(
              runtime.document!.mutate(
                command: 'partial',
                upsert: [
                  CadDocumentEntity(
                    id: 'e1',
                    kind: CadDocumentEntityKind.curve,
                    data: {'name': 'partial'},
                  ),
                ],
              ),
            );
            throw StateError('persistence failed after mutation');
          },
          undo: (_, _) async => 'unused when execute throws',
          redo: (_, _) async => 'unused when execute throws',
          checkpoint: (_, _) async {
            final saved = runtime.captureCommandCheckpoint();
            return () async {
              runtime.restoreCommandCheckpoint(saved);
            };
          },
        ),
      );
      final manager = CommandManager(registry: registry);

      await expectLater(
        manager.execute(
          'sketch.partial',
          CommandContext(projectId: null, projectDirectory: null),
        ),
        throwsA(isA<StateError>()),
      );

      final restored = runtime.document!;
      expect(restored.revision, 1);
      expect(restored.entities['e1']!.data['name'], 'line');
      expect(restored.entities['e1']!.shape, same(shape));
      expect(
        () => shape.metadata['mutated'] = true,
        throwsA(isA<UnsupportedError>()),
      );
      expect(restored.parameters['units'], 'mm');
      expect(runtime.runtimeRevision, 0);
      expect(runtime.canUndo, isFalse);
      expect(manager.canUndo, isFalse);
    },
  );

  test('a failed redo with a checkpoint restores the pre-redo domain', () async {
    final domain = _Domain();
    final registry = CommandRegistry();
    registry.register(
      RegisteredEngineeringCommand(
        id: 'sketch.ok',
        module: 'Sketch',
        execute: (_, _) async {
          domain.geometry = 'line-b';
          domain.dirty = true;
          domain.revision = 4;
          return 'ok';
        },
        undo: (_, _) async {
          domain.geometry = 'line-a';
          domain.dirty = false;
          domain.revision = 3;
          return 'undone';
        },
        redo: (_, _) async {
          domain.corrupt();
          throw StateError('redo failed after mutation');
        },
        checkpoint: (_, _) async {
          final saved = domain.snapshot();
          return () async => domain.restore(saved);
        },
      ),
    );
    final manager = CommandManager(registry: registry);
    final directory = await Directory.systemTemp.createTemp('cmd-redo-');
    addTearDown(() => directory.delete(recursive: true));
    final context = CommandContext(projectId: 'p', projectDirectory: directory);
    await manager.execute('sketch.ok', context);
    await manager.undo();
    final beforeRedo = domain.snapshot();

    await expectLater(
      manager.redo(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'redo failed after mutation',
        ),
      ),
    );

    expect(domain.snapshot(), beforeRedo);
    expect(manager.canUndo, isFalse);
    expect(manager.canRedo, isTrue);
    expect(manager.lastUncheckpointedFailure, isNull);
  });

  test(
    'a failed redo without a checkpoint stays visible and uncommitted',
    () async {
      final domain = _Domain();
      final registry = CommandRegistry();
      registry.register(
        RegisteredEngineeringCommand(
          id: 'sketch.ok',
          module: 'Sketch',
          execute: (_, _) async {
            domain.geometry = 'line-b';
            return 'ok';
          },
          undo: (_, _) async {
            domain.geometry = 'line-a';
            return 'undone';
          },
          redo: (_, _) async {
            domain.corrupt();
            throw StateError('redo failed after mutation');
          },
        ),
      );
      final manager = CommandManager(registry: registry);
      final directory = await Directory.systemTemp.createTemp('cmd-redo-open-');
      addTearDown(() => directory.delete(recursive: true));
      final context = CommandContext(projectId: 'p', projectDirectory: directory);
      await manager.execute('sketch.ok', context);
      await manager.undo();

      await expectLater(manager.redo(), throwsA(isA<StateError>()));

      expect(domain.geometry, 'moved');
      expect(domain.dirty, isTrue);
      expect(manager.canRedo, isTrue);
      expect(manager.canUndo, isFalse);
      expect(
        manager.lastUncheckpointedFailure,
        isA<CommandUncheckpointedFailure>().having(
          (failure) => failure.operation,
          'operation',
          'redo',
        ),
      );
    },
  );

  test('a validator rejection does not record an uncheckpointed failure', () async {
    final domain = _Domain();
    final before = domain.snapshot();
    final registry = CommandRegistry();
    registry.register(
      RegisteredEngineeringCommand(
        id: 'sketch.rejected',
        module: 'Sketch',
        validator: CommandValidation.projectRequired,
        execute: (_, _) async {
          domain.corrupt();
          return 'should not run';
        },
        undo: (_, _) async => 'unused',
        redo: (_, _) async => 'unused',
      ),
    );
    final manager = CommandManager(registry: registry);

    await expectLater(
      manager.execute(
        'sketch.rejected',
        CommandContext(projectId: null, projectDirectory: null),
      ),
      throwsA(isA<StateError>()),
    );

    expect(domain.snapshot(), before);
    expect(manager.lastUncheckpointedFailure, isNull);
    expect(manager.canUndo, isFalse);
  });

  test('a later success does not clear an uncheckpointed failure', () async {
    final domain = _Domain();
    final registry = CommandRegistry();
    registry.register(
      RegisteredEngineeringCommand(
        id: 'sketch.leak',
        module: 'Sketch',
        execute: (_, _) async {
          domain.corrupt();
          throw StateError('persistence failed after mutation');
        },
        undo: (_, _) async => 'unused',
        redo: (_, _) async => 'unused',
      ),
    );
    registry.register(
      RegisteredEngineeringCommand(
        id: 'sketch.ok',
        module: 'Sketch',
        execute: (_, _) async {
          domain.geometry = 'line-b';
          return 'ok';
        },
        undo: (_, _) async => 'undone',
        redo: (_, _) async => 'redone',
      ),
    );
    final manager = CommandManager(registry: registry);
    final context = CommandContext(projectId: null, projectDirectory: null);
    await expectLater(
      manager.execute('sketch.leak', context),
      throwsA(isA<StateError>()),
    );
    final recorded = manager.lastUncheckpointedFailure;

    await manager.execute('sketch.ok', context);

    expect(manager.lastUncheckpointedFailure, same(recorded));
    expect(domain.geometry, 'line-b');
    expect(manager.canUndo, isTrue);
  });
}
