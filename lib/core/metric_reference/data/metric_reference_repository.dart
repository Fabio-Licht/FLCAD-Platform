import 'dart:convert';
import 'dart:io';

import '../engine/metric_reference_solver.dart';
import '../models/metric_reference.dart';

class MetricReferenceSnapshot {
  const MetricReferenceSnapshot({
    required this.projectId,
    required this.references,
    required this.solution,
  });

  final String projectId;
  final List<MetricReference> references;
  final MetricScaleSolution solution;

  Map<String, dynamic> toJson() => {
    'projectId': projectId,
    'references': references.map((reference) => reference.toJson()).toList(),
    'solution': solution.toJson(),
  };

  factory MetricReferenceSnapshot.fromJson(Map<String, dynamic> json) {
    final references = (json['references'] as List<dynamic>? ?? const [])
        .map(
          (reference) => MetricReference.fromJson(
            Map<String, dynamic>.from(reference as Map),
          ),
        )
        .toList();
    final solutionJson = Map<String, dynamic>.from(json['solution'] as Map);
    final evidence = (solutionJson['evidence'] as List<dynamic>? ?? const [])
        .map(
          (item) => MetricReferenceEvidence.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
    final solutionReferences =
        (solutionJson['references'] as List<dynamic>? ?? const [])
            .map(
              (reference) => MetricReference.fromJson(
                Map<String, dynamic>.from(reference as Map),
              ),
            )
            .toList();
    final conflicts = (solutionJson['conflicts'] as List<dynamic>? ?? const [])
        .map(
          (conflict) => MetricReferenceConflict(
            referenceA: (conflict as Map)['referenceA'] as String,
            referenceB: conflict['referenceB'] as String,
            residualMillimeters: (conflict['residualMillimeters'] as num)
                .toDouble(),
            suggestedInvestigation:
                conflict['suggestedInvestigation'] as String? ??
                'Verificar a captura e a calibração da referência',
          ),
        )
        .toList();
    return MetricReferenceSnapshot(
      projectId: json['projectId'] as String,
      references: references,
      solution: MetricScaleSolution(
        scaleFactor: (solutionJson['scaleFactor'] as num?)?.toDouble(),
        confidence: (solutionJson['confidence'] as num).toDouble(),
        references: solutionReferences,
        evidence: evidence,
        hasConflicts: solutionJson['hasConflicts'] as bool,
        conflicts: conflicts,
      ),
    );
  }
}

class MetricReferenceRepository {
  const MetricReferenceRepository({required this.directory});

  final Directory directory;

  Future<File> _file(String projectId) async {
    await directory.create(recursive: true);
    final safeId = projectId.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return File('${directory.path}${Platform.pathSeparator}$safeId.json');
  }

  Future<void> save(MetricReferenceSnapshot snapshot) async {
    final file = await _file(snapshot.projectId);
    await file.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
  }

  Future<MetricReferenceSnapshot?> load(String projectId) async {
    final file = await _file(projectId);
    if (!await file.exists()) return null;
    return MetricReferenceSnapshot.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
  }
}
