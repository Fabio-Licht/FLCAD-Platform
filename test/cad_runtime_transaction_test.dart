import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/cad_document_repository.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';

class Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }
}

class Repository extends CadDocumentRepository {
  Future<void> Function(CadDocument)? onSave;
  Future<void> Function(String)? onLoad;
  Future<void> Function()? onHistory;
  bool failRecovery = false;
  Future<void> Function(File, Directory)? onTemporary;
  @override
  Future<Directory> createTemporaryDirectory(File target) async {
    final temporary = await super.createTemporaryDirectory(target);
    try {
      if (onTemporary != null) await onTemporary!(target, temporary);
      return temporary;
    } catch (_) {
      await temporary.delete(recursive: true);
      rethrow;
    }
  }

  final saved = <CadDocument>[];
  final histories = <CadDocumentHistoryState>[];
  @override
  Future<CadDocument> load(String id, Directory dir) async {
    if (onLoad != null) await onLoad!(id);
    return super.load(id, dir);
  }

  @override
  Future<void> save(CadDocument doc, Directory dir) async {
    saved.add(doc);
    if (onSave != null) await onSave!(doc);
    await super.save(doc, dir);
  }

  @override
  Future<void> saveHistory(
    Directory dir, {
    required Iterable<CadDocument> undo,
    required Iterable<CadDocument> redo,
  }) async {
    histories.add(
      CadDocumentHistoryState(undo: undo.toList(), redo: redo.toList()),
    );
    if (onHistory != null) await onHistory!();
    await super.saveHistory(dir, undo: undo, redo: redo);
  }

  @override
  Future<void> restoreFiles(
    Directory dir,
    Map<String, List<int>?> backup,
  ) async {
    if (failRecovery) throw FileSystemException('recovery failed');
    await super.restoreFiles(dir, backup);
  }
}

CadDocumentEntity point(String id) => CadDocumentEntity(
  id: id,
  kind: CadDocumentEntityKind.vertex,
  data: {
    'sceneKind': 'point',
    'sceneGeometry': {
      'position': [0, 0, 0],
    },
  },
);

void main() {
  late Repository repository;
  late CadRuntime runtime;
  late Directory root, a, b;
  Future<void> add(String id) =>
      runtime.mutate(command: id, upsert: [point(id)]);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cad-transaction-test-');
    a = await Directory('${root.path}/A').create();
    b = await Directory('${root.path}/B').create();
    repository = Repository();
    runtime = CadRuntime(kernels: KernelManager(), repository: repository);
    await runtime.open('A', a);
    repository.saved.clear();
    repository.histories.clear();
  });
  tearDown(() async {
    await runtime.shutdown();
    await root.delete(recursive: true);
  });

  test('mutate FIFO publishes only prepared documents', () async {
    final gate = Gate();
    repository.onSave = (doc) =>
        doc.entities.containsKey('one') && !doc.entities.containsKey('two')
        ? gate.wait()
        : Future.value();
    final documentBefore = runtime.document;
    final sceneBefore = runtime.scene.entities.toList();
    final filesBefore = await repository.captureFiles(a);
    var notifications = 0;
    runtime.addListener(() => notifications++);
    runtime.scene.addListener(() => notifications++);
    runtime.geometrySelection.addListener(() => notifications++);
    final first = add('one');
    await gate.entered.future;
    final second = add('two');
    expect(runtime.document, same(documentBefore));
    expect(runtime.scene.entities.toList(), sceneBefore);
    expect(runtime.selection, isEmpty);
    expect(repository.histories, isEmpty);
    expect(notifications, 0);
    expect(await repository.captureFiles(a), filesBefore);
    expect(runtime.document!.entities.containsKey('one'), isFalse);
    expect(runtime.canUndo, isFalse);
    gate.release.complete();
    await Future.wait([first, second]);
    expect(repository.saved.map((d) => d.revisions.last.command), [
      'one',
      'two',
    ]);
    expect(runtime.document!.entities.keys, containsAll(['one', 'two']));
    expect(repository.histories.last.undo, hasLength(2));
  });

  test('undo during mutate waits and preserves monotonic revision', () async {
    final revision = runtime.runtimeRevision;
    final gate = Gate();
    repository.onSave = (_) => gate.wait();
    final mutation = add('one');
    await gate.entered.future;
    final undo = runtime.undoDocument();
    gate.release.complete();
    await Future.wait([mutation, undo]);
    expect(runtime.document!.entities.containsKey('one'), isFalse);
    expect(runtime.canRedo, isTrue);
    expect(runtime.runtimeRevision, revision + 2);
  });

  test('redo during mutate sees the confirmed cleared redo stack', () async {
    await add('one');
    await runtime.undoDocument();
    final gate = Gate();
    repository.onSave = (_) => gate.wait();
    final mutation = add('two');
    await gate.entered.future;
    final redo = runtime.redoDocument();
    gate.release.complete();
    await Future.wait([mutation, redo]);
    expect(runtime.document!.entities.containsKey('one'), isFalse);
    expect(runtime.document!.entities.containsKey('two'), isTrue);
    expect(runtime.canRedo, isFalse);
  });

  test(
    'history failure restores disk without moving document or stacks',
    () async {
      await add('one');
      await runtime.undoDocument();
      final before = runtime.document;
      final revision = runtime.runtimeRevision;
      final disk = await repository.captureFiles(a);
      repository.onHistory = () async => throw StateError('history failed');
      await expectLater(add('two'), throwsStateError);
      expect(runtime.document, same(before));
      expect(runtime.canUndo, isFalse);
      expect(runtime.canRedo, isTrue);
      expect(runtime.runtimeRevision, revision);
      expect(await repository.captureFiles(a), disk);
      expect(runtime.recoveryRequired, isFalse);
    },
  );

  test('obsolete open finishing after close request cannot activate', () async {
    final gate = Gate();
    repository.onLoad = (_) => gate.wait();
    final opening = runtime.open('B', b);
    final rejected = expectLater(opening, throwsA(isA<StaleCadTransaction>()));
    await gate.entered.future;
    final closing = runtime.close();
    gate.release.complete();
    await rejected;
    await closing;
    expect(runtime.document, isNull);
    expect(runtime.sessionActive, isFalse);
  });

  test(
    'two opens: later ready result wins, older load never publishes',
    () async {
      final old = Gate(), latest = Gate();
      final entered = <String>[];
      latest.release
          .complete(); // Later request data is ready before the old one.
      repository.onLoad = (id) {
        entered.add(id);
        return id == 'B' ? old.wait() : latest.wait();
      };
      final first = runtime.open('B', b);
      final rejected = expectLater(first, throwsA(isA<StaleCadTransaction>()));
      await old.entered.future;
      final second = runtime.open('A', a);
      expect(entered, [
        'B',
      ]); // FIFO never runs both loads in its critical section.
      old.release.complete();
      await rejected;
      await second;
      expect(entered, ['B', 'A']);
      expect(runtime.document!.projectId, 'A');
      expect(runtime.sessionActive, isTrue);
    },
  );

  test(
    'close failure retains exact document, renews session; retry succeeds',
    () async {
      final before = runtime.document;
      final session = runtime.sessionIdentity;
      repository.onSave = (_) async => throw StateError('save failed');
      await expectLater(runtime.close(), throwsStateError);
      expect(runtime.document, same(before));
      expect(runtime.sessionActive, isTrue);
      expect(runtime.sessionIdentity, greaterThan(session));
      repository.onSave = null;
      await add('after-failure');
      await runtime.close();
      expect(runtime.document, isNull);
      expect(runtime.sessionActive, isFalse);
    },
  );

  test(
    'two close failures create distinct sessions without changing document',
    () async {
      final before = runtime.document;
      repository.onSave = (_) async => throw StateError('save failed');
      await expectLater(runtime.close(), throwsStateError);
      final session = runtime.sessionIdentity;
      await expectLater(runtime.close(), throwsStateError);
      expect(runtime.sessionIdentity, greaterThan(session));
      expect(runtime.document, same(before));
      repository.onSave = null;
      await runtime.close();
    },
  );

  test(
    'dispose during admitted work waits, rejects admissions and is idempotent',
    () async {
      final gate = Gate();
      repository.onSave = (_) => gate.wait();
      final before = runtime.document;
      final mutation = add('one');
      final rejected = expectLater(
        mutation,
        throwsA(isA<StaleCadTransaction>()),
      );
      await gate.entered.future;
      runtime.dispose();
      final shutdown = runtime.shutdown();
      runtime.dispose();
      expect(runtime.shutdown(), same(shutdown));
      await expectLater(add('two'), throwsA(isA<CadRuntimeShuttingDown>()));
      var finished = false;
      unawaited(shutdown.then((_) => finished = true));
      expect(finished, isFalse);
      gate.release.complete();
      await rejected;
      await shutdown;
      expect(runtime.document, same(before));
      expect(runtime.sessionActive, isFalse);
    },
  );

  test('open after dispose request never reactivates', () async {
    final gate = Gate();
    repository.onLoad = (_) => gate.wait();
    final opening = runtime.open('B', b);
    final rejected = expectLater(opening, throwsA(isA<StaleCadTransaction>()));
    await gate.entered.future;
    runtime.dispose();
    gate.release.complete();
    await rejected;
    await runtime.shutdown();
    expect(runtime.sessionActive, isFalse);
    expect(runtime.document!.projectId, 'A');
  });

  test('listener reentrant mutate queues without deadlock', () async {
    final second = Completer<void>();
    var invoked = false;
    runtime.addListener(() {
      if (invoked) return;
      invoked = true;
      add('two').then(second.complete, onError: second.completeError);
    });
    await add('one');
    await second.future;
    expect(runtime.document!.entities.keys, containsAll(['one', 'two']));
  });

  test(
    'internal public reacquisition is rejected instead of deadlocking',
    () async {
      repository.onSave = (_) => runtime.save();
      await expectLater(add('one'), throwsStateError);
      expect(runtime.document!.entities.containsKey('one'), isFalse);
    },
  );

  for (final externalFirst in [false, true]) {
    test(
      'active transaction cannot await public drainage (external=$externalFirst)',
      () async {
        final gate = Gate();
        final events = <String>[];
        repository.onSave = (_) async {
          await gate.wait();
          await expectLater(runtime.shutdown(), throwsStateError);
          events.add('producer-returned');
          // Dependency remains usable until this transaction leaves the queue.
          runtime.scene.addListener(() {});
        };
        final mutation = add('one');
        final result = expectLater(
          mutation,
          throwsA(isA<StaleCadTransaction>()),
        );
        await gate.entered.future;
        Future<void>? external;
        if (externalFirst) external = runtime.shutdown();
        gate.release.complete();
        await result;
        events.add('transaction-returned');
        external ??= runtime.shutdown();
        await external;
        events.add('drained');
        expect(runtime.shutdown(), same(external));
        runtime.dispose();
        await runtime.shutdown();
        expect(events, [
          'producer-returned',
          'transaction-returned',
          'drained',
        ]);
        await expectLater(add('two'), throwsA(isA<CadRuntimeShuttingDown>()));
        expect(() => runtime.scene.addListener(() {}), throwsFlutterError);
      },
    );
  }

  test(
    'escaped revoked context awaits another transaction before shutdown completes',
    () async {
      final resumeOld = Completer<void>();
      final requested = Completer<void>();
      late Future<void> oldCallback;
      repository.onSave = (_) async {
        oldCallback = resumeOld.future.then((_) {
          final drainage = runtime.shutdown();
          requested.complete();
          return drainage;
        });
      };
      await add('one');
      final secondGate = Gate();
      repository.onSave = (_) => secondGate.wait();
      final second = add('two');
      final cancelled = expectLater(
        second,
        throwsA(isA<StaleCadTransaction>()),
      );
      await secondGate.entered.future;
      var drained = false;
      final callbackCompleted = oldCallback.then((_) => drained = true);
      resumeOld.complete();
      await requested.future;
      expect(drained, isFalse);
      runtime.scene.addListener(
        () {},
      ); // Still owned until producer has returned.
      await expectLater(add('three'), throwsA(isA<CadRuntimeShuttingDown>()));
      final external = runtime.shutdown();
      expect(runtime.shutdown(), same(external));
      secondGate.release.complete();
      await cancelled;
      await callbackCompleted;
      await external;
      runtime.dispose();
      await runtime.shutdown();
      expect(() => runtime.scene.addListener(() {}), throwsFlutterError);
    },
  );

  test(
    'revoked context can enqueue ordinary work without false reentry',
    () async {
      late Zone oldZone;
      repository.onSave = (_) async => oldZone = Zone.current;
      await add('one');
      repository.onSave = null;
      await oldZone.run(() => add('two'));
      expect(runtime.document!.entities.containsKey('two'), isTrue);
    },
  );

  test(
    'capability belonging to another runtime never acknowledges its drainage',
    () async {
      final otherRepository = Repository();
      final other = CadRuntime(
        kernels: KernelManager(),
        repository: otherRepository,
      );
      await other.open('B', b);
      final gate = Gate();
      otherRepository.onSave = (_) => gate.wait();
      final otherWrite = other.mutate(
        command: 'other',
        upsert: [point('other')],
      );
      final cancelled = expectLater(
        otherWrite,
        throwsA(isA<StaleCadTransaction>()),
      );
      await gate.entered.future;
      final request = Completer<void>();
      var drained = false;
      repository.onSave = (_) async {
        final future = other.shutdown();
        request.complete();
        await future;
        drained = true;
      };
      final ownWrite = add('one');
      await request.future;
      expect(drained, isFalse);
      gate.release.complete();
      await cancelled;
      await ownWrite;
      await other.shutdown();
      expect(drained, isTrue);
      expect(runtime.document!.entities.containsKey('one'), isTrue);
    },
  );

  for (final invalidKind in ['nan', 'infinity', 'cycle', 'object']) {
    test(
      'invalid $invalidKind rejects only through Future and does not enter queue',
      () async {
        final entity = point('invalid');
        final cycle = <Object?>[];
        cycle.add(cycle);
        entity.data['invalid'] = switch (invalidKind) {
          'nan' => double.nan,
          'infinity' => double.infinity,
          'cycle' => cycle,
          _ => Object(),
        };
        final before = runtime.document;
        final revision = runtime.runtimeRevision;
        final scenes = runtime.scene.entities.toList();
        final files = await repository.captureFiles(a);
        Object? error;
        StackTrace? stack;
        late Future<void> pending;
        expect(() {
          pending = runtime.mutate(command: 'invalid', upsert: [entity]);
        }, returnsNormally);
        await pending.catchError((Object e, StackTrace s) {
          error = e;
          stack = s;
        });
        expect(error, isA<JsonUnsupportedObjectError>());
        expect(stack.toString(), contains('captureEntity'));
        expect(stack.toString(), contains('json'));
        expect(runtime.document, same(before));
        expect(runtime.scene.entities.toList(), scenes);
        expect(runtime.runtimeRevision, revision);
        expect(runtime.canUndo, isFalse);
        expect(await repository.captureFiles(a), files);
        await add('valid');
        expect(runtime.document!.entities.containsKey('valid'), isTrue);
        final shutdown = runtime.shutdown();
        await expectLater(
          runtime.mutate(command: 'invalid', upsert: [entity]),
          throwsA(isA<CadRuntimeShuttingDown>()),
        );
        await shutdown;
      },
    );
  }

  test(
    'capture preserves original error and stack from a throwing public producer',
    () async {
      final error = StateError('original producer');
      final stack = StackTrace.current;
      Iterable<CadDocumentEntity> inputs() sync* {
        Error.throwWithStackTrace(error, stack);
      }

      Object? caught;
      StackTrace? caughtStack;
      await runtime.mutate(command: 'capture', upsert: inputs()).catchError((
        Object e,
        StackTrace s,
      ) {
        caught = e;
        caughtStack = s;
      });
      expect(caught, same(error));
      expect(caughtStack.toString(), stack.toString());
      await add('valid');
    },
  );

  test(
    'owned immutable history and large unchanged geometry are reused by identity',
    () async {
      final nodes = List<int>.generate(12000, (i) => i);
      final input = point('large');
      input.data['sceneGeometry']['nodes'] = nodes;
      await runtime.mutate(command: 'large', upsert: [input]);
      final first = runtime.document!;
      final originalNodes =
          first.entities['large']!.data['sceneGeometry']['nodes'];
      nodes[0] = -99;
      expect((originalNodes as List).first, 0);
      final oldSnapshots = <CadDocument>[first];
      for (var i = 0; i < 4; i++) {
        await add('small-$i');
        final history = repository.histories.last.undo;
        for (var index = 0; index < oldSnapshots.length; index++) {
          expect(history[index + 1], same(oldSnapshots[index]));
        }
        expect(
          runtime.document!.entities['large']!.data['sceneGeometry']['nodes'],
          same(originalNodes),
        );
        oldSnapshots.add(runtime.document!);
      }
      final beforeNoop = runtime.document;
      final historyBefore = repository.histories.last;
      final saves = repository.saved.length;
      await runtime.mutate(command: 'empty');
      expect(runtime.document, same(beforeNoop));
      expect(repository.saved.length, saves);
      expect(repository.histories.last, same(historyBefore));
      expect(() => originalNodes.add(1), throwsUnsupportedError);
      expect(
        () => first.entities['large']!.data['new'] = true,
        throwsUnsupportedError,
      );
      await runtime.undoDocument();
      await runtime.redoDocument();
      expect(
        runtime.document!.entities['large']!.data['sceneGeometry']['nodes'],
        same(originalNodes),
      );
      expect(
        (await repository.load('A', a)).toJson(),
        runtime.document!.toJson(),
      );
      // A consumer cannot reuse our authority: even a published entity re-entering
      // through mutate is captured afresh when the operation genuinely changes it.
      final changed = CadDocumentEntity.fromJson(
        first.entities['large']!.toJson(),
      );
      changed.data['label'] = 'changed';
      final revision = runtime.runtimeRevision;
      await runtime.mutate(command: 'real', upsert: [changed]);
      expect(runtime.runtimeRevision, revision + 1);
      expect(
        runtime.document!.entities['large']!.data['sceneGeometry']['nodes'],
        isNot(same(originalNodes)),
      );
    },
  );

  test('work admitted during open cannot retarget the new document', () async {
    final gate = Gate();
    repository.onLoad = (_) => gate.wait();
    final opening = runtime.open('B', b);
    await gate.entered.future;
    final queued = expectLater(
      add('from-A'),
      throwsA(isA<StaleCadTransaction>()),
    );
    gate.release.complete();
    await opening;
    await queued;
    expect(runtime.document!.projectId, 'B');
    expect(runtime.document!.entities.containsKey('from-A'), isFalse);
  });

  test(
    'close invalidates a write during persistence and saves confirmed state',
    () async {
      final gate = Gate();
      final before = runtime.document!.toJson();
      repository.onSave = (_) => gate.wait();
      final mutation = add('obsolete');
      final rejected = expectLater(
        mutation,
        throwsA(isA<StaleCadTransaction>()),
      );
      await gate.entered.future;
      final closing = runtime.close();
      gate.release.complete();
      await rejected;
      await closing;
      expect((await repository.load('A', a)).toJson(), before);
      expect((await repository.loadHistory(a)).undo, isEmpty);
    },
  );

  test('save takes document and history from the same snapshot', () async {
    await add('one');
    final gate = Gate();
    repository.saved.clear();
    repository.histories.clear();
    repository.onSave = (_) => gate.wait();
    final saving = runtime.save();
    await gate.entered.future;
    final mutation = add('two');
    gate.release.complete();
    await Future.wait([saving, mutation]);
    expect(repository.saved.first.entities.containsKey('two'), isFalse);
    expect(repository.histories.first.undo, hasLength(1));
    expect(repository.histories.last.undo, hasLength(2));
  });

  test(
    'recovery failure is observable and blocks queued and new writes',
    () async {
      final gate = Gate();
      repository.onSave = (_) async {
        await gate.wait();
        throw StateError('original');
      };
      repository.failRecovery = true;
      final mutation = add('one');
      final rejected = expectLater(
        mutation,
        throwsA(
          isA<CadRecoveryFailure>()
              .having((e) => e.original, 'original', isA<StateError>())
              .having(
                (e) => e.recovery,
                'recovery',
                isA<FileSystemException>(),
              ),
        ),
      );
      await gate.entered.future;
      final queued = expectLater(add('two'), throwsStateError);
      gate.release.complete();
      await rejected;
      await queued;
      expect(runtime.recoveryRequired, isTrue);
      await expectLater(runtime.save(), throwsStateError);
    },
  );

  test(
    'selection changed during preparation keeps matching visual flags',
    () async {
      await add('one');
      await add('two');
      runtime.select({'one'});
      final gate = Gate();
      repository.onSave = (_) => gate.wait();
      final mutation = add('three');
      await gate.entered.future;
      runtime.select({'two'});
      gate.release.complete();
      await mutation;
      expect(runtime.selection, {'two'});
      expect(runtime.scene.find('two')!.selected, isTrue);
      expect(runtime.scene.find('one')!.selected, isFalse);
    },
  );

  test(
    'two runtimes own distinct live temporaries and both saves succeed',
    () async {
      final second = CadRuntime(
        kernels: KernelManager(),
        repository: repository,
      );
      await second.open('A', a);
      final gates = [Gate(), Gate()];
      final temporaryPaths = <String>[];
      repository.onTemporary = (target, directory) async {
        if (!target.path.endsWith('cad-document.json')) return;
        final index = temporaryPaths.length;
        temporaryPaths.add(directory.path);
        await gates[index].wait();
      };
      try {
        final firstSave = runtime.save();
        await gates[0].entered.future;
        final secondSave = second.save();
        await gates[1].entered.future;
        expect(temporaryPaths.toSet(), hasLength(2));
        for (final temporary in temporaryPaths) {
          expect(await Directory(temporary).exists(), isTrue);
          expect(Directory(temporary).parent.absolute.path, a.absolute.path);
        }
        // Final-file multi-writer arbitration is explicitly outside this phase.
        gates[0].release.complete();
        await firstSave;
        gates[1].release.complete();
        await secondSave;
        for (final temporary in temporaryPaths) {
          expect(await Directory(temporary).exists(), isFalse);
        }
        expect(
          (await repository.load('A', a)).toJson(),
          runtime.document!.toJson(),
        );
      } finally {
        await second.shutdown();
      }
    },
  );

  test(
    'one deeply frozen candidate backs scene, disk, history and effective redo',
    () async {
      final initial = point('one');
      initial.data['sceneGeometry']['nodes'] =
          initial.data['sceneGeometry']['position'];
      await runtime.mutate(command: 'initial', upsert: [initial]);
      final oldDocument = runtime.document!;
      final input = point('one');
      input.data['sceneGeometry']['nodes'] =
          input.data['sceneGeometry']['position'];
      (input.data['sceneGeometry']['position'] as List)[0] = 5;
      input.data['custom'] = {
        'nested': [
          {'value': 7},
        ],
      };
      final gate = Gate();
      repository.onSave = (_) => gate.wait();
      final previousRevision = runtime.runtimeRevision;
      final pending = runtime.mutate(command: 'change', upsert: [input]);
      await gate.entered.future;
      (input.data['sceneGeometry']['position'] as List)[0] = 500;
      input.data['custom']['nested'][0]['value'] = 700;
      (initial.data['sceneGeometry']['position'] as List)[0] = 900;
      expect(runtime.document, same(oldDocument));
      expect(runtime.scene.find('one')!.geometry['position'], [0, 0, 0]);
      gate.release.complete();
      await pending;
      final committed = runtime.document!;
      expect(runtime.runtimeRevision, previousRevision + 1);
      expect(repository.saved.last, same(committed));
      expect(
        committed.entities['one']!.data['custom']['nested'][0]['value'],
        7,
      );
      expect(runtime.scene.find('one')!.geometry['position'], [5, 0, 0]);
      expect(runtime.workspaceBounds!.minX, 5);
      expect((await repository.load('A', a)).toJson(), committed.toJson());
      expect(
        repository
            .histories
            .last
            .undo
            .last
            .entities['one']!
            .data['sceneGeometry']['position'],
        [0, 0, 0],
      );
      (input.data['sceneGeometry']['position'] as List)[0] = 999;
      expect(committed.entities['one']!.data['sceneGeometry']['position'], [
        5,
        0,
        0,
      ]);
      expect(
        () =>
            (committed.entities['one']!.data['sceneGeometry']['position']
                    as List)[0] =
                1,
        throwsUnsupportedError,
      );
      final revision = runtime.runtimeRevision;
      await runtime.undoDocument();
      expect(runtime.scene.find('one')!.geometry['position'], [0, 0, 0]);
      await runtime.redoDocument();
      expect(runtime.runtimeRevision, revision + 2);
      expect(runtime.scene.find('one')!.geometry['position'], [5, 0, 0]);
      expect(
        runtime.document!.entities['one']!.data['custom']['nested'][0]['value'],
        7,
      );
      expect(
        (await repository.load('A', a)).toJson(),
        runtime.document!.toJson(),
      );
    },
  );

  test(
    'shape and mesh nested metadata detach without creating native resources',
    () async {
      final metadata = <String, dynamic>{
        'nested': {
          'values': [1, 2],
        },
      };
      final source = CadDocumentEntity(
        id: 'metadata',
        kind: CadDocumentEntityKind.vertex,
        data: point('metadata').data,
        shape: ShapeHandle.reference(
          persistentId: 'shape',
          kernelId: 'none',
          type: CADShapeType.solid,
          metadata: metadata,
        ),
        mesh: KernelMeshHandle(
          persistentId: 'mesh',
          kernelId: 'none',
          fingerprint: 'mesh',
          vertexCount: 0,
          triangleCount: 0,
          bounds: const KernelBounds(0, 0, 0, 0, 0, 0),
          hasNormals: false,
          metadata: metadata,
        ),
      );
      final gate = Gate();
      repository.onSave = (_) => gate.wait();
      final pending = runtime.mutate(command: 'metadata', upsert: [source]);
      await gate.entered.future;
      metadata['nested']['values'][0] = 999;
      gate.release.complete();
      await pending;
      final entity = runtime.document!.entities['metadata']!;
      expect(entity.shape!.metadata['nested']['values'], [1, 2]);
      expect(entity.mesh!.metadata['nested']['values'], [1, 2]);
      expect(
        () => (entity.mesh!.metadata['nested']['values'] as List).add(3),
        throwsUnsupportedError,
      );
      expect(
        (await repository.load('A', a)).toJson(),
        runtime.document!.toJson(),
      );
    },
  );

  for (final source in ['scene', 'selection', 'runtime']) {
    test(
      'dispose in $source listener stops delivery without undoing commit',
      () async {
        await add('one');
        runtime.select({'one'});
        var later = 0;
        final notifier = source == 'scene'
            ? runtime.scene
            : source == 'selection'
            ? runtime.geometrySelection
            : runtime;
        notifier.addListener(() => runtime.dispose());
        notifier.addListener(() => later++);
        await runtime.mutate(command: 'remove', remove: ['one']);
        expect(later, 0);
        expect(runtime.document!.entities.containsKey('one'), isFalse);
        expect(
          (await repository.load('A', a)).entities.containsKey('one'),
          isFalse,
        );
        final draining = runtime.shutdown();
        await draining;
        runtime.dispose();
        expect(runtime.shutdown(), same(draining));
        expect(() => runtime.scene.addListener(() {}), throwsFlutterError);
      },
    );
  }

  test(
    'post-commit listener error is reported without failing mutation',
    () async {
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      try {
        runtime.addListener(() => throw StateError('observer failed'));
        await add('one');
        expect(reported, hasLength(1));
        expect(runtime.document!.entities.containsKey('one'), isTrue);
        expect(
          (await repository.load('A', a)).entities.containsKey('one'),
          isTrue,
        );
      } finally {
        FlutterError.onError = previous;
      }
    },
  );

  for (final category in [
    'empty',
    'missing',
    'equivalent',
    'export',
    'normalized',
  ]) {
    test(
      'no-op $category preserves functional redo and all published state',
      () async {
        await add('one');
        if (category == 'export') {
          await runtime.mutate(
            command: 'export',
            upsert: [
              CadDocumentEntity(
                id: 'one',
                kind: CadDocumentEntityKind.vertex,
                data: point('one').data,
                shape: ShapeHandle.reference(
                  persistentId: 'one',
                  kernelId: 'fixture',
                  type: CADShapeType.solid,
                ),
              ),
            ],
            officialExportShapeId: 'one',
          );
        }
        await add('two');
        await runtime.undoDocument();
        final before = runtime.document;
        final sceneBefore = runtime.scene.entities.toList();
        final files = await repository.captureFiles(a);
        final revision = runtime.runtimeRevision;
        repository.saved.clear();
        var notifications = 0;
        runtime.addListener(() => notifications++);
        runtime.scene.addListener(() => notifications++);
        await runtime.mutate(
          command: 'no-op',
          remove: category == 'missing' ? ['missing'] : const [],
          upsert: category == 'equivalent'
              ? [
                  CadDocumentEntity.fromJson({
                    ...runtime.document!.entities['one']!.toJson(),
                    'data': Map.fromEntries(
                      runtime.document!.entities['one']!.data.entries
                          .toList()
                          .reversed,
                    ),
                  }),
                ]
              : const [],
          officialExportShapeId: category == 'export'
              ? runtime.document!.officialExportShapeId
              : null,
        );
        expect(runtime.document, same(before));
        expect(runtime.scene.entities.toList(), sceneBefore);
        expect(runtime.runtimeRevision, revision);
        expect(repository.saved, isEmpty);
        expect(notifications, 0);
        expect(await repository.captureFiles(a), files);
        expect(runtime.canRedo, isTrue);
        await runtime.redoDocument();
        expect(runtime.document!.entities.containsKey('two'), isTrue);
        expect(runtime.runtimeRevision, revision + 1);
      },
    );
  }

  test(
    'failure of first queued mutation does not prevent second from committing',
    () async {
      final gate = Gate();
      repository.onSave = (doc) async {
        if (doc.entities.containsKey('one')) {
          await gate.wait();
          throw StateError('first failed');
        }
      };
      final first = add('one');
      final rejected = expectLater(first, throwsStateError);
      await gate.entered.future;
      final second = add('two');
      gate.release.complete();
      await rejected;
      await second;
      expect(runtime.document!.entities.containsKey('one'), isFalse);
      expect(runtime.document!.entities.containsKey('two'), isTrue);
    },
  );

  test(
    'projection failure preserves document scene selection and redo',
    () async {
      await add('one');
      await add('two');
      await runtime.undoDocument();
      runtime.select({'one'});
      final before = runtime.document;
      final sceneBefore = runtime.scene.entities.toList();
      final revision = runtime.runtimeRevision;
      final files = await repository.captureFiles(a);
      var notifications = 0;
      runtime.scene.addListener(() => notifications++);
      runtime.addListener(() => notifications++);
      final invalid = point('invalid');
      invalid.data['sceneKind'] = 'not-a-scene-kind';
      await expectLater(
        runtime.mutate(command: 'invalid', upsert: [invalid]),
        throwsArgumentError,
      );
      expect(runtime.document, same(before));
      expect(runtime.scene.entities.toList(), sceneBefore);
      expect(runtime.selection, {'one'});
      expect(runtime.runtimeRevision, revision);
      expect(runtime.canRedo, isTrue);
      expect(notifications, 0);
      expect(await repository.captureFiles(a), files);
    },
  );
}
