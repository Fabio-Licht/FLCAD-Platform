import 'dart:convert';
import 'dart:io';

import 'package:flcad_mobile/app/desktop/layout/display_service.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_host_gateway.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_migration.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_presets.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_recovery.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_store.dart';
import 'package:flcad_mobile/core/adaptive_studio/models/adaptive_studio_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mm2_layout_harness.dart';

void main() {
  group('panel identity', () {
    test('catalog covers the five operator panels with stable ids', () {
      expect(PanelId.values, hasLength(5));
      expect(
        PanelId.values.map((id) => panelDescriptor(id).workspaceId).toList(),
        [
          'explorer',
          'inspector',
          'assistant',
          'sketch-reconstruct',
          'sketch-continuity',
        ],
      );
      expect(panelIdFromWorkspaceId('inspector'), PanelId.inspector);
      expect(panelIdFromWorkspaceId('desconhecido'), isNull);
      expect(panelCatalog[PanelId.explorer]!.kind, PanelKind.primary);
      expect(contextualPanelsByPriority().first, PanelId.reconstruct);
    });

    test(
      'reuses the adaptive studio dock vocabulary instead of a new model',
      () {
        // DockState is the shared vocabulary (6 values, asserted by
        // adaptive_studio_test.dart); the layout never adds a competing enum.
        expect(DockState.values, hasLength(6));
        final entry = PanelLayoutEntry.defaultFor(PanelId.reconstruct);
        expect(
          entry.copyWith(dockState: DockState.undocked).isDetached,
          isTrue,
        );
        expect(
          entry.copyWith(dockState: DockState.floating).isFloatingInWindow,
          isTrue,
        );
        expect(
          entry.copyWith(dockState: DockState.floating).occupiesSideColumn,
          isFalse,
        );
        expect(
          entry.copyWith(dockState: DockState.docked).occupiesSideColumn,
          isTrue,
        );
      },
    );
  });

  group('layout serialization', () {
    test('round-trips every persisted field', () {
      final layout = PanelLayout.defaults()
          .withEntry(
            PanelLayout.defaults()
                .entryFor(PanelId.inspector)
                .copyWith(
                  dockWidth: 312,
                  order: 3,
                  visible: false,
                  collapsed: true,
                ),
          )
          .withEntry(
            PanelLayout.defaults()
                .entryFor(PanelId.continuity)
                .copyWith(
                  dockState: DockState.undocked,
                  geometry: const PanelGeometry(
                    left: -1440,
                    top: -120,
                    width: 420,
                    height: 380,
                  ),
                  monitorSignature: r'\\.\DISPLAY2|1920x1080+-1920,0@1.25',
                  monitorDevice: r'\\.\DISPLAY2',
                  monitorScale: 1.25,
                ),
          )
          .copyWith(
            preset: PanelLayoutPreset.dualMonitor,
            preferences: const PanelLayoutPreferences(
              focusMode: true,
              lastContextualPanel: PanelId.reconstruct,
            ),
          )
          .normalize();

      final restored = PanelLayout.fromJson(
        jsonDecode(jsonEncode(layout.toJson())) as Map<String, Object?>,
      );

      expect(restored.preset, PanelLayoutPreset.dualMonitor);
      expect(restored.version, PanelLayout.currentVersion);
      expect(restored.preferences.focusMode, isTrue);
      expect(restored.preferences.lastContextualPanel, PanelId.reconstruct);
      expect(restored.entryFor(PanelId.inspector).dockWidth, 312);
      expect(restored.entryFor(PanelId.inspector).visible, isFalse);
      expect(restored.entryFor(PanelId.inspector).collapsed, isTrue);
      final detached = restored.entryFor(PanelId.continuity);
      expect(detached.isDetached, isTrue);
      expect(detached.monitorScale, 1.25);
      expect(detached.monitorDevice, r'\\.\DISPLAY2');
      expect(
        detached.geometry,
        const PanelGeometry(left: -1440, top: -120, width: 420, height: 380),
      );
      expect(jsonEncode(restored.toJson()), jsonEncode(layout.toJson()));
    });

    test('normalizes widths, order and hidden panels deterministically', () {
      final layout = PanelLayout.defaults()
          .withEntry(
            PanelLayout.defaults()
                .entryFor(PanelId.explorer)
                .copyWith(dockWidth: 5, order: 9),
          )
          .withEntry(
            PanelLayout.defaults()
                .entryFor(PanelId.inspector)
                .copyWith(dockWidth: 5000, order: 0),
          )
          .normalize();

      expect(layout.entryFor(PanelId.explorer).dockWidth, panelMinWidth);
      expect(layout.entryFor(PanelId.inspector).dockWidth, panelMaxWidth);
      expect(
        layout.entriesInSide(PanelDockSide.left).map((e) => e.panelId).toList(),
        [PanelId.explorer],
      );
      expect(layout.entryFor(PanelId.explorer).order, 0);
      expect(layout.entryFor(PanelId.inspector).order, 0);
    });
  });

  group('versioning and migration', () {
    const migrator = PanelLayoutMigrator();

    test('migrates the legacy flat map into the versioned document', () {
      final migration = migrator.migrate({
        'explorer': 'undocked',
        'inspector': 'docked',
        'assistant': 'autoHidden',
      });

      expect(migration.report.sourceVersion, 0);
      expect(migration.report.migrated, isTrue);
      expect(migration.report.notes, contains('mapa-plano-legado'));
      expect(migration.layout.version, PanelLayout.currentVersion);
      expect(migration.layout.entryFor(PanelId.explorer).isDetached, isTrue);
      expect(
        migration.layout.entryFor(PanelId.assistant).dockState,
        DockState.autoHidden,
      );
      expect(migration.layout.entryFor(PanelId.assistant).collapsed, isTrue);
      // Panels absent from the legacy payload fall back to defaults.
      expect(
        migration.layout.entryFor(PanelId.inspector).dockWidth,
        panelDescriptor(PanelId.inspector).defaultWidth,
      );
    });

    test('accepts documents without a version and drops unknown panels', () {
      final migration = migrator.migrate({
        'panels': [
          {'id': 'explorer', 'dockWidth': 260, 'dockState': 'docked'},
          {'id': 'nao-existe', 'dockWidth': 100},
          'lixo',
        ],
      });

      expect(migration.report.sourceVersion, isNull);
      expect(migration.report.notes, contains('versao-ausente'));
      expect(migration.report.droppedPanelIds, ['nao-existe']);
      expect(migration.layout.entryFor(PanelId.explorer).dockWidth, 260);
      expect(migration.layout.entries, hasLength(PanelId.values.length));
    });

    test('keeps recognized fields from a future version without throwing', () {
      final migration = migrator.migrate({
        'version': 99,
        'preset': 'custom',
        'algoNovo': true,
        'panels': [
          {'id': 'explorer', 'dockWidth': 275, 'dockState': 'pinned'},
        ],
      });

      expect(migration.report.notes, contains('versao-futura:99'));
      expect(migration.layout.preset, PanelLayoutPreset.custom);
      expect(migration.layout.entryFor(PanelId.explorer).dockWidth, 275);
      expect(
        migration.layout.entryFor(PanelId.explorer).dockState,
        DockState.pinned,
      );
    });

    test('falls back to defaults for unusable payloads', () {
      for (final payload in <Object?>[null, 'texto', 42, <String>[]]) {
        final migration = migrator.migrate(payload);
        expect(migration.report.usedDefaults, isTrue);
        expect(migration.layout.entries, hasLength(PanelId.values.length));
        expect(
          migration.layout.entryFor(PanelId.explorer).dockWidth,
          panelDescriptor(PanelId.explorer).defaultWidth,
        );
      }
    });
  });

  group('per-user store', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('mm2-store-');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('creates defaults when the preferences file is missing', () async {
      final store = PanelLayoutStore.forConfigDirectory(directory);
      final result = await store.load();

      expect(result.fileExisted, isFalse);
      expect(result.error, isNull);
      expect(result.layout.preset, PanelLayoutPreset.singleMonitor);
      expect(
        await File('${directory.path}/${PanelLayoutStore.fileName}').exists(),
        isFalse,
      );
    });

    test('restores the operator layout after a restart', () async {
      final store = PanelLayoutStore.forConfigDirectory(directory);
      final layout = PanelLayoutPresets.dualMonitor(
        displays: dualDisplayDesktop(),
        preferences: const PanelLayoutPreferences(
          lastContextualPanel: PanelId.continuity,
        ),
      );
      await store.save(layout);

      // A new store instance models the next application start.
      final restarted = PanelLayoutStore.forConfigDirectory(directory);
      final result = await restarted.load();

      expect(result.fileExisted, isTrue);
      expect(result.error, isNull);
      expect(result.migration.sourceVersion, PanelLayout.currentVersion);
      expect(result.layout.preset, PanelLayoutPreset.dualMonitor);
      expect(result.layout.preferences.lastContextualPanel, PanelId.continuity);
      expect(result.layout.entryFor(PanelId.reconstruct).isDetached, isTrue);
      // `save` stamps `updatedAt`, so compare the arrangement itself.
      expect(
        result.layout.entries.map((id, entry) => MapEntry(id, entry.toJson())),
        layout.normalize().entries.map(
          (id, entry) => MapEntry(id, entry.toJson()),
        ),
      );
      expect(result.layout.preferences, layout.normalize().preferences);
    });

    test('is atomic and leaves no temporary file behind', () async {
      final store = PanelLayoutStore.forConfigDirectory(directory);
      await store.save(PanelLayout.defaults());
      await store.save(PanelLayoutPresets.singleMonitor());

      final leftovers = directory
          .listSync()
          .where((entity) => entity.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
      final raw = await File(
        '${directory.path}/${PanelLayoutStore.fileName}',
      ).readAsString();
      expect(
        (jsonDecode(raw) as Map<String, dynamic>)['version'],
        PanelLayout.currentVersion,
      );
    });

    test('recovers from corrupt preferences with defaults', () async {
      final file = File('${directory.path}/${PanelLayoutStore.fileName}');
      await file.writeAsString('{ isto não é json');
      final store = PanelLayoutStore(file);

      final result = await store.load();

      expect(result.error, isNotNull);
      expect(result.migration.usedDefaults, isTrue);
      expect(result.layout.entries, hasLength(PanelId.values.length));
    });
  });

  group('presets', () {
    test('single monitor keeps every panel inside the main window', () {
      final layout = PanelLayoutPresets.singleMonitor();
      expect(layout.preset, PanelLayoutPreset.singleMonitor);
      for (final id in PanelId.values) {
        expect(layout.entryFor(id).isDetached, isFalse, reason: id.name);
        expect(layout.entryFor(id).geometry, isNull);
      }
      expect(layout.entryFor(PanelId.explorer).side, PanelDockSide.left);
      expect(layout.entryFor(PanelId.inspector).side, PanelDockSide.right);
      expect(layout.entryFor(PanelId.assistant).collapsed, isTrue);
    });

    test('dual monitor detaches the contextual panels on the secondary', () {
      final desktop = dualDisplayDesktop(
        secondaryOrigin: const Offset(1920, 0),
      );
      final layout = PanelLayoutPresets.dualMonitor(displays: desktop);
      final secondary = desktop.displays[1].workArea;

      expect(layout.preset, PanelLayoutPreset.dualMonitor);
      for (final id in [PanelId.reconstruct, PanelId.continuity]) {
        final entry = layout.entryFor(id);
        expect(entry.isDetached, isTrue, reason: id.name);
        expect(entry.visible, isTrue);
        expect(entry.monitorDevice, desktop.displays[1].deviceName);
        expect(secondary.contains(entry.geometry!.topLeft), isTrue);
        expect(
          secondary.contains(
            Offset(
              entry.geometry!.left + entry.geometry!.width - 1,
              entry.geometry!.top + entry.geometry!.height - 1,
            ),
          ),
          isTrue,
        );
      }
      // Primary panels stay docked.
      expect(layout.entryFor(PanelId.explorer).isDetached, isFalse);
      expect(layout.entryFor(PanelId.inspector).isDetached, isFalse);
    });

    test('dual monitor falls back to single when only one screen exists', () {
      final layout = PanelLayoutPresets.dualMonitor(
        displays: FakeDisplayService.single(),
      );
      expect(layout.preset, PanelLayoutPreset.singleMonitor);
      for (final id in PanelId.values) {
        expect(layout.entryFor(id).isDetached, isFalse, reason: id.name);
      }
    });

    test('forDisplays picks the preset from the desktop', () {
      expect(
        PanelLayoutPresets.forDisplays(
          displays: FakeDisplayService.single(),
        ).preset,
        PanelLayoutPreset.singleMonitor,
      );
      expect(
        PanelLayoutPresets.forDisplays(displays: dualDisplayDesktop()).preset,
        PanelLayoutPreset.dualMonitor,
      );
    });

    test('custom marks the arrangement and applyPreset keeps preferences', () {
      final current = PanelLayout.defaults()
          .withEntry(
            PanelLayout.defaults()
                .entryFor(PanelId.explorer)
                .copyWith(collapsed: true, dockWidth: 205),
          )
          .copyWith(
            preferences: const PanelLayoutPreferences(
              focusMode: true,
              lastContextualPanel: PanelId.continuity,
            ),
          );

      final custom = PanelLayoutPresets.custom(current);
      expect(custom.preset, PanelLayoutPreset.custom);

      final applied = PanelLayoutPresets.applyPreset(
        current: custom,
        preset: PanelLayoutPresets.dualMonitor(displays: dualDisplayDesktop()),
      );
      expect(applied.preset, PanelLayoutPreset.dualMonitor);
      expect(applied.entryFor(PanelId.explorer).collapsed, isTrue);
      expect(applied.entryFor(PanelId.explorer).dockWidth, 205);
      expect(applied.preferences.lastContextualPanel, PanelId.continuity);
      expect(applied.entryFor(PanelId.continuity).isDetached, isTrue);
    });
  });

  group('panel host gateway seam', () {
    test('the default backend never opens a window', () async {
      const gateway = NoopPanelHostGateway();
      final layout = PanelLayoutPresets.dualMonitor(
        displays: dualDisplayDesktop(),
      );

      final created = await materializeDetachedPanels(
        layout: layout,
        gateway: gateway,
      );

      expect(created, isEmpty);
      expect(gateway.windows, isEmpty);
      // Detached stays a modeled state, not a promise of a real window.
      expect(layout.entryFor(PanelId.reconstruct).isDetached, isTrue);
    });

    test('a recording backend materializes only detached panels', () async {
      final gateway = RecordingPanelHostGateway();
      final layout = PanelLayoutPresets.dualMonitor(
        displays: dualDisplayDesktop(),
      );

      final created = await materializeDetachedPanels(
        layout: layout,
        gateway: gateway,
      );

      expect(created, hasLength(2));
      expect(created.map((state) => state.panelId).toSet(), {
        PanelId.reconstruct,
        PanelId.continuity,
      });
      expect(gateway.requests.map((request) => request.panelId).toSet(), {
        PanelId.reconstruct,
        PanelId.continuity,
      });
      expect(
        PanelWindowRequest.fromEntry(layout.entryFor(PanelId.explorer)),
        isNull,
      );
      await gateway.closeAllWindows();
      expect(gateway.windows, isEmpty);
    });
  });

  group('no document mutation', () {
    test('the layout pipeline never writes into a project directory', () async {
      final projectDirectory = await Directory.systemTemp.createTemp(
        'mm2-project-',
      );
      final configDirectory = await Directory.systemTemp.createTemp(
        'mm2-config-',
      );
      addTearDown(() async {
        if (await projectDirectory.exists()) {
          await projectDirectory.delete(recursive: true);
        }
        if (await configDirectory.exists()) {
          await configDirectory.delete(recursive: true);
        }
      });

      final cad = Directory('${projectDirectory.path}/CAD/Layout')
        ..createSync(recursive: true);
      File('${projectDirectory.path}/job.json').writeAsStringSync('{"id":"p"}');
      File('${cad.path}/workspace.json').writeAsStringSync('{"panels":[]}');
      final before = _directoryFingerprint(projectDirectory);

      final store = PanelLayoutStore.forConfigDirectory(configDirectory);
      final layout = PanelLayoutPresets.dualMonitor(
        displays: dualDisplayDesktop(),
      );
      await store.save(layout);
      final restored = await store.load();
      final recovered = const PanelLayoutRecovery().recover(
        layout: restored.layout,
        displays: dualDisplayDesktop(),
      );
      await store.save(recovered.layout);

      expect(_directoryFingerprint(projectDirectory), before);
      expect(
        await File(
          '${configDirectory.path}/${PanelLayoutStore.fileName}',
        ).exists(),
        isTrue,
      );
    });

    test('the layout module depends on no CAD, kernel or command service', () {
      final moduleDirectory = Directory('lib/app/desktop/layout');
      expect(moduleDirectory.existsSync(), isTrue);
      const forbidden = [
        'cad_runtime',
        'cad_kernel',
        'cad_document/repository',
        'opencascade',
        'sketch_engine',
        'sketch_assistant',
        'operational_reverse_engineering_controller',
        'desktop_command_coordinator',
        'desktop_cad_controller',
        'engineering_bootstrap',
        'flutter/material',
        'flutter/widgets',
      ];
      final offenders = <String>[];
      for (final entity in moduleDirectory.listSync()) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final line in entity.readAsLinesSync()) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('import ')) continue;
          for (final needle in forbidden) {
            if (trimmed.contains(needle)) {
              offenders.add('${entity.path}: $trimmed');
            }
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });
}

String _directoryFingerprint(Directory directory) {
  final entries = <String>[];
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = entity.path.substring(directory.path.length);
    entries.add('$relative:${entity.lengthSync()}:${_hash(entity)}');
  }
  entries.sort();
  return entries.join('\n');
}

String _hash(File file) => base64Encode(utf8.encode(file.readAsStringSync()));
