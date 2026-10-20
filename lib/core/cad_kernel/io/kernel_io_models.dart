import '../models/kernel_models.dart';

enum KernelExchangeFormat { step, iges, brep }

enum KernelImportFormat { stl, asciiStl, binaryStl, autoDetect }

class KernelBounds {
  const KernelBounds(
    this.minX,
    this.minY,
    this.minZ,
    this.maxX,
    this.maxY,
    this.maxZ,
  );
  final double minX, minY, minZ, maxX, maxY, maxZ;
  Map<String, dynamic> toJson() => {
    'min': [minX, minY, minZ],
    'max': [maxX, maxY, maxZ],
  };
}

class KernelMeshHandle {
  const KernelMeshHandle({
    required this.persistentId,
    required this.kernelId,
    required this.fingerprint,
    required this.vertexCount,
    required this.triangleCount,
    required this.bounds,
    required this.hasNormals,
    required this.metadata,
    this.degenerateTriangleCount = 0,
  });
  final String persistentId, kernelId, fingerprint;
  final int vertexCount, triangleCount;
  final KernelBounds bounds;
  final bool hasNormals;
  final int degenerateTriangleCount;
  final Map<String, dynamic> metadata;
}

class KernelMeshGeometry {
  const KernelMeshGeometry({required this.nodes, required this.triangles});
  final List<double> nodes;
  final List<int> triangles;
}

class KernelBoundaryData {
  const KernelBoundaryData({
    required this.index,
    required this.length,
    required this.closed,
  });
  final int index;
  final double length;
  final bool closed;
}

class KernelLoopData {
  const KernelLoopData({
    required this.index,
    required this.closed,
    required this.boundaryIndices,
  });
  final int index;
  final bool closed;
  final List<int> boundaryIndices;
}

class KernelSurfaceTopology {
  const KernelSurfaceTopology({
    required this.boundaries,
    required this.loops,
    this.area = 0,
    this.perimeter = 0,
    this.faceCount = 0,
    this.edgeCount = 0,
    this.vertexCount = 0,
    this.valid = false,
  });
  final List<KernelBoundaryData> boundaries;
  final List<KernelLoopData> loops;
  final double area, perimeter;
  final int faceCount, edgeCount, vertexCount;
  final bool valid;
}

class KernelSurfaceIntersection {
  const KernelSurfaceIntersection({
    required this.edgeCount,
    required this.length,
    this.handle,
  });
  final int edgeCount;
  final double length;
  final ShapeHandle? handle;
}

abstract interface class SurfaceTopologyKernelAPI {
  Future<KernelSurfaceTopology> inspectSurfaceTopology(ShapeHandle surface);
  Future<KernelSurfaceIntersection> intersectSurfaces(
    ShapeHandle first,
    ShapeHandle second, {
    required String projectId,
  });
}

abstract interface class SurfaceQualityKernelAPI {
  Future<Map<String, dynamic>> inspectSurfaceQuality(
    ShapeHandle surface, {
    required List<double> draftDirection,
    int samples = 100,
  });
}

class KernelSurfaceOperationResult {
  const KernelSurfaceOperationResult({
    required this.supported,
    required this.diagnostic,
    this.result,
    this.undoToken,
    this.redoToken,
  });
  final bool supported;
  final String diagnostic;
  final ShapeHandle? result;
  final String? undoToken, redoToken;
}

abstract interface class SurfaceOperationKernelAPI {
  Future<KernelSurfaceOperationResult> executeSurfaceOperation(
    ShapeHandle surface,
    String operation,
    Map<String, dynamic> parameters, {
    required String projectId,
  });
  Future<void> rollbackSurfaceOperation(String undoToken);
}

/// Adds redo without changing existing SurfaceOperationKernelAPI implementers.
abstract interface class ReversibleSurfaceOperationKernelAPI
    implements SurfaceOperationKernelAPI {
  Future<void> redoSurfaceOperation(String redoToken);
}

abstract interface class MeshGeometryKernelAPI {
  Future<KernelMeshHandle> importStl(
    String path, {
    required String projectId,
    KernelImportFormat format = KernelImportFormat.autoDetect,
    KernelCancellationToken cancellation = const NoKernelCancellation(),
    void Function(KernelProgress progress)? onProgress,
  });
  Future<void> closeMesh(KernelMeshHandle handle);
  Future<KernelMeshGeometry> inspectMesh(KernelMeshHandle handle);
}

class KernelProgress {
  const KernelProgress(this.operation, this.fraction, this.message);
  final String operation, message;
  final double fraction;
}

class GeometryDiagnostic {
  const GeometryDiagnostic({
    required this.code,
    required this.message,
    required this.severity,
    this.shapeId,
    this.metadata = const {},
  });
  final String code, message, severity;
  final String? shapeId;
  final Map<String, dynamic> metadata;
}

class HealingProposal {
  const HealingProposal({
    required this.id,
    required this.operation,
    required this.reason,
    required this.diagnostics,
    this.metadata = const {},
  });
  final String id, operation, reason;
  final List<GeometryDiagnostic> diagnostics;
  final Map<String, dynamic> metadata;
}

class KernelMeshResult {
  const KernelMeshResult({
    required this.source,
    required this.vertexCount,
    required this.triangleCount,
    required this.payloadPath,
  });
  final ShapeHandle source;
  final int vertexCount, triangleCount;
  final String payloadPath;
}

abstract interface class KernelCancellationToken {
  bool get isCancelled;
}

class NoKernelCancellation implements KernelCancellationToken {
  const NoKernelCancellation();
  @override
  bool get isCancelled => false;
}
