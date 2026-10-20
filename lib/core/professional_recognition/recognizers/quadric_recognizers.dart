import 'dart:math' as math;

import '../../geometric_kernel/geometry/vectors.dart';
import '../../geometric_kernel/linear_algebra/linear_algebra.dart';
import '../../geometric_recognition/models/recognition_models.dart';
import '../../geometric_recognition/recognizers/supported_recognizers.dart';
import '../../geometric_recognition/statistics/statistical_engine.dart';

class CylinderProfessionalRecognizer extends FittedRecognizer {
  const CylinderProfessionalRecognizer();
  @override
  String get id => 'uers.cylinder.v2';
  @override
  PrimitiveType get type => PrimitiveType.cylinder;
  @override
  bool detect(RecognitionContext context) =>
      context.observation.points.length >= 6;

  @override
  RecognitionCandidate evaluate(RecognitionContext context) {
    final fit = _fitCylinder(context.observation);
    if (!fit.valid) throw StateError('Degenerate cylindrical evidence');
    final base = fitStatistics(context, fit.residuals),
        scaleValue = math.max(scale(context), 1e-9);
    final effectiveCoverage = math.max(
      base.coverage,
      fit.inlierCount / fit.sampleCount,
    );
    final radialQuality = (1 - base.rms / scaleValue).clamp(0.0, 1.0);
    final angularQuality = (fit.angularCoverageDegrees / 180).clamp(0.0, 1.0);
    final conditioningQuality = (fit.conditioning / .2).clamp(0.0, 1.0);
    final stability = (fit.axisStability * conditioningQuality).clamp(0.0, 1.0);
    final score =
        (radialQuality *
                effectiveCoverage *
                (0.55 + .45 * angularQuality) *
                (0.55 + .45 * stability))
            .clamp(0.0, 1.0);
    final status = _qualityStatus(fit, effectiveCoverage, radialQuality);
    final stats = FitStatistics(
      rms: base.rms,
      maximum: base.maximum,
      mean: base.mean,
      coverage: effectiveCoverage,
      stability: stability,
      score: score,
      confidenceInterval: base.confidenceInterval,
      angularCoverageDegrees: fit.angularCoverageDegrees,
      axialLength: fit.axialLength,
      pointCount: context.observation.points.length,
      inlierCount: fit.inlierCount,
      conditioning: fit.conditioning,
      axisStability: fit.axisStability,
      converged: fit.converged,
      qualityStatus: status,
    );
    return RecognitionCandidate(
      id: '$id:${context.observation.regionFingerprint}',
      type: type,
      regionId: context.observation.regionId,
      parameters: {
        'origin': fit.origin.toJson(),
        'axis': fit.axis.toJson(),
        'radius': fit.radius,
        'diameter': fit.radius * 2,
        'axialLength': fit.axialLength,
        'angularCoverageDegrees': fit.angularCoverageDegrees,
        'inlierCoverage': effectiveCoverage,
        'pointCount': context.observation.points.length,
        'fitPointCount': fit.sampleCount,
        'inlierCount': fit.inlierCount,
        'conditioning': fit.conditioning,
        'axisStability': fit.axisStability,
        'converged': fit.converged,
        'qualityStatus': status,
      },
      statistics: stats,
      evidence: [
        RecognitionEvidence(
          'cylinder-radial-residual',
          'Ajuste conjunto de eixo, centro e raio com M-estimador robusto',
          id,
          score,
        ),
        RecognitionEvidence(
          'cylinder-angular-coverage',
          'Cobertura angular observada nos pontos selecionados',
          id,
          angularQuality,
        ),
      ],
      origin: id,
    );
  }
}

final class _CylinderFit {
  const _CylinderFit({
    required this.origin,
    required this.axis,
    required this.radius,
    required this.residuals,
    required this.axialLength,
    required this.angularCoverageDegrees,
    required this.conditioning,
    required this.axisStability,
    required this.inlierCount,
    required this.sampleCount,
    required this.converged,
    required this.valid,
  });
  final Vector3 origin, axis;
  final double radius,
      axialLength,
      angularCoverageDegrees,
      conditioning,
      axisStability;
  final List<double> residuals;
  final int inlierCount;
  final int sampleCount;
  final bool converged, valid;
}

final _invalidCylinderFit = _CylinderFit(
  origin: Vector3.zero,
  axis: Vector3.zero,
  radius: 0,
  residuals: const [],
  axialLength: 0,
  angularCoverageDegrees: 0,
  conditioning: double.infinity,
  axisStability: 0,
  inlierCount: 0,
  sampleCount: 0,
  converged: false,
  valid: false,
);

_CylinderFit _fitCylinder(RecognitionObservation observation) {
  final points = _boundedCylinderSample(observation.points);
  if (points.length < 6) return _invalidCylinderFit;
  final sampledObservation = RecognitionObservation(
    projectId: observation.projectId,
    meshId: observation.meshId,
    regionId: observation.regionId,
    points: points,
    normals: _boundedNormals(observation.normals, observation.points.length),
    meshFingerprint: observation.meshFingerprint,
    regionFingerprint: observation.regionFingerprint,
  );
  final pca = const RecognitionStatisticalEngine().pca(sampledObservation),
      seeds = <Vector3>[];
  for (final index in [0, 1, 2]) {
    final axis = Vector3(
      pca.axes[index][0],
      pca.axes[index][1],
      pca.axes[index][2],
    ).normalized;
    if (axis.length > 1e-10) seeds.add(axis);
  }
  final normalAxis = _normalEvidenceAxis(sampledObservation.normals);
  if (normalAxis.length > 1e-10) seeds.add(normalAxis);
  _CylinderFit? best;
  for (final seed in seeds) {
    final fit = _refineCylinder(points, seed, sampledObservation.normals);
    if (fit.valid &&
        (best == null || _fitObjective(fit) < _fitObjective(best))) {
      best = fit;
    }
  }
  return best ?? _invalidCylinderFit;
}

const _maxCylinderFitPoints = 4096;

List<Vector3> _boundedCylinderSample(List<Vector3> points) {
  if (points.length <= _maxCylinderFitPoints) return points;
  final stride = points.length / _maxCylinderFitPoints;
  return [
    for (var i = 0; i < _maxCylinderFitPoints; i++)
      points[(i * stride).floor()],
  ];
}

List<Vector3> _boundedNormals(List<Vector3> normals, int pointCount) {
  if (normals.length != pointCount || pointCount <= _maxCylinderFitPoints) {
    return normals;
  }
  final stride = pointCount / _maxCylinderFitPoints;
  return [
    for (var i = 0; i < _maxCylinderFitPoints; i++)
      normals[(i * stride).floor()],
  ];
}

_CylinderFit _refineCylinder(
  List<Vector3> points,
  Vector3 seed,
  List<Vector3> normals,
) {
  var axis = seed.normalized, step = .08;
  _CylinderFit? current;
  var converged = false;
  for (var iteration = 0; iteration < 12; iteration++) {
    final evaluated = _circleFit(points, axis, normals, converged: false);
    if (!evaluated.valid) return _invalidCylinderFit;
    current = evaluated;
    final basis = _basis(axis);
    var improved = false,
        bestAxis = axis,
        bestObjective = _fitObjective(evaluated);
    for (final delta in [
      Vector2(step, 0),
      Vector2(-step, 0),
      Vector2(0, step),
      Vector2(0, -step),
    ]) {
      final candidateAxis =
          (axis + basis.$1 * delta.x + basis.$2 * delta.y).normalized;
      final candidate = _circleFit(points, candidateAxis, normals);
      if (candidate.valid && _fitObjective(candidate) < bestObjective) {
        bestObjective = _fitObjective(candidate);
        bestAxis = candidateAxis;
        improved = true;
      }
    }
    axis = bestAxis;
    if (!improved) {
      step *= .45;
      if (step < 1e-4) {
        converged = true;
        break;
      }
    }
  }
  final result = _circleFit(points, axis, normals, converged: converged);
  return result.valid ? result : (current ?? _invalidCylinderFit);
}

_CylinderFit _circleFit(
  List<Vector3> points,
  Vector3 axis,
  List<Vector3> normals, {
  bool converged = true,
}) {
  final basis = _basis(axis), u = basis.$1, v = basis.$2;
  var weights = List<double>.filled(points.length, 1),
      origin = Vector3.zero,
      radius = 0.0;
  List<double> residuals = const [];
  for (var iteration = 0; iteration < 6; iteration++) {
    final rows = <List<double>>[], rhs = <double>[];
    for (var i = 0; i < points.length; i++) {
      final p = points[i], x = p.dot(u), y = p.dot(v), w = weights[i];
      rows.add([x * w, y * w, w]);
      rhs.add(-(x * x + y * y) * w);
    }
    late final List<double> solution;
    try {
      solution = const LinearAlgebra().leastSquares(DenseMatrix(rows), rhs);
    } catch (_) {
      return _invalidCylinderFit;
    }
    final center = u * (-solution[0] / 2) + v * (-solution[1] / 2),
        axial = points.map((p) => p.dot(axis)).toList(),
        meanAxial = axial.reduce((a, b) => a + b) / axial.length;
    origin = center + axis * meanAxial;
    final radicand =
        (solution[0] * solution[0] + solution[1] * solution[1]) / 4 -
        solution[2];
    if (!radicand.isFinite || radicand <= 1e-12) return _invalidCylinderFit;
    radius = math.sqrt(radicand);
    residuals = points
        .map((p) => ((p - origin).cross(axis).length - radius).abs())
        .toList();
    final sorted = [...residuals]..sort(),
        median = sorted[sorted.length ~/ 2],
        deviations = residuals.map((r) => (r - median).abs()).toList()..sort(),
        robustScale = math.max(
          1e-7,
          1.4826 * deviations[deviations.length ~/ 2],
        );
    weights = residuals.map((r) {
      final normalized = r / (4.685 * robustScale);
      if (normalized.abs() >= 1) return .001;
      final value = 1 - normalized * normalized;
      return value * value;
    }).toList();
  }
  final axial = points.map((p) => p.dot(axis)).toList()..sort(),
      angles = points.map((p) {
        final d = p - origin;
        return math.atan2(d.dot(v), d.dot(u));
      }).toList()..sort(),
      gaps = <double>[];
  for (var i = 1; i < angles.length; i++) {
    gaps.add(angles[i] - angles[i - 1]);
  }
  if (angles.length > 1) gaps.add(2 * math.pi - angles.last + angles.first);
  final coverage =
          (2 * math.pi - (gaps.isEmpty ? 2 * math.pi : gaps.reduce(math.max)))
              .clamp(0.0, 2 * math.pi),
      sortedResiduals = [...residuals]..sort(),
      threshold = math.max(
        .05 * radius,
        2.5 * sortedResiduals[sortedResiduals.length ~/ 2],
      ),
      inliers = residuals.where((r) => r <= threshold).length;
  final normalAgreement = normals.isEmpty
          ? 1.0
          : normals
                    .map((n) => n.normalized.dot(axis).abs())
                    .fold<double>(0, (a, b) => a + b) /
                math.max(1, normals.length),
      conditioning =
          _angularConditioning(angles, coverage) * (.5 + .5 * normalAgreement),
      // Axial extent is not an instability signal: a long, healthy cylinder
      // naturally has a large spread along its axis.
      axisStability = conditioning
          .clamp(0.0, 1.0)
          .toDouble();
  return _CylinderFit(
    origin: origin,
    axis: axis,
    radius: radius,
    residuals: residuals,
    axialLength: axial.last - axial.first,
    angularCoverageDegrees: coverage * 180 / math.pi,
    conditioning: conditioning,
    axisStability: axisStability,
    inlierCount: inliers,
    sampleCount: points.length,
    converged: converged,
    valid: radius.isFinite && radius > 1e-8 && coverage > math.pi / 18,
  );
}

double _fitObjective(_CylinderFit fit) {
  if (!fit.valid || fit.residuals.isEmpty) return double.infinity;
  final sorted = [...fit.residuals]..sort(),
      cutoff =
          sorted[(sorted.length * .85).floor().clamp(0, sorted.length - 1)],
      values = fit.residuals.where((r) => r <= cutoff).toList();
  return math.sqrt(
    values.map((r) => r * r).fold<double>(0, (a, b) => a + b) /
        math.max(1, values.length),
  );
}

Vector3 _normalEvidenceAxis(List<Vector3> normals) {
  if (normals.length < 3) return Vector3.zero;
  final covariance = List.generate(3, (_) => List<double>.filled(3, 0));
  for (final raw in normals) {
    final n = raw.normalized;
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        covariance[i][j] += _component(n, i) * _component(n, j);
      }
    }
  }
  final eigen = const LinearAlgebra().symmetricEigen(DenseMatrix(covariance)),
      value = eigen.vectors[2];
  return Vector3(value[0], value[1], value[2]).normalized;
}

(Vector3, Vector3) _basis(Vector3 axis) {
  final reference = axis.z.abs() < .9
      ? const Vector3(0, 0, 1)
      : const Vector3(1, 0, 0);
  final u = axis.cross(reference).normalized;
  return (u, axis.cross(u).normalized);
}

double _angularConditioning(List<double> angles, double coverage) {
  if (angles.length < 3 || coverage <= 1e-9) return 0;
  final c = angles.map(math.cos).reduce((a, b) => a + b) / angles.length,
      s = angles.map(math.sin).reduce((a, b) => a + b) / angles.length;
  return (1 - math.sqrt(c * c + s * s)).clamp(0.0, 1.0);
}

String _qualityStatus(_CylinderFit fit, double coverage, double radialQuality) {
  if (!fit.converged) return 'convergence-failed';
  if (fit.angularCoverageDegrees < 45) return 'insufficient-angular-coverage';
  if (fit.conditioning < .08) return 'ill-conditioned';
  if (coverage < .65 || radialQuality < .5) return 'high-residuals';
  if (fit.angularCoverageDegrees < 120 || fit.conditioning < .2) {
    return 'conditioned';
  }
  return 'reliable';
}

double _component(Vector3 value, int index) => index == 0
    ? value.x
    : index == 1
    ? value.y
    : value.z;

class ConeProfessionalRecognizer extends FittedRecognizer {
  const ConeProfessionalRecognizer();
  @override
  String get id => 'uers.cone.v1';
  @override
  PrimitiveType get type => PrimitiveType.cone;
  @override
  bool detect(RecognitionContext context) =>
      context.observation.points.length >= 7;
  @override
  RecognitionCandidate evaluate(RecognitionContext context) {
    final pca = statistics.pca(context.observation),
        center = Vector3(pca.mean[0], pca.mean[1], pca.mean[2]),
        axis = Vector3(
          pca.axes[0][0],
          pca.axes[0][1],
          pca.axes[0][2],
        ).normalized,
        samples = context.observation.points.map((p) {
          final d = p - center;
          return (d.dot(axis), d.cross(axis).length);
        }).toList(),
        meanH =
            samples.map((e) => e.$1).reduce((a, b) => a + b) / samples.length,
        meanR =
            samples.map((e) => e.$2).reduce((a, b) => a + b) / samples.length,
        denominator = samples
            .map((e) => math.pow(e.$1 - meanH, 2))
            .reduce((a, b) => a + b),
        slope = denominator < 1e-14
            ? 0.0
            : samples
                      .map((e) => (e.$1 - meanH) * (e.$2 - meanR))
                      .reduce((a, b) => a + b) /
                  denominator;
    final intercept = meanR - slope * meanH,
        residuals = samples
            .map((e) => (e.$2 - (intercept + slope * e.$1)).abs())
            .toList(),
        stats = fitStatistics(context, residuals);
    final coneDegeneracyPenalty = math.min(1.0, slope.abs() / 1e-5),
        coneStats = stats.copyWith(score: stats.score * coneDegeneracyPenalty);
    return RecognitionCandidate(
      id: '$id:${context.observation.regionFingerprint}',
      type: type,
      regionId: context.observation.regionId,
      parameters: {
        'origin': center.toJson(),
        'axis': axis.toJson(),
        'referenceRadius': intercept,
        'halfAngle': math.atan(slope.abs()),
      },
      statistics: coneStats,
      evidence: [
        RecognitionEvidence(
          'cone-linear-radius',
          'Raio varia linearmente ao longo do eixo PCA',
          id,
          coneStats.score,
        ),
      ],
      origin: id,
    );
  }
}

class TorusProfessionalRecognizer extends FittedRecognizer {
  const TorusProfessionalRecognizer();
  @override
  String get id => 'uers.torus.v1';
  @override
  PrimitiveType get type => PrimitiveType.torus;
  @override
  bool detect(RecognitionContext context) =>
      context.observation.points.length >= 10;
  @override
  RecognitionCandidate evaluate(RecognitionContext context) {
    final pca = statistics.pca(context.observation),
        center = Vector3(pca.mean[0], pca.mean[1], pca.mean[2]),
        axis = Vector3(
          pca.axes[2][0],
          pca.axes[2][1],
          pca.axes[2][2],
        ).normalized,
        samples = context.observation.points.map((p) {
          final d = p - center;
          return (d.cross(axis).length, d.dot(axis));
        }).toList(),
        major = _robustMean(samples.map((e) => e.$1).toList()),
        tubes = samples
            .map((e) => math.sqrt(math.pow(e.$1 - major, 2) + e.$2 * e.$2))
            .toList(),
        minor = _robustMean(tubes),
        residuals = tubes.map((e) => (e - minor).abs()).toList(),
        stats = fitStatistics(context, residuals);
    return RecognitionCandidate(
      id: '$id:${context.observation.regionFingerprint}',
      type: type,
      regionId: context.observation.regionId,
      parameters: {
        'center': center.toJson(),
        'axis': axis.toJson(),
        'majorRadius': major,
        'minorRadius': minor,
      },
      statistics: stats,
      evidence: [
        RecognitionEvidence(
          'torus-tube-residual',
          'Distância ao círculo gerador avaliada robustamente',
          id,
          stats.score,
        ),
      ],
      origin: id,
    );
  }
}

double _robustMean(List<double> values) {
  final sorted = [...values]..sort(),
      median = sorted[sorted.length ~/ 2],
      deviations = values.map((v) => (v - median).abs()).toList()..sort(),
      mad = deviations[deviations.length ~/ 2],
      inliers = mad == 0
          ? values
          : values.where((v) => (v - median).abs() <= 3 * mad).toList();
  return inliers.reduce((a, b) => a + b) / inliers.length;
}
