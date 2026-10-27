import '../../utils/id_generator.dart';

enum ConstraintHistoryAction {
  create,
  delete,
  modify,
  enable,
  disable,
  suppress,
  solve,
  rollback,
  undo,
  redo,
}

class ConstraintHistoryEntry {
  ConstraintHistoryEntry(this.action, this.targetId)
    : id = 'constraint-history:${IdGenerator.generate()}',
      timestamp = DateTime.now().toUtc();
  final String id;
  final ConstraintHistoryAction action;
  final String targetId;
  final DateTime timestamp;
  Map<String, dynamic> toJson() => {
    'id': id,
    'action': action.name,
    'targetId': targetId,
    'timestamp': timestamp.toIso8601String(),
  };
}

class ConstraintHistory {
  final List<ConstraintHistoryEntry> _entries = [];
  List<ConstraintHistoryEntry> get entries => List.unmodifiable(_entries);
  void record(ConstraintHistoryAction action, String target) =>
      _entries.add(ConstraintHistoryEntry(action, target));
  void restore(Iterable<ConstraintHistoryEntry> entries) {
    _entries
      ..clear()
      ..addAll(entries);
  }

  void truncate(int length) => _entries.removeRange(length, _entries.length);
}
