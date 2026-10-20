import 'dart:math' as math;

import '../geometric_kernel/geometry/vectors.dart';

enum RecognitionFrameKind { global, wcs }

/// A real, immutable frame used by the recognition parameter editor.
/// Directions are always expressed in world coordinates.
class RecognitionCoordinateFrame {
  const RecognitionCoordinateFrame({
    required this.id,
    required this.label,
    required this.kind,
    required this.origin,
    required this.xAxis,
    required this.yAxis,
    required this.zAxis,
  });

  final String id, label;
  final RecognitionFrameKind kind;
  final Vector3 origin, xAxis, yAxis, zAxis;

  Vector3 direction(String axis) => switch (axis) {
    'X' => xAxis,
    'Y' => yAxis,
    'Z' => zAxis,
    _ => throw ArgumentError.value(axis, 'axis'),
  };
}

class MeasuredGeometry {
  const MeasuredGeometry({
    required this.type,
    required this.meshId,
    required this.regionId,
    required this.meshFingerprint,
    required this.selectionFingerprint,
    required this.selectionRevision,
    required this.parameters,
    required this.points,
  });

  final String type, meshId, regionId, meshFingerprint, selectionFingerprint;
  final int selectionRevision;
  final Map<String, dynamic> parameters;
  final List<Vector3> points;
}

class TargetGeometry {
  const TargetGeometry({
    required this.diameter,
    required this.origin,
    required this.axis,
    required this.axisSource,
    required this.anchor,
  });

  final double diameter;
  final Vector3 origin, axis;
  final String axisSource, anchor;

  TargetGeometry copyWith({
    double? diameter,
    Vector3? origin,
    Vector3? axis,
    String? axisSource,
    String? anchor,
  }) => TargetGeometry(
    diameter: diameter ?? this.diameter,
    origin: origin ?? this.origin,
    axis: axis ?? this.axis,
    axisSource: axisSource ?? this.axisSource,
    anchor: anchor ?? this.anchor,
  );
}

class RecognitionCorrectionMetrics {
  const RecognitionCorrectionMetrics({
    required this.rms,
    required this.maximum,
    required this.mean,
    required this.diameterDelta,
  });

  final double rms, maximum, mean, diameterDelta;
}

class RecognitionCorrectionProposal {
  const RecognitionCorrectionProposal({
    required this.measured,
    required this.target,
    required this.metrics,
    required this.valid,
    this.error,
  });

  final MeasuredGeometry measured;
  final TargetGeometry target;
  final RecognitionCorrectionMetrics metrics;
  final bool valid;
  final String? error;
}

/// Universal, runtime-only editor state.  Cylinder-specific UI is layered on
/// top of this model so other recognized primitives can reuse the same split
/// between measured and operator-selected geometry.
class RecognitionParameterEditor {
  RecognitionParameterEditor({required this.measured, required this.target})
    : metrics = _metrics(measured.points, target, _measuredDiameter(measured)),
      state = RecognitionParameterEditorState.editing;

  final MeasuredGeometry measured;
  TargetGeometry target;
  RecognitionCorrectionMetrics metrics;
  RecognitionParameterEditorState state;
  String? error;

  bool isStaleFor({
    required String meshFingerprint,
    required String selectionFingerprint,
    required int selectionRevision,
  }) =>
      measured.meshFingerprint != meshFingerprint ||
      measured.selectionFingerprint != selectionFingerprint ||
      measured.selectionRevision != selectionRevision;

  RecognitionCorrectionProposal get proposal => RecognitionCorrectionProposal(
    measured: measured,
    target: target,
    metrics: metrics,
    valid: error == null,
    error: error,
  );

  void setDiameter(double value) {
    if (!value.isFinite || value <= 0) {
      error = 'O diâmetro deve ser finito e estritamente positivo.';
      return;
    }
    target = target.copyWith(diameter: value);
    error = null;
    _refreshMetrics();
  }

  void setRadius(double value) => setDiameter(value * 2);

  void setAxis(Vector3 value, {String source = 'manual'}) {
    if (!_validVector(value) || value.length <= 1e-12) {
      error = 'A direção do eixo deve ser um vetor finito não nulo.';
      return;
    }
    target = target.copyWith(axis: value.normalized, axisSource: source);
    error = null;
    _refreshMetrics();
  }

  void setOrigin(Vector3 value) {
    if (!_validVector(value)) {
      error = 'A origem deve conter coordenadas finitas.';
      return;
    }
    target = target.copyWith(origin: value);
    error = null;
    _refreshMetrics();
  }

  void reset() {
    final measuredOrigin = _vector(measured.parameters['origin']);
    final measuredAxis = _vector(measured.parameters['axis']).normalized;
    final diameter = _number(
      measured.parameters['diameter'],
      _number(measured.parameters['radius'], 0) * 2,
    );
    target = TargetGeometry(
      diameter: diameter,
      origin: measuredOrigin,
      axis: measuredAxis,
      axisSource: 'recognized',
      anchor: 'recognized-center',
    );
    error = null;
    state = RecognitionParameterEditorState.editing;
    _refreshMetrics();
  }

  void confirm() {
    if (error != null) return;
    state = RecognitionParameterEditorState.confirmed;
  }

  void cancel() => state = RecognitionParameterEditorState.cancelled;

  void _refreshMetrics() =>
      metrics = _metrics(measured.points, target, _measuredDiameter(measured));

  static RecognitionCorrectionMetrics _metrics(
    List<Vector3> points,
    TargetGeometry target,
    double measuredDiameter,
  ) {
    if (points.isEmpty ||
        !target.diameter.isFinite ||
        target.diameter <= 0 ||
        target.axis.length <= 1e-12) {
      return const RecognitionCorrectionMetrics(
        rms: double.infinity,
        maximum: double.infinity,
        mean: double.infinity,
        diameterDelta: double.infinity,
      );
    }
    final axis = target.axis.normalized;
    final radius = target.diameter / 2;
    var sumSquares = 0.0;
    var sum = 0.0;
    var maximum = 0.0;
    for (final point in points) {
      final axial = (point - target.origin).dot(axis);
      final radial = point - (target.origin + axis * axial);
      final deviation = radial.length - radius;
      final absolute = deviation.abs();
      sum += absolute;
      sumSquares += deviation * deviation;
      if (absolute > maximum) maximum = absolute;
    }
    return RecognitionCorrectionMetrics(
      rms: math.sqrt(sumSquares / points.length),
      maximum: maximum,
      mean: sum / points.length,
      diameterDelta: target.diameter - measuredDiameter,
    );
  }

  static bool _validVector(Vector3 value) =>
      value.x.isFinite && value.y.isFinite && value.z.isFinite;

  static double _number(dynamic value, double fallback) =>
      value is num && value.isFinite ? value.toDouble() : fallback;

  static Vector3 _vector(dynamic value) =>
      value is List && value.length == 3 && value.every((x) => x is num)
      ? Vector3.fromJson(value)
      : Vector3.zero;

  static double _measuredDiameter(MeasuredGeometry measured) => _number(
    measured.parameters['diameter'],
    _number(measured.parameters['radius'], 0) * 2,
  );
}

enum RecognitionParameterEditorState {
  editing,
  previewActive,
  confirmed,
  cancelled,
  error,
}
