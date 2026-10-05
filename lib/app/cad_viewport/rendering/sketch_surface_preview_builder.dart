import 'dart:math' as math;

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
    final loops = _loops(entities.where((e) => e.visible && !e.construction));
    if (loops.isEmpty) throw StateError('No closed profile is available.');
    final nodes = <double>[];
    final triangles = <int>[];
    for (final loop in loops) {
      final clean = _clean(loop);
      if (clean.length < 3) continue;
      final base = nodes.length ~/ 3;
      for (final point in clean) {
        final global = coordinates.localToGlobal(point);
        nodes.addAll([global.x, global.y, global.z]);
      }
      for (final triangle in _triangulate(clean)) {
        triangles.addAll(triangle.map((index) => base + index));
      }
    }
    if (triangles.isEmpty) throw StateError('The profile cannot be previewed.');
    return SketchSurfaceProfile(
      nodes: List.unmodifiable(nodes),
      triangles: List.unmodifiable(triangles),
      loops: List<List<SketchVector>>.unmodifiable([
        for (final loop in loops)
          List<SketchVector>.unmodifiable(
            _clean(loop).map(coordinates.localToGlobal),
          ),
      ]),
    );
  }

  List<List<SketchVector>> _loops(Iterable<SketchEntity> source) {
    final loops = <List<SketchVector>>[];
    final edges = <List<SketchVector>>[];
    for (final entity in source) {
      if (entity is SketchCircle) {
        loops.add(_sample(entity));
      } else if (entity is SketchLine || entity is SketchArc) {
        edges.add(_sample(entity));
      } else if (entity is SketchSpline) {
        final raw =
            (entity.parameters['sampledPoints'] ?? entity.parameters['points'])
                as List?;
        if (raw != null && raw.length >= 2) {
          edges.add(raw.map(SketchVector.fromJson).toList(growable: false));
        }
      }
    }
    while (edges.isNotEmpty) {
      final loop = List<SketchVector>.of(edges.removeAt(0));
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
          progressed = true;
          break;
        }
      }
      if (_near(loop.first, loop.last)) loops.add(loop);
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

  List<SketchVector> _clean(List<SketchVector> loop) {
    final result = <SketchVector>[];
    for (final point in loop) {
      if (result.isEmpty || !_near(result.last, point)) result.add(point);
    }
    if (result.length > 1 && _near(result.first, result.last)) {
      result.removeLast();
    }
    return result;
  }

  List<List<int>> _triangulate(List<SketchVector> polygon) {
    final result = <List<int>>[];
    final indices = List<int>.generate(polygon.length, (i) => i);
    final ccw = _area(polygon) > 0;
    var guard = polygon.length * polygon.length;
    while (indices.length > 3 && guard-- > 0) {
      var clipped = false;
      for (var i = 0; i < indices.length; i++) {
        final a = indices[(i - 1 + indices.length) % indices.length];
        final b = indices[i];
        final c = indices[(i + 1) % indices.length];
        if (_cross(polygon[a], polygon[b], polygon[c]) * (ccw ? 1 : -1) <=
            tolerance) {
          continue;
        }
        if (indices.any(
          (p) =>
              p != a &&
              p != b &&
              p != c &&
              _inside(polygon[p], polygon[a], polygon[b], polygon[c]),
        )) {
          continue;
        }
        result.add(ccw ? [a, b, c] : [c, b, a]);
        indices.removeAt(i);
        clipped = true;
        break;
      }
      if (!clipped) break;
    }
    if (indices.length == 3) {
      result.add(ccw ? indices : indices.reversed.toList());
    }
    return result;
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

  bool _inside(SketchVector p, SketchVector a, SketchVector b, SketchVector c) {
    final x = _cross(a, b, p), y = _cross(b, c, p), z = _cross(c, a, p);
    return (x >= -tolerance && y >= -tolerance && z >= -tolerance) ||
        (x <= tolerance && y <= tolerance && z <= tolerance);
  }

  bool _near(SketchVector a, SketchVector b) =>
      math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2)) <= tolerance;
}

class SketchSurfaceProfile {
  const SketchSurfaceProfile({
    required this.nodes,
    required this.triangles,
    required this.loops,
  });

  final List<double> nodes;
  final List<int> triangles;
  final List<List<SketchVector>> loops;
}
