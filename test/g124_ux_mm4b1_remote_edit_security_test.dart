import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/panels/multi_window_panel_transport.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_bridge.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_protocol.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_session_source.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_shell.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_window_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<
    ({
      LoopbackPanelWindowBackend backend,
      FakePanelSessionSource source,
      PanelBridge bridge,
      PanelShellEndpoint inspector,
      PanelShellEndpoint explorer,
      MultiWindowPanelTransport inspectorTransport,
    })
  >
  harness({Future<void> Function(String, double)? edit}) async {
    final backend = LoopbackPanelWindowBackend();
    final source = FakePanelSessionSource(
      projectId: 'project-1',
      entities: const [
        (id: 'dim-1', kind: 'dimension', label: 'Width', visible: true),
      ],
      dimensionEditGate: edit,
    );
    final main = MultiWindowPanelTransport(
      backend: backend,
      isMainWindow: true,
      panelWindowIdResolver: (panelId) => panelId == PanelId.inspector.name
          ? 'inspector-window'
          : 'explorer-window',
    );
    final bridge = PanelBridge(transport: main, source: source)..start();
    await main.ready;
    final inspectorTransport = MultiWindowPanelTransport(
      backend: backend,
      isMainWindow: false,
      windowId: 'inspector-window',
    );
    final inspector = PanelShellEndpoint(
      panelId: PanelId.inspector,
      transport: inspectorTransport,
      capabilities: const [PanelCapabilities.inspectorEdit],
    );
    final explorerTransport = MultiWindowPanelTransport(
      backend: backend,
      isMainWindow: false,
      windowId: 'explorer-window',
    );
    final explorer = PanelShellEndpoint(
      panelId: PanelId.explorer,
      transport: explorerTransport,
      capabilities: const [PanelCapabilities.explorer],
    );
    inspector.connect();
    explorer.connect();
    await pumpEventQueue();
    await inspectorTransport.ready;
    await explorerTransport.ready;
    inspector.connect(resync: true);
    explorer.connect(resync: true);
    await pumpEventQueue();
    return (
      backend: backend,
      source: source,
      bridge: bridge,
      inspector: inspector,
      explorer: explorer,
      inspectorTransport: inspectorTransport,
    );
  }

  tearDown(() {});

  test('whitelist rejects an unauthorized inspector edit', () {
    expect(
      () => validatePanelAction(
        action: panelActionInspectorDimensionEdit,
        params: {'entityId': 'dim-1', 'value': 2.0},
        grantedCapabilities: const {PanelCapabilities.explorer},
      ),
      throwsA(
        isA<PanelProtocolException>().having(
          (error) => error.code,
          'code',
          PanelErrorCode.unauthorizedCapability,
        ),
      ),
    );
  });

  test('whitelist rejects invalid typed parameters', () {
    expect(
      () => validatePanelAction(
        action: panelActionInspectorDimensionEdit,
        params: {'entityId': 'dim-1', 'value': double.nan},
        grantedCapabilities: const {PanelCapabilities.inspectorEdit},
      ),
      throwsA(
        isA<PanelProtocolException>().having(
          (error) => error.code,
          'code',
          PanelErrorCode.invalidPayload,
        ),
      ),
    );
  });

  test('valid edit reaches the main transaction callback once', () async {
    final calls = <({String id, double value})>[];
    final h = await harness(
      edit: (id, value) async => calls.add((id: id, value: value)),
    );
    addTearDown(() {
      h.inspector.dispose();
      h.explorer.dispose();
      h.bridge.dispose();
    });

    await h.inspector.editDrivingDimension(entityId: 'dim-1', value: 2.5);
    await pumpEventQueue();

    expect(calls, [(id: 'dim-1', value: 2.5)]);
    expect(h.inspector.results.last.ok, isTrue);
    expect(h.source.appliedDimensionEdits, [(id: 'dim-1', value: 2.5)]);
  });

  test('session, project and base revision mismatches are rejected', () async {
    final h = await harness(edit: (_, _) async {});
    addTearDown(() {
      h.inspector.dispose();
      h.explorer.dispose();
      h.bridge.dispose();
    });

    // The endpoint's session/project/revision are authoritative after hello;
    // use direct transport messages to exercise forged values.
    final transport = h.inspectorTransport;
    transport.sendToMain(
      PanelId.inspector.name,
      PanelIntent(
        panelId: PanelId.inspector,
        sessionId: h.inspector.sessionId! + 1,
        projectId: h.inspector.projectId,
        action: panelActionInspectorDimensionEdit,
        params: const {'entityId': 'dim-1', 'value': 3.0},
        requestId: 'stale-session',
        baseRevision: h.inspector.revision,
      ).toJson(),
    );
    transport.sendToMain(
      PanelId.inspector.name,
      PanelIntent(
        panelId: PanelId.inspector,
        sessionId: h.inspector.sessionId!,
        projectId: 'other-project',
        action: panelActionInspectorDimensionEdit,
        params: const {'entityId': 'dim-1', 'value': 3.0},
        requestId: 'stale-project',
        baseRevision: h.inspector.revision,
      ).toJson(),
    );
    transport.sendToMain(
      PanelId.inspector.name,
      PanelIntent(
        panelId: PanelId.inspector,
        sessionId: h.inspector.sessionId!,
        projectId: h.inspector.projectId,
        action: panelActionInspectorDimensionEdit,
        params: const {'entityId': 'dim-1', 'value': 3.0},
        requestId: 'stale-revision',
        baseRevision: h.inspector.revision - 1,
      ).toJson(),
    );
    await pumpEventQueue();

    expect(
      h.inspector.results
          .where((result) => result.requestId == 'stale-session')
          .single
          .errorCode,
      PanelErrorCode.staleSession,
    );
    expect(
      h.inspector.results
          .where((result) => result.requestId == 'stale-project')
          .single
          .errorCode,
      PanelErrorCode.staleProject,
    );
    expect(
      h.inspector.results
          .where((result) => result.requestId == 'stale-revision')
          .single
          .errorCode,
      PanelErrorCode.outOfOrderRevision,
    );
  });

  test('duplicate and conflicting requestIds never double-apply', () async {
    var count = 0;
    final h = await harness(edit: (_, _) async => count++);
    addTearDown(() {
      h.inspector.dispose();
      h.explorer.dispose();
      h.bridge.dispose();
    });

    final request = PanelIntent(
      panelId: PanelId.inspector,
      sessionId: h.inspector.sessionId!,
      projectId: h.inspector.projectId,
      action: panelActionInspectorDimensionEdit,
      params: const {'entityId': 'dim-1', 'value': 4.0},
      requestId: 'same-request',
      baseRevision: h.inspector.revision,
    );
    h.inspectorTransport.sendToMain(PanelId.inspector.name, request.toJson());
    await pumpEventQueue();
    final replay = request.toJson();
    h.inspectorTransport.sendToMain(PanelId.inspector.name, replay);
    final conflict = request.toJson()
      ..['params'] = const {'entityId': 'dim-1', 'value': 5.0};
    h.inspectorTransport.sendToMain(PanelId.inspector.name, conflict);
    await pumpEventQueue();

    expect(count, 1);
    expect(
      h.inspector.results.last.errorCode,
      PanelErrorCode.conflictingRequestId,
    );
  });

  test(
    'deleted entity and transaction failure are reported without mutation',
    () async {
      final h = await harness(
        edit: (id, _) async {
          if (id != 'dim-1') throw StateError('entity deleted');
          throw StateError('transaction failed');
        },
      );
      addTearDown(() {
        h.inspector.dispose();
        h.explorer.dispose();
        h.bridge.dispose();
      });

      await h.inspector.editDrivingDimension(entityId: 'deleted', value: 2);
      await pumpEventQueue();
      expect(h.inspector.results.last.errorCode, PanelErrorCode.internalError);
      expect(h.source.appliedDimensionEdits, isEmpty);
    },
  );

  test('inspector edit capability never crosses into Explorer', () async {
    final h = await harness(edit: (_, _) async {});
    addTearDown(() {
      h.inspector.dispose();
      h.explorer.dispose();
      h.bridge.dispose();
    });

    await h.inspector.editDrivingDimension(entityId: 'dim-1', value: 6);
    await pumpEventQueue();

    expect(h.explorer.results, isEmpty);
    expect(h.source.appliedDimensionEdits, [(id: 'dim-1', value: 6.0)]);
  });
}
