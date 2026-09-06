import 'dart:convert';
import 'dart:io';

import '../../../acquisition_intelligence/models/evidence_graph.dart';
import '../../engine/reconstruction_engine.dart';
import '../../models/reconstruction_contract.dart';
import '../reconstruction_backend_contract.dart';

class ColmapCommandResult {
  const ColmapCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.durationMs,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final int durationMs;

  bool get succeeded => exitCode == 0;
}

abstract interface class ColmapProcessRunner {
  Future<ColmapCommandResult> run(
    String executable,
    List<String> arguments, {
    required Directory workingDirectory,
    ReconstructionCancellation? cancellation,
  });

  Future<String?> version(String executable);
}

class IoColmapProcessRunner implements ColmapProcessRunner {
  const IoColmapProcessRunner();

  @override
  Future<ColmapCommandResult> run(
    String executable,
    List<String> arguments, {
    required Directory workingDirectory,
    ReconstructionCancellation? cancellation,
  }) async {
    final started = DateTime.now();
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory.path,
      runInShell: false,
    );
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final stdoutSubscription = process.stdout.transform(utf8.decoder).listen(stdout.write);
    final stderrSubscription = process.stderr.transform(utf8.decoder).listen(stderr.write);
    while (true) {
      if (cancellation?.isCancelled ?? false) {
        process.kill(ProcessSignal.sigterm);
        throw const ReconstructionCancelled();
      }
      final exitCode = await Future.any<int?>([
        process.exitCode,
        Future<void>.delayed(const Duration(milliseconds: 100)).then((_) => null),
      ]);
      if (exitCode == null) continue;
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      return ColmapCommandResult(
        exitCode: exitCode,
        stdout: stdout.toString(),
        stderr: stderr.toString(),
        durationMs: DateTime.now().difference(started).inMilliseconds,
      );
    }
  }

  @override
  Future<String?> version(String executable) async {
    try {
      final result = await run(
        executable,
        const ['-h'],
        workingDirectory: Directory.current,
      );
      final text = '${result.stdout}\n${result.stderr}';
      final match = RegExp(
        r'colmap[^\r\n]*',
        caseSensitive: false,
      ).firstMatch(text);
      return match?.group(0)?.trim();
    } on ProcessException {
      return null;
    }
  }
}

class ColmapBackend implements ReconstructionBackend {
  const ColmapBackend({
    this.executable = 'colmap',
    this.detectedVersion = 'undetected',
    ColmapProcessRunner? processRunner,
  }) : _processRunner = processRunner ?? const IoColmapProcessRunner();

  final String executable;
  final String detectedVersion;
  final ColmapProcessRunner _processRunner;

  @override
  String get id => 'colmap';

  @override
  ReconstructionBackendCapabilities get capabilities =>
      _capabilities(detectedVersion);

  ReconstructionBackendCapabilities _capabilities(String version) =>
      ReconstructionBackendCapabilities(
        supportsGpu: true,
        supportsCpu: true,
        incremental: true,
        denseReconstruction: true,
        texturing: false,
        automaticCalibration: true,
        license: 'BSD-3-Clause',
        version: version,
      );

  Future<ReconstructionBackendCapabilities> detectCapabilities() async {
    final detectedVersion = await _processRunner.version(executable);
    return _capabilities(detectedVersion ?? 'undetected');
  }

  @override
  Future<ReconstructionBackendResult> reconstruct(
    ReconstructionRequest request, {
    void Function(ReconstructionStageReport report)? onStage,
    ReconstructionCancellation? cancellation,
  }) async {
    final workspacePath = request.calibration['workspacePath'] as String?;
    final imagePath = request.calibration['imagePath'] as String?;
    if (workspacePath == null || imagePath == null) {
      throw ArgumentError('workspacePath and imagePath are required');
    }
    final workspaceRoot = Directory(workspacePath).absolute;
    await workspaceRoot.create(recursive: true);
    final images = Directory(imagePath).absolute;
    await _validateImageDirectory(images);
    final workspace = await workspaceRoot.createTemp(
      '${_safeRunPrefix(request.id)}-',
    );
    final database = File(
      '${workspace.path}${Platform.pathSeparator}database.db',
    );
    final sparse = Directory('${workspace.path}${Platform.pathSeparator}sparse');
    final sparseText = Directory(
      '${workspace.path}${Platform.pathSeparator}sparse_text',
    );
    final dense = Directory('${workspace.path}${Platform.pathSeparator}dense');
    await sparse.create(recursive: true);
    await sparseText.create(recursive: true);
    await dense.create(recursive: true);
    final reports = <ReconstructionStageReport>[];
    final started = DateTime.now();

    Future<void> execute(
      ReconstructionStage stage,
      List<String> arguments,
      String explanation,
      Future<void> Function() validateArtifacts,
    ) async {
      final stageStarted = DateTime.now();

      void emitFailure(String detail, int durationMs) {
        final report = ReconstructionStageReport(
          stage: stage,
          status: ReconstructionStageStatus.failed,
          confidence: 0,
          quality: 0,
          durationMs: durationMs,
          residuals: const {},
          dependencies: const [],
          accepted: false,
          explanation: '$explanation Falha: $detail',
        );
        reports.add(report);
        onStage?.call(report);
      }

      late final ColmapCommandResult result;
      try {
        result = await _processRunner.run(
          executable,
          arguments,
          workingDirectory: workspace,
          cancellation: cancellation,
        );
      } on ReconstructionCancelled {
        rethrow;
      } catch (error, stackTrace) {
        emitFailure(
          error.toString(),
          DateTime.now().difference(stageStarted).inMilliseconds,
        );
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (!result.succeeded) {
        emitFailure(result.stderr.trim(), result.durationMs);
        throw StateError(reports.last.explanation);
      }
      try {
        await validateArtifacts();
      } on ReconstructionCancelled {
        rethrow;
      } catch (error, stackTrace) {
        emitFailure(error.toString(), result.durationMs);
        Error.throwWithStackTrace(error, stackTrace);
      }
      final report = ReconstructionStageReport(
        stage: stage,
        status: ReconstructionStageStatus.completed,
        confidence: 1,
        quality: 1,
        durationMs: result.durationMs,
        residuals: const {},
        dependencies: const [],
        accepted: true,
        explanation: explanation,
      );
      reports.add(report);
      onStage?.call(report);
    }

    await execute(
      ReconstructionStage.featureDetection,
      [
        'feature_extractor',
        '--database_path',
        database.path,
        '--image_path',
        images.path,
        '--ImageReader.single_camera',
        '1',
      ],
      'COLMAP detectou características das imagens fornecidas pelo Evidence Graph.',
      () => _requireNonEmptyFile(database, 'database.db'),
    );
    final featureDatabaseFingerprint = await _fingerprint(database);
    await execute(
      ReconstructionStage.featureMatching,
      [
        'exhaustive_matcher',
        '--database_path',
        database.path,
      ],
      'COLMAP calculou correspondências entre as observações disponíveis.',
      () async {
        await _requireNonEmptyFile(database, 'database.db');
        final matchedDatabaseFingerprint = await _fingerprint(database);
        if (matchedDatabaseFingerprint == featureDatabaseFingerprint) {
          throw StateError(
            'COLMAP did not modify database.db while matching features.',
          );
        }
      },
    );
    await execute(
      ReconstructionStage.cameraCalibration,
      [
        'mapper',
        '--database_path',
        database.path,
        '--image_path',
        images.path,
        '--output_path',
        sparse.path,
      ],
      'COLMAP estimou a calibração a partir das correspondências.',
      () => _discoverSparseModel(sparse).then((_) {}),
    );
    final sparseModel = await _discoverSparseModel(sparse);
    await execute(
      ReconstructionStage.poseEstimation,
      [
        'image_undistorter',
        '--image_path',
        images.path,
        '--input_path',
        sparseModel.path,
        '--output_path',
        dense.path,
        '--output_type',
        'COLMAP',
      ],
      'COLMAP produziu poses calibradas para as imagens observadas.',
      () async {
        await _requireModelInEitherFormat(
          Directory('${dense.path}${Platform.pathSeparator}sparse'),
          'undistorted sparse model',
        );
        await _requireSupportedNonEmptyImage(
          Directory('${dense.path}${Platform.pathSeparator}images'),
          'undistorted image output',
        );
      },
    );
    await execute(
      ReconstructionStage.sparseReconstruction,
      [
        'model_converter',
        '--input_path',
        sparseModel.path,
        '--output_path',
        sparseText.path,
        '--output_type',
        'TXT',
      ],
      'COLMAP disponibilizou a reconstrução esparsa para o contrato interno.',
      () => _requireCompleteModel(
        sparseText,
        const ['cameras.txt', 'images.txt', 'points3D.txt'],
        'sparse text model',
      ),
    );
    await execute(
      ReconstructionStage.denseReconstruction,
      [
        'patch_match_stereo',
        '--workspace_path',
        dense.path,
        '--workspace_format',
        'COLMAP',
      ],
      'COLMAP calculou a profundidade densa a partir das poses calibradas.',
      () => _requireNonEmptyDirectory(
        Directory(
          '${dense.path}${Platform.pathSeparator}stereo'
          '${Platform.pathSeparator}depth_maps',
        ),
        'dense depth-map output',
      ),
    );
    await execute(
      ReconstructionStage.meshGeneration,
      [
        'stereo_fusion',
        '--workspace_path',
        dense.path,
        '--output_path',
        '${dense.path}${Platform.pathSeparator}fused.ply',
      ],
      'COLMAP produziu uma nuvem densa sem convertê-la em malha definitiva.',
      () => _requireNonEmptyFile(
        File('${dense.path}${Platform.pathSeparator}fused.ply'),
        'fused.ply',
      ),
    );
    final meshCandidate = File(
      '${dense.path}${Platform.pathSeparator}mesh_candidate.ply',
    );
    await execute(
      ReconstructionStage.optimization,
      [
        'poisson_mesher',
        '--input_path',
        '${dense.path}${Platform.pathSeparator}fused.ply',
        '--output_path',
        meshCandidate.path,
      ],
      'COLMAP produziu um candidato de malha sem reparo ou otimização adicional.',
      () => _requireNonEmptyFile(meshCandidate, 'mesh_candidate.ply'),
    );

    final output = ReconstructionOutput(
      requestId: request.id,
      stageReports: List.unmodifiable(reports),
      confidenceMap: const [],
      provenance: const {},
      meshCandidate: {
        'path': meshCandidate.path,
        'final': false,
        'provenance': ProvenanceSource.photogrammetry.name,
      },
      sparseCloud: [
        {
          'path': sparseText.path,
          'provenance': ProvenanceSource.photogrammetry.name,
        },
      ],
      denseCloud: [
        {
          'path': '${dense.path}${Platform.pathSeparator}fused.ply',
          'provenance': ProvenanceSource.photogrammetry.name,
        },
      ],
      evidenceGraph: request.evidenceGraph,
    );
    final captureCount = request.evidenceGraph.nodes
        .where((node) => node.kind == EvidenceNodeKind.capture)
        .length;
    return ReconstructionBackendResult(
      output: output,
      diagnostics: ReconstructionBackendDiagnostics(
        backendId: id,
        backendVersion: capabilities.version,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        memoryBytes: null,
        confidence: reports.isEmpty
            ? 0
            : reports.map((e) => e.confidence).reduce((a, b) => a + b) /
                  reports.length,
        completedStages: reports.map((report) => report.stage).toList(),
        limitations: const [
          'Texturing is disabled.',
          'Mesh candidate is not repaired, closed or optimized.',
        ],
        explanations: {
          for (final report in reports)
            report.stage:
                '${report.explanation} Capturas consideradas: $captureCount.',
        },
      ),
    );
  }
}

const _supportedImageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.tif',
  '.tiff',
  '.bmp',
  '.webp',
};

Future<void> _validateImageDirectory(Directory directory) async {
  if (!await directory.exists()) {
    throw ArgumentError.value(directory.path, 'imagePath', 'does not exist');
  }
  final hasSupportedImage = await directory.list(followLinks: false).any(
    (entity) {
      if (entity is! File) return false;
      final name = entity.uri.pathSegments.last.toLowerCase();
      return _supportedImageExtensions.any(name.endsWith);
    },
  );
  if (!hasSupportedImage) {
    throw ArgumentError.value(
      directory.path,
      'imagePath',
      'does not contain a supported image',
    );
  }
}

String _safeRunPrefix(String requestId) {
  final safe = requestId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final bounded = safe.length > 48 ? safe.substring(0, 48) : safe;
  return bounded.isEmpty ? 'run' : bounded;
}

Future<({int length, int hash})> _fingerprint(File file) async {
  var length = 0;
  var hash = 0x811c9dc5;
  await for (final chunk in file.openRead()) {
    length += chunk.length;
    for (final byte in chunk) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
  }
  return (length: length, hash: hash);
}

Future<void> _requireNonEmptyFile(File file, String label) async {
  if (!await file.exists() || await file.length() == 0) {
    throw StateError('COLMAP did not produce a non-empty $label artifact.');
  }
}

Future<void> _requireNonEmptyDirectory(
  Directory directory,
  String label,
) async {
  if (!await directory.exists()) {
    throw StateError('COLMAP did not produce the $label directory.');
  }
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File && await entity.length() > 0) return;
  }
  throw StateError('COLMAP did not produce a non-empty $label artifact.');
}

Future<void> _requireSupportedNonEmptyImage(
  Directory directory,
  String label,
) async {
  if (await directory.exists()) {
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || await entity.length() == 0) continue;
      final name = entity.uri.pathSegments.last.toLowerCase();
      if (_supportedImageExtensions.any(name.endsWith)) return;
    }
  }
  throw StateError('COLMAP did not produce a non-empty $label artifact.');
}

Future<void> _requireCompleteModel(
  Directory directory,
  List<String> names,
  String label,
) async {
  final valid = await Future.wait(
    names.map((name) async {
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      return await file.exists() && await file.length() > 0;
    }),
  );
  if (!valid.every((value) => value)) {
    throw StateError('COLMAP did not produce a complete non-empty $label.');
  }
}

Future<void> _requireModelInEitherFormat(
  Directory directory,
  String label,
) async {
  for (final names in const [
    ['cameras.bin', 'images.bin', 'points3D.bin'],
    ['cameras.txt', 'images.txt', 'points3D.txt'],
  ]) {
    try {
      await _requireCompleteModel(directory, names, label);
      return;
    } on StateError {
      // Try the other supported COLMAP representation.
    }
  }
  throw StateError('COLMAP did not produce a complete non-empty $label.');
}

Future<Directory> _discoverSparseModel(Directory sparseRoot) async {
  if (!await sparseRoot.exists()) {
    throw StateError('COLMAP did not produce a sparse model directory.');
  }
  final candidates = await sparseRoot
      .list(followLinks: false)
      .where((entity) => entity is Directory)
      .cast<Directory>()
      .toList();
  candidates.sort((left, right) => left.path.compareTo(right.path));
  for (final candidate in candidates) {
    try {
      await _requireModelInEitherFormat(candidate, 'sparse model');
      return candidate;
    } on StateError {
      // Keep looking: COLMAP may produce more than one candidate model.
    }
  }
  throw StateError('COLMAP did not produce a complete non-empty sparse model.');
}
