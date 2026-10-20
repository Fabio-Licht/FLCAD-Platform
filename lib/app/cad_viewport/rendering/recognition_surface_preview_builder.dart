import 'dart:math' as math;

import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../../../core/recognition_engine/recognition_result.dart';
import '../../../core/surface_assistant/surface_assistant.dart';
import '../scene/cad_scene_graph.dart';

class RecognitionSurfacePreviewBuilder {
  const RecognitionSurfacePreviewBuilder();

  CadSceneEntity build(
    RecognitionResult result,
    SurfaceAssistantSuggestion suggestion, {
    String? id,
    Map<String, dynamic>? parameters,
    String? displayColor,
  }) {
    final effectiveParameters = parameters ?? result.parameters;
    final mesh = switch (result.type) {
      RecognitionResultType.plane => _plane(effectiveParameters),
      RecognitionResultType.cylinder => _cylinder(effectiveParameters),
      RecognitionResultType.cone => _cone(effectiveParameters),
      RecognitionResultType.sphere => _sphere(effectiveParameters),
      RecognitionResultType.fillet => _torus(effectiveParameters),
      RecognitionResultType.freeform => (const <double>[], const <int>[]),
    };
    return CadSceneEntity(
      id: id ?? 'surface-assistant-preview',
      kind: CadSceneEntityKind.preview,
      transparent: true,
      geometry: {
        'surfaceKind': result.type.name,
        'displayColor': displayColor ?? 'surfaceAssistantPreview',
        if (displayColor == 'recognitionMeasured')
          'rootLinearRgb': const [0.12, 0.42, 0.78],
        if (displayColor == 'recognitionCorrected')
          'rootLinearRgb': const [0.78, 0.24, 0.06],
        'previewOnly': true,
        'sourceRecognitionId': result.id,
        'strategy': suggestion.strategy.name,
        'nodes': mesh.$1,
        'triangles': mesh.$2,
      },
    );
  }

  (List<double>, List<int>) _plane(Map<String, dynamic> p) {
    final center = _vector(p['origin']),
        normal = _vector(p['normal']).normalized;
    final extent =
        math.sqrt(_number(p['area'], 4).abs()).clamp(1.0, 100000.0) / 2;
    final basis = _basis(normal), u = basis.$1 * extent, v = basis.$2 * extent;
    return (
      _nodes([center - u - v, center + u - v, center + u + v, center - u + v]),
      const [0, 1, 2, 0, 2, 3],
    );
  }

  (List<double>, List<int>) _cylinder(Map<String, dynamic> p) {
    final center = _vector(p['origin']), axis = _vector(p['axis']).normalized;
    final radius = _number(p['radius'], 1),
        length = _number(p['length'], radius * 2);
    final basis = _basis(axis), points = <Vector3>[];
    const steps = 32;
    for (final end in [-.5, .5]) {
      for (var i = 0; i < steps; i++) {
        final angle = i * 2 * math.pi / steps;
        points.add(
          center +
              axis * (length * end) +
              basis.$1 * (radius * math.cos(angle)) +
              basis.$2 * (radius * math.sin(angle)),
        );
      }
    }
    return (_nodes(points), _quads(steps, 2));
  }

  (List<double>, List<int>) _cone(Map<String, dynamic> p) {
    final center = _vector(p['origin']), axis = _vector(p['axis']).normalized;
    final radius = _number(p['radius'], 1),
        length = _number(p['length'], radius * 2);
    final basis = _basis(axis), points = <Vector3>[center];
    const steps = 32;
    for (var i = 0; i < steps; i++) {
      final angle = i * 2 * math.pi / steps;
      points.add(
        center +
            axis * length +
            basis.$1 * (radius * math.cos(angle)) +
            basis.$2 * (radius * math.sin(angle)),
      );
    }
    return (
      _nodes(points),
      [
        for (var i = 0; i < steps; i++) ...[0, i + 1, (i + 1) % steps + 1],
      ],
    );
  }

  (List<double>, List<int>) _sphere(Map<String, dynamic> p) {
    final center = _vector(p['center']), radius = _number(p['radius'], 1);
    const rings = 16, steps = 24;
    final points = <Vector3>[];
    for (var ring = 0; ring <= rings; ring++) {
      final latitude = -math.pi / 2 + math.pi * ring / rings;
      for (var i = 0; i < steps; i++) {
        final longitude = i * 2 * math.pi / steps;
        points.add(
          center +
              Vector3(
                    math.cos(latitude) * math.cos(longitude),
                    math.cos(latitude) * math.sin(longitude),
                    math.sin(latitude),
                  ) *
                  radius,
        );
      }
    }
    return (_nodes(points), _quads(steps, rings + 1));
  }

  (List<double>, List<int>) _torus(Map<String, dynamic> p) {
    final center = _vector(p['center']), axis = _vector(p['axis']).normalized;
    final major = _number(p['majorRadius'], 2),
        minor = _number(p['minorRadius'], .5);
    final basis = _basis(axis), points = <Vector3>[];
    const rings = 32, steps = 12;
    for (var ring = 0; ring < rings; ring++) {
      final a = ring * 2 * math.pi / rings;
      final radial = basis.$1 * math.cos(a) + basis.$2 * math.sin(a);
      for (var i = 0; i < steps; i++) {
        final b = i * 2 * math.pi / steps;
        points.add(
          center +
              radial * (major + minor * math.cos(b)) +
              axis * (minor * math.sin(b)),
        );
      }
    }
    return (_nodes(points), _wrappedQuads(steps, rings));
  }

  (Vector3, Vector3) _basis(Vector3 normal) {
    final reference = normal.z.abs() < .9
        ? const Vector3(0, 0, 1)
        : const Vector3(1, 0, 0);
    final first = normal.cross(reference).normalized;
    return (first, normal.cross(first).normalized);
  }

  Vector3 _vector(dynamic value) =>
      value is List ? Vector3.fromJson(value) : Vector3.zero;
  double _number(dynamic value, double fallback) =>
      value is num ? value.toDouble() : fallback;
  List<double> _nodes(Iterable<Vector3> values) => [
    for (final p in values) ...[p.x, p.y, p.z],
  ];

  List<int> _quads(int steps, int rows) => [
    for (var row = 0; row < rows - 1; row++)
      for (var i = 0; i < steps; i++) ...[
        row * steps + i,
        row * steps + (i + 1) % steps,
        (row + 1) * steps + (i + 1) % steps,
        row * steps + i,
        (row + 1) * steps + (i + 1) % steps,
        (row + 1) * steps + i,
      ],
  ];

  List<int> _wrappedQuads(int steps, int rows) => [
    for (var row = 0; row < rows; row++)
      for (var i = 0; i < steps; i++) ...[
        row * steps + i,
        row * steps + (i + 1) % steps,
        ((row + 1) % rows) * steps + (i + 1) % steps,
        row * steps + i,
        ((row + 1) % rows) * steps + (i + 1) % steps,
        ((row + 1) % rows) * steps + i,
      ],
  ];
}
