import 'package:flcad_mobile/app/cad_viewport/rendering/recognition_surface_preview_builder.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/models/professional_recognition_models.dart';
import 'package:flcad_mobile/core/recognition_engine/recognition_result.dart';
import 'package:flcad_mobile/core/surface_assistant/surface_assistant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plane recognition keeps fit metrics for inspection', () {
    const adapter = RecognitionResultAdapter();
    final result = adapter.build(
      id: 'Recognition001',
      meshId: 'Mesh001',
      regionId: 'region:1',
      points: const [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
      area: 1,
      primitive: _planePrimitive(),
    );

    expect(result.parameters['rmsDeviation'], .004);
    expect(result.parameters['maximumDeviation'], .01);
    expect(result.parameters['rmsDeviation'], isA<double>());
  });

  test('plane preview is transient presentation geometry', () {
    const adapter = RecognitionResultAdapter();
    final result = adapter.build(
      id: 'Recognition001',
      meshId: 'Mesh001',
      regionId: 'region:1',
      points: const [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
      area: 1,
      primitive: _planePrimitive(),
    );
    final suggestion = const IntelligentSurfaceAssistant().suggest(result);
    final preview = const RecognitionSurfacePreviewBuilder().build(
      result,
      suggestion,
    );

    expect(preview.kind.name, 'preview');
    expect(preview.geometry['previewOnly'], isTrue);
    expect(preview.geometry['sourceRecognitionId'], result.id);
    expect(preview.geometry['triangles'], isNotEmpty);
  });
}

ProfessionalPrimitive _planePrimitive() {
  const type = PrimitiveType.plane;
  const statistics = FitStatistics(
    rms: .004,
    maximum: .01,
    mean: .003,
    coverage: .99,
    stability: .98,
    score: .97,
  );
  const candidate = RecognitionCandidate(
    id: 'candidate:plane',
    type: type,
    regionId: 'region:1',
    parameters: {
      'origin': [0, 0, 0],
      'normal': [0, 1, 0],
    },
    statistics: statistics,
    evidence: [],
    origin: 'test',
  );
  return ProfessionalPrimitive(
    recognition: PrimitiveRecognitionResult(
      id: 'recognition:plane',
      projectId: 'project',
      meshId: 'Mesh001',
      winner: candidate,
      alternatives: const [],
      dna: const RecognitionDNA(
        type: type,
        parameters: {
          'origin': [0, 0, 0],
          'normal': [0, 1, 0],
        },
        regionId: 'region:1',
        geometricSignature: 'plane',
        quality: .97,
        confidence: .98,
        evidence: [],
        origin: 'test',
        version: '1',
      ),
      explanation: const RecognitionExplanation(
        why: 'synthetic plane',
        evidence: [],
        regions: ['region:1'],
        parameters: {},
        losingCandidates: [],
        score: .97,
        confidence: .98,
      ),
      createdAt: DateTime(2026, 1, 1),
    ),
    residualMap: const ResidualMap([], [], []),
    pass: 1,
    auditTrail: const ['test'],
  );
}
