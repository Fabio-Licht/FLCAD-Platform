import 'dart:io';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flcad_mobile/app/desktop/layout/display_service.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_presets.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_recovery.dart';
import 'package:flcad_mobile/core/adaptive_studio/models/adaptive_studio_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mm2_layout_harness.dart';

void main() {
  const recovery = PanelLayoutRecovery();

  PanelLayout detachedLayout({
    required String signature,
    required String device,
    required double scale,
    PanelGeometry geometry = const PanelGeometry(
      left: 1960,
      top: 40,
      width: 360,
      height: 420,
    ),
    PanelId panelId = PanelId.continuity,
  }) {
    final base = PanelLayoutPresets.singleMonitor();
    return base
        .withEntry(
          base
              .entryFor(panelId)
              .copyWith(
                dockState: DockState.undocked,
                visible: true,
                collapsed: false,
                geometry: geometry,
                monitorSignature: signature,
                monitorDevice: device,
                monitorScale: scale,
              ),
        )
        .copyWith(preset: PanelLayoutPreset.dualMonitor)
        .normalize();
  }

  group('display service', () {
    test('exposes monitor work areas without assuming an origin at (0,0)', () {
      final desktop = dualDisplayDesktop(
        secondaryOrigin: const Offset(-1920, -120),
      );
      final primary = desktop.primary!;
      final secondary = desktop.displays[1];

      expect(primary.deviceName, r'\\.\DISPLAY1');
      expect(primary.isPrimary, isTrue);
      expect(primary.workArea, const Rect.fromLTWH(0, 0, 1920, 1040));
      // Left/above the primary monitor: negative coordinates are legitimate.
      expect(secondary.bounds.left, -1920);
      expect(secondary.bounds.top, -120);
      expect(secondary.workArea.left, -1920);
      expect(secondary.containsPoint(const Offset(-1920, -100)), isTrue);
      expect(secondary.containsPoint(const Offset(0, 0)), isFalse);
      expect(
        desktop
            .bestForRect(const Rect.fromLTWH(-1900, 0, 300, 200))
            ?.deviceName,
        secondary.deviceName,
      );
      expect(
        desktop
            .bestForRect(const Rect.fromLTWH(100, 100, 300, 200))
            ?.deviceName,
        primary.deviceName,
      );
      expect(
        desktop.bestForRect(const Rect.fromLTWH(5000, 5000, 100, 100)),
        isNull,
      );
    });

    test('signatures separate stable identity from configuration', () {
      final display = testDisplay(
        deviceName: r'\\.\DISPLAY2',
        origin: const Offset(-1920, 0),
        scaleFactor: 1.25,
      );
      expect(display.signature, r'\\.\DISPLAY2');
      expect(
        display.configurationSignature,
        r'\\.\DISPLAY2|1920x1080+-1920,0@1.25',
      );
      expect(display.logicalWorkArea.width, closeTo(1536, 0.001));
    });

    test('the real Windows service is read-only and never throws', () {
      if (!Platform.isWindows) return;
      final service = WindowsDisplayService();
      expect(service.isAvailable, isTrue);
      expect(service.displays, isNotEmpty);
      for (final display in service.displays) {
        expect(display.workArea.width, greaterThan(0));
        expect(display.workArea.height, greaterThan(0));
        expect(display.scaleFactor, greaterThan(0));
      }
      expect(service.primary, isNotNull);
    });
  });

  group('monitor loss and single-screen fallback', () {
    test('a dual layout returns to one screen but keeps the preference', () {
      final layout = PanelLayoutPresets.dualMonitor(
        displays: dualDisplayDesktop(),
        preferences: const PanelLayoutPreferences(
          lastContextualPanel: PanelId.continuity,
        ),
      );
      final result = recovery.recover(
        layout: layout,
        displays: singleDisplayDesktop(),
      );

      expect(result.kinds, contains(PanelRecoveryKind.singleScreenFallback));
      // The preset is the operator's preference: it survives so a reconnected
      // monitor can restore the arrangement.
      expect(result.layout.preset, PanelLayoutPreset.dualMonitor);
      for (final id in PanelId.values) {
        expect(result.layout.entryFor(id).isDetached, isFalse, reason: id.name);
      }
      // Operator preferences survive the downgrade.
      expect(result.layout.preferences.lastContextualPanel, PanelId.continuity);
      // Screen geometry is retained for the moment the monitor comes back.
      expect(result.layout.entryFor(PanelId.continuity).geometry, isNotNull);
    });

    test('a missing secondary monitor moves the panel to the primary', () {
      final desktop = dualDisplayDesktop();
      final layout = detachedLayout(
        signature: desktop.displays[1].configurationSignature,
        device: desktop.displays[1].deviceName,
        scale: 1,
      );
      final stillTwoScreens = FakeDisplayService([
        desktop.displays[0],
        testDisplay(deviceName: r'\\.\DISPLAY3'),
      ]);

      final result = recovery.recover(
        layout: layout,
        displays: stillTwoScreens,
      );

      final entry = result.layout.entryFor(PanelId.continuity);
      expect(result.kinds, contains(PanelRecoveryKind.missingMonitor));
      expect(entry.isDetached, isTrue);
      expect(entry.monitorDevice, r'\\.\DISPLAY1');
      expect(
        stillTwoScreens.displays[0].workArea.overlaps(entry.geometry!.rect),
        isTrue,
      );
    });

    test('same device with a new configuration is rebound, not discarded', () {
      final desktop = dualDisplayDesktop();
      final layout = detachedLayout(
        signature: desktop.displays[1].configurationSignature,
        device: desktop.displays[1].deviceName,
        scale: 1,
      );
      final reconfigured = FakeDisplayService([
        desktop.displays[0],
        testDisplay(
          deviceName: r'\\.\DISPLAY2',
          origin: const Offset(-2560, 0),
          size: const Size(2560, 1440),
        ),
      ]);

      final result = recovery.recover(layout: layout, displays: reconfigured);

      expect(
        result.kinds,
        contains(PanelRecoveryKind.monitorConfigurationChanged),
      );
      final entry = result.layout.entryFor(PanelId.continuity);
      expect(entry.monitorDevice, r'\\.\DISPLAY2');
      expect(
        reconfigured.displays[1].workArea.overlaps(entry.geometry!.rect),
        isTrue,
      );
    });
  });

  group('DPI scale', () {
    test('a scale change preserves the apparent size', () {
      final desktop = dualDisplayDesktop();
      final layout = detachedLayout(
        signature: desktop.displays[1].configurationSignature,
        device: desktop.displays[1].deviceName,
        scale: 1,
        geometry: const PanelGeometry(
          left: 1960,
          top: 40,
          width: 400,
          height: 300,
        ),
      );
      final scaled = FakeDisplayService([
        desktop.displays[0],
        testDisplay(
          deviceName: r'\\.\DISPLAY2',
          origin: const Offset(1920, 0),
          scaleFactor: 1.5,
        ),
      ]);

      final result = recovery.recover(layout: layout, displays: scaled);

      expect(result.kinds, contains(PanelRecoveryKind.scaleChanged));
      final geometry = result.layout.entryFor(PanelId.continuity).geometry!;
      expect(geometry.width, closeTo(600, 0.001));
      expect(geometry.height, closeTo(450, 0.001));
      expect(scaled.displays[1].workArea.overlaps(geometry.rect), isTrue);
      expect(result.layout.entryFor(PanelId.continuity).monitorScale, 1.5);
    });
  });

  group('invalid and off-screen geometry', () {
    /// Two displays, so the single-screen fallback does not swallow the
    /// per-panel geometry recovery under test.
    FakeDisplayService twoScreens() => dualDisplayDesktop();

    test('tiny and absurd geometry falls back to the default size', () {
      final desktop = twoScreens();
      for (final geometry in <PanelGeometry>[
        const PanelGeometry(left: 100, top: 100, width: 20, height: 20),
        const PanelGeometry(left: 0, top: 0, width: 40000, height: 40000),
      ]) {
        final layout = detachedLayout(
          signature: desktop.displays[1].configurationSignature,
          device: desktop.displays[1].deviceName,
          scale: 1,
          geometry: geometry,
        );
        final result = recovery.recover(layout: layout, displays: desktop);
        final entry = result.layout.entryFor(PanelId.continuity);
        expect(
          result.kinds.contains(PanelRecoveryKind.invalidGeometry),
          isTrue,
          reason: geometry.toString(),
        );
        expect(
          entry.geometry!.width,
          panelDescriptor(PanelId.continuity).defaultSize.width,
        );
        expect(
          desktop.displays[1].workArea.contains(entry.geometry!.topLeft),
          isTrue,
        );
      }
    });

    test('non-finite geometry is cleaned before recovery places the panel', () {
      final desktop = twoScreens();
      final layout = detachedLayout(
        signature: desktop.displays[1].configurationSignature,
        device: desktop.displays[1].deviceName,
        scale: 1,
        geometry: PanelGeometry(
          left: double.nan,
          top: 100,
          width: 300,
          height: 200,
        ),
      );
      // Normalization drops the unusable rectangle (and its monitor binding)
      // instead of persisting NaN in the operator's preferences.
      expect(layout.entryFor(PanelId.continuity).geometry, isNull);
      expect(layout.entryFor(PanelId.continuity).monitorSignature, isNull);

      final result = recovery.recover(layout: layout, displays: desktop);

      expect(result.kinds, contains(PanelRecoveryKind.unboundDetached));
      final entry = result.layout.entryFor(PanelId.continuity);
      expect(
        entry.geometry!.width,
        panelDescriptor(PanelId.continuity).defaultSize.width,
      );
      expect(
        desktop.displays[1].workArea.contains(entry.geometry!.topLeft) ||
            desktop.primary!.workArea.contains(entry.geometry!.topLeft),
        isTrue,
      );
    });

    test('a panel far outside every work area is recovered', () {
      final desktop = twoScreens();
      final layout = detachedLayout(
        signature: desktop.displays[1].configurationSignature,
        device: desktop.displays[1].deviceName,
        scale: 1,
        geometry: const PanelGeometry(
          left: 8000,
          top: 6000,
          width: 360,
          height: 420,
        ),
      );

      final result = recovery.recover(layout: layout, displays: desktop);

      expect(result.kinds, contains(PanelRecoveryKind.offScreen));
      final entry = result.layout.entryFor(PanelId.continuity);
      expect(
        desktop.displays[1].workArea.contains(entry.geometry!.topLeft),
        isTrue,
      );
      expect(entry.geometry!.width, 360);
    });

    test('a panel larger than the work area is clamped', () {
      final desktop = FakeDisplayService([
        testDisplay(
          deviceName: r'\\.\DISPLAY1',
          size: const Size(1024, 768),
          workAreaSize: const Size(1024, 728),
          isPrimary: true,
        ),
        testDisplay(deviceName: r'\\.\DISPLAY2', origin: const Offset(1024, 0)),
      ]);
      final layout = detachedLayout(
        signature: desktop.displays[1].configurationSignature,
        device: desktop.displays[1].deviceName,
        scale: 1,
        geometry: const PanelGeometry(
          left: 10,
          top: 10,
          width: 2000,
          height: 1400,
        ),
      );

      final result = recovery.recover(layout: layout, displays: desktop);

      expect(result.kinds, contains(PanelRecoveryKind.clamped));
      final rect = result.layout.entryFor(PanelId.continuity).geometry!.rect;
      final target = desktop.displays[1].workArea;
      expect(target.contains(rect.topLeft), isTrue);
      expect(rect.width, lessThanOrEqualTo(target.width));
      expect(rect.height, lessThanOrEqualTo(target.height));
    });

    test('a detached panel without geometry is placed on the primary', () {
      final desktop = twoScreens();
      final base = PanelLayoutPresets.singleMonitor();
      final layout = base
          .withEntry(
            base
                .entryFor(PanelId.reconstruct)
                .copyWith(
                  dockState: DockState.undocked,
                  visible: true,
                  collapsed: false,
                ),
          )
          .normalize();

      final result = recovery.recover(layout: layout, displays: desktop);

      expect(result.kinds, contains(PanelRecoveryKind.unboundDetached));
      final entry = result.layout.entryFor(PanelId.reconstruct);
      expect(entry.geometry, isNotNull);
      expect(
        desktop.primary!.workArea.contains(entry.geometry!.topLeft),
        isTrue,
      );
    });
  });

  group('recovery is safe and stable', () {
    test('a visible panel on the current monitor is left alone', () {
      final desktop = dualDisplayDesktop();
      final layout = detachedLayout(
        signature: desktop.displays[1].configurationSignature,
        device: desktop.displays[1].deviceName,
        scale: 1,
        geometry: const PanelGeometry(
          left: 2000,
          top: 60,
          width: 360,
          height: 420,
        ),
      );

      final result = recovery.recover(layout: layout, displays: desktop);

      expect(result.changed, isFalse);
      expect(
        result.layout.entryFor(PanelId.continuity).geometry,
        layout.entryFor(PanelId.continuity).geometry,
      );
    });

    test('recovery is idempotent', () {
      final desktop = dualDisplayDesktop();
      final layout = detachedLayout(
        signature: 'monitor-que-nao-existe|800x600+0,0@1.00',
        device: r'\\.\DISPLAY9',
        scale: 2,
        geometry: const PanelGeometry(
          left: -5000,
          top: 9000,
          width: 360,
          height: 420,
        ),
      );

      final first = recovery.recover(layout: layout, displays: desktop);
      final second = recovery.recover(layout: first.layout, displays: desktop);

      expect(first.changed, isTrue);
      expect(second.actions, isEmpty);
      expect(
        second.layout.entries.map((id, entry) => MapEntry(id, entry.toJson())),
        first.layout.entries.map((id, entry) => MapEntry(id, entry.toJson())),
      );
    });

    test('without display information the stored layout is preserved', () {
      final layout = PanelLayoutPresets.dualMonitor(
        displays: dualDisplayDesktop(),
      );
      final result = recovery.recover(
        layout: layout,
        displays: UnavailableDisplayService(),
      );

      expect(result.changed, isFalse);
      expect(result.kinds, contains(PanelRecoveryKind.noDisplayInformation));
      expect(result.layout.entryFor(PanelId.continuity).isDetached, isTrue);
      expect(
        result.layout.entryFor(PanelId.continuity).monitorDevice,
        layout.entryFor(PanelId.continuity).monitorDevice,
      );
    });
  });
}
