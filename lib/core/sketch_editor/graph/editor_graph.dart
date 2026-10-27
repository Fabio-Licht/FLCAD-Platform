class EditorGraph {
  final Map<String, Set<String>> _operations = {};
  Map<String, Set<String>> get operations => Map.unmodifiable(_operations);
  void record(String operationId, Iterable<String> entityIds) =>
      _operations[operationId] = entityIds.toSet();
  void remove(String operationId) => _operations.remove(operationId);
  Map<String, Set<String>> capture() => {
    for (final entry in _operations.entries)
      entry.key: Set<String>.of(entry.value),
  };
  void restore(Map<String, Set<String>> snapshot) {
    _operations
      ..clear()
      ..addAll({
        for (final entry in snapshot.entries)
          entry.key: Set<String>.of(entry.value),
      });
  }

  Map<String, dynamic> toJson() =>
      _operations.map((k, v) => MapEntry(k, v.toList()));
}
