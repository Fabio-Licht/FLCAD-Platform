import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/core/sketch_editor/regions/sketch_region_classifier.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';

List<SketchVector> _square(
  double x,
  double y,
  double size, {
  bool reverse = false,
}) {
  final points = [
    SketchVector(x, y),
    SketchVector(x + size, y),
    SketchVector(x + size, y + size),
    SketchVector(x, y + size),
    SketchVector(x, y),
  ];
  return reverse ? points.reversed.toList() : points;
}

SketchRegionLoopInput _loop(
  String id,
  List<SketchVector> points, {
  List<String>? entities,
}) =>
    SketchRegionLoopInput(id: id, entityIds: entities ?? [id], points: points);

void main() {
  const classifier = SketchRegionClassifier(tolerance: 1e-5);

  test('classifies one external loop and preserves identity', () {
    final result = classifier.classify([_loop('outer', _square(0, 0, 10))]);
    expect(result.conclusive, isTrue);
    expect(result.loops.single.role, SketchRegionRole.outer);
    expect(result.loops.single.depth, 0);
    expect(result.loops.single.entityIds, ['outer']);
    expect(result.loops.single.points.length, 4);
  });

  test('classifies independent loops without inventing a parent', () {
    final result = classifier.classify([
      _loop('a', _square(0, 0, 2)),
      _loop('b', _square(5, 0, 2)),
    ]);
    expect(result.loops.map((loop) => loop.role), [
      SketchRegionRole.outer,
      SketchRegionRole.outer,
    ]);
    expect(result.loops.every((loop) => loop.parentLoopId == null), isTrue);
  });

  test('uses containment depth for holes, islands and four levels', () {
    final result = classifier.classify([
      _loop('l0', _square(0, 0, 20)),
      _loop('l1', _square(2, 2, 16, reverse: true)),
      _loop('l2', _square(4, 4, 12)),
      _loop('l3', _square(6, 6, 8, reverse: true)),
    ]);
    expect(result.conclusive, isTrue);
    expect(result.loops.map((loop) => loop.depth), [0, 1, 2, 3]);
    expect(result.loops.map((loop) => loop.role), [
      SketchRegionRole.outer,
      SketchRegionRole.hole,
      SketchRegionRole.island,
      SketchRegionRole.hole,
    ]);
    expect(result.loops[3].parentLoopId, 'l2');
  });

  test('classifies two holes under the same external loop', () {
    final result = classifier.classify([
      _loop('outer', _square(0, 0, 20)),
      _loop('hole-a', _square(2, 2, 3)),
      _loop('hole-b', _square(12, 2, 3)),
    ]);
    expect(result.conclusive, isTrue);
    expect(
      result.loops.where((loop) => loop.role == SketchRegionRole.hole),
      hasLength(2),
    );
    expect(
      result.loops
          .where((loop) => loop.role == SketchRegionRole.hole)
          .every((loop) => loop.parentLoopId == 'outer'),
      isTrue,
    );
  });

  test('does not depend on winding orientation', () {
    final result = classifier.classify([
      _loop('outer', _square(0, 0, 10, reverse: true)),
      _loop('hole', _square(2, 2, 3)),
    ]);
    expect(result.conclusive, isTrue);
    expect(result.loops[0].role, SketchRegionRole.outer);
    expect(result.loops[1].role, SketchRegionRole.hole);
  });

  test('rejects tangency and crossings', () {
    final tangent = classifier.classify([
      _loop('a', _square(0, 0, 2)),
      _loop('b', _square(2, 0, 2)),
    ]);
    final crossing = classifier.classify([
      _loop('a', [
        const SketchVector(0, 0),
        const SketchVector(4, 4),
        const SketchVector(1, 3),
        const SketchVector(3, 0),
        const SketchVector(0, 0),
      ]),
    ]);
    expect(tangent.conclusive, isFalse);
    expect(
      tangent.diagnostics.single.code,
      SketchRegionDiagnosticCode.boundaryContact,
    );
    expect(crossing.conclusive, isFalse);
    expect(
      crossing.diagnostics.single.code,
      SketchRegionDiagnosticCode.selfIntersection,
    );
  });

  test('rejects partial overlap and a vertex on the parent boundary', () {
    final partial = classifier.classify([
      _loop('outer', _square(0, 0, 5)),
      _loop('overlap', _square(3, 1, 5)),
    ]);
    final boundaryVertex = classifier.classify([
      _loop('outer', _square(0, 0, 10)),
      _loop('touching', _square(0, 2, 3)),
    ]);
    expect(partial.conclusive, isFalse);
    expect(boundaryVertex.conclusive, isFalse);
    expect(
      partial.diagnostics.single.code,
      SketchRegionDiagnosticCode.boundaryContact,
    );
    expect(
      boundaryVertex.diagnostics.single.code,
      SketchRegionDiagnosticCode.boundaryContact,
    );
  });

  test('rejects open and degenerate loops', () {
    final result = classifier.classify([
      const SketchRegionLoopInput(
        id: 'open',
        entityIds: ['open'],
        points: [SketchVector(0, 0), SketchVector(1, 0), SketchVector(1, 1)],
        closed: false,
      ),
      _loop('flat', [
        const SketchVector(0, 0),
        const SketchVector(1, 0),
        const SketchVector(2, 0),
      ]),
    ]);
    expect(result.conclusive, isFalse);
    expect(
      result.diagnostics.map((item) => item.code),
      containsAll([
        SketchRegionDiagnosticCode.openLoop,
        SketchRegionDiagnosticCode.degenerateLoop,
      ]),
    );
  });

  test('does not classify an explicitly insufficient curve sample', () {
    final result = classifier.classify([
      SketchRegionLoopInput(
        id: 'spline',
        entityIds: const ['spline-1'],
        points: _square(0, 0, 10),
        samplingSufficient: false,
      ),
    ]);
    expect(result.conclusive, isFalse);
    expect(
      result.diagnostics.single.code,
      SketchRegionDiagnosticCode.insufficientSamples,
    );
  });

  test('excludes construction and reference loops', () {
    final result = classifier.classify([
      _loop('outer', _square(0, 0, 10)),
      SketchRegionLoopInput(
        id: 'construction',
        entityIds: ['c'],
        points: _square(1, 1, 1),
        construction: true,
      ),
      SketchRegionLoopInput(
        id: 'reference',
        entityIds: ['r'],
        points: _square(2, 2, 1),
        reference: true,
      ),
    ]);
    expect(result.conclusive, isTrue);
    expect(result.excludedLoopIds, ['construction', 'reference']);
    expect(result.loops, hasLength(1));
  });

  test('preserves sampled arc or spline points and scale tolerance', () {
    final result = const SketchRegionClassifier(tolerance: .001).classify([
      _loop(
        'curve',
        [
          const SketchVector(0, 0),
          const SketchVector(2, 0),
          const SketchVector(2, 1),
          const SketchVector(1, 2),
          const SketchVector(0, 1),
          const SketchVector(0, 0),
        ],
        entities: ['arc-1', 'spline-1'],
      ),
    ]);
    expect(result.conclusive, isTrue);
    expect(result.loops.single.entityIds, ['arc-1', 'spline-1']);
    expect(result.loops.single.points, hasLength(5));
    expect(result.loops.single.absoluteArea, closeTo(3, 1e-9));
  });

  test('keeps classification stable when model scale changes', () {
    final small = const SketchRegionClassifier(
      tolerance: 1e-7,
    ).classify([_loop('small', _square(0, 0, .01))]);
    final large = const SketchRegionClassifier(
      tolerance: 1e-4,
    ).classify([_loop('large', _square(0, 0, 1000))]);
    expect(small.loops.single.role, SketchRegionRole.outer);
    expect(large.loops.single.role, SketchRegionRole.outer);
  });

  test('rejects duplicate identities and ambiguous boundary contacts', () {
    final result = classifier.classify([
      _loop('same', _square(0, 0, 3)),
      _loop('same', _square(5, 0, 3)),
    ]);
    expect(result.conclusive, isFalse);
    expect(
      result.diagnostics.single.code,
      SketchRegionDiagnosticCode.duplicateLoopId,
    );
  });
}
