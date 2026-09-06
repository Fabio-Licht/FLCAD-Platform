import 'dart:convert';
import 'dart:io';

import '../models/reconstruction_contract.dart';

class ReconstructionRepository {
  const ReconstructionRepository({required this.directory});

  final Directory directory;

  Future<File> _file(String requestId) async {
    await directory.create(recursive: true);
    final safeId = requestId.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return File('${directory.path}${Platform.pathSeparator}$safeId.json');
  }

  Future<void> save(ReconstructionOutput output) async {
    final file = await _file(output.requestId);
    await file.writeAsString(jsonEncode(output.toJson()), flush: true);
  }

  Future<ReconstructionOutput?> load(String requestId) async {
    final file = await _file(requestId);
    if (!await file.exists()) return null;
    return ReconstructionOutput.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
  }
}
