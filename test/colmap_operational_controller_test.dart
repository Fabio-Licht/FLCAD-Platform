import 'dart:async';

import 'package:flcad_mobile/app/reconstruction/colmap_operational_controller.dart';
import 'package:flcad_mobile/core/acquisition_intelligence/models/evidence_graph.dart';
import 'package:flcad_mobile/core/reconstruction_engine/reconstruction_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _Backend implements ReconstructionBackend {
  _Backend({this.block, this.failure});

  final Completer<void>? block;
  final Object? failure;
  ReconstructionCancellation? cancellation;
  int calls = 0;
  void Function(ReconstructionStageReport report)? capturedOnStage;

  @override
  String get id => 'colmap';

  @override
  ReconstructionBackendCapabilities get capabilities =>
      const ReconstructionBackendCapabilities(
        supportsGpu: true,
        supportsCpu: true,
        incremental: false,
        denseReconstruction: true,
        texturing: false,
        automaticCalibration: true,
        license: 'BSD-3-Clause',
        version: 'COLMAP test',
      );

  @override
  Future<ReconstructionBackendResult> reconstruct(
    ReconstructionRequest request, {
    void Function(ReconstructionStageReport report)? onStage,
    ReconstructionCancellation? cancellation,
  }) async {
    calls++;
    capturedOnStage = onStage;
    this.cancellation = cancellation;
    if (block != null) await block!.future;
    if (cancellation?.isCancelled ?? false) {
      throw const ReconstructionCancelled();
    }
    final reports = <ReconstructionStageReport>[];
    for (final stage in ReconstructionStage.values) {
      final report = _report(stage);
      reports.add(report);
      onStage?.call(report);
    }
    if (failure != null) {
      final failed = ReconstructionStageReport(
        stage: ReconstructionStage.optimization,
        status: ReconstructionStageStatus.failed,
        confidence: 0,
        quality: 0,
        durationMs: 1,
        residuals: const {},
        dependencies: const [],
        accepted: false,
        explanation: 'artifact missing',
      );
      onStage?.call(failed);
      throw failure!;
    }
    final output = ReconstructionOutput(
      requestId: request.id,
      stageReports: List.unmodifiable(reports),
      confidenceMap: const [],
      provenance: const {},
      meshCandidate: const {'path': 'candidate.ply', 'final': false},
      sparseCloud: const [],
      denseCloud: const [],
      evidenceGraph: request.evidenceGraph,
    );
    return ReconstructionBackendResult(
      output: output,
      diagnostics: ReconstructionBackendDiagnostics(
        backendId: id,
        backendVersion: capabilities.version,
        durationMs: 1,
        memoryBytes: null,
        confidence: 1,
        completedStages: ReconstructionStage.values,
        limitations: const ['Technical completion only.'],
        explanations: const {},
      ),
    );
  }
}

class _RecoveringBackend extends _Backend {
  int remainingFailures = 1;

  @override
  Future<ReconstructionBackendResult> reconstruct(
    ReconstructionRequest request, {
    void Function(ReconstructionStageReport report)? onStage,
    ReconstructionCancellation? cancellation,
  }) async {
    if (remainingFailures > 0) {
      remainingFailures--;
      calls++;
      final failed = ReconstructionStageReport(
        stage: ReconstructionStage.featureDetection,
        status: ReconstructionStageStatus.failed,
        confidence: 0,
        quality: 0,
        durationMs: 1,
        residuals: const {},
        dependencies: const [],
        accepted: false,
        explanation: 'temporary failure',
      );
      onStage?.call(failed);
      throw StateError('temporary failure');
    }
    return super.reconstruct(
      request,
      onStage: onStage,
      cancellation: cancellation,
    );
  }
}

class _Token implements OperationalReconstructionCancellation {
  @override
  bool isCancelled = false;

  @override
  void cancel() => isCancelled = true;
}

ReconstructionStageReport _report(ReconstructionStage stage) =>
    ReconstructionStageReport(
      stage: stage,
      status: ReconstructionStageStatus.completed,
      confidence: 1,
      quality: 1,
      durationMs: 1,
      residuals: const {},
      dependencies: const [],
      accepted: true,
      explanation: 'Technical artifact completed.',
    );

const _request = ReconstructionRequest(
  id: 'request',
  projectId: 'project',
  evidenceGraph: EvidenceGraph(),
);

BackendInstallationRecord _record() => BackendInstallationRecord(
  backendId: 'colmap',
  version: 'test',
  installedAt: DateTime.utc(2026),
  source: Uri.file('colmap'),
  sha256: '',
  architecture: 'test',
  status: BackendInstallationStatus.installed,
  certification: BackendCertificationStatus.notCertified,
  executablePath: '/test/colmap',
  origin: BackendInstallationOrigin.external,
);

void main() {
  test('explicit activation registers COLMAP and becomes ready', () async {
    final manager = ReconstructionBackendManager();
    final backend = _Backend();
    late bool allowed;
    final controller = ColmapOperationalController(
      backendManager: manager,
      activate: (record, {required allowUncertifiedExternal}) async {
        allowed = allowUncertifiedExternal;
        return backend;
      },
    );

    await controller.configureExternal(
      _record(),
      consent: true,
      allowExperimental: true,
    );

    expect(allowed, isTrue);
    expect(manager.get('colmap'), same(backend));
    expect(controller.state, ColmapOperationalState.ready);
  });

  test('successful reconfiguration atomically replaces COLMAP', () async {
    final previous = _Backend();
    final replacement = _Backend();
    final manager = ReconstructionBackendManager(backends: [previous]);
    final controller = ColmapOperationalController(
      backendManager: manager,
      activate: (record, {required allowUncertifiedExternal}) async =>
          replacement,
    );

    await controller.configureExternal(
      _record(),
      consent: true,
      allowExperimental: true,
    );

    expect(manager.get('colmap'), same(replacement));
    expect(controller.state, ColmapOperationalState.ready);
  });

  test('failed reconfiguration preserves working backend and ready state', () async {
    final previous = _Backend();
    final manager = ReconstructionBackendManager(backends: [previous]);
    final controller = ColmapOperationalController(
      backendManager: manager,
      activate: (record, {required allowUncertifiedExternal}) async =>
          throw StateError('replacement probe failed'),
    );

    await controller.configureExternal(
      _record(),
      consent: true,
      allowExperimental: true,
    );

    expect(manager.get('colmap'), same(previous));
    expect(controller.state, ColmapOperationalState.ready);
    expect(controller.error, isA<StateError>());
  });

  test('consent is mandatory and activation failure changes no manager', () async {
    final manager = ReconstructionBackendManager();
    final controller = ColmapOperationalController(
      backendManager: manager,
      activate: (record, {required allowUncertifiedExternal}) async =>
          throw StateError('probe failed'),
    );

    await expectLater(
      controller.configureExternal(
        _record(),
        consent: false,
        allowExperimental: true,
      ),
      throwsStateError,
    );
    await controller.configureExternal(
      _record(),
      consent: true,
      allowExperimental: true,
    );
    expect(controller.state, ColmapOperationalState.failed);
    expect(controller.error, isA<StateError>());
    expect(() => manager.get('colmap'), throwsStateError);
  });

  test('runs manual COLMAP and retains exact result and eight stages', () async {
    final backend = _Backend();
    final controller = ColmapOperationalController(
      backendManager: ReconstructionBackendManager(backends: [backend]),
    );

    await controller.start(_request);

    expect(controller.state, ColmapOperationalState.succeeded);
    expect(controller.result!.diagnostics.backendId, 'colmap');
    expect(controller.result!.output.meshCandidate!['path'], 'candidate.ply');
    expect(controller.reports, hasLength(8));
    expect(() => controller.reports.add(_report(ReconstructionStage.optimization)),
        throwsUnsupportedError);
  });

  test('rejects double start, exposes cancelling, then becomes cancelled', () async {
    final block = Completer<void>();
    final backend = _Backend(block: block);
    final token = _Token();
    final controller = ColmapOperationalController(
      backendManager: ReconstructionBackendManager(backends: [backend]),
      cancellationFactory: () => token,
    );
    final running = controller.start(_request);

    await expectLater(controller.start(_request), throwsStateError);
    controller.cancel();
    expect(controller.state, ColmapOperationalState.cancelling);
    expect(token.isCancelled, isTrue);
    block.complete();
    await running;
    expect(controller.state, ColmapOperationalState.cancelled);
  });

  test('retains failed stage and can retry after backend failure', () async {
    final failure = _Backend(failure: StateError('mesh failed'));
    final manager = ReconstructionBackendManager(backends: [failure]);
    final controller = ColmapOperationalController(backendManager: manager);

    await controller.start(_request);
    expect(controller.state, ColmapOperationalState.failed);
    expect(controller.error, isA<StateError>());
    expect(controller.reports.last.status, ReconstructionStageStatus.failed);

    await controller.start(_request);
    expect(failure.calls, 2);
    expect(controller.reports.last.status, ReconstructionStageStatus.failed);
  });

  test('retry can recover after a transient backend failure', () async {
    final backend = _RecoveringBackend();
    final controller = ColmapOperationalController(
      backendManager: ReconstructionBackendManager(backends: [backend]),
    );

    await controller.start(_request);
    expect(controller.state, ColmapOperationalState.failed);

    await controller.start(_request);
    expect(controller.state, ColmapOperationalState.succeeded);
    expect(backend.calls, 2);
    expect(controller.error, isNull);
  });

  test('start without a registered COLMAP backend fails before running', () async {
    final controller = ColmapOperationalController(
      backendManager: ReconstructionBackendManager(),
    );

    await expectLater(controller.start(_request), throwsStateError);
    expect(controller.state, ColmapOperationalState.idle);
  });

  test('configure is rejected while running', () async {
    final block = Completer<void>();
    final backend = _Backend(block: block);
    final controller = ColmapOperationalController(
      backendManager: ReconstructionBackendManager(backends: [backend]),
    );
    final running = controller.start(_request);

    await expectLater(
      controller.configureExternal(
        _record(),
        consent: true,
        allowExperimental: true,
      ),
      throwsStateError,
    );
    controller.cancel();
    block.complete();
    await running;
  });

  test('start and reconfigure are rejected while activation is pending', () async {
    final activation = Completer<ReconstructionBackend>();
    final manager = ReconstructionBackendManager();
    final controller = ColmapOperationalController(
      backendManager: manager,
      activate: (record, {required allowUncertifiedExternal}) =>
          activation.future,
    );
    final configuring = controller.configureExternal(
      _record(),
      consent: true,
      allowExperimental: true,
    );

    expect(controller.state, ColmapOperationalState.activating);
    await expectLater(controller.start(_request), throwsStateError);
    await expectLater(
      controller.configureExternal(
        _record(),
        consent: true,
        allowExperimental: true,
      ),
      throwsStateError,
    );
    activation.complete(_Backend());
    await configuring;
    expect(controller.state, ColmapOperationalState.ready);
  });

  test('retry can recover after cancellation', () async {
    final block = Completer<void>();
    final backend = _Backend(block: block);
    final controller = ColmapOperationalController(
      backendManager: ReconstructionBackendManager(backends: [backend]),
    );
    final running = controller.start(_request);
    controller.cancel();
    block.complete();
    await running;
    expect(controller.state, ColmapOperationalState.cancelled);

    await controller.start(_request);
    expect(controller.state, ColmapOperationalState.succeeded);
    expect(backend.calls, 2);
  });

  test('late stage callback after success is ignored', () async {
    final backend = _Backend();
    final controller = ColmapOperationalController(
      backendManager: ReconstructionBackendManager(backends: [backend]),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);
    await controller.start(_request);
    final reports = controller.reports;
    final beforeLateCallback = notifications;

    backend.capturedOnStage!(_report(ReconstructionStage.optimization));

    expect(controller.reports, same(reports));
    expect(notifications, beforeLateCallback);
  });

  test('late stage callback after failure is ignored', () async {
    final backend = _Backend(failure: StateError('mesh failed'));
    final controller = ColmapOperationalController(
      backendManager: ReconstructionBackendManager(backends: [backend]),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);
    await controller.start(_request);
    final reports = controller.reports;
    final beforeLateCallback = notifications;

    backend.capturedOnStage!(_report(ReconstructionStage.optimization));

    expect(controller.reports, same(reports));
    expect(notifications, beforeLateCallback);
    expect(controller.state, ColmapOperationalState.failed);
  });

  test('dispose during activation ignores late completion', () async {
    final activation = Completer<ReconstructionBackend>();
    final manager = ReconstructionBackendManager();
    final controller = ColmapOperationalController(
      backendManager: manager,
      activate: (record, {required allowUncertifiedExternal}) =>
          activation.future,
    );
    final configuring = controller.configureExternal(
      _record(),
      consent: true,
      allowExperimental: true,
    );

    controller.dispose();
    activation.complete(
      ColmapBackend(executable: _record().executablePath!),
    );
    await configuring;

    expect(controller.state, ColmapOperationalState.disposed);
    expect(manager.contains('colmap'), isFalse);
  });

  test('late completion after dispose is ignored without notification', () async {
    final block = Completer<void>();
    final backend = _Backend(block: block);
    final controller = ColmapOperationalController(
      backendManager: ReconstructionBackendManager(backends: [backend]),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);
    final running = controller.start(_request);
    final beforeDispose = notifications;

    controller.dispose();
    block.complete();
    await running;

    expect(controller.state, ColmapOperationalState.disposed);
    expect(notifications, beforeDispose);
  });
}
