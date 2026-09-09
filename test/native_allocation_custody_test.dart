import 'dart:async';
import 'dart:convert';

import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';

import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_bridge.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Simulates the registry, never loads FFI. Native token reuse is intentional.
class _Ledger
    implements OpenCascadeNativeBridge, OpenCascadeManagedMeshNativeBridge {
  final events = <Map<String, Object?>>[];
  final live = <String, int>{};
  int sequence = 0, initializations = 0, shutdowns = 0;
  String? nextToken;
  bool failDestroy = false, failShutdown = false, failInitialize = false;
  Completer<void>? createBarrier,
      destroyBarrier,
      validateBarrier,
      versionBarrier,
      diagnosticBarrier;
  final createEntered = Completer<void>();
  final destroyEntered = Completer<void>();
  final validateEntered = Completer<void>();
  final versionEntered = Completer<void>();
  final diagnosticEntered = Completer<void>();
  void Function()? onInitialize, onDestroy;

  void enter(Completer<void> signal) {
    if (!signal.isCompleted) signal.complete();
  }

  @override
  Future<void> initialize() {
    initializations++;
    onInitialize?.call();
    return failInitialize
        ? Future.error(StateError('initialize failed'))
        : Future.value();
  }

  @override
  Future<String> version() async {
    enter(versionEntered);
    if (versionBarrier case final barrier?) await barrier.future;
    return 'simulated';
  }

  @override
  Future<Set<String>> capabilities() async => {'brep', 'meshing'};
  @override
  Future<Map<String, dynamic>> diagnostics() async {
    enter(diagnosticEntered);
    if (diagnosticBarrier case final barrier?) await barrier.future;
    return {'healthy': true};
  }

  String allocate(String kind) {
    final token = nextToken ?? 'native-${++sequence}';
    nextToken = null;
    final generation = (live['generation:$kind:$token'] ?? 0) + 1;
    live['generation:$kind:$token'] = generation;
    live['$kind:$token'] = generation;
    events.add({
      'event': 'allocate',
      'kind': kind,
      'token': token,
      'generation': generation,
    });
    return token;
  }

  @override
  Future<OpenCascadeNativeShape> createShape(
    String operation,
    Map<String, dynamic> parameters,
    CADShapeType expectedType,
  ) async {
    enter(createEntered);
    if (createBarrier case final barrier?) await barrier.future;
    return OpenCascadeNativeShape(
      token: allocate('shape'),
      type: expectedType,
      fingerprint: 'same-persistent-description',
    );
  }

  @override
  Future<OpenCascadeNativeMesh> createManagedMesh() async =>
      OpenCascadeNativeMesh(
        token: allocate('mesh'),
        fingerprint: 'mesh',
        vertexCount: 3,
        triangleCount: 1,
        bounds: const KernelBounds(0, 0, 0, 1, 1, 1),
        hasNormals: true,
      );
  Future<void> destroy(String kind, String token) async {
    events.add({
      'event': 'destroy-request',
      'kind': kind,
      'token': token,
      'generation': live['$kind:$token'],
    });
    enter(destroyEntered);
    onDestroy?.call();
    if (destroyBarrier case final barrier?) await barrier.future;
    if (failDestroy) {
      events.add({'event': 'destroy-failed', 'kind': kind, 'token': token});
      throw StateError('destroy uncertain');
    }
    if (live.remove('$kind:$token') == null) {
      throw StateError('double-free or wrong allocation');
    }
    events.add({'event': 'destroy-complete', 'kind': kind, 'token': token});
  }

  @override
  Future<void> destroyShape(String token) => destroy('shape', token);
  @override
  Future<void> destroyMesh(String token) => destroy('mesh', token);
  @override
  Future<List<GeometryDiagnostic>> validate(String token) async {
    enter(validateEntered);
    if (validateBarrier case final barrier?) await barrier.future;
    if (!live.containsKey('shape:$token')) throw StateError('use-after-free');
    return [];
  }

  @override
  Future<void> shutdown() async {
    shutdowns++;
    events.add({'event': 'shutdown'});
    if (failShutdown) throw StateError('shutdown uncertain');
    live.clear();
  }

  void snapshot(OwnedNativeShape owner, {String event = 'owner'}) {
    events.add({
      'event': event,
      'allocationId': owner.identity.hashCode,
      'kind': owner.identity.kind.name,
      'generation': owner.identity.generation,
      'session': owner.identity.sessionGeneration,
      'gateway': owner.identity.sessionGeneration,
      'owner': identityHashCode(owner),
      'leases': owner.leaseCount,
      'state': owner.state.name,
    });
  }

  int get destroys =>
      events.where((e) => e['event'] == 'destroy-request').length;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Wrapper implements OpenCascadeNativeBridge {
  _Wrapper(this.ledger);
  final _Ledger ledger;
  @override
  Future<void> initialize() => ledger.initialize();
  @override
  Future<void> shutdown() => ledger.shutdown();
  @override
  Future<String> version() => ledger.version();
  @override
  Future<Set<String>> capabilities() => ledger.capabilities();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Ledger ledger;
  late OpenCascadeKernelAdapter adapter;
  late List<OpenCascadeKernelAdapter> adapters;
  Future<OwnedNativeShape> shape([OpenCascadeKernelAdapter? a]) =>
      (a ?? adapter).createOwnedShape('CREATE VERTEX', const {
        'persistentId': 'same',
      }, CADShapeType.vertex);
  OpenCascadeKernelAdapter another({
    OpenCascadeNativeBridge? bridge,
    Object? key,
  }) {
    final a = OpenCascadeKernelAdapter(
      bridge: bridge ?? ledger,
      nativeLibraryKey: key,
    );
    adapters.add(a);
    return a;
  }

  setUp(() {
    ledger = _Ledger();
    adapters = [];
    adapter = another();
  });
  tearDown(() async {
    for (final a in adapters) {
      await a.unload().catchError((Object _) {});
    }
  });

  test(
    'same persistent description has independent allocation identities',
    () async {
      final a = await shape(), b = await shape();
      ledger.snapshot(a);
      ledger.snapshot(b);
      expect(a.identity, isNot(b.identity));
      await a.dispose();
      expect(b.state, NativeResourceState.owned);
      await b.dispose();
      expect(ledger.destroys, 2);
    },
  );
  test(
    'same token receives new generation and stale owner cannot destroy new record',
    () async {
      ledger.nextToken = 'reused';
      final a = await shape();
      await a.dispose();
      ledger.nextToken = 'reused';
      final b = await shape();
      expect(a.identity, isNot(b.identity));
      expect(b.identity.generation, greaterThan(a.identity.generation));
      await a.dispose();
      expect(ledger.destroys, 1);
      await b.dispose();
    },
  );
  test(
    'new session invalidates old identity even with reused native token',
    () async {
      ledger.nextToken = 'reused';
      final a = await shape();
      final oldLease = a.borrow();
      oldLease.release();
      await adapter.unload();
      ledger.nextToken = 'reused';
      final b = await shape();
      expect(a.identity.sessionGeneration, isNot(b.identity.sessionGeneration));
      await expectLater(adapter.diagnoseOwned(oldLease), throwsStateError);
      await a.dispose();
      expect(b.state, NativeResourceState.owned);
    },
  );
  test(
    'JSON and reconstructed ShapeHandle carry no ownership authority',
    () async {
      final owner = await shape();
      final handle = ShapeHandle.reference(
        persistentId: 'same',
        kernelId: 'opencascade',
        type: CADShapeType.vertex,
        fingerprint: 'x',
      );
      final restored = ShapeHandle.fromJson(
        jsonDecode(jsonEncode(handle.toJson())) as Map<String, dynamic>,
      );
      expect(restored, isNot(isA<OwnedNativeShape>()));
      expect(adapter.isUnmanaged(restored), isFalse);
      await expectLater(adapter.destroy(restored), throwsStateError);
      expect(owner.state, NativeResourceState.owned);
      expect(owner.identity.toString(), isNot(contains('native-')));
      expect(
        () => jsonEncode(owner.identity),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
    },
  );
  test('shape and mesh credentials cannot mix even with same token', () async {
    ledger.nextToken = 'same-token';
    final a = await shape();
    ledger.nextToken = 'same-token';
    final b = await adapter.createOwnedMesh();
    expect(a.identity, isNot(b.identity));
    final dynamic meshLease = b.borrow();
    expect(() => adapter.diagnoseOwned(meshLease), throwsA(isA<TypeError>()));
    meshLease.release();
    await a.dispose();
    await b.dispose();
    expect(
      ledger.events
          .where((e) => e['event'] == 'destroy-request')
          .map((e) => e['kind']),
      ['shape', 'mesh'],
    );
  });
  test(
    'transfer revokes old owner and preserves allocation identity',
    () async {
      final a = await shape();
      final b = a.transfer();
      ledger.snapshot(a, event: 'transfer-from');
      ledger.snapshot(b, event: 'transfer-to');
      expect(a.state, NativeResourceState.transferred);
      expect(a.identity, b.identity);
      expect(a.borrow, throwsStateError);
      expect(a.transfer, throwsStateError);
      await expectLater(a.dispose(), throwsStateError);
      expect(ledger.destroys, 0);
      await b.dispose();
      expect(ledger.destroys, 1);
    },
  );
  test(
    'dispose is idempotent and concurrent calls share exact Future',
    () async {
      final a = await shape();
      ledger.destroyBarrier = Completer<void>();
      final first = a.dispose(), second = a.dispose();
      expect(identical(first, second), isTrue);
      await ledger.destroyEntered.future;
      expect(ledger.destroys, 1);
      ledger.destroyBarrier!.complete();
      await first;
      expect(identical(first, a.dispose()), isTrue);
      expect(a.state, NativeResourceState.disposed);
      expect(a.borrow, throwsStateError);
      expect(a.transfer, throwsStateError);
    },
  );
  test(
    'synchronous destroy reentrancy observes published disposal Future',
    () async {
      final a = await shape();
      Future<void>? reentrant;
      ledger.onDestroy = () => reentrant = a.dispose();
      final first = a.dispose();
      expect(identical(first, reentrant), isTrue);
      await first;
      expect(ledger.destroys, 1);
    },
  );
  test('one lease blocks destroy; last release completes disposal', () async {
    final a = await shape();
    final lease = a.borrow();
    ledger.snapshot(a, event: 'lease');
    final disposal = a.dispose();
    expect(ledger.destroys, 0);
    expect(a.borrow, throwsStateError);
    lease.release();
    await disposal;
    expect(ledger.destroys, 1);
  });
  test('multiple leases and repeated release preserve correct count', () async {
    final a = await shape();
    final first = a.borrow(), second = a.borrow();
    final disposal = a.dispose();
    first.release();
    first.release();
    expect(a.leaseCount, 1);
    expect(ledger.destroys, 0);
    second.release();
    await disposal;
    expect(a.leaseCount, 0);
  });
  test('lease survives transfer and continues pinning the new owner', () async {
    final a = await shape();
    final lease = a.borrow();
    final b = a.transfer();
    await adapter.diagnoseOwned(lease);
    final disposal = b.dispose();
    expect(ledger.destroys, 0);
    lease.release();
    await disposal;
  });
  test('existing lease can be used while owner disposal waits', () async {
    final a = await shape();
    final lease = a.borrow();
    final disposal = a.dispose();
    await adapter.diagnoseOwned(lease);
    lease.release();
    await disposal;
  });
  test(
    'release cannot race in-flight native usage protected by child pin',
    () async {
      final a = await shape();
      final lease = a.borrow();
      ledger.validateBarrier = Completer<void>();
      final use = adapter.diagnoseOwned(lease);
      await ledger.validateEntered.future;
      lease.release();
      final disposal = a.dispose();
      expect(ledger.destroys, 0);
      ledger.validateBarrier!.complete();
      await use;
      await disposal;
    },
  );
  test(
    'released lease cannot recover authority through late callback',
    () async {
      final a = await shape();
      final lease = a.borrow();
      lease.release();
      await expectLater(adapter.diagnoseOwned(lease), throwsStateError);
      expect(a.leaseCount, 0);
    },
  );
  test(
    'destroy failure remains observable in quarantine without retry',
    () async {
      final a = await shape();
      ledger.failDestroy = true;
      final disposal = a.dispose();
      await expectLater(disposal, throwsStateError);
      expect(a.state, NativeResourceState.quarantined);
      expect(a.disposalError, isA<StateError>());
      expect(a.transfer, throwsStateError);
      expect(a.borrow, throwsStateError);
      expect(identical(disposal, a.dispose()), isTrue);
      await expectLater(a.dispose(), throwsStateError);
      expect(ledger.destroys, 1);
      expect(adapter.custodyDiagnostics!.quarantined, 1);
    },
  );
  test('two adapters share session and initialization', () async {
    final b = another();
    await Future.wait([adapter.initialize(), b.initialize()]);
    expect(ledger.initializations, 1);
    expect(adapter.custodyDiagnostics!.participants, 2);
    expect(
      adapter.custodyDiagnostics!.sessionGeneration,
      b.custodyDiagnostics!.sessionGeneration,
    );
  });
  test(
    'unload A preserves B and managed resources until final participant',
    () async {
      final b = another();
      final aOwner = await shape();
      final bOwner = await shape(b);
      await adapter.unload();
      expect(ledger.shutdowns, 0);
      expect(ledger.destroys, 0);
      final lease = aOwner.borrow();
      await b.diagnoseOwned(lease);
      lease.release();
      await b.unload();
      expect(ledger.shutdowns, 1);
      expect(ledger.destroys, 2);
      expect(bOwner.state, NativeResourceState.disposed);
    },
  );
  test(
    'last unload waits for leaked leases, blocks joins and shares Future',
    () async {
      final a = await shape();
      final lease = a.borrow();
      final close = adapter.unload();
      expect(identical(close, adapter.unload()), isTrue);
      expect(adapter.custodyDiagnostics!.leases, 1);
      expect(a.borrow, throwsStateError);
      await expectLater(another().initialize(), throwsStateError);
      expect(ledger.shutdowns, 0);
      lease.release();
      await close;
      expect(ledger.shutdowns, 1);
      await adapter.unload();
      expect(ledger.shutdowns, 1);
    },
  );
  test(
    'shutdown failure remains quarantined and cannot open new session',
    () async {
      await adapter.initialize();
      ledger.failShutdown = true;
      final close = adapter.unload();
      await expectLater(close, throwsStateError);
      expect(adapter.custodyDiagnostics!.state, NativeSessionState.quarantined);
      expect(adapter.custodyDiagnostics!.error, isA<StateError>());
      expect(identical(close, adapter.unload()), isTrue);
      await expectLater(another().initialize(), throwsStateError);
      expect(ledger.shutdowns, 1);
    },
  );
  test(
    'pending acquisition registers before callback and shutdown drains it',
    () async {
      await adapter.initialize();
      ledger.createBarrier = Completer<void>();
      final create = shape();
      await ledger.createEntered.future;
      expect(adapter.custodyDiagnostics!.pendingOperations, 1);
      final close = adapter.unload();
      expect(ledger.shutdowns, 0);
      ledger.createBarrier!.complete();
      final a = await create;
      expect(a.identity.kind, NativeResourceKind.shape);
      await close;
      expect(ledger.events.map((e) => e['event']), [
        'allocate',
        'destroy-request',
        'destroy-complete',
        'shutdown',
      ]);
    },
  );
  test(
    'successful acquisition is owned before first public continuation',
    () async {
      await shape().then((owner) {
        expect(owner.state, NativeResourceState.owned);
        expect(adapter.custodyDiagnostics!.allocations, 1);
      });
    },
  );
  test(
    'different session lease is rejected without calling native validate',
    () async {
      final a = await shape();
      final lease = a.borrow();
      final b = another(bridge: _Ledger());
      await expectLater(b.diagnoseOwned(lease), throwsStateError);
      lease.release();
    },
  );
  test(
    'explicit key coordinates distinct wrappers over same fake registry',
    () async {
      final key = Object();
      final a = another(bridge: _Wrapper(ledger), key: key),
          b = another(bridge: _Wrapper(ledger), key: key);
      await a.initialize();
      await b.initialize();
      expect(
        a.custodyDiagnostics!.sessionGeneration,
        b.custodyDiagnostics!.sessionGeneration,
      );
      await a.unload();
      expect(ledger.shutdowns, 0);
      await b.unload();
      expect(ledger.shutdowns, 1);
    },
  );
  test(
    'legacy create remains unmanaged and is not automatically destroyed',
    () async {
      final handle = await adapter.create(
        'CREATE VERTEX',
        const {},
        persistentId: 'same',
        expectedType: CADShapeType.vertex,
        transaction: KernelTransaction(
          'tx',
          'p',
          'opencascade',
          DateTime(2026),
          TransactionStatus.active,
          const [],
        ),
      );
      expect(adapter.isUnmanaged(handle), isTrue);
      expect(adapter.custodyDiagnostics!.allocations, 0);
      await adapter.unload();
      expect(ledger.destroys, 0);
      expect(ledger.shutdowns, 1);
    },
  );
  test(
    'duplicate live token is quarantined rather than minting wrong authority',
    () async {
      ledger.nextToken = 'duplicate';
      final a = await shape();
      ledger.nextToken = 'duplicate';
      await expectLater(shape(), throwsStateError);
      expect(adapter.custodyDiagnostics!.state, NativeSessionState.quarantined);
      expect(a.borrow, throwsStateError);
      await expectLater(a.dispose(), throwsStateError);
      expect(a.state, NativeResourceState.quarantined);
      expect(ledger.destroys, 0);
    },
  );
  test('metadata initialization participates in shutdown drain', () async {
    ledger.versionBarrier = Completer<void>();
    final init = adapter.initialize();
    await ledger.versionEntered.future;
    final observed = expectLater(init, throwsStateError);
    final close = adapter.unload();
    expect(ledger.shutdowns, 0);
    ledger.versionBarrier!.complete();
    await observed;
    await close;
    expect(ledger.shutdowns, 1);
  });
  test(
    'initialization failure quarantines session and removes participation',
    () async {
      ledger.failInitialize = true;
      await expectLater(adapter.initialize(), throwsStateError);
      expect(adapter.custodyDiagnostics!.state, NativeSessionState.quarantined);
      expect(adapter.custodyDiagnostics!.participants, 0);
      await expectLater(another().initialize(), throwsStateError);
    },
  );
  test(
    'initialize publishes Future before synchronous native reentrancy',
    () async {
      Future<void>? nested;
      ledger.onInitialize = () => nested = adapter.initialize();
      final init = adapter.initialize();
      expect(identical(init, nested), isTrue);
      await init;
      expect(ledger.initializations, 1);
    },
  );
  test('health diagnostics in flight prevent global shutdown', () async {
    await adapter.initialize();
    ledger.diagnosticBarrier = Completer<void>();
    final health = adapter.healthCheck();
    await ledger.diagnosticEntered.future;
    final close = adapter.unload();
    expect(ledger.shutdowns, 0);
    ledger.diagnosticBarrier!.complete();
    await health;
    await close;
    expect(ledger.shutdowns, 1);
  });
  test(
    'nonfinal unload drains own pending operations before clearing legacy maps',
    () async {
      final b = another();
      await adapter.initialize();
      await b.initialize();
      ledger.createBarrier = Completer<void>();
      final create = adapter.create(
        'CREATE VERTEX',
        const {},
        persistentId: 'same',
        expectedType: CADShapeType.vertex,
        transaction: KernelTransaction(
          'tx',
          'p',
          'opencascade',
          DateTime(2026),
          TransactionStatus.active,
          const [],
        ),
      );
      await ledger.createEntered.future;
      final close = adapter.unload();
      await expectLater(adapter.initialize(), throwsStateError);
      expect(ledger.shutdowns, 0);
      ledger.createBarrier!.complete();
      final handle = await create;
      await close;
      expect(adapter.isUnmanaged(handle), isFalse);
      expect(ledger.shutdowns, 0);
    },
  );
}
