import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/commands/command_registry.dart';
import 'package:flcad_mobile/app/bootstrap/engineering_bootstrap.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/desktop/desktop_application.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/import_export/api/import_export_api.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flcad_mobile/features/projects/models/project.dart';
import 'package:flcad_mobile/features/projects/models/project_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String _sectionVisibilityCommand = 'reverse.section.visibility';

RegisteredEngineeringCommand _command(String id, String module) =>
    RegisteredEngineeringCommand(
      id: id,
      module: module,
      execute: (_, _) async => null,
      undo: (_, _) async => null,
      redo: (_, _) async => null,
    );

void main() {
  test('a foreign registration is never replaced by a session install', () {
    final cad = DesktopCadController(
      kernels: KernelManager(),
      projects: ProjectManager(),
    );
    addTearDown(cad.dispose);
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager(),
    );
    commands.registry.register(_command(_sectionVisibilityCommand, 'Foreign'));

    expect(
      () => OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: commands,
        runtime: cad.runtime,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Command already registered: $_sectionVisibilityCommand'),
        ),
      ),
    );
    // The conflict must leave the registry exactly as it was: no partial
    // operational install, no silent handler replacement.
    expect(
      commands.registry.resolve(_sectionVisibilityCommand).module,
      'Foreign',
    );
    expect(
      commands.registry.commands.where(
        (command) => command.id.startsWith('reverse.sketch.'),
      ),
      isEmpty,
    );
  });

  test('a conflict anywhere in the set leaves the registry untouched', () {
    final cad = DesktopCadController(
      kernels: KernelManager(),
      projects: ProjectManager(),
    );
    addTearDown(cad.dispose);
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager(),
    );
    commands.registry.register(_command('foreign.module', 'Foreign'));

    final owner = Object();
    expect(
      () => commands.installSessionCommands(
        owner: owner,
        commands: [
          _command('session.alpha', 'Session'),
          _command('foreign.module', 'Session'),
          _command('session.beta', 'Session'),
        ],
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Command already registered: foreign.module'),
        ),
      ),
    );
    expect(commands.registry.resolve('foreign.module').module, 'Foreign');
    expect(commands.registry.contains('session.alpha'), isFalse);
    expect(commands.registry.contains('session.beta'), isFalse);
    expect(commands.sessionCommandIds, isEmpty);

    // A repeated id inside the incoming set is rejected just as atomically.
    expect(
      () => commands.installSessionCommands(
        owner: owner,
        commands: [
          _command('session.gamma', 'Session'),
          _command('session.gamma', 'Session'),
        ],
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Command already registered: session.gamma'),
        ),
      ),
    );
    expect(commands.registry.contains('session.gamma'), isFalse);
    expect(commands.sessionCommandIds, isEmpty);
  });

  test('a late dispose never strips the newer session commands', () {
    final cad = DesktopCadController(
      kernels: KernelManager(),
      projects: ProjectManager(),
    );
    addTearDown(cad.dispose);
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager(),
    );
    final first = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
    );
    final second = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
    );
    addTearDown(second.dispose);

    expect(_visibilityCount(commands), 1);
    // Flutter can dispose the replaced Workspace after the rebuilt one mounted.
    first.dispose();

    expect(_visibilityCount(commands), 1);
    expect(commands.sessionCommandIds, contains(_sectionVisibilityCommand));
    expect(
      commands.registry.resolve(_sectionVisibilityCommand).module,
      'SketchSurface',
    );
  });

  test('a released session hands the ids over to the next install', () async {
    final harness = await _harness(
      'p0-command-registry-release',
      withSession: false,
    );
    addTearDown(() => harness.directory.delete(recursive: true));
    addTearDown(harness.cad.dispose);
    addTearDown(harness.disposeAllSessions);

    final first = harness.newController();
    expect(_visibilityCommandCount(harness), 1);
    expect(
      harness.commands.sessionCommandIds,
      contains(_sectionVisibilityCommand),
    );

    harness.disposeSession(first);
    expect(_visibilityCommandCount(harness), 0);
    expect(harness.commands.sessionCommandIds, isEmpty);

    final second = harness.newController();
    await harness.configureSession(second);
    expect(_visibilityCommandCount(harness), 1);
    await _expectSectionVisibilityRoundTrip(harness, second);
  });

  testWidgets(
    'Workspace mount, unmount and remount keep a single command set',
    (tester) async {
      EngineeringBootstrap.instance.initialize();
      final cad = DesktopCadController(
        kernels: KernelManager(),
        projects: ProjectManager(),
      );
      addTearDown(cad.dispose);
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager(),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1400, 900));

      Widget workspace() => MaterialApp(
        home: Scaffold(
          body: OfficialEngineeringWorkspace(cad: cad, commands: commands),
        ),
      );

      await tester.pumpWidget(workspace());
      await tester.pump();
      expect(_visibilityCount(commands), 1);
      final mounted = commands.registry.resolve(_sectionVisibilityCommand);

      // The operator leaves the Workspace: the session is disposed and gives
      // its ids back.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pump();
      expect(_visibilityCount(commands), 0);
      expect(commands.sessionCommandIds, isEmpty);

      await tester.pumpWidget(workspace());
      await tester.pump();
      expect(_visibilityCount(commands), 1);
      expect(
        identical(
          mounted,
          commands.registry.resolve(_sectionVisibilityCommand),
        ),
        isFalse,
        reason: 'the rebuilt session must dispatch its own handlers',
      );
    },
  );

  test(
    'a rebuilt workspace session adopts the operational command set once',
    () async {
      final harness = await _harness('p0-command-registry-handover');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.cad.dispose);
      addTearDown(harness.disposeAllSessions);

      final first = harness.controller;
      final primary = await harness.ensurePrimaryProject();
      final created = await _createThreeSketches(first);
      final ids = created.ids;
      await first.saveProject();
      expect(first.error, isNull);

      // Only one registration of the Section visibility command may exist in
      // the shared registry, regardless of how many project sessions ran.
      expect(_visibilityCommandCount(harness), 1);

      // Leaving the Workspace tab disposes the whole session state, and
      // reopening the project clears CadRuntime._state (sketchApi, stage,
      // project.configuredId) before the Workspace is
      // mounted again.  Session two therefore starts from a pristine runtime
      // map while the coordinator registry already holds the earlier set.
      harness.disposeSession(first);
      await harness.projectManager.open(primary);
      await harness.cad.runtime.open(primary.id, harness.primaryDirectory);

      final second = harness.newController();
      expect(
        harness.commands.sessionCommandIds,
        contains(_sectionVisibilityCommand),
        reason: 'the live session must own the operational command set',
      );
      for (final id in ids) {
        await second.reopenSketchForEditing(id);
        expect(second.error, isNull);
        expect(second.activeSketch!.id, id);
        final restored = second.sketchApi!.sketches
            .where((sketch) => sketch.id == id)
            .toList();
        expect(
          restored.single.entityIds,
          isNotEmpty,
          reason: 'Sketch $id must still expose its entities',
        );
        await second.finishSketch();
        expect(second.error, isNull);
      }

      expect(_visibilityCommandCount(harness), 1);
      await _expectSectionVisibilityRoundTrip(harness, second);
    },
  );

  test(
    'three Sketches keep entering across project switch and reopen',
    () async {
      final harness = await _harness('p0-command-registry-cycle');
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.cad.dispose);
      addTearDown(harness.disposeAllSessions);

      final controller = harness.controller;
      final primary = await harness.ensurePrimaryProject();
      final created = await _createThreeSketches(controller);
      final ids = created.ids;
      await _editEachSketch(controller, created);
      await controller.saveProject();

      // Trocar de projeto: o coordenador e seu registry continuam vivos.
      final other = await harness.projectManager.create(
        name: 'p0-command-registry-other',
        client: 'P0',
      );
      final otherDirectory = await harness.projects.directoryFor(other.id);
      await harness.cad.runtime.open(other.id, otherDirectory);
      await controller.configureProject(
        projectId: other.id,
        projectDirectory: otherDirectory,
      );
      expect(controller.error, isNull);

      // Reabrir o primeiro projeto sem remontar a Workspace.
      await harness.projectManager.open(primary);
      await harness.cad.runtime.open(primary.id, harness.primaryDirectory);
      await controller.configureProject(
        projectId: primary.id,
        projectDirectory: harness.primaryDirectory,
      );
      await _editEachSketch(controller, created);
      expect(controller.error, isNull);

      // Remontar a Workspace e repetir o ciclo de configuração e edição.
      harness.disposeSession(controller);
      await harness.projectManager.open(primary);
      await harness.cad.runtime.open(primary.id, harness.primaryDirectory);
      final rebuilt = harness.newController();
      // Save/Open must still enter every Sketch and edit persisted geometry.
      await _editEachSketch(rebuilt, created, base: 20);
      await rebuilt.saveProject();
      await _enterExitEachSketch(rebuilt, ids);
      expect(rebuilt.error, isNull);
      expect(_visibilityCommandCount(harness), 1);
      await _expectSectionVisibilityRoundTrip(harness, rebuilt);

      final roots = harness.cad.runtime.document!.entities.values
          .where((entity) => entity.kind == CadDocumentEntityKind.sketch)
          .map((entity) => entity.id)
          .toSet();
      expect(roots, containsAll(ids));
    },
  );
}

int _visibilityCount(DesktopCommandCoordinator commands) => commands
    .registry
    .commands
    .where((command) => command.id == _sectionVisibilityCommand)
    .length;

int _visibilityCommandCount(_Harness harness) =>
    _visibilityCount(harness.commands);

bool _sectionVisible(
  OperationalReverseEngineeringController controller,
  String id,
) =>
    controller.runtime.document!.entities[id]!.data['sceneVisible'] as bool? ??
    true;

/// Toggles the Section against the live session and asserts the registry
/// handler mutates the document that the operator is looking at.
Future<void> _expectSectionVisibilityRoundTrip(
  _Harness harness,
  OperationalReverseEngineeringController controller,
) async {
  await controller.createWorldReferenceCurve(SketchPlaneType.xy);
  final section = controller.sections.sections.last;
  expect(section.kind, CadDocumentEntityKind.section);
  expect(controller.selectedSection?.id, section.id);

  // Workspace button: Section Show/Hide keeps working.
  await controller.toggleSourceSectionVisibility();
  expect(controller.error, isNull);
  expect(_sectionVisible(controller, section.id), isFalse);

  // Registry dispatch: the handler installed by this session must mutate the
  // document the operator is looking at, never a previous session's state.
  await harness.commands.dispatch(_sectionVisibilityCommand, {
    'id': section.id,
    'visible': true,
  });
  expect(_sectionVisible(controller, section.id), isTrue);
}

typedef _ThreeSketches = ({List<String> ids, Map<String, String> lineIds});

Future<_ThreeSketches> _createThreeSketches(
  OperationalReverseEngineeringController controller,
) async {
  const planes = [SketchPlaneType.xy, SketchPlaneType.yz, SketchPlaneType.zx];
  final ids = <String>[];
  final lineIds = <String, String>{};
  for (var index = 0; index < planes.length; index++) {
    controller.selectWorldSketchPlane(planes[index]);
    await controller.openSketch(forceNew: index > 0);
    final sketch = controller.activeSketch!;
    ids.add(sketch.id);
    lineIds[sketch.id] = controller.sketchApi!.builders.line
        .build(
          SketchVector(index.toDouble(), 0),
          SketchVector(index.toDouble() + 1, 0),
        )
        .id;
    await controller.finishSketch();
    expect(controller.error, isNull);
  }
  expect(ids.toSet(), hasLength(3));
  return (ids: ids, lineIds: lineIds);
}

/// Enters each Sketch, edits its persisted line and leaves it again.
Future<void> _editEachSketch(
  OperationalReverseEngineeringController controller,
  _ThreeSketches created, {
  double base = 12,
}) async {
  for (final id in created.ids) {
    await controller.reopenSketchForEditing(id);
    expect(controller.error, isNull);
    expect(controller.activeSketch!.id, id);
    expect(controller.sketchApi!.engine.activeSketchId, id);
    final lineId = created.lineIds[id]!;
    final length = base + created.ids.indexOf(id);
    await controller.updateSketchEntityParameters(lineId, {'length': length});
    expect(controller.error, isNull);
    final edited = controller.sketchApi!.entity(lineId)! as SketchLine;
    expect(edited.parameters['length'], closeTo(length, 1e-9));
    await controller.finishSketch();
    expect(controller.error, isNull);
  }
}

Future<void> _enterExitEachSketch(
  OperationalReverseEngineeringController controller,
  List<String> ids,
) async {
  for (final id in ids) {
    await controller.reopenSketchForEditing(id);
    expect(controller.error, isNull);
    expect(controller.activeSketch!.id, id);
    expect(controller.sketchApi!.engine.activeSketchId, id);
    await controller.finishSketch();
    expect(controller.error, isNull);
  }
}

class _Harness {
  _Harness({
    required this.directory,
    required this.projects,
    required this.projectManager,
    required this.cad,
    required this.commands,
    required this.primaryProjectId,
  });

  final Directory directory;
  final ProjectRepository projects;
  final ProjectManager projectManager;
  final DesktopCadController cad;
  final DesktopCommandCoordinator commands;
  final String primaryProjectId;
  late final OperationalReverseEngineeringController controller;
  final List<OperationalReverseEngineeringController> _sessions = [];
  final Set<OperationalReverseEngineeringController> _disposedSessions = {};
  Directory? _primaryDirectory;

  Directory get primaryDirectory => _primaryDirectory!;

  /// Mirrors the Workspace tab lifecycle: every mount builds a brand new
  /// session controller over the long lived coordinator and runtime.
  OperationalReverseEngineeringController newController() {
    final controller = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
      referenceApi: ReferenceApi(
        engine: ReferenceEngine(
          repository: ReferenceRepository(projects: projects),
        ),
      ),
    );
    _sessions.add(controller);
    return controller;
  }

  void disposeSession(OperationalReverseEngineeringController session) {
    if (_disposedSessions.add(session)) session.dispose();
  }

  void disposeAllSessions() {
    for (final session in _sessions) {
      disposeSession(session);
    }
  }

  Future<void> configureSession(
    OperationalReverseEngineeringController session,
  ) => session.configureProject(
    projectId: primaryProjectId,
    projectDirectory: primaryDirectory,
  );

  /// Creates (or recreates) the primary project of this harness, mirroring the
  /// Explorer's three genuine Sketches workflow: XY, YZ and ZX.
  Future<Project> ensurePrimaryProject() async {
    final project = await projectManager.open(
      Project(
        id: primaryProjectId,
        name: primaryProjectId,
        client: 'P0',
        description: 'P0 command registry identity',
        createdAt: DateTime(2020),
        status: ProjectStatus.created,
      ),
    );
    _primaryDirectory = await projects.directoryFor(project.id);
    await cad.runtime.open(project.id, _primaryDirectory!);
    await commands.refreshContext();
    return project;
  }
}

Future<_Harness> _harness(
  String name, {
  bool withSession = true,
  bool withMesh = true,
}) async {
  final directory = await Directory.systemTemp.createTemp('${name}_');
  final projects = ProjectRepository(
    storage: LocalStorageService(rootDirectory: directory),
  );
  final projectManager = ProjectManager(repository: projects);
  final kernels = KernelManager()
    ..register(_HealthySurfaceKernel(), makeDefault: true);
  final cad = DesktopCadController(kernels: kernels, projects: projectManager);
  final commands = DesktopCommandCoordinator(
    cad: cad,
    projects: projectManager,
    repository: projects,
  );
  final harness = _Harness(
    directory: directory,
    projects: projects,
    projectManager: projectManager,
    cad: cad,
    commands: commands,
    primaryProjectId: '$name-primary',
  );
  if (withSession) harness.controller = harness.newController();
  await harness.ensurePrimaryProject();
  if (withSession) await harness.configureSession(harness.controller);
  if (withMesh) await _registerMesh(harness);
  return harness;
}

Future<void> _registerMesh(_Harness harness) async {
  final id = 'Mesh001';
  final nodes = _boxNodes(-10, 10, -2, 2, -5, 5);
  final triangles = _boxTriangles(0);
  final xs = [for (var i = 0; i < nodes.length; i += 3) nodes[i]];
  final ys = [for (var i = 1; i < nodes.length; i += 3) nodes[i]];
  final zs = [for (var i = 2; i < nodes.length; i += 3) nodes[i]];
  final document = harness.cad.runtime.document!;
  await harness.cad.runtime.registerImport(
    ImportedCadDocument(
      id: id,
      projectId: document.projectId,
      sourcePath: '$id.stl',
      format: CadImportFormat.stl,
      registeredPath: 'CAD/Imports/$id.stl',
      validation: const [],
      mesh: KernelMeshHandle(
        persistentId: '$id-mesh',
        kernelId: 'test',
        fingerprint: id,
        vertexCount: nodes.length ~/ 3,
        triangleCount: triangles.length ~/ 3,
        bounds: KernelBounds(
          xs.reduce(math.min),
          ys.reduce(math.min),
          zs.reduce(math.min),
          xs.reduce(math.max),
          ys.reduce(math.max),
          zs.reduce(math.max),
        ),
        hasNormals: false,
        metadata: const {},
      ),
    ),
    geometry: KernelMeshGeometry(nodes: nodes, triangles: triangles),
  );
}

List<double> _boxNodes(
  double x0,
  double x1,
  double y0,
  double y1,
  double z0,
  double z1,
) => [
  x0,
  y0,
  z0,
  x1,
  y0,
  z0,
  x1,
  y1,
  z0,
  x0,
  y1,
  z0,
  x0,
  y0,
  z1,
  x1,
  y0,
  z1,
  x1,
  y1,
  z1,
  x0,
  y1,
  z1,
];

List<int> _boxTriangles(int base) => [
  base,
  base + 1,
  base + 2,
  base,
  base + 2,
  base + 3,
  base + 4,
  base + 6,
  base + 5,
  base + 4,
  base + 7,
  base + 6,
  base,
  base + 5,
  base + 1,
  base,
  base + 4,
  base + 5,
  base + 3,
  base + 2,
  base + 6,
  base + 3,
  base + 6,
  base + 7,
  base,
  base + 3,
  base + 7,
  base,
  base + 7,
  base + 4,
  base + 1,
  base + 5,
  base + 6,
  base + 1,
  base + 6,
  base + 2,
];

class _HealthySurfaceKernel
    implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'p0-command-registry-test',
    name: 'P0 command registry test kernel',
    version: '1',
    capabilities: KernelCapabilities({KernelCapability.planeSurface}),
    vendor: 'FLCAD',
  );

  @override
  Future<KernelHealth> healthCheck() async =>
      KernelHealth(KernelHealthStatus.healthy, 'ok', DateTime(2000));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
