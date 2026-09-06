import 'dart:async';

import '../../acquisition_intelligence/models/evidence_graph.dart';
import '../backend/reconstruction_backend_contract.dart';
import '../models/reconstruction_contract.dart';

class ReconstructionCancelled implements Exception {
  const ReconstructionCancelled();
}

class ReconstructionEngine {
  const ReconstructionEngine();

  static const stages = ReconstructionStage.values;

  Future<ReconstructionOutput> run(
    ReconstructionRequest request, {
    ReconstructionCancellation? cancellation,
    void Function(ReconstructionStageReport report)? onStage,
  }) async {
    final reports = <ReconstructionStageReport>[];
    final captureNodes = request.evidenceGraph.nodes
        .where((node) => node.kind == EvidenceNodeKind.capture)
        .toList(growable: false);
    final captureCount = captureNodes.length;
    final evidenceIds = captureNodes
        .map((node) => node.id)
        .toList();
    final provenance = <String, ProvenanceSource>{};
    final confidenceMap = <ConfidenceRegion>[];

    for (final stage in stages) {
      if (cancellation?.isCancelled ?? false) {
        throw const ReconstructionCancelled();
      }
      final started = DateTime.now();
      final skipped = request.completedStages.contains(stage);
      final confidence = captureCount == 0
          ? 0.0
          : (captureCount / 10).clamp(0.0, 1.0);
      final report = ReconstructionStageReport(
        stage: stage,
        status: skipped
            ? ReconstructionStageStatus.skipped
            : ReconstructionStageStatus.pending,
        confidence: confidence,
        quality: confidence,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        residuals: const {},
        dependencies: _dependencies(stage),
        accepted: false,
        explanation: skipped
            ? 'Etapa declarada como já processada pela solicitação; o '
                  'Foundation não validou nem executou seu resultado.'
            : captureCount > 0
            ? 'Etapa pendente: há $captureCount captura(s), mas o Foundation '
                  'não executa reconstrução.'
            : 'Etapa pendente: não há capturas e o Foundation não executa '
                  'reconstrução.',
      );
      reports.add(report);
      onStage?.call(report);
      if (stage == ReconstructionStage.sparseReconstruction &&
          captureCount > 0) {
        confidenceMap.add(
          ConfidenceRegion(
            id: 'region:global',
            band: confidence >= .8
                ? ConfidenceBand.high
                : confidence >= .5
                ? ConfidenceBand.medium
                : ConfidenceBand.low,
            confidence: confidence,
            evidenceIds: evidenceIds,
            provenance: ProvenanceSource.unknown,
          ),
        );
      }
      await Future<void>.value();
    }

    return ReconstructionOutput(
      requestId: request.id,
      stageReports: List.unmodifiable(reports),
      confidenceMap: List.unmodifiable(confidenceMap),
      provenance: provenance,
      meshCandidate: null,
      sparseCloud: const [],
      denseCloud: const [],
      evidenceGraph: request.evidenceGraph,
    );
  }

  List<String> _dependencies(ReconstructionStage stage) => switch (stage) {
    ReconstructionStage.featureDetection => const [],
    ReconstructionStage.featureMatching => const ['featureDetection'],
    ReconstructionStage.cameraCalibration => const ['featureDetection'],
    ReconstructionStage.poseEstimation => const [
      'featureMatching',
      'cameraCalibration',
    ],
    ReconstructionStage.sparseReconstruction => const ['poseEstimation'],
    ReconstructionStage.denseReconstruction => const ['sparseReconstruction'],
    ReconstructionStage.meshGeneration => const ['denseReconstruction'],
    ReconstructionStage.optimization => const ['meshGeneration'],
  };
}
