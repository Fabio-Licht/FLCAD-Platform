import '../../utils/id_generator.dart';

enum SketchHistoryAction {
  create,
  delete,
  modify,
  move,
  rotate,
  scale,
  mirror,
  convert,
  reference,
  construction,
  undo,
  redo,
}

class SketchHistoryEntry {
  SketchHistoryEntry(this.action, this.targetId, {this.details = const {}})
    : id = 'skh:${IdGenerator.generate()}',
      timestamp = DateTime.now().toUtc();
  final String id;
  final SketchHistoryAction action;
  final String targetId;
  final DateTime timestamp;
  final Map<String, dynamic> details;
  Map<String, dynamic> toJson() => {
    'id': id,
    'action': action.name,
    'targetId': targetId,
    'timestamp': timestamp.toIso8601String(),
    'details': details,
  };
}

class SketchHistory {
  final List<SketchHistoryEntry> _entries = [];
  List<SketchHistoryEntry> get entries => List.unmodifiable(_entries);
  void record(
    SketchHistoryAction action,
    String targetId, {
    Map<String, dynamic> details = const {},
  }) => _entries.add(SketchHistoryEntry(action, targetId, details: details));
  void clear() => _entries.clear();
  void restore(Iterable<SketchHistoryEntry> entries) {
    _entries
      ..clear()
      ..addAll(entries);
  }

  void truncate(int length) => _entries.removeRange(length, _entries.length);
}
