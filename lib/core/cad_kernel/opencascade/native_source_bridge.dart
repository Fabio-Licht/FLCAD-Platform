part of 'open_cascade_kernel_adapter.dart';

final class _SourceFsResult extends Struct {
  @Uint32()
  external int version;
  @Uint32()
  external int status;
  @Uint32()
  external int win32;
  @Uint32()
  external int nt;
  @Uint32()
  external int effect;
  @Uint32()
  external int reserved;
  @Uint64()
  external int object;
  @Uint64()
  external int bytes;
  @Uint64()
  external int volume;
  @Array(16)
  external Array<Uint8> fileId;
  @Array(32)
  external Array<Uint8> hash;
}

final class _SourceOccResult extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int version;
  @Uint32()
  external int status;
  @Uint32()
  external int phase;
  @Uint32()
  external int domain;
  @Int32()
  external int code;
  @Uint64()
  external int detail;
  @Uint64()
  external int bytes;
  @Uint32()
  external int countValid;
  @Uint32()
  external int published;
  @Uint32()
  external int kind;
  @Uint32()
  external int reserved;
  @Uint64()
  external int vertices;
  @Uint64()
  external int triangles;
  @Array(6)
  external Array<Double> bounds;
  @Array(64)
  external Array<Uint8> token;
  @Array(64)
  external Array<Uint8> fingerprint;
  @Array(32)
  external Array<Uint8> type;
  @Array(256)
  external Array<Uint8> message;
}

final class _SourceBridgeResult extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int version;
  @Uint32()
  external int status;
  @Uint32()
  external int phase;
  @Uint64()
  external int operation;
  external _SourceFsResult filesystem;
  external _SourceOccResult native;
  @Uint32()
  external int held;
  @Uint32()
  external int compensation;
  @Int32()
  external int cleanupCode;
  @Array(256)
  external Array<Uint8> cleanupMessage;
}

typedef _SourceActionN =
    Int32 Function(Uint64, Pointer<_SourceBridgeResult>, Uint32);
typedef _SourceActionD = int Function(int, Pointer<_SourceBridgeResult>, int);

final class _SourceBridgeApi {
  static final _instances = <String, _SourceBridgeApi>{};
  factory _SourceBridgeApi(String path) =>
      _instances.putIfAbsent(path, () => _SourceBridgeApi._(path));
  _SourceBridgeApi._(this.path) : library = DynamicLibrary.open(path) {
    if (library.lookupFunction<Uint32 Function(), int Function()>(
          'cob_version',
        )() !=
        1) {
      throw StateError('Incompatible native source bridge ABI');
    }
    if (library.lookupFunction<Uint32 Function(), int Function()>(
          'cob_result_size_v1',
        )() !=
        sizeOf<_SourceBridgeResult>()) {
      throw StateError('Incompatible native source result layout');
    }
    begin = library
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            Pointer<Void>,
            Uint64,
            Pointer<_SourceFsResult>,
            Uint32,
            Uint32,
            Pointer<_SourceBridgeResult>,
            Uint32,
          ),
          int Function(
            Pointer<Void>,
            Pointer<Void>,
            int,
            Pointer<_SourceFsResult>,
            int,
            int,
            Pointer<_SourceBridgeResult>,
            int,
          )
        >('cob_begin_v1');
    run = library.lookupFunction<_SourceActionN, _SourceActionD>('cob_run_v1');
    snapshot = library.lookupFunction<_SourceActionN, _SourceActionD>(
      'cob_snapshot_v1',
    );
    close = library.lookupFunction<_SourceActionN, _SourceActionD>(
      'cob_close_v1',
    );
    cancel = library.lookupFunction<Int32 Function(Uint64), int Function(int)>(
      'cob_cancel_v1',
    );
    adopt = library.lookupFunction<Int32 Function(Uint64), int Function(int)>(
      'cob_adopt_v1',
    );
  }
  final String path;
  // Process resident. Operations also retain independent native CAF/OCCT refs.
  final DynamicLibrary library;
  late final int Function(
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_SourceFsResult>,
    int,
    int,
    Pointer<_SourceBridgeResult>,
    int,
  )
  begin;
  late final _SourceActionD run, snapshot, close;
  late final int Function(int) cancel, adopt;
}

Future<int> _sourceWorker(int address, int operation) => Isolate.run(() {
  final run = Pointer<NativeFunction<_SourceActionN>>.fromAddress(
    address,
  ).asFunction<_SourceActionD>();
  final out = calloc<_SourceBridgeResult>();
  try {
    return run(operation, out, sizeOf<_SourceBridgeResult>());
  } finally {
    calloc.free(out);
  }
});

final class NativeSourceCancellation {
  bool _revoked = false;
  bool _used = false;
  final _admitted = Completer<void>();
  Future<void> get admitted => _admitted.future;
  int Function()? _cancel;
  bool get isRevoked => _revoked;
  void revoke() {
    _revoked = true;
    _cancel?.call();
  }
}

final class NativeSourceFailure implements Exception {
  NativeSourceFailure(
    this.bridgeStatus,
    this.nativeStatus,
    this.phase,
    this.domain,
    this.code,
    this.detail,
    this.bytes,
    this.message, {
    this.compensated = false,
    this.operation = 0,
  });
  final int bridgeStatus,
      nativeStatus,
      phase,
      domain,
      code,
      detail,
      bytes,
      operation;
  final String message;
  final bool compensated;
  Map<String, Object?> filesystem = const {};
  int bridgePhase = 0;
  int cleanupCode = 0;
  String cleanupMessage = '';

  @override
  String toString() =>
      'Native source failure: bridge=$bridgeStatus native=$nativeStatus phase=$phase domain=$domain code=$code: $message';
}

final class NativeSourceResource {
  NativeSourceResource._(this.shape, this.mesh);
  final OwnedNativeShape? shape;
  final OwnedNativeMesh? mesh;
  Future<void> dispose() => shape?.dispose() ?? mesh!.dispose();
}

final class NativeSourcePublicationFailure implements Exception {
  NativeSourcePublicationFailure(this.resource, this.failure);
  final NativeSourceResource resource;
  final NativeSourceFailure failure;
}

final class NativeSourceNotificationFailure implements Exception {
  NativeSourceNotificationFailure(this.resource, this.cause, this.stack);
  final NativeSourceResource resource;
  final Object cause;
  final StackTrace stack;
}

String _sourceText(Array<Uint8> data, int capacity) {
  final values = <int>[];
  for (var i = 0; i < capacity && data[i] != 0; i++) {
    values.add(data[i]);
  }
  return String.fromCharCodes(values);
}

NativeSourceFailure _sourceError(
  int code,
  _SourceBridgeResult r, {
  bool compensated = false,
}) {
  final failure = NativeSourceFailure(
    code,
    r.native.status,
    r.native.phase,
    r.native.domain,
    r.native.code,
    r.native.detail,
    r.native.bytes,
    _sourceText(r.native.message, 256),
    compensated: compensated,
    operation: r.operation,
  );
  String hex(Array<Uint8> a, int size) =>
      List.generate(size, (i) => a[i].toRadixString(16).padLeft(2, '0')).join();
  failure.filesystem = {
    'status': r.filesystem.status,
    'win32': r.filesystem.win32,
    'nt': r.filesystem.nt,
    'effect': r.filesystem.effect,
    'size': r.filesystem.bytes,
    'volume': r.filesystem.volume.toRadixString(16),
    'fileId': hex(r.filesystem.fileId, 16),
    'sha256': hex(r.filesystem.hash, 32),
  };
  failure.bridgePhase = r.phase;
  failure.cleanupCode = r.cleanupCode;
  failure.cleanupMessage = _sourceText(r.cleanupMessage, 256);
  return failure;
}

final class NativeSourceRecoveryFailure implements Exception {
  NativeSourceRecoveryFailure(
    this.cause,
    this.stack,
    this.cleanup,
    this.resource,
  );
  final Object? cause;
  final StackTrace? stack;
  final NativeSourceFailure cleanup;
  final NativeSourceResource? resource;
}

final class NativeSourceEffect {
  NativeSourceEffect(this.compensated, this.quarantined, this.failure);
  final bool compensated, quarantined;
  final Object? failure;
}

extension NativeSourceBridge on OpenCascadeKernelAdapter {
  /// Foundation entry only. No existing import command calls this method.
  Future<NativeSourceResource> readOwnedAsset({
    required CadAssetNativeFs filesystem,
    required int file,
    required Map<String, dynamic> expected,
    required NativeResourceKind kind,
    required NativeSourceCancellation cancellation,
    String? bridgePath,
    void Function(NativeSourceResource)? onCaptured,
    bool debugRejectCustody = false,
  }) async {
    final snapshot = Map<String, dynamic>.of(expected);
    await initialize();
    final participant = _participant!;
    final occ = _nativeBridge;
    if (occ is! OpenCascadeFFI || !Platform.isWindows) {
      throw UnsupportedError('Native source bridge requires Windows OCCT FFI');
    }
    final path =
        bridgePath ??
        '${File(Platform.resolvedExecutable).parent.path}\\cad_occ_bridge.dll';
    final api = _SourceBridgeApi(path);
    return participant.run(
      () => filesystem.withSourceCapability(file, (cap, anchor) async {
        if (cancellation._used || cancellation._cancel != null) {
          throw StateError('Cancellation already belongs to an operation');
        }
        if (cancellation.isRevoked) throw StateError('Native source revoked');
        cancellation._used = true;
        final out = calloc<_SourceBridgeResult>();
        final spec = calloc<_SourceFsResult>();
        int operation = 0;
        _AllocationRecord? registered;
        bool adopted = false;
        Object? primary;
        StackTrace? primaryStack;
        NativeSourceResource? captured;

        try {
          spec.ref.version = 1;
          spec.ref.bytes = snapshot['size'] as int;
          spec.ref.volume = int.parse(snapshot['volume'] as String, radix: 16);
          void hex(String value, Array<Uint8> target, int count) {
            if (value.length != count * 2 ||
                !RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
              throw ArgumentError('Invalid sealed identity/hash');
            }
            for (var i = 0; i < count; i++) {
              target[i] = int.parse(
                value.substring(i * 2, i * 2 + 2),
                radix: 16,
              );
            }
          }

          hex(snapshot['fileId'] as String, spec.ref.fileId, 16);
          hex(snapshot['sha256'] as String, spec.ref.hash, 32);
          final code = api.begin(
            anchor,
            occ.library
                .lookup<NativeFunction<Uint32 Function()>>(
                  'flcad_occ_source_version',
                )
                .cast(),
            cap,
            spec,
            sizeOf<_SourceFsResult>(),
            kind == NativeResourceKind.shape ? 1 : 2,
            out,
            sizeOf<_SourceBridgeResult>(),
          );
          operation = out.ref.operation;
          if (code != 0) throw _sourceError(code, out.ref);
          cancellation._cancel = () => api.cancel(operation);
          cancellation._admitted.complete();
          if (cancellation.isRevoked) api.cancel(operation);
          final result = await _sourceWorker(
            api.library
                .lookup<NativeFunction<_SourceActionN>>('cob_run_v1')
                .address,
            operation,
          );
          if (api.snapshot(operation, out, sizeOf<_SourceBridgeResult>()) !=
              0) {
            throw StateError('Source result is unavailable; escrow retained');
          }
          if (out.ref.native.published == 0) {
            throw _sourceError(result, out.ref);
          }
          // No notification/await between token decode, registration and adoption.
          final token = _sourceText(out.ref.native.token, 64);
          assert(() {
            if (debugRejectCustody) {
              throw StateError('Injected custody admission failure');
            }
            return true;
          }());
          registered = participant.session.register(
            kind,
            token,
            kind == NativeResourceKind.shape
                ? occ.destroyShape
                : occ.destroyMesh,
          );
          final resource = kind == NativeResourceKind.shape
              ? NativeSourceResource._(OwnedNativeShape._(registered), null)
              : NativeSourceResource._(null, OwnedNativeMesh._(registered));
          if (api.adopt(operation) != 0) {
            throw StateError('Native escrow adoption failed');
          }
          adopted = true;
          captured = resource;
          if (result != 0 || out.ref.native.status != 0) {
            throw NativeSourcePublicationFailure(
              resource,
              _sourceError(result, out.ref),
            );
          }
          if (cancellation.isRevoked) {
            await resource.dispose();
            throw StateError('Native source revoked after publication');
          }
          try {
            onCaptured?.call(resource);
          } catch (error, stack) {
            throw NativeSourceNotificationFailure(resource, error, stack);
          }
          return resource;
        } catch (error, stack) {
          primary = error;
          primaryStack = stack;
          if (error is NativeSourceFailure) {
            _sourceEffects.add(NativeSourceEffect(false, true, error));
          }
          rethrow;
        } finally {
          cancellation._cancel = null;
          if (!adopted && registered != null) {
            participant.session.records.remove((
              registered.identity.kind,
              registered.identity._token,
            ));
          }
          try {
            if (operation != 0) {
              final cleanup = api.close(
                operation,
                out,
                sizeOf<_SourceBridgeResult>(),
              );
              _sourceEffects.add(
                NativeSourceEffect(
                  out.ref.compensation != 0,
                  cleanup != 0,
                  primary,
                ),
              );
              if (cleanup != 0) {
                final failure = NativeSourceRecoveryFailure(
                  primary,
                  primaryStack,
                  _sourceError(cleanup, out.ref),
                  captured,
                );
                participant.session.state = NativeSessionState.quarantined;
                participant.session.error = failure;
                filesystem.quarantineSource(failure);
                throw failure;
              }
            }
          } finally {
            calloc.free(spec);
            calloc.free(out);
          }
        }
      }),
    );
  }
}
