import 'dart:ui' show Offset, Rect;

import '../../../core/adaptive_studio/models/adaptive_studio_models.dart';
import 'display_service.dart';
import 'panel_identity.dart';
import 'panel_layout.dart';

/// Ready-made arrangements offered to the operator.
///
/// * Single Monitor: everything lives inside the main window (today's layout).
/// * Dual Monitor: the contextual Sketch panels are modeled as detached on the
///   secondary monitor while Explorer/Inspector/Assistant stay docked.
/// * Custom: whatever the operator arranged, kept as-is and flagged as custom.
class PanelLayoutPresets {
  const PanelLayoutPresets._();

  static const double _cascadeStep = 32;

  static PanelLayout singleMonitor({
    PanelLayoutPreferences preferences = const PanelLayoutPreferences(),
  }) => PanelLayout(
    preset: PanelLayoutPreset.singleMonitor,
    preferences: preferences.copyWith(focusMode: false),
    entries: {
      for (final id in PanelId.values) id: PanelLayoutEntry.defaultFor(id),
    },
  ).normalize();

  static PanelLayout dualMonitor({
    required DisplayService displays,
    PanelLayoutPreferences preferences = const PanelLayoutPreferences(),
  }) {
    final secondary = _secondaryDisplay(displays);
    if (secondary == null) {
      return singleMonitor(preferences: preferences);
    }
    final entries = <PanelId, PanelLayoutEntry>{
      for (final id in PanelId.values) id: PanelLayoutEntry.defaultFor(id),
    };
    var cascade = 0;
    for (final id in contextualPanelsByPriority()) {
      final descriptor = panelDescriptor(id);
      if (!descriptor.detachable || !descriptor.detachesToSecondaryByDefault) {
        continue;
      }
      entries[id] = entries[id]!.copyWith(
        dockState: DockState.undocked,
        visible: true,
        collapsed: false,
        side: descriptor.defaultSide,
        geometry: PanelGeometry.fromSize(
          secondary.workArea.left + _cascadeStep * (cascade + 1),
          secondary.workArea.top + _cascadeStep * (cascade + 1),
          descriptor.defaultSize,
        ),
        monitorSignature: secondary.configurationSignature,
        monitorDevice: secondary.deviceName,
        monitorScale: secondary.scaleFactor,
      );
      cascade++;
    }
    return PanelLayout(
      preset: PanelLayoutPreset.dualMonitor,
      preferences: preferences.copyWith(focusMode: false),
      entries: entries,
    ).normalize();
  }

  /// Preset chosen from the desktop the operator actually has.
  static PanelLayout forDisplays({
    required DisplayService displays,
    PanelLayoutPreferences preferences = const PanelLayoutPreferences(),
  }) => displays.displays.length >= 2
      ? dualMonitor(displays: displays, preferences: preferences)
      : singleMonitor(preferences: preferences);

  /// Marks the current arrangement as operator-defined.
  static PanelLayout custom(PanelLayout layout) =>
      layout.copyWith(preset: PanelLayoutPreset.custom).normalize();

  /// Keeps the operator's panel preferences (collapse, width, order, focus) and
  /// only replaces geometry/monitor bindings with the given preset.
  static PanelLayout applyPreset({
    required PanelLayout current,
    required PanelLayout preset,
  }) {
    final entries = <PanelId, PanelLayoutEntry>{};
    for (final id in PanelId.values) {
      final existing = current.entryFor(id);
      final incoming = preset.entryFor(id);
      var entry = incoming.copyWith(
        visible: existing.isDetached ? incoming.visible : existing.visible,
        collapsed: existing.isDetached
            ? incoming.collapsed
            : existing.collapsed,
        dockWidth: existing.dockWidth,
        order: existing.order,
      );
      // Keep the operator's last known screen geometry so switching
      // Dual -> Single -> Dual restores their exact positions instead of
      // re-cascading the preset defaults.
      final geometry = existing.geometry;
      if (geometry != null && geometry.isFinite) {
        entry = entry.copyWith(
          geometry: geometry,
          monitorSignature: existing.monitorSignature,
          monitorDevice: existing.monitorDevice,
          monitorScale: existing.monitorScale,
        );
      }
      entries[id] = entry;
    }
    return current
        .copyWith(
          entries: entries,
          preset: preset.preset,
          preferences: preset.preferences.copyWith(
            lastContextualPanel: current.preferences.lastContextualPanel,
            // The operator chose a preset explicitly: no pending restoration.
            pendingDualRestore: false,
          ),
        )
        .normalize();
  }

  static DisplayInfo? _secondaryDisplay(DisplayService displays) {
    for (final display in displays.displays) {
      if (!display.isPrimary) return display;
    }
    return null;
  }

  /// Convenience: geometry of the first detached panel, useful for tests and
  /// for the (future) panel host gateway.
  static Rect? detachedGeometry(PanelLayout layout, PanelId id) {
    final entry = layout.entryFor(id);
    if (!entry.isDetached) return null;
    return entry.geometry?.rect;
  }

  static Offset? detachedOrigin(PanelLayout layout, PanelId id) {
    final rect = detachedGeometry(layout, id);
    return rect == null ? null : Offset(rect.left, rect.top);
  }
}
