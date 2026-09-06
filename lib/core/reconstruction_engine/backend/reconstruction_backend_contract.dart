import '../models/reconstruction_contract.dart';

enum BackendSelectionMode { automatic, manual, preferred, fallback }

class ReconstructionBackendCapabilities {
  const ReconstructionBackendCapabilities({
    required this.supportsGpu,
    required this.supportsCpu,
    required this.incremental,
    required this.denseReconstruction,
    required this.texturing,
    required this.automaticCalibration,
    required this.license,
    required this.version,
  });

  final bool supportsGpu;
  final bool supportsCpu;
  final bool incremental;
  final bool denseReconstruction;
  final bool texturing;
  final bool automaticCalibration;
  final String license;
  final String version;

  Map<String, dynamic> toJson() => {
    'supportsGpu': supportsGpu,
    'supportsCpu': supportsCpu,
    'incremental': incremental,
    'denseReconstruction': denseReconstruction,
    'texturing': texturing,
    'automaticCalibration': automaticCalibration,
    'license': license,
    'version': version,
  };
}

class ReconstructionBackendDiagnostics {
  const ReconstructionBackendDiagnostics({
    required this.backendId,
    required this.backendVersion,
    required this.durationMs,
    required this.memoryBytes,
    required this.confidence,
    required this.completedStages,
    required this.limitations,
    required this.explanations,
  });

  final String backendId;
  final String backendVersion;
  final int durationMs;
  final int? memoryBytes;
  final double confidence;
  final List<ReconstructionStage> completedStages;
  final List<String> limitations;
  final Map<ReconstructionStage, String> explanations;

  Map<String, dynamic> toJson() => {
    'backendId': backendId,
    'backendVersion': backendVersion,
    'durationMs': durationMs,
    'memoryBytes': memoryBytes,
    'confidence': confidence,
    'completedStages': completedStages.map((stage) => stage.name).toList(),
    'limitations': limitations,
    'explanations': explanations.map(
      (stage, explanation) => MapEntry(stage.name, explanation),
    ),
  };

  factory ReconstructionBackendDiagnostics.fromJson(
    Map<String, dynamic> json,
  ) => ReconstructionBackendDiagnostics(
    backendId: json['backendId'] as String,
    backendVersion: json['backendVersion'] as String,
    durationMs: json['durationMs'] as int,
    memoryBytes: json['memoryBytes'] as int?,
    confidence: (json['confidence'] as num).toDouble(),
    completedStages: (json['completedStages'] as List<dynamic>)
        .map((stage) => ReconstructionStage.values.byName(stage as String))
        .toList(),
    limitations: (json['limitations'] as List<dynamic>).cast<String>(),
    explanations: (json['explanations'] as Map<String, dynamic>).map(
      (stage, explanation) => MapEntry(
        ReconstructionStage.values.byName(stage),
        explanation as String,
      ),
    ),
  );
}

class ReconstructionBackendResult {
  const ReconstructionBackendResult({
    required this.output,
    required this.diagnostics,
  });

  final ReconstructionOutput output;
  final ReconstructionBackendDiagnostics diagnostics;

  Map<String, dynamic> toJson() => {
    'output': output.toJson(),
    'diagnostics': diagnostics.toJson(),
  };
}

abstract interface class ReconstructionBackend {
  String get id;
  ReconstructionBackendCapabilities get capabilities;

  Future<ReconstructionBackendResult> reconstruct(
    ReconstructionRequest request, {
    void Function(ReconstructionStageReport report)? onStage,
    ReconstructionCancellation? cancellation,
  });
}

abstract interface class ReconstructionCancellation {
  bool get isCancelled;
}
