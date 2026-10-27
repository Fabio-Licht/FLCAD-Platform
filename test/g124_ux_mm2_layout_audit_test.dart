import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flcad_mobile/app/desktop/layout/display_service.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_planner.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_presets.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_recovery.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_store.dart';
import 'package:flcad_mobile/core/adaptive_studio/models/adaptive_studio_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mm2_layout_harness.dart';

void main() {
  const recovery = PanelLayoutRecovery();
  const planner = PanelLayoutPlanner();

  group('dock vocabulary', () {
    test('classifies all six adaptive studio dock states', () {
      final expectations =
          <DockState, ({bool column, bool overlay, bool screen})>{
            DockState.docked: (column: true, overlay: false, screen: false),
            DockState.pinned: (column: true, overlay: false, screen: false),
            DockState.snapped: (column: true, overlay: false, screen: false),
            DockState.autoHidden: (column: true, overlay: false, screen: false),
            DockState.floating: (column: false, overlay: true, screen: false),
            DockState.undocked: (column: false, overlay: false, screen: true),
          };
      expect(expectations.keys.toSet(), DockState.values.toSet());

      for (final entry in expectations.entries) {
        final panel = PanelLayoutEntry.defaultFor(
          PanelId.inspector,
        ).copyWith(dockState: entry.key).normalized();
        expect(
          panel.occupiesSideColumn,
          entry.value.column,
          reason: '${entry.key}',
        );
        expect(panel.isOverlay, entry.value.overlay, reason: '${entry.key}');
        expect(
          panel.usesScreenGeometry,
          entry.value.screen,
          reason: '${entry.key}',
        );
      }
    });

    test('floating and detached round-trip differently through JSON', () {
      final base = PanelLayoutPresets.singleMonitor();
      final floating = base
          .withEntry(
            base
                .entryFor(PanelId.assistant)
                .copyWith(
                  dockState: DockState.floating,
                  geometry: const PanelGeometry(
                    left: 320,
                    top: 64,
                    width: 340,
                    height: 420,
                  ),
                ),
          )
          .normalize();
      final detached = base
          .withEntry(
            base
                .entryFor(PanelId.assistant)
                .copyWith(
                  dockState: DockState.undocked,
                  geometry: PanelGeometry(
                    left: dualDisplayDesktop().displays[1].workArea.left + 40,
                    top: 80,
                    width: 340,
                    height: 420,
                  ),
                  monitorDevice: r'\\.\DISPLAY2',
                ),
          )
          .normalize();

      final restoredFloating = PanelLayout.fromJson(
        jsonDecode(jsonEncode(floating.toJson())) as Map<String, Object?>,
      );
      final restoredDetached = PanelLayout.fromJson(
        jsonDecode(jsonEncode(detached.toJson())) as Map<String, Object?>,
      );

      expect(
        restoredFloating.entryFor(PanelId.assistant).isFloatingInWindow,
        isTrue,
      );
      expect(
        restoredFloating.entryFor(PanelId.assistant).usesScreenGeometry,
        isFalse,
      );
      expect(restoredDetached.entryFor(PanelId.assistant).isDetached, isTrue);
      expect(
        restoredDetached.entryFor(PanelId.assistant).usesScreenGeometry,
        isTrue,
      );
      // Monitor recovery only rewrites real screen geometry: a floating panel
      // inside the main window is untouched even with no monitor information.
      final result = recovery.recover(
        layout: restoredFloating,
        displays: UnavailableDisplayService(),
      );
      expect(
        result.layout.entryFor(PanelId.assistant).geometry,
        restoredFloating.entryFor(PanelId.assistant).geometry,
      );
    });
  });

  group('workspace compatibility', () {
    test('defaults match the current DockableSidePanel configuration', () {
      final explorer = panelDescriptor(PanelId.explorer);
      final inspector = panelDescriptor(PanelId.inspector);
      final assistant = panelDescriptor(PanelId.assistant);

      expect(explorer.workspaceId, 'explorer');
      expect(explorer.defaultSide, PanelDockSide.left);
      expect(explorer.defaultWidth, 240);
      expect(explorer.defaultDockState, DockState.docked);
      expect(explorer.visibleByDefault, isTrue);
      expect(explorer.collapsedByDefault, isFalse);

      expect(inspector.workspaceId, 'inspector');
      expect(inspector.defaultSide, PanelDockSide.right);
      expect(inspector.defaultWidth, 280);
      expect(inspector.collapsedByDefault, isFalse);

      expect(assistant.workspaceId, 'assistant');
      expect(assistant.defaultSide, PanelDockSide.right);
      expect(assistant.defaultWidth, 300);
      expect(assistant.collapsedByDefault, isTrue);
      // The assistant is the in-window contextual panel; the Sketch panels are
      // the ones the dual-monitor preset moves to the other screen.
      expect(assistant.kind, PanelKind.contextual);
      expect(assistant.detachesToSecondaryByDefault, isFalse);
      expect(
        panelDescriptor(PanelId.reconstruct).detachesToSecondaryByDefault,
        isTrue,
      );
      expect(
        panelDescriptor(PanelId.continuity).detachesToSecondaryByDefault,
        isTrue,
      );
    });

    test('the layout mirrors the adaptive studio panel vocabulary', () {
      final entry = PanelLayoutEntry.defaultFor(PanelId.inspector);
      final panel = entry.toAdaptivePanel(monitorIndex: 2);

      expect(panel.id, 'inspector');
      expect(panel.title, 'Inspector');
      expect(panel.dockState, DockState.docked);
      expect(panel.visible, isTrue);
      expect(panel.monitor, 2);

      final detached = entry.copyWith(dockState: DockState.undocked);
      final back = panelLayoutEntryFromAdaptivePanel(
        detached.toAdaptivePanel(),
      );
      expect(back, isNotNull);
      expect(back!.dockState, DockState.undocked);
      expect(back.panelId, PanelId.inspector);
      expect(
        panelLayoutEntryFromAdaptivePanel(
          AdaptivePanel('painel-desconhecido', 'X'),
        ),
        isNull,
      );
      // Workspace-style ids also resolve.
      expect(
        panelLayoutEntryFromAdaptivePanel(
          AdaptivePanel('assistant', 'Engineering Assistant'),
        )?.panelId,
        PanelId.assistant,
      );
    });
  });

  group('persistence safety', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('mm2-audit-');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    File layoutFile() => File('${directory.path}/${PanelLayoutStore.fileName}');

    test('a newer format version is not overwritten silently', () async {
      final future = jsonEncode({
        'version': 99,
        'preset': 'custom',
        'campoDesconhecido': {'qualquer': 'coisa'},
        'panels': [
          {'id': 'explorer', 'dockWidth': 275, 'dockState': 'pinned'},
        ],
      });
      await layoutFile().writeAsString(future);
      final before = await layoutFile().readAsBytes();
      final store = PanelLayoutStore.forConfigDirectory(directory);

      final load = await store.load();

      expect(load.readOnly, isTrue);
      expect(store.protectsFutureVersion, isTrue);
      expect(store.loadedVersion, 99);
      expect(load.migration.notes, contains('versao-futura:99'));
      expect(load.layout.entryFor(PanelId.explorer).dockWidth, 275);

      await expectLater(
        () => store.save(PanelLayout.defaults()),
        throwsA(isA<StateError>()),
      );
      expect(await layoutFile().readAsBytes(), before);

      await store.save(PanelLayout.defaults(), force: true);
      expect(store.protectsFutureVersion, isFalse);
      final overwritten =
          jsonDecode(await layoutFile().readAsString()) as Map<String, dynamic>;
      expect(overwritten['version'], PanelLayout.currentVersion);
    });

    test('a read failure is reported and the layout is untouched', () async {
      await layoutFile().writeAsString(
        jsonEncode(PanelLayoutPresets.singleMonitor().toJson()),
      );
      final before = await layoutFile().readAsBytes();
      final store = PanelLayoutStore(
        layoutFile(),
        fileSystem: FaultyLayoutFileSystem(failRead: true),
      );

      final result = await store.load();

      expect(result.error, isNotNull);
      expect(result.migration.usedDefaults, isTrue);
      expect(result.layout.entries, hasLength(PanelId.values.length));
      expect(await layoutFile().readAsBytes(), before);
    });

    test('a write failure keeps the previous file intact', () async {
      final store = PanelLayoutStore.forConfigDirectory(directory);
      final first = PanelLayoutPresets.singleMonitor();
      await store.save(first);
      final before = await layoutFile().readAsBytes();

      final faulty = PanelLayoutStore(
        layoutFile(),
        fileSystem: FaultyLayoutFileSystem(failWrite: true),
      );
      await expectLater(
        () => faulty.save(
          PanelLayoutPresets.dualMonitor(displays: dualDisplayDesktop()),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await layoutFile().readAsBytes(), before);
    });

    test('a rename failure restores the previous layout', () async {
      final good = PanelLayoutStore.forConfigDirectory(directory);
      await good.save(PanelLayoutPresets.singleMonitor());
      final before = await layoutFile().readAsBytes();

      final faulty = PanelLayoutStore(
        layoutFile(),
        fileSystem: FaultyLayoutFileSystem(failRenameWhenTargetIsLayout: true),
      );
      await expectLater(
        () => faulty.save(
          PanelLayoutPresets.dualMonitor(displays: dualDisplayDesktop()),
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(await layoutFile().readAsBytes(), before);
      final leftovers = directory.listSync().where(
        (entity) => !entity.path.endsWith('.json'),
      );
      expect(leftovers, isEmpty);
    });

    test('the first rename failure still commits through the backup', () async {
      final good = PanelLayoutStore.forConfigDirectory(directory);
      await good.save(PanelLayoutPresets.singleMonitor());

      final fs = FaultyLayoutFileSystem(failRenameWhenTargetIsLayout: false);
      final store = PanelLayoutStore(layoutFile(), fileSystem: fs);
      final target = PanelLayoutPresets.dualMonitor(
        displays: dualDisplayDesktop(),
      );
      await store.save(target);

      final restored = await good.load();
      expect(restored.layout.preset, PanelLayoutPreset.dualMonitor);
      expect(
        fs.operations.any((operation) => operation.startsWith('write:')),
        isTrue,
      );
    });
  });

  group('preset alternation', () {
    test('Dual -> Single -> Dual restores position and preferences', () {
      final desktop = dualDisplayDesktop();
      final dual = PanelLayoutPresets.dualMonitor(displays: desktop);
      final customPosition = PanelGeometry(
        left: desktop.displays[1].workArea.left + 120,
        top: desktop.displays[1].workArea.top + 80,
        width: 420,
        height: 460,
      );
      final moved = dual
          .withEntry(
            dual
                .entryFor(PanelId.continuity)
                .copyWith(
                  geometry: customPosition,
                  collapsed: true,
                  dockWidth: 355,
                ),
          )
          .copyWith(
            preferences: const PanelLayoutPreferences(
              lastContextualPanel: PanelId.continuity,
            ),
          );

      final single = PanelLayoutPresets.applyPreset(
        current: moved,
        preset: PanelLayoutPresets.singleMonitor(),
      );
      expect(single.preset, PanelLayoutPreset.singleMonitor);
      for (final id in PanelId.values) {
        expect(single.entryFor(id).isDetached, isFalse, reason: id.name);
      }
      // Geometry is kept while docked so the next switch can restore it.
      expect(single.entryFor(PanelId.continuity).geometry, customPosition);
      expect(single.entryFor(PanelId.continuity).collapsed, isTrue);
      expect(single.entryFor(PanelId.continuity).dockWidth, 355);
      expect(single.preferences.lastContextualPanel, PanelId.continuity);

      final backToDual = PanelLayoutPresets.applyPreset(
        current: single,
        preset: PanelLayoutPresets.dualMonitor(displays: desktop),
      );
      expect(backToDual.preset, PanelLayoutPreset.dualMonitor);
      final restored = backToDual.entryFor(PanelId.continuity);
      expect(restored.isDetached, isTrue);
      expect(restored.geometry, customPosition);
      expect(restored.monitorDevice, desktop.displays[1].deviceName);
      expect(restored.dockWidth, 355);
      expect(backToDual.preferences.lastContextualPanel, PanelId.continuity);
    });

    test('Custom keeps the operator arrangement untouched', () {
      final desktop = dualDisplayDesktop();
      final dual = PanelLayoutPresets.dualMonitor(displays: desktop);
      final custom = PanelLayoutPresets.custom(dual);

      expect(custom.preset, PanelLayoutPreset.custom);
      expect(
        custom.entryFor(PanelId.reconstruct).geometry,
        dual.entryFor(PanelId.reconstruct).geometry,
      );
      expect(
        custom.entries.map((id, entry) => MapEntry(id, entry.toJson())),
        dual.entries.map((id, entry) => MapEntry(id, entry.toJson())),
      );
    });
  });

  group('monitor disconnect and reconnect', () {
    test('disconnect brings panels home, reconnect restores them', () {
      final desktop = dualDisplayDesktop();
      final layout = PanelLayoutPresets.dualMonitor(displays: desktop);

      final disconnected = recovery.recover(
        layout: layout,
        displays: singleDisplayDesktop(),
      );
      expect(
        disconnected.kinds,
        contains(PanelRecoveryKind.singleScreenFallback),
      );
      for (final id in PanelId.values) {
        expect(
          disconnected.layout.entryFor(id).isDetached,
          isFalse,
          reason: id.name,
        );
      }

      final reconnected = recovery.recover(
        layout: disconnected.layout,
        displays: desktop,
      );
      expect(reconnected.kinds, contains(PanelRecoveryKind.reconnectedMonitor));
      for (final id in [PanelId.reconstruct, PanelId.continuity]) {
        final entry = reconnected.layout.entryFor(id);
        expect(entry.isDetached, isTrue, reason: id.name);
        expect(entry.monitorDevice, desktop.displays[1].deviceName);
        expect(
          desktop.displays[1].workArea.overlaps(entry.geometry!.rect),
          isTrue,
        );
      }
      // The arrangement is stable afterwards.
      final stable = recovery.recover(
        layout: reconnected.layout,
        displays: desktop,
      );
      expect(stable.actions, isEmpty);
    });

    test('a single-screen preference is not re-detached', () {
      final desktop = dualDisplayDesktop();
      final result = recovery.recover(
        layout: PanelLayoutPresets.singleMonitor(),
        displays: desktop,
      );
      expect(
        result.kinds,
        isNot(contains(PanelRecoveryKind.reconnectedMonitor)),
      );
      for (final id in PanelId.values) {
        expect(result.layout.entryFor(id).isDetached, isFalse, reason: id.name);
      }
    });
  });

  group('geometry validation', () {
    test('non-finite and malformed JSON geometry is rejected', () {
      expect(PanelGeometry.fromJson(null), isNull);
      expect(PanelGeometry.fromJson('nada'), isNull);
      expect(PanelGeometry.fromJson(<String, Object?>{}), isNull);
      expect(
        PanelGeometry.fromJson({
          'left': double.nan,
          'top': 0,
          'width': 100,
          'height': 100,
        }),
        isNull,
      );
      expect(
        PanelGeometry.fromJson({
          'left': 0,
          'top': double.infinity,
          'width': 100,
          'height': 100,
        }),
        isNull,
      );
      final valid = PanelGeometry.fromJson({
        'left': -1920,
        'top': -160,
        'width': 360,
        'height': 420,
      });
      expect(
        valid,
        const PanelGeometry(left: -1920, top: -160, width: 360, height: 420),
      );
    });

    test('size limits follow the monitor scale', () {
      // Minimum detached size is 220x160 logical.
      const panel = PanelGeometry(left: 0, top: 0, width: 240, height: 180);
      expect(panel.hasUsableSize(scaleFactor: 1), isTrue);
      // At 150% the minimum becomes 330x240, so the same panel is too small.
      expect(panel.hasUsableSize(scaleFactor: 1.5), isFalse);
      expect(
        const PanelGeometry(
          left: 0,
          top: 0,
          width: 330,
          height: 240,
        ).hasUsableSize(scaleFactor: 1.5),
        isTrue,
      );
      expect(
        const PanelGeometry(
          left: 0,
          top: 0,
          width: 20000,
          height: 400,
        ).hasUsableSize(scaleFactor: 1),
        isFalse,
      );
    });

    test('normalize is idempotent for a messy layout', () {
      final messy = PanelLayout(
        entries: {
          PanelId.explorer: PanelLayoutEntry.defaultFor(
            PanelId.explorer,
          ).copyWith(dockWidth: double.nan, order: 42, collapsed: false),
          PanelId.inspector: PanelLayoutEntry.defaultFor(
            PanelId.inspector,
          ).copyWith(dockState: DockState.autoHidden, collapsed: false),
          PanelId.continuity: PanelLayoutEntry.defaultFor(PanelId.continuity)
              .copyWith(
                dockState: DockState.undocked,
                geometry: const PanelGeometry(
                  left: double.nan,
                  top: 0,
                  width: 100,
                  height: 100,
                ),
              ),
        },
        preferences: const PanelLayoutPreferences(
          lastContextualPanel: PanelId.continuity,
        ),
      );

      final once = messy.normalize();
      final twice = once.normalize();

      expect(
        twice.entries.map((id, entry) => MapEntry(id, entry.toJson())),
        once.entries.map((id, entry) => MapEntry(id, entry.toJson())),
      );
      expect(twice.entries, hasLength(PanelId.values.length));
      expect(once.entryFor(PanelId.inspector).collapsed, isTrue);
      expect(once.entryFor(PanelId.continuity).geometry, isNull);
    });
  });

  group('responsive edge cases', () {
    test('a compact window keeps a single open contextual panel', () {
      final layout = PanelLayoutPresets.singleMonitor().copyWith(
        preferences: const PanelLayoutPreferences(
          lastContextualPanel: PanelId.reconstruct,
        ),
      );

      final resolution = planner.resolve(
        layout: layout,
        usableSize: const Size(1120, 640),
      );

      expect(resolution.compact, isTrue);
      expect(resolution.highlightedContextualPanel, PanelId.reconstruct);
      final highlighted = resolution.dockWidths[PanelId.reconstruct];
      expect(highlighted, isNotNull);
      expect(highlighted!, greaterThanOrEqualTo(panelMinWidth));
      expect(
        resolution.viewportWidth,
        greaterThanOrEqualTo(
          const PanelLayoutPolicy().viewportMinWidthCompact - 0.001,
        ),
      );
      // Only one contextual panel is expanded.
      final expandedContextual = PanelId.values.where(
        (id) =>
            panelDescriptor(id).kind == PanelKind.contextual &&
            resolution.collapsed[id] == false,
      );
      expect(expandedContextual, hasLength(1));
    });

    test('a very short window stays usable', () {
      final resolution = planner.resolve(
        layout: PanelLayoutPresets.singleMonitor(),
        usableSize: const Size(1600, 400),
      );

      expect(resolution.compact, isTrue);
      expect(resolution.viewportHeight, greaterThan(0));
      expect(resolution.viewportWidth, greaterThan(0));
      for (final width in resolution.dockWidths.values) {
        expect(width, lessThanOrEqualTo(panelMaxWidth));
      }
    });
  });

  group('multi resolution desktop', () {
    test('a dual preset places panels inside the physical work area', () {
      // 4K at 150% plus a 1080p screen at 100%: different resolutions and DPIs.
      final desktop = FakeDisplayService([
        testDisplay(
          deviceName: r'\\.\DISPLAY1',
          size: const Size(3840, 2160),
          workAreaSize: const Size(3840, 2080),
          scaleFactor: 1.5,
          isPrimary: true,
        ),
        testDisplay(
          deviceName: r'\\.\DISPLAY2',
          origin: const Offset(3840, 120),
          size: const Size(1920, 1080),
          workAreaSize: const Size(1920, 1040),
        ),
      ]);

      final layout = PanelLayoutPresets.dualMonitor(displays: desktop);
      final secondary = desktop.displays[1];
      for (final id in [PanelId.reconstruct, PanelId.continuity]) {
        final geometry = layout.entryFor(id).geometry!;
        expect(geometry.hasUsableSize(scaleFactor: 1), isTrue);
        expect(secondary.workArea.contains(geometry.topLeft), isTrue);
        expect(layout.entryFor(id).monitorScale, 1);
      }

      final result = recovery.recover(layout: layout, displays: desktop);
      expect(result.actions, isEmpty);
    });

    test('a panel on a monitor left of the primary stays there', () {
      final desktop = dualDisplayDesktop(
        secondaryOrigin: const Offset(-1920, -120),
      );
      final secondary = desktop.displays[1];
      final base = PanelLayoutPresets.singleMonitor();
      final layout = base
          .withEntry(
            base
                .entryFor(PanelId.continuity)
                .copyWith(
                  dockState: DockState.undocked,
                  visible: true,
                  collapsed: false,
                  geometry: PanelGeometry(
                    left: secondary.workArea.left + 60,
                    top: secondary.workArea.top + 40,
                    width: 360,
                    height: 420,
                  ),
                  monitorSignature: secondary.configurationSignature,
                  monitorDevice: secondary.deviceName,
                  monitorScale: secondary.scaleFactor,
                ),
          )
          .normalize();

      final result = recovery.recover(layout: layout, displays: desktop);

      expect(result.changed, isFalse);
      expect(
        result.layout.entryFor(PanelId.continuity).monitorDevice,
        secondary.deviceName,
      );
    });
  });

  group('display service safety', () {
    test('an unavailable service degrades safely', () {
      final service = UnavailableDisplayService();
      expect(service.isAvailable, isFalse);
      expect(service.displays, isEmpty);
      expect(service.primary, isNull);
      expect(service.bySignature('qualquer'), isNull);
      expect(service.bestForRect(const Rect.fromLTWH(0, 0, 100, 100)), isNull);
    });

    test('display JSON parsing tolerates garbage', () {
      final parsed = DisplayInfo.fromJson({
        'deviceName': r'\\.\DISPLAY9',
        'bounds': [1, 2, 'x', 4],
        'workArea': <Object?>[],
        'scaleFactor': 0,
        'dpi': -5,
      });
      expect(parsed.deviceName, r'\\.\DISPLAY9');
      expect(parsed.bounds, Rect.zero);
      expect(parsed.workArea, Rect.zero);
      expect(parsed.scaleFactor, 1);
      expect(parsed.dpi, defaultDpi);
      expect(parsed.visibleFraction(Rect.zero), 0);
    });

    test('repeated refresh on the real Windows service is stable', () async {
      if (!Platform.isWindows) return;
      final first = WindowsDisplayService();
      for (var index = 0; index < 3; index++) {
        await first.refresh();
        expect(first.isAvailable, isTrue);
        expect(first.displays, isNotEmpty);
      }
      final second = WindowsDisplayService();
      expect(second.isAvailable, isTrue);
      expect(second.displays.length, first.displays.length);
      expect(createPlatformDisplayService(), isA<WindowsDisplayService>());
    });
  });
}
