import 'dart:math' as math;

import '../models/metric_reference.dart';

class MetricScaleSolution {
  const MetricScaleSolution({
    required this.scaleFactor,
    required this.confidence,
    required this.references,
    required this.evidence,
    required this.hasConflicts,
    this.conflicts = const [],
  });

  final double? scaleFactor;
  final double confidence;
  final List<MetricReference> references;
  final List<MetricReferenceEvidence> evidence;
  final bool hasConflicts;
  final List<MetricReferenceConflict> conflicts;

  double get maximumResidual => evidence.isEmpty
      ? 0
      : evidence.map((item) => item.residualMillimeters.abs()).reduce(math.max);

  double get averageResidual => evidence.isEmpty
      ? 0
      : evidence
                .map((item) => item.residualMillimeters.abs())
                .fold<double>(0, (sum, value) => sum + value) /
            evidence.length;

  bool get isSolvable => scaleFactor != null && references.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'scaleFactor': scaleFactor,
    'confidence': confidence,
    'references': references.map((reference) => reference.toJson()).toList(),
    'evidence': evidence.map((item) => item.toJson()).toList(),
    'hasConflicts': hasConflicts,
    'maximumResidual': maximumResidual,
    'averageResidual': averageResidual,
    'conflicts': conflicts.map((conflict) => conflict.toJson()).toList(),
  };
}

class MetricReferenceConflict {
  const MetricReferenceConflict({
    required this.referenceA,
    required this.referenceB,
    required this.residualMillimeters,
    this.suggestedInvestigation =
        'Verificar a captura e a calibração da referência',
  });

  final String referenceA;
  final String referenceB;
  final double residualMillimeters;
  final String suggestedInvestigation;

  Map<String, dynamic> toJson() => {
    'referenceA': referenceA,
    'referenceB': referenceB,
    'residualMillimeters': residualMillimeters,
    'suggestedInvestigation': suggestedInvestigation,
  };
}

class MetricReferenceSolver {
  const MetricReferenceSolver({this.conflictTolerance = .05});

  final double conflictTolerance;

  MetricScaleSolution solve(Iterable<MetricReference> input) {
    final references = List<MetricReference>.unmodifiable(input);
    final usable = references
        .where(
          (reference) =>
              reference.observedDistance.isFinite &&
              reference.observedDistance > 0 &&
              reference.knownMillimeters.isFinite &&
              reference.knownMillimeters > 0,
        )
        .toList();
    if (usable.isEmpty) {
      return MetricScaleSolution(
        scaleFactor: null,
        confidence: 0,
        references: references,
        evidence: const [],
        hasConflicts: false,
      );
    }

    final denominator = usable.fold<double>(
      0,
      (sum, reference) =>
          sum + reference.observedDistance * reference.observedDistance,
    );
    final numerator = usable.fold<double>(
      0,
      (sum, reference) =>
          sum + reference.observedDistance * reference.knownMillimeters,
    );
    final factor = numerator / denominator;
    final evidence = usable.map((reference) {
      final residual =
          reference.observedDistance * factor - reference.knownMillimeters;
      final tolerance = math.max(
        reference.knownMillimeters * conflictTolerance,
        reference.uncertainty,
      );
      final conflict = residual.abs() > tolerance;
      final confidence =
          (1 - residual.abs() / math.max(reference.knownMillimeters, 1e-9))
              .clamp(0.0, 1.0)
              .toDouble();
      return MetricReferenceEvidence(
        referenceId: reference.id,
        type: reference.type,
        origin: reference.origin,
        nominalDimension: reference.knownMillimeters,
        observedDistance: reference.observedDistance,
        expectedMillimeters: reference.knownMillimeters,
        residualMillimeters: residual,
        confidence: confidence,
        conflict: conflict,
      );
    }).toList();
    final confidence =
        evidence.fold<double>(0, (sum, item) => sum + item.confidence) /
        evidence.length;
    final conflicts = <MetricReferenceConflict>[];
    for (var index = 0; index < evidence.length; index++) {
      for (
        var otherIndex = index + 1;
        otherIndex < evidence.length;
        otherIndex++
      ) {
        final first = evidence[index];
        final second = evidence[otherIndex];
        if (!first.conflict && !second.conflict) continue;
        conflicts.add(
          MetricReferenceConflict(
            referenceA: first.referenceId,
            referenceB: second.referenceId,
            residualMillimeters:
                (first.residualMillimeters - second.residualMillimeters).abs(),
          ),
        );
      }
    }
    return MetricScaleSolution(
      scaleFactor: factor,
      confidence: confidence,
      references: references,
      evidence: List.unmodifiable(evidence),
      hasConflicts: evidence.any((item) => item.conflict),
      conflicts: List.unmodifiable(conflicts),
    );
  }
}
