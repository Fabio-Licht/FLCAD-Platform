import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_derived_edge_classifier.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_derived_edge_refiner.dart';

const _config = MeshDerivedEdgeClassifierConfig(
  maxTriangles: 250000,
  maxEdges: 250000,
);

({List<double> vertices, List<int> triangles, List<double> normals}) _parseStl(
  File file,
) {
  final bytes = file.readAsBytesSync();
  if (bytes.length >= 6) {
    final prefix = String.fromCharCodes(bytes.take(5));
    if (prefix.toLowerCase() == 'solid' &&
        (bytes.length < 84 || !_looksBinary(bytes))) {
      return _parseAscii(bytes);
    }
  }
  return _parseBinary(bytes);
}

bool _looksBinary(Uint8List bytes) {
  if (bytes.length < 84) return false;
  final count = ByteData.sublistView(bytes).getUint32(80, Endian.little);
  return count > 0 && bytes.length >= 84 + count * 50;
}

({List<double> vertices, List<int> triangles, List<double> normals})
_parseBinary(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final count = data.getUint32(80, Endian.little);
  final vertices = List<double>.filled(count * 9, 0);
  final normals = List<double>.filled(count * 9, 0);
  final triangles = List<int>.generate(count * 3, (index) => index);
  var cursor = 84;
  var offset = 0;
  for (var face = 0; face < count; face++) {
    final nx = data.getFloat32(cursor, Endian.little);
    final ny = data.getFloat32(cursor + 4, Endian.little);
    final nz = data.getFloat32(cursor + 8, Endian.little);
    cursor += 12;
    for (var corner = 0; corner < 3; corner++) {
      vertices[offset] = data.getFloat32(cursor, Endian.little);
      vertices[offset + 1] = data.getFloat32(cursor + 4, Endian.little);
      vertices[offset + 2] = data.getFloat32(cursor + 8, Endian.little);
      normals[offset] = nx;
      normals[offset + 1] = ny;
      normals[offset + 2] = nz;
      offset += 3;
      cursor += 12;
    }
    cursor += 2;
  }
  return (vertices: vertices, triangles: triangles, normals: normals);
}

({List<double> vertices, List<int> triangles, List<double> normals})
_parseAscii(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final vertices = <double>[];
  final normals = <double>[];
  final triangles = <int>[];
  var nx = 0.0, ny = 0.0, nz = 1.0;
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.startsWith('facet normal')) {
      final parts = line.split(RegExp(r'\s+'));
      nx = double.parse(parts[2]);
      ny = double.parse(parts[3]);
      nz = double.parse(parts[4]);
    } else if (line.startsWith('vertex')) {
      final parts = line.split(RegExp(r'\s+'));
      vertices.addAll([
        double.parse(parts[1]),
        double.parse(parts[2]),
        double.parse(parts[3]),
      ]);
      normals.addAll([nx, ny, nz]);
      triangles.add(triangles.length);
    }
  }
  return (vertices: vertices, triangles: triangles, normals: normals);
}

void _measure(String label, File file) {
  final mesh = _parseStl(file);
  final classifyWatch = Stopwatch()..start();
  final classified = const MeshDerivedEdgeClassifier().classify(
    vertices: mesh.vertices,
    triangles: mesh.triangles,
    normals: mesh.normals,
    config: _config,
  );
  classifyWatch.stop();
  final refined = const MeshDerivedEdgeRefiner().refine(classified);
  final stats = classified.statistics;
  debugPrint(
    'RV-P1c.3a $label: tris=${stats.inputTriangles} '
    'orig=${refined.originalSegments} refined=${refined.refinedSegments} '
    'suppressed=${refined.suppressed} candidates=${refined.suppressionCandidates} '
    'crease ${stats.creaseEdges}→${refined.creaseEdges} '
    'open ${stats.openBoundaryEdges}→${refined.openBoundaryEdges} '
    'amb ${stats.ambiguousEdges}→${refined.ambiguousEdges} '
    'chains=${refined.chains} loops=${refined.closedLoopCount} '
    'isolated=${refined.isolatedCount} applied=${refined.applied} '
    'skipped=${refined.skippedReason} '
    'classMs=${classifyWatch.elapsedMilliseconds} '
    'refineUs=${refined.elapsedMicros} extraBytes=${refined.estimatedBytes} '
    'flag=$kFlcadDevMeshDerivedEdgeRefinement '
    'appliedToPresentation=${kFlcadDevMeshDerivedEdgeRefinement && refined.applied}',
  );
  expect(classified.statistics.truncated, isFalse);
  expect(mesh.vertices, isNotEmpty);
}

void main() {
  test('mede STLs de smoke com o mesmo contrato de produção', () {
    final root = Directory.current.path;
    final files = [
      File('$root/smoke/g104b_primitives/sphere.stl'),
      File('$root/smoke/g104b_primitives/torus.stl'),
      File('$root/smoke/g104b_primitives/cone.stl'),
      File('$root/smoke/g104b_primitives/plane.stl'),
    ];
    for (final file in files) {
      expect(file.existsSync(), isTrue, reason: file.path);
      _measure(file.uri.pathSegments.last, file);
    }
    expect(kFlcadDevMeshDerivedEdgeRefinement, isFalse);
  });

  test('mede o custo extra numa malha do porte da CALOTA', () {
    const side = 270;
    final vertices = Float64List((side + 1) * (side + 1) * 3);
    final triangles = Int32List(side * side * 6);
    var vertexOffset = 0;
    for (var y = 0; y <= side; y++) {
      for (var x = 0; x <= side; x++) {
        vertices[vertexOffset++] = x / side;
        vertices[vertexOffset++] = y / side;
        vertices[vertexOffset++] = 0;
      }
    }
    var triangleOffset = 0;
    int vertex(int x, int y) => y * (side + 1) + x;
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final a = vertex(x, y);
        final b = vertex(x + 1, y);
        final c = vertex(x + 1, y + 1);
        final d = vertex(x, y + 1);
        triangles[triangleOffset++] = a;
        triangles[triangleOffset++] = b;
        triangles[triangleOffset++] = c;
        triangles[triangleOffset++] = a;
        triangles[triangleOffset++] = c;
        triangles[triangleOffset++] = d;
      }
    }
    final classified = const MeshDerivedEdgeClassifier().classify(
      vertices: vertices,
      triangles: triangles,
      config: _config,
    );
    final refined = const MeshDerivedEdgeRefiner().refine(classified);
    debugPrint(
      'RV-P1c.3a calota-scale-plane: tris=${classified.statistics.inputTriangles} '
      'orig=${refined.originalSegments} refined=${refined.refinedSegments} '
      'suppressed=${refined.suppressed} chains=${refined.chains} '
      'loops=${refined.closedLoopCount} refineUs=${refined.elapsedMicros} '
      'extraBytes=${refined.estimatedBytes} applied=${refined.applied}',
    );
    expect(classified.statistics.inputTriangles, 145800);
    expect(refined.suppressed, 0);
    expect(refined.elapsedMicros, lessThan(1e6 * 2));
  });
}
