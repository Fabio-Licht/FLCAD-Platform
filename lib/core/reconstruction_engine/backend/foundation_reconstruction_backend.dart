import 'reconstruction_backend_contract.dart';
import '../engine/reconstruction_engine.dart';

class FoundationReconstructionBackend implements ReconstructionBackend {
  const FoundationReconstructionBackend();

  @override
  String get id => 'foundation';

  @override
  ReconstructionBackendCapabilities get capabilities =>
      const ReconstructionBackendCapabilities(
        supportsGpu: false,
        supportsCpu: true,
        incremental: true,
        denseReconstruction: false,
        texturing: false,
        automaticCalibration: false,
        license: 'FLSCAN internal foundation',
        version: '1.0.0',
      );

  @override
  Future<ReconstructionBackendResult> reconstruct(
    ReconstructionRequest request, {
    void Function(ReconstructionStageReport report)? onStage,
    ReconstructionCancellation? cancellation,
  }) async {
    final started = DateTime.now();
    final output = await const ReconstructionEngine().run(
      request,
      cancellation: cancellation,
      onStage: onStage,
    );
    final completed = output.stageReports
        .where(
          (report) =>
              report.status == ReconstructionStageStatus.completed ||
              report.status == ReconstructionStageStatus.skipped,
        )
        .map((report) => report.stage)
        .toList();
    return ReconstructionBackendResult(
      output: output,
      diagnostics: ReconstructionBackendDiagnostics(
        backendId: id,
        backendVersion: capabilities.version,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        memoryBytes: null,
        confidence: output.confidenceMap.isEmpty
            ? 0
            : output.confidenceMap.first.confidence,
        completedStages: completed,
        limitations: const [
          'Foundation adapter does not execute a reconstruction algorithm.',
          'Dense reconstruction and texturing are unavailable.',
        ],
        explanations: {
          for (final report in output.stageReports)
            report.stage: report.explanation,
        },
      ),
    );
  }
}
