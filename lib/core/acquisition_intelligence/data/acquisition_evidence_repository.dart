import 'dart:convert';
import 'dart:io';

import '../models/evidence_graph.dart';
import '../models/universal_capture_contract.dart';

class AcquisitionEvidenceSnapshot {
  const AcquisitionEvidenceSnapshot({
    required this.projectId,
    required this.captures,
    required this.evidence,
    required this.graph,
  });

  final String projectId;
  final List<UniversalCaptureContract> captures;
  final List<CaptureEvidence> evidence;
  final EvidenceGraph graph;

  Map<String, dynamic> toJson() => {
    'projectId': projectId,
    'captures': captures.map((capture) => capture.toJson()).toList(),
    'evidence': evidence.map((item) => item.toJson()).toList(),
    'graph': graph.toJson(),
  };

  factory AcquisitionEvidenceSnapshot.fromJson(
    Map<String, dynamic> json,
  ) => AcquisitionEvidenceSnapshot(
    projectId: json['projectId'] as String,
    captures: (json['captures'] as List<dynamic>? ?? const [])
        .map(
          (capture) => UniversalCaptureContract.fromJson(
            Map<String, dynamic>.from(capture as Map),
          ),
        )
        .toList(),
    evidence: (json['evidence'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              CaptureEvidence.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
    graph: EvidenceGraph.fromJson(
      Map<String, dynamic>.from(json['graph'] as Map),
    ),
  );
}

class AcquisitionEvidenceRepository {
  const AcquisitionEvidenceRepository({required this.directory});

  final Directory directory;

  Future<File> _file(String projectId) async {
    await directory.create(recursive: true);
    final safeId = projectId.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return File('${directory.path}${Platform.pathSeparator}$safeId.json');
  }

  Future<void> save(AcquisitionEvidenceSnapshot snapshot) async {
    final file = await _file(snapshot.projectId);
    await file.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
  }

  Future<AcquisitionEvidenceSnapshot?> load(String projectId) async {
    final file = await _file(projectId);
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return AcquisitionEvidenceSnapshot.fromJson(json);
  }
}
