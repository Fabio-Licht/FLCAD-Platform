import '../geometric_kernel/geometry/vectors.dart';
import '../geometric_recognition/models/recognition_models.dart';
import '../professional_recognition/models/professional_recognition_models.dart';

enum RecognitionResultType { plane, cylinder, cone, sphere, fillet, freeform }

class RecognitionResult {
  const RecognitionResult({
    required this.id,
    required this.type,
    required this.meshId,
    required this.regionId,
    required this.confidence,
    required this.parameters,
    required this.quality,
    required this.suggestion,
    required this.createdAt,
    this.history = const [],
  });

  final String id, meshId, regionId, quality, suggestion;
  final RecognitionResultType type;
  final double confidence;
  final Map<String, dynamic> parameters;
  final DateTime createdAt;
  final List<String> history;

  Map<String, dynamic> toJson() => {
    'schema': 'flcad.recognition-result',
    'version': 1,
    'id': id,
    'type': type.name,
    'meshId': meshId,
    'regionId': regionId,
    'confidence': confidence,
    'parameters': parameters,
    'quality': quality,
    'suggestion': suggestion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'history': history,
  };

  factory RecognitionResult.fromJson(Map<String, dynamic> json) =>
      RecognitionResult(
        id: json['id'] as String,
        type: RecognitionResultType.values.byName(json['type'] as String),
        meshId: json['meshId'] as String,
        regionId: json['regionId'] as String,
        confidence: (json['confidence'] as num).toDouble(),
        parameters: Map<String, dynamic>.from(json['parameters'] as Map),
        quality: json['quality'] as String,
        suggestion: json['suggestion'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        history: (json['history'] as List? ?? const []).cast<String>(),
      );
}

/// Converts statistical recognition into a consumer-neutral knowledge object.
/// This adapter has no CAD, Sketch, Surface or Solver dependency.
class RecognitionResultAdapter {
  const RecognitionResultAdapter({this.minimumPrimitiveConfidence = .65});
  final double minimumPrimitiveConfidence;

  RecognitionResult build({
    required String id,
    required String meshId,
    required String regionId,
    required List<Vector3> points,
    required double area,
    ProfessionalPrimitive? primitive,
    List<String> history = const [],
    Map<String, dynamic> extraParameters = const {},
    double? minimumPrimitiveConfidence,
  }) {
    final threshold =
        minimumPrimitiveConfidence ?? this.minimumPrimitiveConfidence;
    if (primitive == null || primitive.recognition.dna.confidence < threshold) {
      return RecognitionResult(
        id: id,
        type: RecognitionResultType.freeform,
        meshId: meshId,
        regionId: regionId,
        confidence: primitive?.recognition.dna.confidence ?? .5,
        parameters: {
          'area': area,
          'pointCount': points.length,
          ...extraParameters,
        },
        quality: 'No validated analytic primitive',
        suggestion: 'Reconstruction by Surface',
        createdAt: DateTime.now(),
        history: history,
      );
    }
    final recognition = primitive.recognition;
    final candidate = recognition.winner;
    final type = switch (candidate.type) {
      PrimitiveType.plane => RecognitionResultType.plane,
      PrimitiveType.cylinder => RecognitionResultType.cylinder,
      PrimitiveType.cone => RecognitionResultType.cone,
      PrimitiveType.sphere => RecognitionResultType.sphere,
      PrimitiveType.torus => RecognitionResultType.fillet,
      _ => RecognitionResultType.freeform,
    };
    final parameters = Map<String, dynamic>.from(candidate.parameters)
      ..['area'] = area
      ..['rmsDeviation'] = candidate.statistics.rms
      ..['maximumDeviation'] = candidate.statistics.maximum
      ..addAll(extraParameters);
    if (type == RecognitionResultType.cylinder) {
      final radius = (parameters['radius'] as num).toDouble();
      parameters['diameter'] = radius * 2;
      parameters['length'] = _axialLength(points, parameters['axis']);
    } else if (type == RecognitionResultType.cone) {
      parameters['angleDegrees'] =
          (parameters['halfAngle'] as num).toDouble() * 180 / 3.141592653589793;
      parameters['radius'] = parameters['referenceRadius'];
      parameters['length'] = _axialLength(points, parameters['axis']);
    } else if (type == RecognitionResultType.fillet) {
      final radius = (parameters['minorRadius'] as num).toDouble();
      parameters.addAll({
        'meanRadius': radius,
        'minimumRadius': radius - candidate.statistics.maximum,
        'maximumRadius': radius + candidate.statistics.maximum,
        'length': _polylineExtent(points),
      });
    }
    return RecognitionResult(
      id: id,
      type: type,
      meshId: meshId,
      regionId: regionId,
      confidence: recognition.dna.confidence.clamp(0.0, 1.0),
      parameters: parameters,
      quality:
          'RMS ${candidate.statistics.rms.toStringAsPrecision(4)} · '
          'coverage ${(candidate.statistics.coverage * 100).toStringAsFixed(1)}%',
      suggestion: type == RecognitionResultType.freeform
          ? 'Reconstruction by Surface'
          : 'Review and confirm before reconstruction',
      createdAt: recognition.createdAt,
      history: history,
    );
  }

  double _axialLength(List<Vector3> points, dynamic rawAxis) {
    if (points.isEmpty || rawAxis is! List) return 0;
    final axis = Vector3.fromJson(rawAxis).normalized;
    final values = points.map((point) => point.dot(axis)).toList();
    return values.reduce((a, b) => a < b ? a : b) * -1 +
        values.reduce((a, b) => a > b ? a : b);
  }

  double _polylineExtent(List<Vector3> points) {
    if (points.length < 2) return 0;
    var maximum = 0.0;
    for (var i = 0; i < points.length; i++) {
      for (var j = i + 1; j < points.length; j++) {
        final distance = points[i].distanceTo(points[j]);
        if (distance > maximum) maximum = distance;
      }
    }
    return maximum;
  }
}
