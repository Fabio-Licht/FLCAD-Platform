import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

// This file emits structured fixture evidence during the real-mesh audit.
// ignore_for_file: avoid_print

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
import 'package:flcad_mobile/core/geometric_kernel/linear_algebra/linear_algebra.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/professional_recognition/recognizers/quadric_recognizers.dart';
import 'package:flcad_mobile/core/surface_recognition/models/surface_recognition_models.dart';
import 'package:flcad_mobile/core/surface_recognition/segmentation/region_growing.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/cylindrical_region_selector.dart';
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

  test(
    'ER-P2C-B-F1 real Ø18 fixture geometry audit',
    () async {
      final file = File(
        r'C:\flcad_mobile\test_assets\real_meshes\PARCIAL_FURO_18MM.stl',
      );
      expect(file.existsSync(), isTrue);
      final parsed = _parseStl(file);
      final welded = _weld(parsed.vertices, parsed.triangles);
      final geometry = KernelMeshGeometry(
        nodes: welded.vertices,
        triangles: welded.triangles,
      );
      var min = Vector3(double.infinity, double.infinity, double.infinity);
      var max = Vector3(
        double.negativeInfinity,
        double.negativeInfinity,
        double.negativeInfinity,
      );
      for (var i = 0; i < geometry.nodes.length; i += 3) {
        final p = Vector3(
          geometry.nodes[i],
          geometry.nodes[i + 1],
          geometry.nodes[i + 2],
        );
        min = Vector3(
          math.min(min.x, p.x),
          math.min(min.y, p.y),
          math.min(min.z, p.z),
        );
        max = Vector3(
          math.max(max.x, p.x),
          math.max(max.y, p.y),
          math.max(max.z, p.z),
        );
      }
      final result = const ProfessionalRegionGrowing().segment(
        MeshSurfaceData.fromKernel(geometry),
        'f1-audit',
        settings: const SurfaceRecognitionSettings(minimumTriangles: 1),
      );
      final mesh = MeshSurfaceData.fromKernel(geometry);
      final edgeCounts = <String, int>{};
      final edgeVertices = <String, (int, int)>{};
      void addEdge(int a, int b) {
        final first = math.min(a, b), second = math.max(a, b);
        final key = '$first:$second';
        edgeCounts[key] = (edgeCounts[key] ?? 0) + 1;
        edgeVertices[key] = (first, second);
      }

      for (final t in mesh.triangles) {
        addEdge(t.$1, t.$2);
        addEdge(t.$2, t.$3);
        addEdge(t.$3, t.$1);
      }
      final centroids = [
        for (var triangle = 0; triangle < mesh.triangles.length; triangle++)
          triangleCentroid(geometry, triangle),
      ];
      final boundaryAdjacency = <int, Set<int>>{};
      for (final entry in edgeCounts.entries.where(
        (entry) => entry.value == 1,
      )) {
        final edge = edgeVertices[entry.key]!;
        (boundaryAdjacency[edge.$1] ??= <int>{}).add(edge.$2);
        (boundaryAdjacency[edge.$2] ??= <int>{}).add(edge.$1);
      }
      final boundaryComponents =
          <
            ({
              int vertices,
              double perimeter,
              double spanX,
              double spanY,
              double spanZ,
            })
          >[];
      final boundaryFits =
          <
            ({
              double perimeter,
              double radius,
              double rms,
              List<Vector3> points,
              List<int> triangles,
            })
          >[];
      final remainingBoundary = boundaryAdjacency.keys.toSet();
      while (remainingBoundary.isNotEmpty) {
        final queue = <int>[remainingBoundary.first];
        final component = <int>{};
        while (queue.isNotEmpty) {
          final vertex = queue.removeLast();
          if (!component.add(vertex)) continue;
          remainingBoundary.remove(vertex);
          queue.addAll(
            boundaryAdjacency[vertex]!.where(remainingBoundary.contains),
          );
        }
        final points = component.map((index) => mesh.vertices[index]).toList();
        final cmin = Vector3(
          points.map((p) => p.x).reduce(math.min),
          points.map((p) => p.y).reduce(math.min),
          points.map((p) => p.z).reduce(math.min),
        );
        final cmax = Vector3(
          points.map((p) => p.x).reduce(math.max),
          points.map((p) => p.y).reduce(math.max),
          points.map((p) => p.z).reduce(math.max),
        );
        var perimeter = 0.0;
        for (final a in component) {
          for (final b in boundaryAdjacency[a]!.where(component.contains)) {
            if (a < b) {
              perimeter += (mesh.vertices[a] - mesh.vertices[b]).length;
            }
          }
        }
        boundaryComponents.add((
          vertices: component.length,
          perimeter: perimeter,
          spanX: cmax.x - cmin.x,
          spanY: cmax.y - cmin.y,
          spanZ: cmax.z - cmin.z,
        ));
        final adjacentTriangles = <int>[];
        for (var triangle = 0; triangle < mesh.triangles.length; triangle++) {
          final t = mesh.triangles[triangle];
          if (component.contains(t.$1) ||
              component.contains(t.$2) ||
              component.contains(t.$3)) {
            adjacentTriangles.add(triangle);
          }
        }
        final adjacentPoints = [
          for (final triangle in adjacentTriangles) centroids[triangle],
        ];
        if (adjacentPoints.length >= 6) {
          final fit = const CylinderProfessionalRecognizer().evaluate(
            RecognitionContext(
              observation: RecognitionObservation(
                projectId: 'f1',
                meshId: 'f1',
                regionId: 'f1-boundary',
                points: adjacentPoints,
                meshFingerprint: 'f1',
                regionFingerprint: 'f1-boundary',
              ),
            ),
          );
          boundaryFits.add((
            perimeter: perimeter,
            radius: (fit.parameters['radius'] as num).toDouble(),
            rms: fit.statistics.rms,
            points: adjacentPoints,
            triangles: adjacentTriangles,
          ));
        }
      }
      boundaryComponents.sort(
        (a, b) => (a.perimeter - 56).abs().compareTo((b.perimeter - 56).abs()),
      );
      boundaryFits.sort(
        (a, b) => ((a.radius - 9).abs() + a.rms).compareTo(
          (b.radius - 9).abs() + b.rms,
        ),
      );
      final boundaryBest = boundaryFits.first;
      final centerX = (min.x + max.x) / 2;
      final centerY = (min.y + max.y) / 2;
      final radialBand = <int>[];
      final innerWallBand = <int>[];
      final sideBand = <int>[];
      for (var triangle = 0; triangle < mesh.triangles.length; triangle++) {
        final p = triangleCentroid(geometry, triangle);
        final t = mesh.triangles[triangle];
        final normal = (mesh.vertices[t.$2] - mesh.vertices[t.$1])
            .cross(mesh.vertices[t.$3] - mesh.vertices[t.$1])
            .normalized;
        final radialVector = Vector3(
          p.x - centerX,
          p.y - centerY,
          0,
        ).normalized;
        final radial = math.sqrt(
          math.pow(p.x - centerX, 2) + math.pow(p.y - centerY, 2),
        );
        if (radial >= 7.5 && radial <= 10.5) radialBand.add(triangle);
        if (radial >= 7.5 &&
            radial <= 10.5 &&
            normal.dot(radialVector).abs() >= .75) {
          innerWallBand.add(triangle);
        }
        if (normal.z.abs() <= .25) sideBand.add(triangle);
      }
      final candidates =
          <
            ({
              int seed,
              int triangles,
              double radius,
              double rms,
              double maximum,
            })
          >[];
      for (final region in result.regions) {
        if (region.triangleIndices.length < 6) continue;
        final points = region.vertexIndices
            .map((index) => mesh.vertices[index])
            .toList();
        final candidate = const CylinderProfessionalRecognizer().evaluate(
          RecognitionContext(
            observation: RecognitionObservation(
              projectId: 'f1',
              meshId: 'f1',
              regionId: region.id,
              points: points,
              meshFingerprint: 'f1',
              regionFingerprint: region.id,
            ),
          ),
        );
        candidates.add((
          seed: region.triangleIndices.first,
          triangles: region.triangleIndices.length,
          radius: (candidate.parameters['radius'] as num).toDouble(),
          rms: candidate.statistics.rms,
          maximum: candidate.statistics.maximum,
        ));
      }
      candidates.sort(
        (a, b) => ((a.radius - 9).abs() + a.rms).compareTo(
          (b.radius - 9).abs() + b.rms,
        ),
      );
      final best = candidates.first;
      final localCandidates =
          <
            ({double radius, double rms, double maximum, List<int> triangles})
          >[];
      for (var x = min.x; x < max.x; x += 8) {
        for (var y = min.y; y < max.y; y += 8) {
          for (var z = min.z; z < max.z; z += 8) {
            final selected = <int>[];
            for (var triangle = 0; triangle < centroids.length; triangle++) {
              final p = centroids[triangle];
              if (p.x >= x &&
                  p.x < x + 8 &&
                  p.y >= y &&
                  p.y < y + 8 &&
                  p.z >= z &&
                  p.z < z + 8) {
                selected.add(triangle);
              }
            }
            if (selected.length < 30) continue;
            final fitted = const CylinderProfessionalRecognizer().evaluate(
              RecognitionContext(
                observation: RecognitionObservation(
                  projectId: 'f1',
                  meshId: 'f1',
                  regionId: 'f1-local',
                  points: [
                    for (final triangle in selected) centroids[triangle],
                  ],
                  meshFingerprint: 'f1',
                  regionFingerprint: 'f1-local',
                ),
              ),
            );
            localCandidates.add((
              radius: (fitted.parameters['radius'] as num).toDouble(),
              rms: fitted.statistics.rms,
              maximum: fitted.statistics.maximum,
              triangles: selected,
            ));
          }
        }
      }
      localCandidates.sort(
        (a, b) => ((a.radius - 9).abs() + a.rms).compareTo(
          (b.radius - 9).abs() + b.rms,
        ),
      );
      final localBest = localCandidates.first;
      final sideCandidate = const CylinderProfessionalRecognizer().evaluate(
        RecognitionContext(
          observation: RecognitionObservation(
            projectId: 'f1',
            meshId: 'f1',
            regionId: 'f1-side',
            points: [for (final triangle in sideBand) centroids[triangle]],
            meshFingerprint: 'f1',
            regionFingerprint: 'f1-side',
          ),
        ),
      );
      print(
        'ER-P2C-B-F1 topCandidates=${candidates.take(12).map((c) => "seed=${c.seed},triangles=${c.triangles},radius=${c.radius},rms=${c.rms}").join(';')}',
      );
      print(
        'ER-P2C-B-F1 localBest=triangles=${localBest.triangles.length},'
        'radius=${localBest.radius},rms=${localBest.rms},maximum=${localBest.maximum}',
      );
      print(
        'ER-P2C-B-F1 sideBand=${sideBand.length} '
        'radius=${sideCandidate.parameters['radius']} '
        'rms=${sideCandidate.statistics.rms}',
      );
      print(
        'ER-P2C-B-F1 radialBandCount=${radialBand.length} '
        'innerWallBandCount=${innerWallBand.length} '
        'boundsCenter=($centerX,$centerY)',
      );
      print(
        'ER-P2C-B-F1 boundaryComponents=${boundaryComponents.take(8).join(';')}',
      );
      print(
        'ER-P2C-B-F1 boundaryFits=${boundaryFits.map((fit) => 'perimeter=${fit.perimeter},radius=${fit.radius},rms=${fit.rms}').join(';')}',
      );
      expect(radialBand, isNotEmpty);
      expect(innerWallBand, isNotEmpty);
      final resolver = TechnicalStlPickResolver(
        null,
        entityProvider: (_) => CadDocumentEntity(
          id: 'f1-stl',
          kind: CadDocumentEntityKind.import,
          data: {
            'managedStlAssets': {
              'displayMeshSha256': List.filled(64, '0').join(),
            },
          },
        ),
        geometryLoader: (_) async => geometry,
      );
      final ray = _rayForTriangle(geometry, boundaryBest.triangles.first);
      final technicalHit = await resolver.resolve(
        entityId: 'f1-stl',
        worldRay: ray,
      );
      final externalHit = await resolver.resolve(
        entityId: 'f1-stl',
        worldRay: _rayForTriangle(geometry, 0),
      );
      final editedPoints = boundaryBest.points;
      final editedCandidate = const CylinderProfessionalRecognizer().evaluate(
        RecognitionContext(
          observation: RecognitionObservation(
            projectId: 'f1',
            meshId: 'f1',
            regionId: 'f1-edited-inner-wall',
            points: editedPoints,
            meshFingerprint: 'f1',
            regionFingerprint: 'f1-edited-inner-wall',
          ),
        ),
      );
      final directedReport = await ProfessionalRecognitionApi().recognize(
        [
          RecognitionContext(
            observation: RecognitionObservation(
              projectId: 'f1',
              meshId: 'f1',
              regionId: 'f1-edited-inner-wall',
              points: editedPoints,
              meshFingerprint: 'f1',
              regionFingerprint: 'f1-edited-inner-wall',
            ),
          ),
        ],
        allowedTypes: {PrimitiveType.cylinder},
      );
      final directedWinner =
          directedReport.primitives.single.recognition.winner;
      final sampleNormals = [
        for (final triangle in boundaryBest.triangles)
          (mesh.vertices[mesh.triangles[triangle].$2] -
                  mesh.vertices[mesh.triangles[triangle].$1])
              .cross(
                mesh.vertices[mesh.triangles[triangle].$3] -
                    mesh.vertices[mesh.triangles[triangle].$1],
              )
              .normalized,
      ];
      final pcaOrigin = Vector3(
        ((editedCandidate.parameters['origin'] as List)[0] as num).toDouble(),
        ((editedCandidate.parameters['origin'] as List)[1] as num).toDouble(),
        ((editedCandidate.parameters['origin'] as List)[2] as num).toDouble(),
      );
      final pcaAxis = Vector3(
        ((editedCandidate.parameters['axis'] as List)[0] as num).toDouble(),
        ((editedCandidate.parameters['axis'] as List)[1] as num).toDouble(),
        ((editedCandidate.parameters['axis'] as List)[2] as num).toDouble(),
      ).normalized;
      final pcaRadius = (editedCandidate.parameters['radius'] as num)
          .toDouble();
      final pcaResiduals = _cylinderResiduals(
        editedPoints,
        pcaOrigin,
        pcaAxis,
        pcaRadius,
      );
      final pcaFit = _ExperimentalCylinderFit(
        origin: pcaOrigin,
        axis: pcaAxis,
        radius: pcaRadius,
        residuals: pcaResiduals,
        inliers: {
          for (var i = 0; i < pcaResiduals.length; i++)
            if (pcaResiduals[i].abs() <= 2.5 * editedCandidate.statistics.rms)
              i,
        },
        conditioning: double.nan,
        elapsedMicros: 0,
      );
      final normalFit = _normalAxisFit(editedPoints, sampleNormals);
      final jointFit = _jointCylinderFit(
        editedPoints,
        normalFit.origin,
        normalFit.axis,
        normalFit.radius,
      );
      final normalResiduals = _cylinderResiduals(
        editedPoints,
        normalFit.origin,
        normalFit.axis,
        normalFit.radius,
      );
      final normalSorted = normalResiduals.map((value) => value.abs()).toList()
        ..sort();
      final rejectionLimit = math.max(
        4 * normalSorted[normalSorted.length ~/ 2],
        .2,
      );
      final rejectedPoints = [
        for (var i = 0; i < editedPoints.length; i++)
          if (normalResiduals[i].abs() <= rejectionLimit) editedPoints[i],
      ];
      final robustSubset = _jointCylinderFit(
        rejectedPoints,
        normalFit.origin,
        normalFit.axis,
        normalFit.radius,
      );
      final robustAllResiduals = _cylinderResiduals(
        editedPoints,
        robustSubset.origin,
        robustSubset.axis,
        robustSubset.radius,
      );
      final robustAllSorted =
          robustAllResiduals.map((value) => value.abs()).toList()..sort();
      final robustAllLimit = math.max(
        3 * robustAllSorted[robustAllSorted.length ~/ 2],
        1e-9,
      );
      final robustFit = _ExperimentalCylinderFit(
        origin: robustSubset.origin,
        axis: robustSubset.axis,
        radius: robustSubset.radius,
        residuals: robustAllResiduals,
        inliers: {
          for (var i = 0; i < robustAllResiduals.length; i++)
            if (robustAllResiduals[i].abs() <= robustAllLimit) i,
        },
        conditioning: robustSubset.conditioning,
        elapsedMicros: robustSubset.elapsedMicros,
      );
      final coverageA = _sampleCoverage(editedPoints, pcaOrigin, pcaAxis);
      final coverageB = _sampleCoverage(
        editedPoints,
        normalFit.origin,
        normalFit.axis,
      );
      final coverageC = _sampleCoverage(
        editedPoints,
        jointFit.origin,
        jointFit.axis,
      );
      final coverageD = _sampleCoverage(
        editedPoints,
        robustFit.origin,
        robustFit.axis,
      );
      _writeCylinderAuditSvg(
        editedPoints,
        pcaFit,
        normalFit,
        jointFit,
        File(
          r'C:\flcad_mobile\artifacts\ER-P2C-C1-windows-debug\inner-wall-diagnostic.svg',
        ),
      );
      final report = File(
        r'C:\flcad_mobile\artifacts\ER-P2C-C1-windows-debug\ER-P2C-C1-report.txt',
      )..parent.createSync(recursive: true);
      report.writeAsStringSync(
        _cylinderAuditReport(
          geometry: geometry,
          points: editedPoints,
          normals: sampleNormals,
          boundaryComponents: boundaryComponents,
          pca: pcaFit,
          normal: normalFit,
          joint: jointFit,
          robust: robustFit,
          coverageA: coverageA,
          coverageB: coverageB,
          coverageC: coverageC,
          coverageD: coverageD,
          directedWinner: directedWinner,
        ),
      );
      // This audit intentionally records evidence without changing the STL.
      print(
        'ER-P2C-B-F1 geometry triangles=${geometry.triangles.length ~/ 3} '
        'bounds=(${min.x},${min.y},${min.z})..'
        '(${max.x},${max.y},${max.z}) regions=${result.regions.length} '
        'bestSeed=${best.seed} bestRegionTriangles=${best.triangles} '
        'technicalHitTriangle=${technicalHit?.triangleIndex} '
        'externalHitTriangle=${externalHit?.triangleIndex}',
      );
      print(
        'ER-P2C-C1 methods='
        'A(radius=${pcaFit.radius},diameter=${pcaFit.radius * 2},rms=${pcaFit.rms},coverage=$coverageA);'
        'B(radius=${normalFit.radius},diameter=${normalFit.radius * 2},rms=${normalFit.rms},coverage=$coverageB);'
        'C(radius=${jointFit.radius},diameter=${jointFit.radius * 2},rms=${jointFit.rms},coverage=$coverageC);'
        'D(radius=${robustFit.radius},diameter=${robustFit.radius * 2},rms=${robustFit.rms},coverage=$coverageD,inliers=${robustFit.inliers.length})',
      );
      print(
        'ER-P2C-B-F1 candidateRadius=${best.radius} candidateRms=${best.rms} candidateMaximum=${best.maximum}',
      );
      final editedAxis = Vector3(
        ((directedWinner.parameters['axis'] as List)[0] as num).toDouble(),
        ((directedWinner.parameters['axis'] as List)[1] as num).toDouble(),
        ((directedWinner.parameters['axis'] as List)[2] as num).toDouble(),
      );
      final axial = editedPoints.map((point) => point.dot(editedAxis)).toList();
      print(
        'ER-P2C-B-F1 directedWinner=${directedWinner.parameters} '
        'diameter=${(directedWinner.parameters['radius'] as num).toDouble() * 2} '
        'axialLength=${axial.reduce(math.max) - axial.reduce(math.min)} '
        'rms=${directedWinner.statistics.rms} '
        'maximum=${directedWinner.statistics.maximum} '
        'confidence=${directedReport.primitives.single.recognition.dna.confidence} '
        'points=${editedPoints.length} coverage=${editedCandidate.statistics.coverage}',
      );
      expect(geometry.triangles.length ~/ 3, greaterThan(0));
      expect(result.regions, isNotEmpty);
      expect(technicalHit, isNotNull);
      expect(technicalHit!.triangleIndex, greaterThanOrEqualTo(0));
      expect(externalHit, isNotNull);
      expect(externalHit!.triangleIndex, greaterThanOrEqualTo(0));
      expect(directedWinner.parameters['radius'], isA<num>());
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test('ER-P2C-C2 cylindrical continuity selects the real inner wall', () {
    final file = File(
      r'C:\flcad_mobile\test_assets\real_meshes\PARCIAL_FURO_18MM.stl',
    );
    final parsed = _parseStl(file);
    final welded = _weld(parsed.vertices, parsed.triangles);
    final geometry = KernelMeshGeometry(
      nodes: welded.vertices,
      triangles: welded.triangles,
    );
    final source = EditableSurfaceSelection(
      projectId: 'c2',
      meshId: 'fixture',
      meshFingerprint: 'fixture',
      entityId: 'fixture',
      geometry: geometry,
      initialTriangles: {32065},
      area: 0,
    );
    final result = const CylindricalRegionSelector().select(
      geometry: geometry,
      seedTriangle: 32065,
      neighborsOf: source.neighborsOf,
    );
    print(
      'ER-P2C-C2 real selected=${result.triangles.length} '
      'transitions=${result.transitionTriangles.length} '
      'radius=${result.radius} axis=${result.diagnostics['axis']} '
      'origin=${result.diagnostics['origin']}',
    );
    final selectedPoints = [
      for (final triangle in result.triangles)
        triangleCentroid(geometry, triangle),
    ];
    final selectedCandidate = const CylinderProfessionalRecognizer().evaluate(
      RecognitionContext(
        observation: RecognitionObservation(
          projectId: 'c2',
          meshId: 'fixture',
          regionId: 'cylindrical-selection',
          points: selectedPoints,
          meshFingerprint: 'fixture',
          regionFingerprint: 'cylindrical-selection',
        ),
      ),
    );
    final segmented = const ProfessionalRegionGrowing().segment(
      MeshSurfaceData.fromKernel(geometry),
      'c2-generic',
      settings: const SurfaceRecognitionSettings(minimumTriangles: 1),
    );
    final generic = segmented.regions
        .where((region) => region.triangleIndices.contains(32065))
        .firstOrNull;
    final genericPoints = generic == null
        ? const <Vector3>[]
        : [
            for (final triangle in generic.triangleIndices)
              triangleCentroid(geometry, triangle),
          ];
    final genericCandidate = genericPoints.length < 6
        ? null
        : const CylinderProfessionalRecognizer().evaluate(
            RecognitionContext(
              observation: RecognitionObservation(
                projectId: 'c2',
                meshId: 'fixture',
                regionId: 'generic-selection',
                points: genericPoints,
                meshFingerprint: 'fixture',
                regionFingerprint: 'generic-selection',
              ),
            ),
          );
    final report = File(
      r'C:\flcad_mobile\artifacts\ER-P2C-C1-windows-debug\ER-P2C-C2-selection-report.txt',
    )..parent.createSync(recursive: true);
    report.writeAsStringSync(
      'ER-P2C-C2 cylindrical continuity selection\n'
      'selected_triangles=${result.triangles.length}\n'
      'transition_triangles=${result.transitionTriangles.length}\n'
      'selector_radius_mm=${result.radius}\n'
      'selector_axis=${result.diagnostics['axis']}\n'
      'selector_origin=${result.diagnostics['origin']}\n'
      'current_fitter_selected_radius_mm=${selectedCandidate.parameters['radius']}\n'
      'current_fitter_selected_rms_mm=${selectedCandidate.statistics.rms}\n'
      'generic_region_triangles=${generic?.triangleIndices.length ?? 0}\n'
      'current_fitter_generic_radius_mm=${genericCandidate?.parameters['radius']}\n'
      'current_fitter_generic_rms_mm=${genericCandidate?.statistics.rms}\n'
      'nominal_diameter_used=false\n'
      'brush_and_undo_contract=EditableSurfaceSelection\n',
    );
    _writeC2SelectionSvg(
      geometry,
      result.triangles,
      result.transitionTriangles,
      File(
        r'C:\flcad_mobile\artifacts\ER-P2C-B-F1-windows-debug\c2-selection-diagnostic.svg',
      ),
    );
    print(
      'ER-P2C-C2 fitter selected radius=${selectedCandidate.parameters['radius']} '
      'rms=${selectedCandidate.statistics.rms} '
      'genericTriangles=${generic?.triangleIndices.length ?? 0} '
      'genericRadius=${genericCandidate?.parameters['radius']} '
      'genericRms=${genericCandidate?.statistics.rms}',
    );
    expect(result.triangles, contains(32065));
    expect(result.triangles.length, greaterThan(1000));
    expect(result.transitionTriangles, isNotEmpty);
    expect(result.diagnostics['nominalDiameterUsed'], isFalse);
  });

  test(
    'ER-P2C-C3-F1 staged real cylinder performance audit',
    () {
      final total = Stopwatch()..start();
      final file = File(
        r'C:\flcad_mobile\test_assets\real_meshes\PARCIAL_FURO_18MM.stl',
      );
      final importWatch = Stopwatch()..start();
      final parsed = _parseStl(file);
      final importMs = importWatch.elapsedMicroseconds / 1000;
      final weldWatch = Stopwatch()..start();
      final welded = _weld(parsed.vertices, parsed.triangles);
      final weldMs = weldWatch.elapsedMicroseconds / 1000;
      final geometry = KernelMeshGeometry(
        nodes: welded.vertices,
        triangles: welded.triangles,
      );
      final source = EditableSurfaceSelection(
        projectId: 'c3-f1',
        meshId: 'fixture',
        meshFingerprint: 'fixture',
        entityId: 'fixture',
        geometry: geometry,
        initialTriangles: {32065},
        area: 0,
      );
      final bvhPickMs = 0.0;
      final c2Watch = Stopwatch()..start();
      final result = const CylindricalRegionSelector().select(
        geometry: geometry,
        seedTriangle: 32065,
        neighborsOf: source.neighborsOf,
      );
      final c2Ms = c2Watch.elapsedMicroseconds / 1000;
      final extractionWatch = Stopwatch()..start();
      final region = const MeshRegionBuilder().build(
        meshId: 'fixture',
        selection: BridgeSelection(
          id: 'c3-f1',
          entityId: 'fixture',
          kind: BridgeSelectionKind.meshRegion,
          geometry: geometry,
          triangleIndices: result.triangles,
        ),
      );
      final extractionMs = extractionWatch.elapsedMicroseconds / 1000;
      final fitWatch = Stopwatch()..start();
      final candidate = const CylinderProfessionalRecognizer().evaluate(
        RecognitionContext(
          observation: RecognitionObservation(
            projectId: 'c3-f1',
            meshId: 'fixture',
            regionId: 'cylindrical-selection',
            points: region.points,
            normals: region.normals,
            meshFingerprint: 'fixture',
            regionFingerprint: 'c3-f1',
          ),
        ),
      );
      final fitMs = fitWatch.elapsedMicroseconds / 1000;
      total.stop();
      final parameters = candidate.parameters;
      final report = File(
        r'C:\flcad_mobile\artifacts\ER-P2C-C3-F1-windows-debug\ER-P2C-C3-F1-performance-report.txt',
      )..parent.createSync(recursive: true);
      report.writeAsStringSync(
        'ER-P2C-C3-F1 staged real cylinder performance audit\n'
        'fixture=${file.path}\n'
        'input_bytes=${file.lengthSync()}\n'
        'input_triangles=${geometry.triangles.length ~/ 3}\n'
        'input_vertices=${geometry.nodes.length ~/ 3}\n'
        'seed_triangle=32065\n'
        'import_ms=$importMs\n'
        'weld_ms=$weldMs\n'
        'bvh_pick_ms=$bvhPickMs\n'
        'c2_selection_ms=$c2Ms\n'
        'c2_selected_triangles=${result.triangles.length}\n'
        'c2_transition_triangles=${result.transitionTriangles.length}\n'
        'point_extraction_ms=$extractionMs\n'
        'sampled_points=${region.points.length}\n'
        'sampled_normals=${region.normals.length}\n'
        'initial_axis=embedded in C3 candidate search\n'
        'robust_refine_and_metrics_ms=$fitMs\n'
        'c3_iterations=4 axis seeds x up to 12 refinements x 4 local candidates x 6 robust circle iterations\n'
        'diameter_mm=${parameters['diameter']}\n'
        'radius_mm=${parameters['radius']}\n'
        'origin=${parameters['origin']}\n'
        'axis=${parameters['axis']}\n'
        'rms_mm=${candidate.statistics.rms}\n'
        'maximum_mm=${candidate.statistics.maximum}\n'
        'angular_coverage_degrees=${candidate.statistics.angularCoverageDegrees}\n'
        'inliers=${candidate.statistics.inlierCount}\n'
        'conditioning=${candidate.statistics.conditioning}\n'
        'stability=${candidate.statistics.stability}\n'
        'quality_status=${candidate.statistics.qualityStatus}\n'
        'total_ms=${total.elapsedMicroseconds / 1000}\n'
        'nominal_diameter_used=false\n',
      );
      print(report.readAsStringSync());
      expect(result.triangles, contains(32065));
      expect(candidate.parameters['diameter'], isA<num>());
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test('ER-P2C-C1 synthetic cylinder stability matrix', () {
    final cases = [
      _syntheticCylinder(
        axis: const Vector3(0, 0, 1),
        start: 0,
        end: 2 * math.pi,
      ),
      _syntheticCylinder(
        axis: const Vector3(.3, .4, .8660254038),
        start: 0,
        end: 2 * math.pi,
      ),
      _syntheticCylinder(
        axis: const Vector3(.3, .4, .8660254038),
        start: -.4,
        end: 1.2,
      ),
      _syntheticCylinder(
        axis: const Vector3(.3, .4, .8660254038),
        start: -.4,
        end: 1.2,
        noise: .15,
        outliers: 12,
      ),
    ];
    for (final sample in cases) {
      final pca = const CylinderProfessionalRecognizer().evaluate(
        RecognitionContext(
          observation: RecognitionObservation(
            projectId: 'synthetic',
            meshId: 'synthetic',
            regionId: 'synthetic',
            points: sample.points,
            meshFingerprint: 'synthetic',
            regionFingerprint: 'synthetic',
          ),
        ),
      );
      final normal = _normalAxisFit(sample.points, sample.normals);
      final joint = _jointCylinderFit(
        sample.points,
        Vector3(
          ((pca.parameters['origin'] as List)[0] as num).toDouble(),
          ((pca.parameters['origin'] as List)[1] as num).toDouble(),
          ((pca.parameters['origin'] as List)[2] as num).toDouble(),
        ),
        Vector3(
          ((pca.parameters['axis'] as List)[0] as num).toDouble(),
          ((pca.parameters['axis'] as List)[1] as num).toDouble(),
          ((pca.parameters['axis'] as List)[2] as num).toDouble(),
        ),
        (pca.parameters['radius'] as num).toDouble(),
      );
      final robustSeed = _normalAxisFit(sample.points, sample.normals);
      final robustResiduals = _cylinderResiduals(
        sample.points,
        robustSeed.origin,
        robustSeed.axis,
        robustSeed.radius,
      );
      final sortedResiduals =
          robustResiduals.map((value) => value.abs()).toList()..sort();
      final trimLimit = math.max(
        4 * sortedResiduals[sortedResiduals.length ~/ 2],
        .2,
      );
      final robustPoints = [
        for (var i = 0; i < sample.points.length; i++)
          if (robustResiduals[i].abs() <= trimLimit) sample.points[i],
      ];
      final robust = _jointCylinderFit(
        robustPoints,
        robustSeed.origin,
        robustSeed.axis,
        robustSeed.radius,
      );
      print(
        'ER-P2C-C1 synthetic radius=${sample.radius} '
        'pca=${pca.parameters['radius']} normal=${normal.radius} '
        'joint=${joint.radius} jointRms=${joint.rms}',
      );
      print(
        'ER-P2C-C1 robust points=${robustPoints.length} '
        'radius=${robust.radius} rms=${robust.rms}',
      );
      expect(
        robust.radius,
        closeTo(sample.radius, sample.noise > 0 ? .6 : .25),
      );
      expect(joint.axis.length, closeTo(1, 1e-6));
    }
  });

  test(
    'ER-P2C-C2 selector preserves complete and partial synthetic cylinders',
    () {
      for (final endAngle in [2 * math.pi, math.pi]) {
        final geometry = _syntheticCylinderGeometry(endAngle: endAngle);
        final source = EditableSurfaceSelection(
          projectId: 'c2',
          meshId: 'synthetic',
          meshFingerprint: 'synthetic',
          entityId: 'synthetic',
          geometry: geometry,
          initialTriangles: {0},
          area: 0,
        );
        final result = const CylindricalRegionSelector().select(
          geometry: geometry,
          seedTriangle: 0,
          neighborsOf: source.neighborsOf,
        );
        final count = geometry.triangles.length ~/ 3;
        print(
          'ER-P2C-C2 synthetic end=$endAngle selected=${result.triangles.length}/$count '
          'radius=${result.radius}',
        );
        expect(result.triangles.length, greaterThan(count ~/ 2));
      }
    },
  );
}

KernelMeshGeometry _syntheticCylinderGeometry({required double endAngle}) {
  const radialSteps = 48;
  const axialSteps = 20;
  final nodes = <double>[];
  for (var z = 0; z <= axialSteps; z++) {
    for (var angle = 0; angle <= radialSteps; angle++) {
      final theta = endAngle * angle / radialSteps;
      nodes.addAll([7 * math.cos(theta), 7 * math.sin(theta), z.toDouble()]);
    }
  }
  final columns = radialSteps + 1;
  final triangles = <int>[];
  for (var z = 0; z < axialSteps; z++) {
    for (var angle = 0; angle < radialSteps; angle++) {
      final a = z * columns + angle;
      final b = a + 1;
      final c = a + columns;
      final d = c + 1;
      triangles.addAll([a, c, b, b, c, d]);
    }
  }
  return KernelMeshGeometry(nodes: nodes, triangles: triangles);
}

void _writeC2SelectionSvg(
  KernelMeshGeometry geometry,
  Set<int> selected,
  Set<int> transitions,
  File output,
) {
  final points = <({double x, double y, bool transition})>[];
  for (final triangle in selected) {
    final point = triangleCentroid(geometry, triangle);
    points.add((x: point.x, y: point.y, transition: false));
  }
  for (final triangle in transitions) {
    final point = triangleCentroid(geometry, triangle);
    points.add((x: point.x, y: point.y, transition: true));
  }
  if (points.isEmpty) return;
  final minX = points.map((point) => point.x).reduce(math.min);
  final maxX = points.map((point) => point.x).reduce(math.max);
  final minY = points.map((point) => point.y).reduce(math.min);
  final maxY = points.map((point) => point.y).reduce(math.max);
  final spanX = math.max(maxX - minX, 1e-6);
  final spanY = math.max(maxY - minY, 1e-6);
  String mapX(double value) =>
      (30 + (value - minX) / spanX * 840).toStringAsFixed(2);
  String mapY(double value) =>
      (670 - (value - minY) / spanY * 620).toStringAsFixed(2);
  final svg = StringBuffer(
    '<svg xmlns="http://www.w3.org/2000/svg" width="900" height="700" '
    'viewBox="0 0 900 700"><rect width="900" height="700" fill="#18212b"/>'
    '<text x="30" y="22" fill="#F5F7FA" font-family="Segoe UI" font-size="14">'
    'ER-P2C-C2 cyan=selected wall; red=excluded transitions</text>',
  );
  for (final point in points) {
    svg.write(
      '<circle cx="${mapX(point.x)}" cy="${mapY(point.y)}" r="${point.transition ? 1.8 : 1.0}" '
      'fill="${point.transition ? '#FF6B6B' : '#7DD3FC'}" fill-opacity="0.72"/>',
    );
  }
  svg.write('</svg>');
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(svg.toString());
}

final class _ExperimentalCylinderFit {
  const _ExperimentalCylinderFit({
    required this.origin,
    required this.axis,
    required this.radius,
    required this.residuals,
    required this.inliers,
    required this.conditioning,
    required this.elapsedMicros,
  });

  final Vector3 origin, axis;
  final double radius;
  final List<double> residuals;
  final Set<int> inliers;
  final double conditioning;
  final int elapsedMicros;

  double get rms => math.sqrt(
    residuals.fold<double>(0, (sum, value) => sum + value * value) /
        math.max(1, residuals.length),
  );
  double get maximum => residuals.map((value) => value.abs()).reduce(math.max);
  double get coverage => _angularCoverage(residuals.length, origin, axis);
}

double _robustMeanExperimental(List<double> values) {
  final sorted = [...values]..sort();
  final median = sorted[sorted.length ~/ 2];
  final deviations = values.map((value) => (value - median).abs()).toList()
    ..sort();
  final mad = deviations[deviations.length ~/ 2];
  final limit = mad <= 1e-12 ? double.infinity : 3 * mad;
  final accepted = values.where((value) => (value - median).abs() <= limit);
  return accepted.reduce((a, b) => a + b) / accepted.length;
}

List<double> _cylinderResiduals(
  List<Vector3> points,
  Vector3 origin,
  Vector3 axis,
  double radius,
) => [
  for (final point in points)
    (((point - origin) - axis * (point - origin).dot(axis)).length - radius),
];

_ExperimentalCylinderFit _normalAxisFit(
  List<Vector3> points,
  List<Vector3> normals,
) {
  final watch = Stopwatch()..start();
  var axis = Vector3.zero;
  var bestScore = -1;
  final step = math.max(1, normals.length ~/ 24);
  for (var i = 0; i < normals.length; i += step) {
    for (var j = i + step; j < normals.length; j += step) {
      final cross = normals[i].cross(normals[j]);
      if (cross.length <= 1e-6) continue;
      final candidate = cross.normalized;
      final score = normals
          .where((normal) => normal.dot(candidate).abs() <= .15)
          .length;
      if (score > bestScore) {
        bestScore = score;
        axis = candidate;
      }
    }
  }
  if (axis.length <= 1e-12) {
    final normalPca = const LinearAlgebra().principalComponents([
      for (final normal in normals) [normal.x, normal.y, normal.z],
    ]);
    axis = Vector3(
      normalPca.axes[2][0],
      normalPca.axes[2][1],
      normalPca.axes[2][2],
    ).normalized;
  }
  final mean =
      points.fold<Vector3>(Vector3.zero, (sum, point) => sum + point) /
      points.length.toDouble();
  final radii = [
    for (final point in points)
      ((point - mean) - axis * (point - mean).dot(axis)).length,
  ];
  final radius = _robustMeanExperimental(radii);
  final residuals = _cylinderResiduals(points, mean, axis, radius);
  final median = [...residuals.map((value) => value.abs())]..sort();
  final limit = math.max(3 * median[median.length ~/ 2], 1e-9);
  final inliers = {
    for (var index = 0; index < residuals.length; index++)
      if (residuals[index].abs() <= limit) index,
  };
  watch.stop();
  return _ExperimentalCylinderFit(
    origin: mean,
    axis: axis,
    radius: radius,
    residuals: residuals,
    inliers: inliers,
    conditioning: bestScore <= 0 ? double.infinity : normals.length / bestScore,
    elapsedMicros: watch.elapsedMicroseconds,
  );
}

_ExperimentalCylinderFit _jointCylinderFit(
  List<Vector3> points,
  Vector3 seedOrigin,
  Vector3 seedAxis,
  double seedRadius,
) {
  final watch = Stopwatch()..start();
  var origin = seedOrigin;
  var axis = seedAxis.normalized;
  var radius = seedRadius;
  var conditioning = double.infinity;
  for (var iteration = 0; iteration < 12; iteration++) {
    final residuals = _cylinderResiduals(points, origin, axis, radius);
    final absolute = residuals.map((value) => value.abs()).toList()..sort();
    final scale = math.max(1.4826 * absolute[absolute.length ~/ 2], 1e-6);
    final normal = List.generate(7, (_) => List<double>.filled(7, 0));
    final rhs = List<double>.filled(7, 0);
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final weight = absolute[i] <= 2.5 * scale
          ? 1.0
          : (2.5 * scale / absolute[i]);
      final base = [
        origin.x,
        origin.y,
        origin.z,
        axis.x,
        axis.y,
        axis.z,
        radius,
      ];
      final jacobian = List<double>.filled(7, 0);
      for (var parameter = 0; parameter < 7; parameter++) {
        final delta = parameter == 6 ? 1e-4 : 1e-3;
        final next = [...base];
        next[parameter] += delta;
        final nextAxis = Vector3(next[3], next[4], next[5]).normalized;
        final nextOrigin = Vector3(next[0], next[1], next[2]);
        final nextResidual = _cylinderResiduals(
          [point],
          nextOrigin,
          nextAxis,
          next[6],
        ).single;
        jacobian[parameter] = (nextResidual - residuals[i]) / delta;
      }
      for (var row = 0; row < 7; row++) {
        rhs[row] += -weight * jacobian[row] * residuals[i];
        for (var column = 0; column < 7; column++) {
          normal[row][column] += weight * jacobian[row] * jacobian[column];
        }
      }
    }
    final diagonal = [for (var i = 0; i < 7; i++) normal[i][i]];
    final minimum = diagonal
        .where((value) => value > 1e-12)
        .fold<double>(double.infinity, math.min);
    conditioning = minimum.isFinite
        ? diagonal.reduce(math.max) / minimum
        : double.infinity;
    for (var i = 0; i < 7; i++) {
      normal[i][i] += 1e-6;
    }
    List<double> step;
    try {
      step = const LinearAlgebra().solveGaussian(DenseMatrix(normal), rhs);
    } catch (_) {
      break;
    }
    origin = origin + Vector3(step[0], step[1], step[2]);
    axis = Vector3(
      axis.x + step[3],
      axis.y + step[4],
      axis.z + step[5],
    ).normalized;
    radius = math.max(1e-9, radius + step[6]);
    if (step.map((value) => value.abs()).reduce(math.max) < 1e-7) break;
  }
  final residuals = _cylinderResiduals(points, origin, axis, radius);
  final absolute = residuals.map((value) => value.abs()).toList()..sort();
  final limit = math.max(3 * absolute[absolute.length ~/ 2], 1e-9);
  final inliers = {
    for (var index = 0; index < residuals.length; index++)
      if (residuals[index].abs() <= limit) index,
  };
  watch.stop();
  return _ExperimentalCylinderFit(
    origin: origin,
    axis: axis,
    radius: radius,
    residuals: residuals,
    inliers: inliers,
    conditioning: conditioning,
    elapsedMicros: watch.elapsedMicroseconds,
  );
}

double _angularCoverage(int count, Vector3 origin, Vector3 axis) {
  // The audit records a conservative coverage proxy here; the exact angular
  // coverage is computed by [_sampleCoverage] where the points are available.
  return count == 0 ? 0 : 1;
}

double _sampleCoverage(List<Vector3> points, Vector3 origin, Vector3 axis) {
  final reference = axis.z.abs() < .9
      ? const Vector3(0, 0, 1)
      : const Vector3(1, 0, 0);
  final u = axis.cross(reference).normalized;
  final v = axis.cross(u).normalized;
  final angles = [
    for (final point in points)
      math.atan2((point - origin).dot(v), (point - origin).dot(u)),
  ]..sort();
  if (angles.length < 2) return 0;
  var largestGap = 0.0;
  for (var i = 0; i < angles.length; i++) {
    final next = i + 1 == angles.length
        ? angles.first + 2 * math.pi
        : angles[i + 1];
    largestGap = math.max(largestGap, next - angles[i]);
  }
  return ((2 * math.pi - largestGap) / (2 * math.pi)).clamp(0.0, 1.0);
}

void _writeCylinderAuditSvg(
  List<Vector3> points,
  _ExperimentalCylinderFit pca,
  _ExperimentalCylinderFit normal,
  _ExperimentalCylinderFit joint,
  File output,
) {
  final reference = joint.axis.z.abs() < .9
      ? const Vector3(0, 0, 1)
      : const Vector3(1, 0, 0);
  final u = joint.axis.cross(reference).normalized;
  final v = joint.axis.cross(u).normalized;
  final projected = [
    for (var i = 0; i < points.length; i++)
      (
        x: (points[i] - joint.origin).dot(u),
        y: (points[i] - joint.origin).dot(v),
        outlier: !joint.inliers.contains(i),
      ),
  ];
  final minX = projected.map((p) => p.x).reduce(math.min);
  final maxX = projected.map((p) => p.x).reduce(math.max);
  final minY = projected.map((p) => p.y).reduce(math.min);
  final maxY = projected.map((p) => p.y).reduce(math.max);
  final spanX = math.max(maxX - minX, 1e-6);
  final spanY = math.max(maxY - minY, 1e-6);
  String mapX(double value) =>
      (30 + (value - minX) / spanX * 840).toStringAsFixed(2);
  String mapY(double value) =>
      (670 - (value - minY) / spanY * 620).toStringAsFixed(2);
  final svg = StringBuffer(
    '<svg xmlns="http://www.w3.org/2000/svg" width="900" height="700" '
    'viewBox="0 0 900 700"><rect width="900" height="700" fill="#18212b"/>'
    '<text x="30" y="22" fill="#F5F7FA" font-family="Segoe UI" font-size="14">'
    'ER-P2C-C1 inner-wall sample; red=joint-fit outlier</text>',
  );
  for (final point in projected) {
    svg.write(
      '<circle cx="${mapX(point.x)}" cy="${mapY(point.y)}" r="${point.outlier ? 1.8 : 1.1}" '
      'fill="${point.outlier ? '#FF6B6B' : '#7DD3FC'}" fill-opacity="0.72"/>',
    );
  }
  svg
    ..write(
      '<text x="30" y="692" fill="#CBD5E1" font-family="Segoe UI" font-size="11">',
    )
    ..write(
      'PCA d=${(pca.radius * 2).toStringAsFixed(3)} mm · Normais d=${(normal.radius * 2).toStringAsFixed(3)} mm · Joint d=${(joint.radius * 2).toStringAsFixed(3)} mm</text>',
    )
    ..write('</svg>');
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(svg.toString());
}

String _cylinderAuditReport({
  required KernelMeshGeometry geometry,
  required List<Vector3> points,
  required List<Vector3> normals,
  required List<
    ({int vertices, double perimeter, double spanX, double spanY, double spanZ})
  >
  boundaryComponents,
  required _ExperimentalCylinderFit pca,
  required _ExperimentalCylinderFit normal,
  required _ExperimentalCylinderFit joint,
  required _ExperimentalCylinderFit robust,
  required double coverageA,
  required double coverageB,
  required double coverageC,
  required double coverageD,
  required RecognitionCandidate directedWinner,
}) {
  final buffer = StringBuffer()
    ..writeln('ER-P2C-C1 real cylinder dimensional audit')
    ..writeln(
      'fixture=C:\\flcad_mobile\\test_assets\\real_meshes\\PARCIAL_FURO_18MM.stl',
    )
    ..writeln('nominal_diameter_mm=18.000')
    ..writeln('mesh_triangles=${geometry.triangles.length ~/ 3}')
    ..writeln('sample_points=${points.length}')
    ..writeln('sample_normals=${normals.length}')
    ..writeln('boundary_components=${boundaryComponents.length}')
    ..writeln('boundary_components_detail=$boundaryComponents')
    ..writeln('directed_production_reference=$directedWinner');
  void method(String name, _ExperimentalCylinderFit fit, double coverage) {
    final diameter = fit.radius * 2;
    buffer
      ..writeln('$name.radius_mm=${fit.radius}')
      ..writeln('$name.diameter_mm=$diameter')
      ..writeln('$name.error_mm=${diameter - 18}')
      ..writeln('$name.error_percent=${(diameter - 18) / 18 * 100}')
      ..writeln('$name.rms_mm=${fit.rms}')
      ..writeln('$name.maximum_mm=${fit.maximum}')
      ..writeln('$name.inliers=${fit.inliers.length}')
      ..writeln('$name.inlier_coverage=${fit.inliers.length / points.length}')
      ..writeln('$name.angular_coverage=$coverage')
      ..writeln('$name.origin=${_vectorText(fit.origin)}')
      ..writeln('$name.axis=${_vectorText(fit.axis)}')
      ..writeln('$name.conditioning=${fit.conditioning}')
      ..writeln('$name.elapsed_us=${fit.elapsedMicros}');
  }

  method('A_pca_robust_radius', pca, coverageA);
  method('B_normal_axis', normal, coverageB);
  method('C_joint_robust', joint, coverageC);
  method('D_trimmed_outlier_rejection', robust, coverageD);
  buffer
    ..writeln(
      'selection_diagnosis=boundary component selected; generic region growing mixed shell',
    )
    ..writeln('production_unchanged=true')
    ..writeln(
      'visual= C:\\flcad_mobile\\artifacts\\ER-P2C-C1-windows-debug\\inner-wall-diagnostic.svg',
    );
  return buffer.toString();
}

String _vectorText(Vector3 value) => '[${value.x}, ${value.y}, ${value.z}]';

({List<Vector3> points, List<Vector3> normals, double radius, double noise})
_syntheticCylinder({
  required Vector3 axis,
  required double start,
  required double end,
  double noise = 0,
  int outliers = 0,
}) {
  final normalizedAxis = axis.normalized;
  final reference = normalizedAxis.z.abs() < .9
      ? const Vector3(0, 0, 1)
      : const Vector3(1, 0, 0);
  final u = normalizedAxis.cross(reference).normalized;
  final v = normalizedAxis.cross(u).normalized;
  final points = <Vector3>[];
  final normals = <Vector3>[];
  for (var axial = -12; axial <= 12; axial += 2) {
    for (var i = 0; i < 72; i++) {
      final angle = start + (end - start) * i / 71;
      final radial = u * math.cos(angle) + v * math.sin(angle);
      final deterministicNoise = noise == 0
          ? 0.0
          : noise * math.sin(i * 17.0 + axial * 0.7);
      points.add(
        radial * (7 + deterministicNoise) + normalizedAxis * axial.toDouble(),
      );
      normals.add(radial);
    }
  }
  for (var i = 0; i < outliers; i++) {
    points.add(Vector3(30.0 + i, -20.0 + i * .5, 15.0));
    normals.add(const Vector3(0, 0, 1));
  }
  return (points: points, normals: normals, radius: 7, noise: noise);
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
