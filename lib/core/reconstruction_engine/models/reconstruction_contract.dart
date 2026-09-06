import '../../acquisition_intelligence/models/evidence_graph.dart';

enum ReconstructionStage {
  featureDetection,
  featureMatching,
  cameraCalibration,
  poseEstimation,
  sparseReconstruction,
  denseReconstruction,
  meshGeneration,
  optimization,
}

enum ReconstructionStageStatus { pending, running, completed, skipped, failed }

enum ConfidenceBand { high, medium, low, noEvidence }

enum ProvenanceSource {
  photogrammetry,
  scanner,
  interpolation,
  fusion,
  unknown,
}

class ReconstructionRequest {
  const ReconstructionRequest({
    required this.id,
    required this.projectId,
    required this.evidenceGraph,
    this.calibration = const {},
    this.completedStages = const {},
    this.previousOutput,
  });

  final String id;
  final String projectId;
  final EvidenceGraph evidenceGraph;
  final Map<String, dynamic> calibration;
  final Set<ReconstructionStage> completedStages;
  final ReconstructionOutput? previousOutput;

  Map<String, dynamic> toJson() => {
    'id': id,
    'projectId': projectId,
    'evidenceGraph': evidenceGraph.toJson(),
    'calibration': calibration,
    'completedStages': completedStages.map((stage) => stage.name).toList(),
    'previousOutput': previousOutput?.toJson(),
  };

  factory ReconstructionRequest.fromJson(Map<String, dynamic> json) =>
      ReconstructionRequest(
        id: json['id'] as String,
        projectId: json['projectId'] as String,
        evidenceGraph: EvidenceGraph.fromJson(
          Map<String, dynamic>.from(json['evidenceGraph'] as Map),
        ),
        calibration: Map<String, dynamic>.from(
          (json['calibration'] as Map<String, dynamic>?) ?? const {},
        ),
        completedStages: (json['completedStages'] as List<dynamic>? ?? const [])
            .map((stage) => ReconstructionStage.values.byName(stage as String))
            .toSet(),
        previousOutput:
            (json['previousOutput'] as Map<String, dynamic>?) == null
            ? null
            : ReconstructionOutput.fromJson(
                json['previousOutput'] as Map<String, dynamic>,
              ),
      );
}

class ReconstructionStageReport {
  const ReconstructionStageReport({
    required this.stage,
    required this.status,
    required this.confidence,
    required this.quality,
    required this.durationMs,
    required this.residuals,
    required this.dependencies,
    required this.accepted,
    required this.explanation,
  });

  final ReconstructionStage stage;
  final ReconstructionStageStatus status;
  final double confidence;
  final double quality;
  final int durationMs;
  final Map<String, double> residuals;
  final List<String> dependencies;
  final bool accepted;
  final String explanation;

  Map<String, dynamic> toJson() => {
    'stage': stage.name,
    'status': status.name,
    'confidence': confidence,
    'quality': quality,
    'durationMs': durationMs,
    'residuals': residuals,
    'dependencies': dependencies,
    'accepted': accepted,
    'explanation': explanation,
  };

  factory ReconstructionStageReport.fromJson(Map<String, dynamic> json) =>
      ReconstructionStageReport(
        stage: ReconstructionStage.values.byName(json['stage'] as String),
        status: ReconstructionStageStatus.values.byName(
          json['status'] as String,
        ),
        confidence: (json['confidence'] as num).toDouble(),
        quality: (json['quality'] as num).toDouble(),
        durationMs: json['durationMs'] as int,
        residuals: (json['residuals'] as Map<String, dynamic>).map(
          (key, value) => MapEntry(key, (value as num).toDouble()),
        ),
        dependencies: (json['dependencies'] as List<dynamic>).cast<String>(),
        accepted: json['accepted'] as bool,
        explanation: json['explanation'] as String,
      );
}

class ConfidenceRegion {
  const ConfidenceRegion({
    required this.id,
    required this.band,
    required this.confidence,
    required this.evidenceIds,
    required this.provenance,
  });

  final String id;
  final ConfidenceBand band;
  final double confidence;
  final List<String> evidenceIds;
  final ProvenanceSource provenance;

  Map<String, dynamic> toJson() => {
    'id': id,
    'band': band.name,
    'confidence': confidence,
    'evidenceIds': evidenceIds,
    'provenance': provenance.name,
  };

  factory ConfidenceRegion.fromJson(Map<String, dynamic> json) =>
      ConfidenceRegion(
        id: json['id'] as String,
        band: ConfidenceBand.values.byName(json['band'] as String),
        confidence: (json['confidence'] as num).toDouble(),
        evidenceIds: (json['evidenceIds'] as List<dynamic>).cast<String>(),
        provenance: ProvenanceSource.values.byName(
          json['provenance'] as String,
        ),
      );
}

class ReconstructionOutput {
  const ReconstructionOutput({
    required this.requestId,
    required this.stageReports,
    required this.confidenceMap,
    required this.provenance,
    required this.meshCandidate,
    required this.sparseCloud,
    required this.denseCloud,
    required this.evidenceGraph,
  });

  final String requestId;
  final List<ReconstructionStageReport> stageReports;
  final List<ConfidenceRegion> confidenceMap;
  final Map<String, ProvenanceSource> provenance;
  final Map<String, dynamic>? meshCandidate;
  final List<Map<String, dynamic>> sparseCloud;
  final List<Map<String, dynamic>> denseCloud;
  final EvidenceGraph evidenceGraph;

  ReconstructionStage? get currentStage => stageReports
      .where((report) => report.status == ReconstructionStageStatus.running)
      .map((report) => report.stage)
      .cast<ReconstructionStage?>()
      .firstOrNull;

  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'stageReports': stageReports.map((report) => report.toJson()).toList(),
    'confidenceMap': confidenceMap.map((region) => region.toJson()).toList(),
    'provenance': provenance.map((key, value) => MapEntry(key, value.name)),
    'meshCandidate': meshCandidate,
    'sparseCloud': sparseCloud,
    'denseCloud': denseCloud,
    'evidenceGraph': evidenceGraph.toJson(),
  };

  factory ReconstructionOutput.fromJson(
    Map<String, dynamic> json,
  ) => ReconstructionOutput(
    requestId: json['requestId'] as String,
    stageReports: (json['stageReports'] as List<dynamic>)
        .map(
          (item) => ReconstructionStageReport.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(),
    confidenceMap: (json['confidenceMap'] as List<dynamic>)
        .map(
          (item) =>
              ConfidenceRegion.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
    provenance: (json['provenance'] as Map<String, dynamic>).map(
      (key, value) =>
          MapEntry(key, ProvenanceSource.values.byName(value as String)),
    ),
    meshCandidate: json['meshCandidate'] as Map<String, dynamic>?,
    sparseCloud: (json['sparseCloud'] as List<dynamic>)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(),
    denseCloud: (json['denseCloud'] as List<dynamic>)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(),
    evidenceGraph: EvidenceGraph.fromJson(
      Map<String, dynamic>.from(json['evidenceGraph'] as Map),
    ),
  );
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
