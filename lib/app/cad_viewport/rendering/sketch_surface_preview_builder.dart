import 'dart:math' as math;

import 'package:dart_earcut/dart_earcut.dart';

import '../../../core/sketch_editor/regions/sketch_region_classifier.dart';
import '../../../core/sketch_engine/entities/sketch_entities.dart';
import '../../../core/sketch_engine/models/sketch_models.dart';
import '../scene/cad_scene_graph.dart';

/// Builds disposable display geometry directly from a healthy Sketch.
/// It never creates a kernel shape, document entity, persistent id or history.
class SketchSurfacePreviewBuilder {
  const SketchSurfacePreviewBuilder({this.tolerance = 1e-6});
  final double tolerance;

  CadSceneEntity build({
    required Iterable<SketchEntity> entities,
    required SketchCoordinateSystem coordinates,
  }) {
    final profile = buildProfile(entities: entities, coordinates: coordinates);
    return CadSceneEntity(
      id: 'surface-preview',
      kind: CadSceneEntityKind.preview,
      transparent: true,
      geometry: {
        'surfaceKind': 'sketchPreview',
        'displayColor': 'surfacePreviewBlue',
        'previewOnly': true,
        'nodes': profile.nodes,
        'triangles': profile.triangles,
      },
    );
  }

  SketchSurfaceProfile buildProfile({
    required Iterable<SketchEntity> entities,
    required SketchCoordinateSystem coordinates,
  }) {
    final sampled = _sampledLoops(
      entities.where((e) => e.visible && !e.construction && !e.reference),
    );
    if (sampled.isEmpty) throw StateError('No closed profile is available.');
    final classification = const SketchRegionClassifier().classify([
      for (final loop in sampled)
        SketchRegionLoopInput(
          id: loop.id,
          entityIds: loop.entityIds,
          points: loop.points,
          samplingSufficient: loop.points.length >= 3,
        ),
    ]);
    if (!classification.conclusive) {
      final details = classification.diagnostics
          .map((diagnostic) => diagnostic.message)
          .join('; ');
      throw StateError('Sketch region classification failed: $details');
    }
    if (classification.loops.isEmpty) {
      throw StateError('No closed profile is available.');
    }
    final nodes = <double>[];
    final triangles = <int>[];
    for (final loop in classification.loops) {
      if (loop.role != SketchRegionRole.outer &&
          loop.role != SketchRegionRole.island) {
        continue;
      }
      final holes = classification.loops
          .where(
            (candidate) =>
                candidate.role == SketchRegionRole.hole &&
                candidate.parentLoopId == loop.id,
          )
          .toList(growable: false);
      final regionPoints = [loop.points, for (final hole in holes) hole.points];
      final base = nodes.length ~/ 3;
      for (final point in regionPoints.expand((points) => points)) {
        final global = coordinates.localToGlobal(point);
        nodes.addAll([global.x, global.y, global.z]);
      }
      for (final index in _triangulateRegion(loop.points, holes)) {
        triangles.add(base + index);
      }
    }
    if (triangles.isEmpty) throw StateError('The profile cannot be previewed.');
    return SketchSurfaceProfile(
      nodes: List.unmodifiable(nodes),
      triangles: List.unmodifiable(triangles),
      loops: List<List<SketchVector>>.unmodifiable([
        for (final loop in classification.loops)
          List<SketchVector>.unmodifiable(
            loop.points.map(coordinates.localToGlobal),
          ),
      ]),
      regions: classification.loops,
    );
  }

  List<_SampledLoop> _sampledLoops(Iterable<SketchEntity> source) {
    final loops = <_SampledLoop>[];
    final edges = <_SampledEdge>[];
    for (final entity in source) {
      if (entity is SketchCircle) {
        loops.add(
          _SampledLoop(
            id: entity.id,
            entityIds: [entity.id],
            points: _sample(entity),
          ),
        );
      } else if (entity is SketchLine || entity is SketchArc) {
        edges.add(_SampledEdge(id: entity.id, points: _sample(entity)));
      } else if (entity is SketchSpline) {
        final raw =
            (entity.parameters['sampledPoints'] ?? entity.parameters['points'])
                as List?;
        if (raw != null && raw.length >= 2) {
          edges.add(
            _SampledEdge(
              id: entity.id,
              points: raw.map(SketchVector.fromJson).toList(growable: false),
            ),
          );
        }
      }
    }
    while (edges.isNotEmpty) {
      final first = edges.removeAt(0);
      final loop = List<SketchVector>.of(first.points);
      final entityIds = <String>[first.id];
      var progressed = true;
      while (!_near(loop.first, loop.last) && progressed) {
        progressed = false;
        for (var i = 0; i < edges.length; i++) {
          final edge = edges[i];
          if (_near(loop.last, edge.first)) {
            loop.addAll(edge.skip(1));
          } else if (_near(loop.last, edge.last)) {
            loop.addAll(edge.reversed.skip(1));
          } else {
            continue;
          }
          edges.removeAt(i);
          entityIds.add(edge.id);
          progressed = true;
          break;
        }
      }
      if (_near(loop.first, loop.last)) {
        loops.add(
          _SampledLoop(
            id: 'loop:${entityIds.join('|')}',
            entityIds: entityIds,
            points: loop,
          ),
        );
      }
    }
    return loops;
  }

  List<SketchVector> _sample(SketchEntity entity) {
    if (entity is SketchLine) {
      return [
        SketchVector.fromJson(entity.parameters['start']),
        SketchVector.fromJson(entity.parameters['end']),
      ];
    }
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
      for (var i = 0; i <= steps; i++)
        SketchVector(
          center.x + radius * math.cos(start + (end - start) * i / steps),
          center.y + radius * math.sin(start + (end - start) * i / steps),
        ),
    ];
  }

  List<int> _triangulateRegion(
    List<SketchVector> outer,
    List<SketchRegionLoop> holes,
  ) {
    final points = [...outer, for (final hole in holes) ...hole.points];
    final indices = Earcut.triangulateFromPointsAndHolePoints(
      outline: outer.map((point) => math.Point<double>(point.x, point.y)),
      holes: [
        for (final hole in holes)
          hole.points.map((point) => math.Point<double>(point.x, point.y)),
      ],
    );
    if (indices.isEmpty || indices.length % 3 != 0) {
      throw StateError('Earcut returned no valid triangle index groups.');
    }
    for (final index in indices) {
      if (index < 0 || index >= points.length) {
        throw StateError('Earcut returned an out-of-range triangle index.');
      }
    }
    final expected =
        _area(outer).abs() -
        holes.fold(0.0, (sum, hole) => sum + _area(hole.points).abs());
    var actual = 0.0;
    for (var i = 0; i < indices.length; i += 3) {
      final a = points[indices[i]],
          b = points[indices[i + 1]],
          c = points[indices[i + 2]];
      final triangleArea = _cross(a, b, c).abs() / 2;
      if (triangleArea <= tolerance * tolerance) {
        throw StateError('Earcut returned a degenerate triangle.');
      }
      final centroid = SketchVector(
        (a.x + b.x + c.x) / 3,
        (a.y + b.y + c.y) / 3,
      );
      if (holes.any((hole) => _insidePolygon(centroid, hole.points))) {
        throw StateError('Earcut filled a classified hole.');
      }
      actual += triangleArea;
    }
    final areaTolerance = math.max(
      tolerance * tolerance,
      expected.abs() * 1e-6,
    );
    if ((actual - expected).abs() > areaTolerance) {
      throw StateError('Earcut area validation failed.');
    }
    return indices;
  }

  double _area(List<SketchVector> p) {
    var sum = 0.0;
    for (var i = 0; i < p.length; i++) {
      final next = p[(i + 1) % p.length];
      sum += p[i].x * next.y - next.x * p[i].y;
    }
    return sum / 2;
  }

  double _cross(SketchVector a, SketchVector b, SketchVector c) =>
      (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);

  bool _insidePolygon(SketchVector point, List<SketchVector> polygon) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i], b = polygon[j];
      if ((a.y > point.y) != (b.y > point.y)) {
        final x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x;
        if (point.x < x) inside = !inside;
      }
    }
    return inside;
  }

  bool _near(SketchVector a, SketchVector b) =>
      math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2)) <= tolerance;
}

class SketchSurfaceProfile {
  const SketchSurfaceProfile({
    required this.nodes,
    required this.triangles,
    required this.loops,
    required this.regions,
  });

  final List<double> nodes;
  final List<int> triangles;
  final List<List<SketchVector>> loops;

  /// Transient classification metadata used by the operation controller to
  /// keep the selected outer loop together with its holes and islands.
  ///
  /// This is presentation metadata only; it is never persisted or passed to
  /// the CAD kernel.
  final List<SketchRegionLoop> regions;
}

class _SampledLoop {
  const _SampledLoop({
    required this.id,
    required this.entityIds,
    required this.points,
  });

  final String id;
  final List<String> entityIds;
  final List<SketchVector> points;
}

class _SampledEdge {
  const _SampledEdge({required this.id, required this.points});

  final String id;
  final List<SketchVector> points;

  SketchVector get first => points.first;
  SketchVector get last => points.last;
  Iterable<SketchVector> skip(int count) => points.skip(count);
  Iterable<SketchVector> get reversed => points.reversed;
}
