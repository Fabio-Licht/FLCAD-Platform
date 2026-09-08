import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/cad_kernel/manager/kernel_manager.dart';
import '../../core/cad_document/cad_document.dart';
import '../../core/feature_lifecycle/feature_lifecycle.dart';
import '../../core/geometric_kernel/geometry/vectors.dart';
import '../../core/professional_recognition/api/professional_recognition_api.dart';
import '../../core/professional_extrude/professional_extrude.dart';
import '../../core/professional_revolve/professional_revolve.dart';
import '../../core/professional_surface/models/professional_surface_models.dart';
import '../../core/sketch_constraints/models/constraint_models.dart';
import '../../core/sketch_editor/inferencing/sketch_inference_engine.dart';
import '../../core/sketch_assistant/sketch_assistant.dart';
import '../../core/recognition_engine/recognition_result.dart';
import '../../core/reverse_engineering_studio/reverse_engineering_studio.dart';
import '../../core/sketch_editor/health/sketch_health_analyzer.dart';
import '../../core/sketch_editor/models/editor_models.dart';
import '../../core/sketch_engine/entities/sketch_entities.dart';
import '../../core/sketch_engine/models/sketch_models.dart';
import '../../core/surface_generation/models/surface_topology.dart';
import '../../features/projects/domain/project_manager.dart';
import '../../features/projects/models/project.dart';
import '../bootstrap/app_bootstrap.dart';
import '../bootstrap/engineering_bootstrap.dart';
import '../cad_viewport/camera/cad_camera_controller.dart';
import '../cad_viewport/native/integrated_native_viewport_widget.dart';
import '../cad_viewport/scene/cad_scene_graph.dart';
import '../cad_viewport/selection/viewport_picking_controller.dart';
import '../commands/desktop_command_coordinator.dart';
import '../engineering_bridge/operational_reverse_engineering_controller.dart';
import '../engineering_bridge/selection/geometry_selection_manager.dart';
import '../engineering_bridge/widgets/recognition_workspace_panel.dart';
import '../engineering_bridge/widgets/reverse_engineering_studio_panel.dart';
import '../engineering_bridge/widgets/sketch_surface_workspace_panel.dart';
import '../entities/entity_point_service.dart';
import '../entities/entity_plane_service.dart';
import '../entities/entity_vector_service.dart';
import '../entities/entity_curve_service.dart';
import '../entities/entity_primitive_surface_service.dart';
import '../modeling/modeling.dart';
import '../modeling/entity_edit_contract.dart';
import '../navigation/cad_camera_navigation_adapter.dart';
import '../navigation/navigation_engine.dart';
import '../operational_entities/operational_entity.dart';
import '../reconstruction/desktop_colmap_lab_runtime.dart';
import '../runtime/cad_runtime.dart';
import 'desktop_asset_manager.dart';
import 'desktop_cad_controller.dart';
import 'desktop_settings.dart';
import 'desktop_theme.dart';

class FLCADDesktopApplication extends StatefulWidget {
  const FLCADDesktopApplication({
    super.key,
    this.settingsRepository,
    this.splashStep = const Duration(milliseconds: 250),
    this.colmapLabRuntimeFactory,
    this.platformInitializer,
  });
  final DesktopSettingsRepository? settingsRepository;
  final Duration splashStep;
  final DesktopColmapLabRuntimeFactory? colmapLabRuntimeFactory;
  final Future<void> Function()? platformInitializer;
  @override
  State<FLCADDesktopApplication> createState() =>
      _FLCADDesktopApplicationState();
}

class _FLCADDesktopApplicationState extends State<FLCADDesktopApplication> {
  DesktopSettingsController? controller;
  Object? startupError;
  DesktopColmapLabRuntime? colmapLabRuntime;
  Object? colmapLabStartupError;
  bool colmapLabInitializing = false;
  final ChangeNotifier emptyController = ChangeNotifier();
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final repository =
          widget.settingsRepository ??
          JsonDesktopSettingsRepository(await getApplicationSupportDirectory());
      await (widget.platformInitializer ?? _initializePlatform)();
      final value = DesktopSettingsController(
        repository,
        await repository.load(),
      );
      if (!mounted) {
        value.dispose();
        return;
      }
      setState(() {
        controller = value;
        colmapLabInitializing = true;
      });
      unawaited(_initializeColmapLab());
    } catch (error) {
      if (mounted) setState(() => startupError = error);
    }
  }

  Future<void> _initializePlatform() async {
    await DesktopAssetManager(rootBundle).validate();
    await AppBootstrap.instance.initialize();
  }

  Future<void> _initializeColmapLab() async {
    DesktopColmapLabRuntime? runtime;
    Object? error;
    try {
      runtime =
          await (widget.colmapLabRuntimeFactory ??
              DesktopColmapLabRuntime.create)();
    } catch (caught) {
      error = caught;
    }
    if (!mounted) {
      runtime?.dispose();
      return;
    }
    setState(() {
      colmapLabRuntime = runtime;
      colmapLabStartupError = error;
      colmapLabInitializing = false;
    });
  }

  @override
  void dispose() {
    emptyController.dispose();
    colmapLabRuntime?.dispose();
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = controller;
    return AnimatedBuilder(
      animation: value ?? emptyController,
      builder: (context, _) => MaterialApp(
        title: 'FLCAD Reverse AI',
        debugShowCheckedModeBanner: false,
        theme: DesktopThemeManager.light(),
        darkTheme: DesktopThemeManager.dark(),
        themeMode: value?.settings.theme == DesktopThemePreference.light
            ? ThemeMode.light
            : ThemeMode.dark,
        home: startupError != null
            ? _StartupFailure(error: startupError!)
            : value == null
            ? const _StartupLoading()
            : DesktopStartupSequence(
                controller: value,
                stepDuration: widget.splashStep,
                colmapLabBuilder: colmapLabRuntime?.buildLab,
                colmapLabStartupError: colmapLabStartupError,
                colmapLabInitializing: colmapLabInitializing,
              ),
      ),
    );
  }
}

class _StartupLoading extends StatelessWidget {
  const _StartupLoading();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.error});
  final Object error;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Semantics(
        label: 'Desktop startup failed',
        child: Text(
          'Unable to start FLCAD Reverse AI\n$error',
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}

class DesktopStartupSequence extends StatefulWidget {
  const DesktopStartupSequence({
    super.key,
    required this.controller,
    required this.stepDuration,
    this.colmapLabBuilder,
    this.colmapLabStartupError,
    this.colmapLabInitializing = false,
  });
  final DesktopSettingsController controller;
  final Duration stepDuration;
  final WidgetBuilder? colmapLabBuilder;
  final Object? colmapLabStartupError;
  final bool colmapLabInitializing;
  @override
  State<DesktopStartupSequence> createState() => _DesktopStartupSequenceState();
}

class _DesktopStartupSequenceState extends State<DesktopStartupSequence> {
  static const messages = [
    'Initializing Project System...',
    'Loading Geometry Kernel...',
    'Loading AI Engineering...',
    'Loading Recognition Engine...',
    'Loading Workspaces...',
    'Loading User Interface...',
    'Ready.',
  ];
  int index = 0;
  bool complete = false;
  @override
  void initState() {
    super.initState();
    _advance();
  }

  Future<void> _advance() async {
    for (var next = 0; next < messages.length; next++) {
      await Future<void>.delayed(widget.stepDuration);
      if (!mounted) return;
      setState(() => index = next);
    }
    if (mounted) setState(() => complete = true);
  }

  @override
  Widget build(BuildContext context) {
    if (complete) {
      return widget.controller.settings.firstRunCompleted
          ? DesktopShell(
              controller: widget.controller,
              colmapLabBuilder: widget.colmapLabBuilder,
              colmapLabStartupError: widget.colmapLabStartupError,
              colmapLabInitializing: widget.colmapLabInitializing,
            )
          : FirstRunWizard(controller: widget.controller);
    }
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                duration: widget.stepDuration * 2,
                tween: Tween(begin: .85, end: 1),
                builder: (context, value, child) =>
                    Transform.scale(scale: value, child: child),
                child: Image.asset(
                  DesktopAssets.splashTransformation,
                  width: 176,
                  height: 176,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'FLCAD Reverse AI',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Engineering Intelligence Platform',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: scheme.primary),
              ),
              const SizedBox(height: 32),
              LinearProgressIndicator(value: (index + 1) / messages.length),
              const SizedBox(height: 12),
              Text(messages[index], key: const Key('splash-status')),
            ],
          ),
        ),
      ),
    );
  }
}

class FirstRunWizard extends StatefulWidget {
  const FirstRunWizard({super.key, required this.controller});
  final DesktopSettingsController controller;
  @override
  State<FirstRunWizard> createState() => _FirstRunWizardState();
}

class _FirstRunWizardState extends State<FirstRunWizard> {
  int step = 0;
  late String language = widget.controller.settings.language;
  late DesktopThemePreference theme = widget.controller.settings.theme;
  late final directory = TextEditingController(
    text: widget.controller.settings.defaultDirectory,
  );
  @override
  void dispose() {
    directory.dispose();
    super.dispose();
  }

  Future<void> _finish() => widget.controller.update(
    widget.controller.settings.copyWith(
      language: language,
      theme: theme,
      defaultDirectory: directory.text.trim(),
      firstRunCompleted: true,
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Welcome to FLCAD Reverse AI')),
    body: Center(
      child: SizedBox(
        width: 720,
        child: Stepper(
          currentStep: step,
          onStepContinue: () async {
            if (step < 2) {
              setState(() => step++);
            } else {
              await _finish();
            }
          },
          onStepCancel: step == 0 ? null : () => setState(() => step--),
          controlsBuilder: (context, details) => Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Row(
              children: [
                FilledButton(
                  key: ValueKey('wizard-continue-${details.stepIndex}'),
                  onPressed: details.onStepContinue,
                  child: Text(step == 2 ? 'Finish' : 'Continue'),
                ),
                if (details.onStepCancel != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: details.onStepCancel,
                    child: const Text('Back'),
                  ),
                ],
              ],
            ),
          ),
          steps: [
            Step(
              title: const Text('Language'),
              content: DropdownButtonFormField<String>(
                initialValue: language,
                items: const [
                  DropdownMenuItem(
                    value: 'pt-BR',
                    child: Text('Português (Brasil)'),
                  ),
                  DropdownMenuItem(value: 'en-US', child: Text('English')),
                ],
                onChanged: (value) => setState(() => language = value!),
              ),
            ),
            Step(
              title: const Text('Theme'),
              content: SegmentedButton<DesktopThemePreference>(
                segments: const [
                  ButtonSegment(
                    value: DesktopThemePreference.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode),
                  ),
                  ButtonSegment(
                    value: DesktopThemePreference.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode),
                  ),
                ],
                selected: {theme},
                onSelectionChanged: (value) =>
                    setState(() => theme = value.single),
              ),
            ),
            Step(
              title: const Text('Default directory'),
              content: TextField(
                controller: directory,
                decoration: const InputDecoration(
                  labelText: 'Project directory',
                  hintText: 'Choose a project directory in Settings',
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.controller,
    this.colmapLabBuilder,
    this.colmapLabStartupError,
    this.colmapLabInitializing = false,
  });
  final DesktopSettingsController controller;
  final WidgetBuilder? colmapLabBuilder;
  final Object? colmapLabStartupError;
  final bool colmapLabInitializing;
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  int destination = 0;
  late final DesktopCadController cad;
  late final DesktopCommandCoordinator commands;
  @override
  void initState() {
    super.initState();
    EngineeringBootstrap.instance.initialize();
    cad = DesktopCadController(
      kernels: EngineeringBootstrap.instance.services.get<KernelManager>(),
      projects: ProjectManager.instance,
    );
    commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    unawaited(
      commands.initialize().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    cad.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      DesktopHomeDashboard(
        onWorkspace: () => setState(() => destination = 1),
        controller: widget.controller,
        commands: commands,
      ),
      OfficialEngineeringWorkspace(cad: cad, commands: commands),
      DesktopSettingsScreen(
        controller: widget.controller,
        colmapLabBuilder: widget.colmapLabBuilder,
        colmapLabStartupError: widget.colmapLabStartupError,
        colmapLabInitializing: widget.colmapLabInitializing,
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Image.asset(DesktopAssets.logo, width: 34, height: 34),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FLCAD Reverse AI',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                Text(
                  'Engineering Intelligence Platform',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Arquivo',
            onSelected: (value) async {
              final parts = value.split(':');
              await commands.dispatch('${parts.first}.${parts.last}');
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'project:save',
                child: Text('Salvar Projeto'),
              ),
              PopupMenuItem(
                value: 'project:close',
                child: Text('Fechar Projeto'),
              ),
              PopupMenuDivider(),
              PopupMenuItem(enabled: false, child: Text('Importar')),
              PopupMenuItem(value: 'import:stl', child: Text('STL')),
              PopupMenuItem(value: 'import:step', child: Text('STEP')),
              PopupMenuItem(value: 'import:iges', child: Text('IGES')),
              PopupMenuDivider(),
              PopupMenuItem(enabled: false, child: Text('Exportar')),
              PopupMenuItem(value: 'export:step', child: Text('STEP')),
              PopupMenuItem(value: 'export:iges', child: Text('IGES')),
              PopupMenuItem(value: 'export:stl', child: Text('STL')),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined),
                  SizedBox(width: 6),
                  Text('Arquivo'),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Undo',
            onPressed: commands.undo,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: commands.redo,
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            tooltip: 'About',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const AboutFLCADDialog(),
            ),
            icon: const Icon(Icons.info_outline),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: destination,
            onDestinationSelected: (value) =>
                setState(() => destination = value),
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: Text('Home'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.view_quilt_outlined),
                selectedIcon: Icon(Icons.view_quilt),
                label: Text('Workspace'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('Settings'),
              ),
            ],
          ),
          const VerticalDivider(),
          Expanded(child: screens[destination]),
        ],
      ),
    );
  }
}

class DesktopHomeDashboard extends StatefulWidget {
  const DesktopHomeDashboard({
    super.key,
    required this.onWorkspace,
    required this.controller,
    required this.commands,
  });
  final VoidCallback onWorkspace;
  final DesktopSettingsController controller;
  final DesktopCommandCoordinator commands;

  @override
  State<DesktopHomeDashboard> createState() => _DesktopHomeDashboardState();
}

class _DesktopHomeDashboardState extends State<DesktopHomeDashboard> {
  bool creatingProject = false;
  Completer<void>? projectDialogCompletion;
  DesktopSettingsController get controller => widget.controller;
  DesktopCommandCoordinator get commands => widget.commands;
  VoidCallback get onWorkspace => widget.onWorkspace;

  Future<void> _newProject(BuildContext context) async {
    if (!creatingProject) {
      projectDialogCompletion = Completer<void>();
      setState(() => creatingProject = true);
    }
    await projectDialogCompletion?.future;
  }

  void _cancelProject() {
    setState(() => creatingProject = false);
    projectDialogCompletion?.complete();
    projectDialogCompletion = null;
  }

  Future<void> _createProject(String name, String client) async {
    await commands.createProject(name, client);
    if (!mounted) return;
    setState(() => creatingProject = false);
    projectDialogCompletion?.complete();
    projectDialogCompletion = null;
    onWorkspace();
  }

  Future<void> _openProject(BuildContext context) async {
    await commands.projects.initialize(restoreCurrent: false);
    if (!context.mounted) return;
    final project = await showDialog<Project>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Open Project'),
        children: [
          for (final project in commands.projects.visibleProjects)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, project),
              child: ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(project.name),
                subtitle: Text(project.client),
              ),
            ),
          if (commands.projects.visibleProjects.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No projects available.'),
            ),
        ],
      ),
    );
    if (project != null) {
      await commands.openProject(project);
      onWorkspace();
    }
  }

  Future<bool> _ensureProject(BuildContext context) async {
    if (commands.projects.current != null) return true;
    await _newProject(context);
    return commands.projects.current != null;
  }

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.all(32),
          children: [
            Text(
              'Home Dashboard',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'FLCAD Reverse AI 0.9.1 Alpha · FLCAD MODEL',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 28),
            Wrap(
              spacing: 14,
              runSpacing: 14,
              children: [
                _DashboardAction(
                  icon: Icons.add_box_outlined,
                  label: 'Novo Projeto',
                  onTap: () => _newProject(context),
                ),
                _DashboardAction(
                  icon: Icons.folder_open,
                  label: 'Abrir Projeto',
                  onTap: () => _openProject(context),
                ),
                _DashboardAction(
                  icon: Icons.grid_on,
                  label: 'Importar STL',
                  onTap: () async {
                    if (!await _ensureProject(context)) return;
                    onWorkspace();
                    await commands.refreshContext();
                    await commands.dispatch('import.stl');
                  },
                ),
                _DashboardAction(
                  icon: Icons.view_in_ar,
                  label: 'Importar STEP',
                  onTap: () async {
                    if (!await _ensureProject(context)) return;
                    onWorkspace();
                    await commands.refreshContext();
                    await commands.dispatch('import.step');
                  },
                ),
                _DashboardAction(
                  icon: Icons.tune,
                  label: 'Configurações',
                  onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Use Settings in the navigation rail.'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            Text(
              'Projetos Recentes',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            if (commands.projects.visibleProjects.isEmpty)
              const _EmptyState(
                icon: Icons.history,
                message:
                    'No recent projects. Open or create a project to begin.',
              )
            else
              for (final project in commands.projects.visibleProjects.take(8))
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(project.name),
                  subtitle: Text(project.client),
                  onTap: () async {
                    await commands.openProject(project);
                    onWorkspace();
                  },
                ),
            if (settings.engineeringTips) ...[
              const SizedBox(height: 24),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.lightbulb_outline),
                  title: const Text('Engineering tip'),
                  subtitle: const Text(
                    'Validate the project coordinate system before reconstruction.',
                  ),
                  trailing: IconButton(
                    tooltip: 'Disable tips',
                    onPressed: () => controller.update(
                      settings.copyWith(engineeringTips: false),
                    ),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: onWorkspace,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Open Engineering Workspace'),
            ),
          ],
        ),
        if (creatingProject)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black54,
              child: Center(
                child: _InlineNewProjectPanel(
                  onCancel: _cancelProject,
                  onCreate: _createProject,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _InlineNewProjectPanel extends StatefulWidget {
  const _InlineNewProjectPanel({
    required this.onCancel,
    required this.onCreate,
  });
  final VoidCallback onCancel;
  final Future<void> Function(String name, String client) onCreate;

  @override
  State<_InlineNewProjectPanel> createState() => _InlineNewProjectPanelState();
}

class _InlineNewProjectPanelState extends State<_InlineNewProjectPanel> {
  final name = TextEditingController();
  final client = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    name.dispose();
    client.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final projectName = name.text.trim();
    if (projectName.isEmpty || busy) return;
    setState(() => busy = true);
    try {
      await widget.onCreate(projectName, client.text.trim());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    elevation: 12,
    child: SizedBox(
      width: 460,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New Project', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 20),
            TextField(
              controller: name,
              autofocus: true,
              onSubmitted: (_) => _create(),
              decoration: const InputDecoration(labelText: 'Project name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: client,
              onSubmitted: (_) => _create(),
              decoration: const InputDecoration(labelText: 'Client'),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: busy ? null : widget.onCancel,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : _create,
                  child: busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _DashboardAction extends StatelessWidget {
  const _DashboardAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 180,
    height: 104,
    child: Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon),
              const Spacer(),
              Text(label, style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
        ),
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});
  final IconData icon;
  final String message;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ],
      ),
    ),
  );
}

class OfficialEngineeringWorkspace extends StatefulWidget {
  const OfficialEngineeringWorkspace({
    super.key,
    required this.cad,
    required this.commands,
  });
  final DesktopCadController cad;
  final DesktopCommandCoordinator commands;
  @override
  State<OfficialEngineeringWorkspace> createState() =>
      _OfficialEngineeringWorkspaceState();
}

class _OfficialEngineeringWorkspaceState
    extends State<OfficialEngineeringWorkspace> {
  String module = 'AI Engineering';
  ProfessionalSurfaceTool? toolbarSurfaceTool;
  int toolbarEntityConstructor = 0;
  PrimitiveSurfaceType? toolbarPrimitiveType;
  final Set<String> openToolWindows = <String>{};
  final modelingViewport = ModelingViewportController();
  CadSceneGraph get scene => widget.cad.runtime.scene;
  final camera = CadCameraController();
  late final NavigationEngine navigation;
  GeometrySelectionManager get geometrySelection =>
      widget.cad.runtime.geometrySelection;
  late final OperationalReverseEngineeringController operational;
  String? fittedDocumentId;
  final transformX = TextEditingController(text: '10');
  final transformY = TextEditingController(text: '0');
  final transformZ = TextEditingController(text: '0');
  final transformAngle = TextEditingController(text: '15');
  final transformScaleX = TextEditingController(text: '1.1');
  final transformScaleY = TextEditingController(text: '1.1');
  final transformScaleZ = TextEditingController(text: '1.1');
  final surfaceOffset = TextEditingController(text: '1.0');
  final sectionOffset = TextEditingController(text: '0.0');
  double rememberedSplineTolerance = 0.05;
  double sectionOffsetValue = 0;
  bool rememberSplineConfiguration = false;
  bool automaticSplinePreview = true;
  bool advancedInspector = false;
  bool choosingSketchSupport = false;
  static const modules = [
    'Reverse Engineering',
    'AI Engineering',
    'Recognition',
    'Reference',
    'Entidades',
    'Sketch',
    'Curves',
    'Surfaces',
    'Solids',
    'Sections',
    'Transform',
  ];
  ModelingSelection? get documentSelection {
    final document = widget.cad.document;
    if (document == null) return null;
    return ModelingSelection(
      id: document.id,
      name: document.sourcePath.split(RegExp(r'[/\\]')).last,
      type: document.isMesh
          ? ModelingSelectionType.meshRegion
          : ModelingSelectionType.feature,
      sourceIds: [document.registeredPath],
      evidence: document.isMesh
          ? ['${document.mesh!.triangleCount} kernel triangles']
          : ['Validated ${document.shape!.type.name} kernel shape'],
    );
  }

  Widget? _operationalInspector() {
    final entity = widget.cad.runtime.operationalSelection.active;
    if (entity == null) return null;
    final basicProperties = <(String, Object?)>[
      ('Name', entity.label),
      ('Type', entity.type.name),
      ('Visibility', entity.available ? 'Visible' : 'Unavailable'),
      ('Triangles', entity.properties['triangleCount']),
      ('Area', entity.properties['area']),
      ('Volume', entity.properties['volume']),
      ('Bounding Box', entity.properties['boundingBox']),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Basic')),
            ButtonSegment(value: true, label: Text('Advanced')),
          ],
          selected: {advancedInspector},
          onSelectionChanged: (value) =>
              setState(() => advancedInspector = value.first),
        ),
        const SizedBox(height: 10),
        _InspectorSection(
          title: 'Operational Entity',
          children: [
            for (final property in basicProperties)
              if (property.$2 != null)
                _InspectorProperty(label: property.$1, value: property.$2!),
          ],
        ),
        if (advancedInspector) ...[
          const SizedBox(height: 8),
          _InspectorSection(
            title: 'Advanced',
            children: [
              _InspectorProperty(label: 'ID', value: entity.id),
              _InspectorProperty(label: 'Owner', value: entity.ownerDomain),
              _InspectorProperty(label: 'Owner ID', value: entity.ownerId),
              _InspectorProperty(label: 'Document', value: entity.documentId),
              _InspectorProperty(label: 'Revision', value: entity.revision),
              for (final property in entity.properties.entries.where(
                (entry) => !const {
                  'triangleCount',
                  'area',
                  'volume',
                  'boundingBox',
                }.contains(entry.key),
              ))
                _InspectorProperty(label: property.key, value: property.value),
            ],
          ),
        ],
      ],
    );
  }

  Widget? _documentEntityInspector() {
    final selected = geometrySelection.selectedIds;
    if (selected.isEmpty) return null;
    final entity = widget.cad.runtime.document?.entities[selected.first];
    if (entity == null) return null;
    final mesh = entity.mesh;
    final bounds = mesh?.bounds;
    final fullName = entity.kind == CadDocumentEntityKind.import
        ? entity.data['name'] as String? ??
              (entity.data['sourcePath'] as String?)
                  ?.split(RegExp(r'[/\\]'))
                  .last ??
              entity.id
        : entity.data['name'] as String? ?? entity.id;
    final shortName = fullName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Basic')),
            ButtonSegment(value: true, label: Text('Advanced')),
          ],
          selected: {advancedInspector},
          onSelectionChanged: (value) =>
              setState(() => advancedInspector = value.first),
        ),
        const SizedBox(height: 10),
        _InspectorSection(
          title: 'Identity',
          children: [
            _InspectorProperty(label: 'Name', value: shortName),
            _InspectorProperty(label: 'Type', value: entity.kind.name),
            _InspectorProperty(
              label: 'Visibility',
              value: (entity.data['sceneVisible'] as bool? ?? true)
                  ? 'Visible'
                  : 'Hidden',
            ),
          ],
        ),
        if (entity.data[FeatureLifecycleContract.dataKey]
            case final Map raw) ...[
          const SizedBox(height: 8),
          _InspectorSection(
            title: 'Feature Lifecycle',
            children: [
              _InspectorProperty(label: 'Feature ID', value: raw['featureId']),
              _InspectorProperty(label: 'State', value: raw['state']),
              _InspectorProperty(label: 'Workspace', value: raw['workspace']),
              _InspectorProperty(label: 'Created By', value: raw['createdBy']),
              _InspectorProperty(label: 'Revision', value: raw['revision']),
              _InspectorProperty(
                label: 'References',
                value: (raw['references'] as List? ?? const []).join(', '),
              ),
              _InspectorProperty(
                label: 'Children',
                value: (raw['childIds'] as List? ?? const []).join(', '),
              ),
              _InspectorProperty(
                label: 'Dependencies',
                value: (raw['dependencyIds'] as List? ?? const []).join(', '),
              ),
              _InspectorProperty(
                label: 'Used By',
                value: (raw['dependentIds'] as List? ?? const []).join(', '),
              ),
              _InspectorProperty(
                label: 'History Events',
                value: (raw['history'] as List? ?? const []).length,
              ),
            ],
          ),
        ],
        if (entity.data['sketchEntity'] case final Map raw)
          if (raw['type'] == 'line') ...[
            const SizedBox(height: 8),
            _InspectorSection(
              title: 'Line',
              children: [
                _InspectorProperty(
                  label: 'Start Point',
                  value: (raw['parameters'] as Map?)?['start'] ?? '—',
                ),
                _InspectorProperty(
                  label: 'End Point',
                  value: (raw['parameters'] as Map?)?['end'] ?? '—',
                ),
                _InspectorProperty(
                  label: 'Length',
                  value:
                      ((raw['parameters'] as Map?)?['length'] as num?)
                          ?.toStringAsFixed(3) ??
                      '—',
                ),
                _InspectorProperty(
                  label: 'Direction',
                  value: (raw['parameters'] as Map?)?['direction'] ?? '—',
                ),
                _InspectorProperty(
                  label: 'Angle',
                  value:
                      '${((raw['parameters'] as Map?)?['angleDegrees'] as num?)?.toStringAsFixed(2) ?? '—'}°',
                ),
                _InspectorProperty(
                  label: 'Layer',
                  value: (raw['parameters'] as Map?)?['layer'] ?? 'Default',
                ),
                _InspectorProperty(
                  label: 'Status',
                  value: raw['construction'] == true
                      ? 'Construction'
                      : 'Active',
                ),
              ],
            ),
          ],
        if (entity.data['dimension'] case final Map raw) ...[
          const SizedBox(height: 8),
          _InspectorSection(
            title: 'Driving Dimension',
            children: [
              _InspectorProperty(label: 'Type', value: raw['type']),
              SketchInspectorNumberProperty(
                label: 'Value',
                value: (raw['value'] as num).toDouble(),
                suffix: raw['type'] == 'angular' ? '°' : 'mm',
                onSubmitted: (value) =>
                    operational.editDrivingDimension(entity.id, value),
              ),
              SketchInspectorNumberProperty(
                label: 'Text X',
                value: (raw['labelX'] as num?)?.toDouble() ?? 0,
                onSubmitted: (value) => operational.moveDimensionLabel(
                  entity.id,
                  SketchVector(value, (raw['labelY'] as num?)?.toDouble() ?? 0),
                ),
              ),
              SketchInspectorNumberProperty(
                label: 'Text Y',
                value: (raw['labelY'] as num?)?.toDouble() ?? 0,
                onSubmitted: (value) => operational.moveDimensionLabel(
                  entity.id,
                  SketchVector((raw['labelX'] as num?)?.toDouble() ?? 0, value),
                ),
              ),
              _InspectorProperty(
                label: 'Anchor',
                value: raw['anchorReference'] ?? 'Automatic',
              ),
            ],
          ),
        ],
        if (entity.data['recognitionResult'] case final Map raw) ...[
          const SizedBox(height: 8),
          _InspectorSection(
            title: 'Recognition',
            children: [
              _InspectorProperty(label: 'Type', value: raw['type']),
              _InspectorProperty(
                label: 'Confidence',
                value:
                    '${(((raw['confidence'] as num?)?.toDouble() ?? 0) * 100).toStringAsFixed(1)}%',
              ),
              _InspectorProperty(label: 'Quality', value: raw['quality']),
              _InspectorProperty(label: 'Suggestion', value: raw['suggestion']),
              if (operational.activeSurfaceAssistantSuggestion
                  case final assistant?)
                if (assistant.recognitionResultId == entity.id)
                  _InspectorProperty(
                    label: 'Reconstruction Strategy',
                    value: assistant.strategy.name,
                  ),
              _InspectorProperty(label: 'Source Mesh', value: raw['meshId']),
              _InspectorProperty(label: 'Region', value: raw['regionId']),
              for (final parameter in Map<String, dynamic>.from(
                raw['parameters'] as Map? ?? const {},
              ).entries)
                _InspectorProperty(
                  label: parameter.key,
                  value: parameter.value,
                ),
            ],
          ),
        ],
        if (entity.data['section'] case final Map raw) ...[
          if (entity.data['referenceCurve'] == true) ...[
            const SizedBox(height: 8),
            _InspectorSection(
              title: 'Reference Curve',
              children: [
                _InspectorProperty(label: 'ID', value: entity.id),
                _InspectorProperty(
                  label: 'Source Plane',
                  value: raw['planeId'] ?? '—',
                ),
                _InspectorProperty(
                  label: 'Source Mesh',
                  value: raw['meshId'] ?? '—',
                ),
                _InspectorProperty(
                  label: 'Length',
                  value:
                      '${(raw['length'] as num?)?.toStringAsFixed(3) ?? 0} mm',
                ),
                _InspectorProperty(
                  label: 'Generated Entities',
                  value: raw['segmentCount'] ?? 0,
                ),
                _InspectorProperty(
                  label: 'State',
                  value: raw['segmentCount'] == 0 ? 'Empty' : 'Valid',
                ),
                _InspectorProperty(
                  label: 'Dynamic Update',
                  value: entity.data['dynamicUpdate'] == true
                      ? 'Enabled'
                      : 'Disabled',
                ),
                _InspectorProperty(
                  label: 'Offset',
                  value:
                      '${(raw['offset'] as num?)?.toStringAsFixed(3) ?? 0} mm',
                ),
                _InspectorProperty(
                  label: 'Display',
                  value: entity.data['displayMode'] ?? 'curveAndMesh',
                ),
              ],
            ),
          ],
        ],
        if (entity.kind == CadDocumentEntityKind.surface) ...[
          const SizedBox(height: 8),
          _InspectorSection(
            title: 'Surface Quality',
            children: [
              _InspectorProperty(
                label: 'Continuity relations',
                value:
                    (entity.data['surfaceContinuityRelations'] as List?)
                        ?.length ??
                    0,
              ),
              _InspectorProperty(
                label: 'G0',
                value:
                    operational.surfaceContinuityHealth(entity.id)['g0'] == true
                    ? '✔'
                    : '✖',
              ),
              _InspectorProperty(
                label: 'G1',
                value:
                    operational.surfaceContinuityHealth(entity.id)['g1'] == true
                    ? '✔'
                    : '✖',
              ),
              const _InspectorProperty(label: 'G2', value: '○ Prepared'),
              for (final relationId
                  in (entity.data['surfaceContinuityRelations'] as List? ??
                          const [])
                      .whereType<String>())
                if (widget
                        .cad
                        .runtime
                        .document
                        ?.entities[relationId]
                        ?.data['continuityRelation']
                    case final Map relation)
                  _InspectorProperty(
                    label: relation['firstSurfaceId'] == entity.id
                        ? '${relation['secondSurfaceId']}'
                        : '${relation['firstSurfaceId']}',
                    value:
                        '${relation['level']}'.toUpperCase() == 'DISCONNECTED'
                        ? 'No shared boundary'
                        : '${relation['level']}'.toUpperCase(),
                  ),
              for (final analysis
                  in (entity.data['surfaceAnalyses'] as List? ?? const [])
                      .whereType<Map>())
                _InspectorProperty(
                  label:
                      '${analysis['kind']}'[0].toUpperCase() +
                      '${analysis['kind']}'.substring(1),
                  value: analysis['enabled'] == true
                      ? 'On · ${((analysis['intensity'] as num?) ?? 0.7).toStringAsFixed(2)}'
                      : 'Off',
                ),
            ],
          ),
        ],
        if (entity.data['extrudeFeature'] case final Map raw) ...[
          const SizedBox(height: 8),
          _InspectorSection(
            title: 'Professional Extrude',
            children: [
              _InspectorProperty(label: 'Feature ID', value: entity.id),
              _InspectorProperty(
                label: 'Source',
                value: (raw['contract'] as Map?)?['sourceEntityId'] ?? '—',
              ),
              _InspectorProperty(
                label: 'Distance',
                value: (raw['contract'] as Map?)?['distance'] ?? 0,
              ),
              _InspectorProperty(
                label: 'Direction',
                value: (raw['contract'] as Map?)?['direction'] ?? 'normal',
              ),
              _InspectorProperty(
                label: 'Revision',
                value: raw['revision'] ?? 1,
              ),
              _InspectorProperty(
                label: 'Status',
                value: raw['status'] ?? 'committed',
              ),
              _InspectorProperty(
                label: 'Kernel',
                value: (raw['handle'] as Map?)?['kernelId'] ?? '—',
              ),
              for (final item in const [
                ('profile', 'Profile'),
                ('distance', 'Distance'),
                ('direction', 'Direction'),
                ('ready', 'Ready'),
              ])
                _InspectorProperty(
                  label: item.$2,
                  value: ((raw['health'] as Map?)?[item.$1] == true)
                      ? '✔'
                      : '✖',
                ),
            ],
          ),
        ],
        if (entity.data['revolveFeature'] case final Map raw) ...[
          const SizedBox(height: 8),
          _InspectorSection(
            title: 'Professional Revolve',
            children: [
              _InspectorProperty(label: 'Feature ID', value: entity.id),
              _InspectorProperty(
                label: 'Source',
                value: (raw['contract'] as Map?)?['profileEntityId'] ?? '—',
              ),
              _InspectorProperty(
                label: 'Axis',
                value: (raw['contract'] as Map?)?['axisEntityId'] ?? '—',
              ),
              _InspectorProperty(
                label: 'Angle',
                value: '${(raw['contract'] as Map?)?['angleDegrees'] ?? 0}°',
              ),
              _InspectorProperty(
                label: 'Direction',
                value:
                    (raw['contract'] as Map?)?['direction'] ??
                    'counterClockwise',
              ),
              _InspectorProperty(
                label: 'Output',
                value: (raw['contract'] as Map?)?['output'] ?? '—',
              ),
              _InspectorProperty(
                label: 'Revision',
                value: raw['revision'] ?? 1,
              ),
              _InspectorProperty(
                label: 'Kernel',
                value: (raw['handle'] as Map?)?['kernelId'] ?? '—',
              ),
              for (final item in const [
                ('valid', 'Valid'),
                ('axis', 'Axis'),
                ('angle', 'Angle'),
                ('ready', 'Ready'),
              ])
                _InspectorProperty(
                  label: item.$2,
                  value: ((raw['health'] as Map?)?[item.$1] == true)
                      ? '✔'
                      : '✖',
                ),
            ],
          ),
        ],
        if (entity.data['professionalSurface'] case final Map raw)
          if (raw['tool'] == 'loft') ...[
            const SizedBox(height: 8),
            _InspectorSection(
              title: 'Professional Loft',
              children: [
                _InspectorProperty(label: 'Feature ID', value: entity.id),
                const _InspectorProperty(label: 'Type', value: 'Loft'),
                _InspectorProperty(
                  label: 'Sections',
                  value:
                      ((raw['parameters'] as Map?)?['sourceEntityIds'] as List?)
                          ?.length ??
                      0,
                ),
                _InspectorProperty(
                  label: 'Continuity',
                  value: '${raw['continuity'] ?? 'g0'}'.toUpperCase(),
                ),
                _InspectorProperty(label: 'Revision', value: raw['revision']),
                _InspectorProperty(
                  label: 'Kernel',
                  value: (raw['handle'] as Map?)?['kernelId'] ?? '—',
                ),
                for (final item in const [
                  ('valid', 'Valid'),
                  ('topologyOk', 'Topology OK'),
                  ('boundariesOk', 'Boundaries OK'),
                  ('ready', 'Ready'),
                ])
                  _InspectorProperty(
                    label: item.$2,
                    value:
                        ((raw['parameters'] as Map?)?['health']
                                as Map?)?[item.$1] ==
                            true
                        ? '✔'
                        : '✖',
                  ),
              ],
            ),
          ],
        if (entity.data['professionalSurface'] case final Map raw)
          if (raw['tool'] == 'sweep') ...[
            const SizedBox(height: 8),
            _InspectorSection(
              title: 'Professional Sweep',
              children: [
                _InspectorProperty(label: 'Feature ID', value: entity.id),
                const _InspectorProperty(label: 'Type', value: 'Sweep'),
                _InspectorProperty(
                  label: 'Profile',
                  value:
                      ((raw['parameters'] as Map?)?['profile']
                          as Map?)?['entityId'] ??
                      '—',
                ),
                _InspectorProperty(
                  label: 'Path',
                  value:
                      ((raw['parameters'] as Map?)?['path']
                          as Map?)?['entityId'] ??
                      '—',
                ),
                _InspectorProperty(
                  label: 'Continuity',
                  value: '${raw['continuity'] ?? 'g0'}'.toUpperCase(),
                ),
                _InspectorProperty(label: 'Revision', value: raw['revision']),
                _InspectorProperty(
                  label: 'Kernel',
                  value: (raw['handle'] as Map?)?['kernelId'] ?? '—',
                ),
                for (final item in const [
                  ('valid', 'Valid'),
                  ('pathOk', 'Path OK'),
                  ('profileOk', 'Profile OK'),
                  ('continuity', 'Continuity'),
                  ('ready', 'Ready'),
                ])
                  _InspectorProperty(
                    label: item.$2,
                    value:
                        ((raw['parameters'] as Map?)?['health']
                                as Map?)?[item.$1] ==
                            true
                        ? '✔'
                        : '✖',
                  ),
              ],
            ),
          ],
        if (entity.data['professionalSurface'] case final Map raw)
          if (raw['tool'] == 'blend') ...[
            const SizedBox(height: 8),
            _InspectorSection(
              title: 'Professional Blend',
              children: [
                _InspectorProperty(label: 'Feature ID', value: entity.id),
                const _InspectorProperty(label: 'Type', value: 'Blend Surface'),
                _InspectorProperty(
                  label: 'Participating Surfaces',
                  value:
                      (((raw['parameters'] as Map?)?['participants']
                                  as List?) ??
                              const [])
                          .whereType<Map>()
                          .map((item) => item['entityId'])
                          .join(' + '),
                ),
                _InspectorProperty(
                  label: 'Boundaries',
                  value:
                      (((raw['parameters'] as Map?)?['boundaryEntityIds']
                                  as List?) ??
                              const [])
                          .length,
                ),
                _InspectorProperty(
                  label: 'Continuity',
                  value: '${raw['continuity'] ?? 'g0'}'.toUpperCase(),
                ),
                _InspectorProperty(
                  label: 'Area',
                  value: (raw['parameters'] as Map?)?['area'] ?? 0.0,
                ),
                _InspectorProperty(
                  label: 'Quality',
                  value:
                      ((((raw['parameters'] as Map?)?['health']
                                      as Map?)?['quality']
                                  as num?) ??
                              0)
                          .toStringAsFixed(2),
                ),
                _InspectorProperty(label: 'Revision', value: raw['revision']),
                _InspectorProperty(
                  label: 'Kernel',
                  value: (raw['handle'] as Map?)?['kernelId'] ?? '—',
                ),
                for (final item in const [
                  ('valid', 'Valid'),
                  ('boundaries', 'Boundaries'),
                  ('continuity', 'Continuity'),
                  ('ready', 'Ready'),
                ])
                  _InspectorProperty(
                    label: item.$2,
                    value:
                        ((raw['parameters'] as Map?)?['health']
                                as Map?)?[item.$1] ==
                            true
                        ? 'âœ”'
                        : 'âœ–',
                  ),
              ],
            ),
          ],
        if (entity.data['professionalSurface'] case final Map raw)
          if (raw['tool'] == 'fillet') ...[
            const SizedBox(height: 8),
            _InspectorSection(
              title: 'Professional Surface Fillet',
              children: [
                _InspectorProperty(label: 'Feature ID', value: entity.id),
                _InspectorProperty(
                  label: 'Radius',
                  value: (raw['parameters'] as Map?)?['radius'],
                ),
                _InspectorProperty(
                  label: 'Width',
                  value: (raw['parameters'] as Map?)?['width'],
                ),
                _InspectorProperty(
                  label: 'Trim',
                  value: (raw['parameters'] as Map?)?['trim'],
                ),
                _InspectorProperty(
                  label: 'Extend',
                  value: (raw['parameters'] as Map?)?['extend'],
                ),
                _InspectorProperty(
                  label: 'Compensation',
                  value: (raw['parameters'] as Map?)?['compensationGap'],
                ),
                _InspectorProperty(
                  label: 'Continuity',
                  value: '${(raw['parameters'] as Map?)?['continuity'] ?? 'g1'}'
                      .toUpperCase(),
                ),
                _InspectorProperty(
                  label: 'Surface Health',
                  value: raw['status'] ?? 'committed',
                ),
                _InspectorProperty(label: 'Revision', value: raw['revision']),
              ],
            ),
          ],
        if (entity.data['professionalSurface'] case final Map raw)
          if (raw['tool'] == 'sew') ...[
            const SizedBox(height: 8),
            _InspectorSection(
              title: 'Professional Sew Body',
              children: [
                _InspectorProperty(label: 'Body ID', value: entity.id),
                _InspectorProperty(
                  label: 'Surfaces',
                  value:
                      ((raw['parameters'] as Map?)?['surfaceEntityIds']
                                  as List? ??
                              const [])
                          .length,
                ),
                _InspectorProperty(
                  label: 'Sewed edges',
                  value:
                      (((raw['parameters'] as Map?)?['gaps']
                          as Map?)?['coincidentEdges'] ??
                      0),
                ),
                _InspectorProperty(
                  label: 'Remaining gaps',
                  value:
                      (((raw['parameters'] as Map?)?['gaps']
                          as Map?)?['maximum'] ??
                      0),
                ),
                _InspectorProperty(
                  label: 'Tolerance',
                  value: (raw['parameters'] as Map?)?['tolerance'],
                ),
                _InspectorProperty(
                  label: 'State',
                  value: (raw['parameters'] as Map?)?['state'] ?? 'sewed',
                ),
                _InspectorProperty(
                  label: 'Topology OK',
                  value:
                      (((raw['parameters'] as Map?)?['health']
                              as Map?)?['topologyOk'] ==
                          true)
                      ? 'Yes'
                      : 'No',
                ),
                _InspectorProperty(
                  label: 'Ready for Solid',
                  value:
                      (((raw['parameters'] as Map?)?['health']
                              as Map?)?['readyForSolid'] ==
                          true)
                      ? 'Yes'
                      : 'No',
                ),
                _InspectorProperty(label: 'Revision', value: raw['revision']),
              ],
            ),
          ],
        if (entity.data['surface'] case final Map raw) ...[
          const SizedBox(height: 8),
          _InspectorSection(
            title: 'Planar Surface',
            children: [
              _InspectorProperty(label: 'Surface ID', value: entity.id),
              _InspectorProperty(
                label: 'Type',
                value: raw['kind'] == 'plane' ? 'Planar' : raw['kind'],
              ),
              _InspectorProperty(
                label: 'Area',
                value:
                    ((raw['parameters'] as Map?)?['topology']
                        as Map?)?['area'] ??
                    '—',
              ),
              _InspectorProperty(
                label: 'Perimeter',
                value:
                    ((raw['parameters'] as Map?)?['topology']
                        as Map?)?['perimeter'] ??
                    '—',
              ),
              _InspectorProperty(
                label: 'Edges',
                value:
                    (((raw['parameters'] as Map?)?['topology']
                                as Map?)?['edges']
                            as List?)
                        ?.length ??
                    0,
              ),
              _InspectorProperty(
                label: 'Vertices',
                value:
                    (((raw['parameters'] as Map?)?['topology']
                                as Map?)?['vertices']
                            as List?)
                        ?.length ??
                    0,
              ),
              _InspectorProperty(
                label: 'Source Sketch',
                value: (raw['parameters'] as Map?)?['sourceSketchId'] ?? '—',
              ),
              _InspectorProperty(label: 'Revision', value: raw['revision']),
              _InspectorProperty(
                label: 'Kernel',
                value: (raw['handle'] as Map?)?['kernelId'] ?? '—',
              ),
              _InspectorProperty(
                label: 'Normal',
                value: (raw['parameters'] as Map?)?['normal'] ?? '—',
              ),
              _InspectorProperty(label: 'Valid', value: raw['valid']),
              _InspectorProperty(
                label: 'State',
                value: entity.data['associationState'] ?? 'current',
              ),
              if (entity.data['updateDiagnostic'] != null)
                _InspectorProperty(
                  label: 'Update',
                  value: entity.data['updateDiagnostic'],
                ),
              DropdownButtonFormField<SurfaceDisplayMode>(
                initialValue: SurfaceDisplayMode.values.byName(
                  (raw['parameters'] as Map?)?['displayMode'] as String? ??
                      SurfaceDisplayMode.shadedWithEdges.name,
                ),
                decoration: const InputDecoration(
                  labelText: 'Display Mode',
                  isDense: true,
                ),
                items: [
                  for (final mode in SurfaceDisplayMode.values)
                    DropdownMenuItem(
                      value: mode,
                      child: Text(switch (mode) {
                        SurfaceDisplayMode.shaded => 'Shaded',
                        SurfaceDisplayMode.wireframe => 'Wireframe',
                        SurfaceDisplayMode.shadedWithEdges =>
                          'Shaded with Edges',
                        SurfaceDisplayMode.transparent => 'Transparent',
                      }),
                    ),
                ],
                onChanged: (mode) {
                  if (mode != null) {
                    operational.setSurfaceDisplayMode(entity.id, mode);
                  }
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: operational.busy
                    ? null
                    : () => operational.reverseSurfaceNormal(entity.id),
                icon: const Icon(Icons.swap_vert, size: 16),
                label: const Text('Reverse Normal'),
              ),
              TextField(
                controller: surfaceOffset,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Offset',
                  suffixText: 'mm',
                  isDense: true,
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        final value = double.tryParse(
                          surfaceOffset.text.replaceAll(',', '.'),
                        );
                        if (value != null) {
                          operational.previewSurfaceOffset(entity.id, value);
                        }
                      },
                      child: const Text('Preview Offset'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => operational.confirmSurfaceOffset(),
                      child: const Text('Confirm'),
                    ),
                  ),
                ],
              ),
              Builder(
                builder: (context) {
                  final selectedSurfaces = geometrySelection.selectedIds
                      .where(
                        (id) =>
                            widget.cad.runtime.document?.entities[id]?.kind ==
                            CadDocumentEntityKind.surface,
                      )
                      .toList();
                  if (selectedSurfaces.length != 2) {
                    return const SizedBox.shrink();
                  }
                  return Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => operational.joinSurfaces(
                            selectedSurfaces[0],
                            selectedSurfaces[1],
                          ),
                          child: const Text('Join'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => operational.unjoinSurfaces(
                            selectedSurfaces[0],
                            selectedSurfaces[1],
                          ),
                          child: const Text('Unjoin'),
                        ),
                      ),
                    ],
                  );
                },
              ),
              if (entity.data['surfaceHealth'] case final Map health) ...[
                const SizedBox(height: 8),
                for (final item in const [
                  ('valid', 'Valid'),
                  ('kernelOk', 'Kernel OK'),
                  ('topologyOk', 'Topology OK'),
                  ('boundariesOk', 'Boundaries OK'),
                  ('readyForLoft', 'Ready for Loft'),
                ])
                  _InspectorProperty(
                    label: item.$2,
                    value: health[item.$1] == true ? '✔' : '✖',
                  ),
              ],
            ],
          ),
        ],
        if (entity.data['surfaceTopology'] != null) ...[
          const SizedBox(height: 8),
          _InspectorSection(
            title: entity.data['surfaceTopology'] == 'edge'
                ? 'Surface Edge'
                : 'Surface Vertex',
            children: [
              _InspectorProperty(label: 'ID', value: entity.id),
              _InspectorProperty(
                label: 'Parent Surface',
                value: entity.data['parentSurfaceId'],
              ),
              _InspectorProperty(label: 'Persistent', value: true),
              _InspectorProperty(
                label: 'Revision',
                value: (entity.data['topology'] as Map?)?['revision'] ?? 1,
              ),
            ],
          ),
        ],
        if (mesh != null || bounds != null) const SizedBox(height: 8),
        if (mesh != null || bounds != null)
          _InspectorSection(
            title: 'Geometry',
            children: [
              if (mesh != null) ...[
                _InspectorProperty(
                  label: 'Triangles',
                  value: mesh.triangleCount,
                ),
                _InspectorProperty(label: 'Vertices', value: mesh.vertexCount),
                _InspectorProperty(
                  label: 'Area',
                  value: entity.data['area'] ?? mesh.metadata['area'] ?? '—',
                ),
                _InspectorProperty(
                  label: 'Volume',
                  value:
                      entity.data['volume'] ?? mesh.metadata['volume'] ?? '—',
                ),
              ],
              if (bounds != null)
                _InspectorProperty(
                  label: 'Bounding Box',
                  value:
                      '${bounds.minX.toStringAsFixed(2)}, ${bounds.minY.toStringAsFixed(2)}, ${bounds.minZ.toStringAsFixed(2)}  →  ${bounds.maxX.toStringAsFixed(2)}, ${bounds.maxY.toStringAsFixed(2)}, ${bounds.maxZ.toStringAsFixed(2)}',
                ),
            ],
          ),
        if (advancedInspector) ...[
          const Divider(),
          _InspectorProperty(label: 'ID', value: entity.id),
          _InspectorProperty(label: 'Runtime type', value: entity.kind.name),
          if (mesh != null)
            _InspectorProperty(label: 'Mesh GUID', value: mesh.persistentId),
          if (entity.shape != null)
            _InspectorProperty(
              label: 'Shape GUID',
              value: entity.shape!.persistentId,
            ),
          _InspectorProperty(
            label: 'Revision',
            value: widget.cad.runtime.document?.revision ?? 0,
          ),
        ],
      ],
    );
  }

  Widget? _operationalAssistant() {
    final entity = widget.cad.runtime.operationalSelection.active;
    if (entity == null) return null;
    final capabilities = entity.capabilities
        .map((item) => item.name)
        .join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Active operational entity: ${entity.label}'),
        Text('Type: ${entity.type.name}'),
        const SizedBox(height: 8),
        const Text('Available capabilities'),
        Text(capabilities),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    navigation = NavigationEngine(
      camera: CadCameraNavigationAdapter(camera),
      resolvePoint: (_, _) => null,
    );
    operational = OperationalReverseEngineeringController(
      recognition: EngineeringBootstrap.instance.services
          .get<ProfessionalRecognitionApi>(),
      commands: widget.commands,
      runtime: widget.cad.runtime,
    );
    widget.cad.addListener(_synchronizeScene);
    _synchronizeScene();
  }

  @override
  void dispose() {
    transformX.dispose();
    transformY.dispose();
    transformZ.dispose();
    transformAngle.dispose();
    transformScaleX.dispose();
    transformScaleY.dispose();
    transformScaleZ.dispose();
    surfaceOffset.dispose();
    sectionOffset.dispose();
    widget.cad.removeListener(_synchronizeScene);
    operational.dispose();
    navigation.dispose();
    camera.dispose();
    modelingViewport.dispose();
    super.dispose();
  }

  void _synchronizeScene() {
    final runtimeDocument = widget.cad.runtime.document;
    if (runtimeDocument == null) {
      operational.detachProject();
      fittedDocumentId = null;
      openToolWindows.clear();
      return;
    }
    unawaited(
      widget.commands.repository
          .directoryFor(runtimeDocument.projectId)
          .then(
            (directory) => operational.configureProject(
              projectId: runtimeDocument.projectId,
              projectDirectory: directory,
            ),
          ),
    );
    final document = widget.cad.document;
    if (document == null) return;
    if (fittedDocumentId != runtimeDocument.projectId) {
      openToolWindows.clear();
      choosingSketchSupport = false;
      modelingViewport.clearPreview();
      modelingViewport.clearSelection();
      final bounds = widget.cad.runtime.workspaceBounds;
      if (bounds != null) {
        camera.restoreWorkspace(
          Vector3(bounds.minX, bounds.minY, bounds.minZ),
          Vector3(bounds.maxX, bounds.maxY, bounds.maxZ),
        );
      }
      fittedDocumentId = runtimeDocument.projectId;
    }
  }

  ({Vector3 minimum, Vector3 maximum})? _visibleSceneBounds() {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;

    void include(Object? raw) {
      if (raw is! List || raw.length < 3) return;
      final x = (raw[0] as num).toDouble();
      final y = (raw[1] as num).toDouble();
      final z = (raw[2] as num).toDouble();
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      minZ = math.min(minZ, z);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
      maxZ = math.max(maxZ, z);
    }

    for (final entity in scene.entities.where((item) => item.visible)) {
      final nodes = entity.geometry['nodes'];
      if (nodes is List) {
        for (var index = 0; index + 2 < nodes.length; index += 3) {
          include([nodes[index], nodes[index + 1], nodes[index + 2]]);
        }
      }
      final points = entity.geometry['points'];
      if (points is List) {
        for (final point in points) {
          include(point);
        }
      }
      final segments = entity.geometry['segments'];
      if (segments is List) {
        for (final segment in segments.whereType<List>()) {
          for (final point in segment) {
            include(point);
          }
        }
      }
    }
    if (!minX.isFinite || !maxX.isFinite) return null;
    return (
      minimum: Vector3(minX, minY, minZ),
      maximum: Vector3(maxX, maxY, maxZ),
    );
  }

  void _fitVisibleScene() {
    final bounds = _visibleSceneBounds();
    if (bounds == null) return;
    navigation.fit(bounds.minimum, bounds.maximum);
  }

  void _setStandardView(CadStandardView view) {
    final bounds = _visibleSceneBounds();
    if (bounds == null) return;
    camera.setStandardView(view, bounds.minimum, bounds.maximum);
  }

  void selectDocument() {
    final selection = documentSelection;
    if (selection == null) return;
    modelingViewport.select(selection);
    widget.cad.runtime.select({widget.cad.document!.id});
    widget.commands.dispatch('selection.set', {
      'ids': [selection.id],
    });
  }

  void _beginDirectSketchSupportSelection() {
    if (mounted) {
      setState(() {
        module = 'Sketch';
        openToolWindows.add('Sketch');
        choosingSketchSupport = widget.cad.runtime.document != null;
      });
    }
    if (widget.cad.runtime.document == null) {
      widget.cad.setStatus('Open a project before creating a Sketch.');
      return;
    }
    widget.cad.setStatus(
      'Select XY, YZ, ZX or another planar support directly in the viewport. '
      'Press ESC to cancel.',
    );
  }

  Future<void> _openSketchSupportFallback() async {
    final document = widget.cad.runtime.document;
    if (document == null) {
      widget.cad.setStatus('Open a project before creating a Sketch.');
      return;
    }
    final selectedEntity = geometrySelection.selectedIds.isEmpty
        ? null
        : document.entities[geometrySelection.selectedIds.first];
    final selectedGeometry =
        selectedEntity?.data['sketchSupport'] ??
        selectedEntity?.data['sceneGeometry'];
    final selectedIsPlanar =
        selectedGeometry is Map &&
        selectedGeometry['type'] == 'plane' &&
        const {
          CadDocumentEntityKind.reference,
          CadDocumentEntityKind.face,
          CadDocumentEntityKind.surface,
        }.contains(selectedEntity?.kind);
    var choice = 'xy';
    final selectedChoice = selectedIsPlanar ? selectedEntity : null;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Where do you want to create the Sketch?'),
          content: SizedBox(
            width: 420,
            child: RadioGroup<String>(
              groupValue: choice,
              onChanged: (value) {
                if (value != null) setDialogState(() => choice = value);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const RadioListTile(value: 'xy', title: Text('XY Plane')),
                  const RadioListTile(value: 'yz', title: Text('YZ Plane')),
                  const RadioListTile(value: 'zx', title: Text('ZX Plane')),
                  const Divider(),
                  RadioListTile(
                    value: 'existing',
                    enabled:
                        selectedChoice?.kind == CadDocumentEntityKind.reference,
                    title: const Text('Existing plane'),
                    subtitle: Text(
                      selectedChoice?.kind == CadDocumentEntityKind.reference
                          ? selectedChoice!.data['name'] as String? ??
                                selectedChoice.id
                          : 'Select a planar reference first',
                    ),
                  ),
                  RadioListTile(
                    value: 'face',
                    enabled: selectedChoice?.kind == CadDocumentEntityKind.face,
                    title: const Text('Planar face'),
                    subtitle: Text(
                      selectedChoice?.kind == CadDocumentEntityKind.face
                          ? selectedChoice!.data['name'] as String? ??
                                selectedChoice.id
                          : 'Select a planar Face first',
                    ),
                  ),
                  RadioListTile(
                    value: 'surface',
                    enabled:
                        selectedChoice?.kind == CadDocumentEntityKind.surface,
                    title: const Text('Planar surface'),
                    subtitle: Text(
                      selectedChoice?.kind == CadDocumentEntityKind.surface
                          ? selectedChoice!.data['name'] as String? ??
                                selectedChoice.id
                          : 'Select a planar Surface first',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create Sketch'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true) return;
    switch (choice) {
      case 'xy':
        operational.selectWorldSketchPlane(SketchPlaneType.xy);
        break;
      case 'yz':
        operational.selectWorldSketchPlane(SketchPlaneType.yz);
        break;
      case 'zx':
        operational.selectWorldSketchPlane(SketchPlaneType.zx);
        break;
      default:
        if (selectedChoice == null) return;
        operational.selectSketchSupport(selectedChoice.id);
    }
    await _activateSelectedSketchSupport();
  }

  Future<void> _selectWorldSketchSupport(SketchPlaneType type) async {
    try {
      operational.selectWorldSketchPlane(type);
      await _activateSelectedSketchSupport();
    } catch (error) {
      widget.cad.setStatus(error.toString());
    }
  }

  Future<void> _activateSelectedSketchSupport() async {
    final plane = operational.activeSketchPlane;
    final planeId = operational.activeSketchPlaneId;
    if (plane == null || planeId == null) {
      widget.cad.setStatus('Choose a planar Sketch support in the viewport.');
      return;
    }
    await operational.openSketch();
    final sketch = operational.activeSketch!;
    final support = widget.cad.runtime.document?.entities[planeId];
    final rawSize = support?.data['sceneGeometry'] is Map
        ? (support!.data['sceneGeometry'] as Map)['visualSize']
        : null;
    final visualSize = rawSize is num ? rawSize.toDouble() : 60.0;
    camera.enterSketch(
      origin: Vector3(
        sketch.coordinates.origin.x,
        sketch.coordinates.origin.y,
        sketch.coordinates.origin.z,
      ),
      normal: Vector3(
        sketch.coordinates.normal.x,
        sketch.coordinates.normal.y,
        sketch.coordinates.normal.z,
      ),
      xDirection: Vector3(
        sketch.coordinates.xAxis.x,
        sketch.coordinates.xAxis.y,
        sketch.coordinates.xAxis.z,
      ),
      visualSize: visualSize,
    );
    switch (operational.activeTool) {
      case SketchToolType.circle:
      case SketchToolType.centerCircle:
      case SketchToolType.threePointCircle:
        operational.beginCircleCommand(operational.circleMode);
      case SketchToolType.arc:
      case SketchToolType.threePointArc:
      case SketchToolType.tangentArc:
        operational.beginArcCommand(operational.arcMode);
      default:
        operational.beginLineCommand();
    }
    if (mounted) {
      setState(() {
        choosingSketchSupport = false;
        openToolWindows.add('Sketch');
      });
    }
    widget.cad.setStatus('Sketch active · orthographic · support framed.');
  }

  Future<void> _selectSketchSupportFromViewport(CadViewportPick pick) async {
    final entity = widget.cad.runtime.document?.entities[pick.entityId];
    if (entity == null ||
        !const {
          CadDocumentEntityKind.reference,
          CadDocumentEntityKind.face,
          CadDocumentEntityKind.surface,
        }.contains(entity.kind)) {
      widget.cad.setStatus('Point to an XY, YZ, ZX or planar support.');
      return;
    }
    final geometry =
        entity.data['sketchSupport'] ?? entity.data['sceneGeometry'];
    if (geometry is! Map || geometry['type'] != 'plane') {
      widget.cad.setStatus('The selected entity is not a planar support.');
      return;
    }
    operational.selectSketchSupport(entity.id);
    await _activateSelectedSketchSupport();
  }

  Future<void> _finishSketch() async {
    operational.cancelSketchCommand();
    await operational.finishSketch();
    camera.exitSketch();
    await operational.refreshSketchSceneAfterExit();
    final sketch = operational.activeSketch;
    if (sketch != null) {
      final points = <Vector3>[];
      for (final id in sketch.entityIds) {
        final geometry = widget.cad.runtime.scene.find(id)?.geometry['points'];
        if (geometry is! List) continue;
        for (final raw in geometry.whereType<List>()) {
          if (raw.length >= 3) {
            points.add(
              Vector3(
                (raw[0] as num).toDouble(),
                (raw[1] as num).toDouble(),
                (raw[2] as num).toDouble(),
              ),
            );
          }
        }
      }
      if (points.isNotEmpty) {
        var minimum = points.first, maximum = points.first;
        for (final point in points.skip(1)) {
          minimum = Vector3(
            math.min(minimum.x, point.x),
            math.min(minimum.y, point.y),
            math.min(minimum.z, point.z),
          );
          maximum = Vector3(
            math.max(maximum.x, point.x),
            math.max(maximum.y, point.y),
            math.max(maximum.z, point.z),
          );
        }
        camera.fit(minimum, maximum);
      }
    }
  }

  void _focusSketchHealthIssue(SketchHealthIssue issue) {
    operational.highlightSketchHealthIssue(issue);
    final sketch = operational.activeSketch;
    if (sketch == null || issue.locations.isEmpty) return;
    final points = issue.locations
        .map(sketch.coordinates.localToGlobal)
        .map((point) => Vector3(point.x, point.y, point.z))
        .toList(growable: false);
    var minimum = points.first, maximum = points.first;
    for (final point in points.skip(1)) {
      minimum = Vector3(
        math.min(minimum.x, point.x),
        math.min(minimum.y, point.y),
        math.min(minimum.z, point.z),
      );
      maximum = Vector3(
        math.max(maximum.x, point.x),
        math.max(maximum.y, point.y),
        math.max(maximum.z, point.z),
      );
    }
    final span = math.max(
      1.0,
      math.max(maximum.x - minimum.x, maximum.y - minimum.y) * 2.5,
    );
    final center = (minimum + maximum) * .5;
    navigation.fit(
      center - Vector3(span, span, span) * .5,
      center + Vector3(span, span, span) * .5,
    );
  }

  Future<void> _offerSketchGapRepair(SketchHealthIssue issue) async {
    _focusSketchHealthIssue(issue);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Safe Gap Repair'),
        content: Text(
          'A gap of ${(issue.distance ?? 0).toStringAsFixed(3)} mm was found. '
          'Close it automatically?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await operational.autoHealSketchGap(issue);
      widget.cad.setStatus('Gap closed with operator authorization.');
    } catch (error) {
      widget.cad.setStatus(error.toString());
    }
  }

  Future<void> _reopenSketchFromExplorer(CadDocumentEntity entity) async {
    try {
      await operational.reopenSketchForEditing(entity.id);
      await widget.cad.runtime.transitionFeature(
        entity.id,
        FeatureLifecycleState.editing,
        command: 'feature.reenter',
      );
      final sketch = operational.activeSketch!;
      final supportId = sketch.metadata['supportEntityId'] as String?;
      final support = supportId == null
          ? null
          : widget.cad.runtime.document?.entities[supportId];
      final rawSize = support?.data['sceneGeometry'] is Map
          ? (support!.data['sceneGeometry'] as Map)['visualSize']
          : null;
      camera.enterSketch(
        origin: Vector3(
          sketch.coordinates.origin.x,
          sketch.coordinates.origin.y,
          sketch.coordinates.origin.z,
        ),
        normal: Vector3(
          sketch.coordinates.normal.x,
          sketch.coordinates.normal.y,
          sketch.coordinates.normal.z,
        ),
        xDirection: Vector3(
          sketch.coordinates.xAxis.x,
          sketch.coordinates.xAxis.y,
          sketch.coordinates.xAxis.z,
        ),
        visualSize: rawSize is num ? rawSize.toDouble() : 60,
      );
      if (mounted) {
        setState(() {
          module = 'Sketch';
          choosingSketchSupport = false;
          openToolWindows.add('Sketch');
        });
      }
      widget.cad.setStatus(
        '${entity.data['name'] ?? entity.id} reopened · select geometry to edit or choose a creation tool.',
      );
    } catch (error) {
      widget.cad.setStatus(error.toString());
    }
  }

  Future<void> _activateEntityEditor(CadDocumentEntity entity) async {
    if (entity.data['dimension'] case final Map raw) {
      final dimension = SketchDimension.fromJson(raw.cast<String, dynamic>());
      final input = TextEditingController(text: '${dimension.value}');
      final value = await showDialog<double>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Edit driving dimension'),
          content: TextField(
            controller: input,
            autofocus: true,
            onSubmitted: (text) => Navigator.pop(
              context,
              double.tryParse(text.replaceAll(',', '.')),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                double.tryParse(input.text.replaceAll(',', '.')),
              ),
              child: const Text('Apply'),
            ),
          ],
        ),
      );
      input.dispose();
      if (value != null) {
        await operational.editDrivingDimension(entity.id, value);
      }
      return;
    }
    if (!EntityEditContract.isAuthoringRoot(entity)) return;
    if (entity.kind == CadDocumentEntityKind.recognition &&
        entity.data['recognitionResult'] is Map) {
      await widget.cad.runtime.transitionFeature(
        entity.id,
        FeatureLifecycleState.editing,
        command: 'surface-assistant.reenter',
      );
      operational.openSurfaceAssistant(entity.id);
      if (mounted) {
        setState(() {
          module = 'Recognition';
          openToolWindows.add('Recognition');
          advancedInspector = true;
        });
      }
      widget.cad.setStatus(
        '${entity.data['name'] ?? entity.id} reopened · preview requires explicit confirmation.',
      );
      return;
    }
    if (entity.kind == CadDocumentEntityKind.sketch &&
        entity.data['sketch'] is Map) {
      await _reopenSketchFromExplorer(entity);
      return;
    }
    if (entity.kind == CadDocumentEntityKind.sketch &&
        entity.data['sketchEntity'] is Map &&
        entity.data['authoringRoot'] == true) {
      final parentId = entity.data['parentSketchId'] as String?;
      final parent = parentId == null
          ? null
          : widget.cad.runtime.document?.entities[parentId];
      if (parent == null) {
        widget.cad.setStatus('The owning Sketch could not be found.');
        return;
      }
      await _reopenSketchFromExplorer(parent);
      operational.reopenSketchFeature(entity.id);
      widget.cad.setStatus(
        '${entity.data['name'] ?? entity.id} reopened · edit its parameter in Inspector.',
      );
      return;
    }
    if (entity.kind == CadDocumentEntityKind.solid &&
        entity.data['extrudeFeature'] is Map) {
      await operational.reenterProfessionalExtrude(entity.id);
      geometrySelection.select(entity.id);
      if (mounted) {
        setState(() {
          module = 'Solids';
          openToolWindows.add('Solids');
          advancedInspector = true;
        });
      }
      widget.cad.setStatus(
        '${entity.data['name'] ?? entity.id} reopened with the same ID.',
      );
      return;
    }
    if ({
          CadDocumentEntityKind.solid,
          CadDocumentEntityKind.surface,
        }.contains(entity.kind) &&
        entity.data['revolveFeature'] is Map) {
      await operational.reenterProfessionalRevolve(entity.id);
      geometrySelection.select(entity.id);
      if (mounted) {
        setState(() {
          module = entity.kind == CadDocumentEntityKind.solid
              ? 'Solids'
              : 'Surfaces';
          openToolWindows.add(module);
          advancedInspector = true;
        });
      }
      widget.cad.setStatus(
        '${entity.data['name'] ?? entity.id} reopened with the same ID.',
      );
      return;
    }
    final professionalSurface = entity.data['professionalSurface'];
    if (entity.kind == CadDocumentEntityKind.shell &&
        professionalSurface is Map &&
        professionalSurface['tool'] == 'sew') {
      await operational.reenterProfessionalSew(entity.id);
      geometrySelection.select(entity.id);
      if (mounted) {
        setState(() {
          module = 'Surfaces';
          openToolWindows.add('Surfaces');
          advancedInspector = true;
        });
      }
      widget.cad.setStatus(
        '${entity.data['name'] ?? entity.id} reopened with the same ID.',
      );
      return;
    }
    if (entity.kind == CadDocumentEntityKind.surface &&
        professionalSurface is Map &&
        {
          'loft',
          'sweep',
          'blend',
          'fill',
          'fillet',
        }.contains(professionalSurface['tool'])) {
      if (professionalSurface['tool'] == 'loft') {
        await operational.reenterProfessionalLoft(entity.id);
      } else if (professionalSurface['tool'] == 'sweep') {
        await operational.reenterProfessionalSweep(entity.id);
      } else if (professionalSurface['tool'] == 'fill') {
        await operational.reenterProfessionalFill(entity.id);
      } else if (professionalSurface['tool'] == 'fillet') {
        await operational.reenterProfessionalSurfaceFillet(entity.id);
      } else {
        await operational.reenterProfessionalBlend(entity.id);
      }
      geometrySelection.select(entity.id);
      if (mounted) {
        setState(() {
          module = 'Surfaces';
          openToolWindows.add('Surfaces');
          advancedInspector = true;
        });
      }
      widget.cad.setStatus(
        '${entity.data['name'] ?? entity.id} reopened with the same ID.',
      );
      return;
    }
    await widget.cad.runtime.transitionFeature(
      entity.id,
      FeatureLifecycleState.editing,
      command: 'feature.reenter',
    );
    geometrySelection.select(entity.id);
    if (mounted) {
      setState(() {
        module = EntityEditContract.workspace(entity);
        advancedInspector = true;
      });
    }
    widget.cad.setStatus(
      '${entity.data['name'] ?? entity.id} reopened with the same ID · '
      'continue editing in its Feature Inspector.',
    );
  }

  Future<void> _closeToolWindow(String workspace) async {
    if (workspace == 'Sketch') {
      choosingSketchSupport = false;
      operational.cancelSketchCommand();
    }
    if (workspace == 'Recognition') {
      operational.ignoreSurfaceAssistantSuggestion();
    }
    if (mounted) setState(() => openToolWindows.remove(workspace));
    widget.cad.setStatus(
      workspace == 'Sketch'
          ? 'Sketch command closed · viewport navigation restored.'
          : '$workspace command closed.',
    );
  }

  Widget? _sketchEnvironmentInspector() {
    final sketch = operational.activeSketch;
    if (sketch == null ||
        operational.stage != SketchSurfaceStage.sketchActive) {
      return null;
    }
    final supportId = sketch.metadata['supportEntityId'] as String?;
    final support = supportId == null
        ? null
        : widget.cad.runtime.document?.entities[supportId];
    final selectedConstraintId = operational.selectedConstraintIds.singleOrNull;
    final selectedConstraint = selectedConstraintId == null
        ? null
        : operational.constraints
              .where((item) => item.id == selectedConstraintId)
              .firstOrNull;
    if (selectedConstraint != null) {
      return _InspectorSection(
        title: 'Constraint',
        children: [
          _InspectorProperty(
            label: 'Type',
            value: selectedConstraint.type.name,
          ),
          _InspectorProperty(
            label: 'Entities',
            value: selectedConstraint.references.join(' → '),
          ),
          _InspectorProperty(
            label: 'State',
            value: selectedConstraint.status.name,
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => operational.setConstraintVisibility(
                    selectedConstraint.id,
                    !selectedConstraint.visible,
                  ),
                  icon: Icon(
                    selectedConstraint.visible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 16,
                  ),
                  label: Text(selectedConstraint.visible ? 'Hide' : 'Show'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () =>
                      operational.deleteConstraint(selectedConstraint.id),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Delete'),
                ),
              ),
            ],
          ),
        ],
      );
    }
    final selectedId = operational.selectedSketchEntityIds.singleOrNull;
    final selected = selectedId == null
        ? null
        : operational.sketchEntities
              .where((entity) => entity.id == selectedId)
              .firstOrNull;
    Future<void> edit(String key, double value) async {
      if (selected == null) return;
      try {
        final featureType = selected.metadata['featureType'];
        if (featureType == 'fillet' && key == 'radius' ||
            featureType == 'chamfer' && key == 'length') {
          await operational.updateSketchFeatureParameter(selected.id, value);
        } else {
          await operational.updateSketchEntityParameters(selected.id, {
            key: value,
          });
        }
        widget.cad.setStatus('${selected.type.name} updated.');
      } catch (error) {
        widget.cad.setStatus(error.toString());
      }
    }

    if (selected is SketchLine) {
      final chamfer = selected.metadata['featureType'] == 'chamfer';
      return _InspectorSection(
        title: chamfer ? 'Chamfer' : 'Line',
        children: [
          SketchInspectorNumberProperty(
            label: chamfer ? 'Distance' : 'Length',
            value: chamfer
                ? (selected.metadata['featureValue'] as num).toDouble()
                : (selected.parameters['length'] as num).toDouble(),
            onSubmitted: (v) => edit('length', v),
          ),
          SketchInspectorNumberProperty(
            label: 'Angle',
            value: (selected.parameters['angleDegrees'] as num).toDouble(),
            suffix: '°',
            onSubmitted: (v) => edit('angleDegrees', v),
          ),
        ],
      );
    }
    if (selected is SketchArc) {
      final fillet = selected.metadata['featureType'] == 'fillet';
      final radius = (selected.parameters['radius'] as num).toDouble();
      final start = (selected.parameters['startAngle'] as num).toDouble();
      final end = (selected.parameters['endAngle'] as num).toDouble();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InspectorSection(
            title: fillet ? 'Fillet' : 'Arc',
            children: [
              SketchInspectorNumberProperty(
                label: 'Radius',
                value: radius,
                onSubmitted: (v) => edit('radius', v),
              ),
              SketchInspectorNumberProperty(
                label: 'Start angle',
                value: start * 180 / math.pi,
                suffix: '°',
                onSubmitted: (v) => edit('startAngleDegrees', v),
              ),
              SketchInspectorNumberProperty(
                label: 'End angle',
                value: end * 180 / math.pi,
                suffix: '°',
                onSubmitted: (v) => edit('endAngleDegrees', v),
              ),
              _InspectorProperty(
                label: 'Arc length',
                value: (radius * (end - start).abs()).toStringAsFixed(3),
              ),
              _InspectorProperty(
                label: 'Plane',
                value:
                    support?.data['name'] ??
                    sketch.plane.type.name.toUpperCase(),
              ),
              _InspectorProperty(
                label: 'Layer',
                value: selected.metadata['layer'] ?? 'Default',
              ),
            ],
          ),
        ],
      );
    }
    if (selected is SketchCircle) {
      final radius = (selected.parameters['radius'] as num).toDouble();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InspectorSection(
            title: 'Circle',
            children: [
              SketchInspectorNumberProperty(
                label: 'Radius',
                value: radius,
                onSubmitted: (v) => edit('radius', v),
              ),
              SketchInspectorNumberProperty(
                label: 'Diameter',
                value: radius * 2,
                onSubmitted: (v) => edit('diameter', v),
              ),
              _InspectorProperty(
                label: 'Area',
                value: (math.pi * radius * radius).toStringAsFixed(3),
              ),
              _InspectorProperty(
                label: 'Circumference',
                value: (2 * math.pi * radius).toStringAsFixed(3),
              ),
              _InspectorProperty(
                label: 'Plane',
                value:
                    support?.data['name'] ??
                    sketch.plane.type.name.toUpperCase(),
              ),
              _InspectorProperty(
                label: 'Layer',
                value: selected.metadata['layer'] ?? 'Default',
              ),
            ],
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InspectorSection(
          title: 'Sketch',
          children: [
            _InspectorProperty(label: 'Name', value: sketch.name),
            _InspectorProperty(label: 'Status', value: 'Editing'),
          ],
        ),
        const SizedBox(height: 8),
        _InspectorSection(
          title: 'Support',
          children: [
            _InspectorProperty(
              label: 'Plane',
              value:
                  support?.data['name'] ?? sketch.plane.type.name.toUpperCase(),
            ),
            _InspectorProperty(
              label: 'References',
              value: supportId == null ? 0 : 1,
            ),
          ],
        ),
        const SizedBox(height: 8),
        _InspectorSection(
          title: 'Definition',
          children: [
            _InspectorProperty(
              label: 'Geometry',
              value: sketch.entityIds.length,
            ),
            _InspectorProperty(
              label: 'Constraints',
              value: operational.constraints.length,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _applyAlignment() async {
    await operational.applyAlignment();
    final bounds = widget.cad.runtime.activeImport?.mesh?.bounds;
    if (bounds != null) {
      navigation.fit(
        Vector3(bounds.minX, bounds.minY, bounds.minZ),
        Vector3(bounds.maxX, bounds.maxY, bounds.maxZ),
      );
    }
  }

  Future<void> _sectionAction(Future<void> Function() action) async {
    try {
      await action();
      widget.cad.setStatus('Section operation completed.');
    } catch (error) {
      widget.cad.setStatus(error.toString());
    }
  }

  Future<void> _bestFitSpline() async {
    var selected = rememberedSplineTolerance;
    var remember = rememberSplineConfiguration;
    var automaticPreview = automaticSplinePreview;
    if (automaticPreview) operational.previewBestFitSpline(selected);
    final sectionData =
        operational.selectedOrActiveSketchSourceSection?.data['section'];
    final section = sectionData is Map ? sectionData : const {};
    final segmentCount = (section['segments'] as List?)?.length ?? 0;
    final pointCount = segmentCount * 2;
    final tolerance = await showDialog<double>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Best Fit Spline'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Tolerance'),
              RadioGroup<double>(
                groupValue: selected,
                onChanged: (value) {
                  if (value == null) return;
                  setDialogState(() => selected = value);
                  if (automaticPreview) {
                    operational.previewBestFitSpline(value);
                  }
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final value in const [0.01, 0.02, 0.05, 0.10])
                      RadioListTile<double>(
                        title: Text('${value.toStringAsFixed(2)} mm'),
                        value: value,
                      ),
                  ],
                ),
              ),
              Text('Points: $pointCount  ·  Segments: $segmentCount'),
              Text(
                'Estimated time: ${(pointCount / 5000).clamp(.1, 30).toStringAsFixed(1)} s',
              ),
              Text('Maximum error target: ${selected.toStringAsFixed(3)} mm'),
              Text(
                'Mean error target: ${(selected * .5).toStringAsFixed(3)} mm',
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Remember this configuration'),
                value: remember,
                onChanged: (value) =>
                    setDialogState(() => remember = value ?? false),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Automatic preview'),
                value: automaticPreview,
                onChanged: (value) {
                  setDialogState(() => automaticPreview = value ?? false);
                  if (automaticPreview) {
                    operational.previewBestFitSpline(selected);
                  } else {
                    operational.clearBestFitSplinePreview();
                  }
                },
              ),
              const Text(
                'Assistant: use the largest tolerance that preserves the engineering profile.',
              ),
              const Text('Orange: Spline preview'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Create Spline'),
            ),
          ],
        ),
      ),
    );
    operational.clearBestFitSplinePreview();
    if (tolerance == null) return;
    setState(() {
      rememberSplineConfiguration = remember;
      automaticSplinePreview = automaticPreview;
      if (remember) rememberedSplineTolerance = tolerance;
    });
    await _sectionAction(
      () => operational.createSketchFromSelectedSection(
        convertToSpline: true,
        tolerance: tolerance,
      ),
    );
  }

  Widget _sectionTools() => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final plane in const [
        (SketchPlaneType.xy, 'XY'),
        (SketchPlaneType.yz, 'YZ'),
        (SketchPlaneType.zx, 'ZX'),
      ])
        FilledButton.icon(
          icon: const Icon(Icons.polyline),
          label: Text('Plane ${plane.$2}'),
          onPressed: () => _sectionAction(
            () => operational.createWorldReferenceCurve(plane.$1),
          ),
        ),
      FilledButton.icon(
        icon: const Icon(Icons.polyline),
        label: const Text('Create Section'),
        onPressed: () => _sectionAction(operational.createSection),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.draw),
        label: const Text('Sketch from Section'),
        onPressed: () =>
            _sectionAction(operational.createSketchFromSelectedSection),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.gesture),
        label: const Text('Best Fit Spline'),
        onPressed: _bestFitSpline,
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.layers_outlined),
        label: const Text('Toggle Section'),
        onPressed: () =>
            _sectionAction(operational.toggleSourceSectionVisibility),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Toggle Sketch'),
        onPressed: () =>
            _sectionAction(operational.toggleActiveSketchVisibility),
      ),
      if (operational.activeSketch?.metadata['associationState'] == 'outdated')
        FilledButton.tonalIcon(
          icon: const Icon(Icons.sync_problem),
          label: const Text('Update Sketch'),
          onPressed: () =>
              _sectionAction(operational.updateActiveSketchFromSourceSection),
        ),
      OutlinedButton.icon(
        icon: const Icon(Icons.swap_vert),
        label: const Text('Dynamic -1'),
        onPressed: () =>
            _sectionAction(() => operational.moveSelectedSection(-1)),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.swap_vert),
        label: const Text('Dynamic +1'),
        onPressed: () =>
            _sectionAction(() => operational.moveSelectedSection(1)),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.view_stream),
        label: const Text('Multiple (5 × 5 mm)'),
        onPressed: () => _sectionAction(operational.createMultipleSections),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.straighten),
        label: const Text('Section by Axis'),
        onPressed: () =>
            _sectionAction(operational.createSectionsBySelectedAxis),
      ),
      SizedBox(
        width: 180,
        child: TextField(
          controller: sectionOffset,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(
            labelText: 'Plane Offset',
            suffixText: 'mm',
            isDense: true,
          ),
          onSubmitted: (text) {
            final value = double.tryParse(text.replaceAll(',', '.'));
            if (value != null) {
              _sectionAction(
                () => operational.setSelectedReferenceCurveOffset(value),
              );
            }
          },
        ),
      ),
      SizedBox(
        width: 240,
        child: Slider(
          value: sectionOffsetValue,
          min: -100,
          max: 100,
          divisions: 400,
          label: '${sectionOffsetValue.toStringAsFixed(1)} mm',
          onChanged: operational.selectedSection == null
              ? null
              : (value) {
                  setState(() {
                    sectionOffsetValue = value;
                    sectionOffset.text = value.toStringAsFixed(1);
                  });
                  operational.setSelectedReferenceCurveOffset(value);
                },
        ),
      ),
      for (final mode in const [
        ('curveOnly', 'Curve Only'),
        ('curveAndMesh', 'Curve + Mesh'),
        ('highlighted', 'Highlighted'),
      ])
        OutlinedButton(
          onPressed: operational.selectedSection == null
              ? null
              : () => _sectionAction(
                  () => operational.setReferenceCurveDisplayMode(
                    operational.selectedSection!.id,
                    mode.$1,
                  ),
                ),
          child: Text(mode.$2),
        ),
      OutlinedButton.icon(
        icon: const Icon(Icons.refresh),
        label: const Text('Recalculate'),
        onPressed: operational.selectedSection == null
            ? null
            : () =>
                  _sectionAction(operational.recalculateSelectedReferenceCurve),
      ),
    ],
  );

  double _number(TextEditingController controller, String label) {
    final value = double.tryParse(controller.text.replaceAll(',', '.'));
    if (value == null || !value.isFinite) {
      throw FormatException('$label must be a finite number.');
    }
    return value;
  }

  Future<void> _transformAction(FutureOr<void> Function() action) async {
    try {
      await action();
      widget.cad.setStatus('Transform preview updated.');
    } catch (error) {
      widget.cad.setStatus('Transform: $error');
    }
  }

  Widget _transformTools() {
    Widget numberField(String label, TextEditingController controller) =>
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(
            signed: true,
            decimal: true,
          ),
          decoration: InputDecoration(labelText: label, isDense: true),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Transform', style: TextStyle(fontWeight: FontWeight.bold)),
        const Text('Select an entity, configure values, preview, then apply.'),
        RadioGroup<TransformDisposition>(
          groupValue: operational.transformDisposition,
          onChanged: operational.chooseTransformDisposition,
          child: const Column(
            children: [
              RadioListTile<TransformDisposition>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: TransformDisposition.original,
                title: Text('Transform Original'),
              ),
              RadioListTile<TransformDisposition>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: TransformDisposition.workingCopy,
                title: Text('Create Working Copy'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: numberField('X', transformX)),
            const SizedBox(width: 4),
            Expanded(child: numberField('Y', transformY)),
            const SizedBox(width: 4),
            Expanded(child: numberField('Z', transformZ)),
          ],
        ),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.open_with),
          label: const Text('Move Preview'),
          onPressed: () => _transformAction(
            () => operational.previewMove(
              Vector3(
                _number(transformX, 'X'),
                _number(transformY, 'Y'),
                _number(transformZ, 'Z'),
              ),
            ),
          ),
        ),
        const Divider(),
        numberField('Angle (degrees)', transformAngle),
        Wrap(
          spacing: 4,
          children: [
            for (final axis in const [
              ('X', Vector3(1, 0, 0)),
              ('Y', Vector3(0, 1, 0)),
              ('Z', Vector3(0, 0, 1)),
            ])
              OutlinedButton(
                onPressed: () => _transformAction(
                  () => operational.previewRotate(
                    axis.$2,
                    _number(transformAngle, 'Angle'),
                  ),
                ),
                child: Text('Rotate ${axis.$1}'),
              ),
          ],
        ),
        const Divider(),
        Row(
          children: [
            Expanded(child: numberField('Scale X', transformScaleX)),
            const SizedBox(width: 4),
            Expanded(child: numberField('Y', transformScaleY)),
            const SizedBox(width: 4),
            Expanded(child: numberField('Z', transformScaleZ)),
          ],
        ),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.aspect_ratio),
          label: const Text('Scale Preview'),
          onPressed: () => _transformAction(
            () => operational.previewScale(
              Vector3(
                _number(transformScaleX, 'Scale X'),
                _number(transformScaleY, 'Scale Y'),
                _number(transformScaleZ, 'Scale Z'),
              ),
            ),
          ),
        ),
        const Divider(),
        const Text('Transform by Reference'),
        Wrap(
          spacing: 4,
          children: [
            for (final target in const [
              'Origin',
              'XY',
              'XZ',
              'YZ',
              'X',
              'Y',
              'Z',
            ])
              OutlinedButton(
                onPressed: () => _transformAction(
                  () => operational.previewTransformByReference(target),
                ),
                child: Text(target),
              ),
          ],
        ),
        const Divider(),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Apply'),
                onPressed: operational.manualTransformPreview == null
                    ? null
                    : () => _transformAction(operational.applyManualTransform),
              ),
            ),
            IconButton(
              tooltip: 'Cancel preview',
              onPressed: operational.manualTransformPreview == null
                  ? null
                  : operational.cancelManualTransform,
              icon: const Icon(Icons.close),
            ),
            IconButton(
              tooltip: 'Reset transform',
              onPressed: () =>
                  _transformAction(operational.resetSelectedTransform),
              icon: const Icon(Icons.restart_alt),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.undo),
                label: const Text('Undo'),
                onPressed: widget.cad.runtime.canUndo
                    ? () => _transformAction(operational.undoManualTransform)
                    : null,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.redo),
                label: const Text('Redo'),
                onPressed: widget.cad.runtime.canRedo
                    ? () => _transformAction(operational.redoManualTransform)
                    : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmDelete(CadDocumentEntity entity) async {
    final impacted = operational.deletionImpact(entity.id);
    operational.previewDeletion(
      entity.id,
      includeDependencies: impacted.isNotEmpty,
    );
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final counts = <String, int>{};
        for (final item in impacted) {
          counts.update(
            item.kind.name,
            (value) => value + 1,
            ifAbsent: () => 1,
          );
        }
        return AlertDialog(
          title: const Text('Dependency Analysis'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${entity.data['name'] ?? entity.id} affects:'),
              if (counts.isEmpty) const Text('No dependent entities.'),
              for (final entry in counts.entries)
                Text('${entry.value} ${entry.key}'),
              const SizedBox(height: 12),
              const Text(
                'Deleted entities are moved to the Project Recycle Bin.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('Cancel'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, 'only'),
              child: const Text('Delete only this entity'),
            ),
            if (impacted.isNotEmpty)
              FilledButton(
                onPressed: () => Navigator.pop(context, 'all'),
                child: const Text('Delete all affected'),
              ),
          ],
        );
      },
    );
    operational.clearDeletionPreview();
    if (choice == 'only' || choice == 'all') {
      await operational.deleteToRecycleBin(
        entity.id,
        includeDependencies: choice == 'all',
      );
    }
  }

  Widget _documentExplorer(BuildContext context) {
    final entities =
        widget.cad.runtime.document?.entities.values.toList() ?? [];
    final groups = <String, List<CadDocumentEntity>>{
      'Entidades': entities
          .where(
            (entity) =>
                entity.data['constructionEntity'] is Map &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'Meshes': entities
          .where(
            (entity) =>
                entity.kind == CadDocumentEntityKind.import &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'References': entities
          .where(
            (entity) =>
                entity.kind == CadDocumentEntityKind.reference &&
                entity.data['constructionEntity'] is! Map &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'Sketches': entities
          .where(
            (entity) =>
                entity.kind == CadDocumentEntityKind.sketch &&
                entity.data['deleted'] != true &&
                entity.data['sketch'] is Map,
          )
          .toList(),
      'Curves': entities
          .where(
            (entity) =>
                entity.kind == CadDocumentEntityKind.curve &&
                entity.data['constructionEntity'] is! Map &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'Surfaces': entities
          .where(
            (entity) =>
                entity.kind == CadDocumentEntityKind.surface &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'Solids': entities
          .where(
            (entity) =>
                entity.kind == CadDocumentEntityKind.solid &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'Reference Curves': entities
          .where(
            (entity) =>
                entity.kind == CadDocumentEntityKind.section &&
                entity.data['section'] is Map &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'Inspection': entities
          .where(
            (entity) =>
                entity.data['workspaceGroup'] == 'Inspection' &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'Construction': entities
          .where(
            (entity) =>
                const {
                  CadDocumentEntityKind.collection,
                  CadDocumentEntityKind.boundary,
                  CadDocumentEntityKind.vertex,
                  CadDocumentEntityKind.edge,
                  CadDocumentEntityKind.wire,
                  CadDocumentEntityKind.face,
                  CadDocumentEntityKind.shell,
                  CadDocumentEntityKind.constraint,
                }.contains(entity.kind) &&
                entity.data['parentSurfaceId'] == null &&
                entity.data['hiddenFromExplorer'] != true &&
                entity.data['deleted'] != true,
          )
          .toList(),
    };
    Future<void> renameEntity(CadDocumentEntity entity, String name) async {
      final controller = TextEditingController(text: name);
      final replacement = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Rename'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Rename'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (replacement == null || replacement.trim().isEmpty) return;
      if (entity.kind == CadDocumentEntityKind.collection) {
        await widget.cad.runtime.updateCollection(entity.id, name: replacement);
      } else if (entity.kind == CadDocumentEntityKind.section) {
        await operational.sections.rename(entity.id, replacement);
      }
    }

    Widget row(CadDocumentEntity entity) {
      final collection = entity.kind == CadDocumentEntityKind.collection;
      final deleted = entity.data['deleted'] == true;
      final visible = entity.data['sceneVisible'] as bool? ?? true;
      final fullName = entity.kind == CadDocumentEntityKind.import
          ? entity.data['name'] as String? ??
                (entity.data['sourcePath'] as String?)
                    ?.split(RegExp(r'[/\\]'))
                    .last ??
                entity.id
          : entity.data['name'] as String? ?? entity.id;
      final name = fullName;
      Future<void> runContextAction(String action) async {
        if (action == 'rename') {
          await renameEntity(entity, name);
        } else if (action == 'visibility') {
          if (entity.kind == CadDocumentEntityKind.sketch &&
              entity.data['sketch'] is Map) {
            operational.selectSketch(entity.id);
            await operational.toggleActiveSketchVisibility();
          } else {
            await widget.cad.runtime.setEntityVisibility(entity.id, !visible);
          }
        } else if (action == 'duplicate' && collection) {
          await widget.cad.runtime.duplicateCollection(entity.id);
        } else if (action == 'delete') {
          await _confirmDelete(entity);
        } else if (action == 'properties') {
          geometrySelection.select(entity.id);
        }
      }

      final entityTile = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: deleted
            ? null
            : (details) async {
                final action = await showMenu<String>(
                  context: context,
                  position: RelativeRect.fromLTRB(
                    details.globalPosition.dx,
                    details.globalPosition.dy,
                    details.globalPosition.dx,
                    details.globalPosition.dy,
                  ),
                  items: [
                    PopupMenuItem(
                      value: 'rename',
                      enabled:
                          collection ||
                          entity.kind == CadDocumentEntityKind.section,
                      child: const Text('Rename'),
                    ),
                    PopupMenuItem(
                      value: 'visibility',
                      child: Text(visible ? 'Hide' : 'Show'),
                    ),
                    PopupMenuItem(
                      value: 'duplicate',
                      enabled: collection,
                      child: const Text('Duplicate'),
                    ),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'properties',
                      child: Text('Properties'),
                    ),
                  ],
                );
                if (action != null) await runContextAction(action);
              },
        child: ListTile(
          dense: true,
          minTileHeight: 29,
          visualDensity: const VisualDensity(vertical: -4),
          contentPadding: const EdgeInsets.only(left: 6, right: 2),
          selected:
              operational.selectedConstraintIds.contains(entity.id) ||
              (scene.find(entity.id)?.selected ?? false),
          leading: _CadExplorerGlyph(
            collection
                ? _CadGlyphKind.project
                : entity.kind == CadDocumentEntityKind.section
                ? _CadGlyphKind.section
                : switch (entity.data['sceneKind']) {
                    'plane' => _CadGlyphKind.plane,
                    'axis' => _CadGlyphKind.axis,
                    'point' => _CadGlyphKind.point,
                    'coordinateSystem' => _CadGlyphKind.reference,
                    'sketch' => _CadGlyphKind.sketch,
                    'surface' => _CadGlyphKind.surface,
                    'curve' => _CadGlyphKind.curve,
                    'mesh' => _CadGlyphKind.mesh,
                    'solid' => _CadGlyphKind.solid,
                    _ => _CadGlyphKind.construction,
                  },
          ),
          trailing: collection
              ? PopupMenuButton<String>(
                  onSelected: (action) async {
                    switch (action) {
                      case 'visibility':
                        await widget.cad.runtime.updateCollection(
                          entity.id,
                          visible: !(entity.data['visible'] as bool? ?? true),
                        );
                      case 'lock':
                        await widget.cad.runtime.updateCollection(
                          entity.id,
                          locked: !(entity.data['locked'] as bool? ?? false),
                        );
                      case 'active':
                        await widget.cad.runtime.updateCollection(
                          entity.id,
                          active: true,
                        );
                      case 'duplicate':
                        await widget.cad.runtime.duplicateCollection(entity.id);
                      case 'delete':
                        await _confirmDelete(entity);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'visibility',
                      child: Text('Show/Hide'),
                    ),
                    const PopupMenuItem(
                      value: 'lock',
                      child: Text('Lock/Unlock'),
                    ),
                    const PopupMenuItem(
                      value: 'active',
                      child: Text('Make Active'),
                    ),
                    const PopupMenuItem(
                      value: 'duplicate',
                      child: Text('Duplicate'),
                    ),
                    if (entity.data['systemCollection'] != true)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Move to Recycle Bin'),
                      ),
                  ],
                )
              : deleted
              ? PopupMenuButton<String>(
                  onSelected: (action) async {
                    if (action == 'restore') {
                      await operational.restoreDeleted(entity.id);
                    } else if (action == 'purge') {
                      await operational.permanentlyDelete(entity.id);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'restore', child: Text('Restore')),
                    PopupMenuItem(
                      value: 'purge',
                      child: Text('Delete Permanently'),
                    ),
                  ],
                )
              : PopupMenuButton<String>(
                  onSelected: (action) async {
                    if (action == 'rename') {
                      await renameEntity(entity, name);
                    } else if (action == 'visibility') {
                      if (entity.kind == CadDocumentEntityKind.constraint) {
                        await operational.setConstraintVisibility(
                          entity.id,
                          !visible,
                        );
                      } else if (entity.kind == CadDocumentEntityKind.sketch &&
                          entity.data['sketch'] is Map) {
                        operational.selectSketch(entity.id);
                        await operational.toggleActiveSketchVisibility();
                      } else if (entity.kind == CadDocumentEntityKind.surface) {
                        await operational.setSurfaceVisibility(
                          entity.id,
                          !visible,
                        );
                      } else {
                        await widget.cad.runtime.setEntityVisibility(
                          entity.id,
                          !visible,
                        );
                      }
                    } else if (action == 'delete') {
                      if (entity.data['dimension'] is Map) {
                        await operational.deleteDrivingDimension(entity.id);
                      } else if (entity.kind ==
                          CadDocumentEntityKind.constraint) {
                        await operational.deleteConstraint(entity.id);
                      } else {
                        await _confirmDelete(entity);
                      }
                    } else if (action == 'properties') {
                      geometrySelection.select(entity.id);
                    }
                  },
                  itemBuilder: (_) => [
                    if (entity.kind == CadDocumentEntityKind.section)
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('Rename'),
                      ),
                    PopupMenuItem(
                      value: 'visibility',
                      child: Text(visible ? 'Hide' : 'Show'),
                    ),
                    const PopupMenuItem<String>(
                      enabled: false,
                      value: 'duplicate',
                      child: Text('Duplicate'),
                    ),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'properties',
                      child: Text('Properties'),
                    ),
                  ],
                ),
          title: _ExplorerLabel(
            name,
            fontSize: 10.5,
            fontWeight: FontWeight.w400,
          ),
          subtitle: entity.data[FeatureLifecycleContract.dataKey] is Map
              ? Text(
                  '${(entity.data[FeatureLifecycleContract.dataKey] as Map)['state']} · '
                  'r${(entity.data[FeatureLifecycleContract.dataKey] as Map)['revision']}',
                  style: const TextStyle(fontSize: 8.5),
                )
              : null,
          onLongPress:
              entity.kind != CadDocumentEntityKind.section && !collection
              ? null
              : () => renameEntity(entity, name),
          onTap: collection
              ? null
              : () {
                  if (entity.kind == CadDocumentEntityKind.import) {
                    widget.cad.runtime.operationalSelection.clear();
                    setState(() => advancedInspector = false);
                  }
                  final additive = HardwareKeyboard.instance.isControlPressed;
                  geometrySelection.select(entity.id, additive: additive);
                  if (entity.data['sceneKind'] == 'plane') {
                    operational.selectDocumentPlane(entity.id);
                  } else if (entity.kind == CadDocumentEntityKind.sketch &&
                      entity.data['sketch'] is Map) {
                    if (!additive) operational.selectSketch(entity.id);
                  } else if (entity.kind == CadDocumentEntityKind.sketch &&
                      entity.data['sketchEntity'] is Map) {
                    operational.selectSketchEntity(
                      entity.id,
                      additive: HardwareKeyboard.instance.isControlPressed,
                    );
                  } else if (entity.kind == CadDocumentEntityKind.constraint) {
                    if (entity.data['dimension'] is Map) {
                      geometrySelection.select(entity.id);
                    } else {
                      operational.selectConstraint(
                        entity.id,
                        additive: HardwareKeyboard.instance.isControlPressed,
                      );
                    }
                  } else if (entity.kind == CadDocumentEntityKind.recognition) {
                    operational.openSurfaceAssistant(entity.id);
                  }
                },
        ),
      );
      return entity.kind == CadDocumentEntityKind.import
          ? _MeshExplorerNode(
              regions: widget.cad.runtime.operationalEntities.entities
                  .where(
                    (operationalEntity) =>
                        operationalEntity.ownerId == entity.id &&
                        operationalEntity.type ==
                            OperationalEntityType.meshRegion,
                  )
                  .map((operationalEntity) => operationalEntity.label)
                  .toList(growable: false),
              recognitionResults: operational.persistedRecognitionResults
                  .where((result) {
                    final raw = result.data['recognitionResult'];
                    return raw is Map && raw['meshId'] == entity.id;
                  })
                  .toList(growable: false),
              entityBuilder: row,
              child: entityTile,
            )
          : entity.kind == CadDocumentEntityKind.sketch &&
                entity.data['sketch'] is Map
          ? _SketchExplorerNode(
              health: operational.healthForSketch(entity.id),
              onHealthIssue: (issue) {
                operational.selectSketch(entity.id);
                _focusSketchHealthIssue(issue);
              },
              entities:
                  <String>[
                        ...(entity.data['geometricEntities'] as List? ??
                                const [])
                            .whereType<String>(),
                        ...(entity.data['constraints'] as List? ?? const [])
                            .whereType<String>(),
                        ...(entity.data['dimensions'] as List? ?? const [])
                            .whereType<String>(),
                      ]
                      .map((id) => widget.cad.runtime.document?.entities[id])
                      .whereType<CadDocumentEntity>()
                      .toList(growable: false),
              entityBuilder: row,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => _activateEntityEditor(entity),
                child: entityTile,
              ),
            )
          : entity.kind == CadDocumentEntityKind.surface &&
                entity.data['professionalSurface'] is Map &&
                (entity.data['professionalSurface'] as Map)['tool'] == 'blend'
          ? _BlendExplorerNode(
              definition: Map<String, dynamic>.from(
                entity.data['professionalSurface'] as Map,
              ),
              onInputTap: (id) => geometrySelection.select(id),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => _activateEntityEditor(entity),
                child: entityTile,
              ),
            )
          : entity.kind == CadDocumentEntityKind.surface &&
                entity.data['professionalSurface'] is Map &&
                (entity.data['professionalSurface'] as Map)['tool'] == 'sweep'
          ? _SweepExplorerNode(
              definition: Map<String, dynamic>.from(
                entity.data['professionalSurface'] as Map,
              ),
              onInputTap: (id) => geometrySelection.select(id),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => _activateEntityEditor(entity),
                child: entityTile,
              ),
            )
          : entity.kind == CadDocumentEntityKind.surface &&
                entity.data['professionalSurface'] is Map &&
                (entity.data['professionalSurface'] as Map)['tool'] == 'loft'
          ? _LoftExplorerNode(
              definition: Map<String, dynamic>.from(
                entity.data['professionalSurface'] as Map,
              ),
              qualityData: entity.data,
              onSectionTap: (id) => geometrySelection.select(id),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => _activateEntityEditor(entity),
                child: entityTile,
              ),
            )
          : entity.kind == CadDocumentEntityKind.surface &&
                entity.data['surface'] is Map
          ? _SurfaceExplorerNode(
              surface: (entity.data['surface'] as Map).cast<String, dynamic>(),
              qualityData: entity.data,
              lifecycle:
                  (entity.data[FeatureLifecycleContract.dataKey] as Map?)
                      ?.cast<String, dynamic>() ??
                  const {},
              onSketchTap: (id) {
                final source = widget.cad.runtime.document?.entities[id];
                if (source != null) {
                  geometrySelection.select(id);
                  operational.selectSketch(id);
                }
              },
              onTopologyTap: (id) => geometrySelection.select(id),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => _activateEntityEditor(entity),
                child: entityTile,
              ),
            )
          : EntityEditContract.isAuthoringRoot(entity) ||
                entity.data['dimension'] is Map
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () => _activateEntityEditor(entity),
              child: entityTile,
            )
          : entityTile;
    }

    return ExpansionTile(
      key: const ValueKey('workspace-project-root'),
      initiallyExpanded: false,
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      leading: const _CadExplorerGlyph(_CadGlyphKind.project),
      title: const _ExplorerLabel(
        'Project',
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
      ),
      children: [
        for (final entry in groups.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: ExpansionTile(
              key: ValueKey('workspace-group-${entry.key}'),
              initiallyExpanded: false,
              dense: true,
              visualDensity: const VisualDensity(vertical: -3),
              leading: _CadExplorerGlyph(switch (entry.key) {
                'Meshes' => _CadGlyphKind.mesh,
                'References' => _CadGlyphKind.reference,
                'Sections' => _CadGlyphKind.section,
                'Sketches' => _CadGlyphKind.sketch,
                'Curves' => _CadGlyphKind.curve,
                'Surfaces' => _CadGlyphKind.surface,
                'Solids' => _CadGlyphKind.solid,
                'Inspection' => _CadGlyphKind.inspection,
                _ => _CadGlyphKind.construction,
              }, size: 19),
              title: _ExplorerLabel(
                entry.key,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
              children: entry.value.isEmpty
                  ? [
                      const ListTile(
                        dense: true,
                        title: _ExplorerLabel('Empty', fontSize: 10.5),
                      ),
                    ]
                  : entry.value.map(row).toList(),
            ),
          ),
      ],
    );
  }

  void _openStudioRecommendation() {
    final selectedId = geometrySelection.selectedIds.firstOrNull;
    final selected = selectedId == null
        ? null
        : widget.cad.runtime.document?.entities[selectedId];
    final target = switch (selected?.kind) {
      CadDocumentEntityKind.import => 'Recognition',
      CadDocumentEntityKind.recognition => 'Recognition',
      CadDocumentEntityKind.section => 'Sketch',
      CadDocumentEntityKind.sketch => 'Surfaces',
      CadDocumentEntityKind.surface => 'Surfaces',
      CadDocumentEntityKind.solid => 'Solids',
      _ => switch (operational.reverseEngineeringStudioState.currentStage) {
        ReverseEngineeringStage.mesh => 'Reference',
        ReverseEngineeringStage.recognition => 'Recognition',
        ReverseEngineeringStage.referenceCurves => 'Sections',
        ReverseEngineeringStage.sketch => 'Sketch',
        ReverseEngineeringStage.surface ||
        ReverseEngineeringStage.topology => 'Surfaces',
        ReverseEngineeringStage.solid => 'Surfaces',
      },
    };
    if (selected?.kind == CadDocumentEntityKind.recognition) {
      operational.openSurfaceAssistant(selected!.id);
    }
    if (mounted) {
      setState(() {
        module = target;
        openToolWindows.add(target);
      });
    }
  }

  Widget? _activeToolWindowContent() => switch (module) {
    'Reverse Engineering' => ReverseEngineeringStudioPanel(
      state: operational.reverseEngineeringStudioState,
      reconstruction: operational.reconstructionState,
      onOpenNext: _openStudioRecommendation,
      onRegionSelected: (id) {
        geometrySelection.select(id);
        operational.openSurfaceAssistant(id);
        setState(() {
          module = 'Recognition';
          openToolWindows.add('Recognition');
        });
      },
      onRegionIgnored: (id, ignored) {
        operational.setReconstructionRegionIgnored(id, ignored);
      },
    ),
    'AI Engineering' => const _WorkspaceEnvironmentPlaceholder(
      icon: Icons.psychology_outlined,
      title: 'Engineering Intelligence',
      description:
          'Specialized assistance for engineering decisions and project evidence.',
      capabilities: ['Evidence', 'Guidance', 'Automation'],
    ),
    'Recognition' => RecognitionWorkspacePanel(
      controller: operational,
      onApplyAlignment: _applyAlignment,
    ),
    'Reference' => const _WorkspaceEnvironmentPlaceholder(
      icon: Icons.architecture_outlined,
      title: 'Reference Geometry',
      description: 'Project construction references.',
      capabilities: ['Point', 'Axis', 'Plane', 'Coordinate System'],
    ),
    'Entidades' => _EntitiesHubPanel(
      key: ValueKey(
        'entity-tool-$toolbarEntityConstructor-${toolbarPrimitiveType?.name ?? 'default'}',
      ),
      runtime: widget.cad.runtime,
      onStatus: widget.cad.setStatus,
      initialConstructor: toolbarEntityConstructor,
      initialPrimitiveType: toolbarPrimitiveType,
      pickedSourceId: operational.activePick?.entityId,
      pickedPoint: operational.activePick?.hit.point,
      pickedTriangleIndex: operational.activePick?.hit.triangleIndex,
    ),
    'Sketch'
        when operational.activeSketch != null &&
            operational.stage != SketchSurfaceStage.idle &&
            operational.stage != SketchSurfaceStage.referenceReady =>
      _SketchWorkspaceFoundation(
        controller: operational,
        onExitSketch: _finishSketch,
        onHealthIssue: _focusSketchHealthIssue,
        onAutoHeal: _offerSketchGapRepair,
      ),
    'Sketch' => _SketchEntryWorkspace(
      onChooseFromList: _openSketchSupportFallback,
      onChooseWorldPlane: _selectWorldSketchSupport,
    ),
    'Curves' => const _WorkspaceEnvironmentPlaceholder(
      icon: Icons.gesture,
      title: 'Curves',
      description: 'Engineering curve workspace prepared for future tools.',
      capabilities: ['Splines', 'Projected', 'Extracted', 'Intersection'],
    ),
    'Surfaces' => SketchSurfaceWorkspacePanel(
      key: ValueKey('surface-tool-${toolbarSurfaceTool?.name ?? 'home'}'),
      controller: operational,
      initialSurfaceTool: toolbarSurfaceTool,
      onOpenSketch: () async => _beginDirectSketchSupportSelection(),
      onFinishSketch: _finishSketch,
    ),
    'Solids' => _ProfessionalExtrudePanel(controller: operational),
    'Sections' => _sectionTools(),
    'Transform' => _transformTools(),
    _ => null,
  };

  Widget _surfaceToolbarMenu() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: PopupMenuButton<ProfessionalSurfaceTool>(
      tooltip: 'Surface commands',
      position: PopupMenuPosition.under,
      onSelected: (tool) async {
        setState(() {
          toolbarSurfaceTool = tool;
          module = 'Surfaces';
          openToolWindows.add('Surfaces');
        });
        try {
          await widget.commands.dispatch('workspace.surfaces');
        } catch (_) {
          widget.cad.setStatus('${tool.name} Surface aberto.');
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(enabled: false, child: Text('Create Surface')),
        for (final tool in const [
          ProfessionalSurfaceTool.loft,
          ProfessionalSurfaceTool.sweep,
          ProfessionalSurfaceTool.fill,
          ProfessionalSurfaceTool.patch,
          ProfessionalSurfaceTool.blend,
          ProfessionalSurfaceTool.fillet,
          ProfessionalSurfaceTool.sew,
        ])
          PopupMenuItem(
            value: tool,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(switch (tool) {
                ProfessionalSurfaceTool.loft => Icons.view_in_ar,
                ProfessionalSurfaceTool.sweep => Icons.route,
                ProfessionalSurfaceTool.fill => Icons.format_color_fill,
                ProfessionalSurfaceTool.patch => Icons.grid_4x4,
                ProfessionalSurfaceTool.blend => Icons.rounded_corner,
                ProfessionalSurfaceTool.fillet => Icons.blur_circular,
                ProfessionalSurfaceTool.sew => Icons.hub_outlined,
                _ => Icons.layers,
              }),
              title: Text(tool.name[0].toUpperCase() + tool.name.substring(1)),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: ProfessionalSurfaceTool.offset,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.layers_outlined),
            title: Text('Offset'),
          ),
        ),
      ],
      child: Chip(
        avatar: module == 'Surfaces'
            ? const Icon(Icons.check, size: 16)
            : const Icon(Icons.layers_outlined, size: 16),
        label: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Surfaces'),
            SizedBox(width: 4),
            Icon(Icons.arrow_drop_down),
          ],
        ),
        backgroundColor: module == 'Surfaces'
            ? Theme.of(context).colorScheme.secondaryContainer
            : null,
      ),
    ),
  );

  Future<void> _openEntityTool(
    int constructor, {
    PrimitiveSurfaceType? primitive,
  }) async {
    setState(() {
      toolbarEntityConstructor = constructor;
      toolbarPrimitiveType = primitive;
      module = 'Entidades';
      openToolWindows.add('Entidades');
    });
    try {
      await widget.commands.dispatch('workspace.entidades');
    } catch (_) {
      widget.cad.setStatus('Geometria de Referência aberta.');
    }
  }

  Widget _entityToolbarMenu() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: PopupMenuButton<Object>(
      tooltip: 'Geometria de Referência',
      position: PopupMenuPosition.under,
      onSelected: (value) {
        if (value is int) _openEntityTool(value);
        if (value is PrimitiveSurfaceType) {
          _openEntityTool(4, primitive: value);
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(enabled: false, child: Text('Geometria de Referência')),
        PopupMenuItem(value: 0, child: Text('📍  Ponto')),
        PopupMenuItem(value: 1, child: Text('▱  Plano')),
        PopupMenuItem(value: 2, child: Text('↗  Vetor')),
        PopupMenuItem(value: 3, child: Text('⌁  Curva')),
        PopupMenuDivider(),
        PopupMenuItem(enabled: false, child: Text('Superfícies primitivas')),
        PopupMenuItem(value: PrimitiveSurfaceType.plane, child: Text('Plano')),
        PopupMenuItem(
          value: PrimitiveSurfaceType.cylinder,
          child: Text('Cilindro'),
        ),
        PopupMenuItem(value: PrimitiveSurfaceType.cone, child: Text('Cone')),
        PopupMenuItem(
          value: PrimitiveSurfaceType.sphere,
          child: Text('Esfera'),
        ),
        PopupMenuItem(value: PrimitiveSurfaceType.torus, child: Text('Toro')),
      ],
      child: Chip(
        avatar: module == 'Entidades'
            ? const Icon(Icons.check, size: 16)
            : const Icon(Icons.architecture_outlined, size: 16),
        label: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Geometria'),
            SizedBox(width: 4),
            Icon(Icons.arrow_drop_down),
          ],
        ),
        backgroundColor: module == 'Entidades'
            ? Theme.of(context).colorScheme.secondaryContainer
            : null,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (choosingSketchSupport) {
          setState(() => choosingSketchSupport = false);
          widget.cad.setStatus('Sketch support selection cancelled.');
          return;
        }
        operational.cancelPendingSketchOperation();
        operational.cancelProfessionalSurface();
        operational.cancelProfessionalExtrude();
        operational.cancelProfessionalRevolve();
        widget.cad.setStatus('Sketch command cancelled.');
      },
      const SingleActivator(LogicalKeyboardKey.enter): () {
        if (operational.professionalRevolvePreview != null &&
            !operational.busy) {
          operational.confirmProfessionalRevolve();
        } else if (operational.professionalExtrudePreview != null &&
            !operational.busy) {
          operational.confirmProfessionalExtrude();
        } else if (operational.professionalSurfacePreview != null &&
            !operational.busy) {
          operational.confirmProfessionalSurface();
        } else {
          widget.cad.setStatus('Sketch command confirmed.');
        }
      },
      const SingleActivator(LogicalKeyboardKey.delete): () {
        operational.deleteSelectedSketchEntities();
        widget.cad.setStatus('Sketch selection removed.');
      },
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
          operational.undo,
      const SingleActivator(LogicalKeyboardKey.keyY, control: true):
          operational.redo,
      const SingleActivator(LogicalKeyboardKey.space): () {
        operational.selectSketchTool(operational.activeTool);
        widget.cad.setStatus(
          'Repeated ${operational.activeTool.name} command.',
        );
      },
      const SingleActivator(LogicalKeyboardKey.keyF): _fitVisibleScene,
      const SingleActivator(LogicalKeyboardKey.f1): () =>
          _setStandardView(CadStandardView.perspective),
      const SingleActivator(LogicalKeyboardKey.f2): () =>
          _setStandardView(CadStandardView.top),
      const SingleActivator(LogicalKeyboardKey.f3): () =>
          _setStandardView(CadStandardView.bottom),
      const SingleActivator(LogicalKeyboardKey.f4): () =>
          _setStandardView(CadStandardView.front),
      const SingleActivator(LogicalKeyboardKey.f5): () =>
          _setStandardView(CadStandardView.back),
      const SingleActivator(LogicalKeyboardKey.f6): () =>
          _setStandardView(CadStandardView.right),
      const SingleActivator(LogicalKeyboardKey.f7): () =>
          _setStandardView(CadStandardView.left),
      const SingleActivator(LogicalKeyboardKey.f8): () =>
          _setStandardView(CadStandardView.isometric),
    },
    child: Focus(
      autofocus: true,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          widget.cad,
          modelingViewport,
          operational,
          geometrySelection,
          widget.cad.runtime.operationalSelection,
          widget.cad.runtime.operationalEntities,
        ]),
        builder: (context, _) => Column(
          children: [
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final item in modules)
                    if (item == 'Surfaces')
                      _surfaceToolbarMenu()
                    else if (item == 'Entidades')
                      _entityToolbarMenu()
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: ChoiceChip(
                          avatar: item == 'AI Engineering'
                              ? const Icon(Icons.psychology_outlined, size: 16)
                              : item == 'Reverse Engineering'
                              ? const Icon(
                                  Icons.account_tree_outlined,
                                  size: 16,
                                )
                              : null,
                          label: Text(
                            item,
                            style: TextStyle(
                              fontWeight: item == 'AI Engineering'
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          selected: module == item,
                          onSelected: (_) async {
                            if (item == 'Sketch') {
                              if (operational.stage ==
                                  SketchSurfaceStage.sketchActive) {
                                if (mounted) {
                                  setState(() {
                                    module = 'Sketch';
                                    choosingSketchSupport = false;
                                    openToolWindows.add('Sketch');
                                  });
                                }
                              } else {
                                _beginDirectSketchSupportSelection();
                              }
                            }
                            if (item != 'Sketch' && mounted) {
                              setState(() {
                                module = item;
                                openToolWindows.add(item);
                              });
                            }
                            try {
                              await widget.commands.dispatch(
                                'workspace.${item.toLowerCase().replaceAll(' ', '_')}',
                              );
                            } catch (error) {
                              // A workspace panel is a local UI surface and must
                              // still open when no coordinator command is
                              // registered for that module yet.
                              widget.cad.setStatus('$item aberto.');
                            }
                            if (item == 'Reverse Engineering') {
                              await operational
                                  .persistReverseEngineeringStudioState();
                            }
                          },
                        ),
                      ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Row(
                      children: [
                        _DockableSidePanel(
                          panelId: 'explorer',
                          title: 'Explorer',
                          icon: Icons.account_tree,
                          width: 240,
                          child: widget.cad.runtime.document == null
                              ? const _EmptyState(
                                  icon: Icons.folder_outlined,
                                  message:
                                      'Open a project to populate the engineering tree.',
                                )
                              : _documentExplorer(context),
                        ),
                        const VerticalDivider(),
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: IntegratedCadViewportWidget(
                                  scene: scene,
                                  camera: camera,
                                  operationalEntities:
                                      widget.cad.runtime.operationalEntities,
                                  operationalResolver:
                                      widget.cad.runtime.operationalResolver,
                                  operationalSelection:
                                      widget.cad.runtime.operationalSelection,
                                  showSketchGrid:
                                      module == 'Sketch' &&
                                      operational.stage ==
                                          SketchSurfaceStage.sketchActive,
                                  onSketchTap:
                                      module == 'Sketch' &&
                                          (operational
                                                  .sketchCreationCommandActive ||
                                              operational
                                                  .sketchEditingCommandActive)
                                      ? (position) {
                                          if (operational
                                              .sketchCreationCommandActive) {
                                            operational.captureSketchTap(
                                              position,
                                              camera,
                                            );
                                          }
                                        }
                                      : null,
                                  onSketchSupportPick:
                                      module == 'Sketch' &&
                                          choosingSketchSupport
                                      ? _selectSketchSupportFromViewport
                                      : null,
                                  onSketchEntityPick:
                                      module == 'Sketch' &&
                                          operational.stage ==
                                              SketchSurfaceStage.sketchActive &&
                                          (!operational
                                                  .sketchCreationCommandActive ||
                                              operational
                                                  .sketchEditingCommandActive)
                                      ? (pick) async {
                                          if (operational
                                              .sketchEditingCommandActive) {
                                            try {
                                              await operational
                                                  .captureSketchEditingPick(
                                                    pick,
                                                  );
                                              widget.cad.setStatus(
                                                '${operational.activeTool.name} ready · command remains active.',
                                              );
                                            } catch (error) {
                                              widget.cad.setStatus(
                                                error.toString(),
                                              );
                                            }
                                          } else {
                                            operational.cancelSketchCommand();
                                            operational.selectSketchEntity(
                                              pick.entityId,
                                              additive: HardwareKeyboard
                                                  .instance
                                                  .isControlPressed,
                                            );
                                          }
                                          geometrySelection.select(
                                            pick.entityId,
                                            toggle: false,
                                            range: false,
                                          );
                                          widget.cad.setStatus(
                                            'Sketch entity selected · edit parameters in Inspector.',
                                          );
                                        }
                                      : null,
                                  onSketchEntityDoublePick:
                                      module == 'Sketch' &&
                                          operational.stage ==
                                              SketchSurfaceStage.sketchActive
                                      ? (pick) {
                                          final entity = widget
                                              .cad
                                              .runtime
                                              .document
                                              ?.entities[pick.entityId];
                                          if (entity?.data['dimension']
                                              is Map) {
                                            geometrySelection.select(
                                              pick.entityId,
                                            );
                                            _activateEntityEditor(entity!);
                                          }
                                        }
                                      : null,
                                  onSketchSecondaryTap:
                                      module == 'Sketch' &&
                                          (operational
                                                  .sketchCreationCommandActive ||
                                              operational
                                                  .sketchEditingCommandActive)
                                      ? () {
                                          if (operational
                                              .sketchEditingCommandActive) {
                                            operational
                                                .finishSketchEditingTool();
                                          } else if (operational
                                              .arcCommandActive) {
                                            operational.finishArcCommand();
                                          } else if (operational
                                              .circleCommandActive) {
                                            operational.finishCircleCommand();
                                          } else {
                                            operational.finishLineCommand();
                                          }
                                        }
                                      : null,
                                  onSketchHover:
                                      module == 'Sketch' &&
                                          operational
                                              .sketchCreationCommandActive
                                      ? (position) =>
                                            operational.previewSketchPointer(
                                              position,
                                              camera,
                                            )
                                      : null,
                                  onSketchEntityDragStart:
                                      module == 'Sketch' &&
                                          operational.stage ==
                                              SketchSurfaceStage.sketchActive &&
                                          !operational
                                              .sketchCreationCommandActive &&
                                          !operational
                                              .sketchEditingCommandActive
                                      ? (pick, position) {
                                          operational.beginSketchEntityDrag(
                                            pick,
                                            position,
                                            camera,
                                          );
                                        }
                                      : null,
                                  onSketchEntityDragUpdate: module == 'Sketch'
                                      ? (position) =>
                                            operational.updateSketchEntityDrag(
                                              position,
                                              camera,
                                            )
                                      : null,
                                  onSketchEntityDragEnd: module == 'Sketch'
                                      ? (position) async {
                                          try {
                                            await operational
                                                .finishSketchEntityDrag(
                                                  position,
                                                  camera,
                                                );
                                            widget.cad.setStatus(
                                              'Sketch line moved · Undo is available.',
                                            );
                                          } catch (error) {
                                            widget.cad.setStatus(
                                              error.toString().replaceFirst(
                                                'Bad state: ',
                                                '',
                                              ),
                                            );
                                          }
                                        }
                                      : null,
                                  onPick: widget.cad.document == null
                                      ? null
                                      : (pick) async {
                                          geometrySelection.select(
                                            pick.entityId,
                                            toggle: HardwareKeyboard
                                                .instance
                                                .isControlPressed,
                                            range: HardwareKeyboard
                                                .instance
                                                .isShiftPressed,
                                          );
                                          selectDocument();
                                          final picked = widget
                                              .cad
                                              .runtime
                                              .document
                                              ?.entities[pick.entityId];
                                          if (module == 'Solids' &&
                                              operational
                                                  .selectExtrudeSourceFromViewport(
                                                    pick.entityId,
                                                  )) {
                                            widget.cad.setStatus(
                                              'Perfil do Extrude selecionado na área de trabalho.',
                                            );
                                          }
                                          if (picked?.mesh != null) {
                                            await operational.recognizePick(
                                              pick: pick,
                                            );
                                          } else {
                                            operational.activePick = pick;
                                            if (picked?.kind ==
                                                    CadDocumentEntityKind
                                                        .sketch &&
                                                picked?.data['sketchEntity']
                                                    is Map) {
                                              operational.toggleSketchSelection(
                                                pick.entityId,
                                              );
                                            }
                                          }
                                        },
                                ),
                              ),
                              if (module == 'Sketch' &&
                                  operational.sketchCreationCommandActive)
                                if (operational.activeSketchInference
                                    case final inference?)
                                  if (operational.sketchInferenceCursor
                                      case final cursor?)
                                    Positioned(
                                      left: cursor.dx + 12,
                                      top: math.max(4, cursor.dy - 20),
                                      child: IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: const Color(
                                              0xff0f1820,
                                            ).withValues(alpha: .82),
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
                                            border: Border.all(
                                              color: const Color(
                                                0xff62d98b,
                                              ).withValues(alpha: .7),
                                              width: .7,
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 4,
                                              vertical: 1,
                                            ),
                                            child: Text(
                                              inference.type.glyph,
                                              style: const TextStyle(
                                                color: Color(0xff8ce8aa),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                                height: 1.1,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                              if (module == 'Sketch' &&
                                  operational.sketchCreationCommandActive &&
                                  operational.sketchAssistantSuggestion !=
                                      null &&
                                  operational.sketchInferenceCursor != null)
                                Positioned(
                                  left:
                                      operational.sketchInferenceCursor!.dx +
                                      12,
                                  top: math.max(
                                    24,
                                    operational.sketchInferenceCursor!.dy + 4,
                                  ),
                                  child: IgnorePointer(
                                    child: Text(
                                      operational
                                          .sketchAssistantSuggestion!
                                          .label,
                                      style: const TextStyle(
                                        color: Color(0xff4de1d2),
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        shadows: [
                                          Shadow(
                                            color: Color(0xff081116),
                                            blurRadius: 3,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              if (module == 'Sketch' &&
                                  operational.sketchCreationCommandActive &&
                                  (operational.lineHud != null ||
                                      operational.circleHud != null ||
                                      operational.arcHud != null))
                                Positioned(
                                  left: 14,
                                  bottom: 14,
                                  child: operational.arcCommandActive
                                      ? _SketchArcHud(controller: operational)
                                      : operational.circleCommandActive
                                      ? _SketchCircleHud(
                                          controller: operational,
                                        )
                                      : _SketchLineHud(controller: operational),
                                ),
                            ],
                          ),
                        ),
                        const VerticalDivider(),
                        _DockableSidePanel(
                          panelId: 'inspector',
                          title: 'Property Inspector',
                          icon: Icons.tune,
                          width: 280,
                          child:
                              _sketchEnvironmentInspector() ??
                              _operationalInspector() ??
                              _documentEntityInspector() ??
                              (module == 'Sketch'
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'State: ${operational.stage.name}',
                                        ),
                                        Text(
                                          'Sketch entities: ${operational.sketchEntities.length}',
                                        ),
                                        Text(
                                          'Constraints: ${operational.constraints.length}',
                                        ),
                                        if (operational.surfacePlan != null)
                                          Text(
                                            'Surface quality: ${(operational.surfacePlan!.candidates.first.quality * 100).toStringAsFixed(1)}%',
                                          ),
                                        if (operational.activeSurface !=
                                            null) ...[
                                          Text(
                                            'Continuity: ${operational.activeSurface!.continuity.name}',
                                          ),
                                          Text(
                                            'Confidence: ${(operational.activeSurface!.confidence * 100).toStringAsFixed(1)}%',
                                          ),
                                          Text(
                                            'Kernel shape: ${operational.activeSurface!.handle.persistentId}',
                                          ),
                                        ],
                                        if (operational
                                                .professionalSurfacePreview !=
                                            null) ...[
                                          const Divider(),
                                          const Text(
                                            'Surface Edit Preview',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          Text(
                                            'Operation: ${operational.professionalSurfacePreview!.definition.tool.name}',
                                          ),
                                          Text(
                                            'Status: ${operational.professionalSurfacePreview!.definition.status.name}',
                                          ),
                                          Text(
                                            'Inputs: ${operational.professionalSurfacePreview!.definition.references.length}',
                                          ),
                                          Text(
                                            'Transient ShapeHandle: ${operational.professionalSurfacePreview!.definition.handle?.persistentId ?? '-'}',
                                          ),
                                          const Text(
                                            'Document impact: none until Apply',
                                          ),
                                          const Text(
                                            'Cancel discards the complete preview.',
                                          ),
                                          for (final parameter
                                              in operational
                                                  .professionalSurfacePreview!
                                                  .definition
                                                  .parameters
                                                  .entries
                                                  .where(
                                                    (entry) =>
                                                        entry.key !=
                                                            'shapeHandles' &&
                                                        entry.key !=
                                                            'sourceEntityIds',
                                                  ))
                                            Text(
                                              '${parameter.key}: ${parameter.value}',
                                            ),
                                        ],
                                        if (operational
                                            .professionalSurfaceValidationCompleted) ...[
                                          const Divider(),
                                          const Text(
                                            'BRep Validation',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          if (operational
                                              .professionalSurfaceValidation
                                              .isEmpty)
                                            const Text(
                                              'Valid: BRepCheck reported no errors.',
                                            )
                                          else
                                            for (final diagnostic
                                                in operational
                                                    .professionalSurfaceValidation)
                                              Text(diagnostic),
                                        ],
                                        if (operational
                                                .professionalSurfaceOperationReport
                                            case final report?) ...[
                                          const Divider(),
                                          const Text(
                                            'Operation Result',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          Text('State: ${report['state']}'),
                                          Text(
                                            'Affected entities: ${report['affectedEntities']}',
                                          ),
                                          Text(
                                            'Boundaries/loops: ${report['boundaries']}/${report['loops']}',
                                          ),
                                          Text(
                                            'Tolerance: ${report['tolerance']}',
                                          ),
                                          for (final entry
                                              in report.entries.where(
                                                (entry) => !const {
                                                  'operation',
                                                  'state',
                                                  'affectedEntities',
                                                  'boundaries',
                                                  'loops',
                                                  'tolerance',
                                                  'diagnostics',
                                                  'result',
                                                }.contains(entry.key),
                                              ))
                                            Text(
                                              '${entry.key}: ${entry.value}',
                                            ),
                                          Text(
                                            'Final diagnostic: ${report['result']}',
                                          ),
                                        ],
                                      ],
                                    )
                                  : module == 'Transform'
                                  ? Builder(
                                      builder: (context) {
                                        final selected =
                                            geometrySelection.selectedIds;
                                        if (selected.isEmpty) {
                                          return const Text(
                                            'Select an entity to transform.',
                                          );
                                        }
                                        final entity = widget
                                            .cad
                                            .runtime
                                            .document
                                            ?.entities[selected.first];
                                        final matrix =
                                            entity?.data['transformMatrix'];
                                        final collectionId =
                                            entity?.data['collectionId']
                                                as String?;
                                        final collection = collectionId == null
                                            ? null
                                            : widget
                                                  .cad
                                                  .runtime
                                                  .document
                                                  ?.entities[collectionId];
                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              entity?.data['name'] as String? ??
                                                  entity?.id ??
                                                  '-',
                                            ),
                                            Text(
                                              'Type: ${entity?.kind.name ?? '-'}',
                                            ),
                                            Text(
                                              'Selected: ${selected.length}',
                                            ),
                                            Text(
                                              'Collection: ${collection?.data['name'] ?? '-'}',
                                            ),
                                            Text(
                                              'Position/rotation/scale: ${matrix is List ? 'transformed' : 'identity'}',
                                            ),
                                            Text(
                                              'Active system: ${operational.manualTransformMode?.name ?? 'World'}',
                                            ),
                                            if (entity?.shape != null)
                                              const Text(
                                                'Native BRep transform: OCCT',
                                              ),
                                          ],
                                        );
                                      },
                                    )
                                  : module == 'Sections'
                                  ? Builder(
                                      builder: (context) {
                                        final entity =
                                            operational.selectedSection;
                                        final section = entity?.data['section'];
                                        if (section is! Map) {
                                          final sketch =
                                              operational.activeSketch;
                                          if (sketch == null) {
                                            return const Text(
                                              'Select a Section or associated Sketch.',
                                            );
                                          }
                                          final metadata = sketch.metadata;
                                          String metric(String key) =>
                                              ((metadata[key] as num?) ?? 0)
                                                  .toDouble()
                                                  .toStringAsFixed(6);
                                          return Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(sketch.name),
                                              Text(
                                                'Entities: ${sketch.entityIds.length}',
                                              ),
                                              Text(
                                                'Points: ${metadata['pointCount'] ?? 0}',
                                              ),
                                              Text(
                                                'Segments: ${metadata['segmentCount'] ?? 0}',
                                              ),
                                              Text(
                                                'Maximum error: ${metric('maximumError')} mm',
                                              ),
                                              Text(
                                                'Mean error: ${metric('meanError')} mm',
                                              ),
                                              Text(
                                                'Tolerance: ${metric('tolerance')} mm',
                                              ),
                                              Text(
                                                'Association: ${metadata['associationState'] ?? 'detached'}',
                                              ),
                                              Text(
                                                'Updated: ${metadata['lastUpdatedAt'] ?? '-'}',
                                              ),
                                            ],
                                          );
                                        }
                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              entity!.data['name'] as String,
                                            ),
                                            Text(
                                              'Segments: ${section['segmentCount']}',
                                            ),
                                            Text(
                                              'Loops: ${section['loopCount']}',
                                            ),
                                            Text(
                                              'Length: ${(section['length'] as num).toStringAsFixed(3)} mm',
                                            ),
                                            Text(
                                              'Closed: ${section['closed']}',
                                            ),
                                            Text(
                                              'Projected area: ${(section['projectedArea'] as num).toStringAsFixed(3)} mm²',
                                            ),
                                            Text(
                                              'Tolerance: ${section['toleranceUsed']}',
                                            ),
                                            const SizedBox(height: 8),
                                            FilledButton.tonalIcon(
                                              icon: const Icon(
                                                Icons.delete_outline,
                                              ),
                                              label: const Text(
                                                'Delete Section',
                                              ),
                                              onPressed: () => _sectionAction(
                                                () => operational.sections
                                                    .remove(entity.id),
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    )
                                  : module == 'Recognition'
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text('Alignment guidance'),
                                        if (operational.activeReference == null)
                                          const Text(
                                            'Accept a planar hypothesis and create its official reference.',
                                          )
                                        else ...[
                                          const Text(
                                            'Deseja criar um Sistema de Coordenadas utilizando essas referências?',
                                          ),
                                          const SizedBox(height: 8),
                                          const Text(
                                            'Deseja alinhar a peça utilizando este sistema?',
                                          ),
                                          if (operational.alignmentTransform !=
                                              null)
                                            Text(
                                              'Preview ativo: plano → ${operational.alignmentTarget}. Confirme somente após revisar a posição final.',
                                            ),
                                        ],
                                      ],
                                    )
                                  : modelingViewport.selection.isEmpty
                                  ? const _EmptyState(
                                      icon: Icons.touch_app_outlined,
                                      message:
                                          'Select an engineering object to inspect its properties.',
                                    )
                                  : ModelingPropertyInspector(
                                      context: InteractionContext(
                                        stage: InteractionStage.selected,
                                        selection: modelingViewport.selection,
                                        message: 'Selection synchronized',
                                      ),
                                      onParameterChanged: (key, value) =>
                                          widget.cad.setStatus(
                                            'Parameter $key updated to $value.',
                                          ),
                                    )),
                        ),
                        const VerticalDivider(),
                        _DockableSidePanel(
                          panelId: 'assistant',
                          title: 'Engineering Assistant',
                          icon: Icons.psychology_outlined,
                          width: 300,
                          initiallyCollapsed: true,
                          child: module == 'Reverse Engineering'
                              ? Builder(
                                  builder: (context) {
                                    final state = operational
                                        .reverseEngineeringStudioState;
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Reverse Engineering guidance',
                                        ),
                                        const SizedBox(height: 6),
                                        Text(state.explanation),
                                        if (state.blockReason != null) ...[
                                          const SizedBox(height: 6),
                                          Text(
                                            'Blocked: ${state.blockReason}',
                                            style: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.error,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 8),
                                        Text(
                                          'Next recommended action: ${state.nextAction}',
                                        ),
                                      ],
                                    );
                                  },
                                )
                              : _operationalAssistant() ??
                                    (module == 'Sketch'
                                        ? Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Text(
                                                'Certified operational guidance',
                                              ),
                                              Text(switch (operational.stage) {
                                                SketchSurfaceStage.idle =>
                                                  'Accept a planar Recognition hypothesis before creating a reference.',
                                                SketchSurfaceStage
                                                    .referenceReady =>
                                                  'The approved reference is ready for a Sketch session.',
                                                SketchSurfaceStage
                                                    .sketchActive =>
                                                  'Capture the profile points and review constraints before finishing.',
                                                SketchSurfaceStage
                                                    .sketchFinished =>
                                                  'A healthy profile can be inspected with Preview Surface.',
                                                SketchSurfaceStage
                                                    .surfacePreview =>
                                                  'The translucent film is temporary and follows every Sketch edit.',
                                                SketchSurfaceStage
                                                    .surfaceGenerated =>
                                                  'The CAD kernel generated and validated the surface.',
                                              }),
                                              if (operational.stage ==
                                                  SketchSurfaceStage
                                                      .sketchActive) ...[
                                                const SizedBox(height: 8),
                                                for (final recommendation
                                                    in operational
                                                            .editorApi
                                                            ?.recommendations ??
                                                        const [])
                                                  ListTile(
                                                    dense: true,
                                                    contentPadding:
                                                        EdgeInsets.zero,
                                                    leading: const Icon(
                                                      Icons.lightbulb_outline,
                                                      size: 17,
                                                    ),
                                                    title: Text(
                                                      recommendation.title,
                                                    ),
                                                    subtitle: Text(
                                                      recommendation.reason,
                                                    ),
                                                  ),
                                                const Text('Suggestions'),
                                                const Text(
                                                  '• Simplify the fitted spline',
                                                ),
                                                const Text(
                                                  '• Complete useful constraints',
                                                ),
                                                if (operational
                                                        .activeSketch
                                                        ?.metadata['associationState'] ==
                                                    'outdated')
                                                  const Text(
                                                    '• Update the associated Sketch',
                                                  ),
                                                const Text(
                                                  '• Prepare profile for Loft or Sweep',
                                                ),
                                              ],
                                              if (operational.surfacePlan !=
                                                  null)
                                                for (final evidence
                                                    in operational
                                                        .surfacePlan!
                                                        .candidates
                                                        .first
                                                        .evidence)
                                                  Text(
                                                    '• ${evidence.description}',
                                                  ),
                                              if (operational
                                                      .professionalSurfacePreview !=
                                                  null) ...[
                                                const Divider(),
                                                const Text(
                                                  'Surface editing guidance',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                                Text(
                                                  'Preview ${operational.professionalSurfacePreview!.definition.tool.name} is transient. Inspect the viewport before Apply.',
                                                ),
                                                Text(switch (operational
                                                    .professionalSurfacePreview!
                                                    .definition
                                                    .tool) {
                                                  ProfessionalSurfaceTool
                                                      .offset =>
                                                    'Check offset direction, self-intersections and boundary changes.',
                                                  ProfessionalSurfaceTool
                                                      .offsetWalls =>
                                                    'Review Offset mode, Inside/Outside/Bilateral direction, every Wall/Open boundary choice and the real topological result before Apply.',
                                                  ProfessionalSurfaceTool
                                                      .extend =>
                                                    'Check the extended side, length and continuity.',
                                                  ProfessionalSurfaceTool
                                                      .boundaryExtend =>
                                                    'Review the selected boundary, side, extension length or target, and continuity before Apply.',
                                                  ProfessionalSurfaceTool
                                                      .trim ||
                                                  ProfessionalSurfaceTool
                                                      .split =>
                                                    'Confirm which region will remain after the cut.',
                                                  ProfessionalSurfaceTool
                                                      .boundaryTrim =>
                                                    'Confirm the region identified by the yellow Keep Point; ambiguous or open regions must not be applied.',
                                                  ProfessionalSurfaceTool
                                                      .match =>
                                                    'Compare requested G0/G1/G2 tolerances with the kernel validation before Apply.',
                                                  ProfessionalSurfaceTool
                                                      .blend =>
                                                    'Review radius, support faces, consumed regions and continuity before Apply.',
                                                  ProfessionalSurfaceTool
                                                      .heal =>
                                                    'Review every topology correction proposed by ShapeFix.',
                                                  ProfessionalSurfaceTool
                                                      .healLocal =>
                                                    'Review the local ShapeFix proposal, before/after gaps and every directly affected adjacent entity.',
                                                  ProfessionalSurfaceTool
                                                      .replaceFace =>
                                                    'Create a Working Copy when appropriate and inspect every replacement-boundary mismatch.',
                                                  ProfessionalSurfaceTool
                                                      .deleteFace =>
                                                    'Review dependencies and the open Shell that will remain. Delete Face never fills implicitly.',
                                                  ProfessionalSurfaceTool
                                                      .unsewFace ||
                                                  ProfessionalSurfaceTool
                                                      .unsewSelected ||
                                                  ProfessionalSurfaceTool
                                                      .unsewAll =>
                                                    'Review every new open boundary and resulting independent Face group before Apply.',
                                                  ProfessionalSurfaceTool
                                                      .mergeFaces =>
                                                    'Confirm only same-domain faces are consolidated.',
                                                  ProfessionalSurfaceTool
                                                      .join =>
                                                    'Review sewing tolerance and remaining open boundaries.',
                                                  _ =>
                                                    'Review geometry and topology before committing.',
                                                }),
                                                const Text(
                                                  'Apply persists the result. Cancel preserves the current document.',
                                                ),
                                              ],
                                              if (operational
                                                      .professionalSurfaceOperationReport
                                                  case final report?) ...[
                                                const Divider(),
                                                Text(switch (report['result']) {
                                                  'Critical' =>
                                                    'Critical: do not apply before correcting the reported topology errors.',
                                                  'Attention' =>
                                                    'Attention: review boundaries and tolerances before Apply.',
                                                  _ =>
                                                    'OK: OCCT validation found no critical result problem.',
                                                }),
                                                Text(
                                                  '${report['affectedEntities']} input entity/entities affected · tolerance ${report['tolerance']}.',
                                                ),
                                              ],
                                            ],
                                          )
                                        : module == 'Transform'
                                        ? Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Text(
                                                'Manual transform guidance',
                                              ),
                                              Text(
                                                operational.transformDisposition ==
                                                        null
                                                    ? 'Transform Original or Create Working Copy?'
                                                    : operational
                                                              .manualTransformPreview ==
                                                          null
                                                    ? 'Select geometry and create a preview. The document is unchanged until Apply.'
                                                    : 'Deseja aplicar esta transformação permanentemente?',
                                              ),
                                              if (operational
                                                      .transformDisposition ==
                                                  TransformDisposition.original)
                                                const Text(
                                                  'The Original will move to the Modified Collection.',
                                                ),
                                              if (operational
                                                      .transformDisposition ==
                                                  TransformDisposition
                                                      .workingCopy)
                                                const Text(
                                                  'The Original remains intact and a new Working Copy Collection will be created.',
                                                ),
                                              if (operational
                                                      .manualTransformMode ==
                                                  ManualTransformMode.align)
                                                const Text(
                                                  'Deseja criar um novo Sistema de Coordenadas baseado nesta posição?',
                                                ),
                                            ],
                                          )
                                        : module == 'Sections'
                                        ? Builder(
                                            builder: (context) {
                                              final data = operational
                                                  .selectedSection
                                                  ?.data['section'];
                                              if (data is! Map) {
                                                final sketch =
                                                    operational.activeSketch;
                                                if (sketch == null) {
                                                  return const Text(
                                                    'Select a plane and create a Section, then convert it to a Sketch.',
                                                  );
                                                }
                                                final metadata =
                                                    sketch.metadata;
                                                final outdated =
                                                    metadata['associationState'] ==
                                                    'outdated';
                                                return Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    const Text(
                                                      'Section converted successfully.',
                                                    ),
                                                    Text(
                                                      'Maximum error: ${((metadata['maximumError'] as num?) ?? 0).toStringAsFixed(6)} mm',
                                                    ),
                                                    Text(
                                                      'Mean error: ${((metadata['meanError'] as num?) ?? 0).toStringAsFixed(6)} mm',
                                                    ),
                                                    Text(
                                                      'Entities: ${metadata['entityCount'] ?? sketch.entityIds.length}',
                                                    ),
                                                    Text(
                                                      outdated
                                                          ? 'The source Section changed. Do you want to update this Sketch?'
                                                          : 'Association with Section is active.',
                                                    ),
                                                    const SizedBox(height: 8),
                                                    const Text(
                                                      'Do you want to start editing the Sketch?',
                                                    ),
                                                  ],
                                                );
                                              }
                                              final quality =
                                                  (data['degenerations']
                                                              as int) ==
                                                          0 &&
                                                      (data['nonManifoldEdges']
                                                              as int) ==
                                                          0
                                                  ? 'Good'
                                                  : 'Review';
                                              return Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    'Segments: ${data['segmentCount']}',
                                                  ),
                                                  Text(
                                                    'Loops: ${data['loopCount']}',
                                                  ),
                                                  Text(
                                                    'Length: ${(data['length'] as num).toStringAsFixed(3)} mm',
                                                  ),
                                                  Text('Quality: $quality'),
                                                  Text(
                                                    'Candidates: ${data['candidateTriangles']} triangles',
                                                  ),
                                                  const SizedBox(height: 12),
                                                  const Text(
                                                    'Deseja converter esta Section em Sketch?',
                                                  ),
                                                  const Text(
                                                    'Choose Polyline or Best Fit Spline.',
                                                  ),
                                                ],
                                              );
                                            },
                                          )
                                        : modelingViewport.selection.isEmpty
                                        ? const _EmptyState(
                                            icon: Icons.chat_bubble_outline,
                                            message:
                                                'Assistant guidance appears when project evidence is available.',
                                          )
                                        : Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Text('Selected evidence'),
                                              for (final evidence
                                                  in modelingViewport
                                                      .selection
                                                      .first
                                                      .evidence)
                                                Text('• $evidence'),
                                              const SizedBox(height: 8),
                                              const Text(
                                                'No operation will execute until a preview is reviewed and explicitly accepted.',
                                              ),
                                            ],
                                          )),
                        ),
                      ],
                    ),
                  ),
                  if (openToolWindows.contains(module))
                    if (_activeToolWindowContent() case final tool?)
                      _ProfessionalToolWindow(
                        key: ValueKey('tool-window-$module'),
                        title:
                            module == 'Sketch' &&
                                operational.stage ==
                                    SketchSurfaceStage.sketchActive
                            ? 'Sketch'
                            : module,
                        onClose: () => _closeToolWindow(module),
                        child: tool,
                      ),
                ],
              ),
            ),
            if (widget.cad.busy)
              LinearProgressIndicator(value: widget.cad.progress),
            if (widget.cad.message != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(widget.cad.message!),
                ),
              ),
            Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: const Row(
                children: [
                  Icon(Icons.check_circle_outline, size: 16),
                  SizedBox(width: 6),
                  Text('Ready'),
                  Spacer(),
                  Text('OpenCascade · Project First · Consultative AI'),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

enum _CadGlyphKind {
  project,
  mesh,
  reference,
  section,
  sketch,
  curve,
  surface,
  solid,
  inspection,
  construction,
  plane,
  axis,
  point,
}

class _SketchEntryWorkspace extends StatelessWidget {
  const _SketchEntryWorkspace({
    required this.onChooseFromList,
    required this.onChooseWorldPlane,
  });
  final Future<void> Function() onChooseFromList;
  final Future<void> Function(SketchPlaneType) onChooseWorldPlane;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Sketch',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 6),
      Text(
        'Point to XY, YZ, ZX or another planar support directly in the viewport.',
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        'World planes',
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          for (final plane in const [
            ('XY', SketchPlaneType.xy),
            ('YZ', SketchPlaneType.yz),
            ('ZX', SketchPlaneType.zx),
          ]) ...[
            Expanded(
              child: FilledButton.tonal(
                onPressed: () => onChooseWorldPlane(plane.$2),
                child: Text(plane.$1),
              ),
            ),
            if (plane.$2 != SketchPlaneType.zx) const SizedBox(width: 6),
          ],
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        'You can also click a visible planar face or reference directly in the viewport.',
        style: TextStyle(fontSize: 10),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: onChooseFromList,
        icon: const Icon(Icons.list_alt_outlined, size: 18),
        label: const Text('Choose plane from list...'),
      ),
    ],
  );
}

class _EntitiesHubPanel extends StatefulWidget {
  const _EntitiesHubPanel({
    super.key,
    required this.runtime,
    required this.onStatus,
    this.initialConstructor = 0,
    this.initialPrimitiveType,
    this.pickedSourceId,
    this.pickedPoint,
    this.pickedTriangleIndex,
  });

  final CadRuntime runtime;
  final ValueChanged<String> onStatus;
  final int initialConstructor;
  final PrimitiveSurfaceType? initialPrimitiveType;
  final String? pickedSourceId;
  final Vector3? pickedPoint;
  final int? pickedTriangleIndex;

  @override
  State<_EntitiesHubPanel> createState() => _EntitiesHubPanelState();
}

class _EntitiesHubPanelState extends State<_EntitiesHubPanel> {
  late int constructor;

  @override
  void initState() {
    super.initState();
    constructor = widget.initialConstructor;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<int>(
          segments: const [
            ButtonSegment(
              value: 0,
              icon: Icon(Icons.add_location_alt_outlined),
              label: Text('Pontos'),
            ),
            ButtonSegment(
              value: 1,
              icon: Icon(Icons.layers_outlined),
              label: Text('Planos'),
            ),
            ButtonSegment(
              value: 2,
              icon: Icon(Icons.arrow_outward),
              label: Text('Vetores'),
            ),
            ButtonSegment(
              value: 3,
              icon: Icon(Icons.gesture),
              label: Text('Curvas'),
            ),
            ButtonSegment(
              value: 4,
              icon: Icon(Icons.blur_on_outlined),
              label: Text('Superfícies'),
            ),
          ],
          selected: {constructor},
          onSelectionChanged: (value) =>
              setState(() => constructor = value.first),
        ),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: constructor == 1
            ? _EntityPlanePanel(
                runtime: widget.runtime,
                onStatus: widget.onStatus,
                pickedSourceId: widget.pickedSourceId,
                pickedPoint: widget.pickedPoint,
                pickedTriangleIndex: widget.pickedTriangleIndex,
              )
            : constructor == 2
            ? _EntityVectorPanel(
                runtime: widget.runtime,
                onStatus: widget.onStatus,
                pickedSourceId: widget.pickedSourceId,
                pickedPoint: widget.pickedPoint,
                pickedTriangleIndex: widget.pickedTriangleIndex,
              )
            : constructor == 3
            ? _EntityCurvePanel(
                runtime: widget.runtime,
                onStatus: widget.onStatus,
                pickedSourceId: widget.pickedSourceId,
                pickedPoint: widget.pickedPoint,
              )
            : constructor == 4
            ? _EntityPrimitiveSurfacePanel(
                runtime: widget.runtime,
                onStatus: widget.onStatus,
                initialType: widget.initialPrimitiveType,
              )
            : _EntitiesWorkspacePanel(
                runtime: widget.runtime,
                onStatus: widget.onStatus,
                pickedSourceId: widget.pickedSourceId,
                pickedPoint: widget.pickedPoint,
              ),
      ),
    ],
  );
}

class _EntityPrimitiveSurfacePanel extends StatefulWidget {
  const _EntityPrimitiveSurfacePanel({
    required this.runtime,
    required this.onStatus,
    this.initialType,
  });
  final CadRuntime runtime;
  final ValueChanged<String> onStatus;
  final PrimitiveSurfaceType? initialType;
  @override
  State<_EntityPrimitiveSurfacePanel> createState() =>
      _EntityPrimitiveSurfacePanelState();
}

class _EntityPrimitiveSurfacePanelState
    extends State<_EntityPrimitiveSurfacePanel> {
  late PrimitiveSurfaceType type;
  final ox = TextEditingController(text: '0'),
      oy = TextEditingController(text: '0'),
      oz = TextEditingController(text: '0');
  final dx = TextEditingController(text: '0'),
      dy = TextEditingController(text: '0'),
      dz = TextEditingController(text: '1');
  final radius = TextEditingController(text: '10');
  final majorRadius = TextEditingController(text: '20'),
      minorRadius = TextEditingController(text: '5');
  final height = TextEditingController(text: '20'),
      angle = TextEditingController(text: '30');
  final planeSize = TextEditingController(text: '100');
  final latitudeStart = TextEditingController(text: '-90'),
      latitudeEnd = TextEditingController(text: '90');
  bool busy = false;

  @override
  void initState() {
    super.initState();
    type = widget.initialType ?? PrimitiveSurfaceType.plane;
  }

  double _number(TextEditingController controller, String label) {
    final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite) {
      throw FormatException('$label deve ser um número válido.');
    }
    return value;
  }

  Future<void> _create() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await EntityPrimitiveSurfaceService(widget.runtime).create(
        type: type,
        origin: Vector3(
          _number(ox, 'Origem X'),
          _number(oy, 'Origem Y'),
          _number(oz, 'Origem Z'),
        ),
        direction: Vector3(
          _number(dx, 'Direção X'),
          _number(dy, 'Direção Y'),
          _number(dz, 'Direção Z'),
        ),
        radius: _number(radius, 'Raio'),
        majorRadius: _number(majorRadius, 'Raio maior'),
        minorRadius: _number(minorRadius, 'Raio menor'),
        height: _number(height, 'Altura'),
        semiAngleDegrees: _number(angle, 'Semiângulo'),
        planeSize: _number(planeSize, 'Tamanho'),
        sphereLatitudeStartDegrees: _number(latitudeStart, 'Latitude inicial'),
        sphereLatitudeEndDegrees: _number(latitudeEnd, 'Latitude final'),
      );
      widget.onStatus(
        'Superfície ${type.name} criada diretamente pelo kernel, sem malha de origem.',
      );
    } catch (error) {
      widget.onStatus(
        error
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('FormatException: ', ''),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    for (final c in [
      ox,
      oy,
      oz,
      dx,
      dy,
      dz,
      radius,
      majorRadius,
      minorRadius,
      height,
      angle,
      planeSize,
      latitudeStart,
      latitudeEnd,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Entidades · Superfícies primitivas',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        const Text(
          'Criação analítica manual pelo kernel CAD. Nenhuma malha ou reconhecimento é necessário.',
          style: TextStyle(fontSize: 10),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<PrimitiveSurfaceType>(
          initialValue: type,
          decoration: const InputDecoration(
            labelText: 'Primitiva',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: const [
            DropdownMenuItem(
              value: PrimitiveSurfaceType.plane,
              child: Text('Plano'),
            ),
            DropdownMenuItem(
              value: PrimitiveSurfaceType.cylinder,
              child: Text('Cilindro'),
            ),
            DropdownMenuItem(
              value: PrimitiveSurfaceType.cone,
              child: Text('Cone'),
            ),
            DropdownMenuItem(
              value: PrimitiveSurfaceType.sphere,
              child: Text('Esfera'),
            ),
            DropdownMenuItem(
              value: PrimitiveSurfaceType.torus,
              child: Text('Toro'),
            ),
          ],
          onChanged: busy ? null : (value) => setState(() => type = value!),
        ),
        const SizedBox(height: 9),
        _vectorFields('Origem / centro / ápice', [
          ('X', ox),
          ('Y', oy),
          ('Z', oz),
        ]),
        if (type != PrimitiveSurfaceType.sphere) ...[
          const SizedBox(height: 7),
          _vectorFields(
            type == PrimitiveSurfaceType.plane ? 'Normal' : 'Direção do eixo',
            [('DX', dx), ('DY', dy), ('DZ', dz)],
          ),
        ],
        const SizedBox(height: 8),
        if (type == PrimitiveSurfaceType.plane)
          _field(planeSize, 'Tamanho do plano'),
        if ({
          PrimitiveSurfaceType.cylinder,
          PrimitiveSurfaceType.sphere,
        }.contains(type))
          _field(radius, 'Raio'),
        if ({
          PrimitiveSurfaceType.cylinder,
          PrimitiveSurfaceType.cone,
        }.contains(type)) ...[
          const SizedBox(height: 7),
          _field(height, 'Altura'),
        ],
        if (type == PrimitiveSurfaceType.cone) ...[
          const SizedBox(height: 7),
          _field(angle, 'Semiângulo (graus)'),
        ],
        if (type == PrimitiveSurfaceType.sphere) ...[
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(child: _field(latitudeStart, 'Latitude inicial')),
              const SizedBox(width: 5),
              Expanded(child: _field(latitudeEnd, 'Latitude final')),
            ],
          ),
        ],
        if (type == PrimitiveSurfaceType.torus) ...[
          Row(
            children: [
              Expanded(child: _field(majorRadius, 'Raio maior')),
              const SizedBox(width: 5),
              Expanded(child: _field(minorRadius, 'Raio menor')),
            ],
          ),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy ? null : _create,
          icon: busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.blur_on_outlined, size: 18),
          label: const Text('Criar superfície'),
        ),
        const SizedBox(height: 7),
        const Text(
          'O resultado é uma face B-Rep persistente, validada e tessellada apenas para exibição.',
          style: TextStyle(fontSize: 10),
        ),
      ],
    ),
  );

  Widget _field(TextEditingController controller, String label) => TextField(
    controller: controller,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
    keyboardType: const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
  );

  Widget _vectorFields(
    String label,
    List<(String, TextEditingController)> fields,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 10)),
      const SizedBox(height: 4),
      Row(
        children: [
          for (final item in fields) ...[
            Expanded(child: _field(item.$2, item.$1)),
            if (item != fields.last) const SizedBox(width: 5),
          ],
        ],
      ),
    ],
  );
}

class _EntityCurvePanel extends StatefulWidget {
  const _EntityCurvePanel({
    required this.runtime,
    required this.onStatus,
    this.pickedSourceId,
    this.pickedPoint,
  });
  final CadRuntime runtime;
  final ValueChanged<String> onStatus;
  final String? pickedSourceId;
  final Vector3? pickedPoint;
  @override
  State<_EntityCurvePanel> createState() => _EntityCurvePanelState();
}

class _EntityCurvePanelState extends State<_EntityCurvePanel> {
  ConstructionCurveMethod method = ConstructionCurveMethod.extractEdge;
  final u = TextEditingController(text: '0.5');
  final v = TextEditingController(text: '0.5');
  final samples = TextEditingController(text: '65');
  bool locateByPick = true;
  bool busy = false;
  List<String> get sourceIds =>
      widget.runtime.geometrySelection.selectedIds.toList(growable: false);

  double _number(TextEditingController controller, String label) {
    final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite) {
      throw FormatException('$label deve ser um número válido.');
    }
    return value;
  }

  Future<void> _create() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final ids = await EntityCurveService(widget.runtime).create(
        method: method,
        sourceEntityIds: sourceIds,
        u: _number(u, 'Parâmetro U'),
        v: _number(v, 'Parâmetro V'),
        samples: int.tryParse(samples.text.trim()) ?? 0,
        pickedPoint:
            widget.pickedSourceId != null &&
                sourceIds.contains(widget.pickedSourceId)
            ? widget.pickedPoint
            : null,
        locateByPickedPoint: locateByPick,
      );
      widget.onStatus(
        ids.length == 1
            ? 'Curva extraída e registrada no projeto.'
            : '${ids.length} curvas extraídas em uma única operação.',
      );
    } catch (error) {
      widget.onStatus(
        error
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('FormatException: ', ''),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    u.dispose();
    v.dispose();
    samples.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const labels = {
      ConstructionCurveMethod.extractEdge: 'Extrair aresta/curva selecionada',
      ConstructionCurveMethod.allBoundaries: 'Todas as bordas e loops',
      ConstructionCurveMethod.externalBoundary: 'Somente borda externa',
      ConstructionCurveMethod.isoU: 'Isoparamétrica U',
      ConstructionCurveMethod.isoV: 'Isoparamétrica V',
      ConstructionCurveMethod.isoBoth: 'Isoparamétricas U + V',
      ConstructionCurveMethod.surfacePlaneIntersection:
          'Interseção superfície × plano',
      ConstructionCurveMethod.meshSection: 'Seção de malha por plano',
    };
    final usesU = {
      ConstructionCurveMethod.isoU,
      ConstructionCurveMethod.isoBoth,
    }.contains(method);
    final usesV = {
      ConstructionCurveMethod.isoV,
      ConstructionCurveMethod.isoBoth,
    }.contains(method);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Entidades · Curvas',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          const Text(
            'Extração associativa de bordas, parâmetros UV e interseções.',
            style: TextStyle(fontSize: 10),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<ConstructionCurveMethod>(
            initialValue: method,
            decoration: const InputDecoration(
              labelText: 'Método',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final item in ConstructionCurveMethod.values)
                DropdownMenuItem(value: item, child: Text(labels[item]!)),
            ],
            onChanged: busy ? null : (value) => setState(() => method = value!),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              sourceIds.isEmpty
                  ? 'Selecione face, superfície, topologia, malha, aresta ou plano. Use Ctrl para múltiplas.'
                  : '${sourceIds.length} referência(s): ${sourceIds.join(', ')}',
              style: const TextStyle(fontSize: 10),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (usesU) ...[
            const SizedBox(height: 8),
            _field(u, 'Posição U normalizada (0–1)'),
          ],
          if (usesV) ...[
            const SizedBox(height: 8),
            _field(v, 'Posição V normalizada (0–1)'),
          ],
          if (usesU || usesV) ...[
            const SizedBox(height: 8),
            _field(samples, 'Amostras (2–2001)'),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Usar o ponto clicado para localizar U/V',
                style: TextStyle(fontSize: 11),
              ),
              value: locateByPick,
              onChanged: busy
                  ? null
                  : (value) => setState(() => locateByPick = value!),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: busy ? null : _create,
            icon: busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.gesture, size: 18),
            label: const Text('Extrair curva'),
          ),
          const SizedBox(height: 7),
          const Text(
            'U/V usa o domínio paramétrico real publicado pela superfície. Interseção e seção usam a triangulação persistida como fallback.',
            style: TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController controller, String label) => TextField(
    controller: controller,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
    keyboardType: const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
  );
}

class _EntityVectorPanel extends StatefulWidget {
  const _EntityVectorPanel({
    required this.runtime,
    required this.onStatus,
    this.pickedSourceId,
    this.pickedPoint,
    this.pickedTriangleIndex,
  });

  final CadRuntime runtime;
  final ValueChanged<String> onStatus;
  final String? pickedSourceId;
  final Vector3? pickedPoint;
  final int? pickedTriangleIndex;

  @override
  State<_EntityVectorPanel> createState() => _EntityVectorPanelState();
}

class _EntityVectorPanelState extends State<_EntityVectorPanel> {
  ConstructionVectorMethod method = ConstructionVectorMethod.xAxis;
  final ox = TextEditingController(text: '0');
  final oy = TextEditingController(text: '0');
  final oz = TextEditingController(text: '0');
  final vx = TextEditingController(text: '1');
  final vy = TextEditingController(text: '0');
  final vz = TextEditingController(text: '0');
  final length = TextEditingController(text: '40');
  bool reversed = false;
  bool busy = false;

  List<String> get sourceIds =>
      widget.runtime.geometrySelection.selectedIds.toList(growable: false);

  double _number(TextEditingController controller, String label) {
    final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite) {
      throw FormatException('$label deve ser um número válido.');
    }
    return value;
  }

  Vector3? get _pickedNormal {
    final id = widget.pickedSourceId;
    if (id == null || !sourceIds.contains(id)) return null;
    final geometry = widget.runtime.scene.find(id)?.geometry;
    if (geometry == null) return null;
    Vector3? vector(Object? raw) {
      if (raw is! List || raw.length < 3) return null;
      final x = raw[0], y = raw[1], z = raw[2];
      return x is num && y is num && z is num
          ? Vector3(x.toDouble(), y.toDouble(), z.toDouble())
          : null;
    }

    final explicit = vector(geometry['normal']);
    if (explicit != null) return explicit.normalized;
    final nodes = geometry['nodes'], triangles = geometry['triangles'];
    final triangle = widget.pickedTriangleIndex;
    if (nodes is! List ||
        triangles is! List ||
        triangle == null ||
        triangle < 0 ||
        triangle * 3 + 2 >= triangles.length) {
      return null;
    }
    Vector3 node(int index) => Vector3(
      (nodes[index * 3] as num).toDouble(),
      (nodes[index * 3 + 1] as num).toDouble(),
      (nodes[index * 3 + 2] as num).toDouble(),
    );
    final a = node((triangles[triangle * 3] as num).toInt());
    final b = node((triangles[triangle * 3 + 1] as num).toInt());
    final c = node((triangles[triangle * 3 + 2] as num).toInt());
    return (b - a).cross(c - a).normalized;
  }

  Future<void> _create() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await EntityVectorService(widget.runtime).create(
        method: method,
        sourceEntityIds: sourceIds,
        origin: Vector3(
          _number(ox, 'Origem X'),
          _number(oy, 'Origem Y'),
          _number(oz, 'Origem Z'),
        ),
        components: Vector3(
          _number(vx, 'Componente X'),
          _number(vy, 'Componente Y'),
          _number(vz, 'Componente Z'),
        ),
        pickedPoint:
            widget.pickedSourceId != null &&
                sourceIds.contains(widget.pickedSourceId)
            ? widget.pickedPoint
            : null,
        pickedNormal: _pickedNormal,
        visualLength: _number(length, 'Comprimento visual'),
        reverse: reversed,
      );
      widget.onStatus('Vetor criado, associado e registrado no projeto.');
    } catch (error) {
      widget.onStatus(
        error
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('FormatException: ', ''),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    for (final controller in [ox, oy, oz, vx, vy, vz, length]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const labels = {
      ConstructionVectorMethod.xAxis: 'Eixo principal X',
      ConstructionVectorMethod.yAxis: 'Eixo principal Y',
      ConstructionVectorMethod.zAxis: 'Eixo principal Z',
      ConstructionVectorMethod.components: 'Origem + componentes XYZ',
      ConstructionVectorMethod.twoPoints: 'Entre dois pontos',
      ConstructionVectorMethod.directionBetweenEntities: 'Entre duas entidades',
      ConstructionVectorMethod.fromLineOrCurve: 'Extrair de linha/curva',
      ConstructionVectorMethod.tangentToCurve: 'Tangente à curva',
      ConstructionVectorMethod.planeNormal: 'Normal a plano',
      ConstructionVectorMethod.surfaceNormal: 'Normal a superfície/malha',
      ConstructionVectorMethod.planeIntersection: 'Interseção de dois planos',
      ConstructionVectorMethod.crossProduct: 'Produto vetorial',
      ConstructionVectorMethod.bisector: 'Bissetor de direções',
      ConstructionVectorMethod.projectedOnPlane: 'Projetado sobre plano',
      ConstructionVectorMethod.reverse: 'Inverter vetor existente',
      ConstructionVectorMethod.bestFitDirection: 'Best-fit de direção',
    };
    final manual = method == ConstructionVectorMethod.components;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Entidades · Vetores',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          const Text(
            'Direções construtivas, derivadas e extraídas de CAD ou scan.',
            style: TextStyle(fontSize: 10),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<ConstructionVectorMethod>(
            initialValue: method,
            decoration: const InputDecoration(
              labelText: 'Método',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final item in ConstructionVectorMethod.values)
                DropdownMenuItem(value: item, child: Text(labels[item]!)),
            ],
            onChanged: busy ? null : (value) => setState(() => method = value!),
          ),
          const SizedBox(height: 10),
          if (manual) ...[
            _vectorFields('Origem', [('X', ox), ('Y', oy), ('Z', oz)]),
            const SizedBox(height: 7),
            _vectorFields('Componentes', [('VX', vx), ('VY', vy), ('VZ', vz)]),
          ] else
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                sourceIds.isEmpty
                    ? 'Selecione referências no viewport (Ctrl para múltiplas).'
                    : '${sourceIds.length} referência(s): ${sourceIds.join(', ')}',
                style: const TextStyle(fontSize: 10),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(height: 8),
          _field(length, 'Comprimento visual'),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Inverter direção',
              style: TextStyle(fontSize: 11),
            ),
            value: reversed,
            onChanged: busy
                ? null
                : (value) => setState(() => reversed = value!),
          ),
          FilledButton.icon(
            onPressed: busy ? null : _create,
            icon: busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_outward, size: 18),
            label: const Text('Criar vetor'),
          ),
          const SizedBox(height: 7),
          const Text(
            'Tangente e normal local usam o ponto clicado. Best-fit registra RMS e desvio máximo.',
            style: TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController controller, String label) => TextField(
    controller: controller,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
    keyboardType: const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
  );

  Widget _vectorFields(
    String label,
    List<(String, TextEditingController)> fields,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 10)),
      const SizedBox(height: 4),
      Row(
        children: [
          for (final item in fields) ...[
            Expanded(child: _field(item.$2, item.$1)),
            if (item != fields.last) const SizedBox(width: 5),
          ],
        ],
      ),
    ],
  );
}

class _EntityPlanePanel extends StatefulWidget {
  const _EntityPlanePanel({
    required this.runtime,
    required this.onStatus,
    this.pickedSourceId,
    this.pickedPoint,
    this.pickedTriangleIndex,
  });

  final CadRuntime runtime;
  final ValueChanged<String> onStatus;
  final String? pickedSourceId;
  final Vector3? pickedPoint;
  final int? pickedTriangleIndex;

  @override
  State<_EntityPlanePanel> createState() => _EntityPlanePanelState();
}

class _EntityPlanePanelState extends State<_EntityPlanePanel> {
  ConstructionPlaneMethod method = ConstructionPlaneMethod.xy;
  final ox = TextEditingController(text: '0');
  final oy = TextEditingController(text: '0');
  final oz = TextEditingController(text: '0');
  final nx = TextEditingController(text: '0');
  final ny = TextEditingController(text: '0');
  final nz = TextEditingController(text: '1');
  final distance = TextEditingController(text: '10');
  final angle = TextEditingController(text: '45');
  final tolerance = TextEditingController(text: '0.05');
  final size = TextEditingController(text: '60');
  bool busy = false;

  List<String> get sourceIds =>
      widget.runtime.geometrySelection.selectedIds.toList(growable: false);

  double _number(TextEditingController controller, String label) {
    final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite) {
      throw FormatException('$label deve ser um número válido.');
    }
    return value;
  }

  Vector3? get _pickedNormal {
    final id = widget.pickedSourceId;
    if (id == null || !sourceIds.contains(id)) return null;
    final geometry = widget.runtime.scene.find(id)?.geometry;
    if (geometry == null) return null;
    Vector3? vector(Object? raw) {
      if (raw is! List || raw.length < 3) return null;
      final x = raw[0], y = raw[1], z = raw[2];
      return x is num && y is num && z is num
          ? Vector3(x.toDouble(), y.toDouble(), z.toDouble())
          : null;
    }

    final explicit = vector(geometry['normal']);
    if (explicit != null) return explicit.normalized;
    final nodes = geometry['nodes'], triangles = geometry['triangles'];
    final triangleIndex = widget.pickedTriangleIndex;
    if (nodes is List &&
        triangles is List &&
        triangleIndex != null &&
        triangleIndex >= 0 &&
        triangleIndex * 3 + 2 < triangles.length) {
      Vector3 node(int index) => Vector3(
        (nodes[index * 3] as num).toDouble(),
        (nodes[index * 3 + 1] as num).toDouble(),
        (nodes[index * 3 + 2] as num).toDouble(),
      );
      final a = node((triangles[triangleIndex * 3] as num).toInt());
      final b = node((triangles[triangleIndex * 3 + 1] as num).toInt());
      final c = node((triangles[triangleIndex * 3 + 2] as num).toInt());
      return (b - a).cross(c - a).normalized;
    }
    return null;
  }

  Future<void> _create() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await EntityPlaneService(widget.runtime).create(
        method: method,
        sourceEntityIds: sourceIds,
        origin: Vector3(
          _number(ox, 'Origem X'),
          _number(oy, 'Origem Y'),
          _number(oz, 'Origem Z'),
        ),
        normal: Vector3(
          _number(nx, 'Normal X'),
          _number(ny, 'Normal Y'),
          _number(nz, 'Normal Z'),
        ),
        pickedPoint:
            widget.pickedSourceId != null &&
                sourceIds.contains(widget.pickedSourceId)
            ? widget.pickedPoint
            : null,
        pickedNormal: _pickedNormal,
        distance: _number(distance, 'Distância'),
        angleDegrees: _number(angle, 'Ângulo'),
        planarTolerance: _number(tolerance, 'Tolerância'),
        visualSize: _number(size, 'Tamanho visual'),
      );
      widget.onStatus('Plano criado, associado e registrado no projeto.');
    } catch (error) {
      widget.onStatus(
        error
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('FormatException: ', ''),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    for (final controller in [
      ox,
      oy,
      oz,
      nx,
      ny,
      nz,
      distance,
      angle,
      tolerance,
      size,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const labels = {
      ConstructionPlaneMethod.xy: 'Plano principal XY',
      ConstructionPlaneMethod.yz: 'Plano principal YZ',
      ConstructionPlaneMethod.zx: 'Plano principal ZX',
      ConstructionPlaneMethod.originNormal: 'Origem + normal',
      ConstructionPlaneMethod.threePoints: 'Por três pontos',
      ConstructionPlaneMethod.offset: 'Offset de plano',
      ConstructionPlaneMethod.parallelThroughPoint: 'Paralelo por ponto',
      ConstructionPlaneMethod.midPlane: 'Plano médio / bissetor',
      ConstructionPlaneMethod.perpendicular: 'Perpendicular a plano',
      ConstructionPlaneMethod.angle: 'Angular em torno de eixo',
      ConstructionPlaneMethod.normalToCurve: 'Normal a curva no ponto',
      ConstructionPlaneMethod.tangentToSurface: 'Tangente à superfície',
      ConstructionPlaneMethod.lineAndPoint: 'Linha e ponto',
      ConstructionPlaneMethod.twoLines: 'Por duas linhas',
      ConstructionPlaneMethod.bestFit: 'Best-fit em scan/geometria',
      ConstructionPlaneMethod.extractPlanar: 'Extrair face/região plana',
    };
    final manual = method == ConstructionPlaneMethod.originNormal;
    final showDistance = method == ConstructionPlaneMethod.offset;
    final showAngle = method == ConstructionPlaneMethod.angle;
    final showTolerance = {
      ConstructionPlaneMethod.bestFit,
      ConstructionPlaneMethod.extractPlanar,
    }.contains(method);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Entidades · Planos',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          const Text(
            'Planos construtivos, derivados e extraídos de CAD ou scan.',
            style: TextStyle(fontSize: 10),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<ConstructionPlaneMethod>(
            initialValue: method,
            decoration: const InputDecoration(
              labelText: 'Método',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final item in ConstructionPlaneMethod.values)
                DropdownMenuItem(value: item, child: Text(labels[item]!)),
            ],
            onChanged: busy ? null : (value) => setState(() => method = value!),
          ),
          const SizedBox(height: 10),
          if (manual) ...[
            _vectorFields('Origem', [('X', ox), ('Y', oy), ('Z', oz)]),
            const SizedBox(height: 7),
            _vectorFields('Normal', [('NX', nx), ('NY', ny), ('NZ', nz)]),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                sourceIds.isEmpty
                    ? 'Selecione as referências no viewport (Ctrl para múltiplas).'
                    : '${sourceIds.length} referência(s): ${sourceIds.join(', ')}',
                style: const TextStyle(fontSize: 10),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          if (showDistance) ...[
            const SizedBox(height: 8),
            _field(distance, 'Distância de offset'),
          ],
          if (showAngle) ...[
            const SizedBox(height: 8),
            _field(angle, 'Ângulo (graus)'),
          ],
          if (showTolerance) ...[
            const SizedBox(height: 8),
            _field(tolerance, 'Tolerância de planaridade'),
          ],
          const SizedBox(height: 8),
          _field(size, 'Tamanho visual do plano'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: busy ? null : _create,
            icon: busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.layers_outlined, size: 18),
            label: const Text('Criar plano'),
          ),
          const SizedBox(height: 7),
          const Text(
            'Para tangência, clique diretamente na face ou malha. Best-fit usa todas as amostras das entidades selecionadas.',
            style: TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController controller, String label) => TextField(
    controller: controller,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
    keyboardType: const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
  );

  Widget _vectorFields(
    String label,
    List<(String, TextEditingController)> fields,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 10)),
      const SizedBox(height: 4),
      Row(
        children: [
          for (final item in fields) ...[
            Expanded(child: _field(item.$2, item.$1)),
            if (item != fields.last) const SizedBox(width: 5),
          ],
        ],
      ),
    ],
  );
}

class _EntitiesWorkspacePanel extends StatefulWidget {
  const _EntitiesWorkspacePanel({
    required this.runtime,
    required this.onStatus,
    this.pickedSourceId,
    this.pickedPoint,
  });

  final CadRuntime runtime;
  final ValueChanged<String> onStatus;
  final String? pickedSourceId;
  final Vector3? pickedPoint;

  @override
  State<_EntitiesWorkspacePanel> createState() =>
      _EntitiesWorkspacePanelState();
}

class _EntitiesWorkspacePanelState extends State<_EntitiesWorkspacePanel> {
  ConstructionPointMethod method = ConstructionPointMethod.coordinates;
  final x = TextEditingController(text: '0');
  final y = TextEditingController(text: '0');
  final z = TextEditingController(text: '0');
  final parameter = TextEditingController(text: '0.5');
  final count = TextEditingController(text: '3');
  bool busy = false;

  String? get sourceId {
    final selected = widget.runtime.geometrySelection.selectedIds;
    return selected.isEmpty ? null : selected.first;
  }

  bool get needsSource => method != ConstructionPointMethod.coordinates;

  double _number(TextEditingController controller, String label) {
    final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite) {
      throw FormatException('$label deve ser um número válido.');
    }
    return value;
  }

  Future<void> _create() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final ids = await EntityPointService(widget.runtime).create(
        method: method,
        sourceEntityId: needsSource ? sourceId : null,
        coordinates: Vector3(_number(x, 'X'), _number(y, 'Y'), _number(z, 'Z')),
        pickedPoint:
            method == ConstructionPointMethod.onEntity &&
                widget.pickedSourceId == sourceId
            ? widget.pickedPoint
            : null,
        parameter: _number(parameter, 'Parâmetro'),
        divisionCount: int.tryParse(count.text.trim()) ?? 0,
      );
      widget.onStatus(
        ids.length == 1
            ? 'Ponto criado e registrado no projeto.'
            : '${ids.length} pontos equidistantes criados em uma única operação.',
      );
    } catch (error) {
      widget.onStatus(error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    x.dispose();
    y.dispose();
    z.dispose();
    parameter.dispose();
    count.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const labels = {
      ConstructionPointMethod.coordinates: 'Coordenadas',
      ConstructionPointMethod.startPoint: 'Endpoint inicial',
      ConstructionPointMethod.endPoint: 'Endpoint final',
      ConstructionPointMethod.midpoint: 'Midpoint',
      ConstructionPointMethod.equidistant: 'Equidistantes',
      ConstructionPointMethod.onEntity: 'Sobre entidade',
    };
    final source = sourceId == null
        ? null
        : widget.runtime.document?.entities[sourceId!];
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.category_outlined, size: 19),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Entidades · Pontos',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Construa pontos associativos a partir de qualquer geometria selecionável.',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: 20),
          DropdownButtonFormField<ConstructionPointMethod>(
            initialValue: method,
            decoration: const InputDecoration(
              labelText: 'Método',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final item in ConstructionPointMethod.values)
                DropdownMenuItem(value: item, child: Text(labels[item]!)),
            ],
            onChanged: busy ? null : (value) => setState(() => method = value!),
          ),
          const SizedBox(height: 10),
          if (method == ConstructionPointMethod.coordinates)
            Row(
              children: [
                for (final field in [('X', x), ('Y', y), ('Z', z)]) ...[
                  Expanded(
                    child: TextField(
                      controller: field.$2,
                      decoration: InputDecoration(
                        labelText: field.$1,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                    ),
                  ),
                  if (field.$1 != 'Z') const SizedBox(width: 5),
                ],
              ],
            )
          else
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(
                children: [
                  Icon(
                    source == null ? Icons.ads_click : Icons.check_circle,
                    size: 17,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      source == null
                          ? 'Selecione a entidade de origem'
                          : '${source.data['name'] ?? source.id} · ${source.kind.name}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          if (method == ConstructionPointMethod.onEntity) ...[
            const SizedBox(height: 10),
            TextField(
              controller: parameter,
              decoration: const InputDecoration(
                labelText: 'Parâmetro (0–1), se não houver clique 3D',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
          if (method == ConstructionPointMethod.equidistant) ...[
            const SizedBox(height: 10),
            TextField(
              controller: count,
              decoration: const InputDecoration(
                labelText: 'Quantidade de pontos (2–1000)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.number,
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: busy || (needsSource && source == null) ? null : _create,
            icon: busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_location_alt_outlined, size: 18),
            label: Text(
              method == ConstructionPointMethod.equidistant
                  ? 'Criar pontos'
                  : 'Criar ponto',
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Próximas entidades: planos e vetores. O contrato do comando já aceita novos construtores.',
            style: TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceEnvironmentPlaceholder extends StatelessWidget {
  const _WorkspaceEnvironmentPlaceholder({
    required this.icon,
    required this.title,
    required this.description,
    required this.capabilities,
  });
  final IconData icon;
  final String title;
  final String description;
  final List<String> capabilities;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Icon(icon, size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        description,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const Divider(height: 20),
      for (final capability in capabilities)
        Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: OutlinedButton(
            onPressed: null,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(capability),
            ),
          ),
        ),
    ],
  );
}

class _SketchWorkspaceFoundation extends StatelessWidget {
  const _SketchWorkspaceFoundation({
    required this.controller,
    required this.onExitSketch,
    required this.onHealthIssue,
    required this.onAutoHeal,
  });
  final OperationalReverseEngineeringController controller;
  final Future<void> Function() onExitSketch;
  final ValueChanged<SketchHealthIssue> onHealthIssue;
  final Future<void> Function(SketchHealthIssue) onAutoHeal;

  Future<void> _createDimension(
    BuildContext context,
    SketchDimensionType type,
  ) async {
    final input = TextEditingController();
    final entityId = controller.selectedSketchEntityIds.single;
    final lineDimension =
        type == SketchDimensionType.linear ||
        type == SketchDimensionType.angular;
    var anchor = 'automatic';
    final result = await showDialog<(double, String?)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('${type.name} driving dimension'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: input,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: type == SketchDimensionType.angular
                      ? 'Angle'
                      : 'Value',
                  suffixText: type == SketchDimensionType.angular ? '°' : 'mm',
                ),
              ),
              if (lineDimension)
                DropdownButtonFormField<String>(
                  initialValue: anchor,
                  decoration: const InputDecoration(labelText: 'Anchor'),
                  items: const [
                    DropdownMenuItem(
                      value: 'automatic',
                      child: Text('Automatic · smallest movement'),
                    ),
                    DropdownMenuItem(
                      value: 'start',
                      child: Text('Keep start fixed'),
                    ),
                    DropdownMenuItem(
                      value: 'end',
                      child: Text('Keep end fixed'),
                    ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => anchor = value ?? 'automatic'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = double.tryParse(input.text.replaceAll(',', '.'));
                if (value != null) {
                  Navigator.pop(context, (
                    value,
                    anchor == 'automatic' ? null : '$entityId:$anchor',
                  ));
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    input.dispose();
    if (result == null) return;
    await controller.createDrivingDimension(
      type,
      result.$1,
      anchorReference: result.$2,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hud = controller.lineHud;
    final dragHud = controller.sketchDragHud;
    final health = controller.sketchHealth;
    final dimensionEntity = controller.selectedSketchEntityIds.length == 1
        ? controller.sketchApi?.entity(
            controller.selectedSketchEntityIds.single,
          )
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Sketch Environment',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '${controller.activeSketch?.name ?? 'No active Sketch'} · '
          '${controller.sketchEntities.length} geometries · '
          'Orthographic view · local grid',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const Divider(height: 20),
        ExpansionTile(
          initiallyExpanded: true,
          dense: true,
          tilePadding: EdgeInsets.zero,
          leading: Icon(
            health.readyForSurface
                ? Icons.health_and_safety
                : Icons.warning_amber,
            size: 18,
            color: health.readyForSurface ? Colors.green : Colors.redAccent,
          ),
          title: const Text('Sketch Health'),
          subtitle: Text(
            health.readyForSurface ? 'Sketch Ready' : 'Sketch contains errors',
            style: const TextStyle(fontSize: 9.5),
          ),
          children: [
            _SketchHealthCheck(
              label: controller.sketchEntities.isEmpty
                  ? 'Empty Sketch'
                  : health.closedProfile
                  ? 'Closed Profile'
                  : 'Open Profile',
              ok: health.closedProfile,
            ),
            _SketchHealthCheck(
              label: health.hasDuplicates
                  ? '${health.issues.where((i) => i.type == SketchHealthIssueType.duplicate || i.type == SketchHealthIssueType.overlap).length} Duplicates / Overlaps'
                  : 'No Duplicates',
              ok: !health.hasDuplicates,
            ),
            _SketchHealthCheck(
              label: health.hasGaps
                  ? '${health.issues.where((i) => i.type == SketchHealthIssueType.gap).length} Gap(s)'
                  : 'No Gaps',
              ok: !health.hasGaps,
            ),
            _SketchHealthCheck(
              label: health.hasSelfIntersections
                  ? 'Self Intersections'
                  : 'No Self Intersections',
              ok: !health.hasSelfIntersections,
            ),
            _SketchHealthCheck(
              label: health.hasTinyGeometry
                  ? 'Tiny Geometry'
                  : 'No Tiny Geometry',
              ok: !health.hasTinyGeometry,
            ),
            for (final issue in health.issues)
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: const Icon(
                  Icons.error_outline,
                  size: 15,
                  color: Colors.redAccent,
                ),
                title: Text(
                  issue.message,
                  style: const TextStyle(fontSize: 10.5),
                ),
                subtitle: Text(
                  issue.entityIds.join(' · '),
                  style: const TextStyle(fontSize: 9),
                ),
                onTap: () => issue.canAutoHeal
                    ? onAutoHeal(issue)
                    : onHealthIssue(issue),
                trailing: issue.canAutoHeal
                    ? TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        icon: const Icon(Icons.healing, size: 15),
                        label: const Text(
                          'Close gap',
                          style: TextStyle(fontSize: 9.5),
                        ),
                        onPressed: () => onAutoHeal(issue),
                      )
                    : const Icon(Icons.zoom_in, size: 16),
              ),
          ],
        ),
        ExpansionTile(
          initiallyExpanded: true,
          dense: true,
          tilePadding: EdgeInsets.zero,
          title: const Text('Create'),
          leading: const Icon(Icons.add_box_outlined, size: 17),
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed:
                    !controller.sketchCreationCommandActive &&
                        !controller.sketchEditingCommandActive
                    ? null
                    : controller.enterSketchSelectionMode,
                icon: const Icon(Icons.near_me_outlined, size: 17),
                label: Text(
                  !controller.sketchCreationCommandActive &&
                          !controller.sketchEditingCommandActive
                      ? 'Selection Active'
                      : 'Select / Edit',
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: controller.lineCommandActive
                        ? controller.enterSketchSelectionMode
                        : controller.beginLineCommand,
                    icon: const Icon(Icons.show_chart, size: 17),
                    label: Text(
                      controller.lineCommandActive ? 'Drawing' : 'Line',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: controller.circleCommandActive
                        ? controller.enterSketchSelectionMode
                        : () => controller.beginCircleCommand(
                            controller.circleMode,
                          ),
                    icon: const Icon(Icons.circle_outlined, size: 17),
                    label: Text(
                      controller.circleCommandActive ? 'Drawing' : 'Circle',
                    ),
                  ),
                ),
                PopupMenuButton<SketchCircleMode>(
                  tooltip: 'Circle creation mode',
                  icon: const Icon(Icons.arrow_drop_down, size: 20),
                  onSelected: controller.beginCircleCommand,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: SketchCircleMode.centerRadius,
                      child: Text('Center + Radius'),
                    ),
                    PopupMenuItem(
                      value: SketchCircleMode.centerDiameter,
                      child: Text('Center + Diameter'),
                    ),
                    PopupMenuItem(
                      value: SketchCircleMode.twoPoints,
                      child: Text('Two Points'),
                    ),
                    PopupMenuItem(
                      value: SketchCircleMode.threePoints,
                      child: Text('Three Points'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      enabled: false,
                      value: SketchCircleMode.tangentRadius,
                      child: Text('Tangent + Radius — Preparation'),
                    ),
                    PopupMenuItem(
                      enabled: false,
                      value: SketchCircleMode.tangentTangentRadius,
                      child: Text('2 Tangencies + Radius — Preparation'),
                    ),
                    PopupMenuItem(
                      enabled: false,
                      value: SketchCircleMode.threeTangencies,
                      child: Text('Three Tangencies — Preparation'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: controller.arcCommandActive
                        ? controller.enterSketchSelectionMode
                        : () => controller.beginArcCommand(controller.arcMode),
                    icon: const Icon(Icons.architecture_outlined, size: 17),
                    label: Text(
                      controller.arcCommandActive ? 'Drawing Arc' : 'Arc',
                    ),
                  ),
                ),
                PopupMenuButton<SketchArcMode>(
                  tooltip: 'Arc creation mode',
                  icon: const Icon(Icons.arrow_drop_down, size: 20),
                  onSelected: controller.beginArcCommand,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: SketchArcMode.center,
                      child: Text('Center Arc'),
                    ),
                    PopupMenuItem(
                      value: SketchArcMode.threePoints,
                      child: Text('Three-Point Arc'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      enabled: false,
                      value: SketchArcMode.tangent,
                      child: Text('Tangent Arc — Preparation'),
                    ),
                  ],
                ),
              ],
            ),
            if (controller.circleCommandActive)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  'Mode: ${_circleModeLabel(controller.circleMode)}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (controller.arcCommandActive)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  'Mode: ${_arcModeLabel(controller.arcMode)}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        if (controller.sketchCreationCommandActive)
          _SketchDirectInput(controller: controller),
        ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          leading: const Icon(Icons.auto_fix_high_outlined, size: 17),
          title: const Text('Sketch Assistant'),
          subtitle: Text(
            controller.sketchAssistantSuggestion?.label ??
                'Reference Curves · suggestions only',
            style: const TextStyle(fontSize: 9.5),
          ),
          children: [
            SegmentedButton<SketchAssistantPrecision>(
              segments: const [
                ButtonSegment(
                  value: SketchAssistantPrecision.high,
                  label: Text('High'),
                ),
                ButtonSegment(
                  value: SketchAssistantPrecision.medium,
                  label: Text('Medium'),
                ),
                ButtonSegment(
                  value: SketchAssistantPrecision.low,
                  label: Text('Low'),
                ),
              ],
              selected: {controller.sketchAssistantPrecision},
              onSelectionChanged: (value) =>
                  controller.setSketchAssistantPrecision(value.single),
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: controller.sketchAssistantSuggestion == null
                        ? null
                        : controller.acceptSketchAssistantSuggestion,
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Confirm suggestion'),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: controller.selectedSketchEntityIds.length == 1
                        ? () async {
                            try {
                              await controller
                                  .fitSelectedSketchEntityToReferenceCurve();
                            } catch (_) {}
                          }
                        : null,
                    icon: const Icon(Icons.fit_screen, size: 16),
                    label: const Text('Fit to curve'),
                  ),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 7, 8, 0),
              child: Text(
                'Cyan dashed geometry is temporary. Nothing is created until confirmation.',
                style: TextStyle(fontSize: 9.5),
              ),
            ),
          ],
        ),
        ExpansionTile(
          initiallyExpanded: controller.sketchEditingCommandActive,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          leading: const Icon(Icons.edit_outlined, size: 17),
          title: const Text('Modify'),
          subtitle: controller.sketchEditingCommandActive
              ? Text(
                  '${controller.activeTool.name.toUpperCase()} · persistent',
                  style: const TextStyle(fontSize: 9.5),
                )
              : null,
          children: [
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final item in const [
                  ('Trim', Icons.content_cut, SketchToolType.trim),
                  ('Extend', Icons.trending_flat, SketchToolType.extend),
                  ('Fillet', Icons.rounded_corner, SketchToolType.fillet),
                  ('Chamfer', Icons.change_history, SketchToolType.chamfer),
                ])
                  Tooltip(
                    message: item.$1,
                    child: IconButton.filledTonal(
                      isSelected:
                          controller.sketchEditingCommandActive &&
                          controller.activeTool == item.$3,
                      onPressed: () =>
                          controller.beginSketchEditingTool(item.$3),
                      icon: Icon(item.$2, size: 17),
                    ),
                  ),
              ],
            ),
            if (controller.sketchEditingCommandActive &&
                const {
                  SketchToolType.fillet,
                  SketchToolType.chamfer,
                }.contains(controller.activeTool)) ...[
              const SizedBox(height: 7),
              TextFormField(
                key: ValueKey(
                  'sketch-edit-${controller.activeTool.name}-${controller.sketchEditingValue}',
                ),
                initialValue: controller.sketchEditingValue.toString(),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: controller.activeTool == SketchToolType.fillet
                      ? 'Radius'
                      : 'Distance',
                  suffixText: 'mm',
                ),
                onChanged: (text) {
                  final value = double.tryParse(text.replaceAll(',', '.'));
                  if (value != null) controller.setSketchEditingValue(value);
                },
                onFieldSubmitted: (_) async {
                  try {
                    await controller.commitSketchCorner();
                  } catch (_) {}
                },
              ),
              if (controller.activeTool == SketchToolType.fillet)
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Automatic Trim'),
                  value: controller.sketchFilletAutoTrim,
                  onChanged: controller.setSketchFilletAutoTrim,
                ),
              const SizedBox(height: 6),
              FilledButton.icon(
                onPressed: controller.selectedSketchEntityIds.length == 2
                    ? () async {
                        try {
                          await controller.commitSketchCorner();
                        } catch (_) {}
                      }
                    : null,
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Confirm'),
              ),
            ],
            if (controller.sketchEditingCommandActive)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 8, 0),
                child: Text(
                  controller.activeTool == SketchToolType.trim
                      ? 'Click an end to remove its overhang, or click the two sides that must remain.'
                      : controller.activeTool == SketchToolType.extend
                      ? 'Click the line, then its boundary reference.'
                      : 'Select two lines, enter the value, then confirm.',
                  style: const TextStyle(fontSize: 9.5),
                ),
              ),
          ],
        ),
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          leading: const Icon(Icons.link_outlined, size: 17),
          title: const Text('Constraints'),
          subtitle: Text(
            '${controller.selectedSketchEntityIds.length} selected · reference first',
            style: const TextStyle(fontSize: 9.5),
          ),
          children: [
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final item in const [
                  (
                    'Horizontal',
                    Icons.horizontal_rule,
                    SketchConstraintType.horizontal,
                  ),
                  (
                    'Vertical',
                    Icons.vertical_align_center,
                    SketchConstraintType.vertical,
                  ),
                  ('Coincident', Icons.adjust, SketchConstraintType.coincident),
                  (
                    'Parallel',
                    Icons.drag_handle,
                    SketchConstraintType.parallel,
                  ),
                  (
                    'Perpendicular',
                    Icons.call_made,
                    SketchConstraintType.perpendicular,
                  ),
                  (
                    'Concentric',
                    Icons.radio_button_checked,
                    SketchConstraintType.concentric,
                  ),
                ])
                  Tooltip(
                    message: item.$1,
                    child: OutlinedButton(
                      onPressed: () async {
                        try {
                          await controller.applyConstraint(item.$3);
                        } catch (_) {
                          // The controller exposes the actionable diagnostic.
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(42, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: Icon(item.$2, size: 17),
                    ),
                  ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 7, 10, 0),
              child: Text(
                'For pairs: select the trusted reference first, then the geometry to correct.',
                style: TextStyle(fontSize: 9.5),
              ),
            ),
          ],
        ),
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: const Icon(Icons.straighten_outlined, size: 17),
          title: const Text('Dimensions'),
          subtitle: Text(
            '${controller.dimensions.length} driving · select one entity',
            style: const TextStyle(fontSize: 9.5),
          ),
          children: [
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final item in const [
                  ('Linear', SketchDimensionType.linear),
                  ('Angular', SketchDimensionType.angular),
                  ('Radius', SketchDimensionType.radius),
                  ('Diameter', SketchDimensionType.diameter),
                ])
                  OutlinedButton(
                    onPressed:
                        dimensionEntity != null &&
                            ((item.$2 == SketchDimensionType.linear ||
                                    item.$2 == SketchDimensionType.angular)
                                ? dimensionEntity is SketchLine
                                : dimensionEntity is SketchCircle ||
                                      dimensionEntity is SketchArc)
                        ? () => _createDimension(context, item.$2)
                        : null,
                    child: Text(item.$1),
                  ),
              ],
            ),
            for (final dimension in controller.dimensions)
              ListTile(
                dense: true,
                leading: const Icon(Icons.straighten, size: 15),
                title: Text(
                  '${dimension.type.name}  ${dimension.value.toStringAsFixed(3)}',
                  style: const TextStyle(fontSize: 10.5),
                ),
                subtitle: Text(
                  dimension.references.join(' · '),
                  style: const TextStyle(fontSize: 9),
                ),
                onTap: () async {
                  final input = TextEditingController(
                    text: '${dimension.value}',
                  );
                  final value = await showDialog<double>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Edit driving dimension'),
                      content: TextField(
                        controller: input,
                        autofocus: true,
                        onSubmitted: (text) => Navigator.pop(
                          context,
                          double.tryParse(text.replaceAll(',', '.')),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(
                            context,
                            double.tryParse(input.text.replaceAll(',', '.')),
                          ),
                          child: const Text('Apply'),
                        ),
                      ],
                    ),
                  );
                  input.dispose();
                  if (value != null) {
                    await controller.editDrivingDimension(dimension.id, value);
                  }
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Move dimension text',
                      icon: const Icon(Icons.open_with, size: 16),
                      onPressed: () async {
                        final x = TextEditingController(
                          text: '${dimension.labelX}',
                        );
                        final y = TextEditingController(
                          text: '${dimension.labelY}',
                        );
                        final accepted = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Move dimension text'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextField(
                                  controller: x,
                                  decoration: const InputDecoration(
                                    labelText: 'X',
                                  ),
                                ),
                                TextField(
                                  controller: y,
                                  decoration: const InputDecoration(
                                    labelText: 'Y',
                                  ),
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Move'),
                              ),
                            ],
                          ),
                        );
                        final px = double.tryParse(x.text.replaceAll(',', '.'));
                        final py = double.tryParse(y.text.replaceAll(',', '.'));
                        x.dispose();
                        y.dispose();
                        if (accepted == true && px != null && py != null) {
                          await controller.moveDimensionLabel(
                            dimension.id,
                            SketchVector(px, py),
                          );
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'Delete dimension',
                      icon: const Icon(Icons.delete_outline, size: 16),
                      onPressed: () =>
                          controller.deleteDrivingDimension(dimension.id),
                    ),
                  ],
                ),
              ),
          ],
        ),
        ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: const Icon(Icons.layers_outlined, size: 17),
          title: const Text('Planar Surface'),
          subtitle: Text(
            controller.surfacePreviewActive
                ? 'Preview approved · ready to create'
                : health.readyForSurface
                ? 'Profile Ready'
                : 'Sketch Health must be Ready',
            style: const TextStyle(fontSize: 9.5),
          ),
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        health.readyForSurface &&
                            !controller.surfacePreviewActive &&
                            !controller.busy
                        ? controller.previewPlanarSurface
                        : null,
                    icon: const Icon(Icons.visibility_outlined, size: 16),
                    label: const Text('Preview Surface'),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        controller.surfacePreviewActive && !controller.busy
                        ? controller.confirmSurface
                        : null,
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Create Surface'),
                  ),
                ),
              ],
            ),
          ],
        ),
        for (final category in const [('Reference', Icons.layers_outlined)])
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: OutlinedButton.icon(
              onPressed: null,
              icon: Icon(category.$2, size: 17),
              label: Align(
                alignment: Alignment.centerLeft,
                child: Text(category.$1),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: OutlinedButton.icon(
            onPressed: onExitSketch,
            icon: const Icon(Icons.logout_outlined, size: 17),
            label: const Align(
              alignment: Alignment.centerLeft,
              child: Text('Exit Sketch'),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          controller.arcCommandActive
              ? 'Choose three points. Right-click finishes; ESC cancels the pending arc and exits Arc.'
              : controller.circleCommandActive
              ? 'Click the required points. Right-click finishes; ESC cancels only the pending circle.'
              : controller.lineCommandActive
              ? 'Click points to draw. Right-click finishes; ESC cancels the pending segment.'
              : 'Select Line, Circle or Arc to start drawing.',
          style: TextStyle(
            fontSize: 10.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (hud != null) ...[
          const Divider(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              Text('X ${hud.x.toStringAsFixed(3)}'),
              Text('Y ${hud.y.toStringAsFixed(3)}'),
              Text('L ${hud.length.toStringAsFixed(3)}'),
              Text('∠ ${hud.angle.toStringAsFixed(2)}°'),
              if (controller.lineSnapType case final snap?)
                Text(
                  'SNAP ${snap.name.toUpperCase()}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ],
        if (dragHud != null) ...[
          const Divider(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              Text('MOVE X ${dragHud.x.toStringAsFixed(3)}'),
              Text('Y ${dragHud.y.toStringAsFixed(3)}'),
              Text(
                'SNAP ${dragHud.snap.toUpperCase()}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            color: (health.readyForSurface ? Colors.green : Colors.red)
                .withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            child: Text(
              health.readyForSurface
                  ? '🟢 Sketch Ready · Ready for Surface'
                  : '🔴 Sketch contains errors',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: health.readyForSurface ? Colors.green : Colors.redAccent,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _circleModeLabel(SketchCircleMode mode) => switch (mode) {
    SketchCircleMode.centerRadius => 'Center + Radius',
    SketchCircleMode.centerDiameter => 'Center + Diameter',
    SketchCircleMode.twoPoints => 'Two Points',
    SketchCircleMode.threePoints => 'Three Points',
    SketchCircleMode.tangentRadius => 'Tangent + Radius',
    SketchCircleMode.tangentTangentRadius => '2 Tangencies + Radius',
    SketchCircleMode.threeTangencies => 'Three Tangencies',
  };

  static String _arcModeLabel(SketchArcMode mode) => switch (mode) {
    SketchArcMode.center => 'Center + Start + End',
    SketchArcMode.threePoints => 'Three Points',
    SketchArcMode.tangent => 'Tangent — Preparation',
  };
}

class _SketchHealthCheck extends StatelessWidget {
  const _SketchHealthCheck({required this.label, required this.ok});
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    child: Row(
      children: [
        Icon(
          ok ? Icons.check_circle_outline : Icons.cancel_outlined,
          size: 14,
          color: ok ? Colors.green : Colors.redAccent,
        ),
        const SizedBox(width: 6),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 10))),
      ],
    ),
  );
}

class _SketchDirectInput extends StatefulWidget {
  const _SketchDirectInput({required this.controller});
  final OperationalReverseEngineeringController controller;

  @override
  State<_SketchDirectInput> createState() => _SketchDirectInputState();
}

class _SketchDirectInputState extends State<_SketchDirectInput> {
  final primary = TextEditingController();
  final secondary = TextEditingController();
  final tertiary = TextEditingController();
  bool diameter = false;

  @override
  void dispose() {
    primary.dispose();
    secondary.dispose();
    tertiary.dispose();
    super.dispose();
  }

  double? number(TextEditingController value) =>
      double.tryParse(value.text.trim().replaceAll(',', '.'));

  Future<void> submit() async {
    var text = primary.text.trim().toUpperCase();
    final typedDiameter = text.startsWith('D');
    if (typedDiameter) text = text.substring(1).trim();
    final first = double.tryParse(text.replaceAll(',', '.'));
    if (first == null) return;
    final committed = await widget.controller.commitDirectSketchValues(
      primary: first,
      secondary: number(secondary),
      tertiary: number(tertiary),
      diameter: diameter || typedDiameter,
    );
    if (committed && mounted) {
      primary.clear();
      secondary.clear();
      tertiary.clear();
      setState(() => diameter = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.controller.lineCommandActive;
    final circle = widget.controller.circleCommandActive;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: primary,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: line || !circle
                  ? TextInputAction.next
                  : TextInputAction.done,
              onSubmitted: circle ? (_) => submit() : null,
              decoration: InputDecoration(
                isDense: true,
                labelText: line
                    ? 'Length'
                    : circle
                    ? 'Radius / D100'
                    : 'Radius',
              ),
            ),
          ),
          if (line || widget.controller.arcCommandActive) ...[
            const SizedBox(width: 5),
            Expanded(
              child: TextField(
                controller: secondary,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                textInputAction: line
                    ? TextInputAction.done
                    : TextInputAction.next,
                onSubmitted: line ? (_) => submit() : null,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: line ? 'Angle °' : 'Start °',
                ),
              ),
            ),
          ],
          if (widget.controller.arcCommandActive) ...[
            const SizedBox(width: 5),
            Expanded(
              child: TextField(
                controller: tertiary,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => submit(),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'End °',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SketchLineHud extends StatelessWidget {
  const _SketchLineHud({required this.controller});
  final OperationalReverseEngineeringController controller;

  @override
  Widget build(BuildContext context) {
    final value = controller.lineHud!;
    return Material(
      elevation: 3,
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHigh.withValues(alpha: .94),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('X ${value.x.toStringAsFixed(3)}'),
            const SizedBox(width: 12),
            Text('Y ${value.y.toStringAsFixed(3)}'),
            const SizedBox(width: 12),
            Text('L ${value.length.toStringAsFixed(3)}'),
            const SizedBox(width: 12),
            Text('∠ ${value.angle.toStringAsFixed(2)}°'),
            if (controller.lineSnapType case final snap?) ...[
              const SizedBox(width: 12),
              Text(
                snap.name.toUpperCase(),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SketchCircleHud extends StatelessWidget {
  const _SketchCircleHud({required this.controller});
  final OperationalReverseEngineeringController controller;

  @override
  Widget build(BuildContext context) {
    final value = controller.circleHud!;
    return Material(
      elevation: 3,
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHigh.withValues(alpha: .94),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('R ${value.radius.toStringAsFixed(3)}'),
            const SizedBox(width: 12),
            Text('D ${value.diameter.toStringAsFixed(3)}'),
            if (controller.circleSnapType case final snap?) ...[
              const SizedBox(width: 12),
              Text(
                snap.name.toUpperCase(),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SketchArcHud extends StatelessWidget {
  const _SketchArcHud({required this.controller});
  final OperationalReverseEngineeringController controller;

  @override
  Widget build(BuildContext context) {
    final value = controller.arcHud!;
    return Material(
      elevation: 3,
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHigh.withValues(alpha: .94),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('R ${value.radius.toStringAsFixed(3)}'),
            const SizedBox(width: 12),
            Text('A₀ ${value.startDegrees.toStringAsFixed(2)}°'),
            const SizedBox(width: 12),
            Text('A₁ ${value.endDegrees.toStringAsFixed(2)}°'),
            const SizedBox(width: 12),
            Text('L ${value.length.toStringAsFixed(3)}'),
            if (controller.arcSnapType case final snap?) ...[
              const SizedBox(width: 12),
              Text(
                snap.name.toUpperCase(),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfessionalToolWindow extends StatefulWidget {
  const _ProfessionalToolWindow({
    super.key,
    required this.title,
    required this.child,
    this.onClose,
  });
  final String title;
  final Widget child;
  final Future<void> Function()? onClose;

  @override
  State<_ProfessionalToolWindow> createState() =>
      _ProfessionalToolWindowState();
}

class _ProfessionalToolWindowState extends State<_ProfessionalToolWindow> {
  Offset position = const Offset(168, 56);
  late Size windowSize;
  final GlobalKey _contentKey = GlobalKey();
  bool _autoResizeScheduled = false;
  bool docked = false;
  bool visible = true;

  @override
  void initState() {
    super.initState();
    windowSize = widget.title == 'Sketch'
        ? const Size(282, 360)
        : widget.title == 'AI Engineering'
        ? const Size(300, 280)
        : const {'Reference', 'Curves'}.contains(widget.title)
        ? const Size(300, 350)
        : const Size(320, 470);
    _scheduleAutomaticExpansion();
  }

  @override
  void didUpdateWidget(covariant _ProfessionalToolWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleAutomaticExpansion();
  }

  void _scheduleAutomaticExpansion() {
    if (_autoResizeScheduled || docked) return;
    _autoResizeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoResizeScheduled = false;
      if (!mounted || docked) return;
      final box = _contentKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final viewportHeight = MediaQuery.sizeOf(context).height;
      final maximum = math.max(
        240.0,
        math.min(720.0, viewportHeight - position.dy - 20),
      );
      final desired = (box.size.height + 48).clamp(240.0, maximum);
      if (desired > windowSize.height + 1) {
        setState(() {
          windowSize = Size(windowSize.width, desired);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => _buildOverlayWindow(context);

  Widget _buildOverlayWindow(BuildContext context) => !visible
      ? Positioned(
          left: 8,
          top: 8,
          child: ActionChip(
            avatar: const Icon(Icons.build_outlined, size: 14),
            label: Text(widget.title),
            onPressed: () => setState(() => visible = true),
          ),
        )
      : Positioned(
          left: docked ? 0 : position.dx,
          top: docked ? 0 : position.dy,
          bottom: docked ? 0 : null,
          width: windowSize.width,
          height: docked ? null : windowSize.height,
          child: Material(
            elevation: docked ? 0 : 8,
            color: Theme.of(context).colorScheme.surface,
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(docked ? 0 : 3),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: docked
                          ? null
                          : (details) => setState(() {
                              position = Offset(
                                math.max(0, position.dx + details.delta.dx),
                                math.max(0, position.dy + details.delta.dy),
                              );
                            }),
                      child: Container(
                        height: 34,
                        padding: const EdgeInsets.only(left: 10, right: 2),
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHigh,
                        child: Row(
                          children: [
                            const _CadExplorerGlyph(
                              _CadGlyphKind.construction,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                widget.title,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: docked ? 'Float window' : 'Dock window',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => setState(() => docked = !docked),
                              icon: Icon(
                                docked
                                    ? Icons.open_in_new
                                    : Icons.push_pin_outlined,
                                size: 16,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Close',
                              visualDensity: VisualDensity.compact,
                              onPressed: () async {
                                await widget.onClose?.call();
                                if (mounted) setState(() => visible = false);
                              },
                              icon: const Icon(Icons.close, size: 16),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Divider(),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(10),
                        child:
                            NotificationListener<SizeChangedLayoutNotification>(
                              onNotification: (_) {
                                _scheduleAutomaticExpansion();
                                return false;
                              },
                              child: SizeChangedLayoutNotifier(
                                child: KeyedSubtree(
                                  key: _contentKey,
                                  child: widget.child,
                                ),
                              ),
                            ),
                      ),
                    ),
                  ],
                ),
                if (!docked)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) => setState(() {
                        windowSize = Size(
                          (windowSize.width + details.delta.dx).clamp(260, 520),
                          (windowSize.height + details.delta.dy).clamp(
                            240,
                            720,
                          ),
                        );
                      }),
                      child: const SizedBox(
                        width: 18,
                        height: 18,
                        child: CustomPaint(painter: _ResizeGripPainter()),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
}

class _ResizeGripPainter extends CustomPainter {
  const _ResizeGripPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xff71818d)
      ..strokeWidth = 1;
    for (var offset = 4.0; offset <= 12; offset += 4) {
      canvas.drawLine(
        Offset(size.width - offset, size.height),
        Offset(size.width, size.height - offset),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ProfessionalExtrudePanel extends StatefulWidget {
  const _ProfessionalExtrudePanel({required this.controller});
  final OperationalReverseEngineeringController controller;
  @override
  State<_ProfessionalExtrudePanel> createState() =>
      _ProfessionalExtrudePanelState();
}

class _ProfessionalExtrudePanelState extends State<_ProfessionalExtrudePanel> {
  double distance = 10;
  double draftAngleDegrees = 0;
  String directionSourceId = 'profileNormal';
  ProfessionalExtrudeDirection direction = ProfessionalExtrudeDirection.normal;
  ProfessionalExtrudeOutput output = ProfessionalExtrudeOutput.solid;
  bool extrudeCommandActive = false;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final revolvePreview = widget.controller.professionalRevolvePreview;
      if (revolvePreview != null) {
        final contract = ProfessionalRevolveContract.fromJson(
          Map<String, dynamic>.from(revolvePreview['contract'] as Map),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${revolvePreview['id']} · Preview',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text('Profile: ${contract.profileEntityId}'),
            Text('Axis: ${contract.axisEntityId}'),
            TextFormField(
              initialValue: contract.angleDegrees.toString(),
              decoration: const InputDecoration(
                labelText: 'Angle',
                suffixText: '°',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onFieldSubmitted: (value) {
                final parsed = double.tryParse(value.replaceAll(',', '.'));
                if (parsed != null && parsed > 0 && parsed <= 360) {
                  widget.controller.updateProfessionalRevolvePreview(
                    angleDegrees: parsed,
                  );
                }
              },
            ),
            DropdownButtonFormField<RevolveDirection>(
              initialValue: contract.direction,
              decoration: const InputDecoration(labelText: 'Direction'),
              items: RevolveDirection.values
                  .map(
                    (item) => DropdownMenuItem(
                      value: item,
                      child: Text(
                        item == RevolveDirection.clockwise
                            ? 'Clockwise'
                            : 'Counter-clockwise',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: widget.controller.busy
                  ? null
                  : (value) {
                      if (value != null) {
                        widget.controller.updateProfessionalRevolvePreview(
                          direction: value,
                        );
                      }
                    },
            ),
            Text('Output: ${contract.output.name}'),
            const Text(
              'Symmetric · Thin · Up To Surface · Multi Axis: architecture prepared',
              style: TextStyle(fontSize: 11),
            ),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: widget.controller.busy
                        ? null
                        : widget.controller.confirmProfessionalRevolve,
                    child: const Text('Create Revolve'),
                  ),
                ),
                TextButton(
                  onPressed: widget.controller.busy
                      ? null
                      : widget.controller.cancelProfessionalRevolve,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        );
      }
      final preview = widget.controller.professionalExtrudePreview;
      if (preview == null) {
        final selectedFeature = widget.controller.selectedExtrudeFeature;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.view_in_ar),
              title: Text('Professional Solids'),
              subtitle: Text('Extrude · Revolve'),
            ),
            Text(
              selectedFeature != null
                  ? 'Selected: ${selectedFeature.id}'
                  : widget.controller.selectedExtrudeSource == null
                  ? 'Select one Sketch or Surface.'
                  : 'Ready: ${widget.controller.selectedExtrudeSource!.id}',
            ),
            if (selectedFeature != null) ...[
              const SizedBox(height: 8),
              const Text(
                'Use Shaded, Wireframe, Arestas ou Transparência na barra global da área de trabalho.',
                style: TextStyle(fontSize: 10),
              ),
            ],
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: widget.controller.busy
                  ? null
                  : () => setState(() => extrudeCommandActive = true),
              icon: const Icon(Icons.preview),
              label: const Text('Extrude'),
            ),
            if (extrudeCommandActive) ...[
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Extrude active',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<String>(
                        key: ValueKey(
                          'extrude-source-${widget.controller.selectedExtrudeSource?.id ?? 'none'}',
                        ),
                        initialValue:
                            widget.controller.selectedExtrudeSource?.id,
                        decoration: const InputDecoration(
                          labelText: 'Perfil (Sketch ou superfície)',
                          helperText:
                              'Escolha aqui ou clique em uma linha do perfil.',
                          helperMaxLines: 2,
                        ),
                        isExpanded: true,
                        items: widget.controller.extrudeSources
                            .map(
                              (entity) => DropdownMenuItem(
                                value: entity.id,
                                child: Text(
                                  '${entity.data['name'] ?? entity.id} · ${entity.kind.name}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: widget.controller.busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  widget.controller.selectExtrudeSource(value);
                                }
                              },
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.controller.selectedExtrudeSource == null
                            ? 'Select one Sketch or Surface.'
                            : 'Source: ${widget.controller.selectedExtrudeSource!.id}',
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: distance.toString(),
                        decoration: const InputDecoration(
                          labelText: 'Distância',
                          suffixText: 'mm',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (value) {
                          final parsed = double.tryParse(
                            value.replaceAll(',', '.'),
                          );
                          if (parsed != null && parsed > 0) distance = parsed;
                        },
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        initialValue: draftAngleDegrees.toString(),
                        decoration: const InputDecoration(
                          labelText: 'Ângulo de saída (Draft)',
                          suffixText: '°',
                          helperText:
                              'Positivo abre; negativo fecha as paredes laterais.',
                          helperMaxLines: 2,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        onChanged: (value) {
                          final parsed = double.tryParse(
                            value.replaceAll(',', '.'),
                          );
                          if (parsed != null && parsed.abs() < 89) {
                            draftAngleDegrees = parsed;
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: directionSourceId,
                        decoration: const InputDecoration(
                          labelText: 'Eixo ou vetor de extrusão',
                          helperText:
                              'Normal do perfil, eixo global ou vetor criado em Entidades.',
                          helperMaxLines: 2,
                        ),
                        isExpanded: true,
                        items: widget.controller.extrudeDirectionOptions
                            .map(
                              (option) => DropdownMenuItem(
                                value: option.id,
                                child: Text(option.label),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) directionSourceId = value;
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<ProfessionalExtrudeDirection>(
                        initialValue: direction,
                        decoration: const InputDecoration(labelText: 'Direção'),
                        items: ProfessionalExtrudeDirection.values
                            .map(
                              (item) => DropdownMenuItem(
                                value: item,
                                child: Text(
                                  item == ProfessionalExtrudeDirection.normal
                                      ? 'Normal'
                                      : 'Reverse',
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) direction = value;
                        },
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<ProfessionalExtrudeOutput>(
                        initialValue: output,
                        decoration: const InputDecoration(
                          labelText: 'Resultado',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: ProfessionalExtrudeOutput.solid,
                            child: Text('Solid / Cylinder'),
                          ),
                          DropdownMenuItem(
                            value: ProfessionalExtrudeOutput.surface,
                            child: Text('Surface / Walls'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => output = value);
                        },
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed:
                                  widget.controller.busy ||
                                      !widget.controller.canPreviewExtrude
                                  ? null
                                  : () => widget.controller
                                        .previewProfessionalExtrude(
                                          distance: distance,
                                          draftAngleDegrees: draftAngleDegrees,
                                          directionSourceId: directionSourceId,
                                          direction: direction,
                                          output: output,
                                        ),
                              child: const Text('Preview'),
                            ),
                          ),
                          TextButton(
                            onPressed: widget.controller.busy
                                ? null
                                : () => setState(
                                    () => extrudeCommandActive = false,
                                  ),
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 6),
            FilledButton.icon(
              onPressed:
                  widget.controller.busy || !widget.controller.canPreviewRevolve
                  ? null
                  : () => widget.controller.previewProfessionalRevolve(),
              icon: const Icon(Icons.rotate_right),
              label: const Text('Preview Revolve'),
            ),
            const Text(
              'Revolve selection order: Profile first, Axis second.',
              style: TextStyle(fontSize: 11),
            ),
          ],
        );
      }
      final contract = ProfessionalExtrudeContract.fromJson(
        Map<String, dynamic>.from(preview['contract'] as Map),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${preview['id']} · Preview',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: contract.distance.toString(),
            decoration: const InputDecoration(
              labelText: 'Distância',
              suffixText: 'mm',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onFieldSubmitted: (value) {
              final parsed = double.tryParse(value.replaceAll(',', '.'));
              if (parsed != null && parsed > 0) {
                widget.controller.updateProfessionalExtrudePreview(
                  distance: parsed,
                );
              }
            },
          ),
          const SizedBox(height: 14),
          TextFormField(
            key: ValueKey('extrude-draft-${contract.draftAngleDegrees}'),
            initialValue: contract.draftAngleDegrees.toString(),
            decoration: const InputDecoration(
              labelText: 'Ângulo de saída (Draft)',
              suffixText: '°',
              helperText: 'Positivo abre; negativo fecha as paredes laterais.',
              helperMaxLines: 2,
            ),
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            onFieldSubmitted: (value) {
              final parsed = double.tryParse(value.replaceAll(',', '.'));
              if (parsed != null && parsed.abs() < 89) {
                widget.controller.updateProfessionalExtrudePreview(
                  draftAngleDegrees: parsed,
                );
              }
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: contract.directionSourceId,
            decoration: const InputDecoration(
              labelText: 'Eixo ou vetor de extrusão',
            ),
            isExpanded: true,
            items: widget.controller.extrudeDirectionOptions
                .map(
                  (option) => DropdownMenuItem(
                    value: option.id,
                    child: Text(option.label),
                  ),
                )
                .toList(),
            onChanged: widget.controller.busy
                ? null
                : (value) {
                    if (value != null) {
                      widget.controller.updateProfessionalExtrudePreview(
                        directionSourceId: value,
                      );
                    }
                  },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<ProfessionalExtrudeDirection>(
            initialValue: contract.direction,
            decoration: const InputDecoration(labelText: 'Direção'),
            items: ProfessionalExtrudeDirection.values
                .map(
                  (item) => DropdownMenuItem(
                    value: item,
                    child: Text(
                      item == ProfessionalExtrudeDirection.normal
                          ? 'Normal'
                          : 'Reverse',
                    ),
                  ),
                )
                .toList(),
            onChanged: widget.controller.busy
                ? null
                : (value) {
                    if (value != null) {
                      widget.controller.updateProfessionalExtrudePreview(
                        direction: value,
                      );
                    }
                  },
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<ProfessionalExtrudeOutput>(
            initialValue: contract.output,
            decoration: const InputDecoration(labelText: 'Resultado'),
            items: const [
              DropdownMenuItem(
                value: ProfessionalExtrudeOutput.solid,
                child: Text('Solid / Cylinder'),
              ),
              DropdownMenuItem(
                value: ProfessionalExtrudeOutput.surface,
                child: Text('Surface / Walls'),
              ),
            ],
            onChanged: widget.controller.busy
                ? null
                : (value) {
                    if (value != null) {
                      widget.controller.updateProfessionalExtrudePreview(
                        output: value,
                      );
                    }
                  },
          ),
          const Text(
            'Symmetric · Through All · Up To Surface: architecture prepared',
            style: TextStyle(fontSize: 11),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: widget.controller.busy
                      ? null
                      : () async {
                          await widget.controller.confirmProfessionalExtrude();
                          if (mounted) {
                            setState(() => extrudeCommandActive = false);
                          }
                        },
                  child: const Text('Create Extrude'),
                ),
              ),
              TextButton(
                onPressed: widget.controller.busy
                    ? null
                    : () {
                        widget.controller.cancelProfessionalExtrude();
                        setState(() => extrudeCommandActive = false);
                      },
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class _BlendExplorerNode extends StatefulWidget {
  const _BlendExplorerNode({
    required this.child,
    required this.definition,
    required this.onInputTap,
  });
  final Widget child;
  final Map<String, dynamic> definition;
  final ValueChanged<String> onInputTap;
  @override
  State<_BlendExplorerNode> createState() => _BlendExplorerNodeState();
}

class _BlendExplorerNodeState extends State<_BlendExplorerNode> {
  bool expanded = true;
  @override
  Widget build(BuildContext context) {
    final parameters = Map<String, dynamic>.from(
      widget.definition['parameters'] as Map? ?? const {},
    );
    final participants = (parameters['participants'] as List? ?? const [])
        .whereType<Map>()
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: 24,
              height: 30,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => expanded = !expanded),
                icon: Icon(
                  expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                  size: 18,
                ),
              ),
            ),
            Expanded(child: widget.child),
          ],
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Column(
              children: [
                for (var index = 0; index < participants.length; index++)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.layers, size: 15),
                    title: Text(
                      'Surface${(index + 1).toString().padLeft(3, '0')}',
                      style: const TextStyle(fontSize: 10.5),
                    ),
                    subtitle: Text(
                      '${participants[index]['entityId']}',
                      style: const TextStyle(fontSize: 9),
                    ),
                    onTap: participants[index]['entityId'] is String
                        ? () => widget.onInputTap(
                            participants[index]['entityId'] as String,
                          )
                        : null,
                  ),
                for (final participant in participants)
                  if (participant['boundaryEntityId'] is String)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.timeline, size: 15),
                      title: const Text(
                        'Boundary',
                        style: TextStyle(fontSize: 10.5),
                      ),
                      subtitle: Text(
                        '${participant['boundaryEntityId']}',
                        style: const TextStyle(fontSize: 9),
                      ),
                      onTap: () => widget.onInputTap(
                        participant['boundaryEntityId'] as String,
                      ),
                    ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.link, size: 15),
                  title: const Text(
                    'Continuity',
                    style: TextStyle(fontSize: 10.5),
                  ),
                  subtitle: Text(
                    '${widget.definition['continuity'] ?? 'g0'}'.toUpperCase(),
                    style: const TextStyle(fontSize: 9),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SweepExplorerNode extends StatefulWidget {
  const _SweepExplorerNode({
    required this.child,
    required this.definition,
    required this.onInputTap,
  });

  final Widget child;
  final Map<String, dynamic> definition;
  final ValueChanged<String> onInputTap;

  @override
  State<_SweepExplorerNode> createState() => _SweepExplorerNodeState();
}

class _SweepExplorerNodeState extends State<_SweepExplorerNode> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) {
    final parameters = Map<String, dynamic>.from(
      widget.definition['parameters'] as Map? ?? const {},
    );
    final profile = parameters['profile'] as Map?;
    final path = parameters['path'] as Map?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: 24,
              height: 30,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => expanded = !expanded),
                icon: Icon(
                  expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                  size: 18,
                ),
              ),
            ),
            Expanded(child: widget.child),
          ],
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Column(
              children: [
                for (final input in [('Profile', profile), ('Path', path)])
                  ListTile(
                    dense: true,
                    leading: Icon(
                      input.$1 == 'Profile' ? Icons.crop_square : Icons.route,
                      size: 15,
                    ),
                    title: Text(
                      input.$1,
                      style: const TextStyle(fontSize: 10.5),
                    ),
                    subtitle: Text(
                      '${input.$2?['entityId'] ?? 'Unavailable'}',
                      style: const TextStyle(fontSize: 9),
                    ),
                    onTap: input.$2?['entityId'] is String
                        ? () =>
                              widget.onInputTap(input.$2!['entityId'] as String)
                        : null,
                  ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.link, size: 15),
                  title: const Text(
                    'Continuity',
                    style: TextStyle(fontSize: 10.5),
                  ),
                  subtitle: Text(
                    '${widget.definition['continuity'] ?? 'g0'}'.toUpperCase(),
                    style: const TextStyle(fontSize: 9),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _LoftExplorerNode extends StatefulWidget {
  const _LoftExplorerNode({
    required this.child,
    required this.definition,
    required this.qualityData,
    required this.onSectionTap,
  });

  final Widget child;
  final Map<String, dynamic> definition;
  final Map<String, dynamic> qualityData;
  final ValueChanged<String> onSectionTap;

  @override
  State<_LoftExplorerNode> createState() => _LoftExplorerNodeState();
}

class _LoftExplorerNodeState extends State<_LoftExplorerNode> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) {
    final parameters = Map<String, dynamic>.from(
      widget.definition['parameters'] as Map? ?? const {},
    );
    final sources = (parameters['sourceEntityIds'] as List? ?? const [])
        .whereType<String>()
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: 24,
              height: 30,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => expanded = !expanded),
                icon: Icon(
                  expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                  size: 18,
                ),
              ),
            ),
            Expanded(child: widget.child),
          ],
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Column(
              children: [
                for (var index = 0; index < sources.length; index++)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.all_out, size: 15),
                    title: Text(
                      'Section${(index + 1).toString().padLeft(3, '0')}',
                      style: const TextStyle(fontSize: 10.5),
                    ),
                    subtitle: Text(
                      sources[index],
                      style: const TextStyle(fontSize: 9),
                    ),
                    onTap: () => widget.onSectionTap(sources[index]),
                  ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.link, size: 15),
                  title: const Text(
                    'Continuity',
                    style: TextStyle(fontSize: 10.5),
                  ),
                  subtitle: Text(
                    '${widget.definition['continuity'] ?? 'g0'}'.toUpperCase(),
                    style: const TextStyle(fontSize: 9),
                  ),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.analytics_outlined, size: 15),
                  title: const Text(
                    'Analysis',
                    style: TextStyle(fontSize: 10.5),
                  ),
                  subtitle: Text(
                    (widget.qualityData['surfaceAnalyses'] as List? ?? const [])
                        .whereType<Map>()
                        .where((item) => item['enabled'] == true)
                        .map((item) => item['kind'])
                        .join(' · '),
                    style: const TextStyle(fontSize: 9),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SurfaceExplorerNode extends StatefulWidget {
  const _SurfaceExplorerNode({
    required this.child,
    required this.surface,
    required this.qualityData,
    required this.lifecycle,
    required this.onSketchTap,
    required this.onTopologyTap,
  });

  final Widget child;
  final Map<String, dynamic> surface;
  final Map<String, dynamic> qualityData;
  final Map<String, dynamic> lifecycle;
  final ValueChanged<String> onSketchTap;
  final ValueChanged<String> onTopologyTap;

  @override
  State<_SurfaceExplorerNode> createState() => _SurfaceExplorerNodeState();
}

class _SurfaceExplorerNodeState extends State<_SurfaceExplorerNode> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) {
    final parameters = Map<String, dynamic>.from(
      widget.surface['parameters'] as Map? ?? const {},
    );
    final sourceSketchId = parameters['sourceSketchId'] as String?;
    final health = Map<String, dynamic>.from(
      parameters['health'] as Map? ?? const {},
    );
    final history = (widget.lifecycle['history'] as List? ?? const []);
    final topology = Map<String, dynamic>.from(
      parameters['topology'] as Map? ?? const {},
    );
    final loops = (topology['loops'] as List? ?? const []).whereType<Map>();
    final vertices = (topology['vertices'] as List? ?? const [])
        .whereType<Map>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: 24,
              height: 30,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => expanded = !expanded),
                icon: Icon(
                  expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                  size: 18,
                ),
              ),
            ),
            Expanded(child: widget.child),
          ],
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.draw_outlined, size: 15),
                  title: Text(
                    sourceSketchId ?? 'Source Sketch unavailable',
                    style: const TextStyle(fontSize: 10.5),
                  ),
                  onTap: sourceSketchId == null
                      ? null
                      : () => widget.onSketchTap(sourceSketchId),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.link, size: 15),
                  title: const Text(
                    'Continuity',
                    style: TextStyle(fontSize: 10.5),
                  ),
                  subtitle: Text(
                    '${(widget.qualityData['surfaceContinuityRelations'] as List? ?? const []).length} relation(s)',
                    style: const TextStyle(fontSize: 9),
                  ),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.analytics_outlined, size: 15),
                  title: const Text(
                    'Analysis',
                    style: TextStyle(fontSize: 10.5),
                  ),
                  subtitle: Text(
                    (widget.qualityData['surfaceAnalyses'] as List? ?? const [])
                        .whereType<Map>()
                        .where((item) => item['enabled'] == true)
                        .map((item) => item['kind'])
                        .join(' · '),
                    style: const TextStyle(fontSize: 9),
                  ),
                ),
                for (final loop in loops)
                  ExpansionTile(
                    dense: true,
                    tilePadding: EdgeInsets.zero,
                    leading: const Icon(Icons.all_out, size: 15),
                    title: Text(
                      loop['outer'] == true ? 'Outer Loop' : '${loop['id']}',
                      style: const TextStyle(fontSize: 10.5),
                    ),
                    children: [
                      for (final edgeId
                          in (loop['edgeIds'] as List? ?? const [])
                              .whereType<String>())
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.timeline, size: 14),
                          title: Text(
                            edgeId,
                            style: const TextStyle(fontSize: 9.5),
                          ),
                          onTap: () => widget.onTopologyTap(edgeId),
                        ),
                    ],
                  ),
                ExpansionTile(
                  dense: true,
                  tilePadding: EdgeInsets.zero,
                  leading: const Icon(Icons.scatter_plot_outlined, size: 15),
                  title: Text(
                    'Vertices (${vertices.length})',
                    style: const TextStyle(fontSize: 10.5),
                  ),
                  children: [
                    for (final vertex in vertices)
                      ListTile(
                        dense: true,
                        title: Text(
                          '${vertex['id']}',
                          style: const TextStyle(fontSize: 9.5),
                        ),
                        onTap: () => widget.onTopologyTap('${vertex['id']}'),
                      ),
                  ],
                ),
                ExpansionTile(
                  dense: true,
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(left: 16),
                  title: const Text(
                    'Parameters',
                    style: TextStyle(fontSize: 10.5),
                  ),
                  children: [
                    for (final entry in parameters.entries.where(
                      (entry) => !const {
                        'displayNodes',
                        'displayTriangles',
                        'profilePoints',
                        'health',
                      }.contains(entry.key),
                    ))
                      ListTile(
                        dense: true,
                        title: Text(
                          entry.key,
                          style: const TextStyle(fontSize: 9.5),
                        ),
                        subtitle: Text(
                          '${entry.value}',
                          style: const TextStyle(fontSize: 8.5),
                        ),
                      ),
                  ],
                ),
                ExpansionTile(
                  dense: true,
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Health', style: TextStyle(fontSize: 10.5)),
                  children: [
                    ListTile(
                      dense: true,
                      leading: Icon(
                        health['readyForSurface'] == true
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 15,
                      ),
                      title: Text(
                        health['readyForSurface'] == true
                            ? 'Profile Ready'
                            : 'Update blocked',
                        style: const TextStyle(fontSize: 9.5),
                      ),
                    ),
                  ],
                ),
                ExpansionTile(
                  dense: true,
                  tilePadding: EdgeInsets.zero,
                  title: const Text(
                    'History',
                    style: TextStyle(fontSize: 10.5),
                  ),
                  children: [
                    for (final raw in history.whereType<Map>())
                      ListTile(
                        dense: true,
                        title: Text(
                          '${raw['sequence']} · ${raw['action']}',
                          style: const TextStyle(fontSize: 9.5),
                        ),
                        subtitle: Text(
                          '${raw['command']}',
                          style: const TextStyle(fontSize: 8.5),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SketchExplorerNode extends StatefulWidget {
  const _SketchExplorerNode({
    required this.child,
    required this.entities,
    required this.entityBuilder,
    required this.health,
    required this.onHealthIssue,
  });
  final Widget child;
  final List<CadDocumentEntity> entities;
  final Widget Function(CadDocumentEntity) entityBuilder;
  final SketchHealthReport health;
  final ValueChanged<SketchHealthIssue> onHealthIssue;

  @override
  State<_SketchExplorerNode> createState() => _SketchExplorerNodeState();
}

class _SketchExplorerNodeState extends State<_SketchExplorerNode> {
  bool expanded = true;

  String _groupFor(CadDocumentEntity entity) {
    if (entity.data['dimension'] is Map) return 'Dimensions';
    if (entity.kind == CadDocumentEntityKind.constraint) return 'Constraints';
    final sketchEntity = entity.data['sketchEntity'];
    final type = sketchEntity is Map ? sketchEntity['type'] as String? : null;
    return switch (type) {
      'line' => 'Lines',
      'circle' => 'Circles',
      'arc' => 'Arcs',
      _ => 'Geometry',
    };
  }

  List<Widget> _entityGroups() {
    const order = [
      'Lines',
      'Circles',
      'Arcs',
      'Geometry',
      'Constraints',
      'Dimensions',
    ];
    final groups = <String, List<CadDocumentEntity>>{};
    for (final entity in widget.entities) {
      groups.putIfAbsent(_groupFor(entity), () => []).add(entity);
    }
    return [
      for (final name in order)
        if (groups[name]?.isNotEmpty ?? false)
          ExpansionTile(
            dense: true,
            initiallyExpanded: true,
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(left: 16),
            title: Text(name, style: const TextStyle(fontSize: 11)),
            children: groups[name]!
                .map(widget.entityBuilder)
                .toList(growable: false),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          SizedBox(
            width: 24,
            height: 30,
            child: IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: expanded ? 'Collapse Sketch' : 'Expand Sketch',
              onPressed: () => setState(() => expanded = !expanded),
              icon: Icon(
                expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                size: 18,
              ),
            ),
          ),
          Expanded(child: widget.child),
        ],
      ),
      if (expanded)
        Padding(
          padding: const EdgeInsets.only(left: 28),
          child: Column(
            children: [
              ..._entityGroups(),
              ExpansionTile(
                dense: true,
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(left: 16),
                leading: Icon(
                  widget.health.readyForSurface
                      ? Icons.health_and_safety_outlined
                      : Icons.warning_amber_outlined,
                  size: 16,
                  color: widget.health.readyForSurface
                      ? Colors.green
                      : Colors.redAccent,
                ),
                title: const Text('Health', style: TextStyle(fontSize: 11)),
                children: [
                  _healthBranch('Gaps', SketchHealthIssueType.gap),
                  _healthBranch('Duplicates', SketchHealthIssueType.duplicate),
                  _healthBranch('Overlaps', SketchHealthIssueType.overlap),
                  _healthBranch('Warnings', null),
                  ListTile(
                    dense: true,
                    leading: Icon(
                      widget.health.readyForSurface ? Icons.check : Icons.close,
                      size: 14,
                    ),
                    title: Text(
                      widget.health.readyForSurface ? 'Ready' : 'Not Ready',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  );

  Widget _healthBranch(String label, SketchHealthIssueType? type) {
    final issues = widget.health.issues.where((issue) {
      if (type != null) return issue.type == type;
      return {
        SketchHealthIssueType.selfIntersection,
        SketchHealthIssueType.tinyGeometry,
        SketchHealthIssueType.openEnd,
      }.contains(issue.type);
    }).toList();
    return ExpansionTile(
      dense: true,
      tilePadding: EdgeInsets.zero,
      title: Text(
        '$label (${issues.length})',
        style: const TextStyle(fontSize: 10),
      ),
      children: [
        for (final issue in issues)
          ListTile(
            dense: true,
            title: Text(issue.message, style: const TextStyle(fontSize: 9.5)),
            onTap: () => widget.onHealthIssue(issue),
            trailing: const Icon(Icons.zoom_in, size: 14),
          ),
      ],
    );
  }
}

class _MeshExplorerNode extends StatefulWidget {
  const _MeshExplorerNode({
    required this.child,
    required this.regions,
    required this.recognitionResults,
    required this.entityBuilder,
  });
  final Widget child;
  final List<String> regions;
  final List<CadDocumentEntity> recognitionResults;
  final Widget Function(CadDocumentEntity) entityBuilder;

  @override
  State<_MeshExplorerNode> createState() => _MeshExplorerNodeState();
}

class _MeshExplorerNodeState extends State<_MeshExplorerNode> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          SizedBox(
            width: 24,
            height: 30,
            child: IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: expanded ? 'Collapse mesh' : 'Expand mesh',
              onPressed: () => setState(() => expanded = !expanded),
              icon: Icon(
                expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                size: 18,
              ),
            ),
          ),
          Expanded(child: widget.child),
        ],
      ),
      if (expanded)
        Padding(
          padding: const EdgeInsets.only(left: 30),
          child: Column(
            children: [
              _MeshDetailFolder(
                'Regions',
                children: [
                  for (final region in widget.regions)
                    _EngineeringTreeLeaf(region, glyph: _CadGlyphKind.surface),
                ],
              ),
              _MeshDetailFolder(
                'Recognition',
                children: [
                  for (final entry in const [
                    ('Planes', RecognitionResultType.plane),
                    ('Cylinders', RecognitionResultType.cylinder),
                    ('Cones', RecognitionResultType.cone),
                    ('Spheres', RecognitionResultType.sphere),
                    ('Fillets', RecognitionResultType.fillet),
                    ('Freeform', RecognitionResultType.freeform),
                  ])
                    _PrimitiveRecognitionFolder(
                      entry.$1,
                      children: widget.recognitionResults
                          .where((entity) {
                            final raw = entity.data['recognitionResult'];
                            return raw is Map && raw['type'] == entry.$2.name;
                          })
                          .map(widget.entityBuilder)
                          .toList(growable: false),
                    ),
                ],
              ),
              const _MeshDetailFolder('Measurements'),
              const _MeshDetailFolder('Properties'),
            ],
          ),
        ),
    ],
  );
}

class _MeshDetailFolder extends StatelessWidget {
  const _MeshDetailFolder(this.label, {this.children = const []});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    dense: true,
    visualDensity: const VisualDensity(vertical: -4),
    tilePadding: EdgeInsets.zero,
    childrenPadding: EdgeInsets.zero,
    leading: const _CadExplorerGlyph(_CadGlyphKind.construction, size: 15),
    title: _ExplorerLabel(label, fontSize: 11.5),
    children: children,
  );
}

class _PrimitiveRecognitionFolder extends StatelessWidget {
  const _PrimitiveRecognitionFolder(this.label, {this.children = const []});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    dense: true,
    visualDensity: const VisualDensity(vertical: -4),
    tilePadding: const EdgeInsets.only(left: 22, right: 4),
    childrenPadding: const EdgeInsets.only(left: 18),
    leading: const _CadExplorerGlyph(_CadGlyphKind.reference, size: 13),
    title: _ExplorerLabel(label, fontSize: 11),
    subtitle: Text('${children.length}', style: const TextStyle(fontSize: 8.5)),
    children: children,
  );
}

class _EngineeringTreeLeaf extends StatelessWidget {
  const _EngineeringTreeLeaf(this.label, {required this.glyph});
  final String label;
  final _CadGlyphKind glyph;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    visualDensity: const VisualDensity(vertical: -4),
    contentPadding: const EdgeInsets.only(left: 22, right: 4),
    leading: _CadExplorerGlyph(glyph, size: 13),
    title: _ExplorerLabel(label, fontSize: 11),
  );
}

class _ExplorerLabel extends StatelessWidget {
  const _ExplorerLabel(
    this.text, {
    required this.fontSize,
    this.fontWeight = FontWeight.w400,
  });
  final String text;
  final double fontSize;
  final FontWeight fontWeight;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: text,
    waitDuration: const Duration(milliseconds: 450),
    child: Text(
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        height: 1.05,
      ),
    ),
  );
}

class _CadExplorerGlyph extends StatelessWidget {
  const _CadExplorerGlyph(this.kind, {this.size = 18});
  final _CadGlyphKind kind;
  final double size;

  static Color color(_CadGlyphKind kind) => switch (kind) {
    _CadGlyphKind.mesh => const Color(0xff6689a5),
    _CadGlyphKind.reference ||
    _CadGlyphKind.plane ||
    _CadGlyphKind.axis ||
    _CadGlyphKind.point => const Color(0xff5f918b),
    _CadGlyphKind.section => const Color(0xffa66f68),
    _CadGlyphKind.sketch => const Color(0xffa88752),
    _CadGlyphKind.curve => const Color(0xff826f91),
    _CadGlyphKind.surface => const Color(0xffa28e58),
    _CadGlyphKind.solid => const Color(0xff8a969f),
    _CadGlyphKind.inspection => const Color(0xff69866d),
    _CadGlyphKind.construction => const Color(0xff71818d),
    _CadGlyphKind.project => const Color(0xff9b8058),
  };

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _CadGlyphPainter(kind, color(kind)),
  );
}

class _CadGlyphPainter extends CustomPainter {
  const _CadGlyphPainter(this.kind, this.color);
  final _CadGlyphKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 18;
    canvas.save();
    canvas.scale(scale);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.45
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color.withValues(alpha: .22)
      ..style = PaintingStyle.fill;
    switch (kind) {
      case _CadGlyphKind.project:
        canvas.drawPath(
          Path()
            ..moveTo(2, 5)
            ..lineTo(7, 5)
            ..lineTo(8.5, 7)
            ..lineTo(16, 7)
            ..lineTo(15, 15)
            ..lineTo(2, 15)
            ..close(),
          fill,
        );
        canvas.drawPath(
          Path()
            ..moveTo(2, 15)
            ..lineTo(2, 5)
            ..lineTo(7, 5)
            ..lineTo(8.5, 7)
            ..lineTo(16, 7)
            ..lineTo(15, 15)
            ..close(),
          stroke,
        );
      case _CadGlyphKind.mesh || _CadGlyphKind.solid:
        final path = Path()
          ..moveTo(9, 2)
          ..lineTo(15, 5.5)
          ..lineTo(15, 12.5)
          ..lineTo(9, 16)
          ..lineTo(3, 12.5)
          ..lineTo(3, 5.5)
          ..close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
        canvas.drawLine(const Offset(3, 5.5), const Offset(9, 9), stroke);
        canvas.drawLine(const Offset(15, 5.5), const Offset(9, 9), stroke);
        canvas.drawLine(const Offset(9, 9), const Offset(9, 16), stroke);
        if (kind == _CadGlyphKind.mesh) {
          canvas.drawLine(const Offset(9, 2), const Offset(9, 9), stroke);
          canvas.drawLine(
            const Offset(3, 12.5),
            const Offset(15, 12.5),
            stroke,
          );
        }
      case _CadGlyphKind.reference:
        canvas.drawLine(const Offset(3, 14), const Offset(15, 14), stroke);
        canvas.drawLine(const Offset(9, 16), const Offset(9, 3), stroke);
        canvas.drawLine(const Offset(9, 9), const Offset(15, 5), stroke);
        canvas.drawCircle(const Offset(9, 14), 1.5, fill);
      case _CadGlyphKind.plane:
        final plane = Path()
          ..moveTo(2, 11)
          ..lineTo(7, 5)
          ..lineTo(16, 7)
          ..lineTo(11, 13)
          ..close();
        canvas.drawPath(plane, fill);
        canvas.drawPath(plane, stroke);
      case _CadGlyphKind.axis:
        canvas.drawLine(const Offset(2, 14), const Offset(16, 4), stroke);
        canvas.drawLine(const Offset(12, 4), const Offset(16, 4), stroke);
        canvas.drawLine(const Offset(16, 4), const Offset(15, 8), stroke);
      case _CadGlyphKind.point:
        canvas.drawCircle(const Offset(9, 9), 3.2, fill);
        canvas.drawCircle(const Offset(9, 9), 3.2, stroke);
        canvas.drawLine(const Offset(9, 2), const Offset(9, 16), stroke);
        canvas.drawLine(const Offset(2, 9), const Offset(16, 9), stroke);
      case _CadGlyphKind.section:
        canvas.drawLine(const Offset(3, 4), const Offset(15, 14), stroke);
        canvas.drawLine(const Offset(3, 14), const Offset(15, 4), stroke);
        canvas.drawCircle(const Offset(4, 4), 2, stroke);
        canvas.drawCircle(const Offset(4, 14), 2, stroke);
      case _CadGlyphKind.sketch:
        canvas.drawRect(const Rect.fromLTWH(2.5, 2.5, 13, 13), stroke);
        canvas.drawLine(const Offset(5, 13), const Offset(13, 5), stroke);
        canvas.drawCircle(const Offset(5, 13), 1.3, fill);
        canvas.drawCircle(const Offset(13, 5), 1.3, fill);
      case _CadGlyphKind.curve:
        final path = Path()
          ..moveTo(2, 13)
          ..cubicTo(5, 2, 12, 16, 16, 5);
        canvas.drawPath(path, stroke);
        canvas.drawCircle(const Offset(2, 13), 1.3, fill);
        canvas.drawCircle(const Offset(16, 5), 1.3, fill);
      case _CadGlyphKind.surface:
        final patch = Path()
          ..moveTo(2, 12)
          ..quadraticBezierTo(7, 3, 16, 6)
          ..lineTo(15, 13)
          ..quadraticBezierTo(8, 10, 2, 15)
          ..close();
        canvas.drawPath(patch, fill);
        canvas.drawPath(patch, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(5, 11)
            ..quadraticBezierTo(9, 6, 15, 7),
          stroke,
        );
      case _CadGlyphKind.inspection:
        canvas.drawLine(const Offset(3, 15), const Offset(3, 3), stroke);
        canvas.drawLine(const Offset(3, 15), const Offset(16, 15), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(5, 12)
            ..lineTo(8, 8)
            ..lineTo(11, 10)
            ..lineTo(15, 4),
          stroke,
        );
      case _CadGlyphKind.construction:
        canvas.drawCircle(const Offset(9, 9), 5.5, stroke);
        canvas.drawCircle(const Offset(9, 9), 2, fill);
        for (var index = 0; index < 8; index++) {
          final angle = index * math.pi / 4;
          canvas.drawLine(
            Offset(9 + math.cos(angle) * 6, 9 + math.sin(angle) * 6),
            Offset(9 + math.cos(angle) * 8, 9 + math.sin(angle) * 8),
            stroke,
          );
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CadGlyphPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.color != color;
}

class _InspectorSection extends StatelessWidget {
  const _InspectorSection({required this.title, required this.children});
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
          Text(
            title,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const Divider(height: 12),
          ...children,
        ],
      ),
    ),
  );
}

class _InspectorProperty extends StatelessWidget {
  const _InspectorProperty({required this.label, required this.value});
  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Text(
            '$value',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class SketchInspectorNumberProperty extends StatefulWidget {
  const SketchInspectorNumberProperty({
    super.key,
    required this.label,
    required this.value,
    required this.onSubmitted,
    this.suffix,
  });
  final String label;
  final double value;
  final String? suffix;
  final Future<void> Function(double value) onSubmitted;

  @override
  State<SketchInspectorNumberProperty> createState() =>
      _SketchInspectorNumberPropertyState();
}

class _SketchInspectorNumberPropertyState
    extends State<SketchInspectorNumberProperty> {
  late final TextEditingController controller;
  late final FocusNode focusNode;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.value.toStringAsFixed(3));
    focusNode = FocusNode()..addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(SketchInspectorNumberProperty oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      controller.text = widget.value.toStringAsFixed(3);
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );
    }
  }

  @override
  void dispose() {
    focusNode
      ..removeListener(_focusChanged)
      ..dispose();
    controller.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (focusNode.hasFocus) return;
    final parsed = double.tryParse(controller.text.replaceAll(',', '.'));
    if (parsed != null && (parsed - widget.value).abs() > 1e-12) submit();
  }

  Future<void> submit() async {
    final parsed = double.tryParse(controller.text.replaceAll(',', '.'));
    if (parsed != null) await widget.onSubmitted(parsed);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 92,
          child: Text(
            widget.label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Focus(
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.enter ||
                      event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
                submit();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextFormField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                isDense: true,
                suffixText: widget.suffix,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 7,
                ),
              ),
              onFieldSubmitted: (_) => submit(),
            ),
          ),
        ),
      ],
    ),
  );
}

class _DockableSidePanel extends StatefulWidget {
  const _DockableSidePanel({
    required this.panelId,
    required this.title,
    required this.icon,
    required this.width,
    required this.child,
    this.initiallyCollapsed = false,
  });
  final String panelId;
  final String title;
  final IconData icon;
  final double width;
  final Widget child;
  final bool initiallyCollapsed;

  @override
  State<_DockableSidePanel> createState() => _DockableSidePanelState();
}

class _DockableSidePanelState extends State<_DockableSidePanel> {
  late bool collapsed;
  bool closed = false;
  bool pinned = true;
  bool expanded = false;

  @override
  void initState() {
    super.initState();
    collapsed = widget.initiallyCollapsed;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (collapsed || closed) {
      return SizedBox(
        key: ValueKey('collapsed-${widget.panelId}'),
        width: 32,
        child: Material(
          color: colors.surfaceContainerHigh,
          child: Tooltip(
            message: 'Open ${widget.title}',
            child: InkWell(
              onTap: () => setState(() {
                collapsed = false;
                closed = false;
              }),
              child: RotatedBox(
                quarterTurns: 3,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(widget.icon, size: 15),
                    const SizedBox(width: 6),
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      key: ValueKey('open-${widget.panelId}'),
      width: expanded ? widget.width + 90 : widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.only(left: 9),
            color: colors.surfaceContainerHigh,
            child: Row(
              children: [
                Icon(widget.icon, size: 16, color: colors.onSurfaceVariant),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _PanelHeaderButton(
                  tooltip: 'Collapse',
                  icon: Icons.chevron_left,
                  onPressed: () => setState(() => collapsed = true),
                ),
                _PanelHeaderButton(
                  tooltip: expanded ? 'Restore width' : 'Expand',
                  icon: expanded ? Icons.close_fullscreen : Icons.open_in_full,
                  onPressed: () => setState(() => expanded = !expanded),
                ),
                _PanelHeaderButton(
                  tooltip: pinned ? 'Unpin' : 'Pin',
                  icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  onPressed: () => setState(() => pinned = !pinned),
                ),
                _PanelHeaderButton(
                  tooltip: 'Close',
                  icon: Icons.close,
                  onPressed: () => setState(() => closed = true),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(8, 7, 8, 10),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelHeaderButton extends StatelessWidget {
  const _PanelHeaderButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 25, height: 28),
    onPressed: onPressed,
    icon: Icon(icon, size: 14),
  );
}

class DesktopSettingsScreen extends StatefulWidget {
  const DesktopSettingsScreen({
    super.key,
    required this.controller,
    this.colmapLabBuilder,
    this.colmapLabStartupError,
    this.colmapLabInitializing = false,
  });
  final DesktopSettingsController controller;
  final WidgetBuilder? colmapLabBuilder;
  final Object? colmapLabStartupError;
  final bool colmapLabInitializing;
  @override
  State<DesktopSettingsScreen> createState() => _DesktopSettingsScreenState();
}

class _DesktopSettingsScreenState extends State<DesktopSettingsScreen> {
  late final directory = TextEditingController(
    text: widget.controller.settings.defaultDirectory,
  );
  @override
  void dispose() {
    directory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.controller.settings;
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 24),
        DropdownButtonFormField<String>(
          initialValue: value.language,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Language'),
          items: const [
            DropdownMenuItem(value: 'pt-BR', child: Text('Português (Brasil)')),
            DropdownMenuItem(value: 'en-US', child: Text('English')),
          ],
          onChanged: (item) {
            if (item != null) {
              widget.controller.update(value.copyWith(language: item));
            }
          },
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) =>
              SegmentedButton<DesktopThemePreference>(
                direction: constraints.maxWidth < 360
                    ? Axis.vertical
                    : Axis.horizontal,
                segments: const [
                  ButtonSegment(
                    value: DesktopThemePreference.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode),
                  ),
                  ButtonSegment(
                    value: DesktopThemePreference.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode),
                  ),
                ],
                selected: {value.theme},
                onSelectionChanged: (selection) => widget.controller.update(
                  value.copyWith(theme: selection.single),
                ),
              ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: directory,
          decoration: const InputDecoration(
            labelText: 'Default project directory',
          ),
        ),
        const SizedBox(height: 10),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Engineering tips'),
          value: value.engineeringTips,
          onChanged: (enabled) => widget.controller.update(
            value.copyWith(engineeringTips: enabled),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => widget.controller.update(
              value.copyWith(defaultDirectory: directory.text.trim()),
            ),
            icon: const Icon(Icons.save),
            label: const Text('Save settings'),
          ),
        ),
        const SizedBox(height: 32),
        Text(
          'Recursos experimentais',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Card(
          key: const Key('colmap-experimental-settings-card'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Laboratório experimental do COLMAP',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Reconstrução por pasta de fotografias no domínio FLCAD Scan. '
                  'Exige um COLMAP externo autorizado e produz um candidato de '
                  'malha; o resultado não certifica precisão dimensional.',
                ),
                if (widget.colmapLabStartupError != null) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'O laboratório está temporariamente indisponível. '
                    'As demais configurações continuam disponíveis.',
                    key: Key('colmap-lab-unavailable'),
                  ),
                ] else if (widget.colmapLabInitializing) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Inicializando laboratório…',
                    key: Key('colmap-lab-initializing'),
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('open-colmap-lab'),
                  onPressed: widget.colmapLabBuilder == null
                      ? null
                      : () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (context) => Scaffold(
                              appBar: AppBar(
                                title: const Text(
                                  'Laboratório experimental do COLMAP',
                                ),
                              ),
                              body: widget.colmapLabBuilder!(context),
                            ),
                          ),
                        ),
                  child: const Text('Abrir laboratório'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class AboutFLCADDialog extends StatelessWidget {
  const AboutFLCADDialog({super.key});
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        Image.asset(DesktopAssets.logo, width: 48, height: 48),
        const SizedBox(width: 12),
        const Text('FLCAD Reverse AI'),
      ],
    ),
    content: const SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Engineering Intelligence Platform'),
          SizedBox(height: 16),
          _AboutRow('Version', '0.9.1 Alpha'),
          _AboutRow('Company', 'FLCAD MODEL'),
          _AboutRow('GitHub', 'github.com/FLCAD-MODEL'),
          _AboutRow('License', 'Project license'),
          _AboutRow('Geometry Kernel', 'OpenCascade'),
          _AboutRow('UI Framework', 'Flutter'),
          SizedBox(height: 12),
          Text('Copyright © 2026 FLCAD MODEL. All rights reserved.'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

class _AboutRow extends StatelessWidget {
  const _AboutRow(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}
