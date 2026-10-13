import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'panel_layout.dart';
import 'panel_layout_migration.dart';

class PanelLayoutLoadResult {
  const PanelLayoutLoadResult({
    required this.layout,
    required this.migration,
    this.error,
    this.fileExisted = false,
    this.readOnly = false,
  });

  final PanelLayout layout;
  final PanelLayoutMigrationReport migration;

  /// Non-null when the stored file could not be used (corrupt/unreadable).
  final String? error;
  final bool fileExisted;

  /// True when the stored file was written by a *newer* format: it is loaded
  /// read-only so unknown data is never silently overwritten.
  final bool readOnly;

  bool get recoveredFromError => error != null;
}

/// File operations seam so read/write/rename failures are testable.
abstract class PanelLayoutFileSystem {
  Future<bool> exists(File file);
  Future<String> read(File file);
  Future<void> ensureDirectory(Directory directory);
  Future<void> write(File file, String contents);
  Future<void> rename(File from, File to);
  Future<void> delete(File file);
}

class IoPanelLayoutFileSystem implements PanelLayoutFileSystem {
  const IoPanelLayoutFileSystem();

  @override
  Future<bool> exists(File file) => file.exists();

  @override
  Future<String> read(File file) => file.readAsString();

  @override
  Future<void> ensureDirectory(Directory directory) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
  }

  @override
  Future<void> write(File file, String contents) =>
      file.writeAsString(contents, flush: true);

  @override
  Future<void> rename(File from, File to) => from.rename(to.path);

  @override
  Future<void> delete(File file) async {
    if (await file.exists()) await file.delete();
  }
}

/// Per-user layout persistence.
///
/// The file lives in the application support directory (the same root the
/// desktop settings repository already uses) and is **never** written inside a
/// project directory, so no CAD/document artefact is touched. Writes are
/// atomic (temporary sibling + rename) and rotate through a `.bak` copy, so a
/// failed rename can never destroy the operator's last good layout. A payload
/// written by a newer format version is loaded read-only and refuses to be
/// overwritten unless the caller explicitly forces it.
abstract class PanelLayoutStoreBase {
  Future<PanelLayoutLoadResult> load();
  Future<void> save(PanelLayout layout, {bool force = false});
  Future<bool> delete();
}

class PanelLayoutStore extends PanelLayoutStoreBase {
  PanelLayoutStore(
    this.file, {
    PanelLayoutMigrator migrator = const PanelLayoutMigrator(),
    PanelLayoutFileSystem fileSystem = const IoPanelLayoutFileSystem(),
  }) : _migrator = migrator,
       _fileSystem = fileSystem;

  factory PanelLayoutStore.forConfigDirectory(Directory directory) =>
      PanelLayoutStore(File(path.join(directory.path, fileName)));

  static const String fileName = 'panel_layout.json';
  static const String backupSuffix = '.bak';

  final File file;
  final PanelLayoutMigrator _migrator;
  final PanelLayoutFileSystem _fileSystem;

  int? _loadedVersion;
  bool _futureVersionDetected = false;

  File get _temporaryFile => File('${file.path}.tmp');
  File get _backupFile => File('${file.path}$backupSuffix');

  /// Format version found in the stored file (null when it had none).
  int? get loadedVersion => _loadedVersion;

  /// True when the stored file came from a newer format version.
  bool get protectsFutureVersion => _futureVersionDetected;

  @override
  Future<PanelLayoutLoadResult> load() async {
    if (!await _fileSystem.exists(file)) {
      _loadedVersion = null;
      _futureVersionDetected = false;
      return PanelLayoutLoadResult(
        layout: PanelLayout.defaults().normalize(),
        migration: const PanelLayoutMigrationReport(
          notes: ['arquivo-ausente'],
          usedDefaults: true,
        ),
      );
    }
    try {
      final raw = await _fileSystem.read(file);
      final decoded = raw.trim().isEmpty ? null : jsonDecode(raw);
      final migration = _migrator.migrate(decoded);
      _loadedVersion = migration.report.sourceVersion;
      _futureVersionDetected =
          (migration.report.sourceVersion ?? PanelLayout.currentVersion) >
          PanelLayout.currentVersion;
      return PanelLayoutLoadResult(
        layout: migration.layout,
        migration: migration.report,
        fileExisted: true,
        readOnly: _futureVersionDetected,
      );
    } catch (error) {
      _loadedVersion = null;
      _futureVersionDetected = false;
      return PanelLayoutLoadResult(
        layout: PanelLayout.defaults().normalize(),
        migration: const PanelLayoutMigrationReport(
          notes: ['preferencias-ilegiveis'],
          usedDefaults: true,
        ),
        error: '$error',
        fileExisted: true,
      );
    }
  }

  @override
  Future<void> save(PanelLayout layout, {bool force = false}) async {
    if (_futureVersionDetected && !force) {
      throw StateError(
        'O arquivo de layout pertence a uma versão mais nova '
        '($_loadedVersion); sobrescrever destruiria dados desconhecidos. '
        'Use force: true apenas após migração explícita.',
      );
    }
    final directory = file.parent;
    await _fileSystem.ensureDirectory(directory);
    final payload = layout
        .copyWith(
          version: PanelLayout.currentVersion,
          updatedAt: DateTime.now().toUtc(),
        )
        .normalize();
    await _fileSystem.write(
      _temporaryFile,
      const JsonEncoder.withIndent('  ').convert(payload.toJson()),
    );
    try {
      await _fileSystem.rename(_temporaryFile, file);
      _loadedVersion = PanelLayout.currentVersion;
      _futureVersionDetected = false;
      return;
    } on Object {
      // Windows refuses to rename over an existing file. Rotate through a
      // backup so a failure can never destroy the last good layout.
      await _fileSystem.delete(_backupFile);
      var rotated = false;
      if (await _fileSystem.exists(file)) {
        await _fileSystem.rename(file, _backupFile);
        rotated = true;
      }
      try {
        await _fileSystem.rename(_temporaryFile, file);
      } on Object {
        if (rotated) {
          // Restore through a plain write: a rename failure must not be able
          // to leave the operator without a layout file.
          final previous = await _fileSystem.read(_backupFile);
          await _fileSystem.write(file, previous);
          await _fileSystem.delete(_backupFile);
        }
        await _fileSystem.delete(_temporaryFile);
        rethrow;
      }
      if (rotated) await _fileSystem.delete(_backupFile);
      _loadedVersion = PanelLayout.currentVersion;
      _futureVersionDetected = false;
    }
  }

  @override
  Future<bool> delete() async {
    var removed = false;
    if (await _fileSystem.exists(file)) {
      await _fileSystem.delete(file);
      removed = true;
    }
    await _fileSystem.delete(_temporaryFile);
    await _fileSystem.delete(_backupFile);
    return removed;
  }
}

/// In-memory store for tests and dry runs.
class MemoryPanelLayoutStore extends PanelLayoutStoreBase {
  MemoryPanelLayoutStore([PanelLayout? initial]) : _layout = initial;

  PanelLayout? _layout;
  int saveCount = 0;

  PanelLayout? get current => _layout;

  @override
  Future<PanelLayoutLoadResult> load() async => PanelLayoutLoadResult(
    layout: (_layout ?? PanelLayout.defaults()).normalize(),
    migration: PanelLayoutMigrationReport(
      sourceVersion: _layout?.version,
      usedDefaults: _layout == null,
    ),
    fileExisted: _layout != null,
  );

  @override
  Future<void> save(PanelLayout layout, {bool force = false}) async {
    _layout = layout.normalize();
    saveCount++;
  }

  @override
  Future<bool> delete() async {
    final had = _layout != null;
    _layout = null;
    return had;
  }
}
