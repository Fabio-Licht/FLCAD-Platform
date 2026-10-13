import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_bridge.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_protocol.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_session_source.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_shell.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_transport.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_view_model.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/import_export/api/import_export_api.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flcad_mobile/features/projects/models/project.dart';
import 'package:flcad_mobile/features/projects/models/project_status.dart';
import 'package:flutter_test/flutter_test.dart';

const String _projectId = 'mm3-panel-project';
const String _meshId = 'Mesh001';

class _RuntimeHarness {
  _RuntimeHarness({
    required this.directory,
    required this.projects,
    required this.projectManager,
    required this.cad,
    required this.commands,
  });

  final Directory directory;
  final ProjectRepository projects;
  final ProjectManager projectManager;
  final DesktopCadController cad;
  final DesktopCommandCoordinator commands;

  Future<void> dispose() async {
    cad.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

Future<_RuntimeHarness> _harness() async {
  final directory = await Directory.systemTemp.createTemp('mm3-panels-');
  final projects = ProjectRepository(
    storage: LocalStorageService(rootDirectory: directory),
  );
  final projectManager = ProjectManager(repository: projects);
  await projectManager.open(
    Project(
      id: _projectId,
      name: _projectId,
      client: 'MM3',
      description: 'painel bridge runtime test',
      createdAt: DateTime(2020),
      status: ProjectStatus.created,
    ),
  );
  final kernels = KernelManager()
    ..register(_HealthySurfaceKernel(), makeDefault: true);
  final cad = DesktopCadController(kernels: kernels, projects: projectManager);
  final commands = DesktopCommandCoordinator(
    cad: cad,
    projects: projectManager,
    repository: projects,
  );
  await cad.runtime.open(_projectId, directory);
  await _registerMesh(cad);
  return _RuntimeHarness(
    directory: directory,
    projects: projects,
    projectManager: projectManager,
    cad: cad,
    commands: commands,
  );
}

Future<void> _registerMesh(DesktopCadController cad) async {
  final nodes = _boxNodes(-10, 10, -2, 2, -5, 5);
  final triangles = _boxTriangles(0);
  final xs = [for (var i = 0; i < nodes.length; i += 3) nodes[i]];
  final ys = [for (var i = 1; i < nodes.length; i += 3) nodes[i]];
  final zs = [for (var i = 2; i < nodes.length; i += 3) nodes[i]];
  final document = cad.runtime.document!;
  await cad.runtime.registerImport(
    ImportedCadDocument(
      id: _meshId,
      projectId: document.projectId,
      sourcePath: '$_meshId.stl',
      format: CadImportFormat.stl,
      registeredPath: 'CAD/Imports/$_meshId.stl',
      validation: const [],
      mesh: KernelMeshHandle(
        persistentId: '$_meshId-mesh',
        kernelId: 'mm3-test',
        fingerprint: _meshId,
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

String _directoryFingerprint(Directory directory) {
  final entries = <String>[];
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File) continue;
    entries.add(
      '${entity.path.substring(directory.path.length)}:'
      '${entity.lengthSync()}:${entity.readAsStringSync()}',
    );
  }
  entries.sort();
  return entries.join('\n');
}

void main() {
  test(
    'the explorer projection reads the real document without mutating it',
    () async {
      final harness = await _harness();
      addTearDown(harness.dispose);
      final before = jsonEncode(harness.cad.runtime.document!.toJson());

      final source = CadRuntimePanelSessionSource(harness.cad.runtime);
      final viewModel = source.viewModel(panelId: PanelId.explorer);
      final rows = viewModel[PanelViewModelKeys.entities]! as List;
      final mesh =
          rows.firstWhere((row) => (row as Map)['id'] == _meshId) as Map;

      expect(mesh['label'], startsWith('Mesh001'));
      expect(mesh['kind'], 'import');
      expect(mesh['visible'], isTrue);
      expect(viewModel[PanelViewModelKeys.groups], containsPair('import', 1));
      expect(viewModel[PanelViewModelKeys.projectId], _projectId);
      // Reading never changes the document (no transaction was opened).
      expect(jsonEncode(harness.cad.runtime.document!.toJson()), before);
    },
  );

  test('selection started in the panel lands in the main session', () async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    final transport = InMemoryPanelTransport();
    final source = CadRuntimePanelSessionSource(harness.cad.runtime);
    final bridge = PanelBridge(transport: transport, source: source)..start();
    addTearDown(bridge.dispose);
    final shell = PanelShellEndpoint(
      panelId: PanelId.explorer,
      transport: transport,
    );
    addTearDown(shell.dispose);
    shell.connect();
    expect(shell.lifecycle, PanelLifecycleState.ready);
    expect(harness.cad.runtime.selection, isEmpty);

    await shell.setSelection([_meshId]);
    await pumpEventQueue();

    expect(harness.cad.runtime.selection, {_meshId});
    expect(shell.results.single.ok, isTrue);
    expect(shell.viewModel[PanelViewModelKeys.selection], [_meshId]);
  });

  test('selection changed in the main session reaches the panel', () async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    final transport = InMemoryPanelTransport();
    final source = CadRuntimePanelSessionSource(harness.cad.runtime);
    final bridge = PanelBridge(transport: transport, source: source)..start();
    addTearDown(bridge.dispose);
    final shell = PanelShellEndpoint(
      panelId: PanelId.explorer,
      transport: transport,
    );
    addTearDown(shell.dispose);
    shell.connect();

    // The operator selects something in the viewport / workspace.
    harness.cad.runtime.select({_meshId});
    bridge.flushPending();

    expect(shell.viewModel[PanelViewModelKeys.selection], [_meshId]);
    expect(shell.revision, greaterThan(1));
    // The selection intent never created a second session.
    expect(source.sessionId, harness.cad.runtime.sessionIdentity);
  });

  test(
    'the real session refuses visibility until a documental API is wired',
    () async {
      final harness = await _harness();
      addTearDown(harness.dispose);
      final fingerprintBefore = _directoryFingerprint(harness.directory);
      final documentBefore = jsonEncode(harness.cad.runtime.document!.toJson());
      final transport = InMemoryPanelTransport();
      final source = CadRuntimePanelSessionSource(harness.cad.runtime);
      final bridge = PanelBridge(transport: transport, source: source)..start();
      addTearDown(bridge.dispose);
      final shell = PanelShellEndpoint(
        panelId: PanelId.explorer,
        transport: transport,
      );
      addTearDown(shell.dispose);
      shell.connect();

      await shell.setVisibility(_meshId, visible: false);
      await pumpEventQueue();

      // Audit finding: `CadRuntime.setEntityVisibility` is display-only and left
      // both the document flag and the scene unchanged for this entity, so the
      // real session does not advertise the capability.
      expect(source.supportsVisibility, isFalse);
      expect(shell.results.last.ok, isFalse);
      expect(shell.results.last.errorCode, PanelErrorCode.unknownAction);
      // Nothing changed in the authoritative state and nothing was persisted.
      expect(
        jsonEncode(harness.cad.runtime.document!.toJson()),
        documentBefore,
      );
      expect(harness.cad.runtime.scene.find(_meshId)?.visible, isTrue);
      expect(_directoryFingerprint(harness.directory), fingerprintBefore);
    },
  );

  test(
    'reopening the project invalidates intents from the previous session',
    () async {
      final harness = await _harness();
      addTearDown(harness.dispose);
      final transport = InMemoryPanelTransport();
      final source = CadRuntimePanelSessionSource(harness.cad.runtime);
      final bridge = PanelBridge(transport: transport, source: source)..start();
      addTearDown(bridge.dispose);
      final shell = PanelShellEndpoint(
        panelId: PanelId.explorer,
        transport: transport,
      );
      addTearDown(shell.dispose);
      shell.connect();
      final staleSession = shell.sessionId;

      // The operator reopens the project: the runtime installs a new session.
      await harness.cad.runtime.open(_projectId, harness.directory);
      bridge.flushPending();
      expect(shell.sessionId, isNot(staleSession));

      // A late intent carrying the previous session is refused.
      transport.sendToMain(PanelId.explorer.name, {
        'type': 'intent',
        'panelId': PanelId.explorer.name,
        'sessionId': staleSession,
        'projectId': _projectId,
        'action': panelActionSelectionSet,
        'params': {
          'ids': [_meshId],
        },
        'requestId': 'late-intent',
      });
      await pumpEventQueue();

      expect(
        transport.toPanelOfType('result').last['errorCode'],
        PanelErrorCode.staleSession.name,
      );
      expect(harness.cad.runtime.selection, isEmpty);
    },
  );

  test(
    'unknown ids in a panel selection are filtered by the main session',
    () async {
      final harness = await _harness();
      addTearDown(harness.dispose);
      final transport = InMemoryPanelTransport();
      final source = CadRuntimePanelSessionSource(harness.cad.runtime);
      final bridge = PanelBridge(transport: transport, source: source)..start();
      addTearDown(bridge.dispose);
      final shell = PanelShellEndpoint(
        panelId: PanelId.explorer,
        transport: transport,
      );
      addTearDown(shell.dispose);
      shell.connect();

      await shell.setSelection(['sketch:nao-existe']);
      await pumpEventQueue();

      // The runtime is the authority on what exists: the intent is accepted and
      // the unknown id simply never becomes selection.
      expect(shell.results.single.ok, isTrue);
      expect(harness.cad.runtime.selection, isEmpty);
      expect(shell.viewModel[PanelViewModelKeys.selection], isEmpty);
    },
  );

  test('projecting and delivering never mutate the document', () async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    final before = jsonEncode(harness.cad.runtime.document!.toJson());
    final revisionBefore = harness.cad.runtime.runtimeRevision;
    final transport = InMemoryPanelTransport();
    final source = CadRuntimePanelSessionSource(harness.cad.runtime);
    final bridge = PanelBridge(transport: transport, source: source)..start();
    addTearDown(bridge.dispose);
    final shell = PanelShellEndpoint(
      panelId: PanelId.explorer,
      transport: transport,
    );
    addTearDown(shell.dispose);

    shell.connect();
    bridge.flushPending();
    source.viewModel(panelId: PanelId.explorer);
    source.viewModel(panelId: PanelId.inspector);

    expect(jsonEncode(harness.cad.runtime.document!.toJson()), before);
    expect(harness.cad.runtime.runtimeRevision, revisionBefore);
    expect(harness.cad.runtime.sessionIdentity, source.sessionId);
  });
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
    id: 'mm3-test',
    name: 'MM3 test kernel',
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
