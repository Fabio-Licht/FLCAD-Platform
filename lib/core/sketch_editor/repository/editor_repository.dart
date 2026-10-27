import 'dart:convert';
import 'dart:io';
import '../analytics/editor_analytics.dart';
import '../graph/editor_graph.dart';
import '../history/editor_history.dart';

class EditorRepository {
  EditorRepository(this.projectDirectory);
  final Directory projectDirectory;
  String? _lastHistoryJson;
  String? _lastGraphJson;
  String? _lastAnalyticsJson;
  static const paths = [
    'CAD/SketchEditor',
    'CAD/SketchEditorHistory',
    'CAD/SketchEditorGraph',
    'CAD/SketchEditorAnalytics',
  ];
  Directory _dir(String p) => Directory(
    '${projectDirectory.path}${Platform.pathSeparator}${p.replaceAll('/', Platform.pathSeparator)}',
  );
  Future<void> save({
    required EditorHistory history,
    required EditorGraph graph,
    required EditorAnalytics analytics,
  }) async {
    for (final p in paths) {
      await _dir(p).create(recursive: true);
    }
    final historyJson = jsonEncode(
      history.entries.map((e) => e.toJson()).toList(),
    );
    if (_lastHistoryJson != historyJson) {
      await File(
        '${_dir(paths[1]).path}${Platform.pathSeparator}history.json',
      ).writeAsString(historyJson);
      _lastHistoryJson = historyJson;
    }
    final graphJson = jsonEncode(graph.toJson());
    if (_lastGraphJson != graphJson) {
      await File(
        '${_dir(paths[2]).path}${Platform.pathSeparator}graph.json',
      ).writeAsString(graphJson);
      _lastGraphJson = graphJson;
    }
    final analyticsJson = jsonEncode(analytics.toJson());
    if (_lastAnalyticsJson != analyticsJson) {
      await File(
        '${_dir(paths[3]).path}${Platform.pathSeparator}analytics.json',
      ).writeAsString(analyticsJson);
      _lastAnalyticsJson = analyticsJson;
    }
  }
}

class EditorRepositoryFactory {
  const EditorRepositoryFactory();
  EditorRepository create(Directory project) => EditorRepository(project);
}
