import 'dart:math' as math;

import '../../../core/adaptive_surface/continuity/surface_continuity.dart';
import '../../../core/adaptive_surface/models/surface_geometry.dart';
import '../../../core/feature_lifecycle/feature_update_solver.dart';
import '../../../core/parametric_solver/parametric_solver.dart';
import '../../../core/sketch_editor/health/sketch_health_analyzer.dart';
import '../../../core/sketch_engine/entities/sketch_entities.dart';
import '../../../core/sketch_engine/models/sketch_models.dart';
import '../../../core/surface_generation/api/surface_generation_api.dart';
import '../../../core/surface_generation/models/surface_generation_models.dart';
import '../../../core/surface_generation/models/surface_topology.dart';
import '../../../core/surface_intelligence/models/surface_models.dart';
import '../../cad_viewport/rendering/sketch_surface_preview_builder.dart';

/// The sole translator between a live Sketch and the domain-neutral Solver.
/// Surface geometry itself contains no Sketch-specific update logic.
class PlanarSurfaceFeatureAdapter {
  const PlanarSurfaceFeatureAdapter({
    this.profileBuilder = const SketchSurfacePreviewBuilder(),
    this.updates = const FeatureUpdateSolver(),
  });

  final SketchSurfacePreviewBuilder profileBuilder;
  final FeatureUpdateSolver updates;

  Future<GeneratedSurface> build({
    required String featureId,
    required Sketch sketch,
    required Iterable<SketchEntity> entities,
    required SketchHealthReport health,
    required SurfaceCandidate candidate,
    required SurfaceGenerationApi generation,
  }) {
    if (!health.readyForSurface) {
      throw StateError('Sketch Health is not Ready for Surface.');
    }
    final activeIds = health.activeProfileEntityIds;
    final sourceEntities = entities
        .where((entity) => activeIds.isEmpty || activeIds.contains(entity.id))
        .toList(growable: false);
    final profile = profileBuilder.buildProfile(
      entities: sourceEntities,
      coordinates: sketch.coordinates,
    );
    if (profile.loops.length != 1) {
      throw StateError(
        'Planar Surface requires exactly one closed profile in this Sprint.',
      );
    }
    final loop = profile.loops.single;
    if (loop.length < 3) throw StateError('The profile is degenerate.');
    final points = [for (final point in loop) ...point.toJson()];
    final previous = generation.engine.registry.surfaces
        .where((surface) => surface.surfaceId == featureId)
        .firstOrNull;
    final topology = _buildTopology(
      featureId: featureId,
      entities: sourceEntities,
      coordinates: sketch.coordinates,
      profile: profile,
      previous: previous?.parameters['topology'] is Map
          ? SurfaceTopology.fromJson(
              (previous!.parameters['topology'] as Map).cast<String, dynamic>(),
            )
          : null,
      allSurfaces: generation.engine.registry.surfaces,
    );
    final profileRevision = sketch.version.toDouble();
    return updates.update(
      request: ParametricSolveRequest(
        first: '${sketch.id}:definition',
        second: '$featureId:definition',
        degreesOfFreedom: [
          ParametricDegreeOfFreedom('${sketch.id}:definition', fixed: true),
          ParametricDegreeOfFreedom(
            '$featureId:definition',
            parameterIds: {'$featureId:profileRevision'},
          ),
        ],
        parameters: [
          ParametricParameter('$featureId:profileRevision', profileRevision),
        ],
        anchors: {'${sketch.id}:definition'},
      ),
      apply: (_) async {
        final result = await generation.engine.generate(
          SurfaceGenerationRequest(
            candidate: candidate,
            featureId: featureId,
            origin: 'live-sketch',
            parameters: {
              'origin': sketch.coordinates.origin.toJson(),
              'normal': sketch.coordinates.normal.toJson(),
              'profilePoints': points,
              'sourceSketchId': sketch.id,
              'sourceSketchRevision': sketch.version,
              'sourceEntityVersions': {
                for (final entity in sourceEntities) entity.id: entity.version,
              },
              'displayNodes': profile.nodes,
              'displayTriangles': profile.triangles,
              'displayMode':
                  previous?.parameters['displayMode'] ??
                  SurfaceDisplayMode.shadedWithEdges.name,
              'topology': topology.toJson(),
              'health': {
                'readyForSurface': health.readyForSurface,
                'closedProfile': health.closedProfile,
                'issueCount': health.issues.length,
              },
            },
          ),
        );
        if (!result.success || result.surface == null) {
          throw StateError(
            result.diagnostics.map((item) => item.message).join('; '),
          );
        }
        return result.surface!;
      },
    );
  }

  SurfaceCandidate candidateFor(Sketch sketch) => SurfaceCandidate(
    id: '${sketch.id}:planar-surface',
    kind: SurfaceKind.plane,
    classification: SurfaceClassification.analytical,
    confidence: 1,
    evidence: [
      SurfacePlanningEvidence(
        id: '${sketch.id}:health-ready',
        source: 'Sketch Health Analyzer',
        description: 'Healthy planar Sketch profile',
        value: 1,
        regionId: sketch.id,
      ),
    ],
    regionIds: [sketch.id],
    boundaries: sketch.entityIds,
    quality: 1,
    coverage: 1,
    predictedContinuity: SurfaceContinuityLevel.g0,
    justification: 'A healthy closed Sketch defines one planar face.',
  );

  SurfaceTopology _buildTopology({
    required String featureId,
    required List<SketchEntity> entities,
    required SketchCoordinateSystem coordinates,
    required SketchSurfaceProfile profile,
    required SurfaceTopology? previous,
    required Iterable<GeneratedSurface> allSurfaces,
  }) {
    final usedEdgeIds = <String>{};
    final usedVertexIds = <String>{};
    for (final surface in allSurfaces) {
      final raw = surface.parameters['topology'];
      if (raw is! Map) continue;
      final topology = SurfaceTopology.fromJson(raw.cast<String, dynamic>());
      usedEdgeIds.addAll(topology.edges.map((edge) => edge.id));
      usedVertexIds.addAll(topology.vertices.map((vertex) => vertex.id));
    }
    String allocate(String prefix, Set<String> used) {
      var index = 1;
      while (used.contains('$prefix${index.toString().padLeft(3, '0')}')) {
        index++;
      }
      final id = '$prefix${index.toString().padLeft(3, '0')}';
      used.add(id);
      return id;
    }

    final oldEdges = {
      for (final edge in previous?.edges ?? const <SurfaceEdge>[])
        edge.sourceEntityId: edge,
    };
    final endpointGroups = <List<_BoundaryEndpoint>>[];
    final edgeDrafts = <_BoundaryEdge>[];
    for (final entity in entities.where(
      (item) => item.visible && !item.construction && !item.reference,
    )) {
      final local = _sampleEntity(entity);
      if (local.length < 2) continue;
      final global = local.map(coordinates.localToGlobal).toList();
      final edgeId = oldEdges[entity.id]?.id ?? allocate('Edge', usedEdgeIds);
      final start = _BoundaryEndpoint('${entity.id}:start', global.first);
      final end = _BoundaryEndpoint('${entity.id}:end', global.last);
      void merge(_BoundaryEndpoint endpoint) {
        final group = endpointGroups
            .where((candidate) => _near(candidate.first.point, endpoint.point))
            .firstOrNull;
        if (group == null) {
          endpointGroups.add([endpoint]);
        } else {
          group.add(endpoint);
        }
      }

      merge(start);
      merge(end);
      edgeDrafts.add(
        _BoundaryEdge(entity.id, edgeId, global, start.key, end.key),
      );
    }
    final vertexByKey = <String, String>{};
    final vertices = <SurfaceVertex>[];
    for (final group in endpointGroups) {
      final keys = group.map((item) => item.key).toList()..sort();
      final old = previous?.vertices
          .where((vertex) => vertex.sourceKeys.any(keys.contains))
          .firstOrNull;
      final id = old?.id ?? allocate('Vertex', usedVertexIds);
      final point = group.first.point;
      vertices.add(
        SurfaceVertex(
          id: id,
          sourceKeys: keys,
          position: point.toJson(),
          revision: old == null ? 1 : old.revision + 1,
        ),
      );
      for (final key in keys) {
        vertexByKey[key] = id;
      }
    }
    final edges = [
      for (final draft in edgeDrafts)
        SurfaceEdge(
          id: draft.id,
          sourceEntityId: draft.sourceId,
          vertexIds: [vertexByKey[draft.startKey]!, vertexByKey[draft.endKey]!],
          points: draft.points.map((point) => point.toJson()).toList(),
          revision: (oldEdges[draft.sourceId]?.revision ?? 0) + 1,
        ),
    ];
    final loopId = previous?.loops.firstOrNull?.id ?? 'Outer Loop';
    final perimeter = edges.fold<double>(0, (sum, edge) {
      var length = 0.0;
      for (var i = 1; i < edge.points.length; i++) {
        length += _distance3(edge.points[i - 1], edge.points[i]);
      }
      return sum + length;
    });
    return SurfaceTopology(
      loops: [
        SurfaceLoop(
          id: loopId,
          outer: true,
          edgeIds: edges.map((e) => e.id).toList(),
        ),
      ],
      edges: edges,
      vertices: vertices,
      area: profile.loops.fold(0, (sum, item) => sum + _area(item).abs()),
      perimeter: perimeter,
    );
  }

  List<SketchVector> _sampleEntity(SketchEntity entity) {
    if (entity is SketchLine) {
      return [
        SketchVector.fromJson(entity.parameters['start']),
        SketchVector.fromJson(entity.parameters['end']),
      ];
    }
    if (entity is! SketchCircle && entity is! SketchArc) return const [];
    final center = SketchVector.fromJson(entity.parameters['center']);
    final radius = (entity.parameters['radius'] as num).toDouble();
    final start = entity is SketchArc
        ? (entity.parameters['startAngle'] as num).toDouble()
        : 0.0;
    final end = entity is SketchArc
        ? (entity.parameters['endAngle'] as num).toDouble()
        : math.pi * 2;
    final steps = entity is SketchCircle ? 96 : 48;
    return [
      for (var index = 0; index <= steps; index++)
        SketchVector(
          center.x + radius * math.cos(start + (end - start) * index / steps),
          center.y + radius * math.sin(start + (end - start) * index / steps),
        ),
    ];
  }

  bool _near(SketchVector a, SketchVector b) =>
      (a.x - b.x).abs() <= 1e-6 &&
      (a.y - b.y).abs() <= 1e-6 &&
      (a.z - b.z).abs() <= 1e-6;
  double _distance3(List<double> a, List<double> b) => math.sqrt(
    math.pow(a[0] - b[0], 2) +
        math.pow(a[1] - b[1], 2) +
        math.pow(a[2] - b[2], 2),
  );
  double _area(List<SketchVector> points) {
    var value = 0.0;
    for (var i = 0; i < points.length; i++) {
      final next = points[(i + 1) % points.length];
      value += points[i].x * next.y - next.x * points[i].y;
    }
    return value / 2;
  }
}

class _BoundaryEndpoint {
  const _BoundaryEndpoint(this.key, this.point);
  final String key;
  final SketchVector point;
}

class _BoundaryEdge {
  const _BoundaryEdge(
    this.sourceId,
    this.id,
    this.points,
    this.startKey,
    this.endKey,
  );
  final String sourceId, id, startKey, endKey;
  final List<SketchVector> points;
}
