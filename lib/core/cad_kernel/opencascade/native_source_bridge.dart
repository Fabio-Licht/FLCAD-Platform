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

final class _StreamOccResult extends Struct {
  @Uint32()
  external int version;
  @Uint32()
  external int status;
  @Int32()
  external int consumerCode;
  @Uint32()
  external int acceptedCountValid;
  @Uint64()
  external int bytesAccepted;
  @Uint64()
  external int triangles;
  @Array(256)
  external Array<Uint8> message;
}

final class _StreamBridgeResult extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int version;
  @Uint32()
  external int status;
  @Uint32()
  external int phase;
  external _SourceFsResult filesystem;
  external _StreamOccResult native;
}

typedef _SourceActionN =
    Int32 Function(Uint64, Pointer<_SourceBridgeResult>, Uint32);
typedef _SourceActionD = int Function(int, Pointer<_SourceBridgeResult>, int);
typedef _ShapeWriteN =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Uint64,
      Pointer<Utf8>,
      Uint32,
      Pointer<_StreamBridgeResult>,
      Uint32,
    );
typedef _ShapeWriteD =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<_StreamBridgeResult>,
      int,
    );

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
    if (library.lookupFunction<Uint32 Function(), int Function()>(
          'cob_stream_result_size_v1',
        )() !=
        sizeOf<_StreamBridgeResult>()) {
      throw StateError('Incompatible native stream result layout');
    }
    shapeWrite = library.lookupFunction<_ShapeWriteN, _ShapeWriteD>(
      'cob_shape_write_v1',
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
  late final _ShapeWriteD shapeWrite;
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

final class NativeGeometryDescriptor {
  NativeGeometryDescriptor._({
    required this.kind,
    required this.resourceType,
    required this.fingerprint,
    required this.vertices,
    required this.triangles,
    required List<double> bounds,
    required this.hasNormals,
  }) : bounds = List.unmodifiable(bounds);
  final NativeResourceKind kind;
  final String resourceType, fingerprint;
  final int vertices, triangles;
  final List<double> bounds;
  final bool hasNormals;
  Map<String, dynamic> toManagedMetadata() => {
    'schema': 'flcad.native-geometry-descriptor',
    'version': 1,
    'kind': kind.name,
    'type': resourceType,
    'fingerprint': fingerprint,
    'vertices': vertices,
    'triangles': triangles,
    'bounds': bounds,
    'hasNormals': hasNormals,
  };
}

/// Private-token ownership plus immutable native facts. A callback receives a
/// custody lease only for its synchronous work; neither the token nor a lease
/// is serializable or retained by the renderer.
final class ManagedNativeShape {
  ManagedNativeShape._(this._owner, this.descriptor);
  final OwnedNativeShape _owner;
  final NativeGeometryDescriptor descriptor;
  bool _transferred = false;
  Future<T> withLease<T>(Future<T> Function(NativeShapeLease) body) async {
    if (_transferred) throw StateError('Managed shape was transferred');
    final lease = _owner.borrow();
    try {
      return await body(lease);
    } finally {
      lease.release();
    }
  }

  ManagedNativeShape transfer() {
    if (_transferred) throw StateError('Managed shape was transferred');
    _transferred = true;
    return ManagedNativeShape._(_owner.transfer(), descriptor);
  }

  bool get _canTransfer => !_transferred;

  Future<void> dispose() async {
    if (_transferred) return;
    _transferred = true;
    await _owner.dispose();
  }
}

final class ManagedNativeDisplayMesh {
  ManagedNativeDisplayMesh._(this._owner, this.descriptor);
  final OwnedNativeMesh _owner;
  final NativeGeometryDescriptor descriptor;
  bool _transferred = false;
  Future<T> withLease<T>(Future<T> Function(NativeMeshLease) body) async {
    if (_transferred) throw StateError('Managed display mesh was transferred');
    final lease = _owner.borrow();
    try {
      return await body(lease);
    } finally {
      lease.release();
    }
  }

  ManagedNativeDisplayMesh transfer() {
    if (_transferred) throw StateError('Managed display mesh was transferred');
    _transferred = true;
    return ManagedNativeDisplayMesh._(_owner.transfer(), descriptor);
  }

  bool get _canTransfer => !_transferred;

  Future<void> dispose() async {
    if (_transferred) return;
    _transferred = true;
    await _owner.dispose();
  }

  /// Copies render data while the custody lease is live. The scene receives no
  /// token or handle; normals are reconstructed deterministically by the
  /// existing canvas normal pipeline from nodes and triangle indices.
  Future<Map<String, dynamic>> prepareSceneGeometry(
    OpenCascadeKernelAdapter kernel,
  ) => withLease((lease) async {
    final bridge = kernel._nativeBridge;
    if (bridge is! OpenCascadeFFI) {
      throw UnsupportedError(
        'Managed mesh projection requires OpenCascade FFI',
      );
    }
    final geometry = await bridge.inspectMesh(
      lease._record.identity._token,
      vertexCount: descriptor.vertices,
      triangleCount: descriptor.triangles,
    );
    if (geometry.nodes.length != descriptor.vertices * 3 ||
        geometry.triangles.length != descriptor.triangles * 3 ||
        geometry.nodes.any((value) => !value.isFinite) ||
        geometry.triangles.any(
          (value) => value < 0 || value >= descriptor.vertices,
        )) {
      throw StateError('Native mesh does not match its published descriptor');
    }
    return {
      'nodes': List<double>.unmodifiable(geometry.nodes),
      'triangles': List<int>.unmodifiable(geometry.triangles),
      'bounds': descriptor.bounds,
      'normalsOrigin': 'calculatedByAdapter',
      'hasNativeVertexNormals': false,
    };
  });
}

final class ManagedEntityGeometry {
  ManagedEntityGeometry(this.shape, this.displayMesh);
  final ManagedNativeShape shape;
  final ManagedNativeDisplayMesh displayMesh;
  bool _transferred = false;
  ManagedEntityGeometry transfer() {
    if (_transferred) throw StateError('Managed geometry was transferred');
    // Both checks occur before either authority is revoked. The two transfer
    // calls are synchronous and contain no callback, await or native effect.
    if (!shape._canTransfer || !displayMesh._canTransfer) {
      throw StateError('Managed geometry has an unavailable component');
    }
    final nextShape = shape.transfer();
    final nextMesh = displayMesh.transfer();
    _transferred = true;
    return ManagedEntityGeometry(nextShape, nextMesh);
  }

  Future<void> dispose() async {
    if (_transferred) return;
    _transferred = true;
    await Future.wait([shape.dispose(), displayMesh.dispose()]);
  }
}

final class NativeSourceResource {
  NativeSourceResource._(this.shape, this.mesh, this.descriptor);
  final OwnedNativeShape? shape;
  final OwnedNativeMesh? mesh;
  final NativeGeometryDescriptor descriptor;
  bool _claimed = false;
  ManagedNativeShape claimShape() {
    if (_claimed || shape == null) {
      throw StateError('Shape resource unavailable');
    }
    _claimed = true;
    return ManagedNativeShape._(shape!.transfer(), descriptor);
  }

  ManagedNativeDisplayMesh claimMesh() {
    if (_claimed || mesh == null) {
      throw StateError('Mesh resource unavailable');
    }
    _claimed = true;
    return ManagedNativeDisplayMesh._(mesh!.transfer(), descriptor);
  }

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
  /// Internal 2B2A2 staging primitive. It accepts only a live custody lease and
  /// a CAF writer lease; no pathname or byte callback crosses Dart.
  Future<Map<String, dynamic>> streamShapeIntoStaging({
    required CadAssetNativeFs filesystem,
    required int file,
    required NativeShapeLease shape,
    required bool displayStl,
    String? bridgePath,
  }) async {
    await initialize();
    final participant = _participant!;
    final occ = _nativeBridge;
    if (occ is! OpenCascadeFFI || !Platform.isWindows) {
      throw UnsupportedError('Native staging stream requires Windows OCCT FFI');
    }
    shape._check(participant.session);
    final api = _SourceBridgeApi(
      bridgePath ??
          '${File(Platform.resolvedExecutable).parent.path}\\cad_occ_bridge.dll',
    );
    return participant.run(
      () => filesystem.withWriterCapability(file, (writer, cafAnchor) async {
        shape._check(participant.session);
        final token = shape._record.identity._token.toNativeUtf8();
        final out = calloc<_StreamBridgeResult>();
        try {
          final status = api.shapeWrite(
            cafAnchor,
            occ.library
                .lookup<NativeFunction<Uint32 Function()>>(
                  displayStl
                      ? 'flcad_occ_mesh_stream_version'
                      : 'flcad_occ_brep_stream_version',
                )
                .cast(),
            writer,
            token,
            displayStl ? 2 : 1,
            out,
            sizeOf<_StreamBridgeResult>(),
          );
          if (status != 0 || out.ref.native.status != 0) {
            throw NativeSourceFailure(
              status,
              out.ref.native.status,
              out.ref.phase,
              0x434146,
              out.ref.filesystem.status,
              (out.ref.filesystem.win32 << 32) | out.ref.filesystem.nt,
              out.ref.native.bytesAccepted,
              _sourceText(out.ref.native.message, 256),
            );
          }
        } finally {
          calloc.free(token);
          calloc.free(out);
        }
      }),
    );
  }

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
          final native = out.ref.native;
          final descriptor = NativeGeometryDescriptor._(
            kind: kind,
            resourceType: _sourceText(native.type, 32),
            fingerprint: _sourceText(native.fingerprint, 64),
            vertices: native.vertices,
            triangles: native.triangles,
            bounds: List<double>.generate(6, (i) => native.bounds[i]),
            // ABI v1 does not define a normals-validity flag. Do not infer it
            // from countValid; a v2 descriptor must add that fact explicitly.
            hasNormals: false,
          );
          if (descriptor.resourceType.isEmpty ||
              descriptor.fingerprint.isEmpty ||
              descriptor.vertices < 0 ||
              descriptor.triangles < 0 ||
              descriptor.bounds.any((value) => !value.isFinite)) {
            throw StateError(
              'Native publication returned an invalid descriptor',
            );
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
              ? NativeSourceResource._(
                  OwnedNativeShape._(registered),
                  null,
                  descriptor,
                )
              : NativeSourceResource._(
                  null,
                  OwnedNativeMesh._(registered),
                  descriptor,
                );
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
