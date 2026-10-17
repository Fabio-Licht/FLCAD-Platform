import '../../cad_kernel/io/kernel_io_models.dart';
import '../../geometric_kernel/geometry/vectors.dart';
import '../../geometric_recognition/models/recognition_models.dart';

enum RecognitionHealth { excellent, good, medium, low, rejected }

class SurfaceRecognitionSettings {
  const SurfaceRecognitionSettings({
    this.normalAngleDegrees = 28,
    this.curvatureDelta = .35,
    this.minimumTriangles = 8,
    this.planar = false,
    this.planarToleranceMm = .5,
    this.seedTriangle,
    this.seedNeighborhoodTriangles = 24,
  });
  final double normalAngleDegrees, curvatureDelta;
  final int minimumTriangles;
  final bool planar;
  final double planarToleranceMm;
  final int? seedTriangle;
  final int seedNeighborhoodTriangles;
}

class MeshSurfaceData {
  const MeshSurfaceData({required this.vertices, required this.triangles});
  final List<Vector3> vertices;
  final List<(int, int, int)> triangles;
  factory MeshSurfaceData.fromKernel(KernelMeshGeometry value) =>
      MeshSurfaceData(
        vertices: [
          for (var i = 0; i < value.nodes.length; i += 3)
            Vector3(value.nodes[i], value.nodes[i + 1], value.nodes[i + 2]),
        ],
        triangles: [
          for (var i = 0; i < value.triangles.length; i += 3)
            (
              value.triangles[i],
              value.triangles[i + 1],
              value.triangles[i + 2],
            ),
        ],
      );
}

class SurfaceRegion {
  const SurfaceRegion({
    required this.id,
    required this.color,
    required this.triangleIndices,
    required this.vertexIndices,
    required this.area,
    required this.averageNormal,
    required this.bounds,
    required this.meanCurvature,
    required this.confidence,
    required this.health,
  });
  final String id, color;
  final List<int> triangleIndices, vertexIndices;
  final double area, meanCurvature, confidence;
  final Vector3 averageNormal;
  final KernelBounds bounds;
  final RecognitionHealth health;
  Map<String, dynamic> toJson() => {
    'id': id,
    'color': color,
    'area': area,
    'triangleCount': triangleIndices.length,
    'vertexCount': vertexIndices.length,
    'averageNormal': averageNormal.toJson(),
    'boundingBox': bounds.toJson(),
    'curvature': meanCurvature,
    'confidence': confidence,
    'health': health.name,
  };
}

class SurfaceClassification {
  const SurfaceClassification({
    required this.region,
    required this.type,
    required this.confidence,
    required this.quality,
    required this.parameters,
    required this.evidence,
    required this.reason,
    required this.rms,
  });
  final SurfaceRegion region;
  final PrimitiveType type;
  final double confidence, quality, rms;
  final Map<String, dynamic> parameters;
  final List<String> evidence;
  final String reason;
  Map<String, dynamic> toJson() => {
    ...region.toJson(),
    'type': type.name,
    'confidence': confidence,
    'quality': quality,
    'parameters': parameters,
    'evidence': evidence,
    'reason': reason,
    'rms': rms,
  };
}

class RegionGraph {
  const RegionGraph(this.edges);
  final Map<String, Set<String>> edges;
  Map<String, dynamic> toJson() =>
      edges.map((key, value) => MapEntry(key, value.toList()..sort()));
}

class RecognitionAnalytics {
  const RecognitionAnalytics({
    required this.elapsed,
    required this.totalArea,
    required this.recognizedArea,
    required this.unknownArea,
    required this.averageConfidence,
    required this.distribution,
  });
  final Duration elapsed;
  final double totalArea, recognizedArea, unknownArea, averageConfidence;
  final Map<PrimitiveType, int> distribution;
  Map<String, dynamic> toJson() => {
    'elapsedMicros': elapsed.inMicroseconds,
    'regionCount': distribution.values.fold<int>(0, (a, b) => a + b),
    'distribution': distribution.map((k, v) => MapEntry(k.name, v)),
    'totalArea': totalArea,
    'recognizedArea': recognizedArea,
    'unknownArea': unknownArea,
    'averageConfidence': averageConfidence,
  };
}

class RecognitionAdvice {
  const RecognitionAdvice(this.regionId, this.suggestion, this.reason);
  final String regionId, suggestion, reason;
  Map<String, dynamic> toJson() => {
    'regionId': regionId,
    'suggestion': suggestion,
    'reason': reason,
    'consultative': true,
  };
}

class SurfaceRecognitionReport {
  const SurfaceRecognitionReport({
    required this.id,
    required this.meshId,
    required this.classifications,
    required this.graph,
    required this.analytics,
    required this.advice,
    required this.createdAt,
  });
  final String id, meshId;
  final List<SurfaceClassification> classifications;
  final RegionGraph graph;
  final RecognitionAnalytics analytics;
  final List<RecognitionAdvice> advice;
  final DateTime createdAt;
  Map<String, dynamic> toJson() => {
    'id': id,
    'meshId': meshId,
    'summary': analytics.toJson(),
    'regions': classifications.map((e) => e.toJson()).toList(),
    'regionGraph': graph.toJson(),
    'advisor': advice.map((e) => e.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'createsCad': false,
  };
}
