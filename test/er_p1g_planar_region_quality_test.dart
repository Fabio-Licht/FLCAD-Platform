import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/recognition_engine/recognition_result.dart';
import 'package:flcad_mobile/core/surface_assistant/surface_assistant.dart';
import 'package:flcad_mobile/core/surface_recognition/models/surface_recognition_models.dart';
import 'package:flcad_mobile/core/surface_recognition/segmentation/region_growing.dart';

void main() {
  test('planar growth stops at a raised connected triangle', () {
    final mesh = MeshSurfaceData(
      vertices: [
        const Vector3(0, 0, 0),
        const Vector3(1, 0, 0),
        const Vector3(1, 1, 0),
        const Vector3(0, 1, 0),
        const Vector3(2, 0, .2),
      ],
      triangles: const [(0, 1, 2), (0, 2, 3), (1, 4, 2)],
    );
    final result = const ProfessionalRegionGrowing().segment(
      mesh,
      'fixture',
      settings: const SurfaceRecognitionSettings(
        planar: true,
        planarToleranceMm: .05,
        seedTriangle: 0,
        seedNeighborhoodTriangles: 1,
        minimumTriangles: 1,
      ),
    );
    expect(result.regions.single.triangleIndices, [0, 1]);
    expect(result.diagnostics['selectedTriangles'], 2);
    expect(result.diagnostics['rejectedByDistance'], 1);
  });

  test('planar tolerance is explicit and controls admissibility', () {
    final mesh = MeshSurfaceData(
      vertices: [
        const Vector3(0, 0, 0),
        const Vector3(1, 0, 0),
        const Vector3(1, 1, 0),
        const Vector3(0, 1, 0),
        const Vector3(2, 0, .2),
      ],
      triangles: const [(0, 1, 2), (0, 2, 3), (1, 4, 2)],
    );
    final result = const ProfessionalRegionGrowing().segment(
      mesh,
      'fixture',
      settings: const SurfaceRecognitionSettings(
        planar: true,
        planarToleranceMm: 2,
        seedTriangle: 0,
        seedNeighborhoodTriangles: 1,
        minimumTriangles: 1,
      ),
    );

    expect(result.regions.single.triangleIndices, [0, 1, 2]);
  });

  test(
    'dimensional rejection blocks CAD creation independently of confidence',
    () {
      final result = RecognitionResult(
        id: 'recognition:1',
        type: RecognitionResultType.plane,
        meshId: 'mesh',
        regionId: 'region',
        confidence: .958,
        parameters: const {
          'rmsDeviation': 5.425,
          'maximumDeviation': 12.451,
          'dimensionalToleranceMm': .5,
          'dimensionalStatus': 'rejected',
          'dimensionalApproved': false,
        },
        quality: 'rejected',
        suggestion: 'Review',
        createdAt: DateTime(2026),
      );

      final suggestion = const IntelligentSurfaceAssistant().suggest(result);
      expect(result.confidence, greaterThan(.9));
      expect(suggestion.canCreate, isFalse);
    },
  );

  test('recognition result adapter preserves dimensional metadata', () {
    const adapter = RecognitionResultAdapter();
    final result = adapter.build(
      id: 'recognition:2',
      meshId: 'mesh',
      regionId: 'region',
      points: const [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)],
      area: .5,
      extraParameters: const {
        'dimensionalToleranceMm': .5,
        'dimensionalApproved': false,
      },
    );

    expect(result.parameters['dimensionalToleranceMm'], .5);
    expect(result.parameters['dimensionalApproved'], isFalse);
  });
}
