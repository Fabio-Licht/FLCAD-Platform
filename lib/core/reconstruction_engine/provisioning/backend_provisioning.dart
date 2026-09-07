import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../backend/reconstruction_backend_contract.dart';
import '../backend/reconstruction_backend_manager.dart';

part 'colmap_external_activation_coordinator.dart';

const defaultBackendInstallationRoot = r'C:\ProgramData\FLSCAN\Backends';

enum BackendCertificationStatus { certified, notCertified, unsupported }

enum BackendInstallationOrigin { managed, external }

enum BackendInstallationStatus {
  notInstalled,
  installed,
  validating,
  certified,
  failed,
}

class ApprovedBackendRelease {
  const ApprovedBackendRelease({
    required this.backendId,
    required this.version,
    required this.downloadUri,
    required this.sha256,
    required this.signature,
    required this.architecture,
    required this.executableRelativePath,
  });

  final String backendId;
  final String version;
  final Uri downloadUri;
  final String sha256;
  final String signature;
  final String architecture;
  final String executableRelativePath;

  Map<String, dynamic> toJson() => {
    'backendId': backendId,
    'version': version,
    'downloadUri': downloadUri.toString(),
    'sha256': sha256,
    'signature': signature,
    'architecture': architecture,
    'executableRelativePath': executableRelativePath,
  };
}

class BackendInstallationRecord {
  const BackendInstallationRecord({
    required this.backendId,
    required this.version,
    required this.installedAt,
    required this.source,
    required this.sha256,
    required this.architecture,
    required this.status,
    required this.certification,
    required this.executablePath,
    this.origin = BackendInstallationOrigin.managed,
    this.lastError,
  });

  final String backendId;
  final String version;
  final DateTime installedAt;
  final Uri source;
  final String sha256;
  final String architecture;
  final BackendInstallationStatus status;
  final BackendCertificationStatus certification;
  final String executablePath;
  final BackendInstallationOrigin origin;
  final String? lastError;

  Map<String, dynamic> toJson() => {
    'backendId': backendId,
    'version': version,
    'installedAt': installedAt.toIso8601String(),
    'source': source.toString(),
    'sha256': sha256,
    'architecture': architecture,
    'status': status.name,
    'certification': certification.name,
    'executablePath': executablePath,
    'origin': origin.name,
    'lastError': lastError,
  };

  factory BackendInstallationRecord.fromJson(Map<String, dynamic> json) =>
      BackendInstallationRecord(
        backendId: json['backendId'] as String,
        version: json['version'] as String,
        installedAt: DateTime.parse(json['installedAt'] as String),
        source: Uri.parse(json['source'] as String),
        sha256: json['sha256'] as String,
        architecture: json['architecture'] as String,
        status: BackendInstallationStatus.values.byName(
          json['status'] as String,
        ),
        certification: BackendCertificationStatus.values.byName(
          json['certification'] as String,
        ),
        executablePath: json['executablePath'] as String,
        origin: BackendInstallationOrigin.values.byName(
          json['origin'] as String? ?? BackendInstallationOrigin.managed.name,
        ),
        lastError: json['lastError'] as String?,
      );
}

abstract interface class BackendProvisioningRepository {
  List<ApprovedBackendRelease> get approvedReleases;
  Future<List<BackendInstallationRecord>> loadInstallations();
  Future<void> saveInstallations(List<BackendInstallationRecord> records);
}

class FileBackendProvisioningRepository
    implements BackendProvisioningRepository {
  static int _temporarySequence = 0;

  FileBackendProvisioningRepository({
    required this.catalogFile,
    required this.installationsFile,
    required this.approvedReleases,
    BackendFileRename? renameFile,
    BackendFileDelete? deleteFile,
  }) : _renameFile = renameFile ?? _rename,
       _deleteFile = deleteFile ?? _delete;

  final File catalogFile;
  final File installationsFile;
  final BackendFileRename _renameFile;
  final BackendFileDelete _deleteFile;
  @override
  final List<ApprovedBackendRelease> approvedReleases;

  @override
  Future<List<BackendInstallationRecord>> loadInstallations() async {
    final backup = File('${installationsFile.path}.backup');
    Object? primaryFailure;
    if (await installationsFile.exists()) {
      try {
        return await _readRecords(installationsFile);
      } catch (error) {
        primaryFailure = error;
      }
    }
    if (await backup.exists()) {
      try {
        final records = await _readRecords(backup);
        if (!await installationsFile.exists()) {
          try {
            await _renameFile(backup, installationsFile.path);
          } on FileSystemException {
            // Loading the valid backup is still safe when rename fails.
          }
        }
        return records;
      } catch (backupFailure) {
        throw StateError(
          'Backend installation state and recovery backup are invalid: '
          '$primaryFailure; $backupFailure',
        );
      }
    }
    if (primaryFailure != null) {
      throw StateError(
        'Backend installation state is invalid: $primaryFailure',
      );
    }
    return const [];
  }

  @override
  /// Writes a complete same-directory temporary file before replacement.
  ///
  /// On Windows-compatible filesystems the previous file is kept as a backup
  /// across the two rename steps and restoration is best effort. This is not
  /// an ACID transaction and cannot guarantee durability across power loss.
  Future<void> saveInstallations(
    List<BackendInstallationRecord> records,
  ) async {
    await installationsFile.parent.create(recursive: true);
    final temporary = File(
      '${installationsFile.path}.tmp-$pid-'
      '${DateTime.now().microsecondsSinceEpoch}-${_temporarySequence++}',
    );
    final backup = File('${installationsFile.path}.backup');
    final displaced = File(
      '${installationsFile.path}.rollback-$pid-'
      '${DateTime.now().microsecondsSinceEpoch}-${_temporarySequence++}',
    );
    var primaryWasValid = false;
    var primaryWasDisplaced = false;
    try {
      final output = await temporary.open(mode: FileMode.writeOnly);
      try {
        await output.writeString(
          jsonEncode(records.map((record) => record.toJson()).toList()),
        );
        await output.flush();
      } finally {
        await output.close();
      }
      if (await installationsFile.exists()) {
        primaryWasValid = await _containsValidRecords(installationsFile);
        await _renameFile(installationsFile, displaced.path);
        primaryWasDisplaced = true;
      }
      try {
        await _renameFile(temporary, installationsFile.path);
      } catch (_) {
        if (primaryWasValid &&
            primaryWasDisplaced &&
            !await installationsFile.exists() &&
            await displaced.exists()) {
          try {
            await _renameFile(displaced, installationsFile.path);
          } on FileSystemException {
            // Best effort. A valid backup remains untouched when available.
          }
        }
        rethrow;
      }
      await _deleteBestEffort(displaced);
      await _deleteBestEffort(backup);
    } finally {
      await _deleteBestEffort(temporary);
    }
  }

  static Future<File> _rename(File source, String target) =>
      source.rename(target);

  static Future<void> _delete(File file) => file.delete();

  Future<void> _deleteBestEffort(File file) async {
    try {
      if (await file.exists()) await _deleteFile(file);
    } catch (_) {
      // Post-commit cleanup never changes a successful transaction result.
    }
  }

  static Future<bool> _containsValidRecords(File file) async {
    try {
      await _readRecords(file);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<BackendInstallationRecord>> _readRecords(File file) async {
    final values = jsonDecode(await file.readAsString()) as List;
    return values
        .map(
          (value) => BackendInstallationRecord.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        )
        .toList();
  }

  Future<void> saveCatalog() async {
    await catalogFile.parent.create(recursive: true);
    await catalogFile.writeAsString(
      jsonEncode(approvedReleases.map((release) => release.toJson()).toList()),
      flush: true,
    );
  }
}

abstract interface class BackendDownloadManager {
  Future<File> download(Uri uri, File destination);
}

abstract interface class BackendArchiveInstaller {
  Future<void> extract(File archive, Directory destination);
}

abstract interface class BackendChecksumVerifier {
  Future<bool> verify(File file, String expectedSha256);
}

abstract interface class BackendSignatureVerifier {
  Future<bool> verify(File file, String signature);
}

abstract interface class BackendSelfTest {
  Future<ReconstructionBackendCapabilities> validate(
    String backendId,
    String executablePath,
  );
}

typedef BackendCanonicalPathResolver = Future<String> Function(String value);
typedef BackendFileRename = Future<File> Function(File source, String target);
typedef BackendFileDelete = Future<void> Function(File file);
typedef BackendFileExists = Future<bool> Function(String value);
typedef BackendPreparedPublication = void Function();

final class PreparedExternalBackendCandidate {
  PreparedExternalBackendCandidate._(this._owner, this.record);

  final BackendProvisioningManager _owner;
  final BackendInstallationRecord record;
  bool _consumed = false;
}

class BackendProvisioningEvent {
  const BackendProvisioningEvent({
    required this.type,
    required this.backendId,
    required this.timestamp,
    this.message,
  });

  final String type;
  final String backendId;
  final DateTime timestamp;
  final String? message;

  Map<String, dynamic> toJson() => {
    'type': type,
    'backendId': backendId,
    'timestamp': timestamp.toIso8601String(),
    'message': message,
  };
}

class BackendProvisioningManager {
  BackendProvisioningManager({
    required this.repository,
    required this.downloader,
    required this.installer,
    required this.checksumVerifier,
    required this.signatureVerifier,
    required this.selfTest,
    Directory? installationRoot,
    BackendCanonicalPathResolver? canonicalPathResolver,
    BackendFileExists? externalFileExists,
    void Function(BackendProvisioningEvent event)? onEvent,
  }) : installationRoot =
           installationRoot ?? Directory(defaultBackendInstallationRoot),
       _canonicalPathResolver = canonicalPathResolver ?? _resolveCanonicalPath,
       _externalFileExists = externalFileExists ?? _fileExists,
       _onEvent = onEvent;

  final BackendProvisioningRepository repository;
  final BackendDownloadManager downloader;
  final BackendArchiveInstaller installer;
  final BackendChecksumVerifier checksumVerifier;
  final BackendSignatureVerifier signatureVerifier;
  final BackendSelfTest selfTest;
  final BackendCanonicalPathResolver _canonicalPathResolver;
  final BackendFileExists _externalFileExists;
  final Directory installationRoot;
  final void Function(BackendProvisioningEvent event)? _onEvent;
  List<BackendInstallationRecord> _installations = [];
  final _SerialQueue _persistenceQueue = _SerialQueue();

  List<BackendInstallationRecord> get installations =>
      List.unmodifiable(_installations);

  Future<List<BackendInstallationRecord>> discover() => _persistenceQueue.run(
    () async {
      final loaded = await repository.loadInstallations();
      final next = [for (final record in loaded) await _validateRecord(record)];
      await repository.saveInstallations(next);
      _installations = next;
      return installations;
    },
  );

  Future<BackendInstallationRecord> _validateRecord(
    BackendInstallationRecord record,
  ) async {
    if (record.origin == BackendInstallationOrigin.external) {
      return _validateExternalRecord(record);
    }
    if (record.status != BackendInstallationStatus.certified) {
      return record;
    }
    if (record.executablePath.isNotEmpty &&
        await File(record.executablePath).exists()) {
      try {
        final rootPath = await _canonicalInstallationRoot();
        final executablePath = await _canonicalPathResolver(
          record.executablePath,
        );
        if (_isWithin(rootPath, executablePath)) return record;
      } on FileSystemException {
        // Treat an unresolvable or escaped path as an invalid installation.
      }
    }
    return BackendInstallationRecord(
      backendId: record.backendId,
      version: record.version,
      installedAt: record.installedAt,
      source: record.source,
      sha256: record.sha256,
      architecture: record.architecture,
      status: BackendInstallationStatus.notInstalled,
      certification: BackendCertificationStatus.notCertified,
      executablePath: record.executablePath,
      origin: record.origin,
      lastError: 'Installed executable was not found',
    );
  }

  Future<BackendInstallationRecord> _validateExternalRecord(
    BackendInstallationRecord record,
  ) async {
    try {
      final executable = File(record.executablePath);
      _requireExpectedExecutable(record.backendId, executable.path);
      if (!path.isAbsolute(executable.path) || !await executable.exists()) {
        throw StateError('External executable was not found');
      }
      final canonical = await _canonicalPathResolver(executable.path);
      _requireExpectedExecutable(record.backendId, canonical);
      _event('validationStarted', record.backendId, canonical);
      final capabilities = await selfTest.validate(record.backendId, canonical);
      final validated = BackendInstallationRecord(
        backendId: record.backendId,
        version: capabilities.version,
        installedAt: record.installedAt,
        source: Uri.file(canonical),
        sha256: '',
        architecture: record.architecture,
        status: BackendInstallationStatus.installed,
        certification: BackendCertificationStatus.notCertified,
        executablePath: canonical,
        origin: BackendInstallationOrigin.external,
      );
      _event('externalValidated', record.backendId, capabilities.version);
      return validated;
    } catch (error) {
      _event('failed', record.backendId, error.toString());
      return BackendInstallationRecord(
        backendId: record.backendId,
        version: record.version,
        installedAt: record.installedAt,
        source: record.source,
        sha256: '',
        architecture: record.architecture,
        status: BackendInstallationStatus.notInstalled,
        certification: BackendCertificationStatus.notCertified,
        executablePath: record.executablePath,
        origin: BackendInstallationOrigin.external,
        lastError: 'External self test failed: $error',
      );
    }
  }

  Future<BackendInstallationRecord> registerExisting(
    String backendId, {
    required String executablePath,
    required bool authorized,
  }) async {
    if (!authorized) {
      throw StateError('External backend registration requires authorization');
    }
    _validatePathComponent(backendId, field: 'backendId');
    if (!path.isAbsolute(executablePath)) {
      throw ArgumentError.value(
        executablePath,
        'executablePath',
        'must be absolute',
      );
    }
    _requireExpectedExecutable(backendId, executablePath);
    final executable = File(executablePath);
    if (!await _externalFileExists(executable.path)) {
      throw ArgumentError.value(
        executablePath,
        'executablePath',
        'must identify an existing file',
      );
    }
    final canonical = await _canonicalPathResolver(executable.path);
    _requireExpectedExecutable(backendId, canonical);
    _event('externalRegistrationStarted', backendId, canonical);
    late final ReconstructionBackendCapabilities capabilities;
    try {
      capabilities = await selfTest.validate(backendId, canonical);
    } catch (error) {
      final failed = BackendInstallationRecord(
        backendId: backendId,
        version: 'undetected',
        installedAt: DateTime.now().toUtc(),
        source: Uri.file(canonical),
        sha256: '',
        architecture: 'external',
        status: BackendInstallationStatus.failed,
        certification: BackendCertificationStatus.notCertified,
        executablePath: canonical,
        origin: BackendInstallationOrigin.external,
        lastError: 'External self test failed: $error',
      );
      await _replaceAndSave(failed);
      _event('failed', backendId, failed.lastError);
      return failed;
    }
    final record = BackendInstallationRecord(
      backendId: backendId,
      version: capabilities.version,
      installedAt: DateTime.now().toUtc(),
      source: Uri.file(canonical),
      sha256: '',
      architecture: 'external',
      status: BackendInstallationStatus.installed,
      certification: BackendCertificationStatus.notCertified,
      executablePath: canonical,
      origin: BackendInstallationOrigin.external,
    );
    await _replaceAndSave(record);
    _event('externalRegistered', backendId, capabilities.version);
    return record;
  }

  /// Validates an explicitly selected external COLMAP without publishing it.
  Future<PreparedExternalBackendCandidate> prepareExisting(
    String backendId, {
    required String executablePath,
    required bool authorized,
  }) async {
    if (!authorized) {
      throw StateError('External backend validation requires authorization');
    }
    _validatePathComponent(backendId, field: 'backendId');
    if (!path.isAbsolute(executablePath)) {
      throw ArgumentError.value(
        executablePath,
        'executablePath',
        'must be absolute',
      );
    }
    _requireExpectedExecutable(backendId, executablePath);
    final executable = File(executablePath);
    if (!await _externalFileExists(executable.path)) {
      throw ArgumentError.value(
        executablePath,
        'executablePath',
        'must identify an existing file',
      );
    }
    final canonical = await _canonicalPathResolver(executable.path);
    _requireExpectedExecutable(backendId, canonical);
    _event('externalValidationStarted', backendId, canonical);
    try {
      final capabilities = await selfTest.validate(backendId, canonical);
      final record = BackendInstallationRecord(
        backendId: backendId,
        version: capabilities.version,
        installedAt: DateTime.now().toUtc(),
        source: Uri.file(canonical),
        sha256: '',
        architecture: 'external',
        status: BackendInstallationStatus.installed,
        certification: BackendCertificationStatus.notCertified,
        executablePath: canonical,
        origin: BackendInstallationOrigin.external,
      );
      _event('externalValidated', backendId, capabilities.version);
      return PreparedExternalBackendCandidate._(this, record);
    } catch (error, stackTrace) {
      _event('failed', backendId, 'External self test failed: $error');
      Error.throwWithStackTrace(
        StateError('External self test failed: $error'),
        stackTrace,
      );
    }
  }

  /// Persists a previously validated external COLMAP transactionally.
  Future<void> _verifyPreparedExistingPath(
    PreparedExternalBackendCandidate candidate,
  ) async {
    if (!identical(candidate._owner, this)) {
      throw StateError('Prepared candidate belongs to another manager');
    }
    if (candidate._consumed) {
      throw StateError('Prepared candidate was already consumed');
    }
    final record = candidate.record;
    if (record.backendId != 'colmap' ||
        record.origin != BackendInstallationOrigin.external ||
        record.status != BackendInstallationStatus.installed ||
        record.certification != BackendCertificationStatus.notCertified) {
      throw StateError('Prepared candidate is no longer valid');
    }
    if (!path.isAbsolute(record.executablePath)) {
      throw StateError('Prepared executable path is not absolute');
    }
    _requireExpectedExecutable(record.backendId, record.executablePath);
    final executable = File(record.executablePath);
    if (!await _externalFileExists(executable.path)) {
      throw StateError('Prepared executable no longer exists');
    }
    final canonical = await _canonicalPathResolver(executable.path);
    _requireExpectedExecutable(record.backendId, canonical);
    if (canonical != record.executablePath) {
      throw StateError('Prepared executable path is no longer canonical');
    }
  }

  void _claimPreparedExisting(PreparedExternalBackendCandidate candidate) {
    if (!identical(candidate._owner, this)) {
      throw StateError('Prepared candidate belongs to another manager');
    }
    if (candidate._consumed) {
      throw StateError('Prepared candidate was already consumed');
    }
    candidate._consumed = true;
  }

  Future<void> _commitPreparedExisting(
    PreparedExternalBackendCandidate candidate, {
    required bool authorized,
    required BackendPreparedPublication publish,
  }) async {
    if (!authorized) {
      throw StateError('External backend commit requires authorization');
    }
    await _verifyPreparedExistingPath(candidate);
    await _persistenceQueue.run(() async {
      _claimPreparedExisting(candidate);
      final record = candidate.record;
      final next = <BackendInstallationRecord>[
        ..._installations.where((item) => item.backendId != record.backendId),
        record,
      ];
      await repository.saveInstallations(next);
      _installations = next;
      publish();
      _event('externalCommitted', record.backendId, record.version);
    });
  }

  Future<void> _replaceAndSave(BackendInstallationRecord record) =>
      _persistenceQueue.run(() async {
        final next = [
          ..._installations.where((item) => item.backendId != record.backendId),
          record,
        ];
        await repository.saveInstallations(next);
        _installations = next;
      });

  static void _requireExpectedExecutable(String backendId, String value) {
    if (backendId != 'colmap') {
      throw ArgumentError.value(backendId, 'backendId', 'is not supported');
    }
    final expected = Platform.isWindows ? 'colmap.exe' : 'colmap';
    if (path.basename(value).toLowerCase() != expected) {
      throw ArgumentError.value(
        value,
        'executablePath',
        'must end with $expected',
      );
    }
  }

  ApprovedBackendRelease release(String backendId, {String? version}) {
    _validatePathComponent(backendId, field: 'backendId');
    if (version != null) _parseVersion(version);
    final matches = repository.approvedReleases
        .where(
          (item) =>
              item.backendId == backendId &&
              (version == null || item.version == version),
        )
        .map(_validateRelease);
    if (matches.isEmpty) {
      throw StateError('No approved release for backend $backendId');
    }
    return matches.reduce(
      (first, second) =>
          _compareVersions(first.version, second.version) >= 0 ? first : second,
    );
  }

  ApprovedBackendRelease _validateRelease(ApprovedBackendRelease value) {
    _validatePathComponent(value.backendId, field: 'backendId');
    _parseVersion(value.version);
    _validateRelativePath(
      value.executableRelativePath,
      field: 'executableRelativePath',
    );
    return value;
  }

  Future<BackendInstallationRecord> install(
    String backendId, {
    String? version,
    required bool authorized,
  }) async {
    if (!authorized) {
      throw StateError('Backend installation requires explicit authorization');
    }
    final approved = release(backendId, version: version);
    await installationRoot.create(recursive: true);
    final canonicalRoot = await _canonicalInstallationRoot();
    final target = Directory(
      '${installationRoot.path}${Platform.pathSeparator}${approved.backendId}${Platform.pathSeparator}${approved.version}',
    );
    final archive = File(
      '${target.parent.path}${Platform.pathSeparator}${approved.backendId}-${approved.version}.archive',
    );
    _event('downloadStarted', backendId);
    final downloaded = await downloader.download(approved.downloadUri, archive);
    if (!await checksumVerifier.verify(downloaded, approved.sha256)) {
      return _failed(approved, 'Checksum verification failed');
    }
    if (!await signatureVerifier.verify(downloaded, approved.signature)) {
      return _failed(approved, 'Signature verification failed');
    }
    _event('installStarted', backendId);
    await installer.extract(downloaded, target);
    final executable = File(
      '${target.path}${Platform.pathSeparator}${approved.executableRelativePath}',
    );
    if (!await executable.exists()) {
      return _failed(approved, 'Installed executable was not found');
    }
    final canonicalExecutable = await _canonicalPathResolver(executable.path);
    if (!_isWithin(canonicalRoot, canonicalExecutable)) {
      return _failed(
        approved,
        'Installed executable escapes installation root',
      );
    }
    _event('validationStarted', backendId);
    try {
      await selfTest.validate(backendId, canonicalExecutable);
    } catch (error) {
      return _failed(approved, 'Self test failed: $error');
    }
    final record = BackendInstallationRecord(
      backendId: approved.backendId,
      version: approved.version,
      installedAt: DateTime.now().toUtc(),
      source: approved.downloadUri,
      sha256: approved.sha256,
      architecture: approved.architecture,
      status: BackendInstallationStatus.certified,
      certification: BackendCertificationStatus.certified,
      executablePath: canonicalExecutable,
    );
    await _replaceAndSave(record);
    _event('certified', backendId);
    return record;
  }

  Future<void> remove(String backendId, {required bool authorized}) async {
    if (!authorized) throw StateError('Backend removal requires authorization');
    await _persistenceQueue.run(() async {
      final next = _installations
          .where((item) => item.backendId != backendId)
          .toList();
      await repository.saveInstallations(next);
      _installations = next;
    });
    _event('removed', backendId);
  }

  Future<BackendInstallationRecord> update(
    String backendId, {
    required bool authorized,
  }) => install(backendId, authorized: authorized);

  Future<BackendInstallationRecord> rollback(
    String backendId, {
    required String version,
    required bool authorized,
  }) => install(backendId, version: version, authorized: authorized);

  void _event(String type, String backendId, [String? message]) {
    try {
      _onEvent?.call(
        BackendProvisioningEvent(
          type: type,
          backendId: backendId,
          timestamp: DateTime.now().toUtc(),
          message: message,
        ),
      );
    } catch (_) {
      // Provisioning events are observational and never affect transactions.
    }
  }

  Future<BackendInstallationRecord> _failed(
    ApprovedBackendRelease release,
    String error,
  ) async {
    final record = BackendInstallationRecord(
      backendId: release.backendId,
      version: release.version,
      installedAt: DateTime.now().toUtc(),
      source: release.downloadUri,
      sha256: release.sha256,
      architecture: release.architecture,
      status: BackendInstallationStatus.failed,
      certification: BackendCertificationStatus.notCertified,
      executablePath: '',
      lastError: error,
    );
    await _replaceAndSave(record);
    _event('failed', release.backendId, error);
    return record;
  }

  Future<String> _canonicalInstallationRoot() =>
      _canonicalPathResolver(installationRoot.path);

  static Future<String> _resolveCanonicalPath(String value) =>
      File(value).resolveSymbolicLinks();

  static Future<bool> _fileExists(String value) => File(value).exists();

  static bool _isWithin(String root, String candidate) {
    final normalizedRoot = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    final caseSensitive = !Platform.isWindows;
    final comparedRoot = caseSensitive
        ? normalizedRoot
        : normalizedRoot.toLowerCase();
    final comparedCandidate = caseSensitive
        ? candidate
        : candidate.toLowerCase();
    return comparedCandidate.startsWith(comparedRoot);
  }

  static void _validatePathComponent(String value, {required String field}) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value) ||
        value == '.' ||
        value == '..') {
      throw ArgumentError.value(value, field, 'must be a safe path component');
    }
  }

  static void _validateRelativePath(String value, {required String field}) {
    if (value.isEmpty ||
        value.startsWith('/') ||
        value.startsWith(r'\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(value)) {
      throw ArgumentError.value(value, field, 'must be a relative path');
    }
    final segments = value.split(RegExp(r'[/\\]'));
    if (segments.any(
      (segment) =>
          segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._ -]*$').hasMatch(segment) ||
          segment.endsWith('.') ||
          segment.endsWith(' '),
    )) {
      throw ArgumentError.value(
        value,
        field,
        'contains an unsafe path segment',
      );
    }
  }

  static ({List<int> core, List<String>? prerelease}) _parseVersion(
    String value,
  ) {
    final match = RegExp(
      r'^(0|[1-9]\d*)(?:\.(0|[1-9]\d*))*'
      r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(value);
    if (match == null) {
      throw ArgumentError.value(value, 'version', 'must be a numeric version');
    }
    final prereleaseSeparator = value.indexOf('-');
    final core = prereleaseSeparator < 0
        ? value
        : value.substring(0, prereleaseSeparator);
    final prerelease = prereleaseSeparator < 0
        ? null
        : value.substring(prereleaseSeparator + 1).split('.');
    return (
      core: core.split('.').map(int.parse).toList(),
      prerelease: prerelease,
    );
  }

  static int _compareVersions(String left, String right) {
    final leftParts = _parseVersion(left);
    final rightParts = _parseVersion(right);
    final leftCore = leftParts.core;
    final rightCore = rightParts.core;
    final length = leftCore.length > rightCore.length
        ? leftCore.length
        : rightCore.length;
    for (var index = 0; index < length; index++) {
      final l = index < leftCore.length ? leftCore[index] : 0;
      final r = index < rightCore.length ? rightCore[index] : 0;
      if (l != r) return l.compareTo(r);
    }
    final leftPre = leftParts.prerelease;
    final rightPre = rightParts.prerelease;
    if (leftPre == null || rightPre == null) {
      if (leftPre == rightPre) return 0;
      return leftPre == null ? 1 : -1;
    }
    final preLength = leftPre.length < rightPre.length
        ? leftPre.length
        : rightPre.length;
    for (var index = 0; index < preLength; index++) {
      final l = leftPre[index];
      final r = rightPre[index];
      if (l == r) continue;
      final lNumber = int.tryParse(l);
      final rNumber = int.tryParse(r);
      if (lNumber != null && rNumber != null) {
        return lNumber.compareTo(rNumber);
      }
      if (lNumber != null) return -1;
      if (rNumber != null) return 1;
      return l.compareTo(r);
    }
    return leftPre.length.compareTo(rightPre.length);
  }
}
