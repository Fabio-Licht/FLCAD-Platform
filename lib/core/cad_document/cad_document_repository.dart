import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart' show protected;
import 'cad_document.dart';

class CadDocumentRepository {
  const CadDocumentRepository();
  File file(Directory project) =>
      File(path.join(project.path, 'cad-document.json'));
  Future<CadDocument> load(String projectId, Directory project) async {
    final source = file(project);
    if (!await source.exists()) return CadDocument.empty(projectId);
    final value = CadDocument.fromJson(
      Map<String, dynamic>.from(jsonDecode(await source.readAsString()) as Map),
    );
    if (value.projectId != projectId) {
      throw StateError('CAD document project identity mismatch.');
    }
    return value;
  }

  Future<void> save(CadDocument document, Directory project) async {
    await _atomic(file(project), document.toJson());
  }

  File historyFile(Directory project) =>
      File(path.join(project.path, 'cad-document-history.json'));

  Future<CadDocumentHistoryState> loadHistory(Directory project) async {
    final source = historyFile(project);
    if (!await source.exists()) return const CadDocumentHistoryState();
    final json = Map<String, dynamic>.from(
      jsonDecode(await source.readAsString()) as Map,
    );
    return CadDocumentHistoryState(
      undo: (json['undo'] as List? ?? const [])
          .map(
            (value) =>
                CadDocument.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList(),
      redo: (json['redo'] as List? ?? const [])
          .map(
            (value) =>
                CadDocument.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList(),
    );
  }

  Future<void> saveHistory(
    Directory project, {
    required Iterable<CadDocument> undo,
    required Iterable<CadDocument> redo,
  }) => _atomic(historyFile(project), {
    'schema': 'flcad.cad-document-history',
    'version': 1,
    'undo': undo.map((value) => value.toJson()).toList(),
    'redo': redo.map((value) => value.toJson()).toList(),
  });

  /// In-process recovery only. The two JSON files are NOT crash-atomic.
  Future<Map<String, List<int>?>> captureFiles(Directory project) async {
    final result = <String, List<int>?>{};
    for (final target in [file(project), historyFile(project)]) {
      result[path.basename(target.path)] = await target.exists()
          ? await target.readAsBytes()
          : null;
    }
    return result;
  }

  Future<void> restoreFiles(
    Directory project,
    Map<String, List<int>?> backup,
  ) async {
    for (final entry in backup.entries) {
      final target = File(path.join(project.path, entry.key));
      if (entry.value == null) {
        if (await target.exists()) await target.delete();
      } else {
        await _atomicBytes(target, entry.value!);
      }
    }
    final restored = await captureFiles(project);
    for (final entry in backup.entries) {
      final actual = restored[entry.key];
      if (entry.value == null
          ? actual != null
          : actual == null ||
                base64Encode(actual) != base64Encode(entry.value!)) {
        throw StateError('CAD persistence recovery could not be verified.');
      }
    }
  }

  Future<void> _atomic(File target, Map<String, dynamic> value) =>
      _atomicBytes(target, utf8.encode(jsonEncode(value)));

  /// Storage boundary for fault injection; ownership passes to _atomicBytes.
  @protected
  Future<Directory> createTemporaryDirectory(File target) =>
      target.parent.createTemp('${path.basename(target.path)}.txn-');

  Future<void> _atomicBytes(File target, List<int> bytes) async {
    // Exclusive directory per write: concurrent transactions/processes never
    // share a temporary name. Same volume as the destination for rename.
    final temporaryDirectory = await createTemporaryDirectory(target);
    final temporary = File(path.join(temporaryDirectory.path, 'payload'));
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    } finally {
      await temporaryDirectory.delete(recursive: true);
    }
  }
}

class CadDocumentHistoryState {
  const CadDocumentHistoryState({this.undo = const [], this.redo = const []});
  final List<CadDocument> undo;
  final List<CadDocument> redo;
}
