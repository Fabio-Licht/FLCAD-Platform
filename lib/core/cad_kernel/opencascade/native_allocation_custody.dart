part of 'open_cascade_kernel_adapter.dart';

enum NativeResourceState { owned, transferred, quarantined, disposed }

enum NativeResourceKind { shape, mesh }

enum NativeSessionState { active, closing, closed, quarantined }

/// A process-local capability. It has no document representation or public mint.
final class NativeAllocationIdentity {
  NativeAllocationIdentity._(
    _NativeSession session,
    this.kind,
    this._token,
    this.generation,
  ) : _stamp = session.stamp;
  final _SessionStamp _stamp;
  final String _token;
  final NativeResourceKind kind;
  final int generation;
  int get sessionGeneration => _stamp.generation;

  @override
  bool operator ==(Object other) =>
      other is NativeAllocationIdentity &&
      identical(_stamp, other._stamp) &&
      kind == other.kind &&
      _token == other._token &&
      generation == other.generation;

  @override
  int get hashCode => Object.hash(_stamp, kind, _token, generation);

  @override
  String toString() => 'NativeAllocationIdentity(${kind.name}, opaque)';
}

/// Read-only diagnostics deliberately omit the destructive native token.
final class NativeCustodyDiagnostics {
  NativeCustodyDiagnostics._(_NativeSession session)
    : sessionGeneration = session.generation,
      state = session.state,
      participants = session.participants.length,
      pendingOperations = session.pending,
      allocations = session.records.length,
      leases = session.records.values.fold(0, (sum, r) => sum + r.leases),
      quarantined = session.records.values
          .where((r) => r.state == NativeResourceState.quarantined)
          .length,
      error = session.error;
  final int sessionGeneration,
      participants,
      pendingOperations,
      allocations,
      leases,
      quarantined;
  final NativeSessionState state;
  final Object? error;
}

sealed class _OwnedNativeResource {
  _OwnedNativeResource(this._record) : _authority = Object() {
    _record.authority = _authority;
  }
  final _AllocationRecord _record;
  final Object _authority;
  Future<void>? _revokedDisposal;
  NativeAllocationIdentity get identity => _record.identity;
  NativeResourceState get state => identical(_record.authority, _authority)
      ? _record.state
      : NativeResourceState.transferred;
  Object? get disposalError => _record.error;
  int get leaseCount => _record.leases;
  bool get isDisposing => _record.disposal != null;

  void _requireOwner() {
    if (!identical(_record.authority, _authority)) {
      throw StateError('Ownership was transferred');
    }
    _record.requireUsable();
  }

  Future<void> dispose() {
    if (!identical(_record.authority, _authority)) {
      return _revokedDisposal ??= Future.error(
        StateError('Ownership was transferred'),
      );
    }
    return _record.dispose();
  }
}

final class OwnedNativeShape extends _OwnedNativeResource {
  OwnedNativeShape._(super.record);
  OwnedNativeShape transfer() {
    _requireOwner();
    return OwnedNativeShape._(_record);
  }

  NativeShapeLease borrow() {
    _requireOwner();
    return NativeShapeLease._(_record);
  }
}

final class OwnedNativeMesh extends _OwnedNativeResource {
  OwnedNativeMesh._(super.record);
  OwnedNativeMesh transfer() {
    _requireOwner();
    return OwnedNativeMesh._(_record);
  }

  NativeMeshLease borrow() {
    _requireOwner();
    return NativeMeshLease._(_record);
  }
}

sealed class _NativeLease {
  _NativeLease(this._record) {
    _record.requireUsable();
    _record.leases++;
  }
  final _AllocationRecord _record;
  bool _released = false;
  NativeAllocationIdentity get identity => _record.identity;
  bool get isReleased => _released;
  void release() {
    if (_released) return;
    _released = true;
    _record.leases--;
    if (_record.leases == 0) {
      _record.drained?.complete();
      _record.drained = null;
    }
  }

  void _check(_NativeSession session) {
    if (_released ||
        !identical(session.stamp, _record.identity._stamp) ||
        session.state == NativeSessionState.closed ||
        _record.state != NativeResourceState.owned) {
      throw StateError(
        'Lease is released, invalid, or belongs to another session',
      );
    }
  }
}

final class NativeShapeLease extends _NativeLease {
  NativeShapeLease._(super.record);
}

final class NativeMeshLease extends _NativeLease {
  NativeMeshLease._(super.record);
}

final class _AllocationRecord {
  _AllocationRecord(this.identity, this.destroy, this.session);
  final NativeAllocationIdentity identity;
  Future<void> Function(String)? destroy;
  _NativeSession? session;
  Object? authority;
  NativeResourceState state = NativeResourceState.owned;
  Object? error;
  int leases = 0;
  Completer<void>? drained;
  Future<void>? disposal;

  void requireUsable() {
    if (state != NativeResourceState.owned ||
        disposal != null ||
        session?.state != NativeSessionState.active) {
      throw StateError(
        'Allocation is not available for new ownership or leases',
      );
    }
  }

  Future<void> dispose() {
    if (disposal case final existing?) return existing;
    final completion = Completer<void>();
    disposal = completion.future;
    // Publish disposal before invoking any asynchronous or reentrant native work.
    unawaited(_dispose(completion));
    return disposal!;
  }

  Future<void> _dispose(Completer<void> completion) async {
    try {
      if (leases != 0) {
        drained ??= Completer<void>();
        await drained!.future;
      }
      final activeSession = session!;
      if (activeSession.state == NativeSessionState.quarantined) {
        throw StateError(
          'Registry is quarantined; destructive authority is suspended',
        );
      }
      await destroy!(identity._token);
      state = NativeResourceState.disposed;
      activeSession.records.remove((identity.kind, identity._token));
      destroy = null;
      session = null;
      completion.complete();
    } catch (failure, stack) {
      error = failure;
      state = NativeResourceState.quarantined;
      completion.completeError(failure, stack);
    }
  }
}

/// All adapters for one actual registry share this coordinator. Real FFI calls
/// are confined to the root isolate (see OpenCascadeFFI).
final class _NativeSessions {
  static final sessions = Map<Object, _NativeSession>.identity();
  static final libraryKeys = <int, Object>{};
  static int generation = 0;

  static _NativeParticipant join(OpenCascadeNativeBridge bridge, Object? key) {
    final Object resolved;
    if (bridge is OpenCascadeFFI) {
      if (key != null) {
        throw ArgumentError('FFI registry identity cannot be overridden');
      }
      resolved = libraryKeys.putIfAbsent(
        bridge.library.handle.address,
        Object.new,
      );
    } else {
      resolved = key ?? bridge;
    }
    final session = sessions.putIfAbsent(
      resolved,
      () => _NativeSession(resolved, bridge, ++generation),
    );
    if (session.state != NativeSessionState.active) {
      throw StateError('Native registry is closing or quarantined');
    }
    final participant = _NativeParticipant(session);
    session.participants.add(participant);
    return participant;
  }
}

final class _SessionStamp {
  _SessionStamp(this.generation);
  final int generation;
}

final class _NativeSession {
  _NativeSession(this.key, this.bridge, this.generation)
    : stamp = _SessionStamp(generation);
  final _SessionStamp stamp;
  final Object key;
  final OpenCascadeNativeBridge bridge;
  final int generation;
  final participants = <_NativeParticipant>{};
  final records = <(NativeResourceKind, String), _AllocationRecord>{};
  final unmanaged = <(NativeResourceKind, String)>{};
  int nextAllocation = 0;
  int pending = 0;
  NativeSessionState state = NativeSessionState.active;
  Object? error;
  Future<void>? initialization;
  Future<void>? shutdown;
  Completer<void>? idle;

  Future<void> initialize() {
    if (initialization case final existing?) return existing;
    final completion = Completer<void>();
    initialization = completion.future;
    unawaited(
      Future.sync(
        bridge.initialize,
      ).then(completion.complete, onError: completion.completeError),
    );
    return completion.future;
  }

  _AllocationRecord register(
    NativeResourceKind kind,
    String token,
    Future<void> Function(String) destroy,
  ) {
    // An acquisition admitted while active must register even during closing.
    if (token.isEmpty ||
        records.containsKey((kind, token)) ||
        unmanaged.contains((kind, token))) {
      state = NativeSessionState.quarantined;
      error = StateError(
        'Native allocator returned an empty or live duplicate token',
      );
      throw error!;
    }
    final record = _AllocationRecord(
      NativeAllocationIdentity._(this, kind, token, ++nextAllocation),
      destroy,
      this,
    );
    records[(kind, token)] = record;
    return record;
  }

  Future<void> close() {
    if (shutdown case final existing?) return existing;
    final completion = Completer<void>();
    shutdown = completion.future;
    if (state == NativeSessionState.active) state = NativeSessionState.closing;
    unawaited(_close(completion));
    return shutdown!;
  }

  Future<void> _close(Completer<void> completion) async {
    try {
      await initialize();
      if (pending != 0) {
        idle ??= Completer<void>();
        await idle!.future;
      }
      if (state == NativeSessionState.quarantined) throw error!;
      await Future.wait(records.values.toList().map((r) => r.dispose()));
      await bridge.shutdown();
      state = NativeSessionState.closed;
      _NativeSessions.sessions.remove(key);
      completion.complete();
    } catch (failure, stack) {
      state = NativeSessionState.quarantined;
      error = failure;
      completion.completeError(failure, stack);
    }
  }
}

final class _NativeParticipant {
  _NativeParticipant(this.session);
  final _NativeSession session;
  bool closing = false;
  Future<void>? closure;
  int pending = 0;
  Completer<void>? idle;

  Future<T> run<T>(Future<T> Function() operation) {
    if (closing || session.state != NativeSessionState.active) {
      return Future.error(StateError('Native participation is closing'));
    }
    session.pending++;
    pending++;
    return _run(operation);
  }

  Future<T> _run<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } finally {
      session.pending--;
      pending--;
      if (pending == 0) {
        idle?.complete();
        idle = null;
      }
      if (session.pending == 0) {
        session.idle?.complete();
        session.idle = null;
      }
    }
  }

  Future<void> close() {
    if (closure case final existing?) return existing;
    closing = true;
    session.participants.remove(this);
    return closure = session.participants.isEmpty
        ? session.close()
        : pending == 0
        ? Future.value()
        : (idle ??= Completer<void>()).future;
  }
}
