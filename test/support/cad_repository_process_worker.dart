import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/cad_document_repository.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) exit(64);
  final mode = args[0];
  final project = Directory(args[1]);
  final projectId = args[2];
  final marker = args.length > 3 ? args[3] : 'worker';
  final repository = const CadDocumentRepository();
  var code = 0;
  try {
    switch (mode) {
      case 'write':
        await _write(repository, project, projectId, marker);
      case 'prepare-crash':
        _prepareRecovery(project, confirmed: false);
        code = 33;
      case 'confirm-crash':
        _prepareRecovery(project, confirmed: true);
        code = 34;
      case 'fail-before':
        code = 31;
      case 'snapshot-doc-crash':
        await _snapshotCrash(
          repository,
          project,
          projectId,
          afterHistory: false,
        );
      case 'snapshot-history-crash':
        await _snapshotCrash(
          repository,
          project,
          projectId,
          afterHistory: true,
        );
      default:
        code = 64;
    }
  } catch (error, _) {
    File(pathOf(project, 'worker-error-$marker')).writeAsStringSync('$error');
    code = error.toString().contains('concurrent') ? 17 : 1;
  }
  File(pathOf(project, 'worker-result-$marker')).writeAsStringSync('$code');
  exit(code);
}

Future<void> _snapshotCrash(
  CadDocumentRepository repository,
  Directory project,
  String projectId, {
  required bool afterHistory,
}) async {
  final baseline = await repository.load(projectId, project);
  final candidate = baseline.mutate(
    command: afterHistory ? 'snapshot-history-crash' : 'snapshot-doc-crash',
    upsert: [
      CadDocumentEntity(
        id: 'worker:snapshot',
        kind: CadDocumentEntityKind.sketch,
        data: {'marker': 'snapshot'},
      ),
    ],
  );
  await repository.saveSnapshot(project, () async {
    await repository.save(candidate, project);
    if (!afterHistory) {
      stdout.writeln('READY:after-document');
      await stdout.flush();
      stdin.readLineSync();
      return;
    }
    await repository.saveHistory(project, undo: [baseline], redo: const []);
    stdout.writeln('READY:after-history');
    await stdout.flush();
    stdin.readLineSync();
  });
}

CadDocument _readUnlocked(Directory project, String projectId) {
  final file = const CadDocumentRepository().file(project);
  if (!file.existsSync()) return CadDocument.empty(projectId);
  return CadDocument.fromJson(
    Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map),
  );
}

Future<void> _write(
  CadDocumentRepository repository,
  Directory project,
  String projectId,
  String marker,
) async {
  final baseline = _readUnlocked(project, projectId);
  File(pathOf(project, 'worker-waiting-$marker')).writeAsStringSync('1');
  await repository.withProjectLock(project, () async {
    final current = await repository.load(projectId, project);
    if (jsonEncode(current.toJson()) != jsonEncode(baseline.toJson())) {
      throw StateError('concurrent project change detected');
    }
    File(pathOf(project, 'worker-locked-$marker')).writeAsStringSync('1');
    if (marker == 'one') {
      while (!File(pathOf(project, 'worker-release-$marker')).existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    final entity = CadDocumentEntity(
      id: 'worker:$marker',
      kind: CadDocumentEntityKind.sketch,
      data: {'marker': marker, 'sceneKind': 'sketch'},
    );
    final candidate = baseline.mutate(
      command: 'worker-$marker',
      upsert: [entity],
    );
    await repository.save(candidate, project);
    await repository.saveHistory(project, undo: [baseline], redo: const []);
    File(pathOf(project, 'worker-saved-$marker')).writeAsStringSync('1');
  });
  File(pathOf(project, 'worker-done-$marker')).writeAsStringSync('1');
}

void _prepareRecovery(Directory project, {required bool confirmed}) {
  final repository = const CadDocumentRepository();
  final target = repository.historyFile(project);
  final temporaryDirectory = Directory(
    '${target.parent.path}${Platform.pathSeparator}'
    '${target.uri.pathSegments.last}.txn-manual',
  )..createSync();
  final temporary = File(
    '${temporaryDirectory.path}${Platform.pathSeparator}payload',
  );
  final backup = File('${target.path}.bak');
  final oldBytes = target.readAsBytesSync();
  final newBytes = utf8.encode(
    jsonEncode({
      'schema': 'flcad.cad-document-history',
      'version': 1,
      'undo': const [],
      'redo': const [],
      'recoveryMarker': confirmed ? 'confirmed' : 'prepared',
    }),
  );
  backup.writeAsBytesSync(oldBytes, flush: true);
  temporary.writeAsBytesSync(newBytes, flush: true);
  if (confirmed) target.writeAsBytesSync(newBytes, flush: true);
  File('${target.path}.txn.json').writeAsStringSync(
    jsonEncode({
      'version': 1,
      'target': target.path,
      'temporary': temporary.path,
      'backup': backup.path,
      'previousExists': true,
      'payloadSha256': sha256.convert(newBytes).toString(),
      'phase': 'prepared',
    }),
    flush: true,
  );
}

String pathOf(Directory project, String name) =>
    '${project.path}${Platform.pathSeparator}$name';
