import 'dart:convert';

import '../../../core/adaptive_studio/models/adaptive_studio_models.dart';
import '../layout/display_service.dart';
import '../layout/panel_identity.dart';
import '../layout/panel_layout.dart';
import '../layout/panel_layout_presets.dart';
import '../layout/panel_layout_recovery.dart';
import '../layout/panel_layout_store.dart';
import 'panel_window_backend.dart';

/// One detached panel window owned by the main process.
class PanelWindowAttachment {
  const PanelWindowAttachment({
    required this.panelId,
    required this.windowId,
    required this.geometry,
  });

  final PanelId panelId;
  final String windowId;

  /// Physical screen geometry (MM2 contract).
  final PanelGeometry geometry;
}

/// Main-process owner of the detached panel windows.
///
/// It never touches CAD state: it creates/closes windows, keeps the per-user
/// MM2 layout persisted and lets the bridge serve the projection over the
/// versioned channels.
class PanelWindowHost {
  PanelWindowHost({
    required this.backend,
    PanelLayoutStoreBase? layoutStore,
    DisplayService? displays,
    double Function()? devicePixelRatio,
    PanelLayoutRecovery recovery = const PanelLayoutRecovery(),
  }) : _layoutStore = layoutStore,
       displays = displays ?? UnavailableDisplayService(),
       _devicePixelRatio = devicePixelRatio ?? (() => 1),
       _recovery = recovery;

  final PanelWindowBackend backend;
  final PanelLayoutStoreBase? _layoutStore;
  final DisplayService displays;
  final double Function() _devicePixelRatio;
  final PanelLayoutRecovery _recovery;

  final Map<PanelId, PanelWindowAttachment> attachments = {};
  int detachCount = 0;
  int dockCount = 0;
  int reconciledWindows = 0;
  int geometryAppliedCount = 0;
  int geometryFailures = 0;
  int dockFailures = 0;
  int adoptedWindows = 0;
  int preservedPreferenceDocks = 0;

  bool get hasAttachments => attachments.isNotEmpty;
  PanelWindowAttachment? attachmentFor(PanelId panelId) => attachments[panelId];

  /// Returns the attachment that owns [windowId], if any.
  ///
  /// Window ids are process-wide. Keeping this lookup in the host prevents a
  /// restored window from being adopted by two panel identities at once.
  PanelWindowAttachment? attachmentForWindow(String windowId) {
    for (final attachment in attachments.values) {
      if (attachment.windowId == windowId) return attachment;
    }
    return null;
  }

  /// MM2 physical geometry -> window_manager logical units.
  RectData toLogical(PanelGeometry geometry) {
    final ratio = _devicePixelRatio() <= 0 ? 1.0 : _devicePixelRatio();
    return RectData(
      left: geometry.left / ratio,
      top: geometry.top / ratio,
      width: geometry.width / ratio,
      height: geometry.height / ratio,
    );
  }

  /// window_manager logical units -> MM2 physical geometry.
  PanelGeometry toPhysical(RectData logical) {
    final ratio = _devicePixelRatio() <= 0 ? 1.0 : _devicePixelRatio();
    return PanelGeometry(
      left: logical.left * ratio,
      top: logical.top * ratio,
      width: logical.width * ratio,
      height: logical.height * ratio,
    );
  }

  /// Persisted layout, always recovered against the current work areas.
  Future<PanelLayout> prepareLayout() async {
    final store = _layoutStore;
    if (store == null) return PanelLayoutPresets.singleMonitor().normalize();
    final loaded = await store.load();
    return _recovery
        .recover(layout: loaded.layout, displays: displays)
        .layout
        .normalize();
  }

  /// Creates (or focuses) the real panel window and persists the layout.
  Future<PanelWindowAttachment?> detach(
    PanelId panelId, {
    required PanelGeometry requestedGeometry,
  }) async {
    final existing = attachments[panelId];
    if (existing != null) {
      if ((await backend.listWindowIds()).contains(existing.windowId)) {
        await backend.focusWindow(existing.windowId);
        return existing;
      }
      // The window is gone but the host never saw it close (for instance a
      // teardown the operator triggered from outside). Refusing to open a new
      // one would leave "Detach" doing nothing until the next reconcile tick.
      attachments.remove(panelId);
    }
    final geometry = _recoverGeometry(panelId, requestedGeometry);
    final descriptor = panelDescriptor(panelId);
    // Persist the *intent* before the attachment exists: the reconcile timer
    // reads the stored layout, so a tick landing between "attachment added" and
    // "layout persisted as detached" would dock the brand new window again
    // (observed: the panel appeared and vanished seconds later).
    // Persist the *intent* before the attachment exists: the reconcile timer
    // reads the stored layout, so a tick landing between "attachment added" and
    // "layout persisted as detached" would dock the brand new window again
    // (observed: the panel appeared and vanished seconds later).
    await _persist(panelId, geometry: geometry, detached: true);
    final windowId = await backend.createWindow(
      arguments: jsonEncode({'panelId': panelId.name, 'protocolVersion': 1}),
      title: descriptor.title,
      logicalBounds: toLogical(geometry),
      // The plugin shows the window itself (SW_SHOW): keeping it hidden would
      // leave an invisible orphan window, because the secondary engine has no
      // window plugin able to show it from Dart.
      hiddenAtLaunch: false,
    );
    if (windowId == null) {
      // Roll the stored intent back: without a window nothing is detached.
      await _persist(panelId, geometry: geometry, detached: false);
      return null;
    }
    final attachment = PanelWindowAttachment(
      panelId: panelId,
      windowId: windowId,
      geometry: geometry,
    );
    attachments[panelId] = attachment;
    detachCount++;
    await _configureWindow(panelId, windowId, geometry);
    return attachment;
  }

  /// Applies title and geometry to the freshly created window.
  ///
  /// The panel registers its channel handler while it starts, so the send is
  /// retried a bounded number of times instead of failing silently; a window
  /// that never answers keeps the platform default geometry and stays visible.
  Future<bool> _configureWindow(
    PanelId panelId,
    String windowId,
    PanelGeometry geometry,
  ) async {
    final descriptor = panelDescriptor(panelId);
    final logical = toLogical(geometry);
    final payload = <String, Object?>{
      'title': descriptor.title,
      'bounds': {
        'left': logical.left,
        'top': logical.top,
        'width': logical.width,
        'height': logical.height,
      },
    };
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await backend.sendWindowControl(
        windowId,
        'panel_configure',
        payload,
      )) {
        geometryAppliedCount++;
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    geometryFailures++;
    return false;
  }

  /// Closes the window and returns the panel to the in-window layout.
  ///
  /// Returns false when the window did not acknowledge the close: the caller
  /// can then report it instead of pretending the panel returned safely (the
  /// operator can still close it with the X, which destroys the engine).
  Future<bool> dock(
    PanelId panelId, {
    bool closeWindow = true,
    bool persist = true,
  }) async {
    final attachment = attachments.remove(panelId);
    if (attachment == null) return true;
    var closed = !closeWindow;
    if (closeWindow) {
      await backend.closeWindow(attachment.windowId);
      for (var attempt = 0; attempt < 6 && !closed; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        closed = !(await backend.listWindowIds()).contains(attachment.windowId);
      }
    }
    dockCount++;
    if (persist) {
      await _persist(panelId, geometry: attachment.geometry, detached: false);
    } else {
      // Session teardown (the shell closing, or the Workspace being remounted):
      // the window goes away but the operator's detached preference stays, so
      // the next session can restore the panel.
      preservedPreferenceDocks++;
    }
    if (!closed) {
      dockFailures++;
      // The window is still alive: keep tracking it so a later reconcile can
      // still dock it instead of leaving an unmanaged window behind.
      attachments[panelId] = attachment;
    }
    return closed;
  }

  Future<void> focus(PanelId panelId) async {
    final attachment = attachments[panelId];
    if (attachment == null) return;
    await backend.focusWindow(attachment.windowId);
  }

  /// Detects windows the operator closed with the X and restores the layout.
  Future<List<PanelId>> reconcileWindows() async {
    if (attachments.isEmpty) return const [];
    final live = (await backend.listWindowIds()).toSet();
    final closed = <PanelId>[];
    for (final entry in attachments.entries.toList()) {
      if (live.contains(entry.value.windowId)) continue;
      closed.add(entry.key);
      reconciledWindows++;
      await dock(entry.key, closeWindow: false);
    }
    return closed;
  }

  /// Reacts to display changes: a panel whose monitor disappeared (or whose
  /// layout recovery decided it belongs to the main window again) is docked
  /// back instead of being left on a screen that no longer exists.
  Future<List<PanelId>> reconcileDisplays() async {
    if (attachments.isEmpty || displays.displays.isEmpty) return const [];
    final layout = await prepareLayout();
    final docked = <PanelId>[];
    for (final panelId in attachments.keys.toList()) {
      if (layout.entryFor(panelId).isDetached) continue;
      docked.add(panelId);
      await dock(panelId);
    }
    return docked;
  }

  /// Restores an attachment persisted in an earlier session.
  ///
  /// [windowId] adopts a window that is already open - a remount must never
  /// materialise a second one - instead of creating a new window. Returns null
  /// when the stored preference no longer wants the panel detached (an explicit
  /// Dock, or the single-screen recovery that brings it back into the shell).
  Future<PanelWindowAttachment?> restorePersisted(
    PanelId panelId, {
    String? windowId,
  }) async {
    final layout = await prepareLayout();
    final entry = layout.entryFor(panelId);
    final geometry = entry.geometry;
    if (!entry.isDetached || geometry == null) return null;
    if (windowId != null) {
      final existing = attachments[panelId];
      if (existing?.windowId == windowId) {
        await focus(panelId);
        return existing;
      }
      final owner = attachmentForWindow(windowId);
      if (owner != null && owner.panelId != panelId) {
        // A native window can belong to only one panel identity. Refuse the
        // adoption instead of silently stealing another panel's channel.
        return null;
      }
      final attachment = PanelWindowAttachment(
        panelId: panelId,
        windowId: windowId,
        geometry: geometry,
      );
      attachments[panelId] = attachment;
      adoptedWindows++;
      await _configureWindow(panelId, windowId, geometry);
      return attachment;
    }
    final attachment = await detach(panelId, requestedGeometry: geometry);
    if (attachment == null) {
      // A restore that could not materialise the window must not erase the
      // operator's preference (detach() rolls the stored intent back): keep the
      // intent so a later session can try again.
      await _persist(panelId, geometry: geometry, detached: true);
    }
    return attachment;
  }

  /// Read-only peek used *before* the panel infrastructure is built at startup.
  ///
  /// The stored layout is recovered against the current displays, so a
  /// preference that cannot materialise (single screen, invalid geometry, a
  /// layout written by a newer format) reports false and nothing is created.
  static Future<bool> hasDetachedPreference(
    PanelLayoutStoreBase store, {
    required PanelId panelId,
    required DisplayService displays,
    PanelLayoutRecovery recovery = const PanelLayoutRecovery(),
  }) async {
    final loaded = await store.load();
    if (loaded.readOnly) return false;
    final layout = recovery
        .recover(layout: loaded.layout, displays: displays)
        .layout;
    final entry = layout.entryFor(panelId);
    return entry.isDetached && entry.geometry != null;
  }

  PanelGeometry _recoverGeometry(PanelId panelId, PanelGeometry requested) {
    final descriptor = panelDescriptor(panelId);
    // Bind the requested rectangle to the monitor that currently shows it, so
    // recovery keeps the panel on that screen instead of pulling it to the
    // primary by default.
    final host = displays.displays.isEmpty || !requested.isFinite
        ? null
        : displays.bestForRect(requested.rect, minVisibleFraction: 0.01);
    final seed = PanelLayoutPresets.singleMonitor().withEntry(
      PanelLayoutPresets.singleMonitor()
          .entryFor(panelId)
          .copyWith(
            dockState: DockState.undocked,
            visible: true,
            collapsed: false,
            geometry: requested.isFinite ? requested : null,
            monitorSignature: host?.configurationSignature,
            monitorDevice: host?.deviceName,
            monitorScale: host?.scaleFactor,
            clearMonitor: host == null,
          ),
    );
    final recovered = _recovery
        .recover(layout: seed, displays: displays)
        .layout;
    return recovered.entryFor(panelId).geometry ??
        PanelGeometry.fromSize(
          requested.left,
          requested.top,
          descriptor.defaultSize,
        );
  }

  Future<void> _persist(
    PanelId panelId, {
    required PanelGeometry? geometry,
    required bool detached,
  }) async {
    final store = _layoutStore;
    if (store == null) return;
    final layout = await prepareLayout();
    final descriptor = panelDescriptor(panelId);
    final display = displays.displays.isEmpty
        ? null
        : geometry == null
        ? displays.primary
        : displays.bestForRect(geometry.rect, minVisibleFraction: 0.01) ??
              displays.primary;
    final entry = layout
        .entryFor(panelId)
        .copyWith(
          dockState: detached ? DockState.undocked : DockState.docked,
          side: descriptor.defaultSide,
          visible: detached ? layout.entryFor(panelId).visible : true,
          collapsed: false,
          geometry: geometry,
          monitorSignature: display?.configurationSignature,
          monitorDevice: display?.deviceName,
          monitorScale: display?.scaleFactor,
          clearMonitor: display == null,
        );
    await store.save(
      layout
          .withEntry(entry)
          .copyWith(
            preset: detached ? layout.preset : PanelLayoutPreset.singleMonitor,
            preferences: layout.preferences.copyWith(pendingDualRestore: false),
          )
          .normalize(),
    );
  }
}
