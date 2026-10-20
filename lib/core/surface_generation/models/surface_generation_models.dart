import '../../adaptive_surface/continuity/surface_continuity.dart';
import '../../adaptive_surface/models/surface_geometry.dart';
import '../../cad_kernel/io/kernel_io_models.dart';
import '../../cad_kernel/models/kernel_models.dart';
import '../../surface_intelligence/models/surface_models.dart';

enum SurfaceGenerationStatus { generated, invalid, unavailable, failed }

enum SurfacePipelineStage {
  candidateValidation,
  geometryBuilder,
  shapeValidation,
  healingProposal,
  registration,
  engineeringGraph,
  history,
  analytics,
}

class SurfaceGenerationRequest {
  const SurfaceGenerationRequest({
    required this.candidate,
    required this.parameters,
    this.featureId,
    this.tolerance = 1e-4,
    this.origin = 'surface-intelligence',
  });
  final SurfaceCandidate candidate;
  final Map<String, dynamic> parameters;
  final String? featureId;
  final double tolerance;
  final String origin;
}

class GeneratedSurface {
  const GeneratedSurface({
    required this.surfaceId,
    required this.projectId,
    required this.kind,
    required this.origin,
    required this.regionIds,
    required this.evidenceIds,
    required this.featureId,
    required this.handle,
    required this.revision,
    required this.timestamp,
    required this.parameters,
    required this.continuity,
    required this.valid,
    required this.confidence,
    required this.diagnostics,
  });
  final String surfaceId, projectId, origin;
  final SurfaceKind kind;
  final List<String> regionIds, evidenceIds;
  final String? featureId;
  final ShapeHandle handle;
  final int revision;
  final DateTime timestamp;
  final Map<String, dynamic> parameters;
  final SurfaceContinuityLevel continuity;
  final bool valid;
  final double confidence;
  final List<GeometryDiagnostic> diagnostics;
  GeneratedSurface copyWith({Map<String, dynamic>? parameters}) =>
      GeneratedSurface(
        surfaceId: surfaceId,
        projectId: projectId,
        kind: kind,
        origin: origin,
        regionIds: regionIds,
        evidenceIds: evidenceIds,
        featureId: featureId,
        handle: handle,
        revision: revision,
        timestamp: timestamp,
        parameters: parameters ?? this.parameters,
        continuity: continuity,
        valid: valid,
        confidence: confidence,
        diagnostics: diagnostics,
      );
  Map<String, dynamic> toJson() => {
    'surfaceId': surfaceId,
    'projectId': projectId,
    'kind': kind.name,
    'origin': origin,
    'regionIds': regionIds,
    'evidenceIds': evidenceIds,
    'featureId': featureId,
    'handle': handle.toJson(),
    'revision': revision,
    'timestamp': timestamp.toIso8601String(),
    'parameters': parameters,
    'continuity': continuity.name,
    'valid': valid,
    'confidence': confidence,
    'diagnostics': diagnostics
        .map(
          (e) => {
            'code': e.code,
            'message': e.message,
            'severity': e.severity,
            'shapeId': e.shapeId,
            'metadata': e.metadata,
          },
        )
        .toList(),
  };
  factory GeneratedSurface.fromJson(Map<String, dynamic> json) =>
      GeneratedSurface(
        surfaceId: json['surfaceId'] as String,
        projectId: json['projectId'] as String,
        kind: SurfaceKind.values.byName(json['kind'] as String),
        origin: json['origin'] as String,
        regionIds: (json['regionIds'] as List).cast<String>(),
        evidenceIds: (json['evidenceIds'] as List).cast<String>(),
        featureId: json['featureId'] as String?,
        handle: ShapeHandle.fromJson(
          (json['handle'] as Map).cast<String, dynamic>(),
        ),
        revision: json['revision'] as int,
        timestamp: DateTime.parse(json['timestamp'] as String),
        parameters: (json['parameters'] as Map).cast<String, dynamic>(),
        continuity: SurfaceContinuityLevel.values.byName(
          json['continuity'] as String,
        ),
        valid: json['valid'] as bool,
        confidence: (json['confidence'] as num).toDouble(),
        diagnostics: (json['diagnostics'] as List)
            .map(
              (value) => GeometryDiagnostic(
                code: value['code'] as String,
                message: value['message'] as String,
                severity: value['severity'] as String,
                shapeId: value['shapeId'] as String?,
                metadata: (value['metadata'] as Map? ?? const {})
                    .cast<String, dynamic>(),
              ),
            )
            .toList(),
      );
}

class SurfaceGenerationResult {
  const SurfaceGenerationResult({
    required this.status,
    required this.diagnostics,
    required this.completedStages,
    this.surface,
    this.healingProposals = const [],
    this.sewingSuggestions = const [],
    this.repairSuggestions = const [],
  });
  final SurfaceGenerationStatus status;
  final GeneratedSurface? surface;
  final List<GeometryDiagnostic> diagnostics;
  final List<SurfacePipelineStage> completedStages;
  final List<HealingProposal> healingProposals;
  final List<String> sewingSuggestions, repairSuggestions;
  bool get success =>
      status == SurfaceGenerationStatus.generated && surface != null;
}

class SurfaceGenerationAdvice {
  const SurfaceGenerationAdvice({
    required this.surfaceId,
    required this.why,
    required this.evidenceIds,
    required this.predictedQuality,
    required this.limitations,
    required this.improvements,
  });
  final String surfaceId, why;
  final List<String> evidenceIds, limitations, improvements;
  final double predictedQuality;
}

class SurfaceGenerationMetric {
  const SurfaceGenerationMetric(
    this.kind,
    this.generationTime,
    this.validationTime,
    this.healingTime,
    this.success,
    this.coverage,
  );
  final SurfaceKind kind;
  final Duration generationTime, validationTime, healingTime;
  final bool success;
  final double coverage;
}
