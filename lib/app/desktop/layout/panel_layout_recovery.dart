import 'dart:ui' show Offset, Rect;

import '../../../core/adaptive_studio/models/adaptive_studio_models.dart';
import 'display_service.dart';
import 'panel_identity.dart';
import 'panel_layout.dart';

enum PanelRecoveryKind {
  /// The platform gave no monitor information: geometry is left untouched.
  noDisplayInformation,

  /// A multi-monitor layout came back on a single screen: panels return to the
  /// main window while the dual-monitor preference is remembered.
  singleScreenFallback,

  /// The stored monitor no longer exists.
  missingMonitor,

  /// Same device, different resolution/position/DPI signature.
  monitorConfigurationChanged,

  /// A second monitor came back and the dual-monitor preference was restored.
  reconnectedMonitor,

  /// The monitor changed DPI scale.
  scaleChanged,

  /// The panel would not be visible on any work area.
  offScreen,

  /// Stored geometry was not usable (NaN, absurd or too small).
  invalidGeometry,

  /// Detached panel without geometry.
  unboundDetached,

  /// Geometry was pulled back inside the work area.
  clamped,
}

class PanelRecoveryAction {
  const PanelRecoveryAction(this.panelId, this.kind, this.detail);

  final PanelId? panelId;
  final PanelRecoveryKind kind;
  final String detail;

  @override
  String toString() =>
      'PanelRecoveryAction(${panelId?.name ?? 'layout'}, ${kind.name}, '
      '$detail)';
}

class PanelRecoveryResult {
  const PanelRecoveryResult(this.layout, this.actions);

  final PanelLayout layout;
  final List<PanelRecoveryAction> actions;

  bool get changed => actions.any(
    (action) => action.kind != PanelRecoveryKind.noDisplayInformation,
  );

  Set<PanelRecoveryKind> get kinds => {
    for (final action in actions) action.kind,
  };
}

/// Brings a stored layout back onto the monitors that exist right now.
///
/// Pure and read-only with respect to CAD state: it only rewrites layout
/// geometry. Rules:
/// * no monitor information -> return the layout untouched (never guess);
/// * single screen with a multi-monitor layout -> back to the single-monitor
///   preset, panels re-docked, operator preferences preserved;
/// * missing monitor / off-screen geometry -> cascade onto the primary work
///   area, keeping the logical size;
/// * DPI scale change -> rescale so the apparent size is preserved;
/// * invalid geometry -> descriptor default, then clamped into the work area.
class PanelLayoutRecovery {
  const PanelLayoutRecovery({
    this.minVisibleFraction = 0.25,
    this.cascadeStep = 28,
    this.workAreaMargin = 8,
  });

  final double minVisibleFraction;
  final double cascadeStep;
  final double workAreaMargin;

  PanelRecoveryResult recover({
    required PanelLayout layout,
    required DisplayService displays,
  }) {
    final actions = <PanelRecoveryAction>[];
    final available = displays.displays;
    if (available.isEmpty) {
      actions.add(
        const PanelRecoveryAction(
          null,
          PanelRecoveryKind.noDisplayInformation,
          'Nenhum monitor identificado; geometria preservada.',
        ),
      );
      return PanelRecoveryResult(layout.normalize(), actions);
    }

    final primary = displays.primary ?? available.first;
    var working = layout;
    var cascadeIndex = 0;

    Offset nextCascade(Rect workArea) {
      final step = cascadeStep * (cascadeIndex + 1);
      cascadeIndex++;
      return Offset(workArea.left + step, workArea.top + step);
    }

    // 1) Multi-monitor layout on a single screen: everything comes back into
    //    the main window. The stored preset stays as the operator's preference
    //    so a reconnected monitor can restore it (step 2).
    final detached = PanelId.values
        .where((id) => working.entryFor(id).isDetached)
        .toList();
    if (available.length == 1 && detached.isNotEmpty) {
      final entries = <PanelId, PanelLayoutEntry>{};
      for (final id in PanelId.values) {
        final entry = working.entryFor(id);
        if (!entry.isDetached) {
          entries[id] = entry;
          continue;
        }
        final descriptor = panelDescriptor(id);
        entries[id] = entry.copyWith(
          dockState: descriptor.defaultDockState,
          side: descriptor.defaultSide,
          collapsed:
              descriptor.defaultDockState == DockState.autoHidden ||
              entry.collapsed,
        );
        actions.add(
          PanelRecoveryAction(
            id,
            PanelRecoveryKind.singleScreenFallback,
            'Um único monitor: ${descriptor.title} voltou para a janela '
            'principal.',
          ),
        );
      }
      working = working
          .copyWith(
            entries: entries,
            preferences: working.preferences.copyWith(pendingDualRestore: true),
          )
          .normalize();
    }

    // 2) Reconnected monitor: the operator's dual-monitor preference is
    //    restored as soon as a second screen exists again.
    if (available.length >= 2 && working.preferences.pendingDualRestore) {
      final reattached = <PanelId, PanelLayoutEntry>{};
      var reattachedAny = false;
      for (final id in PanelId.values) {
        final entry = working.entryFor(id);
        final descriptor = panelDescriptor(id);
        if (entry.isDetached || !descriptor.detachesToSecondaryByDefault) {
          reattached[id] = entry;
          continue;
        }
        reattached[id] = entry.copyWith(
          dockState: DockState.undocked,
          collapsed: false,
        );
        reattachedAny = true;
        actions.add(
          PanelRecoveryAction(
            id,
            PanelRecoveryKind.reconnectedMonitor,
            'Monitor reconectado: ${descriptor.title} voltou para a tela '
            'secundária.',
          ),
        );
      }
      working = working
          .copyWith(
            entries: reattached,
            preferences: working.preferences.copyWith(
              pendingDualRestore: !reattachedAny,
            ),
          )
          .normalize();
    }

    // 2) Per-panel monitor/geometry recovery.
    final entries = <PanelId, PanelLayoutEntry>{...working.entries};
    for (final id in PanelId.values) {
      final entry = entries[id] ?? PanelLayoutEntry.defaultFor(id);
      if (!entry.isDetached) continue;
      final descriptor = panelDescriptor(id);

      var bound = displays.bySignature(entry.monitorSignature);
      if (bound == null && entry.monitorSignature != null) {
        bound = displays.byDevice(entry.monitorDevice);
        if (bound != null) {
          actions.add(
            PanelRecoveryAction(
              id,
              PanelRecoveryKind.monitorConfigurationChanged,
              'Configuração do monitor mudou; ${descriptor.title} foi '
              'reancorado ao mesmo dispositivo.',
            ),
          );
        }
      }
      final target = bound ?? primary;
      if (bound == null && entry.monitorSignature != null) {
        actions.add(
          PanelRecoveryAction(
            id,
            PanelRecoveryKind.missingMonitor,
            'Monitor ausente; ${descriptor.title} foi movido para o monitor '
            'principal.',
          ),
        );
      }

      var scale = entry.monitorScale ?? target.scaleFactor;
      var geometry = entry.geometry;
      if (geometry == null) {
        final origin = nextCascade(target.workArea);
        geometry = PanelGeometry.fromSize(
          origin.dx,
          origin.dy,
          descriptor.defaultSize,
        );
        scale = target.scaleFactor;
        actions.add(
          PanelRecoveryAction(
            id,
            PanelRecoveryKind.unboundDetached,
            '${descriptor.title} destacado sem geometria; posicionado no '
            'monitor principal.',
          ),
        );
      } else if (!geometry.isFinite ||
          !geometry.hasUsableSize(scaleFactor: scale)) {
        final size = descriptor.defaultSize;
        geometry = PanelGeometry.fromSize(
          target.workArea.left + workAreaMargin,
          target.workArea.top + workAreaMargin,
          size,
        );
        scale = target.scaleFactor;
        actions.add(
          PanelRecoveryAction(
            id,
            PanelRecoveryKind.invalidGeometry,
            'Geometria inválida para ${descriptor.title}; tamanho padrão '
            'aplicado.',
          ),
        );
      }

      if ((scale - target.scaleFactor).abs() > 0.01) {
        geometry = geometry.rescale(target.scaleFactor / scale);
        actions.add(
          PanelRecoveryAction(
            id,
            PanelRecoveryKind.scaleChanged,
            'Escala DPI mudou de ${scale.toStringAsFixed(2)} para '
            '${target.scaleFactor.toStringAsFixed(2)}; tamanho aparente '
            'preservado.',
          ),
        );
      }

      final visible = target.visibleFraction(geometry.rect);
      if (visible < minVisibleFraction) {
        final size = geometry.size;
        final origin = nextCascade(target.workArea);
        geometry = PanelGeometry.fromSize(origin.dx, origin.dy, size);
        actions.add(
          PanelRecoveryAction(
            id,
            PanelRecoveryKind.offScreen,
            '${descriptor.title} estava fora da área visível; reposicionado em '
            '${target.deviceName}.',
          ),
        );
      }

      final clamped = clampRectInto(
        geometry.rect,
        target.workArea,
        margin: workAreaMargin,
      );
      if (clamped != geometry.rect) {
        geometry = geometry.withRect(clamped);
        actions.add(
          PanelRecoveryAction(
            id,
            PanelRecoveryKind.clamped,
            '${descriptor.title} foi ajustado para dentro da work area.',
          ),
        );
      }

      entries[id] = entry.copyWith(
        geometry: geometry,
        monitorSignature: target.configurationSignature,
        monitorDevice: target.deviceName,
        monitorScale: target.scaleFactor,
      );
    }

    return PanelRecoveryResult(
      working.copyWith(entries: entries).normalize(),
      actions,
    );
  }
}
