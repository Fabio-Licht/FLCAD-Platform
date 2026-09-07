import 'dart:convert';
import 'dart:io';

import 'package:flcad_mobile/core/acquisition_intelligence/models/evidence_graph.dart';
import 'package:flcad_mobile/core/reconstruction_engine/reconstruction_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repository implements BackendProvisioningRepository {
  _Repository({this.file});

  final File? file;
  List<BackendInstallationRecord> memory = [];

  @override
  List<ApprovedBackendRelease> get approvedReleases => const [];

  @override
  Future<List<BackendInstallationRecord>> loadInstallations() async {
    if (file == null || !await file!.exists()) return memory;
    final values = jsonDecode(await file!.readAsString()) as List<dynamic>;
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
    memory = List.of(records);
    if (file != null) {
      await file!.writeAsString(
        jsonEncode(records.map((record) => record.toJson()).toList()),
      );
    }
  }
}

class _NeverDownloader implements BackendDownloadManager {
  int calls = 0;

  @override
  Future<File> download(Uri uri, File destination) async {
    calls++;
    throw StateError('Downloader must not be called');
  }
}

class _NeverInstaller implements BackendArchiveInstaller {
  int calls = 0;

  @override
  Future<void> extract(File archive, Directory destination) async {
    calls++;
    throw StateError('Installer must not be called');
  }
}

class _Verifier implements BackendChecksumVerifier, BackendSignatureVerifier {
  @override
  Future<bool> verify(File file, String expected) async => true;
}

class _SelfTest implements BackendSelfTest {
  _SelfTest({this.fail = false});

  final bool fail;
  final List<String> paths = [];

  @override
  Future<ReconstructionBackendCapabilities> validate(
    String backendId,
    String executablePath,
  ) async {
    paths.add(executablePath);
    if (fail) throw StateError('probe failed');
    return const ReconstructionBackendCapabilities(
      supportsGpu: true,
      supportsCpu: true,
      incremental: true,
      denseReconstruction: true,
      texturing: false,
      automaticCalibration: true,
      license: 'BSD-3-Clause',
      version: 'COLMAP 3.13',
    );
  }
}

class _PipelineRunner implements ColmapProcessRunner {
  _PipelineRunner({this.versionResult = 'COLMAP 3.13'});

  final String? versionResult;
  final List<String> executables = [];

  @override
  Future<String?> version(String executable) async {
    executables.add(executable);
    return versionResult;
  }

  @override
  Future<ColmapCommandResult> run(
    String executable,
    List<String> arguments, {
    required Directory workingDirectory,
    ReconstructionCancellation? cancellation,
  }) async {
    executables.add(executable);
    String valueAfter(String option) => arguments[arguments.indexOf(option) + 1];
    Future<void> write(String target, [List<int> bytes = const [1]]) async {
      final file = File(target);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, mode: FileMode.append);
    }

    switch (arguments.first) {
      case 'feature_extractor':
      case 'exhaustive_matcher':
        await write(valueAfter('--database_path'));
        break;
      case 'mapper':
        final output = valueAfter('--output_path');
        for (final name in ['cameras.bin', 'images.bin', 'points3D.bin']) {
          await write('$output${Platform.pathSeparator}2${Platform.pathSeparator}$name');
        }
        break;
      case 'image_undistorter':
        final output = valueAfter('--output_path');
        await write('$output${Platform.pathSeparator}images${Platform.pathSeparator}a.jpg');
        for (final name in ['cameras.bin', 'images.bin', 'points3D.bin']) {
          await write('$output${Platform.pathSeparator}sparse${Platform.pathSeparator}$name');
        }
        break;
      case 'model_converter':
        final output = valueAfter('--output_path');
        for (final name in ['cameras.txt', 'images.txt', 'points3D.txt']) {
          await write('$output${Platform.pathSeparator}$name');
        }
        break;
      case 'patch_match_stereo':
        final output = valueAfter('--workspace_path');
        await write(
          '$output${Platform.pathSeparator}stereo${Platform.pathSeparator}'
          'depth_maps${Platform.pathSeparator}a.bin',
        );
        break;
      case 'stereo_fusion':
      case 'poisson_mesher':
        await write(valueAfter('--output_path'));
        break;
    }
    return const ColmapCommandResult(
      exitCode: 0,
      stdout: '',
      stderr: '',
      durationMs: 1,
    );
  }
}

BackendProvisioningManager _manager({
  required BackendProvisioningRepository repository,
  required BackendDownloadManager downloader,
  required BackendArchiveInstaller installer,
  required BackendSelfTest selfTest,
  required Directory root,
  BackendCanonicalPathResolver? canonicalPathResolver,
}) => BackendProvisioningManager(
  repository: repository,
  downloader: downloader,
  installer: installer,
  checksumVerifier: _Verifier(),
  signatureVerifier: _Verifier(),
  selfTest: selfTest,
  installationRoot: root,
  canonicalPathResolver: canonicalPathResolver,
);

String get _executableName => Platform.isWindows ? 'colmap.exe' : 'colmap';

void main() {
  test('default manager never activates COLMAP from PATH', () {
    final manager = ReconstructionBackendManager();
    expect(manager.backends.map((backend) => backend.id), ['foundation']);
    expect(() => manager.get('colmap'), throwsStateError);
  });

  test('legacy installation JSON defaults its origin to managed', () {
    final record = BackendInstallationRecord.fromJson({
      'backendId': 'colmap',
      'version': '3.13',
      'installedAt': DateTime.utc(2026).toIso8601String(),
      'source': 'https://example.test/colmap',
      'sha256': 'hash',
      'architecture': 'windows-x64',
      'status': 'certified',
      'certification': 'certified',
      'executablePath': r'C:\managed\colmap.exe',
    });
    expect(record.origin, BackendInstallationOrigin.managed);
  });

  test('external registration is authorized, persistent and never certified', () async {
    final temp = await Directory.systemTemp.createTemp('flcad external & path-');
    addTearDown(() => temp.delete(recursive: true));
    final executable = await File(
      '${temp.path}${Platform.pathSeparator}tools & bin${Platform.pathSeparator}$_executableName',
    ).create(recursive: true);
    final storage = File('${temp.path}${Platform.pathSeparator}installations.json');
    final repository = _Repository(file: storage);
    final downloader = _NeverDownloader();
    final installer = _NeverInstaller();
    final selfTest = _SelfTest();
    final events = <BackendProvisioningEvent>[];
    final manager = BackendProvisioningManager(
      repository: repository,
      downloader: downloader,
      installer: installer,
      checksumVerifier: _Verifier(),
      signatureVerifier: _Verifier(),
      selfTest: selfTest,
      installationRoot: Directory(
        '${temp.path}${Platform.pathSeparator}managed',
      ),
      onEvent: events.add,
    );

    await expectLater(
      manager.registerExisting(
        'colmap',
        executablePath: executable.path,
        authorized: false,
      ),
      throwsStateError,
    );
    final record = await manager.registerExisting(
      'colmap',
      executablePath: executable.path,
      authorized: true,
    );
    expect(record.origin, BackendInstallationOrigin.external);
    expect(record.status, BackendInstallationStatus.installed);
    expect(record.certification, BackendCertificationStatus.notCertified);
    expect(record.version, 'COLMAP 3.13');
    expect(record.executablePath, await executable.resolveSymbolicLinks());
    expect(selfTest.paths.single, record.executablePath);
    expect(downloader.calls, 0);
    expect(installer.calls, 0);
    expect(
      events.map((event) => event.type),
      containsAllInOrder(['externalRegistrationStarted', 'externalRegistered']),
    );

    final reopened = _manager(
      repository: _Repository(file: storage),
      downloader: downloader,
      installer: installer,
      selfTest: selfTest,
      root: Directory('${temp.path}${Platform.pathSeparator}other-managed'),
    );
    final discovered = await reopened.discover();
    expect(discovered.single.origin, BackendInstallationOrigin.external);
    expect(discovered.single.status, BackendInstallationStatus.installed);
    expect(
      discovered.single.certification,
      BackendCertificationStatus.notCertified,
    );
  });

  test('registration rejects relative, missing and wrongly named executables', () async {
    final temp = await Directory.systemTemp.createTemp('flcad-invalid-external-');
    addTearDown(() => temp.delete(recursive: true));
    final manager = _manager(
      repository: _Repository(),
      downloader: _NeverDownloader(),
      installer: _NeverInstaller(),
      selfTest: _SelfTest(),
      root: Directory('${temp.path}${Platform.pathSeparator}managed'),
    );
    await expectLater(
      manager.registerExisting(
        'colmap',
        executablePath: _executableName,
        authorized: true,
      ),
      throwsArgumentError,
    );
    await expectLater(
      manager.registerExisting(
        'colmap',
        executablePath: '${temp.path}${Platform.pathSeparator}$_executableName',
        authorized: true,
      ),
      throwsArgumentError,
    );
    final wrong = await File(
      '${temp.path}${Platform.pathSeparator}not-colmap.exe',
    ).create();
    await expectLater(
      manager.registerExisting(
        'colmap',
        executablePath: wrong.path,
        authorized: true,
      ),
      throwsArgumentError,
    );
  });

  test('failed external self test remains failed and not certified', () async {
    final temp = await Directory.systemTemp.createTemp('flcad-failed-external-');
    addTearDown(() => temp.delete(recursive: true));
    final executable = await File(
      '${temp.path}${Platform.pathSeparator}$_executableName',
    ).create();
    final manager = _manager(
      repository: _Repository(),
      downloader: _NeverDownloader(),
      installer: _NeverInstaller(),
      selfTest: _SelfTest(fail: true),
      root: Directory('${temp.path}${Platform.pathSeparator}managed'),
    );
    final record = await manager.registerExisting(
      'colmap',
      executablePath: executable.path,
      authorized: true,
    );
    expect(record.status, BackendInstallationStatus.failed);
    expect(record.certification, BackendCertificationStatus.notCertified);
  });

  test('activation requires opt-in and uses the exact executable end to end', () async {
    final temp = await Directory.systemTemp.createTemp('flcad-activate-external-');
    addTearDown(() => temp.delete(recursive: true));
    final executable = await File(
      '${temp.path}${Platform.pathSeparator}bin & tools${Platform.pathSeparator}$_executableName',
    ).create(recursive: true);
    final canonical = await executable.resolveSymbolicLinks();
    final record = BackendInstallationRecord(
      backendId: 'colmap',
      version: 'COLMAP 3.13',
      installedAt: DateTime.utc(2026),
      source: Uri.file(canonical),
      sha256: '',
      architecture: 'external',
      status: BackendInstallationStatus.installed,
      certification: BackendCertificationStatus.notCertified,
      executablePath: canonical,
      origin: BackendInstallationOrigin.external,
    );
    final runner = _PipelineRunner();
    final activation = ColmapBackendActivation(processRunner: runner);
    await expectLater(activation.activate(record), throwsStateError);
    final backend = await activation.activate(
      record,
      allowUncertifiedExternal: true,
    );
    expect(backend.capabilities.version, 'COLMAP 3.13');
    final images = await Directory(
      '${temp.path}${Platform.pathSeparator}images',
    ).create();
    await File('${images.path}${Platform.pathSeparator}a.jpg').writeAsBytes([1]);
    final result = await backend.reconstruct(
      ReconstructionRequest(
        id: 'external',
        projectId: 'project',
        evidenceGraph: const EvidenceGraph(nodes: [], edges: []),
        calibration: {
          'workspacePath': '${temp.path}${Platform.pathSeparator}runs',
          'imagePath': images.path,
        },
      ),
    );
    expect(result.diagnostics.backendVersion, 'COLMAP 3.13');
    expect(runner.executables, hasLength(9));
    expect(runner.executables, everyElement(canonical));
  });

  test('activates only a certified managed executable confined to its root', () async {
    final temp = await Directory.systemTemp.createTemp('flcad-managed-');
    addTearDown(() => temp.delete(recursive: true));
    final root = await Directory(
      '${temp.path}${Platform.pathSeparator}managed',
    ).create();
    final executable = await File(
      '${root.path}${Platform.pathSeparator}colmap-3.13'
      '${Platform.pathSeparator}$_executableName',
    ).create(recursive: true);
    final canonical = await executable.resolveSymbolicLinks();
    final record = BackendInstallationRecord(
      backendId: 'colmap',
      version: 'COLMAP 3.13',
      installedAt: DateTime.utc(2026),
      source: Uri.parse('https://example.test/colmap'),
      sha256: 'approved',
      architecture: 'test',
      status: BackendInstallationStatus.certified,
      certification: BackendCertificationStatus.certified,
      executablePath: canonical,
    );
    final runner = _PipelineRunner();
    final backend = await ColmapBackendActivation(
      processRunner: runner,
      managedInstallationRoot: root,
    ).activate(record);
    expect(backend.executable, canonical);

    await expectLater(
      ColmapBackendActivation(processRunner: runner).activate(record),
      throwsStateError,
    );
    final outside = await File(
      '${temp.path}${Platform.pathSeparator}outside'
      '${Platform.pathSeparator}$_executableName',
    ).create(recursive: true);
    final escaped = BackendInstallationRecord(
      backendId: record.backendId,
      version: record.version,
      installedAt: record.installedAt,
      source: record.source,
      sha256: record.sha256,
      architecture: record.architecture,
      status: record.status,
      certification: record.certification,
      executablePath: outside.path,
    );
    await expectLater(
      ColmapBackendActivation(
        processRunner: runner,
        managedInstallationRoot: root,
      ).activate(escaped),
      throwsStateError,
    );
  });

  test('rejects invalid external states and missing version probes', () async {
    final temp = await Directory.systemTemp.createTemp('flcad-activation-state-');
    addTearDown(() => temp.delete(recursive: true));
    final executable = await File(
      '${temp.path}${Platform.pathSeparator}$_executableName',
    ).create();
    BackendInstallationRecord external({
      BackendInstallationStatus status = BackendInstallationStatus.installed,
      BackendCertificationStatus certification =
          BackendCertificationStatus.notCertified,
    }) => BackendInstallationRecord(
      backendId: 'colmap',
      version: 'COLMAP 3.13',
      installedAt: DateTime.utc(2026),
      source: Uri.file(executable.path),
      sha256: '',
      architecture: 'external',
      status: status,
      certification: certification,
      executablePath: executable.path,
      origin: BackendInstallationOrigin.external,
    );

    for (final record in [
      external(status: BackendInstallationStatus.failed),
      external(status: BackendInstallationStatus.certified),
      external(certification: BackendCertificationStatus.certified),
    ]) {
      await expectLater(
        ColmapBackendActivation(
          processRunner: _PipelineRunner(),
        ).activate(record, allowUncertifiedExternal: true),
        throwsStateError,
      );
    }
    for (final version in <String?>[null, '']) {
      await expectLater(
        ColmapBackendActivation(
          processRunner: _PipelineRunner(versionResult: version),
        ).activate(external(), allowUncertifiedExternal: true),
        throwsStateError,
      );
    }
  });

  test('low-level COLMAP backend rejects implicit relative executables', () async {
    final runner = _PipelineRunner();
    await expectLater(
      ColmapBackend(executable: 'colmap', processRunner: runner)
          .detectCapabilities(),
      throwsArgumentError,
    );
    expect(runner.executables, isEmpty);
  });

  test('external discovery rejects a canonical alias with a wrong name', () async {
    final temp = await Directory.systemTemp.createTemp('flcad-external-alias-');
    addTearDown(() => temp.delete(recursive: true));
    final executable = await File(
      '${temp.path}${Platform.pathSeparator}$_executableName',
    ).create();
    final unexpectedCanonical =
        '${temp.path}${Platform.pathSeparator}unexpected-binary.bin';
    final repository = _Repository()
      ..memory = [
        BackendInstallationRecord(
          backendId: 'colmap',
          version: 'COLMAP 3.13',
          installedAt: DateTime.utc(2026),
          source: Uri.file(executable.path),
          sha256: '',
          architecture: 'external',
          status: BackendInstallationStatus.installed,
          certification: BackendCertificationStatus.notCertified,
          executablePath: executable.path,
          origin: BackendInstallationOrigin.external,
        ),
      ];
    final selfTest = _SelfTest();
    final manager = _manager(
      repository: repository,
      downloader: _NeverDownloader(),
      installer: _NeverInstaller(),
      selfTest: selfTest,
      root: Directory('${temp.path}${Platform.pathSeparator}managed'),
      canonicalPathResolver: (value) async {
        expect(value, executable.path);
        return unexpectedCanonical;
      },
    );
    final discovered = await manager.discover();
    expect(discovered.single.status, BackendInstallationStatus.notInstalled);
    expect(selfTest.paths, isEmpty);
  });

  test('stale preferred backend falls back safely', () async {
    final temp = await Directory.systemTemp.createTemp('flcad-selection-');
    addTearDown(() => temp.delete(recursive: true));
    final selection = File('${temp.path}${Platform.pathSeparator}selection.json');
    await selection.writeAsString(jsonEncode({'preferredId': 'colmap'}));
    final manager = ReconstructionBackendManager();
    await manager.loadSelection(selection);
    expect(manager.preferredId, isNull);
    expect(manager.select(mode: BackendSelectionMode.preferred).id, 'foundation');
  });
}
