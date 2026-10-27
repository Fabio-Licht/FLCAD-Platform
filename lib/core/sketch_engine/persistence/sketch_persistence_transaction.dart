import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../cad_document/cad_document_repository.dart';

/// Adds cross-repository rollback around the existing Sketch JSON contract.
/// Repositories keep their normal files and formats; this is only a save
/// boundary for Sketch, constraints, dimensions and editor metadata.
final class SketchPersistenceTransaction {
  const SketchPersistenceTransaction();

  static const manifestFileName = 'sketch-save.txn.json';
  static const backupDirectoryName = '.sketch-save-pending';
  static const _backupCompleteFile = 'backup.complete';
  static const _backupSchema = 'flcad.sketch-snapshot-backup';

  static const _paths = <String>[
    'CAD/Sketch',
    'CAD/SketchEntities',
    'CAD/SketchHistory',
    'CAD/SketchGraph',
    'CAD/SketchAnalytics',
    'CAD/Constraints',
    'CAD/ConstraintGraph',
    'CAD/ConstraintHistory',
    'CAD/ConstraintAnalytics',
    'CAD/Dimensions',
    'CAD/SketchEditor',
    'CAD/SketchEditorHistory',
    'CAD/SketchEditorGraph',
    'CAD/SketchEditorAnalytics',
  ];

  Future<void> run(
    Directory project,
    Future<void> Function() persist, {
    void Function(String phase, int elapsedMicros)? reportTiming,
  }) => const CadDocumentRepository().withProjectLock(project, () async {
    await _recoverUnlocked(project);
    return _runUnlocked(project, persist, reportTiming: reportTiming);
  });

  /// Applies the durable snapshot left by an interrupted multi-file save.
  /// This is idempotent and shares the normal project lock.
  Future<void> recoverIfNeeded(Directory project) =>
      const CadDocumentRepository().withProjectLock(
        project,
        () => _recoverUnlocked(project),
      );

  Future<void> _runUnlocked(
    Directory project,
    Future<void> Function() persist, {
    void Function(String phase, int elapsedMicros)? reportTiming,
  }) async {
    final manifest = _manifest(project);
    final backup = _backup(project);
    if (backup.existsSync()) backup.deleteSync(recursive: true);
    backup.createSync(recursive: true);
    final existing = <String>[];
    var preserveRecovery = false;
    final clock = Stopwatch()..start();
    try {
      for (final relative in _paths) {
        final source = _child(project, relative);
        if (source.existsSync()) {
          existing.add(relative);
          _copyTree(source, _child(backup, relative));
        }
      }
      final hashes = _hashTree(backup);
      _writeBackupMarker(backup, hashes);
      _writeManifest(manifest, phase: 'prepared', hashes: hashes);
      reportTiming?.call('backup', clock.elapsedMicroseconds);
      try {
        await persist();
        _writeManifest(
          manifest,
          phase: 'committed',
          hashes: hashes,
          committedHashes: _hashProject(project),
        );
        reportTiming?.call('persist', clock.elapsedMicroseconds);
      } catch (error, stack) {
        try {
          _restoreFromBackup(project, backup, existing: existing);
        } catch (recovery, recoveryStack) {
          // The restore may itself fail after deleting part of the project.
          // Keep both the complete backup and its prepared manifest so the
          // next open can retry instead of destroying the recovery source.
          preserveRecovery = true;
          throw SketchPersistenceRecoveryFailure(
            error,
            recovery,
            stack,
            recoveryStack,
          );
        }
        Error.throwWithStackTrace(error, stack);
      }
    } finally {
      if (!preserveRecovery) {
        _cleanup(project);
      }
      reportTiming?.call('total', clock.elapsedMicroseconds);
    }
  }

  Future<void> _recoverUnlocked(Directory project) async {
    final manifest = _manifest(project);
    final backup = _backup(project);
    if (!manifest.existsSync()) {
      _deleteBestEffort(backup);
      return;
    }
    Map<String, String>? manifestHashes;
    Map<String, String>? committedHashes;
    var committed = false;
    var manifestValid = false;
    try {
      final raw = jsonDecode(manifest.readAsStringSync());
      final files = raw is Map ? raw['files'] : null;
      if (raw is! Map ||
          raw['schema'] != 'flcad.sketch-save-transaction' ||
          raw['version'] != 1 ||
          raw['backup'] != backupDirectoryName ||
          (raw['phase'] != 'prepared' && raw['phase'] != 'committed')) {
        throw const FormatException('Invalid Sketch transaction manifest.');
      }
      if (!_isValidHashes(files, allowEmpty: true)) {
        throw const FormatException('Invalid Sketch snapshot hashes.');
      }
      files as Map;
      manifestHashes = files.map(
        (key, value) => MapEntry(key as String, value as String),
      );
      committed = raw['phase'] == 'committed';
      if (committed) {
        final committedFiles = raw['committedFiles'];
        if (!_isValidHashes(committedFiles, allowEmpty: true)) {
          throw const FormatException(
            'Invalid committed Sketch snapshot hashes.',
          );
        }
        committedFiles as Map;
        committedHashes = committedFiles.map(
          (key, value) => MapEntry(key as String, value as String),
        );
      }
      manifestValid = true;
    } catch (error, stack) {
      final marker = File(
        '${backup.path}${Platform.pathSeparator}$_backupCompleteFile',
      );
      if (!marker.existsSync()) {
        throw SketchPersistenceRecoveryFailure(
          error,
          StateError('Sketch transaction backup is incomplete.'),
          stack,
          StackTrace.current,
        );
      }
    }
    var committedVerified = false;
    if (committed && committedHashes != null) {
      try {
        committedVerified = _verifyProjectHashes(project, committedHashes);
      } on Object {
        // A readable backup is the safe fallback if the published tree cannot
        // be inspected completely.
      }
    }
    if (committedVerified) {
      _cleanup(project);
      return;
    }
    final markerHashes = _loadBackupMarker(backup);
    var manifestVerified = false;
    if (manifestHashes != null && backup.existsSync()) {
      try {
        _verifyBackupHashes(backup, manifestHashes);
        manifestVerified = true;
      } on Object {
        // The manifest hash may itself be corrupt. The independently written
        // backup marker below is consulted before recovery is refused.
      }
    }
    var markerVerified = false;
    if (markerHashes != null &&
        (manifestValid || markerHashes.isNotEmpty) &&
        backup.existsSync()) {
      try {
        _verifyBackupHashes(backup, markerHashes);
        markerVerified = true;
      } on Object {
        // A corrupt marker cannot authorize restoration.
      }
    }
    if (!manifestVerified && !markerVerified) {
      if (manifestHashes != null &&
          !backup.existsSync() &&
          _verifyProjectHashes(project, manifestHashes)) {
        // A previous recovery restored the project and was interrupted during
        // cleanup. Repeating recovery is safe and only removes the manifest.
        _cleanup(project);
        return;
      }
      throw SketchPersistenceRecoveryFailure(
        const FormatException('Sketch snapshot integrity could not be proven.'),
        StateError('Sketch backup failed integrity verification.'),
        StackTrace.current,
        StackTrace.current,
      );
    }
    _restoreFromBackup(project, backup);
    _cleanup(project);
  }

  void _restoreFromBackup(
    Directory project,
    Directory backup, {
    List<String>? existing,
  }) {
    final marker = File(
      '${backup.path}${Platform.pathSeparator}$_backupCompleteFile',
    );
    if (!marker.existsSync()) {
      throw StateError('Sketch transaction backup is incomplete.');
    }
    final present =
        existing ??
        [
          for (final relative in _paths)
            if (_child(backup, relative).existsSync()) relative,
        ];
    for (final relative in _paths) {
      final target = _child(project, relative);
      if (target.existsSync()) target.deleteSync(recursive: true);
    }
    for (final relative in present) {
      _copyTree(_child(backup, relative), _child(project, relative));
    }
  }

  void _writeManifest(
    File manifest, {
    required String phase,
    required Map<String, String> hashes,
    Map<String, String>? committedHashes,
  }) {
    manifest.parent.createSync(recursive: true);
    manifest.writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.sketch-save-transaction',
        'version': 1,
        'phase': phase,
        'backup': backupDirectoryName,
        'files': hashes,
        'committedFiles': ?committedHashes,
      }),
      flush: true,
    );
  }

  void _cleanup(Directory project) {
    final manifest = _manifest(project);
    if (manifest.existsSync()) {
      try {
        manifest.deleteSync();
      } on FileSystemException {
        // Keep the backup until the manifest is gone, so a later pass can
        // verify and retry instead of observing prepared-without-backup.
        return;
      }
    }
    _deleteBestEffort(_backup(project));
  }

  File _manifest(Directory project) => File(
    '${project.path}${Platform.pathSeparator}CAD'
    '${Platform.pathSeparator}$manifestFileName',
  );

  Directory _backup(Directory project) => Directory(
    '${project.path}${Platform.pathSeparator}CAD'
    '${Platform.pathSeparator}$backupDirectoryName',
  );

  Map<String, String> _hashTree(Directory backup) {
    final result = <String, String>{};
    for (final entry in backup.listSync(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      final relative = entry.path.substring(backup.path.length + 1);
      if (relative == _backupCompleteFile) continue;
      result[relative.replaceAll(Platform.pathSeparator, '/')] = sha256
          .convert(entry.readAsBytesSync())
          .toString();
    }
    return result;
  }

  void _writeBackupMarker(Directory backup, Map<String, String> hashes) {
    File(
      '${backup.path}${Platform.pathSeparator}$_backupCompleteFile',
    ).writeAsStringSync(
      jsonEncode({'schema': _backupSchema, 'version': 1, 'files': hashes}),
      flush: true,
    );
  }

  Map<String, String>? _loadBackupMarker(Directory backup) {
    final marker = File(
      '${backup.path}${Platform.pathSeparator}$_backupCompleteFile',
    );
    if (!marker.existsSync()) return null;
    try {
      final value = jsonDecode(marker.readAsStringSync());
      final files = value is Map ? value['files'] : null;
      if (value is! Map ||
          value['schema'] != _backupSchema ||
          value['version'] != 1 ||
          !_isValidHashes(files, allowEmpty: true)) {
        return null;
      }
      files as Map;
      return files.map(
        (key, entry) => MapEntry(key as String, entry as String),
      );
    } on Object {
      return null;
    }
  }

  bool _verifyProjectHashes(Directory project, Map<String, String> expected) {
    return _sameHashes(_hashProject(project), expected);
  }

  Map<String, String> _hashProject(Directory project) {
    final actual = <String, String>{};
    for (final relative in _paths) {
      final source = _child(project, relative);
      if (!source.existsSync()) continue;
      for (final entry in source.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is! File) continue;
        final child = entry.path.substring(source.path.length + 1);
        actual['$relative/${child.replaceAll(Platform.pathSeparator, '/')}'] =
            sha256.convert(entry.readAsBytesSync()).toString();
      }
    }
    return actual;
  }

  void _verifyBackupHashes(Directory backup, Map<String, String> expected) {
    final actual = _hashTree(backup);
    if (!_sameHashes(actual, expected)) {
      throw const FormatException('Sketch snapshot hash mismatch.');
    }
  }

  bool _sameHashes(Map<String, String> actual, Map<String, String> expected) =>
      actual.length == expected.length &&
      expected.entries.every((entry) => actual[entry.key] == entry.value);

  bool _isValidHashes(Object? value, {bool allowEmpty = false}) {
    if (value is! Map || (!allowEmpty && value.isEmpty)) return false;
    for (final entry in value.entries) {
      if (entry.key is! String ||
          entry.value is! String ||
          !_hexSha256.hasMatch(entry.value as String) ||
          !_isSnapshotPath(entry.key as String)) {
        return false;
      }
    }
    return true;
  }

  bool _isSnapshotPath(String value) {
    if (value.contains('\\')) return false;
    final segments = value.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      return false;
    }
    return _paths.any((root) => value.startsWith('$root/'));
  }

  static final _hexSha256 = RegExp(r'^[0-9a-f]{64}$');

  void _deleteBestEffort(Directory directory) {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } on Object {
      // A Windows scanner may briefly retain a snapshot. The project save has
      // already completed; snapshot cleanup must not hold the UI command.
    }
  }

  Directory _child(Directory root, String relative) => Directory(
    '${root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
  );

  void _copyTree(FileSystemEntity source, FileSystemEntity target) {
    if (source is File) {
      target.parent.createSync(recursive: true);
      source.copySync(target.path);
      return;
    }
    final sourceDirectory = source as Directory;
    final targetDirectory = target as Directory;
    targetDirectory.createSync(recursive: true);
    for (final entry in sourceDirectory.listSync(followLinks: false)) {
      final name = entry.uri.pathSegments.lastWhere(
        (segment) => segment.isNotEmpty,
      );
      final targetEntry = FileSystemEntity.isDirectorySync(entry.path)
          ? Directory('${targetDirectory.path}${Platform.pathSeparator}$name')
          : File('${targetDirectory.path}${Platform.pathSeparator}$name');
      _copyTree(entry, targetEntry);
    }
  }
}

final class SketchPersistenceRecoveryFailure implements Exception {
  const SketchPersistenceRecoveryFailure(
    this.original,
    this.recovery,
    this.originalStack,
    this.recoveryStack,
  );
  final Object original, recovery;
  final StackTrace originalStack, recoveryStack;
  @override
  String toString() =>
      'Sketch persistence recovery required: $original; recovery: $recovery';
}
