import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/core/cad_document/dependency_walk.dart';

void main() {
  for (final reverse in [false, true]) {
    test('5000 vertices visit each vertex and edge once reverse=$reverse', () {
      final ids = List.generate(5000, (i) => '$i');
      final calls = <String, int>{};
      final walk = DependencyWalk([...(reverse ? ids.reversed : ids), ...ids], (
        id,
      ) {
        calls.update(id, (n) => n + 1, ifAbsent: () => 1);
        final i = int.parse(id);
        return i == 4999 ? const [] : ['${i + 1}'];
      });
      expect(walk.vertexCount, 5000);
      expect(walk.edgeCount, 4999);
      expect(calls.values, everyElement(1));
      expect(walk.components.length, 5000);
      expect(walk.components.expand((e) => e).toSet(), ids.toSet());
    });
  }

  test(
    'overlapping cycles form one component independent of traversal order',
    () {
      const graph = {
        'A': ['B', 'C'],
        'B': ['A'],
        'C': ['B'],
        'X': ['A'],
      };
      for (final reverse in [false, true]) {
        final walk = DependencyWalk([
          'X',
          'X',
        ], (id) => reverse ? graph[id]!.reversed : graph[id]!);
        expect(
          walk.components,
          containsAll([
            {'A', 'B', 'C'},
            {'X'},
          ]),
        );
        expect(walk.vertexCount, 4);
        expect(walk.edgeCount, 5);
      }
    },
  );
}
