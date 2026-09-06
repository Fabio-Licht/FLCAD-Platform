import 'dart:convert';
import 'dart:io';

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
      runInShell: Platform.isWindows,
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
      final match = RegExp(r'(?i)colmap[^\r\n]*').firstMatch(text);
      return match?.group(0)?.trim();
    } on ProcessException {
      return null;
    }
  }
}

class ColmapBackend implements ReconstructionBackend {
  const ColmapBackend({
    this.executable = 'colmap',
    ColmapProcessRunner? processRunner,
  }) : _processRunner = processRunner ?? const IoColmapProcessRunner();

  final String executable;
  final ColmapProcessRunner _processRunner;
  String? _detectedVersion;

  @override
  String get id => 'colmap';

  @override
  ReconstructionBackendCapabilities get capabilities =>
      ReconstructionBackendCapabilities(
        supportsGpu: true,
        supportsCpu: true,
        incremental: true,
        denseReconstruction: true,
        texturing: false,
        automaticCalibration: true,
        license: 'BSD-3-Clause',
        version: _detectedVersion ?? 'undetected',
      );

  Future<ReconstructionBackendCapabilities> detectCapabilities() async {
    _detectedVersion = await _processRunner.version(executable);
    return capabilities;
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
    final workspace = Directory(workspacePath);
    await workspace.create(recursive: true);
    final database = File('${workspace.path}${Platform.pathSeparator}database.db');
    final sparse = Directory('${workspace.path}${Platform.pathSeparator}sparse');
    final dense = Directory('${workspace.path}${Platform.pathSeparator}dense');
    final reports = <ReconstructionStageReport>[];
    final diagnostics = <String>[];
    final started = DateTime.now();

    Future<void> execute(
      ReconstructionStage stage,
      List<String> arguments,
      String explanation,
    ) async {
      final result = await _processRunner.run(
        executable,
        arguments,
        workingDirectory: workspace,
        cancellation: cancellation,
      );
      final accepted = result.succeeded;
      final report = ReconstructionStageReport(
        stage: stage,
        status: accepted
            ? ReconstructionStageStatus.completed
            : ReconstructionStageStatus.failed,
        confidence: accepted ? 1 : 0,
        quality: accepted ? 1 : 0,
        durationMs: result.durationMs,
        residuals: const {},
        dependencies: const [],
        accepted: accepted,
        explanation: accepted
            ? explanation
            : '$explanation Falha: ${result.stderr.trim()}',
      );
      reports.add(report);
      onStage?.call(report);
      if (!accepted) {
        throw StateError(report.explanation);
      }
    }

    await execute(
      ReconstructionStage.featureDetection,
      [
        'feature_extractor',
        '--database_path',
        database.path,
        '--image_path',
        imagePath,
        '--ImageReader.single_camera',
        '1',
      ],
      'COLMAP detectou características das imagens fornecidas pelo Evidence Graph.',
    );
    await execute(
      ReconstructionStage.featureMatching,
      [
        'exhaustive_matcher',
        '--database_path',
        database.path,
      ],
      'COLMAP calculou correspondências entre as observações disponíveis.',
    );
    await execute(
      ReconstructionStage.cameraCalibration,
      [
        'mapper',
        '--database_path',
        database.path,
        '--image_path',
        imagePath,
        '--output_path',
        sparse.path,
      ],
      'COLMAP estimou a calibração a partir das correspondências.',
    );
    await execute(
      ReconstructionStage.poseEstimation,
      [
        'image_undistorter',
        '--image_path',
        imagePath,
        '--input_path',
        '${sparse.path}${Platform.pathSeparator}0',
        '--output_path',
        dense.path,
        '--output_type',
        'COLMAP',
      ],
      'COLMAP produziu poses calibradas para as imagens observadas.',
    );
    await execute(
      ReconstructionStage.sparseReconstruction,
      ['model_converter', '--input_path', sparse.path, '--output_path', sparse.path, '--output_type', 'TXT],
      'COLMAP disponibilizou a reconstrução esparsa para o contrato interno.',
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
        {'path': sparse.path, 'provenance': ProvenanceSource.photogrammetry.name},
      ],
      denseCloud: [
        {'path': '${dense.path}${Platform.pathSeparator}fused.ply', 'provenance': ProvenanceSource.photogrammetry.name},
      ],
      evidenceGraph: request.evidenceGraph,
    );
    diagnostics.add('images=${request.evidenceGraph.nodes.length}');
    return ReconstructionBackendResult(
      output: output,
      diagnostics: ReconstructionBackendDiagnostics(
        backendId: id,
        backendVersion: capabilities.version,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        memoryBytes: null,
        confidence: reports.isEmpty ? 0 : reports.map((e) => e.confidence).reduce((a, b) => a + b) / reports.length,
        completedStages: reports.map((report) => report.stage).toList(),
        limitations: const [
          'Texturing is disabled.',
          'Mesh candidate is not repaired, closed or optimized.',
        ],
        explanations: {for (final report in reports) report.stage: report.explanation},
      ),
    );
  }
}
