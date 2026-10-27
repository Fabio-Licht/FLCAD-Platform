import '../../../../core/cad_document/cad_document.dart';
import '../../operational_entities/operational_entity.dart';
import '../layout/panel_identity.dart';
import 'panel_protocol.dart';
import 'panel_inspector_view_model.dart';

/// Keys of the projection exchanged with a panel window.
///
/// The panel shell never receives CAD objects: only these JSON-encodable
/// values, which is what keeps the secondary process free of the CAD core.
abstract final class PanelViewModelKeys {
  static const String panelId = 'panelId';
  static const String projectId = 'projectId';
  static const String sessionId = 'sessionId';
  static const String stateRevision = 'stateRevision';
  static const String entities = 'entities';
  static const String groups = 'groups';
  static const String selection = 'selection';
  static const String explorerDocumentSelection = 'explorer.documentSelection';
  static const String explorerOperationalSelection =
      'explorer.operationalSelection';
  static const String status = 'status';
  static const String empty = 'empty';
  static const String truncated = 'truncated';
  static const String entityCount = 'entityCount';
  static const String inspectorSelectionState =
      PanelInspectorViewModelKeys.selectionState;
  static const String inspectorDocumentSelectionIds =
      PanelInspectorViewModelKeys.documentSelectionIds;
  static const String inspectorOperationalSelectionIds =
      PanelInspectorViewModelKeys.operationalSelectionIds;
  static const String inspectorDocumentEntity =
      PanelInspectorViewModelKeys.documentEntity;
  static const String inspectorOperationalEntities =
      PanelInspectorViewModelKeys.operationalEntities;
  static const String inspectorPresentation =
      PanelInspectorViewModelKeys.presentation;

  static const List<String> all = [
    panelId,
    projectId,
    sessionId,
    stateRevision,
    entities,
    groups,
    selection,
    explorerDocumentSelection,
    explorerOperationalSelection,
    status,
    empty,
    truncated,
    entityCount,
    inspectorSelectionState,
    inspectorDocumentSelectionIds,
    inspectorOperationalSelectionIds,
    inspectorDocumentEntity,
    inspectorOperationalEntities,
    inspectorPresentation,
  ];
}

class PanelViewModelUpdate {
  const PanelViewModelUpdate(this.viewModel, this.changedKeys);

  final Map<String, Object?> viewModel;
  final List<String> changedKeys;
}

/// Pure projections over the authoritative document.
///
/// Everything here is read-only: no transaction, no mutation, no persistence.
abstract final class PanelViewModel {
  /// Explorer rows for the given document (bounded and deterministic).
  static List<Map<String, Object?>> explorerRows(
    CadDocument? document, {
    int maxEntities = 2000,
  }) {
    if (document == null) return const [];
    final rows = <Map<String, Object?>>[];
    for (final entity in document.entities.values) {
      if (rows.length >= maxEntities) break;
      final parentSketch = entity.data['parentSketchId'];
      final parentSurface = entity.data['parentSurfaceId'];
      rows.add({
        'id': entity.id,
        'label': _label(entity),
        'kind': entity.kind.name,
        'group': _group(entity),
        'iconSemantic': _iconSemantic(entity),
        'available': entity.data['deleted'] != true,
        'visible': entity.data['sceneVisible'] as bool? ?? true,
        if (parentSketch is String)
          'parent': parentSketch,
        if (parentSketch == null && parentSurface is String)
          'parent': parentSurface,
      });
    }
    rows.sort((first, second) {
      final byKind = (first['kind']! as String).compareTo(
        second['kind']! as String,
      );
      return byKind != 0
          ? byKind
          : (first['id']! as String).compareTo(second['id']! as String);
    });
    return List<Map<String, Object?>>.unmodifiable(rows);
  }

  static Map<String, Object?> groupCounts(List<Map<String, Object?>> rows) {
    final counts = <String, int>{};
    for (final row in rows) {
      final kind = row['kind']! as String;
      counts[kind] = (counts[kind] ?? 0) + 1;
      final group = row['group'] as String?;
      if (group != null) counts[group] = (counts[group] ?? 0) + 1;
    }
    final keys = counts.keys.toList()..sort();
    return {for (final key in keys) key: counts[key]};
  }

  /// Builds the whole projection for one panel.
  static Map<String, Object?> build({
    required PanelId panelId,
    required int sessionId,
    required String? projectId,
    required int stateRevision,
    required CadDocument? document,
    required Set<String> selection,
    Set<String> documentSelection = const {},
    List<String> operationalSelection = const [],
    Map<String, OperationalEntity?> operationalEntities = const {},
    String status = '',
    PanelProtocolLimits limits = const PanelProtocolLimits(),
  }) {
    final rows = explorerRows(
      document,
      maxEntities: limits.maxViewModelEntities,
    );
    final totalEntities = document?.entities.length ?? 0;
    final sortedSelection = selection.toList()..sort();
    final result = <String, Object?>{
      PanelViewModelKeys.panelId: panelId.name,
      PanelViewModelKeys.projectId: projectId,
      PanelViewModelKeys.sessionId: sessionId,
      PanelViewModelKeys.stateRevision: stateRevision,
      PanelViewModelKeys.entities: rows,
      PanelViewModelKeys.groups: groupCounts(rows),
      PanelViewModelKeys.selection: sortedSelection,
      PanelViewModelKeys.explorerDocumentSelection:
          documentSelection.toList()..sort(),
      PanelViewModelKeys.explorerOperationalSelection:
          operationalSelection.toList()..sort(),
      PanelViewModelKeys.status: status,
      PanelViewModelKeys.empty: document == null,
      // Explicit, never silent: the panel knows the projection is partial.
      PanelViewModelKeys.truncated: rows.length < totalEntities,
      PanelViewModelKeys.entityCount: totalEntities,
    };
    if (panelId == PanelId.inspector) {
      result.addAll(
        PanelInspectorViewModel.build(
          document: document,
          documentSelection: documentSelection,
          operationalSelection: operationalSelection,
          operationalEntities: operationalEntities,
        ),
      );
    }
    return result;
  }

  /// Keys whose value differs between two projections.
  static List<String> changedKeys(
    Map<String, Object?> previous,
    Map<String, Object?> next,
  ) {
    final changed = <String>[];
    for (final key in PanelViewModelKeys.all) {
      if (!_sameValue(previous[key], next[key])) changed.add(key);
    }
    return changed;
  }

  /// Applies a snapshot to the panel's cached projection.
  ///
  /// A full snapshot replaces everything; an incremental one patches only the
  /// keys it carries, so a dropped message can never leave a half state.
  static PanelViewModelUpdate merge(
    Map<String, Object?> current,
    PanelSnapshot snapshot,
  ) {
    if (snapshot.full) {
      return PanelViewModelUpdate(
        Map<String, Object?>.from(snapshot.viewModel),
        snapshot.changedKeys.isEmpty
            ? PanelViewModelKeys.all
            : snapshot.changedKeys,
      );
    }
    final merged = Map<String, Object?>.from(current);
    for (final entry in snapshot.viewModel.entries) {
      merged[entry.key] = entry.value;
    }
    return PanelViewModelUpdate(merged, snapshot.changedKeys);
  }

  static final RegExp _embeddedUuid = RegExp(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
  );

  static bool _isSketchPresentation(CadDocumentEntity entity) =>
      entity.kind == CadDocumentEntityKind.sketch ||
      entity.data['parentSketchId'] is String ||
      entity.data['sketchEntity'] != null;

  static String _label(CadDocumentEntity entity) {
    final stored =
        entity.data['name'] as String? ?? entity.data['label'] as String?;
    final hasStored = stored != null && stored.isNotEmpty;
    final sketchUuid =
        hasStored &&
        _isSketchPresentation(entity) &&
        _embeddedUuid.hasMatch(stored);
    if (hasStored && !sketchUuid) return stored;
    if (_isSketchPresentation(entity)) return 'Geometria';
    return entity.id;
  }

  static String _group(CadDocumentEntity entity) {
    final workspaceGroup = entity.data['workspaceGroup'];
    if (workspaceGroup is String && workspaceGroup.isNotEmpty) {
      return workspaceGroup;
    }
    if (entity.data['constructionEntity'] is Map) return 'Entidades';
    return switch (entity.kind.name) {
      'import' => 'Meshes',
      'sketch' => 'Sketches',
      'curve' => 'Curves',
      'surface' => 'Surfaces',
      'solid' => 'Solids',
      'section' => 'Reference Curves',
      _ => 'Construction',
    };
  }

  static String _iconSemantic(CadDocumentEntity entity) {
    final semantic = entity.data['cadSemanticKind'];
    if (semantic is String && semantic.isNotEmpty) return semantic;
    final sceneKind = entity.data['sceneKind'];
    if (sceneKind is String && sceneKind.isNotEmpty) return sceneKind;
    return entity.kind.name;
  }

  static bool _sameValue(Object? first, Object? second) {
    if (identical(first, second)) return true;
    if (first is List && second is List) {
      if (first.length != second.length) return false;
      for (var index = 0; index < first.length; index++) {
        if (!_sameValue(first[index], second[index])) return false;
      }
      return true;
    }
    if (first is Map && second is Map) {
      if (first.length != second.length) return false;
      for (final key in first.keys) {
        if (!_sameValue(first[key], second[key])) return false;
      }
      return true;
    }
    return first == second;
  }
}
