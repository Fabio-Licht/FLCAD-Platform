import 'dart:ui' show Size;

import '../../../core/adaptive_studio/models/adaptive_studio_models.dart';

/// Stable identity of every desktop panel the layout foundation knows about.
///
/// The ids are deliberately decoupled from widget class names: the Workspace
/// keeps using its own strings ("explorer", "inspector", "assistant") while the
/// Sketch reconstruction and continuity panels (extracted in the G124-UX Sprint
/// 0 commit 1830ec4) live inside the Sketch tool window today and become
/// first-class layout entries here.
enum PanelId { explorer, inspector, assistant, reconstruct, continuity }

/// Where a docked panel sits inside the main window.
///
/// [DockState] (reused from `core/adaptive_studio`) describes the dock *mode*;
/// this enum only adds the side, which the adaptive studio model does not
/// express. No second docking model is introduced.
enum PanelDockSide { left, right, bottom }

/// Role of a panel inside the responsive layout.
///
/// [primary] panels (Explorer, Inspector) are always available and collapse
/// independently. [contextual] panels (Assistant, Reconstruct, Continuity)
/// compete for a single highlighted slot when the window is compact.
enum PanelKind { primary, contextual }

/// Immutable metadata for one panel.
class PanelDescriptor {
  const PanelDescriptor({
    required this.id,
    required this.workspaceId,
    required this.title,
    required this.kind,
    required this.defaultSide,
    required this.defaultWidth,
    required this.defaultSize,
    required this.defaultDockState,
    this.contextualPriority = 0,
    this.visibleByDefault = true,
    this.collapsedByDefault = false,
    this.detachable = true,
    this.detachesToSecondaryByDefault = false,
  });

  final PanelId id;

  /// Id already used by `_DockableSidePanel(panelId: ...)` in the Workspace.
  final String workspaceId;
  final String title;
  final PanelKind kind;

  /// Higher wins when the compact layout must highlight a single contextual
  /// panel and no active context is provided.
  final int contextualPriority;
  final PanelDockSide defaultSide;

  /// Logical width used when docked to a side.
  final double defaultWidth;

  /// Logical size used when floating or (later) detached to its own window.
  final Size defaultSize;
  final DockState defaultDockState;
  final bool visibleByDefault;
  final bool collapsedByDefault;
  final bool detachable;

  /// True for panels the dual-monitor preset moves to the secondary display.
  final bool detachesToSecondaryByDefault;
}

const double panelMinWidth = 160;
const double panelMaxWidth = 720;
const double panelMinHeight = 120;
const double panelMaxHeight = 4000;
const double panelMinDetachedWidth = 220;
const double panelMinDetachedHeight = 160;

/// Single source of truth for panel metadata.
const Map<PanelId, PanelDescriptor> panelCatalog = {
  PanelId.explorer: PanelDescriptor(
    id: PanelId.explorer,
    workspaceId: 'explorer',
    title: 'Explorer',
    kind: PanelKind.primary,
    defaultSide: PanelDockSide.left,
    defaultWidth: 240,
    defaultSize: Size(320, 640),
    defaultDockState: DockState.docked,
  ),
  PanelId.inspector: PanelDescriptor(
    id: PanelId.inspector,
    workspaceId: 'inspector',
    title: 'Property Inspector',
    kind: PanelKind.primary,
    defaultSide: PanelDockSide.right,
    defaultWidth: 280,
    defaultSize: Size(340, 560),
    defaultDockState: DockState.docked,
  ),
  PanelId.assistant: PanelDescriptor(
    id: PanelId.assistant,
    workspaceId: 'assistant',
    title: 'Engineering Assistant',
    kind: PanelKind.contextual,
    contextualPriority: 1,
    defaultSide: PanelDockSide.right,
    defaultWidth: 300,
    defaultSize: Size(360, 520),
    defaultDockState: DockState.docked,
    collapsedByDefault: true,
  ),
  PanelId.reconstruct: PanelDescriptor(
    id: PanelId.reconstruct,
    workspaceId: 'sketch-reconstruct',
    title: 'Reconstruct',
    kind: PanelKind.contextual,
    contextualPriority: 3,
    defaultSide: PanelDockSide.bottom,
    defaultWidth: 320,
    defaultSize: Size(340, 460),
    defaultDockState: DockState.autoHidden,
    visibleByDefault: false,
    detachesToSecondaryByDefault: true,
  ),
  PanelId.continuity: PanelDescriptor(
    id: PanelId.continuity,
    workspaceId: 'sketch-continuity',
    title: 'Continuity C0/G1',
    kind: PanelKind.contextual,
    contextualPriority: 2,
    defaultSide: PanelDockSide.bottom,
    defaultWidth: 340,
    defaultSize: Size(360, 480),
    defaultDockState: DockState.autoHidden,
    visibleByDefault: false,
    detachesToSecondaryByDefault: true,
  ),
};

/// Contextual panels ordered by descending priority (deterministic tie-break).
List<PanelId> contextualPanelsByPriority() {
  final ids = panelCatalog.values
      .where((descriptor) => descriptor.kind == PanelKind.contextual)
      .map((descriptor) => descriptor.id)
      .toList();
  ids.sort((first, second) {
    final byPriority = panelDescriptor(
      second,
    ).contextualPriority.compareTo(panelDescriptor(first).contextualPriority);
    return byPriority != 0 ? byPriority : first.index.compareTo(second.index);
  });
  return ids;
}

PanelDescriptor panelDescriptor(PanelId id) => panelCatalog[id]!;

/// Maps a Workspace `panelId` string back to its stable [PanelId].
PanelId? panelIdFromWorkspaceId(String workspaceId) {
  for (final descriptor in panelCatalog.values) {
    if (descriptor.workspaceId == workspaceId) return descriptor.id;
  }
  return null;
}

/// Parses a persisted panel id, ignoring unknown values.
PanelId? panelIdFromName(String name) {
  for (final id in PanelId.values) {
    if (id.name == name) return id;
  }
  return null;
}
