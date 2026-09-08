part of 'cad_runtime.dart';

extension _CadIntegrity on CadRuntime {
  void _validateAssociations(
    CadDocument before,
    CadDocument candidate,
    List<CadDocumentEntity> requested,
  ) {
    for (final entity in requested) {
      final collectionId = candidate.entities[entity.id]?.data['collectionId'];
      if (entity.data['deleted'] == true || collectionId == null) {
        continue;
      }
      final previous = before.entities[entity.id];
      if (previous != null &&
          previous.data['deleted'] != true &&
          previous.data['collectionId'] == collectionId) {
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
    final walk = DependencyWalk(restored, (id) {
      final entity = candidate.entities[id];
      if (entity == null || entity.data['deleted'] == true) {
        throw StateError('Restore requires an active dependency: $id');
      }
      return _documentDependencies(entity);
    });
    for (final component in walk.components) {
      if (component.any(restored.contains) &&
          !component.every(restored.contains)) {
        throw StateError(
          'Restore requires the complete dependency cycle: $component',
        );
      }
    }
  }

  OfficialExportUpdate _exportUpdateForDelta(
    CadDocument before,
    List<CadDocumentEntity> requested,
    List<String> removed,
    OfficialExportUpdate update,
  ) {
    if (update.action != OfficialExportAction.keep) return update;
    final id = before.officialExportShapeId;
    if (id == null || !before.entities.containsKey(id)) return update;
    final replacement = {for (final entity in requested) entity.id: entity}[id];
    // Upsert wins over removal, just as in CadDocument.mutate. A legacy invalid
    // reference is never cleaned by an unrelated keep operation.
    if ((replacement == null && removed.contains(id)) ||
        (replacement?.data['deleted'] == true &&
            before.entities[id]!.data['deleted'] != true)) {
      return const OfficialExportUpdate.clear();
    }
    return update;
  }

  void _validateDependencyDelta(
    CadDocument before,
    CadDocument candidate,
    List<CadDocumentEntity> requested,
    List<String> removed,
    Set<String> restoredIds,
  ) {
    final affected = {...removed, ...requested.map((e) => e.id)};
    final deleted = <String>{}, recycled = <String>{};
    final restored = {...restoredIds};
    final activeRoots = <String>{}, recycledRoots = <String>{};
    for (final id in affected) {
      final old = before.entities[id], next = candidate.entities[id];
      if (next == null) {
        if (old != null) deleted.add(id);
        continue;
      }
      if (old?.data['deleted'] != true && next.data['deleted'] == true) {
        recycled.add(id);
      }
      if (old?.data['deleted'] == true && next.data['deleted'] != true) {
        restored.add(id);
      }
      final addedEdges = _documentDependencies(
        next,
      ).difference(old == null ? const {} : _documentDependencies(old));
      (next.data['deleted'] == true ? recycledRoots : activeRoots).addAll(
        addedEdges,
      );
    }
    _validateRetiredDependencies(candidate, deleted, recycled);
    _validateRestoredDependencies(candidate, restored);
    for (final (roots, active) in [
      (activeRoots, true),
      (recycledRoots, false),
    ]) {
      DependencyWalk(roots, (id) {
        final entity = candidate.entities[id];
        if (entity == null || (active && entity.data['deleted'] == true)) {
          throw StateError('Invalid new dependency: $id');
        }
        return _documentDependencies(entity);
      });
    }
  }

  void _validateRetiredDependencies(
    CadDocument candidate,
    Set<String> removed,
    Set<String> recycled,
  ) {
    if (removed.isEmpty && recycled.isEmpty) return;
    final reverse = _reverseDependencies(candidate);
    for (final (roots, purge) in [(removed, true), (recycled, false)]) {
      final seen = {...roots}, pending = roots.toList();
      while (pending.isNotEmpty) {
        for (final id in reverse[pending.removeLast()] ?? const <String>{}) {
          if (!seen.add(id)) continue;
          final entity = candidate.entities[id]!;
          if (purge || entity.data['deleted'] != true) {
            throw StateError(
              'Retirement requires the explicit dependent batch: $id',
            );
          }
          pending.add(id);
        }
      }
    }
  }

  List<String> _legacyIntegrityDiagnostics(CadDocument document) {
    final issues = <String>[];
    for (final entity in document.entities.values) {
      for (final id in _documentDependencies(entity)) {
        final dependency = document.entities[id];
        if (dependency == null ||
            (entity.data['deleted'] != true &&
                dependency.data['deleted'] == true)) {
          issues.add('Invalid dependency: ${entity.id} -> $id');
        }
      }
      final collectionId = entity.data['collectionId'];
      final collection = document.entities[collectionId];
      if (entity.data['deleted'] != true &&
          collectionId != null &&
          (collection?.kind != CadDocumentEntityKind.collection ||
              collection?.data['deleted'] == true)) {
        issues.add('Invalid collection: ${entity.id} -> $collectionId');
      }
    }
    final id = document.officialExportShapeId;
    final entity = document.entities[id];
    if (id != null &&
        (entity == null ||
            entity.data['deleted'] == true ||
            entity.shape == null ||
            entity.shape!.metadata['temporary'] == true)) {
      issues.add('Invalid official export: $id');
    }
    return List.unmodifiable(issues);
  }
}

Map<String, Set<String>> _reverseDependencies(CadDocument document) {
  final reverse = <String, Set<String>>{};
  for (final entity in document.entities.values) {
    for (final id in _documentDependencies(entity)) {
      reverse.putIfAbsent(id, () => <String>{}).add(entity.id);
    }
  }
  return reverse;
}

Set<String> _documentDependencies(CadDocumentEntity entity) =>
    FeatureDependencies.resolve(entity.data).toSet();
