import '../../../core/adaptive_studio/models/adaptive_studio_models.dart';
import 'panel_identity.dart';
import 'panel_layout.dart';

class PanelLayoutMigrationReport {
  const PanelLayoutMigrationReport({
    this.sourceVersion,
    this.droppedPanelIds = const [],
    this.notes = const [],
    this.usedDefaults = false,
  });

  final int? sourceVersion;
  final List<String> droppedPanelIds;
  final List<String> notes;
  final bool usedDefaults;

  bool get migrated => sourceVersion != PanelLayout.currentVersion;

  Map<String, Object?> toJson() => {
    'sourceVersion': sourceVersion,
    'currentVersion': PanelLayout.currentVersion,
    'droppedPanelIds': droppedPanelIds,
    'notes': notes,
    'usedDefaults': usedDefaults,
  };
}

class PanelLayoutMigration {
  const PanelLayoutMigration(this.layout, this.report);

  final PanelLayout layout;
  final PanelLayoutMigrationReport report;
}

/// Reads any historical layout payload without ever throwing.
///
/// Supported inputs: current document (version 1), documents without a version
/// field, the legacy flat map `{panelId: dockState}` (version 0) and unknown
/// future versions (recognized fields are kept, the rest is ignored).
class PanelLayoutMigrator {
  const PanelLayoutMigrator();

  static const int legacyFlatMapVersion = 0;

  PanelLayoutMigration migrate(Object? raw) {
    if (raw is! Map) {
      return PanelLayoutMigration(
        PanelLayout.defaults().normalize(),
        const PanelLayoutMigrationReport(
          notes: ['payload-ausente'],
          usedDefaults: true,
        ),
      );
    }

    final rawVersion = raw['version'];
    final version = rawVersion is num && rawVersion.isFinite
        ? rawVersion.toInt()
        : null;
    final notes = <String>[];
    if (version == null) notes.add('versao-ausente');
    if (version != null && version > PanelLayout.currentVersion) {
      notes.add('versao-futura:$version');
    }
    if (version == legacyFlatMapVersion) notes.add('layout-legado');

    final dropped = <String>[];
    final looksLikeLegacy = version == null && _isLegacyFlatMap(raw);
    if (looksLikeLegacy) {
      notes.add('mapa-plano-legado');
    }

    final parsed = looksLikeLegacy
        ? _fromLegacyFlatMap(raw, dropped)
        : _fromDocument(raw, dropped);

    return PanelLayoutMigration(
      parsed
          .copyWith(
            version: PanelLayout.currentVersion,
            preset: PanelLayoutPreset.parse(raw['preset']),
          )
          .normalize(),
      PanelLayoutMigrationReport(
        sourceVersion:
            version ?? (looksLikeLegacy ? legacyFlatMapVersion : null),
        droppedPanelIds: dropped,
        notes: notes,
      ),
    );
  }

  static bool _isLegacyFlatMap(Map<Object?, Object?> raw) {
    if (raw.containsKey('panels') || raw.containsKey('version')) return false;
    if (raw.isEmpty) return false;
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String) return false;
      final known =
          panelIdFromName(key) != null || panelIdFromWorkspaceId(key) != null;
      if (!known) return false;
      if (entry.value is! String) return false;
    }
    return true;
  }

  static PanelLayout _fromLegacyFlatMap(
    Map<Object?, Object?> raw,
    List<String> dropped,
  ) {
    final entries = <PanelId, PanelLayoutEntry>{
      for (final id in PanelId.values) id: PanelLayoutEntry.defaultFor(id),
    };
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final id = panelIdFromName(key) ?? panelIdFromWorkspaceId(key);
      if (id == null) {
        dropped.add(key);
        continue;
      }
      final state = _dockStateFromName(entry.value as String?);
      if (state == null) {
        dropped.add(key);
        continue;
      }
      entries[id] = entries[id]!.copyWith(
        dockState: state,
        collapsed: state == DockState.autoHidden ? true : null,
      );
    }
    return PanelLayout(entries: entries);
  }

  static PanelLayout _fromDocument(
    Map<Object?, Object?> raw,
    List<String> dropped,
  ) {
    final rawPanels = raw['panels'];
    if (rawPanels is List) {
      for (final entry in rawPanels) {
        if (entry is Map) {
          final name = entry['id'];
          if (name is String && panelIdFromName(name) == null) {
            dropped.add(name);
          }
        }
      }
    }
    final json = <String, Object?>{
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    return PanelLayout.fromJson(json);
  }

  static DockState? _dockStateFromName(String? name) {
    if (name == null) return null;
    for (final state in DockState.values) {
      if (state.name == name) return state;
    }
    return null;
  }
}
