enum CaptureSourceKind { camera, scanner, imported }

enum CaptureRecommendation {
  goodDistance,
  moveCloser,
  moveFurther,
  increaseLight,
  decreaseLight,
  reduceReflection,
  holdSteady,
  captureMissingArea,
  improveFocus,
}

class CapturePose {
  const CapturePose({
    required this.azimuthDegrees,
    required this.elevationDegrees,
    this.distanceMeters,
    this.confidence = 0,
  });

  final double azimuthDegrees;
  final double elevationDegrees;
  final double? distanceMeters;
  final double confidence;

  Map<String, dynamic> toJson() => {
    'azimuthDegrees': azimuthDegrees,
    'elevationDegrees': elevationDegrees,
    'distanceMeters': distanceMeters,
    'confidence': confidence,
  };

  factory CapturePose.fromJson(Map<String, dynamic> json) => CapturePose(
    azimuthDegrees: (json['azimuthDegrees'] as num).toDouble(),
    elevationDegrees: (json['elevationDegrees'] as num).toDouble(),
    distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
    confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
  );
}

class UniversalCaptureContract {
  const UniversalCaptureContract({
    required this.id,
    required this.sessionId,
    required this.source,
    required this.capturedAt,
    required this.imagePath,
    this.width,
    this.height,
    this.pose,
    this.distanceMeters,
    this.focusScore,
    this.exposureValue,
    this.blurScore,
    this.reflectionScore,
    this.coverageScore,
    this.stabilityScore,
    this.metadata = const {},
  });

  final String id;
  final String sessionId;
  final CaptureSourceKind source;
  final DateTime capturedAt;
  final String imagePath;
  final int? width;
  final int? height;
  final CapturePose? pose;
  final double? distanceMeters;
  final double? focusScore;
  final double? exposureValue;
  final double? blurScore;
  final double? reflectionScore;
  final double? coverageScore;
  final double? stabilityScore;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'source': source.name,
    'capturedAt': capturedAt.toIso8601String(),
    'imagePath': imagePath,
    'width': width,
    'height': height,
    'pose': pose?.toJson(),
    'distanceMeters': distanceMeters,
    'focusScore': focusScore,
    'exposureValue': exposureValue,
    'blurScore': blurScore,
    'reflectionScore': reflectionScore,
    'coverageScore': coverageScore,
    'stabilityScore': stabilityScore,
    'metadata': metadata,
  };

  factory UniversalCaptureContract.fromJson(Map<String, dynamic> json) =>
      UniversalCaptureContract(
        id: json['id'] as String,
        sessionId: json['sessionId'] as String,
        source: CaptureSourceKind.values.byName(json['source'] as String),
        capturedAt: DateTime.parse(json['capturedAt'] as String),
        imagePath: json['imagePath'] as String,
        width: json['width'] as int?,
        height: json['height'] as int?,
        pose: (json['pose'] as Map<String, dynamic>?) == null
            ? null
            : CapturePose.fromJson(json['pose'] as Map<String, dynamic>),
        distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
        focusScore: (json['focusScore'] as num?)?.toDouble(),
        exposureValue: (json['exposureValue'] as num?)?.toDouble(),
        blurScore: (json['blurScore'] as num?)?.toDouble(),
        reflectionScore: (json['reflectionScore'] as num?)?.toDouble(),
        coverageScore: (json['coverageScore'] as num?)?.toDouble(),
        stabilityScore: (json['stabilityScore'] as num?)?.toDouble(),
        metadata: Map<String, dynamic>.from(
          (json['metadata'] as Map<String, dynamic>?) ?? const {},
        ),
      );
}

class CaptureEvidence {
  const CaptureEvidence({
    required this.captureId,
    required this.quality,
    required this.positionConfidence,
    required this.exposure,
    required this.focus,
    required this.coverage,
    required this.reflection,
    required this.recommendations,
    required this.confidence,
  });

  final double quality;
  final double positionConfidence;
  final double exposure;
  final double focus;
  final double coverage;
  final double reflection;
  final String captureId;
  final List<CaptureRecommendation> recommendations;
  final double confidence;

  Map<String, dynamic> toJson() => {
    'captureId': captureId,
    'quality': quality,
    'positionConfidence': positionConfidence,
    'exposure': exposure,
    'focus': focus,
    'coverage': coverage,
    'reflection': reflection,
    'recommendations': recommendations.map((e) => e.name).toList(),
    'confidence': confidence,
  };

  factory CaptureEvidence.fromJson(Map<String, dynamic> json) =>
      CaptureEvidence(
        captureId: json['captureId'] as String,
        quality: (json['quality'] as num).toDouble(),
        positionConfidence: (json['positionConfidence'] as num).toDouble(),
        exposure: (json['exposure'] as num).toDouble(),
        focus: (json['focus'] as num).toDouble(),
        coverage: (json['coverage'] as num).toDouble(),
        reflection: (json['reflection'] as num).toDouble(),
        recommendations: (json['recommendations'] as List<dynamic>? ?? const [])
            .map(
              (value) => CaptureRecommendation.values.byName(value as String),
            )
            .toList(),
        confidence: (json['confidence'] as num).toDouble(),
      );
}
