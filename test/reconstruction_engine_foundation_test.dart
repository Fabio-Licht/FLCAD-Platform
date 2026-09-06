import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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
      expect(
        output.stageReports.every(
          (report) =>
              report.status == ReconstructionStageStatus.pending &&
              !report.accepted,
        ),
        isTrue,
      );
      expect(output.evidenceGraph, same(graph()));
      expect(output.meshCandidate, isNull);
    },
  );

  test('confidence counts captures rather than auxiliary graph nodes', () async {
    final output = await const ReconstructionEngine().run(
      ReconstructionRequest(
        id: 'capture-confidence',
        projectId: 'project-1',
        evidenceGraph: graph(),
      ),
    );

    expect(output.confidenceMap.single.confidence, .1);
    expect(output.confidenceMap.single.evidenceIds, ['capture:1']);
  });

  test(
    'auxiliary nodes alone do not create reconstruction confidence',
    () async {
      final output = await const ReconstructionEngine().run(
        ReconstructionRequest(
          id: 'auxiliary-only',
          projectId: 'project-1',
          evidenceGraph: EvidenceGraph(
            nodes: [
              EvidenceNode(
                id: 'analysis:1',
                kind: EvidenceNodeKind.analysis,
                payload: {'confidence': 1.0},
              ),
              EvidenceNode(
                id: 'metric-reference:1',
                kind: EvidenceNodeKind.metricReference,
                payload: {'confidence': 1.0},
              ),
            ],
          ),
        ),
      );

      expect(output.confidenceMap, isEmpty);
      expect(
        output.stageReports.every((report) => report.confidence == 0),
        isTrue,
      );
      expect(output.stageReports.every((report) => !report.accepted), isTrue);
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
        ReconstructionStageStatus.pending,
      );
      expect(output.stageReports.every((report) => !report.accepted), isTrue);
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

  test('runtime observes an external cancellation token while running', () async {
    final runtime = ReconstructionRuntime();
    final cancellation = ReconstructionCancellationToken();
    addTearDown(runtime.dispose);
    final subscription = runtime.progress.listen((_) => cancellation.cancel());
    addTearDown(subscription.cancel);

    final future = runtime.start(
      ReconstructionRequest(
        id: 'reconstruction-external-cancel',
        projectId: 'project-1',
        evidenceGraph: graph(),
      ),
      cancellation: cancellation,
    );

    await expectLater(future, throwsA(isA<ReconstructionCancelled>()));
  });

  test('stop completes the active future and runtime can restart', () async {
    final runtime = ReconstructionRuntime();
    addTearDown(runtime.dispose);
    late final StreamSubscription<ReconstructionStageReport> subscription;
    subscription = runtime.progress.listen((_) {
      subscription.cancel();
      runtime.stop();
    });

    final interrupted = runtime.start(
      ReconstructionRequest(
        id: 'reconstruction-stop',
        projectId: 'project-1',
        evidenceGraph: graph(),
      ),
    );
    await expectLater(interrupted, throwsA(isA<ReconstructionCancelled>()));

    final restarted = await runtime.start(
      ReconstructionRequest(
        id: 'reconstruction-restart',
        projectId: 'project-1',
        evidenceGraph: graph(),
      ),
    );
    expect(restarted.requestId, 'reconstruction-restart');
  });

  test('stop during isolate spawn does not leave an orphan isolate', () async {
    final allowSpawnToReturn = Completer<void>();
    final isolateStarted = Completer<void>();
    final isolateExited = Completer<void>();
    final exitPort = ReceivePort();
    final exitSubscription = exitPort.listen((_) {
      if (!isolateExited.isCompleted) isolateExited.complete();
    });
    addTearDown(exitSubscription.cancel);
    addTearDown(exitPort.close);

    final runtime = ReconstructionRuntime(
      spawnIsolate: (entry, message, errorPort) async {
        final isolate = await Isolate.spawn(
          (_) => ReceivePort(),
          null,
          onError: errorPort,
        );
        isolate.addOnExitListener(exitPort.sendPort);
        isolateStarted.complete();
        await allowSpawnToReturn.future;
        return isolate;
      },
    );
    addTearDown(runtime.dispose);

    final startFuture = runtime.start(
      ReconstructionRequest(
        id: 'reconstruction-stop-during-spawn',
        projectId: 'project-1',
        evidenceGraph: graph(),
      ),
    );
    final cancellationResult = startFuture.then<Object?>(
      (_) => fail('The stopped reconstruction completed successfully.'),
      onError: (Object error, StackTrace _) => error,
    );

    await isolateStarted.future;
    await runtime.stop();
    allowSpawnToReturn.complete();

    expect(await cancellationResult, isA<ReconstructionCancelled>());
    await isolateExited.future.timeout(const Duration(seconds: 5));
  });

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
        expect(result.diagnostics.completedStages, isEmpty);
        expect(result.output.meshCandidate, isNull);
        expect(
          result.output.stageReports.every((report) => !report.accepted),
          isTrue,
        );
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
