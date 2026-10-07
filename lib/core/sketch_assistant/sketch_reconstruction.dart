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
  });

  final List<List<SketchVector>> regions;
  final SketchVector start;
  final SketchVector end;
  final List<double> gaps;

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

  String get label => switch (kind) {
    SketchReconstructionKind.line => 'Linha reconhecida',
    SketchReconstructionKind.circle => 'Círculo reconhecido',
    SketchReconstructionKind.arc => 'Arco reconhecido',
    SketchReconstructionKind.parallel => 'Linhas paralelas',
    SketchReconstructionKind.perpendicular => 'Linhas perpendiculares',
  };
}

/// Conservative, non-mutating recognition pass for section-derived Sketches.
/// It only proposes semantics; geometry and constraints change only after an
/// explicit user confirmation.
class SketchReconstructionEngine {
  const SketchReconstructionEngine();

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
    );
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
      ordered.add(
        orient(regions[pending.removeAt(bestIndex)], atLast: bestAtLast),
      );
    }
    // Close the chain on the far extreme found by the initial search.
    final lastGap = _distance(ordered.last.last, endSamples.first);
    gaps.add(lastGap);
    ordered.add(endSamples);
    return _SelectionOrder(
      _OrderedSelection(
        regions: ordered,
        start: ordered.first.first,
        end: ordered.last.last,
        gaps: gaps,
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
    final values = entities.toList(growable: false);
    final result = <SketchReconstructionSuggestion>[];
    final lines = values.whereType<SketchLine>().toList(growable: false);
    final components = <List<SketchLine>>[];
    for (final line in lines) {
      final component = components.firstWhere(
        (candidate) => candidate.any(
          (other) => _sharesEndpoint(line, other, angularTolerance * 8),
        ),
        orElse: () {
          final created = <SketchLine>[];
          components.add(created);
          return created;
        },
      );
      component.add(line);
    }
    for (final component in components) {
      result.add(
        SketchReconstructionSuggestion(
          kind: SketchReconstructionKind.line,
          entityIds: component.map((line) => line.id).toList(growable: false),
          confidence: 1.0,
        ),
      );
      // Automatic recognition is filtered by confidence at acceptance time;
      // allowing smaller manually selected chains lets the user fit a short
      // arc from two or three section segments.
      if (component.length >= 2) {
        final points = <SketchVector>[];
        for (final line in component) {
          points
            ..add(SketchVector.fromJson(line.parameters['start']))
            ..add(SketchVector.fromJson(line.parameters['end']));
        }
        final fit = _fitCircle(points);
        if (fit != null && _isSaneCircularFit(points, fit.$1, fit.$2)) {
          final error =
              points
                  .map((point) => (_distance(point, fit.$1) - fit.$2).abs())
                  .fold<double>(0, (sum, value) => sum + value) /
              points.length;
          if (error <= math.max(.5, fit.$2 * .05)) {
            final angles =
                points
                    .map(
                      (point) =>
                          math.atan2(point.y - fit.$1.y, point.x - fit.$1.x),
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
            final kind = sweep >= 2 * math.pi - .5
                ? SketchReconstructionKind.circle
                : sweep >= .35
                ? SketchReconstructionKind.arc
                : null;
            if (kind != null) {
              result.add(
                SketchReconstructionSuggestion(
                  kind: kind,
                  entityIds: component.map((line) => line.id).toList(),
                  confidence:
                      (1 - error / math.max(math.max(.5, fit.$2 * .05), 1e-9))
                          .clamp(0.0, 1.0),
                  center: fit.$1,
                  radius: fit.$2,
                  startAngle: _arcAngles(points, fit.$1).$1,
                  endAngle: _arcAngles(points, fit.$1).$2,
                ),
              );
            }
          }
        }
      }
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
      final lineConfidence = _lineConfidence(points);
      if (lineConfidence != null) {
        result.add(
          SketchReconstructionSuggestion(
            kind: SketchReconstructionKind.line,
            entityIds: [spline.id],
            confidence: lineConfidence,
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
      final error =
          points
              .map((point) => (_distance(point, center) - radius).abs())
              .fold<double>(0, (sum, value) => sum + value) /
          points.length;
      if (error > math.max(0.5, radius * 0.05)) continue;
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
        result.add(
          SketchReconstructionSuggestion(
            kind: kind,
            entityIds: [spline.id],
            confidence: (1 - error / math.max(math.max(.5, radius * .05), 1e-9))
                .clamp(0.0, 1.0),
            center: center,
            radius: radius,
            startAngle: _arcAngles(points, center).$1,
            endAngle: _arcAngles(points, center).$2,
          ),
        );
      }
    }
    final relations = <SketchReconstructionSuggestion>[];
    // Dense section polylines are curve samples, not independent engineering
    // lines.  Do not manufacture hundreds of false relations from them.
    if (lines.length > 64) return result;
    for (var i = 0; i < lines.length; i++) {
      for (var j = i + 1; j < lines.length; j++) {
        final first = _direction(lines[i]);
        final second = _direction(lines[j]);
        final angle = (first - second).abs() % math.pi;
        final parallel = math.min(angle, math.pi - angle);
        if (parallel <= angularTolerance) {
          relations.add(
            SketchReconstructionSuggestion(
              kind: SketchReconstructionKind.parallel,
              entityIds: [lines[i].id, lines[j].id],
              confidence: 1 - parallel / angularTolerance,
            ),
          );
        } else if ((parallel - math.pi / 2).abs() <= angularTolerance) {
          relations.add(
            SketchReconstructionSuggestion(
              kind: SketchReconstructionKind.perpendicular,
              entityIds: [lines[i].id, lines[j].id],
              confidence: 1 - (parallel - math.pi / 2).abs() / angularTolerance,
            ),
          );
        }
      }
    }
    relations.sort((a, b) => b.confidence.compareTo(a.confidence));
    result.addAll(relations.take(128));
    return result;
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

  double? _lineConfidence(List<SketchVector> points) {
    if (points.length < 3) return null;
    final first = points.first, last = points.last;
    final dx = last.x - first.x, dy = last.y - first.y;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length <= 1e-9) return null;
    final residual = points
        .map(
          (point) =>
              ((point.x - first.x) * dy - (point.y - first.y) * dx).abs() /
              length,
        )
        .fold<double>(0, math.max);
    final tolerance = math.max(.5, length * .025);
    return residual <= tolerance
        ? (1 - residual / tolerance).clamp(0.0, 1.0)
        : null;
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

  bool _sharesEndpoint(SketchLine first, SketchLine second, double tolerance) {
    final firstStart = SketchVector.fromJson(first.parameters['start']);
    final firstEnd = SketchVector.fromJson(first.parameters['end']);
    final secondStart = SketchVector.fromJson(second.parameters['start']);
    final secondEnd = SketchVector.fromJson(second.parameters['end']);
    return _distance(firstStart, secondStart) <= tolerance ||
        _distance(firstStart, secondEnd) <= tolerance ||
        _distance(firstEnd, secondStart) <= tolerance ||
        _distance(firstEnd, secondEnd) <= tolerance;
  }

  double _distance(SketchVector first, SketchVector second) {
    final dx = first.x - second.x, dy = first.y - second.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}
