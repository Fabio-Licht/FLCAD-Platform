import 'dart:convert';
import 'dart:io';

import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_host_gateway.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_presets.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_bridge.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_protocol.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_session_source.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_shell.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_transport.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mm2_layout_harness.dart';

/// Two-endpoint harness: main process (bridge) and panel shell.
({
  InMemoryPanelTransport transport,
  PanelBridge bridge,
  FakePanelSessionSource source,
  PanelShellEndpoint shell,
})
harness({
  String? projectId = 'project-1',
  int sessionId = 1,
  List<({String id, String kind, String label, bool visible})> entities =
      const [
        (id: 'sketch:1', kind: 'sketch', label: 'Sketch 1', visible: true),
        (id: 'import:1', kind: 'import', label: 'CALOTA', visible: true),
      ],
  bool supportsVisibility = true,
  Future<void> Function(Set<String> ids)? selectionGate,
  Future<void> Function(String id, bool visible)? visibilityGate,
}) {
  final transport = InMemoryPanelTransport();
  final source = FakePanelSessionSource(
    projectId: projectId,
    sessionId: sessionId,
    entities: entities,
    supportsVisibility: supportsVisibility,
    selectionGate: selectionGate,
    visibilityGate: visibilityGate,
  );
  final bridge = PanelBridge(transport: transport, source: source)..start();
  final shell = PanelShellEndpoint(
    panelId: PanelId.explorer,
    transport: transport,
  );
  return (transport: transport, bridge: bridge, source: source, shell: shell);
}

void main() {
  group('handshake', () {
    test('accepts a compatible version and sends ready + full snapshot', () {
      final h = harness();
      addTearDown(h.bridge.dispose);

      h.shell.connect();

      expect(h.shell.lifecycle, PanelLifecycleState.ready);
      expect(h.shell.sessionId, 1);
      expect(h.shell.projectId, 'project-1');
      expect(h.shell.revision, 1);
      expect(h.shell.viewModelIsStale, isFalse);
      final snapshot = h.transport.toPanelOfType('snapshot').single;
      expect(snapshot['full'], isTrue);
      expect(snapshot['revision'], 1);
      final viewModel = snapshot['viewModel']! as Map<String, Object?>;
      expect((viewModel[PanelViewModelKeys.entities]! as List).length, 2);
      expect(viewModel[PanelViewModelKeys.groups], {'import': 1, 'sketch': 1});
      expect(viewModel[PanelViewModelKeys.empty], isFalse);
      expect(
        h.bridge.connectionFor(PanelId.explorer)!.capabilities,
        PanelCapabilities.all.toSet(),
      );
    });

    test('rejects a newer major and a newer minor version', () {
      for (final version in const [
        PanelProtocolVersion(2, 0),
        PanelProtocolVersion(1, 5),
        PanelProtocolVersion(0, 9),
      ]) {
        final transport = InMemoryPanelTransport();
        final bridge = PanelBridge(
          transport: transport,
          source: FakePanelSessionSource(projectId: 'p'),
        )..start();
        addTearDown(bridge.dispose);
        final shell = PanelShellEndpoint(
          panelId: PanelId.explorer,
          transport: transport,
          protocolVersion: version,
        );

        expect(
          () => shell.connect(),
          throwsA(
            isA<PanelProtocolException>().having(
              (error) => error.code,
              'code',
              PanelErrorCode.unsupportedVersion,
            ),
          ),
        );
        expect(shell.lifecycle, PanelLifecycleState.disconnected);
        expect(
          transport.toPanelOfType('snapshot'),
          isEmpty,
          reason: 'versão incompatível não recebe projeção',
        );
      }
    });

    test('a panel without a project connects but stays empty', () {
      final h = harness(projectId: null);
      addTearDown(h.bridge.dispose);

      h.shell.connect();

      expect(h.shell.lifecycle, PanelLifecycleState.connected);
      expect(h.shell.projectId, isNull);
      expect(h.shell.viewModel[PanelViewModelKeys.empty], isTrue);
    });
  });

  group('snapshots and revisions', () {
    test('coalesces main-side changes without losing the final state', () {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();
      final before = h.transport.toPanelOfType('snapshot').length;

      // Three rapid main-side changes must merge into a single delivery.
      h.source.setSelection(['sketch:1']);
      h.source.setSelection(['import:1']);
      h.source.setSelection(['sketch:1', 'import:1']);
      h.bridge.flushPending();

      final delivered = h.transport.toPanelOfType('snapshot').toList();
      expect(delivered.length, before + 1);
      final patch = delivered.last;
      expect(patch['full'], isFalse);
      expect(patch['changedKeys'], contains(PanelViewModelKeys.selection));
      expect(
        (patch['viewModel']!
            as Map<String, Object?>)[PanelViewModelKeys.selection],
        ['import:1', 'sketch:1'],
      );
      expect(h.shell.viewModel[PanelViewModelKeys.selection], [
        'import:1',
        'sketch:1',
      ]);
      expect(h.shell.revision, 2);
    });

    test('incremental patches keep the parts they do not carry', () {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      h.source.addEntity(id: 'sketch:2', label: 'Sketch 2');
      h.bridge.flushPending();

      final patch = h.transport.toPanelOfType('snapshot').last;
      expect(patch['changedKeys'], contains(PanelViewModelKeys.entities));
      expect(
        (h.shell.viewModel[PanelViewModelKeys.entities]! as List).length,
        3,
      );
      // Untouched keys survive the patch.
      expect(h.shell.viewModel[PanelViewModelKeys.projectId], 'project-1');
      expect(h.shell.viewModel[PanelViewModelKeys.groups], {
        'import': 1,
        'sketch': 2,
      });
    });

    test('a stale revision is dropped and a gap triggers a full resync', () {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      // Out-of-order patch (older revision) is ignored.
      h.transport.sendToPanel(PanelId.explorer.name, {
        'type': 'snapshot',
        'panelId': PanelId.explorer.name,
        'sessionId': 1,
        'projectId': 'project-1',
        'revision': h.shell.revision,
        'full': false,
        'changedKeys': [PanelViewModelKeys.selection],
        'viewModel': {
          PanelViewModelKeys.selection: ['antigo'],
        },
      });
      expect(h.shell.droppedOutOfOrderSnapshots, 1);
      expect(
        h.shell.viewModel[PanelViewModelKeys.selection],
        isNot(['antigo']),
      );

      // A gap asks for a full snapshot instead of applying a partial state.
      h.transport.sendToPanel(PanelId.explorer.name, {
        'type': 'snapshot',
        'panelId': PanelId.explorer.name,
        'sessionId': 1,
        'projectId': 'project-1',
        'revision': h.shell.revision + 5,
        'full': false,
        'changedKeys': [PanelViewModelKeys.selection],
        'viewModel': {
          PanelViewModelKeys.selection: ['perdido'],
        },
      });
      expect(h.shell.resyncRequests, 1);
      expect(
        h.shell.viewModel[PanelViewModelKeys.selection],
        isNot(['perdido']),
      );
      // The resync answers with a brand new full snapshot.
      final full = h.transport.toPanelOfType('snapshot').last;
      expect(full['full'], isTrue);
      expect(h.shell.viewModelIsStale, isFalse);
    });
  });

  group('bidirectional selection', () {
    test('panel selection reaches the main session', () async {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      final requestId = await h.shell.setSelection(['sketch:1']);
      await pumpEventQueue();

      expect(h.source.appliedSelections, [
        {'sketch:1'},
      ]);
      final result = h.shell.results.single;
      expect(result.requestId, requestId);
      expect(result.ok, isTrue);
      expect(result.revision, isNotNull);
      // The panel already sees its own change.
      expect(h.shell.viewModel[PanelViewModelKeys.selection], ['sketch:1']);
    });

    test('main change is reflected in the panel', () {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      h.source.setSelection(['import:1']);
      h.bridge.flushPending();

      expect(h.shell.viewModel[PanelViewModelKeys.selection], ['import:1']);
    });

    test('no update loop between snapshots and intents', () async {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();
      final intentsAfterHandshake = h.transport.toMainOfType('intent').length;
      expect(intentsAfterHandshake, 0);

      h.source.setSelection(['sketch:1']);
      h.bridge.flushPending();
      h.source.setSelection(['import:1']);
      h.bridge.flushPending();
      expect(h.transport.toMainOfType('intent').length, 0);

      await h.shell.setSelection(['sketch:1']);
      await pumpEventQueue();

      expect(h.transport.toMainOfType('intent').length, 1);
      expect(h.transport.toPanelOfType('result').length, 1);
      expect(h.bridge.messageLoopsDetected, 0);
      expect(h.bridge.messageDepth, 0);
    });
  });

  group('intent validation', () {
    test('a duplicated requestId is answered from the cache', () async {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      final requestId = await h.shell.setSelection(['sketch:1']);
      await pumpEventQueue();
      // Resend the very same intent (transport retry).
      h.transport.sendToMain(PanelId.explorer.name, {
        'type': 'intent',
        'panelId': PanelId.explorer.name,
        'sessionId': 1,
        'projectId': 'project-1',
        'action': panelActionSelectionSet,
        'params': {
          'ids': ['sketch:1'],
        },
        'requestId': requestId,
      });
      await pumpEventQueue();

      expect(h.source.selectionApplications, 1);
      final results = h.shell.results;
      expect(results, hasLength(2));
      expect(results.last.replayed, isTrue);
      expect(results.last.ok, isTrue);
    });

    test('a requestId reused with another payload is refused', () async {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      final requestId = await h.shell.setSelection(['sketch:1']);
      await pumpEventQueue();

      Map<String, Object?> conflicting() => {
        'type': 'intent',
        'panelId': PanelId.explorer.name,
        'sessionId': 1,
        'projectId': 'project-1',
        'action': panelActionSelectionSet,
        'params': {
          'ids': ['import:1'],
        },
        'requestId': requestId,
      };

      h.transport.sendToMain(PanelId.explorer.name, conflicting());
      await pumpEventQueue();

      // The conflicting reuse never reached the session.
      expect(h.source.appliedSelections, [
        {'sketch:1'},
      ]);
      expect(
        h.transport.toPanelOfType('result').last['errorCode'],
        PanelErrorCode.conflictingRequestId.name,
      );

      // Retrying the very same (rejected) request replays the same answer.
      h.transport.sendToMain(PanelId.explorer.name, conflicting());
      await pumpEventQueue();
      expect(h.source.appliedSelections, hasLength(1));
      expect(h.transport.toPanelOfType('result').last['replayed'], isTrue);
      expect(h.transport.toPanelOfType('result').last['ok'], isFalse);
    });

    test(
      'unknown actions, bad payloads and missing capabilities are typed',
      () async {
        final h = harness();
        addTearDown(h.bridge.dispose);
        h.shell.connect();

        Future<PanelErrorCode?> send(
          String action,
          Map<String, Object?> params, {
          List<String> capabilities = PanelCapabilities.all,
        }) async {
          final transport = h.transport;
          final requestId =
              'probe-${action.hashCode}-${params.hashCode}-'
              '${capabilities.length}';
          transport.sendToMain(PanelId.explorer.name, {
            'type': 'intent',
            'panelId': PanelId.explorer.name,
            'sessionId': 1,
            'projectId': 'project-1',
            'action': action,
            'params': params,
            'requestId': requestId,
          });
          await pumpEventQueue();
          return h.shell.results.last.errorCode;
        }

        // Capability check happens against what the panel declared.
        final limited = harness();
        addTearDown(limited.bridge.dispose);
        PanelShellEndpoint(
          panelId: PanelId.inspector,
          transport: limited.transport,
          capabilities: const [PanelCapabilities.explorer],
        ).connect();
        limited.transport.sendToMain(PanelId.inspector.name, {
          'type': 'intent',
          'panelId': PanelId.inspector.name,
          'sessionId': 1,
          'projectId': 'project-1',
          'action': panelActionSelectionSet,
          'params': {
            'ids': ['sketch:1'],
          },
          'requestId': 'limited-1',
        });
        await pumpEventQueue();
        expect(
          limited.transport.toMainOfType('result'),
          isEmpty,
          reason: 'resultados voltam ao painel, não ao main',
        );
        expect(
          limited.transport.toPanelOfType('result').last['errorCode'],
          PanelErrorCode.unauthorizedCapability.name,
        );
        expect(limited.source.selectionApplications, 0);

        expect(
          await send('cad.execute.anything', const {}),
          PanelErrorCode.unknownAction,
        );
        expect(
          await send(panelActionSelectionSet, const {}),
          PanelErrorCode.invalidPayload,
        );
        expect(
          await send(panelActionSelectionSet, {
            'ids': ['a', 'a'],
          }),
          PanelErrorCode.invalidPayload,
        );
        expect(
          await send(panelActionSelectionSet, {
            'ids': ['sketch:1'],
            'extra': 1,
          }),
          PanelErrorCode.invalidPayload,
        );
        expect(
          await send(panelActionVisibilitySet, {
            'id': 'sketch:1',
            'visible': 'sim',
          }),
          PanelErrorCode.invalidPayload,
        );
        expect(h.source.selectionApplications, 0);
        expect(h.source.visibilityApplications, 0);
      },
    );

    test('oversized payloads and selections are refused', () async {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      final tooManyIds = [
        for (var index = 0; index < 600; index++) 'sketch:$index',
      ];
      h.transport.sendToMain(PanelId.explorer.name, {
        'type': 'intent',
        'panelId': PanelId.explorer.name,
        'sessionId': 1,
        'projectId': 'project-1',
        'action': panelActionSelectionSet,
        'params': {'ids': tooManyIds},
        'requestId': 'oversized-1',
      });
      await pumpEventQueue();
      expect(h.source.selectionApplications, 0);
      expect(
        h.transport.toPanelOfType('result').last['errorCode'],
        PanelErrorCode.payloadTooLarge.name,
      );

      // A raw message above the byte limit is rejected before parsing.
      final huge = jsonEncode({'type': 'intent', 'pad': 'x' * 70000});
      expect(
        () => decodePanelMessage(huge),
        throwsA(
          isA<PanelProtocolException>().having(
            (error) => error.code,
            'code',
            PanelErrorCode.payloadTooLarge,
          ),
        ),
      );
      expect(
        () => decodePanelMessage({'type': 'inventado'}),
        throwsA(
          isA<PanelProtocolException>().having(
            (error) => error.code,
            'code',
            PanelErrorCode.malformedMessage,
          ),
        ),
      );
    });
  });

  group('session lifecycle', () {
    test('an intent from an old session is refused', () async {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      h.transport.sendToMain(PanelId.explorer.name, {
        'type': 'intent',
        'panelId': PanelId.explorer.name,
        'sessionId': 999,
        'projectId': 'project-1',
        'action': panelActionSelectionSet,
        'params': {
          'ids': ['sketch:1'],
        },
        'requestId': 'old-session',
      });
      await pumpEventQueue();

      expect(h.source.selectionApplications, 0);
      expect(
        h.transport.toPanelOfType('result').last['errorCode'],
        PanelErrorCode.staleSession.name,
      );
    });

    test('an intent for another project is refused', () async {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      h.transport.sendToMain(PanelId.explorer.name, {
        'type': 'intent',
        'panelId': PanelId.explorer.name,
        'sessionId': 1,
        'projectId': 'outro-projeto',
        'action': panelActionSelectionSet,
        'params': {
          'ids': ['sketch:1'],
        },
        'requestId': 'other-project',
      });
      await pumpEventQueue();

      expect(h.source.selectionApplications, 0);
      expect(
        h.transport.toPanelOfType('result').last['errorCode'],
        PanelErrorCode.staleProject.name,
      );
    });

    test(
      'a project switch while an intent is pending invalidates the answer',
      () async {
        late final ({
          InMemoryPanelTransport transport,
          PanelBridge bridge,
          FakePanelSessionSource source,
          PanelShellEndpoint shell,
        })
        h;
        h = harness(
          selectionGate: (ids) async {
            h.source.replaceSession(2, projectId: 'project-2');
          },
        );
        addTearDown(h.bridge.dispose);
        h.shell.connect();

        await h.shell.setSelection(['sketch:1']);
        await pumpEventQueue();

        expect(
          h.transport.toPanelOfType('result').last['errorCode'],
          PanelErrorCode.staleSession.name,
        );
        // The panel was resynced onto the new session.
        expect(h.shell.sessionId, 2);
        expect(h.shell.projectId, 'project-2');
        final sessionTwoSnapshots = h.transport
            .toPanelOfType('snapshot')
            .where((message) => message['sessionId'] == 2)
            .toList();
        expect(sessionTwoSnapshots, isNotEmpty);
        expect(
          sessionTwoSnapshots.first['full'],
          isTrue,
          reason: 'uma nova sessão só começa com snapshot completo',
        );
      },
    );

    test(
      'a new session resyncs with a full snapshot and only that revision',
      () {
        final h = harness();
        addTearDown(h.bridge.dispose);
        h.shell.connect();
        h.source.setSelection(['sketch:1']);
        h.bridge.flushPending();
        expect(h.shell.viewModel[PanelViewModelKeys.selection], ['sketch:1']);

        h.source.replaceSession(7, projectId: 'project-7');
        h.bridge.flushPending();

        expect(h.bridge.sessionChanges, 1);
        expect(h.shell.sessionId, 7);
        expect(h.shell.projectId, 'project-7');
        expect(h.shell.viewModel[PanelViewModelKeys.selection], isEmpty);
        final messages = h.transport.toPanelLog
            .where((message) => message['type'] == 'snapshot')
            .toList();
        expect(messages.last['full'], isTrue);
        // No pending delivery survives the session change.
        final countAfterSwitch = messages.length;
        h.bridge.flushPending();
        expect(
          h.transport.toPanelLog
              .where((message) => message['type'] == 'snapshot')
              .length,
          countAfterSwitch,
        );
      },
    );

    test(
      'closing the document suspends the panel and clears it on disconnect',
      () async {
        final h = harness();
        addTearDown(h.bridge.dispose);
        h.shell.connect();

        h.source.closeProject();
        h.bridge.flushPending();
        expect(h.shell.lifecycle, PanelLifecycleState.suspended);
        expect(h.shell.viewModelIsStale, isTrue);

        await h.bridge.disconnectPanel(PanelId.explorer);
        expect(h.shell.lifecycle, PanelLifecycleState.disconnected);
        expect(h.shell.viewModel, isEmpty);
        expect(h.transport.disposedPanels, [PanelId.explorer.name]);
        expect(h.bridge.connectionFor(PanelId.explorer), isNull);
      },
    );

    test('remounting the Workspace reconnects the panel cleanly', () async {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();
      h.source.setSelection(['sketch:1']);
      h.bridge.flushPending();

      // The Workspace is disposed and a new panel endpoint is created.
      h.shell.dispose();
      final remounted = PanelShellEndpoint(
        panelId: PanelId.explorer,
        transport: h.transport,
      );
      h.source.setSelection(const []);
      remounted.connect();

      expect(remounted.lifecycle, PanelLifecycleState.ready);
      expect(remounted.viewModelIsStale, isFalse);
      expect(h.transport.toPanelOfType('snapshot').last['full'], isTrue);
      expect(remounted.viewModel[PanelViewModelKeys.selection], isEmpty);
    });

    test('reconnection asks for and receives a full snapshot', () async {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();
      final firstRevision = h.shell.revision;

      h.shell.requestResync();
      await pumpEventQueue();

      expect(h.shell.resyncRequests, 1);
      expect(h.shell.revision, greaterThan(firstRevision));
      expect(h.transport.toPanelOfType('snapshot').last['full'], isTrue);
      expect(h.shell.viewModelIsStale, isFalse);
    });
  });

  group('visibility action', () {
    test('is applied in the main session and projected back', () async {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      await h.shell.setVisibility('sketch:1', visible: false);
      await pumpEventQueue();

      expect(h.source.appliedVisibilities, [(id: 'sketch:1', visible: false)]);
      final entities = h.shell.viewModel[PanelViewModelKeys.entities]! as List;
      final row =
          entities.firstWhere((entry) => (entry as Map)['id'] == 'sketch:1')
              as Map;
      expect(row['visible'], isFalse);
      expect(h.shell.results.last.ok, isTrue);
    });

    test('is refused when the session cannot apply it', () async {
      final h = harness(supportsVisibility: false);
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      await h.shell.setVisibility('sketch:1', visible: false);
      await pumpEventQueue();

      expect(h.source.visibilityApplications, 0);
      expect(h.shell.results.last.errorCode, PanelErrorCode.unknownAction);
    });

    test('a failing mutation is reported as a typed error', () async {
      final h = harness(
        visibilityGate: (id, visible) async => throw StateError('kernel off'),
      );
      addTearDown(h.bridge.dispose);
      h.shell.connect();

      await h.shell.setVisibility('sketch:1', visible: false);
      await pumpEventQueue();

      expect(h.shell.results.last.ok, isFalse);
      expect(h.shell.results.last.errorCode, PanelErrorCode.internalError);
      expect(h.shell.results.last.message, contains('kernel off'));
    });
  });

  group('protocol revisions', () {
    test('the protocol sequence is independent of the document revision', () {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();
      expect(h.shell.viewModel[PanelViewModelKeys.stateRevision], 0);
      expect(h.shell.revision, 1);

      // Two authoritative changes, one coalesced delivery.
      h.source.addEntity(id: 'sketch:9');
      h.source.addEntity(id: 'sketch:10');
      h.bridge.flushPending();

      expect(h.shell.viewModel[PanelViewModelKeys.stateRevision], 2);
      expect(
        h.shell.revision,
        2,
        reason: 'a sequência de protocolo conta entregas, não mudanças',
      );
    });

    test('a recovery snapshot is accepted even with an older revision', () {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();
      h.source.setSelection(['sketch:1']);
      h.bridge.flushPending();
      expect(h.shell.revision, greaterThan(1));

      h.transport.sendToPanel(PanelId.explorer.name, {
        'type': 'snapshot',
        'panelId': PanelId.explorer.name,
        'sessionId': 1,
        'projectId': 'project-1',
        'revision': 1,
        'full': true,
        'viewModel': {PanelViewModelKeys.selection: <String>[]},
      });

      expect(h.shell.revision, 1);
      expect(h.shell.viewModel[PanelViewModelKeys.selection], isEmpty);
      expect(h.shell.droppedOutOfOrderSnapshots, 0);
    });
  });

  group('snapshot integrity', () {
    test('an oversized projection is omitted explicitly, never truncated', () {
      final h = harness();
      addTearDown(h.bridge.dispose);
      for (var index = 0; index < 400; index++) {
        h.source.addEntity(id: 'sketch:$index', label: 'x' * 200);
      }
      h.shell.connect();

      final snapshot = h.transport.toPanelOfType('snapshot').last;
      expect(
        panelPayloadSize(snapshot),
        lessThanOrEqualTo(const PanelProtocolLimits().maxMessageBytes),
        reason: 'o limite vale para a mensagem serializada inteira',
      );
      expect(snapshot['omittedKeys'], contains(PanelViewModelKeys.entities));
      final viewModel = snapshot['viewModel']! as Map<String, Object?>;
      expect(viewModel[PanelViewModelKeys.truncated], isTrue);
      expect(viewModel[PanelViewModelKeys.entityCount], 402);
      expect(h.shell.lastOmittedKeys, contains(PanelViewModelKeys.entities));
      expect(h.shell.protocolErrors, isEmpty);
    });

    test('a payload that cannot fit at all is refused with a typed reason', () {
      final transport = InMemoryPanelTransport();
      final source = FakePanelSessionSource(projectId: 'p');
      source.extraViewModel['status'] = 'x' * 70000;
      final bridge = PanelBridge(transport: transport, source: source)..start();
      addTearDown(bridge.dispose);
      final shell = PanelShellEndpoint(
        panelId: PanelId.explorer,
        transport: transport,
      );
      shell.connect();

      expect(bridge.snapshotsRefused, 1);
      expect(transport.toPanelOfType('snapshot'), isEmpty);
      final lifecycle = transport.toPanelOfType('lifecycle').last;
      expect(lifecycle['reason'], 'snapshot-too-large');
      expect(lifecycle['state'], PanelLifecycleState.suspended.name);
      expect(shell.lifecycle, PanelLifecycleState.suspended);
    });
  });

  group('multiple panels', () {
    test(
      'two panels keep their own session, revision and projection',
      () async {
        final transport = InMemoryPanelTransport();
        final source = FakePanelSessionSource(
          projectId: 'project-1',
          entities: const [
            (id: 'sketch:1', kind: 'sketch', label: 'Sketch 1', visible: true),
          ],
        );
        final bridge = PanelBridge(transport: transport, source: source)
          ..start();
        addTearDown(bridge.dispose);
        final explorer = PanelShellEndpoint(
          panelId: PanelId.explorer,
          transport: transport,
        );
        final inspector = PanelShellEndpoint(
          panelId: PanelId.inspector,
          transport: transport,
        );
        explorer.connect();
        inspector.connect();

        expect(explorer.viewModel[PanelViewModelKeys.panelId], 'explorer');
        expect(inspector.viewModel[PanelViewModelKeys.panelId], 'inspector');
        expect(explorer.sessionId, inspector.sessionId);
        final snapshots = transport.toPanelOfType('snapshot').toList();
        expect(snapshots.map((message) => message['panelId']).toSet(), {
          'explorer',
          'inspector',
        });
        expect(
          snapshots.map((message) => message['revision']).toSet(),
          hasLength(2),
          reason: 'cada painel tem a sua própria sequência',
        );

        await explorer.setSelection(['sketch:1']);
        await pumpEventQueue();
        expect(inspector.results, isEmpty);

        source.replaceSession(5, projectId: 'project-5');
        bridge.flushPending();
        expect(explorer.sessionId, 5);
        expect(inspector.sessionId, 5);
        expect(explorer.projectId, 'project-5');
        expect(
          transport
              .toPanelOfType('snapshot')
              .where((message) => message['sessionId'] == 5)
              .length,
          2,
        );
      },
    );
  });

  group('transport failures', () {
    test('lost deliveries are detected as a gap and recovered by resync', () {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();
      final revisionBeforeOutage = h.shell.revision;

      h.transport.blockDeliveries = true;
      h.source.setSelection(['sketch:1']);
      h.bridge.flushPending();
      h.source.setSelection(['import:1']);
      h.bridge.flushPending();
      expect(h.shell.revision, revisionBeforeOutage, reason: 'canal caído');

      h.transport.blockDeliveries = false;
      h.source.setSelection(['sketch:1', 'import:1']);
      h.bridge.flushPending();

      expect(h.shell.resyncRequests, 1);
      expect(h.shell.viewModel[PanelViewModelKeys.selection], [
        'import:1',
        'sketch:1',
      ]);
      expect(h.shell.viewModelIsStale, isFalse);
    });

    test('disposing during a pending update delivers nothing', () async {
      final h = harness();
      addTearDown(h.bridge.dispose);
      h.shell.connect();
      h.source.setSelection(['sketch:1']);
      final delivered = h.transport.toPanelLog.length;

      h.bridge.dispose();
      await pumpEventQueue();

      expect(h.transport.toPanelLog.length, delivered);
      expect(h.bridge.connectionFor(PanelId.explorer), isNull);
      expect(h.bridge.messageDepth, 0);
      // The main listener is gone: a late message changes nothing.
      h.transport.sendToMain(PanelId.explorer.name, {
        'type': 'intent',
        'panelId': PanelId.explorer.name,
        'sessionId': 1,
        'projectId': 'project-1',
        'action': panelActionSelectionSet,
        'params': {
          'ids': ['sketch:1'],
        },
        'requestId': 'after-dispose',
      });
      await pumpEventQueue();
      expect(h.source.selectionApplications, 0);
      expect(h.transport.toPanelOfType('result'), isEmpty);
    });
  });

  group('panel host gateway compatibility', () {
    test(
      'the bridge serves every panel a detached layout materializes',
      () async {
        final layout = PanelLayoutPresets.dualMonitor(
          displays: dualDisplayDesktop(),
        );
        final gateway = RecordingPanelHostGateway();
        final created = await materializeDetachedPanels(
          layout: layout,
          gateway: gateway,
        );
        expect(created, hasLength(2));

        final transport = InMemoryPanelTransport();
        final bridge = PanelBridge(
          transport: transport,
          source: FakePanelSessionSource(projectId: 'project-1'),
        )..start();
        addTearDown(bridge.dispose);
        final shells = <PanelId, PanelShellEndpoint>{
          for (final state in created)
            state.panelId: PanelShellEndpoint(
              panelId: state.panelId,
              transport: transport,
            )..connect(),
        };

        expect(shells.keys.toSet(), {PanelId.reconstruct, PanelId.continuity});
        for (final entry in shells.entries) {
          expect(entry.value.lifecycle, PanelLifecycleState.ready);
          expect(
            entry.value.viewModel[PanelViewModelKeys.panelId],
            entry.key.name,
          );
        }
        expect(bridge.connections.map((c) => c.panelId).toSet(), {
          PanelId.reconstruct,
          PanelId.continuity,
        });
      },
    );
  });

  group('isolation', () {
    test('the panel shell and protocol never import the CAD core', () {
      const forbidden = [
        'cad_runtime',
        'cad_document',
        'cad_kernel',
        'opencascade',
        'sketch_engine',
        'sketch_assistant',
        'desktop_command_coordinator',
        'command_registry',
        'desktop_cad_controller',
        'operational_reverse_engineering_controller',
        'engineering_bootstrap',
        'project_manager',
        'dart:io',
      ];
      final offenders = <String>[];
      for (final path in const [
        'lib/app/desktop/panels/panel_shell.dart',
        'lib/app/desktop/panels/panel_protocol.dart',
        'lib/app/desktop/panels/panel_transport.dart',
      ]) {
        for (final line in File(path).readAsLinesSync()) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('import ')) continue;
          for (final needle in forbidden) {
            if (trimmed.contains(needle)) offenders.add('$path: $trimmed');
          }
        }
      }
      expect(offenders, isEmpty);
    });

    test('the bridge only mutates through the session source', () {
      final bridgeSource = File(
        'lib/app/desktop/panels/panel_bridge.dart',
      ).readAsStringSync();
      for (final line in bridgeSource.split('\n')) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('import ')) continue;
        expect(trimmed.contains('cad_runtime'), isFalse);
        expect(trimmed.contains('cad_document'), isFalse);
        expect(trimmed.contains('command_registry'), isFalse);
      }
      expect(bridgeSource.contains('runtime.select'), isFalse);
    });
  });
}
