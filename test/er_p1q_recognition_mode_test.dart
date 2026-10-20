import 'dart:io';
import 'dart:async';

import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_context.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/widgets/recognition_workspace_panel.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/adaptive_surface/models/surface_geometry.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/professional_recognition/models/professional_recognition_models.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic recognition publishes the automatic winner', () async {
    final harness = await _ModeHarness.create(
      _FakeRecognitionApi(_report(type: PrimitiveType.sphere)),
    );
    addTearDown(harness.dispose);

    await harness.controller.detectAutomatically();

    expect(harness.controller.error, isNull);
    expect(harness.controller.activeRecognitionResult?.type.name, 'sphere');
    expect(harness.controller.recognitionFilter, isNull);
    expect(harness.controller.hasRecognitionModeMismatch, isFalse);
    expect(harness.controller.canCreateNonPlaneReference, isTrue);

    harness.controller.openSurfaceAssistant(
      harness.controller.activeRecognitionResult!.id,
    );
    expect(harness.controller.canCreateSurfaceFromAssistant, isTrue);
    expect(harness.controller.surfaceCreationBlockReason, isNull);
  });

  test('a new recognition replaces the previous region result', () async {
    final api = _FakeRecognitionApi(_report(type: PrimitiveType.sphere));
    final harness = await _ModeHarness.create(api);
    addTearDown(harness.dispose);
    await harness.controller.detectAutomatically();
    expect(harness.controller.activeRecognitionResult?.type.name, 'sphere');

    api.report = _report(type: PrimitiveType.plane, rms: .002, maximum: .004);
    await harness.controller.detectAutomatically();

    expect(harness.controller.activeRecognitionResult?.type.name, 'plane');
    expect(harness.controller.hypotheses, hasLength(1));
    expect(
      harness.controller.hypotheses.single.recognition.winner.type,
      PrimitiveType.plane,
    );
    expect(
      harness.controller.report?.primitives.single.recognition.winner.type,
      PrimitiveType.plane,
    );
  });

  test('specific filter publishes only the matching winner', () async {
    final harness = await _ModeHarness.create(
      _FakeRecognitionApi(_report(type: PrimitiveType.sphere)),
    );
    addTearDown(harness.dispose);

    await harness.controller.detect('sphere');

    expect(harness.controller.recognitionFilter, 'sphere');
    expect(harness.controller.activeRecognitionResult?.type.name, 'sphere');
    expect(harness.controller.hasRecognitionModeMismatch, isFalse);
    expect(harness.controller.canCreateNonPlaneReference, isTrue);

    await harness.controller.detect('plane');

    expect(harness.controller.activeRecognitionResult, isNull);
    expect(harness.controller.hypotheses, isEmpty);
    expect(harness.controller.hasRecognitionModeMismatch, isTrue);
    expect(harness.controller.canCreatePlaneReference, isFalse);
    expect(harness.controller.canCreateNonPlaneReference, isFalse);
  });

  test('plane filter keeps planar authorization', () async {
    final harness = await _ModeHarness.create(
      _FakeRecognitionApi(
        _report(type: PrimitiveType.plane, rms: .002, maximum: .004),
      ),
    );
    addTearDown(harness.dispose);

    await harness.controller.detect('plane');

    expect(harness.controller.recognitionFilter, 'plane');
    expect(harness.controller.activeRecognitionResult?.type.name, 'plane');
    expect(harness.controller.hasRecognitionModeMismatch, isFalse);
    expect(harness.controller.canCreatePlaneReference, isTrue);
  });

  test(
    'directed plane restricts allowedTypes and records provenance',
    () async {
      final api = _FakeRecognitionApi(
        _report(type: PrimitiveType.plane, rms: .002, maximum: .004),
      );
      final harness = await _ModeHarness.create(api);
      addTearDown(harness.dispose);

      await harness.controller.recognizeDirected(PrimitiveType.plane);

      expect(api.lastAllowedTypes, {PrimitiveType.plane});
      expect(
        harness.controller.requestedRecognitionPrimitive,
        PrimitiveType.plane,
      );
      final result = harness.controller.activeRecognitionResult!;
      expect(result.type.name, 'plane');
      expect(result.parameters['recognitionMode'], 'directed');
      expect(result.parameters['requestedPrimitiveType'], 'plane');
      expect(harness.controller.canCreatePlaneReference, isTrue);
    },
  );

  test(
    'directed cylinder restricts allowedTypes and remains diagnostic-only',
    () async {
      final api = _FakeRecognitionApi(
        _report(type: PrimitiveType.cylinder, rms: .02, maximum: .04),
      );
      final harness = await _ModeHarness.create(api);
      addTearDown(harness.dispose);

      await harness.controller.recognizeDirected(PrimitiveType.cylinder);

      expect(api.lastAllowedTypes, {PrimitiveType.cylinder});
      expect(
        harness.controller.requestedRecognitionPrimitive,
        PrimitiveType.cylinder,
      );
      expect(harness.controller.activeRecognitionResult?.type.name, 'cylinder');
      expect(harness.controller.canCreateNonPlaneReference, isFalse);
      expect(
        harness.controller.nonPlaneReferenceBlockReason,
        contains('somente diagnÃ³stico'),
      );
      expect(
        harness.controller.canCreateRecognizedSurface(SurfaceKind.cylinder),
        isFalse,
      );
    },
  );

  test('degenerate directed cylinder remains CAD-blocked', () async {
    final api = _FakeRecognitionApi(
      _report(
        type: PrimitiveType.cylinder,
        parameters: const {
          'origin': [0.0, 0.0, 0.0],
          'axis': [0.0, 0.0, 0.0],
          'radius': 0.0,
          'area': 12.0,
        },
      ),
    );
    final harness = await _ModeHarness.create(api);
    addTearDown(harness.dispose);

    await harness.controller.recognizeDirected(PrimitiveType.cylinder);

    expect(harness.controller.activeRecognitionResult, isNotNull);
    expect(harness.controller.canCreateNonPlaneReference, isFalse);
    expect(
      harness.controller.canCreateRecognizedSurface(SurfaceKind.cylinder),
      isFalse,
    );
  });

  test(
    'low-confidence directed plane stays diagnostic and blocks CAD',
    () async {
      final api = _FakeRecognitionApi(
        _report(
          type: PrimitiveType.plane,
          confidence: .4,
          rms: .002,
          maximum: .004,
        ),
      );
      final harness = await _ModeHarness.create(api);
      addTearDown(harness.dispose);

      await harness.controller.recognizeDirected(PrimitiveType.plane);

      final result = harness.controller.activeRecognitionResult!;
      expect(result.type.name, 'plane');
      expect(result.parameters['diagnosticOnly'], isTrue);
      expect(harness.controller.isActiveRecognitionDiagnosticOnly, isTrue);
      expect(harness.controller.canCreatePlaneReference, isFalse);
      expect(
        harness.controller.planeReferenceBlockReason,
        contains('Confiança'),
      );
      expect(
        harness.controller.recognitionDiagnostic?['requestedPrimitiveType'],
        'plane',
      );

      harness.controller.previewActiveRecognition();
      expect(harness.controller.activeSurfaceAssistantSuggestion, isNotNull);
      expect(harness.controller.canCreateSurfaceFromAssistant, isFalse);
      expect(
        harness.controller.surfaceCreationBlockReason,
        contains('Confiança'),
      );
      harness.controller.ignoreSurfaceAssistantSuggestion();
      expect(harness.controller.activeSurfaceAssistantSuggestion, isNull);
    },
  );

  test('directed plane outside tolerance remains rejected', () async {
    final api = _FakeRecognitionApi(
      _report(
        type: PrimitiveType.plane,
        confidence: .908,
        rms: .729,
        maximum: 2.757,
      ),
    );
    final harness = await _ModeHarness.create(api);
    addTearDown(harness.dispose);

    await harness.controller.recognizeDirected(PrimitiveType.plane);

    final result = harness.controller.activeRecognitionResult!;
    expect(result.type.name, 'plane');
    expect(result.parameters['dimensionalApproved'], isFalse);
    expect(harness.controller.canCreatePlaneReference, isFalse);
    expect(
      harness.controller.planeReferenceBlockReason,
      contains('dimensional'),
    );
  });

  test('automatic filter preserves existing planar classification', () async {
    final harness = await _ModeHarness.create(
      _FakeRecognitionApi(
        _report(type: PrimitiveType.plane, rms: .002, maximum: .004),
      ),
    );
    addTearDown(harness.dispose);
    harness.cad.runtime.write('recognition.planarDiagnostics', {
      'planarClassification': 'curvedPatch',
    });

    await harness.controller.detect('plane');

    final result = harness.controller.activeRecognitionResult!;
    expect(result.parameters['planarClassification'], 'curvedPatch');
    expect(harness.controller.canCreatePlaneReference, isFalse);
  });

  test('directed plane without a candidate keeps a diagnostic only', () async {
    final harness = await _ModeHarness.create(
      _FakeRecognitionApi(_emptyReport()),
    );
    addTearDown(harness.dispose);

    await harness.controller.recognizeDirected(PrimitiveType.plane);

    expect(harness.controller.activeRecognitionResult, isNull);
    expect(
      harness.controller.recognitionDiagnostic?['requestedPrimitiveType'],
      'plane',
    );
    expect(harness.controller.canCreatePlaneReference, isFalse);
  });

  test(
    'clear recognition selection removes result report and preview',
    () async {
      final harness = await _ModeHarness.create(
        _FakeRecognitionApi(
          _report(type: PrimitiveType.plane, rms: .002, maximum: .004),
        ),
      );
      addTearDown(harness.dispose);
      harness.cad.runtime.debugPutEntity(
        const CadDocumentEntity(
          id: 'kept-surface',
          kind: CadDocumentEntityKind.surface,
          data: {'name': 'kept-surface'},
        ),
      );
      await harness.controller.detectAutomatically();
      final result = harness.controller.activeRecognitionResult!;
      harness.controller.openSurfaceAssistant(result.id);
      expect(harness.controller.activeSurfaceAssistantSuggestion, isNotNull);
      expect(
        harness.cad.runtime.scene.find('surface-assistant-preview'),
        isNotNull,
      );

      harness.controller.clearRecognitionSelection();

      expect(harness.controller.activeContext, isNull);
      expect(harness.controller.activeSelection, isNull);
      expect(harness.controller.activePick, isNull);
      expect(harness.controller.report, isNull);
      expect(harness.controller.activeRecognitionResult, isNull);
      expect(harness.controller.hypotheses, isEmpty);
      expect(harness.controller.activeSurfaceAssistantSuggestion, isNull);
      expect(
        harness.cad.runtime.scene.find('surface-assistant-preview'),
        isNull,
      );
      expect(harness.cad.runtime.document!.entities['kept-surface'], isNotNull);
    },
  );

  test('clear invalidates an in-flight recognition response', () async {
    final api = _DelayedRecognitionApi();
    final harness = await _ModeHarness.create(api);
    addTearDown(harness.dispose);

    final pending = harness.controller.recognizeDirected(PrimitiveType.plane);
    await Future<void>.delayed(Duration.zero);
    expect(api.requests, hasLength(1));

    harness.controller.clearRecognitionSelection();
    expect(harness.controller.busy, isFalse);
    api.requests.single.completer.complete(
      _report(type: PrimitiveType.plane, rms: .002, maximum: .004),
    );
    await pending;

    expect(harness.controller.activeRecognitionResult, isNull);
    expect(harness.controller.report, isNull);
    expect(harness.controller.activeContext, isNull);
  });

  test(
    'a stale directed response cannot replace the latest mode result',
    () async {
      final api = _DelayedRecognitionApi();
      final harness = await _ModeHarness.create(api);
      addTearDown(harness.dispose);

      final directed = harness.controller.recognizeDirected(
        PrimitiveType.plane,
      );
      await Future<void>.delayed(Duration.zero);
      expect(api.requests, hasLength(1));
      expect(api.requests.single.allowedTypes, {PrimitiveType.plane});

      final automatic = harness.controller.detectAutomatically();
      await Future<void>.delayed(Duration.zero);
      expect(api.requests, hasLength(2));
      expect(api.requests.last.allowedTypes, isNull);

      api.requests.last.completer.complete(_report(type: PrimitiveType.sphere));
      await automatic;
      api.requests.first.completer.complete(_report(type: PrimitiveType.plane));
      await directed;

      expect(harness.controller.error, isNull);
      expect(harness.controller.requestedRecognitionPrimitive, isNull);
      expect(harness.controller.activeRecognitionResult?.type.name, 'sphere');
    },
  );

  test(
    'cylinder and cone retain legacy axis-reference authorization',
    () async {
      final cylinder = await _ModeHarness.create(
        _FakeRecognitionApi(_report(type: PrimitiveType.cylinder)),
      );
      addTearDown(cylinder.dispose);
      await cylinder.controller.detect('cylinder');
      expect(
        cylinder.controller.activeRecognitionResult?.type.name,
        'cylinder',
      );
      expect(cylinder.controller.canCreateNonPlaneReference, isTrue);
      expect(cylinder.controller.nonPlaneReferenceBlockReason, isNull);

      final cone = await _ModeHarness.create(
        _FakeRecognitionApi(_report(type: PrimitiveType.cone)),
      );
      addTearDown(cone.dispose);
      await cone.controller.detect('cone');
      expect(cone.controller.activeRecognitionResult?.type.name, 'cone');
      expect(cone.controller.canCreateNonPlaneReference, isTrue);
    },
  );

  test('malformed sphere is not offered as an authorized reference', () async {
    final harness = await _ModeHarness.create(
      _FakeRecognitionApi(
        _report(
          type: PrimitiveType.sphere,
          parameters: const {'radius': 10.0, 'area': 12.0},
        ),
      ),
    );
    addTearDown(harness.dispose);

    await harness.controller.detectAutomatically();

    expect(harness.controller.activeRecognitionResult?.type.name, 'sphere');
    expect(harness.controller.canCreateNonPlaneReference, isFalse);
    expect(
      harness.controller.nonPlaneReferenceBlockReason,
      contains('centro válido'),
    );
  });

  testWidgets('sphere UI omits planar classification and tolerance', (
    tester,
  ) async {
    final harness = (await tester.runAsync(() async {
      final harness = await _ModeHarness.create(
        _FakeRecognitionApi(
          _report(
            type: PrimitiveType.sphere,
            confidence: .908,
            rms: .729,
            maximum: 2.757,
          ),
        ),
      );
      await harness.controller.detectAutomatically();
      return harness;
    }))!;
    addTearDown(harness.dispose);
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: RecognitionWorkspacePanel(controller: harness.controller),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Não aplicável a este tipo'), findsOneWidget);
    expect(find.textContaining('Tolerância'), findsNothing);
    expect(find.textContaining('Tolerância planar'), findsNothing);
    expect(
      find.textContaining('Automático executa o motor multiprimitiva'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(
              FilledButton,
              'Aceitar esfera e criar referência',
            ),
          )
          .onPressed,
      isNotNull,
    );
    expect(harness.controller.canCreateNonPlaneReference, isTrue);
  });

  testWidgets('directed cylinder UI exposes metrics without CAD action', (
    tester,
  ) async {
    final harness = (await tester.runAsync(() async {
      final value = await _ModeHarness.create(
        _FakeRecognitionApi(
          _report(
            type: PrimitiveType.cylinder,
            parameters: const {
              'origin': [0.0, 0.0, 0.0],
              'axis': [0.0, 0.0, 1.0],
              'radius': 5.0,
              'area': 12.0,
            },
          ),
        ),
      );
      await value.controller.recognizeDirected(PrimitiveType.cylinder);
      return value;
    }))!;
    addTearDown(harness.dispose);
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: RecognitionWorkspacePanel(controller: harness.controller),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Reconhecer Cilindro'), findsOneWidget);
    expect(find.text('Origem do eixo'), findsOneWidget);
    expect(find.text('Direção do eixo'), findsOneWidget);
    expect(find.text('RMS radial'), findsOneWidget);
    expect(find.text('Desvio máximo radial'), findsOneWidget);
    expect(find.text('Cobertura de inliers'), findsOneWidget);
    expect(harness.controller.canCreateNonPlaneReference, isFalse);
  });

  testWidgets('filter mismatch is shown and creation stays disabled', (
    tester,
  ) async {
    final harness = (await tester.runAsync(() async {
      final harness = await _ModeHarness.create(
        _FakeRecognitionApi(_report(type: PrimitiveType.sphere)),
      );
      await harness.controller.detect('plane');
      return harness;
    }))!;
    addTearDown(harness.dispose);
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: RecognitionWorkspacePanel(controller: harness.controller),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('Filtro Plano sem correspondência'),
      findsOneWidget,
    );
    expect(find.textContaining('Vencedor automático: Esfera'), findsOneWidget);
    expect(find.text('Aceitar esfera e criar referência'), findsNothing);
    expect(harness.controller.canCreatePlaneReference, isFalse);
    expect(harness.controller.canCreateNonPlaneReference, isFalse);
  });

  testWidgets('directed plane is presented separately from automatic filters', (
    tester,
  ) async {
    final harness = (await tester.runAsync(() async {
      final harness = await _ModeHarness.create(
        _FakeRecognitionApi(
          _report(type: PrimitiveType.plane, rms: .002, maximum: .004),
        ),
      );
      await harness.controller.recognizeDirected(PrimitiveType.plane);
      return harness;
    }))!;
    addTearDown(harness.dispose);
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: RecognitionWorkspacePanel(controller: harness.controller),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Reconhecer Plano'), findsOneWidget);
    expect(find.textContaining('Modo dirigido: Plano'), findsOneWidget);
    expect(find.text('Tipo solicitado'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(
              FilledButton,
              'Aceitar plano e criar referência',
            ),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('low-confidence directed plane is shown as diagnostic', (
    tester,
  ) async {
    final harness = (await tester.runAsync(() async {
      final harness = await _ModeHarness.create(
        _FakeRecognitionApi(
          _report(
            type: PrimitiveType.plane,
            confidence: .4,
            rms: .002,
            maximum: .004,
          ),
        ),
      );
      await harness.controller.recognizeDirected(PrimitiveType.plane);
      return harness;
    }))!;
    addTearDown(harness.dispose);
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: RecognitionWorkspacePanel(controller: harness.controller),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Diagnóstico · criação CAD bloqueada'), findsOneWidget);
    expect(find.text('Tipo solicitado'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(
              FilledButton,
              'Aceitar plano e criar referência',
            ),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Pré-visualizar diagnóstico'),
          )
          .onPressed,
      isNotNull,
    );
  });
}

final class _FakeRecognitionApi extends ProfessionalRecognitionApi {
  _FakeRecognitionApi(this.report);

  ProfessionalRecognitionReport report;
  Set<PrimitiveType>? lastAllowedTypes;

  @override
  Future<ProfessionalRecognitionReport> recognize(
    List<RecognitionContext> regions, {
    Set<PrimitiveType>? allowedTypes,
  }) async {
    lastAllowedTypes = allowedTypes;
    return report;
  }
}

final class _DelayedRecognitionApi extends ProfessionalRecognitionApi {
  final requests =
      <
        ({
          Set<PrimitiveType>? allowedTypes,
          Completer<ProfessionalRecognitionReport> completer,
        })
      >[];

  @override
  Future<ProfessionalRecognitionReport> recognize(
    List<RecognitionContext> regions, {
    Set<PrimitiveType>? allowedTypes,
  }) {
    final completer = Completer<ProfessionalRecognitionReport>();
    requests.add((allowedTypes: allowedTypes, completer: completer));
    return completer.future;
  }
}

final class _ModeHarness {
  _ModeHarness({
    required this.cad,
    required this.controller,
    required this.directory,
  });

  final DesktopCadController cad;
  final OperationalReverseEngineeringController controller;
  final Directory directory;

  static Future<_ModeHarness> create(ProfessionalRecognitionApi api) async {
    final cad = DesktopCadController(
      kernels: KernelManager(),
      projects: ProjectManager.instance,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    final directory = Directory.systemTemp.createTempSync('flcad-er-p1q-');
    await cad.runtime.open('project', directory);
    cad.runtime.debugPutEntity(
      const CadDocumentEntity(
        id: 'Mesh001',
        kind: CadDocumentEntityKind.recognition,
        data: {'name': 'Mesh001'},
      ),
    );
    final controller = OperationalReverseEngineeringController(
      recognition: api,
      commands: commands,
      runtime: cad.runtime,
    );
    controller.configuredProjectId = 'project';
    final geometry = KernelMeshGeometry(
      nodes: const [0, 0, 0, 1, 0, 0, 0, 1, 0],
      triangles: const [0, 1, 2],
    );
    controller.activeSelection = BridgeSelection(
      id: 'region-1',
      entityId: 'mesh',
      kind: BridgeSelectionKind.meshRegion,
      geometry: geometry,
      triangleIndices: const {0},
    );
    controller.activePick = const CadViewportPick(
      entityId: 'mesh',
      hit: MeshHit(triangleIndex: 0, point: Vector3.zero, distance: 1),
    );
    controller.activeContext = BridgeContext(
      projectId: 'project',
      meshId: 'Mesh001',
      meshFingerprint: 'fingerprint',
      userConfirmed: false,
      region: MeshRegion(
        id: 'region-1',
        meshId: 'Mesh001',
        triangleIndices: List<int>.generate(3656, (index) => index),
        vertexIndices: const [0, 1, 2],
        points: const [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)],
        normals: const [Vector3(0, 0, 1)],
        bounds: const KernelBounds(0, 0, 0, 1, 1, 0),
        area: 12.0,
        connectivity: const {0: {}},
        fingerprint: 'region-fingerprint',
      ),
    );
    return _ModeHarness(cad: cad, controller: controller, directory: directory);
  }

  void dispose() {
    controller.dispose();
    cad.dispose();
    directory.deleteSync(recursive: true);
  }
}

ProfessionalRecognitionReport _report({
  required PrimitiveType type,
  Map<String, dynamic>? parameters,
  double confidence = .908,
  double rms = .729,
  double maximum = 2.757,
}) {
  final values =
      parameters ??
      switch (type) {
        PrimitiveType.sphere => const {
          'center': [0.0, 0.0, 0.0],
          'radius': 10.0,
          'area': 12.0,
        },
        PrimitiveType.plane => const {
          'origin': [0.0, 0.0, 0.0],
          'normal': [0.0, 0.0, 1.0],
          'area': 12.0,
        },
        PrimitiveType.cylinder => const {
          'origin': [0.0, 0.0, 0.0],
          'axis': [0.0, 0.0, 1.0],
          'radius': 10.0,
          'area': 12.0,
        },
        PrimitiveType.cone => const {
          'origin': [0.0, 0.0, 0.0],
          'axis': [0.0, 0.0, 1.0],
          'halfAngle': .5,
          'referenceRadius': 10.0,
          'area': 12.0,
        },
        PrimitiveType.torus => const {
          'center': [0.0, 0.0, 0.0],
          'axis': [0.0, 0.0, 1.0],
          'majorRadius': 10.0,
          'minorRadius': 2.0,
          'area': 12.0,
        },
        _ => const {'area': 12.0},
      };
  final statistics = FitStatistics(
    rms: rms,
    maximum: maximum,
    mean: rms,
    coverage: .98,
    stability: .9,
    score: .9,
  );
  final candidate = RecognitionCandidate(
    id: 'candidate:${type.name}',
    type: type,
    regionId: 'region-1',
    parameters: values,
    statistics: statistics,
    evidence: const [],
    origin: 'test',
  );
  final primitive = ProfessionalPrimitive(
    recognition: PrimitiveRecognitionResult(
      id: 'recognition:${type.name}',
      projectId: 'project',
      meshId: 'Mesh001',
      winner: candidate,
      alternatives: const [],
      dna: RecognitionDNA(
        type: type,
        parameters: values,
        regionId: 'region-1',
        geometricSignature: type.name,
        quality: .9,
        confidence: confidence,
        evidence: const [],
        origin: 'test',
        version: '1',
      ),
      explanation: RecognitionExplanation(
        why: 'synthetic ${type.name}',
        evidence: const [],
        regions: const ['region-1'],
        parameters: const {},
        losingCandidates: const [],
        score: .9,
        confidence: confidence,
      ),
      createdAt: DateTime(2026, 1, 1),
    ),
    residualMap: const ResidualMap([], [], []),
    pass: 1,
    auditTrail: const ['test'],
  );
  return ProfessionalRecognitionReport(
    projectId: 'project',
    primitives: [primitive],
    relations: const [],
    features: const [],
    patterns: const [],
    functions: const [],
    manufacturing: const [],
    advice: const [],
    elapsed: const Duration(milliseconds: 1),
    pendingRegionIds: const [],
    createdAt: DateTime(2026, 1, 1),
  );
}

ProfessionalRecognitionReport _emptyReport() => ProfessionalRecognitionReport(
  projectId: 'project',
  primitives: const [],
  relations: const [],
  features: const [],
  patterns: const [],
  functions: const [],
  manufacturing: const [],
  advice: const [],
  elapsed: const Duration(milliseconds: 1),
  pendingRegionIds: const ['region-1'],
  createdAt: DateTime(2026, 1, 1),
);
