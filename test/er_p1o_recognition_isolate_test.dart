import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/professional_cad_viewport_widget.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_context.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/editable_surface_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/mesh_region_builder.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/surface_selection_engine.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/surface_selection_policy.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/technical_stl_pick_resolver.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/cad_selection_palette.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/import_export/api/import_export_api.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/surface_recognition/models/surface_recognition_models.dart';
import 'package:flcad_mobile/core/surface_recognition/segmentation/region_growing.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('capturing mesh wrappers in Isolate.run is unsendable', () async {
    final geometry = _unsendablePlane();
    await expectLater(
      Isolate.run(
        () => runRegionGrowingInIsolate(
          regionGrowingIsolatePayload(
            geometry: geometry,
            fingerprint: 'captured',
            settings: const SurfaceRecognitionSettings(minimumTriangles: 1),
          ),
        ),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.toString(),
          'message',
          contains('unsendable'),
        ),
      ),
    );
  });

  test(
    'recognizePick uses TechnicalStl resolver then a sendable Region Growing worker',
    () async {
      final geometry = _unsendablePlane();
      final session = await _RecognitionSession.open(
        geometry: geometry,
        entityId: 'stl-plane',
      );
      addTearDown(session.dispose);

      await session.controller.recognizePick(
        pick: const CadViewportPick(
          entityId: 'stl-plane',
          hit: MeshHit(triangleIndex: 0, point: Vector3(1, 1, 0), distance: 10),
          ray: MeshRay(Vector3(1, 1, 10), Vector3(0, 0, -1)),
        ),
        allowTechnicalStl: true,
      );

      expect(session.controller.error ?? '', isNot(contains('unsendable')));
      expect(session.resolverHits, 1);
      expect(
        session.controller.report,
        isNotNull,
        reason: session.controller.error,
      );
      expect(session.controller.hypotheses, isNotEmpty);
    },
  );

  test(
    'CALOTA_INOXX.stl smoke through recognizePick has no isolate error',
    () async {
      const path = r'C:\flcad_mobile\test_assets\real_meshes\CALOTA_INOXX.stl';
      final file = File(path);
      expect(file.existsSync(), isTrue);
      final parsed = _parseStl(file);
      final geometry = KernelMeshGeometry(
        nodes: parsed.vertices,
        triangles: parsed.triangles,
      );
      const seed = 0;
      final ray = _rayForTriangle(geometry, seed);
      final session = await _RecognitionSession.open(
        geometry: geometry,
        entityId: 'calota',
      );
      addTearDown(session.dispose);

      final stopwatch = Stopwatch()..start();
      await session.controller.recognizePick(
        pick: CadViewportPick(
          entityId: 'calota',
          hit: MeshHit(triangleIndex: seed, point: ray.origin, distance: 1),
          ray: ray,
        ),
        allowTechnicalStl: true,
      );
      stopwatch.stop();

      expect(session.controller.error ?? '', isNot(contains('unsendable')));
      expect(session.resolverHits, 1);
      expect(
        session.controller.report,
        isNotNull,
        reason: session.controller.error,
      );
      expect(session.controller.hypotheses, isNotEmpty);

      final winner = session.controller.hypotheses.first.recognition.winner;
      final diagnostics =
          session.cad.runtime.read<Map>('recognition.planarDiagnostics') ??
          const {};
      final managedAssetsBefore = session
          .cad
          .runtime
          .document!
          .entities['calota']!
          .data['managedStlAssets'];
      session.controller.clearRecognitionSelection();
      expect(session.controller.activeContext, isNull);
      expect(session.controller.report, isNull);
      expect(
        session
            .cad
            .runtime
            .document!
            .entities['calota']!
            .data['managedStlAssets'],
        managedAssetsBefore,
      );
      final report = StringBuffer()
        ..writeln('ER-P1O CALOTA isolate smoke')
        ..writeln('head=a5a3972245a9f662a097af5cc827a8c502491ad9')
        ..writeln('fixture=$path')
        ..writeln('triangles=${geometry.triangles.length ~/ 3}')
        ..writeln('seed=$seed')
        ..writeln('isolate_error=none')
        ..writeln('winner=${winner.type.name}')
        ..writeln('rms=${winner.statistics.rms}')
        ..writeln('max=${winner.statistics.maximum}')
        ..writeln('planarClassification=${diagnostics['planarClassification']}')
        ..writeln('selectedTriangles=${diagnostics['selectedTriangles']}')
        ..writeln('managed_stl_preserved_after_clear=true')
        ..writeln('processing_ms=${stopwatch.elapsedMilliseconds}')
        ..writeln('gui_capture=not performed');
      final out = File(
        r'C:\flcad_mobile\test_assets\screenshots\ER-P1O\er_p1o_report.txt',
      );
      out.parent.createSync(recursive: true);
      out.writeAsStringSync(report.toString());
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'CALOTA requested versus returned recognition mode audit',
    () async {
      const path = r'C:\flcad_mobile\test_assets\real_meshes\CALOTA_INOXX.stl';
      final parsed = _parseStl(File(path));
      final welded = _weld(parsed.vertices, parsed.triangles);
      final geometry = KernelMeshGeometry(
        nodes: welded.vertices,
        triangles: welded.triangles,
      );
      final session = await _RecognitionSession.open(
        geometry: geometry,
        entityId: 'calota',
        managed: false,
      );
      addTearDown(session.dispose);
      final segmented = const ProfessionalRegionGrowing().segment(
        MeshSurfaceData.fromKernel(geometry),
        'calota-real-region',
        settings: const SurfaceRecognitionSettings(
          planar: true,
          planarToleranceMm: .5,
          seedTriangle: 0,
        ),
      );
      final region = segmented.regions
          .where((candidate) => candidate.triangleIndices.isNotEmpty)
          .reduce(
            (first, second) =>
                first.triangleIndices.length >= second.triangleIndices.length
                ? first
                : second,
          );
      final selection = BridgeSelection(
        id: region.id,
        entityId: 'calota',
        kind: BridgeSelectionKind.meshRegion,
        geometry: geometry,
        triangleIndices: region.triangleIndices.toSet(),
      );
      session.controller.activeSelection = selection;
      session.controller.activePick = const CadViewportPick(
        entityId: 'calota',
        hit: MeshHit(triangleIndex: 0, point: Vector3.zero, distance: 1),
      );
      session.controller.activeContext = BridgeContext(
        projectId: 'project',
        meshId: 'calota',
        meshFingerprint: 'calota-real-region',
        userConfirmed: false,
        region: const MeshRegionBuilder().build(
          meshId: 'calota',
          selection: selection,
        ),
      );
      final automaticWatch = Stopwatch()..start();
      await session.controller.detectAutomatically();
      automaticWatch.stop();
      expect(
        session.controller.error,
        isNull,
        reason: session.controller.error,
      );
      final automaticType =
          session.controller.activeRecognitionResult?.type.name;
      final automaticTriangles =
          session.controller.activeContext?.region?.triangleIndices.length;

      await session.controller.detect('plane');
      final planeType = session.controller.activeRecognitionResult?.type.name;
      final planeMatches = !session.controller.hasRecognitionModeMismatch;
      final planeAuthorized = session.controller.canCreatePlaneReference;

      await session.controller.detect('sphere');
      final sphereType = session.controller.activeRecognitionResult?.type.name;
      final sphereMatches = !session.controller.hasRecognitionModeMismatch;
      final sphereAuthorized = session.controller.canCreateNonPlaneReference;
      final automaticWinner = session.controller.automaticRecognitionWinnerType;

      final directedWatch = Stopwatch()..start();
      await session.controller.recognizeDirected(PrimitiveType.plane);
      directedWatch.stop();
      final directedWinner =
          session.controller.report?.primitives.firstOrNull?.recognition.winner;
      final directedClassification =
          (session.cad.runtime.read<Map>('recognition.planarDiagnostics') ??
          const {})['planarClassification'];
      final editable = session.controller.editableSelection!;
      final initialSelectionCount = editable.triangleCount;
      final initialSelectionTriangles = Set<int>.from(
        editable.currentTriangles,
      );
      await session.controller.expandRecognitionSelection();
      final expandOneCount = session.controller.selectionTriangleCount;
      await session.controller.expandRecognitionSelection();
      final expandTwoCount = session.controller.selectionTriangleCount;
      await session.controller.contractRecognitionSelection();
      final contractCount = session.controller.selectionTriangleCount;
      final beforeLocalAdd = session.controller.selectionTriangleCount;
      final currentTriangles = {
        ...session.controller.editableSelection!.currentTriangles,
      };
      final adjacent = currentTriangles
          .map(session.controller.editableSelection!.neighborsOf)
          .expand((values) => values)
          .firstWhere((value) => !currentTriangles.contains(value));
      session.controller.setSelectionTool(RecognitionSelectionTool.add);
      await session.controller.editRecognitionSelection(
        _pickForOriginalTriangle(geometry, adjacent),
      );
      final localAddCount = session.controller.selectionTriangleCount;
      session.controller.setSelectionTool(RecognitionSelectionTool.remove);
      await session.controller.editRecognitionSelection(
        _pickForOriginalTriangle(geometry, adjacent),
      );
      final localRemoveCount = session.controller.selectionTriangleCount;
      final editedSelectionTriangles = Set<int>.from(
        session.controller.editableSelection!.currentTriangles,
      );
      await session.controller.recognizeDirected(PrimitiveType.plane);
      final editedWinner =
          session.controller.report?.primitives.firstOrNull?.recognition.winner;
      final editedReferenceAuthorized =
          session.controller.canCreatePlaneReference;
      final editedDiagnosticOnly =
          session.controller.isActiveRecognitionDiagnosticOnly;
      final editedResult = session.controller.activeRecognitionResult;
      final editedSelectionCount = session.controller.selectionTriangleCount;
      await session.controller.undoRecognitionSelection();
      final localUndoCount = session.controller.selectionTriangleCount;
      await session.controller.redoRecognitionSelection();
      final localRedoCount = session.controller.selectionTriangleCount;
      session.controller.clearRecognitionSelection();
      final clearedSelection = !session.controller.hasEditableSelection;
      await session.controller.recognizePick(
        pick: CadViewportPick(
          entityId: 'calota',
          hit: MeshHit(
            triangleIndex: 201756,
            point: _rayForTriangle(geometry, 201756).origin,
            distance: 1,
          ),
          ray: _rayForTriangle(geometry, 201756),
        ),
        allowTechnicalStl: false,
      );
      final newSelectionCount = session.controller.selectionTriangleCount;
      final beforeSvg = File(
        r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-S1\calota_selection_before.svg',
      );
      final afterSvg = File(
        r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-S1\calota_selection_after.svg',
      );
      _writeSelectionSvg(
        geometry,
        initialSelectionTriangles,
        beforeSvg,
        label: 'Diagnostic: initial CALOTA selection',
      );
      _writeSelectionSvg(
        geometry,
        editedSelectionTriangles,
        afterSvg,
        label: 'Diagnostic: edited CALOTA selection',
      );

      final report = StringBuffer()
        ..writeln('ER-P2D-S1 CALOTA editable selection and recognition')
        ..writeln('fixture=$path')
        ..writeln(
          'diagnostic_note=SVG and PNG artifacts are diagnostic, not GUI screenshots',
        )
        ..writeln(
          'region_source=planar-region-growing welded seed=0 tolerance=0.5',
        )
        ..writeln('automatic_requested=automatic')
        ..writeln('automatic_returned=$automaticType')
        ..writeln('automatic_triangles=$automaticTriangles')
        ..writeln('automatic_elapsed_ms=${automaticWatch.elapsedMilliseconds}')
        ..writeln('plane_requested=plane')
        ..writeln('plane_returned=$planeType')
        ..writeln('plane_matches=$planeMatches')
        ..writeln('plane_reference_authorized=$planeAuthorized')
        ..writeln('sphere_requested=sphere')
        ..writeln('sphere_returned=$sphereType')
        ..writeln('sphere_matches=$sphereMatches')
        ..writeln('sphere_reference_authorized=$sphereAuthorized')
        ..writeln('automatic_winner_for_filters=$automaticWinner')
        ..writeln('directed_requested=plane')
        ..writeln('directed_returned=${directedWinner?.type.name}')
        ..writeln('directed_elapsed_ms=${directedWatch.elapsedMilliseconds}')
        ..writeln('directed_rms=${directedWinner?.statistics.rms}')
        ..writeln('directed_maximum=${directedWinner?.statistics.maximum}')
        ..writeln('directed_classification=$directedClassification')
        ..writeln(
          'new_region_reference_authorized='
          '${session.controller.canCreatePlaneReference}',
        )
        ..writeln('selection_initial_triangles=$initialSelectionCount')
        ..writeln('selection_expand_1=$expandOneCount')
        ..writeln('selection_expand_2=$expandTwoCount')
        ..writeln('selection_contract_1=$contractCount')
        ..writeln('selection_local_add=$localAddCount (before=$beforeLocalAdd)')
        ..writeln('selection_local_remove=$localRemoveCount')
        ..writeln('selection_after_edit=$editedSelectionCount')
        ..writeln('selection_edited_winner=${editedWinner?.type.name}')
        ..writeln('selection_edited_rms=${editedWinner?.statistics.rms}')
        ..writeln(
          'selection_edited_maximum=${editedWinner?.statistics.maximum}',
        )
        ..writeln(
          'selection_edited_classification='
          '${editedResult?.parameters['planarClassification']}',
        )
        ..writeln('selection_edited_confidence=${editedResult?.confidence}')
        ..writeln(
          'selection_edited_tolerance_mm='
          '${editedResult?.parameters['dimensionalToleranceMm']}',
        )
        ..writeln('selection_edited_diagnostic_only=$editedDiagnosticOnly')
        ..writeln(
          'selection_edited_reference_authorized='
          '$editedReferenceAuthorized',
        )
        ..writeln(
          'selection_edited_cad_surface_approved='
          '${editedResult?.parameters['cadSurfaceApproved']}',
        )
        ..writeln('selection_local_undo=$localUndoCount')
        ..writeln('selection_local_redo=$localRedoCount')
        ..writeln('selection_cleared=$clearedSelection')
        ..writeln('selection_after_new_region=$newSelectionCount')
        ..writeln('visual_before=${beforeSvg.path}')
        ..writeln('visual_after=${afterSvg.path}')
        ..writeln('error=${session.controller.error}');
      for (final path in const [
        r'C:\flcad_mobile\test_assets\screenshots\ER-P1Q\er_p1q_real_mode_report.txt',
        r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-S1\er_p2d_s1_report.txt',
      ]) {
        final out = File(path);
        out.parent.createSync(recursive: true);
        out.writeAsStringSync(report.toString());
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'CALOTA editable adjacency diagnostic timing',
    () {
      const path = r'C:\flcad_mobile\test_assets\real_meshes\CALOTA_INOXX.stl';
      final parsed = _parseStl(File(path));
      final welded = _weld(parsed.vertices, parsed.triangles);
      final geometry = KernelMeshGeometry(
        nodes: welded.vertices,
        triangles: welded.triangles,
      );
      final selection = EditableSurfaceSelection(
        projectId: 'project',
        meshId: 'calota',
        meshFingerprint: 'calota',
        entityId: 'calota',
        geometry: geometry,
        initialTriangles: const {0},
        area: 0,
      );
      final watch = Stopwatch()..start();
      final ring = selection.expandRing();
      watch.stop();
      // ignore: avoid_print
      print(
        'CALOTA adjacency diagnostic: '
        'triangles=${geometry.triangles.length ~/ 3} '
        'elapsed_ms=${watch.elapsedMilliseconds} ring=${ring.length}',
      );
      expect(ring, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'managed LOD brush paints original triangles and reuses the technical BVH',
    () async {
      final geometry = _managedRoofGeometry();
      final session = await _RecognitionSession.open(
        geometry: geometry,
        entityId: 'calota',
        managed: false,
        resolverManaged: true,
        meshFingerprint: 'sha-calota:calota',
      );
      addTearDown(session.dispose);

      final initialRay = _rayForTriangle(geometry, 0);
      await session.controller.recognizePick(
        pick: CadViewportPick(
          entityId: 'calota',
          hit: MeshHit(triangleIndex: 0, point: initialRay.origin, distance: 1),
          ray: initialRay,
        ),
        allowTechnicalStl: true,
      );
      expect(session.controller.error, isNull);
      expect(session.controller.hasEditableSelection, isTrue);
      expect(session.resolverHits, 0);
      final editable = session.controller.editableSelection!;
      final current = {...editable.currentTriangles};
      final adjacent = current
          .map(editable.neighborsOf)
          .expand((values) => values)
          .firstWhere((triangle) => !current.contains(triangle));
      final before = session.controller.selectionTriangleCount;
      final brushRay = _rayForTriangle(geometry, adjacent);
      final imported = session.cad.runtime.document!.entities['calota']!;
      session.cad.runtime.debugPutEntity(
        CadDocumentEntity(
          id: imported.id,
          kind: imported.kind,
          mesh: imported.mesh,
          placement: imported.placement,
          data: {
            ...imported.data,
            'managedStlAssets': {'displayMeshSha256': 'sha-calota'},
          },
        ),
      );
      session.cad.runtime.scene.upsert(
        CadSceneEntity(
          id: 'calota',
          kind: CadSceneEntityKind.mesh,
          geometry: {
            'presentationLod': {'triangles': geometry.triangles.length ~/ 3},
          },
        ),
      );
      session.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
      session.controller.setBrushDiameterMm(2);
      await session.controller.startBrushStroke(
        CadViewportPick(
          entityId: 'calota',
          hit: MeshHit(triangleIndex: -1, point: brushRay.origin, distance: 1),
          ray: brushRay,
        ),
      );
      session.cad.runtime.debugPutEntity(imported);
      await session.controller.finishBrushStroke();

      expect(session.controller.selectionTriangleCount, greaterThan(before));
      expect(session.resolverHits, 1);
      expect(
        session.controller.activeContext!.region!.triangleIndices.every(
          (triangle) => triangle < geometry.triangles.length ~/ 3,
        ),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'CALOTA brush stroke smoke with whole-mesh timings',
    () async {
      const path = r'C:\flcad_mobile\test_assets\real_meshes\CALOTA_INOXX.stl';
      final parsed = _parseStl(File(path));
      final welded = _weld(parsed.vertices, parsed.triangles);
      final geometry = KernelMeshGeometry(
        nodes: welded.vertices,
        triangles: welded.triangles,
      );
      final session = await _RecognitionSession.open(
        geometry: geometry,
        entityId: 'calota',
        managed: false,
      );
      addTearDown(session.dispose);
      final meshColor = colorFromLinearRgb(
        session.cad.runtime.scene.find('calota')?.geometry['rootLinearRgb'],
      );
      expect(meshColor, isNotNull);
      expect(
        contrastRatio(meshColor!, kCadSelectionColor),
        greaterThanOrEqualTo(kMinimumSelectionContrast),
      );

      final segmented = const ProfessionalRegionGrowing().segment(
        MeshSurfaceData.fromKernel(geometry),
        'calota-brush-region',
        settings: const SurfaceRecognitionSettings(
          planar: true,
          planarToleranceMm: .5,
          seedTriangle: 0,
        ),
      );
      final region = segmented.regions
          .where((candidate) => candidate.triangleIndices.isNotEmpty)
          .reduce(
            (first, second) =>
                first.triangleIndices.length >= second.triangleIndices.length
                ? first
                : second,
          );
      final initialTriangles = region.triangleIndices.toSet();
      final selection = BridgeSelection(
        id: region.id,
        entityId: 'calota',
        kind: BridgeSelectionKind.meshRegion,
        geometry: geometry,
        triangleIndices: initialTriangles,
      );
      session.controller.activeSelection = selection;
      session.controller.activeContext = BridgeContext(
        projectId: 'project',
        meshId: 'calota',
        meshFingerprint: 'calota-brush-region',
        userConfirmed: false,
        region: const MeshRegionBuilder().build(
          meshId: 'calota',
          selection: selection,
        ),
      );
      final regionCentroid = _trianglesCentroid(geometry, initialTriangles);
      final camera = regionCentroid + region.averageNormal.normalized * 200;
      final initialRay = MeshRay(
        camera,
        (triangleCentroid(geometry, 0) - camera).normalized,
      );
      session.controller.activePick = CadViewportPick(
        entityId: 'calota',
        hit: MeshHit(
          triangleIndex: 0,
          point: triangleCentroid(geometry, 0),
          distance: 1,
        ),
        ray: initialRay,
      );

      await session.controller.detectAutomatically();
      expect(session.controller.error, isNull);
      final automaticResult = session.controller.activeRecognitionResult;
      final editable = session.controller.editableSelection!;
      final initialCount = session.controller.selectionTriangleCount;
      final current = {...editable.currentTriangles};
      final boundary =
          current
              .map(editable.neighborsOf)
              .expand((values) => values)
              .where((triangle) => !current.contains(triangle))
              .toSet()
              .toList()
            ..sort();
      expect(boundary, isNotEmpty);

      final throughSeed = boundary.first;
      final throughReference = triangleCentroid(geometry, throughSeed);
      final throughNormal = region.averageNormal.normalized;
      final throughCameraOrigin = throughReference + throughNormal * 200;
      final throughUp = throughNormal.z.abs() < .9
          ? const Vector3(0, 0, 1)
          : const Vector3(0, 1, 0);
      final throughCamera = CadCameraController(
        eye: throughCameraOrigin,
        target: throughReference,
        up: throughUp,
      )..resize(800, 600);
      final throughNdc = throughCamera.viewProjectionMatrix.transformPoint(
        throughReference,
      );
      final throughTool = ProjectedBrushTool(
        ray: MeshRay(
          throughCameraOrigin,
          (throughReference - throughCameraOrigin).normalized,
        ),
        referencePoint: throughReference,
        radiusMm: 1.5,
        orthographic: false,
        viewProjection: throughCamera.viewProjectionMatrix,
        viewportWidth: 800,
        viewportHeight: 600,
        centerScreen: Offset(
          (throughNdc.x + 1) * 400,
          (1 - throughNdc.y) * 300,
        ),
        radiusPx: brushCursorRadiusPixels(
          camera: throughCamera,
          point: throughReference,
          radiusWorld: 1.5,
        ),
      );
      final throughWatch = Stopwatch()..start();
      final throughResult =
          const SurfaceSelectionEngine(maxSpatialCandidates: 32768).collect(
            geometry: geometry,
            bvh: editable.bvh,
            tool: throughTool,
            seedTriangle: throughSeed,
            cameraOrigin: throughCameraOrigin,
            visibility: SelectionVisibilityPolicy.throughMesh,
            connectivity: SelectionConnectivityPolicy.local,
            neighborsOf: editable.neighborsOf,
          );
      final visibleResult =
          const SurfaceSelectionEngine(maxSpatialCandidates: 32768).collect(
            geometry: geometry,
            bvh: editable.bvh,
            tool: throughTool,
            seedTriangle: throughSeed,
            cameraOrigin: throughCameraOrigin,
            visibility: SelectionVisibilityPolicy.visibleOnly,
            connectivity: SelectionConnectivityPolicy.local,
            neighborsOf: editable.neighborsOf,
          );
      final throughVisible = throughResult.triangles
          .intersection(visibleResult.triangles)
          .length;
      final throughHidden = throughResult.triangles
          .difference(visibleResult.triangles)
          .length;
      throughWatch.stop();

      session.controller.setSelectionTool(RecognitionSelectionTool.brushAdd);
      session.controller.setBrushDiameterMm(3);
      session.controller.setBrushVisibility(
        SelectionVisibilityPolicy.visibleOnly,
      );
      session.controller.setBrushConnectivity(
        SelectionConnectivityPolicy.connectedSurface,
      );
      const sampleCount = 6;
      final samples = <CadViewportPick>[];
      for (var index = 0; index < sampleCount; index++) {
        final position = index * boundary.length ~/ sampleCount;
        samples.add(
          _brushPickForTriangle(geometry, boundary[position], camera),
        );
      }
      final strokeWatch = Stopwatch()..start();
      await session.controller.startBrushStroke(samples.first);
      for (final pick in samples.skip(1)) {
        await session.controller.addBrushSample(pick);
      }
      final finishWatch = Stopwatch()..start();
      await session.controller.finishBrushStroke();
      finishWatch.stop();
      strokeWatch.stop();
      final addRequests = session.controller.brushRequestCount;
      final addProcessed = session.controller.brushSampleCount;
      final addPickMicros = session.controller.brushPickMicros;
      final addCollectMicros = session.controller.brushCollectMicros;
      final addPreviewMicros = session.controller.brushPreviewMicros;
      final brushedCount = session.controller.selectionTriangleCount;
      final addResult = session.controller.activeRecognitionResult;
      final brushedTriangles = Set<int>.from(
        session.controller.editableSelection!.currentTriangles,
      );
      expect(brushedCount, greaterThan(initialCount));
      expect(
        session.controller.activeContext!.region!.triangleIndices.toSet(),
        brushedTriangles,
      );

      await session.controller.undoRecognitionSelection();
      final brushUndoCount = session.controller.selectionTriangleCount;
      await session.controller.redoRecognitionSelection();
      final brushRedoCount = session.controller.selectionTriangleCount;
      expect(brushUndoCount, initialCount);
      expect(brushRedoCount, brushedCount);

      session.controller.setSelectionTool(RecognitionSelectionTool.brushRemove);
      session.controller.setBrushDiameterMm(4);
      final removeSeed = brushedTriangles
          .difference(initialTriangles)
          .firstOrNull;
      expect(removeSeed, isNotNull);
      final removePick = _brushPickForTriangle(geometry, removeSeed!, camera);
      final removeStrokeWatch = Stopwatch()..start();
      await session.controller.startBrushStroke(removePick);
      final removeFinishWatch = Stopwatch()..start();
      await session.controller.finishBrushStroke();
      removeFinishWatch.stop();
      removeStrokeWatch.stop();
      final removeRequests = session.controller.brushRequestCount;
      final removeProcessed = session.controller.brushSampleCount;
      final removePickMicros = session.controller.brushPickMicros;
      final removeCollectMicros = session.controller.brushCollectMicros;
      final removePreviewMicros = session.controller.brushPreviewMicros;
      final removedCount = session.controller.selectionTriangleCount;
      final removeResult = session.controller.activeRecognitionResult;
      expect(removedCount, lessThan(brushedCount));
      await session.controller.undoRecognitionSelection();
      final removeUndoCount = session.controller.selectionTriangleCount;
      await session.controller.redoRecognitionSelection();
      final removeRedoCount = session.controller.selectionTriangleCount;
      expect(removeUndoCount, brushedCount);
      expect(removeRedoCount, removedCount);

      final fitWatch = Stopwatch()..start();
      await session.controller.recognizeDirected(PrimitiveType.plane);
      fitWatch.stop();
      final winner =
          session.controller.report?.primitives.firstOrNull?.recognition.winner;
      final result = session.controller.activeRecognitionResult;
      final referenceAuthorized = session.controller.canCreatePlaneReference;
      final cadSurfaceApproved =
          result?.parameters['cadSurfaceApproved'] == true;
      final editedCacheHits = session.controller.editedClassificationCacheHits;

      session.controller.clearRecognitionSelection();
      final cleared = !session.controller.hasEditableSelection;
      final newRay = _rayForTriangle(geometry, 201756);
      await session.controller.recognizePick(
        pick: CadViewportPick(
          entityId: 'calota',
          hit: MeshHit(
            triangleIndex: 201756,
            point: newRay.origin,
            distance: 1,
          ),
          ray: newRay,
        ),
        allowTechnicalStl: false,
      );
      final newSelectionCount = session.controller.selectionTriangleCount;

      final beforeSvg = File(
        r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-S2\calota_brush_before.svg',
      );
      final afterSvg = File(
        r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-S2\calota_brush_after.svg',
      );
      _writeSelectionSvg(
        geometry,
        initialTriangles,
        beforeSvg,
        label: 'Diagnostic: CALOTA before brush stroke',
      );
      _writeSelectionSvg(
        geometry,
        brushedTriangles,
        afterSvg,
        label: 'Diagnostic: CALOTA after brush stroke',
      );

      final report = StringBuffer()
        ..writeln('ER-P2D-S3 CALOTA edited region reclassification')
        ..writeln('fixture=$path')
        ..writeln(
          'diagnostic_note=SVG artifacts are diagnostic, not GUI screenshots',
        )
        ..writeln('mesh_color_srgb=${_colorHex(meshColor)}')
        ..writeln('selection_color_srgb=#F5F7FA')
        ..writeln('brush_cursor_color_srgb=#FFBF45')
        ..writeln('through_seed=$throughSeed')
        ..writeln('through_total=${throughResult.triangles.length}')
        ..writeln('through_visible=$throughVisible')
        ..writeln('through_hidden=$throughHidden')
        ..writeln('through_diag_ms=${throughWatch.elapsedMilliseconds}')
        ..writeln('mesh_triangles=${geometry.triangles.length ~/ 3}')
        ..writeln('initial_triangles=$initialCount')
        ..writeln('boundary_candidates=${boundary.length}')
        ..writeln('brush_samples=$sampleCount')
        ..writeln('brush_requests=$addRequests')
        ..writeln('brush_processed_samples=$addProcessed')
        ..writeln('brushed_triangles=$brushedCount')
        ..writeln('brush_added=${brushedCount - initialCount}')
        ..writeln('stroke_total_ms=${strokeWatch.elapsedMilliseconds}')
        ..writeln('finish_fit_ms=${finishWatch.elapsedMilliseconds}')
        ..writeln('pick_total_ms=${(addPickMicros / 1000).toStringAsFixed(3)}')
        ..writeln(
          'collect_total_ms=${(addCollectMicros / 1000).toStringAsFixed(3)}',
        )
        ..writeln(
          'preview_total_ms=${(addPreviewMicros / 1000).toStringAsFixed(3)}',
        )
        ..writeln('brush_undo=$brushUndoCount')
        ..writeln('brush_redo=$brushRedoCount')
        ..writeln('removed_triangles=$removedCount')
        ..writeln('remove_stroke_ms=${removeStrokeWatch.elapsedMilliseconds}')
        ..writeln(
          'remove_finish_fit_ms=${removeFinishWatch.elapsedMilliseconds}',
        )
        ..writeln('remove_requests=$removeRequests')
        ..writeln('remove_processed_samples=$removeProcessed')
        ..writeln(
          'remove_pick_total_ms=${(removePickMicros / 1000).toStringAsFixed(3)}',
        )
        ..writeln(
          'remove_collect_total_ms=${(removeCollectMicros / 1000).toStringAsFixed(3)}',
        )
        ..writeln(
          'remove_preview_total_ms=${(removePreviewMicros / 1000).toStringAsFixed(3)}',
        )
        ..writeln('remove_undo=$removeUndoCount')
        ..writeln('remove_redo=$removeRedoCount')
        ..writeln(
          'automatic_rms=${automaticResult?.parameters['rmsDeviation']}',
        )
        ..writeln(
          'automatic_maximum=${automaticResult?.parameters['maximumDeviation']}',
        )
        ..writeln(
          'automatic_classification='
          '${automaticResult?.parameters['planarClassification']}',
        )
        ..writeln('automatic_confidence=${automaticResult?.confidence}')
        ..writeln('added_rms=${addResult?.parameters['rmsDeviation']}')
        ..writeln('added_maximum=${addResult?.parameters['maximumDeviation']}')
        ..writeln(
          'added_classification='
          '${addResult?.parameters['planarClassification']}',
        )
        ..writeln('added_confidence=${addResult?.confidence}')
        ..writeln('removed_rms=${removeResult?.parameters['rmsDeviation']}')
        ..writeln(
          'removed_maximum=${removeResult?.parameters['maximumDeviation']}',
        )
        ..writeln(
          'removed_classification='
          '${removeResult?.parameters['planarClassification']}',
        )
        ..writeln('removed_confidence=${removeResult?.confidence}')
        ..writeln('directed_requested=plane')
        ..writeln('directed_returned=${winner?.type.name}')
        ..writeln('directed_fit_ms=${fitWatch.elapsedMilliseconds}')
        ..writeln('directed_rms=${winner?.statistics.rms}')
        ..writeln('directed_maximum=${winner?.statistics.maximum}')
        ..writeln(
          'directed_classification='
          '${result?.parameters['planarClassification']}',
        )
        ..writeln(
          'edited_components='
          '${result?.parameters['selectionComponentCount']}',
        )
        ..writeln(
          'region_build_ms='
          '${(session.controller.lastRegionBuildMicros / 1000).toStringAsFixed(3)}',
        )
        ..writeln(
          'fitting_ms='
          '${(session.controller.lastRecognitionMicros / 1000).toStringAsFixed(3)}',
        )
        ..writeln(
          'classification_compute_ms='
          '${(session.controller.lastClassificationComputeMicros / 1000).toStringAsFixed(3)}',
        )
        ..writeln(
          'publication_ms='
          '${(session.controller.lastPublishMicros / 1000).toStringAsFixed(3)}',
        )
        ..writeln('classification_cache_hits=$editedCacheHits')
        ..writeln('reference_authorized=$referenceAuthorized')
        ..writeln('cad_surface_approved=$cadSurfaceApproved')
        ..writeln('selection_cleared=$cleared')
        ..writeln('new_selection_triangles=$newSelectionCount')
        ..writeln('visual_before=${beforeSvg.path}')
        ..writeln('visual_after=${afterSvg.path}')
        ..writeln('error=${session.controller.error}');
      for (final path in const [
        r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-S2\er_p2d_s2_report.txt',
        r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-S3\er_p2d_s3_calota_report.txt',
      ]) {
        final out = File(path);
        out.parent.createSync(recursive: true);
        out.writeAsStringSync(report.toString());
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

KernelMeshGeometry _managedRoofGeometry() {
  const columns = 5;
  const rows = 6;
  final nodes = <double>[];
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < columns; x++) {
      final z = x <= 2 ? 0.0 : (x - 2) * 2.0;
      nodes.addAll([x.toDouble(), y.toDouble(), z]);
    }
  }
  final triangles = <int>[];
  for (var y = 0; y < rows - 1; y++) {
    for (var x = 0; x < columns - 1; x++) {
      final a = y * columns + x;
      triangles.addAll([a, a + 1, a + columns + 1]);
      triangles.addAll([a, a + columns + 1, a + columns]);
    }
  }
  return KernelMeshGeometry(nodes: nodes, triangles: triangles);
}

Vector3 _trianglesCentroid(KernelMeshGeometry geometry, Set<int> triangles) {
  var x = 0.0, y = 0.0, z = 0.0;
  for (final triangle in triangles) {
    final centroid = triangleCentroid(geometry, triangle);
    x += centroid.x;
    y += centroid.y;
    z += centroid.z;
  }
  final count = triangles.isEmpty ? 1 : triangles.length;
  return Vector3(x / count, y / count, z / count);
}

String _colorHex(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

CadViewportPick _brushPickForTriangle(
  KernelMeshGeometry geometry,
  int triangle,
  Vector3 camera,
) {
  final centroid = triangleCentroid(geometry, triangle);
  return CadViewportPick(
    entityId: 'calota',
    hit: MeshHit(triangleIndex: triangle, point: centroid, distance: 1),
    ray: MeshRay(camera, (centroid - camera).normalized),
  );
}

final class _RecognitionSession {
  _RecognitionSession({
    required this.cad,
    required this.controller,
    required this.entityId,
  });

  final DesktopCadController cad;
  final OperationalReverseEngineeringController controller;
  final String entityId;
  int resolverHits = 0;

  static Future<_RecognitionSession> open({
    required KernelMeshGeometry geometry,
    required String entityId,
    bool managed = true,
    bool? resolverManaged,
    String? meshFingerprint,
  }) async {
    final cad = DesktopCadController(
      kernels: KernelManager(),
      projects: ProjectManager.instance,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    final runtimeDirectory = await Directory.systemTemp.createTemp(
      'flcad-er-p1o-',
    );
    await cad.runtime.open('project', runtimeDirectory);
    final triangleCount = geometry.triangles.length ~/ 3;
    final vertexCount = geometry.nodes.length ~/ 3;
    await cad.runtime.registerImport(
      ImportedCadDocument(
        id: entityId,
        projectId: 'project',
        sourcePath: '$entityId.stl',
        format: CadImportFormat.stl,
        registeredPath: 'CAD/$entityId.stl',
        validation: const [],
        mesh: KernelMeshHandle(
          persistentId: entityId,
          kernelId: 'kernel',
          fingerprint: meshFingerprint ?? entityId,
          vertexCount: vertexCount,
          triangleCount: triangleCount,
          bounds: const KernelBounds(0, 0, 0, 1, 1, 1),
          hasNormals: false,
          metadata: const {},
        ),
      ),
      geometry: managed ? null : geometry,
    );
    final imported = cad.runtime.document!.entities[entityId]!;
    if (managed) {
      cad.runtime.debugPutEntity(
        CadDocumentEntity(
          id: imported.id,
          kind: imported.kind,
          mesh: imported.mesh,
          placement: imported.placement,
          data: {
            ...imported.data,
            'managedStlAssets': {'displayMeshSha256': 'sha-$entityId'},
          },
        ),
      );
      cad.runtime.scene.upsert(
        CadSceneEntity(
          id: entityId,
          kind: CadSceneEntityKind.mesh,
          geometry: {
            'presentationLod': {'triangles': triangleCount},
          },
        ),
      );
    }
    late final _RecognitionSession session;
    final useManagedResolver = resolverManaged ?? managed;
    final resolver = TechnicalStlPickResolver(
      null,
      entityProvider: (_) => useManagedResolver
          ? CadDocumentEntity(
              id: imported.id,
              kind: CadDocumentEntityKind.import,
              data: {
                'managedStlAssets': {'displayMeshSha256': 'sha-$entityId'},
              },
            )
          : null,
      geometryLoader: (_) async {
        session.resolverHits++;
        return geometry;
      },
    );
    final controller = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
      technicalStlPickResolver: resolver,
    );
    session = _RecognitionSession(
      cad: cad,
      controller: controller,
      entityId: entityId,
    );
    session._runtimeDirectory = runtimeDirectory;
    return session;
  }

  late final Directory _runtimeDirectory;

  Future<void> dispose() async {
    controller.dispose();
    cad.dispose();
    await _runtimeDirectory.delete(recursive: true);
  }
}

KernelMeshGeometry _unsendablePlane() {
  final nodes = <double>[];
  final triangles = <int>[];
  const rows = 6;
  const columns = 6;
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < columns; x++) {
      nodes.addAll([x.toDouble(), y.toDouble(), 0]);
    }
  }
  for (var y = 0; y < rows - 1; y++) {
    for (var x = 0; x < columns - 1; x++) {
      final a = y * columns + x;
      final b = a + 1;
      final c = a + columns + 1;
      final d = a + columns;
      triangles
        ..addAll([a, b, c])
        ..addAll([a, c, d]);
    }
  }
  return KernelMeshGeometry(
    nodes: _UnsendableList<double>(nodes),
    triangles: _UnsendableList<int>(triangles),
  );
}

CadViewportPick _pickForOriginalTriangle(
  KernelMeshGeometry geometry,
  int triangleIndex,
) {
  final vertex = geometry.triangles[triangleIndex * 3];
  final offset = vertex * 3;
  return CadViewportPick(
    entityId: 'calota',
    hit: MeshHit(
      triangleIndex: triangleIndex,
      point: Vector3(
        geometry.nodes[offset],
        geometry.nodes[offset + 1],
        geometry.nodes[offset + 2],
      ),
      distance: 1,
    ),
  );
}

MeshRay _rayForTriangle(KernelMeshGeometry geometry, int triangleIndex) {
  final offset = triangleIndex * 3;
  Vector3 vertex(int index) {
    final cursor = geometry.triangles[index] * 3;
    return Vector3(
      geometry.nodes[cursor],
      geometry.nodes[cursor + 1],
      geometry.nodes[cursor + 2],
    );
  }

  final a = vertex(offset);
  final b = vertex(offset + 1);
  final c = vertex(offset + 2);
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

void _writeSelectionSvg(
  KernelMeshGeometry geometry,
  Set<int> triangles,
  File output, {
  required String label,
}) {
  if (geometry.nodes.isEmpty) return;
  var minX = geometry.nodes[0], maxX = minX;
  var minY = geometry.nodes[1], maxY = minY;
  for (var index = 0; index + 2 < geometry.nodes.length; index += 3) {
    minX = minX < geometry.nodes[index] ? minX : geometry.nodes[index];
    maxX = maxX > geometry.nodes[index] ? maxX : geometry.nodes[index];
    minY = minY < geometry.nodes[index + 1] ? minY : geometry.nodes[index + 1];
    maxY = maxY > geometry.nodes[index + 1] ? maxY : geometry.nodes[index + 1];
  }
  final spanX = (maxX - minX).abs() < 1e-9 ? 1.0 : maxX - minX;
  final spanY = (maxY - minY).abs() < 1e-9 ? 1.0 : maxY - minY;
  const width = 900.0, height = 700.0, margin = 30.0;
  String point(int vertex) {
    final offset = vertex * 3;
    final x =
        margin + (geometry.nodes[offset] - minX) / spanX * (width - margin * 2);
    final y =
        height -
        margin -
        (geometry.nodes[offset + 1] - minY) / spanY * (height - margin * 2);
    return '$x,$y';
  }

  final buffer = StringBuffer(
    '<svg xmlns="http://www.w3.org/2000/svg" width="900" height="700" '
    'viewBox="0 0 900 700"><rect width="900" height="700" fill="#1b2430"/>'
    '<text x="30" y="20" font-family="Segoe UI, sans-serif" font-size="12" '
    'fill="#F5F7FA">$label - ${triangles.length} triangles</text>',
  );
  for (final triangle in triangles) {
    final offset = triangle * 3;
    if (offset + 2 >= geometry.triangles.length) continue;
    buffer.write(
      '<polygon points="${point(geometry.triangles[offset])} '
      '${point(geometry.triangles[offset + 1])} '
      '${point(geometry.triangles[offset + 2])}" '
      'fill="#F5F7FA" fill-opacity="0.85" stroke="#FFBF45" '
      'stroke-width="0.5"/>',
    );
  }
  buffer.write('</svg>');
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(buffer.toString());
}

final class _UnsendableList<E> extends ListBase<E> {
  _UnsendableList(this._values);

  final List<E> _values;
  final Future<void> _keepAlive = Future<void>.value();

  @override
  int get length => _values.length;

  @override
  set length(int newLength) => _values.length = newLength;

  @override
  E operator [](int index) {
    _keepAlive;
    return _values[index];
  }

  @override
  void operator []=(int index, E value) => _values[index] = value;
}

({List<double> vertices, List<int> triangles}) _parseStl(File file) {
  final bytes = file.readAsBytesSync();
  if (bytes.length >= 6) {
    final prefix = String.fromCharCodes(bytes.take(5));
    if (prefix.toLowerCase() == 'solid' &&
        (bytes.length < 84 || !_looksBinary(bytes))) {
      return _parseAscii(bytes);
    }
  }
  return _parseBinary(bytes);
}

({List<double> vertices, List<int> triangles}) _weld(
  List<double> vertices,
  List<int> triangles,
) {
  final unique = <String, int>{};
  final weldedVertices = <double>[];
  final weldedTriangles = <int>[];
  for (final sourceIndex in triangles) {
    final offset = sourceIndex * 3;
    final key = [
      for (var axis = 0; axis < 3; axis++)
        (vertices[offset + axis] * 1000000).round(),
    ].join(':');
    final index = unique.putIfAbsent(key, () {
      final next = weldedVertices.length ~/ 3;
      weldedVertices.addAll(vertices.sublist(offset, offset + 3));
      return next;
    });
    weldedTriangles.add(index);
  }
  return (vertices: weldedVertices, triangles: weldedTriangles);
}

bool _looksBinary(Uint8List bytes) {
  if (bytes.length < 84) return false;
  final count = ByteData.sublistView(bytes).getUint32(80, Endian.little);
  return count > 0 && bytes.length >= 84 + count * 50;
}

({List<double> vertices, List<int> triangles}) _parseBinary(Uint8List bytes) {
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
      offset += 3;
      cursor += 12;
    }
    cursor += 2;
  }
  return (vertices: vertices, triangles: triangles);
}

({List<double> vertices, List<int> triangles}) _parseAscii(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final vertices = <double>[];
  final triangles = <int>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.startsWith('vertex')) {
      final parts = line.split(RegExp(r'\s+'));
      vertices.addAll([
        double.parse(parts[1]),
        double.parse(parts[2]),
        double.parse(parts[3]),
      ]);
      triangles.add(triangles.length);
    }
  }
  return (vertices: vertices, triangles: triangles);
}
