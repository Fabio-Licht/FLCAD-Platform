import 'dart:async';
import 'dart:io';

import 'package:flcad_mobile/app/reconstruction/desktop_colmap_lab_runtime.dart';
import 'package:flcad_mobile/app/reconstruction/colmap_operational_controller.dart';
import 'package:flcad_mobile/core/acquisition_intelligence/models/evidence_graph.dart';
import 'package:flcad_mobile/core/reconstruction_engine/reconstruction_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

class _Runner implements ColmapProcessRunner {
  int versionCalls = 0;
  @override
  Future<String?> version(String executable) async {
    versionCalls++;
    return '3.13-test';
  }

  @override
  Future<ColmapCommandResult> run(
    String executable,
    List<String> arguments, {
    required Directory workingDirectory,
    ReconstructionCancellation? cancellation,
  }) => throw UnsupportedError('No real process in runtime tests');
}

class _BlockingBackend implements ReconstructionBackend {
  final started = Completer<void>();
  final release = Completer<void>();
  bool observedCancellation = false;

  @override
  String get id => 'colmap';

  @override
  ReconstructionBackendCapabilities get capabilities =>
      const ReconstructionBackendCapabilities(
        supportsGpu: false,
        supportsCpu: true,
        incremental: false,
        denseReconstruction: true,
        texturing: false,
        automaticCalibration: true,
        license: 'test',
        version: 'test',
      );

  @override
  Future<ReconstructionBackendResult> reconstruct(
    ReconstructionRequest request, {
    void Function(ReconstructionStageReport report)? onStage,
    ReconstructionCancellation? cancellation,
  }) async {
    started.complete();
    await release.future;
    observedCancellation = cancellation?.isCancelled ?? false;
    throw const ReconstructionCancelled();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'runtime uses private Application Support workspace without probes',
    () async {
      final support = await Directory.systemTemp.createTemp('flcad_support_');
      addTearDown(() => support.delete(recursive: true));
      final runner = _Runner();
      var executablePickerCalls = 0;
      var photoPickerCalls = 0;

      final runtime = await DesktopColmapLabRuntime.create(
        applicationSupportDirectoryProvider: () async => support,
        processRunner: runner,
        selectExecutable: () async {
          executablePickerCalls++;
          return null;
        },
        selectPhotoDirectory: () async {
          photoPickerCalls++;
          return null;
        },
      );
      addTearDown(runtime.dispose);

      expect(path.isWithin(support.path, runtime.workspaceRoot.path), isTrue);
      expect(
        runtime.workspaceRoot.path,
        path.join(support.path, 'FLCAD Platform', 'COLMAP', 'workspaces'),
      );
      expect(runtime.workspaceRoot.existsSync(), isTrue);
      expect(runner.versionCalls, 0);
      expect(executablePickerCalls, 0);
      expect(photoPickerCalls, 0);
      expect(runtime.labController.activeInstallation, isNull);
    },
  );

  test('photo selection can never become the managed workspace root', () async {
    final support = await Directory.systemTemp.createTemp('flcad_support_');
    final photos = await Directory.systemTemp.createTemp('flcad_photos_');
    addTearDown(() => support.delete(recursive: true));
    addTearDown(() => photos.delete(recursive: true));
    final runtime = await DesktopColmapLabRuntime.create(
      applicationSupportDirectoryProvider: () async => support,
      processRunner: _Runner(),
      selectExecutable: () async => null,
      selectPhotoDirectory: () async => photos.path,
    );
    addTearDown(runtime.dispose);

    expect(runtime.workspaceRoot.absolute.path, isNot(photos.absolute.path));
    expect(path.isWithin(support.path, runtime.workspaceRoot.path), isTrue);
  });

  test('disposing runtime requests cooperative cancellation', () async {
    final support = await Directory.systemTemp.createTemp('flcad_support_');
    addTearDown(() => support.delete(recursive: true));
    final runtime = await DesktopColmapLabRuntime.create(
      applicationSupportDirectoryProvider: () async => support,
      processRunner: _Runner(),
      selectExecutable: () async => null,
      selectPhotoDirectory: () async => null,
    );
    final backend = _BlockingBackend();
    runtime.backendManager.register(backend);
    final operation = runtime.operationalController.start(
      const ReconstructionRequest(
        id: 'dispose-test',
        projectId: 'test',
        evidenceGraph: EvidenceGraph(),
      ),
    );
    await backend.started.future;

    runtime.dispose();
    backend.release.complete();
    await operation;

    expect(backend.observedCancellation, isTrue);
    expect(
      runtime.operationalController.state,
      ColmapOperationalState.disposed,
    );
  });
}
