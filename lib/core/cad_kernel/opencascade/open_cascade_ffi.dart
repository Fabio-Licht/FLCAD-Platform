import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import '../io/kernel_io_models.dart';
import '../models/kernel_models.dart';
import 'open_cascade_bridge.dart';

typedef _InitNative = Int32 Function(Pointer<Utf8>, IntPtr);
typedef _InitDart = int Function(Pointer<Utf8>, int);
typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
typedef _DestroyNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, IntPtr);
typedef _DestroyDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _StringNative = Pointer<Utf8> Function();
typedef _StringDart = Pointer<Utf8> Function();
typedef _VertexNative =
    Int32 Function(
      Double,
      Double,
      Double,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _VertexDart =
    int Function(
      double,
      double,
      double,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _TwoTokenNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _TwoTokenDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _OneTokenNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _OneTokenDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _ShellNative =
    Int32 Function(
      Pointer<Utf8>,
      Double,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _ShellDart =
    int Function(
      Pointer<Utf8>,
      double,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _ExtrudeNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Double>,
      Int32,
      Double,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _ExtrudeDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Double>,
      int,
      double,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _PlaneNative =
    Int32 Function(
      Pointer<Double>,
      Pointer<Double>,
      Double,
      Double,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _PlaneDart =
    int Function(
      Pointer<Double>,
      Pointer<Double>,
      double,
      double,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _PlanarFaceNative =
    Int32 Function(
      Pointer<Double>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _PlanarFaceDart =
    int Function(
      Pointer<Double>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _RadialNative =
    Int32 Function(
      Pointer<Double>,
      Pointer<Double>,
      Double,
      Double,
      Double,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _RadialDart =
    int Function(
      Pointer<Double>,
      Pointer<Double>,
      double,
      double,
      double,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _SphereNative =
    Int32 Function(
      Pointer<Double>,
      Double,
      Double,
      Double,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _SphereDart =
    int Function(
      Pointer<Double>,
      double,
      double,
      double,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _TorusNative =
    Int32 Function(
      Pointer<Double>,
      Pointer<Double>,
      Double,
      Double,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _TorusDart =
    int Function(
      Pointer<Double>,
      Pointer<Double>,
      double,
      double,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _ImportNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _ImportDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _ExportNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _ExportDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
    );
typedef _InspectNative =
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>, IntPtr, Pointer<Utf8>, IntPtr);
typedef _InspectDart =
    int Function(Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Utf8>, int);
typedef _IntersectNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _IntersectDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _SurfaceQualityNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Double>,
      Int32,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _SurfaceQualityDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Double>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );
typedef _MeshNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Double,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _MeshDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      double,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Utf8>,
      int,
    );
typedef _ImportStlNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Double>,
      Pointer<Int32>,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _ImportStlDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Double>,
      Pointer<Int32>,
      Pointer<Utf8>,
      int,
    );
typedef _MeshGeometryNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Double>,
      IntPtr,
      Pointer<Int32>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _MeshGeometryDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Double>,
      int,
      Pointer<Int32>,
      int,
      Pointer<Utf8>,
      int,
    );

typedef _SurfaceOperationNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Double>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _SurfaceOperationDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Double>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );

typedef _TransformShapeNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Double>,
      Int32,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
      Pointer<Utf8>,
      IntPtr,
    );
typedef _TransformShapeDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Double>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      int,
    );

class OpenCascadeFFI
    implements
        OpenCascadeNativeBridge,
        OpenCascadeMeshNativeBridge,
        OpenCascadeSurfaceNativeBridge {
  OpenCascadeFFI._(this.library)
    : _initialize = library.lookupFunction<_InitNative, _InitDart>(
        'flcad_occ_initialize',
      ),
      _shutdown = library.lookupFunction<_VoidNative, _VoidDart>(
        'flcad_occ_shutdown',
      ),
      _version = library.lookupFunction<_StringNative, _StringDart>(
        'flcad_occ_version',
      ),
      _capabilities = library.lookupFunction<_StringNative, _StringDart>(
        'flcad_occ_capabilities',
      ),
      _diagnostics = library.lookupFunction<_StringNative, _StringDart>(
        'flcad_occ_diagnostics',
      );
  final DynamicLibrary library;
  final _InitDart _initialize;
  final _VoidDart _shutdown;
  final _StringDart _version, _capabilities, _diagnostics;
  static String defaultLibraryName() => Platform.isWindows
      ? 'flcad_opencascade.dll'
      : Platform.isMacOS
      ? 'libflcad_opencascade.dylib'
      : 'libflcad_opencascade.so';
  static OpenCascadeFFI load({String? path}) {
    final resolved = path ?? defaultLibraryName();
    try {
      return OpenCascadeFFI._(DynamicLibrary.open(resolved));
    } catch (error) {
      throw StateError(
        'OpenCascade DLL is unavailable ($resolved). Build the native target '
        'and ensure the OCCT runtime DLLs are beside the Flutter executable. '
        'Loader error: $error',
      );
    }
  }

  static OpenCascadeFFI? tryLoad({String? path}) {
    try {
      return load(path: path);
    } catch (_) {
      return null;
    }
  }

  static OpenCascadeNativeBridge loadOrUnavailable({String? path}) {
    try {
      return load(path: path);
    } catch (error) {
      return UnavailableOpenCascadeBridge(error.toString());
    }
  }

  @override
  Future<void> initialize() async {
    final error = calloc<Uint8>(4096).cast<Utf8>();
    try {
      if (_initialize(error, 4096) != 1) throw StateError(error.toDartString());
    } finally {
      calloc.free(error);
    }
  }

  @override
  Future<void> shutdown() async => _shutdown();
  @override
  Future<String> version() async => _version().toDartString();
  @override
  Future<Set<String>> capabilities() async => _capabilities()
      .toDartString()
      .split(',')
      .where((e) => e.isNotEmpty)
      .toSet();
  @override
  Future<Map<String, dynamic>> diagnostics() async => Map<String, dynamic>.from(
    jsonDecode(_diagnostics().toDartString()) as Map,
  );
  _Buffers _buffers() => _Buffers();
  OpenCascadeNativeShape _shape(_Buffers b, CADShapeType type) =>
      OpenCascadeNativeShape(
        token: b.token.toDartString(),
        type: type,
        fingerprint: b.fingerprint.toDartString(),
        metadata: {'backend': 'OpenCascade', 'topoDSType': type.name},
      );
  List<double> _vector(Object? value, String name) {
    final list = (value as List?)?.cast<num>();
    if (list == null || list.length != 3) {
      throw ArgumentError('$name requires three coordinates');
    }
    return list.map((e) => e.toDouble()).toList();
  }

  Pointer<Double> _nativeVector(List<double> v) {
    final p = calloc<Double>(3);
    for (var i = 0; i < 3; i++) {
      p[i] = v[i];
    }
    return p;
  }

  @override
  Future<OpenCascadeNativeShape> createShape(
    String operation,
    Map<String, dynamic> p,
    CADShapeType expectedType,
  ) async {
    final b = _buffers();
    try {
      int ok;
      switch (operation) {
        case 'CREATE VERTEX':
          final fn = library.lookupFunction<_VertexNative, _VertexDart>(
            'flcad_occ_create_vertex',
          );
          ok = fn(
            (p['x'] as num).toDouble(),
            (p['y'] as num).toDouble(),
            (p['z'] as num).toDouble(),
            b.token,
            256,
            b.fingerprint,
            256,
            b.error,
            4096,
          );
        case 'CREATE EDGE':
          final fn = library.lookupFunction<_TwoTokenNative, _TwoTokenDart>(
                'flcad_occ_create_edge',
              ),
              a = (p['start'] as String).toNativeUtf8(),
              z = (p['end'] as String).toNativeUtf8();
          try {
            ok = fn(a, z, b.token, 256, b.fingerprint, 256, b.error, 4096);
          } finally {
            calloc.free(a);
            calloc.free(z);
          }
        case 'CREATE WIRE':
          ok = _tokenList('flcad_occ_create_wire', p['edges'], b);
        case 'CREATE FACE':
          ok = _oneToken('flcad_occ_create_face', p['wire'], b);
        case 'CREATE SHELL':
          final ids = _csv(p['faces']),
              fn = library.lookupFunction<_ShellNative, _ShellDart>(
                'flcad_occ_create_shell',
              );
          try {
            ok = fn(
              ids,
              (p['tolerance'] as num? ?? .001).toDouble(),
              b.token,
              256,
              b.fingerprint,
              256,
              b.error,
              4096,
            );
          } finally {
            calloc.free(ids);
          }
        case 'CREATE SOLID':
          ok = _oneToken('flcad_occ_create_solid', p['shell'], b);
        case 'EXTRUDE':
          final source = ((p['inputs'] as List).single as String)
              .toNativeUtf8();
          final vector = _nativeVector(_vector(p['direction'], 'direction'));
          final fn = library.lookupFunction<_ExtrudeNative, _ExtrudeDart>(
            'flcad_occ_extrude',
          );
          try {
            ok = fn(
              source,
              vector,
              p['output'] == 'surface' ? 0 : 1,
              (p['draftAngleDegrees'] as num? ?? 0).toDouble(),
              b.token,
              256,
              b.fingerprint,
              256,
              b.error,
              4096,
            );
          } finally {
            calloc.free(source);
            calloc.free(vector);
          }
        case 'GENERATE PLANE':
          ok = _plane(p, b);
        case 'CREATE PLANAR FACE':
          ok = _planarFace(p, b);
        case 'GENERATE CYLINDER':
          ok = _radial(
            'flcad_occ_create_cylinder',
            p,
            'axisOrigin',
            'axisDirection',
            'radius',
            b,
          );
        case 'GENERATE CONE':
          ok = _radial(
            'flcad_occ_create_cone',
            p,
            'apex',
            'axisDirection',
            'semiAngle',
            b,
          );
        case 'GENERATE SPHERE':
          ok = _sphere(p, b);
        case 'GENERATE TORUS':
          ok = _torus(p, b);
        default:
          throw UnsupportedError(
            '$operation is not exported by OCCT native bridge',
          );
      }
      if (ok != 1) throw StateError(b.error.toDartString());
      return _shape(b, expectedType);
    } finally {
      b.dispose();
    }
  }

  @override
  Future<void> destroyShape(String nativeToken) async {
    final token = nativeToken.toNativeUtf8();
    final error = calloc<Uint8>(4096).cast<Utf8>();
    final fn = library.lookupFunction<_DestroyNative, _DestroyDart>(
      'flcad_occ_destroy_shape',
    );
    try {
      if (fn(token, error, 4096) != 1) {
        throw StateError(error.toDartString());
      }
    } finally {
      calloc.free(token);
      calloc.free(error);
    }
  }

  @override
  Future<OpenCascadeNativeShape> transformShape(
    String nativeToken,
    List<double> matrix, {
    bool copyGeometry = true,
  }) async {
    if (matrix.length != 16 || matrix.any((value) => !value.isFinite)) {
      throw ArgumentError('Shape transform requires a finite 4x4 matrix.');
    }
    final source = nativeToken.toNativeUtf8();
    final values = calloc<Double>(16);
    final type = calloc<Uint8>(64).cast<Utf8>();
    final buffers = _buffers();
    final fn = library
        .lookupFunction<_TransformShapeNative, _TransformShapeDart>(
          'flcad_occ_transform_shape',
        );
    try {
      for (var index = 0; index < 16; index++) {
        values[index] = matrix[index];
      }
      final ok = fn(
        source,
        values,
        copyGeometry ? 1 : 0,
        buffers.token,
        256,
        buffers.fingerprint,
        256,
        type,
        64,
        buffers.error,
        4096,
      );
      if (ok != 1) throw StateError(buffers.error.toDartString());
      return _shape(buffers, CADShapeType.values.byName(type.toDartString()));
    } finally {
      calloc.free(source);
      calloc.free(values);
      calloc.free(type);
      buffers.dispose();
    }
  }

  int _oneToken(String symbol, Object? token, _Buffers b) {
    final value = (token as String).toNativeUtf8(),
        fn = library.lookupFunction<_OneTokenNative, _OneTokenDart>(symbol);
    try {
      return fn(value, b.token, 256, b.fingerprint, 256, b.error, 4096);
    } finally {
      calloc.free(value);
    }
  }

  Pointer<Utf8> _csv(Object? tokens) =>
      ((tokens as List).cast<String>().join(',')).toNativeUtf8();
  int _tokenList(String symbol, Object? tokens, _Buffers b) {
    final value = _csv(tokens),
        fn = library.lookupFunction<_OneTokenNative, _OneTokenDart>(symbol);
    try {
      return fn(value, b.token, 256, b.fingerprint, 256, b.error, 4096);
    } finally {
      calloc.free(value);
    }
  }

  int _plane(Map<String, dynamic> p, _Buffers b) {
    final o = _nativeVector(_vector(p['origin'], 'origin')),
        n = _nativeVector(_vector(p['normal'], 'normal')),
        fn = library.lookupFunction<_PlaneNative, _PlaneDart>(
          'flcad_occ_create_plane',
        );
    try {
      return fn(
        o,
        n,
        (p['lowerBound'] as num? ?? -1).toDouble(),
        (p['upperBound'] as num? ?? 1).toDouble(),
        b.token,
        256,
        b.fingerprint,
        256,
        b.error,
        4096,
      );
    } finally {
      calloc.free(o);
      calloc.free(n);
    }
  }

  int _planarFace(Map<String, dynamic> p, _Buffers b) {
    final values = (p['profilePoints'] as List?)?.cast<num>();
    if (values == null || values.length < 9 || values.length % 3 != 0) {
      throw ArgumentError('profilePoints requires at least three XYZ points');
    }
    final points = calloc<Double>(values.length);
    for (var i = 0; i < values.length; i++) {
      points[i] = values[i].toDouble();
    }
    final fn = library.lookupFunction<_PlanarFaceNative, _PlanarFaceDart>(
      'flcad_occ_create_planar_face',
    );
    try {
      return fn(
        points,
        values.length ~/ 3,
        b.token,
        256,
        b.fingerprint,
        256,
        b.error,
        4096,
      );
    } finally {
      calloc.free(points);
    }
  }

  int _radial(
    String symbol,
    Map<String, dynamic> p,
    String origin,
    String direction,
    String radius,
    _Buffers b,
  ) {
    final o = _nativeVector(_vector(p[origin], origin)),
        d = _nativeVector(_vector(p[direction], direction)),
        fn = library.lookupFunction<_RadialNative, _RadialDart>(symbol);
    try {
      return fn(
        o,
        d,
        (p[radius] as num).toDouble(),
        (p['lowerBound'] as num? ?? 0).toDouble(),
        (p['upperBound'] as num? ?? 1).toDouble(),
        b.token,
        256,
        b.fingerprint,
        256,
        b.error,
        4096,
      );
    } finally {
      calloc.free(o);
      calloc.free(d);
    }
  }

  int _sphere(Map<String, dynamic> p, _Buffers b) {
    final c = _nativeVector(_vector(p['center'], 'center')),
        fn = library.lookupFunction<_SphereNative, _SphereDart>(
          'flcad_occ_create_sphere',
        );
    try {
      return fn(
        c,
        (p['radius'] as num).toDouble(),
        (p['lowerBound'] as num? ?? -1.57).toDouble(),
        (p['upperBound'] as num? ?? 1.57).toDouble(),
        b.token,
        256,
        b.fingerprint,
        256,
        b.error,
        4096,
      );
    } finally {
      calloc.free(c);
    }
  }

  int _torus(Map<String, dynamic> p, _Buffers b) {
    final c = _nativeVector(_vector(p['center'], 'center')),
        d = _nativeVector(_vector(p['axisDirection'], 'axisDirection')),
        fn = library.lookupFunction<_TorusNative, _TorusDart>(
          'flcad_occ_create_torus',
        );
    try {
      return fn(
        c,
        d,
        (p['majorRadius'] as num).toDouble(),
        (p['minorRadius'] as num).toDouble(),
        b.token,
        256,
        b.fingerprint,
        256,
        b.error,
        4096,
      );
    } finally {
      calloc.free(c);
      calloc.free(d);
    }
  }

  @override
  Future<OpenCascadeNativeShape> importShape(
    String path,
    KernelExchangeFormat format, {
    required KernelCancellationToken cancellation,
    void Function(KernelProgress progress)? onProgress,
  }) async {
    if (cancellation.isCancelled) {
      throw StateError('Kernel operation cancelled');
    }
    final b = _buffers(),
        type = calloc<Uint8>(64).cast<Utf8>(),
        p = path.toNativeUtf8(),
        f = format.name.toNativeUtf8(),
        fn = library.lookupFunction<_ImportNative, _ImportDart>(
          'flcad_occ_import_shape',
        );
    try {
      onProgress?.call(
        KernelProgress('import-${format.name}', 0, 'Reading native shape'),
      );
      if (fn(p, f, b.token, 256, b.fingerprint, 256, type, 64, b.error, 4096) !=
          1) {
        throw StateError(b.error.toDartString());
      }
      onProgress?.call(
        KernelProgress('import-${format.name}', 1, 'Native shape loaded'),
      );
      return _shape(b, CADShapeType.values.byName(type.toDartString()));
    } finally {
      calloc.free(type);
      calloc.free(p);
      calloc.free(f);
      b.dispose();
    }
  }

  @override
  Future<OpenCascadeNativeMesh> importStl(
    String path,
    KernelImportFormat format, {
    required KernelCancellationToken cancellation,
    void Function(KernelProgress progress)? onProgress,
  }) async {
    if (cancellation.isCancelled) {
      throw StateError('Kernel operation cancelled');
    }
    final b = _buffers(),
        p = path.toNativeUtf8(),
        vertices = calloc<Int32>(),
        triangles = calloc<Int32>(),
        degenerates = calloc<Int32>(),
        bounds = calloc<Double>(6),
        normals = calloc<Int32>(),
        fn = library.lookupFunction<_ImportStlNative, _ImportStlDart>(
          'flcad_occ_import_stl',
        );
    try {
      onProgress?.call(
        const KernelProgress(
          'import-stl',
          0,
          'Reading STL with OpenCascade RWStl',
        ),
      );
      if (fn(
            p,
            b.token,
            256,
            b.fingerprint,
            256,
            vertices,
            triangles,
            degenerates,
            bounds,
            normals,
            b.error,
            4096,
          ) !=
          1) {
        throw StateError(b.error.toDartString());
      }
      onProgress?.call(
        const KernelProgress('import-stl', 1, 'STL triangulation loaded'),
      );
      return OpenCascadeNativeMesh(
        token: b.token.toDartString(),
        fingerprint: b.fingerprint.toDartString(),
        vertexCount: vertices.value,
        triangleCount: triangles.value,
        degenerateTriangleCount: degenerates.value,
        bounds: KernelBounds(
          bounds[0],
          bounds[1],
          bounds[2],
          bounds[3],
          bounds[4],
          bounds[5],
        ),
        hasNormals: normals.value == 1,
      );
    } finally {
      calloc.free(p);
      calloc.free(vertices);
      calloc.free(triangles);
      calloc.free(degenerates);
      calloc.free(bounds);
      calloc.free(normals);
      b.dispose();
    }
  }

  @override
  Future<void> destroyMesh(String nativeToken) async {
    final token = nativeToken.toNativeUtf8(),
        error = calloc<Uint8>(4096).cast<Utf8>(),
        fn = library.lookupFunction<_DestroyNative, _DestroyDart>(
          'flcad_occ_destroy_mesh',
        );
    try {
      if (fn(token, error, 4096) != 1) throw StateError(error.toDartString());
    } finally {
      calloc.free(token);
      calloc.free(error);
    }
  }

  @override
  Future<KernelMeshGeometry> inspectMesh(
    String nativeToken, {
    required int vertexCount,
    required int triangleCount,
  }) async {
    final token = nativeToken.toNativeUtf8();
    final nodes = calloc<Double>(vertexCount * 3);
    final triangles = calloc<Int32>(triangleCount * 3);
    final error = calloc<Uint8>(4096).cast<Utf8>();
    try {
      final fn = library.lookupFunction<_MeshGeometryNative, _MeshGeometryDart>(
        'flcad_occ_mesh_geometry',
      );
      if (fn(
            token,
            nodes,
            vertexCount * 3,
            triangles,
            triangleCount * 3,
            error,
            4096,
          ) !=
          1) {
        throw StateError(error.toDartString());
      }
      return KernelMeshGeometry(
        nodes: List<double>.generate(vertexCount * 3, (i) => nodes[i]),
        triangles: List<int>.generate(triangleCount * 3, (i) => triangles[i]),
      );
    } finally {
      calloc.free(token);
      calloc.free(nodes);
      calloc.free(triangles);
      calloc.free(error);
    }
  }

  @override
  Future<void> exportShape(
    String token,
    String path,
    KernelExchangeFormat format, {
    required KernelCancellationToken cancellation,
    void Function(KernelProgress progress)? onProgress,
  }) async {
    if (cancellation.isCancelled) {
      throw StateError('Kernel operation cancelled');
    }
    final t = token.toNativeUtf8(),
        p = path.toNativeUtf8(),
        f = format.name.toNativeUtf8(),
        e = calloc<Uint8>(4096).cast<Utf8>(),
        fn = library.lookupFunction<_ExportNative, _ExportDart>(
          'flcad_occ_export_shape',
        );
    try {
      if (fn(t, p, f, e, 4096) != 1) throw StateError(e.toDartString());
    } finally {
      for (final x in [t, p, f, e]) {
        calloc.free(x);
      }
    }
  }

  Future<String> _inspect(String symbol, String token) async {
    final t = token.toNativeUtf8(),
        out = calloc<Uint8>(16384).cast<Utf8>(),
        error = calloc<Uint8>(4096).cast<Utf8>(),
        fn = library.lookupFunction<_InspectNative, _InspectDart>(symbol);
    try {
      if (fn(t, out, 16384, error, 4096) != 1) {
        throw StateError(error.toDartString());
      }
      return out.toDartString();
    } finally {
      calloc.free(t);
      calloc.free(out);
      calloc.free(error);
    }
  }

  @override
  Future<List<GeometryDiagnostic>> validate(String token) async =>
      (jsonDecode(await _inspect('flcad_occ_validate', token)) as List).map((
        e,
      ) {
        final m = Map<String, dynamic>.from(e as Map);
        return GeometryDiagnostic(
          code: m['code'] as String,
          message: m['message'] as String,
          severity: m['severity'] as String,
        );
      }).toList();
  @override
  Future<Map<String, dynamic>> inspectSurfaceTopology(
    String nativeToken,
  ) async => Map<String, dynamic>.from(
    jsonDecode(await _inspect('flcad_occ_surface_topology', nativeToken))
        as Map,
  );

  @override
  Future<Map<String, dynamic>> intersectSurfaces(
    String firstToken,
    String secondToken,
  ) async {
    final first = firstToken.toNativeUtf8(),
        second = secondToken.toNativeUtf8(),
        out = calloc<Uint8>(16384).cast<Utf8>(),
        error = calloc<Uint8>(4096).cast<Utf8>(),
        fn = library.lookupFunction<_IntersectNative, _IntersectDart>(
          'flcad_occ_intersect_surfaces',
        );
    try {
      if (fn(first, second, out, 16384, error, 4096) != 1) {
        throw StateError(error.toDartString());
      }
      return Map<String, dynamic>.from(jsonDecode(out.toDartString()) as Map);
    } finally {
      calloc.free(first);
      calloc.free(second);
      calloc.free(out);
      calloc.free(error);
    }
  }

  @override
  Future<Map<String, dynamic>> inspectSurfaceQuality(
    String nativeToken, {
    required List<double> draftDirection,
    required int samples,
  }) async {
    if (draftDirection.length != 3) {
      throw ArgumentError('Draft direction requires three coordinates');
    }
    final token = nativeToken.toNativeUtf8(),
        direction = calloc<Double>(3),
        out = calloc<Uint8>(16384).cast<Utf8>(),
        error = calloc<Uint8>(4096).cast<Utf8>(),
        fn = library.lookupFunction<_SurfaceQualityNative, _SurfaceQualityDart>(
          'flcad_occ_surface_quality',
        );
    for (var i = 0; i < 3; i++) {
      direction[i] = draftDirection[i];
    }
    try {
      if (fn(token, direction, samples, out, 16384, error, 4096) != 1) {
        throw StateError(error.toDartString());
      }
      return Map<String, dynamic>.from(jsonDecode(out.toDartString()) as Map);
    } finally {
      calloc.free(token);
      calloc.free(direction);
      calloc.free(out);
      calloc.free(error);
    }
  }

  @override
  Future<List<HealingProposal>> proposeHealing(String token) async =>
      (jsonDecode(await _inspect('flcad_occ_healing_proposals', token)) as List)
          .map((e) {
            final m = Map<String, dynamic>.from(e as Map);
            return HealingProposal(
              id: m['id'] as String,
              operation: m['operation'] as String,
              reason: m['reason'] as String,
              diagnostics: const [],
            );
          })
          .toList();

  @override
  Future<OpenCascadeNativeShape> executeSurfaceOperation(
    String operation, {
    String? sourceToken,
    List<String> referenceTokens = const [],
    List<double> values = const [],
  }) async {
    final op = operation.toNativeUtf8();
    final source = (sourceToken ?? '').toNativeUtf8();
    final references = referenceTokens.join(',').toNativeUtf8();
    final nativeValues = calloc<Double>(values.isEmpty ? 1 : values.length);
    final type = calloc<Uint8>(64).cast<Utf8>();
    final buffers = _Buffers();
    for (var index = 0; index < values.length; index++) {
      nativeValues[index] = values[index];
    }
    final fn = library
        .lookupFunction<_SurfaceOperationNative, _SurfaceOperationDart>(
          'flcad_occ_surface_operation',
        );
    try {
      final ok = fn(
        op,
        source,
        references,
        nativeValues,
        values.length,
        buffers.token,
        256,
        buffers.fingerprint,
        256,
        type,
        64,
        buffers.error,
        4096,
      );
      if (ok != 1) throw StateError(buffers.error.toDartString());
      return OpenCascadeNativeShape(
        token: buffers.token.toDartString(),
        type: CADShapeType.values.byName(type.toDartString()),
        fingerprint: buffers.fingerprint.toDartString(),
        metadata: {'backend': 'OpenCascade', 'operator': operation},
      );
    } finally {
      calloc.free(op);
      calloc.free(source);
      calloc.free(references);
      calloc.free(nativeValues);
      calloc.free(type);
      buffers.dispose();
    }
  }

  @override
  Future<OpenCascadeNativeShape> sew(List<String> tokens, double tolerance) =>
      createShape('CREATE SHELL', {
        'faces': tokens,
        'tolerance': tolerance,
      }, CADShapeType.shell);
  @override
  Future<KernelMeshData> mesh(
    String nativeToken,
    String outputPath,
    double deflection,
  ) async {
    final token = nativeToken.toNativeUtf8();
    final path = outputPath.toNativeUtf8();
    final vertices = calloc<Int32>();
    final triangles = calloc<Int32>();
    final error = calloc<Uint8>(4096).cast<Utf8>();
    final fn = library.lookupFunction<_MeshNative, _MeshDart>('flcad_occ_mesh');
    try {
      if (fn(token, path, deflection, vertices, triangles, error, 4096) != 1) {
        throw StateError(error.toDartString());
      }
      return KernelMeshData(vertices.value, triangles.value, outputPath);
    } finally {
      calloc.free(token);
      calloc.free(path);
      calloc.free(vertices);
      calloc.free(triangles);
      calloc.free(error);
    }
  }
}

class _Buffers {
  _Buffers()
    : token = calloc<Uint8>(256).cast<Utf8>(),
      fingerprint = calloc<Uint8>(256).cast<Utf8>(),
      error = calloc<Uint8>(4096).cast<Utf8>();
  final Pointer<Utf8> token, fingerprint, error;
  void dispose() {
    calloc.free(token);
    calloc.free(fingerprint);
    calloc.free(error);
  }
}
