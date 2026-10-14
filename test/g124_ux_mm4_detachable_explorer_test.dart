import 'dart:io';

import 'package:flcad_mobile/app/desktop/layout/display_service.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_store.dart';
import 'package:flcad_mobile/app/desktop/panels/desktop_panel_window_backend.dart';
import 'package:flcad_mobile/app/desktop/panels/multi_window_panel_transport.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_bridge.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_protocol.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_session_source.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_shell.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_shell_entry.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_shell_window.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_view_model.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_window_backend.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_window_host.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mm2_layout_harness.dart';

const String _explorerWindowPayload =
    '{"panelId":"explorer",'
    '"protocolVersion":1}';

/// Harness for one simulated pair of windows (main + Explorer panel).
final class _Spike {
  _Spike({
    required this.backend,
    required this.mainTransport,
    required this.panelTransport,
    required this.bridge,
    required this.source,
    required this.shell,
    required this.host,
    required this.store,
  });

  final LoopbackPanelWindowBackend backend;
  final MultiWindowPanelTransport mainTransport;
  final MultiWindowPanelTransport panelTransport;
  final PanelBridge bridge;
  final FakePanelSessionSource source;
  final PanelShellEndpoint shell;
  final PanelWindowHost host;
  final MemoryPanelLayoutStore store;
}

/// Wires the whole spike without native windows: one loopback backend shared by
/// the main transport, the panel transport, the bridge and the window host.
///
/// The window id resolver falls back to the panel's own id so the handshake can
/// be tested before the host materializes a window (in the real flow the window
/// is created first and the attachment always exists).
_Spike _spike({
  DisplayService? displays,
  double devicePixelRatio = 1,
  String panelWindowId = 'loopback-window-1',
  List<({String id, String kind, String label, bool visible})> entities =
      const [
        (id: 'sketch:1', kind: 'sketch', label: 'Sketch 1', visible: true),
        (id: 'import:1', kind: 'import', label: 'CALOTA', visible: true),
      ],
}) {
  final backend = LoopbackPanelWindowBackend();
  final source = FakePanelSessionSource(
    projectId: 'project-1',
    entities: entities,
  );
  final store = MemoryPanelLayoutStore();
  final host = PanelWindowHost(
    backend: backend,
    layoutStore: store,
    displays: displays ?? dualDisplayDesktop(),
    devicePixelRatio: () => devicePixelRatio,
  );
  final mainTransport = MultiWindowPanelTransport(
    backend: backend,
    isMainWindow: true,
    panelWindowIdResolver: (panelId) =>
        host.attachmentFor(PanelId.explorer)?.windowId ?? panelWindowId,
  );
  final bridge = PanelBridge(transport: mainTransport, source: source);
  bridge.start();
  final panelTransport = MultiWindowPanelTransport(
    backend: backend,
    isMainWindow: false,
    windowId: panelWindowId,
  );
  final shell = PanelShellEndpoint(
    panelId: PanelId.explorer,
    transport: panelTransport,
    capabilities: const [
      PanelCapabilities.explorer,
      PanelCapabilities.selection,
    ],
  );
  return _Spike(
    backend: backend,
    mainTransport: mainTransport,
    panelTransport: panelTransport,
    bridge: bridge,
    source: source,
    shell: shell,
    host: host,
    store: store,
  );
}

/// Loopback backend that runs a probe at the exact moment the native window
/// would be created, so the persisted layout can be inspected mid-detach.
final class _CreateProbeBackend extends LoopbackPanelWindowBackend {
  Future<void> Function()? onBeforeCreate;

  @override
  Future<String?> createWindow({
    required String arguments,
    required String title,
    required RectData logicalBounds,
    required bool hiddenAtLaunch,
  }) async {
    await onBeforeCreate?.call();
    return super.createWindow(
      arguments: arguments,
      title: title,
      logicalBounds: logicalBounds,
      hiddenAtLaunch: hiddenAtLaunch,
    );
  }
}

/// Connects the panel endpoint after the main channel handler is registered
/// (the real app creates the window after registering, so this only models the
/// ordering explicitly in tests).
Future<void> _connect(_Spike spike) async {
  await spike.mainTransport.ready;
  await pumpEventQueue();
  spike.shell.connect();
  // The panel registers its own channel asynchronously; wait for it before the
  // main starts pushing snapshots (the app waits for its first frame instead).
  await spike.panelTransport.ready;
  await pumpEventQueue();
}

void main() {
  late _Spike spike;
  setUp(() => spike = _spike());
  tearDown(() async {
    spike.bridge.dispose();
    await spike.mainTransport.close();
  });

  group('panel window entry', () {
    test('recognises the entrypoint arguments desktop_multi_window passes', () {
      expect(
        PanelShellEntry.isPanelWindow([
          'multi_window',
          'window-1',
          _explorerWindowPayload,
        ]),
        isTrue,
      );
      final config = PanelShellEntry.configFor([
        'multi_window',
        'window-1',
        _explorerWindowPayload,
      ]);
      expect(config?.panelId, PanelId.explorer);
      expect(config?.windowId, 'window-1');
    });

    test('never treats the main window as a panel window', () {
      expect(PanelShellEntry.isPanelWindow(const []), isFalse);
      expect(PanelShellEntry.isPanelWindow(const ['--flag']), isFalse);
      expect(
        PanelShellEntry.isPanelWindow(const ['multi_window', 'window-1']),
        isFalse,
        reason: 'faltam os argumentos do painel',
      );
      expect(
        PanelShellEntry.configFor(const [
          'multi_window',
          'window-1',
          '{ isto não é json',
        ]),
        isNull,
      );
      expect(
        PanelShellEntry.configFor(const [
          'multi_window',
          'window-1',
          '{"panelId":"painel-inexistente"}',
        ]),
        isNull,
      );
    });

    test('the panel shell never imports the CAD core', () {
      const forbidden = [
        'cad_runtime',
        'cad_document',
        'cad_kernel',
        'opencascade',
        'sketch_engine',
        'command_registry',
        'desktop_command_coordinator',
        'desktop_cad_controller',
        'operational_reverse_engineering_controller',
        'engineering_bootstrap',
        'project_manager',
        'dart:io',
      ];
      final offenders = <String>[];
      // Every file the secondary engine can reach from the panel entrypoint.
      for (final path in const [
        'lib/app/desktop/panels/panel_shell_entry.dart',
        'lib/app/desktop/panels/panel_shell_window.dart',
        'lib/app/desktop/panels/panel_shell.dart',
        'lib/app/desktop/panels/multi_window_panel_transport.dart',
        'lib/app/desktop/panels/desktop_panel_window_backend.dart',
        'lib/app/desktop/panels/panel_window_backend.dart',
        'lib/app/desktop/panels/panel_window_host.dart',
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

    test('main.dart branches before any bootstrap', () {
      final main = File('lib/main.dart').readAsStringSync();
      final branch = main.indexOf('PanelShellEntry.isPanelWindow');
      final bootstrap = main.indexOf('WidgetsFlutterBinding.ensureInitialized');
      expect(branch, greaterThan(-1));
      expect(bootstrap, greaterThan(branch));
      expect(main.contains('PanelShellEntry.run(arguments)'), isTrue);
    });
  });

  group('two endpoints over the real channel routing', () {
    test('handshake produces the Explorer projection', () async {
      await _connect(spike);

      expect(spike.shell.lifecycle, PanelLifecycleState.ready);
      expect(spike.shell.viewModel[PanelViewModelKeys.panelId], 'explorer');
      final rows = spike.shell.viewModel[PanelViewModelKeys.entities]! as List;
      expect(rows, hasLength(2));
      expect((rows.first as Map)['id'], isNotNull);
      expect(spike.shell.viewModelIsStale, isFalse);
      expect(
        spike.source.selectionApplications,
        0,
        reason: 'a projeção não muta nada',
      );
    });

    test('selection started in the panel reaches the main session', () async {
      await _connect(spike);
      await spike.shell.setSelection(['import:1']);
      await pumpEventQueue();

      expect(spike.source.appliedSelections, [
        {'import:1'},
      ]);
      expect(spike.shell.viewModel[PanelViewModelKeys.selection], ['import:1']);
      expect(spike.shell.results.last.ok, isTrue);
    });

    test('selection changed in the main session reaches the panel', () async {
      await _connect(spike);
      spike.source.setSelection(['sketch:1']);
      spike.bridge.flushPending();

      expect(spike.shell.viewModel[PanelViewModelKeys.selection], ['sketch:1']);
    });

    test(
      'the panel asks for a dock back through the control channel',
      () async {
        await _connect(spike);
        final control = <String>[];
        spike.mainTransport.onMainWindowControl = (method, arguments) {
          control.add(method);
        };

        await spike.panelTransport.backend.invokeChannel(
          panelIntentsChannel,
          'panel_dock',
          {'panelId': 'explorer', 'windowId': 'loopback-window-1'},
        );

        expect(control, ['panel_dock']);
      },
    );

    test('a lost channel is detected and recovered by resync', () async {
      await _connect(spike);
      final revision = spike.shell.revision;

      spike.backend.blockChannels = true;
      spike.source.setSelection(['sketch:1']);
      spike.bridge.flushPending();
      expect(spike.shell.revision, revision);

      spike.backend.blockChannels = false;
      spike.source.setSelection(['import:1']);
      spike.bridge.flushPending();

      expect(spike.shell.resyncRequests, 1);
      expect(spike.shell.viewModel[PanelViewModelKeys.selection], ['import:1']);
    });

    test('an oversized projection is omitted explicitly in the real path', () {
      final big = _spike(
        entities: [
          for (var index = 0; index < 300; index++)
            (
              id: 'sketch:$index',
              kind: 'sketch',
              label: 'x' * 220,
              visible: true,
            ),
        ],
      );
      addTearDown(big.bridge.dispose);
      big.shell.connect();

      expect(big.shell.lastOmittedKeys, contains(PanelViewModelKeys.entities));
      expect(big.shell.viewModel[PanelViewModelKeys.entityCount], 300);
      expect(big.shell.protocolErrors, isEmpty);
    });
  });

  group('window host', () {
    test(
      'detach creates a real window entry and persists the layout',
      () async {
        final attachment = await spike.host.detach(
          PanelId.explorer,
          requestedGeometry: const PanelGeometry(
            left: 1960,
            top: 40,
            width: 340,
            height: 620,
          ),
        );

        expect(attachment, isNotNull);
        expect(spike.backend.createdWindows, hasLength(1));
        final persisted = await spike.store.load();
        final entry = persisted.layout.entryFor(PanelId.explorer);
        expect(entry.isDetached, isTrue);
        expect(entry.geometry, isNotNull);
        expect(entry.monitorDevice, isNotNull);
      },
    );

    test(
      'geometry persists across dock/detach and is clamped off-screen',
      () async {
        const requested = PanelGeometry(
          left: 9000,
          top: 7000,
          width: 340,
          height: 620,
        );
        final first = await spike.host.detach(
          PanelId.explorer,
          requestedGeometry: requested,
        );
        final geometry = first!.geometry;
        expect(
          dualDisplayDesktop().displays.any(
            (display) => display.workArea.overlaps(geometry.rect),
          ),
          isTrue,
          reason: 'geometria fora da tela é recuperada',
        );
        await spike.host.dock(PanelId.explorer);
        expect(
          (await spike.store.load()).layout.entryFor(PanelId.explorer).geometry,
          geometry,
          reason: 'a geometria sobrevive ao reencaixe',
        );

        final second = await spike.host.detach(
          PanelId.explorer,
          requestedGeometry: (await spike.host.prepareLayout())
              .entryFor(PanelId.explorer)
              .geometry!,
        );
        expect(second!.geometry, geometry);
        expect(spike.backend.createdWindows, hasLength(2));
      },
    );

    test(
      'a disconnected monitor brings the window back inside the primary',
      () async {
        final desktop = FakeDisplayService([
          testDisplay(
            deviceName: r'\\.\DISPLAY1',
            isPrimary: true,
            size: const Size(1920, 1080),
          ),
          testDisplay(
            deviceName: r'\\.\DISPLAY2',
            origin: const Offset(1920, 0),
          ),
        ]);
        final host = PanelWindowHost(
          backend: LoopbackPanelWindowBackend(),
          layoutStore: MemoryPanelLayoutStore(),
          displays: desktop,
        );
        final attachment = await host.detach(
          PanelId.explorer,
          requestedGeometry: const PanelGeometry(
            left: 2000,
            top: 60,
            width: 340,
            height: 620,
          ),
        );
        expect(
          desktop.displays[1].workArea.overlaps(attachment!.geometry.rect),
          isTrue,
        );

        // The second monitor disappears.
        desktop.replaceDisplays([desktop.displays.first]);
        final docked = await host.reconcileDisplays();

        expect(docked, [
          PanelId.explorer,
        ], reason: 'sem o monitor, o painel volta para a janela principal');
        expect(host.hasAttachments, isFalse);
        expect(host.backend, isNot(null));
        final persisted = await host.prepareLayout();
        expect(
          persisted.entryFor(PanelId.explorer).isDetached,
          isFalse,
          reason: 'o layout volta para uma tela',
        );
      },
    );

    test('closing the window with the X docks the panel back', () async {
      await spike.host.detach(
        PanelId.explorer,
        requestedGeometry: const PanelGeometry(
          left: 100,
          top: 100,
          width: 340,
          height: 620,
        ),
      );
      // The operator closes the window: it disappears from the window list
      // without the host asking for it.
      spike.backend.windowBounds.clear();

      final closed = await spike.host.reconcileWindows();

      expect(closed, [PanelId.explorer]);
      expect(spike.host.hasAttachments, isFalse);
      final persisted = await spike.store.load();
      expect(persisted.layout.entryFor(PanelId.explorer).isDetached, isFalse);
      expect(
        persisted.layout.preset,
        PanelLayoutPreset.singleMonitor,
        reason: 'retorno funcional ao layout de uma tela',
      );
    });

    test(
      'repeated open/close cycles leak no listeners or registrations',
      () async {
        await _connect(spike);
        for (var cycle = 0; cycle < 3; cycle++) {
          await spike.host.detach(
            PanelId.explorer,
            requestedGeometry: const PanelGeometry(
              left: 120,
              top: 120,
              width: 340,
              height: 620,
            ),
          );
          await spike.host.dock(PanelId.explorer);
        }

        expect(spike.host.detachCount, 3);
        expect(spike.host.dockCount, 3);
        expect(spike.backend.closedWindows, hasLength(3));
        expect(spike.bridge.connections, hasLength(1));
        expect(
          spike.backend.registeredChannelNames,
          contains(panelIntentsChannel),
          reason: 'o canal de intents do main permanece único',
        );
        expect(
          spike.backend.registeredChannelNames
              .where((name) => name.startsWith('flcad.panel.window.'))
              .length,
          lessThanOrEqualTo(1),
          reason: 'nenhum canal de painel vaza entre ciclos',
        );
      },
    );

    test('detach stores the intent before the window exists', () async {
      final backend = _CreateProbeBackend();
      final store = MemoryPanelLayoutStore();
      final host = PanelWindowHost(
        backend: backend,
        layoutStore: store,
        displays: dualDisplayDesktop(),
      );
      bool? detachedWhenWindowWasCreated;
      backend.onBeforeCreate = () async {
        detachedWhenWindowWasCreated =
            (await store.load()).layout.entryFor(PanelId.explorer).isDetached;
      };

      await host.detach(
        PanelId.explorer,
        requestedGeometry: const PanelGeometry(
          left: 120,
          top: 120,
          width: 340,
          height: 620,
        ),
      );

      expect(
        detachedWhenWindowWasCreated,
        isTrue,
        reason:
            'o reconcile le o layout gravado: gravar depois de anexar faz a '
            'janela recem-criada voltar para o main no proximo tick',
      );
    });

    test('a stale attachment never blocks a new window', () async {
      await _connect(spike);
      const geometry = PanelGeometry(
        left: 120,
        top: 120,
        width: 340,
        height: 620,
      );
      final first = await spike.host.detach(
        PanelId.explorer,
        requestedGeometry: geometry,
      );
      // The window disappears without the host ever being asked to dock it.
      spike.backend.windowBounds.clear();

      final second = await spike.host.detach(
        PanelId.explorer,
        requestedGeometry: geometry,
      );

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(
        second!.windowId,
        isNot(first!.windowId),
        reason: 'o anexo morto e descartado em vez de bloquear o destaque',
      );
      expect(spike.backend.createdWindows, hasLength(2));
    });

    test('physical and logical geometry convert with the display scale', () {
      final scaled = _spike(devicePixelRatio: 1.5);
      addTearDown(scaled.bridge.dispose);
      const physical = PanelGeometry(
        left: 300,
        top: 150,
        width: 450,
        height: 300,
      );
      final logical = scaled.host.toLogical(physical);
      expect(
        logical,
        const RectData(left: 200, top: 100, width: 300, height: 200),
      );
      expect(scaled.host.toPhysical(logical), physical);
    });

    test('a panel on a left-hand monitor keeps negative coordinates', () async {
      final desktop = dualDisplayDesktop(
        secondaryOrigin: const Offset(-1920, 0),
        secondaryScale: 1.25,
      );
      final host = PanelWindowHost(
        backend: LoopbackPanelWindowBackend(),
        layoutStore: MemoryPanelLayoutStore(),
        displays: desktop,
        devicePixelRatio: () => 1.25,
      );
      const requested = PanelGeometry(
        left: -1800,
        top: 80,
        width: 340,
        height: 620,
      );

      final attachment = await host.detach(
        PanelId.explorer,
        requestedGeometry: requested,
      );

      final geometry = attachment!.geometry;
      expect(
        geometry.left,
        lessThan(0),
        reason: 'monitor a esquerda da tela principal tem x negativo',
      );
      expect(
        desktop.displays[1].workArea.overlaps(geometry.rect),
        isTrue,
        reason: 'o painel fica no monitor esquerdo, nao e puxado ao primario',
      );
      final logical = host.toLogical(geometry);
      expect(logical.left, lessThan(0));
      expect(
        host.toPhysical(logical),
        geometry,
        reason: 'ida e volta fisico/logico preserva o offset negativo',
      );
    });

    test('a late dispose of the previous session keeps the new one alive',
        () async {
      // One backend models the process-global platform channels: two workspace
      // sessions register the very same channel names.
      final backend = LoopbackPanelWindowBackend();
      final oldSession = MultiWindowPanelTransport(
        backend: backend,
        isMainWindow: true,
        panelWindowIdResolver: (_) => 'loopback-window-1',
      );
      final newSession = MultiWindowPanelTransport(
        backend: backend,
        isMainWindow: true,
        panelWindowIdResolver: (_) => 'loopback-window-1',
      );
      final received = <String>[];
      oldSession.registerMainListener((_, _) => received.add('old'));
      newSession.registerMainListener((_, _) => received.add('new'));

      Future<void> send() => backend.invokeChannel(
        panelIntentsChannel,
        'panelMessage',
        const {'panelId': 'explorer'},
      );

      await send();
      expect(received, ['new'], reason: 'a sessao mais recente e a viva');

      // The previous workspace state is disposed *after* the new session
      // registered its channels (late dispose during a remount).
      await oldSession.close();

      received.clear();
      await send();
      expect(
        received,
        ['new'],
        reason: 'o dispose tardio nao pode desregistrar a sessao nova',
      );
      await newSession.close();
      expect(backend.registeredHandlers, 0);
    });

    test('disposing during a pending update delivers nothing', () async {
      final isolated = _spike();
      await _connect(isolated);
      isolated.source.setSelection(['sketch:1']);
      final delivered = List<String>.of(isolated.backend.undelivered);

      isolated.bridge.dispose();
      await isolated.mainTransport.close();
      await pumpEventQueue();

      expect(isolated.bridge.connectionFor(PanelId.explorer), isNull);
      expect(isolated.backend.undelivered, delivered);
      // Only the panel's own channel survives on the main side: it belongs to
      // the panel window and is cleared when that window goes away.
      expect(isolated.backend.registeredChannelNames.toList(), [
        panelWindowChannel('loopback-window-1'),
      ]);
      await isolated.panelTransport.close();
      expect(isolated.backend.registeredHandlers, 0);
    });
  });

  group('plugin registration and real teardown (MM4.1A)', () {
    test('the runner registers the app plugins in every engine it creates', () {
      final source = File(
        'windows/runner/flutter_window.cpp',
      ).readAsStringSync();
      final start = source.indexOf(
        'DesktopMultiWindowSetWindowCreatedCallback',
      );
      final end = source.indexOf('native_viewport_registrar_ =', start);

      expect(start, greaterThan(-1), reason: 'o hook oficial e obrigatorio');
      expect(end, greaterThan(start));
      final hook = source.substring(start, end);
      expect(
        hook.contains('RegisterPlugins(registry)'),
        isTrue,
        reason: 'o engine secundario tem canais proprios (window_manager)',
      );
      expect(
        hook.contains('NativeViewportHost'),
        isFalse,
        reason: 'a janela do painel nao hospeda o viewport nativo do CAD',
      );
    });

    test('the panel never posts WM_QUIT through window_manager.destroy', () {
      final source = File(
        'lib/app/desktop/panels/panel_shell_window.dart',
      ).readAsStringSync();

      expect(
        source.contains('windowManager.destroy'),
        isFalse,
        reason:
            'destroy() posts WM_QUIT on the process main thread: the secondary '
            'engine runs with UIThreadPolicy::RunOnSeparateThread, so it would '
            'take the whole application down together with the panel',
      );
      expect(source.contains('setPreventClose(false)'), isTrue);
      expect(source.contains('windowManager.close()'), isTrue);
      expect(source.contains('windowManager.focus()'), isTrue);
    });

    test('the close request travels on the panel window control plane',
        () async {
      await _connect(spike);
      final controls = <String>[];
      spike.panelTransport.onWindowControl = (method, _) => controls.add(method);

      final attachment = await spike.host.detach(
        PanelId.explorer,
        requestedGeometry: const PanelGeometry(
          left: 120,
          top: 120,
          width: 340,
          height: 620,
        ),
      );
      final closed = await spike.host.dock(PanelId.explorer);

      expect(
        controls,
        ['panel_configure', 'panel_close'],
        reason: 'geometria primeiro, depois o fechamento real da janela',
      );
      expect(closed, isTrue);
      expect(spike.backend.closedWindows, [attachment!.windowId]);
      expect(spike.host.hasAttachments, isFalse);
    });

    test('focus is requested from the panel itself', () async {
      await _connect(spike);
      final controls = <String>[];
      spike.panelTransport.onWindowControl = (method, _) => controls.add(method);

      await spike.host.detach(
        PanelId.explorer,
        requestedGeometry: const PanelGeometry(
          left: 120,
          top: 120,
          width: 340,
          height: 620,
        ),
      );
      await spike.host.focus(PanelId.explorer);

      expect(
        controls,
        contains('panel_focus'),
        reason: 'o painel resolve o proprio HWND; o main nao adivinha',
      );
    });

    test('a panel that ignores the close stays tracked instead of orphaned',
        () async {
      await _connect(spike);
      // The control reaches the window, but the window never disappears: a
      // wedged engine must not desynchronize the layout from reality.
      spike.backend.honorPanelClose = false;
      final controls = <String>[];
      spike.panelTransport.onWindowControl = (method, _) => controls.add(method);
      await spike.host.detach(
        PanelId.explorer,
        requestedGeometry: const PanelGeometry(
          left: 120,
          top: 120,
          width: 340,
          height: 620,
        ),
      );

      final closed = await spike.host.dock(PanelId.explorer);

      expect(controls, contains('panel_close'));
      expect(closed, isFalse);
      expect(spike.host.dockFailures, 1);
      expect(
        spike.host.hasAttachments,
        isTrue,
        reason: 'uma janela viva continua rastreada e pode ser reencaixada',
      );
    });

    testWidgets('the panel chrome fits the narrow detached window', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(340, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final backend = LoopbackPanelWindowBackend();
      final transport = MultiWindowPanelTransport(
        backend: backend,
        isMainWindow: false,
        windowId: 'loopback-window-1',
      );
      addTearDown(transport.close);

      await tester.pumpWidget(
        PanelShellWindowApp(
          config: PanelShellEntry.configFor(const [
            'multi_window',
            'loopback-window-1',
            _explorerWindowPayload,
          ])!,
          transport: transport,
          windowControlAvailable: false,
        ),
      );
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'a barra superior e o rodape nao podem estourar a largura',
      );
      expect(
        find.textContaining("Instance of 'PanelShellEndpoint'"),
        findsNothing,
        reason: 'o rodape interpola valores, nao o objeto do endpoint',
      );
      expect(find.textContaining('rev 0'), findsOneWidget);
      expect(find.textContaining('Reencaixar'), findsOneWidget);
      expect(find.textContaining('Explorer'), findsWidgets);

      // The chrome is built from the window's ambient context; it must resolve
      // the panel's own dark theme, not the fallback light one.
      for (final key in const ['panel-header', 'panel-footer']) {
        final chrome = tester.widget<Container>(find.byKey(ValueKey(key)));
        expect(
          chrome.color?.computeLuminance(),
          lessThan(0.5),
          reason: 'o painel e escuro: $key nao pode virar faixa clara',
        );
      }

      // Dispose the panel so the heartbeat timer is cancelled.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
