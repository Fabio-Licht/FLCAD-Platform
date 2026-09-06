import 'dart:math' as math;

import '../../core/cad_document/cad_document.dart';
import '../../core/geometric_kernel/geometry/vectors.dart';
import '../../core/geometric_kernel/services/fitting_engine.dart';
import '../cad_viewport/scene/cad_scene_graph.dart';
import '../runtime/cad_runtime.dart';

enum ConstructionPlaneMethod {
  xy,
  yz,
  zx,
  originNormal,
  threePoints,
  offset,
  parallelThroughPoint,
  midPlane,
  perpendicular,
  angle,
  normalToCurve,
  tangentToSurface,
  lineAndPoint,
  twoLines,
  bestFit,
  extractPlanar,
}

class EntityPlaneService {
  EntityPlaneService(this.runtime);

  final CadRuntime runtime;

  Future<String> create({
    required ConstructionPlaneMethod method,
    List<String> sourceEntityIds = const [],
    Vector3 origin = Vector3.zero,
    Vector3 normal = const Vector3(0, 0, 1),
    Vector3? pickedPoint,
    Vector3? pickedNormal,
    double distance = 0,
    double angleDegrees = 0,
    double planarTolerance = .05,
    double visualSize = 60,
  }) async {
    if (runtime.document == null) {
      throw StateError('Abra um projeto antes de criar planos.');
    }
    final effectiveSourceIds =
        {
          ConstructionPlaneMethod.xy,
          ConstructionPlaneMethod.yz,
          ConstructionPlaneMethod.zx,
          ConstructionPlaneMethod.originNormal,
        }.contains(method)
        ? const <String>[]
        : sourceEntityIds;
    final result = _construct(
      method,
      effectiveSourceIds,
      origin: origin,
      normal: normal,
      pickedPoint: pickedPoint,
      pickedNormal: pickedNormal,
      distance: distance,
      angleDegrees: angleDegrees,
      planarTolerance: planarTolerance,
    );
    if (result.normal.length <= 1e-12) {
      throw StateError('A definição produz uma normal de comprimento zero.');
    }
    final unitNormal = result.normal.normalized;
    final xDirection = _stableX(unitNormal);
    final id = 'plane:${DateTime.now().microsecondsSinceEpoch}';
    final number =
        1 +
        runtime.document!.entities.values.where((entity) {
          final contract = entity.data['constructionEntity'];
          return entity.kind == CadDocumentEntityKind.reference &&
              contract is Map &&
              contract['type'] == 'plane';
        }).length;
    await runtime.upsertEntity(
      command: 'entities.plane.${method.name}',
      kind: CadDocumentEntityKind.reference,
      entity: CadSceneEntity(
        id: id,
        kind: CadSceneEntityKind.plane,
        geometry: {
          'origin': result.origin.toJson(),
          'normal': unitNormal.toJson(),
          'xDirection': xDirection.toJson(),
          'visualSize': visualSize.clamp(1.0, 1000000.0),
          'displayColor': 'constructionPlane',
        },
        transparent: true,
      ),
      data: {
        'name': 'Plane $number',
        'collectionId': 'collection:references',
        'constructionEntity': {
          'type': 'plane',
          'method': method.name,
          'origin': result.origin.toJson(),
          'normal': unitNormal.toJson(),
          'xDirection': xDirection.toJson(),
          if (effectiveSourceIds.isNotEmpty)
            'sourceEntityIds': effectiveSourceIds,
          if ({ConstructionPlaneMethod.offset}.contains(method))
            'distance': distance,
          if (method == ConstructionPlaneMethod.angle)
            'angleDegrees': angleDegrees,
          if ({
            ConstructionPlaneMethod.bestFit,
            ConstructionPlaneMethod.extractPlanar,
          }.contains(method)) ...{
            'rmsError': result.rmsError,
            'maxDeviation': result.maxDeviation,
            'pointCount': result.pointCount,
            'tolerance': planarTolerance,
          },
        },
        if (effectiveSourceIds.isNotEmpty)
          'sourceEntityIds': effectiveSourceIds,
        'authoringRoot': true,
        'workspace': 'Entidades',
      },
    );
    runtime.geometrySelection.select(id);
    return id;
  }

  ({
    Vector3 origin,
    Vector3 normal,
    double rmsError,
    double maxDeviation,
    int pointCount,
  })
  _construct(
    ConstructionPlaneMethod method,
    List<String> ids, {
    required Vector3 origin,
    required Vector3 normal,
    required Vector3? pickedPoint,
    required Vector3? pickedNormal,
    required double distance,
    required double angleDegrees,
    required double planarTolerance,
  }) {
    ({Vector3 origin, Vector3 normal}) simple(Vector3 o, Vector3 n) =>
        (origin: o, normal: n);
    late final ({Vector3 origin, Vector3 normal}) plane;
    var rms = 0.0, maximum = 0.0, count = 0;

    switch (method) {
      case ConstructionPlaneMethod.xy:
        plane = simple(Vector3.zero, const Vector3(0, 0, 1));
      case ConstructionPlaneMethod.yz:
        plane = simple(Vector3.zero, const Vector3(1, 0, 0));
      case ConstructionPlaneMethod.zx:
        plane = simple(Vector3.zero, const Vector3(0, 1, 0));
      case ConstructionPlaneMethod.originNormal:
        plane = simple(origin, normal);
      case ConstructionPlaneMethod.threePoints:
        _require(ids, 3, 'Selecione três pontos.');
        final points = ids.take(3).map(_point).toList();
        plane = simple(
          points.first,
          (points[1] - points[0]).cross(points[2] - points[0]),
        );
      case ConstructionPlaneMethod.offset:
        _require(ids, 1, 'Selecione um plano base.');
        final base = _plane(ids.first);
        plane = simple(
          base.origin + base.normal.normalized * distance,
          base.normal,
        );
      case ConstructionPlaneMethod.parallelThroughPoint:
        _require(ids, 2, 'Selecione um plano e um ponto.');
        final base = _firstPlane(ids), point = _firstPoint(ids);
        plane = simple(point, base.normal);
      case ConstructionPlaneMethod.midPlane:
        _require(ids, 2, 'Selecione dois planos.');
        final a = _plane(ids[0]), b = _plane(ids[1]);
        var bNormal = b.normal.normalized;
        if (a.normal.normalized.dot(bNormal) < 0) bNormal = -bNormal;
        final bisector = a.normal.normalized + bNormal;
        plane = simple(
          (a.origin + b.origin) / 2,
          bisector.length <= 1e-12 ? a.normal : bisector,
        );
      case ConstructionPlaneMethod.perpendicular:
        _require(ids, 1, 'Selecione um plano base.');
        final base = _plane(ids.first);
        plane = simple(pickedPoint ?? base.origin, _stableX(base.normal));
      case ConstructionPlaneMethod.angle:
        _require(ids, 2, 'Selecione um plano e um eixo/linha.');
        final base = _firstPlane(ids), axis = _firstDirection(ids);
        plane = simple(
          pickedPoint ?? base.origin,
          _rotate(base.normal.normalized, axis.direction, angleDegrees),
        );
      case ConstructionPlaneMethod.normalToCurve:
        _require(ids, 1, 'Selecione uma curva ou linha.');
        final path = _points(ids.first);
        final anchor = pickedPoint ?? path[path.length ~/ 2];
        plane = simple(anchor, _curveTangent(path, anchor));
      case ConstructionPlaneMethod.tangentToSurface:
        _require(ids, 1, 'Selecione uma face, superfície ou malha.');
        if (pickedPoint == null || pickedNormal == null) {
          throw StateError(
            'Clique na superfície para definir ponto e normal tangente.',
          );
        }
        plane = simple(pickedPoint, pickedNormal);
      case ConstructionPlaneMethod.lineAndPoint:
        _require(ids, 2, 'Selecione uma linha/curva e um ponto.');
        final direction = _firstDirection(ids), point = _firstPoint(ids);
        plane = simple(
          direction.origin,
          direction.direction.cross(point - direction.origin),
        );
      case ConstructionPlaneMethod.twoLines:
        _require(ids, 2, 'Selecione duas linhas ou curvas.');
        final a = _direction(ids[0]), b = _direction(ids[1]);
        plane = simple(a.origin, a.direction.cross(b.direction));
      case ConstructionPlaneMethod.bestFit ||
          ConstructionPlaneMethod.extractPlanar:
        _require(ids, 1, 'Selecione geometria com ao menos três amostras.');
        final samples = ids.expand(_points).toList();
        if (samples.length < 3) {
          throw StateError(
            'São necessários pelo menos três pontos geométricos.',
          );
        }
        final fit = const FittingEngine().fitPlane(samples);
        rms = fit.rmsError;
        maximum = fit.maxError;
        count = fit.pointCount;
        if (method == ConstructionPlaneMethod.extractPlanar &&
            maximum > planarTolerance) {
          throw StateError(
            'A geometria não é plana na tolerância informada: desvio máximo '
            '${maximum.toStringAsPrecision(5)}.',
          );
        }
        plane = simple(fit.geometry.origin, fit.geometry.normal);
    }
    return (
      origin: plane.origin,
      normal: plane.normal,
      rmsError: rms,
      maxDeviation: maximum,
      pointCount: count,
    );
  }

  void _require(List<String> ids, int count, String message) {
    if (ids.length < count) throw StateError(message);
  }

  CadSceneEntity _entity(String id) =>
      runtime.scene.find(id) ??
      (throw StateError('Entidade não encontrada: $id'));

  ({Vector3 origin, Vector3 normal}) _plane(String id) {
    final geometry = _entity(id).geometry;
    final origin = _vector(geometry['origin']);
    final normal = _vector(geometry['normal']);
    if (origin == null || normal == null) {
      throw StateError('$id não é um plano.');
    }
    return (origin: origin, normal: normal.normalized);
  }

  ({Vector3 origin, Vector3 normal}) _firstPlane(List<String> ids) {
    for (final id in ids) {
      try {
        return _plane(id);
      } on StateError {
        // Continue looking for the required semantic type.
      }
    }
    throw StateError('A seleção não contém um plano.');
  }

  Vector3 _point(String id) {
    final geometry = _entity(id).geometry;
    return _vector(geometry['position']) ??
        _vector(geometry['origin']) ??
        (_points(id).length == 1
            ? _points(id).single
            : throw StateError('$id não representa um ponto.'));
  }

  Vector3 _firstPoint(List<String> ids) {
    for (final id in ids) {
      if (_entity(id).kind != CadSceneEntityKind.point) continue;
      return _point(id);
    }
    throw StateError('A seleção não contém um ponto.');
  }

  ({Vector3 origin, Vector3 direction}) _direction(String id) {
    final geometry = _entity(id).geometry;
    final direct = _vector(geometry['direction']);
    if (direct != null) {
      return (
        origin: _vector(geometry['origin']) ?? Vector3.zero,
        direction: direct.normalized,
      );
    }
    final path = _points(id);
    if (path.length < 2) throw StateError('$id não define uma direção.');
    return (origin: path.first, direction: (path.last - path.first).normalized);
  }

  ({Vector3 origin, Vector3 direction}) _firstDirection(List<String> ids) {
    for (final id in ids) {
      if ({
        CadSceneEntityKind.axis,
        CadSceneEntityKind.curve,
        CadSceneEntityKind.sketch,
      }.contains(_entity(id).kind)) {
        return _direction(id);
      }
    }
    throw StateError('A seleção não contém eixo, linha ou curva.');
  }

  List<Vector3> _points(String id) {
    final geometry = _entity(id).geometry;
    final result = <Vector3>[];
    final points = geometry['points'];
    if (points is List) result.addAll(points.map(_vector).whereType<Vector3>());
    final segments = geometry['segments'];
    if (segments is List) {
      for (final segment in segments.whereType<List>()) {
        result.addAll(segment.map(_vector).whereType<Vector3>());
      }
    }
    final nodes = geometry['nodes'];
    if (nodes is List) {
      for (var i = 0; i + 2 < nodes.length; i += 3) {
        final x = nodes[i], y = nodes[i + 1], z = nodes[i + 2];
        if (x is num && y is num && z is num) {
          result.add(Vector3(x.toDouble(), y.toDouble(), z.toDouble()));
        }
      }
    }
    final point = _vector(geometry['position']);
    if (point != null) result.add(point);
    return result;
  }

  Vector3 _curveTangent(List<Vector3> path, Vector3 anchor) {
    if (path.length < 2) throw StateError('A curva precisa de duas amostras.');
    var best = double.infinity, index = 0;
    for (var i = 0; i < path.length; i++) {
      final distance = path[i].distanceTo(anchor);
      if (distance < best) {
        best = distance;
        index = i;
      }
    }
    final a = path[index == 0 ? 0 : index - 1];
    final b = path[index == path.length - 1 ? path.length - 1 : index + 1];
    return (b - a).normalized;
  }

  Vector3 _rotate(Vector3 vector, Vector3 rawAxis, double degrees) {
    final axis = rawAxis.normalized;
    if (axis.length <= 1e-12) throw StateError('O eixo angular é inválido.');
    final angle = degrees * math.pi / 180;
    return vector * math.cos(angle) +
        axis.cross(vector) * math.sin(angle) +
        axis * axis.dot(vector) * (1 - math.cos(angle));
  }

  Vector3 _stableX(Vector3 rawNormal) {
    final normal = rawNormal.normalized;
    final seed = normal.z.abs() < .9
        ? const Vector3(0, 0, 1)
        : const Vector3(0, 1, 0);
    return seed.cross(normal).normalized;
  }

  Vector3? _vector(Object? raw) {
    if (raw is! List || raw.length < 3) return null;
    final x = raw[0], y = raw[1], z = raw[2];
    if (x is! num || y is! num || z is! num) return null;
    return Vector3(x.toDouble(), y.toDouble(), z.toDouble());
  }
}
