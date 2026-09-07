import 'dart:async';
import 'dart:io';

import 'package:flcad_mobile/app/reconstruction/colmap_experimental_lab_controller.dart';
import 'package:flcad_mobile/app/reconstruction/colmap_operational_controller.dart';
import 'package:flcad_mobile/app/reconstruction/widgets/colmap_experimental_lab.dart';
import 'package:flcad_mobile/core/acquisition_intelligence/models/evidence_graph.dart';
import 'package:flcad_mobile/core/reconstruction_engine/reconstruction_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

class _Repository implements BackendProvisioningRepository {
  List<BackendInstallationRecord> records = [];

  @override
  List<ApprovedBackendRelease> get approvedReleases => const [];

  @override
  Future<List<BackendInstallationRecord>> loadInstallations() async => records;

  @override
  Future<void> saveInstallations(List<BackendInstallationRecord> value) async =>
      records = value;
}

class _NoDownload implements BackendDownloadManager {
  @override
  Future<File> download(Uri uri, File destination) =>
      throw UnsupportedError('not used by the laboratory');
}

class _NoInstall implements BackendArchiveInstaller {
  @override
  Future<void> extract(File archive, Directory destination) =>
      throw UnsupportedError('not used by the laboratory');
}

class _NoChecksum implements BackendChecksumVerifier {
  @override
  Future<bool> verify(File file, String expectedSha256) =>
      throw UnsupportedError('not used by the laboratory');
}

class _NoSignature implements BackendSignatureVerifier {
  @override
  Future<bool> verify(File file, String signature) =>
      throw UnsupportedError('not used by the laboratory');
}

class _SelfTest implements BackendSelfTest {
  Object? failure;
  String version = '3.13-test';
  int calls = 0;

  @override
  Future<ReconstructionBackendCapabilities> validate(
    String backendId,
    String executablePath,
  ) async {
    calls++;
    if (failure != null) throw failure!;
    return ReconstructionBackendCapabilities(
      supportsGpu: false,
      supportsCpu: true,
      incremental: false,
      denseReconstruction: true,
      texturing: false,
      automaticCalibration: true,
      license: 'BSD-3-Clause',
      version: version,
    );
  }
}

class _ProvisioningManager extends BackendProvisioningManager {
  _ProvisioningManager()
    : super(
        repository: _Repository(),
        downloader: _NoDownload(),
        installer: _NoInstall(),
        checksumVerifier: _NoChecksum(),
        signatureVerifier: _NoSignature(),
        selfTest: _SelfTest(),
        installationRoot: Directory.systemTemp,
      );

  Object? failure;
  String version = '3.13-test';
  int calls = 0;

  @override
  Future<BackendInstallationRecord> registerExisting(
    String backendId, {
    required String executablePath,
    required bool authorized,
  }) async {
    calls++;
    if (!authorized) {
      throw StateError('External backend registration requires authorization');
    }
    return BackendInstallationRecord(
      backendId: backendId,
      version: failure == null ? version : 'undetected',
      installedAt: DateTime.utc(2026),
      source: Uri.file(executablePath),
      sha256: '',
      architecture: 'external',
      status: failure == null
          ? BackendInstallationStatus.installed
          : BackendInstallationStatus.failed,
      certification: BackendCertificationStatus.notCertified,
      executablePath: executablePath,
      origin: BackendInstallationOrigin.external,
      lastError: failure == null ? null : 'External self test failed: $failure',
    );
  }
}

class _Cancellation implements OperationalReconstructionCancellation {
  int calls = 0;

  @override
  bool isCancelled = false;

  @override
  void cancel() {
    calls++;
    isCancelled = true;
  }
}

class _Backend implements ReconstructionBackend {
  Completer<void>? block;
  Object? failure;
  ReconstructionRequest? request;
  int calls = 0;

  @override
  String get id => 'colmap';

  @override
  ReconstructionBackendCapabilities get capabilities =>
      const ReconstructionBackendCapabilities(
        supportsGpu: false,
        supportsCpu: true,
        incremental: false,
        denseReconstruction: true,
        texturing: false,
        automaticCalibration: true,
        license: 'BSD-3-Clause',
        version: '3.13-test',
      );

  @override
  Future<ReconstructionBackendResult> reconstruct(
    ReconstructionRequest request, {
    void Function(ReconstructionStageReport report)? onStage,
    ReconstructionCancellation? cancellation,
  }) async {
    calls++;
    this.request = request;
    if (block != null) await block!.future;
    if (cancellation?.isCancelled ?? false) {
      throw const ReconstructionCancelled();
    }
    if (failure != null) throw failure!;
    final report = const ReconstructionStageReport(
      stage: ReconstructionStage.meshGeneration,
      status: ReconstructionStageStatus.completed,
      confidence: 0.42,
      quality: 0.7,
      durationMs: 10,
      residuals: {},
      dependencies: [],
      accepted: true,
      explanation: 'Candidato técnico produzido.',
    );
    onStage?.call(report);
    final output = ReconstructionOutput(
      requestId: request.id,
      stageReports: [report],
      confidenceMap: const [],
      provenance: const {},
      meshCandidate: const {
        'path': r'C:\work space\candidate mesh.ply',
        'final': false,
      },
      sparseCloud: const [],
      denseCloud: const [],
      evidenceGraph: request.evidenceGraph,
    );
    return ReconstructionBackendResult(
      output: output,
      diagnostics: const ReconstructionBackendDiagnostics(
        backendId: 'colmap',
        backendVersion: '3.13-test',
        durationMs: 10,
        memoryBytes: null,
        confidence: 0.99,
        completedStages: [ReconstructionStage.meshGeneration],
        limitations: ['Technical completion only.'],
        explanations: {},
      ),
    );
  }
}

class _InputValidator implements ColmapInputValidator {
  _InputValidator({ValidatedColmapPhotoDirectory? photoDirectory})
    : photoDirectory =
          photoDirectory ??
          ValidatedColmapPhotoDirectory(
            canonicalPath: r'C:\capture jobs\photo set',
            canonicalImagePaths: const [
              r'C:\capture jobs\photo set\image 01.jpg',
            ],
          );

  ValidatedColmapPhotoDirectory photoDirectory;
  String workspaceRoot = r'C:\FLCAD Platform\managed workspace';
  Object? photoFailure;
  Object? workspaceFailure;
  int photoCalls = 0;
  final List<String> validatedPhotoPaths = [];

  @override
  Future<String> prepareWorkspaceRoot(String value) async {
    if (workspaceFailure != null) throw workspaceFailure!;
    return workspaceRoot;
  }

  @override
  Future<ValidatedColmapPhotoDirectory> validatePhotoDirectory(
    String value,
  ) async {
    photoCalls++;
    validatedPhotoPaths.add(value);
    if (photoFailure != null) throw photoFailure!;
    return photoDirectory;
  }
}

class _Harness {
  _Harness({
    required this.executable,
    required this.provisioning,
    required this.backend,
    required this.backendManager,
    required this.operational,
    required this.inputValidator,
    required this.lab,
  });

  final String executable;
  final _ProvisioningManager provisioning;
  final _Backend backend;
  final ReconstructionBackendManager backendManager;
  final ColmapOperationalController operational;
  final ColmapInputValidator inputValidator;
  final ColmapExperimentalLabController lab;

  static Future<_Harness> create({
    Completer<ReconstructionBackend>? activation,
    _Cancellation? cancellation,
    ColmapPhotoDirectoryPicker? selectPhotoDirectory,
    ColmapWorkspaceRootProvider? workspaceRootProvider,
    ColmapInputValidator? inputValidator,
  }) async {
    const executable = r'C:\Program Files\COLMAP\colmap.exe';
    final provisioning = _ProvisioningManager();
    final backend = _Backend();
    final validator = inputValidator ?? _InputValidator();
    final backendManager = ReconstructionBackendManager();
    final operational = ColmapOperationalController(
      backendManager: backendManager,
      activate: (record, {required allowUncertifiedExternal}) =>
          activation?.future ?? Future.value(backend),
      cancellationFactory: cancellation == null ? null : () => cancellation,
    );
    final lab = ColmapExperimentalLabController(
      operationalController: operational,
      provisioningManager: provisioning,
      selectExecutable: () async => executable,
      selectPhotoDirectory:
          selectPhotoDirectory ?? () async => r'C:\capture jobs\photo set',
      workspaceRootProvider:
          workspaceRootProvider ??
          () async => r'C:\FLCAD Platform\managed workspace',
      inputValidator: validator,
      requestIdFactory: () => 'request-test',
    );
    return _Harness(
      executable: executable,
      provisioning: provisioning,
      backend: backend,
      backendManager: backendManager,
      operational: operational,
      inputValidator: validator,
      lab: lab,
    );
  }

  Future<void> activate() async {
    await lab.chooseExecutable();
    await lab.validateAndActivate(consent: true);
  }

  Future<void> dispose() async {
    lab.dispose();
    operational.dispose();
  }
}

Future<void> _pumpLab(
  WidgetTester tester,
  ColmapExperimentalLabController controller,
) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ColmapExperimentalLab(controller: controller)),
    ),
  );
}

void main() {
  testWidgets('does not activate automatically when mounted', (tester) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);

    await _pumpLab(tester, harness.lab);

    expect(harness.provisioning.calls, 0);
    expect(harness.operational.state, ColmapOperationalState.idle);
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('colmap-consent')))
          .value,
      isFalse,
    );
  });

  testWidgets('requires explicit consent before activation', (tester) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await _pumpLab(tester, harness.lab);
    await tester.tap(find.byKey(const Key('select-colmap')));
    await tester.pump();

    final activate = tester.widget<FilledButton>(
      find.byKey(const Key('activate-colmap')),
    );
    expect(activate.onPressed, isNull);

    await harness.lab.validateAndActivate(consent: false);
    await tester.pump();
    expect(find.textContaining('consentimento experimental'), findsOneWidget);
    expect(harness.provisioning.calls, 0);
  });

  testWidgets('shows the operational activating state', (tester) async {
    final activation = Completer<ReconstructionBackend>();
    final harness = await _Harness.create(activation: activation);
    addTearDown(harness.dispose);
    await harness.lab.chooseExecutable();
    await _pumpLab(tester, harness.lab);
    await tester.tap(find.byKey(const Key('colmap-consent')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('activate-colmap')));
    await tester.pump();

    expect(find.text('Estado: ativando'), findsOneWidget);

    activation.complete(harness.backend);
    await tester.pumpAndSettle();
  });

  testWidgets('reports successful activation with version and active path', (
    tester,
  ) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.activate();
    await _pumpLab(tester, harness.lab);

    expect(find.text('Estado: pronto'), findsOneWidget);
    expect(find.text('Versão: 3.13-test'), findsOneWidget);
    expect(find.text('Caminho ativo: ${harness.executable}'), findsOneWidget);
  });

  testWidgets('reports activation failure without fabricating installation', (
    tester,
  ) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    harness.provisioning.failure = StateError('self test rejected');
    await harness.lab.chooseExecutable();
    await harness.lab.validateAndActivate(consent: true);
    await _pumpLab(tester, harness.lab);

    expect(harness.lab.activeInstallation, isNull);
    expect(harness.backendManager.contains('colmap'), isFalse);
    expect(find.textContaining('self test rejected'), findsOneWidget);
  });

  test(
    'failed reconfiguration preserves the previous active backend',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      await harness.activate();
      final previousRecord = harness.lab.activeInstallation;
      final previousBackend = harness.backendManager.get('colmap');
      harness.provisioning.failure = StateError('replacement rejected');

      await harness.lab.validateAndActivate(consent: true);

      expect(harness.lab.activeInstallation, same(previousRecord));
      expect(harness.backendManager.get('colmap'), same(previousBackend));
      expect(harness.lab.presentationError, isNotNull);
    },
  );

  testWidgets('empty photo directory blocks reconstruction', (tester) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.activate();
    final emptyLab = ColmapExperimentalLabController(
      operationalController: harness.operational,
      provisioningManager: harness.provisioning,
      selectExecutable: () async => harness.executable,
      selectPhotoDirectory: () async => r'C:\empty photos',
      workspaceRootProvider: () async => r'C:\managed workspace',
      inputValidator: _InputValidator(
        photoDirectory: ValidatedColmapPhotoDirectory(
          canonicalPath: r'C:\empty photos',
          canonicalImagePaths: const [],
        ),
      ),
    );
    addTearDown(emptyLab.dispose);
    await emptyLab.choosePhotoDirectory();
    await emptyLab.startReconstruction();
    await _pumpLab(tester, emptyLab);

    expect(harness.backend.calls, 0);
    expect(
      find.textContaining('não contém fotografias compatíveis'),
      findsOneWidget,
    );
  });

  test('preserves paths with spaces in the reconstruction evidence', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.activate();
    await harness.lab.choosePhotoDirectory();

    await harness.lab.startReconstruction();

    final capture = harness.backend.request!.evidenceGraph.nodes.firstWhere(
      (node) => node.kind.name == 'capture',
    );
    expect(capture.payload['path'], contains('photo set'));
    expect(capture.payload['path'], contains('image 01.jpg'));
  });

  testWidgets('double click does not duplicate a running reconstruction', (
    tester,
  ) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.activate();
    await harness.lab.choosePhotoDirectory();
    harness.backend.block = Completer<void>();
    await _pumpLab(tester, harness.lab);

    await tester.tap(find.byKey(const Key('start-reconstruction')));
    await tester.tap(find.byKey(const Key('start-reconstruction')));
    await tester.pump();

    expect(harness.backend.calls, 1);
    harness.backend.block!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('running enables only Cancel among operational actions', (
    tester,
  ) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.activate();
    await harness.lab.choosePhotoDirectory();
    harness.backend.block = Completer<void>();
    await _pumpLab(tester, harness.lab);
    await tester.tap(find.byKey(const Key('start-reconstruction')));
    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('start-reconstruction')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('activate-colmap')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('select-photos')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cancel-reconstruction')))
          .onPressed,
      isNotNull,
    );

    harness.backend.block!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('cancelling prevents a second cancellation', (tester) async {
    final cancellation = _Cancellation();
    final harness = await _Harness.create(cancellation: cancellation);
    addTearDown(harness.dispose);
    await harness.activate();
    await harness.lab.choosePhotoDirectory();
    harness.backend.block = Completer<void>();
    await _pumpLab(tester, harness.lab);
    await tester.tap(find.byKey(const Key('start-reconstruction')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('cancel-reconstruction')));
    await tester.pump();

    expect(find.text('Estado: cancelando'), findsOneWidget);
    expect(cancellation.calls, 1);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cancel-reconstruction')))
          .onPressed,
      isNull,
    );

    harness.backend.block!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('success presents a mesh candidate and artifact path', (
    tester,
  ) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.activate();
    await harness.lab.choosePhotoDirectory();
    await harness.lab.startReconstruction();
    await _pumpLab(tester, harness.lab);

    expect(find.byKey(const Key('mesh-candidate-result')), findsOneWidget);
    expect(find.textContaining('candidate mesh.ply'), findsOneWidget);
  });

  testWidgets('failure allows a new attempt', (tester) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.activate();
    await harness.lab.choosePhotoDirectory();
    harness.backend.failure = StateError('temporary reconstruction failure');
    await harness.lab.startReconstruction();
    await _pumpLab(tester, harness.lab);

    expect(find.text('Estado: falhou'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('start-reconstruction')))
          .onPressed,
      isNotNull,
    );

    harness.backend.failure = null;
    await tester.tap(find.byKey(const Key('start-reconstruction')));
    await tester.pumpAndSettle();
    expect(harness.backend.calls, 2);
    expect(find.text('Estado: concluído'), findsOneWidget);
  });

  testWidgets('diagnostic confidence is not presented as geometric quality', (
    tester,
  ) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.activate();
    await harness.lab.choosePhotoDirectory();
    await harness.lab.startReconstruction();
    await _pumpLab(tester, harness.lab);

    expect(find.textContaining('99%'), findsNothing);
    expect(find.textContaining('qualidade geométrica'), findsNothing);
    expect(
      find.text('Sucesso técnico não certifica precisão dimensional.'),
      findsOneWidget,
    );
  });

  testWidgets('completion after widget dispose does not call setState', (
    tester,
  ) async {
    final activation = Completer<ReconstructionBackend>();
    final harness = await _Harness.create(activation: activation);
    addTearDown(harness.dispose);
    await harness.lab.chooseExecutable();
    await _pumpLab(tester, harness.lab);
    await tester.tap(find.byKey(const Key('colmap-consent')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('activate-colmap')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    activation.complete(harness.backend);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'status is communicated with text and semantics, not color alone',
    (tester) async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      await harness.activate();
      await harness.lab.choosePhotoDirectory();
      harness.backend.block = Completer<void>();
      await _pumpLab(tester, harness.lab);
      await tester.tap(find.byKey(const Key('start-reconstruction')));
      await tester.pump();

      expect(find.text('Estado: executando'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Estado do COLMAP: executando'),
        findsOneWidget,
      );

      harness.backend.block!.complete();
      await tester.pumpAndSettle();
    },
  );

  test(
    'request contains canonical image path and managed workspace root',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'flcad_input_contract_',
      );
      addTearDown(() => root.delete(recursive: true));
      final photos = await Directory(
        '${root.path}${Platform.pathSeparator}Fotos São Paulo',
      ).create();
      await File(
        '${photos.path}${Platform.pathSeparator}peça 01.JPG',
      ).writeAsBytes([1]);
      final managedRoot =
          '${root.path}${Platform.pathSeparator}Área gerenciada com espaços';
      final validator = const IoColmapInputValidator();
      final harness = await _Harness.create(
        selectPhotoDirectory: () async => photos.path,
        workspaceRootProvider: () async => managedRoot,
        inputValidator: validator,
      );
      addTearDown(harness.dispose);
      await harness.activate();

      await harness.lab.choosePhotoDirectory();
      await harness.lab.startReconstruction();

      final canonicalPhotos = await photos.resolveSymbolicLinks();
      final canonicalWorkspace = await Directory(
        managedRoot,
      ).resolveSymbolicLinks();
      expect(
        harness.backend.request!.calibration['imagePath'],
        canonicalPhotos,
      );
      expect(
        harness.backend.request!.calibration['workspacePath'],
        canonicalWorkspace,
      );
      expect(canonicalWorkspace, isNot(equals(canonicalPhotos)));
      expect(path.isAbsolute(canonicalWorkspace), isTrue);
      expect(canonicalPhotos, contains('Fotos São Paulo'));
      expect(canonicalWorkspace, contains('Área gerenciada com espaços'));
    },
  );

  test('start revalidates and uses one fresh photo snapshot', () async {
    final validator = _InputValidator();
    final harness = await _Harness.create(inputValidator: validator);
    addTearDown(harness.dispose);
    await harness.activate();
    await harness.lab.choosePhotoDirectory();

    validator.photoDirectory = ValidatedColmapPhotoDirectory(
      canonicalPath: r'C:\capture jobs\fresh photo set',
      canonicalImagePaths: const [
        r'C:\capture jobs\fresh photo set\new 01.jpg',
        r'C:\capture jobs\fresh photo set\new 02.jpg',
      ],
    );
    await harness.lab.startReconstruction();

    expect(validator.photoCalls, 2);
    expect(validator.validatedPhotoPaths.last, r'C:\capture jobs\photo set');
    expect(
      harness.backend.request!.calibration['imagePath'],
      r'C:\capture jobs\fresh photo set',
    );
    final captures = harness.backend.request!.evidenceGraph.nodes
        .where((node) => node.kind == EvidenceNodeKind.capture)
        .toList();
    expect(captures, hasLength(2));
    expect(captures.map((node) => node.payload['path']), [
      r'C:\capture jobs\fresh photo set\new 01.jpg',
      r'C:\capture jobs\fresh photo set\new 02.jpg',
    ]);
    expect(harness.lab.photoDirectory!.imageCount, 2);
  });

  test('relative photo directory is rejected', () async {
    const validator = IoColmapInputValidator();

    await expectLater(
      validator.validatePhotoDirectory('relative/photos'),
      throwsArgumentError,
    );
  });

  test('missing and empty photo directories are rejected', () async {
    final root = await Directory.systemTemp.createTemp('flcad_input_empty_');
    addTearDown(() => root.delete(recursive: true));
    const validator = IoColmapInputValidator();

    await expectLater(
      validator.validatePhotoDirectory(
        '${root.path}${Platform.pathSeparator}missing',
      ),
      throwsArgumentError,
    );
    await expectLater(
      validator.validatePhotoDirectory(root.path),
      throwsArgumentError,
    );
  });

  test('empty image file is rejected', () async {
    final root = await Directory.systemTemp.createTemp('flcad_input_zero_');
    addTearDown(() => root.delete(recursive: true));
    await File(
      '${root.path}${Platform.pathSeparator}empty.jpg',
    ).writeAsBytes(const []);

    await expectLater(
      const IoColmapInputValidator().validatePhotoDirectory(root.path),
      throwsArgumentError,
    );
  });

  test('image link is rejected and never counted as a regular file', () async {
    final root = await Directory.systemTemp.createTemp('flcad_input_link_');
    addTearDown(() => root.delete(recursive: true));
    final target = await File(
      '${root.path}${Platform.pathSeparator}target.bin',
    ).writeAsBytes([1]);
    final link = Link('${root.path}${Platform.pathSeparator}linked.jpg');
    try {
      await link.create(target.path);
    } on FileSystemException {
      return;
    }

    await expectLater(
      const IoColmapInputValidator().validatePhotoDirectory(root.path),
      throwsArgumentError,
    );
  });

  test(
    'all supported extensions and uppercase extensions are accepted',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'flcad_input_extensions_',
      );
      addTearDown(() => root.delete(recursive: true));
      for (final extension in colmapSupportedImageExtensions) {
        await File(
          '${root.path}${Platform.pathSeparator}image$extension',
        ).writeAsBytes([1]);
      }
      await File(
        '${root.path}${Platform.pathSeparator}uppercase.JPG',
      ).writeAsBytes([1]);

      final result = await const IoColmapInputValidator()
          .validatePhotoDirectory(root.path);

      expect(result.imageCount, colmapSupportedImageExtensions.length + 1);
      expect(result.canonicalImagePaths, contains(endsWith('uppercase.JPG')));
    },
  );

  test('canonical image escaping the selected directory is rejected', () async {
    final root = await Directory.systemTemp.createTemp('flcad_input_escape_');
    addTearDown(() => root.delete(recursive: true));
    final photos = await Directory(
      '${root.path}${Platform.pathSeparator}photos',
    ).create();
    final selected = await File(
      '${photos.path}${Platform.pathSeparator}escape.jpg',
    ).writeAsBytes([1]);
    final external = await File(
      '${root.path}${Platform.pathSeparator}external.jpg',
    ).writeAsBytes([1]);
    final validator = IoColmapInputValidator(
      canonicalPathResolver: (value) async {
        if (value == selected.absolute.path) return external.absolute.path;
        return File(value).resolveSymbolicLinks();
      },
    );

    await expectLater(
      validator.validatePhotoDirectory(photos.path),
      throwsArgumentError,
    );
  });

  test('duplicate canonical image paths are rejected', () async {
    final root = await Directory.systemTemp.createTemp(
      'flcad_input_duplicate_',
    );
    addTearDown(() => root.delete(recursive: true));
    final first = await File(
      '${root.path}${Platform.pathSeparator}first.jpg',
    ).writeAsBytes([1]);
    final alias = await File(
      '${root.path}${Platform.pathSeparator}alias.jpg',
    ).writeAsBytes([1]);
    final validator = IoColmapInputValidator(
      canonicalPathResolver: (value) async {
        if (value == alias.absolute.path) return first.absolute.path;
        return File(value).resolveSymbolicLinks();
      },
    );

    await expectLater(
      validator.validatePhotoDirectory(root.path),
      throwsArgumentError,
    );
  });

  test('photo enumeration is not recursive', () async {
    final root = await Directory.systemTemp.createTemp('flcad_input_flat_');
    addTearDown(() => root.delete(recursive: true));
    await File(
      '${root.path}${Platform.pathSeparator}top.jpg',
    ).writeAsBytes([1]);
    final nested = await Directory(
      '${root.path}${Platform.pathSeparator}nested',
    ).create();
    await File(
      '${nested.path}${Platform.pathSeparator}nested.jpg',
    ).writeAsBytes([1]);

    final result = await const IoColmapInputValidator().validatePhotoDirectory(
      root.path,
    );

    expect(result.imageCount, 1);
    expect(result.canonicalImagePaths.single, endsWith('top.jpg'));
  });

  test('cancelled photo picker does not create a presentation error', () async {
    final harness = await _Harness.create(
      selectPhotoDirectory: () async => null,
    );
    addTearDown(harness.dispose);

    await harness.lab.choosePhotoDirectory();

    expect(harness.lab.photoDirectory, isNull);
    expect(harness.lab.presentationError, isNull);
  });

  test('photo picker exception becomes a presentation error', () async {
    final harness = await _Harness.create(
      selectPhotoDirectory: () async => throw StateError('picker unavailable'),
    );
    addTearDown(harness.dispose);

    await harness.lab.choosePhotoDirectory();

    expect(harness.lab.photoDirectory, isNull);
    expect(harness.lab.presentationError, isA<StateError>());
  });

  test('workspace provider failure prevents reconstruction start', () async {
    final harness = await _Harness.create(
      workspaceRootProvider: () async =>
          throw StateError('workspace unavailable'),
    );
    addTearDown(harness.dispose);
    await harness.activate();
    await harness.lab.choosePhotoDirectory();

    await harness.lab.startReconstruction();

    expect(harness.backend.calls, 0);
    expect(harness.lab.presentationError, isA<StateError>());
  });
}
