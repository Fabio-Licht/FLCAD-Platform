import 'dart:io';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

// ===========================================================================
// PRECISION ORACLE — FERRAMENTA EXPERIMENTAL (Frente C / C.2 / C.2.1)
//
// NÃO é gate obrigatório de aprovação do produto. O arquivo mantém dois
// conjuntos explícitos e separados:
//
//   A) baseline do pipeline padrão — as dez geometrias são tesseladas como a
//      aplicação faz hoje (deflexão 0,01 mm, ângulo 0,5 rad em
//      `flcad_occ_mesh`). Esfera e toro permanecem FAIL nesse baseline, com o
//      motivo exato impresso em cada linha; a referência é sempre analítica e
//      independente do kernel.
//
//   B) estudo de convergência (C.2.1) — varredura de deflexão × ângulo pela
//      API pública `flcad_occ_mesh_stream_v1` (que já aceita o ângulo), sem
//      alterar o bridge nem substituir os parâmetros do pipeline. Registra
//      quais configurações atingem as metas; adotá-las é decisão de engenharia,
//      não relaxamento de tolerância.
//
// Runtime nativo: staging *process-local* (`SetDllDirectoryW`) do diretório que
// contém `flcad_opencascade.dll` + runtime OCCT — nada é copiado, o PATH global
// não é tocado e o Release existente fica intacto. Sem runtime carregável o
// resultado é BLOCKED (skip), nunca aprovação.
//
// Execução:
//   flutter test test/g125_precision_oracle_test.dart
//   FLCAD_ORACLE_REQUIRE_NATIVE=1  -> exige runtime real (skip vira falha)
//   FLCAD_SOURCE_OCC_DLL=<path>    -> aponta uma build específica do bridge
// ===========================================================================

typedef _SetDllDirectoryNative = Int32 Function(Pointer<Utf16> path);
typedef _SetDllDirectoryDart = int Function(Pointer<Utf16> path);

// ---------------------------------------------------------------------------
// C.2.1 — convergência de tesselação.
//
// A API pública já expõe deflexão *e* ângulo (`flcad_occ_mesh_stream_v1`:
// deflexão absoluta em unidades do modelo, ângulo em radianos, STL binário
// float32). Ligar essa função aqui permite varrer as duas dimensões sem tocar
// o bridge nativo nem a API de produção.
typedef _StreamWriteNative =
    Int32 Function(
      Pointer<Void> context,
      Pointer<Uint8> bytes,
      Uint32 length,
      Pointer<Uint32> accepted,
    );
typedef _MeshStreamNative =
    Int32 Function(
      Pointer<Utf8> shapeToken,
      Double deflection,
      Double angularDeflection,
      Uint64 maxTriangles,
      Pointer<_StreamSink> sink,
      Pointer<_StreamResult> result,
      Uint32 resultSize,
    );
typedef _MeshStreamDart =
    int Function(
      Pointer<Utf8> shapeToken,
      double deflection,
      double angularDeflection,
      int maxTriangles,
      Pointer<_StreamSink> sink,
      Pointer<_StreamResult> result,
      int resultSize,
    );

final class _StreamSink extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int version;
  external Pointer<Void> context;
  external Pointer<NativeFunction<_StreamWriteNative>> write;
}

final class _StreamResult extends Struct {
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

/// One tessellation produced through the public stream API.
final class _StreamedMesh {
  const _StreamedMesh({
    required this.nodes,
    required this.triangles,
    required this.microseconds,
    required this.reportedTriangles,
  });

  final List<double> nodes;
  final List<int> triangles;
  final int microseconds;
  final int reportedTriangles;
}

/// Meshes `shapeToken` with the requested absolute deflection and angle.
_StreamedMesh _meshViaStream(
  DynamicLibrary library,
  String shapeToken,
  double deflection,
  double angularDeflection, {
  int maxTriangles = 4000000,
}) {
  final bytes = BytesBuilder(copy: false);
  final write = NativeCallable<_StreamWriteNative>.isolateLocal((
    Pointer<Void> context,
    Pointer<Uint8> chunk,
    int length,
    Pointer<Uint32> accepted,
  ) {
    // The buffer is borrowed and reused by the native side between callbacks:
    // it must be copied before the callback returns.
    bytes.add(Uint8List.fromList(chunk.asTypedList(length)));
    accepted.value = length;
    return 0;
  }, exceptionalReturn: -1);
  final sink = calloc<_StreamSink>();
  final result = calloc<_StreamResult>();
  final token = shapeToken.toNativeUtf8();
  final stopwatch = Stopwatch()..start();
  try {
    sink.ref
      ..size = sizeOf<_StreamSink>()
      ..version = 1
      ..context = nullptr
      ..write = write.nativeFunction;
    result.ref
      ..version = 1
      ..status = 0
      ..consumerCode = 0
      ..acceptedCountValid = 0
      ..bytesAccepted = 0
      ..triangles = 0;
    final fn = library.lookupFunction<_MeshStreamNative, _MeshStreamDart>(
      'flcad_occ_mesh_stream_v1',
    );
    final status = fn(
      token,
      deflection,
      angularDeflection,
      maxTriangles,
      sink,
      result,
      sizeOf<_StreamResult>(),
    );
    stopwatch.stop();
    if (status != 0) {
      final message = result.ref.message[0] == 0
          ? 'status $status'
          : _readCString(result.ref.message);
      throw StateError('mesh_stream falhou: $message');
    }
    final payload = bytes.takeBytes();
    final geometry = _parseBinaryStl(payload);
    return _StreamedMesh(
      nodes: geometry.$1,
      triangles: geometry.$2,
      microseconds: stopwatch.elapsedMicroseconds,
      reportedTriangles: result.ref.triangles,
    );
  } finally {
    write.close();
    calloc.free(sink);
    calloc.free(result);
    calloc.free(token);
  }
}

String _readCString(Array<Uint8> array) {
  final codes = <int>[];
  for (var i = 0; i < 256; i++) {
    final value = array[i];
    if (value == 0) break;
    codes.add(value);
  }
  return String.fromCharCodes(codes);
}

/// Binary STL: 80-byte header, u32 count, then 50 bytes per triangle.
///
/// STL duplicates every vertex per triangle, so the vertices are welded by
/// quantized coordinates again; without welding `V - E + F` and the manifold
/// test describe a triangle soup, not the surface topology.
(List<double>, List<int>) _parseBinaryStl(Uint8List payload) {
  final data = ByteData.sublistView(payload);
  final count = data.getUint32(80, Endian.little);
  final nodes = <double>[];
  final triangles = <int>[];
  final welded = <String, int>{};
  int indexOf(double x, double y, double z) {
    final key =
        '${x.toStringAsFixed(6)},${y.toStringAsFixed(6)},${z.toStringAsFixed(6)}';
    final existing = welded[key];
    if (existing != null) return existing;
    final index = nodes.length ~/ 3;
    nodes
      ..add(x)
      ..add(y)
      ..add(z);
    welded[key] = index;
    return index;
  }

  var offset = 84;
  for (var t = 0; t < count; t++) {
    final base = offset + 12;
    for (var v = 0; v < 3; v++) {
      triangles.add(
        indexOf(
          data.getFloat32(base + v * 12, Endian.little).toDouble(),
          data.getFloat32(base + v * 12 + 4, Endian.little).toDouble(),
          data.getFloat32(base + v * 12 + 8, Endian.little).toDouble(),
        ),
      );
    }
    offset += 50;
  }
  return (nodes, triangles);
}

/// Directories that hold a bridge build. The Release layout is the one that
/// ships the OCCT runtime beside the bridge, so it is the preferred probe.
List<String> _bridgeCandidates() => [
  ?Platform.environment['FLCAD_SOURCE_OCC_DLL'],
  r'C:\flcad_mobile\build\windows\x64\runner\Release\flcad_opencascade.dll',
  r'C:\flcad_mobile\build\occ_mesh_stream\Release\flcad_opencascade.dll',
];

/// Stages the OpenCascade runtime for this test process only.
///
/// The bridge imports the OCCT `TK*` runtime, and `LoadLibrary` with an
/// absolute path does **not** search the DLL's own directory, so without
/// staging the loader fails with error 126. `SetDllDirectoryW` is process-local:
/// nothing is copied, no global PATH is touched and the Release stays intact.
String? _stageRuntime() {
  final setDirectory = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<_SetDllDirectoryNative, _SetDllDirectoryDart>(
        'SetDllDirectoryW',
      );
  for (final candidate in _bridgeCandidates()) {
    if (!File(candidate).existsSync()) continue;
    final directory = File(candidate).parent.path.toNativeUtf16();
    try {
      setDirectory(directory);
      try {
        DynamicLibrary.open(candidate);
        return candidate;
      } on Object {
        setDirectory(nullptr);
      }
    } finally {
      calloc.free(directory);
    }
  }
  return null;
}

/// G125 / Frente C — Precision Oracle.
///
/// Ten synthetic solids are built through the *official* OpenCascade bridge,
/// meshed with a known deflection, re-imported as STL (the same path the
/// reverse-engineering pipeline consumes) and measured by this file alone.
/// Every expectation is a closed-form value computed here, so kernel and
/// measurement never share an implementation. ADR-066 is respected: no parser,
/// no fabricated production geometry, no change to the product pipeline.
const double _deflection = 0.01;
const double _volumeTolerance = 2e-3;
const double _areaTolerance = 2e-3;
const double _dimensionTolerance = 0.02;
const double _nodeTolerance = 1e-5;

typedef _Distance = double Function(double x, double y, double z);

final class _Case {
  const _Case({
    required this.name,
    required this.operation,
    required this.params,
    required this.volume,
    required this.area,
    required this.bounds,
    this.profile,
    this.expectedEuler = 2,
    this.expectedManifold = true,
    this.enclosesVolume = true,
    this.distance,
    this.baselineDiagnosis,
  });

  final String name;
  final String operation;
  final Map<String, dynamic> params;
  final List<double>? profile;
  final double volume;
  final double area;
  final List<double> bounds; // minX,minY,minZ,maxX,maxY,maxZ
  /// `V - E + F` for the expected topology (`2 - 2g`, `1` for a disc, `0` for a
  /// tube with two boundary loops).
  final int expectedEuler;
  /// Closed solids (and the closed shell of a sphere) are manifold; surfaces
  /// with a boundary are not.
  final bool expectedManifold;
  /// False for lateral surfaces that enclose nothing (tube/cone/disc faces).
  final bool enclosesVolume;
  final _Distance? distance;
  /// Motivo exato impresso quando o caso falha no baseline (conjunto A).
  final String? baselineDiagnosis;
}

double _tube(double x, double y, double z, double radius) =>
    (math.sqrt(x * x + y * y) - radius).abs();

double _box(double x, double y, double z, double sx, double sy, double sz) {
  final dx = math.max(0.0, math.max(-x, x - sx));
  final dy = math.max(0.0, math.max(-y, y - sy));
  final dz = math.max(0.0, math.max(-z, z - sz));
  if (dx > 0 || dy > 0 || dz > 0) return math.sqrt(dx * dx + dy * dy + dz * dz);
  return math.min(math.min(x, sx - x), math.min(math.min(y, sy - y), math.min(z, sz - z)));
}

double _ring(double x, double y, double z, double inner, double outer, double h) {
  final r = math.sqrt(x * x + y * y);
  final radial = math.max(inner - r, r - outer);
  final axial = math.max(-z, z - h);
  if (radial > 0 || axial > 0) {
    final a = math.max(radial, 0.0), b = math.max(axial, 0.0);
    return math.sqrt(a * a + b * b);
  }
  return math.min(math.min(r - inner, outer - r), math.min(z, h - z));
}

List<double> _ngon(int sides, double radius) => [
  for (var i = 0; i < sides; i++) ...[
    radius * math.cos(2 * math.pi * i / sides),
    radius * math.sin(2 * math.pi * i / sides),
    0.0,
  ],
];

List<_Case> _corpus() {
  const pi = math.pi;
  const sphereR = 10.0, cylR = 6.0, cylH = 20.0, discR = 8.0, discH = 2.0;
  const torusMajor = 12.0, torusMinor = 3.0;
  const ringIn = 4.0, ringOut = 6.0, ringH = 10.0;
  const hexA = 8.0, hexH = 12.0;
  const boxX = 20.0, boxY = 10.0, boxZ = 5.0;
  const coneSlope = 0.4, coneLower = 5.0, coneUpper = 15.0;
  final hexArea = 3 * math.sqrt(3) / 2 * hexA * hexA;
  // Semântica verificada de `GENERATE CONE`: o parâmetro V de `gp_Cone` é a
  // distância ao longo da *geratriz* desde o ápice, não a altura axial. Medido:
  // z de 4,642 a 13,927 e r máximo 5,571 = V*cos/sin(semiÂngulo).
  final coneHalfAngle = math.atan(coneSlope);
  final coneRadiusTop = coneUpper * math.sin(coneHalfAngle);
  final coneRadiusBottom = coneLower * math.sin(coneHalfAngle);
  final coneZTop = coneUpper * math.cos(coneHalfAngle);
  final coneZBottom = coneLower * math.cos(coneHalfAngle);
  // Semântica verificada do draft: o plano neutro é o perfil extrudado (z=0,
  // lado 20) e o extremo oposto encolhe 2*h*tan(5°) por lado -> topo 18,25.
  // Medido: V=3660,251 contra 3660,20 analítico e bbox 20x20x10.
  const draftSide = 20.0, draftH = 10.0;
  final draftAngle = 5 * pi / 180;
  final draftTop = draftSide - 2 * draftH * math.tan(draftAngle);
  final draftSlant = draftH / math.cos(draftAngle);
  final draftVolume =
      draftH /
      3 *
      (draftSide * draftSide +
          draftTop * draftTop +
          math.sqrt(draftSide * draftSide * draftTop * draftTop));
  final draftArea =
      draftSide * draftSide +
      draftTop * draftTop +
      4 * ((draftSide + draftTop) / 2) * draftSlant;
  // O comprimento da geratriz entre os dois V é exatamente upper - lower.
  final coneArea =
      pi * (coneRadiusTop + coneRadiusBottom) * (coneUpper - coneLower);
  return [
    _Case(
      name: 'box 20x10x5',
      operation: 'EXTRUDE',
      profile: const [0, 0, 0, boxX, 0, 0, boxX, boxY, 0, 0, boxY, 0],
      params: const {
        'direction': [0, 0, boxZ],
        'output': 'solid',
      },
      volume: boxX * boxY * boxZ,
      area: 2 * (boxX * boxY + boxY * boxZ + boxX * boxZ),
      bounds: const [0, 0, 0, boxX, boxY, boxZ],
      distance: (x, y, z) => _box(x, y, z, boxX, boxY, boxZ),
    ),
    _Case(
      name: 'hex prism a=8 h=12',
      operation: 'EXTRUDE',
      profile: _ngon(6, hexA),
      params: const {
        'direction': [0, 0, hexH],
        'output': 'solid',
      },
      volume: hexArea * hexH,
      area: 2 * hexArea + 6 * hexA * hexH,
      bounds: [
        -hexA,
        -hexA * math.sqrt(3) / 2,
        0,
        hexA,
        hexA * math.sqrt(3) / 2,
        hexH,
      ],
    ),
    _Case(
      name: 'square prism draft 5deg',
      operation: 'EXTRUDE',
      profile: const [0, 0, 0, 20, 0, 0, 20, 20, 0, 0, 20, 0],
      params: const {
        'direction': [0, 0, 10],
        'output': 'solid',
        'draftAngleDegrees': 5,
      },
      volume: draftVolume,
      area: draftArea,
      bounds: const [0, 0, 0, draftSide, draftSide, draftH],
    ),
    _Case(
      name: 'hollow ring Ri=4 Ro=6 h=10',
      operation: 'REVOLVE',
      profile: const [ringIn, 0, 0, ringOut, 0, 0, ringOut, 0, ringH, ringIn, 0, ringH],
      params: const {
        'axisOrigin': [0, 0, 0],
        'axisDirection': [0, 0, 1],
        'angleDegrees': 360,
        'output': 'solid',
      },
      volume: pi * (ringOut * ringOut - ringIn * ringIn) * ringH,
      area:
          2 * pi * (ringOut * ringOut - ringIn * ringIn) +
          2 * pi * (ringOut + ringIn) * ringH,
      bounds: const [-ringOut, -ringOut, 0, ringOut, ringOut, ringH],
      // Revolved closed profile: a solid torus-like ring, genus 1.
      expectedEuler: 0,
      distance: (x, y, z) => _ring(x, y, z, ringIn, ringOut, ringH),
    ),
    _Case(
      name: 'cylinder tube r=6 h=20',
      operation: 'GENERATE CYLINDER',
      params: const {
        'axisOrigin': [0, 0, 0],
        'axisDirection': [0, 0, 1],
        'radius': cylR,
        'lowerBound': 0,
        'upperBound': cylH,
      },
      volume: 0,
      area: 2 * pi * cylR * cylH,
      bounds: const [-cylR, -cylR, 0, cylR, cylR, cylH],
      enclosesVolume: false,
      expectedEuler: 0, // two boundary loops: 2 - 2 * 2
      expectedManifold: false,
      distance: (x, y, z) => _tube(x, y, z, cylR),
    ),
    _Case(
      name: 'cone frustum r 2->6',
      operation: 'GENERATE CONE',
      params: {
        'apex': const [0, 0, 0],
        'axisDirection': const [0, 0, 1],
        'semiAngle': math.atan(coneSlope),
        'lowerBound': coneLower,
        'upperBound': coneUpper,
      },
      volume: 0,
      area: coneArea,
      bounds: [
        -coneRadiusTop,
        -coneRadiusTop,
        coneZBottom,
        coneRadiusTop,
        coneRadiusTop,
        coneZTop,
      ],
      enclosesVolume: false,
      expectedEuler: 0,
      expectedManifold: false,
      distance: (x, y, z) {
        final r = math.sqrt(x * x + y * y);
        final v = (z / math.cos(coneHalfAngle)).clamp(coneLower, coneUpper);
        final expected = v * math.sin(coneHalfAngle);
        return (r - expected).abs() * math.cos(coneHalfAngle);
      },
    ),
    _Case(
      name: 'sphere r=10',
      operation: 'GENERATE SPHERE',
      params: const {
        'center': [0, 0, 0],
        'radius': sphereR,
        'lowerBound': -pi / 2,
        'upperBound': pi / 2,
      },
      volume: 4 / 3 * pi * sphereR * sphereR * sphereR,
      area: 4 * pi * sphereR * sphereR,
      bounds: const [-sphereR, -sphereR, -sphereR, sphereR, sphereR, sphereR],
      baselineDiagnosis:
          'desvio interior 1,71e-2 mm > 0,015 mm na deflexao padrao 0,01 mm; '
          'o conjunto B mede 6,92e-3 mm com 0,004 mm.',
      distance: (x, y, z) =>
          (math.sqrt(x * x + y * y + z * z) - sphereR).abs(),
    ),
    _Case(
      name: 'hemisphere r=10',
      operation: 'GENERATE SPHERE',
      params: const {
        'center': [0, 0, 0],
        'radius': sphereR,
        'lowerBound': 0,
        'upperBound': pi / 2,
      },
      volume: 2 / 3 * pi * sphereR * sphereR * sphereR,
      // `GENERATE SPHERE` yields the spherical shell only: no base disc.
      area: 2 * pi * sphereR * sphereR,
      bounds: const [-sphereR, -sphereR, 0, sphereR, sphereR, sphereR],
      // A hemisphere shell is topologically a disc: one boundary loop.
      expectedEuler: 1,
      expectedManifold: false,
      distance: (x, y, z) => math.min(
        (math.sqrt(x * x + y * y + z * z) - sphereR).abs(),
        z.abs(),
      ),
    ),
    _Case(
      name: 'torus R=12 r=3',
      operation: 'GENERATE TORUS',
      params: const {
        'center': [0, 0, 0],
        'axisDirection': [0, 0, 1],
        'majorRadius': torusMajor,
        'minorRadius': torusMinor,
      },
      volume: 2 * pi * pi * torusMajor * torusMinor * torusMinor,
      area: 4 * pi * pi * torusMajor * torusMinor,
      bounds: [
        -(torusMajor + torusMinor),
        -(torusMajor + torusMinor),
        -torusMinor,
        torusMajor + torusMinor,
        torusMajor + torusMinor,
        torusMinor,
      ],
      // Closed surface of genus 1: 2 - 2 * 1.
      expectedEuler: 0,
      baselineDiagnosis:
          'erro de volume 0,261% > 0,2% com o angulo padrao 0,5 rad; o '
          'conjunto B mede 0,083% com 0,10 rad na mesma deflexao de 0,01 mm.',
      distance: (x, y, z) =>
          (math.sqrt(math.pow(math.sqrt(x * x + y * y) - torusMajor, 2) + z * z) -
                  torusMinor)
              .abs(),
    ),
    _Case(
      name: 'disc tube r=8 h=2',
      operation: 'GENERATE CYLINDER',
      params: const {
        'axisOrigin': [0, 0, 0],
        'axisDirection': [0, 0, 1],
        'radius': discR,
        'lowerBound': 0,
        'upperBound': discH,
      },
      volume: 0,
      area: 2 * pi * discR * discH,
      bounds: const [-discR, -discR, 0, discR, discR, discH],
      enclosesVolume: false,
      expectedEuler: 0,
      expectedManifold: false,
      distance: (x, y, z) => _tube(x, y, z, discR),
    ),
  ];
}

final class _Metrics {
  const _Metrics({
    required this.volume,
    required this.area,
    required this.bounds,
    required this.euler,
    required this.manifold,
    required this.nodeDeviation,
    required this.centroidDeviation,
    required this.interiorDeviation,
    required this.signedVolume,
    required this.triangles,
    required this.vertices,
    required this.degenerateTriangles,
    required this.nonManifoldEdges,
  });

  final double volume, area, nodeDeviation, centroidDeviation;
  final double interiorDeviation;
  final double signedVolume;
  final List<double> bounds;
  final int euler, triangles, vertices;
  /// Facetas de área nula (índice repetido ou área < 1e-12): os leques de polo
  /// de uma esfera tesselada são a fonte conhecida.
  final int degenerateTriangles;
  /// Arestas cujo uso por triângulos não é exatamente dois.
  final int nonManifoldEdges;
  final bool manifold;
}

_Metrics _measure(List<double> nodes, List<int> triangles, _Distance? distance) {
  final edges = <int, int>{};
  var volume = 0.0, area = 0.0, nodeDev = 0.0, centroidDev = 0.0;
  var interiorDev = 0.0;
  var degenerate = 0;
  final xs = <double>[], ys = <double>[], zs = <double>[];
  for (var v = 0; v < nodes.length; v += 3) {
    xs.add(nodes[v]);
    ys.add(nodes[v + 1]);
    zs.add(nodes[v + 2]);
    final d = distance?.call(nodes[v], nodes[v + 1], nodes[v + 2]);
    if (d != null && d > nodeDev) nodeDev = d;
  }
  for (var t = 0; t < triangles.length; t += 3) {
    final a = triangles[t], b = triangles[t + 1], c = triangles[t + 2];
    final ax = nodes[a * 3], ay = nodes[a * 3 + 1], az = nodes[a * 3 + 2];
    final bx = nodes[b * 3], by = nodes[b * 3 + 1], bz = nodes[b * 3 + 2];
    final cx = nodes[c * 3], cy = nodes[c * 3 + 1], cz = nodes[c * 3 + 2];
    final ux = bx - ax, uy = by - ay, uz = bz - az;
    final vx = cx - ax, vy = cy - ay, vz = cz - az;
    final nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    final facetArea = math.sqrt(nx * nx + ny * ny + nz * nz) / 2;
    area += facetArea;
    if (a == b || b == c || a == c || facetArea < 1e-12) degenerate++;
    volume += (ax * nx + ay * ny + az * nz) / 6;
    for (final pair in [(a, b), (b, c), (c, a)]) {
      final key = pair.$1 < pair.$2
          ? pair.$1 * 1000000 + pair.$2
          : pair.$2 * 1000000 + pair.$1;
      edges[key] = (edges[key] ?? 0) + 1;
    }
    final d = distance?.call((ax + bx + cx) / 3, (ay + by + cy) / 3, (az + bz + cz) / 3);
    if (d != null && d > centroidDev) centroidDev = d;
    if (distance != null) {
      // Quatro amostras interiores por triângulo: o centróide sozinho é uma
      // amostra, não o máximo demonstrado da faceta.
      const weights = [
        (1 / 3, 1 / 3, 1 / 3),
        (2 / 3, 1 / 6, 1 / 6),
        (1 / 6, 2 / 3, 1 / 6),
        (1 / 6, 1 / 6, 2 / 3),
      ];
      for (final (wa, wb, wc) in weights) {
        final d = distance(
          wa * ax + wb * bx + wc * cx,
          wa * ay + wb * by + wc * cy,
          wa * az + wb * bz + wc * cz,
        );
        if (d > interiorDev) interiorDev = d;
      }
    }
  }
  final vertices = nodes.length ~/ 3;
  final faces = triangles.length ~/ 3;
  return _Metrics(
    volume: volume.abs(),
    area: area,
    bounds: [xs.reduce(math.min), ys.reduce(math.min), zs.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max), zs.reduce(math.max)],
    euler: vertices - edges.length + faces,
    manifold: edges.values.every((count) => count == 2),
    nodeDeviation: nodeDev,
    centroidDeviation: centroidDev,
    triangles: faces,
    vertices: vertices,
    interiorDeviation: interiorDev,
    signedVolume: volume,
    degenerateTriangles: degenerate,
    nonManifoldEdges: edges.values.where((count) => count != 2).length,
  );
}

double _relative(double measured, double expected) =>
    expected == 0 ? measured.abs() : (measured - expected).abs() / expected.abs();

/// One configuration of the C.2.1 tessellation sweep.
final class _SweepRow {
  const _SweepRow({
    required this.deflection,
    required this.angle,
    required this.triangles,
    required this.volumeError,
    required this.areaError,
    required this.nodeDeviation,
    required this.interiorDeviation,
    required this.euler,
    required this.manifold,
    required this.oriented,
    required this.meshMicros,
    required this.analysisMicros,
    required this.reportedTriangles,
    required this.degenerateTriangles,
    required this.nonManifoldEdges,
  });

  final double deflection;
  final double angle;
  final double areaError;
  final double nodeDeviation;
  final double interiorDeviation;
  final double? volumeError;
  final int triangles;
  final int euler;
  final int meshMicros;
  final int analysisMicros;
  final int reportedTriangles;
  final int degenerateTriangles;
  final int nonManifoldEdges;
  final bool manifold;
  final bool oriented;
}

void main() {
  final dll = _stageRuntime();
  final statuses = <String>[];
  final corpus = _corpus();
  final requireNative =
      (Platform.environment['FLCAD_ORACLE_REQUIRE_NATIVE'] ?? '') == '1';
  // A skip is a BLOCKED status, never an approval: with the runtime unavailable
  // the geometric gate cannot be claimed (the flag turns skips into failures so
  // CI can demand a real run).
  final skip = dll == null
      ? 'BLOCKED: runtime OCCT não carregável a partir de ${_bridgeCandidates().join(' | ')}'
      : false;
  tearDownAll(() {
    // ignore: avoid_print
    print('[oracle] resumo: ${statuses.where((s) => s == 'PASS').length} PASS, '
        '${statuses.where((s) => s == 'FAIL').length} FAIL, '
        '${statuses.length} casos executados'
        '${dll == null ? ' — BLOCKED: runtime ausente' : ''}');
    if (dll != null) {
      DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_SetDllDirectoryNative, _SetDllDirectoryDart>(
            'SetDllDirectoryW',
          )(nullptr);
    }
  });

  test('runtime OCCT carregável para o gate geométrico', () {
    if (requireNative) {
      expect(dll, isNotNull, reason: 'FLCAD_ORACLE_REQUIRE_NATIVE=1 exige runtime real');
    } else {
      // ignore: avoid_print
      print('[oracle] runtime=${dll ?? 'BLOCKED'} (defina FLCAD_ORACLE_REQUIRE_NATIVE=1 para exigir)');
    }
  });

  if (requireNative && dll == null) {
    test('BLOCKED: gate geométrico exige runtime OCCT', () {
      fail('FLCAD_ORACLE_REQUIRE_NATIVE=1 mas nenhuma ponte OCCT carregou');
    });
  }

  group('B) estudo de convergencia (deflexao x angulo)', () {
    const deflections = [0.02, 0.01, 0.004, 0.002];
    const angles = [0.5, 0.25, 0.10];
    for (final name in const ['sphere r=10', 'torus R=12 r=3']) {
      test('varredura: $name', () async {
        final item = corpus.firstWhere((entry) => entry.name == name);
        final ffi = OpenCascadeFFI.load(path: dll!);
        final library = DynamicLibrary.open(dll);
        final tokens = <String>[];
        final rows = <_SweepRow>[];
        try {
          await ffi.initialize();
          final built = await ffi.createShape(
            item.operation,
            Map<String, dynamic>.from(item.params),
            CADShapeType.face,
          );
          tokens.add(built.token);
          for (final deflection in deflections) {
            for (final angle in angles) {
              final streamed = _meshViaStream(
                library,
                built.token,
                deflection,
                angle,
              );
              final analysis = Stopwatch()..start();
              final metrics = _measure(
                streamed.nodes,
                streamed.triangles,
                item.distance,
              );
              analysis.stop();
              final row = _SweepRow(
                deflection: deflection,
                angle: angle,
                triangles: metrics.triangles,
                volumeError: item.enclosesVolume
                    ? _relative(metrics.volume, item.volume)
                    : null,
                areaError: _relative(metrics.area, item.area),
                nodeDeviation: metrics.nodeDeviation,
                interiorDeviation: metrics.interiorDeviation,
                euler: metrics.euler,
                manifold: metrics.manifold,
                oriented: metrics.signedVolume > 0,
                meshMicros: streamed.microseconds,
                analysisMicros: analysis.elapsedMicroseconds,
                reportedTriangles: streamed.reportedTriangles,
                degenerateTriangles: metrics.degenerateTriangles,
                nonManifoldEdges: metrics.nonManifoldEdges,
              );
              rows.add(row);
              final volumeText = row.volumeError == null
                  ? 'n/a'
                  : '${(row.volumeError! * 100).toStringAsFixed(3)}%';
              // ignore: avoid_print
              print(
                '[sweep] ${item.name.padRight(14)} '
                'defl=${deflection.toStringAsFixed(3)} '
                'ang=${angle.toStringAsFixed(2)} t=${row.triangles} '
                'volErr=$volumeText '
                'areaErr=${(row.areaError * 100).toStringAsFixed(3)}% '
                'nodeDev=${row.nodeDeviation.toStringAsExponential(2)} '
                'interiorDev=${row.interiorDeviation.toStringAsExponential(2)} '
                'euler=${row.euler} manifold=${row.manifold} '
                'oriented=${row.oriented} '
                'degen=${row.degenerateTriangles} '
                'nonManifoldEdges=${row.nonManifoldEdges} '
                'mesh=${(row.meshMicros / 1000).toStringAsFixed(1)}ms '
                'analysis=${(row.analysisMicros / 1000).toStringAsFixed(1)}ms '
                'reportedT=${row.reportedTriangles}',
              );
            }
          }
          for (final angle in angles) {
            final axis = rows.where((row) => row.angle == angle).toList();
            for (var i = 1; i < axis.length; i++) {
              // Amostra interior (4 pontos por faceta) e mudança de padrão de
              // triangulação tornam o passo mais grosso menos suave: a regra
              // usa folga maior no primeiro passo e folga estreita nos passos
              // finos, onde a relação desvio/deflexão é estável.
              final slack = i == 1 ? 1.30 : 1.10;
              expect(
                axis[i].interiorDeviation,
                lessThanOrEqualTo(axis[i - 1].interiorDeviation * slack + 1e-9),
                reason:
                    'desvio interior nao converge (${item.name}, ang=$angle, '
                    'defl ${axis[i - 1].deflection}->${axis[i].deflection})',
              );
              if (axis[i].volumeError != null) {
                expect(
                  axis[i].volumeError!,
                  lessThanOrEqualTo(axis[i - 1].volumeError! * slack + 1e-9),
                  reason:
                      'erro de volume nao converge (${item.name}, ang=$angle, '
                      'defl ${axis[i - 1].deflection}->${axis[i].deflection})',
                );
              }
            }
          }
          final best = rows.reduce(
            (a, b) => a.interiorDeviation <= b.interiorDeviation ? a : b,
          );
          final meets = item.enclosesVolume
              ? (best.volumeError ?? 1) <= _volumeTolerance &&
                    best.interiorDeviation <= 0.015
              : best.interiorDeviation <= 0.015;
          final volumeText = best.volumeError == null
              ? 'n/a'
              : '${(best.volumeError! * 100).toStringAsFixed(3)}%';
          // ignore: avoid_print
          print(
            '[sweep] ${item.name} melhor: defl=${best.deflection} '
            'ang=${best.angle} '
            'interiorDev=${best.interiorDeviation.toStringAsExponential(3)} '
            'volErr=$volumeText atendeMetas=$meets',
          );
          expect(
            meets,
            isTrue,
            reason: 'nenhuma configuracao atinge as metas atuais (${item.name})',
          );
        } finally {
          for (final token in tokens.reversed) {
            try {
              await ffi.destroyShape(token);
            } on Object {
              // Fixture descartavel.
            }
          }
          await ffi.shutdown();
        }
      }, skip: skip);
    }
  });

  test('o corpus tem dez geometrias analíticas', () {
    expect(corpus, hasLength(10));
    expect(corpus.map((item) => item.name).toSet(), hasLength(10));
  });

  group('A) baseline do pipeline padrao (defl 0,01 mm / angulo 0,5 rad)', () {
    for (final item in corpus) {
      test(item.name, () async {
        final root = await Directory.systemTemp.createTemp('flcad-oracle-');
        final ffi = OpenCascadeFFI.load(path: dll!);
        final tokens = <String>[];
        try {
          await ffi.initialize();
          final params = Map<String, dynamic>.from(item.params);
          if (item.profile != null) {
            final face = await ffi.createShape('CREATE PLANAR FACE', {
              'profilePoints': item.profile,
            }, CADShapeType.face);
            tokens.add(face.token);
            params['inputs'] = [face.token];
          }
          final built = await ffi.createShape(
            item.operation,
            params,
            item.operation.startsWith('GENERATE')
                ? CADShapeType.face
                : CADShapeType.solid,
          );
          tokens.add(built.token);
          final stl = '${root.path}/case.stl';
          await ffi.mesh(built.token, stl, _deflection);
          final imported = await ffi.importStl(
            stl,
            KernelImportFormat.autoDetect,
            cancellation: const NoKernelCancellation(),
          );
          tokens.add(imported.token);
          final geometry = await ffi.inspectMesh(
            imported.token,
            vertexCount: imported.vertexCount,
            triangleCount: imported.triangleCount,
          );
          final metrics = _measure(geometry.nodes, geometry.triangles, item.distance);
          final dimensionError = item.bounds.isEmpty
              ? 0.0
              : [
                  for (var i = 0; i < 6; i++)
                    (metrics.bounds[i] - item.bounds[i]).abs(),
                ].reduce(math.max);
          final volumeError = item.enclosesVolume
              ? _relative(metrics.volume, item.volume)
              : null;
          final areaError = _relative(metrics.area, item.area);
          final volumeOk = volumeError == null || volumeError <= _volumeTolerance;
          final areaOk = areaError <= _areaTolerance;
          final dimensionOk = item.bounds.isEmpty || dimensionError <= _dimensionTolerance;
          final eulerOk = metrics.euler == item.expectedEuler;
          final manifoldOk = metrics.manifold == item.expectedManifold;
          final nodeOk = item.distance == null || metrics.nodeDeviation <= _nodeTolerance;
          final sagittaOk =
              item.distance == null ||
              metrics.centroidDeviation <= 1.5 * _deflection;
          final status =
              volumeOk && areaOk && dimensionOk && eulerOk && manifoldOk && nodeOk && sagittaOk
              ? 'PASS'
              : 'FAIL';
          statuses.add(status);
          // ignore: avoid_print
          print(
            '[oracle] ${item.name.padRight(34)} $status '
            'v=${metrics.vertices} t=${metrics.triangles} '
            'vol=${metrics.volume.toStringAsFixed(3)}/${item.volume.toStringAsFixed(3)} '
            '(${volumeError == null ? 'n/a' : '${(volumeError * 100).toStringAsFixed(3)}%'}) '
            'area=${metrics.area.toStringAsFixed(3)}/${item.area.toStringAsFixed(3)} '
            '(${(areaError * 100).toStringAsFixed(3)}%) '
            'dim<=${dimensionError.toStringAsFixed(4)}mm '
            'bounds=[${metrics.bounds.map((v) => v.toStringAsFixed(3)).join(',')}] '
            'euler=${metrics.euler}/${item.expectedEuler} '
            'manifold=${metrics.manifold}/${item.expectedManifold} '
            'nodeDev=${metrics.nodeDeviation.toStringAsExponential(2)} '
            'centroidDev=${metrics.centroidDeviation.toStringAsExponential(2)} '
            '[vol=${volumeOk ? 'ok' : 'FAIL'} area=${areaOk ? 'ok' : 'FAIL'} '
            'dim=${dimensionOk ? 'ok' : 'FAIL'} euler=${eulerOk ? 'ok' : 'FAIL'} '
            'manifold=${manifoldOk ? 'ok' : 'FAIL'} nodes=${nodeOk ? 'ok' : 'FAIL'} '
            'sagitta=${sagittaOk ? 'ok' : 'FAIL'}] '
            'degen=${metrics.degenerateTriangles} '
            'nonManifoldEdges=${metrics.nonManifoldEdges}',
          );
          if (status == 'FAIL' && item.baselineDiagnosis != null) {
            // ignore: avoid_print
            print('[oracle] diagnostico (${item.name}): ${item.baselineDiagnosis}');
          }

          if (item.enclosesVolume) {
            expect(
              volumeError,
              lessThanOrEqualTo(_volumeTolerance),
              reason: 'volume de ${item.name}',
            );
          }
          expect(
            areaError,
            lessThanOrEqualTo(_areaTolerance),
            reason: 'área de ${item.name}',
          );
          if (item.bounds.isNotEmpty) {
            expect(
              dimensionError,
              lessThanOrEqualTo(_dimensionTolerance),
              reason: 'dimensões de ${item.name}',
            );
          }
          expect(
            metrics.euler,
            item.expectedEuler,
            reason: 'V-E+F de ${item.name}',
          );
          expect(
            metrics.manifold,
            item.expectedManifold,
            reason: 'manifold de ${item.name}',
          );
          if (item.distance != null) {
            expect(
              metrics.nodeDeviation,
              lessThanOrEqualTo(_nodeTolerance),
              reason: 'vértices sobre a superfície analítica (${item.name})',
            );
            expect(
              metrics.centroidDeviation,
              lessThanOrEqualTo(1.5 * _deflection),
              reason: 'flecha dentro da deflexão (${item.name})',
            );
          }
        } finally {
          for (final token in tokens.reversed) {
            try {
              await ffi.destroyShape(token);
            } on Object {
              // Shapes and meshes use different destroy entry points.
            }
          }
          await ffi.shutdown();
          await root.delete(recursive: true);
        }
      }, skip: skip);
    }
  });
}
