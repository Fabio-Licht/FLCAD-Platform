import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/recognition_engine/recognition_result.dart';
import 'package:flcad_mobile/core/surface_assistant/surface_assistant.dart';
import 'package:flcad_mobile/core/surface_recognition/models/surface_recognition_models.dart';
import 'package:flcad_mobile/core/surface_recognition/segmentation/region_growing.dart';

void main() {
  test('multiscale planar evidence accepts a stable planar mesh', () {
    final vertices = <Vector3>[];
    final triangles = <(int, int, int)>[];
    const rows = 11;
    const columns = 11;
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        vertices.add(Vector3(x.toDouble(), y.toDouble(), 0));
      }
    }
    int index(int x, int y) => y * columns + x;
    for (var y = 0; y < rows - 1; y++) {
      for (var x = 0; x < columns - 1; x++) {
        final a = index(x, y), b = index(x + 1, y), c = index(x + 1, y + 1), d = index(x, y + 1);
        triangles.add((a, b, c));
        triangles.add((a, c, d));
      }
    }
    final result = const ProfessionalRegionGrowing().segment(
      MeshSurfaceData(vertices: vertices, triangles: triangles),
      'planar-fixture',
      settings: const SurfaceRecognitionSettings(
        planar: true,
        planarToleranceMm: .5,
        seedTriangle: 0,
        seedNeighborhoodTriangles: 24,
        minimumTriangles: 1,
      ),
    );

    expect(result.diagnostics['planarClassification'], 'planarCadCandidate');
    expect(result.diagnostics['planarScaleCount'], greaterThanOrEqualTo(3));
  });

  test('surface assistant blocks planar CAD without CAD-candidate evidence', () {
    const assistant = IntelligentSurfaceAssistant();
    final result = RecognitionResult(
      id: 'recognition:local',
      type: RecognitionResultType.plane,
      meshId: 'mesh',
      regionId: 'region',
      confidence: .95,
      parameters: const {
        'dimensionalApproved': true,
        'cadSurfaceApproved': false,
        'planarClassification': 'localReference',
      },
      quality: 'local',
      suggestion: 'reference',
      createdAt: DateTime(2026),
    );
    expect(assistant.suggest(result).canCreate, isFalse);

    final approved = RecognitionResult(
      id: 'recognition:cad',
      type: RecognitionResultType.plane,
      meshId: 'mesh',
      regionId: 'region',
      confidence: .95,
      parameters: const {
        'dimensionalApproved': true,
        'cadSurfaceApproved': true,
        'planarClassification': 'planarCadCandidate',
      },
      quality: 'stable',
      suggestion: 'surface',
      createdAt: DateTime(2026),
    );
    expect(assistant.suggest(approved).canCreate, isTrue);
  });
}
