import 'dart:math' as math;

import '../sketch_engine/entities/sketch_entities.dart';
import '../sketch_engine/models/sketch_models.dart';

enum SketchReconstructionKind { line, circle, arc, parallel, perpendicular }

enum SketchCircularFitFailure {
  invalidChain,
  insufficientPoints,
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

class _TangentFitResult {
  const _TangentFitResult({required this.required, this.fit, this.failure});

  /// True when both real neighbours exist.  In that case a three-point arc is
  /// not an authorised substitute for an invalid C1 solution.
  final bool required;
  final (SketchVector, double)? fit;
  final SketchCircularFitFailure? failure;
}

/// Directions supplied by the curves that touch one chain boundary, plus the
/// reason an explicit manual reference could not be used.
class _NeighborProbe {
  const _NeighborProbe(this.directions, [this.failure]);

  final List<SketchVector> directions;
  final SketchCircularFitFailure? failure;
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
  }) {
    final entities = selected.toList(growable: false);
    if (entities.length > 3) return null;
    final boundary = _continuousChainBoundaries(entities);
    if (boundary == null) return null;
    final points = <SketchVector>[];
    for (final entity in entities) {
      if (entity is SketchLine) {
        points
          ..add(SketchVector.fromJson(entity.parameters['start']))
          ..add(SketchVector.fromJson(entity.parameters['end']));
      } else if (entity is SketchSpline) {
        final raw =
            (entity.parameters['sampledPoints'] ?? entity.parameters['points'])
                as List?;
        if (raw != null) {
          points.addAll(raw.whereType<List>().map(SketchVector.fromJson));
        }
      }
    }
    // Adjacent section lines share an endpoint. Two selected lines therefore
    // provide three distinct samples, which are enough to define an arc.
    final uniquePoints = <SketchVector>[];
    for (final point in points) {
      if (!uniquePoints.any((other) => _distance(other, point) <= 1e-7)) {
        uniquePoints.add(point);
      }
    }
    if (uniquePoints.length < 3) return null;
    final anchor =
        uniquePoints
            .where(
              (point) =>
                  _distance(point, boundary.start) > 1e-7 &&
                  _distance(point, boundary.end) > 1e-7,
            )
            .toList(growable: false)
          ..sort(
            (first, second) => _distanceToLine(
              second,
              boundary.start,
              boundary.end,
            ).compareTo(_distanceToLine(first, boundary.start, boundary.end)),
          );
    if (anchor.isEmpty) return null;
    // Retain the external endpoints throughout. Prefer C1 at both ends, then
    // one end, then the existing three-point geometric fit. A continuous,
    // usable chain must not be discarded merely because bilateral C1 is
    // impossible; the quality is reported to the caller as a warning.
    final tangent = _tangentFit(
      boundary,
      entities.map((entity) => entity.id).toSet(),
      context,
      manualStartId: startTangencyId,
      manualEndId: endTangencyId,
      startForward: _chainDirectionInto(entities, boundary.start),
      endForward: _chainDirectionInto(entities, boundary.end)?.scale(-1),
    );
    final manualBoth = startTangencyId != null && endTangencyId != null;
    if (tangent.failure == SketchCircularFitFailure.ambiguousBranch) {
      return null;
    }
    // An explicit pair of references is a user contract: reject instead of
    // silently downgrading to a one sided or three point arc.
    if (manualBoth &&
        tangent.failure != null &&
        tangent.failure != SketchCircularFitFailure.incompatibleTangency) {
      return null;
    }
    if (manualBoth && tangent.fit == null) return null;
    var fit = tangent.fit;
    var quality = SketchCircularFitQuality.c1Bilateral;
    if (fit != null) {
      final angles = _arcDefinition(boundary, anchor.first, fit.$1);
      if (angles == null ||
          !_hasC1Tangency(
            context,
            selectedIds: entities.map((entity) => entity.id).toSet(),
            center: fit.$1,
            startPoint: boundary.start,
            endPoint: boundary.end,
            startTangencyId: startTangencyId,
            endTangencyId: endTangencyId,
          )) {
        // An explicit pair of references is a strict contract: reject instead
        // of downgrading to a one sided or three point arc.
        if (manualBoth) return null;
        fit = null;
        quality = SketchCircularFitQuality.geometricFallback;
      }
    }
    // Defensive: with an explicit pair of references a null fit at this point
    // can only come from the C1 validation above.
    if (manualBoth && fit == null) return null;
    if (fit == null && tangent.required) {
      fit = _partialTangentFit(
        boundary,
        entities.map((entity) => entity.id).toSet(),
        context,
        uniquePoints,
      );
      if (fit != null) {
        final angles = _arcDefinition(boundary, anchor.first, fit.$1);
        if (angles == null ||
            !_hasAnyC1Tangency(
              context,
              selectedIds: entities.map((entity) => entity.id).toSet(),
              center: fit.$1,
              startPoint: boundary.start,
              endPoint: boundary.end,
              startTangencyId: startTangencyId,
              endTangencyId: endTangencyId,
            )) {
          fit = null;
        } else {
          quality = SketchCircularFitQuality.c1Partial;
        }
      }
    }
    fit ??= _circleThrough(boundary.start, anchor.first, boundary.end);
    if (fit == null) return null;
    if (quality == SketchCircularFitQuality.c1Bilateral &&
        tangent.fit == null) {
      quality = SketchCircularFitQuality.geometricFallback;
    }
    final circularFit = fit;
    if (!_isSaneCircularFit(uniquePoints, circularFit.$1, circularFit.$2)) {
      return null;
    }
    final error =
        uniquePoints
            .map(
              (point) =>
                  (_distance(point, circularFit.$1) - circularFit.$2).abs(),
            )
            .fold<double>(0, (sum, value) => sum + value) /
        uniquePoints.length;
    final startAngle = math.atan2(
      boundary.start.y - circularFit.$1.y,
      boundary.start.x - circularFit.$1.x,
    );
    final endAngle = math.atan2(
      boundary.end.y - circularFit.$1.y,
      boundary.end.x - circularFit.$1.x,
    );
    final anchorAngle = math.atan2(
      anchor.first.y - circularFit.$1.y,
      anchor.first.x - circularFit.$1.x,
    );
    final ccwSweep = _positiveSweep(startAngle, endAngle);
    final startContainsAnchor =
        _positiveSweep(startAngle, anchorAngle) <= ccwSweep + 1e-7;
    final arcStart = startContainsAnchor ? startAngle : endAngle;
    final sweep = startContainsAnchor
        ? ccwSweep
        : _positiveSweep(endAngle, startAngle);
    if (sweep < .2) return null;
    final arcStartPoint = startContainsAnchor ? boundary.start : boundary.end;
    final arcEndPoint = startContainsAnchor ? boundary.end : boundary.start;
    return SketchReconstructionSuggestion(
      kind: SketchReconstructionKind.arc,
      entityIds: entities.map((entity) => entity.id).toList(growable: false),
      confidence:
          (1 - error / math.max(math.max(.5, circularFit.$2 * .05), 1e-9))
              .clamp(0.0, 1.0),
      center: circularFit.$1,
      radius: circularFit.$2,
      startAngle: arcStart,
      endAngle: arcStart + sweep,
      startPoint: arcStartPoint,
      endPoint: arcEndPoint,
      circularFitQuality: quality,
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
  }) {
    final entities = selected.toList(growable: false);
    if (entities.length < 2 || entities.length > 3) {
      return SketchCircularFitFailure.invalidChain;
    }
    final boundary = _continuousChainBoundaries(entities);
    if (boundary == null) return SketchCircularFitFailure.invalidChain;
    final points = _fitPoints(entities);
    final uniquePoints = _uniquePoints(points);
    if (uniquePoints.length < 3) {
      return SketchCircularFitFailure.insufficientPoints;
    }
    final anchor = _fitAnchor(uniquePoints, boundary);
    if (anchor == null) return SketchCircularFitFailure.invalidChain;
    final selectedIds = entities.map((entity) => entity.id).toSet();
    final tangent = _tangentFit(
      boundary,
      selectedIds,
      context,
      manualStartId: startTangencyId,
      manualEndId: endTangencyId,
      startForward: _chainDirectionInto(entities, boundary.start),
      endForward: _chainDirectionInto(entities, boundary.end)?.scale(-1),
    );
    if (tangent.failure != null) {
      return tangent.failure!;
    }
    // With two explicit references the fit is strict: mirror the same gates the
    // command applies, so the panel always receives an incompatibility reason
    // instead of the generic invalid-chain default.
    if (startTangencyId != null && endTangencyId != null) {
      final circular = tangent.fit;
      if (circular == null) {
        return SketchCircularFitFailure.incompatibleTangency;
      }
      if (_arcDefinition(boundary, anchor, circular.$1) == null) {
        return SketchCircularFitFailure.incompatibleTangency;
      }
      if (!_isSaneCircularFit(uniquePoints, circular.$1, circular.$2)) {
        return SketchCircularFitFailure.unstableRadius;
      }
      return SketchCircularFitFailure.incompatibleTangency;
    }
    // When both neighbours are present the tangent circle is mandatory: report
    // the geometric reason instead of the generic invalid-chain default.
    if (tangent.required && tangent.fit == null) {
      return tangent.failure ?? SketchCircularFitFailure.incompatibleTangency;
    }
    final fit = _circleThrough(boundary.start, anchor, boundary.end);
    if (fit == null || !_isSaneCircularFit(uniquePoints, fit.$1, fit.$2)) {
      return SketchCircularFitFailure.unstableRadius;
    }
    return SketchCircularFitFailure.invalidChain;
  }

  List<SketchVector> _fitPoints(List<SketchEntity> entities) {
    final points = <SketchVector>[];
    for (final entity in entities) {
      if (entity is SketchLine) {
        points
          ..add(SketchVector.fromJson(entity.parameters['start']))
          ..add(SketchVector.fromJson(entity.parameters['end']));
      } else if (entity is SketchSpline) {
        final raw =
            (entity.parameters['sampledPoints'] ?? entity.parameters['points'])
                as List?;
        if (raw != null) {
          points.addAll(raw.whereType<List>().map(SketchVector.fromJson));
        }
      }
    }
    return points;
  }

  List<SketchVector> _uniquePoints(List<SketchVector> points) {
    final unique = <SketchVector>[];
    for (final point in points) {
      if (!unique.any((other) => _distance(other, point) <= 1e-7)) {
        unique.add(point);
      }
    }
    return unique;
  }

  SketchVector? _fitAnchor(
    List<SketchVector> points,
    ({SketchVector start, SketchVector end}) boundary,
  ) {
    final anchors =
        points
            .where(
              (point) =>
                  _distance(point, boundary.start) > 1e-7 &&
                  _distance(point, boundary.end) > 1e-7,
            )
            .toList(growable: false)
          ..sort(
            (first, second) => _distanceToLine(
              second,
              boundary.start,
              boundary.end,
            ).compareTo(_distanceToLine(first, boundary.start, boundary.end)),
          );
    return anchors.firstOrNull;
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
    if (sweep < .2) return null;
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
      if (entity is SketchLine) {
        final start = SketchVector.fromJson(entity.parameters['start']);
        final end = SketchVector.fromJson(entity.parameters['end']);
        if (_distance(start, point) <= 1e-7) return end - start;
        if (_distance(end, point) <= 1e-7) return start - end;
      } else if (entity is SketchSpline) {
        final raw =
            (entity.parameters['sampledPoints'] ?? entity.parameters['points'])
                as List?;
        final samples =
            raw?.whereType<List>().map(SketchVector.fromJson).toList() ??
            const <SketchVector>[];
        if (samples.length >= 2) {
          if (_distance(samples.first, point) <= 1e-7) {
            return samples[1] - samples.first;
          }
          if (_distance(samples.last, point) <= 1e-7) {
            return samples[samples.length - 2] - samples.last;
          }
        }
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
      final direction = _endpointTangent(reference, endpoint);
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

  /// Circle that stays C1 with both supported neighbouring curves, or a
  /// failure when the chain has fewer than two valid neighbours, they branch,
  /// or the two neighbour tangents are geometrically incompatible.
  _TangentFitResult _tangentFit(
    ({SketchVector start, SketchVector end}) boundary,
    Set<String> selectedIds,
    Iterable<SketchEntity> context, {
    String? manualStartId,
    String? manualEndId,
    SketchVector? startForward,
    SketchVector? endForward,
  }) {
    final startProbe = _neighborTangents(
      boundary.start,
      selectedIds,
      context,
      manualId: manualStartId,
    );
    if (startProbe.failure != null) {
      return _TangentFitResult(required: true, failure: startProbe.failure);
    }
    final endProbe = _neighborTangents(
      boundary.end,
      selectedIds,
      context,
      manualId: manualEndId,
    );
    if (endProbe.failure != null) {
      return _TangentFitResult(required: true, failure: endProbe.failure);
    }
    final startCandidates = startProbe.directions;
    final endCandidates = endProbe.directions;
    // A branch is ambiguous even when the opposite boundary has no neighbour;
    // it must never silently downgrade to the three-point fallback.
    if (startCandidates.length > 1 || endCandidates.length > 1) {
      return const _TangentFitResult(
        required: true,
        failure: SketchCircularFitFailure.ambiguousBranch,
      );
    }
    if (startCandidates.isEmpty || endCandidates.isEmpty) {
      // A C1 constraint is only defined when both extremities continue into a
      // neighboring line. With none or a single neighbor the historical three
      // point fit stays valid.
      return const _TangentFitResult(required: false);
    }
    // At the first boundary the neighbour arrives at the selected chain, so
    // reverse its outward endpoint tangent.  At the final boundary it departs
    // from the replacement arc and keeps its outward orientation.
    final startDirection = startCandidates.single.scale(-1);
    final endDirection = endCandidates.single;
    // An explicit reference attached to the endpoint but running back over the
    // chain is inverted: the requested departure/arrival would be anti-parallel
    // to the chain itself.  Only a named reference is classified this way, so
    // the automatic diagnostics stay untouched.
    if (manualStartId != null &&
        startForward != null &&
        _isAntiAligned(startDirection, startForward)) {
      return const _TangentFitResult(
        required: true,
        failure: SketchCircularFitFailure.reversedTangency,
      );
    }
    if (manualEndId != null &&
        endForward != null &&
        _isAntiAligned(endDirection, endForward)) {
      return const _TangentFitResult(
        required: true,
        failure: SketchCircularFitFailure.reversedTangency,
      );
    }
    // The centre of a circle tangent to both neighbours lies where the two
    // endpoint normals meet:
    //   center = start + u * normal(startDirection)
    //          = end   + v * normal(endDirection)
    // Solve the 2x2 system for u and derive the radius from that centre.
    final startNormal = SketchVector(-startDirection.y, startDirection.x);
    final endNormal = SketchVector(-endDirection.y, endDirection.x);
    final dx = boundary.end.x - boundary.start.x;
    final dy = boundary.end.y - boundary.start.y;
    final cross = startNormal.x * endNormal.y - startNormal.y * endNormal.x;
    if (cross.abs() <= 1e-10) {
      // Parallel normals cannot bound a finite tangent circle.
      return const _TangentFitResult(
        required: true,
        failure: SketchCircularFitFailure.incompatibleTangency,
      );
    }
    final u = (dx * endNormal.y - dy * endNormal.x) / cross;
    final intersection = SketchVector(
      boundary.start.x + u * startNormal.x,
      boundary.start.y + u * startNormal.y,
    );
    // The intersection is exactly C1 only when both neighbour tangents belong
    // to one circle.  Section polylines approximate the real curve with chords,
    // so a small mismatch is expected and must not discard the tangent
    // solution.  Instead of dropping it (or snapping it heuristically), solve
    // for the circle that passes exactly through both preserved endpoints and
    // balances the C1 residual of the two extremities, so neither junction
    // carries a visible break.
    //
    // A circle through both endpoints has its centre on the perpendicular
    // bisector:  center(t) = midpoint + t * bisector, radius(t) = sqrt(D0+t^2)
    // with D0 = (|end - start| / 2)^2 and unit neighbour tangents p and q.  The
    // two tangent residuals are (start - center).p and (end - center).q, so
    // [_bilateralTangentOffset] picks the offset that minimises the worst of
    // the two (with the least-squares solution as a safety net).
    final axis = boundary.end - boundary.start;
    final axisLength = math.sqrt(axis.dot(axis));
    if (!axisLength.isFinite || axisLength <= 1e-7) {
      return const _TangentFitResult(
        required: true,
        failure: SketchCircularFitFailure.unstableRadius,
      );
    }
    final bisector = SketchVector(-axis.y / axisLength, axis.x / axisLength);
    final midpoint = boundary.start + axis.scale(.5);
    final offset = _bilateralTangentOffset(
      start: boundary.start,
      end: boundary.end,
      startDirection: startDirection,
      endDirection: endDirection,
      bisector: bisector,
      axisLength: axisLength,
      preferredSide: (intersection - midpoint).dot(bisector),
    );
    if (offset == null) {
      return const _TangentFitResult(
        required: true,
        failure: SketchCircularFitFailure.unstableRadius,
      );
    }
    final center = midpoint + bisector.scale(offset);
    final radius = _distance(center, boundary.start);
    if (!radius.isFinite || radius <= 1e-9) {
      return const _TangentFitResult(
        required: true,
        failure: SketchCircularFitFailure.unstableRadius,
      );
    }
    // Coincident endpoints are not enough: the arc tangent must follow the
    // oriented neighbour tangent at both extremities.  A named reference that
    // is attached but points the other way is reported as reversed so the UI
    // can explain that the wrong curve was picked.
    final tangencyFailure = _bilateralTangencyFailure(
      center: center,
      start: boundary.start,
      startDirection: startDirection,
      end: boundary.end,
      endDirection: endDirection,
    );
    if (tangencyFailure != null) {
      return _TangentFitResult(required: true, failure: tangencyFailure);
    }
    return _TangentFitResult(required: true, fit: (center, radius));
  }

  /// Offset along the perpendicular bisector of the preserved endpoints for
  /// the circle that balances the bilateral C1 residual.
  ///
  /// For the parametrisation described in [_tangentFit] the two residuals are
  /// `u0(t) = A - tB` and `u1(t) = G - tD`, so the worst-case (minimax) optimum
  /// sits where they cross, `u0(t) = +-u1(t)`.  The least-squares root of the
  /// quadratic `F t^2 + (E D0 - G) t - F D0 = 0` is kept as a fallback for the
  /// pathologically asymmetric case.  [preferredSide] keeps the arc bulging on
  /// the same side as the normal intersection, so a fully consistent chain
  /// returns that exact intersection.  `null` means the system is degenerate.
  double? _bilateralTangentOffset({
    required SketchVector start,
    required SketchVector end,
    required SketchVector startDirection,
    required SketchVector endDirection,
    required SketchVector bisector,
    required double axisLength,
    required double preferredSide,
  }) {
    final startLength = math.sqrt(startDirection.dot(startDirection));
    final endLength = math.sqrt(endDirection.dot(endDirection));
    if (startLength <= 1e-12 || endLength <= 1e-12) return null;
    final p = startDirection.scale(1 / startLength);
    final q = endDirection.scale(1 / endLength);
    final half = (end - start).scale(.5);
    final d0 = axisLength * axisLength / 4;
    final a = -half.dot(p);
    final b = bisector.dot(p);
    final c = half.dot(q);
    final d = bisector.dot(q);
    final e = b * b + d * d;
    final f = a * b + c * d;
    final g = a * a + c * c;

    double worstResidual(double t) {
      final u0 = a - t * b;
      final u1 = c - t * d;
      return math.max(u0 * u0, u1 * u1) / (d0 + t * t);
    }

    final candidates = <double>[];
    // Minimax crossing points.
    if ((b + d).abs() > 1e-12) candidates.add((a + c) / (b + d));
    if ((b - d).abs() > 1e-12) candidates.add((a - c) / (b - d));
    // Least-squares roots as a safety net.
    if (f.abs() > 1e-12) {
      final linear = e * d0 - g;
      final discriminant = linear * linear + 4 * f * f * d0;
      if (discriminant >= 0) {
        final root = math.sqrt(discriminant);
        candidates
          ..add((-linear + root) / (2 * f))
          ..add((-linear - root) / (2 * f));
      }
    } else if ((e * d0 - g).abs() > 1e-12) {
      candidates.add(0);
    }
    candidates.removeWhere((value) => !value.isFinite);
    if (candidates.isEmpty) return null;
    final matchesSide = candidates
        .where((value) => value.sign == preferredSide.sign)
        .toList();
    final pool = matchesSide.isEmpty ? candidates : matchesSide;
    pool.sort(
      (first, second) => worstResidual(first).compareTo(worstResidual(second)),
    );
    return pool.first;
  }

  /// True when the arc centred at [center] leaves [start] along
  /// [startDirection] and arrives at [end] along [endDirection] within
  /// [_maxTangencyAngle].  The check is the dot product between the arc tangent
  /// and the oriented neighbour tangent, so perpendicularity *and* traversal
  /// sense must both hold: an arc sharing only the endpoints, or running
  /// backwards, is never accepted.
  /// Sine of the angle between the radius at [point] and [direction].
  ///
  /// Zero means [direction] is a tangent line of the circle centred at
  /// [center].  `null` when either vector is degenerate.
  double? _tangentLineSine(
    SketchVector point,
    SketchVector center,
    SketchVector direction,
  ) {
    final radius = point - center;
    final radiusLength = math.sqrt(radius.dot(radius));
    final directionLength = math.sqrt(direction.dot(direction));
    if (radiusLength <= 1e-10 || directionLength <= 1e-10) return null;
    return radius.dot(direction).abs() / (radiusLength * directionLength);
  }

  /// Traversal sense about [center] implied by an oriented tangent [direction]
  /// at [point]: `1` counter-clockwise, `-1` clockwise, `0` when the direction
  /// is not a tangent of that circle.
  ///
  /// This is what lets a concave profile, or any chain walked clockwise around
  /// its centre, validate exactly like a counter-clockwise one: the sense is
  /// taken from the chain, never assumed.
  double _arcSense(
    SketchVector point,
    SketchVector center,
    SketchVector direction,
  ) {
    final sine = _tangentLineSine(point, center, direction);
    if (sine == null || sine > math.sin(_maxTangencyAngle)) return 0;
    final radius = point - center;
    final radiusLength = math.sqrt(radius.dot(radius));
    final directionLength = math.sqrt(direction.dot(direction));
    final ccw = SketchVector(-radius.y / radiusLength, radius.x / radiusLength);
    final projection = ccw.dot(direction) / directionLength;
    return projection.sign;
  }

  /// True when the circle centred at [center] follows the oriented
  /// [direction] at [point] for the given traversal [sense].
  bool _followsTangentAt(
    SketchVector point,
    SketchVector center,
    SketchVector direction,
    double sense,
  ) {
    if (sense == 0) return false;
    final sine = _tangentLineSine(point, center, direction);
    if (sine == null || sine > math.sin(_maxTangencyAngle)) return false;
    final radius = point - center;
    final radiusLength = math.sqrt(radius.dot(radius));
    final directionLength = math.sqrt(direction.dot(direction));
    final ccw = SketchVector(-radius.y / radiusLength, radius.x / radiusLength);
    return (ccw.dot(direction) / directionLength) * sense >=
        math.cos(_maxTangencyAngle);
  }

  /// Validates the C1 condition of the tangent circle, returning the precise
  /// failure or `null` when both extremities are satisfied.
  ///
  /// The tangent line at each endpoint has to be parallel to the oriented
  /// neighbour and the traversal sense has to be the same on both sides, which
  /// is derived from the chain instead of assuming counter-clockwise.  An arc
  /// sharing only the endpoints, or walked the wrong way, is never accepted.
  SketchCircularFitFailure? _bilateralTangencyFailure({
    required SketchVector center,
    required SketchVector start,
    required SketchVector startDirection,
    required SketchVector end,
    required SketchVector endDirection,
  }) {
    if (!center.x.isFinite || !center.y.isFinite) {
      return SketchCircularFitFailure.unstableRadius;
    }
    if (_tangentLineSine(start, center, startDirection) == null ||
        _tangentLineSine(end, center, endDirection) == null) {
      return SketchCircularFitFailure.unstableRadius;
    }
    var sense = _arcSense(start, center, startDirection);
    if (sense == 0) sense = _arcSense(end, center, endDirection);
    if (sense == 0) return SketchCircularFitFailure.incompatibleTangency;
    if (!_followsTangentAt(start, center, startDirection, sense) ||
        !_followsTangentAt(end, center, endDirection, sense)) {
      return SketchCircularFitFailure.incompatibleTangency;
    }
    return null;
  }

  /// Returns the least radial-error circle that preserves both chain boundary
  /// points and is tangent to exactly one real continuation. This is the
  /// middle step between bilateral C1 and the unconstrained three-point fit.
  (SketchVector, double)? _partialTangentFit(
    ({SketchVector start, SketchVector end}) boundary,
    Set<String> selectedIds,
    Iterable<SketchEntity> context,
    List<SketchVector> samples,
  ) {
    final candidates = <(SketchVector, double)>[];
    void addFor(
      SketchVector point,
      SketchVector other,
      SketchVector direction,
    ) {
      final normal = SketchVector(-direction.y, direction.x);
      final chord = other - point;
      final denominator = normal.dot(chord);
      if (denominator.abs() <= 1e-10) return;
      final center = point + normal.scale(chord.dot(chord) / (2 * denominator));
      final radius = _distance(center, point);
      if (!radius.isFinite || radius <= 1e-9) return;
      final tolerance = math.max(1e-7, radius * 1e-6);
      if ((_distance(center, other) - radius).abs() > tolerance) return;
      candidates.add((center, radius));
    }

    final start = _neighborTangents(
      boundary.start,
      selectedIds,
      context,
    ).directions;
    final end = _neighborTangents(
      boundary.end,
      selectedIds,
      context,
    ).directions;
    if (start.length == 1) {
      addFor(boundary.start, boundary.end, start.single.scale(-1));
    }
    if (end.length == 1) addFor(boundary.end, boundary.start, end.single);
    if (candidates.isEmpty) return null;
    candidates.sort((first, second) {
      double error((SketchVector, double) fit) => samples
          .map((point) => (_distance(point, fit.$1) - fit.$2).abs())
          .fold<double>(0, (sum, value) => sum + value);
      return error(first).compareTo(error(second));
    });
    final best = candidates.first;
    return _isSaneCircularFit(samples, best.$1, best.$2) ? best : null;
  }

  bool _hasC1Tangency(
    Iterable<SketchEntity> context, {
    required Set<String> selectedIds,
    required SketchVector center,
    required SketchVector startPoint,
    required SketchVector endPoint,
    String? startTangencyId,
    String? endTangencyId,
  }) {
    final startCandidates = _neighborTangents(
      startPoint,
      selectedIds,
      context,
      manualId: startTangencyId,
    ).directions;
    final endCandidates = _neighborTangents(
      endPoint,
      selectedIds,
      context,
      manualId: endTangencyId,
    ).directions;
    if (startCandidates.length != 1 || endCandidates.length != 1) return false;
    // [center] is deliberately an argument: the tangents are evaluated on the
    // fitted arc endpoints, not on a source segment that happens to share those
    // points.  The neighbour at the start arrives at the chain, so the arc has
    // to leave it in the opposite direction; the arrival at the end keeps the
    // neighbour orientation.
    return _bilateralTangencyFailure(
          center: center,
          start: startPoint,
          startDirection: startCandidates.single.scale(-1),
          end: endPoint,
          endDirection: endCandidates.single,
        ) ==
        null;
  }

  bool _hasAnyC1Tangency(
    Iterable<SketchEntity> context, {
    required Set<String> selectedIds,
    required SketchVector center,
    required SketchVector startPoint,
    required SketchVector endPoint,
    String? startTangencyId,
    String? endTangencyId,
  }) {
    final startCandidates = _neighborTangents(
      startPoint,
      selectedIds,
      context,
      manualId: startTangencyId,
    ).directions;
    final endCandidates = _neighborTangents(
      endPoint,
      selectedIds,
      context,
      manualId: endTangencyId,
    ).directions;
    // One sided fallback: accept the arc when it is a real tangent line of the
    // circle at that endpoint.  The traversal sense is taken from the same
    // direction, so a clockwise or concave continuation is accepted too.
    if (!center.x.isFinite || !center.y.isFinite) return false;
    bool follows(SketchVector point, SketchVector direction) {
      final sense = _arcSense(point, center, direction);
      return sense != 0 && _followsTangentAt(point, center, direction, sense);
    }

    return (startCandidates.length == 1 &&
            follows(startPoint, startCandidates.single.scale(-1))) ||
        (endCandidates.length == 1 && follows(endPoint, endCandidates.single));
  }

  ({SketchVector start, SketchVector end})? _continuousChainBoundaries(
    List<SketchEntity> entities,
  ) {
    if (entities.length < 2) return null;
    final endpoints = <({String entityId, SketchVector point})>[];
    for (final entity in entities) {
      if (entity is SketchLine) {
        endpoints
          ..add((
            entityId: entity.id,
            point: SketchVector.fromJson(entity.parameters['start']),
          ))
          ..add((
            entityId: entity.id,
            point: SketchVector.fromJson(entity.parameters['end']),
          ));
      } else if (entity is SketchSpline) {
        final raw =
            (entity.parameters['sampledPoints'] ?? entity.parameters['points'])
                as List?;
        final points =
            raw?.whereType<List>().map(SketchVector.fromJson).toList() ??
            const <SketchVector>[];
        if (points.length < 2) return null;
        endpoints
          ..add((entityId: entity.id, point: points.first))
          ..add((entityId: entity.id, point: points.last));
      } else {
        return null;
      }
    }
    final groups = <List<int>>[];
    for (var index = 0; index < endpoints.length; index++) {
      final group = groups.firstWhere(
        (candidate) => candidate.any(
          (other) =>
              _distance(endpoints[index].point, endpoints[other].point) <= 1e-7,
        ),
        orElse: () {
          final created = <int>[];
          groups.add(created);
          return created;
        },
      );
      group.add(index);
    }
    final external = groups.where((group) => group.length == 1).toList();
    if (external.length != 2 || groups.any((group) => group.length > 2)) {
      return null;
    }
    final adjacent = <String, Set<String>>{
      for (final entity in entities) entity.id: <String>{},
    };
    for (final group in groups.where((group) => group.length == 2)) {
      final first = endpoints[group.first].entityId;
      final second = endpoints[group.last].entityId;
      if (first != second) {
        adjacent[first]!.add(second);
        adjacent[second]!.add(first);
      }
    }
    final visited = <String>{entities.first.id};
    final pending = <String>[entities.first.id];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      for (final next in adjacent[current]!) {
        if (visited.add(next)) pending.add(next);
      }
    }
    if (visited.length != entities.length) return null;
    return (
      start: endpoints[external.first.single].point,
      end: endpoints[external.last.single].point,
    );
  }

  (SketchVector, double)? _circleThrough(
    SketchVector first,
    SketchVector middle,
    SketchVector last,
  ) {
    final determinant =
        2 *
        (first.x * (middle.y - last.y) +
            middle.x * (last.y - first.y) +
            last.x * (first.y - middle.y));
    if (determinant.abs() <= 1e-12) return null;
    final first2 = first.dot(first);
    final middle2 = middle.dot(middle);
    final last2 = last.dot(last);
    final center = SketchVector(
      (first2 * (middle.y - last.y) +
              middle2 * (last.y - first.y) +
              last2 * (first.y - middle.y)) /
          determinant,
      (first2 * (last.x - middle.x) +
              middle2 * (first.x - last.x) +
              last2 * (middle.x - first.x)) /
          determinant,
    );
    return (center, _distance(center, first));
  }

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
