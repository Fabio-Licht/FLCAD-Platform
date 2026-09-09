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
    if (failDestroy) throw StateError('SECRET-native-token failed');
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
      await runtime
          .withGeometryStaging((op) async {
            final a = await op.planAsset(), b = await op.planAsset();
            expect(a, isNot(b));
            expect(a.value, matches(RegExp(r'^ga1_[a-f0-9]{32}$')));
            expect(GeometryAssetId.fromJson(a.toJson()), a);
            await expectLater(
              op.write(
                GeometryAssetId.fromJson(a.toJson()),
                CadAssetFile.brep,
                Stream.value([1]),
              ),
              throwsStateError,
            );
          })
          .catchError((Object _) {});
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
      late String directory;
      late Map<String, dynamic> confirmed;
      await expectLater(
        runtime.withGeometryStaging((op) async {
          directory = op.stagingDirectory;
          await payload(op);
          confirmed = await _data(directory);
          storage.onPhase = (s) async {
            if (s == 'manifest:prepared:$phase' ||
                s.startsWith('manifest:quarantined:')) {
              throw StateError('journal fault');
            }
          };
          await op.prepare();
        }),
        throwsA(anything),
      );
      expect(await _data(directory), confirmed);
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
        final current = await _data(directory),
            previous = await _data(directory, previous: true);
        expect(current['state'], 'prepared');
        expect(previous['sequence'], lessThan(current['sequence'] as int));
        await File(
          p.join(directory, 'manifest.unfinished.tmp'),
        ).writeAsString('{');
      });
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
      expect(storage.chunks, greaterThan(128));
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
        throwsA(isA<CadAssetOperationFailure>()),
      );
      final recovery = (await inspectCadAssetStaging(project)).single;
      expect(recovery.classification, 'quarantinedRecordedFailure');
      expect(recovery.assetsVerified, isTrue);
      expect(ledger.destroys, 1);
      expect(
        await File(p.join(recovery.directory, 'manifest.json')).readAsString(),
        isNot(contains('SECRET')),
      );
      await native.unload().catchError((Object _) {});
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
      await expectLater(promote(runtime), throwsStateError);
      expect(await sentinel.readAsString(), 'safe');
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
