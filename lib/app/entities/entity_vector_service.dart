import '../../core/cad_document/cad_document.dart';
import '../../core/geometric_kernel/geometry/vectors.dart';
import '../../core/geometric_kernel/services/fitting_engine.dart';
import '../cad_viewport/scene/cad_scene_graph.dart';
import '../runtime/cad_runtime.dart';

enum ConstructionVectorMethod {
  xAxis,
  yAxis,
  zAxis,
  components,
  twoPoints,
  directionBetweenEntities,
  fromLineOrCurve,
  tangentToCurve,
  planeNormal,
  surfaceNormal,
  planeIntersection,
  crossProduct,
  bisector,
  projectedOnPlane,
  reverse,
  bestFitDirection,
}

class EntityVectorService {
  EntityVectorService(this.runtime);

  final CadRuntime runtime;

  Future<String> create({
    required ConstructionVectorMethod method,
    List<String> sourceEntityIds = const [],
    Vector3 origin = Vector3.zero,
    Vector3 components = const Vector3(1, 0, 0),
    Vector3? pickedPoint,
    Vector3? pickedNormal,
    double visualLength = 40,
    bool reverse = false,
  }) async {
    if (runtime.document == null) {
      throw StateError('Abra um projeto antes de criar vetores.');
    }
    final sourceFree = {
      ConstructionVectorMethod.xAxis,
      ConstructionVectorMethod.yAxis,
      ConstructionVectorMethod.zAxis,
      ConstructionVectorMethod.components,
    }.contains(method);
    final ids = sourceFree ? const <String>[] : sourceEntityIds;
    final value = _construct(
      method,
      ids,
      origin: origin,
      components: components,
      pickedPoint: pickedPoint,
      pickedNormal: pickedNormal,
    );
    if (value.direction.length <= 1e-12) {
      throw StateError('A definição produz um vetor de comprimento zero.');
    }
    final direction = reverse
        ? -value.direction.normalized
        : value.direction.normalized;
    final magnitude = value.direction.length;
    final id = 'vector:${DateTime.now().microsecondsSinceEpoch}';
    final number =
        1 +
        runtime.document!.entities.values.where((entity) {
          final contract = entity.data['constructionEntity'];
          return entity.kind == CadDocumentEntityKind.reference &&
              contract is Map &&
              contract['type'] == 'vector';
        }).length;
    await runtime.upsertEntity(
      command: 'entities.vector.${method.name}',
      kind: CadDocumentEntityKind.reference,
      entity: CadSceneEntity(
        id: id,
        kind: CadSceneEntityKind.axis,
        geometry: {
          'origin': value.origin.toJson(),
          'direction': direction.toJson(),
          'visualLength': visualLength.clamp(1.0, 1000000.0),
          'displayColor': 'constructionVector',
        },
      ),
      data: {
        'name': 'Vector $number',
        'collectionId': 'collection:references',
        'constructionEntity': {
          'type': 'vector',
          'method': method.name,
          'origin': value.origin.toJson(),
          'direction': direction.toJson(),
          'magnitude': magnitude,
          'reversed': reverse,
          if (ids.isNotEmpty) 'sourceEntityIds': ids,
          if (method == ConstructionVectorMethod.bestFitDirection) ...{
            'rmsError': value.rmsError,
            'maxDeviation': value.maxDeviation,
            'pointCount': value.pointCount,
          },
        },
        if (ids.isNotEmpty) 'sourceEntityIds': ids,
        'authoringRoot': true,
        'workspace': 'Entidades',
      },
    );
    runtime.geometrySelection.select(id);
    return id;
  }

  ({
    Vector3 origin,
    Vector3 direction,
    double rmsError,
    double maxDeviation,
    int pointCount,
  })
  _construct(
    ConstructionVectorMethod method,
    List<String> ids, {
    required Vector3 origin,
    required Vector3 components,
    required Vector3? pickedPoint,
    required Vector3? pickedNormal,
  }) {
    late Vector3 vectorOrigin, direction;
    var rms = 0.0, maximum = 0.0, count = 0;
    switch (method) {
      case ConstructionVectorMethod.xAxis:
        vectorOrigin = Vector3.zero;
        direction = const Vector3(1, 0, 0);
      case ConstructionVectorMethod.yAxis:
        vectorOrigin = Vector3.zero;
        direction = const Vector3(0, 1, 0);
      case ConstructionVectorMethod.zAxis:
        vectorOrigin = Vector3.zero;
        direction = const Vector3(0, 0, 1);
      case ConstructionVectorMethod.components:
        vectorOrigin = origin;
        direction = components;
      case ConstructionVectorMethod.twoPoints:
        _require(ids, 2, 'Selecione dois pontos.');
        vectorOrigin = _point(ids[0]);
        direction = _point(ids[1]) - vectorOrigin;
      case ConstructionVectorMethod.directionBetweenEntities:
        _require(ids, 2, 'Selecione duas entidades.');
        vectorOrigin = _center(ids[0]);
        direction = _center(ids[1]) - vectorOrigin;
      case ConstructionVectorMethod.fromLineOrCurve:
        _require(ids, 1, 'Selecione uma linha, eixo ou curva.');
        final source = _direction(ids.first);
        vectorOrigin = source.origin;
        direction = source.direction;
      case ConstructionVectorMethod.tangentToCurve:
        _require(ids, 1, 'Selecione uma curva e clique na posição desejada.');
        final path = _points(ids.first);
        vectorOrigin = pickedPoint ?? path[path.length ~/ 2];
        direction = _curveTangent(path, vectorOrigin);
      case ConstructionVectorMethod.planeNormal:
        _require(ids, 1, 'Selecione um plano.');
        final plane = _plane(ids.first);
        vectorOrigin = pickedPoint ?? plane.origin;
        direction = plane.normal;
      case ConstructionVectorMethod.surfaceNormal:
        _require(
          ids,
          1,
          'Selecione e clique em uma face, superfície ou malha.',
        );
        if (pickedPoint == null || pickedNormal == null) {
          throw StateError('Clique na geometria para obter sua normal local.');
        }
        vectorOrigin = pickedPoint;
        direction = pickedNormal;
      case ConstructionVectorMethod.planeIntersection:
        _require(ids, 2, 'Selecione dois planos não paralelos.');
        final a = _plane(ids[0]), b = _plane(ids[1]);
        vectorOrigin = (a.origin + b.origin) / 2;
        direction = a.normal.cross(b.normal);
      case ConstructionVectorMethod.crossProduct:
        _require(ids, 2, 'Selecione dois vetores, eixos, linhas ou curvas.');
        final a = _direction(ids[0]), b = _direction(ids[1]);
        vectorOrigin = (a.origin + b.origin) / 2;
        direction = a.direction.cross(b.direction);
      case ConstructionVectorMethod.bisector:
        _require(ids, 2, 'Selecione duas direções.');
        final a = _direction(ids[0]), b = _direction(ids[1]);
        var second = b.direction.normalized;
        if (a.direction.normalized.dot(second) < 0) second = -second;
        vectorOrigin = (a.origin + b.origin) / 2;
        direction = a.direction.normalized + second;
      case ConstructionVectorMethod.projectedOnPlane:
        _require(ids, 2, 'Selecione uma direção e um plano.');
        final source = _firstDirection(ids), plane = _firstPlane(ids);
        vectorOrigin = pickedPoint ?? plane.origin;
        direction =
            source.direction -
            plane.normal.normalized *
                source.direction.dot(plane.normal.normalized);
      case ConstructionVectorMethod.reverse:
        _require(ids, 1, 'Selecione um vetor ou eixo.');
        final source = _direction(ids.first);
        vectorOrigin = source.origin;
        direction = -source.direction;
      case ConstructionVectorMethod.bestFitDirection:
        _require(ids, 1, 'Selecione geometria com ao menos dois pontos.');
        final samples = ids.expand(_points).toList();
        if (samples.length < 2) {
          throw StateError('São necessários ao menos dois pontos geométricos.');
        }
        final fit = const FittingEngine().fitLine(samples);
        vectorOrigin = fit.geometry.origin;
        direction = fit.geometry.direction;
        rms = fit.rmsError;
        maximum = fit.maxError;
        count = fit.pointCount;
    }
    return (
      origin: vectorOrigin,
      direction: direction,
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

  Vector3 _point(String id) {
    final geometry = _entity(id).geometry;
    return _vector(geometry['position']) ??
        (_entity(id).kind == CadSceneEntityKind.point
            ? _vector(geometry['origin'])
            : null) ??
        (throw StateError('$id não é um ponto.'));
  }

  Vector3 _center(String id) {
    final entity = _entity(id);
    final direct =
        _vector(entity.geometry['position']) ??
        _vector(entity.geometry['origin']);
    if (direct != null) return direct;
    final points = _points(id);
    if (points.isEmpty) throw StateError('$id não fornece posição geométrica.');
    return points.reduce((a, b) => a + b) / points.length.toDouble();
  }

  ({Vector3 origin, Vector3 normal}) _plane(String id) {
    final geometry = _entity(id).geometry;
    final planeOrigin = _vector(geometry['origin']);
    final normal = _vector(geometry['normal']);
    if (planeOrigin == null || normal == null) {
      throw StateError('$id não é um plano.');
    }
    return (origin: planeOrigin, normal: normal.normalized);
  }

  ({Vector3 origin, Vector3 normal}) _firstPlane(List<String> ids) {
    for (final id in ids) {
      try {
        return _plane(id);
      } on StateError {
        // Continue looking for a plane.
      }
    }
    throw StateError('A seleção não contém plano.');
  }

  ({Vector3 origin, Vector3 direction}) _direction(String id) {
    final geometry = _entity(id).geometry;
    final direct = _vector(geometry['direction']);
    if (direct != null) {
      return (
        origin: _vector(geometry['origin']) ?? Vector3.zero,
        direction: direct,
      );
    }
    final path = _points(id);
    if (path.length < 2) throw StateError('$id não define uma direção.');
    return (origin: path.first, direction: path.last - path.first);
  }

  ({Vector3 origin, Vector3 direction}) _firstDirection(List<String> ids) {
    for (final id in ids) {
      if (_entity(id).kind == CadSceneEntityKind.plane) continue;
      try {
        return _direction(id);
      } on StateError {
        // Continue looking for a direction.
      }
    }
    throw StateError('A seleção não contém vetor, eixo, linha ou curva.');
  }

  List<Vector3> _points(String id) {
    final geometry = _entity(id).geometry;
    final output = <Vector3>[];
    final points = geometry['points'];
    if (points is List) output.addAll(points.map(_vector).whereType<Vector3>());
    final segments = geometry['segments'];
    if (segments is List) {
      for (final segment in segments.whereType<List>()) {
        output.addAll(segment.map(_vector).whereType<Vector3>());
      }
    }
    final nodes = geometry['nodes'];
    if (nodes is List) {
      for (var i = 0; i + 2 < nodes.length; i += 3) {
        final x = nodes[i], y = nodes[i + 1], z = nodes[i + 2];
        if (x is num && y is num && z is num) {
          output.add(Vector3(x.toDouble(), y.toDouble(), z.toDouble()));
        }
      }
    }
    final position = _vector(geometry['position']);
    if (position != null) output.add(position);
    return output;
  }

  Vector3 _curveTangent(List<Vector3> path, Vector3 anchor) {
    if (path.length < 2) throw StateError('A curva precisa de duas amostras.');
    var nearest = 0, best = double.infinity;
    for (var i = 0; i < path.length; i++) {
      final distance = path[i].distanceTo(anchor);
      if (distance < best) {
        best = distance;
        nearest = i;
      }
    }
    final a = path[nearest == 0 ? 0 : nearest - 1];
    final b = path[nearest == path.length - 1 ? path.length - 1 : nearest + 1];
    return b - a;
  }

  Vector3? _vector(Object? raw) {
    if (raw is! List || raw.length < 3) return null;
    final x = raw[0], y = raw[1], z = raw[2];
    if (x is! num || y is! num || z is! num) return null;
    return Vector3(x.toDouble(), y.toDouble(), z.toDouble());
  }
}
