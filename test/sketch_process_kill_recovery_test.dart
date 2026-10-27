import 'dart:convert';
import 'dart:io';

import 'package:flcad_mobile/core/sketch_engine/persistence/sketch_persistence_transaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scenario in const [
    ('crash-sketch', 'READY:after-sketch-write'),
    ('crash-constraints', 'READY:after-constraints-write'),
    ('crash-editor', 'READY:after-editor-write'),
  ]) {
    test(
      'process kill ${scenario.$2} recovers the confirmed generation',
      () => _runKillScenario(scenario.$1, scenario.$2),
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}

Future<void> _runKillScenario(String mode, String expectedMarker) async {
  final project = await Directory.systemTemp.createTemp(
    'flcad-sketch-process-kill-',
  );
  try {
    final baselineResult = await _runWorker('init', project);
    expect(baselineResult.exitCode, 0, reason: baselineResult.stderr);
    final baseline = jsonDecode(baselineResult.stdout as String) as Map;

    final crash = await _startWorker(mode, project);
    final marker = await crash.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 15));
    expect(marker, expectedMarker);
    expect(crash.kill(), isTrue);
    await crash.exitCode.timeout(const Duration(seconds: 10));

    final contract = Directory('${project.path}/CAD');
    expect(
      File(
        '${contract.path}/${SketchPersistenceTransaction.manifestFileName}',
      ).existsSync(),
      isTrue,
      reason: 'the killed process must leave its recovery boundary closed',
    );

    final reopened = await _runWorker('verify', project);
    expect(reopened.exitCode, 0, reason: reopened.stderr);
    final recovered = jsonDecode(reopened.stdout as String) as Map;
    expect(recovered, baseline);
    expect(
      File(
        '${contract.path}/${SketchPersistenceTransaction.manifestFileName}',
      ).existsSync(),
      isFalse,
    );
    expect(
      Directory(
        '${contract.path}/${SketchPersistenceTransaction.backupDirectoryName}',
      ).existsSync(),
      isFalse,
    );
  } finally {
    if (project.existsSync()) project.deleteSync(recursive: true);
  }
}

Future<Process> _startWorker(String mode, Directory project) => Process.start(
  _dartExecutable(),
  [
    '--packages=${Directory.current.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}package_config.json',
    '${Directory.current.path}${Platform.pathSeparator}test'
        '${Platform.pathSeparator}support'
        '${Platform.pathSeparator}sketch_persistence_process_worker.dart',
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
