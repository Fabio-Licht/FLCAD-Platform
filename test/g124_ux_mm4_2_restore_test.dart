import 'dart:io';

import 'package:flcad_mobile/core/adaptive_studio/models/adaptive_studio_models.dart';
import 'package:flcad_mobile/app/desktop/layout/display_service.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_migration.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_presets.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_store.dart';
import 'package:flcad_mobile/app/desktop/panels/multi_window_panel_transport.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_bridge.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_protocol.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_session_source.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_shell.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_view_model.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_window_backend.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_window_host.dart';
import 'package:flcad_mobile/app/operational_entities/operational_entity.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/cad_document_repository.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mm2_layout_harness.dart';

/// G124-UX.MM4.2: the Explorer the operator left detached must come back after
/// a restart, without duplicating windows and without reopening after an
/// explicit Dock.
class _Repository extends CadDocumentRepository {}

CadDocumentEntity _point(String id) => CadDocumentEntity(
  id: id,
  kind: CadDocumentEntityKind.vertex,
  data: {
    'sceneKind': 'point',
    'sceneGeometry': {
      'position': [0, 0, 0],
    },
  },
);

/// One Workspace session's panel wiring, mirroring what the shell does.
final class _Session {
  _Session({
    required this.backend,
    required this.transport,
    required this.bridge,
    required this.shell,
    required this.host,
  });

  final PanelWindowBackend backend;
  final MultiWindowPanelTransport transport;
  final PanelBridge bridge;
  final PanelShellEndpoint shell;
  final PanelWindowHost host;

  Future<void> close({bool persist = false}) async {
    if (host.hasAttachments) await host.dock(PanelId.explorer, persist: persist);
    bridge.dispose();
    await transport.close();
  }
}

Future<_Session> _startSession({
  required PanelLayoutStoreBase store,
  required PanelWindowBackend backend,
  DisplayService? displays,
  double devicePixelRatio = 1,
  PanelSessionSource? source,
}) async {
  final host = PanelWindowHost(
    backend: backend,
    layoutStore: store,
    displays: displays ?? dualDisplayDesktop(),
    devicePixelRatio: () => devicePixelRatio,
  );
  final transport = MultiWindowPanelTransport(
    backend: backend,
    isMainWindow: true,
    panelWindowIdResolver: (_) => host.attachmentFor(PanelId.explorer)?.windowId,
  );
  final bridge = PanelBridge(
    transport: transport,
    source: source ?? FakePanelSessionSource(projectId: 'project-1'),
  )..start();
  final panelTransport = MultiWindowPanelTransport(
    backend: backend,
    isMainWindow: false,
    windowId: 'loopback-window-1',
  );
  final shell = PanelShellEndpoint(
    panelId: PanelId.explorer,
    transport: panelTransport,
    capabilities: const [
      PanelCapabilities.explorer,
      PanelCapabilities.selection,
    ],
  );
  // The shell registers its channels before any window is materialised.
  await transport.ready;
  await pumpEventQueue();
  return _Session(
    backend: backend,
    transport: transport,
    bridge: bridge,
    shell: shell,
    host: host,
  );
}

Future<String?> _adoptableWindow(PanelWindowBackend backend) async {
  for (final window in await backend.listWindows()) {
    if (window.panelId == PanelId.explorer) return window.windowId;
  }
  return null;
}

void main() {
  group('restauração do Explorer', () {
    test('detach + encerramento da sessão + reinício restaura a janela',
        () async {
      final store = MemoryPanelLayoutStore();
      final backend = LoopbackPanelWindowBackend();
      final first = await _startSession(store: store, backend: backend);
      final attachment = await first.host.detach(
        PanelId.explorer,
        requestedGeometry: const PanelGeometry(
          left: 2000,
          top: 60,
          width: 340,
          height: 620,
        ),
      );
      expect(attachment, isNotNull);

      // Session teardown (shell closing / Workspace remount) keeps the
      // preference while the loopback closes the window.
      await first.close();
      expect(first.host.preservedPreferenceDocks, 1);
      expect((await store.load()).layout.entryFor(PanelId.explorer).isDetached,
          isTrue);

      // Restart: a new session, a fresh window list.
      final restartBackend = LoopbackPanelWindowBackend();
      final store2 = MemoryPanelLayoutStore();
      await store2.save((await store.load()).layout);
      final second = await _startSession(store: store2, backend: restartBackend);
      expect(
        await PanelWindowHost.hasDetachedPreference(
          store2,
          panelId: PanelId.explorer,
          displays: dualDisplayDesktop(),
        ),
        isTrue,
      );

      final restored = await second.host.restorePersisted(PanelId.explorer);

      expect(restored, isNotNull);
      expect(restartBackend.createdWindows, hasLength(1));
      expect(restored!.geometry.left, 2000);
      await second.close();
    });

    test('Dock explícito não reabre na próxima sessão', () async {
      final store = MemoryPanelLayoutStore();
      final backend = LoopbackPanelWindowBackend();
      final first = await _startSession(store: store, backend: backend);
      await first.host.detach(
        PanelId.explorer,
        requestedGeometry: const PanelGeometry(
          left: 2000,
          top: 60,
          width: 340,
          height: 620,
        ),
      );

      final docked = await first.host.dock(PanelId.explorer);
      expect(docked, isTrue);
      expect(first.host.preservedPreferenceDocks, 0);
      expect((await store.load()).layout.entryFor(PanelId.explorer).isDetached,
          isFalse);
      await first.close();

      final restart = LoopbackPanelWindowBackend();
      expect(
        await PanelWindowHost.hasDetachedPreference(
          store,
          panelId: PanelId.explorer,
          displays: dualDisplayDesktop(),
        ),
        isFalse,
      );
      final second = await _startSession(store: store, backend: restart);
      expect(await second.host.restorePersisted(PanelId.explorer), isNull);
      expect(restart.createdWindows, isEmpty);
      await second.close();
    });

    test('reinício após encerramento inesperado restaura (arquivo intacto)',
        () async {
      // The crash wrote nothing: the stored file still says "detached".
      final store = MemoryPanelLayoutStore();
      final layout = PanelLayoutPresets.singleMonitor().withEntry(
        PanelLayoutPresets.singleMonitor().entryFor(PanelId.explorer).copyWith(
          dockState: DockState.undocked,
          geometry: const PanelGeometry(
            left: 120,
            top: 120,
            width: 340,
            height: 620,
          ),
        ),
      );
      await store.save(layout);
      final backend = LoopbackPanelWindowBackend();
      final session = await _startSession(store: store, backend: backend);

      final restored = await session.host.restorePersisted(PanelId.explorer);

      expect(restored, isNotNull);
      expect(restored!.geometry.left, 120);
      await session.close();
    });

    test('remontagem adota a janela viva em vez de criar outra', () async {
      final store = MemoryPanelLayoutStore();
      // One backend models the process-wide window list: the window created by
      // the first session is still there when the second one starts.
      final backend = LoopbackPanelWindowBackend();
      final first = await _startSession(store: store, backend: backend);
      await first.host.detach(
        PanelId.explorer,
        requestedGeometry: const PanelGeometry(
          left: 2000,
          top: 60,
          width: 340,
          height: 620,
        ),
      );
      first.bridge.dispose();
      await first.transport.close();

      final second = await _startSession(store: store, backend: backend);
      final adopt = await _adoptableWindow(backend);
      expect(adopt, isNotNull, reason: 'a janela antiga ainda está aberta');
      final restored = await second.host.restorePersisted(
        PanelId.explorer,
        windowId: adopt,
      );

      expect(restored, isNotNull);
      expect(second.host.adoptedWindows, 1);
      expect(
        backend.createdWindows,
        hasLength(1),
        reason: 'nenhuma segunda janela foi materializada',
      );
      await second.close();
    });

    test('monitor ausente recua para a janela principal e volta na reconexão',
        () async {
      final store = MemoryPanelLayoutStore();
      final dual = dualDisplayDesktop();
      final backend = LoopbackPanelWindowBackend();
      final first = await _startSession(
        store: store,
        backend: backend,
        displays: dual,
      );
      await first.host.detach(
        PanelId.explorer,
        requestedGeometry: const PanelGeometry(
          left: 2000,
          top: 60,
          width: 340,
          height: 620,
        ),
      );
      await first.close();

      // Restart with a single screen: the panel comes back into the shell and
      // the stored preference survives for a future reconnection.
      final single = singleDisplayDesktop();
      expect(
        await PanelWindowHost.hasDetachedPreference(
          store,
          panelId: PanelId.explorer,
          displays: single,
        ),
        isFalse,
      );
      final stored = (await store.load()).layout;
      expect(stored.entryFor(PanelId.explorer).isDetached, isTrue,
          reason: 'a preferência persistida continua destacada');

      // Second screen back: the same stored layout now restores the window.
      expect(
        await PanelWindowHost.hasDetachedPreference(
          store,
          panelId: PanelId.explorer,
          displays: dualDisplayDesktop(),
        ),
        isTrue,
      );
    });

    test('DPI alterado converte a geometria persistida', () async {
      final store = MemoryPanelLayoutStore();
      final backend = LoopbackPanelWindowBackend();
      final session = await _startSession(
        store: store,
        backend: backend,
        devicePixelRatio: 2,
      );
      final attachment = await session.host.detach(
        PanelId.explorer,
        requestedGeometry: const PanelGeometry(
          left: 2000,
          top: 60,
          width: 340,
          height: 620,
        ),
      );
      expect(
        backend.windowBounds[attachment!.windowId],
        const RectData(left: 1000, top: 30, width: 170, height: 310),
      );
      await session.close();
    });

    test('falha ao criar a janela preserva a preferência e não deixa órfão',
        () async {
      final store = MemoryPanelLayoutStore();
      final backend = LoopbackPanelWindowBackend()..failCreateWindows = true;
      final session = await _startSession(store: store, backend: backend);

      final restored = await session.host.restorePersisted(PanelId.explorer);

      expect(restored, isNull);
      expect(session.host.hasAttachments, isFalse);
      expect(backend.createdWindows, isEmpty);
      expect(backend.listWindowIds(), completion(isEmpty));
      await session.close();
    });

    test('layout de versão futura é respeitado (nenhuma janela)', () async {
      final store = _FutureVersionStore();
      expect(
        await PanelWindowHost.hasDetachedPreference(
          store,
          panelId: PanelId.explorer,
          displays: dualDisplayDesktop(),
        ),
        isFalse,
      );
    });

    test('layout corrompido cai no padrão sem janela', () async {
      final directory = await Directory.systemTemp.createTemp('mm42-corrupt-');
      addTearDown(() => directory.delete(recursive: true));
      final store = PanelLayoutStore(
        File('${directory.path}/${PanelLayoutStore.fileName}'),
        fileSystem: FaultyLayoutFileSystem(failRead: true),
      );
      expect(
        await PanelWindowHost.hasDetachedPreference(
          store,
          panelId: PanelId.explorer,
          displays: dualDisplayDesktop(),
        ),
        isFalse,
      );
    });

    test('projeto ainda carregando: restaura e sincroniza quando abre',
        () async {
      final root = await Directory.systemTemp.createTemp('mm42-runtime-');
      final runtime = CadRuntime(
        kernels: KernelManager(),
        repository: _Repository(),
      );
      addTearDown(() async {
        await runtime.shutdown();
        await root.delete(recursive: true);
      });
      final store = MemoryPanelLayoutStore();
      await store.save(
        PanelLayoutPresets.singleMonitor().withEntry(
          PanelLayoutPresets.singleMonitor()
              .entryFor(PanelId.explorer)
              .copyWith(
                dockState: DockState.undocked,
                geometry: const PanelGeometry(
                  left: 120,
                  top: 120,
                  width: 340,
                  height: 620,
                ),
              ),
        ),
      );
      final backend = LoopbackPanelWindowBackend();
      final session = await _startSession(
        store: store,
        backend: backend,
        source: CadRuntimePanelSessionSource(runtime),
      );

      // No document yet: the restore still materialises the window.
      final restored = await session.host.restorePersisted(PanelId.explorer);
      expect(restored, isNotNull);
      session.shell.connect();
      await pumpEventQueue();
      expect(
        session.shell.lifecycle,
        anyOf(PanelLifecycleState.connected, PanelLifecycleState.suspended),
      );

      // Opening a project publishes the projection to the restored window.
      await runtime.open('A', root);
      await runtime.mutate(command: 'seed', upsert: [_point('p1')]);
      await pumpEventQueue();
      expect(session.shell.lifecycle, PanelLifecycleState.ready);
      expect(
        (session.shell.viewModel[PanelViewModelKeys.entities]! as List),
        isNotEmpty,
        reason: 'a janela restaurada recebe o documento quando ele abre',
      );
      expect(session.bridge.connectionFor(PanelId.explorer), isNotNull);

      await session.close();
    });

    test('teardown de sessão não deixa handlers ou janelas para trás',
        () async {
      final store = MemoryPanelLayoutStore();
      final backend = LoopbackPanelWindowBackend();
      final session = await _startSession(store: store, backend: backend);
      await session.host.detach(
        PanelId.explorer,
        requestedGeometry: const PanelGeometry(
          left: 2000,
          top: 60,
          width: 340,
          height: 620,
        ),
      );
      await session.close();

      expect(backend.listWindowIds(), completion(isEmpty));
      expect(backend.registeredHandlers, 0);
      expect(session.host.hasAttachments, isFalse);
      // The preference survives for the next session.
      expect((await store.load()).layout.entryFor(PanelId.explorer).isDetached,
          isTrue);
    });
  });

  test('seleção de subelemento não interfere na restauração', () async {
    final runtime = CadRuntime(
      kernels: KernelManager(),
      repository: _Repository(),
    );
    addTearDown(runtime.shutdown);
    runtime.operationalEntities.replaceOwner('missing', [
      const OperationalEntity(
        id: 'region:1',
        type: OperationalEntityType.meshRegion,
        ownerId: 'missing',
        ownerDomain: 'mesh',
        documentId: 'missing',
        revision: 1,
        label: 'Região 1',
        capabilities: {OperationalCapability.selectable},
        properties: {},
      ),
    ]);
    runtime.operationalSelection.select('region:1');
    expect(runtime.selection, isEmpty);
    expect(runtime.operationalSelection.activeId, 'region:1');
  });
}

/// A layout file written by a newer version is loaded read-only.
class _FutureVersionStore extends PanelLayoutStoreBase {
  @override
  Future<PanelLayoutLoadResult> load() async => PanelLayoutLoadResult(
    layout: PanelLayoutPresets.singleMonitor().withEntry(
      PanelLayoutPresets.singleMonitor().entryFor(PanelId.explorer).copyWith(
        dockState: DockState.undocked,
        geometry: const PanelGeometry(
          left: 120,
          top: 120,
          width: 340,
          height: 620,
        ),
      ),
    ),
    migration: PanelLayoutMigrationReport(),
    readOnly: true,
  );

  @override
  Future<void> save(PanelLayout layout, {bool force = false}) async {
    fail('um layout de versão futura nunca deve ser gravado');
  }

  @override
  Future<bool> delete() async => false;
}
