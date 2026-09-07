import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../backend/reconstruction_backend_contract.dart';

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
  FileBackendProvisioningRepository({
    required this.catalogFile,
    required this.installationsFile,
    required this.approvedReleases,
  });

  final File catalogFile;
  final File installationsFile;
  @override
  final List<ApprovedBackendRelease> approvedReleases;

  @override
  Future<List<BackendInstallationRecord>> loadInstallations() async {
    if (!await installationsFile.exists()) return const [];
    final values = jsonDecode(await installationsFile.readAsString()) as List;
    return values
        .map(
          (value) => BackendInstallationRecord.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        )
        .toList();
  }

  @override
  Future<void> saveInstallations(
    List<BackendInstallationRecord> records,
  ) async {
    await installationsFile.parent.create(recursive: true);
    await installationsFile.writeAsString(
      jsonEncode(records.map((record) => record.toJson()).toList()),
      flush: true,
    );
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
    void Function(BackendProvisioningEvent event)? onEvent,
  }) : installationRoot =
           installationRoot ?? Directory(defaultBackendInstallationRoot),
       _canonicalPathResolver =
           canonicalPathResolver ?? _resolveCanonicalPath,
       _onEvent = onEvent;

  final BackendProvisioningRepository repository;
  final BackendDownloadManager downloader;
  final BackendArchiveInstaller installer;
  final BackendChecksumVerifier checksumVerifier;
  final BackendSignatureVerifier signatureVerifier;
  final BackendSelfTest selfTest;
  final BackendCanonicalPathResolver _canonicalPathResolver;
  final Directory installationRoot;
  final void Function(BackendProvisioningEvent event)? _onEvent;
  List<BackendInstallationRecord> _installations = [];

  List<BackendInstallationRecord> get installations =>
      List.unmodifiable(_installations);

  Future<List<BackendInstallationRecord>> discover() async {
    final loaded = await repository.loadInstallations();
    _installations = [
      for (final record in loaded) await _validateRecord(record),
    ];
    await repository.saveInstallations(_installations);
    return installations;
  }

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
    if (!await executable.exists()) {
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

  Future<void> _replaceAndSave(BackendInstallationRecord record) async {
    _installations = [
      ..._installations.where((item) => item.backendId != record.backendId),
      record,
    ];
    await repository.saveInstallations(_installations);
  }

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
    final matches = repository.approvedReleases.where(
      (item) =>
          item.backendId == backendId &&
          (version == null || item.version == version),
    ).map(_validateRelease);
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
      return _failed(approved, 'Installed executable escapes installation root');
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
    _installations = [
      ..._installations.where((item) => item.backendId != backendId),
      record,
    ];
    await repository.saveInstallations(_installations);
    _event('certified', backendId);
    return record;
  }

  Future<void> remove(String backendId, {required bool authorized}) async {
    if (!authorized) throw StateError('Backend removal requires authorization');
    final records = _installations.where((item) => item.backendId != backendId);
    _installations = records.toList();
    await repository.saveInstallations(_installations);
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

  void _event(String type, String backendId, [String? message]) =>
      _onEvent?.call(
        BackendProvisioningEvent(
          type: type,
          backendId: backendId,
          timestamp: DateTime.now().toUtc(),
          message: message,
        ),
      );

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
    _installations = [
      ..._installations.where((item) => item.backendId != release.backendId),
      record,
    ];
    await repository.saveInstallations(_installations);
    _event('failed', release.backendId, error);
    return record;
  }

  Future<String> _canonicalInstallationRoot() =>
      _canonicalPathResolver(installationRoot.path);

  static Future<String> _resolveCanonicalPath(String value) =>
      File(value).resolveSymbolicLinks();

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
