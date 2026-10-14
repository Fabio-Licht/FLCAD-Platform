import 'dart:io';

import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/panels/multi_window_panel_transport.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_bridge.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_protocol.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_session_source.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_shell.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_view_model.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_window_backend.dart';
import 'package:flcad_mobile/app/operational_entities/operational_entity.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/cad_document_repository.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// G124-UX.MM4.1B: the detached Explorer must follow the *documental* selection
/// no matter which UI path changed it, and a geometric sub-element selection
/// must never be promoted into the documental selection.
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

void main() {
  late Directory root;
  late CadRuntime runtime;
  late LoopbackPanelWindowBackend backend;
  late MultiWindowPanelTransport mainTransport;
  late PanelBridge bridge;
  late PanelShellEndpoint shell;

  /// Wires the MM3 bridge on top of the *real* runtime session source, exactly
  /// like the workspace does (loopback transport instead of native windows).
  Future<void> connect() async {
    backend = LoopbackPanelWindowBackend();
    mainTransport = MultiWindowPanelTransport(
      backend: backend,
      isMainWindow: true,
      panelWindowIdResolver: (_) => 'window-1',
    );
    bridge = PanelBridge(
      transport: mainTransport,
      source: CadRuntimePanelSessionSource(runtime),
    )..start();
    final panelTransport = MultiWindowPanelTransport(
      backend: backend,
      isMainWindow: false,
      windowId: 'window-1',
    );
    shell = PanelShellEndpoint(
      panelId: PanelId.explorer,
      transport: panelTransport,
      capabilities: const [
        PanelCapabilities.explorer,
        PanelCapabilities.selection,
      ],
    );
    await mainTransport.ready;
    await pumpEventQueue();
    shell.connect();
    await panelTransport.ready;
    await pumpEventQueue();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mm4b-selection-');
    runtime = CadRuntime(kernels: KernelManager(), repository: _Repository());
    await runtime.open('A', root);
    await runtime.mutate(command: 'seed', upsert: [_point('p1')]);
    await connect();
  });

  tearDown(() async {
    bridge.dispose();
    await mainTransport.close();
    await runtime.shutdown();
    await root.delete(recursive: true);
  });

  test('a selection made through the manager reaches the panel', () async {
    expect(shell.viewModel[PanelViewModelKeys.selection], isEmpty);

    // This is the viewport pick / Explorer row / entity list path: the managers
    // are changed directly, without going through `runtime.select`.
    runtime.geometrySelection.select('p1');
    await pumpEventQueue();

    expect(runtime.selection, {'p1'});
    expect(
      shell.viewModel[PanelViewModelKeys.selection],
      ['p1'],
      reason: 'o painel destacado não pode ficar com seleção obsoleta',
    );
  });

  test('clearing the selection is published too', () async {
    runtime.geometrySelection.select('p1');
    await pumpEventQueue();
    expect(shell.viewModel[PanelViewModelKeys.selection], ['p1']);

    runtime.geometrySelection.clear();
    await pumpEventQueue();

    expect(shell.viewModel[PanelViewModelKeys.selection], isEmpty);
  });

  test('runtime.select keeps working (no regression)', () async {
    runtime.select({'p1'});
    await pumpEventQueue();

    expect(shell.viewModel[PanelViewModelKeys.selection], ['p1']);
  });

  test('one selection change notifies the runtime exactly once', () async {
    var notifications = 0;
    void listener() => notifications++;
    runtime.addListener(listener);
    addTearDown(() => runtime.removeListener(listener));

    runtime.geometrySelection.select('p1');
    await pumpEventQueue();

    expect(
      notifications,
      1,
      reason: 'encaminhamento único: sem listeners duplicados',
    );
  });

  test('a sub-element selection never becomes the documental selection', () async {
    runtime.geometrySelection.select('p1');
    await pumpEventQueue();

    runtime.operationalEntities.replaceOwner('p1', [
      const OperationalEntity(
        id: 'region:1',
        type: OperationalEntityType.meshRegion,
        ownerId: 'p1',
        ownerDomain: 'mesh',
        documentId: 'p1',
        revision: 1,
        label: 'Região 1',
        capabilities: {OperationalCapability.selectable},
        properties: {},
      ),
    ]);
    runtime.operationalSelection.select('region:1');
    await pumpEventQueue();

    expect(runtime.operationalSelection.activeId, 'region:1');
    expect(
      runtime.selection,
      {'p1'},
      reason: 'subelemento operacional não vira entidade documental',
    );
    expect(
      shell.viewModel[PanelViewModelKeys.selection],
      ['p1'],
      reason: 'a projeção do Explorer mantém apenas a seleção documental',
    );
  });
}
