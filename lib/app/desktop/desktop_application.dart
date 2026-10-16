import 'dart:async';
import 'dart:io';
import 'managed_placement_editor.dart';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/cad_kernel/manager/kernel_manager.dart';
import '../../core/cad_document/cad_document.dart';
import '../../core/cad_document/cad_document_repository.dart';
import '../../core/cad_document/managed_cad_identity.dart';
import '../../core/cad_document/managed_cad_reference.dart';
import '../../core/cad_document/plane_axis_intersection_point.dart';
import '../../core/cad_document/alignment_coordinate_system.dart';
import '../../core/feature_lifecycle/feature_lifecycle.dart';
import '../../core/geometric_kernel/geometry/vectors.dart';
import '../../core/import_export/import_export.dart';
import '../../core/professional_recognition/api/professional_recognition_api.dart';
import '../../core/professional_extrude/professional_extrude.dart';
import '../../core/professional_revolve/professional_revolve.dart';
import '../../core/professional_surface/models/professional_surface_models.dart';
import '../../core/sketch_constraints/models/constraint_models.dart';
import '../../core/sketch_editor/inferencing/sketch_inference_engine.dart';
import '../../core/sketch_assistant/sketch_assistant.dart';
import '../../core/sketch_assistant/sketch_reconstruction.dart';
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
import '../cad_viewport/camera/cad_managed_import_fit.dart';
import '../cad_viewport/native/integrated_native_viewport_widget.dart';
import '../cad_viewport/scene/cad_scene_graph.dart';
import '../cad_viewport/scene/cad_scene_bounds.dart';
import '../cad_viewport/selection/viewport_picking_controller.dart';
import '../commands/desktop_command_coordinator.dart';
import '../commands/command_palette.dart';
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
import '../navigation/navigation_contracts.dart';
import '../operational_entities/operational_entity.dart';
import '../reconstruction/desktop_colmap_lab_runtime.dart';
import '../runtime/cad_runtime.dart';
import 'desktop_asset_manager.dart';
import 'desktop_cad_controller.dart';
import 'desktop_settings.dart';
import 'desktop_theme.dart';
import 'development_calota_autoload.dart';
import 'contextual_reference_actions.dart';
import 'contextual_reference_preview_session.dart';
import 'reference_context_presentation.dart';
import 'reference_contextual_panel.dart';
import 'explorer_tree_projection.dart';
import 'inspector_value_formatter.dart';
import 'layout/display_service.dart';
import 'layout/panel_identity.dart';
import 'layout/panel_layout.dart';
import 'layout/panel_layout_store.dart';
import 'panels/desktop_panel_window_backend.dart';
import 'panels/multi_window_panel_transport.dart';
import 'panels/panel_bridge.dart';
import 'panels/panel_session_source.dart';
import 'panels/panel_window_host.dart';
import 'panels/panel_inspector_widgets.dart';
import 'panels/panel_presentation_models.dart';
import 'plane_axis_intersection_selection.dart';
import 'alignment_coordinate_system_selection.dart';
import 'activity_navigation.dart';
import 'shell_presentation.dart';
import 'reference_tree_taxonomy.dart';
import 'tool_window_layout.dart';
import 'sketch/sketch_continuity_repair_panel.dart';
import 'sketch/sketch_reconstruction_panel.dart';

export 'sketch/sketch_reconstruction_panel.dart'
    show sketchReconstructionSuggestionUiKey;

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
    appBar: AppBar(title: const Text(ShellPresentation.welcome)),
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
                  child: Text(
                    step == 2
                        ? ShellPresentation.finish
                        : ShellPresentation.continueLabel,
                  ),
                ),
                if (details.onStepCancel != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: details.onStepCancel,
                    child: const Text(ShellPresentation.back),
                  ),
                ],
              ],
            ),
          ),
          steps: [
            Step(
              title: const Text(ShellPresentation.language),
              content: DropdownButtonFormField<String>(
                initialValue: language,
                items: const [
                  DropdownMenuItem(
                    value: 'pt-BR',
                    child: Text(ShellPresentation.portugueseBrazil),
                  ),
                  DropdownMenuItem(
                    value: 'en-US',
                    child: Text(ShellPresentation.english),
                  ),
                ],
                onChanged: (value) => setState(() => language = value!),
              ),
            ),
            Step(
              title: const Text(ShellPresentation.theme),
              content: SegmentedButton<DesktopThemePreference>(
                segments: const [
                  ButtonSegment(
                    value: DesktopThemePreference.dark,
                    label: Text(ShellPresentation.dark),
                    icon: Icon(Icons.dark_mode),
                  ),
                  ButtonSegment(
                    value: DesktopThemePreference.light,
                    label: Text(ShellPresentation.light),
                    icon: Icon(Icons.light_mode),
                  ),
                ],
                selected: {theme},
                onSelectionChanged: (value) =>
                    setState(() => theme = value.single),
              ),
            ),
            Step(
              title: const Text(ShellPresentation.defaultDirectory),
              content: TextField(
                controller: directory,
                decoration: const InputDecoration(
                  labelText: ShellPresentation.projectDirectory,
                  hintText: ShellPresentation.chooseProjectDirectory,
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

/// Routes desktop history shortcuts through the same callbacks used by the
/// global Undo/Redo buttons.  The callbacks are intentionally injected so
/// this widget cannot create a second history or bypass the CAD runtime.
class DesktopHistoryShortcuts extends StatefulWidget {
  const DesktopHistoryShortcuts({
    super.key,
    required this.onUndo,
    required this.onRedo,
    this.onSave,
    required this.child,
  });

  final Future<void> Function() onUndo;
  final Future<void> Function() onRedo;
  final Future<void> Function()? onSave;
  final Widget child;

  @override
  State<DesktopHistoryShortcuts> createState() =>
      _DesktopHistoryShortcutsState();
}

class _DesktopHistoryShortcutsState extends State<DesktopHistoryShortcuts> {
  final Set<String> _pending = <String>{};

  static bool _textEditorHasFocus() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null ||
        context.findAncestorWidgetOfExactType<TextField>() != null ||
        context.findAncestorWidgetOfExactType<TextFormField>() != null;
  }

  void _invoke(String key, Future<void> Function() action) {
    if (!_pending.add(key)) return;
    try {
      unawaited(action().whenComplete(() => _pending.remove(key)));
    } catch (_) {
      // Keep a synchronous callback failure from permanently blocking the
      // corresponding shortcut on the next key press.
      _pending.remove(key);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
        if (!_textEditorHasFocus()) _invoke('undo', widget.onUndo);
      },
      SingleActivator(LogicalKeyboardKey.keyY, control: true): () {
        if (!_textEditorHasFocus()) _invoke('redo', widget.onRedo);
      },
      if (widget.onSave != null)
        SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          if (!_textEditorHasFocus()) _invoke('save', widget.onSave!);
        },
    },
    child: Focus(autofocus: true, child: widget.child),
  );
}

class _DesktopShellState extends State<DesktopShell> {
  int destination = 0;
  late final DesktopCadController cad;
  late final DesktopCommandCoordinator commands;
  late final DevelopmentCalotaAutoloadPolicy _autoloadPolicy;
  final DevelopmentCalotaAutoload _autoload = DevelopmentCalotaAutoload();
  final Completer<void> _workspaceViewportReady = Completer<void>();
  bool _devCalotaUsePathForNextImport = false;
  bool _devCalotaIsolationBlocked = false;
  String? _devCalotaIsolationBlockMessage;
  @override
  void initState() {
    super.initState();
    EngineeringBootstrap.instance.initialize();
    // Development Release: both --dart-define=FLCAD_DEV_AUTOLOAD_CALOTA=true
    // and --dart-define=FLCAD_DEV_STL_PATH=... Commercial: defaults, no autoload.
    // Platform.environment fallback is kDebugMode only and never FLUTTER_TEST.
    _autoloadPolicy = DevelopmentCalotaAutoloadPolicy.resolve(
      debugMode: kDebugMode && !const bool.fromEnvironment('FLUTTER_TEST'),
      debugEnvironment:
          kDebugMode && !const bool.fromEnvironment('FLUTTER_TEST')
          ? Platform.environment
          : const <String, String>{},
    );
    if (_autoloadPolicy.enabled) destination = 1;
    cad = DesktopCadController(
      kernels: EngineeringBootstrap.instance.services.get<KernelManager>(),
      projects: ProjectManager.instance,
      managedStlFilePicker: _autoloadPolicy.enabled
          ? _developmentStlFilePicker
          : null,
      managedStlErrorReporter: _autoloadPolicy.enabled
          ? (error, stack) => _logDevAutoload('import.error', {
              'error': '$error',
              'stack': '$stack',
            })
          : null,
    );
    commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    cad.addListener(_refreshShell);
    ProjectManager.instance.addListener(_refreshShell);
    unawaited(
      commands.initialize().then((_) async {
        await _autoloadDevelopmentCalota();
        if (mounted) setState(() {});
      }),
    );
  }

  Future<String?> _developmentStlFilePicker(List<String> extensions) async {
    if (_devCalotaUsePathForNextImport) {
      _devCalotaUsePathForNextImport = false;
      final locator = _autoloadPolicy.path.trim();
      return locator.isEmpty ? null : locator;
    }
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: extensions,
      dialogTitle: 'Importar STL',
    );
    return selected?.path;
  }

  void _logDevAutoload(String event, Map<String, Object?> fields) {
    if (!(kDebugMode || _autoloadPolicy.enabled)) return;
    debugPrint('[dev-autoload] $event $fields');
  }

  Future<void> _autoloadDevelopmentCalota() async {
    _devCalotaIsolationBlocked = false;
    _devCalotaIsolationBlockMessage = null;
    await _autoload.run(
      policy: _autoloadPolicy,
      waitUntilReady: () => _workspaceViewportReady.future,
      fileExists: (path) => File(path).exists(),
      ensureProject: () async {
        final project = ProjectManager.instance.current;
        if (_autoloadPolicy.isolatedSession) {
          if (project != null && await _hasUnsavedCadChanges(project)) {
            const message =
                'Sessão isolada da CALOTA bloqueada: o projeto atual possui alterações não salvas. Salve ou feche o projeto antes de iniciar a sessão de desenvolvimento.';
            _devCalotaIsolationBlocked = true;
            _devCalotaIsolationBlockMessage = message;
            cad.setStatus(message);
            _logDevAutoload('isolated-project-blocked', {
              'projectId': project.id,
              'reason': 'unsaved-document',
            });
            return;
          }
          // Development-only isolation creates a new project instead of
          // clearing or restoring the operator's current project. The prior
          // project remains in ProjectManager and can be reopened normally.
          final previousProjectId = project?.id;
          await commands.createProject(
            'CALOTA - sessao isolada de desenvolvimento',
            'FLCAD',
          );
          _logDevAutoload('isolated-project', {
            'previousProjectId': previousProjectId,
            'projectId': ProjectManager.instance.current?.id,
          });
          return;
        }
        if (project == null) {
          await commands.createProject(
            'CALOTA — validação de desenvolvimento',
            'FLCAD',
          );
        } else {
          if (cad.runtime.document?.projectId != project.id) {
            await cad.restoreProjectGeometry(project.id);
          }
          await commands.refreshContext();
        }
      },
      alreadyContainsCalota: (path) async =>
          _documentContainsDevelopmentCalota(path),
      hasExistingGeometry: () async => _documentHasExistingUserGeometry(),
      importStl: (path) async {
        _devCalotaUsePathForNextImport = true;
        await commands.dispatch('import.stl');
        // Managed import normally starts visible.  Reassert it for the
        // development-only autoload because a restored collection/session may
        // carry an old sceneVisible=false value; do not change commercial
        // imports or create a second import.
        String? importedId;
        for (final id in cad.runtime.selection) {
          final entity = cad.runtime.scene.find(id);
          if (entity?.kind == CadSceneEntityKind.mesh) {
            importedId = id;
            break;
          }
        }
        final importedDocument = importedId == null
            ? null
            : cad.runtime.document?.entities[importedId];
        final importedScene = importedId == null
            ? null
            : cad.runtime.scene.find(importedId);
        if (importedId != null &&
            (importedScene?.visible != true ||
                (importedDocument?.data['sceneVisible'] as bool? ?? true) !=
                    true)) {
          await cad.runtime.setEntityVisibility(importedId, true);
        }
        final publication = cad.runtime.managedImportPublication;
        final visible =
            importedId != null &&
            cad.runtime.scene.find(importedId)?.visible == true;
        final meshPublished =
            publication != null &&
            visible &&
            cad.runtime.scene.find(importedId)?.kind == CadSceneEntityKind.mesh;
        return DevelopmentCalotaImportOutcome(
          entityId: importedId,
          meshPublished: meshPublished,
          visible: visible,
        );
      },
      fitViewAfterMeshPublished: () async {
        // OfficialEngineeringWorkspace schedules Fit after publication and
        // the first valid viewport frame. Do not Fit before the mesh exists.
      },
      reportStatus: cad.setStatus,
      log: _logDevAutoload,
    );
    if (_devCalotaIsolationBlocked && _devCalotaIsolationBlockMessage != null) {
      cad.setStatus(_devCalotaIsolationBlockMessage!);
    }
  }

  Future<bool> _hasUnsavedCadChanges(Project project) async {
    final current = cad.runtime.document;
    if (current == null || current.projectId != project.id) return false;
    try {
      final directory = await cad.projectRepository.directoryFor(project.id);
      final persisted = await const CadDocumentRepository().load(
        project.id,
        directory,
      );
      return !developmentCalotaDocumentMatchesPersisted(
        current: current,
        persisted: persisted,
      );
    } catch (error) {
      _logDevAutoload('isolated-project-guard-error', {
        'projectId': project.id,
        'error': '$error',
      });
      // An unreadable persistence boundary cannot be treated as clean: do not
      // risk replacing the operator's in-memory document.
      return true;
    }
  }

  bool _documentContainsDevelopmentCalota(String locator) {
    final target = File(locator).absolute.path.toLowerCase();
    final document = cad.runtime.document;
    if (document == null) return false;
    bool samePath(Object? value) =>
        value is String && File(value).absolute.path.toLowerCase() == target;
    return document.entities.values.any((entity) {
      if (entity.kind != CadDocumentEntityKind.import ||
          entity.data['format'] != CadImportFormat.stl.name) {
        return false;
      }
      return samePath(entity.data['sourcePath']) ||
          samePath(entity.data['registeredPath']);
    });
  }

  bool _documentHasExistingUserGeometry() {
    final document = cad.runtime.document;
    if (document != null &&
        document.entities.values.any((entity) {
          switch (entity.kind) {
            case CadDocumentEntityKind.import:
            case CadDocumentEntityKind.solid:
            case CadDocumentEntityKind.surface:
            case CadDocumentEntityKind.sketch:
            case CadDocumentEntityKind.curve:
            case CadDocumentEntityKind.face:
            case CadDocumentEntityKind.shell:
            case CadDocumentEntityKind.boundary:
              return true;
            default:
              return false;
          }
        })) {
      return true;
    }
    return cad.runtime.scene.entities.any(
      (entity) => entity.visible && entity.kind == CadSceneEntityKind.mesh,
    );
  }

  @override
  void dispose() {
    ProjectManager.instance.removeListener(_refreshShell);
    cad.removeListener(_refreshShell);
    cad.dispose();
    super.dispose();
  }

  void _refreshShell() {
    if (mounted) setState(() {});
  }

  Future<void> _dispatchStepImport() async {
    if (!cad.canImportManagedStep) {
      if (ProjectManager.instance.current == null) {
        cad.setStatus('Abra ou crie um projeto antes de importar STEP.');
      }
      return;
    }
    await commands.refreshContext();
    await commands.dispatch('import.step');
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      DesktopHomeDashboard(
        onWorkspace: () => setState(() => destination = 1),
        controller: widget.controller,
        commands: commands,
      ),
      OfficialEngineeringWorkspace(
        cad: cad,
        commands: commands,
        onViewportReady: () {
          if (!_workspaceViewportReady.isCompleted) {
            _workspaceViewportReady.complete();
          }
        },
      ),
      DesktopSettingsScreen(
        controller: widget.controller,
        colmapLabBuilder: widget.colmapLabBuilder,
        colmapLabStartupError: widget.colmapLabStartupError,
        colmapLabInitializing: widget.colmapLabInitializing,
      ),
    ];
    final shellProject = commands.projects.current?.name ?? 'Sem projeto';
    final shellDestination = switch (destination) {
      0 => 'Início',
      1 => 'Workspace',
      _ => 'Configurações',
    };
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 10,
        title: Row(
          children: [
            Image.asset(DesktopAssets.logo, width: 28, height: 28),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'FLCAD Reverse AI',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    shellProject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                shellDestination,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: ShellPresentation.searchTools,
            onPressed: () => _openCommandPalette(context),
            icon: const Icon(Icons.search),
          ),
          PopupMenuButton<String>(
            tooltip: 'Arquivo',
            onSelected: (value) async {
              final parts = value.split(':');
              await commands.dispatch('${parts.first}.${parts.last}');
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'project:save',
                child: Text(ShellPresentation.saveProject),
              ),
              PopupMenuItem(
                value: 'project:close',
                child: Text(ShellPresentation.closeProject),
              ),
              PopupMenuDivider(),
              PopupMenuItem(enabled: false, child: Text('Importar')),
              PopupMenuItem(value: 'import:stl', child: Text('STL')),
              if (cad.supportsManagedStep)
                PopupMenuItem(
                  value: 'import:step',
                  enabled: cad.canImportManagedStep,
                  child: Text(
                    cad.canImportManagedStep
                        ? 'Importar STEP'
                        : 'Importar STEP (abra ou crie um projeto)',
                  ),
                ),
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
          if (cad.supportsManagedStep)
            IconButton(
              tooltip: cad.canImportManagedStep
                  ? 'Importar STEP'
                  : 'Importar STEP: abra ou crie um projeto',
              onPressed: cad.canImportManagedStep ? _dispatchStepImport : null,
              icon: const Icon(Icons.view_in_ar),
            ),
          IconButton(
            tooltip: 'Desfazer',
            onPressed: commands.undo,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Refazer',
            onPressed: commands.redo,
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            tooltip: 'Sobre',
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
            minWidth: 56,
            minExtendedWidth: 76,
            labelType: NavigationRailLabelType.selected,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: Text('Início'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.view_quilt_outlined),
                selectedIcon: Icon(Icons.view_quilt),
                label: Text(ShellPresentation.workspace),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('Configurações'),
              ),
            ],
          ),
          const VerticalDivider(),
          Expanded(
            child: DesktopHistoryShortcuts(
              onUndo: commands.undo,
              onRedo: commands.redo,
              onSave: () => commands.dispatch('project.save'),
              child: screens[destination],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openCommandPalette(BuildContext context) async {
    await showSearch<void>(
      context: context,
      delegate: DesktopCommandPaletteDelegate(
        isRegistered: commands.registry.contains,
        canExecute: CommandPalettePolicy.canExecute,
        execute: commands.dispatch,
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
        title: const Text(ShellPresentation.openProject),
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
              child: Text(ShellPresentation.noProjects),
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
              ShellPresentation.dashboard,
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
                  label: ShellPresentation.newProject,
                  onTap: () => _newProject(context),
                ),
                _DashboardAction(
                  icon: Icons.folder_open,
                  label: ShellPresentation.openProject,
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
                if (commands.cad.supportsManagedStep)
                  _DashboardAction(
                    icon: Icons.view_in_ar,
                    label: 'Importar STEP',
                    onTap: () async {
                      if (!commands.cad.canImportManagedStep) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Abra ou crie um projeto antes de importar STEP.',
                            ),
                          ),
                        );
                        return;
                      }
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
                      content: Text(ShellPresentation.settingsHint),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            Text(
              ShellPresentation.recentProjects,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            if (commands.projects.visibleProjects.isEmpty)
              const _EmptyState(
                icon: Icons.history,
                message: ShellPresentation.noRecentProjects,
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
                  title: const Text(ShellPresentation.engineeringTip),
                  subtitle: const Text(
                    'Validate the project coordinate system before reconstruction.',
                  ),
                  trailing: IconButton(
                    tooltip: ShellPresentation.disableTips,
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
              label: Text(ShellPresentation.openEngineeringWorkspace),
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
            Text(
              ShellPresentation.newProject,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: name,
              autofocus: true,
              onSubmitted: (_) => _create(),
              decoration: const InputDecoration(
                labelText: ShellPresentation.projectName,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: client,
              onSubmitted: (_) => _create(),
              decoration: const InputDecoration(
                labelText: ShellPresentation.client,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: busy ? null : widget.onCancel,
                  child: const Text(ShellPresentation.cancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : _create,
                  child: busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(ShellPresentation.create),
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
    this.onViewportReady,
  });
  final DesktopCadController cad;
  final DesktopCommandCoordinator commands;
  final VoidCallback? onViewportReady;
  @override
  State<OfficialEngineeringWorkspace> createState() =>
      _OfficialEngineeringWorkspaceState();
}

class _OfficialEngineeringWorkspaceState
    extends State<OfficialEngineeringWorkspace>
    with WindowListener {
  String module = 'AI Engineering';
  ProfessionalSurfaceTool? toolbarSurfaceTool;
  int toolbarEntityConstructor = 0;
  PrimitiveSurfaceType? toolbarPrimitiveType;
  final Set<String> openToolWindows = <String>{};
  // G124-UX.MM4.1 - janela Explorer destacável (spike, somente Explorer).
  MultiWindowPanelTransport? _panelTransport;
  PanelBridge? _panelBridge;
  PanelWindowHost? _panelWindowHost;
  bool _explorerDetached = false;
  String? _explorerPanelError;
  bool _inspectorDetached = false;
  String? _inspectorPanelError;
  bool _shellCloseGuardArmed = false;
  bool _closingShell = false;
  bool _explorerRestoreEvaluated = false;
  bool _inspectorRestoreEvaluated = false;
  Timer? _panelReconcileTimer;
  final modelingViewport = ModelingViewportController();
  CadSceneGraph get scene => widget.cad.runtime.scene;
  final camera = CadCameraController();
  final managedFaceSelection = CadManagedFaceSelectionController();
  final intersectionSelection = PlaneAxisIntersectionSelectionController();
  final alignmentCoordinateSystemSelection =
      AlignmentCoordinateSystemSelectionController();
  late final ContextualReferencePreviewSession contextualReferencePreview;
  late final NavigationEngine navigation;
  GeometrySelectionManager get geometrySelection =>
      widget.cad.runtime.geometrySelection;
  late final OperationalReverseEngineeringController operational;
  String? fittedDocumentId;
  int? fittedDocumentSession;
  final _managedImportFitGate = CadManagedImportFitGate();
  final _projectOpenFitGate = CadProjectOpenFitGate();
  int _handledManagedImportPublication = 0;
  VoidCallback? _pendingManagedImportFit;
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
  final ScrollController _sketchSuggestionScrollController = ScrollController();
  final ValueNotifier<({Offset position, String label})?>
  _sketchSuggestionHoverPresentation = ValueNotifier(null);
  Offset? _sketchSuggestionHoverPosition;

  /// True only when the operator explicitly asked for a new Sketch. A plain
  /// return to the Sketch module reuses the root already bound to the support.
  bool forceNewSketchOnSupportPick = false;
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
        InspectorModeSelector(
          advanced: advancedInspector,
          onChanged: (value) => setState(() => advancedInspector = value),
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
    final rawReference = entity.data['reference'];
    final referenceRecipe = rawReference is Map ? rawReference['recipe'] : null;
    final referenceParameters = referenceRecipe is Map
        ? referenceRecipe['parameters']
        : null;
    final referenceTolerance = referenceParameters is Map
        ? referenceParameters['tolerance']
        : null;
    final referenceDna = rawReference is Map ? rawReference['dna'] : null;
    final referenceConfidence = referenceDna is Map
        ? referenceDna['confidence']
        : null;
    final bounds = mesh?.bounds;
    final managedIdentity = ManagedCadIdentity.fromDocumentData(entity.data);
    final sceneGeometry = entity.data['sceneGeometry'];
    final sceneCoordinate = sceneGeometry is Map
        ? (entity.data['sceneKind'] == CadSceneEntityKind.point.name
              ? sceneGeometry['position']
              : sceneGeometry['origin'])
        : null;
    final inspectorCoordinate =
        sceneCoordinate is List &&
            sceneCoordinate.length == 3 &&
            sceneCoordinate.every((value) => value is num && value.isFinite)
        ? InspectorValueFormatter.coordinateMm(sceneCoordinate.cast<num>())
        : null;
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
        InspectorModeSelector(
          advanced: advancedInspector,
          onChanged: (value) => setState(() => advancedInspector = value),
        ),
        const SizedBox(height: 10),
        _SharedInspectorReadOnlySection(
          title: 'Identity',
          children: [
            _InspectorProperty(label: 'Name', value: shortName),
            _InspectorProperty(
              label: 'Type',
              value: managedIdentity?.visualTypeLabel ?? entity.kind.name,
            ),
            if (managedIdentity?.technicalName case final technicalName?)
              _InspectorProperty(
                label: 'Nome técnico STEP',
                value: technicalName,
              ),
            _InspectorProperty(
              label: 'Visibility',
              value: (entity.data['sceneVisible'] as bool? ?? true)
                  ? 'Visible'
                  : 'Hidden',
            ),
          ],
        ),
        if (ReferenceTreeTaxonomy.isProjectedReference(entity)) ...[
          const SizedBox(height: 8),
          _SharedInspectorReadOnlySection(
            title: 'Reference Origin',
            children: [
              _InspectorProperty(
                label: 'Origin',
                value: ReferenceTreeTaxonomy.originLabel(entity),
              ),
              if (referenceTolerance is num)
                _InspectorProperty(
                  label: 'Tolerance',
                  value: referenceTolerance,
                ),
              if (referenceConfidence is num)
                _InspectorProperty(
                  label: 'Confidence',
                  value: '${(referenceConfidence * 100).toStringAsFixed(1)}%',
                ),
              if (inspectorCoordinate != null &&
                  entity.data[PlaneAxisIntersectionPoint.dataKey] == null)
                _InspectorProperty(
                  label: entity.data['sceneKind'] == 'point'
                      ? 'Coordenada'
                      : 'Origem',
                  value: inspectorCoordinate,
                ),
            ],
          ),
        ],
        if (entity.data[ManagedCadReference.dataKey] case final Map raw) ...[
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final reference = ManagedCadReference.fromJson(
                Map<String, dynamic>.from(raw),
              );
              return _SharedInspectorReadOnlySection(
                title: 'Managed CAD Reference',
                children: [
                  _InspectorProperty(
                    label: 'Type',
                    value: switch (reference.kind) {
                      ManagedCadReferenceKind.plane => 'Plano por face',
                      ManagedCadReferenceKind.cylindricalAxis =>
                        'Eixo por face cilíndrica',
                    },
                  ),
                  _InspectorProperty(
                    label: 'Source Entity',
                    value: reference.sourceEntityId,
                  ),
                  _InspectorProperty(
                    label: 'Source Format',
                    value: reference.sourceFormat.toUpperCase(),
                  ),
                  _InspectorProperty(
                    label: 'Source Face',
                    value: reference.faceIndex,
                  ),
                  _InspectorProperty(
                    label: 'Origin',
                    value: InspectorValueFormatter.coordinateMm(
                      reference.origin.toJson(),
                    ),
                  ),
                  if (reference.kind == ManagedCadReferenceKind.plane) ...[
                    _InspectorProperty(
                      label: 'Normal',
                      value: reference.normal!.toJson(),
                    ),
                    _InspectorProperty(
                      label: 'X Direction',
                      value: reference.xDirection!.toJson(),
                    ),
                  ] else ...[
                    _InspectorProperty(
                      label: 'Direction',
                      value: reference.direction!.toJson(),
                    ),
                    _InspectorProperty(
                      label: 'Radius',
                      value: reference.radius,
                    ),
                  ],
                  _InspectorProperty(
                    label: 'Status',
                    value:
                        widget.cad.runtime.managedCadReferenceIsOrphaned(
                          reference,
                        )
                        ? 'Órfã / origem indisponível'
                        : 'Válida',
                  ),
                ],
              );
            },
          ),
        ],
        if (entity.data[PlaneAxisIntersectionPoint.dataKey]
            case final Map raw) ...[
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final reference = PlaneAxisIntersectionPoint.fromJson(
                Map<String, dynamic>.from(raw),
              );
              String parentName(ReferenceParentIdentity parent) =>
                  widget
                          .cad
                          .runtime
                          .document
                          ?.entities[parent.entityId]
                          ?.data['name']
                      as String? ??
                  parent.entityId;
              return _InspectorSection(
                title: 'Ponto por interseção Plano + Eixo',
                children: [
                  _InspectorProperty(
                    label: 'Plano pai',
                    value: parentName(reference.plane),
                  ),
                  _InspectorProperty(
                    label: 'Eixo pai',
                    value: parentName(reference.axis),
                  ),
                  _InspectorProperty(
                    label: 'Coordenada mundial',
                    value: InspectorValueFormatter.coordinateMm(
                      reference.point.toJson(),
                    ),
                  ),
                  _InspectorProperty(
                    label: 'Estado',
                    value:
                        widget.cad.runtime.planeAxisIntersectionPointIsOrphaned(
                          reference,
                        )
                        ? 'Órfã / pai indisponível ou alterado'
                        : 'Válida — snapshot',
                  ),
                ],
              );
            },
          ),
        ],
        if (entity.data[AlignmentCoordinateSystem.dataKey]
            case final Map raw) ...[
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final reference = AlignmentCoordinateSystem.fromJson(
                Map<String, dynamic>.from(raw),
              );
              String parentName(ReferenceParentIdentity parent) =>
                  widget
                          .cad
                          .runtime
                          .document
                          ?.entities[parent.entityId]
                          ?.data['name']
                      as String? ??
                  parent.entityId;
              return _InspectorSection(
                title: 'Sistema de Coordenadas de Alinhamento',
                children: [
                  _InspectorProperty(
                    label: 'Plano pai',
                    value: parentName(reference.plane),
                  ),
                  _InspectorProperty(
                    label: 'Eixo/Vetor pai',
                    value: parentName(reference.axis),
                  ),
                  _InspectorProperty(
                    label: switch (reference.originKind) {
                      AlignmentCoordinateSystemOriginKind.referencePoint =>
                        'Ponto de origem',
                      AlignmentCoordinateSystemOriginKind.manual =>
                        'Origem manual',
                      AlignmentCoordinateSystemOriginKind.viewport =>
                        'Origem capturada na viewport',
                    },
                    value: reference.point == null
                        ? InspectorValueFormatter.coordinateMm(
                            reference.origin.toJson(),
                          )
                        : parentName(reference.point!),
                  ),
                  _InspectorProperty(
                    label: 'X',
                    value: InspectorValueFormatter.unitDirection(
                      reference.xAxis.toJson(),
                    ),
                  ),
                  _InspectorProperty(
                    label: 'Y',
                    value: InspectorValueFormatter.unitDirection(
                      reference.yAxis.toJson(),
                    ),
                  ),
                  _InspectorProperty(
                    label: 'Z',
                    value: InspectorValueFormatter.unitDirection(
                      reference.zAxis.toJson(),
                    ),
                  ),
                  _InspectorProperty(
                    label: 'Estado',
                    value:
                        widget.cad.runtime.alignmentCoordinateSystemIsOrphaned(
                          reference,
                        )
                        ? 'Órfã / pai indisponível ou alterado'
                        : 'Válida — snapshot',
                  ),
                ],
              );
            },
          ),
        ],
        if (entity.data['alignmentByCoordinateSystem'] case final Map raw) ...[
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final translation = (raw['translation'] as List?)
                  ?.whereType<num>()
                  .toList(growable: false);
              final systemId = raw['coordinateSystemId'] as String?;
              final systemName = systemId == null
                  ? null
                  : widget
                        .cad
                        .runtime
                        .document
                        ?.entities[systemId]
                        ?.data['name'];
              return _InspectorSection(
                title: 'Alinhamento por Sistema de Coordenadas',
                children: [
                  _InspectorProperty(
                    label: 'Sistema de destino',
                    value: systemName ?? systemId ?? 'Indisponível',
                  ),
                  _InspectorProperty(
                    label: 'Modo',
                    value: raw['mode'] == 'workingCopy'
                        ? 'Working Copy'
                        : 'Original',
                  ),
                  if (translation != null && translation.length == 3)
                    _InspectorProperty(
                      label: 'Translação',
                      value: InspectorValueFormatter.coordinateMm(translation),
                    ),
                  _InspectorProperty(
                    label: 'Rotação',
                    value: 'Base rígida X/Y/Z (sem escala)',
                  ),
                ],
              );
            },
          ),
        ],
        if (entity.data['sketch'] case final Map raw) ...[
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final sketch = Sketch.fromJson(Map<String, dynamic>.from(raw));
              return _SharedInspectorReadOnlySection(
                title: 'Sketch Support',
                children: [
                  _InspectorProperty(
                    label: 'Plane',
                    value:
                        sketch.metadata['supportEntityId'] ??
                        sketch.plane.parameters['referenceId'] ??
                        sketch.plane.type.name,
                  ),
                  _InspectorProperty(
                    label: 'Origin',
                    value: InspectorValueFormatter.coordinateMm(
                      sketch.coordinates.origin.toJson(),
                    ),
                  ),
                  _InspectorProperty(
                    label: 'Normal',
                    value: sketch.coordinates.normal.toJson(),
                  ),
                  _InspectorProperty(
                    label: 'X Axis',
                    value: sketch.coordinates.xAxis.toJson(),
                  ),
                  _InspectorProperty(
                    label: 'Y Axis',
                    value: sketch.coordinates.yAxis.toJson(),
                  ),
                ],
              );
            },
          ),
        ],
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
          if ((raw['metadata'] as Map?)?['reconstructionKind'] is String) ...[
            const SizedBox(height: 8),
            _InspectorSection(
              title: 'Reconstrução Mesh Sketch',
              children: [
                _InspectorProperty(
                  label: 'Classificação',
                  value: (raw['metadata'] as Map)['reconstructionKind'],
                ),
                const _InspectorProperty(
                  label: 'Origem',
                  value: 'Sugestão aceita pelo Sketch Assistant',
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
        if (entity.data['constraint'] case final Map raw) ...[
          const SizedBox(height: 8),
          _InspectorSection(
            title: 'Constraint',
            children: [
              _InspectorProperty(label: 'Type', value: raw['type']),
              _InspectorProperty(
                label: 'Entities',
                value: (raw['references'] as List? ?? const []).join(' → '),
              ),
              _InspectorProperty(label: 'State', value: raw['status']),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => operational.setConstraintVisibility(
                        entity.id,
                        !(raw['visible'] as bool? ?? true),
                      ),
                      icon: const Icon(Icons.visibility_off_outlined, size: 16),
                      label: const Text('Ocultar'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => operational.deleteConstraint(entity.id),
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Excluir'),
                    ),
                  ),
                ],
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
    contextualReferencePreview = ContextualReferencePreviewSession(
      widget.cad.runtime,
    );
    navigation = NavigationEngine(
      profile: NavigationProfile.flcadReverseEngineering,
      camera: CadCameraNavigationAdapter(camera),
      resolvePoint: (_, _) => null,
    );
    operational = OperationalReverseEngineeringController(
      recognition: EngineeringBootstrap.instance.services
          .get<ProfessionalRecognitionApi>(),
      commands: widget.commands,
      runtime: widget.cad.runtime,
    );
    operational.addListener(_onOperationalChanged);
    widget.cad.addListener(_synchronizeScene);
    widget.cad.runtime.addListener(_synchronizeScene);
    alignmentCoordinateSystemSelection.addListener(
      _alignmentCaptureStateChanged,
    );
    _synchronizeScene();
    // G124-UX.MM4.2: the operator may have left the Explorer in its own window.
    unawaited(_restoreDetachedPanelOnce(PanelId.explorer));
    unawaited(_restoreDetachedPanelOnce(PanelId.inspector));
  }

  void _alignmentCaptureStateChanged() {
    if (mounted) setState(() {});
  }

  void _onOperationalChanged() {
    if (operational.hoveredSketchReconstructionSuggestion == null ||
        operational.sketchCreationCommandActive ||
        operational.sketchEditingCommandActive ||
        choosingSketchSupport) {
      _sketchSuggestionHoverPosition = null;
      _sketchSuggestionHoverPresentation.value = null;
    }
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------- painéis
  // G124-UX.MM4.1: o Explorer pode rodar na sua própria janela Windows. O main
  // continua sendo a única fonte de verdade: a janela recebe a projeção do MM3
  // e devolve intents validados (seleção), nunca tocando o CAD.

  Future<void> _ensurePanelInfrastructure({
    PanelLayoutStoreBase? layoutStore,
  }) async {
    if (_panelWindowHost != null) return;
    final backend = DesktopPanelWindowBackend();
    final transport = MultiWindowPanelTransport(
      backend: backend,
      isMainWindow: true,
      panelWindowIdResolver: (panelId) {
        final id = panelIdFromName(panelId);
        return id == null
            ? null
            : _panelWindowHost?.attachmentFor(id)?.windowId;
      },
    );
    final host = PanelWindowHost(
      backend: backend,
      layoutStore:
          layoutStore ??
          PanelLayoutStore.forConfigDirectory(
            await getApplicationSupportDirectory(),
          ),
      displays: createPlatformDisplayService(),
      devicePixelRatio: () => MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    final bridge = PanelBridge(
      transport: transport,
      source: CadRuntimePanelSessionSource(
        widget.cad.runtime,
        editDrivingDimensionCallback: (entityId, value) =>
            widget.commands.dispatch('reverse.sketch.dimension.edit', {
              'id': entityId,
              'value': value,
            }),
      ),
    )..start();
    transport.onMainWindowControl = (method, arguments) {
      if (method != 'panel_dock') return;
      final panelId = panelIdFromName(arguments['panelId'] as String? ?? '');
      if (panelId != null) unawaited(_dockPanel(panelId));
    };
    _panelTransport = transport;
    _panelBridge = bridge;
    _panelWindowHost = host;
    // Resolve the shell HWND once. `preventClose`, `close` and `getBounds` all
    // target `native_window`, which stays null until this call: without it the
    // close request would be posted to a null window and the shell would never
    // leave.
    try {
      await windowManager.ensureInitialized();
    } on Object catch (error) {
      debugPrint('[panel-window] window control unavailable: $error');
    }
    // The shell has to know when the operator closes it: see
    // [_closeShellWithPanels].
    windowManager.addListener(this);
    _panelReconcileTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_reconcilePanelWindows()),
    );
  }

  /// G124-UX.MM4.2: materialises the panel the operator left detached.
  ///
  /// Lifecycle: it runs once per Workspace session, after the first frame (the
  /// shell is laid out and the device pixel ratio is known), and it only builds
  /// the panel infrastructure when the *recovered* preference still keeps the
  /// Explorer detached. The channels are registered before the window exists,
  /// so the panel's handshake always finds the main side listening.
  ///
  /// The stored preference is authoritative: an explicit Dock writes the panel
  /// as docked and is therefore never reopened, while a session teardown keeps
  /// the preference (see [PanelWindowHost.dock]).
  Future<void> _restoreDetachedPanelOnce(PanelId panelId) async {
    final evaluated = panelId == PanelId.explorer
        ? _explorerRestoreEvaluated
        : _inspectorRestoreEvaluated;
    if (evaluated) return;
    if (panelId == PanelId.explorer) {
      _explorerRestoreEvaluated = true;
    } else {
      _inspectorRestoreEvaluated = true;
    }
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final store = PanelLayoutStore.forConfigDirectory(
        await getApplicationSupportDirectory(),
      );
      final detached = await PanelWindowHost.hasDetachedPreference(
        store,
        panelId: panelId,
        displays: createPlatformDisplayService(),
      );
      if (!detached) return;
      await _ensurePanelInfrastructure(layoutStore: store);
      final host = _panelWindowHost;
      if (host == null) return;
      // The bridge registers its channels asynchronously: wait for them before
      // the window starts handshaking.
      await _panelTransport?.ready;
      final adopt = await _livePanelWindow(panelId);
      final attachment = await host.restorePersisted(panelId, windowId: adopt);
      if (attachment == null) return;
      await _setShellCloseGuard(host.hasAttachments);
      if (!mounted) return;
      setState(() {
        if (panelId == PanelId.explorer) {
          _explorerDetached = true;
        } else {
          _inspectorDetached = true;
        }
      });
      widget.cad.setStatus(
        adopt == null
            ? '${panelDescriptor(panelId).title} restaurado na janela destacada.'
            : 'Janela do ${panelDescriptor(panelId).title} reconectada.',
      );
    } on Object catch (error) {
      debugPrint('[panel-window] restore failed: $error');
      if (!mounted) return;
      setState(
        () => panelId == PanelId.explorer
            ? _explorerPanelError = 'Falha ao restaurar o Explorer: $error'
            : _inspectorPanelError = 'Falha ao restaurar o Inspector: $error',
      );
    }
  }

  /// A window the Explorer already owns, if one is still open.
  ///
  /// Adopting it is what keeps a Workspace remount from opening a second window
  /// while the previous session is still tearing its own down.
  Future<String?> _livePanelWindow(PanelId panelId) async {
    final backend = _panelTransport?.backend;
    if (backend == null) return null;
    for (final window in await backend.listWindows()) {
      if (window.panelId == panelId) return window.windowId;
    }
    return null;
  }

  Future<PanelGeometry> _requestedPanelGeometry(PanelId panelId) async {
    final saved = (await _panelWindowHost!.prepareLayout())
        .entryFor(panelId)
        .geometry;
    if (saved != null) return saved;
    final size = panelDescriptor(panelId).defaultSize;
    try {
      final bounds = await windowManager.getBounds();
      return PanelGeometry(
        left: bounds.right + 8,
        top: bounds.top + 40,
        width: size.width,
        height: size.height,
      );
    } on Object {
      return PanelGeometry(
        left: 120,
        top: 120,
        width: size.width,
        height: size.height,
      );
    }
  }

  Future<void> _detachPanel(PanelId panelId) async {
    if (mounted) {
      setState(() {
        if (panelId == PanelId.explorer) {
          _explorerPanelError = null;
        } else {
          _inspectorPanelError = null;
        }
      });
    }
    try {
      await _ensurePanelInfrastructure();
      final host = _panelWindowHost!;
      final attachment = await host.detach(
        panelId,
        requestedGeometry: await _requestedPanelGeometry(panelId),
      );
      if (attachment == null) {
        if (mounted) {
          setState(() {
            if (panelId == PanelId.explorer) {
              _explorerPanelError =
                  'Não foi possível abrir a janela do Explorer.';
            } else {
              _inspectorPanelError =
                  'Não foi possível abrir a janela do Inspector.';
            }
          });
        }
        return;
      }
      await _panelTransport?.ready;
      await _setShellCloseGuard(host.hasAttachments);
      if (!mounted) return;
      setState(() {
        if (panelId == PanelId.explorer) {
          _explorerDetached = true;
        } else {
          _inspectorDetached = true;
        }
      });
      widget.cad.setStatus(
        '${panelDescriptor(panelId).title} destacado para outra janela.',
      );
    } on Object catch (error) {
      if (!mounted) return;
      debugPrint('[panel-window] detach failed: $error');
      setState(
        () => panelId == PanelId.explorer
            ? _explorerPanelError = 'Falha ao destacar o Explorer: $error'
            : _inspectorPanelError = 'Falha ao destacar o Inspector: $error',
      );
    }
  }

  Future<void> _detachExplorer() => _detachPanel(PanelId.explorer);

  Future<void> _detachInspector() => _detachPanel(PanelId.inspector);

  Future<void> _dockExplorer() async {
    await _dockPanel(PanelId.explorer);
  }

  /// Docks one detached panel without coupling the host to Explorer.
  ///
  /// Explorer remains the only panel with an in-window renderer in this
  /// increment; the generic host/bridge lifecycle is nevertheless shared by
  /// every [PanelId].
  Future<void> _dockPanel(PanelId panelId) async {
    final host = _panelWindowHost;
    if (host == null) return;
    final closed = await host.dock(panelId);
    await _setShellCloseGuard(host.hasAttachments);
    await _panelBridge?.disconnectPanel(panelId);
    if (!mounted) return;
    setState(() {
      if (panelId == PanelId.explorer) {
        _explorerDetached = false;
      } else if (panelId == PanelId.inspector) {
        _inspectorDetached = false;
      }
    });
    widget.cad.setStatus(
      closed
          ? '${panelDescriptor(panelId).title} reencaixado na janela principal.'
          : '${panelDescriptor(panelId).title} reencaixado; feche a janela destacada com o X.',
    );
  }

  Future<void> _reconcilePanelWindows() async {
    final host = _panelWindowHost;
    if (host == null || !host.hasAttachments) return;
    final closed = await host.reconcileWindows();
    final detachedByDisplay = await host.reconcileDisplays();
    await _setShellCloseGuard(host.hasAttachments);
    final affected = {...closed, ...detachedByDisplay};
    if (affected.isEmpty || !mounted) return;
    for (final panelId in affected) {
      await _panelBridge?.disconnectPanel(panelId);
    }
    if (affected.contains(PanelId.explorer)) {
      setState(() => _explorerDetached = false);
      widget.cad.setStatus('Janela do Explorer fechada; painel reencaixado.');
    }
    if (affected.contains(PanelId.inspector)) {
      setState(() => _inspectorDetached = false);
      widget.cad.setStatus('Janela do Inspector fechada; painel reencaixado.');
    }
  }

  /// Arms the "close the panels first" barrier while a panel is detached.
  ///
  /// Destroying the main window while a panel is still open leaves the process
  /// alive with an orphan panel window: the secondary engine's platform runner
  /// lives on this very thread, so once the shell stops pumping messages its
  /// shutdown never completes (measured: process stuck with a single thread and
  /// a live `FLUTTER_MULTI_WINDOW_WIN32_WINDOW`). The barrier is only armed
  /// while a panel is actually detached, so the normal close path stays
  /// untouched.
  Future<void> _setShellCloseGuard(bool armed) async {
    if (armed == _shellCloseGuardArmed) return;
    _shellCloseGuardArmed = armed;
    try {
      await windowManager.setPreventClose(armed);
    } on Object catch (error) {
      debugPrint('[panel-window] close guard unavailable: $error');
    }
  }

  /// Docks every panel and only then lets the shell window close.
  Future<void> _closeShellWithPanels() async {
    if (_closingShell) return;
    _closingShell = true;
    try {
      final host = _panelWindowHost;
      if (host != null && host.hasAttachments) {
        // A session teardown closes the window but keeps the operator's
        // detached preference: only an explicit Dock stores the panel as
        // docked (that is what stops a later launch from reopening it).
        for (final panelId in host.attachments.keys.toList()) {
          var closed = await host.dock(panelId, persist: false);
          if (!closed) {
            // One retry: the panel may still have been booting.
            closed = await host.dock(panelId, persist: false);
          }
          await _panelBridge?.disconnectPanel(panelId);
          if (!closed) {
            debugPrint(
              '[panel-window] shell closing with a panel window still alive '
              '(${panelId.name})',
            );
          }
        }
      }
      await _setShellCloseGuard(false);
      await windowManager.close();
    } on Object catch (error) {
      debugPrint('[panel-window] shell close failed: $error');
      _closingShell = false;
    }
  }

  @override
  void onWindowClose() {
    unawaited(_closeShellWithPanels());
  }

  @override
  void dispose() {
    _panelReconcileTimer?.cancel();
    windowManager.removeListener(this);
    final panelHost = _panelWindowHost;
    if (panelHost != null && panelHost.hasAttachments) {
      for (final panelId in panelHost.attachments.keys.toList()) {
        unawaited(panelHost.dock(panelId, persist: false));
      }
    }
    _panelBridge?.dispose();
    unawaited(_panelTransport?.close() ?? Future<void>.value());
    contextualReferencePreview.cancel();
    intersectionSelection.dispose();
    alignmentCoordinateSystemSelection.dispose();
    transformX.dispose();
    transformY.dispose();
    transformZ.dispose();
    transformAngle.dispose();
    transformScaleX.dispose();
    transformScaleY.dispose();
    transformScaleZ.dispose();
    surfaceOffset.dispose();
    sectionOffset.dispose();
    _sketchSuggestionScrollController.dispose();
    _sketchSuggestionHoverPresentation.dispose();
    widget.cad.removeListener(_synchronizeScene);
    widget.cad.runtime.removeListener(_synchronizeScene);
    operational.removeListener(_onOperationalChanged);
    alignmentCoordinateSystemSelection.removeListener(
      _alignmentCaptureStateChanged,
    );
    operational.dispose();
    navigation.dispose();
    camera.dispose();
    managedFaceSelection.dispose();
    modelingViewport.dispose();
    super.dispose();
  }

  void _synchronizeScene() {
    final runtimeDocument = widget.cad.runtime.document;
    if (runtimeDocument == null) {
      contextualReferencePreview.cancel();
      intersectionSelection.clear();
      alignmentCoordinateSystemSelection.clear();
      operational.detachProject();
      fittedDocumentId = null;
      fittedDocumentSession = null;
      _projectOpenFitGate.invalidate();
      _pendingManagedImportFit = null;
      openToolWindows.clear();
      return;
    }
    final sessionChanged =
        fittedDocumentId != runtimeDocument.projectId ||
        fittedDocumentSession != widget.cad.runtime.sessionIdentity;
    // project.new / runtime.open clears CadRuntime._state (sketchApi, stage,
    // hovered) without going through detachProject.  Drop the surviving
    // suggestion list so hover cannot look at stale IDs while the new
    // session rebinds. configureProject below reconnects the same controller.
    if (sessionChanged && fittedDocumentSession != null) {
      operational.detachProject();
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
    if (sessionChanged) {
      contextualReferencePreview.cancel();
      intersectionSelection.clear();
      alignmentCoordinateSystemSelection.clear();
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
      fittedDocumentSession = widget.cad.runtime.sessionIdentity;
      _scheduleProjectOpenFit(
        projectId: runtimeDocument.projectId,
        session: widget.cad.runtime.sessionIdentity,
        revision: widget.cad.runtime.runtimeRevision,
      );
    }
    final publication = widget.cad.runtime.managedImportPublication;
    if (publication != null &&
        publication.id > _handledManagedImportPublication &&
        publication.session == widget.cad.runtime.sessionIdentity) {
      _handledManagedImportPublication = publication.id;
      _scheduleManagedImportFit(publication);
    }
  }

  bool _captureContextualReferencePick(CadViewportPick pick) {
    if (_captureAlignmentCoordinateSystemPick(pick)) return true;
    return _captureIntersectionPick(pick);
  }

  bool _captureAlignmentCoordinateSystemPick(CadViewportPick pick) {
    if (!alignmentCoordinateSystemSelection.active) return false;
    final slot = alignmentCoordinateSystemSelection.activeSlot!;
    if (slot == AlignmentCoordinateSystemSlot.viewportOrigin) {
      final source = scene.find(pick.entityId);
      if (source == null ||
          !source.visible ||
          !const {
            CadSceneEntityKind.mesh,
            CadSceneEntityKind.surface,
            CadSceneEntityKind.solid,
          }.contains(source.kind) ||
          ![
            pick.hit.point.x,
            pick.hit.point.y,
            pick.hit.point.z,
          ].every((value) => value.isFinite)) {
        widget.cad.setStatus(
          'Clique incompatível: a captura exige uma face CAD ou malha STL visível.',
        );
        return true;
      }
      alignmentCoordinateSystemSelection.setManualOrigin(
        pick.hit.point,
        kind: AlignmentCoordinateSystemOriginKind.viewport,
      );
      widget.cad.setStatus(
        'Origem capturada na geometria: ${InspectorValueFormatter.coordinateMm(pick.hit.point.toJson())}.',
      );
      return true;
    }
    final result = alignmentCoordinateSystemSelection.capture(
      pick.entityId,
      planeCandidateIds: widget.cad.runtime
          .planeIntersectionCandidates()
          .map((entity) => entity.id)
          .toSet(),
      axisCandidateIds: widget.cad.runtime
          .axisIntersectionCandidates()
          .map((entity) => entity.id)
          .toSet(),
      pointCandidateIds: widget.cad.runtime
          .pointReferenceCandidates()
          .map((entity) => entity.id)
          .toSet(),
    );
    String label(AlignmentCoordinateSystemSlot value) => switch (value) {
      AlignmentCoordinateSystemSlot.plane => 'Plano base',
      AlignmentCoordinateSystemSlot.axis => 'Eixo/Vetor de direção',
      AlignmentCoordinateSystemSlot.point => 'Ponto de origem',
      AlignmentCoordinateSystemSlot.viewportOrigin =>
        'ponto na geometria visível',
    };
    if (result == AlignmentCoordinateSystemCaptureResult.incompatible) {
      widget.cad.setStatus(
        'Seleção incompatível: clique em ${label(slot)} de References ou WCS.',
      );
    } else if (result == AlignmentCoordinateSystemCaptureResult.accepted) {
      widget.cad.setStatus('Campo ${label(slot)} preenchido pela viewport.');
    }
    return true;
  }

  bool _captureIntersectionPick(CadViewportPick pick) {
    if (!intersectionSelection.active) return false;
    final slot = intersectionSelection.activeSlot!;
    final result = intersectionSelection.capture(
      pick.entityId,
      planeCandidateIds: widget.cad.runtime
          .planeIntersectionCandidates()
          .map((entity) => entity.id)
          .toSet(),
      axisCandidateIds: widget.cad.runtime
          .axisIntersectionCandidates()
          .map((entity) => entity.id)
          .toSet(),
    );
    if (result == PlaneAxisIntersectionCaptureResult.incompatible) {
      widget.cad.setStatus(
        slot == PlaneAxisIntersectionSlot.plane
            ? 'Seleção incompatível: clique em um plano de References ou WCS.'
            : 'Seleção incompatível: clique em um eixo de References ou WCS.',
      );
    } else if (result == PlaneAxisIntersectionCaptureResult.accepted) {
      widget.cad.setStatus(
        'Campo ${slot == PlaneAxisIntersectionSlot.plane ? 'Plano' : 'Eixo'} preenchido pela viewport.',
      );
    }
    return true;
  }

  bool _keepIntersectionCaptureOnEmptyClick() {
    final alignmentSlot = alignmentCoordinateSystemSelection.activeSlot;
    if (alignmentSlot != null) {
      final label = switch (alignmentSlot) {
        AlignmentCoordinateSystemSlot.plane => 'Plano base',
        AlignmentCoordinateSystemSlot.axis => 'Eixo/Vetor de direção',
        AlignmentCoordinateSystemSlot.point => 'Ponto de origem',
        AlignmentCoordinateSystemSlot.viewportOrigin =>
          'Ponto de origem na geometria',
      };
      widget.cad.setStatus(
        'Nenhuma referência válida nesse ponto; a captura de $label continua ativa.',
      );
      return true;
    }
    final slot = intersectionSelection.activeSlot;
    if (slot == null) return false;
    widget.cad.setStatus(
      slot == PlaneAxisIntersectionSlot.plane
          ? 'Nenhum plano válido nesse ponto; a captura de Plano continua ativa.'
          : 'Nenhum eixo válido nesse ponto; a captura de Eixo continua ativa.',
    );
    return true;
  }

  Set<String>? get _contextualCaptureCandidateIds {
    final slot = alignmentCoordinateSystemSelection.activeSlot;
    if (slot != null) {
      return switch (slot) {
        AlignmentCoordinateSystemSlot.plane =>
          widget.cad.runtime
              .planeIntersectionCandidates()
              .map((entity) => entity.id)
              .toSet(),
        AlignmentCoordinateSystemSlot.axis =>
          widget.cad.runtime
              .axisIntersectionCandidates()
              .map((entity) => entity.id)
              .toSet(),
        AlignmentCoordinateSystemSlot.point =>
          widget.cad.runtime
              .pointReferenceCandidates()
              .map((entity) => entity.id)
              .toSet(),
        AlignmentCoordinateSystemSlot.viewportOrigin =>
          scene.entities
              .where(
                (entity) =>
                    entity.visible &&
                    const {
                      CadSceneEntityKind.mesh,
                      CadSceneEntityKind.surface,
                      CadSceneEntityKind.solid,
                    }.contains(entity.kind),
              )
              .map((entity) => entity.id)
              .toSet(),
      };
    }
    final intersectionSlot = intersectionSelection.activeSlot;
    if (intersectionSlot == null) return null;
    return intersectionSlot == PlaneAxisIntersectionSlot.plane
        ? widget.cad.runtime
              .planeIntersectionCandidates()
              .map((entity) => entity.id)
              .toSet()
        : widget.cad.runtime
              .axisIntersectionCandidates()
              .map((entity) => entity.id)
              .toSet();
  }

  void _scheduleManagedImportFit(CadManagedImportPublication publication) {
    _projectOpenFitGate.invalidate();
    final ticket = _managedImportFitGate.schedule();
    final scheduledCamera = camera.snapshot();
    void apply() {
      if (camera.viewportWidth <= 1 || camera.viewportHeight <= 1) return;
      _pendingManagedImportFit = null;
      final current = widget.cad.runtime.managedImportPublication;
      if (!mounted ||
          current == null ||
          !_managedImportFitGate.canApply(
            ticket: ticket,
            publicationId: publication.id,
            currentPublicationId: current.id,
            publicationSession: publication.session,
            currentSession: widget.cad.runtime.sessionIdentity,
            publicationRevision: publication.revision,
            currentRevision: widget.cad.runtime.runtimeRevision,
            scheduledCamera: scheduledCamera,
            camera: camera,
          )) {
        return;
      }
      navigation.fit(
        Vector3(
          publication.bounds.minX,
          publication.bounds.minY,
          publication.bounds.minZ,
        ),
        Vector3(
          publication.bounds.maxX,
          publication.bounds.maxY,
          publication.bounds.maxZ,
        ),
      );
      assert(() {
        debugPrint(
          '[viewport-import-fit] valid viewport presented; Fit delivered',
        );
        return true;
      }());
    }

    _pendingManagedImportFit = apply;
    assert(() {
      debugPrint(
        '[viewport-import-fit] publication queued after controller restoration',
      );
      return true;
    }());
    // The managed publication can arrive after the first valid viewport frame
    // (the development autoload intentionally waits for that frame).  In that
    // case no later layout callback is guaranteed, so deliver the pending Fit
    // on the next frame instead of leaving it stranded indefinitely.
    if (camera.viewportWidth > 1 && camera.viewportHeight > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) apply();
      });
    }
  }

  void _scheduleProjectOpenFit({
    required String projectId,
    required int session,
    required int revision,
  }) {
    final ticket = _projectOpenFitGate.schedule();
    final scheduledCamera = camera.snapshot();
    void apply() {
      if (camera.viewportWidth <= 1 || camera.viewportHeight <= 1) return;
      _pendingManagedImportFit = null;
      final document = widget.cad.runtime.document;
      if (!mounted ||
          document == null ||
          !_projectOpenFitGate.canApply(
            ticket: ticket,
            projectId: projectId,
            currentProjectId: document.projectId,
            session: session,
            currentSession: widget.cad.runtime.sessionIdentity,
            revision: revision,
            currentRevision: widget.cad.runtime.runtimeRevision,
            scheduledCamera: scheduledCamera,
            camera: camera,
          )) {
        return;
      }
      final bounds = cadInitialProjectFitBounds(scene);
      navigation.fit(bounds.minimum, bounds.maximum);
      assert(() {
        debugPrint('[viewport-project-fit] initial Fit delivered');
        return true;
      }());
    }

    _pendingManagedImportFit = apply;
  }

  ({Vector3 minimum, Vector3 maximum})? _visibleSceneBounds() {
    return cadSceneContentBounds(scene);
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

  void _beginDirectSketchSupportSelection({bool forceNew = false}) {
    if (mounted) {
      setState(() {
        module = 'Sketch';
        openToolWindows.add('Sketch');
        choosingSketchSupport = widget.cad.runtime.document != null;
        forceNewSketchOnSupportPick = forceNew;
      });
    }
    if (widget.cad.runtime.document == null) {
      widget.cad.setStatus('Abra um projeto antes de criar um Sketch.');
      return;
    }
    widget.cad.setStatus(
      'Selecione XY, YZ, ZX ou outro suporte planar na viewport. '
      'Pressione ESC para cancelar.',
    );
  }

  Future<void> _openSketchSupportFallback() async {
    final document = widget.cad.runtime.document;
    if (document == null) {
      widget.cad.setStatus('Abra um projeto antes de criar um Sketch.');
      return;
    }
    final selectedEntity = geometrySelection.selectedIds.isEmpty
        ? null
        : document.entities[geometrySelection.selectedIds.first];
    final selectedIsPlanar =
        selectedEntity != null &&
        operational.isPlanarSketchSupport(selectedEntity.id);
    var choice = 'xy';
    final selectedChoice = selectedIsPlanar ? selectedEntity : null;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Onde criar o Sketch?'),
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
                  const RadioListTile(value: 'xy', title: Text('Plano XY')),
                  const RadioListTile(value: 'yz', title: Text('Plano YZ')),
                  const RadioListTile(value: 'zx', title: Text('Plano ZX')),
                  const Divider(),
                  RadioListTile(
                    value: 'existing',
                    enabled:
                        selectedChoice?.kind == CadDocumentEntityKind.reference,
                    title: const Text('Plano existente'),
                    subtitle: Text(
                      selectedChoice?.kind == CadDocumentEntityKind.reference
                          ? selectedChoice!.data['name'] as String? ??
                                selectedChoice.id
                          : 'Selecione primeiro uma referência planar',
                    ),
                  ),
                  RadioListTile(
                    value: 'face',
                    enabled: selectedChoice?.kind == CadDocumentEntityKind.face,
                    title: const Text('Face planar'),
                    subtitle: Text(
                      selectedChoice?.kind == CadDocumentEntityKind.face
                          ? selectedChoice!.data['name'] as String? ??
                                selectedChoice.id
                          : 'Selecione primeiro uma face planar',
                    ),
                  ),
                  RadioListTile(
                    value: 'surface',
                    enabled:
                        selectedChoice?.kind == CadDocumentEntityKind.surface,
                    title: const Text('Superfície planar'),
                    subtitle: Text(
                      selectedChoice?.kind == CadDocumentEntityKind.surface
                          ? selectedChoice!.data['name'] as String? ??
                                selectedChoice.id
                          : 'Selecione primeiro uma superfície planar',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Criar Sketch'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true) return;
    try {
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
    } catch (error) {
      widget.cad.setStatus(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _selectWorldSketchSupport(SketchPlaneType type) async {
    try {
      operational.selectWorldSketchPlane(type);
      await _activateSelectedSketchSupport();
    } catch (error) {
      widget.cad.setStatus(error.toString());
    }
  }

  Future<void> _activateSelectedSketchSupport({bool forceNew = false}) async {
    final plane = operational.activeSketchPlane;
    final planeId = operational.activeSketchPlaneId;
    if (plane == null || planeId == null) {
      widget.cad.setStatus('Escolha um suporte planar de Sketch na viewport.');
      return;
    }
    await operational.openSketch(forceNew: forceNew);
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
      case SketchToolType.rectangle:
        operational.beginRectangleCommand();
      default:
        operational.beginLineCommand();
    }
    if (mounted) {
      setState(() {
        choosingSketchSupport = false;
        forceNewSketchOnSupportPick = false;
        openToolWindows.add('Sketch');
      });
    }
    widget.cad.setStatus('Sketch ativo · ortográfico · suporte enquadrado.');
  }

  Future<void> _selectSketchSupportFromViewport(CadViewportPick pick) async {
    final entity = widget.cad.runtime.document?.entities[pick.entityId];
    if (entity == null ||
        !const {
          CadDocumentEntityKind.reference,
          CadDocumentEntityKind.face,
          CadDocumentEntityKind.surface,
        }.contains(entity.kind)) {
      widget.cad.setStatus('Aponte para um suporte XY, YZ, ZX ou planar.');
      return;
    }
    if (!operational.isPlanarSketchSupport(entity.id)) {
      widget.cad.setStatus('A entidade selecionada não é um suporte planar.');
      return;
    }
    try {
      operational.selectSketchSupport(entity.id);
      await _activateSelectedSketchSupport(
        forceNew: forceNewSketchOnSupportPick,
      );
    } catch (error) {
      widget.cad.setStatus(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _finishSketch() async {
    operational.cancelSketchCommand();
    await operational.finishSketch();
    camera.retainSketchView();
    await operational.refreshSketchSceneAfterExit();
    final bounds = cadSceneContentBounds(widget.cad.runtime.scene);
    if (bounds != null) camera.fit(bounds.minimum, bounds.maximum);
  }

  void _focusSketchReconstructionSuggestion(
    SketchReconstructionSuggestion suggestion,
  ) {
    // Selection/highlight is still handled by the controller.  Focusing is a
    // separate presentation action so hover never moves the camera and the
    // accept button cannot accidentally trigger it through ListTile.onTap.
    final additive = HardwareKeyboard.instance.isControlPressed;
    operational.selectSketchReconstructionSuggestion(
      suggestion,
      additive: additive,
    );
    // Ctrl-click is intentionally selection-only.  A normal click retains
    // the established focus-to-suggestion behavior.
    if (additive) return;
    final bounds = operational.sketchReconstructionSuggestionBounds(suggestion);
    if (bounds == null) return;
    final extent = bounds.maximum - bounds.minimum;
    final diagonal = extent.length;
    if (!diagonal.isFinite) return;
    // A non-zero floor keeps a tiny fragment from producing an unusably tight
    // view, while the proportional margin keeps large chains readable.
    final margin = math.max(0.5, diagonal * 0.15);
    final padding = Vector3(margin, margin, margin);
    navigation.fit(bounds.minimum - padding, bounds.maximum + padding);
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
        title: const Text('Reparo seguro de lacuna'),
        content: Text(
          'A gap of ${(issue.distance ?? 0).toStringAsFixed(3)} mm was found. '
          'Close it automatically?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Não'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sim'),
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
          title: const Text('Editar cota controladora'),
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
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                double.tryParse(input.text.replaceAll(',', '.')),
              ),
              child: const Text('Aplicar'),
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
    if (workspace == 'Reference') contextualReferencePreview.cancel();
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

  Widget _withArcRadiusEditPreview(Widget content) {
    final diagnostic = operational.arcRadiusEditDiagnostic;
    if (operational.arcRadiusEditPreview == null && diagnostic == null) {
      return content;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (operational.arcRadiusEditPreview != null)
          _ArcRadiusEditPreviewPanel(controller: operational),
        if (diagnostic != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              diagnostic,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 10,
              ),
            ),
          ),
        content,
      ],
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
      return _withArcRadiusEditPreview(
        _InspectorSection(
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
                    label: Text(
                      selectedConstraint.visible ? 'Ocultar' : 'Mostrar',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        operational.deleteConstraint(selectedConstraint.id),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Excluir'),
                  ),
                ),
              ],
            ),
          ],
        ),
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
      return _withArcRadiusEditPreview(
        _InspectorSection(
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
        ),
      );
    }
    if (selected is SketchArc) {
      final fillet = selected.metadata['featureType'] == 'fillet';
      final radius = (selected.parameters['radius'] as num).toDouble();
      final start = (selected.parameters['startAngle'] as num).toDouble();
      final end = (selected.parameters['endAngle'] as num).toDouble();
      return _withArcRadiusEditPreview(
        Column(
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
        ),
      );
    }
    if (operational.arcRadiusEditPreview != null) {
      return _withArcRadiusEditPreview(const SizedBox.shrink());
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
            _InspectorProperty(
              label: 'Origin',
              value: InspectorValueFormatter.coordinateMm(
                sketch.coordinates.origin.toJson(),
              ),
            ),
            _InspectorProperty(
              label: 'Normal',
              value: sketch.coordinates.normal.toJson(),
            ),
            _InspectorProperty(
              label: 'X Axis',
              value: sketch.coordinates.xAxis.toJson(),
            ),
            _InspectorProperty(
              label: 'Y Axis',
              value: sketch.coordinates.yAxis.toJson(),
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
    widget.cad.setStatus('Section operation in progress...');
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
          title: const Text('Ajustar spline'),
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
              Text('Pontos: $pointCount  ·  Segmentos: $segmentCount'),
              Text(
                'Tempo estimado: ${(pointCount / 5000).clamp(.1, 30).toStringAsFixed(1)} s',
              ),
              Text('Erro máximo alvo: ${selected.toStringAsFixed(3)} mm'),
              Text('Erro médio alvo: ${(selected * .5).toStringAsFixed(3)} mm'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Lembrar esta configuração'),
                value: remember,
                onChanged: (value) =>
                    setDialogState(() => remember = value ?? false),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Prévia automática'),
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
              const Text('Laranja: prévia da spline'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Criar spline'),
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
        label: const Text('Criar seção'),
        onPressed: () => _sectionAction(operational.createSection),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.draw),
        label: const Text('Sketch a partir da seção'),
        onPressed: () =>
            _sectionAction(operational.createSketchFromSelectedSection),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.gesture),
        label: const Text('Ajustar spline'),
        onPressed: _bestFitSpline,
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.layers_outlined),
        label: const Text('Alternar seção'),
        onPressed: () =>
            _sectionAction(operational.toggleSourceSectionVisibility),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.edit_outlined),
        label: Text(
          operational.activeSketchVisible ? 'Hide Sketch' : 'Show Sketch',
        ),
        onPressed: () =>
            _sectionAction(operational.toggleActiveSketchVisibility),
      ),
      if (operational.activeSketch?.metadata['associationState'] == 'outdated')
        FilledButton.tonalIcon(
          icon: const Icon(Icons.sync_problem),
          label: const Text('Atualizar Sketch'),
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
        label: const Text('Seção por eixo'),
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
            labelText: 'Deslocamento do plano',
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
        label: const Text('Recalcular'),
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
    final runtime = widget.cad.runtime;
    final selected = runtime.selection;
    final managed = selected
        .map((id) => runtime.document?.entities[id])
        .where(
          (e) =>
              e != null &&
              [
                e.data['managedStepAssets'],
                e.data['managedBrepAssets'],
                e.data['managedStlAssets'],
              ].any((a) => a is Map),
        )
        .toList();
    if (managed.isNotEmpty) {
      if (selected.length != 1 || managed.length != 1) {
        return const Text(
          'Selecione uma única entidade managed para editar o placement.',
        );
      }
      return ManagedPlacementEditor(
        key: ValueKey(managed.single!.id),
        runtime: runtime,
        entityId: managed.single!.id,
      );
    }
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
        const Text(
          'Transformação',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const Text(
          'Selecione uma entidade, configure os valores, visualize e aplique.',
        ),
        RadioGroup<TransformDisposition>(
          groupValue: operational.transformDisposition,
          onChanged: operational.chooseTransformDisposition,
          child: const Column(
            children: [
              RadioListTile<TransformDisposition>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: TransformDisposition.original,
                title: Text('Transformar original'),
              ),
              RadioListTile<TransformDisposition>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: TransformDisposition.workingCopy,
                title: Text('Criar cópia de trabalho'),
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
          label: const Text('Prévia de deslocamento'),
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
                child: Text('Rotacionar ${axis.$1}'),
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
          label: const Text('Prévia de escala'),
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
        const Text('Transformar por referência'),
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
              tooltip: 'Cancelar prévia',
              onPressed: operational.manualTransformPreview == null
                  ? null
                  : operational.cancelManualTransform,
              icon: const Icon(Icons.close),
            ),
            IconButton(
              tooltip: 'Redefinir transformação',
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
          title: const Text('Análise de dependências'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${entity.data['name'] ?? entity.id} affects:'),
              if (counts.isEmpty) const Text('Nenhuma entidade dependente.'),
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
              child: const Text('Excluir somente esta entidade'),
            ),
            if (impacted.isNotEmpty)
              FilledButton(
                onPressed: () => Navigator.pop(context, 'all'),
                child: const Text('Excluir todas as afetadas'),
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
    final referenceGroups = ReferenceTreeTaxonomy.grouped(entities);
    final groups = <String, List<CadDocumentEntity>>{
      'Entidades': entities
          .where(
            (entity) =>
                entity.data['constructionEntity'] is Map &&
                !ReferenceTreeTaxonomy.isProjectedReference(entity) &&
                entity.kind != CadDocumentEntityKind.surface &&
                entity.kind != CadDocumentEntityKind.curve &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'Meshes': entities
          .where(
            (entity) =>
                entity.kind == CadDocumentEntityKind.import &&
                (ManagedCadIdentity.fromDocumentData(entity.data)?.kind ??
                        ManagedCadSemanticKind.mesh) ==
                    ManagedCadSemanticKind.mesh &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'References': const [],
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
                !ReferenceTreeTaxonomy.isProjectedReference(entity) &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'Surfaces': entities
          .where(
            (entity) =>
                (entity.kind == CadDocumentEntityKind.surface ||
                    (entity.kind == CadDocumentEntityKind.import &&
                        ManagedCadIdentity.fromDocumentData(
                              entity.data,
                            )?.kind ==
                            ManagedCadSemanticKind.surface)) &&
                entity.data['deleted'] != true,
          )
          .toList(),
      'Solids': entities
          .where(
            (entity) =>
                (entity.kind == CadDocumentEntityKind.solid ||
                    (entity.kind == CadDocumentEntityKind.import &&
                        ManagedCadIdentity.fromDocumentData(
                              entity.data,
                            )?.kind ==
                            ManagedCadSemanticKind.solid)) &&
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
                !ReferenceTreeTaxonomy.isProjectedReference(entity) &&
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
          title: const Text('Renomear'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Renomear'),
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
      final managedIdentity = ManagedCadIdentity.fromDocumentData(entity.data);
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
        } else if (action == 'createReference') {
          geometrySelection.select(entity.id);
          setState(() {
            module = 'Reference';
            openToolWindows.add('Reference');
          });
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
                      child: const Text('Renomear'),
                    ),
                    PopupMenuItem(
                      value: 'visibility',
                      child: Text(visible ? 'Ocultar' : 'Mostrar'),
                    ),
                    PopupMenuItem(
                      value: 'duplicate',
                      enabled: collection,
                      child: const Text('Duplicar'),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Excluir'),
                    ),
                    const PopupMenuDivider(),
                    if (!collection)
                      const PopupMenuItem(
                        value: 'createReference',
                        child: Text('Criar referência'),
                      ),
                    const PopupMenuItem(
                      value: 'properties',
                      child: Text('Propriedades'),
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
                : managedIdentity?.kind == ManagedCadSemanticKind.solid
                ? _CadGlyphKind.solid
                : managedIdentity?.kind == ManagedCadSemanticKind.surface
                ? _CadGlyphKind.surface
                : managedIdentity?.kind == ManagedCadSemanticKind.mesh
                ? _CadGlyphKind.mesh
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
                      child: Text('Mostrar/Ocultar'),
                    ),
                    const PopupMenuItem(
                      value: 'lock',
                      child: Text('Bloquear/Desbloquear'),
                    ),
                    const PopupMenuItem(
                      value: 'active',
                      child: Text('Tornar ativo'),
                    ),
                    const PopupMenuItem(
                      value: 'duplicate',
                      child: Text('Duplicar'),
                    ),
                    if (entity.data['systemCollection'] != true)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Mover para a lixeira'),
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
                    PopupMenuItem(value: 'restore', child: Text('Restaurar')),
                    PopupMenuItem(
                      value: 'purge',
                      child: Text('Excluir permanentemente'),
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
                        child: Text('Renomear'),
                      ),
                    PopupMenuItem(
                      value: 'visibility',
                      child: Text(visible ? 'Ocultar' : 'Mostrar'),
                    ),
                    const PopupMenuItem<String>(
                      enabled: false,
                      value: 'duplicate',
                      child: Text('Duplicar'),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Excluir'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'properties',
                      child: Text('Propriedades'),
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
                  if (entity.kind == CadDocumentEntityKind.section) {
                    // GeometrySelectionManager is the runtime selection
                    // source; keep Section tools on that same context.
                    widget.cad.setStatus('Reference Curve selected.');
                  } else if (entity.data['sceneKind'] == 'plane') {
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
      return entity.kind == CadDocumentEntityKind.import &&
              managedIdentity?.kind == ManagedCadSemanticKind.mesh
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

    Widget referenceFolder(ReferenceTreeGroup group) {
      final members = referenceGroups[group]!;
      final glyph = switch (group) {
        ReferenceTreeGroup.coordinateSystem => _CadGlyphKind.reference,
        ReferenceTreeGroup.points => _CadGlyphKind.point,
        ReferenceTreeGroup.axes => _CadGlyphKind.axis,
        ReferenceTreeGroup.planes => _CadGlyphKind.plane,
        ReferenceTreeGroup.curves => _CadGlyphKind.curve,
        ReferenceTreeGroup.other => _CadGlyphKind.construction,
      };
      return ExpansionTile(
        key: ValueKey('workspace-reference-group-${group.name}'),
        initiallyExpanded:
            group == ReferenceTreeGroup.coordinateSystem || members.isNotEmpty,
        dense: true,
        visualDensity: const VisualDensity(vertical: -3),
        leading: _CadExplorerGlyph(glyph, size: 15),
        title: _ExplorerLabel(
          group.label,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
        children: ExplorerTreeProjection.rowsFor(members).map(row).toList(),
      );
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
              initiallyExpanded:
                  entry.key == 'Reference Curves' && entry.value.isNotEmpty,
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
              children: entry.key == 'References'
                  ? [
                      for (final group in ReferenceTreeTaxonomy.orderedGroups)
                        if (group != ReferenceTreeGroup.other ||
                            referenceGroups[group]!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: referenceFolder(group),
                          ),
                    ]
                  : ExplorerTreeProjection.rowsFor(
                      entry.value,
                    ).map(row).toList(),
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
      CadDocumentEntityKind.import =>
        switch (ManagedCadIdentity.fromDocumentData(selected!.data)?.kind) {
          ManagedCadSemanticKind.solid => 'Solids',
          ManagedCadSemanticKind.surface => 'Surfaces',
          _ => 'Recognition',
        },
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

  Map<String, Object?>? _recognizedStlPlanePreview() {
    if (operational.activeContext?.region == null) return null;
    final plane = operational.hypotheses
        .where((item) => item.recognition.winner.type.name == 'plane')
        .firstOrNull;
    final parameters = plane?.recognition.winner.parameters;
    final origin = parameters?['origin'];
    final normal = parameters?['normal'];
    bool validVector(Object? value) =>
        value is List &&
        value.length == 3 &&
        value.every((component) => component is num && component.isFinite);
    if (!validVector(origin) || !validVector(normal)) return null;
    final tolerance = plane!.recognition.winner.statistics.rms;
    final confidence = plane.recognition.dna.confidence;
    if (!tolerance.isFinite || !confidence.isFinite) return null;
    return {
      'origin': (origin as List).cast<Object?>(),
      'normal': (normal as List).cast<Object?>(),
      'tolerance': tolerance,
      'confidence': confidence,
    };
  }

  Future<void> _selectModule(String item) async {
    if (item == 'Sketch') {
      if (operational.stage == SketchSurfaceStage.sketchActive) {
        if (mounted) {
          setState(() {
            module = 'Sketch';
            choosingSketchSupport = false;
            openToolWindows.add('Sketch');
          });
        }
      } else {
        _beginDirectSketchSupportSelection(forceNew: true);
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
      // A workspace panel is a local UI surface and must still open when no
      // coordinator command is registered for that module yet.
      widget.cad.setStatus('$item aberto.');
    }
    if (item == 'Reverse Engineering') {
      await operational.persistReverseEngineeringStudioState();
    }
  }

  Widget _activityNavigation(BuildContext context) {
    final group = ActivityNavigation.groupFor(module);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          PopupMenuButton<String>(
            tooltip: 'Atividades',
            onSelected: _selectModule,
            itemBuilder: (_) => [
              for (final activity in ActivityNavigation.groups) ...[
                PopupMenuItem<String>(
                  enabled: false,
                  child: Text(
                    activity.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                for (final item in activity.modules)
                  PopupMenuItem<String>(
                    value: item,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 22,
                          child: item == module
                              ? const Icon(Icons.check, size: 16)
                              : null,
                        ),
                        Expanded(
                          child: Text(ActivityNavigation.labelFor(item)),
                        ),
                        if (ActivityNavigation.isPlaceholder(item))
                          const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Text(
                              'ambiente',
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
            child: Chip(
              avatar: const Icon(Icons.dashboard_outlined, size: 16),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(ActivityNavigation.labelFor(module)),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(group, style: Theme.of(context).textTheme.labelMedium),
          if (module == 'Surfaces') ...[
            const SizedBox(width: 8),
            _surfaceToolbarMenu(),
          ],
          if (module == 'Entidades') ...[
            const SizedBox(width: 8),
            _entityToolbarMenu(),
          ],
        ],
      ),
    );
  }

  Widget? _activeToolWindowContent() {
    final recognizedStlPlanePreview = _recognizedStlPlanePreview();
    return switch (module) {
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
      'Reference' => _ManagedCadReferencePanel(
        runtime: widget.cad.runtime,
        preview: contextualReferencePreview,
        intersectionSelection: intersectionSelection,
        alignmentCoordinateSystemSelection: alignmentCoordinateSystemSelection,
        pick: operational.activePick,
        selectedEntity: geometrySelection.selectedIds.firstOrNull == null
            ? null
            : widget.cad.runtime.document?.entities[geometrySelection
                  .selectedIds
                  .first],
        recognizedStlPlaneAvailable: recognizedStlPlanePreview != null,
        recognizedStlPlanePreview: recognizedStlPlanePreview,
        onCreateRecognizedPlane: () async {
          final plane = operational.hypotheses.firstWhere(
            (item) => item.recognition.winner.type.name == 'plane',
          );
          operational.decide(
            plane.recognition.id,
            RecognitionDecision.accepted,
          );
          await operational.createRecognizedPlane();
        },
        onOpenInspector: () => setState(() => advancedInspector = true),
        onStatus: widget.cad.setStatus,
        onCompleted: () {
          operational.activePick = null;
          contextualReferencePreview.cancel();
          managedFaceSelection.clear();
        },
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
      // A persisted/finished Sketch is context for inspection, not an active
      // editing session.  Opening the Sketch module in a project that already
      // contains Sketches must therefore offer a new support, while reopening
      // an existing Sketch remains an explicit Explorer action.
      'Sketch'
          when operational.activeSketch != null &&
              const {
                SketchSurfaceStage.sketchActive,
                SketchSurfaceStage.surfacePreview,
              }.contains(operational.stage) =>
        _SketchWorkspaceFoundation(
          controller: operational,
          onExitSketch: _finishSketch,
          onHealthIssue: _focusSketchHealthIssue,
          onFocusSuggestion: _focusSketchReconstructionSuggestion,
          onAutoHeal: _offerSketchGapRepair,
          suggestionScrollController: _sketchSuggestionScrollController,
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
        onOpenSketch: () async =>
            _beginDirectSketchSupportSelection(forceNew: true),
        onFinishSketch: _finishSketch,
      ),
      'Solids' => _ProfessionalExtrudePanel(controller: operational),
      'Sections' => _sectionTools(),
      'Transform' => _transformTools(),
      _ => null,
    };
  }

  Widget _surfaceToolbarMenu() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: PopupMenuButton<ProfessionalSurfaceTool>(
      tooltip: ShellPresentation.surfaceCommands,
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
        const PopupMenuItem(
          enabled: false,
          child: Text(ShellPresentation.createSurface),
        ),
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
            Text(ShellPresentation.surfaces),
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
        if (value is GeometryCreateAction) {
          _openEntityTool(value.index);
        }
        if (value is PrimitiveSurfaceType) {
          _openEntityTool(4, primitive: value);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          enabled: false,
          child: Text('Geometria de Referência'),
        ),
        for (final action in GeometryCreateActions.visible())
          PopupMenuItem(value: action, child: Text(action.menuLabel)),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          child: Text('Superfícies primitivas'),
        ),
        const PopupMenuItem(
          value: PrimitiveSurfaceType.plane,
          child: Text('Plano'),
        ),
        const PopupMenuItem(
          value: PrimitiveSurfaceType.cylinder,
          child: Text('Cilindro'),
        ),
        const PopupMenuItem(
          value: PrimitiveSurfaceType.cone,
          child: Text('Cone'),
        ),
        const PopupMenuItem(
          value: PrimitiveSurfaceType.sphere,
          child: Text('Esfera'),
        ),
        const PopupMenuItem(
          value: PrimitiveSurfaceType.torus,
          child: Text('Toro'),
        ),
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
        final hasSuggestionSelection =
            operational.selectedSketchReconstructionSuggestions.isNotEmpty;
        final cadCommandActive =
            operational.sketchCreationCommandActive ||
            operational.sketchEditingCommandActive ||
            operational.sketchCircularSelectionMode ||
            operational.sketchPointReferenceCaptureActive ||
            choosingSketchSupport ||
            operational.professionalExtrudePreview != null ||
            operational.professionalRevolvePreview != null ||
            operational.professionalSurfacePreview != null;
        if (hasSuggestionSelection && !cadCommandActive) {
          operational.clearSketchReconstructionSelection();
          widget.cad.setStatus('Seleção de sugestões limpa.');
          return;
        }
        contextualReferencePreview.cancel();
        widget.cad.runtime.clearManagedAlignmentPreview();
        intersectionSelection.clear();
        alignmentCoordinateSystemSelection.clear();
        operational.activePick = null;
        managedFaceSelection.clear();
        widget.cad.runtime.operationalSelection.clear();
        geometrySelection.clear();
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
          widget.cad.runtime,
          modelingViewport,
          operational,
          geometrySelection,
          widget.cad.runtime.operationalSelection,
          widget.cad.runtime.operationalEntities,
        ]),
        builder: (context, _) => Column(
          children: [
            _activityNavigation(context),
            const Divider(),
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Row(
                      children: [
                        if (_explorerDetached)
                          _DetachedPanelRail(
                            panelId: PanelId.explorer,
                            title: 'Explorer',
                            icon: Icons.account_tree,
                            error: _explorerPanelError,
                            onReturn: () => unawaited(_dockExplorer()),
                            onFocus: () => unawaited(
                              _panelWindowHost?.focus(PanelId.explorer) ??
                                  Future<void>.value(),
                            ),
                          )
                        else
                          _DockableSidePanel(
                            panelId: 'explorer',
                            title: 'Explorer',
                            icon: Icons.account_tree,
                            width: 240,
                            onDetach: () => unawaited(_detachExplorer()),
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
                                  onViewportReady: () {
                                    widget.onViewportReady?.call();
                                    _pendingManagedImportFit?.call();
                                  },
                                  onPickCapture:
                                      _captureContextualReferencePick,
                                  pickCaptureCandidateIds:
                                      _contextualCaptureCandidateIds,
                                  onSketchSuggestionHover:
                                      module == 'Sketch' &&
                                          operational.stage ==
                                              SketchSurfaceStage.sketchActive &&
                                          !choosingSketchSupport &&
                                          !operational
                                              .sketchCreationCommandActive &&
                                          !operational
                                              .sketchEditingCommandActive &&
                                          _contextualCaptureCandidateIds == null
                                      ? (pick) {
                                          final found = operational
                                              .hoverSketchReconstructionSuggestionForEntity(
                                                pick?.entityId,
                                              );
                                          final suggestion = operational
                                              .hoveredSketchReconstructionSuggestion;
                                          final position =
                                              _sketchSuggestionHoverPosition;
                                          if (found &&
                                              suggestion != null &&
                                              position != null) {
                                            _sketchSuggestionHoverPresentation
                                                .value = (
                                              position: position,
                                              label: operational
                                                  .sketchReconstructionSuggestionDisplayLabel(
                                                    suggestion,
                                                  ),
                                            );
                                          } else {
                                            _sketchSuggestionHoverPresentation
                                                    .value =
                                                null;
                                          }
                                        }
                                      : null,
                                  onSketchSuggestionHoverPosition:
                                      module == 'Sketch' &&
                                          operational.stage ==
                                              SketchSurfaceStage.sketchActive &&
                                          !choosingSketchSupport &&
                                          !operational
                                              .sketchCreationCommandActive &&
                                          !operational
                                              .sketchEditingCommandActive &&
                                          _contextualCaptureCandidateIds == null
                                      ? (position) {
                                          _sketchSuggestionHoverPosition =
                                              position;
                                          if (position == null) {
                                            _sketchSuggestionHoverPresentation
                                                    .value =
                                                null;
                                          }
                                        }
                                      : null,
                                  sketchSuggestionPickCandidateIds:
                                      module == 'Sketch'
                                      ? operational
                                            .sketchReconstructionSuggestionPickCandidateIds
                                      : null,
                                  scene: scene,
                                  camera: camera,
                                  operationalEntities:
                                      widget.cad.runtime.operationalEntities,
                                  operationalResolver:
                                      widget.cad.runtime.operationalResolver,
                                  operationalSelection:
                                      widget.cad.runtime.operationalSelection,
                                  managedFaceSelectionController:
                                      managedFaceSelection,
                                  onManagedFaceSelectionCleared: () {
                                    if (_keepIntersectionCaptureOnEmptyClick()) {
                                      return;
                                    }
                                    contextualReferencePreview.cancel();
                                    operational.activePick = null;
                                    widget.cad.runtime.operationalSelection
                                        .clear();
                                    geometrySelection.clear();
                                  },
                                  onViewportSelectionCleared: () {
                                    if (_keepIntersectionCaptureOnEmptyClick()) {
                                      return;
                                    }
                                    contextualReferencePreview.cancel();
                                    operational.activePick = null;
                                    widget.cad.runtime.operationalSelection
                                        .clear();
                                    geometrySelection.clear();
                                  },
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
                                                  .sketchEditingCommandActive ||
                                              operational
                                                  .sketchPointReferenceCaptureActive)
                                      ? (pick) async {
                                          if (operational
                                              .sketchPointReferenceCaptureActive) {
                                            await operational
                                                .captureSketchPointReferencePick(
                                                  pick,
                                                );
                                            widget.cad.setStatus(
                                              operational
                                                  .sketchPointReferenceCaptureHint,
                                            );
                                          } else if (operational
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
                                            final suggestionPicked =
                                                !operational
                                                    .sketchCircularSelectionMode &&
                                                operational
                                                    .selectSketchReconstructionSuggestionForEntity(
                                                      pick.entityId,
                                                      additive: HardwareKeyboard
                                                          .instance
                                                          .isControlPressed,
                                                    );
                                            if (suggestionPicked) {
                                              widget.cad.setStatus(
                                                'Sugestão selecionada${HardwareKeyboard.instance.isControlPressed ? ' (Ctrl)' : ''}.',
                                              );
                                              return;
                                            }
                                            operational.cancelSketchCommand();
                                            operational.selectSketchEntity(
                                              pick.entityId,
                                              additive: HardwareKeyboard
                                                  .instance
                                                  .isControlPressed,
                                            );
                                          }
                                          if (!operational
                                              .sketchPointReferenceCaptureActive) {
                                            geometrySelection.select(
                                              pick.entityId,
                                              toggle: false,
                                              range: false,
                                            );
                                            widget.cad.setStatus(
                                              'Sketch entity selected · edit parameters in Inspector.',
                                            );
                                          }
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
                                      ? () async {
                                          try {
                                            await operational
                                                .finishSketchCommandFromSecondaryTap();
                                          } catch (failure) {
                                            widget.cad.setStatus('$failure');
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
                                  onPick: widget.cad.runtime.document == null
                                      ? null
                                      : (pick) async {
                                          if (_captureContextualReferencePick(
                                            pick,
                                          )) {
                                            return;
                                          }
                                          if (module == 'Solids' &&
                                              operational
                                                  .captureRevolveViewportEntity(
                                                    pick.entityId,
                                                  )) {
                                            widget.cad.setStatus(
                                              operational.error ??
                                                  'SeleÃ§Ã£o do Revolve atualizada.',
                                            );
                                            return;
                                          }
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
                                                    append: HardwareKeyboard
                                                        .instance
                                                        .isControlPressed,
                                                    worldHit: [
                                                      pick.hit.point.x,
                                                      pick.hit.point.y,
                                                      pick.hit.point.z,
                                                    ],
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
                              Positioned.fill(
                                child:
                                    ValueListenableBuilder<
                                      ({Offset position, String label})?
                                    >(
                                      valueListenable:
                                          _sketchSuggestionHoverPresentation,
                                      builder: (context, presentation, _) {
                                        if (presentation == null ||
                                            module != 'Sketch') {
                                          return const SizedBox.shrink();
                                        }
                                        final left =
                                            presentation.position.dx + 12;
                                        final top =
                                            presentation.position.dy + 12;
                                        return Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            Positioned(
                                              left: left.clamp(
                                                4.0,
                                                math.max(
                                                  4.0,
                                                  camera.viewportWidth - 132,
                                                ),
                                              ),
                                              top: top.clamp(
                                                4.0,
                                                math.max(
                                                  4.0,
                                                  camera.viewportHeight - 30,
                                                ),
                                              ),
                                              child: IgnorePointer(
                                                child: DecoratedBox(
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0xff101820,
                                                    ).withValues(alpha: .88),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          3,
                                                        ),
                                                    border: Border.all(
                                                      color: const Color(
                                                        0xff4de1d2,
                                                      ).withValues(alpha: .75),
                                                      width: .7,
                                                    ),
                                                  ),
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 5,
                                                          vertical: 2,
                                                        ),
                                                    child: Text(
                                                      presentation.label,
                                                      style: const TextStyle(
                                                        color: Color(
                                                          0xffb8fff7,
                                                        ),
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        height: 1.1,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
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
                                  operational.lineHud != null)
                                if (operational.sketchInferenceCursor
                                    case final lineCursor?)
                                  Positioned(
                                    left: (lineCursor.dx + 18).clamp(
                                      4.0,
                                      math.max(4.0, camera.viewportWidth - 300),
                                    ),
                                    top: (lineCursor.dy + 34).clamp(
                                      4.0,
                                      math.max(4.0, camera.viewportHeight - 52),
                                    ),
                                    child: IgnorePointer(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 290,
                                        ),
                                        child: _SketchLineHud(
                                          controller: operational,
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
                                  (operational.circleHud != null ||
                                      operational.arcHud != null))
                                Positioned(
                                  left: 14,
                                  bottom: 14,
                                  child: operational.arcCommandActive
                                      ? _SketchArcHud(controller: operational)
                                      : _SketchCircleHud(
                                          controller: operational,
                                        ),
                                ),
                            ],
                          ),
                        ),
                        const VerticalDivider(),
                        if (!_inspectorDetached)
                          _DockableSidePanel(
                            panelId: 'inspector',
                            title: 'Property Inspector',
                            icon: Icons.tune,
                            width: 280,
                            onDetach: () => unawaited(_detachInspector()),
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
                                              entity
                                                  ?.placement
                                                  ?.matrix
                                                  .values ??
                                              entity?.data['transformMatrix'];
                                          final collectionId =
                                              entity?.data['collectionId']
                                                  as String?;
                                          final collection =
                                              collectionId == null
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
                                                entity?.data['name']
                                                        as String? ??
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
                                                'Position/rotation: ${matrix is List ? 'transformed' : 'identity'}',
                                              ),
                                              Text(
                                                'Active system: ${operational.manualTransformMode?.name ?? 'World'}',
                                              ),
                                              if (entity?.shape != null)
                                                const Text(
                                                  'Native BRep transform: OCCT',
                                                ),
                                              if (entity?.placement != null)
                                                const Text(
                                                  'Placement rígido não destrutivo',
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
                                          final section =
                                              entity?.data['section'];
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
                                          if (operational.activeReference ==
                                              null)
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
                                            if (operational
                                                    .alignmentTransform !=
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
                        if (_inspectorDetached)
                          _DetachedPanelRail(
                            panelId: PanelId.inspector,
                            title: 'Property Inspector',
                            icon: Icons.tune,
                            error: _inspectorPanelError,
                            onReturn: () =>
                                unawaited(_dockPanel(PanelId.inspector)),
                            onFocus: () => unawaited(
                              _panelWindowHost?.focus(PanelId.inspector) ??
                                  Future<void>.value(),
                            ),
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
                        scrollController: module == 'Sketch'
                            ? _sketchSuggestionScrollController
                            : null,
                        child: tool,
                      ),
                ],
              ),
            ),
            if (widget.cad.isBusy)
              LinearProgressIndicator(
                value: widget.cad.managedStepOperationActive
                    ? null
                    : widget.cad.progress,
              ),
            if (widget.cad.message != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      Expanded(child: Text(widget.cad.message!)),
                      if (widget.cad.canCancelManagedImport)
                        TextButton(
                          onPressed: widget.cad.cancelManagedImport,
                          child: const Text('Cancelar'),
                        ),
                    ],
                  ),
                ),
              ),
            Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: const Row(
                children: [
                  Icon(Icons.check_circle_outline, size: 16),
                  SizedBox(width: 6),
                  Text(ShellPresentation.ready),
                  Spacer(),
                  Text(ShellPresentation.footer),
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

class _ManagedCadReferencePanel extends StatefulWidget {
  const _ManagedCadReferencePanel({
    required this.runtime,
    required this.preview,
    required this.intersectionSelection,
    required this.alignmentCoordinateSystemSelection,
    required this.pick,
    required this.selectedEntity,
    required this.recognizedStlPlaneAvailable,
    required this.recognizedStlPlanePreview,
    required this.onCreateRecognizedPlane,
    required this.onOpenInspector,
    required this.onStatus,
    required this.onCompleted,
  });

  final CadRuntime runtime;
  final ContextualReferencePreviewSession preview;
  final PlaneAxisIntersectionSelectionController intersectionSelection;
  final AlignmentCoordinateSystemSelectionController
  alignmentCoordinateSystemSelection;
  final CadViewportPick? pick;
  final CadDocumentEntity? selectedEntity;
  final bool recognizedStlPlaneAvailable;
  final Map<String, Object?>? recognizedStlPlanePreview;
  final Future<void> Function() onCreateRecognizedPlane;
  final VoidCallback onOpenInspector;
  final ValueChanged<String> onStatus;
  final VoidCallback onCompleted;

  @override
  State<_ManagedCadReferencePanel> createState() =>
      _ManagedCadReferencePanelState();
}

class _ManagedCadReferencePanelState extends State<_ManagedCadReferencePanel> {
  bool busy = false;
  String? surfaceType;
  Map<String, Object?>? faceAnalytic;
  ContextualReferenceAction? draft;
  bool useCompactReferencePilot = true;
  String? referencePilotError;
  bool intersectionEditorOpen = false;
  String? lastIntersectionPreviewKey;
  bool alignmentCoordinateSystemEditorOpen = false;
  String? lastAlignmentCoordinateSystemPreviewKey;
  final manualOffset = TextEditingController(text: '10');
  final alignmentOriginX = TextEditingController();
  final alignmentOriginY = TextEditingController();
  final alignmentOriginZ = TextEditingController();
  bool syncingAlignmentOriginFields = false;

  ContextualReferencePreviewSession get preview => widget.preview;

  @override
  void initState() {
    super.initState();
    manualOffset.addListener(_refreshManualPlanePreview);
    alignmentOriginX.addListener(_manualAlignmentOriginChanged);
    alignmentOriginY.addListener(_manualAlignmentOriginChanged);
    alignmentOriginZ.addListener(_manualAlignmentOriginChanged);
    widget.intersectionSelection.addListener(_intersectionSelectionChanged);
    widget.alignmentCoordinateSystemSelection.addListener(
      _alignmentCoordinateSystemSelectionChanged,
    );
    _inspectFace();
  }

  CadDocumentEntity? get source {
    final pick = widget.pick;
    if (pick == null) return null;
    return widget.runtime.document?.entities[pick.entityId];
  }

  bool get canCreateFromFace {
    final entity = source;
    return widget.pick?.subentityKind == CadViewportSubentityKind.face &&
        (widget.pick?.presentationSubId ?? 0) > 0 &&
        entity?.data['deleted'] != true &&
        entity?.data['managedStlAssets'] == null &&
        (entity?.data['managedStepAssets'] is Map ||
            entity?.data['managedBrepAssets'] is Map);
  }

  @override
  void didUpdateWidget(covariant _ManagedCadReferencePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pick != widget.pick ||
        oldWidget.selectedEntity != widget.selectedEntity) {
      widget.intersectionSelection.clear();
      widget.alignmentCoordinateSystemSelection.clear();
      _cancelPreview();
      _inspectFace();
    }
  }

  @override
  void dispose() {
    manualOffset.removeListener(_refreshManualPlanePreview);
    widget.intersectionSelection.removeListener(_intersectionSelectionChanged);
    widget.alignmentCoordinateSystemSelection.removeListener(
      _alignmentCoordinateSystemSelectionChanged,
    );
    widget.intersectionSelection.clear();
    widget.alignmentCoordinateSystemSelection.clear();
    preview.cancel();
    manualOffset.dispose();
    alignmentOriginX.dispose();
    alignmentOriginY.dispose();
    alignmentOriginZ.dispose();
    super.dispose();
  }

  void _manualAlignmentOriginChanged() {
    if (syncingAlignmentOriginFields ||
        widget.alignmentCoordinateSystemSelection.originKind !=
            AlignmentCoordinateSystemOriginKind.manual) {
      return;
    }
    final x = parseAlignmentCoordinateMm(alignmentOriginX.text);
    final y = parseAlignmentCoordinateMm(alignmentOriginY.text);
    final z = parseAlignmentCoordinateMm(alignmentOriginZ.text);
    widget.alignmentCoordinateSystemSelection.setManualOrigin(
      x == null ||
              y == null ||
              z == null ||
              !x.isFinite ||
              !y.isFinite ||
              !z.isFinite
          ? null
          : Vector3(x, y, z),
      kind: AlignmentCoordinateSystemOriginKind.manual,
    );
  }

  void _synchronizeAlignmentOriginFields(Vector3 value) {
    syncingAlignmentOriginFields = true;
    alignmentOriginX.text = value.x.toStringAsFixed(3);
    alignmentOriginY.text = value.y.toStringAsFixed(3);
    alignmentOriginZ.text = value.z.toStringAsFixed(3);
    syncingAlignmentOriginFields = false;
  }

  void _showCapturedOriginMarker(Vector3 origin) {
    preview.show(
      CadSceneEntity(
        id: 'draft',
        kind: CadSceneEntityKind.point,
        geometry: {
          'type': 'point',
          'position': origin.toJson(),
          'markerRadius': 7.0,
          'displayColor': 'capturedOrigin',
        },
      ),
    );
  }

  void _intersectionSelectionChanged() {
    if (!mounted) return;
    referencePilotError = null;
    setState(() {});
    final planeId = widget.intersectionSelection.planeEntityId;
    final axisId = widget.intersectionSelection.axisEntityId;
    if (planeId == null || axisId == null) {
      lastIntersectionPreviewKey = null;
      preview.cancel();
      draft = null;
      return;
    }
    final key = '$planeId\u0000$axisId';
    if (lastIntersectionPreviewKey == key) return;
    lastIntersectionPreviewKey = key;
    unawaited(_previewPlaneAxisIntersection());
  }

  void _alignmentCoordinateSystemSelectionChanged() {
    if (!mounted) return;
    setState(() {});
    final planeId = widget.alignmentCoordinateSystemSelection.planeEntityId;
    final axisId = widget.alignmentCoordinateSystemSelection.axisEntityId;
    final pointId = widget.alignmentCoordinateSystemSelection.pointEntityId;
    final originKind = widget.alignmentCoordinateSystemSelection.originKind;
    final manualOrigin = widget.alignmentCoordinateSystemSelection.manualOrigin;
    if (originKind == AlignmentCoordinateSystemOriginKind.viewport &&
        manualOrigin != null) {
      _synchronizeAlignmentOriginFields(manualOrigin);
    }
    final originReady =
        originKind == AlignmentCoordinateSystemOriginKind.referencePoint
        ? pointId != null
        : manualOrigin != null;
    if (planeId == null || axisId == null || !originReady) {
      lastAlignmentCoordinateSystemPreviewKey = null;
      if (draft == ContextualReferenceAction.alignmentCoordinateSystem) {
        preview.cancel();
        draft = null;
      }
      if (originKind == AlignmentCoordinateSystemOriginKind.viewport &&
          manualOrigin != null) {
        _showCapturedOriginMarker(manualOrigin);
      }
      return;
    }
    final key =
        '$planeId\u0000$axisId\u0000${originKind.name}\u0000'
        '${pointId ?? manualOrigin?.toJson().join(',')}';
    if (lastAlignmentCoordinateSystemPreviewKey == key) return;
    lastAlignmentCoordinateSystemPreviewKey = key;
    unawaited(_previewAlignmentCoordinateSystem());
  }

  void _cancelPreview() {
    preview.cancel();
    if (mounted) setState(() => draft = null);
  }

  void _cancelCurrentPreview() {
    final intersection =
        draft == ContextualReferenceAction.planeAxisIntersectionPoint ||
        widget.intersectionSelection.active;
    if (intersection) {
      widget.intersectionSelection.clear();
      lastIntersectionPreviewKey = null;
    }
    final alignment =
        draft == ContextualReferenceAction.alignmentCoordinateSystem ||
        widget.alignmentCoordinateSystemSelection.active;
    if (alignment) {
      widget.alignmentCoordinateSystemSelection.clear();
      lastAlignmentCoordinateSystemPreviewKey = null;
    }
    _cancelPreview();
  }

  void _refreshManualPlanePreview() {
    if (draft != ContextualReferenceAction.manualPlane || !preview.active) {
      return;
    }
    _preview(
      ContextualReferenceAction.manualPlane,
      widget.selectedEntity ?? source,
    );
  }

  void _preview(ContextualReferenceAction action, CadDocumentEntity? entity) {
    final geometry = entity?.data['sceneGeometry'];
    final source = geometry is Map
        ? Map<String, dynamic>.from(geometry)
        : <String, dynamic>{};
    List<double>? vector(Object? raw) {
      if (raw is! List ||
          raw.length != 3 ||
          raw.any((value) => value is! num || !value.isFinite)) {
        return null;
      }
      return raw.map((value) => (value as num).toDouble()).toList();
    }

    try {
      final (kind, previewGeometry) = switch (action) {
        ContextualReferenceAction.plane => () {
          final analytic = entity?.data['managedStlAssets'] is Map
              ? widget.recognizedStlPlanePreview
              : faceAnalytic;
          final origin = vector(analytic?['origin']);
          final normal = vector(analytic?['normal']);
          if (origin == null || normal == null) {
            throw StateError(
              'A geometria analítica do plano não está disponível.',
            );
          }
          final normalVector = Vector3.fromJson(normal).normalized;
          final xDirection =
              vector(analytic?['xDirection']) ??
              normalVector
                  .cross(
                    normalVector.z.abs() < .9
                        ? const Vector3(0, 0, 1)
                        : const Vector3(0, 1, 0),
                  )
                  .normalized
                  .toJson();
          return (
            CadSceneEntityKind.plane,
            <String, Object>{
              'origin': origin,
              'normal': normal,
              'xDirection': xDirection,
              'visualSize': source['visualSize'] ?? 60.0,
              'displayColor': 'constructionPlane',
              if (analytic?['tolerance'] is num)
                'tolerance': analytic!['tolerance']!,
              if (analytic?['confidence'] is num)
                'confidence': analytic!['confidence']!,
            },
          );
        }(),
        ContextualReferenceAction.axis => () {
          final origin = vector(faceAnalytic?['origin']);
          final direction = vector(faceAnalytic?['direction']);
          final radius = faceAnalytic?['radius'];
          if (origin == null ||
              direction == null ||
              radius is! num ||
              !radius.isFinite ||
              radius <= 0) {
            throw StateError(
              'A geometria analítica do cilindro não está disponível.',
            );
          }
          return (
            CadSceneEntityKind.axis,
            <String, Object>{
              'origin': origin,
              'direction': direction,
              'radius': radius.toDouble(),
              'visualLength': source['visualLength'] ?? 40.0,
              'displayColor': 'constructionVector',
            },
          );
        }(),
        ContextualReferenceAction.manualPlane => () {
          final origin = vector(source['origin']) ?? const [0.0, 0.0, 0.0];
          final normal = vector(source['normal']) ?? const [0.0, 0.0, 1.0];
          final offset = double.tryParse(
            manualOffset.text.replaceAll(',', '.'),
          );
          if (entity?.data['sceneKind'] == 'plane' && offset == null) {
            throw const FormatException('Informe um offset numérico válido.');
          }
          final previewOrigin = entity?.data['sceneKind'] == 'plane'
              ? List<double>.generate(
                  3,
                  (index) => origin[index] + normal[index] * offset!,
                )
              : origin;
          return (
            CadSceneEntityKind.plane,
            <String, Object>{
              'origin': previewOrigin,
              'normal': normal,
              'xDirection':
                  vector(source['xDirection']) ?? const [1.0, 0.0, 0.0],
              'visualSize': source['visualSize'] ?? 60.0,
              'displayColor': 'constructionPlane',
            },
          );
        }(),
        ContextualReferenceAction.manualAxis => (
          CadSceneEntityKind.axis,
          <String, Object>{
            'origin': vector(source['origin']) ?? const [0.0, 0.0, 0.0],
            'direction': vector(source['direction']) ?? const [1.0, 0.0, 0.0],
            'visualLength': source['visualLength'] ?? 40.0,
            'displayColor': 'constructionVector',
          },
        ),
        ContextualReferenceAction.manualPoint => (
          CadSceneEntityKind.point,
          <String, Object>{
            'position':
                vector(source['position'] ?? source['origin']) ??
                const [0.0, 0.0, 0.0],
            'markerRadius': 5.0,
            'displayColor': 'constructionPoint',
          },
        ),
        ContextualReferenceAction.planeAxisIntersectionPoint =>
          throw StateError(
            'Use os campos de Plano + Eixo para calcular a prévia.',
          ),
        ContextualReferenceAction.alignmentCoordinateSystem => throw StateError(
          'Use os campos de Plano, Eixo/Vetor e Ponto para calcular a prévia.',
        ),
      };
      preview.show(
        CadSceneEntity(id: 'draft', kind: kind, geometry: previewGeometry),
      );
      setState(() => draft = action);
    } catch (error) {
      _cancelPreview();
      widget.onStatus(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _previewPlaneAxisIntersection() async {
    final planeId = widget.intersectionSelection.planeEntityId;
    final axisId = widget.intersectionSelection.axisEntityId;
    if (planeId == null || axisId == null || busy) return;
    setState(() {
      busy = true;
      referencePilotError = null;
    });
    try {
      final result = await widget.runtime.previewPlaneAxisIntersectionPoint(
        planeEntityId: planeId,
        axisEntityId: axisId,
      );
      preview.show(
        CadSceneEntity(
          id: 'draft',
          kind: CadSceneEntityKind.point,
          geometry: {
            'type': 'point',
            'position': result.point.toJson(),
            'markerRadius': 5.0,
            'displayColor': 'constructionPoint',
          },
        ),
      );
      if (mounted) {
        setState(
          () => draft = ContextualReferenceAction.planeAxisIntersectionPoint,
        );
      }
    } catch (error) {
      _cancelPreview();
      referencePilotError = error
          .toString()
          .replaceFirst('Bad state: ', '')
          .replaceFirst('FormatException: ', '');
      widget.onStatus(referencePilotError!);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _previewAlignmentCoordinateSystem() async {
    final planeId = widget.alignmentCoordinateSystemSelection.planeEntityId;
    final axisId = widget.alignmentCoordinateSystemSelection.axisEntityId;
    final pointId = widget.alignmentCoordinateSystemSelection.pointEntityId;
    final originKind = widget.alignmentCoordinateSystemSelection.originKind;
    final manualOrigin = widget.alignmentCoordinateSystemSelection.manualOrigin;
    if (planeId == null ||
        axisId == null ||
        (originKind == AlignmentCoordinateSystemOriginKind.referencePoint
            ? pointId == null
            : manualOrigin == null) ||
        busy) {
      return;
    }
    setState(() => busy = true);
    try {
      final result = await widget.runtime.previewAlignmentCoordinateSystem(
        planeEntityId: planeId,
        axisEntityId: axisId,
        pointEntityId: pointId,
        manualOrigin: manualOrigin,
        originKind: originKind,
      );
      preview.show(
        CadSceneEntity(
          id: 'draft',
          kind: CadSceneEntityKind.coordinateSystem,
          geometry: {
            'type': 'coordinateSystem',
            'origin': result.origin.toJson(),
            'xAxis': result.xAxis.toJson(),
            'yAxis': result.yAxis.toJson(),
            'zAxis': result.zAxis.toJson(),
            'visualLength': 30.0,
            'capturedOriginMarker':
                originKind == AlignmentCoordinateSystemOriginKind.viewport,
          },
        ),
      );
      if (mounted) {
        setState(
          () => draft = ContextualReferenceAction.alignmentCoordinateSystem,
        );
      }
    } catch (error) {
      _cancelPreview();
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

  Future<void> _inspectFace() async {
    final pick = widget.pick;
    if (pick == null || !canCreateFromFace) {
      if (mounted) {
        setState(() {
          surfaceType = null;
          faceAnalytic = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        surfaceType = null;
        faceAnalytic = null;
      });
    }
    final result = await widget.runtime.managedCadFaceAnalyticGeometry(
      sourceEntityId: pick.entityId,
      presentationTriangleId: pick.presentationSubId!,
    );
    if (mounted && widget.pick == pick) {
      setState(() {
        faceAnalytic = result;
        surfaceType = result?['surfaceType'] as String?;
      });
    }
  }

  Future<void> createPlane() async {
    if (!canCreateFromFace) return;
    setState(() => busy = true);
    try {
      final id = await widget.runtime.createManagedCadPlaneReference(
        sourceEntityId: widget.pick!.entityId,
        presentationTriangleId: widget.pick!.presentationSubId!,
      );
      widget.onCompleted();
      widget.onStatus('Plano de referência criado a partir da face B-Rep: $id');
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

  Future<void> createAxis() async {
    if (!canCreateFromFace) return;
    setState(() => busy = true);
    try {
      final id = await widget.runtime.createManagedCadCylinderAxisReference(
        sourceEntityId: widget.pick!.entityId,
        presentationTriangleId: widget.pick!.presentationSubId!,
      );
      widget.onCompleted();
      widget.onStatus('Eixo de referência criado a partir da face B-Rep: $id');
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

  Future<void> _applyDraft(CadDocumentEntity? entity) async {
    final action = draft;
    if (action == null || !preview.active || busy) return;
    setState(() => busy = true);
    try {
      Vector3 vectorOrZero(Object? raw) {
        if (raw is List &&
            raw.length == 3 &&
            raw.every((value) => value is num && value.isFinite)) {
          return Vector3(
            (raw[0] as num).toDouble(),
            (raw[1] as num).toDouble(),
            (raw[2] as num).toDouble(),
          );
        }
        return Vector3.zero;
      }

      final geometry = entity?.data['sceneGeometry'];
      final source = geometry is Map ? geometry : const <String, Object?>{};
      switch (action) {
        case ContextualReferenceAction.plane:
          if (entity?.data['managedStlAssets'] is Map) {
            await widget.onCreateRecognizedPlane();
          } else {
            await createPlane();
          }
        case ContextualReferenceAction.axis:
          await createAxis();
        case ContextualReferenceAction.manualPlane:
          await EntityPlaneService(widget.runtime).create(
            method: entity?.data['sceneKind'] == 'plane'
                ? ConstructionPlaneMethod.offset
                : ConstructionPlaneMethod.xy,
            sourceEntityIds: entity?.data['sceneKind'] == 'plane'
                ? [entity!.id]
                : const [],
            distance:
                double.tryParse(manualOffset.text.replaceAll(',', '.')) ?? 10,
          );
        case ContextualReferenceAction.manualAxis:
          await EntityVectorService(widget.runtime).create(
            method: ConstructionVectorMethod.components,
            origin: vectorOrZero(source['origin']),
            components: vectorOrZero(source['direction']).length <= 1e-12
                ? const Vector3(1, 0, 0)
                : vectorOrZero(source['direction']),
          );
        case ContextualReferenceAction.manualPoint:
          await EntityPointService(widget.runtime).create(
            method: ConstructionPointMethod.coordinates,
            coordinates: vectorOrZero(source['position'] ?? source['origin']),
          );
        case ContextualReferenceAction.planeAxisIntersectionPoint:
          final planeId = widget.intersectionSelection.planeEntityId;
          final axisId = widget.intersectionSelection.axisEntityId;
          if (planeId == null || axisId == null) {
            throw StateError('Selecione um plano e um eixo válidos.');
          }
          await widget.runtime.createPlaneAxisIntersectionPointReference(
            planeEntityId: planeId,
            axisEntityId: axisId,
          );
        case ContextualReferenceAction.alignmentCoordinateSystem:
          final planeId =
              widget.alignmentCoordinateSystemSelection.planeEntityId;
          final axisId = widget.alignmentCoordinateSystemSelection.axisEntityId;
          final pointId =
              widget.alignmentCoordinateSystemSelection.pointEntityId;
          final originKind =
              widget.alignmentCoordinateSystemSelection.originKind;
          final manualOrigin =
              widget.alignmentCoordinateSystemSelection.manualOrigin;
          if (planeId == null ||
              axisId == null ||
              (originKind == AlignmentCoordinateSystemOriginKind.referencePoint
                  ? pointId == null
                  : manualOrigin == null)) {
            throw StateError(
              'Selecione um plano, eixo/vetor e origem válidos.',
            );
          }
          await widget.runtime.createAlignmentCoordinateSystemReference(
            planeEntityId: planeId,
            axisEntityId: axisId,
            pointEntityId: pointId,
            manualOrigin: manualOrigin,
            originKind: originKind,
          );
      }
      if (draft == ContextualReferenceAction.planeAxisIntersectionPoint) {
        widget.intersectionSelection.clear();
        lastIntersectionPreviewKey = null;
      }
      if (draft == ContextualReferenceAction.alignmentCoordinateSystem) {
        widget.alignmentCoordinateSystemSelection.clear();
        lastAlignmentCoordinateSystemPreviewKey = null;
      }
      widget.onCompleted();
      preview.cancel();
      if (mounted) setState(() => draft = null);
    } catch (error) {
      preview.cancel();
      if (mounted) setState(() => draft = null);
      widget.onStatus(error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedReference =
        widget.selectedEntity != null &&
            widget.selectedEntity!.data['systemProtected'] != true &&
            ReferenceTreeTaxonomy.isProjectedReference(widget.selectedEntity!)
        ? widget.selectedEntity
        : null;
    final entity = widget.selectedEntity ?? source;
    final sourceName = entity?.data['name'] as String?;
    final plan = ContextualReferenceActions.plan(
      entity: entity,
      pick: widget.pick,
      managedFaceSurfaceType: surfaceType,
      recognizedStlPlaneAvailable: widget.recognizedStlPlaneAvailable,
    );
    final canPlane = plan.actions.contains(ContextualReferenceAction.plane);
    final canAxis = plan.actions.contains(ContextualReferenceAction.axis);
    final canManualPoint = plan.actions.contains(
      ContextualReferenceAction.manualPoint,
    );
    final canManualPlane = plan.actions.contains(
      ContextualReferenceAction.manualPlane,
    );
    final canManualAxis = plan.actions.contains(
      ContextualReferenceAction.manualAxis,
    );
    final canIntersectPlaneAxis = plan.actions.contains(
      ContextualReferenceAction.planeAxisIntersectionPoint,
    );
    final canCreateAlignmentCoordinateSystem = plan.actions.contains(
      ContextualReferenceAction.alignmentCoordinateSystem,
    );
    final planeCandidates = widget.runtime.planeIntersectionCandidates();
    final axisCandidates = widget.runtime.axisIntersectionCandidates();
    final pointCandidates = widget.runtime.pointReferenceCandidates();
    final intersectionPlaneId = widget.intersectionSelection.planeEntityId;
    final intersectionAxisId = widget.intersectionSelection.axisEntityId;
    final activeIntersectionSlot = widget.intersectionSelection.activeSlot;
    final alignmentPlaneId =
        widget.alignmentCoordinateSystemSelection.planeEntityId;
    final alignmentAxisId =
        widget.alignmentCoordinateSystemSelection.axisEntityId;
    final alignmentPointId =
        widget.alignmentCoordinateSystemSelection.pointEntityId;
    final alignmentOriginKind =
        widget.alignmentCoordinateSystemSelection.originKind;
    final alignmentManualOrigin =
        widget.alignmentCoordinateSystemSelection.manualOrigin;
    final activeAlignmentSlot =
        widget.alignmentCoordinateSystemSelection.activeSlot;
    String alignmentSlotLabel(AlignmentCoordinateSystemSlot slot) =>
        switch (slot) {
          AlignmentCoordinateSystemSlot.plane => 'Plano base',
          AlignmentCoordinateSystemSlot.axis => 'Eixo/Vetor de direção',
          AlignmentCoordinateSystemSlot.point => 'Ponto de origem',
          AlignmentCoordinateSystemSlot.viewportOrigin => 'Ponto na geometria',
        };
    final existingReference = selectedReference != null;
    final referencePilotPresentation =
        ReferenceContextPresentation.planeAxisIntersection(
          planeOptions: [
            for (final candidate in planeCandidates)
              ReferenceContextOption(
                id: candidate.id,
                label: candidate.data['name'] as String? ?? candidate.id,
              ),
          ],
          axisOptions: [
            for (final candidate in axisCandidates)
              ReferenceContextOption(
                id: candidate.id,
                label: candidate.data['name'] as String? ?? candidate.id,
              ),
          ],
          planeId: intersectionPlaneId,
          axisId: intersectionAxisId,
          activeSlot: activeIntersectionSlot?.name,
          previewActive:
              draft == ContextualReferenceAction.planeAxisIntersectionPoint &&
              preview.active,
          busy: busy,
          diagnostic: referencePilotError,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          existingReference ? 'Ações da referência' : 'Criar referência',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          sourceName == null
              ? 'Origem: ${plan.origin}'
              : 'Origem: ${plan.origin} — $sourceName',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        if (plan.showManualSection) ...[
          const Text(
            'Criar manualmente',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
        ],
        if (selectedReference case final reference?) ...[
          FilledButton.icon(
            onPressed: () async {
              final visible = reference.data['sceneVisible'] as bool? ?? true;
              await widget.runtime.setEntityVisibility(reference.id, !visible);
            },
            icon: Icon(
              (reference.data['sceneVisible'] as bool? ?? true)
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 18,
            ),
            label: Text(
              (reference.data['sceneVisible'] as bool? ?? true)
                  ? 'Ocultar'
                  : 'Mostrar',
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: widget.onOpenInspector,
            icon: const Icon(Icons.info_outline, size: 18),
            label: const Text('Abrir Inspector'),
          ),
        ],
        if (canManualPlane) ...[
          if (entity?.data['sceneKind'] == 'plane')
            TextField(
              controller: manualOffset,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Offset (mm)'),
            ),
          if (entity?.data['sceneKind'] == 'plane') const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () =>
                _preview(ContextualReferenceAction.manualPlane, entity),
            icon: const Icon(Icons.crop_square_outlined, size: 18),
            label: const Text('Plano manual'),
          ),
        ],
        if (canManualAxis) ...[
          OutlinedButton.icon(
            onPressed: () =>
                _preview(ContextualReferenceAction.manualAxis, entity),
            icon: const Icon(Icons.straighten, size: 18),
            label: const Text('Eixo manual'),
          ),
        ],
        if (canManualPoint) ...[
          OutlinedButton.icon(
            onPressed: () =>
                _preview(ContextualReferenceAction.manualPoint, entity),
            icon: const Icon(Icons.adjust, size: 18),
            label: const Text('Ponto manual'),
          ),
        ],
        if (canIntersectPlaneAxis) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              _cancelPreview();
              setState(() => intersectionEditorOpen = true);
            },
            icon: const Icon(Icons.control_point_duplicate_outlined, size: 18),
            label: const Text('Ponto por interseção Plano + Eixo'),
          ),
        ],
        if (canIntersectPlaneAxis &&
            intersectionEditorOpen &&
            useCompactReferencePilot) ...[
          ReferenceContextualPanel(
            presentation: referencePilotPresentation,
            onChoosePlane: (value) {
              _cancelPreview();
              referencePilotError = null;
              lastIntersectionPreviewKey = null;
              widget.intersectionSelection.choose(
                PlaneAxisIntersectionSlot.plane,
                value,
              );
            },
            onPickPlane: () {
              _cancelPreview();
              referencePilotError = null;
              lastIntersectionPreviewKey = null;
              widget.intersectionSelection.begin(
                PlaneAxisIntersectionSlot.plane,
              );
              widget.onStatus(
                'Clique em um plano de References ou WCS na viewport.',
              );
            },
            onChooseAxis: (value) {
              _cancelPreview();
              referencePilotError = null;
              lastIntersectionPreviewKey = null;
              widget.intersectionSelection.choose(
                PlaneAxisIntersectionSlot.axis,
                value,
              );
            },
            onPickAxis: () {
              _cancelPreview();
              referencePilotError = null;
              lastIntersectionPreviewKey = null;
              widget.intersectionSelection.begin(
                PlaneAxisIntersectionSlot.axis,
              );
              widget.onStatus(
                'Clique em um eixo de References ou WCS na viewport.',
              );
            },
            onPreview: _previewPlaneAxisIntersection,
            onApply: () => _applyDraft(entity),
            onCancel: _cancelCurrentPreview,
            onShowDetailed: () =>
                setState(() => useCompactReferencePilot = false),
          ),
        ],
        if (canIntersectPlaneAxis &&
            intersectionEditorOpen &&
            !useCompactReferencePilot) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => useCompactReferencePilot = true),
              child: const Text('Usar painel compacto'),
            ),
          ),
          if (activeIntersectionSlot != null) ...[
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'Seleção pela viewport ativa: '
                  '${activeIntersectionSlot == PlaneAxisIntersectionSlot.plane ? 'Plano' : 'Eixo'}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          DropdownButtonFormField<String>(
            initialValue: intersectionPlaneId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Plano'),
            hint: const Text('Selecione o plano'),
            items: [
              for (final candidate in planeCandidates)
                DropdownMenuItem(
                  value: candidate.id,
                  child: Text(
                    candidate.data['name'] as String? ?? candidate.id,
                  ),
                ),
            ],
            onChanged: busy
                ? null
                : (value) {
                    _cancelPreview();
                    lastIntersectionPreviewKey = null;
                    widget.intersectionSelection.choose(
                      PlaneAxisIntersectionSlot.plane,
                      value,
                    );
                  },
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () {
                    _cancelPreview();
                    lastIntersectionPreviewKey = null;
                    widget.intersectionSelection.begin(
                      PlaneAxisIntersectionSlot.plane,
                    );
                    widget.onStatus(
                      'Clique em um plano de References ou WCS na viewport.',
                    );
                  },
            icon: const Icon(Icons.ads_click_outlined, size: 18),
            label: Text(
              activeIntersectionSlot == PlaneAxisIntersectionSlot.plane
                  ? 'Selecionando Plano na viewport…'
                  : 'Selecionar Plano na viewport',
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: intersectionAxisId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Eixo'),
            hint: const Text('Selecione o eixo'),
            items: [
              for (final candidate in axisCandidates)
                DropdownMenuItem(
                  value: candidate.id,
                  child: Text(
                    candidate.data['name'] as String? ?? candidate.id,
                  ),
                ),
            ],
            onChanged: busy
                ? null
                : (value) {
                    _cancelPreview();
                    lastIntersectionPreviewKey = null;
                    widget.intersectionSelection.choose(
                      PlaneAxisIntersectionSlot.axis,
                      value,
                    );
                  },
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () {
                    _cancelPreview();
                    lastIntersectionPreviewKey = null;
                    widget.intersectionSelection.begin(
                      PlaneAxisIntersectionSlot.axis,
                    );
                    widget.onStatus(
                      'Clique em um eixo de References ou WCS na viewport.',
                    );
                  },
            icon: const Icon(Icons.ads_click_outlined, size: 18),
            label: Text(
              activeIntersectionSlot == PlaneAxisIntersectionSlot.axis
                  ? 'Selecionando Eixo na viewport…'
                  : 'Selecionar Eixo na viewport',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed:
                busy ||
                    intersectionPlaneId == null ||
                    intersectionAxisId == null
                ? null
                : _previewPlaneAxisIntersection,
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text('Atualizar Preview'),
          ),
        ],
        if (canCreateAlignmentCoordinateSystem) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              _cancelPreview();
              setState(() => alignmentCoordinateSystemEditorOpen = true);
            },
            icon: const Icon(Icons.account_tree_outlined, size: 18),
            label: const Text('Sistema de Coordenadas de Alinhamento'),
          ),
        ],
        if (canCreateAlignmentCoordinateSystem &&
            alignmentCoordinateSystemEditorOpen) ...[
          const SizedBox(height: 10),
          if (activeAlignmentSlot != null) ...[
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'Seleção pela viewport ativa: '
                  '${alignmentSlotLabel(activeAlignmentSlot)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          DropdownButtonFormField<String>(
            initialValue: alignmentPlaneId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Plano base (Z)'),
            hint: const Text('Selecione o plano'),
            items: [
              for (final candidate in planeCandidates)
                DropdownMenuItem(
                  value: candidate.id,
                  child: Text(
                    candidate.data['name'] as String? ?? candidate.id,
                  ),
                ),
            ],
            onChanged: busy
                ? null
                : (value) {
                    _cancelPreview();
                    lastAlignmentCoordinateSystemPreviewKey = null;
                    widget.alignmentCoordinateSystemSelection.choose(
                      AlignmentCoordinateSystemSlot.plane,
                      value,
                    );
                  },
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () {
                    _cancelPreview();
                    lastAlignmentCoordinateSystemPreviewKey = null;
                    widget.alignmentCoordinateSystemSelection.begin(
                      AlignmentCoordinateSystemSlot.plane,
                    );
                    widget.onStatus(
                      'Clique em um plano de References ou WCS na viewport.',
                    );
                  },
            icon: const Icon(Icons.ads_click_outlined, size: 18),
            label: Text(
              activeAlignmentSlot == AlignmentCoordinateSystemSlot.plane
                  ? 'Selecionando Plano base na viewport…'
                  : 'Selecionar Plano base na viewport',
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: alignmentAxisId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Eixo/Vetor de direção (Y)',
            ),
            hint: const Text('Selecione o eixo ou vetor'),
            items: [
              for (final candidate in axisCandidates)
                DropdownMenuItem(
                  value: candidate.id,
                  child: Text(
                    candidate.data['name'] as String? ?? candidate.id,
                  ),
                ),
            ],
            onChanged: busy
                ? null
                : (value) {
                    _cancelPreview();
                    lastAlignmentCoordinateSystemPreviewKey = null;
                    widget.alignmentCoordinateSystemSelection.choose(
                      AlignmentCoordinateSystemSlot.axis,
                      value,
                    );
                  },
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () {
                    _cancelPreview();
                    lastAlignmentCoordinateSystemPreviewKey = null;
                    widget.alignmentCoordinateSystemSelection.begin(
                      AlignmentCoordinateSystemSlot.axis,
                    );
                    widget.onStatus(
                      'Clique em um eixo/vetor de References ou WCS na viewport.',
                    );
                  },
            icon: const Icon(Icons.ads_click_outlined, size: 18),
            label: Text(
              activeAlignmentSlot == AlignmentCoordinateSystemSlot.axis
                  ? 'Selecionando Eixo/Vetor na viewport…'
                  : 'Selecionar Eixo/Vetor na viewport',
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Ponto de origem',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          SegmentedButton<AlignmentCoordinateSystemOriginKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: AlignmentCoordinateSystemOriginKind.referencePoint,
                label: Text('Referência'),
              ),
              ButtonSegment(
                value: AlignmentCoordinateSystemOriginKind.manual,
                label: Text('Coordenadas'),
              ),
              ButtonSegment(
                value: AlignmentCoordinateSystemOriginKind.viewport,
                label: Text('Viewport'),
              ),
            ],
            selected: {alignmentOriginKind},
            onSelectionChanged: busy
                ? null
                : (values) {
                    _cancelPreview();
                    lastAlignmentCoordinateSystemPreviewKey = null;
                    alignmentOriginX.clear();
                    alignmentOriginY.clear();
                    alignmentOriginZ.clear();
                    widget.alignmentCoordinateSystemSelection.chooseOriginKind(
                      values.single,
                    );
                  },
          ),
          const SizedBox(height: 8),
          if (alignmentOriginKind ==
              AlignmentCoordinateSystemOriginKind.referencePoint) ...[
            DropdownButtonFormField<String>(
              initialValue: alignmentPointId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Ponto de referência',
              ),
              hint: const Text('Selecione o ponto'),
              items: [
                for (final candidate in pointCandidates)
                  DropdownMenuItem(
                    value: candidate.id,
                    child: Text(
                      candidate.data['name'] as String? ?? candidate.id,
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      _cancelPreview();
                      lastAlignmentCoordinateSystemPreviewKey = null;
                      widget.alignmentCoordinateSystemSelection.choose(
                        AlignmentCoordinateSystemSlot.point,
                        value,
                      );
                    },
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () {
                      _cancelPreview();
                      lastAlignmentCoordinateSystemPreviewKey = null;
                      widget.alignmentCoordinateSystemSelection.begin(
                        AlignmentCoordinateSystemSlot.point,
                      );
                      widget.onStatus(
                        'Clique em um ponto de References ou WCS na viewport.',
                      );
                    },
              icon: const Icon(Icons.ads_click_outlined, size: 18),
              label: Text(
                activeAlignmentSlot == AlignmentCoordinateSystemSlot.point
                    ? 'Selecionando Ponto na viewport…'
                    : 'Selecionar Ponto na viewport',
              ),
            ),
          ] else ...[
            Row(
              children: [
                for (final entry in [
                  ('X', alignmentOriginX),
                  ('Y', alignmentOriginY),
                  ('Z', alignmentOriginZ),
                ]) ...[
                  Expanded(
                    child: TextField(
                      controller: entry.$2,
                      readOnly:
                          alignmentOriginKind ==
                          AlignmentCoordinateSystemOriginKind.viewport,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                      decoration: InputDecoration(
                        labelText: entry.$1,
                        suffixText: 'mm',
                      ),
                    ),
                  ),
                  if (entry.$1 != 'Z') const SizedBox(width: 6),
                ],
              ],
            ),
            if (alignmentOriginKind ==
                AlignmentCoordinateSystemOriginKind.viewport) ...[
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () {
                        _cancelPreview();
                        lastAlignmentCoordinateSystemPreviewKey = null;
                        widget.alignmentCoordinateSystemSelection.begin(
                          AlignmentCoordinateSystemSlot.viewportOrigin,
                        );
                        widget.onStatus(
                          'Clique sobre uma face CAD ou malha STL visível.',
                        );
                      },
                icon: const Icon(Icons.my_location_outlined, size: 18),
                label: Text(
                  activeAlignmentSlot ==
                          AlignmentCoordinateSystemSlot.viewportOrigin
                      ? 'Capturando ponto na viewport…'
                      : 'Selecionar ponto na viewport',
                ),
              ),
            ],
            if (alignmentManualOrigin != null) ...[
              const SizedBox(height: 6),
              Text(
                InspectorValueFormatter.coordinateMm(
                  alignmentManualOrigin.toJson(),
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed:
                busy ||
                    alignmentPlaneId == null ||
                    alignmentAxisId == null ||
                    (alignmentOriginKind ==
                            AlignmentCoordinateSystemOriginKind.referencePoint
                        ? alignmentPointId == null
                        : alignmentManualOrigin == null)
                ? null
                : _previewAlignmentCoordinateSystem,
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text('Atualizar Preview'),
          ),
        ],
        if (canManualPoint ||
            canManualPlane ||
            canManualAxis ||
            canIntersectPlaneAxis ||
            canCreateAlignmentCoordinateSystem)
          const SizedBox(height: 8),
        if (canPlane)
          FilledButton.icon(
            onPressed: !canPlane || busy
                ? null
                : () => _preview(ContextualReferenceAction.plane, entity),
            icon: busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.crop_square_outlined, size: 18),
            label: Text(
              entity?.data['managedStlAssets'] is Map
                  ? 'Plano por região STL'
                  : 'Plano por face planar',
            ),
          ),
        if (canAxis) const SizedBox(height: 8),
        if (canAxis)
          OutlinedButton.icon(
            onPressed: canAxis && !busy
                ? () => _preview(ContextualReferenceAction.axis, entity)
                : null,
            icon: const Icon(Icons.linear_scale, size: 18),
            label: const Text('Eixo por face cilíndrica'),
          ),
        if (preview.active) ...[
          const SizedBox(height: 12),
          const Text(
            'Prévia transitória — confirme para gravar uma única ação.',
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : () => _applyDraft(entity),
                  child: const Text('Apply'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: busy ? null : _cancelCurrentPreview,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
        if (!existingReference && plan.unavailable != null) ...[
          const SizedBox(height: 8),
          Text(plan.unavailable!, style: const TextStyle(fontSize: 10)),
        ],
        const SizedBox(height: 8),
        const Text(
          'A face é resolvida na topologia OCCT da shape original. Plano e '
          'eixo cilíndrico nunca usam triângulos da malha de apresentação.',
          style: TextStyle(fontSize: 10),
        ),
      ],
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
    required this.onFocusSuggestion,
    required this.onAutoHeal,
    required this.suggestionScrollController,
  });
  final OperationalReverseEngineeringController controller;
  final Future<void> Function() onExitSketch;
  final ValueChanged<SketchHealthIssue> onHealthIssue;
  final ValueChanged<SketchReconstructionSuggestion> onFocusSuggestion;
  final Future<void> Function(SketchHealthIssue) onAutoHeal;
  final ScrollController suggestionScrollController;

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

  Future<void> _confirmPointReferenceCapture(BuildContext context) async {
    if (!controller.sketchPointReferenceCaptureReady) return;
    final mode = controller.sketchPointReferenceCaptureMode;
    if (!const {
      'distance',
      'horizontalDistance',
      'verticalDistance',
      'angleBetweenLines',
      'parallelDistance',
      'ordinateX',
      'ordinateY',
    }.contains(mode)) {
      await controller.confirmSketchPointReferenceCapture();
      return;
    }
    final measured = controller.sketchPointReferenceMeasuredDistance;
    final input = TextEditingController(
      text: measured?.toStringAsFixed(3) ?? '',
    );
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          mode == 'angleBetweenLines'
              ? 'Cota angular entre linhas'
              : mode == 'parallelDistance'
              ? 'Distância entre linhas'
              : mode == 'ordinateX'
              ? 'Coordenada X'
              : mode == 'ordinateY'
              ? 'Coordenada Y'
              : 'Cota entre pontos',
        ),
        content: TextField(
          controller: input,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: mode == 'angleBetweenLines'
                ? 'Ângulo dirigido'
                : mode == 'parallelDistance'
                ? 'Distância perpendicular entre linhas'
                : mode == 'ordinateX' || mode == 'ordinateY'
                ? 'Coordenada global do Sketch'
                : 'Distância dirigida',
            suffixText: mode == 'angleBetweenLines' ? '°' : 'mm',
          ),
          onSubmitted: (text) => Navigator.pop(
            context,
            double.tryParse(text.replaceAll(',', '.')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              double.tryParse(input.text.replaceAll(',', '.')),
            ),
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
    input.dispose();
    if (value != null) {
      await controller.confirmSketchPointReferenceCapture(value: value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = controller.lineHud;
    final dragHud = controller.sketchDragHud;
    final jointAcceptancePreview = controller.sketchReconstructionJointPreview;
    final continuityRepairJoins =
        controller.sketchContinuityRepairAttentionJoins;
    final continuityRepairAllJoins = controller.sketchContinuityRepairAllJoins;
    final continuityRepairPreview = controller.sketchContinuityRepairPreview;
    final g1ContinuityRepairPreview =
        controller.sketchG1ContinuityRepairPreview;
    final health = controller.sketchHealth;
    final sketchOpenDiagnostic = controller.sketchOpenDiagnostic;
    final friendlyNames = _friendlySketchEntityNames(controller.sketchEntities);
    final blockingIssues = health.blockingIssues.toList(growable: false);
    final warningIssues = health.warningIssues.toList(growable: false);
    final openEndpoints = health
        .blockingOfType(SketchHealthIssueType.openEnd)
        .length;
    final looseIssue = health
        .ofType(SketchHealthIssueType.disconnected)
        .where((issue) => !issue.blocking)
        .firstOrNull;
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
        if (sketchOpenDiagnostic != null) ...[
          const SizedBox(height: 3),
          Text(
            sketchOpenDiagnostic,
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
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
            health.readyForSurface
                ? warningIssues.isEmpty
                      ? 'Active profile ready'
                      : 'Active profile ready with warnings'
                : 'Active profile has blocking errors',
            style: const TextStyle(fontSize: 9.5),
          ),
          children: [
            _SketchHealthCheck(
              label: controller.sketchEntities.isEmpty
                  ? 'Empty Sketch'
                  : health.closedProfile
                  ? 'Active profile closed'
                  : openEndpoints == 0
                  ? 'Active profile open'
                  : 'Active profile open · $openEndpoints open endpoint(s)',
              ok: health.closedProfile,
            ),
            _SketchHealthCheck(
              label: health.hasDuplicates
                  ? '${health.blockingIssues.where((i) => i.type == SketchHealthIssueType.duplicate || i.type == SketchHealthIssueType.overlap).length} duplicate/overlap issue(s) in active profile'
                  : '0 duplicates/overlaps in active profile',
              ok: !health.hasDuplicates,
            ),
            _SketchHealthCheck(
              label: health.hasGaps
                  ? '${health.blockingOfType(SketchHealthIssueType.gap).length} gap(s) in active profile'
                  : '0 gaps in active profile',
              ok: !health.hasGaps,
            ),
            _SketchHealthCheck(
              label: health.hasSelfIntersections
                  ? 'Self-intersection in active profile'
                  : '0 self-intersections',
              ok: !health.hasSelfIntersections,
            ),
            _SketchHealthCheck(
              label: looseIssue == null
                  ? '0 loose entities outside active profile'
                  : '${looseIssue.entityIds.length} loose entities outside active profile',
              ok: looseIssue == null,
              warning: looseIssue != null,
              onTap: looseIssue == null
                  ? null
                  : () => onHealthIssue(looseIssue),
            ),
            _SketchHealthCheck(
              label: health.hasTinyGeometry
                  ? 'Tiny geometry in active profile'
                  : '0 tiny geometry issues',
              ok: !health.hasTinyGeometry,
            ),
            if (blockingIssues.isNotEmpty)
              const _SketchHealthSectionLabel('Blocking issues'),
            for (final issue in blockingIssues.take(8))
              _SketchHealthIssueTile(
                issue: issue,
                friendlyNames: friendlyNames,
                onTap: () => issue.canAutoHeal
                    ? onAutoHeal(issue)
                    : onHealthIssue(issue),
                onAutoHeal: issue.canAutoHeal ? () => onAutoHeal(issue) : null,
              ),
            if (blockingIssues.length > 8)
              _SketchHealthOverflowLabel(blockingIssues.length - 8),
            if (warningIssues.isNotEmpty)
              const _SketchHealthSectionLabel('Sketch warnings'),
            for (final issue in warningIssues.take(5))
              _SketchHealthIssueTile(
                issue: issue,
                friendlyNames: friendlyNames,
                onTap: () => onHealthIssue(issue),
              ),
            if (warningIssues.length > 5)
              _SketchHealthOverflowLabel(warningIssues.length - 5),
            for (final issue in const <SketchHealthIssue>[])
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
            if (!controller.sketchCreationCommandActive)
              if (controller.selectedSketchEntityIds.singleOrNull
                  case final selectedLineId?)
                if (controller.sketchApi?.entity(selectedLineId)
                    case SketchLine(construction: false)) ...[
                  const SizedBox(height: 6),
                  FilledButton.tonalIcon(
                    onPressed: controller.convertSelectedLineToConstruction,
                    icon: const Icon(Icons.linear_scale, size: 17),
                    label: const Text('Usar linha como eixo de construção'),
                  ),
                ],
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
                      controller.lineCommandActive &&
                              !controller.polylineCommandActive
                          ? 'Line · ativo'
                          : 'Line',
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
            if (controller.lineCommandActive &&
                !controller.polylineCommandActive)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Botão direito inicia outra linha sem sair do comando. Esc encerra a ferramenta.',
                  style: TextStyle(fontSize: 10),
                ),
              ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: controller.polylineCommandActive
                    ? null
                    : controller.beginPolylineCommand,
                icon: const Icon(Icons.polyline, size: 17),
                label: Text(
                  controller.polylineCommandActive
                      ? 'Polilinha: clique nos vértices'
                      : 'Polilinha',
                ),
              ),
            ),
            if (controller.polylineCommandActive) ...[
              const SizedBox(height: 5),
              Text(
                'Clique no primeiro vértice para fechar; botão direito ou Concluir mantém aberta. Esc cancela.',
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: controller.previewPoints.length >= 2
                          ? controller.finishPolylineCommand
                          : null,
                      child: const Text('Concluir'),
                    ),
                  ),
                  TextButton(
                    onPressed: controller.cancelSketchCommand,
                    child: const Text('Cancelar'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: controller.splineCommandActive
                    ? null
                    : controller.beginSplineCommand,
                icon: const Icon(Icons.show_chart, size: 17),
                label: Text(
                  controller.splineCommandActive
                      ? 'Spline: clique nos pontos da curva'
                      : 'Spline interpolada',
                ),
              ),
            ),
            if (controller.splineCommandActive) ...[
              const SizedBox(height: 5),
              Text(
                'A curva passa pelos pontos clicados. Após três pontos, botão direito ou Concluir finaliza; Esc cancela.',
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: controller.previewPoints.length >= 3
                          ? controller.finishSplineCommand
                          : null,
                      child: const Text('Concluir spline'),
                    ),
                  ),
                  TextButton(
                    onPressed: controller.cancelSplineCommand,
                    child: const Text('Cancelar'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: controller.sketchTangentBlendActive
                    ? null
                    : controller.beginSketchTangentBlend,
                icon: const Icon(Icons.multiline_chart, size: 17),
                label: Text(
                  controller.sketchTangentBlendActive
                      ? 'Blend tangente: escolha duas extremidades'
                      : 'Blend tangente',
                ),
              ),
            ),
            if (controller.sketchTangentBlendActive) ...[
              const SizedBox(height: 5),
              Text(
                controller.sketchBlendCaptureHint,
                style: TextStyle(fontSize: 10),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('sketch-tangent-blend-first-length'),
                      initialValue: controller.sketchBlendFirstTangentLength
                          .toString(),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Comprimento ponta 1',
                        suffixText: 'mm',
                      ),
                      onChanged: (text) {
                        final value = double.tryParse(
                          text.replaceAll(',', '.'),
                        );
                        if (value != null) {
                          controller.setSketchBlendTangentLength(
                            firstEndpoint: true,
                            value: value,
                          );
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('sketch-tangent-blend-second-length'),
                      initialValue: controller.sketchBlendSecondTangentLength
                          .toString(),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Comprimento ponta 2',
                        suffixText: 'mm',
                      ),
                      onChanged: (text) {
                        final value = double.tryParse(
                          text.replaceAll(',', '.'),
                        );
                        if (value != null) {
                          controller.setSketchBlendTangentLength(
                            firstEndpoint: false,
                            value: value,
                          );
                        }
                      },
                    ),
                  ),
                ],
              ),
              if (controller.sketchEditingDiagnostic case final diagnostic?)
                Text(
                  diagnostic,
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed:
                          controller.sketchBlendFirstEndpoint != null &&
                              controller.sketchBlendSecondEndpoint != null
                          ? () async {
                              try {
                                await controller.commitSketchCorner();
                              } catch (failure) {
                                if (context.mounted) {
                                  ScaffoldMessenger.maybeOf(
                                    context,
                                  )?.showSnackBar(
                                    SnackBar(content: Text('$failure')),
                                  );
                                }
                              }
                            }
                          : null,
                      child: const Text('Confirmar Blend'),
                    ),
                  ),
                  TextButton(
                    onPressed: controller.finishSketchEditingTool,
                    child: const Text('Cancelar'),
                  ),
                ],
              ),
            ],
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
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: controller.rectangleCommandActive
                    ? controller.enterSketchSelectionMode
                    : controller.beginRectangleCommand,
                icon: const Icon(Icons.rectangle_outlined, size: 17),
                label: Text(
                  controller.rectangleCommandActive
                      ? 'Drawing Rectangle'
                      : 'Rectangle · Two Corners',
                ),
              ),
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
        if (controller.sketchCreationCommandActive &&
            !controller.splineCommandActive)
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
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: controller.activeSketch == null
                  ? null
                  : controller.analyzeSketchReconstruction,
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: const Text('Reconhecer geometria'),
            ),
            const SizedBox(height: 5),
            OutlinedButton.icon(
              onPressed: controller.beginSketchCircularSelection,
              icon: Icon(
                controller.sketchCircularSelectionMode
                    ? Icons.check_box
                    : Icons.control_point_duplicate_outlined,
                size: 16,
              ),
              label: Text(
                controller.sketchCircularSelectionMode
                    ? 'Seleção múltipla ativa · clique nas curvas'
                    : 'Selecionar várias curvas (Ctrl)',
              ),
            ),
            OutlinedButton.icon(
              onPressed:
                  controller.selectedSketchEntityIds.isNotEmpty &&
                      controller.selectedSketchEntityIds.length <=
                          controller.sketchCircularMaxRegions
                  ? controller.fitSelectedSketchCircularGeometry
                  : null,
              icon: const Icon(Icons.circle_outlined, size: 16),
              label: const Text('Ajustar círculo/arco pelas linhas'),
            ),
            const SizedBox(height: 5),
            SegmentedButton<SketchRegionFitOutput>(
              segments: const [
                ButtonSegment(
                  value: SketchRegionFitOutput.line,
                  label: Text('Linha'),
                ),
                ButtonSegment(
                  value: SketchRegionFitOutput.spline,
                  label: Text('Spline'),
                ),
              ],
              selected: {controller.sketchRegionFitOutput},
              onSelectionChanged: (values) =>
                  controller.setSketchRegionFitOutput(values.single),
            ),
            OutlinedButton.icon(
              onPressed:
                  controller.sketchCircularSelectionMode &&
                      controller.selectedSketchEntityIds.isNotEmpty
                  ? controller.fitSelectedSketchLineOrSpline
                  : null,
              icon: const Icon(Icons.linear_scale, size: 16),
              label: const Text('Ajustar linha/spline'),
            ),
            if (controller.activeSketchSourceSection != null)
              OutlinedButton.icon(
                onPressed: controller.toggleOriginalSectionReferenceVisibility,
                icon: Icon(
                  controller.originalSectionReferenceVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 16,
                ),
                label: Text(
                  controller.originalSectionReferenceVisible
                      ? 'Ocultar seÃ§Ã£o original'
                      : 'Mostrar seÃ§Ã£o original',
                ),
              ),
            if (controller.sketchRegionFitMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Text(
                  controller.sketchRegionFitMessage!,
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            if (controller.sketchRegionFitComparison case final comparison?)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                child: Text(
                  'Comparação visual (não paramétrica) · RMS ${comparison.rms.toStringAsFixed(3)} mm · média ${comparison.mean.toStringAsFixed(3)} mm · máx ${comparison.maximum.toStringAsFixed(3)} mm · pares ${comparison.deviations.take(4).map((pair) => math.sqrt((pair.source - pair.fitted).dot(pair.source - pair.fitted)).toStringAsFixed(3)).join(', ')}${comparison.deviations.length > 4 ? '…' : ''}',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            const SizedBox(height: 5),
            _SketchTangencyReferences(controller: controller),
            if (controller.sketchCircularFitMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Text(
                  controller.sketchCircularFitMessage!,
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            if (controller.sketchReconstructionMessage case final message?)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 10,
                    color: controller.error == message
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            if (continuityRepairAllJoins.isNotEmpty ||
                controller.selectedSketchContinuityJoin != null ||
                continuityRepairPreview != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                  child: SketchContinuityRepairPanel(
                    controller: controller,
                    joins: continuityRepairJoins,
                    allJoins: continuityRepairAllJoins,
                    preview: continuityRepairPreview,
                    g1Preview: g1ContinuityRepairPreview,
                  ),
                ),
              ),
            if (controller.sketchReconstructionSuggestions.isNotEmpty) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${controller.sketchReconstructionSuggestions.length} sugestões encontradas',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
              OutlinedButton.icon(
                key: const ValueKey('sketch-reconstruction-accept-selected'),
                onPressed:
                    controller.canPreviewSketchReconstructionJointAcceptance &&
                        jointAcceptancePreview == null
                    ? controller.previewSketchReconstructionAcceptance
                    : null,
                icon: const Icon(Icons.preview_outlined, size: 16),
                label: const Text('Aceitar selecionadas'),
              ),
              SketchReconstructionSuggestionGroups(
                controller: controller,
                onFocusSuggestion: onFocusSuggestion,
                scrollController: suggestionScrollController,
              ),
              if (controller.sketchReconstructionSelectionAnalysis
                  case final analysis?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 3, 8, 0),
                  child: Text(
                    'Seleção: ${analysis.summary}${analysis.diagnostics.isEmpty ? '' : ' · ${analysis.diagnostics.join(' · ')}'}',
                    style: const TextStyle(fontSize: 9),
                  ),
                ),
              if (jointAcceptancePreview case final preview?)
                SketchReconstructionJointPreviewPanel(
                  controller: controller,
                  preview: preview,
                ),
              TextButton(
                onPressed: controller.clearSketchReconstructionSuggestions,
                child: const Text('Limpar sugestões'),
              ),
            ],
          ],
        ),
        ExpansionTile(
          initiallyExpanded:
              controller.sketchEditingCommandActive &&
              !controller.sketchTangentBlendActive,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          leading: const Icon(Icons.edit_outlined, size: 17),
          title: const Text('Modify'),
          subtitle:
              controller.sketchEditingCommandActive &&
                  !controller.sketchTangentBlendActive
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
                          controller.activeTool == item.$3 &&
                          !controller.sketchTangentBlendActive,
                      onPressed: () =>
                          controller.beginSketchEditingTool(item.$3),
                      icon: Icon(item.$2, size: 17),
                    ),
                  ),
              ],
            ),
            if (controller.sketchEditingCommandActive &&
                !controller.sketchTangentBlendActive &&
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
              if (controller.sketchEditingDiagnostic case final diagnostic?)
                Text(
                  diagnostic,
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.error,
                  ),
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
            if (controller.sketchEditingCommandActive &&
                !controller.sketchTangentBlendActive)
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
                    'Collinear',
                    Icons.align_horizontal_left,
                    SketchConstraintType.collinear,
                  ),
                  (
                    'Concentric',
                    Icons.radio_button_checked,
                    SketchConstraintType.concentric,
                  ),
                  ('Equal', Icons.drag_handle, SketchConstraintType.equal),
                  ('Tangent', Icons.gesture, SketchConstraintType.tangent),
                  ('Fix', Icons.lock_outline, SketchConstraintType.fixed),
                ])
                  Tooltip(
                    message: item.$1,
                    child: OutlinedButton.icon(
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
                      icon: Icon(item.$2, size: 16),
                      label: Text(
                        item.$1,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                OutlinedButton.icon(
                  onPressed: () =>
                      controller.beginSketchPointReferenceCapture('coincident'),
                  icon: const Icon(Icons.adjust, size: 16),
                  label: const Text('Coincidir pontos'),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      controller.beginSketchPointReferenceCapture('midpoint'),
                  icon: const Icon(Icons.center_focus_strong, size: 16),
                  label: const Text('Ponto médio'),
                ),
                OutlinedButton.icon(
                  onPressed: () => controller.beginSketchPointReferenceCapture(
                    'pointOnLine',
                  ),
                  icon: const Icon(Icons.linear_scale, size: 16),
                  label: const Text('Ponto na linha'),
                ),
              ],
            ),
            if (controller.sketchPointReferenceCaptureActive &&
                controller.sketchPointReferenceCaptureMode != 'distance')
              Card(
                margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        controller.sketchPointReferenceCaptureHint,
                        style: const TextStyle(fontSize: 10),
                      ),
                      if (controller.sketchPointReferenceCaptureDiagnostic
                          case final diagnostic?)
                        Text(
                          diagnostic,
                          style: TextStyle(
                            fontSize: 9.5,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed:
                                  controller.sketchPointReferenceCaptureReady
                                  ? () => _confirmPointReferenceCapture(context)
                                  : null,
                              child: const Text('Aplicar'),
                            ),
                          ),
                          TextButton(
                            onPressed:
                                controller.cancelSketchPointReferenceCapture,
                            child: const Text('Cancelar'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 7, 10, 0),
              child: Text(
                'Equal/Tangent: select the reference first and the target with Ctrl. '
                'Fix: select exactly one entity.',
                style: TextStyle(fontSize: 9.5),
              ),
            ),
          ],
        ),
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: const Icon(Icons.straighten_outlined, size: 17),
          title: const Text('Dimensions / Cotas'),
          subtitle: Text(
            dimensionEntity is SketchLine
                ? 'Linha selecionada · Linear define seu comprimento'
                : dimensionEntity is SketchCircle ||
                      dimensionEntity is SketchArc
                ? 'Curva selecionada · use Raio ou Diâmetro'
                : '${controller.dimensions.length} dirigidas · selecione uma entidade',
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
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () =>
                  controller.beginSketchPointReferenceCapture('distance'),
              icon: const Icon(Icons.social_distance, size: 16),
              label: const Text('Linear entre dois pontos'),
            ),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                OutlinedButton(
                  onPressed: () => controller.beginSketchPointReferenceCapture(
                    'horizontalDistance',
                  ),
                  child: const Text('Horizontal entre pontos'),
                ),
                OutlinedButton(
                  onPressed: () => controller.beginSketchPointReferenceCapture(
                    'verticalDistance',
                  ),
                  child: const Text('Vertical entre pontos'),
                ),
                OutlinedButton(
                  onPressed: () => controller.beginSketchPointReferenceCapture(
                    'angleBetweenLines',
                  ),
                  child: const Text('Ângulo entre linhas'),
                ),
                OutlinedButton(
                  onPressed: () => controller.beginSketchPointReferenceCapture(
                    'parallelDistance',
                  ),
                  child: const Text('Distância entre linhas'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      controller.beginSketchPointReferenceCapture('ordinateX'),
                  child: const Text('Coordenada X'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      controller.beginSketchPointReferenceCapture('ordinateY'),
                  child: const Text('Coordenada Y'),
                ),
              ],
            ),
            if (controller.sketchPointReferenceCaptureActive &&
                const {
                  'distance',
                  'horizontalDistance',
                  'verticalDistance',
                  'angleBetweenLines',
                  'parallelDistance',
                  'ordinateX',
                  'ordinateY',
                }.contains(controller.sketchPointReferenceCaptureMode))
              Card(
                margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        controller.sketchPointReferenceCaptureHint,
                        style: const TextStyle(fontSize: 10),
                      ),
                      if (controller.sketchPointReferenceMeasuredDistance
                          case final measured?)
                        Text(
                          controller.sketchPointReferenceCaptureMode ==
                                  'angleBetweenLines'
                              ? 'Atual: ${measured.toStringAsFixed(3)}°'
                              : 'Atual: ${measured.toStringAsFixed(3)} mm',
                          style: const TextStyle(fontSize: 9.5),
                        ),
                      if (controller.sketchPointReferenceCaptureDiagnostic
                          case final diagnostic?)
                        Text(
                          diagnostic,
                          style: TextStyle(
                            fontSize: 9.5,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed:
                                  controller.sketchPointReferenceCaptureReady
                                  ? () => _confirmPointReferenceCapture(context)
                                  : null,
                              child: const Text('Definir cota'),
                            ),
                          ),
                          TextButton(
                            onPressed:
                                controller.cancelSketchPointReferenceCapture,
                            child: const Text('Cancelar'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 7, 10, 3),
              child: Text(
                'Cota linear: selecione uma única linha na viewport, clique em '
                'Linear e informe o comprimento em mm.',
                style: TextStyle(fontSize: 9.5),
              ),
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
                ? controller.surfaceCadCreationAvailable
                      ? 'Preview approved · ready to create'
                      : controller.surfaceCadCreationBlockReason
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
  const _SketchHealthCheck({
    required this.label,
    required this.ok,
    this.warning = false,
    this.onTap,
  });
  final String label;
  final bool ok;
  final bool warning;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = ok
        ? Colors.green
        : warning
        ? Colors.amber
        : Colors.redAccent;
    final icon = ok
        ? Icons.check_circle_outline
        : warning
        ? Icons.warning_amber_outlined
        : Icons.cancel_outlined;
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 10))),
        ],
      ),
    );
    if (onTap == null) return child;
    return InkWell(onTap: onTap, child: child);
  }
}

class _SketchHealthSectionLabel extends StatelessWidget {
  const _SketchHealthSectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

class _SketchHealthOverflowLabel extends StatelessWidget {
  const _SketchHealthOverflowLabel(this.count);
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(30, 0, 8, 4),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        '+$count more item(s)',
        style: TextStyle(
          fontSize: 9,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

class _ArcRadiusEditPreviewPanel extends StatelessWidget {
  const _ArcRadiusEditPreviewPanel({required this.controller});

  final OperationalReverseEngineeringController controller;

  @override
  Widget build(BuildContext context) {
    final preview = controller.arcRadiusEditPreview;
    if (preview == null) return const SizedBox.shrink();
    final plan = preview.plan;
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('arc-radius-edit-preview'),
      color: theme.colorScheme.primaryContainer.withValues(alpha: .55),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Preview de edicao do raio',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Atual: ${plan.previousRadius?.toStringAsFixed(3)} mm  ->  '
              'Novo: ${plan.requestedRadius?.toStringAsFixed(3)} mm',
              style: const TextStyle(fontSize: 10.5),
            ),
            Text(
              'Afetadas: ${plan.affectedEntityIds.join(', ')}\n'
              'Deslocamento max.: ${plan.maxEndpointDisplacement.toStringAsFixed(4)} mm\n'
              'Residuos C0/G1: ${plan.maxCoincidenceResidual.toStringAsExponential(2)} / '
              '${plan.maxTangencyResidual.toStringAsExponential(2)}',
              style: const TextStyle(fontSize: 10),
            ),
            const SizedBox(height: 3),
            const Text(
              'Preview transitorio; nao e uma constraint parametrica.',
              style: TextStyle(fontSize: 9.5),
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('arc-radius-preview-confirm'),
                    onPressed: controller.busy
                        ? null
                        : controller.confirmArcRadiusEditPreview,
                    icon: const Icon(Icons.check, size: 15),
                    label: const Text('Confirmar'),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('arc-radius-preview-cancel'),
                    onPressed: controller.busy
                        ? null
                        : controller.cancelArcRadiusEditPreview,
                    icon: const Icon(Icons.close, size: 15),
                    label: const Text('Cancelar'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SketchHealthIssueTile extends StatelessWidget {
  const _SketchHealthIssueTile({
    required this.issue,
    required this.friendlyNames,
    required this.onTap,
    this.onAutoHeal,
  });

  final SketchHealthIssue issue;
  final Map<String, String> friendlyNames;
  final VoidCallback onTap;
  final VoidCallback? onAutoHeal;

  @override
  Widget build(BuildContext context) {
    final warning = !issue.blocking;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(
        warning ? Icons.warning_amber_outlined : Icons.error_outline,
        size: 15,
        color: warning ? Colors.amber : Colors.redAccent,
      ),
      title: Text(issue.message, style: const TextStyle(fontSize: 10.5)),
      subtitle: Text(
        _friendlyIssueEntities(issue, friendlyNames),
        style: const TextStyle(fontSize: 9),
      ),
      onTap: onTap,
      trailing: onAutoHeal == null
          ? TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              icon: const Icon(Icons.ads_click, size: 14),
              label: Text(
                issue.type == SketchHealthIssueType.disconnected
                    ? 'Select'
                    : 'Focus',
                style: const TextStyle(fontSize: 9.5),
              ),
              onPressed: onTap,
            )
          : TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              icon: const Icon(Icons.healing, size: 15),
              label: const Text('Close gap', style: TextStyle(fontSize: 9.5)),
              onPressed: onAutoHeal,
            ),
    );
  }
}

Map<String, String> _friendlySketchEntityNames(
  Iterable<SketchEntity> entities,
) {
  final counters = <SketchEntityType, int>{};
  final names = <String, String>{};
  for (final entity in entities) {
    final next = (counters[entity.type] ?? 0) + 1;
    counters[entity.type] = next;
    names[entity.id] =
        '${_friendlySketchEntityPrefix(entity)}'
        '${next.toString().padLeft(3, '0')}';
  }
  return names;
}

String _friendlySketchEntityPrefix(SketchEntity entity) => switch (entity) {
  SketchLine() => 'Line',
  SketchCircle() => 'Circle',
  SketchArc() => 'Arc',
  SketchSpline() => 'Spline',
  SketchPoint() => 'Point',
  SketchEllipse() => 'Ellipse',
  ConstructionGeometry() => 'Construction',
  ReferenceGeometry() => 'Reference',
  _ => 'Entity',
};

String _friendlyIssueEntities(
  SketchHealthIssue issue,
  Map<String, String> friendlyNames,
) {
  if (issue.entityIds.isEmpty) return 'No entities';
  final labels = [for (final id in issue.entityIds) ?friendlyNames[id]];
  if (labels.isEmpty) return '${issue.entityIds.length} sketch entity(s)';
  final shown = labels.take(4).join(' - ');
  final remaining = issue.entityIds.length - labels.take(4).length;
  return remaining <= 0 ? shown : '$shown - +$remaining';
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
        child: Wrap(
          spacing: 4,
          runSpacing: 2,
          children: [
            Text('X ${value.x.toStringAsFixed(3)}'),
            const SizedBox(width: 12),
            Text('Y ${value.y.toStringAsFixed(3)}'),
            const SizedBox(width: 12),
            Text('ΔX ${value.dx.toStringAsFixed(3)}'),
            const SizedBox(width: 12),
            Text('ΔY ${value.dy.toStringAsFixed(3)}'),
            const SizedBox(width: 12),
            Text('L ${value.length.toStringAsFixed(3)}'),
            const SizedBox(width: 12),
            Text('∠ ${value.angle.toStringAsFixed(2)}°'),
            if (controller.sketchMagnetX != null ||
                controller.sketchMagnetY != null) ...[
              const SizedBox(width: 12),
              Text(
                'TRAVADO ${[if (controller.sketchMagnetX case final x?) 'X=${x.toStringAsFixed(3)}', if (controller.sketchMagnetY case final y?) 'Y=${y.toStringAsFixed(3)}'].join('  ')} mm',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
            if (controller.activeSketchInference case final inference?) ...[
              const SizedBox(width: 12),
              Text(
                inference.type.name.toUpperCase(),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ] else if (controller.lineSnapType case final snap?) ...[
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
    this.scrollController,
    this.panelKey,
  });
  final String title;
  final Widget child;
  final Future<void> Function()? onClose;
  final ScrollController? scrollController;
  final Key? panelKey;

  @override
  State<_ProfessionalToolWindow> createState() =>
      _ProfessionalToolWindowState();
}

/// Builds the real floating tool-window layout for composition tests.
///
/// The application uses the private stateful widget directly; this narrow
/// entry point lets a widget test verify that the viewport and overlay coexist
/// under finite constraints without constructing the CAD runtime.
Widget buildProfessionalToolWindowForTesting({
  required String title,
  required Widget child,
  Key? key,
  Key? panelKey,
}) => _ProfessionalToolWindow(
  key: key,
  title: title,
  panelKey: panelKey,
  child: child,
);

class _ProfessionalToolWindowState extends State<_ProfessionalToolWindow> {
  Offset position = const Offset(168, 56);
  late Size windowSize;
  bool _placementScheduled = false;
  bool _initialPlacementDone = false;
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
  }

  void _schedulePlacementGuard(Size viewport, Size boundedWindowSize) {
    assert(() {
      debugPrint(
        '[ux-g1-layout] tool=${widget.title} '
        'viewport=${viewport.width}x${viewport.height} '
        'panel=${boundedWindowSize.width}x${boundedWindowSize.height} '
        'offset=${position.dx},${position.dy} docked=$docked visible=$visible',
      );
      return true;
    }());
    if (_placementScheduled) return;
    _placementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _placementScheduled = false;
      if (!mounted || docked) return;
      final next = _initialPlacementDone
          ? ToolWindowLayout.clampPosition(
              position: position,
              viewport: viewport,
              window: boundedWindowSize,
            )
          : ToolWindowLayout.initialPosition(
              viewport: viewport,
              window: boundedWindowSize,
            );
      if (next == position && _initialPlacementDone) return;
      setState(() {
        position = next;
        _initialPlacementDone = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        final boundedWindowSize = ToolWindowLayout.constrainSize(
          requested: windowSize,
          viewport: viewport,
        );
        _schedulePlacementGuard(viewport, boundedWindowSize);
        return Stack(
          fit: StackFit.expand,
          children: [
            if (!visible)
              Positioned(
                left: 8,
                top: 8,
                child: ActionChip(
                  avatar: const Icon(Icons.build_outlined, size: 14),
                  label: Text(widget.title),
                  onPressed: () => setState(() => visible = true),
                ),
              )
            else
              Positioned(
                left: docked ? 0 : position.dx,
                top: docked ? 0 : position.dy,
                bottom: docked ? 0 : null,
                width: boundedWindowSize.width,
                height: docked ? null : boundedWindowSize.height,
                child: Material(
                  key: widget.panelKey,
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
                                      math.max(
                                        0,
                                        position.dx + details.delta.dx,
                                      ),
                                      math.max(
                                        0,
                                        position.dy + details.delta.dy,
                                      ),
                                    );
                                  }),
                            child: Container(
                              height: 34,
                              padding: const EdgeInsets.only(
                                left: 10,
                                right: 2,
                              ),
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
                                    tooltip: docked
                                        ? 'Float window'
                                        : 'Dock window',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () =>
                                        setState(() => docked = !docked),
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
                                      if (mounted) {
                                        setState(() => visible = false);
                                      }
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
                              controller: widget.scrollController,
                              padding: const EdgeInsets.all(10),
                              child: widget.child,
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
                              windowSize = ToolWindowLayout.resize(
                                current: windowSize,
                                delta: details.delta,
                                viewport: viewport,
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
              ),
          ],
        );
      },
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
  RevolveOutput revolveOutput = RevolveOutput.solid;
  ProfessionalExtrudeExtent extent = ProfessionalExtrudeExtent.distance;
  bool extrudeCommandActive = false;
  bool revolveCommandActive = false;
  Timer? _previewUpdateDebounce;

  void _schedulePreviewUpdate(Future<void> Function() update) {
    _previewUpdateDebounce?.cancel();
    _previewUpdateDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted && !widget.controller.busy) unawaited(update());
    });
  }

  @override
  void dispose() {
    _previewUpdateDebounce?.cancel();
    super.dispose();
  }

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
                  ? 'Selecione um Sketch ou uma superfície para iniciar o Extrude.'
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
                  : () => setState(() {
                      extrudeCommandActive = true;
                      revolveCommandActive = false;
                    }),
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
                            ? 'Selecione um Sketch ou uma superfície para iniciar o Extrude.'
                            : widget
                                  .controller
                                  .selectedExtrudeProfileEntityIds
                                  .isEmpty
                            ? 'Fonte: ${widget.controller.selectedExtrudeSource!.id}'
                            : 'Fonte: perfis individuais do Sketch',
                      ),
                      if (widget
                          .controller
                          .selectedExtrudeProfileEntityIds
                          .isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Perfis selecionados: ${widget.controller.selectedExtrudeProfileGroups.length}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        for (
                          var index = 0;
                          index <
                              widget
                                  .controller
                                  .selectedExtrudeProfileGroups
                                  .length;
                          index++
                        )
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Perfil ${index + 1} — ${widget.controller.extrudeProfileGroupLabel(widget.controller.selectedExtrudeProfileGroups[index])}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Remover perfil',
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: widget.controller.busy
                                    ? null
                                    : () => widget.controller.removeExtrudeProfile(
                                        widget
                                            .controller
                                            .selectedExtrudeProfileGroups[index]
                                            .first,
                                      ),
                              ),
                            ],
                          ),
                      ],
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: widget.controller.busy
                              ? null
                              : () {
                                  final added = widget.controller
                                      .addSelectedExtrudeProfiles();
                                  if (added == 0) {
                                    widget.controller.error =
                                        'Selecione outro perfil fechado na árvore ou viewport.';
                                  }
                                },
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Adicionar perfil selecionado'),
                        ),
                      ),
                      if (widget.controller.error != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          widget.controller.error!,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
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
                          if (parsed != null && parsed > 0) {
                            distance = parsed;
                          }
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
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: widget.controller.busy
                              ? null
                              : () {
                                  widget.controller.clearExtrudeSource(
                                    clearDocumentSelection: true,
                                  );
                                },
                          icon: const Icon(Icons.clear, size: 16),
                          label: const Text('Limpar seleção'),
                        ),
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
                          if (value != null) {
                            directionSourceId = value;
                          }
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
                          if (value != null) {
                            direction = value;
                          }
                        },
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<ProfessionalExtrudeExtent>(
                        initialValue: extent,
                        decoration: const InputDecoration(labelText: 'Modo'),
                        items: const [
                          DropdownMenuItem(
                            value: ProfessionalExtrudeExtent.distance,
                            child: Text('Distância'),
                          ),
                          DropdownMenuItem(
                            value: ProfessionalExtrudeExtent.symmetric,
                            child: Text('Simétrico (distância por lado)'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => extent = value);
                          }
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
                          if (value != null) {
                            setState(() => output = value);
                          }
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
                                  : () async {
                                      try {
                                        await widget.controller
                                            .previewProfessionalExtrude(
                                              distance: distance,
                                              draftAngleDegrees:
                                                  draftAngleDegrees,
                                              directionSourceId:
                                                  directionSourceId,
                                              direction: direction,
                                              output: output,
                                              extent: extent,
                                            );
                                      } catch (value) {
                                        // Never swallow the failure: surface a
                                        // safe, readable message even when the
                                        // controller could not classify it.
                                        if (widget.controller.error == null) {
                                          widget.controller.error =
                                              'Preview do Extrude falhou: $value';
                                        }
                                        if (mounted) setState(() {});
                                      }
                                    },
                              child: const Text('Preview'),
                            ),
                          ),
                          TextButton(
                            onPressed: widget.controller.busy
                                ? null
                                : () {
                                    widget.controller
                                        .cancelProfessionalExtrude();
                                    setState(
                                      () => extrudeCommandActive = false,
                                    );
                                  },
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (!extrudeCommandActive && !revolveCommandActive) ...[
              const SizedBox(height: 6),
              FilledButton.icon(
                onPressed: widget.controller.busy
                    ? null
                    : () => setState(() {
                        revolveCommandActive = true;
                        extrudeCommandActive = false;
                      }),
                icon: const Icon(Icons.rotate_right),
                label: const Text('Revolve'),
              ),
            ],
            if (revolveCommandActive) ...[
              const SizedBox(height: 6),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Revolve',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: ValueKey(
                          'revolve-profile-${widget.controller.selectedRevolveProfileId}',
                        ),
                        initialValue:
                            widget.controller.selectedRevolveProfileId,
                        decoration: const InputDecoration(
                          labelText: 'Perfil',
                          helperText:
                              'Sketch fechado para Solid; aberto para Surface.',
                        ),
                        isExpanded: true,
                        items: widget.controller.revolveProfiles
                            .map(
                              (entity) => DropdownMenuItem(
                                value: entity.id,
                                child: Text(
                                  entity.data['name'] as String? ?? entity.id,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: widget.controller.busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  widget.controller.selectRevolveProfile(value);
                                }
                              },
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: widget.controller.busy
                              ? null
                              : () => widget.controller
                                    .beginRevolveViewportCapture(axis: false),
                          icon: const Icon(Icons.ads_click, size: 16),
                          label: Text(
                            widget.controller.revolveCaptureSlot == 'profile'
                                ? 'Clique no perfil na viewport...'
                                : 'Selecionar perfil na viewport',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        key: ValueKey(
                          'revolve-axis-${widget.controller.selectedRevolveAxisId}',
                        ),
                        initialValue: widget.controller.selectedRevolveAxisId,
                        decoration: const InputDecoration(
                          labelText: 'Eixo',
                          helperText:
                              'Use um eixo de References ou X/Y/Z do WCS.',
                        ),
                        isExpanded: true,
                        items: widget.controller.revolveAxes
                            .map(
                              (entity) => DropdownMenuItem(
                                value: entity.id,
                                child: Text(
                                  entity.data['name'] as String? ?? entity.id,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: widget.controller.busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  widget.controller.selectRevolveAxis(value);
                                }
                              },
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: widget.controller.busy
                              ? null
                              : () => widget.controller
                                    .beginRevolveViewportCapture(axis: true),
                          icon: const Icon(Icons.ads_click, size: 16),
                          label: Text(
                            widget.controller.revolveCaptureSlot == 'axis'
                                ? 'Clique no eixo na viewport...'
                                : 'Selecionar eixo na viewport',
                          ),
                        ),
                      ),
                      DropdownButtonFormField<RevolveOutput>(
                        initialValue: revolveOutput,
                        decoration: const InputDecoration(
                          labelText: 'Resultado',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: RevolveOutput.solid,
                            child: Text('Solid'),
                          ),
                          DropdownMenuItem(
                            value: RevolveOutput.surface,
                            child: Text('Surface'),
                          ),
                        ],
                        onChanged: widget.controller.busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => revolveOutput = value);
                                }
                              },
                      ),
                      if (widget.controller.error != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          widget.controller.error!,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed:
                                  widget.controller.busy ||
                                      !widget.controller.canPreviewRevolve
                                  ? null
                                  : () => widget.controller
                                        .previewProfessionalRevolve(
                                          output: revolveOutput,
                                        ),
                              icon: const Icon(Icons.preview),
                              label: const Text('Preview'),
                            ),
                          ),
                          TextButton(
                            onPressed: widget.controller.busy
                                ? null
                                : () {
                                    widget.controller
                                        .cancelProfessionalRevolve();
                                    widget.controller.clearRevolveSelection();
                                    setState(
                                      () => revolveCommandActive = false,
                                    );
                                  },
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
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
          if (preview['multiProfilePreview'] == true)
            Text(
              'Extrude Multi: ${(preview['profileEntityIds'] as List?)?.length ?? 0} perfis Wire',
              style: const TextStyle(fontSize: 11),
            ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: contract.distance.toString(),
            decoration: const InputDecoration(
              labelText: 'Distância',
              suffixText: 'mm',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (value) {
              final parsed = double.tryParse(value.replaceAll(',', '.'));
              if (parsed != null && parsed > 0) {
                _schedulePreviewUpdate(
                  () => widget.controller.updateProfessionalExtrudePreview(
                    distance: parsed,
                  ),
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
            onChanged: (value) {
              final parsed = double.tryParse(value.replaceAll(',', '.'));
              if (parsed != null && parsed.abs() < 89) {
                _schedulePreviewUpdate(
                  () => widget.controller.updateProfessionalExtrudePreview(
                    draftAngleDegrees: parsed,
                  ),
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
          DropdownButtonFormField<ProfessionalExtrudeExtent>(
            initialValue: contract.extent,
            decoration: const InputDecoration(labelText: 'Modo'),
            items: const [
              DropdownMenuItem(
                value: ProfessionalExtrudeExtent.distance,
                child: Text('Distância'),
              ),
              DropdownMenuItem(
                value: ProfessionalExtrudeExtent.symmetric,
                child: Text('Simétrico (distância por lado)'),
              ),
            ],
            onChanged: widget.controller.busy
                ? null
                : (value) {
                    if (value != null) {
                      widget.controller.updateProfessionalExtrudePreview(
                        extent: value,
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
            'Through All · Up To Surface: architecture prepared',
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
                  child: const Text('Apply'),
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
        SketchHealthIssueType.disconnected,
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
            InspectorPresentationLabels.section(title),
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const Divider(height: 12),
          ...children,
        ],
      ),
    ),
  );
}

class _SharedInspectorReadOnlySection extends StatelessWidget {
  const _SharedInspectorReadOnlySection({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => InspectorPropertySection(
    section: InspectorSectionModel(
      id: title,
      label: InspectorPresentationLabels.section(title),
      properties: const [],
    ),
    children: children,
  );
}

class _InspectorProperty extends StatelessWidget {
  const _InspectorProperty({required this.label, required this.value});
  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) => InspectorPropertyRow(
    property: InspectorPropertyModel(
      id: label,
      label: InspectorPresentationLabels.property(label),
      value: _safeInspectorValue(value),
      availability: value == null
          ? PanelPropertyAvailability.unavailable
          : PanelPropertyAvailability.available,
    ),
  );
}

Object? _safeInspectorValue(Object? value) {
  try {
    return InspectorPropertyModel(
      id: 'value',
      label: 'Valor',
      value: value,
    ).value;
  } on ArgumentError {
    return value?.toString();
  }
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

/// Rail shown in the main window while a panel lives in its own window.
///
/// Keeps the workspace layout stable and gives the operator the two actions
/// that matter: focus the detached window or bring the panel back.
class _DetachedPanelRail extends StatelessWidget {
  const _DetachedPanelRail({
    required this.panelId,
    required this.title,
    required this.icon,
    required this.onReturn,
    required this.onFocus,
    this.error,
  });

  final PanelId panelId;
  final String title;
  final IconData icon;
  final VoidCallback onReturn;
  final VoidCallback onFocus;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      key: ValueKey('detached-${panelId.name}'),
      width: 44,
      child: Material(
        color: colors.surfaceContainerHigh,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Tooltip(
              message: '$title está em outra janela (focar)',
              child: InkWell(
                onTap: onFocus,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(icon, size: 16, color: colors.primary),
                ),
              ),
            ),
            Tooltip(
              message: 'Trazer $title de volta',
              child: InkWell(
                onTap: onReturn,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.push_pin, size: 16),
                ),
              ),
            ),
            if (error != null)
              Tooltip(
                message: error!,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.error_outline,
                    size: 16,
                    color: colors.error,
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Expanded(
              child: RotatedBox(
                quarterTurns: 3,
                child: Center(
                  child: Text(
                    '$title · janela destacada',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DockableSidePanel extends StatefulWidget {
  const _DockableSidePanel({
    required this.panelId,
    required this.title,
    required this.icon,
    required this.width,
    required this.child,
    this.initiallyCollapsed = false,
    this.onDetach,
  });
  final String panelId;
  final String title;
  final IconData icon;
  final double width;
  final Widget child;
  final bool initiallyCollapsed;

  /// G124-UX.MM4.1: detaches this panel to its own Windows window.
  final VoidCallback? onDetach;

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
                if (widget.onDetach != null)
                  _PanelHeaderButton(
                    tooltip: 'Destacar painel para outra janela',
                    icon: Icons.open_in_new,
                    onPressed: widget.onDetach!,
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

/// Optional tangency references for "Ajustar círculo/arco pelas linhas".
///
/// Empty fields keep the automatic inference from the Section neighbours; a
/// filled field makes the named curve drive the tangency at that endpoint.
class _SketchTangencyReferences extends StatelessWidget {
  const _SketchTangencyReferences({required this.controller});

  final OperationalReverseEngineeringController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Tangência (opcional)',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed:
                  controller.sketchTangencyStartId == null &&
                      controller.sketchTangencyEndId == null
                  ? null
                  : controller.clearSketchTangencyReferences,
              child: const Text('Limpar', style: TextStyle(fontSize: 10)),
            ),
          ],
        ),
        _SketchTangencyReferenceField(
          controller: controller,
          label: 'Tangência inicial',
          target: 'start',
          reference: controller.sketchTangencyStartLabel,
        ),
        _SketchTangencyReferenceField(
          controller: controller,
          label: 'Tangência final',
          target: 'end',
          reference: controller.sketchTangencyEndLabel,
        ),
        if (controller.sketchTangencyPickActive)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
            child: Text(
              controller.sketchTangencyPickHint,
              style: const TextStyle(fontSize: 9.5),
            ),
          ),
      ],
    );
  }
}

class _SketchTangencyReferenceField extends StatelessWidget {
  const _SketchTangencyReferenceField({
    required this.controller,
    required this.label,
    required this.target,
    required this.reference,
  });

  final OperationalReverseEngineeringController controller;
  final String label;
  final String target;
  final String? reference;

  @override
  Widget build(BuildContext context) {
    final picking = controller.sketchTangencyPickTarget == target;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: const TextStyle(fontSize: 10)),
                Text(
                  reference ?? 'automático (inferida da seção)',
                  style: TextStyle(
                    fontSize: 9,
                    color: reference == null
                        ? Theme.of(context).disabledColor
                        : null,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: picking
                ? 'Cancelar seleção'
                : 'Selecionar curva na viewport',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: picking
                ? controller.cancelSketchTangencyPick
                : () => controller.beginSketchTangencyPick(target),
            icon: Icon(picking ? Icons.close : Icons.touch_app_outlined),
          ),
          IconButton(
            tooltip: 'Usar modo automático',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: reference == null
                ? null
                : () => controller.clearSketchTangencyReference(target),
            icon: const Icon(Icons.backspace_outlined),
          ),
        ],
      ),
    );
  }
}
