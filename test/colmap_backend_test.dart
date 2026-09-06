import 'dart:io';

import 'package:flcad_mobile/core/acquisition_intelligence/models/evidence_graph.dart';
import 'package:flcad_mobile/core/reconstruction_engine/reconstruction_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeColmapRunner implements ColmapProcessRunner {
  _FakeColmapRunner({this.omitArtifactFor, this.emptyArtifactFor});

  final String? omitArtifactFor;
  final String? emptyArtifactFor;
  final List<({String command, List<String> arguments, String workspace})>
  calls = [];

  @override
  Future<ColmapCommandResult> run(
    String executable,
    List<String> arguments, {
    required Directory workingDirectory,
    ReconstructionCancellation? cancellation,
  }) async {
    final command = arguments.first;
    calls.add((
      command: command,
      arguments: arguments,
      workspace: workingDirectory.path,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 2));
    if (command != omitArtifactFor) {
      await _createArtifact(command, arguments, workingDirectory);
    }
    return const ColmapCommandResult(
      exitCode: 0,
      stdout: '',
      stderr: '',
      durationMs: 1,
    );
  }

  Future<void> _createArtifact(
    String command,
    List<String> arguments,
    Directory workspace,
  ) async {
    Future<void> write(String path) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(command == emptyArtifactFor ? const [] : [1]);
    }

    String valueAfter(String option) => arguments[arguments.indexOf(option) + 1];
    switch (command) {
      case 'feature_extractor':
      case 'exhaustive_matcher':
        await write(valueAfter('--database_path'));
        break;
      case 'mapper':
        final model = Directory(
          '${valueAfter('--output_path')}${Platform.pathSeparator}7',
        );
        for (final name in ['cameras.bin', 'images.bin', 'points3D.bin']) {
          await write('${model.path}${Platform.pathSeparator}$name');
        }
        break;
      case 'image_undistorter':
        await write(
          '${valueAfter('--output_path')}${Platform.pathSeparator}images'
          '${Platform.pathSeparator}undistorted.bin',
        );
        break;
      case 'model_converter':
        for (final name in ['cameras.txt', 'images.txt', 'points3D.txt']) {
          await write(
            '${valueAfter('--output_path')}${Platform.pathSeparator}$name',
          );
        }
        break;
      case 'patch_match_stereo':
        await write(
          '${valueAfter('--workspace_path')}${Platform.pathSeparator}stereo'
          '${Platform.pathSeparator}depth_maps${Platform.pathSeparator}depth.bin',
        );
        break;
      case 'stereo_fusion':
      case 'poisson_mesher':
        await write(valueAfter('--output_path'));
        break;
    }
  }

  @override
  Future<String?> version(String executable) async => 'COLMAP 3.13';
}

Future<({Directory root, Directory images})> _fixture(String prefix) async {
  final root = await Directory.systemTemp.createTemp(prefix);
  final images = Directory(
    '${root.path}${Platform.pathSeparator}images [set] & source',
  );
  await images.create();
  await File('${images.path}${Platform.pathSeparator}capture 01.JPG')
      .writeAsBytes([1]);
  return (root: root, images: images);
}

ReconstructionRequest _request(
  String id,
  Directory workspaceRoot,
  Directory images,
) => ReconstructionRequest(
  id: id,
  projectId: 'project',
  evidenceGraph: const EvidenceGraph(
    nodes: [
      EvidenceNode(
        id: 'capture:1',
        kind: EvidenceNodeKind.capture,
        payload: {},
      ),
      EvidenceNode(
        id: 'analysis:1',
        kind: EvidenceNodeKind.analysis,
        payload: {},
      ),
    ],
  ),
  calibration: {
    'workspacePath': workspaceRoot.path,
    'imagePath': images.path,
  },
);

void main() {
  test('creates one retained atomic run workspace per invocation', () async {
    final fixture = await _fixture('flcad colmap & concurrent-');
    addTearDown(() => fixture.root.delete(recursive: true));
    final runner = _FakeColmapRunner();
    final backend = ColmapBackend(
      executable: 'C:/COLMAP & tools/colmap.exe',
      processRunner: runner,
    );
    final request = _request('same/id & request', fixture.root, fixture.images);

    final results = await Future.wait([
      backend.reconstruct(request),
      backend.reconstruct(request),
    ]);

    final workspaces = runner.calls.map((call) => call.workspace).toSet();
    expect(workspaces, hasLength(2));
    expect(workspaces.every((path) => Directory(path).existsSync()), isTrue);
    expect(results, hasLength(2));
    final undistorters = runner.calls.where(
      (call) => call.command == 'image_undistorter',
    );
    expect(undistorters, hasLength(2));
    expect(
      undistorters.every(
        (call) => call.arguments.contains(
          '${call.workspace}${Platform.pathSeparator}sparse${Platform.pathSeparator}7',
        ),
      ),
      isTrue,
    );
  });

  test('validates the image directory and supported files', () async {
    final root = await Directory.systemTemp.createTemp('flcad-colmap-images-');
    addTearDown(() => root.delete(recursive: true));
    final backend = ColmapBackend(processRunner: _FakeColmapRunner());
    final missing = Directory('${root.path}${Platform.pathSeparator}missing');
    final empty = await Directory(
      '${root.path}${Platform.pathSeparator}empty',
    ).create();
    await File(
      '${empty.path}${Platform.pathSeparator}notes.txt',
    ).writeAsString('x');

    expect(
      () => backend.reconstruct(_request('missing', root, missing)),
      throwsArgumentError,
    );
    expect(
      () => backend.reconstruct(_request('empty', root, empty)),
      throwsArgumentError,
    );
  });

  test('reports failure before throwing when exit zero has no artifact', () async {
    final fixture = await _fixture('flcad-colmap-missing-');
    addTearDown(() => fixture.root.delete(recursive: true));
    final reports = <ReconstructionStageReport>[];
    final backend = ColmapBackend(
      processRunner: _FakeColmapRunner(omitArtifactFor: 'feature_extractor'),
    );

    await expectLater(
      backend.reconstruct(
        _request('missing-artifact', fixture.root, fixture.images),
        onStage: reports.add,
      ),
      throwsStateError,
    );
    expect(reports.single.status, ReconstructionStageStatus.failed);
    expect(reports.single.accepted, isFalse);
    expect(reports.single.explanation, contains('non-empty database.db'));
  });

  test('rejects an empty artifact after a successful command', () async {
    final fixture = await _fixture('flcad-colmap-empty-');
    addTearDown(() => fixture.root.delete(recursive: true));
    final reports = <ReconstructionStageReport>[];
    final backend = ColmapBackend(
      processRunner: _FakeColmapRunner(emptyArtifactFor: 'feature_extractor'),
    );

    await expectLater(
      backend.reconstruct(
        _request('empty-artifact', fixture.root, fixture.images),
        onStage: reports.add,
      ),
      throwsStateError,
    );
    expect(reports.single.status, ReconstructionStageStatus.failed);
  });

  test('passes paths as literal arguments and counts captures only', () async {
    final fixture = await _fixture('flcad colmap [literal] &-');
    addTearDown(() => fixture.root.delete(recursive: true));
    final runner = _FakeColmapRunner();
    final result = await ColmapBackend(processRunner: runner).reconstruct(
      _request('request [1] & done', fixture.root, fixture.images),
    );

    final extractor = runner.calls.first;
    expect(extractor.arguments, contains(fixture.images.path));
    expect(
      result.diagnostics.explanations.values,
      everyElement(contains('Capturas consideradas: 1.')),
    );
    expect(result.output.meshCandidate!['path'], isA<String>());
    expect(
      result.output.meshCandidate!['path'] as String,
      startsWith(fixture.root.path),
    );
  });
}
