part of 'cad_runtime.dart';

extension _CadIntegrity on CadRuntime {
  void _validateAssociations(
    CadDocument candidate,
    List<CadDocumentEntity> requested,
  ) {
    for (final entity in requested) {
      final collectionId = candidate.entities[entity.id]?.data['collectionId'];
      if (entity.data['deleted'] == true || collectionId == null) {
        continue;
      }
      final collection = candidate.entities[collectionId];
      if (collection?.kind != CadDocumentEntityKind.collection ||
          collection?.data['deleted'] == true) {
        throw StateError('Invalid collection destination: $collectionId');
      }
    }
  }

  CadDocument _detachRetiredCollections(
    CadDocument before,
    CadDocument candidate,
  ) {
    final retired = before.entities.values
        .where(
          (entity) =>
              entity.kind == CadDocumentEntityKind.collection &&
              entity.data['deleted'] != true &&
              (candidate.entities[entity.id] == null ||
                  candidate.entities[entity.id]!.data['deleted'] == true),
        )
        .map((entity) => entity.id)
        .toSet();
    if (retired.isEmpty) return candidate;
    final entities = {...candidate.entities};
    for (final entity in candidate.entities.values) {
      final collectionId = entity.data['collectionId'];
      if (entity.data['deleted'] == true ||
          !retired.contains(collectionId) ||
          before.entities[entity.id]?.data['collectionId'] != collectionId) {
        continue;
      }
      entities[entity.id] = CadDocumentEntity(
        id: entity.id,
        kind: entity.kind,
        shape: entity.shape,
        mesh: entity.mesh,
        data: {...entity.data, 'collectionId': null},
      );
    }
    return CadDocument(
      projectId: candidate.projectId,
      entities: entities,
      revisions: candidate.revisions,
      parameters: candidate.parameters,
      officialExportShapeId: candidate.officialExportShapeId,
    );
  }

  void _validateRestoredDependencies(
    CadDocument candidate,
    Set<String> restored,
  ) {
    final visited = <String>{};
    final path = <String>[];
    void visit(String id) {
      final entity = candidate.entities[id];
      if (entity == null || entity.data['deleted'] == true) {
        throw StateError('Restore requires an active dependency: $id');
      }
      final cycleStart = path.indexOf(id);
      if (cycleStart >= 0) {
        // The documentary lifecycle model represents cyclic graphs. A restored
        // cycle must be complete in this batch; never revive only part of it.
        if (!path.skip(cycleStart).every(restored.contains)) {
          throw StateError(
            'Restore requires the complete dependency cycle: $id',
          );
        }
        return;
      }
      if (!visited.add(id)) return;
      path.add(id);
      for (final dependency in _documentDependencies(entity)) {
        visit(dependency);
      }
      path.removeLast();
    }

    for (final id in restored) {
      visit(id);
    }
  }
}

Set<String> _documentDependencies(CadDocumentEntity entity) {
  final data = entity.data;
  final result = <String>{};
  if (FeatureLifecycleContract.appliesTo(entity)) {
    result.addAll(FeatureLifecycleContract.require(entity).dependencyIds);
  } else {
    for (final key in ['dependencies', 'references', 'sourceIds']) {
      final value = data[key];
      if (value is List) result.addAll(value.whereType<String>());
    }
  }
  final source = data['sourceEntityId'];
  if (source is String) result.add(source);
  return result;
}
