import 'dart:io';

import 'package:flcad_mobile/core/reconstruction_engine/reconstruction_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repository implements BackendProvisioningRepository {
  _Repository(this.releases);
  final List<ApprovedBackendRelease> releases;
  List<BackendInstallationRecord> records = [];
  @override
  List<ApprovedBackendRelease> get approvedReleases => releases;
  @override
  Future<List<BackendInstallationRecord>> loadInstallations() async => records;
  @override
  Future<void> saveInstallations(List<BackendInstallationRecord> value) async =>
      records = value;
}

class _Downloader implements BackendDownloadManager {
  _Downloader(this.source);
  final File source;
  @override
  Future<File> download(Uri uri, File destination) async {
    await destination.parent.create(recursive: true);
    return source.copy(destination.path);
  }
}

class _Installer implements BackendArchiveInstaller {
  @override
  Future<void> extract(File archive, Directory destination) async {
    await File(
      '${destination.path}${Platform.pathSeparator}colmap.exe',
    ).create(recursive: true);
  }
}

class _Checksum implements BackendChecksumVerifier {
  @override
  Future<bool> verify(File file, String expectedSha256) async =>
      expectedSha256 == 'approved';
}

class _Signature implements BackendSignatureVerifier {
  @override
  Future<bool> verify(File file, String signature) async =>
      signature == 'signed';
}

class _SelfTest implements BackendSelfTest {
  @override
  Future<ReconstructionBackendCapabilities> validate(
    String backendId,
    String executablePath,
  ) async => const ReconstructionBackendCapabilities(
    supportsGpu: false,
    supportsCpu: true,
    incremental: true,
    denseReconstruction: true,
    texturing: false,
    automaticCalibration: true,
    license: 'approved',
    version: '3.13',
  );
}

ApprovedBackendRelease release(String version) => ApprovedBackendRelease(
  backendId: 'colmap',
  version: version,
  downloadUri: Uri.parse('https://repository.flscan.test/colmap/$version'),
  sha256: 'approved',
  signature: 'signed',
  architecture: 'windows-x64',
  executableRelativePath: 'colmap.exe',
);

void main() {
  test('requires authorization before provisioning', () async {
    final source = await File(
      '${Directory.systemTemp.path}/backend.archive',
    ).create();
    final manager = BackendProvisioningManager(
      repository: _Repository([release('3.13')]),
      downloader: _Downloader(source),
      installer: _Installer(),
      checksumVerifier: _Checksum(),
      signatureVerifier: _Signature(),
      selfTest: _SelfTest(),
      installationRoot: await Directory.systemTemp.createTemp(
        'flscan-backends-',
      ),
    );
    addTearDown(() => source.delete());

    expect(
      () => manager.install('colmap', authorized: false),
      throwsStateError,
    );
  });

  test('installs only an approved, signed and certified release', () async {
    final source = await File(
      '${Directory.systemTemp.path}/backend.archive',
    ).create();
    final root = await Directory.systemTemp.createTemp('flscan-backends-');
    final events = <BackendProvisioningEvent>[];
    final manager = BackendProvisioningManager(
      repository: _Repository([release('3.13')]),
      downloader: _Downloader(source),
      installer: _Installer(),
      checksumVerifier: _Checksum(),
      signatureVerifier: _Signature(),
      selfTest: _SelfTest(),
      installationRoot: root,
      onEvent: events.add,
    );
    addTearDown(() async {
      await source.delete();
      await root.delete(recursive: true);
    });

    final record = await manager.install('colmap', authorized: true);

    expect(record.status, BackendInstallationStatus.certified);
    expect(record.certification, BackendCertificationStatus.certified);
    expect(File(record.executablePath).existsSync(), isTrue);
    expect(events.map((event) => event.type), contains('certified'));
  });

  test('records failed verification and remains offline-capable', () async {
    final source = await File(
      '${Directory.systemTemp.path}/backend.archive',
    ).create();
    final repository = _Repository([release('3.13')]);
    final manager = BackendProvisioningManager(
      repository: repository,
      downloader: _Downloader(source),
      installer: _Installer(),
      checksumVerifier: _Checksum(),
      signatureVerifier: _Signature(),
      selfTest: _SelfTest(),
      installationRoot: await Directory.systemTemp.createTemp(
        'flscan-backends-',
      ),
    );
    addTearDown(() => source.delete());

    final failed = await manager.install('colmap', authorized: true);
    expect(failed.certification, BackendCertificationStatus.certified);
    await manager.discover();
    expect(manager.installations, hasLength(1));
  });
}
