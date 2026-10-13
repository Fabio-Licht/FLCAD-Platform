import 'dart:math' as math;
import 'dart:ui' show Size;

import 'panel_identity.dart';
import 'panel_layout.dart';

/// Why the planner deviated from the stored layout.
enum PanelLayoutNote {
  compactModeActive,
  focusModeActive,
  widthClamped,
  contextualHidden,
  primaryCollapsed,
  viewportBelowTarget,
}

/// Widths and thresholds that keep the geometry viewport usable.
///
/// Values are logical pixels relative to the *usable* window area (client area
/// minus app chrome and toolbars), which is why the layout can be decided from
/// the window size instead of the monitor count.
class PanelLayoutPolicy {
  const PanelLayoutPolicy({
    this.viewportMinWidth = 520,
    this.viewportMinWidthCompact = 320,
    this.viewportMinHeight = 320,
    this.compactUsableWidth = 1180,
    this.compactUsableHeight = 620,
    this.compactPrimaryCollapseWidth = 980,
    this.collapsedRailWidth = 32,
    this.dividerWidth = 1,
    this.compactContextualMaxWidth = 360,
  });

  final double viewportMinWidth;
  final double viewportMinWidthCompact;
  final double viewportMinHeight;

  /// The layout becomes compact below these usable sizes.
  final double compactUsableWidth;
  final double compactUsableHeight;

  /// In compact mode the primary panels stay as rails below this width.
  final double compactPrimaryCollapseWidth;

  /// Width of a collapsed side panel, matching `_DockableSidePanel`.
  final double collapsedRailWidth;
  final double dividerWidth;
  final double compactContextualMaxWidth;
}

/// Concrete arrangement computed for one usable window size.
class PanelLayoutResolution {
  const PanelLayoutResolution({
    required this.compact,
    required this.focusMode,
    required this.dockWidths,
    required this.collapsed,
    required this.leftRailWidth,
    required this.rightRailWidth,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.viewportMinWidth,
    this.highlightedContextualPanel,
    this.notes = const [],
  });

  final bool compact;
  final bool focusMode;

  /// Resolved logical width per docked panel.
  final Map<PanelId, double> dockWidths;
  final Map<PanelId, bool> collapsed;
  final double leftRailWidth;
  final double rightRailWidth;
  final double viewportWidth;
  final double viewportHeight;
  final double viewportMinWidth;

  /// At most one contextual panel is highlighted in compact mode.
  final PanelId? highlightedContextualPanel;
  final List<PanelLayoutNote> notes;

  bool get viewportIsProtected => viewportWidth >= viewportMinWidth - 0.001;

  bool get hasNotes => notes.isNotEmpty;
}

/// Pure, UI-free responsive planner.
///
/// It only *computes* an arrangement: this milestone does not touch the
/// Workspace widget tree, so nothing renders differently yet. Explorer and
/// Inspector always collapse independently because the planner never copies a
/// collapsed state from one primary panel to the other.
class PanelLayoutPlanner {
  const PanelLayoutPlanner({this.policy = const PanelLayoutPolicy()});

  final PanelLayoutPolicy policy;

  PanelLayoutResolution resolve({
    required PanelLayout layout,
    required Size usableSize,
    PanelId? requestedContextualPanel,
    bool? focusModeOverride,
  }) {
    final notes = <PanelLayoutNote>{};
    final focusMode = focusModeOverride ?? layout.preferences.focusMode;
    final compact =
        usableSize.width < policy.compactUsableWidth ||
        usableSize.height < policy.compactUsableHeight;
    if (compact) notes.add(PanelLayoutNote.compactModeActive);
    if (focusMode) notes.add(PanelLayoutNote.focusModeActive);

    final staged = <PanelId, PanelLayoutEntry>{};
    final collapsed = <PanelId, bool>{};
    for (final id in PanelId.values) {
      final entry = layout.entryFor(id);
      staged[id] = entry;
      collapsed[id] = entry.collapsed;
    }

    final highlighted = _selectContextualPanel(
      layout: layout,
      compact: compact,
      focusMode: focusMode,
      requested: requestedContextualPanel,
    );

    // Focus Mode: everything collapses to rails so the geometry gets the room.
    if (focusMode) {
      for (final id in PanelId.values) {
        final entry = staged[id]!;
        if (!entry.occupiesSideColumn) continue;
        collapsed[id] = true;
      }
    } else if (compact) {
      final primaryCollapsed =
          usableSize.width < policy.compactPrimaryCollapseWidth;
      for (final id in PanelId.values) {
        final descriptor = panelDescriptor(id);
        final entry = staged[id]!;
        if (!entry.occupiesSideColumn) {
          collapsed[id] = true;
          continue;
        }
        if (descriptor.kind == PanelKind.primary && primaryCollapsed) {
          collapsed[id] = true;
          notes.add(PanelLayoutNote.primaryCollapsed);
        }
        if (descriptor.kind == PanelKind.contextual && id != highlighted) {
          collapsed[id] = true;
        }
      }
      // Exactly one contextual panel stays in evidence when the window is
      // compact; the others are collapsed to rails.
      if (highlighted != null && staged[highlighted]!.occupiesSideColumn) {
        collapsed[highlighted] = false;
      }
    }

    final widths = <PanelId, double>{};
    for (final id in PanelId.values) {
      widths[id] = staged[id]!.dockWidth;
    }

    var leftRail = _railWidth(layout, PanelDockSide.left, collapsed);
    var rightRail = _railWidth(layout, PanelDockSide.right, collapsed);
    var bottomRail = _railWidth(layout, PanelDockSide.bottom, collapsed);

    final visibleDocked = PanelId.values.where((id) {
      final entry = staged[id]!;
      if (!entry.occupiesSideColumn) return false;
      if (!entry.visible) return false;
      return collapsed[id] != true;
    }).toList();

    double usedWidth() =>
        leftRail +
        rightRail +
        _dividerWidth(layout, PanelDockSide.left, collapsed) +
        _dividerWidth(layout, PanelDockSide.right, collapsed) +
        visibleDocked.fold<double>(0, (sum, id) => sum + (widths[id] ?? 0));

    final target = compact
        ? policy.viewportMinWidthCompact
        : policy.viewportMinWidth;

    // 1) Shrink panels proportionally until the viewport target is honoured.
    if (usedWidth() + target > usableSize.width && visibleDocked.isNotEmpty) {
      final totalTarget =
          usableSize.width -
          leftRail -
          rightRail -
          _dividerWidth(layout, PanelDockSide.left, collapsed) -
          _dividerWidth(layout, PanelDockSide.right, collapsed) -
          target;
      final current = visibleDocked.fold<double>(
        0,
        (sum, id) => sum + (widths[id] ?? 0),
      );
      if (current > 0) {
        final factor = math.max(0.0, totalTarget / current);
        for (final id in visibleDocked) {
          final scaled = (widths[id]! * factor).clamp(
            panelMinWidth,
            panelMaxWidth,
          );
          if (scaled < widths[id]! - 0.001) {
            notes.add(PanelLayoutNote.widthClamped);
          }
          widths[id] = scaled;
        }
      }
    }

    // 2) Still too wide: hide contextual panels, lowest priority first. The
    //    primary panels (Explorer/Inspector) keep their independent state.
    if (usedWidth() + target > usableSize.width) {
      final removable = contextualPanelsByPriority().reversed.where(
        (id) => visibleDocked.contains(id) && id != highlighted,
      );
      for (final id in removable.toList()) {
        widths[id] = 0;
        collapsed[id] = true;
        notes.add(PanelLayoutNote.contextualHidden);
        if (usedWidth() + target <= usableSize.width) break;
      }
    }

    leftRail = _railWidth(layout, PanelDockSide.left, collapsed);
    rightRail = _railWidth(layout, PanelDockSide.right, collapsed);
    bottomRail = _railWidth(layout, PanelDockSide.bottom, collapsed);

    double viewportWithWidths(Map<PanelId, bool> state) {
      final rails =
          _railWidth(layout, PanelDockSide.left, state) +
          _railWidth(layout, PanelDockSide.right, state);
      final dividers =
          _dividerWidth(layout, PanelDockSide.left, state) +
          _dividerWidth(layout, PanelDockSide.right, state);
      final occupied = PanelId.values
          .where(
            (id) =>
                staged[id]!.occupiesSideColumn &&
                state[id] != true &&
                (widths[id] ?? 0) > 0,
          )
          .fold<double>(0, (sum, id) => sum + (widths[id] ?? 0));
      return usableSize.width - rails - dividers - occupied;
    }

    // 3) Last resort: on a very small window even the minimum widths would
    //    crush the geometry, so the remaining expanded panels collapse to rails
    //    (lowest-priority contextual first, then the primary panels, and only
    //    then the highlighted contextual panel). A one-pixel tolerance keeps
    //    rounding noise from collapsing a panel unnecessarily.
    const tolerance = 1.0;
    if (viewportWithWidths(collapsed) < target - tolerance) {
      final order = <PanelId>[
        ...contextualPanelsByPriority().reversed.where(
          (id) => id != highlighted,
        ),
        ...PanelId.values.where(
          (id) => panelDescriptor(id).kind == PanelKind.primary,
        ),
        if (highlighted != null &&
            staged[highlighted]!.occupiesSideColumn &&
            panelDescriptor(highlighted).kind == PanelKind.contextual)
          highlighted,
      ];
      for (final id in order) {
        if (collapsed[id] == true || !staged[id]!.occupiesSideColumn) continue;
        final candidate = {...collapsed, id: true};
        if (viewportWithWidths(candidate) <= viewportWithWidths(collapsed)) {
          continue;
        }
        collapsed[id] = true;
        notes.add(
          panelDescriptor(id).kind == PanelKind.contextual
              ? PanelLayoutNote.contextualHidden
              : PanelLayoutNote.primaryCollapsed,
        );
        if (viewportWithWidths(collapsed) >= target - tolerance) break;
      }
    }

    leftRail = _railWidth(layout, PanelDockSide.left, collapsed);
    rightRail = _railWidth(layout, PanelDockSide.right, collapsed);
    bottomRail = _railWidth(layout, PanelDockSide.bottom, collapsed);

    final chrome =
        leftRail +
        rightRail +
        _dividerWidth(layout, PanelDockSide.left, collapsed) +
        _dividerWidth(layout, PanelDockSide.right, collapsed);
    // Only panels that really occupy a side column consume width: detached and
    // floating panels live outside (or over) the main window.
    final sideColumns = PanelId.values
        .where(
          (id) =>
              staged[id]!.occupiesSideColumn &&
              collapsed[id] != true &&
              (widths[id] ?? 0) > 0,
        )
        .toList();
    final dockedWidth = sideColumns.fold<double>(
      0,
      (sum, id) => sum + (widths[id] ?? 0),
    );
    var viewportWidth = usableSize.width - chrome - dockedWidth;
    if (viewportWidth < policy.viewportMinWidthCompact) {
      notes.add(PanelLayoutNote.viewportBelowTarget);
    }
    if (viewportWidth < 0) viewportWidth = 0;

    final bottomHeight = bottomRail;
    final viewportHeight = math.max(0.0, usableSize.height - bottomHeight);

    return PanelLayoutResolution(
      compact: compact,
      focusMode: focusMode,
      dockWidths: {for (final id in sideColumns) id: widths[id]!},
      collapsed: collapsed,
      leftRailWidth: leftRail,
      rightRailWidth: rightRail,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      viewportMinWidth: target,
      highlightedContextualPanel: highlighted,
      notes: notes.toList(growable: false),
    );
  }

  double _railWidth(
    PanelLayout layout,
    PanelDockSide side,
    Map<PanelId, bool> collapsed,
  ) {
    var width = 0.0;
    for (final entry in layout.entriesInSide(side)) {
      if (collapsed[entry.panelId] == true) {
        width += policy.collapsedRailWidth;
      }
    }
    return width;
  }

  double _dividerWidth(
    PanelLayout layout,
    PanelDockSide side,
    Map<PanelId, bool> collapsed,
  ) {
    final hasContent = layout
        .entriesInSide(side)
        .any((entry) => collapsed[entry.panelId] != true && entry.visible);
    final hasRail = layout
        .entriesInSide(side)
        .any((entry) => collapsed[entry.panelId] == true);
    return (hasContent || hasRail) ? policy.dividerWidth : 0;
  }

  PanelId? _selectContextualPanel({
    required PanelLayout layout,
    required bool compact,
    required bool focusMode,
    PanelId? requested,
  }) {
    final contextual = contextualPanelsByPriority();
    bool isEligible(PanelId id) =>
        panelDescriptor(id).kind == PanelKind.contextual;

    if (requested != null && isEligible(requested)) return requested;
    final last = layout.preferences.lastContextualPanel;
    if (last != null && isEligible(last)) return last;
    if (!compact && !focusMode) return null;
    for (final id in contextual) {
      if (layout.entryFor(id).visible) return id;
    }
    return contextual.isEmpty ? null : contextual.first;
  }
}
