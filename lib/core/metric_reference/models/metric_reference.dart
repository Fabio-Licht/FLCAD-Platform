import '../../geometric_kernel/geometry/vectors.dart';
import '../../geometric_kernel/precision/precision.dart';

enum MetricReferenceType { distance, length, width, diameter }

enum MetricReferenceOrigin {
  knownDistance,
  fiducialMarker,
  scaleBar,
  referenceObject,
}

class MetricReference {
  const MetricReference({
    required this.id,
    required this.type,
    required this.pointA,
    required this.pointB,
    required this.knownValue,
    required this.unit,
    required this.createdAt,
    this.origin = MetricReferenceOrigin.knownDistance,
    this.uncertainty = 0,
    this.metadata = const {},
  });

  final String id;
  final MetricReferenceType type;
  final Vector3 pointA;
  final Vector3 pointB;
  final double knownValue;
  final LengthUnit unit;
  final DateTime createdAt;
  final MetricReferenceOrigin origin;
  final double uncertainty;
  final Map<String, dynamic> metadata;

  double get observedDistance => pointA.distanceTo(pointB);
  double get knownMillimeters =>
      const UnitConverter().length(knownValue, unit, LengthUnit.millimeter);

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'pointA': pointA.toJson(),
    'pointB': pointB.toJson(),
    'knownValue': knownValue,
    'unit': unit.name,
    'createdAt': createdAt.toIso8601String(),
    'origin': origin.name,
    'uncertainty': uncertainty,
    'metadata': metadata,
  };

  factory MetricReference.fromJson(Map<String, dynamic> json) =>
      MetricReference(
        id: json['id'] as String,
        type: MetricReferenceType.values.byName(json['type'] as String),
        pointA: Vector3.fromJson(json['pointA'] as List<dynamic>),
        pointB: Vector3.fromJson(json['pointB'] as List<dynamic>),
        knownValue: (json['knownValue'] as num).toDouble(),
        unit: LengthUnit.values.byName(json['unit'] as String),
        createdAt: DateTime.parse(json['createdAt'] as String),
        origin: MetricReferenceOrigin.values.byName(
          json['origin'] as String? ?? MetricReferenceOrigin.knownDistance.name,
        ),
        uncertainty: (json['uncertainty'] as num?)?.toDouble() ?? 0,
        metadata: Map<String, dynamic>.from(
          (json['metadata'] as Map<String, dynamic>?) ?? const {},
        ),
      );
}

class MetricReferenceEvidence {
  const MetricReferenceEvidence({
    required this.referenceId,
    required this.type,
    required this.origin,
    required this.nominalDimension,
    required this.observedDistance,
    required this.expectedMillimeters,
    required this.residualMillimeters,
    required this.confidence,
    required this.conflict,
  });

  final String referenceId;
  final MetricReferenceType type;
  final MetricReferenceOrigin origin;
  final double nominalDimension;
  final double observedDistance;
  final double expectedMillimeters;
  final double residualMillimeters;
  final double confidence;
  final bool conflict;

  Map<String, dynamic> toJson() => {
    'referenceId': referenceId,
    'type': type.name,
    'origin': origin.name,
    'nominalDimension': nominalDimension,
    'observedDistance': observedDistance,
    'expectedMillimeters': expectedMillimeters,
    'residualMillimeters': residualMillimeters,
    'confidence': confidence,
    'conflict': conflict,
  };

  factory MetricReferenceEvidence.fromJson(Map<String, dynamic> json) =>
      MetricReferenceEvidence(
        referenceId: json['referenceId'] as String,
        type: MetricReferenceType.values.byName(
          json['type'] as String? ?? MetricReferenceType.distance.name,
        ),
        origin: MetricReferenceOrigin.values.byName(
          json['origin'] as String? ?? MetricReferenceOrigin.knownDistance.name,
        ),
        nominalDimension:
            (json['nominalDimension'] as num?)?.toDouble() ??
            (json['expectedMillimeters'] as num).toDouble(),
        observedDistance: (json['observedDistance'] as num).toDouble(),
        expectedMillimeters: (json['expectedMillimeters'] as num).toDouble(),
        residualMillimeters: (json['residualMillimeters'] as num).toDouble(),
        confidence: (json['confidence'] as num).toDouble(),
        conflict: json['conflict'] as bool,
      );
}
