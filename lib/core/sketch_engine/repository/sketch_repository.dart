import 'dart:convert';
import 'dart:io';

import '../analytics/sketch_analytics.dart';
import '../entities/sketch_entities.dart';
import '../graph/sketch_graph.dart';
import '../history/sketch_history.dart';
import '../models/sketch_models.dart';

class SketchRepository {
  SketchRepository(this.projectDirectory);
  final Directory projectDirectory;
  static const _activeSketchFile = 'active-sketch.json';
  static const paths = [
    'CAD/Sketch',
    'CAD/SketchEntities',
    'CAD/SketchHistory',
    'CAD/SketchGraph',
    'CAD/SketchAnalytics',
  ];
  Directory _directory(String relative) => Directory(
    '${projectDirectory.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
  );
  String _safeName(String id) => id.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  Future<void> initialize() async {
    for (final path in paths) {
      await _directory(path).create(recursive: true);
    }
  }

  Future<void> saveSketch(Sketch sketch) async {
    await initialize();
    await _writeJsonAtomically(
      File(
        '${_directory(paths[0]).path}${Platform.pathSeparator}${_safeName(sketch.id)}.json',
      ),
      sketch.toJson(),
    );
  }

  Future<void> saveEntity(String sketchId, SketchEntity entity) async {
    await initialize();
    final dir = Directory(
      '${_directory(paths[1]).path}${Platform.pathSeparator}${_safeName(sketchId)}',
    );
    await dir.create(recursive: true);
    await _writeJsonAtomically(
      File('${dir.path}${Platform.pathSeparator}${_safeName(entity.id)}.json'),
      entity.toJson(),
    );
  }

  Future<List<Sketch>> loadSketches() async {
    final dir = _directory(paths[0]);
    if (!await dir.exists()) return [];
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final result = <Sketch>[];
    for (final f in files) {
      result.add(
        Sketch.fromJson(
          (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>(),
        ),
      );
    }
    return result;
  }

  Future<List<SketchEntity>> loadEntities(String sketchId) async {
    final dir = Directory(
      '${_directory(paths[1]).path}${Platform.pathSeparator}${_safeName(sketchId)}',
    );
    if (!await dir.exists()) return [];
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final result = <SketchEntity>[];
    for (final f in files) {
      result.add(
        SketchEntity.fromJson(
          (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>(),
        ),
      );
    }
    return result;
  }

  Future<void> saveSupport({
    required SketchGraphSet graphs,
    required SketchHistory history,
    required SketchAnalytics analytics,
    String? activeSketchId,
    String? projectId,
  }) async {
    await initialize();
    await _writeJsonAtomically(
      File('${_directory(paths[2]).path}${Platform.pathSeparator}history.json'),
      history.entries.map((e) => e.toJson()).toList(),
    );
    await _writeJsonAtomically(
      File('${_directory(paths[3]).path}${Platform.pathSeparator}graph.json'),
      graphs.toJson(),
    );
    await _writeJsonAtomically(
      File(
        '${_directory(paths[4]).path}${Platform.pathSeparator}analytics.json',
      ),
      analytics.toJson(),
    );
    final activeFile = File(
      '${_directory(paths[2]).path}${Platform.pathSeparator}$_activeSketchFile',
    );
    await _writeJsonAtomically(activeFile, {
      'schema': 'flcad.sketch-active',
      'version': 1,
      'projectId': projectId,
      'activeSketchId': activeSketchId,
    });
  }

  /// Reads the project-level active Sketch identity. Missing or malformed
  /// metadata is treated as a legacy project and resolved deterministically by
  /// [SketchEngine], rather than by filesystem enumeration order.
  Future<String?> loadActiveSketchId() async {
    final metadata = await loadActiveSketchMetadata();
    return metadata.valid ? metadata.id : null;
  }

  Future<SketchActiveMetadata> loadActiveSketchMetadata({
    String? expectedProjectId,
  }) async {
    final file = File(
      '${_directory(paths[2]).path}${Platform.pathSeparator}$_activeSketchFile',
    );
    if (!await file.exists()) return const SketchActiveMetadata.missing();
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map ||
          value['schema'] != 'flcad.sketch-active' ||
          value['version'] != 1) {
        return const SketchActiveMetadata.invalid();
      }
      final storedProjectId = value['projectId'];
      if (storedProjectId != null &&
          (storedProjectId is! String ||
              (expectedProjectId != null &&
                  storedProjectId != expectedProjectId))) {
        return const SketchActiveMetadata.invalid();
      }
      final id = value['activeSketchId'];
      if (id != null && (id is! String || id.isEmpty)) {
        return const SketchActiveMetadata.invalid();
      }
      return SketchActiveMetadata.valid(id as String?);
    } on Object {
      return const SketchActiveMetadata.invalid();
    }
  }

  Future<void> _writeJsonAtomically(File target, Object value) async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final temporary = File('${target.path}.tmp-$suffix');
    final backup = File('${target.path}.bak-$suffix');
    var installed = false;
    try {
      await temporary.writeAsString(jsonEncode(value), flush: true);
      if (await target.exists()) await target.rename(backup.path);
      await temporary.rename(target.path);
      installed = true;
      if (await backup.exists()) {
        try {
          await backup.delete();
        } on Object {
          // A stale backup is recoverable and must not turn a successful save
          // into a false failure.
        }
      }
    } catch (_) {
      if (!installed &&
          !await target.exists() &&
          await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
      if (installed && await backup.exists()) {
        try {
          await backup.delete();
        } on Object {
          // Best-effort cleanup only.
        }
      }
    }
  }
}

class SketchActiveMetadata {
  const SketchActiveMetadata._({
    required this.present,
    required this.valid,
    this.id,
  });
  const SketchActiveMetadata.missing()
    : this._(present: false, valid: false);
  const SketchActiveMetadata.invalid()
    : this._(present: true, valid: false);
  const SketchActiveMetadata.valid(String? id)
    : this._(present: true, valid: true, id: id);

  final bool present;
  final bool valid;
  final String? id;
}

class SketchRepositoryFactory {
  const SketchRepositoryFactory();
  SketchRepository create(Directory projectDirectory) =>
      SketchRepository(projectDirectory);
}
