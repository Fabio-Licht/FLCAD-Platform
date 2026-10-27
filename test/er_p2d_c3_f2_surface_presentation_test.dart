import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/native/integrated_native_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/professional_cad_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/recognition_engine/recognition_result.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/models/reference_entity.dart';
import 'package:flcad_mobile/core/reference_engine/models/reference_geometry.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/smart_regions/models/geometry.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/core/surface_generation/models/surface_topology.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/test_output_path.dart';

// ER-P2D-C3-F2: after "Criar superfície" on a managed STL the viewport fell
// back to Flutter Canvas ("Payload Native GPU inválido para curva CAD") and
// the STL vanished. The BRep face was never at fault: `_upsertSurface`
// publishes its topology children (Edge### curves with `points`, Vertex###
// points with `origin`) which have no triangle payload by design, and the
// Canvas painter aborted the frame on `Vertex###` before reaching the managed
// STL, which `_commitManagedSnapshot` orders last.

const _channel = MethodChannel('flcad/native_viewport');
const _debugDir = r'C:\flcad_mobile\build\windows\x64\runner\Debug';
const _calota = r'C:\flcad_mobile\test_assets\real_meshes\CALOTA_INOXX.stl';
final _reportDir = testOutputPath(
  r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-C3-F2',
);

CadSceneEntity _calotaEntity() => const CadSceneEntity(
  id: 'calota',
  kind: CadSceneEntityKind.mesh,
  geometry: {
    'nodes': [-10.0, -10.0, 0.0, 10.0, -10.0, 0.0, 0.0, 10.0, 0.0],
    'triangles': [0, 1, 2],
    'normals': [0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0],
    'stlPresentation': true,
    'rootLinearRgb': [0.2, 0.4, 0.6],
  },
);

/// Exactly what `_upsertSurface` publishes for a confirmed surface whose OCCT
/// display mesh is already resident: the BRep face plus Edge###/Vertex###.
List<CadSceneEntity> _surfaceWithTopologyChildren() => const [
  CadSceneEntity(
    id: 'Surface001',
    kind: CadSceneEntityKind.surface,
    geometry: {
      'surfaceKind': 'plane',
      'parameters': {
        'origin': [0.0, 0.0, 1.0],
        'normal': [0.0, 0.0, 1.0],
      },
      'displayColor': 'definitiveSurface',
      'shaded': true,
      'displayMode': 'shadedWithEdges',
      'nodes': [-1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, 1.0, 1.0, -1.0, 1.0, 1.0],
      'triangles': [0, 1, 2, 0, 2, 3],
      'topologicalEdges': [
        [-1.0, -1.0, 1.0, 1.0, -1.0, 1.0],
        [1.0, -1.0, 1.0, 1.0, 1.0, 1.0],
        [1.0, 1.0, 1.0, -1.0, 1.0, 1.0],
        [-1.0, 1.0, 1.0, -1.0, -1.0, 1.0],
      ],
    },
  ),
  CadSceneEntity(
    id: 'Edge001',
    kind: CadSceneEntityKind.curve,
    geometry: {
      'points': [
        [-1.0, -1.0, 1.0],
        [1.0, -1.0, 1.0],
      ],
      'parentSurfaceId': 'Surface001',
      'surfaceEdgeIndex': 1,
      'displayColor': 'surfaceEdge',
      'strokeWidth': 1.0,
    },
  ),
  CadSceneEntity(
    id: 'Vertex001',
    kind: CadSceneEntityKind.point,
    geometry: {
      'origin': [-1.0, -1.0, 1.0],
      'parentSurfaceId': 'Surface001',
      'surfaceVertexIndex': 1,
      'displayColor': 'surfaceVertex',
    },
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'surface topology children are Flutter overlays, not Native CAD payload',
    () {
      final scene = CadSceneGraph()
        ..replaceAll([_calotaEntity(), ..._surfaceWithTopologyChildren()]);
      // Wireframe (2) on a bare STL is a legitimate, pre-existing fallback
      // ("malha CAD sem arestas topológicas"); it is unrelated to this bug.
      for (final style in [0, 1, 3]) {
        expect(
          nativeSceneUnsupportedReason(scene, style: style),
          isNull,
          reason: 'style $style',
        );
      }
      expect(
        nativeSceneUnsupportedReason(scene, style: 2),
        isNot(contains('curva CAD')),
      );
      expect(isNativeViewportOverlay(scene.find('Edge001')!), isTrue);
      expect(isNativeViewportOverlay(scene.find('Vertex001')!), isTrue);
      expect(isNativeViewportOverlay(scene.find('Surface001')!), isFalse);
      expect(isNativeViewportOverlay(scene.find('calota')!), isFalse);
      final snapshot = CadSceneDisplayAdapter().initial(scene);
      expect(
        snapshot.entities.map((entity) => entity['id']),
        unorderedEquals(['calota', 'Surface001']),
      );
      final surface = snapshot.entities.singleWhere(
        (entity) => entity['id'] == 'Surface001',
      );
      expect(surface['nodes'], isA<List>());
      expect(surface['triangles'], isA<List>());
      expect(surface['topologicalEdges'], hasLength(4));
      scene.dispose();
    },
  );

  test('generic curves and points keep the legitimate global fallback', () {
    final scene = CadSceneGraph()
      ..replaceAll([
        _calotaEntity(),
        const CadSceneEntity(
          id: 'curve',
          kind: CadSceneEntityKind.curve,
          geometry: {
            'points': [
              [0.0, 0.0, 0.0],
              [1.0, 1.0, 1.0],
            ],
          },
        ),
      ]);
    expect(nativeSceneUnsupportedReason(scene, style: 0), contains('curva CAD'));
    scene.upsert(
      const CadSceneEntity(
        id: 'curve',
        kind: CadSceneEntityKind.curve,
        geometry: {'parentSurfaceId': 'Surface001'},
      ),
    );
    expect(
      nativeSceneUnsupportedReason(scene, style: 0),
      contains('curva CAD'),
      reason: 'a surface child without analytic points is still unsupported',
    );
    scene.upsert(
      const CadSceneEntity(
        id: 'curve',
        kind: CadSceneEntityKind.point,
        geometry: {'parentSurfaceId': 'Surface001'},
      ),
    );
    expect(nativeSceneUnsupportedReason(scene, style: 0), contains('ponto CAD'));
    scene.dispose();
  });

  testWidgets(
    'Flutter Canvas paints the managed STL ordered after surface vertices',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      // `_commitManagedSnapshot` appends managed entities after the base scene.
      final scene = CadSceneGraph()
        ..replaceAll([..._surfaceWithTopologyChildren(), _calotaEntity()]);
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 30),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ProfessionalCadViewportWidget(scene: scene, camera: camera),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final state = tester.state(find.byType(ProfessionalCadViewportWidget));
      final caches = (state as dynamic).meshRenderCaches as Map;
      expect(caches.keys, containsAll(['calota', 'Surface001']));
      await tester.pumpWidget(const SizedBox());
      scene.dispose();
      camera.dispose();
    },
  );

  testWidgets(
    'Native GPU keeps CALOTA and Surface001 after surface topology publish',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      final scene = CadSceneGraph()..replaceAll([_calotaEntity()]);
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 30),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      );
      final host = <String, Map>{};
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'initialize') return 42;
        if (call.method == 'shutdown') host.clear();
        if (call.method == 'snapshot' || call.method == 'delta') {
          final message = call.arguments as Map;
          if (call.method == 'snapshot') host.clear();
          for (final entity in (message['entities'] as List).cast<Map>()) {
            final id = entity['id'] as String;
            if (entity['removed'] == true) {
              host.remove(id);
            } else {
              host[id] = {...?host[id], ...entity};
            }
          }
          return message['revision'];
        }
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: IntegratedCadViewportWidget(scene: scene, camera: camera),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(find.byType(Texture), findsOneWidget);
      expect(host.keys, ['calota']);

      for (final entity in _surfaceWithTopologyChildren()) {
        scene.upsert(entity);
      }
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.takeException(), isNull);
      expect(find.byType(Texture), findsOneWidget);
      expect(find.textContaining('toda a cena'), findsNothing);
      expect(find.textContaining('curva CAD'), findsNothing);
      expect(host.keys, unorderedEquals(['calota', 'Surface001']));
      expect(host['calota']!['visible'], isTrue);
      expect(host['Surface001']!['visible'], isTrue);
      expect(host['Surface001']!['nodes'], isA<List>());
      expect(
        tester
            .widget<ProfessionalCadViewportWidget>(
              find.byType(ProfessionalCadViewportWidget),
            )
            .renderMeshes,
        isFalse,
      );

      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      scene.dispose();
      camera.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        null,
      );
    },
    skip: !Platform.isWindows,
  );

  test(
    'Sketch-created planar surface publishes the same topology children',
    () async {
      final root = await Directory.systemTemp.createTemp('flcad_f2_sketch_');
      addTearDown(() async => root.delete(recursive: true));
      final projects = ProjectRepository(
        storage: LocalStorageService(rootDirectory: root),
      );
      final projectDirectory = await projects.directoryFor('project');
      final references = ReferenceRepository(projects: projects);
      await references.save('project', [_planeReference]);
      final kernels = KernelManager()
        ..register(_PlanarSurfaceKernel(), makeDefault: true);
      final cad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
        projectRepository: projects,
      );
      addTearDown(cad.dispose);
      await cad.runtime.open('project', projectDirectory);
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
        repository: projects,
      );
      final controller = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: commands,
        runtime: cad.runtime,
        referenceApi: ReferenceApi(
          engine: ReferenceEngine(repository: references),
        ),
      );
      addTearDown(controller.dispose);
      await controller.configureProject(
        projectId: 'project',
        projectDirectory: projectDirectory,
      );
      await controller.openSketch();
      controller.sketchApi!.builders.circle.build(const SketchVector(0, 0), 5);
      await controller.finishSketch();
      expect(controller.sketchReadyForSurface, isTrue);
      await controller.previewPlanarSurface();
      await controller.confirmSurface();
      expect(controller.activeSurface!.surfaceId, 'Surface001');

      final scene = cad.runtime.scene;
      final edge = scene.find('Edge001')!;
      final vertex = scene.find('Vertex001')!;
      expect(edge.kind, CadSceneEntityKind.curve);
      expect(edge.visible, isTrue);
      expect(edge.geometry['parentSurfaceId'], 'Surface001');
      expect(vertex.kind, CadSceneEntityKind.point);
      expect(vertex.geometry['origin'], isA<List>());
      // Same contract as the Recognition path: children are overlays and the
      // face (profile triangulation here) is the only native CAD payload.
      expect(isNativeViewportOverlay(edge), isTrue);
      expect(isNativeViewportOverlay(vertex), isTrue);
      expect(scene.find('Surface001')!.geometry['nodes'], isA<List>());
      expect(nativeSceneUnsupportedReason(scene, style: 0), isNull);
    },
  );

  final occ = '$_debugDir\\flcad_opencascade.dll';
  // Managed STL import needs the CAD asset filesystem helper, resolved by the
  // runtime from FLCAD_CAD_ASSET_FS_DLL in test processes, e.g.
  //   $env:FLCAD_CAD_ASSET_FS_DLL = "$_debugDir\cad_asset_fs.dll"
  final realFlowAvailable =
      Platform.isWindows &&
      Platform.environment['FLCAD_CAD_ASSET_FS_DLL'] != null &&
      File(occ).existsSync() &&
      File('$_debugDir\\cad_occ_bridge.dll').existsSync() &&
      File(_calota).existsSync();

  test(
    'managed CALOTA -> Region Growing -> Reconhecer Plano -> manual '
    'Criar superfície keeps STL and BRep visible on Native GPU',
    () async {
      final setDllDirectory = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Utf16>),
            int Function(Pointer<Utf16>)
          >('SetDllDirectoryW');
      final dllDirectory = _debugDir.toNativeUtf16();
      try {
        expect(setDllDirectory(dllDirectory), 1);
      } finally {
        calloc.free(dllDirectory);
      }
      final root = await Directory.systemTemp.createTemp('flcad_f2_calota_');
      addTearDown(() async {
        try {
          await root.delete(recursive: true);
        } on FileSystemException {
          // Native handles may close slightly after shutdown on Windows.
        }
      });
      final adapter = OpenCascadeKernelAdapter(
        bridge: OpenCascadeFFI.load(path: occ),
      );
      final kernels = KernelManager()..register(adapter, makeDefault: true);
      final cad = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
      );
      final projects = ProjectRepository(
        storage: LocalStorageService(rootDirectory: root),
      );
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
      );
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
      DesktopCadController? reopened;
      addTearDown(() async {
        controller.dispose();
        await cad.runtime.shutdown();
        cad.dispose();
        final second = reopened;
        if (second != null) {
          await second.runtime.shutdown();
          second.dispose();
        }
        await adapter.unload();
      });
      final project = Directory('${root.path}\\project')..createSync();
      const projectId = 'er-p2d-c3-f2';
      await cad.runtime.open(projectId, project);
      final parsed = _parseBinaryStl(File(_calota));
      final report = StringBuffer()
        ..writeln('ER-P2D-C3-F2 STL + BRep coexistence (controller pipeline)')
        ..writeln('fixture=$_calota')
        ..writeln(
          'diagnostic_note=controller/runtime evidence, not a GUI screenshot',
        );
      final stopwatch = Stopwatch()..start();
      final imported = await cad.runtime.importManagedStl(
        _calota,
        nativeBridgePath: '$_debugDir\\cad_occ_bridge.dll',
      );
      report.writeln('import_ms=${stopwatch.elapsedMilliseconds}');
      await controller.configureProject(
        projectId: projectId,
        projectDirectory: project,
      );
      final scene = cad.runtime.scene;
      final calotaId = imported.id;
      final calotaBefore = cad.runtime.document!.entities[calotaId]!;
      final calotaSceneBefore = scene.find(calotaId)!;
      final calotaJsonBefore = jsonEncode(calotaBefore.toJson());
      expect(calotaSceneBefore.visible, isTrue);
      expect(calotaBefore.data['managedStlAssets'], isA<Map>());
      expect(
        nativeSceneUnsupportedReason(scene, style: 0),
        isNull,
        reason: 'managed CALOTA alone must already be Native GPU eligible',
      );
      final idsBefore = scene.entities.map((entity) => entity.id).toList();
      final publishedBefore = CadSceneDisplayAdapter()
          .initial(scene)
          .entities
          .map((entity) => entity['id'])
          .toList();
      report
        ..writeln('calota_id=$calotaId')
        ..writeln('calota_stl_bounds=${_bounds(parsed.vertices)}')
        ..writeln('calota_stl_triangles=${parsed.triangles.length ~/ 3}')
        ..writeln('scene_before=$idsBefore')
        ..writeln('native_published_before=$publishedBefore')
        ..writeln(
          'native_fallback_before=${nativeSceneUnsupportedReason(scene, style: 0)}',
        );

      // Pick the same planar seed used by ER-P2D-S1 (original triangle 0).
      final ray = _rayForTriangle(parsed.vertices, parsed.triangles, 0);
      stopwatch.reset();
      await controller.recognizePick(
        pick: CadViewportPick(
          entityId: calotaId,
          hit: MeshHit(triangleIndex: 0, point: ray.origin, distance: 10),
          ray: ray,
        ),
        allowTechnicalStl: true,
        requestedType: PrimitiveType.plane,
      );
      report.writeln('recognition_ms=${stopwatch.elapsedMilliseconds}');
      expect(controller.error, isNull);
      final recognition = controller.activeRecognitionResult;
      expect(recognition, isNotNull, reason: controller.error);
      expect(recognition!.type, RecognitionResultType.plane);
      report
        ..writeln('recognition_id=${recognition.id}')
        ..writeln('recognition_origin=${recognition.parameters['origin']}')
        ..writeln('recognition_normal=${recognition.parameters['normal']}')
        ..writeln('recognition_area=${recognition.parameters['area']}')
        ..writeln(
          'recognition_classification=${recognition.parameters['planarClassification']}',
        )
        ..writeln(
          'region_triangles=${controller.activeContext?.region?.triangleIndices.length}',
        );
      expect(controller.canOpenSurfaceCreation, isTrue);

      // "Criar superfície": preview, then explicit manual confirmation when
      // the automatic gate does not approve the CAD surface.
      controller.previewActiveRecognition();
      expect(controller.activeSurfaceAssistantSuggestion, isNotNull);
      expect(scene.find('surface-assistant-preview'), isNotNull);
      final manual = !controller.canCreateSurfaceFromAssistant;
      if (manual) {
        expect(controller.canRequestManualSurfaceAction, isTrue);
        controller.prepareManualRecognitionApproval('surface');
      }
      report.writeln('creation_approval=${manual ? 'manual' : 'automatic'}');
      stopwatch.reset();
      await controller.confirmSurfaceAssistantSuggestion();
      report.writeln('surface_create_ms=${stopwatch.elapsedMilliseconds}');
      final surface = controller.activeSurface!;
      final surfaceId = surface.surfaceId;
      expect(surfaceId, 'Surface001');
      expect(scene.find('surface-assistant-preview'), isNull);

      // Document: both entities, STL untouched, BRep valid.
      final document = cad.runtime.document!;
      final calotaAfter = document.entities[calotaId]!;
      expect(jsonEncode(calotaAfter.toJson()), calotaJsonBefore);
      final surfaceEntity = document.entities[surfaceId]!;
      expect(surfaceEntity.kind, CadDocumentEntityKind.surface);
      expect(surfaceEntity.shape, isNotNull);
      expect(surfaceEntity.shape!.type, CADShapeType.face);
      final topology = SurfaceTopology.fromJson(
        (surface.parameters['topology'] as Map).cast<String, dynamic>(),
      );
      expect(topology.edges, hasLength(4));
      expect(topology.vertices, hasLength(4));
      expect(topology.area, greaterThan(0));
      expect(topology.perimeter, greaterThan(0));
      final diagnostics = await adapter.validate(surfaceEntity.shape!, const {});
      expect(
        diagnostics.where((item) => item.toLowerCase().startsWith('error')),
        isEmpty,
        reason: diagnostics.join('; '),
      );
      for (final edge in topology.edges) {
        expect(document.entities[edge.id], isNotNull);
      }
      for (final vertex in topology.vertices) {
        expect(document.entities[vertex.id], isNotNull);
      }
      report
        ..writeln('surface_id=$surfaceId')
        ..writeln('surface_shape=${surfaceEntity.shape!.toJson()}')
        ..writeln('surface_area=${topology.area}')
        ..writeln('surface_perimeter=${topology.perimeter}')
        ..writeln('surface_edges=${topology.edges.map((e) => e.id).toList()}')
        ..writeln(
          'surface_vertices=${topology.vertices.map((v) => v.id).toList()}',
        )
        ..writeln('calota_document_unchanged=true');

      // Scene: STL still visible with identical geometry, surface has a real
      // OCCT display mesh, children are overlays, no global fallback.
      void expectCoexistence(CadSceneGraph scene, String label) {
        final calotaScene = scene.find(calotaId)!;
        expect(calotaScene.visible, isTrue, reason: label);
        expect(calotaScene.geometry['nodes'], isA<List>(), reason: label);
        final surfaceScene = scene.find(surfaceId)!;
        expect(surfaceScene.visible, isTrue, reason: label);
        expect(surfaceScene.kind, CadSceneEntityKind.surface, reason: label);
        final nodes = (surfaceScene.geometry['nodes'] as List).cast<num>();
        final triangles = (surfaceScene.geometry['triangles'] as List)
            .cast<num>();
        expect(nodes.length % 3, 0, reason: label);
        expect(nodes, isNotEmpty, reason: label);
        expect(triangles.length % 3, 0, reason: label);
        expect(triangles, isNotEmpty, reason: label);
        expect(
          triangles.every((index) => index >= 0 && index < nodes.length ~/ 3),
          isTrue,
          reason: label,
        );
        expect(
          surfaceScene.geometry['topologicalEdges'],
          hasLength(4),
          reason: label,
        );
        for (final edge in topology.edges) {
          final child = scene.find(edge.id)!;
          expect(child.kind, CadSceneEntityKind.curve, reason: label);
          expect(isNativeViewportOverlay(child), isTrue, reason: label);
        }
        for (final vertex in topology.vertices) {
          final child = scene.find(vertex.id)!;
          expect(child.kind, CadSceneEntityKind.point, reason: label);
          expect(isNativeViewportOverlay(child), isTrue, reason: label);
        }
        // Shaded / Arestas / Transparência. Wireframe on a managed STL keeps
        // its pre-existing "sem arestas topológicas" policy.
        for (final style in [0, 1, 3]) {
          expect(
            nativeSceneUnsupportedReason(scene, style: style),
            isNull,
            reason: '$label style $style',
          );
        }
        expect(
          nativeSceneUnsupportedReason(scene, style: 2),
          isNot(contains('curva CAD')),
          reason: label,
        );
        final published = CadSceneDisplayAdapter()
            .initial(scene)
            .entities
            .map((entity) => entity['id'])
            .toList();
        expect(published, containsAll([calotaId, surfaceId]), reason: label);
        for (final childId in [
          ...topology.edges.map((edge) => edge.id),
          ...topology.vertices.map((vertex) => vertex.id),
        ]) {
          expect(published, isNot(contains(childId)), reason: label);
        }
      }

      expectCoexistence(scene, 'after create');
      expect(
        identical(scene.find(calotaId)!.geometry, calotaSceneBefore.geometry),
        isTrue,
        reason: 'managed STL presentation is retained, not rebuilt',
      );

      // Placement: the surface mesh is centred on the recognised origin and
      // lies inside the STL envelope (planar extent = sqrt(area) / 2).
      final surfaceScene = scene.find(surfaceId)!;
      final nodes = (surfaceScene.geometry['nodes'] as List).cast<num>();
      final bounds = _bounds(nodes);
      final origin = (recognition.parameters['origin'] as List).cast<num>();
      final halfSpan = math.sqrt(topology.area <= 0 ? 1 : topology.area) / 2;
      for (var axis = 0; axis < 3; axis++) {
        final center = (bounds.$1[axis] + bounds.$2[axis]) / 2;
        expect(
          (center - origin[axis]).abs(),
          lessThan(1e-3 + halfSpan),
          reason: 'surface centre axis $axis',
        );
      }
      // The managed STL keeps its geometry native-side; the source file is the
      // authoritative envelope for the placement check.
      final meshBounds = _bounds(parsed.vertices);
      final margin = halfSpan + 1;
      for (var axis = 0; axis < 3; axis++) {
        expect(
          bounds.$1[axis],
          greaterThan(meshBounds.$1[axis] - margin),
          reason: 'surface min axis $axis inside STL envelope',
        );
        expect(
          bounds.$2[axis],
          lessThan(meshBounds.$2[axis] + margin),
          reason: 'surface max axis $axis inside STL envelope',
        );
      }
      report
        ..writeln('surface_display_nodes=${nodes.length ~/ 3}')
        ..writeln(
          'surface_display_triangles=${(surfaceScene.geometry['triangles'] as List).length ~/ 3}',
        )
        ..writeln('surface_display_bounds_min=${bounds.$1}')
        ..writeln('surface_display_bounds_max=${bounds.$2}')
        ..writeln(
          'scene_after=${scene.entities.map((e) => e.id).toList()}',
        )
        ..writeln(
          'native_published_after=${CadSceneDisplayAdapter().initial(scene).entities.map((e) => e['id']).toList()}',
        )
        ..writeln(
          'native_fallback_after=${nativeSceneUnsupportedReason(scene, style: 0)}',
        )
        ..writeln(
          'overlays_after=${scene.entities.where(isNativeViewportOverlay).map((e) => e.id).toList()}',
        );

      // STEP round-trip of the resident OCCT face through the existing
      // exportFile/importFile ABI. The document and the scene stay as they
      // were: this only proves the BRep face survives STEP without a kernel
      // change.
      final stepFile = File('${project.path}\\Surface001.step');
      final stepWatch = Stopwatch()..start();
      await adapter.exportFile(
        surfaceEntity.shape!,
        stepFile.path,
        KernelExchangeFormat.step,
      );
      final stepExportMs = stepWatch.elapsedMilliseconds;
      final stepBytes = stepFile.readAsBytesSync();
      expect(stepBytes.length, greaterThan(80));
      expect(
        utf8.decode(stepBytes.take(64).toList(), allowMalformed: true),
        contains('ISO-10303-21'),
      );
      stepWatch.reset();
      final reimported = await adapter.importFile(
        stepFile.path,
        KernelExchangeFormat.step,
        projectId: projectId,
      );
      final stepImportMs = stepWatch.elapsedMilliseconds;
      expect(
        reimported.type,
        anyOf(
          CADShapeType.face,
          CADShapeType.shell,
          CADShapeType.compound,
        ),
      );
      // flcad_occ_surface_topology rejects anything that is not a TopoDS_Face.
      // STEPControl_Reader.OneShape may wrap the face; extracting it would be
      // a kernel change, so topology is compared only when the reimport is a
      // face. Validation always runs.
      KernelSurfaceTopology? reimportedTopology;
      if (reimported.type == CADShapeType.face) {
        reimportedTopology = await adapter.inspectSurfaceTopology(reimported);
        expect(reimportedTopology.valid, isTrue);
        expect(reimportedTopology.faceCount, 1);
        expect(reimportedTopology.edgeCount, topology.edges.length);
        expect(reimportedTopology.vertexCount, topology.vertices.length);
        expect(
          (reimportedTopology.area - topology.area).abs(),
          lessThan(math.max(1e-3, topology.area * 1e-4)),
          reason:
              'reimported area ${reimportedTopology.area} vs ${topology.area}',
        );
      }
      final reimportedDiagnostics = await adapter.validate(
        reimported,
        const {},
      );
      expect(
        reimportedDiagnostics.where(
          (item) => item.toLowerCase().startsWith('error'),
        ),
        isEmpty,
        reason: reimportedDiagnostics.join('; '),
      );
      expect(jsonEncode(document.entities[calotaId]!.toJson()), calotaJsonBefore);
      expect(
        document.entities[surfaceId]!.shape!.fingerprint,
        surfaceEntity.shape!.fingerprint,
      );
      expect(scene.find(calotaId)!.visible, isTrue);
      expect(scene.find(surfaceId)!.visible, isTrue);
      report
        ..writeln('step_export_ms=$stepExportMs')
        ..writeln('step_bytes=${stepBytes.length}')
        ..writeln('step_reimport_ms=$stepImportMs')
        ..writeln('step_reimport_type=${reimported.type.name}')
        ..writeln(
          'step_reimport_faces=${reimportedTopology?.faceCount ?? 'n/a'}',
        )
        ..writeln(
          'step_reimport_edges=${reimportedTopology?.edgeCount ?? 'n/a'}',
        )
        ..writeln(
          'step_reimport_vertices=${reimportedTopology?.vertexCount ?? 'n/a'}',
        )
        ..writeln('step_reimport_area=${reimportedTopology?.area ?? 'n/a'}')
        ..writeln('step_reimport_valid=${reimportedTopology?.valid ?? 'n/a'}')
        ..writeln(
          'step_topology_compared=${reimportedTopology != null}',
        )
        ..writeln('step_document_unchanged=true');

      // Independent selection.
      cad.runtime.select({surfaceId});
      expect(scene.find(surfaceId)!.selected, isTrue);
      expect(scene.find(calotaId)!.selected, isFalse);
      cad.runtime.select({calotaId});
      expect(scene.find(calotaId)!.selected, isTrue);
      expect(scene.find(surfaceId)!.selected, isFalse);
      cad.runtime.select({});

      // Undo / Redo.
      await commands.undo();
      expect(cad.runtime.document!.entities[surfaceId], isNull);
      expect(scene.find(surfaceId), isNull);
      expect(scene.find('Edge001'), isNull);
      expect(scene.find(calotaId)!.visible, isTrue);
      expect(
        jsonEncode(cad.runtime.document!.entities[calotaId]!.toJson()),
        calotaJsonBefore,
      );
      expect(nativeSceneUnsupportedReason(scene, style: 0), isNull);
      report.writeln(
        'undo_scene=${scene.entities.map((e) => e.id).toList()} '
        'fallback=${nativeSceneUnsupportedReason(scene, style: 0)}',
      );
      await commands.redo();
      expect(cad.runtime.document!.entities[surfaceId], isNotNull);
      expectCoexistence(scene, 'after redo');
      report.writeln(
        'redo_scene=${scene.entities.map((e) => e.id).toList()} '
        'fallback=${nativeSceneUnsupportedReason(scene, style: 0)}',
      );

      // Save / Open.
      await cad.runtime.save();
      final second = DesktopCadController(
        kernels: kernels,
        projects: ProjectManager.instance,
      );
      reopened = second;
      await second.runtime.open(projectId, project);
      final reopenedDocument = second.runtime.document!;
      expect(reopenedDocument.entities[calotaId], isNotNull);
      expect(reopenedDocument.entities[surfaceId], isNotNull);
      expect(reopenedDocument.entities[surfaceId]!.shape, isNotNull);
      expectCoexistence(second.runtime.scene, 'after reopen');
      report.writeln(
        'reopen_scene=${second.runtime.scene.entities.map((e) => e.id).toList()} '
        'fallback=${nativeSceneUnsupportedReason(second.runtime.scene, style: 0)}',
      );

      final out = File('$_reportDir\\er_p2d_c3_f2_report.txt');
      out.parent.createSync(recursive: true);
      out.writeAsStringSync(report.toString());
    },
    skip: realFlowAvailable
        ? false
        : 'OCCT Debug DLLs, FLCAD_CAD_ASSET_FS_DLL or CALOTA fixture missing',
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

(List<double>, List<double>) _bounds(List<num> nodes) {
  final min = [double.infinity, double.infinity, double.infinity];
  final max = [
    double.negativeInfinity,
    double.negativeInfinity,
    double.negativeInfinity,
  ];
  for (var index = 0; index + 2 < nodes.length; index += 3) {
    for (var axis = 0; axis < 3; axis++) {
      final value = nodes[index + axis].toDouble();
      if (value < min[axis]) min[axis] = value;
      if (value > max[axis]) max[axis] = value;
    }
  }
  return (min, max);
}

MeshRay _rayForTriangle(List<double> vertices, List<int> triangles, int index) {
  Vector3 vertex(int corner) {
    final cursor = triangles[index * 3 + corner] * 3;
    return Vector3(
      vertices[cursor],
      vertices[cursor + 1],
      vertices[cursor + 2],
    );
  }

  final a = vertex(0), b = vertex(1), c = vertex(2);
  final centroid = Vector3(
    (a.x + b.x + c.x) / 3,
    (a.y + b.y + c.y) / 3,
    (a.z + b.z + c.z) / 3,
  );
  var normal = (b - a).cross(c - a);
  final length = normal.length;
  normal = length <= 1e-12 ? const Vector3(0, 0, 1) : normal / length;
  return MeshRay(
    centroid + normal * 10,
    Vector3(-normal.x, -normal.y, -normal.z),
  );
}

({List<double> vertices, List<int> triangles}) _parseBinaryStl(File file) {
  final bytes = file.readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  final count = data.getUint32(80, Endian.little);
  final vertices = List<double>.filled(count * 9, 0);
  final triangles = List<int>.generate(count * 3, (index) => index);
  var cursor = 84;
  var offset = 0;
  for (var face = 0; face < count; face++) {
    cursor += 12;
    for (var corner = 0; corner < 3; corner++) {
      vertices[offset] = data.getFloat32(cursor, Endian.little);
      vertices[offset + 1] = data.getFloat32(cursor + 4, Endian.little);
      vertices[offset + 2] = data.getFloat32(cursor + 8, Endian.little);
      cursor += 12;
      offset += 3;
    }
    cursor += 2;
  }
  return (vertices: vertices, triangles: triangles);
}

final _planeReference = ReferenceEntity(
  id: 'plane-reference',
  projectId: 'project',
  name: 'Base Plane',
  geometry: const PlaneGeometry(Vec3(0, 0, 0), Vec3(0, 0, 1)),
  mode: ReferenceMode.staticReference,
  status: ReferenceStatus.valid,
  dna: const ReferenceDNA('plane', 'region', 'z0', 'hash'),
  analytics: const ReferenceAnalytics(
    precision: 1,
    rmsError: 0,
    maxDeviation: 0,
    confidence: 1,
    fitQuality: 1,
    areaUsed: 1,
    coverage: 1,
    pointCount: 3,
  ),
  recipe: const ReferenceRecipe('plane', {}, ['region']),
  version: 1,
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  dependencies: const ['region'],
  metadata: const {},
);

class _PlanarSurfaceKernel
    implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'f2-sketch-kernel',
    name: 'ER-P2D-C3-F2 planar kernel',
    version: '1',
    capabilities: KernelCapabilities({KernelCapability.planeSurface}),
    vendor: 'FLCAD',
  );

  @override
  Future<KernelHealth> healthCheck() async =>
      KernelHealth(KernelHealthStatus.healthy, 'ok', DateTime(2000));
  @override
  Future<void> begin(KernelTransaction transaction) async {}
  @override
  Future<void> commit(KernelTransaction transaction) async {}
  @override
  Future<void> rollback(KernelTransaction transaction) async {}
  @override
  Future<void> unload() async {}

  @override
  Future<ShapeHandle> create(
    String operation,
    Map<String, dynamic> parameters, {
    required String persistentId,
    required CADShapeType expectedType,
    required KernelTransaction transaction,
  }) async => ShapeHandle.reference(
    persistentId: persistentId,
    kernelId: descriptor.id,
    type: expectedType,
    fingerprint: '$operation:$persistentId',
  );

  @override
  Future<List<String>> validate(ShapeHandle handle, Set<String> checks) async =>
      const [];

  @override
  Future<KernelSurfaceOperationResult> executeSurfaceOperation(
    ShapeHandle surface,
    String operation,
    Map<String, dynamic> parameters, {
    required String projectId,
  }) async => KernelSurfaceOperationResult(
    supported: true,
    diagnostic: 'ok',
    result: ShapeHandle.reference(
      persistentId: '$projectId:$operation',
      kernelId: descriptor.id,
      type: CADShapeType.face,
      fingerprint: operation,
    ),
    undoToken: 'undo:$operation',
    redoToken: 'redo:$operation',
  );

  @override
  Future<void> rollbackSurfaceOperation(String undoToken) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
