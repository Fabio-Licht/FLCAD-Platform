import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/cad_document_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late Directory project;
  late CadDocumentRepository repository;
  const projectId = 'process-recovery';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('flcad-process-recovery-');
    project = Directory('${root.path}${Platform.pathSeparator}project')
      ..createSync();
    repository = const CadDocumentRepository();
    final initial = CadDocument.empty(projectId).mutate(
      command: 'initial',
      upsert: [
        CadDocumentEntity(
          id: 'seed',
          kind: CadDocumentEntityKind.sketch,
          data: {'marker': 'seed', 'sceneKind': 'sketch'},
        ),
      ],
    );
    await repository.save(initial, project);
    await repository.saveHistory(
      project,
      undo: [CadDocument.empty(projectId)],
      redo: const [],
    );
  });

  tearDown(() => root.delete(recursive: true));

  test('independent processes serialize and reject stale overwrite', () async {
    final first = await _startWorker(project, projectId, 'write', 'one');
    await _waitFor(
      File('${project.path}${Platform.pathSeparator}worker-waiting-one'),
      first,
    );
    await _waitFor(
      File('${project.path}${Platform.pathSeparator}worker-locked-one'),
      first,
    );
    final second = await _startWorker(project, projectId, 'write', 'two');
    await _waitFor(
      File('${project.path}${Platform.pathSeparator}worker-waiting-two'),
      second,
    );
    File(
      '${project.path}${Platform.pathSeparator}worker-release-one',
    ).writeAsStringSync('1');
    await _waitFor(
      File('${project.path}${Platform.pathSeparator}worker-done-one'),
      first,
    );
    await _waitFor(
      File('${project.path}${Platform.pathSeparator}worker-result-two'),
      second,
    );
    await _waitFor(
      File('${project.path}${Platform.pathSeparator}worker-result-one'),
      first,
    );
    expect(
      File(
        '${project.path}${Platform.pathSeparator}worker-result-one',
      ).readAsStringSync(),
      '0',
    );
    expect(
      File(
        '${project.path}${Platform.pathSeparator}worker-result-two',
      ).readAsStringSync(),
      '17',
      reason: File(
        '${project.path}${Platform.pathSeparator}worker-error-two',
      ).readAsStringSync(),
    );
    first.kill(ProcessSignal.sigterm);
    second.kill(ProcessSignal.sigterm);

    final document = await repository.load(projectId, project);
    expect(document.entities.containsKey('worker:one'), isTrue);
    expect(document.entities.containsKey('worker:two'), isFalse);
    expect((await repository.loadHistory(project)).undo, hasLength(1));
  });

  test('project lock wait has a bounded timeout', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final held = repository.withProjectLock(project, () async {
      entered.complete();
      await release.future;
    });
    await entered.future;

    await expectLater(
      repository.withProjectLock(
        project,
        () async => null,
        timeout: const Duration(milliseconds: 100),
      ),
      throwsA(isA<TimeoutException>()),
    );

    release.complete();
    await held;
  });

  test(
    'prepared replacement recovers the prior history after interruption',
    () async {
      final result = await _runWorker(
        project,
        projectId,
        'prepare-crash',
        'prepared',
      );
      expect(result.exitCode, 33, reason: result.stderr);
      final historyBefore = await repository.loadHistory(project);
      expect(historyBefore.undo, hasLength(1));
      expect(
        File(
          '${project.path}${Platform.pathSeparator}cad-document-history.json.txn.json',
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          '${project.path}${Platform.pathSeparator}cad-document-history.json.bak',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'confirmed replacement survives recovery cleanup after interruption',
    () async {
      final result = await _runWorker(
        project,
        projectId,
        'confirm-crash',
        'confirmed',
      );
      expect(result.exitCode, 34, reason: result.stderr);
      final raw =
          jsonDecode(repository.historyFile(project).readAsStringSync()) as Map;
      expect(raw['recoveryMarker'], 'confirmed');
      await repository.loadHistory(project);
      expect(
        File(
          '${project.path}${Platform.pathSeparator}cad-document-history.json.txn.json',
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          '${project.path}${Platform.pathSeparator}cad-document-history.json.bak',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('failure before writing leaves the project unchanged', () async {
    final before = await repository.captureFiles(project);
    final result = await _runWorker(
      project,
      projectId,
      'fail-before',
      'before',
    );
    expect(result.exitCode, 31, reason: result.stderr);
    expect(await repository.captureFiles(project), before);
  });

  test('corrupt manifest recovers the readable previous file', () async {
    final target = repository.historyFile(project);
    final previous = target.readAsBytesSync();
    final backup = File('${target.path}.bak')
      ..writeAsBytesSync(previous, flush: true);
    target.writeAsStringSync('{}', flush: true);
    final temporary = Directory('${target.path}.txn-orphan')..createSync();
    File('${temporary.path}/payload').writeAsStringSync('{partial');
    File('${target.path}.txn.json').writeAsStringSync('{"phase":', flush: true);
    final history = await repository.loadHistory(project);
    expect(history.undo, hasLength(1));
    expect(backup.existsSync(), isFalse);
    expect(temporary.existsSync(), isFalse);
    expect(File('${target.path}.txn.json').existsSync(), isFalse);
  });

  test('semantically invalid manifest recovers the previous pair', () async {
    final documentBefore = repository.file(project).readAsBytesSync();
    final historyBefore = repository.historyFile(project).readAsBytesSync();
    final backup = repository.snapshotBackup(project)..createSync();
    File(
      '${backup.path}${Platform.pathSeparator}cad-document.json',
    ).writeAsBytesSync(documentBefore);
    File(
      '${backup.path}${Platform.pathSeparator}cad-document-history.json',
    ).writeAsBytesSync(historyBefore);
    File(
      '${backup.path}${Platform.pathSeparator}backup.complete',
    ).writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.cad-snapshot-backup',
        'version': 1,
        'files': {
          'cad-document.json': sha256.convert(documentBefore).toString(),
          'cad-document-history.json': sha256.convert(historyBefore).toString(),
        },
      }),
    );
    repository.file(project).writeAsStringSync('{}');
    repository.historyFile(project).writeAsStringSync('{}');
    repository
        .snapshotManifest(project)
        .writeAsStringSync(
          '{"schema":"flcad.cad-snapshot-transaction","version":1,"phase":"prepared","files":"invalid"}',
        );

    final document = await repository.load(projectId, project);
    expect(document.entities.containsKey('seed'), isTrue);
    expect((await repository.loadHistory(project)).undo, hasLength(1));
    expect(repository.snapshotManifest(project).existsSync(), isFalse);
    expect(repository.snapshotBackup(project).existsSync(), isFalse);
  });

  test('incorrect prepared hash restores the valid backup', () async {
    final target = repository.historyFile(project);
    final previous = target.readAsBytesSync();
    final backup = File('${target.path}.bak')
      ..writeAsBytesSync(previous, flush: true);
    final candidate = {
      'schema': 'flcad.cad-document-history',
      'version': 1,
      'undo': const [],
      'redo': const [],
    };
    target.writeAsStringSync(jsonEncode(candidate), flush: true);
    final temporary = Directory('${target.path}.txn-hash-mismatch')
      ..createSync();
    final payload = File('${temporary.path}/payload')
      ..writeAsStringSync(jsonEncode(candidate), flush: true);
    File('${target.path}.txn.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'target': target.path,
        'temporary': payload.path,
        'backup': backup.path,
        'previousExists': true,
        'payloadSha256': List.filled(64, '0').join(),
        'phase': 'prepared',
      }),
      flush: true,
    );

    final history = await repository.loadHistory(project);
    expect(
      history.undo,
      hasLength(1),
      reason:
          'target=${target.readAsStringSync()} '
          'backup=${backup.existsSync()} '
          'manifest=${File('${target.path}.txn.json').existsSync()} '
          'temporary=${temporary.existsSync()}',
    );
    expect(backup.existsSync(), isFalse);
    expect(temporary.existsSync(), isFalse);
    expect(File('${target.path}.txn.json').existsSync(), isFalse);
  });

  test(
    'committed target with divergent hash restores the valid backup',
    () async {
      final target = repository.historyFile(project);
      final previous = target.readAsBytesSync();
      final backup = File('${target.path}.bak')
        ..writeAsBytesSync(previous, flush: true);
      target.writeAsStringSync('{}', flush: true);
      final temporary = Directory('${target.path}.txn-committed-hash')
        ..createSync();
      final payload = File('${temporary.path}/payload')
        ..writeAsStringSync('{}', flush: true);
      File('${target.path}.txn.json').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'target': target.path,
          'temporary': payload.path,
          'backup': backup.path,
          'previousExists': true,
          'payloadSha256': List.filled(64, '0').join(),
          'phase': 'committed',
        }),
        flush: true,
      );

      final history = await repository.loadHistory(project);

      expect(history.undo, hasLength(1));
      expect(backup.existsSync(), isFalse);
      expect(temporary.existsSync(), isFalse);
      expect(File('${target.path}.txn.json').existsSync(), isFalse);
    },
  );

  test(
    'corrupt pair with divergent manifest hash restores an independently verified backup',
    () async {
      final documentBefore = repository.file(project).readAsBytesSync();
      final historyBefore = repository.historyFile(project).readAsBytesSync();
      final backup = repository.snapshotBackup(project)..createSync();
      final backupDocument = File(
        '${backup.path}${Platform.pathSeparator}cad-document.json',
      )..writeAsBytesSync(documentBefore, flush: true);
      final backupHistory = File(
        '${backup.path}${Platform.pathSeparator}cad-document-history.json',
      )..writeAsBytesSync(historyBefore, flush: true);
      File(
        '${backup.path}${Platform.pathSeparator}backup.complete',
      ).writeAsStringSync(
        jsonEncode({
          'schema': 'flcad.cad-snapshot-backup',
          'version': 1,
          'files': {
            'cad-document.json': sha256
                .convert(backupDocument.readAsBytesSync())
                .toString(),
            'cad-document-history.json': sha256
                .convert(backupHistory.readAsBytesSync())
                .toString(),
          },
        }),
        flush: true,
      );
      repository.file(project).writeAsStringSync('{}', flush: true);
      repository.historyFile(project).writeAsStringSync('{}', flush: true);
      repository
          .snapshotManifest(project)
          .writeAsStringSync(
            jsonEncode({
              'schema': 'flcad.cad-snapshot-transaction',
              'version': 1,
              'phase': 'prepared',
              'files': ['cad-document.json', 'cad-document-history.json'],
              'hashes': {
                'cad-document.json': List.filled(64, '0').join(),
                'cad-document-history.json': List.filled(64, '0').join(),
              },
            }),
            flush: true,
          );

      final document = await repository.load(projectId, project);
      expect(document.entities.containsKey('seed'), isTrue);
      expect((await repository.loadHistory(project)).undo, hasLength(1));
      expect(repository.snapshotManifest(project).existsSync(), isFalse);
      expect(repository.snapshotBackup(project).existsSync(), isFalse);
    },
  );

  test('pair cleanup recovery is idempotent after backup removal', () async {
    final documentBefore = repository.file(project).readAsBytesSync();
    final historyBefore = repository.historyFile(project).readAsBytesSync();
    final manifest = repository.snapshotManifest(project)
      ..writeAsStringSync(
        jsonEncode({
          'schema': 'flcad.cad-snapshot-transaction',
          'version': 1,
          'phase': 'prepared',
          'files': ['cad-document.json', 'cad-document-history.json'],
          'hashes': {
            'cad-document.json': sha256.convert(documentBefore).toString(),
            'cad-document-history.json': sha256
                .convert(historyBefore)
                .toString(),
          },
        }),
        flush: true,
      );

    final document = await repository.load(projectId, project);
    expect(document.entities.containsKey('seed'), isTrue);
    expect((await repository.loadHistory(project)).undo, hasLength(1));
    expect(manifest.existsSync(), isFalse);
    expect(repository.file(project).readAsBytesSync(), documentBefore);
    expect(repository.historyFile(project).readAsBytesSync(), historyBefore);
  });

  test('empty prepared CAD snapshot restores the pre-save state', () async {
    final emptyRoot = await Directory.systemTemp.createTemp(
      'flcad-empty-cad-snapshot-',
    );
    addTearDown(() => emptyRoot.delete(recursive: true));
    final emptyProject = Directory(
      '${emptyRoot.path}${Platform.pathSeparator}project',
    )..createSync();
    final partial = repository.file(emptyProject)
      ..writeAsStringSync('{"partial":true}', flush: true);
    final backup = repository.snapshotBackup(emptyProject)..createSync();
    File(
      '${backup.path}${Platform.pathSeparator}backup.complete',
    ).writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.cad-snapshot-backup',
        'version': 1,
        'files': const <String, String>{},
      }),
      flush: true,
    );
    final manifest = repository.snapshotManifest(emptyProject)
      ..writeAsStringSync(
        jsonEncode({
          'schema': 'flcad.cad-snapshot-transaction',
          'version': 1,
          'phase': 'prepared',
          'files': ['cad-document.json', 'cad-document-history.json'],
          'hashes': const <String, String>{},
        }),
        flush: true,
      );

    final restored = await repository.load(projectId, emptyProject);

    expect(restored.entities, isEmpty);
    expect(partial.existsSync(), isFalse);
    expect(backup.existsSync(), isFalse);
    expect(manifest.existsSync(), isFalse);
  });

  test(
    'legacy marker alone cannot restore an incomplete CAD pair backup',
    () async {
      final currentDocument = repository.file(project).readAsBytesSync();
      final currentHistory = repository.historyFile(project).readAsBytesSync();
      final backup = repository.snapshotBackup(project)..createSync();
      File(
        '${backup.path}${Platform.pathSeparator}cad-document.json',
      ).writeAsStringSync('{"schema":"partial"}', flush: true);
      File(
        '${backup.path}${Platform.pathSeparator}backup.complete',
      ).writeAsStringSync('1', flush: true);
      final manifest = repository.snapshotManifest(project)
        ..writeAsStringSync('{"phase":', flush: true);

      await expectLater(
        repository.load(projectId, project),
        throwsA(isA<Object>()),
      );

      expect(repository.file(project).readAsBytesSync(), currentDocument);
      expect(repository.historyFile(project).readAsBytesSync(), currentHistory);
      expect(backup.existsSync(), isTrue);
      expect(manifest.existsSync(), isTrue);
    },
  );

  test('CAD marker without hashes cannot authorize restoration', () async {
    final currentDocument = repository.file(project).readAsBytesSync();
    final currentHistory = repository.historyFile(project).readAsBytesSync();
    final backup = repository.snapshotBackup(project)..createSync();
    File(
      '${backup.path}${Platform.pathSeparator}backup.complete',
    ).writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.cad-snapshot-backup',
        'version': 1,
        'files': const <String, String>{},
      }),
      flush: true,
    );
    File(
      repository.snapshotManifest(project).path,
    ).writeAsStringSync('{"phase":', flush: true);

    await expectLater(
      repository.load(projectId, project),
      throwsA(isA<Object>()),
    );

    expect(repository.file(project).readAsBytesSync(), currentDocument);
    expect(repository.historyFile(project).readAsBytesSync(), currentHistory);
    expect(backup.existsSync(), isTrue);
  });

  test(
    'committed CAD snapshot with divergent published hashes restores backup',
    () async {
      final documentBefore = repository.file(project).readAsBytesSync();
      final historyBefore = repository.historyFile(project).readAsBytesSync();
      final backup = repository.snapshotBackup(project)..createSync();
      final backupDocument = File(
        '${backup.path}${Platform.pathSeparator}cad-document.json',
      )..writeAsBytesSync(documentBefore, flush: true);
      final backupHistory = File(
        '${backup.path}${Platform.pathSeparator}cad-document-history.json',
      )..writeAsBytesSync(historyBefore, flush: true);
      final backupHashes = {
        'cad-document.json': sha256
            .convert(backupDocument.readAsBytesSync())
            .toString(),
        'cad-document-history.json': sha256
            .convert(backupHistory.readAsBytesSync())
            .toString(),
      };
      File(
        '${backup.path}${Platform.pathSeparator}backup.complete',
      ).writeAsStringSync(
        jsonEncode({
          'schema': 'flcad.cad-snapshot-backup',
          'version': 1,
          'files': backupHashes,
        }),
        flush: true,
      );
      repository.file(project).writeAsStringSync('{}', flush: true);
      repository.historyFile(project).writeAsStringSync('{}', flush: true);
      repository
          .snapshotManifest(project)
          .writeAsStringSync(
            jsonEncode({
              'schema': 'flcad.cad-snapshot-transaction',
              'version': 1,
              'phase': 'committed',
              'files': ['cad-document.json', 'cad-document-history.json'],
              'hashes': backupHashes,
              'committedHashes': {
                'cad-document.json': List.filled(64, '0').join(),
                'cad-document-history.json': List.filled(64, '0').join(),
              },
            }),
            flush: true,
          );

      final document = await repository.load(projectId, project);

      expect(document.entities.containsKey('seed'), isTrue);
      expect((await repository.loadHistory(project)).undo, hasLength(1));
      expect(repository.file(project).readAsBytesSync(), documentBefore);
      expect(repository.historyFile(project).readAsBytesSync(), historyBefore);
      expect(repository.snapshotManifest(project).existsSync(), isFalse);
      expect(repository.snapshotBackup(project).existsSync(), isFalse);
    },
  );

  test(
    'real kill between document and history recovery points restores pair',
    () async {
      final beforeDocument = repository.file(project).readAsBytesSync();
      final beforeHistory = repository.historyFile(project).readAsBytesSync();
      final process = await _startWorker(
        project,
        projectId,
        'snapshot-doc-crash',
        'snapshot-doc',
      );
      await _waitForLine(process, 'READY:after-document');
      expect(process.kill(), isTrue);
      await process.exitCode.timeout(const Duration(seconds: 10));
      expect(repository.snapshotManifest(project).existsSync(), isTrue);
      final document = await repository.load(projectId, project);
      expect(document.entities.containsKey('worker:snapshot'), isFalse);
      expect(repository.file(project).readAsBytesSync(), beforeDocument);
      expect(repository.historyFile(project).readAsBytesSync(), beforeHistory);
      expect(repository.snapshotManifest(project).existsSync(), isFalse);
    },
  );

  test(
    'real kill after both writes but before pair commit restores pair',
    () async {
      final beforeDocument = repository.file(project).readAsBytesSync();
      final beforeHistory = repository.historyFile(project).readAsBytesSync();
      final process = await _startWorker(
        project,
        projectId,
        'snapshot-history-crash',
        'snapshot-history',
      );
      await _waitForLine(process, 'READY:after-history');
      expect(process.kill(), isTrue);
      await process.exitCode.timeout(const Duration(seconds: 10));
      expect(repository.snapshotManifest(project).existsSync(), isTrue);
      final document = await repository.load(projectId, project);
      expect(document.entities.containsKey('worker:snapshot'), isFalse);
      expect(repository.file(project).readAsBytesSync(), beforeDocument);
      expect(repository.historyFile(project).readAsBytesSync(), beforeHistory);
      expect(repository.snapshotManifest(project).existsSync(), isFalse);
    },
  );
}

String _workerPath() =>
    '${Directory.current.path}${Platform.pathSeparator}test${Platform.pathSeparator}support${Platform.pathSeparator}cad_repository_process_worker.dart';

Future<ProcessResult> _runWorker(
  Directory project,
  String projectId,
  String mode,
  String marker,
) async {
  final process = await _startWorker(project, projectId, mode, marker);
  return ProcessResult(process.pid, await process.exitCode, '', '');
}

Future<Process> _startWorker(
  Directory project,
  String projectId,
  String mode,
  String marker,
) => Process.start(
  _dartExecutable(),
  [
    '--packages=${Directory.current.path}${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}package_config.json',
    _workerPath(),
    mode,
    project.path,
    projectId,
    marker,
  ],
  workingDirectory: Directory.current.path,
  runInShell: _dartExecutable() == 'dart',
);

String _dartExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  final candidate = root == null
      ? null
      : '$root${Platform.pathSeparator}bin${Platform.pathSeparator}cache'
            '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin'
            '${Platform.pathSeparator}dart.exe';
  if (candidate != null && File(candidate).existsSync()) return candidate;
  const installed = r'C:\flutter\bin\cache\dart-sdk\bin\dart.exe';
  if (File(installed).existsSync()) return installed;
  return 'dart';
}

Future<void> _waitFor(File file, Process process) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!file.existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      process.kill(ProcessSignal.sigterm);
      final code = await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
      throw StateError(
        'Worker marker was not created: ${file.path}; exit=$code',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitForLine(Process process, String expected) async {
  final line = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 10));
  expect(line, expected);
}
