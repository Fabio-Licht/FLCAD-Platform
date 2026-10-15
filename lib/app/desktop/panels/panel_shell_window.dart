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
import 'panel_inspector_widgets.dart';
import 'panel_presentation_models.dart';
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
      PanelId.inspector => const [PanelCapabilities.inspectorEdit],
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
    final explorer = ExplorerTreeModel.fromSnapshot(_endpoint.viewModel);
    final selectedCount = {
      ...explorer.documentSelection,
      ...explorer.operationalSelection,
    }.length;
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
                  onDimensionSubmitted: (entityId, value) => _endpoint
                      .editDrivingDimension(entityId: entityId, value: value),
                ),
                PanelId.explorer => _ExplorerDetachedPanel(
                  model: explorer,
                  onSelect: (id) => _endpoint.setSelection([id]),
                ),
                /*
                                '${row['visible'] == false ? ' · oculto' : ''}',
                              ),
                */
                _ => const _UnsupportedDetachedPanel(),
              },
            ),
            Builder(
              builder: (context) =>
                  _footer(Theme.of(context).colorScheme, selectedCount, status),
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

class _ExplorerDetachedPanel extends StatefulWidget {
  const _ExplorerDetachedPanel({required this.model, required this.onSelect});

  final ExplorerTreeModel model;
  final ValueChanged<String> onSelect;

  @override
  State<_ExplorerDetachedPanel> createState() => _ExplorerDetachedPanelState();
}

class _ExplorerDetachedPanelState extends State<_ExplorerDetachedPanel> {
  final Set<String> _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    if (widget.model.groups.every((group) => group.nodes.isEmpty)) {
      return const Center(child: Text('Nenhum objeto no projeto.'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final group in widget.model.groups)
          ExpansionTile(
            key: PageStorageKey<String>('explorer-group:${group.id}'),
            initiallyExpanded: _expanded.contains(group.id),
            onExpansionChanged: (expanded) => setState(() {
              if (expanded) {
                _expanded.add(group.id);
              } else {
                _expanded.remove(group.id);
              }
            }),
            dense: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: const Icon(Icons.folder_outlined, size: 17),
            title: Text(
              group.label,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            children: [
              for (final node in _orderedNodes(group.nodes)) _nodeTile(node),
            ],
          ),
      ],
    );
  }

  List<ExplorerNodeModel> _orderedNodes(List<ExplorerNodeModel> nodes) {
    final byParent = <String?, List<ExplorerNodeModel>>{};
    for (final node in nodes) {
      (byParent[node.parentId] ??= <ExplorerNodeModel>[]).add(node);
    }
    final ordered = <ExplorerNodeModel>[];
    void visit(String? parent) {
      for (final node in byParent[parent] ?? const <ExplorerNodeModel>[]) {
        ordered.add(node);
        visit(node.id);
      }
    }

    visit(null);
    for (final node in nodes) {
      if (!ordered.contains(node)) ordered.add(node);
    }
    return ordered;
  }

  Widget _nodeTile(ExplorerNodeModel node) {
    final selected =
        widget.model.documentSelection.contains(node.id) ||
        widget.model.operationalSelection.contains(node.id);
    return ListTile(
      dense: true,
      minTileHeight: 29,
      visualDensity: const VisualDensity(vertical: -4),
      contentPadding: const EdgeInsets.only(left: 30, right: 8),
      selected: selected,
      leading: Icon(_iconFor(node.iconSemantic), size: 16),
      title: Text(
        node.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      subtitle: Text(
        '${InspectorPresentationLabels.nodeKind(node.kind)}${node.visible ? '' : ' · oculto'}',
        style: const TextStyle(fontSize: 9),
      ),
      onTap: node.available ? () => widget.onSelect(node.id) : null,
    );
  }

  IconData _iconFor(String semantic) => switch (semantic) {
    'mesh' => Icons.grid_on,
    'solid' => Icons.view_in_ar_outlined,
    'surface' => Icons.layers_outlined,
    'sketch' => Icons.gesture,
    'curve' => Icons.show_chart,
    'plane' => Icons.crop_landscape,
    'axis' => Icons.swap_vert,
    'point' => Icons.circle_outlined,
    'coordinateSystem' => Icons.my_location,
    'section' => Icons.content_cut,
    _ => Icons.category_outlined,
  };
}

class _InspectorDetachedPanel extends StatelessWidget {
  const _InspectorDetachedPanel({
    required this.viewModel,
    required this.stale,
    required this.onDimensionSubmitted,
  });

  final Map<String, Object?> viewModel;
  final bool stale;
  final Future<String> Function(String entityId, double value)
  onDimensionSubmitted;

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
    final structured =
        viewModel[PanelInspectorViewModelKeys.presentation] is Map
        ? InspectorPresentationModel.fromJson(
            Map<String, Object?>.from(
              viewModel[PanelInspectorViewModelKeys.presentation] as Map,
            ),
          )
        : InspectorPresentationModel.fromSnapshot(viewModel);
    final structuredById = {
      for (final entity in structured.entities) entity.id: entity,
    };
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
          if (document != null)
            _SharedInspectorEntityCard(
              entity: document,
              presentation: structuredById[document['id']],
              onDimensionSubmitted: onDimensionSubmitted,
              enabled: !stale,
            ),
          for (final entity in operational)
            _SharedInspectorEntityCard(
              entity: entity,
              presentation: structuredById[entity['id']],
            ),
        ],
      ],
    );
  }
}

class _SharedInspectorEntityCard extends StatefulWidget {
  const _SharedInspectorEntityCard({
    required this.entity,
    required this.presentation,
    this.onDimensionSubmitted,
    this.enabled = false,
  });

  final Map entity;
  final InspectorEntityModel? presentation;
  final Future<String> Function(String entityId, double value)?
  onDimensionSubmitted;
  final bool enabled;

  @override
  State<_SharedInspectorEntityCard> createState() =>
      _SharedInspectorEntityCardState();
}

class _SharedInspectorEntityCardState
    extends State<_SharedInspectorEntityCard> {
  bool _advanced = false;

  @override
  Widget build(BuildContext context) {
    final model = widget.presentation;
    if (model == null) {
      return const _InspectorNotice('Propriedades indisponíveis.');
    }
    final sections = model.sections
        .where((section) => section.advanced == _advanced)
        .where((section) => section.properties.isNotEmpty);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InspectorEntityHeader(entity: model),
            const SizedBox(height: 8),
            InspectorModeSelector(
              advanced: _advanced,
              onChanged: (value) => setState(() => _advanced = value),
            ),
            const SizedBox(height: 8),
            for (final section in sections) ...[
              InspectorPropertySection(
                section: section,
                children: [
                  for (final property in section.properties)
                    _propertyWidget(model, property),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _propertyWidget(
    InspectorEntityModel model,
    InspectorPropertyModel property,
  ) {
    if (property.id == 'drivingDimension' &&
        property.access == PanelPropertyAccess.editable &&
        widget.onDimensionSubmitted != null &&
        property.value is num) {
      return InspectorNumericEditor(
        label: property.label,
        value: (property.value as num).toDouble(),
        unit: property.unit ?? 'mm',
        precision: property.precision,
        enabled:
            widget.enabled &&
            property.availability == PanelPropertyAvailability.available,
        onSubmitted: (value) => widget.onDimensionSubmitted!(model.id, value),
      );
    }
    return InspectorPropertyRow(property: property);
  }
}

class _StructuredInspectorEntityCard extends StatefulWidget {
  const _StructuredInspectorEntityCard({
    required this.entity,
    required this.presentation,
    required this.onDimensionSubmitted,
    required this.enabled,
  });

  final Map entity;
  final InspectorEntityModel? presentation;
  final Future<String> Function(String entityId, double value)?
  onDimensionSubmitted;
  final bool enabled;

  @override
  State<_StructuredInspectorEntityCard> createState() =>
      _StructuredInspectorEntityCardState();
}

class _StructuredInspectorEntityCardState
    extends State<_StructuredInspectorEntityCard> {
  bool _advanced = false;

  @override
  Widget build(BuildContext context) {
    final model = widget.presentation;
    if (model == null) return _InspectorEntityCard(entity: widget.entity);
    final sections = model.sections
        .where((section) => section.advanced == _advanced)
        .where((section) => section.properties.isNotEmpty);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              model.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '${model.type} · ${InspectorPresentationLabels.selectionDomain(model.selectionDomain)}',
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Básico')),
                ButtonSegment(value: true, label: Text('Avançado')),
              ],
              selected: {_advanced},
              onSelectionChanged: (value) =>
                  setState(() => _advanced = value.first),
            ),
            const SizedBox(height: 8),
            for (final section in sections) ...[
              _DetachedInspectorSection(
                title: InspectorPresentationLabels.section(section.label),
                children: [
                  for (final property in section.properties)
                    if (property.id == 'drivingDimension' &&
                        property.access == PanelPropertyAccess.editable &&
                        widget.onDimensionSubmitted != null)
                      _InspectorDimensionEditor(
                        entityId: model.id,
                        dimension: {
                          'value': property.value,
                          'unit': property.unit ?? 'mm',
                        },
                        enabled: widget.enabled,
                        onSubmitted: widget.onDimensionSubmitted!,
                      )
                    else
                      _InspectorPropertyRow(
                        name: property.label,
                        value:
                            property.availability ==
                                PanelPropertyAvailability.unavailable
                            ? 'Indisponível'
                            : TechnicalValueFormatter.format(
                                property.value,
                                unit: property.unit,
                                precision: property.precision,
                              ),
                      ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetachedInspectorSection extends StatelessWidget {
  const _DetachedInspectorSection({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const Divider(height: 12),
          ...children,
        ],
      ),
    ),
  );
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
              '${entity['type'] ?? '-'} · ${InspectorPresentationLabels.selectionDomain(entity['selectionDomain']?.toString() ?? '-')}',
            ),
            for (final entry in properties.entries)
              _InspectorPropertyRow(
                name: InspectorPresentationLabels.property(
                  entry.key.toString(),
                ),
                value: entry.value,
              ),
          ],
        ),
      ),
    );
  }
}

class _InspectorDimensionEditor extends StatefulWidget {
  const _InspectorDimensionEditor({
    required this.entityId,
    required this.dimension,
    required this.enabled,
    required this.onSubmitted,
  });

  final String entityId;
  final Map<Object?, Object?> dimension;
  final bool enabled;
  final Future<String> Function(String entityId, double value) onSubmitted;

  @override
  State<_InspectorDimensionEditor> createState() =>
      _InspectorDimensionEditorState();
}

class _InspectorDimensionEditorState extends State<_InspectorDimensionEditor> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: (widget.dimension['value'] as num?)?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(String raw) async {
    final value = double.tryParse(raw.trim());
    if (value == null || !value.isFinite || value <= 0) {
      setState(() => _error = 'Valor positivo inválido');
      return;
    }
    setState(() => _error = null);
    try {
      await widget.onSubmitted(widget.entityId, value);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 5),
    child: TextField(
      controller: _controller,
      enabled: widget.enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: 'Cota controladora (${widget.dimension['unit'] ?? 'mm'})',
        errorText: _error,
        isDense: true,
      ),
      onSubmitted: _submit,
    ),
  );
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
