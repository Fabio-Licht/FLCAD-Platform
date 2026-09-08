import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/cad_document_repository.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';

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
    final first = add('one');
    await gate.entered.future;
    final second = add('two');
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

  test(
    'shutdown awaited from a producer is rejected without deadlock',
    () async {
      repository.onSave = (_) => runtime.shutdown();
      await expectLater(add('one'), throwsStateError);
      repository.onSave = null;
      await add('two');
      expect(runtime.document!.entities.containsKey('two'), isTrue);
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
    'concurrent repository writes use distinct exclusive temporary paths',
    () async {
      final seen = <String>{};
      final created = Completer<void>();
      final subscription = a.watch(events: FileSystemEvent.create).listen((
        event,
      ) {
        if (event.path.contains('.txn-')) {
          seen.add(event.path);
          if (seen.length >= 2 && !created.isCompleted) created.complete();
        }
      });
      try {
        // Direct repository writes intentionally bypass the runtime queue here.
        // Destination concurrency is not promised; temporary isolation is.
        Future<void> write() async {
          try {
            await repository.save(runtime.document!, a);
          } on FileSystemException {
            /* destination race is outside this contract */
          }
        }

        await Future.wait([write(), write()]);
        await created.future;
        expect(seen.length, greaterThanOrEqualTo(2));
      } finally {
        await subscription.cancel();
      }
    },
  );
}
