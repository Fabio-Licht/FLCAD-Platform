import 'package:flcad_mobile/app/runtime/cad_asset_fs_native.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_bridge.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';

class _Gate {
  final entered = Completer<void>(), release = Completer<void>();
  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return release.future;
  }
}

class _Storage extends CadAssetStorage {
  Future<void> Function(String)? onPhase;
  String? fixedId;
  void Function()? expireLock;
  bool controlledDeadline = false;
  @override
  String newAssetId() => fixedId ?? super.newAssetId();
  @override
  Timer lockTimer(Duration duration, void Function() expired) {
    if (!controlledDeadline) return super.lockTimer(duration, expired);
    expireLock = expired;
    return Timer(const Duration(days: 1), expired);
  }

  int maxChunk = 0, chunks = 0;
  @override
  Future<void> checkpoint(String phase) async {
    await onPhase?.call(phase);
  }

  @override
  Stream<List<int>> read(File file) async* {
    await for (final chunk in super.read(file)) {
      chunks++;
      if (chunk.length > maxChunk) maxChunk = chunk.length;
      yield chunk;
    }
  }
}

class _NativeLedger implements OpenCascadeNativeBridge {
  int destroys = 0, shutdowns = 0;
  bool failDestroy = false;
  final destroyError = StateError('SECRET-native-token failed');
  @override
  Future<void> initialize() async {}
  @override
  Future<String> version() async => 'simulated';
  @override
  Future<Set<String>> capabilities() async => {};
  @override
  Future<OpenCascadeNativeShape> createShape(
    String op,
    Map<String, dynamic> args,
    CADShapeType type,
  ) async => OpenCascadeNativeShape(
    token: 'SECRET-native-token',
    type: type,
    fingerprint: 'descriptor',
  );
  @override
  Future<void> destroyShape(String token) async {
    destroys++;
    if (failDestroy) throw destroyError;
  }

  @override
  Future<void> shutdown() async {
    shutdowns++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Map<String, dynamic>> _data(
  String directory, {
  bool previous = false,
}) async =>
    (jsonDecode(
              await File(
                p.join(
                  directory,
                  previous ? 'manifest.previous.json' : 'manifest.json',
                ),
              ).readAsString(),
            )
            as Map<String, dynamic>)['data']
        as Map<String, dynamic>;

void main() {
  late Directory root, project;
  late CadRuntime runtime;
  late _Storage storage;
  late List<CadRuntime> runtimes;
  Future<CadRuntime> another({Directory? directory, _Storage? io}) async {
    final r = CadRuntime(
      kernels: KernelManager(),
      assetStorage: io ?? _Storage(),
    );
    runtimes.add(r);
    await r.open('project', directory ?? project);
    return r;
  }

  Future<GeometryAssetId> payload(
    CadGeometryStagingOperation op, {
    CadAssetFile kind = CadAssetFile.brep,
  }) async {
    final id = await op.planAsset();
    await op.write(
      id,
      kind,
      Stream.value(utf8.encode('simulated geometric payload')),
    );
    return id;
  }

  Future<PreparedGeometryAssets> promote(CadRuntime r) =>
      r.withGeometryStaging((op) async {
        await payload(op);
        await op.prepare();
        return op.promote();
      });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cad-assets-test-');
    project = await Directory(p.join(root.path, 'project')).create();
    storage = _Storage();
    runtimes = [];
    runtime = await another(io: storage);
  });
  tearDown(() async {
    for (final r in runtimes) {
      await r.shutdown();
    }
    await root.delete(recursive: true);
  });

  test(
    'IDs use internal entropy and serialize only durable reference',
    () async {
      await runtime.withGeometryStaging((op) async {
        final a = await op.planAsset(), b = await op.planAsset();
        expect(a, isNot(b));
        expect(a.value, matches(RegExp(r'^ga1_[a-f0-9]{32}$')));
        expect(GeometryAssetId.fromJson(a.toJson()), a);
      });
    },
  );
  test('deserialized reference cannot write an owned asset', () async {
    await expectLater(
      runtime.withGeometryStaging((op) async {
        final id = await op.planAsset();
        await op.write(
          GeometryAssetId.fromJson(id.toJson()),
          CadAssetFile.brep,
          Stream.value([1]),
        );
      }),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Asset is not owned by this operation',
        ),
      ),
    );
  });
  for (final phase in [
    'promotion:beforeIntent',
    'manifest:commitIntent:beforeReplace',
    'promotion:afterIntent',
    'promotion:afterMove',
    'manifest:committed:replaced',
  ]) {
    test(
      'producer abort at $phase prevents next advance and retains real moves',
      () async {
        final gate = _Gate(), aborted = Completer<void>();
        final failure = StateError('producer failed'),
            stack = StackTrace.fromString('producer-origin-stack');
        var cleanupCount = 0, moves = 0;
        late String directory;
        late Future<void> promotionObserved;
        storage.onPhase = (s) async {
          if (s == 'cleanup:started') cleanupCount++;
          if (s == 'promotion:afterMove') moves++;
          if (s == 'operation:drainingAfterAbort' && !aborted.isCompleted) {
            aborted.complete();
          }
          if (s == phase && !gate.entered.isCompleted) await gate.wait();
        };
        final task = runtime.withGeometryStaging((op) async {
          directory = op.stagingDirectory;
          await payload(op);
          await payload(op);
          await op.prepare();
          promotionObserved = expectLater(
            op.promote(),
            phase == 'manifest:committed:replaced'
                ? completes
                : throwsA(isA<CadAssetCancelled>()),
          );
          await gate.entered.future;
          Error.throwWithStackTrace(failure, stack);
        });
        final observed = task.then<void>(
          (_) => fail('producer error lost'),
          onError: (Object e, StackTrace s) {
            expect(e, same(failure));
            expect(s.toString(), stack.toString());
          },
        );
        await aborted.future;
        gate.release.complete();
        await observed;
        await promotionObserved;
        final data = await _data(directory);
        expect(data['state'], 'quarantined');
        final expectedMoves = phase == 'promotion:afterMove'
            ? 1
            : phase == 'manifest:committed:replaced'
            ? 2
            : 0;
        expect(moves, expectedMoves);
        expect(data['promoted'], hasLength(expectedMoves));
        expect(cleanupCount, 1);
        final destinations = Directory(
          p.join(project.path, 'CAD', 'Assets', 'v1'),
        );
        expect(
          await destinations.exists() ? await destinations.list().length : 0,
          expectedMoves,
        );
      },
    );
  }
  test('producer failure after committed preserves assets and cause', () async {
    final failure = StateError('post-commit failure');
    var finishes = 0;
    storage.onPhase = (s) async {
      if (s == 'cleanup:started') finishes++;
    };
    await expectLater(
      runtime.withGeometryStaging((op) async {
        await payload(op);
        await op.prepare();
        await op.promote();
        throw failure;
      }),
      throwsA(same(failure)),
    );
    final recovery = (await inspectCadAssetStaging(project)).single;
    expect(recovery.classification, 'quarantinedRecordedFailure');
    expect(recovery.assetsVerified, isTrue);
    expect(finishes, 1);
  });
  test(
    'producer abort wakes a contended lock without releasing incumbent',
    () async {
      final holder = _Gate(), contended = Completer<void>();
      storage.onPhase = (s) async {
        if (s == 'lock:acquired') await holder.wait();
      };
      final a = promote(runtime);
      await holder.entered.future;
      final io = _Storage(), b = await another(io: io);
      io.onPhase = (s) async {
        if (s == 'lock:contended' && !contended.isCompleted) {
          contended.complete();
        }
      };
      final failure = StateError('waiting producer failure');
      late Future<void> promotionObserved;
      await expectLater(
        b.withGeometryStaging((op) async {
          await payload(op);
          await op.prepare();
          promotionObserved = expectLater(
            op.promote(),
            throwsA(isA<CadAssetCancelled>()),
          );
          await contended.future;
          throw failure;
        }),
        throwsA(same(failure)),
      );
      await promotionObserved;
      expect(holder.release.isCompleted, isFalse);
      holder.release.complete();
      await a;
    },
  );
  test('deadline expires while project lock is genuinely contended', () async {
    final holder = _Gate(), contended = Completer<void>();
    storage.onPhase = (s) async {
      if (s == 'lock:acquired') await holder.wait();
    };
    final a = promote(runtime);
    await holder.entered.future;
    final io = _Storage()..controlledDeadline = true, b = await another(io: io);
    io.onPhase = (s) async {
      if (s == 'lock:contended' && !contended.isCompleted) contended.complete();
    };
    final observed = expectLater(promote(b), throwsA(isA<TimeoutException>()));
    await contended.future;
    io.expireLock!(); // Real contention, controlled deadline; no wall-clock sleep.
    await observed;
    expect(holder.release.isCompleted, isFalse);
    holder.release.complete();
    await a;
    io.controlledDeadline = false;
    expect((await promote(b)).assets, hasLength(1));
  });
  for (final changed in ['session', 'revision']) {
    test('isolated $changed change fails the production origin validator', () {
      validateCadTransactionOrigin(
        session: 7,
        revision: 11,
        currentSession: 7,
        currentRevision: 11,
      );
      expect(
        () => validateCadTransactionOrigin(
          session: 7,
          revision: 11,
          currentSession: changed == 'session' ? 8 : 7,
          currentRevision: changed == 'revision' ? 12 : 11,
        ),
        throwsA(isA<StaleCadTransaction>()),
      );
    });
  }
  for (final afterPromotion in [false, true]) {
    test(
      'forced asset ID collision preserves existing asset promoted=$afterPromotion',
      () async {
        storage.fixedId = 'ga1_${'b' * 32}';
        late String directory;
        if (afterPromotion) await promote(runtime);
        await expectLater(
          runtime.withGeometryStaging((op) async {
            directory = op.stagingDirectory;
            if (!afterPromotion) await payload(op);
            await op.planAsset();
          }),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'Asset ID collision',
            ),
          ),
        );
        final file = File(
          afterPromotion
              ? p.join(
                  project.path,
                  'CAD',
                  'Assets',
                  'v1',
                  storage.fixedId!,
                  'shape.brep',
                )
              : p.join(directory, 'files', storage.fixedId!, 'shape.brep'),
        );
        expect(await file.readAsString(), 'simulated geometric payload');
      },
    );
  }
  test('initially empty destination is preserved on collision', () async {
    late Directory destination;
    await expectLater(
      runtime.withGeometryStaging((op) async {
        final id = await payload(op);
        await op.prepare();
        destination = await Directory(
          p.join(project.path, 'CAD', 'Assets', 'v1', id.value),
        ).create(recursive: true);
        expect(await destination.list().length, 0);
        await op.promote();
      }),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Asset destination exists',
        ),
      ),
    );
    expect(await destination.exists(), isTrue);
    expect(await destination.list().length, 0);
  });
  for (final shutdown in [false, true]) {
    test('silent source is cancelled and drained shutdown=$shutdown', () async {
      final listening = Completer<void>(),
          cancelled = Completer<void>(),
          written = Completer<void>();
      storage.onPhase = (s) async {
        if (s == 'file:chunkWritten' && !written.isCompleted) {
          written.complete();
        }
      };
      final source = StreamController<List<int>>(
        onListen: () => listening.complete(),
        onCancel: () => cancelled.complete(),
      );
      final token = CadAssetCancellation();
      late String directory;
      final task = runtime.withGeometryStaging((op) async {
        directory = op.stagingDirectory;
        final id = await op.planAsset();
        await op.write(id, CadAssetFile.brep, source.stream);
      }, cancellation: token);
      final observed = expectLater(
        task,
        throwsA(
          shutdown ? isA<StaleCadTransaction>() : isA<CadAssetCancelled>(),
        ),
      );
      await listening.future;
      source.add([1, 2, 3]);
      await written.future; // No event is emitted after this confirmed chunk.
      final close = shutdown ? runtime.shutdown() : null;
      if (!shutdown) token.cancel();
      await cancelled.future;
      await observed;
      if (close != null) await close;
      await source.close();
      expect((await _data(directory))['state'], 'quarantined');
    });
  }
  test(
    'shutdown waits for transferred owner lease after releasing project lock',
    () async {
      final ledger = _NativeLedger(),
          native = OpenCascadeKernelAdapter(bridge: _NativeLedger());
      final adapter = OpenCascadeKernelAdapter(bridge: ledger);
      final owner = await adapter.createOwnedShape(
        'CREATE VERTEX',
        {},
        CADShapeType.vertex,
      );
      final lease = owner.borrow(), cleanup = Completer<void>();
      var finishes = 0, closed = false;
      storage.onPhase = (s) async {
        if (s == 'cleanup:started') {
          finishes++;
          cleanup.complete();
        }
      };
      final task = runtime.withGeometryStaging((op) async {
        op.attachOwnedShape(owner);
        await payload(op);
        await op.prepare();
        await op.promote();
      });
      await cleanup.future;
      final close = runtime.shutdown().then((_) {
        closed = true;
      });
      final other = await another();
      await promote(
        other,
      ); // Would block if disposal still owned the project lock.
      expect(closed, isFalse);
      expect(ledger.destroys, 0);
      lease.release();
      await task;
      await close;
      expect(ledger.destroys, 1);
      expect(finishes, 1);
      await adapter.unload();
      await native.unload();
    },
  );
  test(
    'silent stream with no events is cancelled without waiting for a chunk',
    () async {
      final listening = Completer<void>(), cancelled = Completer<void>();
      final source = StreamController<List<int>>(
        onListen: () => listening.complete(),
        onCancel: () => cancelled.complete(),
      );
      final token = CadAssetCancellation();
      final observed = expectLater(
        runtime.withGeometryStaging((op) async {
          final id = await op.planAsset();
          await op.write(id, CadAssetFile.brep, source.stream);
        }, cancellation: token),
        throwsA(isA<CadAssetCancelled>()),
      );
      await listening.future;
      token.cancel();
      await cancelled.future;
      await observed;
      await source.close();
    },
  );
  test('failed cleanup checkpoint still disposes owner exactly once', () async {
    final ledger = _NativeLedger(), failure = StateError('cleanup checkpoint');
    final adapter = OpenCascadeKernelAdapter(bridge: ledger);
    final owner = await adapter.createOwnedShape(
      'CREATE VERTEX',
      {},
      CADShapeType.vertex,
    );
    var finishes = 0;
    storage.onPhase = (s) async {
      if (s == 'cleanup:started') {
        finishes++;
        throw failure;
      }
    };
    await expectLater(
      runtime.withGeometryStaging((op) async {
        op.attachOwnedShape(owner);
        await payload(op);
      }),
      throwsA(same(failure)),
    );
    expect(finishes, 1);
    expect(ledger.destroys, 1);
    expect(
      (await inspectCadAssetStaging(project)).single.classification,
      'quarantinedRecordedFailure',
    );
    await adapter.unload();
    expect(ledger.destroys, 1);
  });
  test(
    'producer native disposal and journal failures all remain observable',
    () async {
      final ledger = _NativeLedger()..failDestroy = true;
      final adapter = OpenCascadeKernelAdapter(bridge: ledger);
      final owner = await adapter.createOwnedShape(
        'CREATE VERTEX',
        {},
        CADShapeType.vertex,
      );
      final producer = StateError('producer'), journal = StateError('journal');
      final producerStack = StackTrace.fromString('original producer');
      var finishes = 0;
      storage.onPhase = (s) async {
        if (s == 'cleanup:started') finishes++;
        if (s == 'manifest:quarantined:beforeReplace') throw journal;
      };
      await expectLater(
        runtime.withGeometryStaging((op) async {
          op.attachOwnedShape(owner);
          await payload(op);
          Error.throwWithStackTrace(producer, producerStack);
        }),
        throwsA(
          isA<CadAssetOperationFailure>()
              .having((e) => e.cause, 'producer', same(producer))
              .having(
                (e) => e.causeStack.toString(),
                'producer stack',
                producerStack.toString(),
              )
              .having(
                (e) => e.cleanup,
                'cleanup',
                isA<CadAssetOperationFailure>()
                    .having((e) => e.cause, 'native', same(ledger.destroyError))
                    .having((e) => e.cleanup, 'journal', same(journal)),
              ),
        ),
      );
      expect(finishes, 1);
      expect(ledger.destroys, 1);
      await expectLater(adapter.unload(), throwsA(same(ledger.destroyError)));
    },
  );
  for (final bad in [
    '..',
    '../escape',
    'C:\\evil',
    '/absolute',
    'name:ads',
    'name\u0000',
    'a/b',
    'a\\b',
    'ga1_ABC',
    'ga1_${'a' * 32}.',
  ]) {
    test('asset reference rejects unsafe ID ${jsonEncode(bad)}', () {
      expect(
        () => GeometryAssetId.fromJson({
          'schema': 'flcad.geometry-asset',
          'version': 1,
          'id': bad,
        }),
        throwsFormatException,
      );
    });
  }
  test(
    'two runtimes may prepare simultaneously with separate operation directories',
    () async {
      final b = await another();
      final first = _Gate(), second = _Gate();
      String? aDir, bDir;
      final a = runtime.withGeometryStaging((op) async {
        aDir = op.stagingDirectory;
        await payload(op);
        await first.wait();
      });
      await first.entered.future;
      final other = b.withGeometryStaging((op) async {
        bDir = op.stagingDirectory;
        await payload(op);
        await second.wait();
      });
      await second.entered.future;
      expect(aDir, isNot(bDir));
      first.release.complete();
      second.release.complete();
      await Future.wait([a, other]);
    },
  );
  test('different projects hold promotion locks concurrently', () async {
    final otherProject = await Directory(p.join(root.path, 'other')).create();
    final otherStorage = _Storage(), aGate = _Gate(), bGate = _Gate();
    final b = await another(directory: otherProject, io: otherStorage);
    storage.onPhase = (s) async {
      if (s == 'lock:acquired') await aGate.wait();
    };
    otherStorage.onPhase = (s) async {
      if (s == 'lock:acquired') await bGate.wait();
    };
    final aResult = promote(runtime);
    await aGate.entered.future;
    final bResult = promote(b);
    await bGate.entered.future;
    aGate.release.complete();
    bGate.release.complete();
    await Future.wait([aResult, bResult]);
  });
  test('same project serializes lock and preserves lock file', () async {
    final bStorage = _Storage(),
        b = await another(io: bStorage),
        held = _Gate(),
        contended = Completer<void>();
    storage.onPhase = (s) async {
      if (s == 'lock:acquired') await held.wait();
    };
    bStorage.onPhase = (s) async {
      if (s == 'lock:contended' && !contended.isCompleted) contended.complete();
    };
    final first = promote(runtime);
    await held.entered.future;
    final second = promote(b);
    await contended.future;
    final lock = File(p.join(project.path, '.cad-staging', 'project.lock'));
    expect(await lock.exists(), isTrue);
    held.release.complete();
    await Future.wait([first, second]);
    expect(await lock.exists(), isTrue);
  });
  test(
    'real OS lock from another process prevents promotion and cancellation releases waiter',
    () async {
      final staging = await Directory(
        p.join(project.path, '.cad-staging'),
      ).create();
      final lock = File(p.join(staging.path, 'project.lock'));
      await lock.writeAsString('initial');
      final helper = File(p.join(root.path, 'hold_lock.dart'));
      await helper.writeAsString(
        "import 'dart:io'; import 'dart:convert'; Future<void> main(List<String> a) async { final f=await File(a[0]).open(mode:FileMode.append); await f.lock(FileLock.exclusive,0,1); print('locked'); await stdin.transform(utf8.decoder).first; await f.unlock(0,1); await f.close(); }",
      );
      var search = File(Platform.resolvedExecutable).parent;
      String? executable;
      while (search.parent.path != search.path) {
        for (final candidate in [
          p.join(search.path, 'dart-sdk', 'bin', 'dart.exe'),
          p.join(search.path, 'bin', 'cache', 'dart-sdk', 'bin', 'dart.exe'),
        ]) {
          if (await File(candidate).exists()) executable = candidate;
        }
        if (executable != null) break;
        search = search.parent;
      }
      expect(executable, isNotNull);
      final child = await Process.start(executable!, [helper.path, lock.path]);
      try {
        expect(
          await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
          'locked',
        );
        final cancel = CadAssetCancellation(), contended = Completer<void>();
        storage.onPhase = (s) async {
          if (s == 'lock:contended' && !contended.isCompleted) {
            contended.complete();
          }
        };
        final task = runtime.withGeometryStaging((op) async {
          await payload(op);
          await op.prepare();
          return op.promote();
        }, cancellation: cancel);
        final observed = expectLater(task, throwsA(isA<CadAssetCancelled>()));
        await contended.future;
        cancel.cancel();
        await observed;
      } finally {
        child.stdin.writeln('release');
        await child.stdin.close();
        expect(await child.exitCode, 0);
      }
      expect(await lock.readAsString(), 'initial');
    },
  );
  test(
    'lock timeout is observable without blocking native lock call',
    () async {
      await expectLater(
        runtime.withGeometryStaging((op) async {
          await payload(op);
          await op.prepare();
          await op.promote();
        }, lockTimeout: Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
    },
  );
  test(
    'lock is released after failure and next operation can promote',
    () async {
      storage.onPhase = (s) async {
        if (s == 'promotion:beforeIntent') throw StateError('injected');
      };
      await expectLater(promote(runtime), throwsStateError);
      storage.onPhase = null;
      expect((await promote(runtime)).assets, hasLength(1));
    },
  );
  for (final phase in ['flushed', 'beforeReplace']) {
    test('journal failure at $phase preserves confirmed version', () async {
      final failure = StateError('journal fault'),
          cleanup = StateError('cleanup fault');
      late String directory;
      late String confirmedState;
      await expectLater(
        runtime.withGeometryStaging((op) async {
          directory = op.stagingDirectory;
          await payload(op);
          confirmedState = op.state.name;
          storage.onPhase = (s) async {
            if (s == 'manifest:prepared:$phase') throw failure;
            if (s.startsWith('manifest:quarantined:')) throw cleanup;
          };
          await op.prepare();
        }),
        throwsA(
          isA<CadAssetOperationFailure>()
              .having((e) => e.cause, 'cause', same(failure))
              .having((e) => e.cleanup, 'cleanup', same(cleanup)),
        ),
      );
      final confirmed = await _data(directory);
      expect(confirmed['state'], confirmedState);
      final previous = await _data(directory, previous: true);
      expect(
        previous['sequence'],
        lessThanOrEqualTo(confirmed['sequence'] as int),
      );
      final recovery = await inspectCadAssetStaging(project);
      expect(recovery, hasLength(1));
      expect(await Directory(p.join(directory, 'files')).exists(), isTrue);
    });
  }
  test(
    'manifest updates preserve valid previous and ignore truncated temporaries',
    () async {
      late String directory;
      await runtime.withGeometryStaging((op) async {
        directory = op.stagingDirectory;
        await payload(op);
        await op.prepare();
        expect(op.state, CadAssetStageState.prepared);
        await File(
          p.join(directory, 'manifest.unfinished.tmp'),
        ).writeAsString('{');
      });
      final current = await _data(directory),
          previous = await _data(directory, previous: true);
      expect(current['state'], 'rolledBack');
      expect(previous['state'], 'rollingBack');
      expect(previous['sequence'], lessThan(current['sequence'] as int));
      expect(
        (await inspectCadAssetStaging(project)).single.classification,
        'rolledBackRetained',
      );
    },
  );
  test(
    'valid backup is used conservatively when current is truncated',
    () async {
      late String directory;
      await runtime.withGeometryStaging((op) async {
        directory = op.stagingDirectory;
        await payload(op);
        await op.prepare();
      });
      final backup = await File(
        p.join(directory, 'manifest.previous.json'),
      ).readAsBytes();
      await File(p.join(directory, 'manifest.json')).writeAsString('{');
      final result = (await inspectCadAssetStaging(project)).single;
      expect(result.usedBackup, isTrue);
      expect(result.classification, 'quarantinedBackupOnly');
      expect(
        await File(p.join(directory, 'manifest.previous.json')).readAsBytes(),
        backup,
      );
    },
  );
  test('invalid current and backup are quarantined without removal', () async {
    late String directory;
    await runtime.withGeometryStaging((op) async {
      directory = op.stagingDirectory;
      await payload(op);
    });
    for (final name in ['manifest.json', 'manifest.previous.json']) {
      await File(p.join(directory, name)).writeAsString('{');
    }
    expect(
      (await inspectCadAssetStaging(project)).single.classification,
      'quarantinedInvalidManifestOrPath',
    );
    expect(await Directory(directory).exists(), isTrue);
  });
  test(
    'checksum-valid but semantically invalid committed journal is rejected',
    () async {
      late String directory;
      await runtime.withGeometryStaging((op) async {
        directory = op.stagingDirectory;
        await payload(op);
      });
      final data = await _data(directory);
      data['state'] = 'committed';
      data['promoted'] = [];
      final invalid = jsonEncode({
        'data': data,
        'checksum': sha256.convert(utf8.encode(jsonEncode(data))).toString(),
      });
      for (final name in ['manifest.json', 'manifest.previous.json']) {
        await File(p.join(directory, name)).writeAsString(invalid);
      }
      expect(
        (await inspectCadAssetStaging(project)).single.classification,
        'quarantinedInvalidManifestOrPath',
      );
    },
  );
  test('empty BREP remains recorded as incomplete and quarantined', () async {
    late String directory;
    await expectLater(
      runtime.withGeometryStaging((op) async {
        directory = op.stagingDirectory;
        final id = await op.planAsset();
        await op.write(id, CadAssetFile.brep, const Stream.empty());
      }),
      throwsStateError,
    );
    final data = await _data(directory);
    expect(data['state'], 'quarantined');
    expect(
      ((data['assets'] as List).single['files'] as Map)['brep']['status'],
      'writing',
    );
  });
  test('display changed after hash is rejected before intent', () async {
    late String directory;
    await expectLater(
      runtime.withGeometryStaging((op) async {
        directory = op.stagingDirectory;
        final id = await payload(op, kind: CadAssetFile.display);
        await op.prepare();
        await File(
          p.join(directory, 'files', id.value, 'display.stl'),
        ).writeAsString('tampered');
        await op.promote();
      }),
      throwsStateError,
    );
    expect((await _data(directory))['promoted'], isEmpty);
  });
  test(
    'replacement after directory rename is quarantined before publication',
    () async {
      late String directory;
      GeometryAssetId? id;
      storage.onPhase = (phase) async {
        if (phase == 'promotion:renamed') {
          await File(
            p.join(
              project.path,
              'CAD',
              'Assets',
              'v1',
              id!.value,
              'display.stl',
            ),
          ).writeAsString('replacement after rename');
        }
      };
      await expectLater(
        runtime.withGeometryStaging((op) async {
          directory = op.stagingDirectory;
          id = await payload(op, kind: CadAssetFile.display);
          await op.prepare();
          await op.promote();
        }),
        throwsStateError,
      );
      final manifest = await _data(directory);
      expect(manifest['state'], 'quarantined');
      expect(manifest['promoted'], contains(id!.value));
      expect(
        await File(
          p.join(project.path, 'CAD', 'Assets', 'v1', id!.value, 'display.stl'),
        ).exists(),
        isTrue,
      );
    },
  );
  test(
    'borrowed source streams in bounded chunks and remains unchanged',
    () async {
      final source = File(p.join(root.path, 'borrowed.bin'));
      final writer = await source.open(mode: FileMode.write);
      for (var i = 0; i < 128; i++) {
        await writer.writeFrom(List.filled(65536, i));
      }
      await writer.close();
      final before = (await sha256.bind(source.openRead()).first).toString();
      final result = await runtime.withGeometryStaging((op) async {
        final id = await op.planAsset();
        await op.copySource(id, source);
        await op.prepare();
        return op.promote();
      });
      expect(
        storage.chunks,
        128,
      ); // Borrowed source only; owned hashing is native streaming.
      expect(storage.maxChunk, lessThanOrEqualTo(65536));
      expect((await sha256.bind(source.openRead()).first).toString(), before);
      expect(
        await File(
          p.join(
            project.path,
            'CAD',
            'Assets',
            'v1',
            result.assets.single.value,
            'source',
            'original.bin',
          ),
        ).length(),
        8388608,
      );
    },
  );
  test(
    'destination collision never overwrites even an empty asset directory',
    () async {
      late String destination;
      await expectLater(
        runtime.withGeometryStaging((op) async {
          final id = await payload(op);
          await op.prepare();
          destination = p.join(project.path, 'CAD', 'Assets', 'v1', id.value);
          await Directory(destination).create(recursive: true);
          await File(p.join(destination, 'sentinel')).writeAsString('preserve');
          await op.promote();
        }),
        throwsStateError,
      );
      expect(
        await File(p.join(destination, 'sentinel')).readAsString(),
        'preserve',
      );
    },
  );
  for (final phase in [
    'promotion:beforeIntent',
    'promotion:afterIntent',
    'promotion:afterMove',
  ]) {
    test(
      'failure at $phase remains recoverable and never removes files',
      () async {
        storage.onPhase = (s) async {
          if (s == phase) throw StateError('injected');
        };
        await expectLater(promote(runtime), throwsStateError);
        final recovery = (await inspectCadAssetStaging(project)).single;
        expect(recovery.classification, startsWith('quarantined'));
        expect(await Directory(recovery.directory).exists(), isTrue);
      },
    );
  }
  test('partial multiasset promotion is quarantined and retained', () async {
    var moves = 0;
    storage.onPhase = (s) async {
      if (s == 'promotion:afterMove' && ++moves == 1) {
        throw StateError('partial');
      }
    };
    await expectLater(
      runtime.withGeometryStaging((op) async {
        await payload(op);
        await payload(op);
        await op.prepare();
        return op.promote();
      }),
      throwsStateError,
    );
    final recovery = (await inspectCadAssetStaging(project)).single;
    expect(recovery.classification, startsWith('quarantined'));
    expect(
      await Directory(
        p.join(project.path, 'CAD', 'Assets', 'v1'),
      ).list().length,
      1,
    );
  });
  test(
    'complete promotion awaits reconciliation without publishing document',
    () async {
      final document = runtime.document, revision = runtime.runtimeRevision;
      final result = await promote(runtime);
      expect(result.documentPublished, isFalse);
      expect(identical(runtime.document, document), isTrue);
      expect(runtime.runtimeRevision, revision);
      final recovery = (await inspectCadAssetStaging(project)).single;
      expect(recovery.classification, 'awaitingDocumentReconciliation');
      expect(recovery.assetsVerified, isTrue);
    },
  );
  test(
    'terminal operation and late callback cannot reacquire authority',
    () async {
      late CadGeometryStagingOperation captured;
      await runtime.withGeometryStaging((op) async {
        captured = op;
        await payload(op);
        await op.prepare();
        await op.promote();
      });
      await expectLater(captured.planAsset(), throwsStateError);
      await expectLater(captured.promote(), throwsStateError);
    },
  );
  test(
    'cancelled callback cannot return success without another API call',
    () async {
      final cancel = CadAssetCancellation();
      await expectLater(
        runtime.withGeometryStaging((op) async {
          await payload(op);
          cancel.cancel();
        }, cancellation: cancel),
        throwsA(isA<CadAssetCancelled>()),
      );
    },
  );
  test(
    'runtime shutdown invalidates revision/session context and drains staging',
    () async {
      final gate = _Gate();
      final task = runtime.withGeometryStaging((op) async {
        await payload(op);
        await op.prepare();
        await gate.wait();
        await op.promote();
      });
      final observed = expectLater(task, throwsA(isA<StaleCadTransaction>()));
      await gate.entered.future;
      final close = runtime.shutdown();
      gate.release.complete();
      await observed;
      await close;
    },
  );
  test(
    'shutdown cancels waiting project lock without a polling delay dependency',
    () async {
      final bStorage = _Storage(),
          b = await another(io: bStorage),
          held = _Gate(),
          contended = Completer<void>();
      storage.onPhase = (s) async {
        if (s == 'lock:acquired') await held.wait();
      };
      bStorage.onPhase = (s) async {
        if (s == 'lock:contended' && !contended.isCompleted) {
          contended.complete();
        }
      };
      final first = promote(runtime);
      await held.entered.future;
      final second = promote(b);
      final observed = expectLater(
        second,
        throwsA(anyOf(isA<CadAssetCancelled>(), isA<StaleCadTransaction>())),
      );
      await contended.future;
      final close = b.shutdown();
      await observed;
      await close;
      held.release.complete();
      await first;
    },
  );
  test(
    'reentrant source stream is rejected instead of creating a Future cycle',
    () async {
      await expectLater(
        runtime.withGeometryStaging((op) async {
          final id = await op.planAsset();
          Stream<List<int>> stream() async* {
            await op.planAsset();
            yield [1];
          }

          await op.write(id, CadAssetFile.brep, stream());
        }),
        throwsStateError,
      );
    },
  );
  test(
    'native ownership transfers only while preparing and is disposed once',
    () async {
      final ledger = _NativeLedger(),
          adapter = OpenCascadeKernelAdapter(bridge: _NativeLedger());
      final native = OpenCascadeKernelAdapter(bridge: ledger);
      final owner = await native.createOwnedShape(
        'CREATE VERTEX',
        {},
        CADShapeType.vertex,
      );
      late String directory;
      await runtime.withGeometryStaging((op) async {
        directory = op.stagingDirectory;
        op.attachOwnedShape(owner);
        expect(owner.state, NativeResourceState.transferred);
        await payload(op);
        await op.prepare();
        expect(() => op.attachOwnedShape(owner), throwsStateError);
        await op.promote();
      });
      expect(ledger.destroys, 1);
      expect(
        await File(p.join(directory, 'manifest.json')).readAsString(),
        isNot(contains('SECRET')),
      );
      await native.unload();
      await adapter.unload();
      expect(ledger.destroys, 1);
    },
  );
  test(
    'native dispose failure remains quarantined even with valid promoted assets',
    () async {
      final ledger = _NativeLedger()..failDestroy = true;
      final native = OpenCascadeKernelAdapter(bridge: ledger);
      final owner = await native.createOwnedShape(
        'CREATE VERTEX',
        {},
        CADShapeType.vertex,
      );
      await expectLater(
        runtime.withGeometryStaging((op) async {
          op.attachOwnedShape(owner);
          await payload(op);
          await op.prepare();
          await op.promote();
        }),
        throwsA(same(ledger.destroyError)),
      );
      final recovery = (await inspectCadAssetStaging(project)).single;
      expect(recovery.classification, 'quarantinedRecordedFailure');
      expect(recovery.assetsVerified, isTrue);
      expect(ledger.destroys, 1);
      expect(
        await File(p.join(recovery.directory, 'manifest.json')).readAsString(),
        isNot(contains('SECRET')),
      );
      await expectLater(native.unload(), throwsA(same(ledger.destroyError)));
    },
  );
  test(
    'junction escape is rejected and outside sentinel is untouched',
    () async {
      final outside = await Directory(p.join(root.path, 'outside')).create();
      final sentinel = File(p.join(outside.path, 'sentinel'));
      await sentinel.writeAsString('safe');
      final target = p.join(project.path, 'CAD');
      final creation = await Process.run('cmd.exe', [
        '/d',
        '/c',
        'mklink',
        '/J',
        target,
        outside.path,
      ]);
      expect(creation.exitCode, 0);
      await expectLater(
        promote(runtime),
        throwsA(
          isA<CadAssetNativeError>()
              .having((e) => e.status, 'policy', 3)
              .having((e) => e.effect, 'no mutation', 0),
        ),
      );
      expect(await sentinel.readAsString(), 'safe');
      expect(
        await outside
            .list(recursive: true, followLinks: false)
            .map((entry) => p.relative(entry.path, from: outside.path))
            .toList(),
        ['sentinel'],
      );
    },
    skip: !Platform.isWindows,
  );
  test(
    'one operation never removes another operation or legacy files',
    () async {
      for (final folder in ['NativeShapes', 'DisplayMeshes']) {
        final file = File(p.join(project.path, folder, 'old.bin'));
        await file.parent.create();
        await file.writeAsString('legacy');
      }
      final result = await promote(runtime);
      final first = await inspectCadAssetStaging(project);
      storage.onPhase = (s) async {
        if (s == 'promotion:beforeIntent') throw StateError('fail');
      };
      await expectLater(promote(runtime), throwsStateError);
      expect(await Directory(first.single.directory).exists(), isTrue);
      expect(
        await Directory(
          p.join(
            project.path,
            'CAD',
            'Assets',
            'v1',
            result.assets.single.value,
          ),
        ).exists(),
        isTrue,
      );
      for (final folder in ['NativeShapes', 'DisplayMeshes']) {
        expect(
          await File(p.join(project.path, folder, 'old.bin')).readAsString(),
          'legacy',
        );
      }
    },
  );
}
