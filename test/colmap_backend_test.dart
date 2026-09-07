import 'dart:io';

import 'package:flcad_mobile/core/acquisition_intelligence/models/evidence_graph.dart';
import 'package:flcad_mobile/core/reconstruction_engine/reconstruction_engine.dart';
import 'package:flutter_test/flutter_test.dart';

String get _fakeColmapExecutable =>
    Platform.isWindows ? r'C:\fake-colmap\colmap.exe' : '/fake-colmap/colmap';

class _FakeColmapRunner implements ColmapProcessRunner {
  _FakeColmapRunner({
    this.omitArtifactFor,
    this.emptyArtifactFor,
    this.throwFor,
    this.cancelFor,
  });

  final String? omitArtifactFor;
  final String? emptyArtifactFor;
  final String? throwFor;
  final String? cancelFor;
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
    if (command == throwFor) {
      throw StateError('runner failed for $command');
    }
    if (command == cancelFor) {
      throw const ReconstructionCancelled();
    }
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

    String valueAfter(String option) =>
        arguments[arguments.indexOf(option) + 1];
    switch (command) {
      case 'feature_extractor':
        await write(valueAfter('--database_path'));
        break;
      case 'exhaustive_matcher':
        final database = File(valueAfter('--database_path'));
        if (command == emptyArtifactFor) {
          await database.writeAsBytes(const []);
        } else {
          await database.writeAsBytes([2], mode: FileMode.append);
        }
        break;
      case 'mapper':
        final mapperOutput = valueAfter('--output_path');
        await write(
          '$mapperOutput${Platform.pathSeparator}0'
          '${Platform.pathSeparator}cameras.bin',
        );
        for (final name in ['cameras.bin', 'images.bin', 'points3D.bin']) {
          await write(
            '$mapperOutput${Platform.pathSeparator}8'
            '${Platform.pathSeparator}$name',
          );
        }
        for (final name in ['cameras.bin', 'images.bin', 'points3D.bin']) {
          await write(
            '$mapperOutput${Platform.pathSeparator}7'
            '${Platform.pathSeparator}$name',
          );
        }
        break;
      case 'image_undistorter':
        final undistortedOutput = valueAfter('--output_path');
        await write(
          '$undistortedOutput${Platform.pathSeparator}images'
          '${Platform.pathSeparator}undistorted.jpg',
        );
        for (final name in ['cameras.bin', 'images.bin', 'points3D.bin']) {
          await write(
            '$undistortedOutput${Platform.pathSeparator}sparse'
            '${Platform.pathSeparator}$name',
          );
        }
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

class _CancelledToken implements ReconstructionCancellation {
  const _CancelledToken();

  @override
  bool get isCancelled => true;
}

class _RejectingInputValidator implements ColmapInputValidator {
  _RejectingInputValidator({this.rejectWorkspace = false});

  final bool rejectWorkspace;
  int photoCalls = 0;
  int workspaceCalls = 0;

  @override
  Future<String> prepareWorkspaceRoot(String value) async {
    workspaceCalls++;
    if (rejectWorkspace) {
      throw ArgumentError.value(value, 'workspacePath', 'must be absolute');
    }
    return value;
  }

  @override
  Future<ValidatedColmapPhotoDirectory> validatePhotoDirectory(
    String value,
  ) async {
    photoCalls++;
    throw ArgumentError.value(value, 'imagePath', 'must be absolute');
  }
}

Future<({Directory root, Directory images})> _fixture(String prefix) async {
  final root = await Directory.systemTemp.createTemp(prefix);
  final images = Directory(
    '${root.path}${Platform.pathSeparator}images [set] & source',
  );
  await images.create();
  await File(
    '${images.path}${Platform.pathSeparator}capture 01.JPG',
  ).writeAsBytes([1]);
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
  calibration: {'workspacePath': workspaceRoot.path, 'imagePath': images.path},
);

void main() {
  test(
    'calls input validator and does not run COLMAP for invalid imagePath',
    () async {
      final runner = _FakeColmapRunner();
      final validator = _RejectingInputValidator();
      final backend = ColmapBackend(
        executable: _fakeColmapExecutable,
        processRunner: runner,
        inputValidator: validator,
      );
      final request = ReconstructionRequest(
        id: 'invalid-images',
        projectId: 'project',
        evidenceGraph: const EvidenceGraph(),
        calibration: {
          'workspacePath': Directory.systemTemp.absolute.path,
          'imagePath': 'relative/images',
        },
      );

      await expectLater(backend.reconstruct(request), throwsArgumentError);

      expect(validator.workspaceCalls, 1);
      expect(validator.photoCalls, 1);
      expect(runner.calls, isEmpty);
    },
  );

  test('rejects relative workspace before running COLMAP', () async {
    final runner = _FakeColmapRunner();
    final validator = _RejectingInputValidator(rejectWorkspace: true);
    final backend = ColmapBackend(
      executable: _fakeColmapExecutable,
      processRunner: runner,
      inputValidator: validator,
    );
    final request = ReconstructionRequest(
      id: 'invalid-workspace',
      projectId: 'project',
      evidenceGraph: const EvidenceGraph(),
      calibration: {
        'workspacePath': 'relative/workspace',
        'imagePath': Directory.systemTemp.absolute.path,
      },
    );

    await expectLater(backend.reconstruct(request), throwsArgumentError);

    expect(validator.workspaceCalls, 1);
    expect(validator.photoCalls, 0);
    expect(runner.calls, isEmpty);
  });

  test('creates one retained atomic run workspace per invocation', () async {
    final fixture = await _fixture('flcad colmap & concurrent-');
    addTearDown(() => fixture.root.delete(recursive: true));
    final runner = _FakeColmapRunner();
    final backend = ColmapBackend(
      executable: Platform.isWindows
          ? r'C:\COLMAP & tools\colmap.exe'
          : '/COLMAP & tools/colmap',
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
    final backend = ColmapBackend(
      executable: _fakeColmapExecutable,
      processRunner: _FakeColmapRunner(),
    );
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

  for (final command in [
    'feature_extractor',
    'exhaustive_matcher',
    'mapper',
    'image_undistorter',
    'model_converter',
    'patch_match_stereo',
    'stereo_fusion',
    'poisson_mesher',
  ]) {
    for (final empty in [false, true]) {
      test(
        'reports $command ${empty ? 'empty' : 'missing'} artifact before throwing',
        () async {
          final fixture = await _fixture('flcad-colmap-artifact-');
          addTearDown(() => fixture.root.delete(recursive: true));
          final reports = <ReconstructionStageReport>[];
          final backend = ColmapBackend(
            executable: _fakeColmapExecutable,
            processRunner: _FakeColmapRunner(
              omitArtifactFor: empty ? null : command,
              emptyArtifactFor: empty ? command : null,
            ),
          );

          await expectLater(
            backend.reconstruct(
              _request('invalid-$command', fixture.root, fixture.images),
              onStage: reports.add,
            ),
            throwsA(anything),
          );
          expect(reports.last.status, ReconstructionStageStatus.failed);
          expect(reports.last.accepted, isFalse);
        },
      );
    }
  }

  test(
    'reports runner exceptions and preserves cancellation semantics',
    () async {
      final fixture = await _fixture('flcad-colmap-runner-error-');
      addTearDown(() => fixture.root.delete(recursive: true));
      final reports = <ReconstructionStageReport>[];
      final backend = ColmapBackend(
        executable: _fakeColmapExecutable,
        processRunner: _FakeColmapRunner(throwFor: 'feature_extractor'),
      );

      await expectLater(
        backend.reconstruct(
          _request('runner-error', fixture.root, fixture.images),
          onStage: reports.add,
        ),
        throwsStateError,
      );
      expect(reports.single.status, ReconstructionStageStatus.failed);

      reports.clear();
      final cancelledBackend = ColmapBackend(
        executable: _fakeColmapExecutable,
        processRunner: _FakeColmapRunner(cancelFor: 'feature_extractor'),
      );
      await expectLater(
        cancelledBackend.reconstruct(
          _request('cancelled', fixture.root, fixture.images),
          onStage: reports.add,
        ),
        throwsA(isA<ReconstructionCancelled>()),
      );
      expect(reports, isEmpty);
    },
  );

  test(
    'pre-cancelled reconstruction never invokes the process runner',
    () async {
      final fixture = await _fixture('flcad-colmap-pre-cancelled-');
      addTearDown(() => fixture.root.delete(recursive: true));
      final runner = _FakeColmapRunner();
      final backend = ColmapBackend(
        executable: _fakeColmapExecutable,
        processRunner: runner,
      );

      await expectLater(
        backend.reconstruct(
          _request('pre-cancelled', fixture.root, fixture.images),
          cancellation: const _CancelledToken(),
        ),
        throwsA(isA<ReconstructionCancelled>()),
      );
      expect(runner.calls, isEmpty);
    },
  );

  test('passes paths as literal arguments and counts captures only', () async {
    final fixture = await _fixture('flcad colmap [literal] &-');
    addTearDown(() => fixture.root.delete(recursive: true));
    final canonicalImages = await fixture.images.resolveSymbolicLinks();
    final canonicalRoot = await fixture.root.resolveSymbolicLinks();
    final runner = _FakeColmapRunner();
    final result = await ColmapBackend(
      executable: _fakeColmapExecutable,
      processRunner: runner,
    ).reconstruct(_request('request [1] & done', fixture.root, fixture.images));

    final extractor = runner.calls.first;
    expect(canonicalImages, contains('images [set] & source'));
    expect(extractor.arguments, contains(canonicalImages));
    expect(
      extractor.arguments.where((argument) => argument == canonicalImages),
      hasLength(1),
    );
    expect(
      result.diagnostics.explanations.values,
      everyElement(contains('Capturas consideradas: 1.')),
    );
    expect(result.output.meshCandidate!['path'], isA<String>());
    expect(
      result.output.meshCandidate!['path'] as String,
      startsWith(canonicalRoot),
    );
  });

  test('bounds and sanitizes the retained workspace prefix', () async {
    final fixture = await _fixture('flcad-colmap-prefix-');
    addTearDown(() => fixture.root.delete(recursive: true));
    final runner = _FakeColmapRunner();
    final requestId = '${'unsafe/&'.padRight(80, 'x')}?';
    await ColmapBackend(
      executable: _fakeColmapExecutable,
      processRunner: runner,
    ).reconstruct(_request(requestId, fixture.root, fixture.images));

    final name = Directory(
      runner.calls.first.workspace,
    ).uri.pathSegments.where((segment) => segment.isNotEmpty).last;
    final expectedPrefix = requestId
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .substring(0, 48);
    expect(name, startsWith('$expectedPrefix-'));
    expect(name, isNot(contains('&')));
    expect(name, isNot(contains('/')));
  });
}
