import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_derived_edge_refiner.dart';

import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_derived_edge_classifier.dart';

const _classifier = MeshDerivedEdgeClassifier();
const _refiner = MeshDerivedEdgeRefiner();

MeshDerivedEdgeStatistics _stats({
  required int segments,
  required int openBoundary,
  required int crease,
  required int ambiguous,
  double weldTolerance = 1e-6,
}) => MeshDerivedEdgeStatistics(
  inputTriangles: 0,
  validTriangles: 0,
  degenerateTriangles: 0,
  invalidTriangles: 0,
  uniqueCandidateEdges: segments,
  openBoundaryEdges: openBoundary,
  creaseEdges: crease,
  coplanarEdgesDiscarded: 0,
  ambiguousEdges: ambiguous,
  weldedVertices: 0,
  segments: segments,
  weldTolerance: weldTolerance,
  normalsAvailable: false,
  inconsistentNormalFaces: 0,
  creaseAngleHistogram: const [0, 0, 0, 0, 0, 0, 0, 0, 0],
  estimatedBytes: 0,
  truncated: false,
);

MeshDerivedEdgeClassification _classification(
  List<MeshDerivedEdgeSegment> segments,
) {
  var openBoundary = 0, crease = 0, ambiguous = 0;
  for (final segment in segments) {
    switch (segment.kind) {
      case MeshDerivedEdgeKind.openBoundary:
        openBoundary++;
      case MeshDerivedEdgeKind.crease:
        crease++;
      case MeshDerivedEdgeKind.ambiguous:
        ambiguous++;
    }
  }
  return MeshDerivedEdgeClassification(
    segments: List.unmodifiable(segments),
    statistics: _stats(
      segments: segments.length,
      openBoundary: openBoundary,
      crease: crease,
      ambiguous: ambiguous,
    ),
    diagnostics: const [],
  );
}

MeshDerivedEdgeSegment _seg(
  List<double> start,
  List<double> end,
  MeshDerivedEdgeKind kind,
) => MeshDerivedEdgeSegment(start: start, end: end, kind: kind);

(List<num>, List<int>) _cube() {
  const vertices = <num>[
    0,
    0,
    0,
    1,
    0,
    0,
    1,
    1,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
    1,
    0,
    1,
    1,
    1,
    1,
    0,
    1,
    1,
  ];
  const triangles = <int>[
    0,
    1,
    2,
    0,
    2,
    3,
    4,
    6,
    5,
    4,
    7,
    6,
    0,
    4,
    5,
    0,
    5,
    1,
    1,
    5,
    6,
    1,
    6,
    2,
    2,
    6,
    7,
    2,
    7,
    3,
    3,
    7,
    4,
    3,
    4,
    0,
  ];
  return (vertices, triangles);
}

(List<num>, List<int>) _cylinder({int sides = 64, bool caps = false}) {
  final vertices = <num>[];
  final triangles = <int>[];
  for (var ring = 0; ring < 2; ring++) {
    final z = ring.toDouble();
    for (var side = 0; side < sides; side++) {
      final angle = side * 2 * math.pi / sides;
      vertices.addAll([math.cos(angle), math.sin(angle), z]);
    }
  }
  if (caps) {
    vertices.addAll([0, 0, 0, 0, 0, 1]);
  }
  for (var side = 0; side < sides; side++) {
    final next = (side + 1) % sides;
    triangles.addAll([
      side,
      next,
      sides + next,
      side,
      sides + next,
      sides + side,
    ]);
    if (caps) {
      final bottom = vertices.length ~/ 3 - 2;
      final top = bottom + 1;
      triangles.addAll([bottom, next, side, top, sides + side, sides + next]);
    }
  }
  return (vertices, triangles);
}

(List<num>, List<int>) _plane({int divisions = 1, double size = 1}) {
  final vertices = <num>[];
  final triangles = <int>[];
  for (var y = 0; y <= divisions; y++) {
    for (var x = 0; x <= divisions; x++) {
      vertices.addAll([x * size / divisions, y * size / divisions, 0]);
    }
  }
  int vertex(int x, int y) => y * (divisions + 1) + x;
  for (var y = 0; y < divisions; y++) {
    for (var x = 0; x < divisions; x++) {
      final a = vertex(x, y);
      final b = vertex(x + 1, y);
      final c = vertex(x + 1, y + 1);
      final d = vertex(x, y + 1);
      triangles.addAll([a, b, c, a, c, d]);
    }
  }
  return (vertices, triangles);
}

(List<num>, List<int>) _channel({int steps = 8}) {
  final vertices = <num>[];
  final triangles = <int>[];
  for (var i = 0; i <= steps; i++) {
    final x = i.toDouble();
    vertices.addAll([x, 0, 1, x, 0, 0, x, 1, 0, x, 1, 1]);
  }
  for (var i = 0; i < steps; i++) {
    final a = i * 4;
    final b = (i + 1) * 4;
    for (final offset in [0, 1, 2]) {
      triangles.addAll([
        a + offset,
        b + offset,
        b + offset + 1,
        a + offset,
        b + offset + 1,
        a + offset + 1,
      ]);
    }
  }
  return (vertices, triangles);
}

(List<num>, List<int>) _plateWithHole({int sides = 12}) {
  final vertices = <num>[0, 0, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0];
  for (var side = 0; side < sides; side++) {
    final angle = side * 2 * math.pi / sides;
    vertices.addAll([2 + 0.4 * math.cos(angle), 2 + 0.4 * math.sin(angle), 0]);
  }
  final triangles = <int>[];
  for (var side = 0; side < sides; side++) {
    final inner = 4 + side;
    final innerNext = 4 + (side + 1) % sides;
    final angle = (side + 0.5) * 2 * math.pi / sides;
    final outer = angle < math.pi / 4 || angle >= 7 * math.pi / 4
        ? 1
        : angle < 3 * math.pi / 4
        ? 2
        : angle < 5 * math.pi / 4
        ? 3
        : 0;
    triangles.addAll([inner, innerNext, outer]);
  }
  triangles.addAll([
    0,
    1,
    4,
    1,
    2,
    4 + sides ~/ 4,
    2,
    3,
    4 + sides ~/ 2,
    3,
    0,
    4,
  ]);
  return (vertices, triangles);
}

void main() {
  test('flag experimental permanece desligada e não altera a apresentação', () {
    expect(kFlcadDevMeshDerivedEdgeRefinement, isFalse);
    final classified = _classifier.classify(
      vertices: const [0, 0, 0, 1, 0, 0, 0, 1, 0],
      triangles: const [0, 1, 2],
    );
    expect(
      meshDerivedPresentationSegments(classified),
      same(classified.segments),
    );
  });

  test('cubo e cilindro preservam arestas reais', () {
    final cube = _cube();
    final cubeClass = _classifier.classify(
      vertices: cube.$1,
      triangles: cube.$2,
    );
    final cubeRefined = _refiner.refine(cubeClass);
    expect(cubeClass.statistics.creaseEdges, 12);
    expect(cubeRefined.refinedSegments, 12);
    expect(cubeRefined.suppressed, 0);

    final tube = _cylinder();
    final tubeClass = _classifier.classify(
      vertices: tube.$1,
      triangles: tube.$2,
    );
    final tubeRefined = _refiner.refine(tubeClass);
    expect(tubeClass.statistics.openBoundaryEdges, 128);
    expect(tubeRefined.openBoundaryEdges, 128);
    expect(tubeRefined.suppressed, 0);
    expect(tubeRefined.closedLoopCount, greaterThanOrEqualTo(2));
  });

  test('plano triangulado não reintroduz diagonais internas', () {
    final plane = _plane(divisions: 4, size: 10);
    final classified = _classifier.classify(
      vertices: plane.$1,
      triangles: plane.$2,
    );
    final refined = _refiner.refine(classified);
    expect(classified.statistics.creaseEdges, 0);
    expect(classified.statistics.openBoundaryEdges, 16);
    expect(refined.refinedSegments, classified.segments.length);
    expect(refined.suppressed, 0);
  });

  test('furos circulares pequenos e nervuras permanecem', () {
    final hole = _plateWithHole();
    final holeClass = _classifier.classify(
      vertices: hole.$1,
      triangles: hole.$2,
    );
    final holeRefined = _refiner.refine(holeClass);
    expect(holeClass.statistics.openBoundaryEdges, greaterThan(4));
    expect(
      holeRefined.openBoundaryEdges,
      holeClass.statistics.openBoundaryEdges,
    );
    expect(holeRefined.suppressed, 0);

    final capped = _cylinder(sides: 16, caps: true);
    final capClass = _classifier.classify(
      vertices: capped.$1,
      triangles: capped.$2,
    );
    final capRefined = _refiner.refine(capClass);
    expect(capClass.statistics.creaseEdges, 32);
    expect(capRefined.creaseEdges, 32);
    expect(capRefined.closedLoopCount, greaterThanOrEqualTo(2));

    final rib = _channel();
    final ribClass = _classifier.classify(vertices: rib.$1, triangles: rib.$2);
    final ribRefined = _refiner.refine(ribClass);
    expect(ribClass.statistics.creaseEdges, greaterThan(0));
    expect(ribRefined.creaseEdges, ribClass.statistics.creaseEdges);
    expect(ribRefined.suppressed, 0);
  });

  test('curva suave com ruído isolado curto pode ser filtrada', () {
    final segments = <MeshDerivedEdgeSegment>[
      for (var i = 0; i < 20; i++)
        _seg(
          [i.toDouble(), 0, 0],
          [(i + 1).toDouble(), 0.05, 0],
          MeshDerivedEdgeKind.crease,
        ),
      _seg([50, 50, 0], [50.05, 50, 0], MeshDerivedEdgeKind.crease),
      _seg([80, 80, 0], [80.04, 80.01, 0], MeshDerivedEdgeKind.crease),
    ];
    final refined = _refiner.refine(_classification(segments));
    expect(refined.originalSegments, 22);
    expect(refined.suppressionCandidates, greaterThanOrEqualTo(2));
    expect(refined.applied, isTrue);
    expect(refined.refinedSegments, lessThan(refined.originalSegments));
    expect(refined.preserved, greaterThanOrEqualTo(20));
  });

  test('bordas abertas curtas e ambiguous nunca são removidos', () {
    final segments = [
      _seg([0, 0, 0], [10, 0, 0], MeshDerivedEdgeKind.openBoundary),
      _seg([10, 0, 0], [10, 10, 0], MeshDerivedEdgeKind.openBoundary),
      _seg([10, 10, 0], [0, 10, 0], MeshDerivedEdgeKind.openBoundary),
      _seg([0, 10, 0], [0, 0, 0], MeshDerivedEdgeKind.openBoundary),
      _seg([1, 1, 0], [1.02, 1, 0], MeshDerivedEdgeKind.openBoundary),
      _seg([5, 5, 0], [5.02, 5, 0], MeshDerivedEdgeKind.ambiguous),
      _seg([8, 8, 0], [8.02, 8, 0], MeshDerivedEdgeKind.crease),
    ];
    final refined = _refiner.refine(_classification(segments));
    expect(refined.openBoundaryEdges, 5);
    expect(refined.ambiguousEdges, 1);
    expect(refined.suppressionCandidates, 1);
    expect(refined.creaseEdges, 0);
  });

  test('malha não-manifold preserva ambiguous e o classificador original', () {
    final classified = _classifier.classify(
      vertices: const [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0],
      triangles: const [0, 1, 2, 0, 1, 3, 1, 0, 2, 0, 1, 0, 0, 1, 99],
    );
    final refined = _refiner.refine(classified);
    expect(classified.statistics.ambiguousEdges, greaterThan(0));
    expect(refined.ambiguousEdges, classified.statistics.ambiguousEdges);
    expect(refined.suppressed, 0);
  });

  test('contorno hexagonal curto de detalhe mecânico é preservado', () {
    final segments = [
      for (var i = 0; i < 6; i++)
        _seg(
          [
            math.cos(i * math.pi / 3) * 0.08,
            math.sin(i * math.pi / 3) * 0.08,
            0,
          ],
          [
            math.cos((i + 1) * math.pi / 3) * 0.08,
            math.sin((i + 1) * math.pi / 3) * 0.08,
            0,
          ],
          MeshDerivedEdgeKind.crease,
        ),
      _seg([0, 0, 0], [10, 0, 0], MeshDerivedEdgeKind.openBoundary),
      _seg([10, 0, 0], [10, 10, 0], MeshDerivedEdgeKind.openBoundary),
      _seg([10, 10, 0], [0, 10, 0], MeshDerivedEdgeKind.openBoundary),
      _seg([0, 10, 0], [0, 0, 0], MeshDerivedEdgeKind.openBoundary),
    ];
    final refined = _refiner.refine(_classification(segments));
    expect(refined.closedLoopCount, greaterThanOrEqualTo(1));
    expect(refined.creaseEdges, 6);
    expect(refined.suppressed, 0);
  });

  test(
    'agrupamento espacial preserva arestas isoladas de um furo quebrado',
    () {
      final segments = [
        _seg([0, 0, 0], [0.04, 0, 0], MeshDerivedEdgeKind.crease),
        _seg([0.2, 0, 0], [0.24, 0, 0], MeshDerivedEdgeKind.crease),
        _seg([0.1, 0.18, 0], [0.14, 0.18, 0], MeshDerivedEdgeKind.crease),
        _seg([0.1, -0.18, 0], [0.14, -0.18, 0], MeshDerivedEdgeKind.crease),
        _seg([40, 0, 0], [50, 0, 0], MeshDerivedEdgeKind.openBoundary),
      ];
      final refined = _refiner.refine(_classification(segments));
      expect(refined.creaseEdges, 4);
      expect(refined.suppressed, 0);
    },
  );

  test('a mesma topologia em escalas distintas permanece relativa ao P50', () {
    List<MeshDerivedEdgeSegment> scaled(double factor) => [
      _seg([0, 0, 0], [factor, 0, 0], MeshDerivedEdgeKind.openBoundary),
      _seg(
        [factor, 0, 0],
        [factor, factor, 0],
        MeshDerivedEdgeKind.openBoundary,
      ),
      _seg(
        [factor, factor, 0],
        [0, factor, 0],
        MeshDerivedEdgeKind.openBoundary,
      ),
      _seg([0, factor, 0], [0, 0, 0], MeshDerivedEdgeKind.openBoundary),
      _seg(
        [0.5 * factor, 0.5 * factor, 0],
        [0.52 * factor, 0.5 * factor, 0],
        MeshDerivedEdgeKind.crease,
      ),
    ];
    final small = _refiner.refine(_classification(scaled(0.001)));
    final large = _refiner.refine(_classification(scaled(1000)));
    expect(small.suppressed, 1);
    expect(large.suppressed, 1);
    expect(small.refinedSegments, large.refinedSegments);
  });

  test('é determinístico e não modifica as entradas da classificação', () {
    final vertices = <num>[0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0];
    final triangles = <num>[0, 1, 2, 0, 2, 3];
    final originalVertices = List<num>.from(vertices);
    final originalTriangles = List<num>.from(triangles);
    final classified = _classifier.classify(
      vertices: vertices,
      triangles: triangles,
    );
    final snapshot = [
      for (final segment in classified.segments)
        [
          segment.start[0],
          segment.start[1],
          segment.start[2],
          segment.end[0],
          segment.end[1],
          segment.end[2],
          segment.kind.index,
        ],
    ];
    final first = _refiner.refine(classified);
    final second = _refiner.refine(classified);
    expect(first.refinedSegments, second.refinedSegments);
    expect(first.chains, second.chains);
    expect(first.turningAngleHistogram, second.turningAngleHistogram);
    expect(vertices, originalVertices);
    expect(triangles, originalTriangles);
    expect([
      for (final segment in classified.segments)
        [
          segment.start[0],
          segment.start[1],
          segment.start[2],
          segment.end[0],
          segment.end[1],
          segment.end[2],
          segment.kind.index,
        ],
    ], snapshot);
  });

  test('cap conservador desiste quando o corte seria amplo demais', () {
    final segments = [
      for (var i = 0; i < 20; i++)
        _seg(
          [i.toDouble(), 0, 0],
          [(i + 1).toDouble(), 0, 0],
          MeshDerivedEdgeKind.crease,
        ),
      for (var i = 0; i < 8; i++)
        _seg(
          [i * 80.0, 100, 0],
          [i * 80.0 + 0.05, 100, 0],
          MeshDerivedEdgeKind.crease,
        ),
    ];
    final refined = _refiner.refine(_classification(segments));
    expect(refined.suppressionCandidates, 8);
    expect(refined.applied, isFalse);
    expect(refined.skippedReason, 'suppression_ratio_exceeds_conservative_cap');
    expect(refined.suppressed, 0);
    expect(refined.refinedSegments, 28);
  });

  test('observa tempo e memória adicionais sem recálculo na observação', () {
    final classified = _classifier.classify(
      vertices: const [0, 0, 0, 1, 0, 0, 0, 1, 0],
      triangles: const [0, 1, 2],
    );
    final first = const MeshDerivedEdgeRefiner().refine(classified);
    final second = const MeshDerivedEdgeRefiner().refine(classified);
    expect(first.elapsedMicros, greaterThanOrEqualTo(0));
    expect(first.estimatedBytes, greaterThan(0));
    expect(first.refinedSegments, second.refinedSegments);
    expect(kDebugMode, isTrue);
  });
}
