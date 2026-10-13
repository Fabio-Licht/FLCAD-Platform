import 'dart:convert';

import '../analytics/sketch_analytics.dart';
import '../entities/sketch_entities.dart';
import '../graph/sketch_graph.dart';
import '../history/sketch_history.dart';
import '../models/sketch_models.dart';
import '../repository/sketch_repository.dart';
import '../runtime/sketch_runtime.dart';
import '../selection/sketch_selection_engine.dart';

class SketchEngine {
  SketchEngine({
    required this.repository,
    SketchRuntime? runtime,
    SketchAnalytics? analytics,
    SketchHistory? history,
  }) : runtime = runtime ?? SketchRuntime(),
       analytics = analytics ?? SketchAnalytics(),
       history = history ?? SketchHistory() {
    selection = SketchSelectionEngine(this.analytics);
  }
  final SketchRepository repository;
  final SketchRuntime runtime;
  final SketchAnalytics analytics;
  final SketchHistory history;
  final graphs = SketchGraphSet();
  late final SketchSelectionEngine selection;
  final Map<String, Sketch> sketches = {};
  final Map<String, SketchEntity> entities = {};
  final List<_Snapshot> _undo = [];
  final List<_Snapshot> _redo = [];
  int _transactionDepth = 0;
  String? activeSketchId;
  String? projectId;
  String? activeSketchRestoreDiagnostic;
  bool activeSketchIdentityPersisted = false;

  Sketch createSketch(
    String name, {
    SketchPlane? plane,
    SketchCoordinateSystem? coordinates,
  }) => _change(SketchHistoryAction.create, name, () {
    final sketch = Sketch(name: name, plane: plane, coordinates: coordinates);
    sketches[sketch.id] = sketch;
    graphs.sketch.addNode(sketch.id);
    activeSketchId = sketch.id;
    analytics.sketches++;
    return sketch;
  });
  void deleteSketch(String id) => _change(SketchHistoryAction.delete, id, () {
    final sketch =
        sketches.remove(id) ?? (throw StateError('Unknown sketch: $id'));
    for (final entityId in List<String>.of(sketch.entityIds)) {
      _removeEntity(entityId);
    }
    graphs.sketch.removeNode(id);
    if (activeSketchId == id) activeSketchId = null;
    analytics.sketches--;
  });
  void openSketch(String id) {
    if (!sketches.containsKey(id)) throw StateError('Unknown sketch: $id');
    activeSketchId = id;
  }

  /// Rehydrates a Sketch root that is still present in the CAD document but
  /// has no canonical file in the Sketch repository. This is deliberately a
  /// non-historic restore: it repairs the engine/document identity boundary
  /// without creating an edit, changing the document, or adding Undo state.
  void restoreSketch(
    Sketch sketch, {
    Iterable<SketchEntity> entities = const <SketchEntity>[],
  }) {
    if (sketches.containsKey(sketch.id)) return;
    final restoredEntities = entities.toList(growable: false);
    final duplicate =
        restoredEntities.map((entity) => entity.id).toSet().length !=
        restoredEntities.length;
    if (duplicate) {
      throw StateError('Sketch ${sketch.id} contains duplicate entity IDs.');
    }
    for (final entity in restoredEntities) {
      final existing = this.entities[entity.id];
      if (existing != null) {
        throw StateError(
          'Sketch entity ID ${entity.id} belongs to another restored Sketch.',
        );
      }
    }
    sketches[sketch.id] = sketch;
    graphs.sketch.addNode(sketch.id);
    for (final entity in restoredEntities) {
      if (!sketch.entityIds.contains(entity.id)) {
        sketch.entityIds.add(entity.id);
      }
      entity.graphNode = entity.graphNode.isEmpty
          ? entity.id
          : entity.graphNode;
      this.entities[entity.id] = entity;
      graphs.entities.addNode(entity.id);
      graphs.dependencies.addNode(entity.id);
      if (entity.reference) graphs.references.addNode(entity.id);
      if (entity.construction) graphs.construction.addNode(entity.id);
    }
    analytics.sketches = sketches.length;
    analytics.entities = this.entities.length;
    analytics.referenceEntities = this.entities.values
        .where((entity) => entity.reference)
        .length;
    analytics.constructionEntities = this.entities.values
        .where((entity) => entity.construction)
        .length;
  }

  void closeSketch() => activeSketchId = null;
  Sketch get activeSketch =>
      sketches[activeSketchId] ?? (throw StateError('No active sketch'));

  T addEntity<T extends SketchEntity>(T entity) =>
      _change(SketchHistoryAction.create, entity.id, () {
        final sketch = activeSketch;
        if (entities.containsKey(entity.id)) {
          throw StateError('Duplicate sketch entity id: ${entity.id}');
        }
        entity.graphNode = entity.id;
        entities[entity.id] = entity;
        sketch.entityIds.add(entity.id);
        graphs.entities.addNode(entity.id);
        graphs.dependencies.addNode(entity.id);
        if (entity.reference) {
          graphs.references.addNode(entity.id);
          analytics.referenceEntities++;
        }
        if (entity.construction) {
          graphs.construction.addNode(entity.id);
          analytics.constructionEntities++;
        }
        analytics.entities++;
        return entity;
      });
  void deleteEntity(String id) =>
      _change(SketchHistoryAction.delete, id, () => _removeEntity(id));
  void _removeEntity(String id) {
    final entity =
        entities.remove(id) ?? (throw StateError('Unknown entity: $id'));
    for (final s in sketches.values) {
      s.entityIds.remove(id);
    }
    graphs.entities.removeNode(id);
    graphs.dependencies.removeNode(id);
    graphs.references.removeNode(id);
    graphs.construction.removeNode(id);
    analytics.entities--;
    if (entity.reference) analytics.referenceEntities--;
    if (entity.construction) analytics.constructionEntities--;
  }

  void modify(
    String id,
    SketchHistoryAction action,
    void Function(SketchEntity) update,
  ) => _change(action, id, () {
    final entity = entities[id] ?? (throw StateError('Unknown entity: $id'));
    if (entity.locked) throw StateError('Entity is locked: $id');
    update(entity);
    entity.refreshDerivedParameters();
    entity.version++;
    entity.history.add(action.name);
    analytics.edits++;
  });

  T transaction<T>(String label, T Function() operation) {
    // Nested entity builders inside a higher-level operation must not capture
    // the complete Sketch for every segment. The outer transaction remains the
    // single undo/redo boundary and still restores atomically on failure.
    if (_transactionDepth > 0) return operation();
    _transactionDepth++;
    final before = _capture();
    final historyLength = history.entries.length;
    final redoLength = _redo.length;
    try {
      final result = operation();
      _undo.add(before);
      _redo.clear();
      history.truncate(historyLength);
      history.record(SketchHistoryAction.modify, label);
      return result;
    } catch (_) {
      _restore(before);
      history.truncate(historyLength);
      _redo.removeRange(redoLength, _redo.length);
      rethrow;
    } finally {
      _transactionDepth--;
    }
  }

  bool undo() {
    if (_undo.isEmpty) return false;
    final current = _capture();
    final previous = _undo.removeLast();
    _redo.add(current);
    _restore(previous);
    history.record(SketchHistoryAction.undo, previous.target);
    analytics.undo++;
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    final current = _capture();
    final next = _redo.removeLast();
    _undo.add(current);
    _restore(next);
    history.record(SketchHistoryAction.redo, next.target);
    analytics.redo++;
    return true;
  }

  T _change<T>(
    SketchHistoryAction action,
    String target,
    T Function() operation,
  ) {
    if (_transactionDepth > 0) return operation();
    final before = _capture(target);
    try {
      final result = operation();
      _undo.add(before);
      _redo.clear();
      history.record(action, target);
      return result;
    } catch (_) {
      _restore(before);
      rethrow;
    }
  }

  Future<void> persist() async {
    for (final sketch in sketches.values) {
      await repository.saveSketch(sketch);
      for (final id in sketch.entityIds) {
        await repository.saveEntity(sketch.id, entities[id]!);
      }
    }
    await repository.saveSupport(
      graphs: graphs,
      history: history,
      analytics: analytics,
      activeSketchId: activeSketchId,
      projectId: projectId,
    );
  }

  Future<void> load() async {
    for (final sketch in await repository.loadSketches()) {
      sketches[sketch.id] = sketch;
      graphs.sketch.addNode(sketch.id);
      // Older project versions could persist the entity files before the
      // sketch root's entityIds list was updated.  Load the files as the
      // source of truth and repair the root membership in memory so the
      // editor, health checks and Explorer all see the same geometry.
      final loadedEntities = await repository.loadEntities(sketch.id);
      for (final entity in loadedEntities) {
        entities[entity.id] = entity;
        if (!sketch.entityIds.contains(entity.id)) {
          sketch.entityIds.add(entity.id);
        }
        graphs.entities.addNode(entity.id);
        graphs.dependencies.addNode(entity.id);
      }
    }
    analytics.sketches = sketches.length;
    analytics.entities = entities.length;
    await _restoreActiveSketchIdentity();
  }

  Future<void> _restoreActiveSketchIdentity() async {
    final ordered = sketches.values.toList()
      ..sort((a, b) {
        final timestamp = a.timestamp.compareTo(b.timestamp);
        return timestamp != 0 ? timestamp : a.id.compareTo(b.id);
      });
    if (ordered.isEmpty) {
      activeSketchId = null;
      activeSketchIdentityPersisted = false;
      activeSketchRestoreDiagnostic = null;
      return;
    }
    final metadata = await repository.loadActiveSketchMetadata(
      expectedProjectId: projectId,
    );
    activeSketchIdentityPersisted = metadata.present && metadata.valid;
    final persisted = metadata.id;
    if (metadata.valid && persisted == null) {
      activeSketchId = null;
      activeSketchRestoreDiagnostic =
          'Projeto com identidade persistida sem Sketch ativo.';
      return;
    }
    if (metadata.valid && persisted != null && sketches.containsKey(persisted)) {
      activeSketchId = persisted;
      activeSketchRestoreDiagnostic =
          'Sketch ativo restaurado pela identidade persistida: $persisted.';
      return;
    }
    final fallback = ordered.first;
    activeSketchId = fallback.id;
    activeSketchRestoreDiagnostic = !metadata.present
        ? 'Projeto legado sem Sketch ativo persistido; usando fallback '
              'determinístico (${fallback.id}).'
        : 'Sketch ativo persistido inválido ou indisponível ($persisted); usando fallback '
              'determinístico (${fallback.id}).';
  }

  _Snapshot _capture([String target = 'transaction']) => _Snapshot(
    target,
    jsonDecode(jsonEncode(sketches.map((k, v) => MapEntry(k, v.toJson()))))
        as Map<String, dynamic>,
    jsonDecode(jsonEncode(entities.map((k, v) => MapEntry(k, v.toJson()))))
        as Map<String, dynamic>,
    jsonDecode(jsonEncode(graphs.toJson())) as Map<String, dynamic>,
    activeSketchId,
    [
      analytics.entities,
      analytics.selections,
      analytics.edits,
      analytics.sketches,
      analytics.constructionEntities,
      analytics.referenceEntities,
      analytics.undo,
      analytics.redo,
    ],
  );
  void _restore(_Snapshot s) {
    sketches.clear();
    for (final e in s.sketches.entries) {
      sketches[e.key] = Sketch.fromJson(
        (e.value as Map).cast<String, dynamic>(),
      );
    }
    entities.clear();
    for (final e in s.entities.entries) {
      entities[e.key] = SketchEntity.fromJson(
        (e.value as Map).cast<String, dynamic>(),
      );
    }
    graphs.restore(s.graphs);
    activeSketchId = s.active;
    analytics.entities = s.analytics[0];
    analytics.selections = s.analytics[1];
    analytics.edits = s.analytics[2];
    analytics.sketches = s.analytics[3];
    analytics.constructionEntities = s.analytics[4];
    analytics.referenceEntities = s.analytics[5];
    analytics.undo = s.analytics[6];
    analytics.redo = s.analytics[7];
  }
}

class _Snapshot {
  const _Snapshot(
    this.target,
    this.sketches,
    this.entities,
    this.graphs,
    this.active,
    this.analytics,
  );
  final String target;
  final Map<String, dynamic> sketches;
  final Map<String, dynamic> entities;
  final Map<String, dynamic> graphs;
  final String? active;
  final List<int> analytics;
}
