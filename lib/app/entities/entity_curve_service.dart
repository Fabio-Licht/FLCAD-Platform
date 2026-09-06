import 'dart:math' as math;

import '../../core/cad_document/cad_document.dart';
import '../../core/geometric_kernel/geometry/vectors.dart';
import '../cad_viewport/scene/cad_scene_graph.dart';
import '../runtime/cad_runtime.dart';

enum ConstructionCurveMethod {
  extractEdge,
  allBoundaries,
  externalBoundary,
  isoU,
  isoV,
  isoBoth,
  surfacePlaneIntersection,
  meshSection,
}

class EntityCurveService {
  EntityCurveService(this.runtime);
  final CadRuntime runtime;

  Future<List<String>> create({
    required ConstructionCurveMethod method,
    required List<String> sourceEntityIds,
    double u = .5,
    double v = .5,
    Vector3? pickedPoint,
    bool locateByPickedPoint = false,
    int samples = 65,
  }) async {
    if (runtime.document == null) {
      throw StateError('Abra um projeto antes de extrair curvas.');
    }
    if (sourceEntityIds.isEmpty) {
      throw StateError('Selecione a geometria de origem.');
    }
    if (samples < 2 || samples > 2001) {
      throw RangeError.range(samples, 2, 2001, 'samples');
    }
    final curves = switch (method) {
      ConstructionCurveMethod.extractEdge => [
        _extractPublishedCurve(sourceEntityIds.first),
      ],
      ConstructionCurveMethod.allBoundaries => _meshBoundaries(
        sourceEntityIds.first,
      ),
      ConstructionCurveMethod.externalBoundary => [
        _largest(_meshBoundaries(sourceEntityIds.first)),
      ],
      ConstructionCurveMethod.isoU => [
        _iso(
          sourceEntityIds.first,
          true,
          u,
          samples,
          locateByPickedPoint ? pickedPoint : null,
        ),
      ],
      ConstructionCurveMethod.isoV => [
        _iso(
          sourceEntityIds.first,
          false,
          v,
          samples,
          locateByPickedPoint ? pickedPoint : null,
        ),
      ],
      ConstructionCurveMethod.isoBoth => [
        _iso(
          sourceEntityIds.first,
          true,
          u,
          samples,
          locateByPickedPoint ? pickedPoint : null,
        ),
        _iso(
          sourceEntityIds.first,
          false,
          v,
          samples,
          locateByPickedPoint ? pickedPoint : null,
        ),
      ],
      ConstructionCurveMethod.surfacePlaneIntersection ||
      ConstructionCurveMethod.meshSection => [
        _section(sourceEntityIds, pickedPoint),
      ],
    };
    final valid = curves.where((curve) => curve.length >= 2).toList();
    if (valid.isEmpty) {
      throw StateError('A operação não produziu curvas válidas.');
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final startNumber =
        1 +
        runtime.document!.entities.values.where((e) {
          final contract = e.data['constructionEntity'];
          return e.kind == CadDocumentEntityKind.curve &&
              contract is Map &&
              contract['type'] == 'curve';
        }).length;
    final entities = <CadDocumentEntity>[];
    final ids = <String>[];
    for (var i = 0; i < valid.length; i++) {
      final id = 'curve:$stamp:$i';
      ids.add(id);
      final closed = valid[i].first.distanceTo(valid[i].last) <= 1e-7;
      entities.add(
        CadDocumentEntity(
          id: id,
          kind: CadDocumentEntityKind.curve,
          data: {
            'name': 'Curve ${startNumber + i}',
            'collectionId': 'collection:modified',
            'sceneKind': CadSceneEntityKind.curve.name,
            'sceneGeometry': {
              'points': valid[i].map((p) => p.toJson()).toList(),
              'closed': closed,
              'displayColor': 'extractedCurve',
              'strokeWidth': 2.0,
            },
            'sceneVisible': true,
            'constructionEntity': {
              'type': 'curve',
              'method': method.name,
              'sourceEntityIds': sourceEntityIds,
              if ({
                ConstructionCurveMethod.isoU,
                ConstructionCurveMethod.isoBoth,
              }.contains(method))
                'u': u.clamp(0.0, 1.0),
              if ({
                ConstructionCurveMethod.isoV,
                ConstructionCurveMethod.isoBoth,
              }.contains(method))
                'v': v.clamp(0.0, 1.0),
              if (locateByPickedPoint && pickedPoint != null)
                'locatedByPickedPoint': true,
              'sampleCount': valid[i].length,
              'closed': closed,
              if (valid.length > 1) 'sequenceIndex': i,
            },
            'sourceEntityIds': sourceEntityIds,
            'authoringRoot': true,
            'workspace': 'Entidades',
          },
        ),
      );
    }
    await runtime.upsertEntityBatch(
      command: 'entities.curve.${method.name}',
      entities: entities,
    );
    runtime.geometrySelection.select(ids.last);
    return ids;
  }

  CadSceneEntity _entity(String id) =>
      runtime.scene.find(id) ??
      (throw StateError('Entidade não encontrada: $id'));

  List<Vector3> _extractPublishedCurve(String id) {
    final geometry = _entity(id).geometry;
    final points = _vectors(geometry['points']);
    if (points.length >= 2) return points;
    final segments = geometry['segments'];
    if (segments is List) {
      final output = <Vector3>[];
      for (final segment in segments.whereType<List>()) {
        output.addAll(_vectors(segment));
      }
      if (output.length >= 2) return output;
    }
    throw StateError('A entidade não publica uma aresta ou curva extraível.');
  }

  List<List<Vector3>> _meshBoundaries(String id) {
    final geometry = _entity(id).geometry;
    final nodes = geometry['nodes'], triangles = geometry['triangles'];
    if (nodes is! List || triangles is! List) {
      final published = _extractPublishedCurve(id);
      return [published];
    }
    final vertices = <Vector3>[
      for (var i = 0; i + 2 < nodes.length; i += 3)
        Vector3(
          (nodes[i] as num).toDouble(),
          (nodes[i + 1] as num).toDouble(),
          (nodes[i + 2] as num).toDouble(),
        ),
    ];
    final counts = <(int, int), int>{};
    for (var i = 0; i + 2 < triangles.length; i += 3) {
      final t = [
        (triangles[i] as num).toInt(),
        (triangles[i + 1] as num).toInt(),
        (triangles[i + 2] as num).toInt(),
      ];
      for (final edge in [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])]) {
        final key = edge.$1 < edge.$2 ? edge : (edge.$2, edge.$1);
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    final adjacency = <int, Set<int>>{};
    for (final edge
        in counts.entries.where((e) => e.value == 1).map((e) => e.key)) {
      (adjacency[edge.$1] ??= {}).add(edge.$2);
      (adjacency[edge.$2] ??= {}).add(edge.$1);
    }
    final unused = <(int, int)>{
      for (final a in adjacency.entries)
        for (final b in a.value)
          if (a.key < b) (a.key, b),
    };
    final loops = <List<Vector3>>[];
    while (unused.isNotEmpty) {
      final seed = unused.first;
      final indices = <int>[seed.$1, seed.$2];
      unused.remove(seed);
      while (true) {
        final current = indices.last, previous = indices[indices.length - 2];
        final next = adjacency[current]?.where((n) {
          final edge = current < n ? (current, n) : (n, current);
          return n != previous && unused.contains(edge);
        }).firstOrNull;
        if (next == null) break;
        unused.remove(current < next ? (current, next) : (next, current));
        indices.add(next);
        if (next == indices.first) break;
      }
      loops.add(indices.map((i) => vertices[i]).toList());
    }
    if (loops.isEmpty) {
      throw StateError('A geometria é fechada ou não possui bordas livres.');
    }
    return loops;
  }

  List<Vector3> _largest(List<List<Vector3>> curves) =>
      curves.reduce((a, b) => _length(a) >= _length(b) ? a : b);
  double _length(List<Vector3> p) => [
    for (var i = 1; i < p.length; i++) p[i - 1].distanceTo(p[i]),
  ].fold(0, (a, b) => a + b);

  List<Vector3> _iso(
    String id,
    bool constantU,
    double parameter,
    int samples,
    Vector3? pickedPoint,
  ) {
    final g = _entity(id).geometry;
    var p = parameter.clamp(0.0, 1.0);
    final rows = (g['vCount'] ?? g['rows']) as int?;
    final columns = (g['uCount'] ?? g['columns']) as int?;
    final nodes = g['nodes'];
    if (nodes is List &&
        rows != null &&
        columns != null &&
        rows * columns * 3 <= nodes.length) {
      Vector3 node(int u, int v) {
        final index = (v * columns + u) * 3;
        return Vector3(
          (nodes[index] as num).toDouble(),
          (nodes[index + 1] as num).toDouble(),
          (nodes[index + 2] as num).toDouble(),
        );
      }

      if (pickedPoint != null) {
        var best = double.infinity, bestU = 0, bestV = 0;
        for (var row = 0; row < rows; row++) {
          for (var column = 0; column < columns; column++) {
            final distance = node(column, row).distanceTo(pickedPoint);
            if (distance < best) {
              best = distance;
              bestU = column;
              bestV = row;
            }
          }
        }
        p = constantU
            ? bestU / math.max(1, columns - 1)
            : bestV / math.max(1, rows - 1);
      }

      final fixedMax = constantU ? columns - 1 : rows - 1;
      final raw = p * fixedMax,
          low = raw.floor(),
          high = raw.ceil(),
          blend = raw - low;
      return List.generate(constantU ? rows : columns, (i) {
        final a = constantU ? node(low, i) : node(i, low);
        final b = constantU ? node(high, i) : node(i, high);
        return a + (b - a) * blend;
      });
    }
    final kind = g['surfaceKind'] ?? (g['parameters'] as Map?)?['surfaceKind'];
    final parameters = g['parameters'] is Map
        ? Map<String, dynamic>.from(g['parameters'] as Map)
        : g;
    Vector3 vec(Object? raw, Vector3 fallback) => _vector(raw) ?? fallback;
    if (kind == 'plane') {
      final center = vec(parameters['origin'], Vector3.zero);
      final normal = vec(
        parameters['normal'],
        const Vector3(0, 0, 1),
      ).normalized;
      final x = normal
          .cross(
            normal.z.abs() < .9
                ? const Vector3(0, 0, 1)
                : const Vector3(0, 1, 0),
          )
          .normalized;
      final y = normal.cross(x).normalized;
      final width = (parameters['width'] as num?)?.toDouble() ?? 100;
      final height = (parameters['height'] as num?)?.toDouble() ?? 100;
      return List.generate(samples, (i) {
        final t = i / (samples - 1);
        return constantU
            ? center + x * ((p - .5) * width) + y * ((t - .5) * height)
            : center + x * ((t - .5) * width) + y * ((p - .5) * height);
      });
    }
    throw StateError(
      'A superfície não publica domínio UV ou grade paramétrica utilizável.',
    );
  }

  List<Vector3> _section(List<String> ids, Vector3? pickedPoint) {
    if (ids.length < 2) {
      throw StateError('Selecione uma superfície/malha e um plano.');
    }
    final mesh = ids
        .map(_entity)
        .where(
          (e) => e.geometry['triangles'] is List && e.geometry['nodes'] is List,
        )
        .firstOrNull;
    final plane = ids
        .map(_entity)
        .where(
          (e) => e.geometry['normal'] is List && e.geometry['origin'] is List,
        )
        .firstOrNull;
    if (mesh == null || plane == null) {
      throw StateError('A interseção requer geometria triangulada e um plano.');
    }
    final origin = _vector(plane.geometry['origin'])!,
        normal = _vector(plane.geometry['normal'])!.normalized;
    final nodes = mesh.geometry['nodes'] as List,
        triangles = mesh.geometry['triangles'] as List;
    Vector3 node(int i) => Vector3(
      (nodes[i * 3] as num).toDouble(),
      (nodes[i * 3 + 1] as num).toDouble(),
      (nodes[i * 3 + 2] as num).toDouble(),
    );
    final segments = <List<Vector3>>[];
    for (var i = 0; i + 2 < triangles.length; i += 3) {
      final vertices = [
        node((triangles[i] as num).toInt()),
        node((triangles[i + 1] as num).toInt()),
        node((triangles[i + 2] as num).toInt()),
      ];
      final hits = <Vector3>[];
      for (final edge in [
        (vertices[0], vertices[1]),
        (vertices[1], vertices[2]),
        (vertices[2], vertices[0]),
      ]) {
        final da = (edge.$1 - origin).dot(normal),
            db = (edge.$2 - origin).dot(normal);
        if (da * db < 0 || da.abs() <= 1e-9 || db.abs() <= 1e-9) {
          final denominator = da - db;
          final t = denominator.abs() <= 1e-12 ? 0.0 : da / denominator;
          final hit = edge.$1 + (edge.$2 - edge.$1) * t.clamp(0.0, 1.0);
          if (hits.every((p) => p.distanceTo(hit) > 1e-7)) hits.add(hit);
        }
      }
      if (hits.length >= 2) segments.add([hits[0], hits[1]]);
    }
    if (segments.isEmpty) {
      throw StateError('O plano não intersecta a geometria.');
    }
    return _joinSegments(segments, pickedPoint);
  }

  List<Vector3> _joinSegments(List<List<Vector3>> segments, Vector3? seed) {
    final remaining = [...segments];
    if (seed != null) {
      remaining.sort(
        (a, b) => a.first.distanceTo(seed).compareTo(b.first.distanceTo(seed)),
      );
    }
    final output = <Vector3>[...remaining.removeAt(0)];
    while (remaining.isNotEmpty) {
      var best = double.infinity, index = -1, reverse = false;
      for (var i = 0; i < remaining.length; i++) {
        final a = output.last.distanceTo(remaining[i].first),
            b = output.last.distanceTo(remaining[i].last);
        if (a < best) {
          best = a;
          index = i;
          reverse = false;
        }
        if (b < best) {
          best = b;
          index = i;
          reverse = true;
        }
      }
      if (best > 1e-5) break;
      final next = remaining.removeAt(index);
      output.addAll(reverse ? next.reversed.skip(1) : next.skip(1));
    }
    return output;
  }

  List<Vector3> _vectors(Object? raw) =>
      raw is List ? raw.map(_vector).whereType<Vector3>().toList() : const [];
  Vector3? _vector(Object? raw) {
    if (raw is! List ||
        raw.length < 3 ||
        raw[0] is! num ||
        raw[1] is! num ||
        raw[2] is! num) {
      return null;
    }
    return Vector3(
      (raw[0] as num).toDouble(),
      (raw[1] as num).toDouble(),
      (raw[2] as num).toDouble(),
    );
  }
}
