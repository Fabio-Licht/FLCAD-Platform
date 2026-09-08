import 'dart:convert';

import '../cad_document/cad_document.dart';
import 'feature_lifecycle.dart';
import 'feature_dependencies.dart';

/// Converts every authored entity to the same durable lifecycle contract.
abstract final class FeatureLifecycleProjector {
  static CadDocument normalize(
    CadDocument document, {
    required String command,
    CadDocument? previousDocument,
    Set<String> touchedIds = const {},
    Map<String, FeatureLifecycleState> stateOverrides = const {},
    Map<String, String> actionOverrides = const {},
  }) {
    final firstPass = <String, CadDocumentEntity>{};
    var order = 0;
    for (final entity in document.entities.values) {
      if (!FeatureLifecycleContract.appliesTo(entity)) {
        firstPass[entity.id] = entity;
        continue;
      }
      firstPass[entity.id] = _normalizeEntity(
        entity,
        previousEntity: previousDocument?.entities[entity.id],
        command: command,
        touched: touchedIds.contains(entity.id),
        stateOverride: stateOverrides[entity.id],
        actionOverride: actionOverrides[entity.id],
        fallbackOrder: order++,
      );
    }

    final dependents = <String, Set<String>>{};
    for (final entity in firstPass.values.where(
      FeatureLifecycleContract.appliesTo,
    )) {
      final lifecycle = FeatureLifecycleContract.require(entity);
      for (final dependency in lifecycle.dependencyIds) {
        dependents.putIfAbsent(dependency, () => <String>{}).add(entity.id);
      }
    }
    final finalEntities = <String, CadDocumentEntity>{};
    for (final entity in firstPass.values) {
      if (!FeatureLifecycleContract.appliesTo(entity)) {
        finalEntities[entity.id] = entity;
        continue;
      }
      final lifecycle = FeatureLifecycleContract.require(entity);
      final nextDependents =
          (dependents[entity.id] ?? const <String>{}).toList()..sort();
      final data = Map<String, dynamic>.from(entity.data);
      data[FeatureLifecycleContract.dataKey] = _copy(
        lifecycle,
        dependentIds: nextDependents,
      ).toJson();
      finalEntities[entity.id] = CadDocumentEntity(
        id: entity.id,
        kind: entity.kind,
        data: data,
        shape: entity.shape,
        mesh: entity.mesh,
      );
    }
    return CadDocument(
      projectId: document.projectId,
      entities: Map.unmodifiable(finalEntities),
      revisions: document.revisions,
      parameters: document.parameters,
      officialExportShapeId: document.officialExportShapeId,
    );
  }

  static CadDocumentEntity _normalizeEntity(
    CadDocumentEntity entity, {
    required CadDocumentEntity? previousEntity,
    required String command,
    required bool touched,
    required FeatureLifecycleState? stateOverride,
    required String? actionOverride,
    required int fallbackOrder,
  }) {
    final raw =
        entity.data[FeatureLifecycleContract.dataKey] ??
        previousEntity?.data[FeatureLifecycleContract.dataKey];
    final previous = raw is Map
        ? FeatureLifecycleRecord.fromJson(Map<String, dynamic>.from(raw))
        : null;
    if (previous != null && previous.featureId != entity.id) {
      throw StateError('Feature ${entity.id} cannot assume another identity.');
    }
    final state =
        stateOverride ??
        (touched && previous?.state == FeatureLifecycleState.created
            ? FeatureLifecycleState.editing
            : previous?.state ?? FeatureLifecycleState.created);
    final action =
        actionOverride ??
        (stateOverride != null
            ? state.name
            : previous == null
            ? 'created'
            : touched
            ? 'updated'
            : null);
    final history = <FeatureLifecycleEvent>[...?previous?.history];
    if (action != null) {
      history.add(
        FeatureLifecycleEvent(
          sequence: history.length + 1,
          action: action,
          timestamp: DateTime.now().toUtc(),
          command: command,
        ),
      );
    }
    final record = FeatureLifecycleRecord(
      featureId: entity.id,
      workspace:
          entity.data['authoringWorkspace'] as String? ??
          _workspace(entity.kind),
      state: state,
      createdBy: previous?.createdBy ?? command,
      parameters: _parameters(entity.data, previous),
      references: FeatureDependencies.references(entity.data),
      childIds: _children(entity.data, previous),
      dependencyIds: FeatureDependencies.resolve(entity.data),
      dependentIds: previous?.dependentIds ?? const [],
      treeParentId:
          entity.data['parentSketchId'] as String? ??
          entity.data['collectionId'] as String?,
      treeOrder: previous?.treeOrder ?? fallbackOrder,
      history: List.unmodifiable(history),
      revision: previous == null ? 1 : previous.revision + (touched ? 1 : 0),
    );
    final data = Map<String, dynamic>.from(entity.data)
      ..['authoringRoot'] = true
      ..['authoringWorkspace'] = record.workspace
      ..[FeatureLifecycleContract.dataKey] = record.toJson();
    return CadDocumentEntity(
      id: entity.id,
      kind: entity.kind,
      data: data,
      shape: entity.shape,
      mesh: entity.mesh,
    );
  }

  static FeatureLifecycleRecord _copy(
    FeatureLifecycleRecord value, {
    required List<String> dependentIds,
  }) => FeatureLifecycleRecord(
    featureId: value.featureId,
    workspace: value.workspace,
    state: value.state,
    createdBy: value.createdBy,
    parameters: value.parameters,
    references: value.references,
    childIds: value.childIds,
    dependencyIds: value.dependencyIds,
    dependentIds: dependentIds,
    treeParentId: value.treeParentId,
    treeOrder: value.treeOrder,
    history: value.history,
    revision: value.revision,
    solverContract: value.solverContract,
    activationGesture: value.activationGesture,
  );

  static Map<String, dynamic>? _map(Object? value) => value is Map
      ? Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map)
      : null;

  static Map<String, dynamic> _parameters(
    Map<String, dynamic> data,
    FeatureLifecycleRecord? previous,
  ) {
    final direct = _map(data['parameters']);
    if (direct != null) return direct;
    for (final key in const ['sketchEntity', 'surface', 'feature', 'solid']) {
      final definition = data[key];
      if (definition is Map) {
        final nested = _map(definition['parameters']);
        if (nested != null) return nested;
      }
    }
    final sketch = data['sketch'];
    if (sketch is Map) {
      return {
        if (sketch['coordinates'] != null) 'coordinates': sketch['coordinates'],
        if (sketch['metadata'] != null) 'metadata': sketch['metadata'],
      };
    }
    return previous?.parameters ?? const {};
  }

  static List<String> _strings(Object? value) => value is List
      ? value.whereType<String>().toSet().toList(growable: false)
      : const [];

  static List<String> _children(
    Map<String, dynamic> data,
    FeatureLifecycleRecord? previous,
  ) {
    final result = <String>{
      ..._strings(data['children']),
      ..._strings(data['geometricEntities']),
      ..._strings(data['constraints']),
      ..._strings(data['dimensions']),
    };
    return result.isEmpty ? previous?.childIds ?? const [] : result.toList();
  }

  static String _workspace(CadDocumentEntityKind kind) => switch (kind) {
    CadDocumentEntityKind.sketch => 'Sketch',
    CadDocumentEntityKind.surface => 'Surfaces',
    CadDocumentEntityKind.shell || CadDocumentEntityKind.solid => 'Solids',
    _ => 'Modeling',
  };
}
