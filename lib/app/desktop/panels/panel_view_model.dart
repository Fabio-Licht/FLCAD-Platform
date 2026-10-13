import '../../../../core/cad_document/cad_document.dart';
import '../layout/panel_identity.dart';
import 'panel_protocol.dart';

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
  static const String status = 'status';
  static const String empty = 'empty';
  static const String truncated = 'truncated';
  static const String entityCount = 'entityCount';

  static const List<String> all = [
    panelId,
    projectId,
    sessionId,
    stateRevision,
    entities,
    groups,
    selection,
    status,
    empty,
    truncated,
    entityCount,
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
      rows.add({
        'id': entity.id,
        'label': _label(entity),
        'kind': entity.kind.name,
        'visible': entity.data['sceneVisible'] as bool? ?? true,
        if (entity.data['parentSketchId'] case final String parent)
          'parent': parent,
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
    String status = '',
    PanelProtocolLimits limits = const PanelProtocolLimits(),
  }) {
    final rows = explorerRows(
      document,
      maxEntities: limits.maxViewModelEntities,
    );
    final totalEntities = document?.entities.length ?? 0;
    final sortedSelection = selection.toList()..sort();
    return {
      PanelViewModelKeys.panelId: panelId.name,
      PanelViewModelKeys.projectId: projectId,
      PanelViewModelKeys.sessionId: sessionId,
      PanelViewModelKeys.stateRevision: stateRevision,
      PanelViewModelKeys.entities: rows,
      PanelViewModelKeys.groups: groupCounts(rows),
      PanelViewModelKeys.selection: sortedSelection,
      PanelViewModelKeys.status: status,
      PanelViewModelKeys.empty: document == null,
      // Explicit, never silent: the panel knows the projection is partial.
      PanelViewModelKeys.truncated: rows.length < totalEntities,
      PanelViewModelKeys.entityCount: totalEntities,
    };
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

  static String _label(CadDocumentEntity entity) =>
      entity.data['name'] as String? ??
      entity.data['label'] as String? ??
      entity.id;

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
