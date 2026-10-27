import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../analytics/sketch_analytics.dart';
import '../entities/sketch_entities.dart';
import '../graph/sketch_graph.dart';
import '../history/sketch_history.dart';
import '../models/sketch_models.dart';
import '../persistence/sketch_persistence_transaction.dart';

class SketchRepository {
  SketchRepository(this.projectDirectory);
  final Directory projectDirectory;
  static const _activeSketchFile = 'active-sketch.json';
  static const _ownershipFile = 'entities.owner.json';
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
  String _safeName(String id) {
    final safe = id.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    if (safe.isEmpty || safe == '.' || safe == '..') return '_';
    return safe;
  }
  Future<void> initialize() async {
    for (final path in paths) {
      _directory(path).createSync(recursive: true);
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
    await saveEntities(sketchId, [entity]);
  }

  /// Persists one Sketch's entities. A directory whose files all belong to
  /// this snapshot is written as one bundle, so a dense Section does not flush
  /// one file per segment. A loose file that is not in the snapshot stays on
  /// disk and the bundle is removed: load must see that file, and an older
  /// bundle must not restore an entity removed from the snapshot.
  Future<void> saveEntities(
    String sketchId,
    List<SketchEntity> entities, {
    Iterable<String>? previousEntityIds,
  }) async {
    await initialize();
    final separator = Platform.pathSeparator;
    final dir = Directory(
      '${_directory(paths[1]).path}$separator${_safeName(sketchId)}',
    );
    dir.createSync(recursive: true);
    final bundle = File('${dir.path}${separator}entities.bundle.json');
    final known = entities
        .map((entity) => '${_safeName(entity.id)}.json')
        .toSet();
    final previousOwned =
        _loadOwnedEntityFiles(dir) ??
        (previousEntityIds ?? const <String>[])
            .map((id) => '${_safeName(id)}.json')
            .toSet();
    if (_entityDirectoryHasExtras(dir, known)) {
      if (bundle.existsSync()) bundle.deleteSync();
      for (final entity in entities) {
        await _writeJsonAtomically(
          File('${dir.path}$separator${_safeName(entity.id)}.json'),
          entity.toJson(),
        );
      }
    } else if (entities.isNotEmpty || bundle.existsSync()) {
      await _writeJsonAtomically(bundle, [
        for (final entity in entities) entity.toJson(),
      ]);
    }
    for (final obsolete in previousOwned.difference(known)) {
      if (!_isValidOwnedEntityFile(obsolete)) continue;
      final file = File('${dir.path}$separator$obsolete');
      if (file.existsSync()) file.deleteSync();
    }
    await _writeJsonAtomically(File('${dir.path}$separator$_ownershipFile'), {
      'schema': 'flcad.sketch-entity-ownership',
      'version': 1,
      'files': known.toList()..sort(),
    });
  }

  bool _entityDirectoryHasExtras(Directory dir, Set<String> knownFileNames) {
    if (!dir.existsSync()) return false;
    for (final entry in dir.listSync()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (!name.endsWith('.json') ||
          name == 'entities.bundle.json' ||
          name == _ownershipFile) {
        continue;
      }
      if (!knownFileNames.contains(name)) return true;
    }
    return false;
  }

  Set<String>? _loadOwnedEntityFiles(Directory dir) {
    final file = File('${dir.path}${Platform.pathSeparator}$_ownershipFile');
    if (!file.existsSync()) return null;
    try {
      final value = jsonDecode(file.readAsStringSync());
      if (value is! Map ||
          value['schema'] != 'flcad.sketch-entity-ownership' ||
          value['version'] != 1 ||
          value['files'] is! List) {
        return null;
      }
      final files = value['files'] as List;
      if (files.any((entry) => !_isValidOwnedEntityFile(entry))) return null;
      return files.cast<String>().toSet();
    } on Object {
      return null;
    }
  }

  bool _isValidOwnedEntityFile(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.endsWith('/') ||
        value.endsWith('\\') ||
        value.contains('/') ||
        value.contains('\\') ||
        value != path.basename(value) ||
        path.isAbsolute(value)) {
      return false;
    }
    return value.endsWith('.json') &&
        value != 'entities.bundle.json' &&
        value != _ownershipFile;
  }

  Future<List<Sketch>> loadSketches() async {
    await const SketchPersistenceTransaction().recoverIfNeeded(
      projectDirectory,
    );
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

  Future<List<SketchEntity>> loadEntities(
    String sketchId, {
    Iterable<String>? expectedEntityIds,
  }) async {
    await const SketchPersistenceTransaction().recoverIfNeeded(
      projectDirectory,
    );
    final separator = Platform.pathSeparator;
    final dir = Directory(
      '${_directory(paths[1]).path}$separator${_safeName(sketchId)}',
    );
    if (!await dir.exists()) return [];
    final ownedFiles = _loadOwnedEntityFiles(dir);
    final expectedFiles = expectedEntityIds
        ?.map((id) => '${_safeName(id)}.json')
        .toSet();
    bool isCurrent(String name) {
      if (ownedFiles != null) return ownedFiles.contains(name);
      // A non-empty root membership is the only durable identity available in
      // a pre-ownership project. It prevents a deleted loose file from being
      // reabsorbed. An empty root list preserves the older write-order
      // behavior, allowing an ancestral snapshot to migrate without data loss.
      if (expectedFiles != null && expectedFiles.isNotEmpty) {
        return expectedFiles.contains(name);
      }
      return true;
    }

    final bundle = File('${dir.path}${separator}entities.bundle.json');
    if (await bundle.exists()) {
      final decoded = jsonDecode(await bundle.readAsString());
      if (decoded is List) {
        final bundled = <SketchEntity>[];
        for (final item in decoded) {
          final entity = SketchEntity.fromJson(
            (item as Map).cast<String, dynamic>(),
          );
          if (isCurrent('${_safeName(entity.id)}.json')) {
            bundled.add(entity);
          }
        }
        final bundledNames = bundled
            .map((entity) => '${_safeName(entity.id)}.json')
            .toSet();
        final extras = <SketchEntity>[];
        await for (final entry in dir.list()) {
          if (entry is! File) continue;
          final name = entry.uri.pathSegments.last;
          if (!name.endsWith('.json') ||
              name == 'entities.bundle.json' ||
              name == _ownershipFile ||
              bundledNames.contains(name)) {
            continue;
          }
          if (!isCurrent(name)) continue;
          final entity = SketchEntity.fromJson(
            (jsonDecode(await entry.readAsString()) as Map)
                .cast<String, dynamic>(),
          );
          extras.add(entity);
        }
        return [...bundled, ...extras];
      }
    }
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final result = <SketchEntity>[];
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      if (name == 'entities.bundle.json' || name == _ownershipFile) continue;
      if (!isCurrent(name)) continue;
      final entity = SketchEntity.fromJson(
        (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>(),
      );
      result.add(entity);
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
    await const SketchPersistenceTransaction().recoverIfNeeded(
      projectDirectory,
    );
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

  static int _atomicWriteSerial = 0;

  Future<void> _writeJsonAtomically(File target, Object value) async {
    final suffix = ++_atomicWriteSerial;
    final temporary = File('${target.path}.tmp-$suffix');
    final backup = File('${target.path}.bak-$suffix');
    var installed = false;
    try {
      final encoded = jsonEncode(value);
      if (!target.existsSync()) {
        target.writeAsStringSync(encoded, flush: true);
        installed = true;
        return;
      }
      temporary.writeAsStringSync(encoded, flush: true);
      if (target.existsSync()) target.renameSync(backup.path);
      temporary.renameSync(target.path);
      installed = true;
      if (backup.existsSync()) {
        unawaited(_deleteBestEffort(backup));
      }
    } catch (_) {
      if (!installed && !target.existsSync() && backup.existsSync()) {
        backup.renameSync(target.path);
      }
      rethrow;
    } finally {
      if (temporary.existsSync()) {
        temporary.deleteSync();
      }
      if (installed && backup.existsSync()) {
        unawaited(_deleteBestEffort(backup));
      }
    }
  }

  Future<void> _deleteBestEffort(File file) async {
    try {
      await file.delete();
    } on Object {
      // Windows scanners may briefly retain the backup. The installed target
      // is already durable; cleanup must not hold the Sketch command.
    }
  }
}

class SketchActiveMetadata {
  const SketchActiveMetadata._({
    required this.present,
    required this.valid,
    this.id,
  });
  const SketchActiveMetadata.missing() : this._(present: false, valid: false);
  const SketchActiveMetadata.invalid() : this._(present: true, valid: false);
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
