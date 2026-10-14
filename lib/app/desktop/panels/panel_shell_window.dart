import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../layout/panel_identity.dart';
import 'desktop_panel_window_backend.dart';
import 'multi_window_panel_transport.dart';
import 'panel_protocol.dart';
import 'panel_shell.dart';
import 'panel_inspector_view_model.dart';
import 'panel_view_model.dart';
import 'panel_window_native_bridge.dart';

/// Identity of the window this isolate is running (parsed from the entrypoint
/// arguments `desktop_multi_window` hands to the sub-window).
class PanelShellWindowConfig {
  const PanelShellWindowConfig({required this.panelId, required this.windowId});

  final PanelId panelId;
  final String windowId;

  static PanelShellWindowConfig? parse(List<String> arguments) {
    if (arguments.length != 3 || arguments.first != 'multi_window') return null;
    final windowId = arguments[1];
    try {
      final payload = jsonDecode(arguments[2]);
      if (payload is! Map) return null;
      final panelId = panelIdFromName(payload['panelId'] as String? ?? '');
      if (panelId == null || windowId.isEmpty) return null;
      return PanelShellWindowConfig(panelId: panelId, windowId: windowId);
    } on Object {
      return null;
    }
  }
}

/// Minimal window shown by a detached panel.
///
/// It renders only the projection received from the main process: no CAD
/// runtime, no kernel, no project manager and no command registry live here.
class PanelShellWindowApp extends StatefulWidget {
  const PanelShellWindowApp({
    super.key,
    required this.config,
    required this.transport,
    this.windowControlAvailable = true,
  });

  final PanelShellWindowConfig config;
  final MultiWindowPanelTransport transport;

  /// False when the sub-window engine has no window plugins registered.
  final bool windowControlAvailable;

  @override
  State<PanelShellWindowApp> createState() => _PanelShellWindowAppState();
}

class _PanelShellWindowAppState extends State<PanelShellWindowApp>
    with WindowListener {
  late final PanelShellEndpoint _endpoint;
  Timer? _heartbeat;

  /// True while this window is tearing itself down; makes the close path
  /// idempotent because closing emits another `onWindowClose`.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    final capabilities = switch (widget.config.panelId) {
      // Explorer is the only functional detached renderer in MM4.3a.1.
      PanelId.explorer => const [
        PanelCapabilities.explorer,
        PanelCapabilities.selection,
      ],
      // Unsupported panel identities receive no mutation capabilities yet.
      _ => const <String>[],
    };
    _endpoint = PanelShellEndpoint(
      panelId: widget.config.panelId,
      transport: widget.transport,
      capabilities: capabilities,
      clientInstanceId: 'panel-shell:${widget.config.windowId}',
    );
    windowManager.addListener(this);
    widget.transport.onWindowControl = _handleWindowControl;
    if (widget.windowControlAvailable) {
      // The X must dock the panel back instead of killing the window silently.
      unawaited(windowManager.setPreventClose(true));
    }
    _endpoint
      ..onViewModelChanged((_) {
        if (mounted) setState(() {});
      })
      ..onLifecycleChanged((_) {
        // A dropped session is *not* a reason to tear the window down: the
        // panel keeps showing its state and the heartbeat reconnects it. Killing
        // the window here used to take the whole application with it (see
        // [_closePanelWindow]).
        if (mounted) setState(() {});
      })
      ..connect();
    // The main process may still be registering its channel when this window
    // starts; ask again shortly instead of showing a stuck spinner.
    Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      if (_endpoint.lifecycle == PanelLifecycleState.disconnected ||
          _endpoint.viewModel.isEmpty) {
        _endpoint.connect(resync: true);
      }
    });
    // The panel reconnects by itself when the main process restarts the shell.
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (_endpoint.lifecycle == PanelLifecycleState.disconnected) {
        _endpoint.connect(resync: true);
      }
    });
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    windowManager.removeListener(this);
    widget.transport.onWindowControl = null;
    _endpoint.dispose();
    super.dispose();
  }

  void _handleWindowControl(String method, Map<Object?, Object?> arguments) {
    if (!widget.windowControlAvailable) {
      // Geometry/show control needs window_manager, which the secondary engine
      // does not have. The panel keeps rendering the projection instead of
      // failing silently.
      return;
    }
    if (method == 'panel_configure') {
      unawaited(DesktopPanelWindowBackend.applyPanelConfiguration(arguments));
    } else if (method == 'panel_close') {
      unawaited(_closePanelWindow());
    } else if (method == 'panel_focus') {
      unawaited(windowManager.show());
      unawaited(windowManager.focus());
    }
  }

  /// Asks the main process to dock this panel back before closing.
  Future<void> _requestDockBack() async {
    await widget.transport.backend.invokeChannel(
      panelIntentsChannel,
      'panel_dock',
      {
        'panelId': widget.config.panelId.name,
        'windowId': widget.config.windowId,
      },
    );
  }

  /// Closes the panel window for real (HWND destroyed, engine released).
  ///
  /// `window_manager.destroy()` must not be used here: it posts `WM_QUIT` on
  /// the *process* message queue. The secondary engine runs with
  /// `UIThreadPolicy::RunOnSeparateThread`, so its platform thread is the
  /// process main thread that also pumps the main window's loop - a `destroy()`
  /// in the panel therefore ends the whole application (observed: the process
  /// exited right after docking, taking the main window with it).
  ///
  /// `setPreventClose(false)` + `close()` only posts `SC_CLOSE` to *this*
  /// window. DefWindowProc turns it into `WM_CLOSE`/`WM_DESTROY`, which is the
  /// documented teardown path of the plugin window: the secondary engine and its
  /// HWND are released and the main window is untouched.
  Future<void> _closePanelWindow() async {
    if (_closing || !widget.windowControlAvailable) return;
    _closing = true;
    try {
      await PanelWindowNativeBridge.unregisterPanel(widget.config.panelId);
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } on Object catch (error) {
      _closing = false;
      debugPrint('[panel-window] close failed: $error');
    }
  }

  @override
  void onWindowClose() {
    // The X docks the panel back and then closes this window for real, so the
    // secondary engine is released instead of lingering behind a hidden window.
    unawaited(() async {
      await _requestDockBack();
      await _closePanelWindow();
    }());
  }

  @override
  Widget build(BuildContext context) {
    final rows = (_endpoint.viewModel[PanelViewModelKeys.entities] as List?)
        ?.whereType<Map>()
        .toList(growable: false);
    final selection =
        (_endpoint.viewModel[PanelViewModelKeys.selection] as List?)
            ?.whereType<String>()
            .toSet() ??
        const <String>{};
    final status = _statusLabel();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Resolve the chrome colours from the theme *inside* the
            // MaterialApp: this State's own context sits above it and would
            // return the fallback light scheme, painting the header and the
            // footer as light strips over the dark body.
            Builder(
              builder: (context) => _header(Theme.of(context).colorScheme),
            ),
            if (_endpoint.lastOmittedKeys.isNotEmpty)
              const _Banner(
                icon: Icons.filter_list_off,
                text:
                    'Projeção parcial: a árvore completa será paginada em '
                    'uma próxima etapa.',
              ),
            if (_endpoint.viewModelIsStale)
              const _Banner(
                icon: Icons.sync_problem,
                text: 'Sessão em ressincronização…',
              ),
            if (!widget.windowControlAvailable)
              const _Banner(
                icon: Icons.warning_amber_outlined,
                text:
                    'Controle de janela indisponível neste build: '
                    'geometria automática desativada. Reencaixe pelo botão.',
              ),
            Expanded(
              child: switch (widget.config.panelId) {
                PanelId.inspector => _InspectorDetachedPanel(
                  viewModel: _endpoint.viewModel,
                  stale: _endpoint.viewModelIsStale,
                ),
                PanelId.explorer =>
                  rows == null
                      ? const Center(child: CircularProgressIndicator())
                      : rows.isEmpty
                      ? const Center(child: Text('Nenhum objeto no projeto.'))
                      : ListView.builder(
                          itemCount: rows.length,
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            final id = row['id'] as String? ?? '';
                            final selected = selection.contains(id);
                            return ListTile(
                              dense: true,
                              selected: selected,
                              title: Text(
                                row['label'] as String? ?? id,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${row['kind']}'
                                '${row['visible'] == false ? ' · oculto' : ''}',
                              ),
                              onTap: id.isEmpty
                                  ? null
                                  : () => _endpoint.setSelection([id]),
                            );
                          },
                        ),
                _ => const _UnsupportedDetachedPanel(),
              },
            ),
            Builder(
              builder: (context) => _footer(
                Theme.of(context).colorScheme,
                selection.length,
                status,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(ColorScheme scheme) => Container(
    key: const ValueKey('panel-header'),
    height: 38,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    color: scheme.surfaceContainerHigh,
    child: Row(
      children: [
        Icon(
          widget.config.panelId == PanelId.inspector
              ? Icons.tune
              : Icons.account_tree,
          size: 16,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            panelDescriptor(widget.config.panelId).title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
        TextButton.icon(
          onPressed: _requestDockBack,
          icon: const Icon(Icons.push_pin_outlined, size: 14),
          label: const Text('Reencaixar'),
        ),
      ],
    ),
  );

  Widget _footer(
    ColorScheme scheme,
    int selectedCount,
    String status,
  ) => Container(
    key: const ValueKey('panel-footer'),
    height: 26,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    color: scheme.surfaceContainerHigh,
    child: Row(
      children: [
        Expanded(
          child: Text(
            '$status · $selectedCount sel.',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            'rev ${_endpoint.revision} · sessão ${_endpoint.sessionId ?? '-'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 10),
          ),
        ),
      ],
    ),
  );

  String _statusLabel() => switch (_endpoint.lifecycle) {
    PanelLifecycleState.ready => 'conectado',
    PanelLifecycleState.connected => 'aguardando projeto',
    PanelLifecycleState.suspended => 'suspenso',
    PanelLifecycleState.disconnected => 'desconectado',
  };
}

/// Placeholder for panel identities whose detached renderer is intentionally
/// not part of MM4.3a.1 yet. It prevents an unsupported panel from presenting
/// Explorer data by accident.
class _UnsupportedDetachedPanel extends StatelessWidget {
  const _UnsupportedDetachedPanel();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(20),
      child: Text('Este painel ainda não possui renderer destacável.'),
    ),
  );
}

class _InspectorDetachedPanel extends StatelessWidget {
  const _InspectorDetachedPanel({required this.viewModel, required this.stale});

  final Map<String, Object?> viewModel;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final state =
        viewModel[PanelInspectorViewModelKeys.selectionState] as String? ??
        'none';
    final document =
        viewModel[PanelInspectorViewModelKeys.documentEntity] as Map?;
    final operational =
        (viewModel[PanelInspectorViewModelKeys.operationalEntities] as List?)
            ?.whereType<Map>()
            .toList(growable: false) ??
        const <Map>[];
    final message = switch (state) {
      'none' => 'Nenhuma entidade selecionada.',
      'multiple' => 'Seleção múltipla: propriedades individuais indisponíveis.',
      'unavailable' => 'A entidade selecionada não está disponível.',
      _ => null,
    };
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (stale) const _InspectorNotice('Atualizando a seleção…'),
        if (message != null)
          _InspectorNotice(message)
        else ...[
          if (document != null) _InspectorEntityCard(entity: document),
          for (final entity in operational)
            _InspectorEntityCard(entity: entity),
        ],
      ],
    );
  }
}

class _InspectorNotice extends StatelessWidget {
  const _InspectorNotice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Text(text, textAlign: TextAlign.center),
  );
}

class _InspectorEntityCard extends StatelessWidget {
  const _InspectorEntityCard({required this.entity});

  final Map entity;

  @override
  Widget build(BuildContext context) {
    final rawProperties = entity['properties'];
    final properties = rawProperties is Map ? rawProperties : const {};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entity['name'] as String? ??
                  entity['id'] as String? ??
                  'Entidade',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '${entity['type'] ?? '-'} · ${entity['selectionDomain'] ?? '-'}',
            ),
            for (final entry in properties.entries)
              _InspectorPropertyRow(
                name: entry.key.toString(),
                value: entry.value,
              ),
          ],
        ),
      ),
    );
  }
}

class _InspectorPropertyRow extends StatelessWidget {
  const _InspectorPropertyRow({required this.name, required this.value});

  final String name;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    final rawValue = value;
    final display = rawValue is Map && rawValue['display'] is String
        ? rawValue['display'] as String
        : rawValue.toString();
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(name, style: const TextStyle(fontSize: 11))),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Row(
      children: [
        Icon(icon, size: 14),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 10.5))),
      ],
    ),
  );
}
