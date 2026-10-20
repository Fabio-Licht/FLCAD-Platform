import 'dart:io';

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_context.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/widgets/recognition_workspace_panel.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/professional_recognition/models/professional_recognition_models.dart';
import 'package:flcad_mobile/core/recognition_engine/recognition_result.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('curvedPatch offers explicit manual CAD confirmation', (
    tester,
  ) async {
    final harness = await _PanelHarness.create(
      tester,
      parameters: _planeParameters(
        classification: 'curvedPatch',
        dimensionalStatus: 'diagnostic-only',
        referenceApproved: false,
        cadSurfaceApproved: false,
      ),
    );
    addTearDown(harness.dispose);

    await harness.pump(tester);

    expect(harness.controller.canCreatePlaneReference, isFalse);
    expect(planeReferenceButton(tester).onPressed, isNotNull);
    expect(find.textContaining('Trecho de superfície curva'), findsWidgets);
    expect(tester.widget<OutlinedButton>(previewFinder()).onPressed, isNotNull);

    await tester.ensureVisible(previewFinder());
    await tester.pump();
    await tester.tap(previewFinder());
    await tester.pump();

    expect(harness.controller.activeSurfaceAssistantSuggestion, isNotNull);
    expect(harness.controller.canCreateSurfaceFromAssistant, isFalse);
    expect(surfaceCreationButton(tester).onPressed, isNotNull);
    expect(harness.controller.canRequestManualSurfaceAction, isTrue);
    expect(
      harness.controller.surfaceCreationBlockReason,
      contains('somente diagnóstico'),
    );
  });

  testWidgets(
    'localReference authorizes the reference but not the CAD surface',
    (tester) async {
      final harness = await _PanelHarness.create(
        tester,
        parameters: _planeParameters(
          classification: 'localReference',
          referenceApproved: true,
          cadSurfaceApproved: false,
        ),
      );
      addTearDown(harness.dispose);

      await harness.pump(tester);

      expect(harness.controller.canCreatePlaneReference, isTrue);
      expect(planeReferenceButton(tester).onPressed, isNotNull);

      await tester.ensureVisible(previewFinder());
      await tester.pump();
      await tester.tap(previewFinder());
      await tester.pump();

      expect(harness.controller.activeSurfaceAssistantSuggestion, isNotNull);
      expect(harness.controller.canCreateSurfaceFromAssistant, isFalse);
      expect(surfaceCreationButton(tester).onPressed, isNotNull);
      expect(harness.controller.canRequestManualSurfaceAction, isTrue);
      expect(
        find.textContaining('autoriza a referência, mas não a superfície CAD'),
        findsOneWidget,
      );

      final cancel = find.widgetWithText(OutlinedButton, 'Cancelar');
      await tester.ensureVisible(cancel);
      await tester.pump();
      await tester.tap(cancel);
      await tester.pump();
      expect(harness.controller.activeSurfaceAssistantSuggestion, isNull);
    },
  );

  testWidgets('planarCadCandidate enables both authorized creation actions', (
    tester,
  ) async {
    final harness = await _PanelHarness.create(
      tester,
      parameters: _planeParameters(
        classification: 'planarCadCandidate',
        referenceApproved: true,
        cadSurfaceApproved: true,
        confidence: .96,
      ),
    );
    addTearDown(harness.dispose);

    await harness.pump(tester);

    expect(harness.controller.canCreatePlaneReference, isTrue);
    expect(planeReferenceButton(tester).onPressed, isNotNull);

    await tester.ensureVisible(previewFinder());
    await tester.pump();
    await tester.tap(previewFinder());
    await tester.pump();

    expect(harness.controller.canCreateSurfaceFromAssistant, isTrue);
    expect(surfaceCreationButton(tester).onPressed, isNotNull);
  });

  testWidgets('planar recognition exposes surface action before preview', (
    tester,
  ) async {
    final harness = await _PanelHarness.create(
      tester,
      parameters: _planeParameters(
        classification: 'planarCadCandidate',
        referenceApproved: true,
        cadSurfaceApproved: true,
      ),
    );
    addTearDown(harness.dispose);

    await harness.pump(tester);
    expect(find.textContaining('Criar superf'), findsOneWidget);
    expect(harness.controller.canOpenSurfaceCreation, isTrue);
    expect(harness.controller.activeSurfaceAssistantSuggestion, isNull);
    return;
  });

  testWidgets('surface action explains when the CAD domain is missing', (
    tester,
  ) async {
    final harness = await _PanelHarness.create(
      tester,
      parameters: _planeParameters(
        classification: 'planarCadCandidate',
        referenceApproved: true,
        cadSurfaceApproved: true,
      ),
    );
    addTearDown(harness.dispose);

    harness.controller.activeContext = null;
    await harness.pump(tester);
    expect(find.textContaining('Criar superf'), findsOneWidget);
    expect(harness.controller.canOpenSurfaceCreation, isFalse);
    expect(
      find.textContaining('Defina uma regiÃ£o planar conectada'),
      findsOneWidget,
    );
  });

  testWidgets('rejected dimensional result requires manual confirmation', (
    tester,
  ) async {
    final harness = await _PanelHarness.create(
      tester,
      parameters: _planeParameters(
        classification: 'planarCadCandidate',
        dimensionalStatus: 'rejected',
        dimensionalApproved: false,
        referenceApproved: false,
        cadSurfaceApproved: false,
        rms: .25,
        maximum: .8,
        tolerance: .1,
      ),
    );
    addTearDown(harness.dispose);

    await harness.pump(tester);

    expect(harness.controller.canCreatePlaneReference, isFalse);
    expect(planeReferenceButton(tester).onPressed, isNotNull);
    expect(
      find.textContaining('Resultado dimensional reprovado'),
      findsOneWidget,
    );

    await tester.ensureVisible(previewFinder());
    await tester.pump();
    await tester.tap(previewFinder());
    await tester.pump();

    expect(harness.controller.canCreateSurfaceFromAssistant, isFalse);
    expect(surfaceCreationButton(tester).onPressed, isNotNull);
    expect(harness.controller.canRequestManualSurfaceAction, isTrue);
    expect(
      harness.controller.surfaceCreationBlockReason,
      contains('Resultado dimensional reprovado'),
    );
  });

  testWidgets('manual approval expires when the mesh context changes', (
    tester,
  ) async {
    final harness = await _PanelHarness.create(
      tester,
      parameters: _planeParameters(
        classification: 'curvedPatch',
        referenceApproved: false,
        cadSurfaceApproved: false,
      ),
    );
    addTearDown(harness.dispose);

    harness.controller.prepareManualRecognitionApproval('reference');
    expect(harness.controller.canCreatePlaneReference, isTrue);

    harness.controller.activeContext = BridgeContext(
      projectId: 'project',
      meshId: 'Mesh002',
      meshFingerprint: 'different-fingerprint',
      userConfirmed: false,
      region: harness.controller.activeContext!.region,
    );
    expect(harness.controller.canCreatePlaneReference, isFalse);
  });

  testWidgets('non-finite fitting parameters cannot be manually approved', (
    tester,
  ) async {
    final harness = await _PanelHarness.create(
      tester,
      parameters: _planeParameters(
        classification: 'curvedPatch',
        referenceApproved: false,
        cadSurfaceApproved: false,
      ),
    );
    addTearDown(harness.dispose);

    harness.controller.activeRecognitionResult!.parameters['normal'] = <double>[
      double.nan,
      0,
      0,
    ];
    expect(harness.controller.hasValidPlanarFitting, isFalse);
    expect(
      () => harness.controller.prepareManualRecognitionApproval('reference'),
      throwsStateError,
    );
  });
}

FilledButton planeReferenceButton(WidgetTester tester) =>
    tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Aceitar plano e criar referência'),
    );

FilledButton surfaceCreationButton(WidgetTester tester) =>
    tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Criar superfície'),
    );

Finder previewFinder() =>
    find.widgetWithText(OutlinedButton, 'Pré-visualizar diagnóstico');

Map<String, dynamic> _planeParameters({
  required String classification,
  String dimensionalStatus = 'approved',
  bool dimensionalApproved = true,
  required bool referenceApproved,
  required bool cadSurfaceApproved,
  double rms = .002,
  double maximum = .004,
  double tolerance = .05,
  double confidence = .96,
}) => {
  'origin': <double>[0, 0, 0],
  'normal': <double>[0, 0, 1],
  'area': 12.5,
  'rmsDeviation': rms,
  'maximumDeviation': maximum,
  'dimensionalToleranceMm': tolerance,
  'dimensionalStatus': dimensionalStatus,
  'dimensionalApproved': dimensionalApproved,
  'dimensionalReason': dimensionalApproved
      ? 'RMS e desvio máximo dentro da tolerância configurada.'
      : 'RMS ou desvio máximo excede a tolerância configurada.',
  'referenceApproved': referenceApproved,
  'cadSurfaceApproved': cadSurfaceApproved,
  'planarClassification': classification,
  'planarClassificationReason': 'Classificação sintética de teste.',
  'confidenceForTest': confidence,
};

final class _PanelHarness {
  _PanelHarness({
    required this.cad,
    required this.controller,
    required this.directory,
  });

  final DesktopCadController cad;
  final OperationalReverseEngineeringController controller;
  final Directory directory;

  static Future<_PanelHarness> create(
    WidgetTester tester, {
    required Map<String, dynamic> parameters,
  }) async {
    final harness = await tester.runAsync(() async {
      final cad = DesktopCadController(
        kernels: KernelManager(),
        projects: ProjectManager.instance,
      );
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
      );
      final directory = Directory.systemTemp.createTempSync('flcad-er-p1p-');
      await cad.runtime.open('project', directory);
      final controller = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: commands,
        runtime: cad.runtime,
      );
      final result = RecognitionResult(
        id: 'Recognition001',
        type: RecognitionResultType.plane,
        meshId: 'Mesh001',
        regionId: 'region-1',
        confidence: (parameters['confidenceForTest'] as num).toDouble(),
        parameters: parameters,
        quality: 'RMS 0.002 · coverage 99.0%',
        suggestion: 'Review and confirm before reconstruction',
        createdAt: DateTime(2026, 1, 1),
      );
      final primitive = _planePrimitive();
      controller.report = ProfessionalRecognitionReport(
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
      controller.decisions
        ..clear()
        ..[primitive.recognition.id] = RecognitionDecision.pending;
      controller.activeContext = BridgeContext(
        projectId: 'project',
        meshId: 'Mesh001',
        meshFingerprint: 'fingerprint',
        userConfirmed: false,
        region: MeshRegion(
          id: 'region-1',
          meshId: 'Mesh001',
          triangleIndices: const [0, 1, 2, 3, 4],
          vertexIndices: const [0, 1, 2, 3, 4],
          points: const [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)],
          normals: const [Vector3(0, 0, 1)],
          bounds: const KernelBounds(0, 0, 0, 1, 1, 0),
          area: 12.5,
          connectivity: const {
            0: {1, 2},
          },
          fingerprint: 'region-fingerprint',
        ),
      );
      cad.runtime.debugPutEntity(
        CadDocumentEntity(
          id: result.id,
          kind: CadDocumentEntityKind.recognition,
          data: {'name': result.id, 'recognitionResult': result.toJson()},
        ),
      );
      cad.runtime.write('recognition.activeResult', result);
      return _PanelHarness(
        cad: cad,
        controller: controller,
        directory: directory,
      );
    });
    return harness!;
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 380,
              child: RecognitionWorkspacePanel(controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  void dispose() {
    controller.dispose();
    cad.dispose();
    directory.deleteSync(recursive: true);
  }
}

ProfessionalPrimitive _planePrimitive() {
  const statistics = FitStatistics(
    rms: .002,
    maximum: .004,
    mean: .002,
    coverage: .99,
    stability: .98,
    score: .97,
  );
  const candidate = RecognitionCandidate(
    id: 'candidate:plane',
    type: PrimitiveType.plane,
    regionId: 'region-1',
    parameters: {
      'origin': [0, 0, 0],
      'normal': [0, 0, 1],
    },
    statistics: statistics,
    evidence: [],
    origin: 'test',
  );
  return ProfessionalPrimitive(
    recognition: PrimitiveRecognitionResult(
      id: 'recognition:plane',
      projectId: 'project',
      meshId: 'Mesh001',
      winner: candidate,
      alternatives: const [],
      dna: const RecognitionDNA(
        type: PrimitiveType.plane,
        parameters: {
          'origin': [0, 0, 0],
          'normal': [0, 0, 1],
        },
        regionId: 'region-1',
        geometricSignature: 'plane',
        quality: .97,
        confidence: .96,
        evidence: [],
        origin: 'test',
        version: '1',
      ),
      explanation: const RecognitionExplanation(
        why: 'synthetic plane',
        evidence: [],
        regions: ['region-1'],
        parameters: {},
        losingCandidates: [],
        score: .97,
        confidence: .96,
      ),
      createdAt: DateTime(2026, 1, 1),
    ),
    residualMap: const ResidualMap([], [], []),
    pass: 1,
    auditTrail: const ['test'],
  );
}
