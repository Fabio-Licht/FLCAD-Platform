import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_context.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/editable_surface_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/mesh_region_builder.dart';
import 'package:flcad_mobile/app/engineering_bridge/widgets/recognition_workspace_panel.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/professional_recognition/models/professional_recognition_models.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'editable selection expands contracts adds removes and resists jumps',
    () {
      final geometry = _gridGeometry();
      final selection = EditableSurfaceSelection(
        projectId: 'project',
        meshId: 'mesh',
        meshFingerprint: 'grid',
        entityId: 'mesh',
        geometry: geometry,
        initialTriangles: const {0},
        area: 1,
      );

      final ring = selection.expandRing();
      expect(ring, isNotEmpty);
      expect(ring, isNot(contains(0)));
      selection.replaceCurrent({0, ...ring}, area: 2);
      expect(selection.isEdited, isTrue);
      final contracted = selection.contractRing();
      expect(contracted, isNotEmpty);
      expect(contracted.length, lessThan(selection.currentTriangles.length));

      final add = EditableSurfaceSelection(
        projectId: 'project',
        meshId: 'mesh',
        meshFingerprint: 'grid',
        entityId: 'mesh',
        geometry: geometry,
        initialTriangles: const {0},
        area: 1,
      );
      expect(add.localAdd(1), {1});
      expect(() => add.localAdd(2), throwsStateError);
      add.replaceCurrent({0, 1}, area: 2);
      expect(add.localRemove(0), {0});

      final empty = EditableSurfaceSelection(
        projectId: 'project',
        meshId: 'mesh',
        meshFingerprint: 'grid',
        entityId: 'mesh',
        geometry: geometry,
        initialTriangles: const {},
        area: 0,
      );
      expect(empty.expandRing(), isEmpty);
      expect(empty.contractRing(), isEmpty);
      expect(() => empty.localAdd(0), throwsStateError);
      expect(() => empty.localRemove(0), throwsStateError);
    },
  );

  test(
    'controller edits the region used by recognition and local history',
    () async {
      final harness = await _SelectionHarness.create();
      addTearDown(harness.dispose);

      await harness.controller.detectAutomatically();

      expect(harness.controller.hasEditableSelection, isTrue);
      expect(harness.controller.selectionTriangleCount, 3);
      expect(
        harness.controller.activeContext!.region!.fingerprint,
        isNot(contains('edited')),
      );
      expect(harness.controller.activeRecognitionResult, isNotNull);
      final initialFingerprint =
          harness.controller.activeContext!.region!.fingerprint;

      // A prior multiscale classification belongs to the old triangle set and
      // must never leak into an edited region.
      harness.cad.runtime.write('recognition.planarDiagnostics', {
        'planarClassification': 'planarCadCandidate',
      });
      await harness.controller.expandRecognitionSelection();
      expect(harness.controller.selectionTriangleCount, greaterThan(3));
      expect(harness.controller.lastSelectionAdded, greaterThan(0));
      expect(harness.controller.selectionIsEdited, isTrue);
      final expandedCount = harness.controller.selectionTriangleCount;
      final expandedFingerprint =
          harness.controller.activeContext!.region!.fingerprint;
      expect(expandedFingerprint, isNot(initialFingerprint));
      expect(harness.commands.manager.canUndo, isFalse);

      await harness.controller.contractRecognitionSelection();
      expect(
        harness.controller.selectionTriangleCount,
        lessThan(expandedCount),
      );
      final contractedCount = harness.controller.selectionTriangleCount;
      await harness.controller.undoRecognitionSelection();
      expect(harness.controller.selectionTriangleCount, expandedCount);
      await harness.controller.redoRecognitionSelection();
      expect(harness.controller.selectionTriangleCount, contractedCount);

      final current = {
        ...harness.controller.editableSelection!.currentTriangles,
      };
      final adjacent = current
          .map(harness.controller.editableSelection!.neighborsOf)
          .expand((values) => values)
          .firstWhere((value) => !current.contains(value));
      harness.controller.setSelectionTool(RecognitionSelectionTool.add);
      await harness.controller.editRecognitionSelection(_pick(adjacent));
      expect(
        harness.controller.selectionTriangleCount,
        greaterThan(current.length),
      );
      final afterAdd = harness.controller.selectionTriangleCount;
      harness.controller.setSelectionTool(RecognitionSelectionTool.remove);
      await harness.controller.editRecognitionSelection(_pick(adjacent));
      expect(harness.controller.selectionTriangleCount, lessThan(afterAdd));
      // Removing the local patch can return to the initial triangle set. Grow
      // once more so the directed fit is evaluated on an edited region.
      await harness.controller.expandRecognitionSelection();
      expect(harness.controller.selectionIsEdited, isTrue);

      final editedTriangles = harness
          .controller
          .activeContext!
          .region!
          .triangleIndices
          .toSet();
      expect(
        editedTriangles,
        harness.controller.editableSelection!.currentTriangles,
      );
      expect(
        harness.controller.activeRecognitionResult?.regionId,
        harness.controller.activeContext!.region!.id,
      );

      await harness.controller.recognizeDirected(PrimitiveType.plane);
      expect(harness.controller.activeRecognitionResult?.type.name, 'plane');
      expect(
        harness.controller.activeContext!.region!.triangleIndices.toSet(),
        harness.controller.editableSelection!.currentTriangles,
      );
      final editedResult = harness.controller.activeRecognitionResult!;
      expect(editedResult.parameters['planarClassification'], 'localReference');
      expect(editedResult.parameters['referenceApproved'], isTrue);
      expect(editedResult.parameters['cadSurfaceApproved'], isFalse);
      expect(harness.controller.canCreatePlaneReference, isTrue);
      harness.controller.previewActiveRecognition();
      expect(harness.controller.canCreateSurfaceFromAssistant, isFalse);
      expect(
        harness.controller.surfaceCreationBlockReason,
        contains('Referência local'),
      );
      harness.controller.ignoreSurfaceAssistantSuggestion();

      await harness.controller.detectAutomatically();
      expect(harness.controller.activeRecognitionResult?.type.name, 'plane');
      expect(
        harness
            .controller
            .activeRecognitionResult!
            .parameters['planarClassification'],
        'localReference',
      );

      harness.controller.clearRecognitionSelection();
      expect(harness.controller.hasEditableSelection, isFalse);
      expect(harness.controller.activeContext, isNull);
      expect(harness.cad.runtime.document!.entities['mesh'], isNotNull);
    },
  );

  test('restoring the automatic region preserves its classification', () async {
    final harness = await _SelectionHarness.create();
    addTearDown(harness.dispose);

    harness.cad.runtime.write('recognition.planarDiagnostics', {
      'planarClassification': 'curvedPatch',
    });
    await harness.controller.detectAutomatically();

    expect(
      harness
          .controller
          .activeRecognitionResult!
          .parameters['planarClassification'],
      'curvedPatch',
    );
    expect(harness.controller.canCreatePlaneReference, isFalse);

    await harness.controller.expandRecognitionSelection();
    expect(harness.controller.selectionIsEdited, isTrue);
    final editedClassification = harness
        .controller
        .activeRecognitionResult!
        .parameters['planarClassification'];
    expect(editedClassification, isNot('curvedPatch'));
    expect(editedClassification, anyOf('localReference', 'planarCadCandidate'));
    expect(harness.controller.canCreatePlaneReference, isTrue);

    await harness.controller.restoreAutomaticRecognitionSelection();
    expect(harness.controller.selectionIsEdited, isFalse);
    expect(
      harness
          .controller
          .activeRecognitionResult!
          .parameters['planarClassification'],
      'curvedPatch',
    );
    expect(harness.controller.canCreatePlaneReference, isFalse);
  });

  test('stale recognition after clear does not republish a result', () async {
    final recognition = _DelayedRecognitionApi();
    final harness = await _SelectionHarness.create(recognition: recognition);
    addTearDown(harness.dispose);

    final pending = harness.controller.detectAutomatically();
    await recognition.started.future;
    harness.controller.clearRecognitionSelection();
    recognition.release.complete();
    await pending;

    expect(harness.controller.activeRecognitionResult, isNull);
    expect(harness.controller.recognitionDiagnostic, isNull);
    expect(harness.controller.hasEditableSelection, isFalse);
    expect(harness.controller.activeContext, isNull);
    expect(harness.controller.report, isNull);
    expect(harness.controller.error, isNull);
  });

  test('editing rejects a pick from another mesh', () async {
    final harness = await _SelectionHarness.create();
    addTearDown(harness.dispose);
    await harness.controller.detectAutomatically();
    harness.controller.setSelectionTool(RecognitionSelectionTool.add);

    await harness.controller.editRecognitionSelection(
      CadViewportPick(
        entityId: 'other',
        hit: MeshHit(triangleIndex: 1, point: Vector3.zero, distance: 1),
      ),
    );

    expect(harness.controller.error, contains('outra malha'));
    expect(harness.controller.selectionTriangleCount, 3);
    expect(harness.controller.selectionIsEdited, isFalse);
  });

  testWidgets('selection controls expose counts and clear the edit state', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_SelectionHarness.create))!;
    addTearDown(harness.dispose);
    await tester.runAsync(harness.controller.detectAutomatically);
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final systemFont = File(r'C:\Windows\Fonts\segoeui.ttf');
    if (systemFont.existsSync()) {
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(ByteData.sublistView(systemFont.readAsBytesSync())),
        );
      await loader.load();
    }
    final captureKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: RepaintBoundary(
            key: captureKey,
            child: SingleChildScrollView(
              child: SizedBox(
                width: 420,
                child: RecognitionWorkspacePanel(
                  controller: harness.controller,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Edição da região'), findsOneWidget);
    expect(find.textContaining('Triângulos selecionados: 3'), findsOneWidget);
    expect(find.text('Expandir'), findsOneWidget);
    expect(find.text('Contrair'), findsOneWidget);

    await tester.runAsync(harness.controller.expandRecognitionSelection);
    await tester.pump();
    expect(
      find.textContaining(
        'Triângulos selecionados: '
        '${harness.controller.selectionTriangleCount}',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Região editada · revisão'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            const {
              'Referência local',
              'Candidato a superfície planar CAD',
              'Ambígua',
            }.any((label) => widget.data?.contains(label) == true),
      ),
      findsOneWidget,
    );
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File(
        r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-S1\recognition_panel_edited_DIAGNOSTIC.png',
      );
      file.parent.createSync(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    });

    await tester.tap(find.widgetWithText(TextButton, 'Limpar seleção'));
    await tester.pump();
    expect(find.text('Edição da região'), findsNothing);
  });
}

final class _SelectionHarness {
  _SelectionHarness({
    required this.cad,
    required this.commands,
    required this.controller,
    required this.directory,
  });

  final DesktopCadController cad;
  final DesktopCommandCoordinator commands;
  final OperationalReverseEngineeringController controller;
  final Directory directory;

  static Future<_SelectionHarness> create({
    ProfessionalRecognitionApi? recognition,
  }) async {
    final directory = await Directory.systemTemp.createTemp('flcad-p2d-s1-');
    final cad = DesktopCadController(
      kernels: KernelManager(),
      projects: ProjectManager.instance,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    await cad.runtime.open('project', directory);
    cad.runtime.debugPutEntity(
      const CadDocumentEntity(
        id: 'mesh',
        kind: CadDocumentEntityKind.recognition,
        data: {'name': 'mesh'},
      ),
    );
    final geometry = _gridGeometry();
    final initialTriangles = {0, 1, 3};
    final selection = BridgeSelection(
      id: 'initial',
      entityId: 'mesh',
      kind: BridgeSelectionKind.meshRegion,
      geometry: geometry,
      triangleIndices: initialTriangles,
    );
    final region = const MeshRegionBuilder().build(
      meshId: 'mesh',
      selection: selection,
    );
    final controller = OperationalReverseEngineeringController(
      recognition: recognition ?? ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
    );
    controller.configuredProjectId = 'project';
    controller.activeSelection = selection;
    controller.activeContext = BridgeContext(
      projectId: 'project',
      meshId: 'mesh',
      meshFingerprint: 'grid-fingerprint',
      userConfirmed: false,
      region: region,
    );
    controller.activePick = _pick(0);
    return _SelectionHarness(
      cad: cad,
      commands: commands,
      controller: controller,
      directory: directory,
    );
  }

  void dispose() {
    controller.dispose();
    cad.dispose();
    directory.deleteSync(recursive: true);
  }
}

final class _DelayedRecognitionApi extends ProfessionalRecognitionApi {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  final ProfessionalRecognitionApi _delegate = ProfessionalRecognitionApi();

  @override
  Future<ProfessionalRecognitionReport> recognize(
    List<RecognitionContext> regions, {
    Set<PrimitiveType>? allowedTypes,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return _delegate.recognize(regions, allowedTypes: allowedTypes);
  }
}

CadViewportPick _pick(int triangle) {
  final geometry = _gridGeometry();
  final vertex = geometry.triangles[triangle * 3];
  final offset = vertex * 3;
  return CadViewportPick(
    entityId: 'mesh',
    hit: MeshHit(
      triangleIndex: triangle,
      point: Vector3(
        geometry.nodes[offset],
        geometry.nodes[offset + 1],
        geometry.nodes[offset + 2],
      ),
      distance: 1,
    ),
  );
}

KernelMeshGeometry _gridGeometry() {
  const columns = 4;
  final nodes = <double>[];
  for (var y = 0; y < columns; y++) {
    for (var x = 0; x < columns; x++) {
      nodes.addAll([x.toDouble(), y.toDouble(), 0]);
    }
  }
  final triangles = <int>[];
  for (var y = 0; y < columns - 1; y++) {
    for (var x = 0; x < columns - 1; x++) {
      final a = y * columns + x;
      triangles.addAll([a, a + 1, a + columns + 1]);
      triangles.addAll([a, a + columns + 1, a + columns]);
    }
  }
  return KernelMeshGeometry(nodes: nodes, triangles: triangles);
}
