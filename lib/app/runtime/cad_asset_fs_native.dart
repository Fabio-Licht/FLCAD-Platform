import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

final class _Result extends Struct {
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

final class CadAssetNativeError implements Exception {
  CadAssetNativeError(
    this.operation,
    this.status,
    this.win32,
    this.nt,
    this.effect, {
    this.bytes = 0,
    this.identity = const {},
    this.cleanup,
  });
  final String operation;
  final int status, win32, nt, effect;
  final int bytes;
  final Map<String, String> identity;
  final Object? cleanup;
  bool get notFound =>
      nt == 0xc0000034 || nt == 0xc000003a || win32 == 2 || win32 == 3;
  bool get collision => nt == 0xc0000035 || win32 == 183;
  bool get contention => nt == 0xc0000043 || win32 == 32 || win32 == 33;
  @override
  String toString() =>
      '$operation: native status=$status Win32=$win32 NT=0x${nt.toRadixString(16)} effect=$effect';
}

typedef _UnaryN = _Result Function(Uint64);
typedef _UnaryD = _Result Function(int);
typedef _ChildN = _Result Function(Uint64, Pointer<Uint16>, Uint32);
typedef _ChildD = _Result Function(int, Pointer<Uint16>, int);

/// Internal gateway. The DLL is intentionally process resident: never unloaded.
/// Capabilities are scoped to this object, closed explicitly and never serialized.
final class CadAssetNativeFs {
  CadAssetNativeFs(String root) : _api = _Api.instance {
    final name = root.toNativeUtf16();
    try {
      this.root = _accept(
        _api.root(name.cast(), root.length),
        'open root',
        acquired: true,
      ).object;
    } finally {
      calloc.free(name);
    }
  }
  final _Api _api;
  late final int root;
  final _owned = <int>{};
  bool _closed = false;
  bool _closing = false;
  int _sourcePins = 0;
  Completer<void>? _sourceIdle;
  Future<void>? _shutdown;
  Object? _sourceQuarantine;
  Object? get sourceQuarantine => _sourceQuarantine;
  void quarantineSource(Object cause) {
    _sourceQuarantine = cause;
    _closing = true;
  }

  /// Internal native source scope. No bytes cross this callback.
  Future<T> withSourceCapability<T>(
    int id,
    Future<T> Function(int, Pointer<Void>) operation,
  ) async {
    _live(id);
    _sourcePins++;
    try {
      return await operation(
        id,
        _api.library
            .lookup<NativeFunction<Uint32 Function()>>('caf_source_version')
            .cast(),
      );
    } finally {
      if (--_sourcePins == 0) {
        _sourceIdle?.complete();
        _sourceIdle = null;
      }
    }
  }

  Future<void> shutdown() => _shutdown ??= _drain();
  Future<void> _drain() async {
    _closing = true;
    if (_sourcePins != 0) await (_sourceIdle ??= Completer<void>()).future;
    if (_sourceQuarantine case final failure?) throw failure;
    dispose();
  }

  _Result _accept(_Result r, String action, {bool acquired = false}) {
    if (acquired && r.object != 0) _owned.add(r.object);
    if (r.version != 1 || r.status != 0) {
      Object? cleanup;
      if (acquired && r.object != 0) {
        try {
          close(r.object);
        } catch (error) {
          cleanup = error;
        }
      }
      throw CadAssetNativeError(
        action,
        r.status,
        r.win32,
        r.nt,
        r.effect,
        bytes: r.bytes,
        identity: {
          'volume': r.volume.toRadixString(16),
          'fileId': List.generate(
            16,
            (i) => r.fileId[i].toRadixString(16).padLeft(2, '0'),
          ).join(),
        },
        cleanup: cleanup,
      );
    }
    return r;
  }

  void _live(int id) {
    if (_closed || _closing || !_owned.contains(id)) {
      throw StateError('Closed filesystem capability');
    }
  }

  int child(
    int parent,
    String name, {
    bool directory = false,
    bool create = false,
    bool pinned = false,
  }) {
    _live(parent);
    final text = name.toNativeUtf16();
    try {
      final fn = directory
          ? (create
                ? (pinned ? _api.createPinnedDir : _api.createDir)
                : _api.openDir)
          : (create ? _api.createFile : _api.openFile);
      return _accept(
        fn(parent, text.cast(), name.length),
        'open/create child',
        acquired: true,
      ).object;
    } finally {
      calloc.free(text);
    }
  }

  Map<String, dynamic> info(int id, {bool digest = false}) {
    _live(id);
    var r = _accept(_api.info(id), 'info');
    if (digest) r = _accept(_api.seal(id, r.bytes), 'seal');
    String hex(Array<Uint8> a, int size) => List.generate(
      size,
      (i) => a[i].toRadixString(16).padLeft(2, '0'),
    ).join();
    return {
      'size': r.bytes,
      'volume': r.volume.toRadixString(16),
      'fileId': hex(r.fileId, 16),
      if (digest) 'sha256': hex(r.hash, 32),
    };
  }

  void write(int id, List<int> bytes) {
    _live(id);
    if (bytes.length > 65536) throw ArgumentError('Chunk exceeds 64 KiB');
    final data = calloc<Uint8>(bytes.length + 1);
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      _accept(_api.write(id, data, bytes.length), 'write');
    } finally {
      calloc.free(data);
    }
  }

  List<int> read(int id, int offset, int count) {
    _live(id);
    if (count < 0 || count > 65536) throw ArgumentError('Read exceeds 64 KiB');
    final data = calloc<Uint8>(count + 1);
    try {
      final r = _accept(_api.read(id, offset, data, count), 'read');
      return List<int>.of(data.asTypedList(r.bytes));
    } finally {
      calloc.free(data);
    }
  }

  List<({String name, bool directory, bool reparse})> entries(int id) {
    _live(id);
    final name = calloc<Uint16>(256);
    try {
      final entries = <({String name, bool directory, bool reparse})>[];
      for (var index = 0; ; index++) {
        final r = _accept(_api.entry(id, index, name, 256), 'enumerate');
        if (r.bytes == 0) return entries;
        entries.add((
          name: String.fromCharCodes(name.asTypedList(r.bytes)),
          directory: (r.reserved & 1) != 0,
          reparse: (r.reserved & 2) != 0,
        ));
      }
    } finally {
      calloc.free(name);
    }
  }

  void lock(int id) {
    _live(id);
    _accept(_api.lock(id), 'lock');
  }

  void rename(int id, int destination, String name) {
    _live(id);
    _live(destination);
    final text = name.toNativeUtf16();
    try {
      _accept(_api.rename(id, destination, text.cast(), name.length), 'rename');
    } finally {
      calloc.free(text);
    }
  }

  void close(int id) {
    if (!_owned.contains(id)) return;
    _accept(_api.close(id), 'close');
    _owned.remove(id);
  }

  void dispose() {
    if (_closed) return;
    if (_sourcePins != 0) {
      throw StateError('Native source operations are pending; await shutdown');
    }
    for (final id in _owned.toList().reversed) {
      close(id);
    }
    _closed = true;
  }
}

final class _Api {
  static final instance = _Api();
  _Api() {
    if (!Platform.isWindows || sizeOf<IntPtr>() != 8) {
      throw UnsupportedError('CAD assets require Windows x64 NTFS');
    }
    // Fixed adjacent DLL; test harness can provide an explicit absolute location.
    final location =
        Platform.environment['FLCAD_CAD_ASSET_FS_DLL'] ??
        p.join(p.dirname(Platform.resolvedExecutable), 'cad_asset_fs.dll');
    if (!p.isAbsolute(location)) {
      throw StateError('Helper path must be absolute');
    }
    library = DynamicLibrary.open(location);
    final abi = library.lookupFunction<Uint32 Function(), int Function()>(
      'caf_abi_version',
    );
    final gateway = library.lookupFunction<Uint32 Function(), int Function()>(
      'caf_gateway_version',
    );
    if (abi() != 1 || gateway() != 1 || sizeOf<_Result>() != 96) {
      throw StateError('Incompatible CAD filesystem ABI');
    }
    root = library
        .lookupFunction<
          _Result Function(Pointer<Uint16>, Uint32),
          _Result Function(Pointer<Uint16>, int)
        >('caf_open_root');
    createPinnedDir = library.lookupFunction<_ChildN, _ChildD>(
      'caf_create_pinned_dir',
    );
    openDir = library.lookupFunction<_ChildN, _ChildD>('caf_open_dir');
    createDir = library.lookupFunction<_ChildN, _ChildD>('caf_create_dir');
    openFile = library.lookupFunction<_ChildN, _ChildD>('caf_open_file');
    createFile = library.lookupFunction<_ChildN, _ChildD>('caf_create_file');
    info = library.lookupFunction<_UnaryN, _UnaryD>('caf_info');
    close = library.lookupFunction<_UnaryN, _UnaryD>('caf_close');
    lock = library.lookupFunction<_UnaryN, _UnaryD>('caf_lock');
    seal = library
        .lookupFunction<
          _Result Function(Uint64, Uint64),
          _Result Function(int, int)
        >('caf_seal');
    write = library
        .lookupFunction<
          _Result Function(Uint64, Pointer<Uint8>, Uint32),
          _Result Function(int, Pointer<Uint8>, int)
        >('caf_write');
    read = library
        .lookupFunction<
          _Result Function(Uint64, Uint64, Pointer<Uint8>, Uint32),
          _Result Function(int, int, Pointer<Uint8>, int)
        >('caf_read');
    entry = library
        .lookupFunction<
          _Result Function(Uint64, Uint32, Pointer<Uint16>, Uint32),
          _Result Function(int, int, Pointer<Uint16>, int)
        >('caf_entry');
    rename = library
        .lookupFunction<
          _Result Function(Uint64, Uint64, Pointer<Uint16>, Uint32),
          _Result Function(int, int, Pointer<Uint16>, int)
        >('caf_rename');
  }
  late final DynamicLibrary library;
  late final _Result Function(Pointer<Uint16>, int) root;
  late final _ChildD openDir, createDir, createPinnedDir, openFile, createFile;
  late final _UnaryD info, close, lock;
  late final _Result Function(int, int) seal;
  late final _Result Function(int, Pointer<Uint8>, int) write;
  late final _Result Function(int, int, Pointer<Uint8>, int) read;
  late final _Result Function(int, int, Pointer<Uint16>, int) entry, rename;
}
