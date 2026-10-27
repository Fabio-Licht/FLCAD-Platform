import 'dart:async';
import 'dart:io';

import 'package:flcad_mobile/app/commands/commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'operation gate delays commands and history until recovery completes',
    () async {
      final gate = Completer<void>();
      final registry = CommandRegistry();
      var executed = false;
      registry.register(
        RegisteredEngineeringCommand(
          id: 'engineering.gated',
          module: 'Engineering',
          execute: (_, _) async => executed = true,
          undo: (_, _) async => null,
          redo: (_, _) async => null,
        ),
      );
      final manager = CommandManager(
        registry: registry,
        operationGate: () => gate.future,
      );

      final pending = manager.execute(
        'engineering.gated',
        CommandContext(projectId: null, projectDirectory: null),
      );
      await Future<void>.delayed(Duration.zero);
      expect(executed, isFalse);
      expect(manager.history, isEmpty);
      expect(manager.hasPendingOperations, isFalse);

      gate.complete();
      await pending;
      expect(executed, isTrue);
      expect(manager.history, hasLength(1));
    },
  );

  test('operation gate also delays undo and redo publication', () async {
    var gate = Completer<void>()..complete();
    final registry = CommandRegistry();
    var value = 0;
    registry.register(
      RegisteredEngineeringCommand(
        id: 'engineering.gated.history',
        module: 'Engineering',
        execute: (_, _) async => value = 1,
        undo: (_, _) async => value = 0,
        redo: (_, _) async => value = 1,
      ),
    );
    final manager = CommandManager(
      registry: registry,
      operationGate: () => gate.future,
    );
    final context = CommandContext(projectId: null, projectDirectory: null);
    await manager.execute('engineering.gated.history', context);

    gate = Completer<void>();
    final undo = manager.undo();
    await Future<void>.delayed(Duration.zero);
    expect(value, 1);
    expect(manager.undoDepth, 1);
    gate.complete();
    await undo;
    expect(value, 0);
    expect(manager.redoDepth, 1);

    gate = Completer<void>();
    final redo = manager.redo();
    await Future<void>.delayed(Duration.zero);
    expect(value, 0);
    expect(manager.redoDepth, 1);
    gate.complete();
    await redo;
    expect(value, 1);
    expect(manager.undoDepth, 1);
  });

  test('non-undoable save preserves redo and does not enter undo', () async {
    final registry = CommandRegistry();
    var value = 0;
    var saves = 0;
    registry.register(
      RegisteredEngineeringCommand(
        id: 'engineering.value',
        module: 'Engineering',
        execute: (_, _) async => value = 1,
        undo: (_, _) async => value = 0,
        redo: (_, _) async => value = 1,
      ),
    );
    registry.register(
      RegisteredEngineeringCommand(
        id: 'engineering.save',
        module: 'Engineering',
        undoable: false,
        execute: (_, _) async => saves++,
        undo: (_, _) async => null,
        redo: (_, _) async => null,
      ),
    );
    final manager = CommandManager(registry: registry);
    final context = CommandContext(projectId: null, projectDirectory: null);

    await manager.execute('engineering.value', context);
    await manager.undo();
    expect(manager.undoDepth, 0);
    expect(manager.redoDepth, 1);

    await manager.execute('engineering.save', context);
    expect(saves, 1);
    expect(value, 0);
    expect(manager.undoDepth, 0);
    expect(manager.redoDepth, 1);

    await manager.redo();
    expect(value, 1);
    expect(manager.history.map((entry) => entry.commandId), [
      'engineering.value',
      'engineering.value',
      'engineering.save',
      'engineering.value',
    ]);
  });

  test(
    'validation manager execution undo redo and histories are integrated',
    () async {
      final root = await Directory.systemTemp.createTemp('flcad_commands_');
      addTearDown(() => root.delete(recursive: true));
      final registry = CommandRegistry();
      var value = 0;
      registry.register(
        RegisteredEngineeringCommand(
          id: 'engineering.increment',
          module: 'Engineering',
          validator: CommandValidation.projectRequired,
          execute: (_, parameters) async =>
              value += parameters['value']! as int,
          undo: (_, parameters) async => value -= parameters['value']! as int,
          redo: (_, parameters) async => value += parameters['value']! as int,
        ),
      );
      final manager = CommandManager(
        registry: registry,
        clock: () => DateTime.utc(2026, 8, 15),
        durationProvider: () => 17,
      );
      final dispatcher = CommandDispatcher(
        manager: manager,
        context: CommandContext(projectId: 'project-1', projectDirectory: root),
      );

      await dispatcher.dispatch('engineering.increment', {'value': 3});
      expect(value, 3);
      expect(manager.canUndo, isTrue);
      await dispatcher.undo();
      expect(value, 0);
      await dispatcher.redo();
      expect(value, 3);
      expect(manager.history.map((e) => e.operation), [
        'execute',
        'undo',
        'redo',
      ]);
      expect(manager.history.every((e) => e.durationMicros == 17), isTrue);
      for (final folder in ['CommandHistory', 'UndoHistory', 'RedoHistory']) {
        final file = File('${root.path}/CAD/$folder/history.jsonl');
        expect(await file.exists(), isTrue);
        expect(await file.readAsString(), contains('engineering.increment'));
      }
    },
  );

  test('invalid command never reaches execution or undo stack', () async {
    final registry = CommandRegistry();
    var executed = false;
    registry.register(
      RegisteredEngineeringCommand(
        id: 'requires.project',
        module: 'Project',
        validator: CommandValidation.projectRequired,
        execute: (_, _) async => executed = true,
        undo: (_, _) async => null,
        redo: (_, _) async => null,
      ),
    );
    final manager = CommandManager(registry: registry);
    final dispatcher = CommandDispatcher(
      manager: manager,
      context: CommandContext(projectId: null, projectDirectory: null),
    );
    await expectLater(
      dispatcher.dispatch('requires.project'),
      throwsA(isA<StateError>()),
    );
    expect(executed, isFalse);
    expect(manager.canUndo, isFalse);
    expect(manager.history, isEmpty);
  });

  test('trace correlation preserves command output parameters', () async {
    final registry = CommandRegistry();
    registry.register(
      RegisteredEngineeringCommand(
        id: 'engineering.output',
        module: 'Engineering',
        execute: (_, parameters) async {
          parameters['createdId'] = 'created-by-command';
          return null;
        },
        undo: (_, _) async => null,
        redo: (_, _) async => null,
      ),
    );
    final manager = CommandManager(registry: registry);
    final parameters = <String, Object?>{
      CommandManager.traceOperationIdKey: 'operation-42',
    };

    await manager.execute(
      'engineering.output',
      CommandContext(projectId: null, projectDirectory: null),
      parameters,
    );

    expect(parameters['createdId'], 'created-by-command');
    expect(parameters.containsKey(CommandManager.traceOperationIdKey), isFalse);
    expect(
      manager.trace.any((event) => event.operationId == 'operation-42'),
      isTrue,
    );
  });

  test(
    'execute recording failure rolls back domain and stacks without duplicates',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'flcad_commands_failure_',
      );
      addTearDown(() => root.delete(recursive: true));
      final blockedProject = File('${root.path}/project')
        ..writeAsStringSync('occupied');
      final registry = CommandRegistry();
      var value = 0;
      registry.register(
        RegisteredEngineeringCommand(
          id: 'engineering.increment',
          module: 'Engineering',
          execute: (_, parameters) async =>
              value += parameters['value']! as int,
          undo: (_, parameters) async => value -= parameters['value']! as int,
          redo: (_, parameters) async => value += parameters['value']! as int,
        ),
      );
      final manager = CommandManager(registry: registry);
      final dispatcher = CommandDispatcher(
        manager: manager,
        context: CommandContext(
          projectId: 'project-1',
          projectDirectory: Directory(blockedProject.path),
        ),
      );

      await expectLater(
        dispatcher.dispatch('engineering.increment', {'value': 3}),
        throwsA(isA<CommandPersistenceFailure>()),
      );
      expect(value, 0);
      expect(manager.history, isEmpty);
      expect(manager.persistenceHealthy, isFalse);
      expect(manager.canUndo, isFalse);
      expect(manager.canRedo, isFalse);
      expect(manager.undoDepth, 0);
      expect(manager.redoDepth, 0);
      expect(
        manager.trace.map((event) => event.stage),
        containsAllInOrder([
          'journal.failed',
          'domain.rollback.begin',
          'domain.rollback.end',
        ]),
      );

      blockedProject.deleteSync();
      await root.create();
      await dispatcher.dispatch('engineering.increment', {'value': 3});
      expect(value, 3);
      expect(manager.undoDepth, 1);
      expect(
        manager.history
            .where(
              (entry) =>
                  entry.commandId == 'engineering.increment' &&
                  entry.operation == 'execute',
            )
            .length,
        1,
      );
      expect(manager.persistenceHealthy, isTrue);
    },
  );

  test('undo recording failure restores model and undo/redo stacks', () async {
    final root = await Directory.systemTemp.createTemp('flcad_undo_failure_');
    addTearDown(() => root.delete(recursive: true));
    final registry = CommandRegistry();
    var value = 0;
    registry.register(
      RegisteredEngineeringCommand(
        id: 'engineering.increment',
        module: 'Engineering',
        execute: (_, parameters) async => value += parameters['value']! as int,
        undo: (_, parameters) async => value -= parameters['value']! as int,
        redo: (_, parameters) async => value += parameters['value']! as int,
      ),
    );
    final manager = CommandManager(registry: registry);
    final dispatcher = CommandDispatcher(
      manager: manager,
      context: CommandContext(projectId: 'project-1', projectDirectory: root),
    );
    await dispatcher.dispatch('engineering.increment', {'value': 3});
    final blocker = File('${root.path}/CAD/UndoHistory')
      ..writeAsStringSync('blocks journal directory');

    await expectLater(
      manager.undo('undo-record-failure'),
      throwsA(isA<CommandPersistenceFailure>()),
    );
    expect(value, 3);
    expect(manager.undoDepth, 1);
    expect(manager.redoDepth, 0);
    expect(manager.history.map((entry) => entry.operation), ['execute']);
    expect(
      manager.trace
          .where((event) => event.operationId == 'undo-record-failure')
          .map((event) => event.stage),
      containsAllInOrder(['journal.failed', 'domain.rollback.end']),
    );

    blocker.deleteSync();
    await manager.undo('undo-retry');
    expect(value, 0);
    expect(manager.undoDepth, 0);
    expect(manager.redoDepth, 1);
    expect(manager.history.map((entry) => entry.operation), [
      'execute',
      'undo',
    ]);
    await manager.redo('redo-retry');
    expect(value, 3);
    expect(manager.history.map((entry) => entry.operation), [
      'execute',
      'undo',
      'redo',
    ]);
  });

  test(
    'partial journal append is truncated with domain and stacks restored',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'flcad-commands-partial_',
      );
      addTearDown(() => root.delete(recursive: true));
      final registry = CommandRegistry();
      var value = 0;
      registry.register(
        RegisteredEngineeringCommand(
          id: 'engineering.increment',
          module: 'Engineering',
          execute: (_, parameters) async =>
              value += parameters['value']! as int,
          undo: (_, parameters) async => value -= parameters['value']! as int,
          redo: (_, parameters) async => value += parameters['value']! as int,
        ),
      );
      final manager = CommandManager(
        registry: registry,
        journalWriter: (file, line) {
          file.writeAsStringSync(
            line.substring(0, line.length ~/ 2),
            mode: FileMode.append,
            flush: true,
          );
          throw StateError('injected partial append');
        },
      );

      await expectLater(
        manager.execute(
          'engineering.increment',
          CommandContext(projectId: 'project-1', projectDirectory: root),
          {'value': 3},
        ),
        throwsA(isA<CommandPersistenceFailure>()),
      );

      expect(value, 0);
      expect(manager.undoDepth, 0);
      expect(manager.redoDepth, 0);
      expect(manager.history, isEmpty);
      final journal = File('${root.path}/CAD/CommandHistory/history.jsonl');
      expect(journal.existsSync() ? journal.readAsStringSync() : '', isEmpty);
    },
  );

  test('redo recording failure restores model and undo/redo stacks', () async {
    final root = await Directory.systemTemp.createTemp('flcad_redo_failure_');
    addTearDown(() => root.delete(recursive: true));
    final registry = CommandRegistry();
    var value = 0;
    registry.register(
      RegisteredEngineeringCommand(
        id: 'engineering.increment',
        module: 'Engineering',
        execute: (_, parameters) async => value += parameters['value']! as int,
        undo: (_, parameters) async => value -= parameters['value']! as int,
        redo: (_, parameters) async => value += parameters['value']! as int,
      ),
    );
    final manager = CommandManager(registry: registry);
    final dispatcher = CommandDispatcher(
      manager: manager,
      context: CommandContext(projectId: 'project-1', projectDirectory: root),
    );
    await dispatcher.dispatch('engineering.increment', {'value': 3});
    await manager.undo('undo-before-redo-failure');
    final blocker = File('${root.path}/CAD/RedoHistory')
      ..writeAsStringSync('blocks journal directory');

    await expectLater(
      manager.redo('redo-record-failure'),
      throwsA(isA<CommandPersistenceFailure>()),
    );
    expect(value, 0);
    expect(manager.undoDepth, 0);
    expect(manager.redoDepth, 1);
    expect(manager.history.map((entry) => entry.operation), [
      'execute',
      'undo',
    ]);
    expect(
      manager.trace
          .where((event) => event.operationId == 'redo-record-failure')
          .map((event) => event.stage),
      containsAllInOrder(['journal.failed', 'domain.rollback.end']),
    );

    blocker.deleteSync();
    await manager.redo('redo-retry');
    expect(value, 3);
    expect(manager.undoDepth, 1);
    expect(manager.redoDepth, 0);
    expect(manager.history.map((entry) => entry.operation), [
      'execute',
      'undo',
      'redo',
    ]);
  });

  test('workspace and selection adapters synchronize command state', () {
    final adapter = WorkspaceCommandAdapter();
    adapter.open('Smart References');
    adapter.select({'plane-A', 'axis-1'});
    expect(adapter.state.workspace, 'Smart References');
    expect(adapter.state.selection, {'plane-A', 'axis-1'});
    expect(adapter.state.status, '2 object(s) selected');
  });

  test('registry rejects duplicates and unknown commands', () {
    final registry = CommandRegistry();
    final command = RegisteredEngineeringCommand(
      id: 'one',
      module: 'Test',
      execute: (_, _) async => null,
      undo: (_, _) async => null,
      redo: (_, _) async => null,
    );
    registry.register(command);
    expect(() => registry.register(command), throwsStateError);
    expect(() => registry.resolve('missing'), throwsStateError);
  });
}
