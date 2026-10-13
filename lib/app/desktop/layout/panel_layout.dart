import 'dart:ui' show Offset, Rect, Size;

import '../../../core/adaptive_studio/models/adaptive_studio_models.dart';
import 'panel_identity.dart';

/// Template the operator chose for the current arrangement.
enum PanelLayoutPreset {
  singleMonitor,
  dualMonitor,
  custom;

  static PanelLayoutPreset parse(Object? value) {
    if (value is String) {
      for (final preset in PanelLayoutPreset.values) {
        if (preset.name == value) return preset;
      }
    }
    return PanelLayoutPreset.custom;
  }
}

/// Position/size of a floating or (later) detached panel, in **physical**
/// screen pixels - the same space [DisplayInfo.bounds] uses. Docked widths are
/// a separate, window-relative logical value ([PanelLayoutEntry.dockWidth]).
class PanelGeometry {
  const PanelGeometry({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  PanelGeometry.fromSize(this.left, this.top, Size size)
    : width = size.width,
      height = size.height;

  final double left;
  final double top;
  final double width;
  final double height;

  Rect get rect => Rect.fromLTWH(left, top, width, height);
  Offset get topLeft => Offset(left, top);
  Size get size => Size(width, height);

  bool get isFinite =>
      left.isFinite && top.isFinite && width.isFinite && height.isFinite;

  bool hasUsableSize({required double scaleFactor}) {
    final minWidth = panelMinDetachedWidth * scaleFactor;
    final minHeight = panelMinDetachedHeight * scaleFactor;
    final maxWidth = panelMaxWidth * 8 * scaleFactor;
    final maxHeight = panelMaxHeight * scaleFactor;
    return width >= minWidth &&
        height >= minHeight &&
        width <= maxWidth &&
        height <= maxHeight;
  }

  PanelGeometry copyWith({
    double? left,
    double? top,
    double? width,
    double? height,
  }) => PanelGeometry(
    left: left ?? this.left,
    top: top ?? this.top,
    width: width ?? this.width,
    height: height ?? this.height,
  );

  PanelGeometry withRect(Rect rect) => PanelGeometry(
    left: rect.left,
    top: rect.top,
    width: rect.width,
    height: rect.height,
  );

  /// Keeps the apparent (logical) size when a panel moves between monitors
  /// with different DPI scaling.
  PanelGeometry rescale(double factor) {
    if (!factor.isFinite || factor <= 0) return this;
    return copyWith(width: width * factor, height: height * factor);
  }

  Map<String, Object?> toJson() => {
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  static PanelGeometry? fromJson(Object? value) {
    if (value is! Map) return null;
    final left = _finiteDouble(value['left']);
    final top = _finiteDouble(value['top']);
    final width = _finiteDouble(value['width']);
    final height = _finiteDouble(value['height']);
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    return PanelGeometry(left: left, top: top, width: width, height: height);
  }

  @override
  bool operator ==(Object other) =>
      other is PanelGeometry &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() =>
      'PanelGeometry(${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}, '
      '${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)})';
}

/// Persisted state of one panel.
///
/// [DockState] is reused from `core/adaptive_studio` (`DockState.undocked` is
/// the modeled "detached to its own window" state; `floating` means floating
/// inside the main window). Nothing here runs a second docking model.
class PanelLayoutEntry {
  const PanelLayoutEntry({
    required this.panelId,
    required this.dockState,
    required this.side,
    required this.order,
    required this.visible,
    required this.collapsed,
    required this.dockWidth,
    this.geometry,
    this.monitorSignature,
    this.monitorDevice,
    this.monitorScale,
  });

  final PanelId panelId;
  final DockState dockState;
  final PanelDockSide side;
  final int order;
  final bool visible;
  final bool collapsed;

  /// Logical width used when docked to a side of the main window.
  final double dockWidth;

  /// Physical geometry used when floating/detached.
  final PanelGeometry? geometry;
  final String? monitorSignature;
  final String? monitorDevice;
  final double? monitorScale;

  PanelDescriptor get descriptor => panelDescriptor(panelId);

  /// True when the panel is modeled as its own window (MM2: model only).
  bool get isDetached => dockState == DockState.undocked;

  /// Floating inside the main window: geometry is window-relative, so monitor
  /// recovery does not apply (the responsive planner handles it).
  bool get isFloatingInWindow => dockState == DockState.floating;

  /// Geometry stored in screen (physical display) space.
  bool get usesScreenGeometry => isDetached;

  /// Occupies a side column (or its collapsed rail) of the main window.
  bool get occupiesSideColumn => !isDetached && !isFloatingInWindow;

  /// Panel takes room inside the viewport area as an overlay.
  bool get isOverlay => isFloatingInWindow;

  PanelLayoutEntry copyWith({
    DockState? dockState,
    PanelDockSide? side,
    int? order,
    bool? visible,
    bool? collapsed,
    double? dockWidth,
    PanelGeometry? geometry,
    String? monitorSignature,
    String? monitorDevice,
    double? monitorScale,
    bool clearMonitor = false,
    bool clearGeometry = false,
  }) => PanelLayoutEntry(
    panelId: panelId,
    dockState: dockState ?? this.dockState,
    side: side ?? this.side,
    order: order ?? this.order,
    visible: visible ?? this.visible,
    collapsed: collapsed ?? this.collapsed,
    dockWidth: dockWidth ?? this.dockWidth,
    geometry: clearGeometry ? null : (geometry ?? this.geometry),
    monitorSignature: clearMonitor
        ? null
        : (monitorSignature ?? this.monitorSignature),
    monitorDevice: clearMonitor ? null : (monitorDevice ?? this.monitorDevice),
    monitorScale: clearMonitor ? null : (monitorScale ?? this.monitorScale),
  );

  Map<String, Object?> toJson() => {
    'id': panelId.name,
    'dockState': dockState.name,
    'side': side.name,
    'order': order,
    'visible': visible,
    'collapsed': collapsed,
    'dockWidth': dockWidth,
    if (geometry != null) 'geometry': geometry!.toJson(),
    if (monitorSignature != null) 'monitor': monitorSignature,
    if (monitorDevice != null) 'monitorDevice': monitorDevice,
    if (monitorScale != null) 'monitorScale': monitorScale,
  };

  static PanelLayoutEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = panelIdFromName(value['id'] as String? ?? '');
    if (id == null) return null;
    final descriptor = panelDescriptor(id);
    final dockState = _dockStateFromName(value['dockState'] as String?);
    final side = _sideFromName(value['side'] as String?);
    return PanelLayoutEntry(
      panelId: id,
      dockState: dockState ?? descriptor.defaultDockState,
      side: side ?? descriptor.defaultSide,
      order: _nonNegativeInt(value['order']),
      visible: value['visible'] as bool? ?? descriptor.visibleByDefault,
      collapsed: value['collapsed'] as bool? ?? descriptor.collapsedByDefault,
      dockWidth: _finiteDouble(value['dockWidth']) ?? descriptor.defaultWidth,
      geometry: PanelGeometry.fromJson(value['geometry']),
      monitorSignature: value['monitor'] as String?,
      monitorDevice: value['monitorDevice'] as String?,
      monitorScale: _finiteDouble(value['monitorScale']),
    );
  }

  static PanelLayoutEntry defaultFor(PanelId id) {
    final descriptor = panelDescriptor(id);
    return PanelLayoutEntry(
      panelId: id,
      dockState: descriptor.defaultDockState,
      side: descriptor.defaultSide,
      order: descriptor.id.index,
      visible: descriptor.visibleByDefault,
      collapsed: descriptor.collapsedByDefault,
      dockWidth: descriptor.defaultWidth,
    );
  }

  PanelLayoutEntry normalized() {
    final width = dockWidth.isFinite
        ? dockWidth.clamp(panelMinWidth, panelMaxWidth).toDouble()
        : descriptor.defaultWidth;
    final usableGeometry = geometry != null && geometry!.isFinite;
    return copyWith(
      dockWidth: width,
      order: order < 0 ? 0 : order,
      collapsed: dockState == DockState.autoHidden ? true : collapsed,
      // Reinstate a clean state when the stored geometry is unusable: dropping
      // the rectangle also drops the monitor binding it belonged to.
      clearGeometry: !usableGeometry,
      clearMonitor: !usableGeometry && geometry != null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PanelLayoutEntry &&
      other.panelId == panelId &&
      other.dockState == dockState &&
      other.side == side &&
      other.order == order &&
      other.visible == visible &&
      other.collapsed == collapsed &&
      other.dockWidth == dockWidth &&
      other.geometry == geometry &&
      other.monitorSignature == monitorSignature &&
      other.monitorDevice == monitorDevice &&
      other.monitorScale == monitorScale;

  @override
  int get hashCode => Object.hash(
    panelId,
    dockState,
    side,
    order,
    visible,
    collapsed,
    dockWidth,
    geometry,
    monitorSignature,
    monitorDevice,
    monitorScale,
  );
}

/// Operator preferences that are not per-panel geometry.
class PanelLayoutPreferences {
  const PanelLayoutPreferences({
    this.focusMode = false,
    this.lastContextualPanel,
    this.pendingDualRestore = false,
  });

  /// Focus Mode: collapse/hide every panel to maximize the geometry viewport.
  final bool focusMode;

  /// Last contextual command panel the operator highlighted.
  final PanelId? lastContextualPanel;

  /// Set when a dual-monitor arrangement had to be brought into a single
  /// screen; the next time a second monitor is available the detached panels
  /// are restored (see [PanelLayoutRecovery]). Cleared when the operator
  /// applies a preset explicitly.
  final bool pendingDualRestore;

  PanelLayoutPreferences copyWith({
    bool? focusMode,
    PanelId? lastContextualPanel,
    bool? pendingDualRestore,
    bool clearLastContextualPanel = false,
  }) => PanelLayoutPreferences(
    focusMode: focusMode ?? this.focusMode,
    pendingDualRestore: pendingDualRestore ?? this.pendingDualRestore,
    lastContextualPanel: clearLastContextualPanel
        ? null
        : (lastContextualPanel ?? this.lastContextualPanel),
  );

  Map<String, Object?> toJson() => {
    'focusMode': focusMode,
    if (pendingDualRestore) 'pendingDualRestore': true,
    if (lastContextualPanel != null)
      'lastContextualPanel': lastContextualPanel!.name,
  };

  static PanelLayoutPreferences fromJson(Object? value) {
    if (value is! Map) return const PanelLayoutPreferences();
    return PanelLayoutPreferences(
      focusMode: value['focusMode'] as bool? ?? false,
      pendingDualRestore: value['pendingDualRestore'] as bool? ?? false,
      lastContextualPanel: panelIdFromName(
        value['lastContextualPanel'] as String? ?? '',
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PanelLayoutPreferences &&
      other.focusMode == focusMode &&
      other.pendingDualRestore == pendingDualRestore &&
      other.lastContextualPanel == lastContextualPanel;

  @override
  int get hashCode =>
      Object.hash(focusMode, pendingDualRestore, lastContextualPanel);
}

/// The per-user visual layout document.
///
/// It never contains CAD state (document, selection, undo/redo) and is never
/// written into a project directory - see [PanelLayoutStore].
class PanelLayout {
  const PanelLayout({
    required this.entries,
    this.version = currentVersion,
    this.preset = PanelLayoutPreset.singleMonitor,
    this.preferences = const PanelLayoutPreferences(),
    this.updatedAt,
  });

  static const int currentVersion = 1;

  final int version;
  final PanelLayoutPreset preset;
  final Map<PanelId, PanelLayoutEntry> entries;
  final PanelLayoutPreferences preferences;
  final DateTime? updatedAt;

  factory PanelLayout.defaults({
    PanelLayoutPreset preset = PanelLayoutPreset.singleMonitor,
  }) => PanelLayout(
    preset: preset,
    entries: {
      for (final id in PanelId.values) id: PanelLayoutEntry.defaultFor(id),
    },
  );

  PanelLayoutEntry entryFor(PanelId id) =>
      entries[id] ?? PanelLayoutEntry.defaultFor(id);

  List<PanelLayoutEntry> entriesInSide(PanelDockSide side) {
    final list = entries.values
        .where((entry) => entry.occupiesSideColumn && entry.side == side)
        .toList();
    list.sort((first, second) {
      final byOrder = first.order.compareTo(second.order);
      return byOrder != 0
          ? byOrder
          : first.panelId.index.compareTo(second.panelId.index);
    });
    return list;
  }

  PanelLayout withEntry(PanelLayoutEntry entry) => PanelLayout(
    version: version,
    preset: preset,
    entries: {...entries, entry.panelId: entry},
    preferences: preferences,
    updatedAt: updatedAt,
  );

  PanelLayout copyWith({
    int? version,
    PanelLayoutPreset? preset,
    Map<PanelId, PanelLayoutEntry>? entries,
    PanelLayoutPreferences? preferences,
    DateTime? updatedAt,
  }) => PanelLayout(
    version: version ?? this.version,
    preset: preset ?? this.preset,
    entries: entries ?? this.entries,
    preferences: preferences ?? this.preferences,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Fills missing panels, clamps widths and renumbers the dock order.
  PanelLayout normalize() {
    final normalized = <PanelId, PanelLayoutEntry>{};
    for (final id in PanelId.values) {
      normalized[id] = entryFor(id).normalized();
    }
    for (final side in PanelDockSide.values) {
      var counter = 0;
      for (final entry in _sortedForSide(normalized, side)) {
        normalized[entry.panelId] = entry.copyWith(order: counter++);
      }
    }
    for (final id in PanelId.values) {
      final entry = normalized[id]!;
      if (!entry.occupiesSideColumn) {
        normalized[id] = entry.copyWith(order: entry.panelId.index);
      }
    }
    return copyWith(entries: normalized);
  }

  static List<PanelLayoutEntry> _sortedForSide(
    Map<PanelId, PanelLayoutEntry> entries,
    PanelDockSide side,
  ) {
    final list = entries.values
        .where((entry) => entry.occupiesSideColumn && entry.side == side)
        .toList();
    list.sort((first, second) {
      final byOrder = first.order.compareTo(second.order);
      return byOrder != 0
          ? byOrder
          : first.panelId.index.compareTo(second.panelId.index);
    });
    return list;
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'preset': preset.name,
    'preferences': preferences.toJson(),
    'panels': [for (final id in PanelId.values) entryFor(id).toJson()],
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
  };

  static PanelLayout fromJson(Map<String, Object?> json) {
    final rawPanels = json['panels'];
    final entries = <PanelId, PanelLayoutEntry>{};
    if (rawPanels is List) {
      for (final raw in rawPanels) {
        final entry = PanelLayoutEntry.fromJson(raw);
        if (entry != null) entries[entry.panelId] = entry;
      }
    }
    return PanelLayout(
      version: _nonNegativeInt(json['version']),
      preset: PanelLayoutPreset.parse(json['preset']),
      entries: entries,
      preferences: PanelLayoutPreferences.fromJson(json['preferences']),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '')?.toUtc(),
    ).normalize();
  }
}

DockState? _dockStateFromName(String? name) {
  if (name == null) return null;
  for (final state in DockState.values) {
    if (state.name == name) return state;
  }
  return null;
}

PanelDockSide? _sideFromName(String? name) {
  if (name == null) return null;
  for (final side in PanelDockSide.values) {
    if (side.name == name) return side;
  }
  return null;
}

double? _finiteDouble(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return value.toDouble();
}

int _nonNegativeInt(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return 0;
  return value.toInt();
}

/// Bridge to the adaptive studio panel model.
///
/// The layout foundation deliberately reuses `DockState` and the adaptive
/// studio panel vocabulary instead of declaring a competing docking model:
/// `AdaptivePanel` keeps the per-project, logical organization (dock mode,
/// visibility, monitor index) while [PanelLayoutEntry] adds the per-user window
/// concerns (geometry, side, order, documentable widths).
extension PanelLayoutEntryAdaptiveStudio on PanelLayoutEntry {
  /// Projects this entry onto an [AdaptivePanel].
  ///
  /// Geometry, side, order and dock width stay in the layout model because the
  /// adaptive studio model does not express them.
  AdaptivePanel toAdaptivePanel({String? title, int monitorIndex = 0}) =>
      AdaptivePanel(
        panelId.name,
        title ?? descriptor.title,
        visible: visible,
        dockState: dockState,
        monitor: monitorIndex,
      );
}

/// Builds a layout entry from an adaptive studio panel, keeping descriptor
/// defaults for everything the adaptive model does not carry.
///
/// Returns `null` when the adaptive panel id is unknown to the catalog.
PanelLayoutEntry? panelLayoutEntryFromAdaptivePanel(AdaptivePanel panel) {
  final id = panelIdFromName(panel.id) ?? panelIdFromWorkspaceId(panel.id);
  if (id == null) return null;
  return PanelLayoutEntry.defaultFor(
    id,
  ).copyWith(dockState: panel.dockState, visible: panel.visible);
}
