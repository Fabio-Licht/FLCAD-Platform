import '../../core/cad_document/cad_document.dart';
import '../../core/geometric_kernel/geometry/vectors.dart';
import '../cad_viewport/scene/cad_scene_graph.dart';
import '../runtime/cad_runtime.dart';

/// Construction methods intentionally mirror the vocabulary used by
/// professional CAD systems while keeping the persisted contract extensible.
enum ConstructionPointMethod {
  coordinates,
  startPoint,
  endPoint,
  midpoint,
  equidistant,
  onEntity,
}

class EntityPointService {
  EntityPointService(this.runtime);

  final CadRuntime runtime;

  Future<List<String>> create({
    required ConstructionPointMethod method,
    String? sourceEntityId,
    Vector3 coordinates = Vector3.zero,
    Vector3? pickedPoint,
    double parameter = .5,
    int divisionCount = 2,
  }) async {
    if (runtime.document == null) {
      throw StateError('Abra um projeto antes de criar pontos.');
    }

    final source = sourceEntityId == null
        ? null
        : runtime.scene.find(sourceEntityId);
    final points = switch (method) {
      ConstructionPointMethod.coordinates => [coordinates],
      ConstructionPointMethod.startPoint => [_path(source).first],
      ConstructionPointMethod.endPoint => [_path(source).last],
      ConstructionPointMethod.midpoint => [_pointAt(_path(source), .5)],
      ConstructionPointMethod.onEntity => [
        pickedPoint ?? _pointAt(_path(source), parameter.clamp(0.0, 1.0)),
      ],
      ConstructionPointMethod.equidistant => _equidistant(
        _path(source),
        divisionCount,
      ),
    };

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final entities = <CadDocumentEntity>[];
    final ids = <String>[];
    for (var index = 0; index < points.length; index++) {
      final id = 'point:$stamp:$index';
      final point = points[index];
      ids.add(id);
      entities.add(
        CadDocumentEntity(
          id: id,
          kind: CadDocumentEntityKind.vertex,
          data: {
            'name': 'Point ${_nextPointNumber() + index}',
            'collectionId': 'collection:references',
            'sceneKind': CadSceneEntityKind.point.name,
            'sceneGeometry': {
              'position': point.toJson(),
              'markerRadius': 5.0,
              'displayColor': 'constructionPoint',
            },
            'sceneVisible': true,
            'constructionEntity': {
              'type': 'point',
              'method': method.name,
              'coordinates': point.toJson(),
              'sourceEntityId': ?sourceEntityId,
              if (method == ConstructionPointMethod.onEntity)
                'parameter': parameter.clamp(0.0, 1.0),
              if (pickedPoint != null) 'pickedOnGeometry': true,
              if (method == ConstructionPointMethod.equidistant)
                'divisionCount': divisionCount,
              if (points.length > 1) 'sequenceIndex': index,
            },
            if (sourceEntityId != null) 'sourceEntityIds': [sourceEntityId],
            'authoringRoot': true,
            'workspace': 'Entities',
          },
        ),
      );
    }
    await runtime.upsertEntityBatch(
      command: 'entities.point.${method.name}',
      entities: entities,
    );
    runtime.geometrySelection.select(ids.last);
    return ids;
  }

  int _nextPointNumber() =>
      1 +
      (runtime.document?.entities.values.where((entity) {
            final contract = entity.data['constructionEntity'];
            return entity.kind == CadDocumentEntityKind.vertex &&
                contract is Map &&
                contract['type'] == 'point';
          }).length ??
          0);

  List<Vector3> _path(CadSceneEntity? source) {
    if (source == null) {
      throw StateError(
        'Selecione uma entidade de origem no viewport ou Explorer.',
      );
    }
    final geometry = source.geometry;

    Vector3? vector(Object? raw) {
      if (raw is! List || raw.length < 3) return null;
      final values = raw.take(3).whereType<num>().toList();
      if (values.length != 3) return null;
      return Vector3(
        values[0].toDouble(),
        values[1].toDouble(),
        values[2].toDouble(),
      );
    }

    final points = geometry['points'];
    if (points is List) {
      final path = points.map(vector).whereType<Vector3>().toList();
      if (path.isNotEmpty) return path;
    }
    final segments = geometry['segments'];
    if (segments is List) {
      final path = <Vector3>[];
      for (final segment in segments.whereType<List>()) {
        for (final raw in segment) {
          final point = vector(raw);
          if (point != null && (path.isEmpty || path.last != point)) {
            path.add(point);
          }
        }
      }
      if (path.isNotEmpty) return path;
    }
    final nodes = geometry['nodes'];
    if (nodes is List) {
      final path = <Vector3>[];
      for (var i = 0; i + 2 < nodes.length; i += 3) {
        final x = nodes[i], y = nodes[i + 1], z = nodes[i + 2];
        if (x is num && y is num && z is num) {
          path.add(Vector3(x.toDouble(), y.toDouble(), z.toDouble()));
        }
      }
      if (path.isNotEmpty) return path;
    }
    final position = vector(geometry['position']);
    if (position != null) return [position];
    final origin = vector(geometry['origin']);
    if (origin != null) return [origin];
    throw StateError(
      'A entidade selecionada não publica geometria utilizável para pontos.',
    );
  }

  List<Vector3> _equidistant(List<Vector3> path, int count) {
    if (count < 2 || count > 1000) {
      throw RangeError.range(count, 2, 1000, 'divisionCount');
    }
    return List.generate(count, (index) => _pointAt(path, index / (count - 1)));
  }

  Vector3 _pointAt(List<Vector3> path, double parameter) {
    if (path.length == 1) return path.single;
    final lengths = <double>[];
    var total = 0.0;
    for (var i = 1; i < path.length; i++) {
      total += path[i - 1].distanceTo(path[i]);
      lengths.add(total);
    }
    if (total <= 1e-12) return path.first;
    final target = total * parameter;
    for (var i = 0; i < lengths.length; i++) {
      if (target <= lengths[i]) {
        final previous = i == 0 ? 0.0 : lengths[i - 1];
        final segment = lengths[i] - previous;
        final local = segment <= 1e-12 ? 0.0 : (target - previous) / segment;
        return path[i] + (path[i + 1] - path[i]) * local;
      }
    }
    return path.last;
  }
}
