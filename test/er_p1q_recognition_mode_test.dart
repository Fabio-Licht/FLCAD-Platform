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
      find.textContaining('reconhecimento automático multiprimitiva'),
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
}

final class _FakeRecognitionApi extends ProfessionalRecognitionApi {
  _FakeRecognitionApi(this.report);

  final ProfessionalRecognitionReport report;

  @override
  Future<ProfessionalRecognitionReport> recognize(
    List<RecognitionContext> regions,
  ) async => report;
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

  static Future<_ModeHarness> create(_FakeRecognitionApi api) async {
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
