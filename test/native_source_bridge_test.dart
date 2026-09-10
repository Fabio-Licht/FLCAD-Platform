import 'dart:async';
import 'dart:io';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:flcad_mobile/app/runtime/cad_asset_fs_native.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final caf = Platform.environment['FLCAD_CAD_ASSET_FS_DLL']!;
  final occ = Platform.environment['FLCAD_SOURCE_OCC_DLL']!;
  final bridge = Platform.environment['FLCAD_SOURCE_BRIDGE_DLL']!;
  final generator = Platform.environment['FLCAD_SOURCE_FIXTURE_EXE']!;
  final faultLibrary =
      Platform.environment['FLCAD_SOURCE_FAULT_DLL'] ??
      p.join(File(bridge).parent.path, 'cad_occ_bridge_test.dll');
  late int Function() pathImports;
  late Directory root;
  late CadAssetNativeFs fs;
  late OpenCascadeKernelAdapter adapter;
  late int shape, mesh;
  late Map<String, dynamic> shapeInfo, meshInfo;
  NativeSourceRecoveryFailure? quarantined;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cob-dart-');
    final fixture = await Process.run(generator, [caf, occ, root.path]);
    expect(fixture.exitCode, 0, reason: '${fixture.stdout}\n${fixture.stderr}');
    fs = CadAssetNativeFs(root.path);
    shape = fs.child(fs.root, 'shape.brep');
    mesh = fs.child(fs.root, 'display.stl');
    shapeInfo = fs.info(shape, digest: true);
    meshInfo = fs.info(mesh, digest: true);
    adapter = OpenCascadeKernelAdapter(bridge: OpenCascadeFFI.load(path: occ));
    await adapter.initialize();
    pathImports = DynamicLibrary.open(occ)
        .lookupFunction<Uint64 Function(), int Function()>(
          'flcad_occ_test_path_import_count',
        );
  });
  tearDown(() async {
    expect(pathImports(), 0, reason: 'No pathname importer in Dart bridge');
    if (quarantined != null) {
      await expectLater(adapter.unload(), throwsA(same(quarantined)));
      fs.dispose();
    } else {
      await adapter.unload();
      await fs.shutdown();
    }
    await root.delete(recursive: true);
  });
  Future<NativeSourceResource> read({
    bool brep = true,
    NativeSourceCancellation? cancellation,
    Map<String, dynamic>? expected,
    void Function(NativeSourceResource)? captured,
    bool reject = false,
    String? library,
  }) => adapter.readOwnedAsset(
    filesystem: fs,
    file: brep ? shape : mesh,
    expected: expected ?? (brep ? shapeInfo : meshInfo),
    kind: brep ? NativeResourceKind.shape : NativeResourceKind.mesh,
    cancellation: cancellation ?? NativeSourceCancellation(),
    bridgePath: library ?? bridge,
    onCaptured: captured,
    debugRejectCustody: reject,
  );
  for (final brep in [true, false]) {
    test(
      '${brep ? 'BREP' : 'STL'} real source publishes into custody and disposes once',
      () async {
        final result = await read(brep: brep);
        expect(adapter.custodyDiagnostics!.allocations, 1);
        expect(
          result.descriptor.kind,
          brep ? NativeResourceKind.shape : NativeResourceKind.mesh,
        );
        expect(result.descriptor.fingerprint, isNotEmpty);
        expect(result.descriptor.bounds, hasLength(6));
        expect(result.descriptor.hasNormals, isFalse);
        if (brep) {
          final lease = result.shape!.borrow();
          expect(await adapter.diagnoseOwned(lease), isA<List>());
          lease.release();
        } else {
          final lease = result.mesh!.borrow();
          expect(lease.isReleased, false);
          lease.release();
        }
        await result.dispose();
        await result.dispose();
        expect(adapter.custodyDiagnostics!.allocations, 0);
        expect(
          await File(
            p.join(root.path, brep ? 'shape.brep' : 'display.stl'),
          ).exists(),
          true,
        );
      },
    );
  }
  for (final field in ['fileId', 'size', 'sha256']) {
    test(
      '$field mismatch preserves source and rejects before custody',
      () async {
        final wrong = Map<String, dynamic>.of(shapeInfo);
        wrong[field] = field == 'size'
            ? (shapeInfo[field] as int) + 1
            : ('0' * (shapeInfo[field] as String).length);
        await expectLater(
          read(expected: wrong),
          throwsA(
            isA<NativeSourceFailure>()
                .having((e) => e.filesystem['status'], 'CAF policy', 3)
                .having(
                  (e) => e.bridgePhase,
                  'filesystem phase',
                  field == 'sha256' ? 2 : 1,
                ),
          ),
        );
        expect(adapter.custodyDiagnostics!.allocations, 0);
        expect(fs.info(shape, digest: true), shapeInfo);
        expect(adapter.sourceEffects.any((e) => e.quarantined), true);
      },
    );
  }
  test('revoke before admission creates no allocation', () async {
    final cancel = NativeSourceCancellation()..revoke();
    await expectLater(
      read(cancellation: cancel),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'cause',
          'Native source revoked',
        ),
      ),
    );
    expect(adapter.custodyDiagnostics!.allocations, 0);
  });
  test(
    'revoke while admitted reaches native source or compensates publication',
    () async {
      final cancel = NativeSourceCancellation();
      final future = read(brep: false, cancellation: cancel);
      final expectation = expectLater(
        future,
        throwsA(
          anyOf(
            isA<NativeSourceFailure>().having(
              (e) => e.nativeStatus,
              'cancel',
              3,
            ),
            isA<StateError>().having(
              (e) => e.message,
              'late cancel',
              'Native source revoked after publication',
            ),
          ),
        ),
      );
      await cancel.admitted;
      cancel.revoke();
      await expectation;
      expect(adapter.custodyDiagnostics!.allocations, 0);
    },
  );
  test('custody failure compensates escrow and remains observable', () async {
    await expectLater(
      read(reject: true),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'cause',
          'Injected custody admission failure',
        ),
      ),
    );
    expect(adapter.custodyDiagnostics!.allocations, 0);
    expect(adapter.sourceEffects.last.compensated, true);
    expect(fs.info(shape, digest: true), shapeInfo);
  });
  test('notification failure retains captured owner in exception', () async {
    final cause = StateError('notification');
    NativeSourceNotificationFailure? observed;
    try {
      await read(
        captured: (_) {
          throw cause;
        },
      );
    } on NativeSourceNotificationFailure catch (e) {
      observed = e;
    }
    expect(observed, isNotNull);
    expect(observed!.cause, same(cause));
    expect(adapter.custodyDiagnostics!.allocations, 1);
    await observed.resource.dispose();
    expect(adapter.custodyDiagnostics!.allocations, 0);
  });
  test('shutdown waits admitted operation and retained owner lease', () async {
    final cancel = NativeSourceCancellation();
    final captured = Completer<void>();
    final prior = await read();
    final lease = prior.shape!.borrow();
    final future = read(
      cancellation: cancel,
      captured: (r) {
        captured.complete();
      },
    );
    await cancel.admitted;
    bool closed = false;
    final closing = adapter.unload().then((_) {
      closed = true;
    });
    await captured.future;
    await future;
    expect(closed, false);
    lease.release();
    await closing;
    expect(closed, true);
  });
  test('filesystem shutdown drains admitted source capability', () async {
    final cancel = NativeSourceCancellation();
    final future = read(cancellation: cancel);
    await cancel.admitted;
    final closing = fs.shutdown();
    final result = await future;
    await closing;
    await result.dispose();
    expect(await File(p.join(root.path, 'shape.brep')).exists(), true);
  });
  test('two concurrent imports produce independent owners', () async {
    final both = await Future.wait([read(), read(brep: false)]);
    expect(adapter.custodyDiagnostics!.allocations, 2);
    expect(both[0].shape!.identity, isNot(both[1].mesh!.identity));
    await Future.wait(both.map((r) => r.dispose()));
  });
  test(
    'BREP sink writes through CAF writer without Dart byte transport',
    () async {
      final resource = await read();
      final target = fs.child(fs.root, 'native-output.brep', create: true);
      final lease = resource.shape!.borrow();
      try {
        final sealed = await adapter.streamShapeIntoStaging(
          filesystem: fs,
          file: target,
          shape: lease,
          displayStl: false,
          bridgePath: bridge,
        );
        expect(sealed['state'], 'sealed');
        expect(sealed['size'], greaterThan(0));
        expect(sealed['sha256'], isNotEmpty);
        expect(fs.info(target, digest: true)['sha256'], sealed['sha256']);
      } finally {
        lease.release();
        fs.close(target);
        await resource.dispose();
      }
    },
  );
  test(
    'STL display sink writes through CAF writer without Dart byte transport',
    () async {
      final resource = await read();
      final target = fs.child(fs.root, 'native-display.stl', create: true);
      final lease = resource.shape!.borrow();
      try {
        final sealed = await adapter.streamShapeIntoStaging(
          filesystem: fs,
          file: target,
          shape: lease,
          displayStl: true,
          bridgePath: bridge,
        );
        expect(sealed['state'], 'sealed');
        expect(sealed['size'], greaterThan(84));
        expect(fs.info(target, digest: true)['sha256'], sealed['sha256']);
      } finally {
        lease.release();
        fs.close(target);
        await resource.dispose();
      }
    },
  );
  test('missing bridge fails explicitly before filesystem effect', () async {
    await expectLater(
      read(library: p.join(root.path, 'missing.dll')),
      throwsA(isA<ArgumentError>()),
    );
    expect(adapter.custodyDiagnostics!.allocations, 0);
    expect(fs.info(shape, digest: true), shapeInfo);
  });
  test(
    'native error after publication enters custody before reporting failure',
    () async {
      final dll = DynamicLibrary.open(faultLibrary);
      final inject = dll
          .lookupFunction<Void Function(Uint32), void Function(int)>(
            'cob_test_parse_failure',
          );
      NativeSourcePublicationFailure? observed;
      inject(2);
      try {
        await read(library: faultLibrary);
      } on NativeSourcePublicationFailure catch (e) {
        observed = e;
      } finally {
        inject(0);
      }
      expect(observed, isNotNull);
      expect(observed!.failure.bridgeStatus, 7);
      expect(adapter.custodyDiagnostics!.allocations, 1);
      await observed.resource.dispose();
      expect(adapter.custodyDiagnostics!.allocations, 0);
    },
  );
  test(
    'failed compensation quarantines session and preserves original failure',
    () async {
      final testPath = faultLibrary;
      final injected = DynamicLibrary.open(testPath);
      final fail = injected
          .lookupFunction<Void Function(Uint32), void Function(int)>(
            'cob_test_destroy_failure',
          );
      fail(1);
      try {
        await read(reject: true, library: testPath);
      } on NativeSourceRecoveryFailure catch (error) {
        quarantined = error;
      }
      expect(quarantined, isNotNull);
      expect(
        quarantined!.cause,
        isA<StateError>().having(
          (e) => e.message,
          'original',
          'Injected custody admission failure',
        ),
      );
      expect(quarantined!.stack, isNotNull);
      expect(quarantined!.cleanup.bridgeStatus, 6);
      expect(quarantined!.cleanup.cleanupMessage, 'Injected destroy failure');
      expect(adapter.custodyDiagnostics!.state, NativeSessionState.quarantined);
      expect(fs.sourceQuarantine, same(quarantined));
      await expectLater(adapter.unload(), throwsA(same(quarantined)));
      // Test-only manual recovery after demonstrating the shutdown prohibition.
      fail(0);
      final size = injected.lookupFunction<Uint32 Function(), int Function()>(
        'cob_result_size_v1',
      )();
      final result = calloc<Uint8>(size);
      try {
        final close = injected
            .lookupFunction<
              Int32 Function(Uint64, Pointer<Void>, Uint32),
              int Function(int, Pointer<Void>, int)
            >('cob_close_v1');
        expect(close(quarantined!.cleanup.operation, result.cast(), size), 0);
      } finally {
        calloc.free(result);
      }
    },
  );
}
