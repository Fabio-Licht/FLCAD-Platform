import 'dart:math' as math;

import '../../../core/cad_kernel/io/kernel_io_models.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../../../core/geometric_kernel/linear_algebra/linear_algebra.dart';
import 'surface_selection_policy.dart';

/// Result of the directed, continuity-aware cylinder seed selection.
///
/// The result is intentionally a triangle set over the original mesh. It is
/// consumed by [EditableSurfaceSelection] and therefore keeps brush, preview,
/// expand/contract and local undo on the existing selection contract.
final class CylindricalRegionSelectionResult {
  const CylindricalRegionSelectionResult({
    required this.triangles,
    required this.transitionTriangles,
    required this.origin,
    required this.axis,
    required this.radius,
    required this.diagnostics,
  });

  final Set<int> triangles;
  final Set<int> transitionTriangles;
  final Vector3 origin;
  final Vector3 axis;
  final double radius;
  final Map<String, Object?> diagnostics;
}

/// Grows a cylinder from a technical original-mesh hit.
///
/// It uses only local surface evidence: edge adjacency, normal continuity,
/// normal-space axis evidence and distance to the locally fitted cylinder.
/// No nominal diameter is consulted. Discontinuities remain outside the
/// returned set and are reported for diagnostics/brush completion.
final class CylindricalRegionSelector {
  const CylindricalRegionSelector({
    this.localSeedLimit = 192,
    this.maxTriangles = 30000,
    this.localNormalAngleDegrees = 24,
    this.growthNormalAngleDegrees = 32,
    this.initialRadialTolerance = .14,
    this.radialTolerance = .075,
  });

  final int localSeedLimit;
  final int maxTriangles;
  final double localNormalAngleDegrees;
  final double growthNormalAngleDegrees;
  final double initialRadialTolerance;
  final double radialTolerance;

  CylindricalRegionSelectionResult select({
    required KernelMeshGeometry geometry,
    required int seedTriangle,
    required Set<int> Function(int triangle) neighborsOf,
  }) {
    final count = geometry.triangles.length ~/ 3;
    if (seedTriangle < 0 || seedTriangle >= count) {
      throw StateError('Triângulo cilíndrico inicial inválido: $seedTriangle.');
    }
    final normals = List<Vector3>.generate(
      count,
      (triangle) => triangleNormal(geometry, triangle),
      growable: false,
    );
    final centers = List<Vector3>.generate(
      count,
      (triangle) => triangleCentroid(geometry, triangle),
      growable: false,
    );
    final local = _collectLocalPatch(
      seedTriangle,
      neighborsOf,
      normals,
      localSeedLimit,
    );
    if (local.length < 12) {
      throw StateError(
        'A vizinhança cilíndrica inicial tem apenas ${local.length} '
        'triângulos; transição ou descontinuidade no seed.',
      );
    }
    final broad = _collectTopologyPatch(
      seedTriangle,
      neighborsOf,
      localSeedLimit * 32,
    );
    final broadAxis = _crossVoteAxis(
      broad.map((triangle) => normals[triangle]).toList(),
    );
    final axisAligned = broadAxis.length > 1e-12
        ? broad
              .where(
                (triangle) => normals[triangle].dot(broadAxis).abs() <= .35,
              )
              .toSet()
        : local;
    final localModel = _fitModel(local, centers, normals);
    final broadModel = _fitModel(
      axisAligned.length >= 12 ? axisAligned : local,
      centers,
      normals,
    );
    final scaleDiagnostics = <Map<String, Object?>>[];
    final hypotheses = <({int scale, int aligned, _CylinderModel model})>[];
    for (final scale in const [192, 384, 768, 1536, 3072, 6144]) {
      final patch = _collectTopologyPatch(
        seedTriangle,
        neighborsOf,
        math.min(localSeedLimit * 32, scale),
      );
      final patchAxis = _crossVoteAxis(
        patch.map((triangle) => normals[triangle]).toList(),
      );
      final aligned = patchAxis.length > 1e-12
          ? patch
                .where(
                  (triangle) => normals[triangle].dot(patchAxis).abs() <= .35,
                )
                .toSet()
          : patch;
      final model = _fitModel(
        aligned.length >= 12 ? aligned : patch,
        centers,
        normals,
      );
      if (model.valid) {
        hypotheses.add((
          scale: patch.length,
          aligned: aligned.length,
          model: model,
        ));
      }
      scaleDiagnostics.add({
        'scale': patch.length,
        'aligned': aligned.length,
        'radius': model.radius,
        'conditioning': model.conditioning,
      });
    }
    var model = broadModel;
    var chosenScale = 6144;
    var chosenScore = double.negativeInfinity;
    var chosenCoverage = 0.0;
    var chosenRms = double.infinity;
    final hypothesisDiagnostics = <Map<String, Object?>>[];
    final hypothesisWatch = Stopwatch()..start();
    for (final hypothesis in hypotheses) {
      final probe = _grow(
        seedTriangles: local,
        model: hypothesis.model,
        centers: centers,
        normals: normals,
        neighborsOf: neighborsOf,
        limit: math.min(2048, maxTriangles),
        refit: false,
      );
      final probeResiduals = [
        for (final triangle in probe)
          (_radialDistance(
                    centers[triangle],
                    hypothesis.model.origin,
                    hypothesis.model.axis,
                  ) -
                  hypothesis.model.radius)
              .abs(),
      ];
      final coverage = _angularCoverage(probe, centers, hypothesis.model);
      final probeRms = _rms(probeResiduals);
      final score =
          probe.length *
          math.pow(coverage / 360.0, 2) /
          math.max(.05, 1 + probeRms);
      hypothesisDiagnostics.add({
        'scale': hypothesis.scale,
        'radius': hypothesis.model.radius,
        'conditioning': hypothesis.model.conditioning,
        'probeTriangles': probe.length,
        'probeCoverage': coverage,
        'probeRms': _rms(probeResiduals),
        'score': score,
      });
      if (score > chosenScore) {
        chosenScore = score;
        chosenScale = hypothesis.scale;
        chosenCoverage = coverage;
        chosenRms = probeRms;
        model = hypothesis.model;
      }
    }
    hypothesisWatch.stop();
    if (!model.valid) {
      throw StateError(
        'Evidência local insuficiente para distinguir cilindro de face plana '
        '(condicionamento ${model.conditioning.toStringAsFixed(3)}).',
      );
    }

    final accepted = <int>{...local};
    final transitions = <int>{};
    final pending = <int>[...local];
    final visited = <int>{...local};
    final radialLimit = math.max(.35, model.radius * initialRadialTolerance);
    while (pending.isNotEmpty && accepted.length < maxTriangles) {
      final current = pending.removeLast();
      for (final next in neighborsOf(current)) {
        if (!visited.add(next)) continue;
        final normalAngle = _angle(normals[current], normals[next]);
        final radial = _radialDistance(centers[next], model.origin, model.axis);
        final candidateLimit = accepted.length <= local.length * 2
            ? radialLimit
            : math.max(.3, model.radius * radialTolerance);
        final axisNormal = normals[next].dot(model.axis).abs();
        if (normalAngle > growthNormalAngleDegrees * math.pi / 180 ||
            axisNormal > .45 ||
            (radial - model.radius).abs() > candidateLimit) {
          transitions.add(next);
          continue;
        }
        accepted.add(next);
        pending.add(next);
        // Re-fitting the complete accepted set every 64 triangles made the
        // growth quadratic on dense STL meshes. Keep the adaptive model, but
        // update it at a bounded cadence relative to the mesh size.
        if (accepted.length % 1024 == 0) {
          final updated = _fitModel(accepted, centers, normals);
          if (updated.valid) model = updated;
        }
      }
    }

    final finalModel = _fitModel(accepted, centers, normals);
    if (finalModel.valid) model = finalModel;
    final residuals = [
      for (final triangle in accepted)
        (_radialDistance(centers[triangle], model.origin, model.axis) -
                model.radius)
            .abs(),
    ]..sort();
    final rms = residuals.isEmpty
        ? double.infinity
        : math.sqrt(
            residuals.fold<double>(0, (sum, value) => sum + value * value) /
                residuals.length,
          );
    return CylindricalRegionSelectionResult(
      triangles: Set.unmodifiable(accepted),
      transitionTriangles: Set.unmodifiable(transitions),
      origin: model.origin,
      axis: model.axis,
      radius: model.radius,
      diagnostics: {
        'mode': 'cylindrical-continuity',
        'seedTriangle': seedTriangle,
        'localSeedTriangles': local.length,
        'broadTopologyTriangles': broad.length,
        'axisAlignedTriangles': axisAligned.length,
        'localModelRadiusMm': localModel.radius,
        'localModelConditioning': localModel.conditioning,
        'broadModelRadiusMm': broadModel.radius,
        'broadModelConditioning': broadModel.conditioning,
        'scaleDiagnostics': scaleDiagnostics,
        'hypothesisCount': hypotheses.length,
        'chosenHypothesisScale': chosenScale,
        'chosenHypothesisScore': chosenScore,
        'chosenHypothesisCoverage': chosenCoverage,
        'chosenHypothesisRms': chosenRms,
        'hypothesisQuality': chosenCoverage >= 300 && chosenRms <= .30
            ? 'sufficient'
            : 'insufficient-local-evidence',
        'hypothesisDiagnostics': hypothesisDiagnostics,
        'hypothesisEvaluationMs': hypothesisWatch.elapsedMicroseconds / 1000,
        'selectedTriangles': accepted.length,
        'transitionTriangles': transitions.length,
        'normalConditioning': model.conditioning,
        'radiusMm': model.radius,
        'rmsCentroidResidualMm': rms,
        'maximumCentroidResidualMm': residuals.isEmpty ? 0 : residuals.last,
        'axis': model.axis.toJson(),
        'origin': model.origin.toJson(),
        'radialToleranceMm': math.max(.3, model.radius * radialTolerance),
        'nominalDiameterUsed': false,
      },
    );
  }

  Set<int> _collectLocalPatch(
    int seed,
    Set<int> Function(int triangle) neighborsOf,
    List<Vector3> normals,
    int limit,
  ) {
    final result = <int>{seed};
    final pending = <int>[seed];
    final maximumAngle = localNormalAngleDegrees * math.pi / 180;
    while (pending.isNotEmpty && result.length < limit) {
      final current = pending.removeLast();
      for (final next in neighborsOf(current)) {
        if (result.length >= limit || result.contains(next)) continue;
        if (_angle(normals[current], normals[next]) > maximumAngle) continue;
        result.add(next);
        pending.add(next);
      }
    }
    return result;
  }

  Set<int> _grow({
    required Set<int> seedTriangles,
    required _CylinderModel model,
    required List<Vector3> centers,
    required List<Vector3> normals,
    required Set<int> Function(int triangle) neighborsOf,
    required int limit,
    required bool refit,
  }) {
    final accepted = <int>{...seedTriangles};
    final pending = <int>[...seedTriangles];
    final visited = <int>{...seedTriangles};
    final radialLimit = math.max(.35, model.radius * initialRadialTolerance);
    var active = model;
    while (pending.isNotEmpty && accepted.length < limit) {
      final current = pending.removeLast();
      for (final next in neighborsOf(current)) {
        if (!visited.add(next)) continue;
        final normalAngle = _angle(normals[current], normals[next]);
        final radial = _radialDistance(
          centers[next],
          active.origin,
          active.axis,
        );
        final candidateLimit = accepted.length <= seedTriangles.length * 2
            ? radialLimit
            : math.max(.3, active.radius * radialTolerance);
        final axisNormal = normals[next].dot(active.axis).abs();
        if (normalAngle > growthNormalAngleDegrees * math.pi / 180 ||
            axisNormal > .45 ||
            (radial - active.radius).abs() > candidateLimit) {
          continue;
        }
        accepted.add(next);
        pending.add(next);
        if (refit && accepted.length % 1024 == 0) {
          final updated = _fitModel(accepted, centers, normals);
          if (updated.valid) active = updated;
        }
      }
    }
    return accepted;
  }

  Set<int> _collectTopologyPatch(
    int seed,
    Set<int> Function(int triangle) neighborsOf,
    int limit,
  ) {
    final result = <int>{seed};
    final pending = <int>[seed];
    while (pending.isNotEmpty && result.length < limit) {
      final current = pending.removeLast();
      for (final next in neighborsOf(current)) {
        if (result.length >= limit || !result.add(next)) continue;
        pending.add(next);
      }
    }
    return result;
  }

  _CylinderModel _fitModel(
    Set<int> triangles,
    List<Vector3> centers,
    List<Vector3> normals,
  ) {
    if (triangles.length < 6) return _CylinderModel.invalid;
    final ids = triangles.toList(growable: false);
    final covariance = List.generate(3, (_) => List<double>.filled(3, 0));
    for (final id in ids) {
      final normal = normals[id];
      for (var row = 0; row < 3; row++) {
        final a = _component(normal, row);
        for (var column = 0; column < 3; column++) {
          covariance[row][column] += a * _component(normal, column);
        }
      }
    }
    final eigen = const LinearAlgebra().symmetricEigen(DenseMatrix(covariance));
    final dominant = eigen.values.first;
    final transverse = eigen.values[1];
    final axisValue = eigen.vectors[2];
    var axis = Vector3(axisValue[0], axisValue[1], axisValue[2]).normalized;
    final normalAxis = _crossVoteAxis(ids.map((id) => normals[id]).toList());
    if (normalAxis.length > 1e-12) axis = normalAxis;
    final conditioning = dominant <= 1e-12
        ? double.infinity
        : transverse / dominant;
    if (axis.length <= 1e-12 || transverse <= dominant * .012) {
      return _CylinderModel.invalid.copyWith(conditioning: conditioning);
    }
    final reference = axis.z.abs() < .9
        ? const Vector3(0, 0, 1)
        : const Vector3(1, 0, 0);
    final u = axis.cross(reference).normalized;
    final v = axis.cross(u).normalized;
    final rows = <List<double>>[];
    final rhs = <double>[];
    for (final id in ids) {
      final point = centers[id];
      final x = point.dot(u), y = point.dot(v);
      rows.add([x, y, 1]);
      rhs.add(-(x * x + y * y));
    }
    Vector3 origin;
    double radius;
    try {
      final solution = const LinearAlgebra().leastSquares(
        DenseMatrix(rows),
        rhs,
      );
      final center = u * (-solution[0] / 2) + v * (-solution[1] / 2);
      final meanAxial =
          ids.map((id) => centers[id].dot(axis)).reduce((a, b) => a + b) /
          ids.length.toDouble();
      origin = center + axis * meanAxial;
      final squared = solution[0] * solution[0] + solution[1] * solution[1];
      final value = squared / 4 - solution[2];
      radius = value > 0 ? math.sqrt(value) : 0;
    } catch (_) {
      final mean =
          ids.fold<Vector3>(Vector3.zero, (sum, id) => sum + centers[id]) /
          ids.length.toDouble();
      final values = [
        for (final id in ids) _radialDistance(centers[id], mean, axis),
      ]..sort();
      origin = mean;
      radius = values[values.length ~/ 2];
    }
    if (!radius.isFinite || radius <= 1e-6) {
      return _CylinderModel.invalid.copyWith(conditioning: conditioning);
    }
    return _CylinderModel(
      origin: origin,
      axis: axis,
      radius: radius,
      conditioning: conditioning,
      valid: true,
    );
  }
}

double _rms(List<double> values) {
  if (values.isEmpty) return double.infinity;
  return math.sqrt(
    values.fold<double>(0, (sum, value) => sum + value * value) / values.length,
  );
}

double _angularCoverage(
  Set<int> triangles,
  List<Vector3> centers,
  _CylinderModel model,
) {
  if (triangles.length < 3) return 0;
  final reference = model.axis.z.abs() < .9
      ? const Vector3(0, 0, 1)
      : const Vector3(1, 0, 0);
  final u = model.axis.cross(reference).normalized;
  final v = model.axis.cross(u).normalized;
  final angles = [
    for (final triangle in triangles)
      math.atan2(
        (centers[triangle] - model.origin).dot(v),
        (centers[triangle] - model.origin).dot(u),
      ),
  ]..sort();
  var largestGap = 0.0;
  for (var i = 1; i < angles.length; i++) {
    largestGap = math.max(largestGap, angles[i] - angles[i - 1]);
  }
  largestGap = math.max(largestGap, angles.first + 2 * math.pi - angles.last);
  return (2 * math.pi - largestGap) * 180 / math.pi;
}

Vector3 _crossVoteAxis(List<Vector3> normals) {
  if (normals.length < 3) return Vector3.zero;
  var best = Vector3.zero;
  var bestScore = -1;
  final step = math.max(1, normals.length ~/ 24);
  for (var i = 0; i < normals.length; i += step) {
    for (var j = i + step; j < normals.length; j += step) {
      final cross = normals[i].cross(normals[j]);
      if (cross.length <= 1e-6) continue;
      final candidate = cross.normalized;
      final score = normals
          .where((normal) => normal.dot(candidate).abs() <= .15)
          .length;
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
  }
  return best;
}

final class _CylinderModel {
  const _CylinderModel({
    required this.origin,
    required this.axis,
    required this.radius,
    required this.conditioning,
    required this.valid,
  });

  static const invalid = _CylinderModel(
    origin: Vector3.zero,
    axis: Vector3.zero,
    radius: 0,
    conditioning: double.infinity,
    valid: false,
  );

  final Vector3 origin, axis;
  final double radius, conditioning;
  final bool valid;

  _CylinderModel copyWith({double? conditioning}) => _CylinderModel(
    origin: origin,
    axis: axis,
    radius: radius,
    conditioning: conditioning ?? this.conditioning,
    valid: valid,
  );
}

double _component(Vector3 value, int index) => switch (index) {
  0 => value.x,
  1 => value.y,
  _ => value.z,
};

double _angle(Vector3 first, Vector3 second) => math.acos(
  (first.dot(second) / math.max(1e-12, first.length * second.length)).clamp(
    -1.0,
    1.0,
  ),
);

double _radialDistance(Vector3 point, Vector3 origin, Vector3 axis) {
  final delta = point - origin;
  return (delta - axis * delta.dot(axis)).length;
}
