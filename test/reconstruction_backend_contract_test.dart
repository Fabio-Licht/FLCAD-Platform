import 'dart:io';

import 'package:flcad_mobile/core/acquisition_intelligence/models/evidence_graph.dart';
import 'package:flcad_mobile/core/reconstruction_engine/reconstruction_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestBackend implements ReconstructionBackend {
  @override
  String get id => 'test-backend';

  @override
  ReconstructionBackendCapabilities get capabilities =>
      const ReconstructionBackendCapabilities(
        supportsGpu: true,
        supportsCpu: true,
        incremental: true,
        denseReconstruction: true,
        texturing: false,
        automaticCalibration: true,
        license: 'test',
        version: '2.0',
      );

  @override
  Future<ReconstructionBackendResult> reconstruct(
    ReconstructionRequest request, {
    void Function(ReconstructionStageReport report)? onStage,
    ReconstructionCancellation? cancellation,
  }) => const FoundationReconstructionBackend().reconstruct(
    request,
    onStage: onStage,
    cancellation: cancellation,
  );
}

const evidence = EvidenceGraph(
  nodes: [
    EvidenceNode(
      id: 'capture:1',
      kind: EvidenceNodeKind.capture,
      payload: {'source': 'universal'},
    ),
  ],
);

void main() {
  test('reports capabilities without binding the engine to a backend', () {
    final manager = ReconstructionBackendManager(backends: [_TestBackend()]);
    final capabilities = manager.get('test-backend').capabilities;

    expect(capabilities.supportsGpu, isTrue);
    expect(capabilities.incremental, isTrue);
    expect(capabilities.license, 'test');
  });

  test('supports automatic, manual, preferred and fallback selection', () {
    final manager = ReconstructionBackendManager(
      backends: [const FoundationReconstructionBackend(), _TestBackend()],
    );

    expect(manager.select().id, 'foundation');
    expect(
      manager
          .select(mode: BackendSelectionMode.manual, manualId: 'test-backend')
          .id,
      'test-backend',
    );
    manager.setPreferred('test-backend');
    expect(
      manager.select(mode: BackendSelectionMode.preferred).id,
      'test-backend',
    );
    expect(
      manager.select(mode: BackendSelectionMode.fallback).id,
      'foundation',
    );
  });

  test(
    'returns diagnostics and explanations through the backend contract',
    () async {
      final manager = ReconstructionBackendManager(backends: [_TestBackend()]);
      final result = await manager.reconstruct(
        const ReconstructionRequest(
          id: 'request-1',
          projectId: 'project-1',
          evidenceGraph: evidence,
        ),
        mode: BackendSelectionMode.manual,
        manualId: 'test-backend',
      );

      expect(result.diagnostics.backendId, 'test-backend');
      expect(result.diagnostics.completedStages, isEmpty);
      expect(result.output.meshCandidate, isNull);
      expect(
        result.output.stageReports.every((report) => !report.accepted),
        isTrue,
      );
      expect(result.diagnostics.explanations, isNotEmpty);
      expect(result.output.evidenceGraph.nodes, hasLength(1));
    },
  );

  test('persists preferred backend for replay', () async {
    final manager = ReconstructionBackendManager(backends: [_TestBackend()]);
    manager.setPreferred('test-backend');
    final directory = await Directory.systemTemp.createTemp('m007-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/backend.json');

    await manager.saveSelection(file);
    final reopened = ReconstructionBackendManager(backends: [_TestBackend()]);
    await reopened.loadSelection(file);

    expect(reopened.preferredId, 'test-backend');
    expect(reopened.select().id, 'test-backend');
  });
}
