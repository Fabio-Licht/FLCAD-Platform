import 'dart:convert';
import 'dart:io';

import 'package:flcad_mobile/core/reconstruction_engine/reconstruction_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repository implements BackendProvisioningRepository {
  _Repository(this.releases);
  final List<ApprovedBackendRelease> releases;
  List<BackendInstallationRecord> records = [];
  Object? saveFailure;
  int saveCalls = 0;
  @override
  List<ApprovedBackendRelease> get approvedReleases => releases;
  @override
  Future<List<BackendInstallationRecord>> loadInstallations() async => records;
  @override
  Future<void> saveInstallations(List<BackendInstallationRecord> value) async {
    saveCalls++;
    if (saveFailure != null) throw saveFailure!;
    records = List.of(value);
  }
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
  Object? failure;
  int calls = 0;

  @override
  Future<ReconstructionBackendCapabilities> validate(
    String backendId,
    String executablePath,
  ) async {
    calls++;
    if (failure != null) throw failure!;
    return const ReconstructionBackendCapabilities(
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

BackendProvisioningManager managerFor(
  List<ApprovedBackendRelease> releases,
  Directory root,
  File source,
) => BackendProvisioningManager(
  repository: _Repository(releases),
  downloader: _Downloader(source),
  installer: _Installer(),
  checksumVerifier: _Checksum(),
  signatureVerifier: _Signature(),
  selfTest: _SelfTest(),
  installationRoot: root,
);

void main() {
  test(
    'file repository restores previous file when final swap fails',
    () async {
      final root = await Directory.systemTemp.createTemp('flcad-file-swap-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}${Platform.pathSeparator}installs.json');
      final oldRecord = BackendInstallationRecord(
        backendId: 'old',
        version: '1',
        installedAt: DateTime.utc(2026),
        source: Uri.file('old'),
        sha256: '',
        architecture: 'test',
        status: BackendInstallationStatus.installed,
        certification: BackendCertificationStatus.notCertified,
        executablePath: 'old',
      );
      await file.writeAsString(jsonEncode([oldRecord.toJson()]));
      var renames = 0;
      final repository = FileBackendProvisioningRepository(
        catalogFile: File('${root.path}${Platform.pathSeparator}catalog.json'),
        installationsFile: file,
        approvedReleases: const [],
        renameFile: (source, target) async {
          renames++;
          if (renames == 2) throw FileSystemException('swap failed');
          return source.rename(target);
        },
      );

      await expectLater(
        repository.saveInstallations(const []),
        throwsA(isA<FileSystemException>()),
      );

      expect((await repository.loadInstallations()).single.backendId, 'old');
      expect(
        root.listSync().where((item) => item.path.contains('.tmp-')),
        isEmpty,
      );
    },
  );

  test('file repository preserves primary when backup rename fails', () async {
    final root = await Directory.systemTemp.createTemp('flcad-file-preserve-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}${Platform.pathSeparator}installs.json');
    await file.writeAsString('[]');
    final repository = FileBackendProvisioningRepository(
      catalogFile: File('${root.path}${Platform.pathSeparator}catalog.json'),
      installationsFile: file,
      approvedReleases: const [],
      renameFile: (source, target) async {
        throw FileSystemException('rename blocked');
      },
    );

    await expectLater(
      repository.saveInstallations(const []),
      throwsA(isA<FileSystemException>()),
    );

    expect(await file.readAsString(), '[]');
    expect(
      root.listSync().where((item) => item.path.contains('.tmp-')),
      isEmpty,
    );
  });

  test(
    'file repository loads valid backup for missing or invalid primary',
    () async {
      final root = await Directory.systemTemp.createTemp('flcad-file-recover-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}${Platform.pathSeparator}installs.json');
      final backup = File('${file.path}.backup');
      final record = BackendInstallationRecord(
        backendId: 'colmap',
        version: '1',
        installedAt: DateTime.utc(2026),
        source: Uri.file('colmap'),
        sha256: '',
        architecture: 'test',
        status: BackendInstallationStatus.installed,
        certification: BackendCertificationStatus.notCertified,
        executablePath: 'colmap',
      );
      await backup.writeAsString(jsonEncode([record.toJson()]));
      final repository = FileBackendProvisioningRepository(
        catalogFile: File('${root.path}${Platform.pathSeparator}catalog.json'),
        installationsFile: file,
        approvedReleases: const [],
      );

      expect((await repository.loadInstallations()).single.backendId, 'colmap');
      await file.writeAsString('{invalid');
      await backup.writeAsString(jsonEncode([record.toJson()]));
      expect((await repository.loadInstallations()).single.backendId, 'colmap');

      await backup.writeAsString('{also-invalid');
      await expectLater(repository.loadInstallations(), throwsStateError);
    },
  );

  test(
    'validates external COLMAP without mutating or persisting state',
    () async {
      final root = await Directory.systemTemp.createTemp('flcad-validate-');
      addTearDown(() => root.delete(recursive: true));
      final executable = await File(
        '${root.path}${Platform.pathSeparator}'
        '${Platform.isWindows ? 'colmap.exe' : 'colmap'}',
      ).create();
      final repository = _Repository(const []);
      final selfTest = _SelfTest();
      final manager = BackendProvisioningManager(
        repository: repository,
        downloader: _Downloader(executable),
        installer: _Installer(),
        checksumVerifier: _Checksum(),
        signatureVerifier: _Signature(),
        selfTest: selfTest,
        installationRoot: root,
      );

      final candidate = await manager.prepareExisting(
        'colmap',
        executablePath: executable.path,
        authorized: true,
      );

      expect(candidate.record.status, BackendInstallationStatus.installed);
      expect(candidate.record.origin, BackendInstallationOrigin.external);
      expect(
        candidate.record.certification,
        BackendCertificationStatus.notCertified,
      );
      expect(manager.installations, isEmpty);
      expect(repository.records, isEmpty);
      expect(repository.saveCalls, 0);
      expect(selfTest.calls, 1);
    },
  );

  test(
    'failed validation preserves prior in-memory and persisted record',
    () async {
      final root = await Directory.systemTemp.createTemp('flcad-selftest-');
      addTearDown(() => root.delete(recursive: true));
      final executable = await File(
        '${root.path}${Platform.pathSeparator}'
        '${Platform.isWindows ? 'colmap.exe' : 'colmap'}',
      ).create();
      final previous = BackendInstallationRecord(
        backendId: 'previous',
        version: '1',
        installedAt: DateTime.utc(2026),
        source: Uri.file(executable.path),
        sha256: '',
        architecture: 'test',
        status: BackendInstallationStatus.installed,
        certification: BackendCertificationStatus.notCertified,
        executablePath: executable.path,
      );
      final repository = _Repository(const [])..records = [previous];
      final selfTest = _SelfTest()..failure = StateError('probe failed');
      final manager = BackendProvisioningManager(
        repository: repository,
        downloader: _Downloader(executable),
        installer: _Installer(),
        checksumVerifier: _Checksum(),
        signatureVerifier: _Signature(),
        selfTest: selfTest,
        installationRoot: root,
      );
      await manager.discover();
      final savedBefore = List.of(repository.records);
      final savesBefore = repository.saveCalls;

      await expectLater(
        manager.prepareExisting(
          'colmap',
          executablePath: executable.path,
          authorized: true,
        ),
        throwsStateError,
      );

      expect(manager.installations, savedBefore);
      expect(repository.records, savedBefore);
      expect(repository.saveCalls, savesBefore);
    },
  );

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

  test('selects versions numerically instead of lexically', () async {
    final source = await File(
      '${Directory.systemTemp.path}/backend-version.archive',
    ).create();
    final root = await Directory.systemTemp.createTemp('flscan-backends-');
    addTearDown(() async {
      await source.delete();
      await root.delete(recursive: true);
    });
    final manager = managerFor(
      [release('3.9'), release('3.10'), release('3.10-beta.1')],
      root,
      source,
    );

    expect(manager.release('colmap').version, '3.10');
  });

  test('rejects unsafe backend identifiers and versions', () async {
    final source = await File(
      '${Directory.systemTemp.path}/backend-invalid.archive',
    ).create();
    final root = await Directory.systemTemp.createTemp('flscan-backends-');
    addTearDown(() async {
      await source.delete();
      await root.delete(recursive: true);
    });
    final manager = managerFor([release('3.13')], root, source);

    expect(() => manager.release('../colmap'), throwsArgumentError);
    expect(
      () => manager.release('colmap', version: '../3.13'),
      throwsArgumentError,
    );
  });

  test('rejects absolute and traversing executable paths', () async {
    final source = await File(
      '${Directory.systemTemp.path}/backend-path.archive',
    ).create();
    final root = await Directory.systemTemp.createTemp('flscan-backends-');
    addTearDown(() async {
      await source.delete();
      await root.delete(recursive: true);
    });
    ApprovedBackendRelease unsafe(String path) => ApprovedBackendRelease(
      backendId: 'colmap',
      version: '3.13',
      downloadUri: Uri.parse('https://repository.flscan.test/colmap/3.13'),
      sha256: 'approved',
      signature: 'signed',
      architecture: 'windows-x64',
      executableRelativePath: path,
    );

    for (final path in [
      '../colmap.exe',
      r'bin\..\colmap.exe',
      '/tmp/colmap.exe',
      r'C:\tools\colmap.exe',
      r'\\server\share\colmap.exe',
      r'bin\colmap.exe:payload',
    ]) {
      final manager = managerFor([unsafe(path)], root, source);
      expect(
        () => manager.release('colmap'),
        throwsArgumentError,
        reason: path,
      );
    }
  });

  test(
    'does not trust a recorded executable outside installation root',
    () async {
      final source = await File(
        '${Directory.systemTemp.path}/backend-discovery.archive',
      ).create();
      final external = await File(
        '${Directory.systemTemp.path}/external-colmap.exe',
      ).create();
      final root = await Directory.systemTemp.createTemp('flscan-backends-');
      final repository = _Repository([release('3.13')])
        ..records = [
          BackendInstallationRecord(
            backendId: 'colmap',
            version: '3.13',
            installedAt: DateTime.utc(2026),
            source: Uri.parse('https://repository.flscan.test/colmap/3.13'),
            sha256: 'approved',
            architecture: 'windows-x64',
            status: BackendInstallationStatus.certified,
            certification: BackendCertificationStatus.certified,
            executablePath: external.path,
          ),
        ];
      final manager = BackendProvisioningManager(
        repository: repository,
        downloader: _Downloader(source),
        installer: _Installer(),
        checksumVerifier: _Checksum(),
        signatureVerifier: _Signature(),
        selfTest: _SelfTest(),
        installationRoot: root,
      );
      addTearDown(() async {
        await source.delete();
        await external.delete();
        await root.delete(recursive: true);
      });

      final discovered = await manager.discover();

      expect(discovered.single.status, BackendInstallationStatus.notInstalled);
      expect(
        discovered.single.certification,
        BackendCertificationStatus.notCertified,
      );
    },
  );
}
