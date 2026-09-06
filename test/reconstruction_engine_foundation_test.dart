import 'dart:io';

import 'package:flcad_mobile/core/acquisition_intelligence/models/evidence_graph.dart';
import 'package:flcad_mobile/core/reconstruction_engine/reconstruction_engine.dart';
import 'package:flutter_test/flutter_test.dart';

EvidenceGraph graph() => const EvidenceGraph(
  nodes: [
    EvidenceNode(
      id: 'capture:1',
      kind: EvidenceNodeKind.capture,
      payload: {'source': 'camera'},
    ),
    EvidenceNode(
      id: 'metric-reference:1',
      kind: EvidenceNodeKind.metricReference,
      payload: {'confidence': .9},
    ),
  ],
);

void main() {
  test(
    'runs the explicit reconstruction contract from Evidence Graph only',
    () async {
      final output = await const ReconstructionEngine().run(
        ReconstructionRequest(
          id: 'reconstruction-1',
          projectId: 'project-1',
          evidenceGraph: graph(),
          calibration: {'unit': 'millimeter'},
        ),
      );

      expect(output.stageReports, hasLength(ReconstructionStage.values.length));
      expect(
        output.stageReports.first.stage,
        ReconstructionStage.featureDetection,
      );
      expect(output.stageReports.last.stage, ReconstructionStage.optimization);
      expect(output.stageReports.every((report) => report.accepted), isTrue);
      expect(output.evidenceGraph, same(graph()));
      expect(output.meshCandidate, isNull);
    },
  );

  test(
    'supports incremental continuation without restarting completed stages',
    () async {
      final output = await const ReconstructionEngine().run(
        ReconstructionRequest(
          id: 'reconstruction-2',
          projectId: 'project-1',
          evidenceGraph: graph(),
          completedStages: {
            ReconstructionStage.featureDetection,
            ReconstructionStage.featureMatching,
          },
        ),
      );

      expect(output.stageReports[0].status, ReconstructionStageStatus.skipped);
      expect(output.stageReports[1].status, ReconstructionStageStatus.skipped);
      expect(
        output.stageReports[2].status,
        ReconstructionStageStatus.completed,
      );
    },
  );

  test(
    'persists output for replay and preserves confidence and provenance',
    () async {
      final output = await const ReconstructionEngine().run(
        ReconstructionRequest(
          id: 'reconstruction-3',
          projectId: 'project-1',
          evidenceGraph: graph(),
        ),
      );
      final directory = await Directory.systemTemp.createTemp('m006-');
      addTearDown(() => directory.delete(recursive: true));
      final repository = ReconstructionRepository(directory: directory);

      await repository.save(output);
      final reopened = await repository.load(output.requestId);

      expect(reopened, isNotNull);
      expect(reopened!.requestId, output.requestId);
      expect(reopened.confidenceMap.single.evidenceIds, contains('capture:1'));
      expect(reopened.stageReports, hasLength(8));
      expect(reopened.evidenceGraph.nodes, hasLength(2));
    },
  );

  test(
    'runtime executes outside the caller and reports observable stages',
    () async {
      final runtime = ReconstructionRuntime();
      addTearDown(runtime.dispose);
      final reports = <ReconstructionStageReport>[];
      final subscription = runtime.progress.listen(reports.add);
      addTearDown(subscription.cancel);

      final output = await runtime.start(
        ReconstructionRequest(
          id: 'reconstruction-runtime',
          projectId: 'project-1',
          evidenceGraph: graph(),
        ),
      );

      expect(output.stageReports, hasLength(8));
      expect(reports, hasLength(8));
    },
  );

  group('M-007 Reconstruction Backend Contract', () {
    test('reports capabilities without binding the engine to a backend', () {
      final manager = ReconstructionBackendManager();
      final capabilities = manager.select().capabilities;

      expect(capabilities.supportsCpu, isTrue);
      expect(capabilities.incremental, isTrue);
      expect(capabilities.denseReconstruction, isFalse);
      expect(capabilities.license, isNotEmpty);
    });

    test('supports automatic, preferred and fallback selection', () {
      final manager = ReconstructionBackendManager();

      expect(manager.select().id, 'foundation');
      manager.setPreferred('foundation');
      expect(
        manager.select(mode: BackendSelectionMode.preferred).id,
        'foundation',
      );
      expect(
        manager.select(mode: BackendSelectionMode.fallback).id,
        'foundation',
      );
    });

    test(
      'returns diagnostics and explanations through the backend contract',
      () async {
        final result = await ReconstructionBackendManager().reconstruct(
          ReconstructionRequest(
            id: 'backend-request',
            projectId: 'project-1',
            evidenceGraph: graph(),
          ),
        );

        expect(result.diagnostics.backendId, 'foundation');
        expect(result.diagnostics.completedStages, hasLength(8));
        expect(result.diagnostics.explanations, isNotEmpty);
        expect(result.output.evidenceGraph.nodes, hasLength(2));
      },
    );

    test('persists preferred backend for replay', () async {
      final manager = ReconstructionBackendManager();
      manager.setPreferred('foundation');
      final directory = await Directory.systemTemp.createTemp('m007-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/backend.json');

      await manager.saveSelection(file);
      final reopened = ReconstructionBackendManager();
      await reopened.loadSelection(file);

      expect(reopened.preferredId, 'foundation');
      expect(reopened.select().id, 'foundation');
    });
  });
}
