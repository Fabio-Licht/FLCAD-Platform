import 'dart:math' as math;

import '../../sketch_engine/entities/sketch_entities.dart';
import '../../sketch_engine/models/sketch_models.dart';

enum SketchHealthIssueType {
  gap,
  duplicate,
  overlap,
  selfIntersection,
  tinyGeometry,
  openEnd,
  disconnected,
}

enum SketchHealthIssueSeverity { error, warning }

enum SketchHealthIssueScope { activeProfile, sketch }

class SketchHealthIssue {
  const SketchHealthIssue({
    required this.type,
    required this.message,
    required this.entityIds,
    required this.locations,
    this.distance,
    this.endpointReferences = const [],
    this.canAutoHeal = false,
    this.severity = SketchHealthIssueSeverity.error,
    this.scope = SketchHealthIssueScope.activeProfile,
  });
  final SketchHealthIssueType type;
  final String message;
  final List<String> entityIds;
  final List<SketchVector> locations;
  final double? distance;
  final List<String> endpointReferences;
  final bool canAutoHeal;
  final SketchHealthIssueSeverity severity;
  final SketchHealthIssueScope scope;
  bool get blocking => severity == SketchHealthIssueSeverity.error;
}

class SketchHealthReport {
  const SketchHealthReport({
    required this.issues,
    required this.closedProfile,
    this.activeProfileEntityIds = const <String>{},
    this.diagnosticEntityIds = const <String>{},
  });
  final List<SketchHealthIssue> issues;
  final bool closedProfile;
  final Set<String> activeProfileEntityIds;
  final Set<String> diagnosticEntityIds;
  Iterable<SketchHealthIssue> ofType(SketchHealthIssueType type) =>
      issues.where((issue) => issue.type == type);
  Iterable<SketchHealthIssue> get blockingIssues =>
      issues.where((issue) => issue.blocking);
  Iterable<SketchHealthIssue> get warningIssues =>
      issues.where((issue) => !issue.blocking);
  Iterable<SketchHealthIssue> blockingOfType(SketchHealthIssueType type) =>
      blockingIssues.where((issue) => issue.type == type);
  bool get hasGaps => blockingOfType(SketchHealthIssueType.gap).isNotEmpty;
  bool get hasDuplicates => blockingIssues.any(
    (issue) =>
        issue.type == SketchHealthIssueType.duplicate ||
        issue.type == SketchHealthIssueType.overlap,
  );
  bool get hasSelfIntersections =>
      blockingOfType(SketchHealthIssueType.selfIntersection).isNotEmpty;
  bool get hasTinyGeometry =>
      blockingOfType(SketchHealthIssueType.tinyGeometry).isNotEmpty;
  bool get hasOpenEnds =>
      blockingOfType(SketchHealthIssueType.openEnd).isNotEmpty;
  bool get hasDisconnected =>
      ofType(SketchHealthIssueType.disconnected).isNotEmpty;
  bool get hasDisconnectedWarnings => ofType(
    SketchHealthIssueType.disconnected,
  ).any((issue) => !issue.blocking);
  bool get readyForSurface =>
      closedProfile &&
      activeProfileEntityIds.isNotEmpty &&
      !hasGaps &&
      !hasDuplicates &&
      !hasSelfIntersections &&
      !hasTinyGeometry &&
      !hasOpenEnds;
}

class SketchHealthAnalyzer {
  const SketchHealthAnalyzer({
    this.connectionTolerance = 1e-4,
    this.gapTolerance = .1,
    this.tinyThreshold = .01,
  });
  final double connectionTolerance, gapTolerance, tinyThreshold;

  SketchHealthReport analyze(
    Iterable<SketchEntity> source, {
    Iterable<String> activeSelection = const <String>[],
  }) {
    final entities = source
        .where(
          (entity) =>
              entity.visible && !entity.construction && !entity.reference,
        )
        .toList(growable: false);
    final issues = <SketchHealthIssue>[];
    final endpoints = <_Endpoint>[];
    final endpointIndicesByEntity = <String, List<int>>{};
    final signatures = <String, String>{};
    final tinyCandidates = <SketchHealthIssue>[];
    final duplicateCandidates = <SketchHealthIssue>[];
    for (final entity in entities) {
      final entityEndpoints = _endpoints(entity);
      endpointIndicesByEntity[entity.id] = [
        for (var i = 0; i < entityEndpoints.length; i++) endpoints.length + i,
      ];
      endpoints.addAll(entityEndpoints);
      final measure = _measure(entity);
      if (measure != null && measure < tinyThreshold) {
        tinyCandidates.add(
          SketchHealthIssue(
            type: SketchHealthIssueType.tinyGeometry,
            message:
                'Tiny ${entity.type.name}: ${measure.toStringAsFixed(6)} mm',
            entityIds: [entity.id],
            locations: _endpoints(entity).map((item) => item.point).toList(),
          ),
        );
      }
      final signature = _signature(entity);
      if (signature != null) {
        final prior = signatures[signature];
        if (prior == null) {
          signatures[signature] = entity.id;
        } else {
          duplicateCandidates.add(
            SketchHealthIssue(
              type: SketchHealthIssueType.duplicate,
              message: 'Duplicate geometry',
              entityIds: [prior, entity.id],
              locations: _sample(entity),
            ),
          );
        }
      }
    }

    final parent = <String, String>{
      for (final entity in entities) entity.id: entity.id,
    };
    String root(String id) {
      var current = id;
      while (parent[current] != current) {
        current = parent[current]!;
      }
      return current;
    }

    // Endpoints that share a real vertex are grouped first.  Merely knowing
    // that every endpoint touched *something* is not enough to prove a
    // closed profile: a T-junction, for example, touches three endpoints but
    // is not a cycle.  A valid wire loop has degree two at every vertex.
    final endpointParent = <int, int>{
      for (var index = 0; index < endpoints.length; index++) index: index,
    };
    int endpointRoot(int index) {
      var current = index;
      while (endpointParent[current] != current) {
        current = endpointParent[current]!;
      }
      return current;
    }

    void unionEndpoints(int first, int second) {
      final firstRoot = endpointRoot(first);
      final secondRoot = endpointRoot(second);
      if (firstRoot != secondRoot) endpointParent[secondRoot] = firstRoot;
    }

    for (var i = 0; i < endpoints.length; i++) {
      for (var j = i + 1; j < endpoints.length; j++) {
        if (_distance(endpoints[i].point, endpoints[j].point) <=
            connectionTolerance) {
          unionEndpoints(i, j);
        }
      }
    }
    final endpointIndicesByVertex = <int, List<int>>{};
    for (var index = 0; index < endpoints.length; index++) {
      endpointIndicesByVertex
          .putIfAbsent(endpointRoot(index), () => <int>[])
          .add(index);
    }
    for (final vertexIndices in endpointIndicesByVertex.values) {
      for (var index = 1; index < vertexIndices.length; index++) {
        final first = endpoints[vertexIndices.first].entityId;
        final other = endpoints[vertexIndices[index]].entityId;
        if (first != other) parent[root(other)] = root(first);
      }
    }
    final components = <String, List<String>>{};
    for (final entity in entities) {
      components.putIfAbsent(root(entity.id), () => []).add(entity.id);
    }
    final entityById = {for (final entity in entities) entity.id: entity};
    final closedComponents = components.values
        .where(
          (component) => _componentClosed(
            component,
            entityById,
            endpointIndicesByEntity,
            endpointIndicesByVertex,
          ),
        )
        .toList(growable: false);
    final selectedIds = activeSelection.where(entityById.containsKey).toSet();
    final selectedComponents = selectedIds.isEmpty
        ? const <List<String>>[]
        : components.values
              .where((component) => component.any(selectedIds.contains))
              .toList(growable: false);
    final largestClosedComponent = closedComponents.isEmpty
        ? null
        : (closedComponents.toList()..sort(
                (a, b) => _componentMeasure(
                  b,
                  entityById,
                ).compareTo(_componentMeasure(a, entityById)),
              ))
              .first;
    final largestComponent = components.values.isEmpty
        ? null
        : (components.values.toList()..sort(
                (a, b) => _componentMeasure(
                  b,
                  entityById,
                ).compareTo(_componentMeasure(a, entityById)),
              ))
              .first;
    // A live selection is intentional user input.  Never silently replace an
    // open selected chain with an unrelated closed loop elsewhere in Sketch.
    final activeComponents = selectedComponents.isNotEmpty
        ? selectedComponents
        : largestClosedComponent == null
        ? (largestComponent == null
              ? const <List<String>>[]
              : [largestComponent])
        : [largestClosedComponent];
    final activeProfileIds = activeComponents.expand((item) => item).toSet();
    final closedProfile =
        activeComponents.length == 1 &&
        _componentClosed(
          activeComponents.single,
          entityById,
          endpointIndicesByEntity,
          endpointIndicesByVertex,
        );
    final validationScope = closedProfile
        ? activeProfileIds
        : entities.map((entity) => entity.id).toSet();
    final diagnosticIds = {
      for (final entity in entities)
        if (!activeProfileIds.contains(entity.id)) entity.id,
    };
    bool inValidationScope(String id) =>
        validationScope.isEmpty || validationScope.contains(id);
    bool allInValidationScope(Iterable<String> ids) =>
        ids.every(inValidationScope);
    void addIssue(SketchHealthIssue issue) {
      final blocking = !closedProfile || allInValidationScope(issue.entityIds);
      issues.add(
        SketchHealthIssue(
          type: issue.type,
          message: issue.message,
          entityIds: issue.entityIds,
          locations: issue.locations,
          distance: issue.distance,
          endpointReferences: issue.endpointReferences,
          canAutoHeal: issue.canAutoHeal && blocking,
          severity: blocking
              ? SketchHealthIssueSeverity.error
              : SketchHealthIssueSeverity.warning,
          scope: blocking
              ? SketchHealthIssueScope.activeProfile
              : SketchHealthIssueScope.sketch,
        ),
      );
    }

    for (final issue in tinyCandidates) {
      if (!closedProfile || allInValidationScope(issue.entityIds)) {
        addIssue(issue);
      }
    }
    for (final issue in duplicateCandidates) {
      addIssue(issue);
    }
    if (diagnosticIds.isNotEmpty && closedProfile) {
      final diagnosticEntities = diagnosticIds
          .map((id) => entityById[id])
          .whereType<SketchEntity>()
          .toList(growable: false);
      issues.add(
        SketchHealthIssue(
          type: SketchHealthIssueType.disconnected,
          message:
              '${diagnosticEntities.length} loose entities outside active profile',
          entityIds: diagnosticEntities.map((entity) => entity.id).toList(),
          locations: diagnosticEntities
              .expand(_sample)
              .take(64)
              .toList(growable: false),
          severity: SketchHealthIssueSeverity.warning,
          scope: SketchHealthIssueScope.sketch,
        ),
      );
    } else if (!closedProfile && components.length > 1) {
      final disconnected = components.values
          .skip(1)
          .expand((component) => component)
          .toList(growable: false);
      final representative = disconnected
          .map((id) => entityById[id])
          .whereType<SketchEntity>()
          .firstOrNull;
      issues.add(
        SketchHealthIssue(
          type: SketchHealthIssueType.disconnected,
          message: 'Disconnected profile entities',
          entityIds: disconnected,
          locations: representative == null
              ? const []
              : _sample(representative).take(1).toList(),
        ),
      );
    }
    final loose = [
      for (var i = 0; i < endpoints.length; i++)
        if ((endpointIndicesByVertex[endpointRoot(i)]?.length ?? 0) != 2 &&
            inValidationScope(endpoints[i].entityId))
          i,
    ];
    final gapEndpoints = <int>{};
    for (var a = 0; a < loose.length; a++) {
      for (var b = a + 1; b < loose.length; b++) {
        final first = endpoints[loose[a]], second = endpoints[loose[b]];
        if (first.entityId == second.entityId) continue;
        final distance = _distance(first.point, second.point);
        if (distance > connectionTolerance && distance <= gapTolerance) {
          gapEndpoints
            ..add(loose[a])
            ..add(loose[b]);
          issues.add(
            SketchHealthIssue(
              type: SketchHealthIssueType.gap,
              message: 'Gap ${distance.toStringAsFixed(3)} mm',
              entityIds: [first.entityId, second.entityId],
              locations: [first.point, second.point],
              distance: distance,
              endpointReferences: [first.reference, second.reference],
              canAutoHeal: true,
            ),
          );
        }
      }
    }
    final reportedOpenVertices = <int>{};
    for (final index in loose.where((index) => !gapEndpoints.contains(index))) {
      final vertex = endpointRoot(index);
      if (!reportedOpenVertices.add(vertex)) continue;
      final endpoint = endpoints[index];
      issues.add(
        SketchHealthIssue(
          type: SketchHealthIssueType.openEnd,
          message: (endpointIndicesByVertex[vertex]?.length ?? 0) > 2
              ? 'Open or branched endpoint'
              : 'Open endpoint',
          entityIds: [
            for (final endpointIndex in endpointIndicesByVertex[vertex] ?? [])
              endpoints[endpointIndex].entityId,
          ],
          locations: [endpoint.point],
          endpointReferences: [
            for (final endpointIndex in endpointIndicesByVertex[vertex] ?? [])
              endpoints[endpointIndex].reference,
          ],
        ),
      );
    }

    for (var i = 0; i < entities.length; i++) {
      if (!inValidationScope(entities[i].id)) continue;
      final selfHit = _selfIntersection(entities[i]);
      if (selfHit != null) {
        issues.add(
          SketchHealthIssue(
            type: SketchHealthIssueType.selfIntersection,
            message: 'Profile entity crosses itself',
            entityIds: [entities[i].id],
            locations: [selfHit],
          ),
        );
      }
      for (var j = i + 1; j < entities.length; j++) {
        if (!inValidationScope(entities[j].id)) continue;
        if (_isDuplicatePair(issues, entities[i].id, entities[j].id)) continue;
        final intersection = _interiorIntersection(entities[i], entities[j]);
        if (intersection != null) {
          issues.add(
            SketchHealthIssue(
              type: SketchHealthIssueType.selfIntersection,
              message: 'Profile entities cross',
              entityIds: [entities[i].id, entities[j].id],
              locations: [intersection],
            ),
          );
        } else if (_overlap(entities[i], entities[j])) {
          issues.add(
            SketchHealthIssue(
              type: SketchHealthIssueType.overlap,
              message: 'Overlapping geometry',
              entityIds: [entities[i].id, entities[j].id],
              locations: [..._sample(entities[i]), ..._sample(entities[j])],
            ),
          );
        }
      }
    }
    return SketchHealthReport(
      issues: List.unmodifiable(issues),
      closedProfile: closedProfile,
      activeProfileEntityIds: Set.unmodifiable(activeProfileIds),
      diagnosticEntityIds: Set.unmodifiable(diagnosticIds),
    );
  }

  bool _componentClosed(
    List<String> component,
    Map<String, SketchEntity> entityById,
    Map<String, List<int>> endpointIndicesByEntity,
    Map<int, List<int>> endpointIndicesByVertex,
  ) {
    if (component.any((id) => entityById[id] is SketchCircle)) return true;
    final indices = [
      for (final id in component)
        ...endpointIndicesByEntity[id] ?? const <int>[],
    ];
    if (indices.isEmpty) return false;
    final indexSet = indices.toSet();
    return endpointIndicesByVertex.values
        .where((vertex) => vertex.any(indexSet.contains))
        .every((vertex) => vertex.length == 2);
  }

  double _componentMeasure(
    List<String> component,
    Map<String, SketchEntity> entityById,
  ) {
    var value = 0.0;
    for (final id in component) {
      final entity = entityById[id];
      if (entity != null) value += _measure(entity) ?? 0.0;
    }
    return value;
  }

  List<_Endpoint> _endpoints(SketchEntity entity) {
    if (entity is SketchLine) {
      return [
        _Endpoint(
          entity.id,
          '${entity.id}:start',
          SketchVector.fromJson(entity.parameters['start']),
        ),
        _Endpoint(
          entity.id,
          '${entity.id}:end',
          SketchVector.fromJson(entity.parameters['end']),
        ),
      ];
    }
    if (entity is SketchArc) {
      final c = SketchVector.fromJson(entity.parameters['center']);
      final r = (entity.parameters['radius'] as num).toDouble();
      final a = (entity.parameters['startAngle'] as num).toDouble();
      final b = (entity.parameters['endAngle'] as num).toDouble();
      return [
        _Endpoint(
          entity.id,
          '${entity.id}:start',
          SketchVector(c.x + r * math.cos(a), c.y + r * math.sin(a)),
        ),
        _Endpoint(
          entity.id,
          '${entity.id}:end',
          SketchVector(c.x + r * math.cos(b), c.y + r * math.sin(b)),
        ),
      ];
    }
    if (entity is SketchSpline) {
      final points = _sample(entity);
      if (points.length < 2) return const [];
      return [
        _Endpoint(entity.id, '${entity.id}:start', points.first),
        _Endpoint(entity.id, '${entity.id}:end', points.last),
      ];
    }
    return const [];
  }

  double? _measure(SketchEntity entity) {
    if (entity is SketchLine) {
      return _distance(
        SketchVector.fromJson(entity.parameters['start']),
        SketchVector.fromJson(entity.parameters['end']),
      );
    }
    if (entity is SketchArc) {
      final radius = (entity.parameters['radius'] as num).toDouble();
      final sweep =
          ((entity.parameters['endAngle'] as num).toDouble() -
                  (entity.parameters['startAngle'] as num).toDouble())
              .abs();
      return radius * sweep;
    }
    if (entity is SketchCircle) {
      return (entity.parameters['radius'] as num).toDouble() * math.pi * 2;
    }
    if (entity is SketchSpline) {
      final points = _sample(entity);
      var length = 0.0;
      for (var i = 1; i < points.length; i++) {
        length += _distance(points[i - 1], points[i]);
      }
      return length;
    }
    return null;
  }

  String? _signature(SketchEntity entity) {
    String point(SketchVector p) =>
        '${(p.x / connectionTolerance).round()},${(p.y / connectionTolerance).round()}';
    if (entity is SketchLine) {
      final keys = [
        point(SketchVector.fromJson(entity.parameters['start'])),
        point(SketchVector.fromJson(entity.parameters['end'])),
      ]..sort();
      return 'line:${keys.join('|')}';
    }
    if (entity is SketchCircle) {
      return 'circle:${point(SketchVector.fromJson(entity.parameters['center']))}:${((entity.parameters['radius'] as num).toDouble() / connectionTolerance).round()}';
    }
    if (entity is SketchArc) {
      final ends = _endpoints(entity).map((item) => point(item.point)).toList()
        ..sort();
      return 'arc:${point(SketchVector.fromJson(entity.parameters['center']))}:${((entity.parameters['radius'] as num).toDouble() / connectionTolerance).round()}:${ends.join('|')}';
    }
    return null;
  }

  List<SketchVector> _sample(SketchEntity entity) {
    if (entity is SketchLine) {
      return _endpoints(entity).map((e) => e.point).toList();
    }
    if (entity is SketchSpline) {
      final raw =
          entity.parameters['sampledPoints'] ?? entity.parameters['points'];
      if (raw is! List) return const [];
      final points = raw.whereType<List>().map(SketchVector.fromJson).toList();
      if (points.length <= 512) return points;
      return [
        for (var i = 0; i < 511; i++) points[i * (points.length - 1) ~/ 511],
        points.last,
      ];
    }
    if (entity is SketchCircle || entity is SketchArc) {
      final center = SketchVector.fromJson(entity.parameters['center']);
      final radius = (entity.parameters['radius'] as num).toDouble();
      final start = entity is SketchArc
          ? (entity.parameters['startAngle'] as num).toDouble()
          : 0.0;
      final end = entity is SketchArc
          ? (entity.parameters['endAngle'] as num).toDouble()
          : math.pi * 2;
      return [
        for (var i = 0; i <= 48; i++)
          SketchVector(
            center.x + radius * math.cos(start + (end - start) * i / 48),
            center.y + radius * math.sin(start + (end - start) * i / 48),
          ),
      ];
    }
    return const [];
  }

  SketchVector? _interiorIntersection(SketchEntity first, SketchEntity second) {
    final a = _sample(first), b = _sample(second);
    for (var i = 1; i < a.length; i++) {
      for (var j = 1; j < b.length; j++) {
        final hit = _segmentIntersection(a[i - 1], a[i], b[j - 1], b[j]);
        if (hit != null && !_isSharedEndpoint(hit, first, second)) return hit;
      }
    }
    return null;
  }

  SketchVector? _selfIntersection(SketchEntity entity) {
    if (entity is! SketchSpline) return null;
    final points = _sample(entity);
    if (points.length < 4) return null;
    final closed = _distance(points.first, points.last) <= connectionTolerance;
    for (var i = 1; i < points.length; i++) {
      for (var j = i + 2; j < points.length; j++) {
        if (closed && i == 1 && j == points.length - 1) continue;
        final hit = _segmentIntersection(
          points[i - 1],
          points[i],
          points[j - 1],
          points[j],
        );
        if (hit != null) return hit;
      }
    }
    return null;
  }

  SketchVector? _segmentIntersection(
    SketchVector a,
    SketchVector b,
    SketchVector c,
    SketchVector d,
  ) {
    final rx = b.x - a.x, ry = b.y - a.y, sx = d.x - c.x, sy = d.y - c.y;
    final denominator = rx * sy - ry * sx;
    if (denominator.abs() <= 1e-12) return null;
    final t = ((c.x - a.x) * sy - (c.y - a.y) * sx) / denominator;
    final u = ((c.x - a.x) * ry - (c.y - a.y) * rx) / denominator;
    if (t <= 1e-7 || t >= 1 - 1e-7 || u <= 1e-7 || u >= 1 - 1e-7) return null;
    return SketchVector(a.x + rx * t, a.y + ry * t);
  }

  bool _isSharedEndpoint(SketchVector point, SketchEntity a, SketchEntity b) =>
      _endpoints(
        a,
      ).any((e) => _distance(e.point, point) <= connectionTolerance) &&
      _endpoints(
        b,
      ).any((e) => _distance(e.point, point) <= connectionTolerance);

  bool _overlap(SketchEntity a, SketchEntity b) {
    if (a is! SketchLine || b is! SketchLine) return false;
    final a0 = SketchVector.fromJson(a.parameters['start']),
        a1 = SketchVector.fromJson(a.parameters['end']);
    final b0 = SketchVector.fromJson(b.parameters['start']),
        b1 = SketchVector.fromJson(b.parameters['end']);
    final cross1 =
        (a1.x - a0.x) * (b0.y - a0.y) - (a1.y - a0.y) * (b0.x - a0.x);
    final cross2 =
        (a1.x - a0.x) * (b1.y - a0.y) - (a1.y - a0.y) * (b1.x - a0.x);
    if (cross1.abs() > connectionTolerance ||
        cross2.abs() > connectionTolerance) {
      return false;
    }
    final useX = (a1.x - a0.x).abs() >= (a1.y - a0.y).abs();
    final aa = [useX ? a0.x : a0.y, useX ? a1.x : a1.y]..sort();
    final bb = [useX ? b0.x : b0.y, useX ? b1.x : b1.y]..sort();
    return math.min(aa[1], bb[1]) - math.max(aa[0], bb[0]) >
        connectionTolerance;
  }

  bool _isDuplicatePair(List<SketchHealthIssue> issues, String a, String b) =>
      issues.any(
        (issue) =>
            issue.type == SketchHealthIssueType.duplicate &&
            issue.entityIds.contains(a) &&
            issue.entityIds.contains(b),
      );

  double _distance(SketchVector a, SketchVector b) =>
      math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
}

class _Endpoint {
  const _Endpoint(this.entityId, this.reference, this.point);
  final String entityId, reference;
  final SketchVector point;
}
