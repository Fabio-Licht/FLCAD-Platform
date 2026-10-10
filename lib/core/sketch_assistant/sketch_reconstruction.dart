import 'dart:convert';
import 'dart:math' as math;

import '../sketch_engine/entities/sketch_entities.dart';
import '../sketch_engine/models/sketch_models.dart';

enum SketchReconstructionKind { line, circle, arc, parallel, perpendicular }

enum SketchCircularFitFailure {
  invalidChain,
  insufficientPoints,

  /// The selected samples can be covered by a straight line within the
  /// absolute tolerance, so no arc is recoverable from them.
  collinearPoints,

  /// The radial error of the fitted circle is larger than the combined
  /// absolute/relative tolerance.
  fitErrorAboveTolerance,

  /// The fitted arc sweep is not a usable positive angle.
  invalidSweep,

  /// The radius is not finite, or is smaller than the geometric tolerance.
  unstableRadius,
  ambiguousBranch,
  incompatibleTangency,

  /// A manual tangency reference is not attached to the requested chain
  /// endpoint (or it is one of the curves being replaced).
  disconnectedTangency,

  /// A manual tangency reference is attached to the endpoint but points into
  /// the chain instead of continuing the profile.
  reversedTangency,
}

/// How much continuity was retained by an explicit circular reconstruction.
/// The geometry is always usable; callers use this to present a non-blocking
/// warning when the source chain cannot satisfy bilateral C1.
enum SketchCircularFitQuality { c1Bilateral, c1Partial, geometricFallback }

/// Absolute and relative tolerances for the circular adjustment.
///
/// Distances are millimetres.  [relativeToRadius] is dimensionless and is
/// multiplied by the fitted radius, so the effective radial budget is
/// `max(absoluteMillimeters, relativeToRadius * radius)` - an absolute floor
/// for small arcs and a relative share for large ones.
class SketchCircularFitTolerance {
  const SketchCircularFitTolerance({
    this.absoluteMillimeters = 0.25,
    this.relativeToRadius = 0.01,
    this.maxGapMillimeters = 0.5,
    this.gapRelativeToSpan = 0.01,
    this.minRadiusMillimeters = 0.01,
    this.collinearMillimeters = 1e-4,
    this.collinearRelativeToSpan = 1e-3,
    this.endpointCoincidenceMillimeters = 0.05,
    this.tangencyAngleRadians = _maxTangencyAngle,
  });

  /// Largest radial error accepted when [relativeToRadius] * radius is
  /// smaller than this.
  final double absoluteMillimeters;

  /// Relative part of the radial budget.
  final double relativeToRadius;

  /// Largest distance allowed between two consecutive selected regions before
  /// the selection is considered split.
  final double maxGapMillimeters;

  /// Relative part of the gap budget: the effective gap is
  /// `max(maxGapMillimeters, gapRelativeToSpan * span)`, so small parts keep
  /// the absolute floor while a long selection tolerates a proportionally
  /// small gap.
  final double gapRelativeToSpan;

  /// Smallest radius that still describes a usable arc.
  final double minRadiusMillimeters;

  /// Absolute floor of the sagitta below which the selection counts as a
  /// straight segment.
  final double collinearMillimeters;

  /// Relative part of the collinearity threshold: the sagitta is compared to
  /// the span of the selection, which keeps the test independent of size.  The
  /// default rejects only arcs spanning less than about half a degree.
  final double collinearRelativeToSpan;

  /// Performance guards for a mesh Section selection.  The command is used on
  /// hand picked regions, so these only stop a pathological whole-profile
  /// selection from reaching the least squares solve.
  static const int maxRegions = 64;
  static const int maxSamples = 4096;

  /// Distance below which two region endpoints count as the same point when
  /// looking for the free ends of the selection.  It is a numerical
  /// coincidence test, not a gap budget: regions separated by real gaps stay
  /// independent and are all still used by the fit.
  final double endpointCoincidenceMillimeters;

  /// Largest angle, in radians, between the arc tangent and the oriented
  /// reference tangent for the fit to be reported as tangente.
  final double tangencyAngleRadians;

  double radialFor(double radius) =>
      math.max(absoluteMillimeters, relativeToRadius * radius);
}

/// Absolute residual budget for Assistant line promotion.
///
/// Distances are millimetres. Isolated native lines stay metadata-only and
/// do not use this budget. Chains of lines and single splines are accepted
/// only when the PCA residual [SketchRegionFitResult.maxError] is at most
/// [reconstructionToleranceMm]. Suggestion confidence is not a substitute
/// for this dimensional gate.
class SketchLineReconstructionTolerance {
  const SketchLineReconstructionTolerance({
    this.reconstructionToleranceMm = 0.10,
  });

  /// Largest PCA residual accepted when promoting a line chain or spline.
  final double reconstructionToleranceMm;
}

/// Maximum angle between the arc tangent and the oriented neighbour tangent
/// accepted for a bilateral C1 solution.
///
/// A Section polyline approximates the real curve with chords, so a neighbour
/// direction differs from the true tangent by half of its own angular span.
/// One degree absorbs that discretization error for realistic section facets
/// while still rejecting a visible tangent break; an arc that merely shares
/// the endpoints is never accepted as C1.
const double _maxTangencyAngle = 0.0175;

/// Cosine below which an oriented reference is considered to run *back over*
/// the chain instead of continuing the profile.
///
/// The chain direction is estimated from its own adjacent chord, which for a
/// coarse Section can sit up to ~45 deg away from the true tangent, so this
/// only has to separate "same way" from "opposite way" (~180 deg) and not act
/// as a precision test.
const double _invertedReferenceCosine = -0.5;

/// Directions supplied by the curves that touch one chain boundary, plus the
/// reason an explicit manual reference could not be used.
class _NeighborProbe {
  const _NeighborProbe(this.directions, [this.failure]);

  final List<SketchVector> directions;
  final SketchCircularFitFailure? failure;
}

/// Selected regions ordered by proximity, with the external endpoints kept and
/// the gaps measured between consecutive regions.
class _OrderedSelection {
  const _OrderedSelection({
    required this.regions,
    required this.start,
    required this.end,
    required this.gaps,
    required this.usedEntityIds,
  });

  final List<List<SketchVector>> regions;
  final SketchVector start;
  final SketchVector end;
  final List<double> gaps;

  /// Entities that actually contributed samples, in walk order.
  final List<String> usedEntityIds;

  /// Every sample of every selected region, in walk order.  The arc is fitted
  /// on this whole cloud, never on an artificial connector.
  List<SketchVector> get points => <SketchVector>[
    for (final region in regions) ...region,
  ];
}

class _SelectionOrder {
  const _SelectionOrder(this.selection, [this.failure]);

  final _OrderedSelection? selection;
  final SketchCircularFitFailure? failure;
}

/// Tangency of a candidate circle at both preserved endpoints, in degrees.
class _TangencyMeasurement {
  const _TangencyMeasurement({
    required this.startDegrees,
    required this.endDegrees,
    this.failure,
  });

  final double startDegrees;
  final double endDegrees;
  final SketchCircularFitFailure? failure;
}

/// Why a circular adjustment was rejected, with the numbers the panel has to
/// show: largest gap, measured tangency angles and the fitted radius.
class SketchCircularFitDiagnosis {
  const SketchCircularFitDiagnosis(
    this.failure, {
    this.maxGapMillimeters,
    this.tangencyStartDegrees,
    this.tangencyEndDegrees,
    this.radius,
    this.endpointDeviationMillimeters,
  });

  final SketchCircularFitFailure failure;
  final double? maxGapMillimeters;
  final double? tangencyStartDegrees;
  final double? tangencyEndDegrees;
  final double? radius;

  /// Largest distance between the fitted arc and the preserved external
  /// endpoints.
  final double? endpointDeviationMillimeters;
}

class SketchReconstructionSuggestion {
  const SketchReconstructionSuggestion({
    required this.kind,
    required this.entityIds,
    required this.confidence,
    this.center,
    this.radius,
    this.startAngle,
    this.endAngle,
    this.startPoint,
    this.endPoint,
    this.circularFitQuality,
    this.warnings = const <String>[],
    this.maxGapMillimeters,
    this.tangencyStartDegrees,
    this.tangencyEndDegrees,
    this.usedEntityIds = const <String>[],
    this.coveredEntityIds = const <String>[],
    this.rmsError,
    this.maxError,
  });

  final SketchReconstructionKind kind;
  final List<String> entityIds;
  final double confidence;
  final SketchVector? center;
  final double? radius;
  final double? startAngle;
  final double? endAngle;

  /// Boundary points retained when a manual circular fit replaces a chain.
  final SketchVector? startPoint;
  final SketchVector? endPoint;

  final SketchCircularFitQuality? circularFitQuality;

  /// Non-blocking findings of the adjustment, for example the gaps measured
  /// between partially disconnected Section regions.
  final List<String> warnings;

  /// Largest distance measured between two consecutive selected regions.
  final double? maxGapMillimeters;

  /// Angle between the arc tangent and the oriented reference tangent at each
  /// preserved endpoint, in degrees.  Zero means a real C1 junction.
  final double? tangencyStartDegrees;
  final double? tangencyEndDegrees;

  /// Regions that actually contributed samples to the fit, in walk order.
  final List<String> usedEntityIds;

  /// Visible source fragments already represented by the promoted arc.
  final List<String> coveredEntityIds;

  /// Residual of the recognized fit, in millimetres. Geometrically segmented
  /// line chains populate these from their PCA pass; native primitives and
  /// relation suggestions may legitimately leave them null.
  final double? rmsError;
  final double? maxError;

  String get label => switch (kind) {
    SketchReconstructionKind.line => 'Linha reconhecida',
    SketchReconstructionKind.circle => 'Círculo reconhecido',
    SketchReconstructionKind.arc => 'Arco reconhecido',
    SketchReconstructionKind.parallel => 'Linhas paralelas',
    SketchReconstructionKind.perpendicular => 'Linhas perpendiculares',
  };
}

/// Classification of a transient set of Assistant suggestions.  This is
/// deliberately separate from the recognition kind: it describes how the
/// selected hypotheses relate topologically, without promoting or editing
/// any Sketch entity.
enum SketchReconstructionSelectionClassification {
  openChain,
  closedLoop,
  ambiguous,
  incompatible,
}

class SketchReconstructionSelectionConnection {
  const SketchReconstructionSelectionConnection({
    required this.fromKey,
    required this.toKey,
    required this.fromEndpoint,
    required this.toEndpoint,
    required this.distanceMillimeters,
    required this.isConnected,
  });

  final String fromKey;
  final String toKey;
  final String fromEndpoint;
  final String toEndpoint;
  final double distanceMillimeters;

  final bool isConnected;

  bool get connected => isConnected;
}

class SketchReconstructionSelectionItem {
  const SketchReconstructionSelectionItem({
    required this.suggestion,
    required this.reversed,
  });

  final SketchReconstructionSuggestion suggestion;
  final bool reversed;
}

/// Read-only diagnosis for the ordered Assistant multiselection.  All values
/// are computed from the current Sketch geometry and are intentionally not
/// persisted or submitted to the command history.
class SketchReconstructionSelectionAnalysis {
  const SketchReconstructionSelectionAnalysis({
    required this.classification,
    required this.items,
    required this.connections,
    required this.gapsMillimeters,
    required this.overlapKeys,
    required this.duplicateKeys,
    required this.branchKeys,
    required this.crossingKeys,
    required this.missingEntityIds,
    required this.diagnostics,
  });

  final SketchReconstructionSelectionClassification classification;
  final List<SketchReconstructionSelectionItem> items;
  final List<SketchReconstructionSelectionConnection> connections;
  final List<double> gapsMillimeters;
  final List<String> overlapKeys;
  final List<String> duplicateKeys;
  final List<String> branchKeys;
  final List<String> crossingKeys;
  final List<String> missingEntityIds;
  final List<String> diagnostics;

  List<SketchReconstructionSuggestion> get orderedSuggestions => [
    for (final item in items) item.suggestion,
  ];

  double get maximumGapMillimeters => gapsMillimeters.isEmpty
      ? 0
      : gapsMillimeters.reduce(math.max);

  bool get isValid =>
      classification == SketchReconstructionSelectionClassification.openChain ||
      classification == SketchReconstructionSelectionClassification.closedLoop;

  String get summary {
    final label = switch (classification) {
      SketchReconstructionSelectionClassification.openChain =>
        'cadeia aberta válida',
      SketchReconstructionSelectionClassification.closedLoop =>
        'loop fechado válido',
      SketchReconstructionSelectionClassification.ambiguous => 'ambíguo',
      SketchReconstructionSelectionClassification.incompatible =>
        'incompatível',
    };
    final gap = maximumGapMillimeters.toStringAsFixed(3);
    return '$label · ${items.length} sugestões · '
        '${connections.length} conexões · gap máx. $gap mm';
  }
}

/// Stable key shared by the Assistant selection model and the joint
/// acceptance planner.  It intentionally depends on source identity and
/// recognition kind, never on click order or list position.
String sketchReconstructionSuggestionKey(
  SketchReconstructionSuggestion suggestion,
) => _selectionSuggestionKey(suggestion);

/// Immutable geometry proposed by a joint acceptance plan.  This is a
/// description only: constructing it never creates or edits a SketchEntity.
class SketchReconstructionProposedGeometry {
  const SketchReconstructionProposedGeometry({
    required this.kind,
    required this.startPoint,
    required this.endPoint,
    required this.closed,
    this.points = const <SketchVector>[],
    this.center,
    this.radius,
    this.startAngle,
    this.endAngle,
  });

  final SketchReconstructionKind kind;
  final SketchVector startPoint;
  final SketchVector endPoint;
  final bool closed;
  /// Immutable samples for a spline proposal.  A line/arc proposal leaves
  /// this empty; no fitting is performed while building the joint plan.
  final List<SketchVector> points;
  final SketchVector? center;
  final double? radius;
  final double? startAngle;
  final double? endAngle;
}

/// One suggestion as it would participate in a future atomic promotion.
/// Source IDs and fingerprints are copied into the plan so a later executor
/// can validate that it is still applying the same recognition result.
class SketchReconstructionJointSuggestionPlan {
  SketchReconstructionJointSuggestionPlan({
    required this.suggestion,
    required this.proposedGeometry,
    required List<String> sourceEntityIds,
    required List<String> coveredEntityIds,
    required List<SketchEntityType> sourceTypes,
    required this.reversed,
    required this.fingerprint,
  }) : sourceEntityIds = List.unmodifiable(sourceEntityIds),
       coveredEntityIds = List.unmodifiable(coveredEntityIds),
       sourceTypes = List.unmodifiable(sourceTypes);

  final SketchReconstructionSuggestion suggestion;
  final SketchReconstructionProposedGeometry proposedGeometry;
  final List<String> sourceEntityIds;
  final List<String> coveredEntityIds;
  final List<SketchEntityType> sourceTypes;
  final bool reversed;
  final String fingerprint;
}

/// Pure, immutable plan for accepting several Assistant suggestions in one
/// future transaction.  The plan is deliberately not connected to a
/// document, command runner, Sketch Engine mutation, overlay or history.
class SketchReconstructionJointAcceptancePlan {
  const SketchReconstructionJointAcceptancePlan({
    required this.analysis,
    required this.suggestions,
    required this.affectedEntityIds,
    required this.hiddenEntityIds,
    required this.sourceFingerprints,
    required this.suggestionFingerprints,
    required this.blockers,
    required this.warnings,
  });

  final SketchReconstructionSelectionAnalysis analysis;
  final List<SketchReconstructionJointSuggestionPlan> suggestions;
  final List<String> affectedEntityIds;
  final List<String> hiddenEntityIds;
  final Map<String, String> sourceFingerprints;
  final Map<String, String> suggestionFingerprints;
  final List<String> blockers;
  final List<String> warnings;

  bool get canApply => blockers.isEmpty;
}

/// Builds a joint acceptance plan without mutating any input object.  It is
/// intentionally separate from individual acceptance: no suggestion is
/// applied sequentially as a substitute for global validation.
class SketchReconstructionAcceptancePlanner {
  const SketchReconstructionAcceptancePlanner();

  SketchReconstructionJointAcceptancePlan plan(
    Iterable<SketchReconstructionSuggestion> selected,
    Map<String, SketchEntity> entities, {
    Map<String, String> expectedSuggestionFingerprints = const {},
    SketchCircularFitTolerance tolerance = const SketchCircularFitTolerance(),
  }) {
    final source = selected.toList(growable: false);
    final engine = const SketchReconstructionEngine();
    final analysis = engine.analyzeSelectedSuggestions(
      source,
      entities,
      tolerance: tolerance,
    );
    final blockers = <String>[];
    final warnings = <String>[];
    final sourceFingerprints = <String, String>{};
    final suggestionFingerprints = <String, String>{};
    final plans = <SketchReconstructionJointSuggestionPlan>[];
    final affected = <String>{};
    final hidden = <String>{};

    if (source.isEmpty) blockers.add('Nenhuma sugestão foi selecionada.');
    if (!analysis.isValid) {
      blockers.add(
        'A seleção conjunta é ${_jointClassificationLabel(analysis.classification)}.',
      );
    }
    if (analysis.duplicateKeys.isNotEmpty) {
      blockers.add('Há sugestões duplicadas na seleção.');
    }
    if (analysis.overlapKeys.isNotEmpty) {
      blockers.add('Há fontes compartilhadas ou sobrepostas entre sugestões.');
    }
    if (analysis.branchKeys.isNotEmpty) {
      blockers.add('A seleção contém ramificações ambíguas.');
    }
    if (analysis.crossingKeys.isNotEmpty) {
      blockers.add('A seleção contém cruzamentos internos.');
    }
    if (analysis.missingEntityIds.isNotEmpty) {
      blockers.add(
        'Há entidades de origem ausentes: ${analysis.missingEntityIds.join(', ')}.',
      );
    }
    if (analysis.gapsMillimeters.isNotEmpty) {
      final maxGap = analysis.maximumGapMillimeters;
      if (maxGap > tolerance.maxGapMillimeters) {
        blockers.add(
          'Há gaps acima da tolerância (${maxGap.toStringAsFixed(3)} mm).',
        );
      } else {
        warnings.add(
          'Gaps dentro da tolerância: ${maxGap.toStringAsFixed(3)} mm.',
        );
      }
    }

    // The topology analyzer intentionally treats covered fragments as
    // presentation-only.  For a joint transaction they still matter: one
    // proposal must not hide or replace a fragment that another proposal
    // claims as a source.  Keep this check separate so a hidden covered
    // fragment belonging to only one suggestion remains a valid warning.
    for (var first = 0; first < source.length; first++) {
      final firstIds = {
        ...source[first].entityIds,
        ...source[first].usedEntityIds,
        ...source[first].coveredEntityIds,
      };
      for (var second = first + 1; second < source.length; second++) {
        final shared = firstIds.intersection({
          ...source[second].entityIds,
          ...source[second].usedEntityIds,
          ...source[second].coveredEntityIds,
        });
        if (shared.isNotEmpty) {
          blockers.add(
            'Fontes compartilhadas ou cobertas em conflito: ${shared.toList()..sort()}.',
          );
        }
      }
    }

    final seenRequired = <String>{};
    for (final item in analysis.items) {
      final suggestion = item.suggestion;
      final key = _selectionSuggestionKey(suggestion);
      final requiredIds = <String>{
        ...suggestion.entityIds,
        ...suggestion.usedEntityIds,
      }.toList()..sort();
      final coveredIds = suggestion.coveredEntityIds.toSet().toList()..sort();
      final allIds = {...requiredIds, ...coveredIds}.toList()..sort();
      final currentFingerprint = _jointSuggestionFingerprint(
        suggestion,
        entities,
      );
      suggestionFingerprints[key] = currentFingerprint;
      final expected = expectedSuggestionFingerprints[key];
      if (expected != null && expected != currentFingerprint) {
        blockers.add('Sugestão obsoleta: $key.');
      }
      for (final id in allIds) {
        final entity = entities[id];
        if (entity == null) {
          blockers.add('Entidade ausente na sugestão $key: $id.');
          continue;
        }
        sourceFingerprints[id] = _jointEntityFingerprint(entity);
        affected.add(id);
        if (requiredIds.contains(id)) {
          if (!seenRequired.add(id)) {
            blockers.add(
              'A entidade fonte $id é usada por mais de uma sugestão.',
            );
          }
          if (!entity.visible ||
              entity.construction ||
              entity.reference ||
              entity.metadata['reconstructionHidden'] == true) {
            blockers.add(
              'A fonte obrigatória $id não está elegível ou visível.',
            );
          }
        } else if (entity.metadata['reconstructionHidden'] == true ||
            !entity.visible) {
          warnings.add(
            'Fragmento coberto $id já está oculto; não será reocultado.',
          );
        }
        hidden.add(id);
      }
      final geometry = engine._selectionSuggestionGeometry(
        suggestion,
        entities,
        tolerance.endpointCoincidenceMillimeters,
      );
      if (geometry == null) {
        blockers.add('Geometria inválida ou degenerada na sugestão $key.');
        continue;
      }
      plans.add(
        SketchReconstructionJointSuggestionPlan(
          suggestion: _freezeSuggestion(suggestion),
          proposedGeometry: SketchReconstructionProposedGeometry(
            kind: suggestion.kind,
            startPoint: item.reversed ? geometry.end : geometry.start,
            endPoint: item.reversed ? geometry.start : geometry.end,
            closed: geometry.closed,
            points: _jointSplineProposalPoints(
              suggestion,
              entities,
              engine,
              reversed: item.reversed,
            ),
            center: suggestion.center,
            radius: suggestion.radius,
            startAngle: item.reversed
                ? suggestion.endAngle
                : suggestion.startAngle,
            endAngle: item.reversed
                ? suggestion.startAngle
                : suggestion.endAngle,
          ),
          sourceEntityIds: requiredIds,
          coveredEntityIds: coveredIds,
          sourceTypes: [
            for (final id in requiredIds)
              if (entities[id] case final entity?) entity.type,
          ],
          reversed: item.reversed,
          fingerprint: currentFingerprint,
        ),
      );
    }
    if (plans.length != source.length) {
      blockers.add('Uma ou mais sugestões não possuem geometria utilizável.');
    }
    return SketchReconstructionJointAcceptancePlan(
      analysis: _freezeSelectionAnalysis(analysis),
      suggestions: List.unmodifiable(plans),
      affectedEntityIds: List.unmodifiable(affected.toList()..sort()),
      hiddenEntityIds: List.unmodifiable(hidden.toList()..sort()),
      sourceFingerprints: Map.unmodifiable(sourceFingerprints),
      suggestionFingerprints: Map.unmodifiable(suggestionFingerprints),
      blockers: List.unmodifiable(_unique(blockers)),
      warnings: List.unmodifiable(_unique(warnings)),
    );
  }

  static List<String> _unique(Iterable<String> values) =>
      values.toSet().toList(growable: false);

  static List<SketchVector> _jointSplineProposalPoints(
    SketchReconstructionSuggestion suggestion,
    Map<String, SketchEntity> entities,
    SketchReconstructionEngine engine,
    {required bool reversed}
  ) {
    final ids = suggestion.usedEntityIds.isEmpty
        ? suggestion.entityIds
        : suggestion.usedEntityIds;
    if (!ids.any((id) => entities[id] is SketchSpline)) {
      return const <SketchVector>[];
    }
    final points = <SketchVector>[];
    for (final id in ids) {
      final entity = entities[id];
      if (entity is! SketchSpline) continue;
      for (final point in engine._entitySamples(entity)) {
        if (points.isEmpty ||
            (point - points.last).dot(point - points.last) > 1e-24) {
          points.add(point);
        }
      }
    }
    return List.unmodifiable(reversed ? points.reversed : points);
  }

  static String _jointClassificationLabel(
    SketchReconstructionSelectionClassification classification,
  ) => switch (classification) {
    SketchReconstructionSelectionClassification.openChain =>
      'uma cadeia aberta',
    SketchReconstructionSelectionClassification.closedLoop => 'um loop fechado',
    SketchReconstructionSelectionClassification.ambiguous => 'ambígua',
    SketchReconstructionSelectionClassification.incompatible => 'incompatível',
  };
}

String _jointEntityFingerprint(SketchEntity entity) {
  try {
    return jsonEncode([
      entity.id,
      entity.type.name,
      entity.version,
      entity.visible,
      entity.construction,
      entity.reference,
      entity.metadata['reconstructionHidden'] == true,
      entity.parameters,
    ]);
  } on Object {
    return '${entity.id}:${entity.type.name}:${entity.version}';
  }
}

String _jointSuggestionFingerprint(
  SketchReconstructionSuggestion suggestion,
  Map<String, SketchEntity> entities,
) {
  final ids = {
    ...suggestion.entityIds,
    ...suggestion.usedEntityIds,
    ...suggestion.coveredEntityIds,
  }.toList()..sort();
  return jsonEncode([
    suggestion.kind.name,
    for (final id in ids)
      [
        id,
        entities[id] == null ? null : _jointEntityFingerprint(entities[id]!),
      ],
  ]);
}

SketchReconstructionSuggestion _freezeSuggestion(
  SketchReconstructionSuggestion suggestion,
) => SketchReconstructionSuggestion(
  kind: suggestion.kind,
  entityIds: List.unmodifiable(suggestion.entityIds),
  confidence: suggestion.confidence,
  center: suggestion.center,
  radius: suggestion.radius,
  startAngle: suggestion.startAngle,
  endAngle: suggestion.endAngle,
  startPoint: suggestion.startPoint,
  endPoint: suggestion.endPoint,
  circularFitQuality: suggestion.circularFitQuality,
  warnings: List.unmodifiable(suggestion.warnings),
  maxGapMillimeters: suggestion.maxGapMillimeters,
  tangencyStartDegrees: suggestion.tangencyStartDegrees,
  tangencyEndDegrees: suggestion.tangencyEndDegrees,
  usedEntityIds: List.unmodifiable(suggestion.usedEntityIds),
  coveredEntityIds: List.unmodifiable(suggestion.coveredEntityIds),
  rmsError: suggestion.rmsError,
  maxError: suggestion.maxError,
);

SketchReconstructionSelectionAnalysis _freezeSelectionAnalysis(
  SketchReconstructionSelectionAnalysis analysis,
) => SketchReconstructionSelectionAnalysis(
  classification: analysis.classification,
  items: [
    for (final item in analysis.items)
      SketchReconstructionSelectionItem(
        suggestion: _freezeSuggestion(item.suggestion),
        reversed: item.reversed,
      ),
  ],
  connections: List.unmodifiable(analysis.connections),
  gapsMillimeters: List.unmodifiable(analysis.gapsMillimeters),
  overlapKeys: List.unmodifiable(analysis.overlapKeys),
  duplicateKeys: List.unmodifiable(analysis.duplicateKeys),
  branchKeys: List.unmodifiable(analysis.branchKeys),
  crossingKeys: List.unmodifiable(analysis.crossingKeys),
  missingEntityIds: List.unmodifiable(analysis.missingEntityIds),
  diagnostics: List.unmodifiable(analysis.diagnostics),
);

class _SelectionEdge {
  const _SelectionEdge(this.start, this.end);
  final SketchVector start;
  final SketchVector end;
}

class _SelectionSuggestionGeometry {
  const _SelectionSuggestionGeometry({
    required this.suggestion,
    required this.start,
    required this.end,
    required this.closed,
    required this.edges,
  });

  final SketchReconstructionSuggestion suggestion;
  final SketchVector start;
  final SketchVector end;
  final bool closed;
  final List<_SelectionEdge> edges;

  String get key => _selectionSuggestionKey(suggestion);
}

String _selectionSuggestionKey(SketchReconstructionSuggestion suggestion) {
  final ids = {
    ...suggestion.entityIds,
    ...suggestion.usedEntityIds,
  }.toList()..sort();
  return '${suggestion.kind.name}:${ids.join(',')}';
}

/// Result of replacing several Section fragments with one line or spline.
class SketchRegionFitResult {
  static const int maxSplineKnots = 256;

  const SketchRegionFitResult({
    required this.start,
    required this.end,
    required this.points,
    required this.referencePoints,
    required this.referenceRegions,
    required this.usedEntityIds,
    required this.rmsError,
    required this.maxError,
    required this.maxGapMillimeters,
    this.pcaRmsError,
    this.pcaMaxError,
    this.boundaryStatus,
  });

  final SketchVector start;
  final SketchVector end;

  /// Ordered source samples retained only for the visual comparison overlay.
  final List<SketchVector> referencePoints;
  final List<List<SketchVector>> referenceRegions;
  final List<SketchVector> points;
  final List<String> usedEntityIds;
  final double rmsError;
  final double maxError;
  final double maxGapMillimeters;

  /// PCA residuals before a controller applies endpoint conditioning.
  ///
  /// The reconstruction engine itself never conditions endpoints, so these
  /// remain null for a raw engine result and are populated by the promotion
  /// path when a boundary-aware result is produced.
  final double? pcaRmsError;
  final double? pcaMaxError;

  /// Human-readable boundary classification recorded by the promotion path.
  final String? boundaryStatus;
}

enum SketchRegionFitFailure {
  invalidSamples,
  insufficientPoints,
  degenerateGeometry,
}

/// Result or explicit rejection reason for a line/spline region adjustment.
class SketchRegionFitDiagnosis {
  const SketchRegionFitDiagnosis.success(this.result) : failure = null;
  const SketchRegionFitDiagnosis.failure(this.failure) : result = null;

  final SketchRegionFitResult? result;
  final SketchRegionFitFailure? failure;
}

/// Conservative, non-mutating recognition pass for section-derived Sketches.
/// It only proposes semantics; geometry and constraints change only after an
/// explicit user confirmation.
class SketchReconstructionEngine {
  const SketchReconstructionEngine();

  /// Analyzes an ordered transient Assistant selection without touching the
  /// Sketch.  Endpoints are recovered from the actual source entities, then
  /// matched with the existing circular-fit coincidence/gap tolerances.  The
  /// result is deterministic even when [suggestions] arrives in click order.
  SketchReconstructionSelectionAnalysis analyzeSelectedSuggestions(
    Iterable<SketchReconstructionSuggestion> suggestions,
    Map<String, SketchEntity> entities, {
    SketchCircularFitTolerance tolerance = const SketchCircularFitTolerance(),
  }) {
    final source = suggestions.toList(growable: false);
    final records = <_SelectionSuggestionGeometry>[];
    final missing = <String>{};
    final duplicateKeys = <String>{};
    final seenKeys = <String>{};
    final overlapKeys = <String>{};
    for (final suggestion in source) {
      final key = _selectionSuggestionKey(suggestion);
      if (!seenKeys.add(key)) duplicateKeys.add(key);
      final ids = <String>{
        ...suggestion.entityIds,
        ...suggestion.usedEntityIds,
      };
      final absent = ids.where((id) => !entities.containsKey(id));
      missing.addAll(absent);
      final geometry = _selectionSuggestionGeometry(
        suggestion,
        entities,
        tolerance.endpointCoincidenceMillimeters,
      );
      if (geometry != null) records.add(geometry);
    }
    for (var first = 0; first < source.length; first++) {
      for (var second = first + 1; second < source.length; second++) {
        final shared = {
          ...source[first].entityIds,
          ...source[first].usedEntityIds,
        }.intersection({
          ...source[second].entityIds,
          ...source[second].usedEntityIds,
        });
        if (shared.isNotEmpty) {
          overlapKeys.add(
            '${_selectionSuggestionKey(source[first])}~${_selectionSuggestionKey(source[second])}',
          );
        }
      }
    }
    final connections = <SketchReconstructionSelectionConnection>[];
    final adjacency = <String, Set<String>>{};
    final endpointDegree = <String, int>{};
    final endpointUse = <String, int>{};
    final nonConnections = <({
      double distance,
      String first,
      String second,
    })>[];
    final gapDetails = <({double distance, String first, String second})>[];
    final recordByKey = <String, _SelectionSuggestionGeometry>{};
    for (final record in records) {
      recordByKey[record.key] = record;
      adjacency[record.key] = <String>{};
    }
    final gaps = <double>[];
    final crossingKeys = <String>{};
    for (var first = 0; first < records.length; first++) {
      for (var second = first + 1; second < records.length; second++) {
        final a = records[first], b = records[second];
        if (a.edges.any(
          (edgeA) => b.edges.any((edgeB) => _properSegmentCrossing(edgeA, edgeB)),
        )) {
          crossingKeys.add('${a.key}~${b.key}');
        }
        if (a.closed || b.closed) {
          nonConnections.add(
            (
              distance: _distance(a.start, b.start),
              first: a.key,
              second: b.key,
            ),
          );
          continue;
        }
        if (_selectionGeometriesOverlap(
          a,
          b,
          tolerance.endpointCoincidenceMillimeters,
        )) {
          overlapKeys.add('${a.key}~${b.key}');
        }
        final candidates = <({double distance, int a, int b})>[
          (distance: _distance(a.start, b.start), a: 0, b: 0),
          (distance: _distance(a.start, b.end), a: 0, b: 1),
          (distance: _distance(a.end, b.start), a: 1, b: 0),
          (distance: _distance(a.end, b.end), a: 1, b: 1),
        ]..sort((x, y) => x.distance.compareTo(y.distance));
        final closest = candidates.first;
        final fromEndpoint = closest.a == 0 ? 'start' : 'end';
        final toEndpoint = closest.b == 0 ? 'start' : 'end';
        final connection = SketchReconstructionSelectionConnection(
          fromKey: a.key,
          toKey: b.key,
          fromEndpoint: fromEndpoint,
          toEndpoint: toEndpoint,
          distanceMillimeters: closest.distance,
          isConnected: closest.distance <=
              tolerance.endpointCoincidenceMillimeters,
        );
        if (connection.connected) {
          connections.add(connection);
          adjacency[a.key]!.add(b.key);
          adjacency[b.key]!.add(a.key);
          endpointDegree[a.key] = (endpointDegree[a.key] ?? 0) + 1;
          endpointDegree[b.key] = (endpointDegree[b.key] ?? 0) + 1;
          endpointUse['${a.key}|$fromEndpoint'] =
              (endpointUse['${a.key}|$fromEndpoint'] ?? 0) + 1;
          endpointUse['${b.key}|$toEndpoint'] =
              (endpointUse['${b.key}|$toEndpoint'] ?? 0) + 1;
        } else {
          nonConnections.add(
            (distance: closest.distance, first: a.key, second: b.key),
          );
        }
      }
    }
    final componentIds = _selectionComponentIds(records, adjacency);
    for (final gap in nonConnections) {
      if (gap.distance <= tolerance.maxGapMillimeters ||
          componentIds[gap.first] != componentIds[gap.second]) {
        gaps.add(gap.distance);
        gapDetails.add(gap);
      }
    }
    final branchKeys = <String>{
      ...endpointDegree.entries
          .where((entry) => entry.value > 2)
          .map((entry) => entry.key),
      ...endpointUse.entries
          .where((entry) => entry.value > 1)
          .map((entry) => entry.key.split('|').first),
    }.toList(growable: false)
      ..sort();
    final orderedKeys = _orderSelectionSuggestionKeys(
      records,
      adjacency,
      endpointDegree,
    );
    final items = <SketchReconstructionSelectionItem>[];
    SketchVector? previousExit;
    for (final key in orderedKeys) {
      final record = recordByKey[key];
      if (record == null) continue;
      final reversed = previousExit == null
          ? false
          : _distance(previousExit, record.start) >
                _distance(previousExit, record.end);
      items.add(
        SketchReconstructionSelectionItem(
          suggestion: record.suggestion,
          reversed: reversed,
        ),
      );
      previousExit = reversed ? record.start : record.end;
    }
    final connectedComponents = _selectionComponentCount(records, adjacency);
    final hasInvalidSources = missing.isNotEmpty || records.length != source.length;
    final hasAmbiguity = duplicateKeys.isNotEmpty ||
        overlapKeys.isNotEmpty ||
        branchKeys.isNotEmpty ||
        crossingKeys.isNotEmpty ||
        (connectedComponents > 1 && gaps.isEmpty);
    final allClosed = records.length == 1 && records.single.closed;
    final degreeOne = endpointDegree.values.where((value) => value == 1).length;
    final isOpen = records.isNotEmpty &&
        connectedComponents == 1 &&
        (records.length == 1 && !records.single.closed || degreeOne == 2) &&
        branchKeys.isEmpty &&
        !hasInvalidSources &&
        !hasAmbiguity;
    final isLoop = (allClosed ||
            (records.isNotEmpty &&
                connectedComponents == 1 &&
                degreeOne == 0 &&
                branchKeys.isEmpty)) &&
        !hasInvalidSources &&
        !hasAmbiguity;
    final classification = hasInvalidSources
        ? SketchReconstructionSelectionClassification.incompatible
        : hasAmbiguity
        ? SketchReconstructionSelectionClassification.ambiguous
        : isLoop
        ? SketchReconstructionSelectionClassification.closedLoop
        : isOpen
        ? SketchReconstructionSelectionClassification.openChain
        : SketchReconstructionSelectionClassification.incompatible;
    final diagnostics = <String>[
      if (missing.isNotEmpty) 'Entidades ausentes: ${missing.toList()..sort()}',
      if (duplicateKeys.isNotEmpty)
        'Sugestões duplicadas: ${duplicateKeys.toList()..sort()}',
      if (overlapKeys.isNotEmpty)
        'Sobreposição de fontes: ${overlapKeys.toList()..sort()}',
      if (branchKeys.isNotEmpty)
        'Ramificações em: ${branchKeys.join(', ')}',
      if (crossingKeys.isNotEmpty)
        'Cruzamentos internos: ${crossingKeys.toList()..sort()}',
      if (gaps.isNotEmpty)
        'Gaps: ${gapDetails.map((item) => '${item.first}~${item.second} ${item.distance.toStringAsFixed(3)} mm').join('; ')}',
      if (connections.isNotEmpty)
        'Conexões: ${connections.map((item) => '${item.fromKey}(${item.fromEndpoint})→${item.toKey}(${item.toEndpoint}) ${item.distanceMillimeters.toStringAsFixed(3)} mm').join('; ')}',
    ];
    return SketchReconstructionSelectionAnalysis(
      classification: classification,
      items: items,
      connections: connections,
      gapsMillimeters: gaps,
      overlapKeys: overlapKeys.toList(growable: false),
      duplicateKeys: duplicateKeys.toList(growable: false),
      branchKeys: branchKeys,
      crossingKeys: crossingKeys.toList(growable: false),
      missingEntityIds: missing.toList(growable: false),
      diagnostics: diagnostics,
    );
  }

  _SelectionSuggestionGeometry? _selectionSuggestionGeometry(
    SketchReconstructionSuggestion suggestion,
    Map<String, SketchEntity> entities,
    double endpointTolerance,
  ) {
    final edges = <_SelectionEdge>[];
    final ids = {
      ...suggestion.entityIds,
      ...suggestion.usedEntityIds,
    };
    for (final id in ids) {
      final entity = entities[id];
      if (entity == null) return null;
      final edge = _selectionEdge(entity);
      if (edge == null) return null;
      edges.add(edge);
    }
    if (edges.isEmpty) return null;
    if (edges.length == 1 && _distance(edges.single.start, edges.single.end) <= endpointTolerance) {
      return _SelectionSuggestionGeometry(
        suggestion: suggestion,
        start: edges.single.start,
        end: edges.single.end,
        closed: true,
        edges: edges,
      );
    }
    final clusters = <SketchVector>[];
    final degree = <int, int>{};
    int clusterFor(SketchVector point) {
      for (var index = 0; index < clusters.length; index++) {
        if (_distance(clusters[index], point) <= endpointTolerance) {
          degree[index] = (degree[index] ?? 0) + 1;
          return index;
        }
      }
      clusters.add(point);
      degree[clusters.length - 1] = 1;
      return clusters.length - 1;
    }
    for (final edge in edges) {
      clusterFor(edge.start);
      clusterFor(edge.end);
    }
    final external = degree.entries
        .where((entry) => entry.value == 1)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (external.isEmpty) {
      return _SelectionSuggestionGeometry(
        suggestion: suggestion,
        start: clusters.first,
        end: clusters.first,
        closed: true,
        edges: edges,
      );
    }
    if (external.length != 2) return null;
    return _SelectionSuggestionGeometry(
      suggestion: suggestion,
      start: clusters[external[0]],
      end: clusters[external[1]],
      closed: false,
      edges: edges,
    );
  }

  _SelectionEdge? _selectionEdge(SketchEntity entity) {
    SketchVector? vector(Object? value) {
      try {
        final point = SketchVector.fromJson(value);
        return _isFinite(point) ? point : null;
      } on Object {
        return null;
      }
    }
    if (entity is SketchLine) {
      final start = vector(entity.parameters['start']);
      final end = vector(entity.parameters['end']);
      return start == null || end == null ? null : _SelectionEdge(start, end);
    }
    if (entity is SketchArc) {
      final center = vector(entity.parameters['center']);
      final radius = (entity.parameters['radius'] as num?)?.toDouble();
      final startAngle = (entity.parameters['startAngle'] as num?)?.toDouble();
      final endAngle = (entity.parameters['endAngle'] as num?)?.toDouble();
      if (center == null || radius == null || radius <= 0 ||
          !radius.isFinite || startAngle == null || endAngle == null ||
          !startAngle.isFinite || !endAngle.isFinite) {
        return null;
      }
      return _SelectionEdge(
        SketchVector(
          center.x + radius * math.cos(startAngle),
          center.y + radius * math.sin(startAngle),
          center.z,
        ),
        SketchVector(
          center.x + radius * math.cos(endAngle),
          center.y + radius * math.sin(endAngle),
          center.z,
        ),
      );
    }
    if (entity is SketchCircle) {
      final center = vector(entity.parameters['center']);
      final radius = (entity.parameters['radius'] as num?)?.toDouble();
      if (center == null || radius == null || radius <= 0 || !radius.isFinite) {
        return null;
      }
      return _SelectionEdge(center, center);
    }
    if (entity is SketchSpline) {
      final raw = entity.parameters['points'] ?? entity.parameters['sampledPoints'];
      if (raw is! List || raw.length < 2) return null;
      final points = <SketchVector>[];
      for (final value in raw) {
        final point = vector(value);
        if (point == null) return null;
        points.add(point);
      }
      return _SelectionEdge(points.first, points.last);
    }
    return null;
  }

  bool _selectionGeometriesOverlap(
    _SelectionSuggestionGeometry first,
    _SelectionSuggestionGeometry second,
    double tolerance,
  ) {
    final direct = _distance(first.start, second.start) <= tolerance &&
        _distance(first.end, second.end) <= tolerance;
    final reverse = _distance(first.start, second.end) <= tolerance &&
        _distance(first.end, second.start) <= tolerance;
    if (direct || reverse) return true;
    final direction = first.end - first.start;
    final length = math.sqrt(direction.dot(direction));
    if (length <= tolerance) return false;
    final crossStart = (second.start - first.start).x * direction.y -
        (second.start - first.start).y * direction.x;
    final crossEnd = (second.end - first.start).x * direction.y -
        (second.end - first.start).y * direction.x;
    if (crossStart.abs() > tolerance * length ||
        crossEnd.abs() > tolerance * length) {
      return false;
    }
    double projection(SketchVector point) =>
        (point - first.start).dot(direction) / length;
    final firstInterval = [0.0, length]..sort();
    final secondInterval = [projection(second.start), projection(second.end)]
      ..sort();
    return math.min(firstInterval[1], secondInterval[1]) -
            math.max(firstInterval[0], secondInterval[0]) >
        tolerance;
  }

  bool _properSegmentCrossing(_SelectionEdge first, _SelectionEdge second) {
    final a = first.start, b = first.end, c = second.start, d = second.end;
    final direction = b - a;
    final other = d - c;
    final denominator = direction.x * other.y - direction.y * other.x;
    if (denominator.abs() <= 1e-12) return false;
    final delta = c - a;
    final t = (delta.x * other.y - delta.y * other.x) / denominator;
    final u = (delta.x * direction.y - delta.y * direction.x) / denominator;
    // End-point contacts are valid connections, not internal crossings.
    const epsilon = 1e-9;
    return t > epsilon && t < 1 - epsilon && u > epsilon && u < 1 - epsilon;
  }

  List<String> _orderSelectionSuggestionKeys(
    List<_SelectionSuggestionGeometry> records,
    Map<String, Set<String>> adjacency,
    Map<String, int> degree,
  ) {
    if (records.isEmpty) return const [];
    final keys = records.map((record) => record.key).toList()..sort();
    final starts = keys.where((key) => degree[key] == 1).toList()..sort();
    final ordered = <String>[];
    final visited = <String>{};
    void walk(String start) {
      var current = start;
      String? previous;
      while (visited.add(current)) {
        ordered.add(current);
        final next = adjacency[current]!
            .where((key) => key != previous && !visited.contains(key))
            .toList()..sort();
        if (next.isEmpty) break;
        previous = current;
        current = next.first;
      }
    }
    for (final start in [...starts, ...keys]) {
      if (!visited.contains(start)) walk(start);
    }
    return ordered;
  }

  int _selectionComponentCount(
    List<_SelectionSuggestionGeometry> records,
    Map<String, Set<String>> adjacency,
  ) {
    final unseen = records.map((record) => record.key).toSet();
    var count = 0;
    while (unseen.isNotEmpty) {
      count++;
      final queue = <String>[unseen.first];
      unseen.remove(queue.first);
      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        for (final next in adjacency[current] ?? const <String>{}) {
          if (unseen.remove(next)) queue.add(next);
        }
      }
    }
    return count;
  }

  Map<String, int> _selectionComponentIds(
    List<_SelectionSuggestionGeometry> records,
    Map<String, Set<String>> adjacency,
  ) {
    final result = <String, int>{};
    var component = 0;
    for (final record in records) {
      if (result.containsKey(record.key)) continue;
      final queue = <String>[record.key];
      result[record.key] = component;
      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        for (final next in adjacency[current] ?? const <String>{}) {
          if (!result.containsKey(next)) {
            result[next] = component;
            queue.add(next);
          }
        }
      }
      component++;
    }
    return result;
  }

  /// Orders every selected region and computes a stable PCA line fit.  The
  /// real external endpoints are projected onto that line; spline knots stay
  /// on the original samples.
  SketchRegionFitResult? fitSelectedLineOrSpline(
    Iterable<SketchEntity> selected, {
    SketchCircularFitTolerance tolerance = const SketchCircularFitTolerance(),
  }) => diagnoseSelectedLineOrSpline(selected, tolerance: tolerance).result;

  /// Validates every source sample before ordering it or passing knots to the
  /// spline kernel. This keeps malformed scan data out of PCA and rendering.
  SketchRegionFitDiagnosis diagnoseSelectedLineOrSpline(
    Iterable<SketchEntity> selected, {
    SketchCircularFitTolerance tolerance = const SketchCircularFitTolerance(),
    int maxRegions = SketchCircularFitTolerance.maxRegions,
  }) {
    final entities = selected.toList(growable: false);
    if (entities.isEmpty || entities.length > maxRegions) {
      return const SketchRegionFitDiagnosis.failure(
        SketchRegionFitFailure.insufficientPoints,
      );
    }
    try {
      for (final entity in entities) {
        final samples = _entitySamples(entity);
        if (samples.length < 2 || samples.any((point) => !_isFinite(point))) {
          return const SketchRegionFitDiagnosis.failure(
            SketchRegionFitFailure.invalidSamples,
          );
        }
      }
    } catch (_) {
      return const SketchRegionFitDiagnosis.failure(
        SketchRegionFitFailure.invalidSamples,
      );
    }
    final order = _orderSelection(entities, tolerance);
    final selection = order.selection;
    if (selection == null || selection.points.length < 2) {
      return const SketchRegionFitDiagnosis.failure(
        SketchRegionFitFailure.insufficientPoints,
      );
    }
    final points = <SketchVector>[];
    for (final point in selection.points) {
      if (points.isEmpty || _distance(points.last, point) > 1e-8) {
        points.add(point);
      }
    }
    if (points.length < 2 ||
        _distance(selection.start, selection.end) <= 1e-9) {
      return const SketchRegionFitDiagnosis.failure(
        SketchRegionFitFailure.degenerateGeometry,
      );
    }
    final mean = points
        .fold(const SketchVector(0, 0), (sum, point) => sum + point)
        .scale(1 / points.length);
    var xx = 0.0, xy = 0.0, yy = 0.0;
    for (final point in points) {
      final delta = point - mean;
      xx += delta.x * delta.x;
      xy += delta.x * delta.y;
      yy += delta.y * delta.y;
    }
    if (!(xx + yy).isFinite || xx + yy <= 1e-16) {
      return const SketchRegionFitDiagnosis.failure(
        SketchRegionFitFailure.degenerateGeometry,
      );
    }
    final angle = .5 * math.atan2(2 * xy, xx - yy);
    var direction = SketchVector(math.cos(angle), math.sin(angle));
    if ((selection.end - selection.start).dot(direction) < 0) {
      direction = direction.scale(-1);
    }
    SketchVector project(SketchVector point) =>
        mean + direction.scale((point - mean).dot(direction));
    final lineStart = project(selection.start);
    final lineEnd = project(selection.end);
    if (_distance(lineStart, lineEnd) <= 1e-9) {
      return const SketchRegionFitDiagnosis.failure(
        SketchRegionFitFailure.degenerateGeometry,
      );
    }
    var squared = 0.0, maximum = 0.0;
    for (final point in points) {
      final delta = point - mean;
      final error = (delta.x * direction.y - delta.y * direction.x).abs();
      squared += error * error;
      maximum = math.max(maximum, error);
    }
    if (!squared.isFinite || !maximum.isFinite) {
      return const SketchRegionFitDiagnosis.failure(
        SketchRegionFitFailure.invalidSamples,
      );
    }
    return SketchRegionFitDiagnosis.success(
      SketchRegionFitResult(
        start: lineStart,
        end: lineEnd,
        points: _reduceSplineKnots(points),
        referencePoints: List.unmodifiable(points),
        referenceRegions: List.unmodifiable(
          selection.regions
              .map((region) => List<SketchVector>.unmodifiable(region))
              .toList(growable: false),
        ),
        usedEntityIds: selection.usedEntityIds,
        rmsError: math.sqrt(squared / points.length),
        maxError: maximum,
        maxGapMillimeters: selection.gaps.isEmpty
            ? 0
            : selection.gaps.reduce(math.max),
      ),
    );
  }

  /// Deterministic, direction-aware decimation.  It leaves modest selections
  /// untouched, retains the external endpoints and sharp turns, and keeps the
  /// centripetal spline bounded for dense scan sections.
  List<SketchVector> _reduceSplineKnots(List<SketchVector> points) {
    if (points.length <= SketchRegionFitResult.maxSplineKnots) {
      return List.unmodifiable(points);
    }
    final required = <int>{0, points.length - 1};
    for (var index = 1; index + 1 < points.length; index++) {
      final before = points[index] - points[index - 1];
      final after = points[index + 1] - points[index];
      final beforeLength = math.sqrt(before.dot(before));
      final afterLength = math.sqrt(after.dot(after));
      if (beforeLength <= 1e-9 || afterLength <= 1e-9) continue;
      final cosine = (before.dot(after) / (beforeLength * afterLength)).clamp(
        -1.0,
        1.0,
      );
      // Keep turns over about 10 degrees even when downsampling heavily.
      if (cosine < 0.985) required.add(index);
    }
    final available = SketchRegionFitResult.maxSplineKnots - 2;
    final interior =
        required
            .where((index) => index != 0 && index != points.length - 1)
            .toList()
          ..sort();
    if (interior.length > available) {
      final stride = (interior.length - 1) / math.max(available - 1, 1);
      required
        ..clear()
        ..add(0)
        ..add(points.length - 1)
        ..addAll(
          List<int>.generate(
            available,
            (slot) => interior[(slot * stride).round()],
          ),
        );
    }
    if (required.length < SketchRegionFitResult.maxSplineKnots) {
      final remaining = SketchRegionFitResult.maxSplineKnots - required.length;
      final stride = (points.length - 1) / (remaining + 1);
      for (var slot = 1; slot <= remaining; slot++) {
        required.add((slot * stride).round());
      }
    }
    final indices = required.toList()..sort();
    return List.unmodifiable([for (final index in indices) points[index]]);
  }

  bool _isFinite(SketchVector point) =>
      point.x.isFinite && point.y.isFinite && point.z.isFinite;

  /// Fits a circular primitive from an explicit short selection. Unlike the
  /// automatic pass, the selected entities do not need to form one connected
  /// component; small scan gaps are expected in this manual workflow.
  ///
  /// [startTangencyId] and [endTangencyId] optionally name the curves that must
  /// drive the tangency at each preserved chain endpoint.  When a reference is
  /// given it is used instead of the inferred neighbour, it has to be attached
  /// to that endpoint, and it must not be one of the curves being replaced.
  SketchReconstructionSuggestion? fitSelectedCircular(
    Iterable<SketchEntity> selected, {
    Iterable<SketchEntity> context = const <SketchEntity>[],
    String? startTangencyId,
    String? endTangencyId,
    SketchCircularFitTolerance tolerance = const SketchCircularFitTolerance(),
  }) {
    final entities = selected.toList(growable: false);
    if (entities.isEmpty ||
        entities.length > SketchCircularFitTolerance.maxRegions) {
      return null;
    }
    // 1. Order whatever the user picked by proximity and find the ends of the
    //    whole set; gaps are measured, never bridged with a segment.
    final order = _orderSelection(entities, tolerance);
    final selection = order.selection;
    if (selection == null || order.failure != null) return null;
    final points = selection.points;
    if (points.length < 3) return null;
    final start = selection.start;
    final end = selection.end;
    final boundary = (start: start, end: end);
    final selectedIds = entities.map((entity) => entity.id).toSet();
    final manualBoth = startTangencyId != null && endTangencyId != null;
    final warnings = <String>[
      for (final gap in selection.gaps)
        if (gap > 0)
          'gap de ${gap.toStringAsFixed(3)} mm entre regiões da seção',
    ];
    // Anchor on the side of the chain: the sample farthest from the external
    // chord.
    var anchor = points.first;
    var anchorDistance = _distanceToLine(anchor, start, end);
    for (final point in points) {
      final distance = _distanceToLine(point, start, end);
      if (distance > anchorDistance) {
        anchor = point;
        anchorDistance = distance;
      }
    }
    if (anchorDistance <= 1e-7) return null;

    (SketchVector, double)? fit;
    var quality = SketchCircularFitQuality.geometricFallback;
    double? tangencyStartDegrees;
    double? tangencyEndDegrees;
    if (manualBoth) {
      // 2a. The two named references are geometric constraints, not hints: the
      //     oriented tangents give two normals, their intersection is the C1
      //     centre, and the weighted best fit refines it when noise keeps the
      //     endpoints off that circle.
      final startProbe = _neighborTangents(
        start,
        selectedIds,
        context,
        manualId: startTangencyId,
        proximity: tolerance.maxGapMillimeters,
      );
      if (startProbe.failure != null || startProbe.directions.length != 1) {
        return null;
      }
      final endProbe = _neighborTangents(
        end,
        selectedIds,
        context,
        manualId: endTangencyId,
        proximity: tolerance.maxGapMillimeters,
      );
      if (endProbe.failure != null || endProbe.directions.length != 1) {
        return null;
      }
      final startDirection = startProbe.directions.single.scale(-1);
      final endDirection = endProbe.directions.single;
      // A reference running back over the chain is rejected before solving.
      final startFlow = _chainDirectionInto(entities, start);
      if (startFlow != null && _isAntiAligned(startDirection, startFlow)) {
        return null;
      }
      final endFlow = _chainDirectionInto(entities, end)?.scale(-1);
      if (endFlow != null && _isAntiAligned(endDirection, endFlow)) {
        return null;
      }
      // Exact C1 centre: intersection of the two endpoint normals.
      final startNormal = SketchVector(-startDirection.y, startDirection.x);
      final endNormal = SketchVector(-endDirection.y, endDirection.x);
      final cross = startNormal.x * endNormal.y - startNormal.y * endNormal.x;
      final chord = end - start;
      final seeds = <(SketchVector, double)>[];
      if (cross.abs() > 1e-10) {
        final u = (chord.x * endNormal.y - chord.y * endNormal.x) / cross;
        final intersection = start + startNormal.scale(u);
        seeds.add((intersection, _distance(intersection, start)));
      }
      final endpointFit = _fitThroughEndpoints(points, start, end);
      if (endpointFit != null) seeds.add(endpointFit);
      final cloud = _fitCircle(points);
      if (cloud != null) seeds.add(cloud);
      if (seeds.isEmpty) return null;
      // Traversal sense of the arc, taken from the chain flow so a clockwise or
      // concave profile is measured exactly like a counter-clockwise one.
      final seedCenter = seeds.first.$1;
      var sense = 0.0;
      if (startFlow != null) {
        sense = _traversalSense(start, seedCenter, startFlow);
      }
      if (sense == 0 && endFlow != null) {
        sense = _traversalSense(end, seedCenter, endFlow);
      }
      if (sense == 0) sense = 1.0;
      final solved = _bestTangencyFit(
        points: points,
        start: start,
        startDirection: startDirection,
        end: end,
        endDirection: endDirection,
        sense: sense,
        seeds: seeds,
        tolerance: tolerance,
      );
      final measurement = _measureTangency(
        center: solved.$1,
        start: start,
        startDirection: startDirection,
        end: end,
        endDirection: endDirection,
        sense: sense,
        tolerance: tolerance,
      );
      tangencyStartDegrees = measurement.startDegrees;
      tangencyEndDegrees = measurement.endDegrees;
      if (measurement.failure != null) return null;
      final solvedAngles = _arcDefinition(boundary, anchor, solved.$1);
      if (solvedAngles == null) return null;
      final failure = _circularFitFailure(
        points: points,
        center: solved.$1,
        radius: solved.$2,
        start: start,
        end: end,
        sweep: solvedAngles.endAngle - solvedAngles.startAngle,
        tolerance: tolerance,
      );
      // Only degenerate geometry rejects here.  A poor radial agreement with
      // the selected regions is reported, because the tangency is the
      // constraint the user asked for.
      if (failure != null &&
          failure != SketchCircularFitFailure.fitErrorAboveTolerance) {
        return null;
      }
      final deviation = _radialError(points, solved.$1, solved.$2);
      if (deviation > tolerance.radialFor(solved.$2)) {
        warnings.add(
          'ajuste radial de ${deviation.toStringAsFixed(3)} mm acima da tolerância',
        );
      }
      fit = solved;
      quality = SketchCircularFitQuality.c1Bilateral;
    } else {
      // 2b. Otherwise the whole selected cloud estimates one arc that still
      //     passes through both external endpoints.  Tangency only labels the
      //     continuity; it never rejects an otherwise valid fit.
      final primary = _fitThroughEndpoints(points, start, end);
      if (primary == null) return null;
      fit = primary;
      final startProbe = _neighborTangents(
        start,
        selectedIds,
        context,
        manualId: startTangencyId,
        proximity: tolerance.maxGapMillimeters,
      );
      final endProbe = _neighborTangents(
        end,
        selectedIds,
        context,
        manualId: endTangencyId,
        proximity: tolerance.maxGapMillimeters,
      );
      // A branch on either extreme is a real ambiguity: two continuations
      // claim the same endpoint.
      if (startProbe.directions.length > 1 || endProbe.directions.length > 1) {
        return null;
      }
      final sides = _endpointTangency(
        center: primary.$1,
        start: start,
        startDirections: startProbe.directions,
        end: end,
        endDirections: endProbe.directions,
      );
      tangencyStartDegrees = sides.startDegrees;
      tangencyEndDegrees = sides.endDegrees;
      final limitDegrees = tolerance.tangencyAngleRadians * 180 / math.pi;
      final startTouches =
          sides.startDegrees != null && sides.startDegrees! <= limitDegrees;
      final endTouches =
          sides.endDegrees != null && sides.endDegrees! <= limitDegrees;
      quality = startTouches && endTouches
          ? SketchCircularFitQuality.c1Bilateral
          : (startTouches || endTouches
                ? SketchCircularFitQuality.c1Partial
                : SketchCircularFitQuality.geometricFallback);
    }

    final circularFit = fit;
    final angles = _arcDefinition(boundary, anchor, circularFit.$1);
    if (angles == null) return null;
    final failure = _circularFitFailure(
      points: points,
      center: circularFit.$1,
      radius: circularFit.$2,
      start: start,
      end: end,
      sweep: angles.endAngle - angles.startAngle,
      tolerance: tolerance,
    );
    if (failure != null) return null;
    final error = _radialError(points, circularFit.$1, circularFit.$2);
    final maximumError = _maxRadialError(
      points,
      circularFit.$1,
      circularFit.$2,
    );
    return SketchReconstructionSuggestion(
      kind: SketchReconstructionKind.arc,
      entityIds: entities.map((entity) => entity.id).toList(growable: false),
      confidence:
          (1 -
                  error /
                      math.max(
                        tolerance.radialFor(circularFit.$2),
                        tolerance.absoluteMillimeters,
                      ))
              .clamp(0.0, 1.0),
      center: circularFit.$1,
      radius: circularFit.$2,
      startAngle: angles.startAngle,
      endAngle: angles.endAngle,
      startPoint: angles.startPoint,
      endPoint: angles.endPoint,
      circularFitQuality: quality,
      warnings: warnings,
      maxGapMillimeters: selection.gaps.isEmpty
          ? 0.0
          : selection.gaps.reduce(math.max),
      tangencyStartDegrees: tangencyStartDegrees,
      tangencyEndDegrees: tangencyEndDegrees,
      usedEntityIds: selection.usedEntityIds,
      rmsError: error,
      maxError: maximumError,
      coveredEntityIds: context
          .where(
            (entity) =>
                !selectedIds.contains(entity.id) &&
                entity.visible &&
                _liesWhollyOnCircularSpan(
                  entity,
                  angles,
                  circularFit,
                  tolerance,
                ),
          )
          .map((entity) => entity.id)
          .toList(growable: false),
    );
  }

  /// True only when every sample is represented by this arc. Boundary curves
  /// which merely touch an endpoint deliberately remain visible.
  bool _liesWhollyOnCircularSpan(
    SketchEntity entity,
    ({
      double startAngle,
      double endAngle,
      SketchVector startPoint,
      SketchVector endPoint,
    })
    angles,
    (SketchVector, double) circle,
    SketchCircularFitTolerance tolerance,
  ) {
    final samples = _coverageSamples(entity);
    if (samples.length < 2) return false;
    final sweep = angles.endAngle - angles.startAngle;
    if (!sweep.isFinite || sweep <= 1e-7) return false;
    final radialTolerance = tolerance.radialFor(circle.$2);
    for (final point in samples) {
      final angle = math.atan2(point.y - circle.$1.y, point.x - circle.$1.x);
      if (_positiveSweep(angles.startAngle, angle) > sweep + 1e-6 ||
          (_distance(point, circle.$1) - circle.$2).abs() > radialTolerance) {
        return false;
      }
    }
    return true;
  }

  /// Adds an interior check for each stored segment.  A long chord can have
  /// both endpoints on a circle while its middle is far inside it, so endpoint
  /// only checks are not enough to safely hide a source fragment.
  List<SketchVector> _coverageSamples(SketchEntity entity) {
    final source = _entitySamples(entity);
    if (source.length < 2) return source;
    final samples = <SketchVector>[];
    for (var index = 0; index + 1 < source.length; index++) {
      final start = source[index];
      final end = source[index + 1];
      samples
        ..add(start)
        ..add((start + end).scale(.5));
    }
    samples.add(source.last);
    return samples;
  }

  /// Tangency angle, in degrees, of the circle at each endpoint that has a
  /// reference direction.  Both sides share the traversal sense of the arc.
  ({double? startDegrees, double? endDegrees}) _endpointTangency({
    required SketchVector center,
    required SketchVector start,
    required List<SketchVector> startDirections,
    required SketchVector end,
    required List<SketchVector> endDirections,
  }) {
    var sense = 0.0;
    if (startDirections.length == 1) {
      // The required departure at the start is the opposite of the neighbour
      // outward direction, and that is what fixes the traversal sense.
      sense = _traversalSense(start, center, startDirections.single.scale(-1));
    }
    if (sense == 0 && endDirections.length == 1) {
      sense = _traversalSense(end, center, endDirections.single);
    }
    if (sense == 0) sense = 1.0;
    double? degrees(SketchVector point, SketchVector direction) {
      final radians = _tangencyAngleRadians(point, center, direction, sense);
      return radians == null ? null : radians * 180 / math.pi;
    }

    return (
      startDegrees: startDirections.length == 1
          ? degrees(start, startDirections.single.scale(-1))
          : null,
      endDegrees: endDirections.length == 1
          ? degrees(end, endDirections.single)
          : null,
    );
  }

  /// Real tangency of the *final* arc geometry against the two named
  /// references, in degrees.
  ///
  /// It is deliberately measured on the created [SketchArc] (its stored centre
  /// and angles) and against the reference curves themselves, so a fit can
  /// never be reported as tangente just because the solver received the
  /// references.  The angle is the line angle, so the traversal sense does not
  /// hide a visible break.
  ({double startDegrees, double endDegrees})? measureCreatedArcTangency({
    required SketchArc arc,
    required SketchEntity startReference,
    required SketchEntity endReference,
    SketchCircularFitTolerance tolerance = const SketchCircularFitTolerance(),
  }) {
    final center = SketchVector.fromJson(arc.parameters['center']);
    final radius = (arc.parameters['radius'] as num).toDouble();
    final startAngle = (arc.parameters['startAngle'] as num).toDouble();
    final endAngle = (arc.parameters['endAngle'] as num).toDouble();
    if (!radius.isFinite || radius <= 0 || !center.x.isFinite) return null;
    SketchVector pointAt(double angle) => SketchVector(
      center.x + radius * math.cos(angle),
      center.y + radius * math.sin(angle),
    );

    SketchVector tangentAt(double angle) =>
        SketchVector(-math.sin(angle), math.cos(angle));
    double? degrees(double angle, SketchEntity reference, SketchVector point) {
      final direction =
          _endpointTangent(reference, point) ??
          _proximityTangent(reference, point, tolerance.maxGapMillimeters);
      if (direction == null) return null;
      final tangent = tangentAt(angle);
      final cosine =
          (tangent.dot(direction) /
                  (math.sqrt(tangent.dot(tangent)) *
                      math.sqrt(direction.dot(direction))))
              .abs()
              .clamp(0.0, 1.0);
      return math.acos(cosine) * 180 / math.pi;
    }

    final startDegrees = degrees(
      startAngle,
      startReference,
      pointAt(startAngle),
    );
    final endDegrees = degrees(endAngle, endReference, pointAt(endAngle));
    if (startDegrees == null || endDegrees == null) return null;
    return (startDegrees: startDegrees, endDegrees: endDegrees);
  }

  /// Explains why a manual circular fit could not be proposed.  This mirrors
  /// the conservative fit gates so the UI can distinguish geometric input
  /// errors from a genuine C1 incompatibility.
  SketchCircularFitFailure diagnoseSelectedCircular(
    Iterable<SketchEntity> selected, {
    Iterable<SketchEntity> context = const <SketchEntity>[],
    String? startTangencyId,
    String? endTangencyId,
    SketchCircularFitTolerance tolerance = const SketchCircularFitTolerance(),
  }) => diagnoseSelectedCircularDetailed(
    selected,
    context: context,
    startTangencyId: startTangencyId,
    endTangencyId: endTangencyId,
    tolerance: tolerance,
  ).failure;

  /// Same diagnosis as [diagnoseSelectedCircular], plus the measured numbers
  /// the panel has to display: largest gap, tangency angles and radius.
  SketchCircularFitDiagnosis diagnoseSelectedCircularDetailed(
    Iterable<SketchEntity> selected, {
    Iterable<SketchEntity> context = const <SketchEntity>[],
    String? startTangencyId,
    String? endTangencyId,
    SketchCircularFitTolerance tolerance = const SketchCircularFitTolerance(),
  }) {
    final entities = selected.toList(growable: false);
    if (entities.isEmpty ||
        entities.length > SketchCircularFitTolerance.maxRegions) {
      return const SketchCircularFitDiagnosis(
        SketchCircularFitFailure.invalidChain,
      );
    }
    final order = _orderSelection(entities, tolerance);
    if (order.failure != null) {
      return SketchCircularFitDiagnosis(order.failure!);
    }
    final selection = order.selection;
    if (selection == null) {
      return const SketchCircularFitDiagnosis(
        SketchCircularFitFailure.invalidChain,
      );
    }
    final points = selection.points;
    final maxGap = selection.gaps.isEmpty
        ? 0.0
        : selection.gaps.reduce(math.max);
    if (points.length < 3) {
      return SketchCircularFitDiagnosis(
        SketchCircularFitFailure.insufficientPoints,
        maxGapMillimeters: maxGap,
      );
    }
    final start = selection.start;
    final end = selection.end;
    final boundary = (start: start, end: end);
    final selectedIds = entities.map((entity) => entity.id).toSet();
    var anchor = points.first;
    var anchorDistance = _distanceToLine(anchor, start, end);
    for (final point in points) {
      final distance = _distanceToLine(point, start, end);
      if (distance > anchorDistance) {
        anchor = point;
        anchorDistance = distance;
      }
    }
    if (anchorDistance <= 1e-7) {
      return SketchCircularFitDiagnosis(
        SketchCircularFitFailure.collinearPoints,
        maxGapMillimeters: maxGap,
      );
    }
    final manualBoth = startTangencyId != null && endTangencyId != null;
    final startProbe = _neighborTangents(
      start,
      selectedIds,
      context,
      manualId: startTangencyId,
      proximity: tolerance.maxGapMillimeters,
    );
    final endProbe = _neighborTangents(
      end,
      selectedIds,
      context,
      manualId: endTangencyId,
      proximity: tolerance.maxGapMillimeters,
    );
    if (startProbe.failure != null) {
      return SketchCircularFitDiagnosis(
        startProbe.failure!,
        maxGapMillimeters: maxGap,
      );
    }
    if (endProbe.failure != null) {
      return SketchCircularFitDiagnosis(
        endProbe.failure!,
        maxGapMillimeters: maxGap,
      );
    }
    // A branch on either extreme is a real ambiguity: two continuations claim
    // the same endpoint, so no single tangent circle is defined.
    if (startProbe.directions.length > 1 || endProbe.directions.length > 1) {
      return SketchCircularFitDiagnosis(
        SketchCircularFitFailure.ambiguousBranch,
        maxGapMillimeters: maxGap,
      );
    }
    if (manualBoth &&
        startProbe.directions.length == 1 &&
        endProbe.directions.length == 1) {
      // A reference running back over the chain is inverted, not a tangency
      // mismatch: report it as such before measuring angles.
      final startFlow = _chainDirectionInto(entities, start);
      final startDirection = startProbe.directions.single.scale(-1);
      if (startFlow != null && _isAntiAligned(startDirection, startFlow)) {
        return SketchCircularFitDiagnosis(
          SketchCircularFitFailure.reversedTangency,
          maxGapMillimeters: maxGap,
        );
      }
      final endFlow = _chainDirectionInto(entities, end)?.scale(-1);
      if (endFlow != null &&
          _isAntiAligned(endProbe.directions.single, endFlow)) {
        return SketchCircularFitDiagnosis(
          SketchCircularFitFailure.reversedTangency,
          maxGapMillimeters: maxGap,
        );
      }
    }
    final fit = _fitThroughEndpoints(points, start, end);
    if (fit == null) {
      return SketchCircularFitDiagnosis(
        SketchCircularFitFailure.fitErrorAboveTolerance,
        maxGapMillimeters: maxGap,
      );
    }
    final angles = _arcDefinition(boundary, anchor, fit.$1);
    if (angles == null) {
      return SketchCircularFitDiagnosis(
        SketchCircularFitFailure.invalidSweep,
        maxGapMillimeters: maxGap,
        radius: fit.$2,
      );
    }
    final failure = _circularFitFailure(
      points: points,
      center: fit.$1,
      radius: fit.$2,
      start: start,
      end: end,
      sweep: angles.endAngle - angles.startAngle,
      tolerance: tolerance,
    );
    final sides = _endpointTangency(
      center: fit.$1,
      start: start,
      startDirections: startProbe.directions,
      end: end,
      endDirections: endProbe.directions,
    );
    final limitDegrees = tolerance.tangencyAngleRadians * 180 / math.pi;
    if (manualBoth) {
      final startTouches =
          sides.startDegrees != null && sides.startDegrees! <= limitDegrees;
      final endTouches =
          sides.endDegrees != null && sides.endDegrees! <= limitDegrees;
      if (!startTouches || !endTouches) {
        return SketchCircularFitDiagnosis(
          SketchCircularFitFailure.incompatibleTangency,
          maxGapMillimeters: maxGap,
          tangencyStartDegrees: sides.startDegrees,
          tangencyEndDegrees: sides.endDegrees,
          radius: fit.$2,
        );
      }
    }
    if (failure != null) {
      return SketchCircularFitDiagnosis(
        failure,
        maxGapMillimeters: maxGap,
        tangencyStartDegrees: sides.startDegrees,
        tangencyEndDegrees: sides.endDegrees,
        radius: fit.$2,
      );
    }
    // Nothing is wrong: this entry point only explains a rejected fit.
    return SketchCircularFitDiagnosis(
      SketchCircularFitFailure.invalidChain,
      maxGapMillimeters: maxGap,
      tangencyStartDegrees: sides.startDegrees,
      tangencyEndDegrees: sides.endDegrees,
      radius: fit.$2,
    );
  }

  /// Ordered samples of one selected region, following the entity's own
  /// direction: line endpoints, analytic arc samples that respect the
  /// clockwise/counter-clockwise sweep, or the spline sampled points.
  List<SketchVector> _entitySamples(SketchEntity entity) {
    if (entity is SketchLine) {
      return <SketchVector>[
        SketchVector.fromJson(entity.parameters['start']),
        SketchVector.fromJson(entity.parameters['end']),
      ];
    }
    if (entity is SketchArc) {
      final center = SketchVector.fromJson(entity.parameters['center']);
      final radius = (entity.parameters['radius'] as num).toDouble();
      final startAngle = (entity.parameters['startAngle'] as num).toDouble();
      final endAngle = (entity.parameters['endAngle'] as num).toDouble();
      if (!radius.isFinite || radius <= 0) return const <SketchVector>[];
      final sweep = endAngle - startAngle;
      final steps = (sweep.abs() / 0.1).ceil().clamp(2, 64);
      return <SketchVector>[
        for (var index = 0; index <= steps; index++)
          SketchVector(
            center.x + radius * math.cos(startAngle + sweep * index / steps),
            center.y + radius * math.sin(startAngle + sweep * index / steps),
          ),
      ];
    }
    if (entity is SketchSpline) {
      final samples = _splinePoints(entity);
      if (samples.length >= 2) return samples;
      final raw = entity.parameters['points'];
      if (raw is! List) return const <SketchVector>[];
      return raw.whereType<List>().map(SketchVector.fromJson).toList();
    }
    return const <SketchVector>[];
  }

  /// Orders [entities] by proximity and returns the external endpoints of the
  /// whole set.
  ///
  /// The two farthest region endpoints anchor the walk, then every remaining
  /// region is appended from the closest free endpoint.  Consecutive gaps are
  /// reported so callers can warn about (or reject) a split selection; the
  /// regions are never joined with an artificial segment.
  _SelectionOrder _orderSelection(
    List<SketchEntity> entities,
    SketchCircularFitTolerance tolerance,
  ) {
    final regions = <List<SketchVector>>[];
    var total = 0;
    final ids = <String>[];
    for (final entity in entities) {
      final samples = _entitySamples(entity);
      if (samples.length < 2) continue;
      total += samples.length;
      if (total > SketchCircularFitTolerance.maxSamples) {
        return const _SelectionOrder(
          null,
          SketchCircularFitFailure.invalidChain,
        );
      }
      ids.add(entity.id);
      regions.add(samples);
    }
    if (regions.isEmpty) {
      return const _SelectionOrder(null, SketchCircularFitFailure.invalidChain);
    }
    if (regions.length == 1) {
      final only = regions.single;
      return _SelectionOrder(
        _OrderedSelection(
          regions: regions,
          start: only.first,
          end: only.last,
          gaps: const <double>[],
          usedEntityIds: ids,
        ),
      );
    }

    // Farthest pair among the region endpoints: it gives the span that sizes
    // the relative gap budget and is the fallback for the external extremes.
    var startRegion = 0;
    var startAtLast = false;
    var endRegion = 1;
    var endAtLast = true;
    var farthest = -1.0;
    for (var first = 0; first < regions.length; first++) {
      for (var firstLast = 0; firstLast < 2; firstLast++) {
        final firstPoint = firstLast == 0
            ? regions[first].first
            : regions[first].last;
        for (var second = first + 1; second < regions.length; second++) {
          for (var secondLast = 0; secondLast < 2; secondLast++) {
            final secondPoint = secondLast == 0
                ? regions[second].first
                : regions[second].last;
            final distance = _distance(firstPoint, secondPoint);
            if (distance > farthest) {
              farthest = distance;
              startRegion = first;
              startAtLast = firstLast == 1;
              endRegion = second;
              endAtLast = secondLast == 1;
            }
          }
        }
      }
    }
    // The farthest pair can be a diagonal of a U shaped selection.  A real
    // external endpoint is a region end with no other region end within the
    // effective gap, which identifies the two free ends of the walk.  When
    // exactly two of those exist they win over the diagonal.
    // Gaps are measured, never blocking: a selected region that is far from
    // its neighbours still contributes its samples to the global fit.  Only
    // the endpoint coincidence test below uses a distance, and it is a
    // numerical threshold, not a gap budget.
    final coincidence = math.max(
      tolerance.endpointCoincidenceMillimeters,
      1e-6,
    );
    final ends = <({int region, bool atLast, SketchVector point})>[
      for (var index = 0; index < regions.length; index++) ...[
        (region: index, atLast: false, point: regions[index].first),
        (region: index, atLast: true, point: regions[index].last),
      ],
    ];
    final freeEnds = <({int region, bool atLast, SketchVector point})>[];
    for (var index = 0; index < ends.length; index++) {
      var connected = false;
      for (var other = 0; other < ends.length; other++) {
        if (other == index) continue;
        if (ends[other].region == ends[index].region) continue;
        if (_distance(ends[index].point, ends[other].point) <= coincidence) {
          connected = true;
          break;
        }
      }
      if (!connected) freeEnds.add(ends[index]);
    }
    if (freeEnds.length == 2 && freeEnds.first.region != freeEnds.last.region) {
      startRegion = freeEnds.first.region;
      startAtLast = freeEnds.first.atLast;
      endRegion = freeEnds.last.region;
      endAtLast = freeEnds.last.atLast;
    } else if (endRegion == startRegion) {
      // Degenerate fallback: keep the farthest pair on different regions.
      endRegion = startRegion == 0 ? 1 : 0;
      endAtLast = false;
    }

    List<SketchVector> orient(
      List<SketchVector> region, {
      required bool atLast,
    }) {
      if (!atLast) return region;
      return region.reversed.toList(growable: false);
    }

    final ordered = <List<SketchVector>>[
      orient(regions[startRegion], atLast: startAtLast),
    ];
    final usedIds = <String>[ids[startRegion]];
    // The far extreme is pinned, so the walk can never end somewhere else.
    final endSamples = orient(regions[endRegion], atLast: !endAtLast);
    final pending = <int>[
      for (var index = 0; index < regions.length; index++)
        if (index != startRegion && index != endRegion) index,
    ];
    final gaps = <double>[];
    while (pending.isNotEmpty) {
      final tail = ordered.last.last;
      var bestIndex = 0;
      var bestAtLast = false;
      var bestDistance = double.infinity;
      for (var slot = 0; slot < pending.length; slot++) {
        final region = regions[pending[slot]];
        final headDistance = _distance(tail, region.first);
        if (headDistance < bestDistance) {
          bestDistance = headDistance;
          bestIndex = slot;
          bestAtLast = false;
        }
        final tailDistance = _distance(tail, region.last);
        if (tailDistance < bestDistance) {
          bestDistance = tailDistance;
          bestIndex = slot;
          bestAtLast = true;
        }
      }
      gaps.add(bestDistance);
      final nextRegion = pending.removeAt(bestIndex);
      ordered.add(orient(regions[nextRegion], atLast: bestAtLast));
      usedIds.add(ids[nextRegion]);
    }
    // Close the chain on the far extreme found by the initial search.
    final lastGap = _distance(ordered.last.last, endSamples.first);
    gaps.add(lastGap);
    ordered.add(endSamples);
    usedIds.add(ids[endRegion]);
    return _SelectionOrder(
      _OrderedSelection(
        regions: ordered,
        start: ordered.first.first,
        end: ordered.last.last,
        gaps: gaps,
        usedEntityIds: usedIds,
      ),
    );
  }

  /// Circle through both preserved endpoints that best fits every sample.
  ///
  /// The centre is searched along the perpendicular bisector of the external
  /// endpoints, so the two external endpoints stay exactly on the arc while the
  /// interior samples of all selected regions drive the radius.  The algebraic
  /// least squares circle seeds the search.
  (SketchVector, double)? _fitThroughEndpoints(
    List<SketchVector> points,
    SketchVector start,
    SketchVector end,
  ) {
    final axis = end - start;
    final axisLength = math.sqrt(axis.dot(axis));
    if (!axisLength.isFinite || axisLength <= 1e-9) return null;
    final bisector = SketchVector(-axis.y / axisLength, axis.x / axisLength);
    final midpoint = start + axis.scale(.5);
    final d0 = axisLength * axisLength / 4;
    final seed = _fitCircle(points);
    final preferred = seed == null ? 0.0 : (seed.$1 - midpoint).dot(bisector);
    var extent = 1.0;
    for (final point in points) {
      extent = math.max(extent, _distance(point, midpoint));
    }
    final offset = _bestBisectorOffset(
      points: points,
      midpoint: midpoint,
      bisector: bisector,
      d0: d0,
      preferred: preferred,
      span: 4 * (math.max(extent, preferred.abs()) + 1),
    );
    final center = midpoint + bisector.scale(offset);
    final radius = math.sqrt(d0 + offset * offset);
    if (!radius.isFinite || radius <= 0) return null;
    return (center, radius);
  }

  /// Offset along the bisector that minimises the squared radial error of
  /// [points] about the circle `center(t) = midpoint + t * bisector` with
  /// `radius(t) = sqrt(d0 + t^2)`.
  ///
  /// A coarse scan brackets the global minimum (the family has two mirror
  /// branches) and a golden section refines it.
  double _bestBisectorOffset({
    required List<SketchVector> points,
    required SketchVector midpoint,
    required SketchVector bisector,
    required double d0,
    required double preferred,
    required double span,
  }) {
    double error(double t) {
      final center = midpoint + bisector.scale(t);
      final radius = math.sqrt(d0 + t * t);
      var sum = 0.0;
      for (final point in points) {
        final delta = _distance(point, center) - radius;
        sum += delta * delta;
      }
      return sum;
    }

    const steps = 48;
    var best = preferred;
    var bestError = error(best);
    for (var index = -steps; index <= steps; index++) {
      final candidate = preferred + span * index / steps;
      final value = error(candidate);
      if (value < bestError) {
        bestError = value;
        best = candidate;
      }
    }
    var low = best - span / steps;
    var high = best + span / steps;
    const ratio = 0.6180339887498949;
    var left = high - (high - low) * ratio;
    var right = low + (high - low) * ratio;
    var leftError = error(left);
    var rightError = error(right);
    for (var iteration = 0; iteration < 48; iteration++) {
      if (leftError < rightError) {
        high = right;
        right = left;
        rightError = leftError;
        left = high - (high - low) * ratio;
        leftError = error(left);
      } else {
        low = left;
        left = right;
        leftError = rightError;
        right = low + (high - low) * ratio;
        rightError = error(right);
      }
    }
    return (low + high) / 2;
  }

  /// Root mean square radial error of [points] about the fitted circle.
  double _radialError(
    List<SketchVector> points,
    SketchVector center,
    double radius,
  ) {
    if (points.isEmpty) return double.infinity;
    var sum = 0.0;
    for (final point in points) {
      final delta = _distance(point, center) - radius;
      sum += delta * delta;
    }
    return math.sqrt(sum / points.length);
  }

  double _maxRadialError(
    List<SketchVector> points,
    SketchVector center,
    double radius,
  ) => points
      .map((point) => (_distance(point, center) - radius).abs())
      .fold<double>(0, math.max);

  /// Largest perpendicular distance of [points] from the chord
  /// [start] -> [end]: the empirical sagitta that tells an arc from a line.
  double _sagitta(
    List<SketchVector> points,
    SketchVector start,
    SketchVector end,
  ) {
    var value = 0.0;
    for (final point in points) {
      value = math.max(value, _distanceToLine(point, start, end));
    }
    return value;
  }

  /// Acceptance gates for a fitted arc, split so the caller can report the
  /// exact cause instead of a generic unstable radius.
  SketchCircularFitFailure? _circularFitFailure({
    required List<SketchVector> points,
    required SketchVector center,
    required double radius,
    required SketchVector start,
    required SketchVector end,
    required double sweep,
    required SketchCircularFitTolerance tolerance,
  }) {
    if (!center.x.isFinite ||
        !center.y.isFinite ||
        !radius.isFinite ||
        radius <= 0) {
      return SketchCircularFitFailure.unstableRadius;
    }
    // Radius shorter than the geometric tolerance is not a usable arc.
    if (radius < tolerance.minRadiusMillimeters) {
      return SketchCircularFitFailure.unstableRadius;
    }
    if (!sweep.isFinite || sweep <= 1e-4 || sweep > 2 * math.pi + 1e-6) {
      return SketchCircularFitFailure.invalidSweep;
    }
    // A straight selection can always be covered by an enormous circle; only
    // the sagitta decides, never the radius/length ratio.
    final span = _distance(start, end);
    final collinearThreshold = math.max(
      tolerance.collinearMillimeters,
      span * tolerance.collinearRelativeToSpan,
    );
    if (_sagitta(points, start, end) <= collinearThreshold) {
      return SketchCircularFitFailure.collinearPoints;
    }
    if (_radialError(points, center, radius) > tolerance.radialFor(radius)) {
      return SketchCircularFitFailure.fitErrorAboveTolerance;
    }
    return null;
  }

  /// Tangent of [entity] at its point closest to [endpoint], oriented away
  /// from that endpoint.  Used for manual references that are near the arc end
  /// without being topologically connected to it.
  SketchVector? _proximityTangent(
    SketchEntity entity,
    SketchVector endpoint,
    double tolerance,
  ) {
    final samples = _entitySamples(entity);
    if (samples.length < 2) return null;
    var bestIndex = 0;
    var bestDistance = double.infinity;
    for (var index = 0; index < samples.length; index++) {
      final distance = _distance(samples[index], endpoint);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = index;
      }
    }
    if (!bestDistance.isFinite || bestDistance > tolerance) return null;
    // Local direction along the entity at the closest sample.
    SketchVector direction;
    if (bestIndex == 0) {
      direction = samples[1] - samples[0];
    } else if (bestIndex == samples.length - 1) {
      direction = samples[samples.length - 1] - samples[samples.length - 2];
    } else {
      direction = samples[bestIndex + 1] - samples[bestIndex - 1];
    }
    if (direction.dot(direction) <= 1e-20) {
      // Fall back to any non degenerate step of the entity.
      for (var index = 0; index + 1 < samples.length; index++) {
        final step = samples[index + 1] - samples[index];
        if (step.dot(step) > 1e-20) {
          direction = step;
          break;
        }
      }
    }
    if (direction.dot(direction) <= 1e-20) return null;
    // Point it away from the arc endpoint into the neighbouring curve, so it
    // plays the same role as a connected neighbour tangent.  The bulk of the
    // reference decides, which also works for a reference offset sideways.
    final bulk = (samples.first + samples.last).scale(.5);
    if ((bulk - endpoint).dot(direction) < 0) {
      direction = direction.scale(-1);
    }
    return direction;
  }

  ({
    double startAngle,
    double endAngle,
    SketchVector startPoint,
    SketchVector endPoint,
  })?
  _arcDefinition(
    ({SketchVector start, SketchVector end}) boundary,
    SketchVector anchor,
    SketchVector center,
  ) {
    final startAngle = math.atan2(
      boundary.start.y - center.y,
      boundary.start.x - center.x,
    );
    final endAngle = math.atan2(
      boundary.end.y - center.y,
      boundary.end.x - center.x,
    );
    final anchorAngle = math.atan2(anchor.y - center.y, anchor.x - center.x);
    final ccwSweep = _positiveSweep(startAngle, endAngle);
    final startContainsAnchor =
        _positiveSweep(startAngle, anchorAngle) <= ccwSweep + 1e-7;
    final arcStart = startContainsAnchor ? startAngle : endAngle;
    final sweep = startContainsAnchor
        ? ccwSweep
        : _positiveSweep(endAngle, startAngle);
    // Only a degenerate sweep is invalid here; the span check that used to
    // reject shallow arcs now lives in the sagitta/error gates, which do not
    // care about the radius/length ratio.
    if (!sweep.isFinite || sweep <= 1e-4) return null;
    return (
      startAngle: arcStart,
      endAngle: arcStart + sweep,
      startPoint: startContainsAnchor ? boundary.start : boundary.end,
      endPoint: startContainsAnchor ? boundary.end : boundary.start,
    );
  }

  /// Tangent that leaves a supported curve at [endpoint].  At the entity's
  /// final endpoint the derivative is inverted, so callers always receive a
  /// direction pointing away from the shared vertex into the neighbouring
  /// curve.
  SketchVector? _endpointTangent(SketchEntity entity, SketchVector endpoint) {
    SketchVector? direction;
    if (entity is SketchLine) {
      final start = SketchVector.fromJson(entity.parameters['start']);
      final end = SketchVector.fromJson(entity.parameters['end']);
      if (_distance(start, endpoint) <= 1e-7) {
        direction = end - start;
      } else if (_distance(end, endpoint) <= 1e-7) {
        direction = start - end;
      }
    } else if (entity is SketchArc) {
      final center = SketchVector.fromJson(entity.parameters['center']);
      final radius = (entity.parameters['radius'] as num).toDouble();
      final startAngle = (entity.parameters['startAngle'] as num).toDouble();
      final endAngle = (entity.parameters['endAngle'] as num).toDouble();
      final start = SketchVector(
        center.x + radius * math.cos(startAngle),
        center.y + radius * math.sin(startAngle),
      );
      final end = SketchVector(
        center.x + radius * math.cos(endAngle),
        center.y + radius * math.sin(endAngle),
      );
      final delta = endAngle - startAngle;
      if (delta.abs() <= 1e-12) return null;
      final sign = delta.isNegative ? -1.0 : 1.0;
      if (_distance(start, endpoint) <= 1e-7) {
        direction = SketchVector(
          -math.sin(startAngle) * sign,
          math.cos(startAngle) * sign,
        );
      } else if (_distance(end, endpoint) <= 1e-7) {
        direction = SketchVector(
          math.sin(endAngle) * sign,
          -math.cos(endAngle) * sign,
        );
      }
    } else if (entity is SketchSpline) {
      final raw =
          (entity.parameters['sampledPoints'] ?? entity.parameters['points'])
              as List?;
      final samples =
          raw?.whereType<List>().map(SketchVector.fromJson).toList() ??
          const <SketchVector>[];
      if (samples.length >= 2) {
        if (_distance(samples.first, endpoint) <= 1e-7) {
          direction = samples[1] - samples.first;
        } else if (_distance(samples.last, endpoint) <= 1e-7) {
          direction = samples[samples.length - 2] - samples.last;
        }
      }
    }
    if (direction == null || direction.dot(direction) <= 1e-20) return null;
    return direction;
  }

  /// Tangents leaving [endpoint] into the neighbouring curves.
  ///
  /// True when [first] runs back over [second] instead of continuing it.
  ///
  /// Only the coarse "opposite way" decision is made here, using
  /// [_invertedReferenceCosine]: the chain direction is a chord estimate, so a
  /// precision comparison would misfire on Section polylines.
  bool _isAntiAligned(SketchVector first, SketchVector second) {
    final firstLength = math.sqrt(first.dot(first));
    final secondLength = math.sqrt(second.dot(second));
    if (firstLength <= 1e-10 || secondLength <= 1e-10) return false;
    return first.dot(second) / (firstLength * secondLength) <=
        _invertedReferenceCosine;
  }

  /// Local direction of the selected chain at [point], pointing into the chain.
  ///
  /// It tells a real continuation from a reference that is attached to the
  /// endpoint but runs back over the chain ("inverted").
  SketchVector? _chainDirectionInto(
    List<SketchEntity> entities,
    SketchVector point,
  ) {
    for (final entity in entities) {
      final samples = _entitySamples(entity);
      if (samples.length < 2) continue;
      if (_distance(samples.first, point) <= 1e-7) {
        return samples[1] - samples.first;
      }
      if (_distance(samples.last, point) <= 1e-7) {
        return samples[samples.length - 2] - samples.last;
      }
    }
    return null;
  }

  /// Tangents leaving [endpoint] into the neighbouring curves.
  ///
  /// With [manualId] the caller named the curve explicitly, so the result is
  /// either exactly that oriented tangent or a failure explaining why the
  /// reference cannot drive this extremity.  Without it the neighbours are
  /// inferred from every visible curve that touches [endpoint].
  _NeighborProbe _neighborTangents(
    SketchVector endpoint,
    Set<String> selectedIds,
    Iterable<SketchEntity> context, {
    String? manualId,
    double proximity = 0.5,
  }) {
    if (manualId != null) {
      SketchEntity? reference;
      for (final entity in context) {
        if (entity.id == manualId) {
          reference = entity;
          break;
        }
      }
      if (reference == null) {
        return const _NeighborProbe(
          <SketchVector>[],
          SketchCircularFitFailure.invalidChain,
        );
      }
      // A reference that is itself part of the chain being replaced is not a
      // neighbour: the command must never confuse the two roles.
      if (selectedIds.contains(reference.id)) {
        return const _NeighborProbe(
          <SketchVector>[],
          SketchCircularFitFailure.disconnectedTangency,
        );
      }
      // A reference connected to the endpoint keeps the exact endpoint
      // tangent; a nearby reference only has to be close enough to the
      // corresponding extreme, which is what mesh Section gaps look like.
      final direction =
          _endpointTangent(reference, endpoint) ??
          _proximityTangent(reference, endpoint, proximity);
      if (direction == null) {
        return const _NeighborProbe(
          <SketchVector>[],
          SketchCircularFitFailure.disconnectedTangency,
        );
      }
      return _NeighborProbe(<SketchVector>[direction]);
    }
    return _NeighborProbe(
      context
          .where((entity) => !selectedIds.contains(entity.id) && entity.visible)
          .map((entity) => _endpointTangent(entity, endpoint))
          .whereType<SketchVector>()
          .toList(growable: false),
    );
  }

  /// Traversal sense of the arc about [center] implied by [flow] at [point]:
  /// `1` counter-clockwise, `-1` clockwise, `0` when undefined.
  ///
  /// The sense comes from the chain (or from the reference direction), never
  /// from an assumed counter-clockwise arc, which is what lets concave and
  /// clockwise profiles validate exactly like counter-clockwise ones.
  double _traversalSense(
    SketchVector point,
    SketchVector center,
    SketchVector flow,
  ) {
    final radius = point - center;
    final radiusLength = math.sqrt(radius.dot(radius));
    final flowLength = math.sqrt(flow.dot(flow));
    if (radiusLength <= 1e-10 || flowLength <= 1e-10) return 0;
    final ccw = SketchVector(-radius.y / radiusLength, radius.x / radiusLength);
    final projection = ccw.dot(flow) / flowLength;
    if (projection.abs() <= 1e-9) return 0;
    return projection.sign;
  }

  /// Angle in radians between the arc tangent at [point] and the oriented
  /// [direction], for the given traversal [sense].
  ///
  /// This is the real tangency measure: zero means the arc leaves (or arrives
  /// at) the endpoint exactly along the reference curve, which is what C1
  /// requires.  `null` when either vector is degenerate.
  double? _tangencyAngleRadians(
    SketchVector point,
    SketchVector center,
    SketchVector direction,
    double sense,
  ) {
    final radius = point - center;
    final radiusLength = math.sqrt(radius.dot(radius));
    final directionLength = math.sqrt(direction.dot(direction));
    if (radiusLength <= 1e-10 || directionLength <= 1e-10) return null;
    final tangent = SketchVector(
      -radius.y / radiusLength * sense,
      radius.x / radiusLength * sense,
    );
    final cosine = (tangent.dot(direction) / directionLength).clamp(-1.0, 1.0);
    return math.acos(cosine);
  }

  /// Tangency of a candidate circle at both preserved endpoints, in degrees.
  _TangencyMeasurement _measureTangency({
    required SketchVector center,
    required SketchVector start,
    required SketchVector startDirection,
    required SketchVector end,
    required SketchVector endDirection,
    required double sense,
    required SketchCircularFitTolerance tolerance,
  }) {
    final usedSense = sense == 0
        ? (_traversalSense(start, center, startDirection) != 0
              ? _traversalSense(start, center, startDirection)
              : (_traversalSense(end, center, endDirection) != 0
                    ? _traversalSense(end, center, endDirection)
                    : 1.0))
        : sense;
    final startRadians =
        _tangencyAngleRadians(start, center, startDirection, usedSense) ??
        math.pi;
    final endRadians =
        _tangencyAngleRadians(end, center, endDirection, usedSense) ?? math.pi;
    final limit = tolerance.tangencyAngleRadians;
    return _TangencyMeasurement(
      startDegrees: startRadians * 180 / math.pi,
      endDegrees: endRadians * 180 / math.pi,
      failure: startRadians > limit || endRadians > limit
          ? SketchCircularFitFailure.incompatibleTangency
          : null,
    );
  }

  /// Best fit circle when the exact normal intersection cannot satisfy both
  /// endpoints and both tangency angles.
  ///
  /// The cost is the weighted sum of the three errors the command has to trade
  /// off, normalised by their tolerances so the endpoint position and the
  /// tangency angles dominate the radial agreement with the selected regions:
  ///   (a) endpoint position error: (|c-start|-r)² + (|c-end|-r)²
  ///   (b) tangency angular error: θ(start)² + θ(end)²
  ///   (c) radial error against every selected sample
  ///
  /// For a fixed centre the optimal radius has a closed form, so only the
  /// centre is searched, with a deterministic compass search from the given
  /// seeds.
  (SketchVector, double) _bestTangencyFit({
    required List<SketchVector> points,
    required SketchVector start,
    required SketchVector startDirection,
    required SketchVector end,
    required SketchVector endDirection,
    required double sense,
    required Iterable<(SketchVector, double)> seeds,
    required SketchCircularFitTolerance tolerance,
  }) {
    final positionTolerance = math.max(
      tolerance.absoluteMillimeters * 0.04,
      1e-9,
    );
    final angleTolerance = math.max(tolerance.tangencyAngleRadians, 1e-9);
    final positionWeight = 1 / (positionTolerance * positionTolerance);
    final angleWeight = 1 / (angleTolerance * angleTolerance);

    double optimalRadius(SketchVector center, double radialWeight) {
      final first = _distance(center, start);
      final last = _distance(center, end);
      var sum = 0.0;
      for (final point in points) {
        sum += _distance(center, point);
      }
      final mean = points.isEmpty ? 0.0 : sum / points.length;
      final denominator = 2 * positionWeight + radialWeight;
      if (!denominator.isFinite || denominator <= 0) return first;
      return (positionWeight * (first + last) + radialWeight * mean) /
          denominator;
    }

    double cost(SketchVector center) {
      final radialWeight =
          1 /
          _squared(
            math.max(tolerance.radialFor(_distance(center, start)), 1e-9),
          );
      final radius = optimalRadius(center, radialWeight);
      var value = 0.0;
      value += positionWeight * _squared(_distance(center, start) - radius);
      value += positionWeight * _squared(_distance(center, end) - radius);
      final startAngle =
          _tangencyAngleRadians(start, center, startDirection, sense) ??
          math.pi;
      final endAngle =
          _tangencyAngleRadians(end, center, endDirection, sense) ?? math.pi;
      value += angleWeight * startAngle * startAngle;
      value += angleWeight * endAngle * endAngle;
      if (points.isNotEmpty) {
        var radial = 0.0;
        for (final point in points) {
          radial += _squared(_distance(point, center) - radius);
        }
        value += radialWeight * radial / points.length;
      }
      return value;
    }

    var bestCenter = start;
    var bestRadius = 0.0;
    var bestCost = double.infinity;
    for (final seed in seeds) {
      if (!seed.$1.x.isFinite || !seed.$1.y.isFinite) continue;
      final value = cost(seed.$1);
      if (value < bestCost) {
        bestCost = value;
        bestCenter = seed.$1;
        bestRadius = seed.$2;
      }
    }
    for (final seed in seeds) {
      var center = seed.$1;
      if (!center.x.isFinite || !center.y.isFinite) continue;
      var value = cost(center);
      var step = math.max(1.0, seed.$2 * 0.25);
      for (var iteration = 0; iteration < 72; iteration++) {
        var improved = false;
        for (final move in const <List<double>>[
          <double>[1, 0],
          <double>[-1, 0],
          <double>[0, 1],
          <double>[0, -1],
          <double>[1, 1],
          <double>[-1, 1],
          <double>[1, -1],
          <double>[-1, -1],
        ]) {
          final candidate = SketchVector(
            center.x + move[0] * step,
            center.y + move[1] * step,
          );
          final candidateCost = cost(candidate);
          if (candidateCost < value - 1e-12) {
            value = candidateCost;
            center = candidate;
            improved = true;
          }
        }
        if (!improved) {
          step *= 0.5;
          if (step <= 1e-7) break;
        }
      }
      if (value < bestCost) {
        bestCost = value;
        bestCenter = center;
        bestRadius = optimalRadius(
          center,
          1 /
              _squared(
                math.max(tolerance.radialFor(_distance(center, start)), 1e-9),
              ),
        );
      }
    }

    if (bestRadius <= 0 || !bestRadius.isFinite) {
      bestRadius = _distance(bestCenter, start);
    }
    return (bestCenter, bestRadius);
  }

  double _squared(double value) => value * value;

  double _distanceToLine(
    SketchVector point,
    SketchVector start,
    SketchVector end,
  ) {
    final dx = end.x - start.x, dy = end.y - start.y;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length <= 1e-12) return 0;
    return ((point.x - start.x) * dy - (point.y - start.y) * dx).abs() / length;
  }

  double _positiveSweep(double start, double end) {
    var value = end - start;
    while (value < 0) {
      value += 2 * math.pi;
    }
    while (value >= 2 * math.pi) {
      value -= 2 * math.pi;
    }
    return value;
  }

  List<SketchReconstructionSuggestion> analyze(
    Iterable<SketchEntity> entities, {
    double angularTolerance = 0.035,
  }) {
    // Recognition receives a snapshot from the document, so stale callers
    // can still hand us repeated IDs, removed entities or malformed geometry.
    // Normalize that boundary here without changing any fitting criteria.
    final seenIds = <String>{};
    final values = <SketchEntity>[];
    for (final entity in entities) {
      if (!seenIds.add(entity.id)) continue;
      if (!_hasFiniteAutomaticGeometry(entity)) continue;
      values.add(entity);
    }
    final result = <SketchReconstructionSuggestion>[];
    final lines = values.whereType<SketchLine>().toList(growable: false);
    for (final component in _orderedLineChains(
      lines,
      endpointTolerance:
          const SketchCircularFitTolerance().endpointCoincidenceMillimeters,
      angularTolerance: angularTolerance,
    )) {
      final suggestion = _classifyLineChain(component);
      if (suggestion != null) result.add(suggestion);
    }
    for (final entity in values.where(
      (item) => item is SketchCircle || item is SketchArc,
    )) {
      result.add(
        SketchReconstructionSuggestion(
          kind: entity is SketchCircle
              ? SketchReconstructionKind.circle
              : SketchReconstructionKind.arc,
          entityIds: [entity.id],
          confidence: 1.0,
        ),
      );
    }
    // Section best-fit output is commonly a spline rather than a native
    // circle/arc.  Fit those sampled points conservatively and propose the
    // semantic primitive without replacing the source geometry.
    for (final spline in values.whereType<SketchSpline>()) {
      final points = _splinePoints(spline);
      final lineDiagnosis = diagnoseSelectedLineOrSpline([spline]);
      const lineTolerance = SketchLineReconstructionTolerance();
      final lineFit = lineDiagnosis.result;
      if (lineFit != null &&
          lineFit.maxError <= lineTolerance.reconstructionToleranceMm + 1e-12) {
        result.add(
          SketchReconstructionSuggestion(
            kind: SketchReconstructionKind.line,
            entityIds: [spline.id],
            confidence:
                (1 -
                        lineFit.rmsError /
                            math.max(
                              lineTolerance.reconstructionToleranceMm,
                              1e-12,
                            ))
                    .clamp(0.0, 1.0),
            usedEntityIds: lineFit.usedEntityIds,
            rmsError: lineFit.rmsError,
            maxError: lineFit.maxError,
            maxGapMillimeters: lineFit.maxGapMillimeters,
          ),
        );
        continue;
      }
      final fit = _fitCircle(points);
      if (fit == null ||
          points.length < 8 ||
          !_isSaneCircularFit(points, fit.$1, fit.$2)) {
        continue;
      }
      final center = fit.$1, radius = fit.$2;
      final error = _radialError(points, center, radius);
      final maximumError = _maxRadialError(points, center, radius);
      final radialTolerance = const SketchCircularFitTolerance().radialFor(
        radius,
      );
      if (maximumError > radialTolerance) continue;
      final angles =
          points
              .map(
                (point) => math.atan2(point.y - center.y, point.x - center.x),
              )
              .toList()
            ..sort();
      var largestGap = 0.0;
      for (var index = 0; index < angles.length; index++) {
        final next = index + 1 < angles.length
            ? angles[index + 1]
            : angles.first + 2 * math.pi;
        largestGap = math.max(largestGap, next - angles[index]);
      }
      final sweep = 2 * math.pi - largestGap;
      final kind = sweep >= 2 * math.pi - 0.5
          ? SketchReconstructionKind.circle
          : sweep >= 0.35
          ? SketchReconstructionKind.arc
          : null;
      if (kind != null) {
        final confidence = (1 - error / math.max(radialTolerance, 1e-9)).clamp(
          0.0,
          1.0,
        );
        if (confidence >= .75) {
          result.add(
            SketchReconstructionSuggestion(
              kind: kind,
              entityIds: [spline.id],
              confidence: confidence,
              center: center,
              radius: radius,
              startAngle: _arcAngles(points, center).$1,
              endAngle: _arcAngles(points, center).$2,
              rmsError: error,
              maxError: _maxRadialError(points, center, radius),
            ),
          );
        }
      }
    }
    final relations = <SketchReconstructionSuggestion>[];
    // Dense section polylines are curve samples, not independent engineering
    // lines.  Do not manufacture hundreds of false relations from them.
    if (lines.length > 64) return _arbitrateSuggestions(result);
    for (var i = 0; i < lines.length; i++) {
      for (var j = i + 1; j < lines.length; j++) {
        final first = _direction(lines[i]);
        final second = _direction(lines[j]);
        final angle = (first - second).abs() % math.pi;
        final parallel = math.min(angle, math.pi - angle);
        final relationIds = [lines[i].id, lines[j].id]..sort();
        if (parallel <= angularTolerance) {
          relations.add(
            SketchReconstructionSuggestion(
              kind: SketchReconstructionKind.parallel,
              entityIds: relationIds,
              confidence: 1 - parallel / angularTolerance,
            ),
          );
        } else if ((parallel - math.pi / 2).abs() <= angularTolerance) {
          relations.add(
            SketchReconstructionSuggestion(
              kind: SketchReconstructionKind.perpendicular,
              entityIds: relationIds,
              confidence: 1 - (parallel - math.pi / 2).abs() / angularTolerance,
            ),
          );
        }
      }
    }
    relations.sort((a, b) {
      final confidence = b.confidence.compareTo(a.confidence);
      if (confidence != 0) return confidence;
      final kind = a.kind.index.compareTo(b.kind.index);
      if (kind != 0) return kind;
      return a.entityIds.join('\u0000').compareTo(b.entityIds.join('\u0000'));
    });
    result.addAll(relations.take(128));
    return _arbitrateSuggestions(result);
  }

  /// Removes exact duplicate hypotheses and arbitrates competing primitive
  /// kinds over the same source set. Relations remain independent because
  /// they describe constraints rather than replacement geometry.
  List<SketchReconstructionSuggestion> _arbitrateSuggestions(
    List<SketchReconstructionSuggestion> suggestions,
  ) {
    final selected = <String, SketchReconstructionSuggestion>{};
    for (final suggestion in suggestions) {
      final ids = suggestion.entityIds.toSet().toList()..sort();
      final key = '${suggestion.kind.index}:${ids.join('\u0000')}';
      final previous = selected[key];
      if (previous == null ||
          _suggestionQuality(suggestion) > _suggestionQuality(previous)) {
        selected[key] = suggestion;
      }
    }
    final primitiveGroups = <String, List<SketchReconstructionSuggestion>>{};
    for (final suggestion in selected.values) {
      if (!_isReplacementSuggestion(suggestion)) continue;
      final key = (suggestion.entityIds.toSet().toList()..sort()).join(
        '\u0000',
      );
      primitiveGroups.putIfAbsent(key, () => []).add(suggestion);
    }
    for (final group in primitiveGroups.values) {
      if (group.length < 2) continue;
      group.sort(
        (a, b) => _suggestionQuality(b).compareTo(_suggestionQuality(a)),
      );
      for (final rejected in group.skip(1)) {
        final key =
            '${rejected.kind.index}:${(rejected.entityIds.toSet().toList()..sort()).join('\u0000')}';
        selected.remove(key);
      }
    }
    return selected.values.toList(growable: false);
  }

  bool _isReplacementSuggestion(SketchReconstructionSuggestion suggestion) =>
      suggestion.kind == SketchReconstructionKind.line ||
      suggestion.kind == SketchReconstructionKind.arc ||
      suggestion.kind == SketchReconstructionKind.circle;

  double _suggestionQuality(SketchReconstructionSuggestion suggestion) {
    final error = suggestion.maxError;
    final fitQuality = error == null ? 0.5 : 1 / (1 + error.abs());
    return fitQuality + suggestion.confidence * 0.01;
  }

  /// Builds connected paths from the actual endpoint graph.  A shared
  /// endpoint only establishes adjacency; it never qualifies a path as a
  /// line.  Branch nodes and gaps terminate a path so each hypothesis can be
  /// evaluated against the geometry it really contains.
  List<List<SketchLine>> _orderedLineChains(
    List<SketchLine> lines, {
    required double endpointTolerance,
    required double angularTolerance,
  }) {
    // Stable geometric ordering makes graph node creation, branch traversal
    // and closed-cycle start points independent of the caller's selection
    // order. IDs are only the final tie-breaker for coincident geometry.
    final orderedLines = lines.toList()..sort(_compareLineGeometry);
    final nodes = <SketchVector>[];
    final nodeEdges = <List<int>>[];
    final edges = <({SketchLine line, int start, int end})>[];

    int nodeFor(SketchVector point) {
      for (var index = 0; index < nodes.length; index++) {
        if (_distance(nodes[index], point) <= endpointTolerance) return index;
      }
      nodes.add(point);
      nodeEdges.add(<int>[]);
      return nodes.length - 1;
    }

    for (final line in orderedLines) {
      final start = SketchVector.fromJson(line.parameters['start']);
      final end = SketchVector.fromJson(line.parameters['end']);
      final edgeIndex = edges.length;
      final edge = (line: line, start: nodeFor(start), end: nodeFor(end));
      edges.add(edge);
      nodeEdges[edge.start].add(edgeIndex);
      nodeEdges[edge.end].add(edgeIndex);
    }

    final visited = <int>{};
    final chains = <List<SketchLine>>[];

    List<SketchLine> walk(int firstEdge, int firstNode) {
      final path = <SketchLine>[];
      var edgeIndex = firstEdge;
      var node = firstNode;
      while (!visited.contains(edgeIndex)) {
        final edge = edges[edgeIndex];
        visited.add(edgeIndex);
        path.add(edge.line);
        final nextNode = edge.start == node ? edge.end : edge.start;
        if (nodeEdges[nextNode].length != 2) break;
        final next = nodeEdges[nextNode].firstWhere(
          (candidate) => !visited.contains(candidate),
          orElse: () => -1,
        );
        if (next < 0) break;
        node = nextNode;
        edgeIndex = next;
      }
      return path;
    }

    // Open paths and branches are walked from their boundary nodes first.
    for (var node = 0; node < nodeEdges.length; node++) {
      if (nodeEdges[node].length == 2) continue;
      for (final edgeIndex in nodeEdges[node]) {
        if (visited.contains(edgeIndex)) continue;
        final path = walk(edgeIndex, node);
        if (path.isNotEmpty) {
          chains.addAll(
            _splitLineChain(path, angularTolerance, endpointTolerance),
          );
        }
      }
    }
    // A closed ring has no boundary node.  Walk each remaining edge once;
    // the turn-state splitter still keeps a constant-curvature ring intact.
    for (var edgeIndex = 0; edgeIndex < edges.length; edgeIndex++) {
      if (visited.contains(edgeIndex)) continue;
      final edge = edges[edgeIndex];
      final path = walk(edgeIndex, edge.start);
      if (path.isNotEmpty) {
        chains.addAll(
          _splitLineChain(path, angularTolerance, endpointTolerance),
        );
      }
    }
    return chains;
  }

  int _compareLineGeometry(SketchLine first, SketchLine second) {
    final firstPoints = [
      SketchVector.fromJson(first.parameters['start']),
      SketchVector.fromJson(first.parameters['end']),
    ]..sort(_comparePointGeometry);
    final secondPoints = [
      SketchVector.fromJson(second.parameters['start']),
      SketchVector.fromJson(second.parameters['end']),
    ]..sort(_comparePointGeometry);
    for (var index = 0; index < firstPoints.length; index++) {
      final comparison = _comparePointGeometry(
        firstPoints[index],
        secondPoints[index],
      );
      if (comparison != 0) return comparison;
    }
    return first.id.compareTo(second.id);
  }

  int _comparePointGeometry(SketchVector first, SketchVector second) {
    final x = first.x.compareTo(second.x);
    if (x != 0) return x;
    final y = first.y.compareTo(second.y);
    if (y != 0) return y;
    return first.z.compareTo(second.z);
  }

  List<List<SketchLine>> _splitLineChain(
    List<SketchLine> path,
    double angularTolerance,
    double endpointTolerance,
  ) {
    if (path.length < 2) return [List.unmodifiable(path)];
    final turns = <double>[];
    for (var index = 0; index + 1 < path.length; index++) {
      final directions = _pathDirections(
        path[index],
        path[index + 1],
        endpointTolerance,
      );
      if (directions == null) {
        turns.add(0);
        continue;
      }
      final firstDirection = directions.$1;
      final secondDirection = directions.$2;
      turns.add(
        math.atan2(
          firstDirection.x * secondDirection.y -
              firstDirection.y * secondDirection.x,
          firstDirection.dot(secondDirection),
        ),
      );
    }
    final minimumTurn = math.max(angularTolerance, 1e-3);
    // A visible cusp is a 30 degree turn (or eight times the existing
    // recognition angular tolerance).  Curvature state changes and
    // inflections split more gently, while constant-turn facets remain one
    // curve instead of producing one suggestion per facet.
    final cornerThreshold = math.max(math.pi / 6, minimumTurn * 8);
    final breaks = <int>{};
    for (var index = 0; index < turns.length; index++) {
      final turn = turns[index];
      if (turn.abs() >= cornerThreshold) {
        breaks.add(index);
      }
      if (index == 0) continue;
      final previous = turns[index - 1];
      if (previous.abs() >= cornerThreshold || turn.abs() >= cornerThreshold) {
        // The cusp itself already defines the boundary; do not add a second
        // split for the curved/straight state change on the other side.
        continue;
      }
      final previousCurved = previous.abs() > minimumTurn;
      final currentCurved = turn.abs() > minimumTurn;
      if (previousCurved != currentCurved ||
          (previousCurved && currentCurved && previous * turn < 0)) {
        breaks.add(index);
      }
    }
    // A tangent line-to-arc transition has the same turn angle as the first
    // arc facet, so angle state alone cannot locate that boundary.  Mark
    // edges that belong to a stable three-edge circular window and split at
    // changes of that state.  Sliding windows keep a real arc together while
    // leaving its tangent straight neighbours outside the region.
    final circularEdges = _circularEdgeFlags(path);
    for (var index = 1; index < circularEdges.length; index++) {
      if (circularEdges[index] != circularEdges[index - 1]) {
        breaks.add(index - 1);
      }
    }
    if (breaks.isEmpty) return [List.unmodifiable(path)];
    final chunks = <List<SketchLine>>[];
    var start = 0;
    for (final breakAfter in breaks.toList()..sort()) {
      final end = math.min(breakAfter + 1, path.length);
      if (end > start) chunks.add(List.unmodifiable(path.sublist(start, end)));
      start = end;
    }
    if (start < path.length) {
      chunks.add(List.unmodifiable(path.sublist(start)));
    }
    return chunks;
  }

  List<bool> _circularEdgeFlags(List<SketchLine> path) {
    final flags = List<bool>.filled(path.length, false);
    if (path.length < 3) return flags;
    for (var start = 0; start + 2 < path.length; start++) {
      final points = <SketchVector>[];
      for (var index = start; index <= start + 2; index++) {
        final line = path[index];
        final lineStart = SketchVector.fromJson(line.parameters['start']);
        final lineEnd = SketchVector.fromJson(line.parameters['end']);
        if (points.isEmpty || _distance(points.last, lineStart) > 1e-8) {
          points.add(lineStart);
        }
        points.add(lineEnd);
      }
      final fit = _fitCircle(points);
      if (fit == null || !_isSaneCircularFit(points, fit.$1, fit.$2)) {
        continue;
      }
      final error = points
          .map((point) => (_distance(point, fit.$1) - fit.$2).abs())
          .fold<double>(0, math.max);
      // Local windows use the established absolute circular budget rather
      // than the broad whole-arc 5% display budget.  This prevents a long
      // tangent line from being absorbed into a short curved transition.
      if (error > const SketchCircularFitTolerance().absoluteMillimeters) {
        continue;
      }
      for (var index = start; index <= start + 2; index++) {
        flags[index] = true;
      }
    }
    return flags;
  }

  SketchReconstructionSuggestion? _classifyLineChain(
    List<SketchLine> component,
  ) {
    if (component.isEmpty) return null;
    if (component.length == 1) {
      return SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.line,
        entityIds: [component.single.id],
        confidence: 1.0,
      );
    }
    // The PCA result is the gate.  Connectivity and shared endpoints alone
    // are deliberately insufficient for line recognition.
    final diagnosis = diagnoseSelectedLineOrSpline(
      component,
      maxRegions: math.max(
        SketchCircularFitTolerance.maxRegions,
        component.length,
      ),
    );
    final fit = diagnosis.result;
    const lineTolerance = SketchLineReconstructionTolerance();
    if (fit != null &&
        fit.maxError <= lineTolerance.reconstructionToleranceMm + 1e-12) {
      return SketchReconstructionSuggestion(
        kind: SketchReconstructionKind.line,
        entityIds: component.map((line) => line.id).toList(growable: false),
        confidence:
            (1 -
                    fit.rmsError /
                        math.max(
                          lineTolerance.reconstructionToleranceMm,
                          1e-12,
                        ))
                .clamp(0.0, 1.0),
        usedEntityIds: fit.usedEntityIds,
        rmsError: fit.rmsError,
        maxError: fit.maxError,
        maxGapMillimeters: fit.maxGapMillimeters,
      );
    }
    // Reuse the established circular fitter for constant-curvature pieces;
    // no new fitting criterion or tolerance is introduced here.
    final circular = fitSelectedCircular(component);
    if (circular != null) {
      final firstStart = SketchVector.fromJson(
        component.first.parameters['start'],
      );
      final lastEnd = SketchVector.fromJson(component.last.parameters['end']);
      if (circular.confidence < .75) return null;
      if (circular.kind == SketchReconstructionKind.arc &&
          _distance(firstStart, lastEnd) <=
              const SketchCircularFitTolerance()
                  .endpointCoincidenceMillimeters) {
        return SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.circle,
          entityIds: circular.entityIds,
          confidence: circular.confidence,
          center: circular.center,
          radius: circular.radius,
          startAngle: circular.startAngle,
          endAngle: circular.endAngle,
          startPoint: circular.startPoint,
          endPoint: circular.endPoint,
          circularFitQuality: circular.circularFitQuality,
          warnings: circular.warnings,
          maxGapMillimeters: circular.maxGapMillimeters,
          tangencyStartDegrees: circular.tangencyStartDegrees,
          tangencyEndDegrees: circular.tangencyEndDegrees,
          usedEntityIds: circular.usedEntityIds,
          coveredEntityIds: circular.coveredEntityIds,
          rmsError: circular.rmsError,
          maxError: circular.maxError,
        );
      }
      return circular;
    }
    // Closed polylines have no external endpoints, so the manual ordered
    // fitter quite correctly refuses to invent a start/end arc.  They can
    // still be recognized as a circle when the existing algebraic circle fit
    // explains every source endpoint within its established error budget.
    final points = <SketchVector>[];
    for (final line in component) {
      final start = SketchVector.fromJson(line.parameters['start']);
      final end = SketchVector.fromJson(line.parameters['end']);
      if (points.isEmpty || _distance(points.last, start) > 1e-8) {
        points.add(start);
      }
      points.add(end);
    }
    final circleFit = _fitCircle(points);
    if (circleFit == null ||
        !_isSaneCircularFit(points, circleFit.$1, circleFit.$2)) {
      return null;
    }
    final start = points.first;
    final end = points.last;
    var anchor = points.first;
    var anchorDistance = _distanceToLine(anchor, start, end);
    for (final point in points) {
      final distance = _distanceToLine(point, start, end);
      if (distance > anchorDistance) {
        anchor = point;
        anchorDistance = distance;
      }
    }
    final tolerance = const SketchCircularFitTolerance();
    final closed =
        _distance(start, end) <= tolerance.endpointCoincidenceMillimeters;
    final angles = closed
        ? (
            startAngle: math.atan2(
              start.y - circleFit.$1.y,
              start.x - circleFit.$1.x,
            ),
            endAngle:
                math.atan2(start.y - circleFit.$1.y, start.x - circleFit.$1.x) +
                2 * math.pi,
            startPoint: start,
            endPoint: end,
          )
        : _arcDefinition((start: start, end: end), anchor, circleFit.$1);
    if (angles == null) return null;
    final failure = _circularFitFailure(
      points: points,
      center: circleFit.$1,
      radius: circleFit.$2,
      start: start,
      end: end,
      sweep: angles.endAngle - angles.startAngle,
      tolerance: tolerance,
    );
    final circularFailure = closed
        ? _circularFitFailure(
            points: points,
            center: circleFit.$1,
            radius: circleFit.$2,
            start: start,
            end: start + const SketchVector(1e-3, 0),
            sweep: 2 * math.pi,
            tolerance: tolerance,
          )
        : failure;
    if (circularFailure != null) return null;
    final rmsError = _radialError(points, circleFit.$1, circleFit.$2);
    final maxError = _maxRadialError(points, circleFit.$1, circleFit.$2);
    final errorLimit = tolerance.radialFor(circleFit.$2);
    final confidence = (1 - maxError / math.max(errorLimit, 1e-9)).clamp(
      0.0,
      1.0,
    );
    if (confidence < .75) return null;
    return SketchReconstructionSuggestion(
      kind: closed
          ? SketchReconstructionKind.circle
          : SketchReconstructionKind.arc,
      entityIds: component.map((line) => line.id).toList(growable: false),
      confidence: confidence,
      center: circleFit.$1,
      radius: circleFit.$2,
      startAngle: angles.startAngle,
      endAngle: angles.endAngle,
      rmsError: rmsError,
      maxError: maxError,
    );
  }

  (SketchVector, SketchVector)? _pathDirections(
    SketchLine line,
    SketchLine next,
    double endpointTolerance,
  ) {
    final lineStart = SketchVector.fromJson(line.parameters['start']);
    final lineEnd = SketchVector.fromJson(line.parameters['end']);
    final nextStart = SketchVector.fromJson(next.parameters['start']);
    final nextEnd = SketchVector.fromJson(next.parameters['end']);
    final pairs = <(SketchVector, SketchVector)>[
      (lineStart, nextStart),
      (lineStart, nextEnd),
      (lineEnd, nextStart),
      (lineEnd, nextEnd),
    ];
    var best = pairs.first;
    var bestDistance = _distance(best.$1, best.$2);
    for (final pair in pairs.skip(1)) {
      final distance = _distance(pair.$1, pair.$2);
      if (distance < bestDistance) {
        best = pair;
        bestDistance = distance;
      }
    }
    if (!bestDistance.isFinite || bestDistance > endpointTolerance) return null;
    final lineShared = best.$1;
    final nextShared = best.$2;
    final lineOther = _distance(lineShared, lineStart) <= 1e-12
        ? lineEnd
        : lineStart;
    final nextOther = _distance(nextShared, nextStart) <= 1e-12
        ? nextEnd
        : nextStart;
    final first = lineShared - lineOther;
    final second = nextOther - nextShared;
    final firstLength = math.sqrt(first.dot(first));
    final secondLength = math.sqrt(second.dot(second));
    if (firstLength <= 1e-12 || secondLength <= 1e-12) return null;
    return (first.scale(1 / firstLength), second.scale(1 / secondLength));
  }

  bool _hasFiniteAutomaticGeometry(SketchEntity entity) {
    try {
      if (entity is SketchCircle) {
        final center = SketchVector.fromJson(entity.parameters['center']);
        final radius = (entity.parameters['radius'] as num).toDouble();
        return _isFinite(center) && radius.isFinite && radius > 0;
      }
      if (entity is! SketchLine &&
          entity is! SketchArc &&
          entity is! SketchSpline) {
        return true;
      }
      final samples = _entitySamples(entity);
      return samples.length >= 2 && samples.every(_isFinite);
    } catch (_) {
      return false;
    }
  }

  (double, double) _arcAngles(List<SketchVector> points, SketchVector center) {
    if (points.isEmpty) return (0, 2 * math.pi);
    final start = math.atan2(
      points.first.y - center.y,
      points.first.x - center.x,
    );
    var end = math.atan2(points.last.y - center.y, points.last.x - center.x);
    while (end < start) {
      end += 2 * math.pi;
    }
    return (start, end);
  }

  bool _isSaneCircularFit(
    List<SketchVector> points,
    SketchVector center,
    double radius,
  ) {
    if (!radius.isFinite || radius <= 1e-9 || points.length < 3) return false;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (final point in points) {
      minX = math.min(minX, point.x);
      minY = math.min(minY, point.y);
      maxX = math.max(maxX, point.x);
      maxY = math.max(maxY, point.y);
    }
    final diagonal = math.sqrt(
      (maxX - minX) * (maxX - minX) + (maxY - minY) * (maxY - minY),
    );
    // A nearly straight section can always be fitted by a circle with an
    // enormous radius. It is not a useful CAD arc, so reject that unstable
    // interpretation before it reaches the Sketch.
    if (!diagonal.isFinite || diagonal <= 1e-9 || radius > diagonal * 8) {
      return false;
    }
    final centerDistance = math.sqrt(
      math.pow(center.x - (minX + maxX) / 2, 2).toDouble() +
          math.pow(center.y - (minY + maxY) / 2, 2).toDouble(),
    );
    return centerDistance <= radius * 1.5 + diagonal;
  }

  List<SketchVector> _splinePoints(SketchSpline spline) {
    final raw =
        (spline.parameters['sampledPoints'] ?? spline.parameters['points']);
    if (raw is! List) return const [];
    return raw.whereType<List>().map(SketchVector.fromJson).toList();
  }

  (SketchVector, double)? _fitCircle(List<SketchVector> points) {
    if (points.length < 3) return null;
    var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0;
    var sb = 0.0, sxb = 0.0, syb = 0.0;
    for (final point in points) {
      sx += point.x;
      sy += point.y;
      sxx += point.x * point.x;
      syy += point.y * point.y;
      sxy += point.x * point.y;
      final b = -(point.x * point.x + point.y * point.y);
      sb += b;
      sxb += point.x * b;
      syb += point.y * b;
    }
    final matrix = [
      [sxx, sxy, sx, sxb],
      [sxy, syy, sy, syb],
      [sx, sy, points.length.toDouble(), sb],
    ];
    for (var column = 0; column < 3; column++) {
      var pivot = column;
      for (var row = column + 1; row < 3; row++) {
        if (matrix[row][column].abs() > matrix[pivot][column].abs()) {
          pivot = row;
        }
      }
      if (matrix[pivot][column].abs() <= 1e-12) return null;
      final swap = matrix[column];
      matrix[column] = matrix[pivot];
      matrix[pivot] = swap;
      final divisor = matrix[column][column];
      for (var item = column; item < 4; item++) {
        matrix[column][item] /= divisor;
      }
      for (var row = 0; row < 3; row++) {
        if (row == column) continue;
        final factor = matrix[row][column];
        for (var item = column; item < 4; item++) {
          matrix[row][item] -= factor * matrix[column][item];
        }
      }
    }
    final center = SketchVector(-matrix[0][3] / 2, -matrix[1][3] / 2);
    final radius2 = center.dot(center) - matrix[2][3];
    return radius2 > 0 ? (center, math.sqrt(radius2)) : null;
  }

  double _direction(SketchLine line) {
    final start = SketchVector.fromJson(line.parameters['start']);
    final end = SketchVector.fromJson(line.parameters['end']);
    return math.atan2(end.y - start.y, end.x - start.x);
  }

  double _distance(SketchVector first, SketchVector second) {
    final dx = first.x - second.x, dy = first.y - second.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}
