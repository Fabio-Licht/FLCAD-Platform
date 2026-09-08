/// Iterative Tarjan traversal of a reachable graph. Each vertex is expanded once
/// and each edge examined once, including duplicate roots and overlapping cycles.
class DependencyWalk {
  DependencyWalk(
    Iterable<String> roots,
    Iterable<String> Function(String) edges,
  ) {
    final indices = <String, int>{};
    final low = <String, int>{};
    final pending = <String>[];
    final onStack = <String>{};
    final frames = <(String, Iterator<String>)>[];
    void enter(String id) {
      indices[id] = vertexCount++;
      low[id] = indices[id]!;
      pending.add(id);
      onStack.add(id);
      frames.add((id, edges(id).iterator));
    }

    for (final root in roots) {
      if (indices.containsKey(root)) continue;
      enter(root);
      while (frames.isNotEmpty) {
        final (id, iterator) = frames.last;
        if (iterator.moveNext()) {
          edgeCount++;
          final next = iterator.current;
          if (!indices.containsKey(next)) {
            enter(next);
          } else if (onStack.contains(next) && indices[next]! < low[id]!) {
            low[id] = indices[next]!;
          }
          continue;
        }
        frames.removeLast();
        if (low[id] == indices[id]) {
          final component = <String>{};
          String member;
          do {
            member = pending.removeLast();
            onStack.remove(member);
            component.add(member);
          } while (member != id);
          components.add(Set.unmodifiable(component));
        }
        if (frames.isNotEmpty) {
          final parent = frames.last.$1;
          if (low[id]! < low[parent]!) low[parent] = low[id]!;
        }
      }
    }
  }

  final List<Set<String>> components = [];
  int vertexCount = 0;
  int edgeCount = 0;
}
