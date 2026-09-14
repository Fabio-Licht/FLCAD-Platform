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
    } catch (error) {
      cad.setStatus(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> redo() async {
    try {
      await cad.runtime.redoCommand();
    } catch (error) {
      cad.setStatus(error.toString().replaceFirst('Bad state: ', ''));
    }
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
      execute: (_, _) async {
        await cad.runtime.save(recordLifecycle: true);
        await repository.save(projects.current!);
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
          await cad.pickAndImport(format);
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
