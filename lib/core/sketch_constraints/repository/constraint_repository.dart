import 'dart:convert';
import 'dart:io';
import '../analytics/constraint_analytics.dart';
import '../graph/constraint_graph.dart';
import '../history/constraint_history.dart';
import '../models/constraint_models.dart';
import '../../sketch_engine/persistence/sketch_persistence_transaction.dart';

class ConstraintRepository {
  ConstraintRepository(this.projectDirectory);
  final Directory projectDirectory;
  final Map<String, String> _lastConstraintJson = <String, String>{};
  final Map<String, String> _lastDimensionJson = <String, String>{};
  static const paths = [
    'CAD/Constraints',
    'CAD/ConstraintGraph',
    'CAD/ConstraintHistory',
    'CAD/ConstraintAnalytics',
    'CAD/Dimensions',
  ];
  Directory _dir(String p) => Directory(
    '${projectDirectory.path}${Platform.pathSeparator}${p.replaceAll('/', Platform.pathSeparator)}',
  );
  String _safe(String id) => id.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  Future<void> initialize() async {
    for (final p in paths) {
      await _dir(p).create(recursive: true);
    }
  }

  Future<void> save({
    required Iterable<SketchConstraint> constraints,
    required Iterable<SketchDimension> dimensions,
    required ConstraintGraphSet graphs,
    required ConstraintHistory history,
    required ConstraintAnalytics analytics,
  }) async {
    await initialize();
    final constraintList = constraints.toList(growable: false);
    final dimensionList = dimensions.toList(growable: false);
    for (final c in constraintList) {
      final target = File(
        '${_dir(paths[0]).path}${Platform.pathSeparator}${_safe(c.id)}.json',
      );
      final encoded = jsonEncode(c.toJson());
      if (_lastConstraintJson[c.id] == encoded) {
        continue;
      }
      await _writeJsonAtomically(target, c.toJson());
      _lastConstraintJson[c.id] = encoded;
    }
    for (final d in dimensionList) {
      final encoded = jsonEncode(d.toJson());
      if (_lastDimensionJson[d.id] == encoded) {
        continue;
      }
      await _writeJsonAtomically(
        File(
          '${_dir(paths[4]).path}${Platform.pathSeparator}${_safe(d.id)}.json',
        ),
        d.toJson(),
      );
      _lastDimensionJson[d.id] = encoded;
    }
    await _writeJsonAtomically(
      File('${_dir(paths[1]).path}${Platform.pathSeparator}graph.json'),
      graphs.toJson(),
    );
    await _writeJsonAtomically(
      File('${_dir(paths[2]).path}${Platform.pathSeparator}history.json'),
      history.entries.map((e) => e.toJson()).toList(),
    );
    await _writeJsonAtomically(
      File('${_dir(paths[3]).path}${Platform.pathSeparator}analytics.json'),
      analytics.toJson(),
    );
    // Remove obsolete records only after every replacement file was written.
    // A failed write therefore leaves the previous set recoverable.
    await _removeStaleJson(
      _dir(paths[0]),
      constraintList.map((value) => value.id),
    );
    await _removeStaleJson(
      _dir(paths[4]),
      dimensionList.map((value) => value.id),
    );
  }

  Future<void> _writeJsonAtomically(File target, Object value) async {
    // SketchPersistenceTransaction snapshots all repository directories before
    // entering this method. A synchronous replacement avoids a second
    // exists/rename chain that can remain pending on Windows when the scanner
    // briefly holds an existing JSON file. The outer snapshot is the recovery
    // boundary for a partial write.
    target.writeAsStringSync(jsonEncode(value));
  }

  Future<void> _removeStaleJson(
    Directory directory,
    Iterable<String> ids,
  ) async {
    final expected = ids.map((id) => '${_safe(id)}.json').toSet();
    await for (final entry in directory.list()) {
      if (entry is File && entry.path.endsWith('.json')) {
        final name = entry.uri.pathSegments.last;
        if (!expected.contains(name)) await entry.delete();
      }
    }
  }

  Future<List<SketchConstraint>> loadConstraints() async {
    await const SketchPersistenceTransaction().recoverIfNeeded(
      projectDirectory,
    );
    final d = _dir(paths[0]);
    if (!await d.exists()) return [];
    final result = <SketchConstraint>[];
    await for (final f in d.list()) {
      if (f is File && f.path.endsWith('.json')) {
        final value = SketchConstraint.fromJson(
          (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>(),
        );
        result.add(value);
        _lastConstraintJson[value.id] = jsonEncode(value.toJson());
      }
    }
    return result;
  }

  Future<List<SketchDimension>> loadDimensions() async {
    await const SketchPersistenceTransaction().recoverIfNeeded(
      projectDirectory,
    );
    final d = _dir(paths[4]);
    if (!await d.exists()) return [];
    final result = <SketchDimension>[];
    await for (final f in d.list()) {
      if (f is File && f.path.endsWith('.json')) {
        final value = SketchDimension.fromJson(
          (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>(),
        );
        result.add(value);
        _lastDimensionJson[value.id] = jsonEncode(value.toJson());
      }
    }
    return result;
  }
}

class ConstraintRepositoryFactory {
  const ConstraintRepositoryFactory();
  ConstraintRepository create(Directory project) =>
      ConstraintRepository(project);
}
