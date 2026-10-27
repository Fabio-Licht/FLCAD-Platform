import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'process kill during journal append preserves confirmed records',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'flcad-command-journal-process-',
      );
      addTearDown(() => project.delete(recursive: true));

      final initial = await _runWorker('append', project);
      expect(initial.exitCode, 0, reason: initial.stderr);
      expect((jsonDecode(initial.stdout as String) as Map)['count'], 1);

      final crash = await _startWorker('crash', project);
      final marker = await crash.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10));
      expect(marker, 'READY:partial-journal');
      expect(crash.kill(), isTrue);
      await crash.exitCode.timeout(const Duration(seconds: 10));

      final journal = File('${project.path}/CAD/CommandHistory/history.jsonl');
      expect(journal.readAsStringSync().endsWith('\n'), isFalse);

      final recovered = await _runWorker('verify', project);
      expect(recovered.exitCode, 0, reason: recovered.stderr);
      final result = jsonDecode(recovered.stdout as String) as Map;
      expect(result['count'], 1);
      expect(result['commands'], ['audit.command']);
      expect(result['operations'], ['execute']);
      expect(journal.readAsStringSync().endsWith('\n'), isTrue);
    },
  );

  test('concurrent processes serialize journal appends', () async {
    final project = await Directory.systemTemp.createTemp(
      'flcad-command-journal-lock-',
    );
    addTearDown(() => project.delete(recursive: true));

    final first = await _startWorker('lock', project);
    final firstLines = StreamIterator(
      first.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    expect(await firstLines.moveNext(), isTrue);
    expect(firstLines.current, 'READY:journal-locked');

    final second = await _startWorker('concurrent', project);
    final secondLines = StreamIterator(
      second.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    expect(await secondLines.moveNext(), isTrue);
    expect(secondLines.current, 'STARTED');
    first.stdin.writeln('release');
    await first.stdin.flush();
    final firstCode = await first.exitCode.timeout(const Duration(seconds: 10));
    final secondCode = await second.exitCode.timeout(
      const Duration(seconds: 10),
    );
    final firstRest = <String>[];
    while (await firstLines.moveNext()) {
      firstRest.add(firstLines.current);
    }
    final secondRest = <String>[];
    while (await secondLines.moveNext()) {
      secondRest.add(secondLines.current);
    }
    expect(firstCode, 0, reason: firstRest.join('\n'));
    expect(secondCode, 0, reason: secondRest.join('\n'));

    final verified = await _runWorker('verify', project);
    expect(verified.exitCode, 0, reason: verified.stderr);
    final result = jsonDecode(verified.stdout as String) as Map;
    expect(result['count'], 2);
    expect(result['commands'], ['audit.command', 'audit.command']);
  });

  test(
    'real coordinator startup repairs a partial journal in another process',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'flcad-command-startup-',
      );
      addTearDown(() => root.delete(recursive: true));
      final repository = ProjectRepository(
        storage: LocalStorageService(rootDirectory: root),
      );
      final project = await repository.create(
        name: 'Startup recovery',
        client: 'FLCAD',
      );
      final directory = await repository.directoryFor(project.id);
      final commandDirectory = Directory(
        '${directory.path}${Platform.pathSeparator}CAD'
        '${Platform.pathSeparator}CommandHistory',
      )..createSync(recursive: true);
      final journal = File(
        '${commandDirectory.path}${Platform.pathSeparator}history.jsonl',
      );
      journal.writeAsStringSync(
        '${jsonEncode({'command': 'confirmed', 'operation': 'execute'})}\n'
        '{"command":"partial"',
        flush: true,
      );
      final dart = _dartExecutable();
      final snapshot =
          '${File(dart).parent.parent.parent.path}'
          '${Platform.pathSeparator}flutter_tools.snapshot';
      final worker = Process.start(
        dart,
        [
          snapshot,
          'test',
          '--no-pub',
          '${Directory.current.path}${Platform.pathSeparator}test'
              '${Platform.pathSeparator}support'
              '${Platform.pathSeparator}command_startup_production_test.dart',
          '--plain-name',
          'production coordinator repairs the journal before initialization returns',
        ],
        workingDirectory: Directory.current.path,
        environment: {
          ...Platform.environment,
          'FLUTTER_SUPPRESS_ANALYTICS': 'true',
          'FLCAD_STARTUP_ROOT': root.path,
          'FLCAD_STARTUP_PROJECT_ID': project.id,
        },
      );
      final process = await worker;
      final stdout = await process.stdout.transform(utf8.decoder).join();
      final stderr = await process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 40),
      );
      expect(exitCode, 0, reason: '$stdout\n$stderr');
      final result =
          jsonDecode(
                File(
                  '${root.path}${Platform.pathSeparator}startup-result.json',
                ).readAsStringSync(),
              )
              as Map;
      expect(result['projectId'], project.id);
      expect(result['repaired'], isTrue);
      expect(result['gatedCommandRan'], isTrue);
      expect(result['canUndo'], isTrue);
      expect(result['persistenceHealthy'], isTrue);
      expect(journal.readAsStringSync().endsWith('\n'), isTrue);
    },
  );
}

Future<Process> _startWorker(String mode, Directory project) => Process.start(
  _dartExecutable(),
  [
    '--packages=${Directory.current.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}package_config.json',
    '${Directory.current.path}${Platform.pathSeparator}test'
        '${Platform.pathSeparator}support'
        '${Platform.pathSeparator}command_journal_process_worker.dart',
    mode,
    project.path,
  ],
  workingDirectory: Directory.current.path,
  runInShell: _dartExecutable() == 'dart',
);

Future<ProcessResult> _runWorker(String mode, Directory project) async {
  final process = await _startWorker(mode, project);
  final stdout = await process.stdout.transform(utf8.decoder).join();
  final stderr = await process.stderr.transform(utf8.decoder).join();
  return ProcessResult(process.pid, await process.exitCode, stdout, stderr);
}

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
