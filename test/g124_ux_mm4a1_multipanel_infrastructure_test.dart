import 'package:flcad_mobile/app/desktop/layout/display_service.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_store.dart';
import 'package:flcad_mobile/app/desktop/panels/multi_window_panel_transport.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_bridge.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_protocol.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_session_source.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_shell.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_window_backend.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_window_host.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mm2_layout_harness.dart';

void main() {
  PanelWindowHost makeHost(
    LoopbackPanelWindowBackend backend,
    MemoryPanelLayoutStore store,
    FakeDisplayService displays,
  ) =>
      PanelWindowHost(backend: backend, layoutStore: store, displays: displays);

  const geometry = PanelGeometry(left: 1960, top: 60, width: 340, height: 620);

  group('MM4.3a.1 infraestrutura multipainel', () {
    test('mantém attachments independentes por PanelId', () async {
      final backend = LoopbackPanelWindowBackend();
      final store = MemoryPanelLayoutStore();
      final desktop = dualDisplayDesktop();
      final host = makeHost(backend, store, desktop);

      final explorer = await host.detach(
        PanelId.explorer,
        requestedGeometry: geometry,
      );
      final inspector = await host.detach(
        PanelId.inspector,
        requestedGeometry: geometry,
      );

      expect(explorer, isNotNull);
      expect(inspector, isNotNull);
      expect(explorer!.windowId, isNot(inspector!.windowId));
      expect(host.attachmentFor(PanelId.explorer), explorer);
      expect(host.attachmentFor(PanelId.inspector), inspector);
      expect(host.attachmentForWindow(explorer.windowId), explorer);
      expect(host.attachmentForWindow(inspector.windowId), inspector);

      await host.dock(PanelId.explorer);
      expect(host.attachmentFor(PanelId.explorer), isNull);
      expect(host.attachmentFor(PanelId.inspector), inspector);
      expect(
        (await store.load()).layout.entryFor(PanelId.inspector).isDetached,
        isTrue,
      );
    });

    test('restauração é idempotente e rejeita adoção cruzada', () async {
      final backend = LoopbackPanelWindowBackend();
      final store = MemoryPanelLayoutStore();
      final host = makeHost(backend, store, dualDisplayDesktop());
      final explorer = await host.detach(
        PanelId.explorer,
        requestedGeometry: geometry,
      );
      final inspector = await host.detach(
        PanelId.inspector,
        requestedGeometry: geometry,
      );

      final same = await host.restorePersisted(
        PanelId.explorer,
        windowId: explorer!.windowId,
      );
      expect(same, explorer);
      expect(host.attachments, hasLength(2));

      final crossAdoption = await host.restorePersisted(
        PanelId.explorer,
        windowId: inspector!.windowId,
      );
      expect(crossAdoption, isNull);
      expect(host.attachmentFor(PanelId.explorer), explorer);
      expect(host.attachmentFor(PanelId.inspector), inspector);
    });

    test('canais e sessões permanecem independentes por painel', () async {
      final backend = LoopbackPanelWindowBackend();
      final store = MemoryPanelLayoutStore();
      final host = makeHost(backend, store, dualDisplayDesktop());
      final explorer = await host.detach(
        PanelId.explorer,
        requestedGeometry: geometry,
      );
      final inspector = await host.detach(
        PanelId.inspector,
        requestedGeometry: geometry,
      );
      final source = FakePanelSessionSource(
        projectId: 'project-1',
        entities: const [
          (id: 'sketch:1', kind: 'sketch', label: 'Sketch', visible: true),
          (id: 'import:1', kind: 'import', label: 'Import', visible: true),
        ],
      );
      final mainTransport = MultiWindowPanelTransport(
        backend: backend,
        isMainWindow: true,
        panelWindowIdResolver: (panelId) =>
            host.attachmentFor(panelIdFromName(panelId)!)?.windowId,
      );
      final bridge = PanelBridge(transport: mainTransport, source: source)
        ..start();
      final explorerTransport = MultiWindowPanelTransport(
        backend: backend,
        isMainWindow: false,
        windowId: explorer!.windowId,
      );
      final inspectorTransport = MultiWindowPanelTransport(
        backend: backend,
        isMainWindow: false,
        windowId: inspector!.windowId,
      );
      final explorerShell = PanelShellEndpoint(
        panelId: PanelId.explorer,
        transport: explorerTransport,
        capabilities: const [
          PanelCapabilities.explorer,
          PanelCapabilities.selection,
        ],
      );
      final inspectorShell = PanelShellEndpoint(
        panelId: PanelId.inspector,
        transport: inspectorTransport,
        capabilities: const [],
      );
      addTearDown(() {
        explorerShell.dispose();
        inspectorShell.dispose();
        bridge.dispose();
      });

      explorerShell.connect();
      inspectorShell.connect();
      await pumpEventQueue();

      expect(explorerShell.viewModel[PanelViewModelKeys.panelId], 'explorer');
      expect(inspectorShell.viewModel[PanelViewModelKeys.panelId], 'inspector');
      expect(explorerShell.sessionId, inspectorShell.sessionId);

      source.setSelection(['sketch:1']);
      await pumpEventQueue();
      expect(explorerShell.viewModel[PanelViewModelKeys.selection], [
        'sketch:1',
      ]);
      expect(inspectorShell.viewModel[PanelViewModelKeys.selection], [
        'sketch:1',
      ]);

      // A message addressed to the other panel reaches the Explorer channel,
      // but the endpoint rejects it by identity instead of applying it.
      mainTransport.sendToPanel(
        PanelId.explorer.name,
        PanelSnapshot(
          panelId: PanelId.inspector,
          sessionId: inspectorShell.sessionId!,
          revision: inspectorShell.revision + 1,
          projectId: 'project-1',
          viewModel: const {
            PanelViewModelKeys.selection: ['import:1'],
          },
        ).toJson(),
      );
      await pumpEventQueue();
      expect(explorerShell.viewModel[PanelViewModelKeys.selection], [
        'sketch:1',
      ]);
      expect(inspectorShell.viewModel[PanelViewModelKeys.selection], [
        'sketch:1',
      ]);
    });

    test(
      'monitor removido recupera todos os painéis sem cruzar identidades',
      () async {
        final backend = LoopbackPanelWindowBackend();
        final store = MemoryPanelLayoutStore();
        final desktop = dualDisplayDesktop();
        final host = makeHost(backend, store, desktop);
        await host.detach(PanelId.explorer, requestedGeometry: geometry);
        await host.detach(PanelId.inspector, requestedGeometry: geometry);

        desktop.replaceDisplays([desktop.displays.first]);
        final recovered = await host.reconcileDisplays();

        expect(
          recovered,
          containsAll(<PanelId>[PanelId.explorer, PanelId.inspector]),
        );
        expect(host.attachments, isEmpty);
        final layout = await store.load();
        expect(layout.layout.entryFor(PanelId.explorer).isDetached, isFalse);
        expect(layout.layout.entryFor(PanelId.inspector).isDetached, isFalse);
      },
    );
  });
}
