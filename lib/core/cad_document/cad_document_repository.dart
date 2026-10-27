import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'cad_document.dart';

class CadDocumentRepository {
  const CadDocumentRepository();
  static final Object _lockZoneKey = Object();
  static const snapshotManifestName = 'cad-document.snapshot.txn.json';
  static const snapshotBackupName = '.cad-document-snapshot-pending';
  static const _snapshotMarkerName = 'backup.complete';
  static const _snapshotBackupSchema = 'flcad.cad-snapshot-backup';

  File file(Directory project) =>
      File(path.join(project.path, 'cad-document.json'));
  Future<CadDocument> load(String projectId, Directory project) =>
      withProjectLock(project, () => _loadUnlocked(projectId, project));

  Future<CadDocument> _loadUnlocked(String projectId, Directory project) async {
    final source = file(project);
    if (!await source.exists()) return CadDocument.empty(projectId);
    final value = CadDocument.fromJson(
      Map<String, dynamic>.from(jsonDecode(await source.readAsString()) as Map),
    );
    if (value.projectId != projectId) {
      throw StateError(
        'CAD document project identity mismatch: '
        'expected=$projectId actual=${value.projectId} path=${source.path}',
      );
    }
    return value;
  }

  Future<void> save(CadDocument document, Directory project) =>
      withProjectLock(project, () => _atomic(file(project), document.toJson()));

  File historyFile(Directory project) =>
      File(path.join(project.path, 'cad-document-history.json'));

  Future<CadDocumentHistoryState> loadHistory(Directory project) =>
      withProjectLock(project, () => _loadHistoryUnlocked(project));

  Future<CadDocumentHistoryState> _loadHistoryUnlocked(
    Directory project,
  ) async {
    final source = historyFile(project);
    if (!await source.exists()) return const CadDocumentHistoryState();
    final json = Map<String, dynamic>.from(
      jsonDecode(await source.readAsString()) as Map,
    );
    if (json['schema'] != 'flcad.cad-document-history' ||
        json['version'] != 1 ||
        json['undo'] is! List ||
        json['redo'] is! List) {
      throw const FormatException('Invalid CAD document history.');
    }
    return CadDocumentHistoryState(
      undo: (json['undo'] as List)
          .map(
            (value) =>
                CadDocument.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList(),
      redo: (json['redo'] as List? ?? const [])
          .map(
            (value) =>
                CadDocument.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList(),
    );
  }

  Future<void> saveHistory(
    Directory project, {
    required Iterable<CadDocument> undo,
    required Iterable<CadDocument> redo,
  }) => withProjectLock(
    project,
    () => _atomic(historyFile(project), {
      'schema': 'flcad.cad-document-history',
      'version': 1,
      'undo': undo.map((value) => value.toJson()).toList(),
      'redo': redo.map((value) => value.toJson()).toList(),
    }),
  );

  File snapshotManifest(Directory project) =>
      File(path.join(project.path, snapshotManifestName));

  Directory snapshotBackup(Directory project) =>
      Directory(path.join(project.path, snapshotBackupName));

  /// Makes document and history one durable commit boundary.
  Future<T> saveSnapshot<T>(
    Directory project,
    Future<T> Function() persist,
  ) => withProjectLock(project, () async {
    final manifest = snapshotManifest(project);
    final backup = snapshotBackup(project);
    backup.createSync(recursive: true);
    try {
      for (final target in [file(project), historyFile(project)]) {
        if (target.existsSync()) {
          target.copySync(path.join(backup.path, path.basename(target.path)));
        }
      }
      final hashes = _snapshotBackupHashes(backup);
      _writeSnapshotBackupMarker(backup, hashes);
      _writeSnapshotManifest(manifest, phase: 'prepared', hashes: hashes);
      final result = await persist();
      _writeSnapshotManifest(
        manifest,
        phase: 'committed',
        hashes: hashes,
        committedHashes: _snapshotCurrentHashes(project),
      );
      _cleanupSnapshotArtifactsBestEffort(project);
      return result;
    } catch (_) {
      // Leave prepared artifacts for process-level recovery. The runtime can
      // discard them after its verified in-process restore succeeds.
      rethrow;
    }
  });

  /// Removes a pending snapshot after the caller restored both in-memory
  /// captures and verified the files.
  Future<void> discardSnapshotTransaction(Directory project) =>
      withProjectLock(project, () async {
        _cleanupSnapshotArtifactsBestEffort(project);
      });

  /// Captures both files for verified in-process rollback.
  // Capture is intentionally a lock-free diagnostic read. Writers replace
  // complete files under the project lock, so callers can inspect the last
  // published state while a transaction is paused without contending on the
  // writer handle.
  Future<Map<String, List<int>?>> captureFiles(Directory project) =>
      _captureFilesUnlocked(project);

  Future<Map<String, List<int>?>> _captureFilesUnlocked(
    Directory project,
  ) async {
    final result = <String, List<int>?>{};
    for (final target in [file(project), historyFile(project)]) {
      result[path.basename(target.path)] = target.existsSync()
          ? target.readAsBytesSync()
          : null;
    }
    return result;
  }

  Future<void> restoreFiles(
    Directory project,
    Map<String, List<int>?> backup,
  ) => withProjectLock(project, () => _restoreFilesUnlocked(project, backup));

  Future<void> _restoreFilesUnlocked(
    Directory project,
    Map<String, List<int>?> backup,
  ) async {
    for (final entry in backup.entries) {
      final target = File(path.join(project.path, entry.key));
      if (entry.value == null) {
        if (target.existsSync()) target.deleteSync();
      } else {
        await _atomicBytes(target, entry.value!);
      }
    }
    final restored = await captureFiles(project);
    for (final entry in backup.entries) {
      final actual = restored[entry.key];
      if (entry.value == null
          ? actual != null
          : actual == null ||
                base64Encode(actual) != base64Encode(entry.value!)) {
        throw StateError('CAD persistence recovery could not be verified.');
      }
    }
  }

  Future<void> _atomic(File target, Map<String, dynamic> value) =>
      _atomicBytes(target, utf8.encode(jsonEncode(value)));

  Future<T> withProjectLock<T>(
    Directory project,
    Future<T> Function() action, {
    Duration timeout = _ProjectFileLock.defaultTimeout,
  }) async {
    final active = Zone.current[_lockZoneKey] as Set<String>? ?? const {};
    final key = path.normalize(project.absolute.path);
    if (active.contains(key)) return action();
    final lock = await _ProjectFileLock.acquire(project, timeout: timeout);
    try {
      await _recoverPendingWrites(project);
      return await Zone.current
          .fork(
            zoneValues: {
              _lockZoneKey: {...active, key},
            },
          )
          .run(action);
    } finally {
      await lock.release();
    }
  }

  /// Storage boundary for fault injection; ownership passes to _atomicBytes.
  Future<Directory> createTemporaryDirectory(File target) =>
      target.parent.createTemp('${path.basename(target.path)}.txn-');

  Future<void> _atomicBytes(File target, List<int> bytes) async {
    final temporaryDirectory = await createTemporaryDirectory(target);
    final temporary = File(path.join(temporaryDirectory.path, 'payload'));
    final manifest = File('${target.path}.txn.json');
    final backup = File('${target.path}.bak');
    final previous = target.existsSync() ? target.readAsBytesSync() : null;
    final payloadHash = sha256.convert(bytes).toString();
    try {
      temporary.writeAsBytesSync(bytes, flush: true);
      if (previous != null) backup.writeAsBytesSync(previous, flush: true);
      _writeManifest(manifest, {
        'version': 1,
        'target': target.path,
        'temporary': temporary.path,
        'backup': previous == null ? null : backup.path,
        'previousExists': previous != null,
        'payloadSha256': payloadHash,
        'phase': 'prepared',
      });
      _replaceFile(temporary, target);
      _validatePayload(target, bytes, payloadHash);
      _writeManifest(manifest, {
        'version': 1,
        'target': target.path,
        'temporary': temporary.path,
        'backup': previous == null ? null : backup.path,
        'previousExists': previous != null,
        'payloadSha256': payloadHash,
        'phase': 'committed',
      });
      _cleanupManifestArtifacts(manifest, backup, temporaryDirectory);
    } catch (_) {
      await _recoverManifest(manifest);
      rethrow;
    } finally {
      if (temporaryDirectory.existsSync()) {
        temporaryDirectory.deleteSync(recursive: true);
      }
    }
  }

  void _writeManifest(File manifest, Map<String, Object?> value) {
    manifest.writeAsStringSync(jsonEncode(value), flush: true);
  }

  void _validatePayload(File target, List<int> bytes, String hash) {
    if (!target.existsSync() ||
        sha256.convert(target.readAsBytesSync()).toString() != hash) {
      throw StateError('CAD replacement validation failed for ${target.path}.');
    }
  }

  void _replaceFile(File source, File target) {
    if (!Platform.isWindows) {
      source.renameSync(target.path);
      return;
    }
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    final move = kernel32
        .lookupFunction<
          ffi.Int32 Function(
            ffi.Pointer<ffi.Uint16>,
            ffi.Pointer<ffi.Uint16>,
            ffi.Uint32,
          ),
          int Function(ffi.Pointer<ffi.Uint16>, ffi.Pointer<ffi.Uint16>, int)
        >('MoveFileExW');
    final from = source.path.toNativeUtf16().cast<ffi.Uint16>();
    final to = target.path.toNativeUtf16().cast<ffi.Uint16>();
    try {
      const flags = 0x1 | 0x8; // REPLACE_EXISTING | WRITE_THROUGH
      if (move(from, to, flags) == 0) {
        throw FileSystemException('MoveFileExW failed', target.path);
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  }

  Future<void> _recoverPendingWrites(Directory project) async {
    if (!project.existsSync()) return;
    await _recoverSnapshotManifest(project);
    for (final entity in project.listSync(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.txn.json')) continue;
      if (path.basename(entity.path) == snapshotManifestName) continue;
      await _recoverManifest(entity);
    }
  }

  void _writeSnapshotManifest(
    File manifest, {
    required String phase,
    required Map<String, String> hashes,
    Map<String, String>? committedHashes,
  }) {
    manifest.writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.cad-snapshot-transaction',
        'version': 1,
        'phase': phase,
        'files': [
          path.basename(file(manifest.parent).path),
          'cad-document-history.json',
        ],
        'hashes': hashes,
        'committedHashes': ?committedHashes,
      }),
      flush: true,
    );
  }

  Future<void> _recoverSnapshotManifest(Directory project) async {
    final manifest = snapshotManifest(project);
    final backup = snapshotBackup(project);
    if (!manifest.existsSync()) {
      if (backup.existsSync()) backup.deleteSync(recursive: true);
      return;
    }
    var committed = false;
    var manifestValid = false;
    Map<String, String>? hashes;
    Map<String, String>? committedHashes;
    try {
      final decoded = jsonDecode(manifest.readAsStringSync());
      final expectedFiles = {
        path.basename(file(project).path),
        path.basename(historyFile(project).path),
      };
      final files = decoded is Map ? decoded['files'] : null;
      final rawHashes = decoded is Map ? decoded['hashes'] : null;
      final rawCommittedHashes = decoded is Map
          ? decoded['committedHashes']
          : null;
      if (decoded is! Map ||
          decoded['schema'] != 'flcad.cad-snapshot-transaction' ||
          decoded['version'] != 1 ||
          (decoded['phase'] != 'prepared' && decoded['phase'] != 'committed') ||
          files is! List ||
          files.length != expectedFiles.length ||
          !expectedFiles.every(files.contains) ||
          rawHashes is! Map ||
          !_isValidSnapshotHashMap(
            rawHashes,
            expectedFiles,
            allowEmpty: true,
            requireAll: false,
          )) {
        throw const FormatException('Invalid CAD snapshot manifest.');
      }
      hashes = rawHashes.map(
        (key, value) => MapEntry(key as String, value as String),
      );
      committed = decoded['phase'] == 'committed';
      if (committed) {
        if (rawCommittedHashes is! Map ||
            !_isValidSnapshotHashMap(
              rawCommittedHashes,
              expectedFiles,
              requireAll: true,
            )) {
          throw const FormatException('Invalid committed CAD snapshot hashes.');
        }
        committedHashes = rawCommittedHashes.map(
          (key, value) => MapEntry(key as String, value as String),
        );
      }
      manifestValid = true;
    } on Object {
      final marker = File(path.join(backup.path, _snapshotMarkerName));
      if (!marker.existsSync()) rethrow;
    }
    if (committed) {
      var committedVerified = false;
      if (committedHashes != null) {
        try {
          committedVerified = _verifySnapshotTargetHashes(
            project,
            committedHashes,
          );
        } on Object {
          // Fall through to the independently verified backup.
        }
      }
      if (committedVerified) {
        _cleanupSnapshotArtifactsBestEffort(project);
        return;
      }
    }
    final markerHashes = _loadSnapshotBackupMarker(backup);
    var manifestVerified = false;
    if (hashes != null && backup.existsSync()) {
      try {
        _verifySnapshotBackupHashes(backup, hashes);
        manifestVerified = true;
      } on Object {
        // The marker provides a second, independently written proof below.
      }
    }
    var markerVerified = false;
    if (markerHashes != null &&
        (manifestValid || markerHashes.isNotEmpty) &&
        backup.existsSync()) {
      try {
        _verifySnapshotBackupHashes(backup, markerHashes);
        markerVerified = true;
      } on Object {
        // A corrupt marker cannot authorize restoration.
      }
    }
    if (!manifestVerified && !markerVerified) {
      if (hashes != null &&
          !backup.existsSync() &&
          _verifySnapshotTargetHashes(project, hashes)) {
        _cleanupSnapshotArtifacts(project);
        return;
      }
      throw StateError('CAD snapshot backup integrity could not be proven.');
    }
    final previous = <String, List<int>?>{};
    for (final target in [file(project), historyFile(project)]) {
      final copied = File(path.join(backup.path, path.basename(target.path)));
      previous[path.basename(target.path)] = copied.existsSync()
          ? copied.readAsBytesSync()
          : null;
    }
    await _restoreFilesUnlocked(project, previous);
    _cleanupSnapshotArtifacts(project);
  }

  void _cleanupSnapshotArtifacts(Directory project) {
    final manifest = snapshotManifest(project);
    if (manifest.existsSync()) {
      manifest.deleteSync();
    }
    final backup = snapshotBackup(project);
    if (backup.existsSync()) backup.deleteSync(recursive: true);
  }

  void _cleanupSnapshotArtifactsBestEffort(Directory project) {
    try {
      _cleanupSnapshotArtifacts(project);
    } on FileSystemException {
      // A committed snapshot is authoritative. A later lock acquisition
      // retries cleanup of the committed manifest/backup.
    }
  }

  Map<String, String> _snapshotBackupHashes(Directory backup) {
    final result = <String, String>{};
    for (final target in [file(backup.parent), historyFile(backup.parent)]) {
      final copied = File(path.join(backup.path, path.basename(target.path)));
      if (copied.existsSync()) {
        result[path.basename(target.path)] = sha256
            .convert(copied.readAsBytesSync())
            .toString();
      }
    }
    return result;
  }

  Map<String, String> _snapshotCurrentHashes(Directory project) {
    final result = <String, String>{};
    for (final target in [file(project), historyFile(project)]) {
      if (target.existsSync()) {
        result[path.basename(target.path)] = sha256
            .convert(target.readAsBytesSync())
            .toString();
      }
    }
    return result;
  }

  void _writeSnapshotBackupMarker(
    Directory backup,
    Map<String, String> hashes,
  ) {
    File(path.join(backup.path, _snapshotMarkerName)).writeAsStringSync(
      jsonEncode({
        'schema': _snapshotBackupSchema,
        'version': 1,
        'files': hashes,
      }),
      flush: true,
    );
  }

  Map<String, String>? _loadSnapshotBackupMarker(Directory backup) {
    final marker = File(path.join(backup.path, _snapshotMarkerName));
    if (!marker.existsSync()) return null;
    try {
      final value = jsonDecode(marker.readAsStringSync());
      final files = value is Map ? value['files'] : null;
      if (value is! Map ||
          value['schema'] != _snapshotBackupSchema ||
          value['version'] != 1 ||
          !_isValidSnapshotHashMap(
            files,
            {
              path.basename(file(backup.parent).path),
              path.basename(historyFile(backup.parent).path),
            },
            allowEmpty: true,
            requireAll: false,
          )) {
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

  bool _verifySnapshotTargetHashes(
    Directory project,
    Map<String, String> expected,
  ) {
    final actual = <String, String>{};
    for (final target in [file(project), historyFile(project)]) {
      if (!target.existsSync()) continue;
      actual[path.basename(target.path)] = sha256
          .convert(target.readAsBytesSync())
          .toString();
    }
    return actual.length == expected.length &&
        expected.entries.every((entry) => actual[entry.key] == entry.value);
  }

  bool _isValidSnapshotHashMap(
    Object? value,
    Set<String> allowed, {
    bool allowEmpty = false,
    required bool requireAll,
  }) {
    if (value is! Map || (!allowEmpty && value.isEmpty)) return false;
    for (final entry in value.entries) {
      if (entry.key is! String ||
          !allowed.contains(entry.key) ||
          entry.value is! String ||
          !_hexSha256.hasMatch(entry.value as String)) {
        return false;
      }
    }
    return !requireAll || value.length == allowed.length;
  }

  static final _hexSha256 = RegExp(r'^[0-9a-f]{64}$');

  void _verifySnapshotBackupHashes(
    Directory backup,
    Map<String, String> expected,
  ) {
    final actual = _snapshotBackupHashes(backup);
    if (actual.length != expected.length ||
        expected.entries.any((entry) => actual[entry.key] != entry.value)) {
      throw const FormatException('CAD snapshot backup hash mismatch.');
    }
  }

  Future<void> _recoverManifest(File manifest) async {
    if (!manifest.existsSync()) return;
    late Map<String, dynamic> raw;
    try {
      final decoded = jsonDecode(manifest.readAsStringSync());
      if (decoded is! Map) {
        throw const FormatException('Manifest is not a JSON object.');
      }
      raw = Map<String, dynamic>.from(decoded);
      final targetValue = raw['target'];
      final temporaryValue = raw['temporary'];
      final backupValue = raw['backup'];
      final hashValue = raw['payloadSha256'];
      final phaseValue = raw['phase'];
      final previousExists = raw['previousExists'];
      if (raw['version'] != 1 ||
          targetValue is! String ||
          temporaryValue is! String ||
          (backupValue != null && backupValue is! String) ||
          hashValue is! String ||
          !_hexSha256.hasMatch(hashValue) ||
          !const {'prepared', 'committed'}.contains(phaseValue) ||
          previousExists is! bool) {
        throw const FormatException('Invalid CAD transaction manifest.');
      }
      final manifestTarget = File(
        manifest.path.substring(0, manifest.path.length - '.txn.json'.length),
      );
      final expectedTarget = path.normalize(manifestTarget.path);
      final temporaryFile = File(temporaryValue);
      final expectedBackup = '${manifestTarget.path}.bak';
      if (path.normalize(targetValue) != expectedTarget ||
          path.normalize(temporaryFile.parent.path) !=
              path.normalize(path.dirname(expectedTarget)) ||
          !path
              .basename(temporaryFile.parent.path)
              .startsWith('${path.basename(expectedTarget)}.txn-') ||
          (backupValue != null &&
              path.normalize(backupValue as String) !=
                  path.normalize(expectedBackup))) {
        throw const FormatException('CAD manifest target mismatch.');
      }
    } on Object {
      _recoverCorruptManifest(manifest);
      return;
    }
    final target = File(raw['target'] as String);
    final temporary = File(raw['temporary'] as String);
    final backupPath = raw['backup'] as String?;
    final backup = backupPath == null ? null : File(backupPath);
    final expected = raw['payloadSha256'] as String;
    final targetMatches =
        _isValidCadPayload(
          target,
          history: path.basename(target.path) == 'cad-document-history.json',
        ) &&
        sha256.convert(target.readAsBytesSync()).toString() == expected;
    if (targetMatches) {
      _cleanupManifestArtifacts(manifest, backup, temporary.parent);
      return;
    }
    if (backup != null && backup.existsSync()) {
      if (!_isValidCadPayload(
        backup,
        history: path.basename(target.path) == 'cad-document-history.json',
      )) {
        throw StateError(
          'CAD recovery backup is not a valid payload: ${backup.path}',
        );
      }
      _replaceFile(backup, target);
    } else if (raw['previousExists'] != true && target.existsSync()) {
      target.deleteSync();
    } else if (raw['previousExists'] == true) {
      throw StateError(
        'Committed CAD target does not match its hash and has no backup: '
        '${target.path}',
      );
    }
    _cleanupManifestArtifacts(manifest, null, temporary.parent);
  }

  void _recoverCorruptManifest(File manifest) {
    const suffix = '.txn.json';
    final target = File(
      manifest.path.substring(0, manifest.path.length - suffix.length),
    );
    final backup = File('${target.path}.bak');
    final history = path.basename(target.path) == 'cad-document-history.json';
    if (_isValidCadPayload(backup, history: history)) {
      _replaceFile(backup, target);
      _cleanupCorruptManifest(manifest, target, backup);
      return;
    }
    if (_isValidCadPayload(target, history: history)) {
      _cleanupCorruptManifest(manifest, target, backup);
      return;
    }
    throw StateError(
      'Corrupt CAD manifest has no readable target or backup: '
      '${manifest.path}; target=${target.existsSync()} '
      'valid=${_isValidCadPayload(target, history: history)}; '
      'backup=${backup.existsSync()} '
      'valid=${_isValidCadPayload(backup, history: history)}',
    );
  }

  bool _isReadableJson(File file) {
    if (!file.existsSync()) return false;
    try {
      jsonDecode(file.readAsStringSync());
      return true;
    } on Object {
      return false;
    }
  }

  bool _isValidCadPayload(File file, {required bool history}) {
    if (!_isReadableJson(file)) return false;
    try {
      final value = jsonDecode(file.readAsStringSync());
      if (value is! Map) return false;
      if (history) {
        final json = Map<String, dynamic>.from(value);
        return json['schema'] == 'flcad.cad-document-history' &&
            json['version'] == 1 &&
            json['undo'] is List &&
            json['redo'] is List &&
            (json['undo'] as List).every((item) => item is Map) &&
            (json['redo'] as List).every((item) => item is Map);
      }
      CadDocument.fromJson(Map<String, dynamic>.from(value));
      return true;
    } on Object {
      return false;
    }
  }

  void _cleanupCorruptManifest(File manifest, File target, File backup) {
    if (manifest.existsSync()) manifest.deleteSync();
    if (backup.existsSync()) backup.deleteSync();
    final prefix = '${path.basename(target.path)}.txn-';
    for (final entry in manifest.parent.listSync(followLinks: false)) {
      if (entry is Directory && path.basename(entry.path).startsWith(prefix)) {
        entry.deleteSync(recursive: true);
      }
    }
  }

  void _cleanupManifestArtifacts(
    File manifest,
    File? backup,
    Directory temporaryDirectory,
  ) {
    if (manifest.existsSync()) manifest.deleteSync();
    if (backup != null && backup.existsSync()) backup.deleteSync();
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  }
}

class _ProjectFileLock {
  _ProjectFileLock(this._handle, [this._testRelease]);
  final RandomAccessFile? _handle;
  final Completer<void>? _testRelease;
  static final Map<String, Future<void>> _testTails = {};
  static const defaultTimeout = Duration(seconds: 30);

  static bool get _usesFlutterTesterLock =>
      path.basename(Platform.resolvedExecutable).toLowerCase() ==
      'flutter_tester.exe';

  static Future<_ProjectFileLock> acquire(
    Directory project, {
    Duration timeout = defaultTimeout,
  }) async {
    final key = path.normalize(project.absolute.path);
    if (_usesFlutterTesterLock) {
      final previous = _testTails[key] ?? Future<void>.value();
      final release = Completer<void>();
      _testTails[key] = previous.then((_) => release.future);
      try {
        await previous.timeout(timeout);
      } on TimeoutException {
        if (!release.isCompleted) release.complete();
        rethrow;
      }
      return _ProjectFileLock(null, release);
    }
    final file = File(path.join(project.path, '.flcad-cad-document.lock'));
    final handle = await file.open(mode: FileMode.append);
    final clock = Stopwatch()..start();
    try {
      while (true) {
        try {
          await handle.lock(FileLock.exclusive);
          break;
        } on PathAccessException catch (error) {
          if (error.osError?.errorCode != 33) rethrow;
          if (clock.elapsed >= timeout) {
            throw TimeoutException(
              'Timed out waiting for project lock: ${project.path}',
              timeout,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      return _ProjectFileLock(handle);
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  Future<void> release() async {
    final testRelease = _testRelease;
    if (testRelease != null) {
      if (!testRelease.isCompleted) testRelease.complete();
      return;
    }
    final handle = _handle;
    if (handle == null) throw StateError('CAD project lock handle missing.');
    try {
      await handle.unlock();
    } finally {
      await handle.close();
    }
  }
}

class CadDocumentHistoryState {
  const CadDocumentHistoryState({this.undo = const [], this.redo = const []});
  final List<CadDocument> undo;
  final List<CadDocument> redo;
}
