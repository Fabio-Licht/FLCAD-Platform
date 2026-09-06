import '../../geometric_kernel/geometry/vectors.dart';
import '../../geometric_kernel/precision/precision.dart';
import 'metric_reference.dart';

enum FiducialMaterial { paper, pvc, aluminum }

class FiducialMarker {
  const FiducialMarker({
    required this.id,
    required this.nominalSize,
    required this.version,
    required this.checksum,
    this.material = FiducialMaterial.paper,
  });

  final String id;
  final double nominalSize;
  final String version;
  final String checksum;
  final FiducialMaterial material;

  static FiducialMarker create({
    required String id,
    required double nominalSize,
    String version = '1',
    FiducialMaterial material = FiducialMaterial.paper,
  }) {
    final payload = '$id|$nominalSize|$version';
    var checksum = 17;
    for (final codeUnit in payload.codeUnits) {
      checksum = (checksum * 31 + codeUnit) & 0x7fffffff;
    }
    return FiducialMarker(
      id: id,
      nominalSize: nominalSize,
      version: version,
      checksum: checksum.toRadixString(16).padLeft(8, '0'),
      material: material,
    );
  }

  bool get hasValidChecksum =>
      checksum ==
      FiducialMarker.create(
        id: id,
        nominalSize: nominalSize,
        version: version,
        material: material,
      ).checksum;

  MetricReference toReference({
    required Vector3 pointA,
    required Vector3 pointB,
    required double measuredSize,
    required DateTime capturedAt,
    double uncertainty = 0,
  }) => MetricReference(
    id: id,
    type: MetricReferenceType.length,
    origin: MetricReferenceOrigin.fiducialMarker,
    pointA: pointA,
    pointB: pointB,
    knownValue: nominalSize,
    unit: LengthUnit.millimeter,
    createdAt: capturedAt,
    uncertainty: uncertainty,
    metadata: {
      'version': version,
      'checksum': checksum,
      'material': material.name,
      'measuredSize': measuredSize,
    },
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nominalSize': nominalSize,
    'version': version,
    'checksum': checksum,
    'material': material.name,
  };
}

enum ScaleBarSize { mm50, mm100, mm200, mm500, custom }

class ScaleBar {
  const ScaleBar({
    required this.id,
    required this.nominalLength,
    required this.version,
    this.size = ScaleBarSize.custom,
  });

  final String id;
  final double nominalLength;
  final String version;
  final ScaleBarSize size;

  factory ScaleBar.calibrated({
    required String id,
    required double millimeters,
    String version = '1',
  }) {
    final size = switch (millimeters) {
      50 => ScaleBarSize.mm50,
      100 => ScaleBarSize.mm100,
      200 => ScaleBarSize.mm200,
      500 => ScaleBarSize.mm500,
      _ => ScaleBarSize.custom,
    };
    if (millimeters <= 0) {
      throw ArgumentError.value(millimeters, 'millimeters');
    }
    return ScaleBar(
      id: id,
      nominalLength: millimeters,
      version: version,
      size: size,
    );
  }

  MetricReference toReference({
    required Vector3 pointA,
    required Vector3 pointB,
    required DateTime capturedAt,
    double uncertainty = 0,
  }) => MetricReference(
    id: id,
    type: MetricReferenceType.length,
    origin: MetricReferenceOrigin.scaleBar,
    pointA: pointA,
    pointB: pointB,
    knownValue: nominalLength,
    unit: LengthUnit.millimeter,
    createdAt: capturedAt,
    uncertainty: uncertainty,
    metadata: {'version': version, 'size': size.name},
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nominalLength': nominalLength,
    'version': version,
    'size': size.name,
  };
}

enum CalibratedObjectShape { sphere, cube, block, cylinder }

class CalibratedReferenceObject {
  const CalibratedReferenceObject({
    required this.id,
    required this.shape,
    required this.nominalDimension,
    required this.unit,
    this.version = '1',
  });

  final String id;
  final CalibratedObjectShape shape;
  final double nominalDimension;
  final LengthUnit unit;
  final String version;

  MetricReference toReference({
    required Vector3 pointA,
    required Vector3 pointB,
    required MetricReferenceType measuredType,
    required DateTime capturedAt,
    double uncertainty = 0,
  }) => MetricReference(
    id: id,
    type: measuredType,
    origin: MetricReferenceOrigin.referenceObject,
    pointA: pointA,
    pointB: pointB,
    knownValue: nominalDimension,
    unit: unit,
    createdAt: capturedAt,
    uncertainty: uncertainty,
    metadata: {'shape': shape.name, 'version': version},
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'shape': shape.name,
    'nominalDimension': nominalDimension,
    'unit': unit.name,
    'version': version,
  };
}
