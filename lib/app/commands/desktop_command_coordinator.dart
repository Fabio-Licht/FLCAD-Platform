import '../../core/import_export/import_export.dart';
import '../../features/projects/data/project_repository.dart';
import '../../features/projects/domain/project_manager.dart';
import '../../features/projects/models/project.dart';
import '../desktop/desktop_cad_controller.dart';
import 'command_context.dart';
import 'command_dispatcher.dart';
import 'command_manager.dart';
import 'command_registry.dart';
import 'command_validation.dart';
import 'engineering_command_router.dart';
import 'workspace_command_adapter.dart';

class DesktopCommandCoordinator {
  DesktopCommandCoordinator({
    required this.cad,
    required this.projects,
    ProjectRepository? repository,
  }) : repository = repository ?? ProjectRepository() {
    manager = CommandManager(registry: registry);
    cad.runtime.attachCommands(manager);
    dispatcher = CommandDispatcher(
      manager: manager,
      context: CommandContext(projectId: null, projectDirectory: null),
    );
    router = EngineeringCommandRouter(dispatcher);
    _register();
  }
  final DesktopCadController cad;
  final ProjectManager projects;
  final ProjectRepository repository;
  final CommandRegistry registry = CommandRegistry();
  final WorkspaceCommandAdapter workspace = WorkspaceCommandAdapter();
  late final CommandManager manager;
  late final CommandDispatcher dispatcher;
  late final EngineeringCommandRouter router;
  Future<void> _saveTail = Future<void>.value();

  /// Session owner of each operational command currently installed in
  /// [registry].
  ///
  /// The coordinator (and its registry) outlives the individual project
  /// sessions: `CadRuntime.open`/`close` clear the whole runtime state map, so
  /// a runtime-store marker cannot tell whether this registry already holds a
  /// command.  Operational handlers capture the Workspace session controller,
  /// therefore the session that installs them owns their lifecycle and
  /// releases them when it is disposed.
  final Map<String, Object> _sessionCommandOwners = <String, Object>{};

  /// Command ids currently owned by a Workspace session.
  Iterable<String> get sessionCommandIds => _sessionCommandOwners.keys;

  /// Installs the operational command set of one Workspace session.
  ///
  /// Registration is idempotent for [owner]: configuring or reopening a
  /// project never registers the same id twice.  Ids still owned by a previous
  /// session are released first, because a rebuilt session must never dispatch
  /// into a disposed controller.  Ids registered by any other part of the
  /// platform (Project, Import/Export, Workspace, …) are never replaced —
  /// that conflict is surfaced instead of being swallowed.
  void installSessionCommands({
    required Object owner,
    required List<RegisteredEngineeringCommand> commands,
  }) {
    // Pre-flight: the whole set is validated before anything is mutated, so a
    // conflict or a repeated id can never leave a partially installed session.
    final incoming = <String>{};
    for (final command in commands) {
      if (!incoming.add(command.id)) {
        throw StateError('Command already registered: ${command.id}');
      }
      if (!registry.contains(command.id)) continue;
      final currentOwner = _sessionCommandOwners[command.id];
      if (identical(currentOwner, owner)) continue;
      if (currentOwner != null) continue;
      throw StateError('Command already registered: ${command.id}');
    }
    final stale = _sessionCommandOwners.entries
        .where((entry) => !identical(entry.value, owner))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final id in stale) {
      registry.unregister(id);
      _sessionCommandOwners.remove(id);
    }
    for (final command in commands) {
      if (identical(_sessionCommandOwners[command.id], owner)) continue;
      registry.register(command);
      _sessionCommandOwners[command.id] = owner;
    }
  }

  /// Releases the ids that [owner] still holds.  Ids already adopted by a
  /// newer session are left untouched, so an out of order dispose cannot strip
  /// the live session.
  void releaseSessionCommands(Object owner) {
    final owned = _sessionCommandOwners.entries
        .where((entry) => identical(entry.value, owner))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final id in owned) {
      registry.unregister(id);
      _sessionCommandOwners.remove(id);
    }
  }

  /// Canonical project save entry point. Menu, Ctrl+S and workspace callers
  /// share this tail so Sketch/document writes cannot interleave.
  Future<void> saveProject({String? expectedProjectId}) {
    final operation = _saveTail.then<void>(
      (_) => _performSave(expectedProjectId: expectedProjectId),
      onError: (_, _) => _performSave(expectedProjectId: expectedProjectId),
    );
    _saveTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _performSave({String? expectedProjectId}) async {
    final project = projects.current;
    if (project == null) throw StateError('No project is open.');
    _assertSaveContext(project, expectedProjectId: expectedProjectId);
    final persist = cad.runtime.read<Future<void> Function()>(
      'project.beforeSave',
    );
    if (persist != null) await persist();
    _assertSaveContext(project, expectedProjectId: expectedProjectId);
    await cad.runtime.save(recordLifecycle: true);
    _assertSaveContext(project, expectedProjectId: expectedProjectId);
    await repository.save(project);
    _assertSaveContext(project, expectedProjectId: expectedProjectId);
  }

  void _assertSaveContext(Project project, {String? expectedProjectId}) {
    if (expectedProjectId != null && project.id != expectedProjectId) {
      throw StateError('The project changed while Save was waiting.');
    }
    if (projects.current?.id != project.id) {
      throw StateError('The active project changed during Save.');
    }
    final documentProjectId = cad.runtime.document?.projectId;
    if (documentProjectId != null && documentProjectId != project.id) {
      throw StateError('The CAD document changed during Save.');
    }
  }

  Future<void> initialize() async {
    await projects.initialize();
    await refreshContext();
  }

  Future<void> refreshContext() async {
    final project = projects.current;
    dispatcher.updateContext(
      CommandContext(
        projectId: project?.id,
        projectDirectory: project == null
            ? null
            : await repository.directoryFor(project.id),
        selection: workspace.state.selection,
      ),
    );
  }

  Future<void> createProject(String name, String client) async {
    await router.route('project.new', {'name': name, 'client': client});
    await refreshContext();
    final project = projects.current;
    if (project != null) await cad.restoreProjectGeometry(project.id);
  }

  Future<void> openProject(Project project) async {
    await router.route('project.open', {'projectId': project.id});
    await refreshContext();
    await cad.restoreProjectGeometry(project.id);
  }

  Future<void> dispatch(
    String id, [
    Map<String, Object?> parameters = const {},
  ]) => router.route(id, parameters).then((_) {});

  Future<void> undo() async {
    try {
      await cad.runtime.undoCommand();
      await _afterHistory('history.afterUndo');
    } catch (error) {
      cad.setStatus(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> redo() async {
    try {
      await cad.runtime.redoCommand();
      await _afterHistory('history.afterRedo');
    } catch (error) {
      cad.setStatus(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _afterHistory(String key) async {
    final callback = cad.runtime.read<Future<void> Function()>(key);
    if (callback != null) await callback();
  }

  void _register() {
    Project? previousProject;
    void register({
      required String id,
      required String module,
      required CommandAction execute,
      required CommandAction undo,
      CommandAction? redo,
      CommandValidator? validator,
    }) => registry.register(
      RegisteredEngineeringCommand(
        id: id,
        module: module,
        execute: execute,
        undo: undo,
        redo: redo ?? execute,
        validator: validator,
      ),
    );

    register(
      id: 'project.new',
      module: 'Project',
      execute: (_, p) async {
        previousProject = projects.current;
        return projects.create(
          name: p['name']! as String,
          client: p['client']! as String,
        );
      },
      undo: (_, _) async {
        final created = projects.current;
        if (created != null) await projects.archive(created);
        if (previousProject != null) await projects.open(previousProject!);
        return 'Project creation reverted';
      },
    );
    register(
      id: 'project.open',
      module: 'Project',
      execute: (_, p) async {
        previousProject = projects.current;
        final id = p['projectId']! as String;
        return projects.open(projects.projects.firstWhere((e) => e.id == id));
      },
      undo: (_, _) async {
        if (previousProject != null) await projects.open(previousProject!);
        return 'Previous project restored';
      },
    );
    register(
      id: 'project.save',
      module: 'Project',
      validator: CommandValidation.projectRequired,
      execute: (context, _) async {
        await saveProject(expectedProjectId: context.projectId);
        return 'Project saved';
      },
      undo: (_, _) async => 'Save is already durable; project state unchanged',
    );
    register(
      id: 'project.close',
      module: 'Project',
      validator: CommandValidation.projectRequired,
      execute: (_, _) async {
        previousProject = projects.current;
        await cad.closeProject();
        await projects.close();
        return 'Project closed';
      },
      undo: (_, _) async {
        if (previousProject != null) await projects.open(previousProject!);
        return 'Project reopened';
      },
    );

    for (final format in CadImportFormat.values.where(
      (format) => format != CadImportFormat.step,
    )) {
      register(
        id: 'import.${format.name}',
        module: 'Import/Export',
        validator: CommandValidation.projectRequired,
        execute: (_, _) async {
          if (format == CadImportFormat.stl) {
            await cad.pickAndImportManagedStl();
          } else {
            await cad.pickAndImport(format);
          }
          return cad.message;
        },
        undo: (_, _) async {
          await cad.runtime.undoDocument();
          return cad.message;
        },
        redo: (_, _) async {
          await cad.runtime.redoDocument();
          return cad.message;
        },
      );
    }
    register(
      id: 'import.step',
      module: 'Import/Export',
      validator: CommandValidation.projectRequired,
      execute: (_, _) async {
        await cad.pickAndImportManagedStep();
        return cad.message;
      },
      undo: (_, _) async {
        await cad.runtime.undoDocument();
        return cad.message;
      },
      redo: (_, _) async {
        await cad.runtime.redoDocument();
        return cad.message;
      },
    );
    for (final format in CadExportFormat.values) {
      register(
        id: 'export.${format.name}',
        module: 'Import/Export',
        validator: CommandValidation.projectRequired,
        execute: (_, _) async {
          await cad.pickAndExport(format);
          return cad.message;
        },
        undo: (_, _) async =>
            'Export history reverted; external file remains user-controlled',
      );
    }
    const workspaces = [
      'Reverse Engineering',
      'AI Engineering',
      'Recognition',
      'Primitive Intelligence',
      'Engineering Features',
      'Smart References',
      'Reconstruction Strategy',
      'Interactive Assistant',
      'Engineering Knowledge',
      'Sketch & Surface',
      'Sketch',
      'Reference',
      'Curves',
      'Surfaces',
      'Solids',
      'Sections',
      'Transform',
    ];
    for (final value in workspaces) {
      var previous = workspace.state.workspace;
      register(
        id: 'workspace.${_commandName(value)}',
        module: value,
        execute: (_, _) async {
          previous = workspace.state.workspace;
          workspace.open(value);
          return workspace.state.status;
        },
        undo: (_, _) async {
          workspace.open(previous);
          return workspace.state.status;
        },
      );
    }
    register(
      id: 'selection.set',
      module: 'Workspace',
      execute: (_, p) async {
        final values = (p['ids']! as List).cast<String>().toSet();
        workspace.select(values);
        await refreshContext();
        return workspace.state.status;
      },
      undo: (_, _) async {
        workspace.select(const {});
        await refreshContext();
        return workspace.state.status;
      },
    );
  }

  static String _commandName(String value) =>
      value.toLowerCase().replaceAll(' ', '_');
}
