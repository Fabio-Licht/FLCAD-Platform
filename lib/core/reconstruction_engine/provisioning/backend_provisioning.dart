import 'dart:convert';
import 'dart:io';

import '../backend/reconstruction_backend_contract.dart';

const defaultBackendInstallationRoot = r'C:\ProgramData\FLSCAN\Backends';

enum BackendCertificationStatus { certified, notCertified, unsupported }

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
    void Function(BackendProvisioningEvent event)? onEvent,
  }) : installationRoot =
           installationRoot ?? Directory(defaultBackendInstallationRoot),
       _onEvent = onEvent;

  final BackendProvisioningRepository repository;
  final BackendDownloadManager downloader;
  final BackendArchiveInstaller installer;
  final BackendChecksumVerifier checksumVerifier;
  final BackendSignatureVerifier signatureVerifier;
  final BackendSelfTest selfTest;
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
    if (record.status != BackendInstallationStatus.certified) {
      return record;
    }
    if (record.executablePath.isNotEmpty &&
        await File(record.executablePath).exists()) {
      return record;
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
      lastError: 'Installed executable was not found',
    );
  }

  ApprovedBackendRelease release(String backendId, {String? version}) {
    final matches = repository.approvedReleases.where(
      (item) =>
          item.backendId == backendId &&
          (version == null || item.version == version),
    );
    if (matches.isEmpty) {
      throw StateError('No approved release for backend $backendId');
    }
    return matches.reduce(
      (first, second) =>
          first.version.compareTo(second.version) >= 0 ? first : second,
    );
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
    _event('validationStarted', backendId);
    try {
      await selfTest.validate(backendId, executable.path);
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
      executablePath: executable.path,
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
}
