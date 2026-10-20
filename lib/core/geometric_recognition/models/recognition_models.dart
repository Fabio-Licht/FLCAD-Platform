import '../../geometric_kernel/geometry/vectors.dart';

enum PrimitiveType {
  plane,
  cylinder,
  cone,
  sphere,
  torus,
  revolution,
  extrusion,
  sweep,
  loft,
  freeform,
  unknown,
}

enum RecognitionStatus {
  candidate,
  refined,
  validated,
  rejected,
  indeterminate,
}

class RecognitionObservation {
  const RecognitionObservation({
    required this.projectId,
    required this.meshId,
    required this.regionId,
    required this.points,
    this.normals = const [],
    this.curvatures = const [],
    this.adjacency = const {},
    required this.meshFingerprint,
    required this.regionFingerprint,
  });
  final String projectId, meshId, regionId, meshFingerprint, regionFingerprint;
  final List<Vector3> points, normals;
  final List<double> curvatures;
  final Map<int, Set<int>> adjacency;
}

class RecognitionContext {
  const RecognitionContext({
    required this.observation,
    this.areiConfidence = 0,
    this.knowledgeConfidence = 0,
    this.cognitionConfidence = 0,
    this.decisionConfidence = 0,
    this.historicalSuccess = 0,
    this.parameters = const {},
  });
  final RecognitionObservation observation;
  final double areiConfidence,
      knowledgeConfidence,
      cognitionConfidence,
      decisionConfidence,
      historicalSuccess;
  final Map<String, double> parameters;
}

class RecognitionEvidence {
  const RecognitionEvidence(this.id, this.description, this.source, this.value);
  final String id, description, source;
  final double value;
}

class FitStatistics {
  const FitStatistics({
    required this.rms,
    required this.maximum,
    required this.mean,
    required this.coverage,
    required this.stability,
    required this.score,
    this.confidenceInterval,
    this.angularCoverageDegrees = 0,
    this.axialLength = 0,
    this.pointCount = 0,
    this.inlierCount = 0,
    this.conditioning = 0,
    this.axisStability = 0,
    this.converged = false,
    this.qualityStatus = 'unknown',
  });
  final double rms, maximum, mean, coverage, stability, score;
  final (double, double)? confidenceInterval;

  /// Additional dimensional diagnostics. They are optional so existing
  /// primitive recognizers keep the original contract.
  final double angularCoverageDegrees, axialLength, conditioning, axisStability;
  final int pointCount, inlierCount;
  final bool converged;
  final String qualityStatus;

  FitStatistics copyWith({double? score}) => FitStatistics(
    rms: rms,
    maximum: maximum,
    mean: mean,
    coverage: coverage,
    stability: stability,
    score: score ?? this.score,
    confidenceInterval: confidenceInterval,
    angularCoverageDegrees: angularCoverageDegrees,
    axialLength: axialLength,
    pointCount: pointCount,
    inlierCount: inlierCount,
    conditioning: conditioning,
    axisStability: axisStability,
    converged: converged,
    qualityStatus: qualityStatus,
  );
}

class RecognitionCandidate {
  const RecognitionCandidate({
    required this.id,
    required this.type,
    required this.regionId,
    required this.parameters,
    required this.statistics,
    required this.evidence,
    required this.origin,
    this.status = RecognitionStatus.candidate,
  });
  final String id, regionId, origin;
  final PrimitiveType type;
  final Map<String, dynamic> parameters;
  final FitStatistics statistics;
  final List<RecognitionEvidence> evidence;
  final RecognitionStatus status;
  RecognitionCandidate copyWith({
    FitStatistics? statistics,
    RecognitionStatus? status,
    Map<String, dynamic>? parameters,
  }) => RecognitionCandidate(
    id: id,
    type: type,
    regionId: regionId,
    parameters: parameters ?? this.parameters,
    statistics: statistics ?? this.statistics,
    evidence: evidence,
    origin: origin,
    status: status ?? this.status,
  );
}

class RecognitionDNA {
  const RecognitionDNA({
    required this.type,
    required this.parameters,
    required this.regionId,
    required this.geometricSignature,
    required this.quality,
    required this.confidence,
    required this.evidence,
    required this.origin,
    required this.version,
  });
  final PrimitiveType type;
  final Map<String, dynamic> parameters;
  final String regionId, geometricSignature, origin, version;
  final double quality, confidence;
  final List<RecognitionEvidence> evidence;
}

class RecognitionExplanation {
  const RecognitionExplanation({
    required this.why,
    required this.evidence,
    required this.regions,
    required this.parameters,
    required this.losingCandidates,
    required this.score,
    required this.confidence,
  });
  final String why;
  final List<RecognitionEvidence> evidence;
  final List<String> regions, losingCandidates;
  final Map<String, dynamic> parameters;
  final double score, confidence;
}

class PrimitiveRecognitionResult {
  const PrimitiveRecognitionResult({
    required this.id,
    required this.projectId,
    required this.meshId,
    required this.winner,
    required this.alternatives,
    required this.dna,
    required this.explanation,
    required this.createdAt,
  });
  final String id, projectId, meshId;
  final RecognitionCandidate winner;
  final List<RecognitionCandidate> alternatives;
  final RecognitionDNA dna;
  final RecognitionExplanation explanation;
  final DateTime createdAt;
}
