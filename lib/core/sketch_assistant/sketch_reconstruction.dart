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
}

class _TangentFitResult {
  const _TangentFitResult({required this.required, this.fit, this.failure});

  /// True when both real neighbours exist.  In that case a three-point arc is
  /// not an authorised substitute for an invalid C1 solution.
  final bool required;
  final (SketchVector, double)? fit;
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
  SketchReconstructionSuggestion? fitSelectedCircular(
    Iterable<SketchEntity> selected, {
    Iterable<SketchEntity> context = const <SketchEntity>[],
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
    // A least-squares circle can move its endpoints away from the source
    // chain. When the chain has two neighboring lines, their normals define
    // the only circle that can remain C1 at both retained boundary vertices.
    // A three-point fallback is valid only when C1 is underdetermined (one or
    // both real neighbours are absent).  If both neighbours exist, an
    // inconsistent tangent solution is a diagnostic failure, not a fit.
    final tangent = _tangentFit(
      boundary,
      entities.map((entity) => entity.id).toSet(),
      context,
    );
    if (tangent.required && tangent.fit == null) return null;
    final fit =
        tangent.fit ??
        _circleThrough(boundary.start, anchor.first, boundary.end);
    if (fit == null || !_isSaneCircularFit(uniquePoints, fit.$1, fit.$2)) {
      return null;
    }
    final error =
        uniquePoints
            .map((point) => (_distance(point, fit.$1) - fit.$2).abs())
            .fold<double>(0, (sum, value) => sum + value) /
        uniquePoints.length;
    final startAngle = math.atan2(
      boundary.start.y - fit.$1.y,
      boundary.start.x - fit.$1.x,
    );
    final endAngle = math.atan2(
      boundary.end.y - fit.$1.y,
      boundary.end.x - fit.$1.x,
    );
    final anchorAngle = math.atan2(
      anchor.first.y - fit.$1.y,
      anchor.first.x - fit.$1.x,
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
    // Intersecting normals proves only G1 up to sign.  The selected chain has
    // an actual traversal direction, so verify the arc leaves/arrives in the
    // same direction as its real neighbouring curves.  This prevents a
    // geometrically coincident arc from reversing at either endpoint.
    if (tangent.required &&
        !_hasC1Tangency(
          context,
          selectedIds: entities.map((entity) => entity.id).toSet(),
          center: fit.$1,
          startAngle: arcStart,
          endAngle: arcStart + sweep,
          startPoint: arcStartPoint,
          endPoint: arcEndPoint,
        )) {
      return null;
    }
    return SketchReconstructionSuggestion(
      kind: SketchReconstructionKind.arc,
      entityIds: entities.map((entity) => entity.id).toList(growable: false),
      confidence: (1 - error / math.max(math.max(.5, fit.$2 * .05), 1e-9))
          .clamp(0.0, 1.0),
      center: fit.$1,
      radius: fit.$2,
      startAngle: arcStart,
      endAngle: arcStart + sweep,
      startPoint: arcStartPoint,
      endPoint: arcEndPoint,
    );
  }

  /// Explains why a manual circular fit could not be proposed.  This mirrors
  /// the conservative fit gates so the UI can distinguish geometric input
  /// errors from a genuine C1 incompatibility.
  SketchCircularFitFailure diagnoseSelectedCircular(
    Iterable<SketchEntity> selected, {
    Iterable<SketchEntity> context = const <SketchEntity>[],
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
    final tangent = _tangentFit(boundary, selectedIds, context);
    if (tangent.required && tangent.fit == null) {
      return tangent.failure ?? SketchCircularFitFailure.incompatibleTangency;
    }
    final fit =
        tangent.fit ?? _circleThrough(boundary.start, anchor, boundary.end);
    if (fit == null || !_isSaneCircularFit(uniquePoints, fit.$1, fit.$2)) {
      return SketchCircularFitFailure.unstableRadius;
    }
    final angles = _arcDefinition(boundary, anchor, fit.$1);
    if (angles == null) return SketchCircularFitFailure.unstableRadius;
    if (tangent.required &&
        !_hasC1Tangency(
          context,
          selectedIds: selectedIds,
          center: fit.$1,
          startAngle: angles.startAngle,
          endAngle: angles.endAngle,
          startPoint: angles.startPoint,
          endPoint: angles.endPoint,
        )) {
      return SketchCircularFitFailure.incompatibleTangency;
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

  List<SketchVector> _neighborTangents(
    SketchVector endpoint,
    Set<String> selectedIds,
    Iterable<SketchEntity> context,
  ) => context
      .where((entity) => !selectedIds.contains(entity.id) && entity.visible)
      .map((entity) => _endpointTangent(entity, endpoint))
      .whereType<SketchVector>()
      .toList(growable: false);

  /// Circle that stays C1 with both supported neighbouring curves, or null
  /// when the chain has fewer than two valid neighbours or they conflict.
  _TangentFitResult _tangentFit(
    ({SketchVector start, SketchVector end}) boundary,
    Set<String> selectedIds,
    Iterable<SketchEntity> context,
  ) {
    final startCandidates = _neighborTangents(
      boundary.start,
      selectedIds,
      context,
    );
    final endCandidates = _neighborTangents(boundary.end, selectedIds, context);
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
    // Center = start + u * normal(startDirection) = end + v * normal(end).
    final startNormal = SketchVector(-startDirection.y, startDirection.x);
    final endNormal = SketchVector(-endDirection.y, endDirection.x);
    final dx = boundary.end.x - boundary.start.x;
    final dy = boundary.end.y - boundary.start.y;
    final cross = startNormal.x * endNormal.y - startNormal.y * endNormal.x;
    if (cross.abs() <= 1e-10) return const _TangentFitResult(required: true);
    final u = (dx * endNormal.y - dy * endNormal.x) / cross;
    final center = SketchVector(
      boundary.start.x + u * startNormal.x,
      boundary.start.y + u * startNormal.y,
    );
    final startRadius = _distance(center, boundary.start);
    final endRadius = _distance(center, boundary.end);
    final tolerance = math.max(1e-7, math.max(startRadius, endRadius) * 1e-6);
    if (!startRadius.isFinite ||
        startRadius <= 1e-9 ||
        (startRadius - endRadius).abs() > tolerance) {
      return const _TangentFitResult(required: true);
    }
    return _TangentFitResult(required: true, fit: (center, startRadius));
  }

  bool _hasC1Tangency(
    Iterable<SketchEntity> context, {
    required Set<String> selectedIds,
    required SketchVector center,
    required double startAngle,
    required double endAngle,
    required SketchVector startPoint,
    required SketchVector endPoint,
  }) {
    final startCandidates = _neighborTangents(startPoint, selectedIds, context);
    final endCandidates = _neighborTangents(endPoint, selectedIds, context);
    if (startCandidates.length != 1 || endCandidates.length != 1) return false;
    SketchVector arcTangent(double angle) =>
        SketchVector(-math.sin(angle), math.cos(angle));
    bool aligned(SketchVector first, SketchVector second) {
      final firstLength = math.sqrt(first.dot(first));
      final secondLength = math.sqrt(second.dot(second));
      if (firstLength <= 1e-10 || secondLength <= 1e-10) return false;
      return first.dot(second) / (firstLength * secondLength) >= 1 - 1e-6;
    }

    // [center] is deliberately an argument: keeping it here documents that
    // the tangents are evaluated on the fitted arc endpoints, not on a source
    // segment that merely happens to share those points.
    if (!center.x.isFinite || !center.y.isFinite) return false;
    return aligned(arcTangent(startAngle), startCandidates.single.scale(-1)) &&
        aligned(arcTangent(endAngle), endCandidates.single);
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
