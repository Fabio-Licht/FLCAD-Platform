import '../io/kernel_io_models.dart';
import '../models/kernel_models.dart';

/// Boundary of the native OCCT host. Native tokens are private to this module.
abstract interface class OpenCascadeNativeBridge {
  Future<void> initialize();
  Future<void> shutdown();
  Future<String> version();
  Future<Set<String>> capabilities();
  Future<Map<String, dynamic>> diagnostics();
  Future<OpenCascadeNativeShape> createShape(
    String operation,
    Map<String, dynamic> parameters,
    CADShapeType expectedType,
  );
  Future<void> destroyShape(String nativeToken);
  Future<OpenCascadeNativeShape> transformShape(
    String nativeToken,
    List<double> matrix, {
    bool copyGeometry = true,
  });
  Future<OpenCascadeNativeShape> importShape(
    String path,
    KernelExchangeFormat format, {
    required KernelCancellationToken cancellation,
    void Function(KernelProgress progress)? onProgress,
  });
  Future<void> exportShape(
    String nativeToken,
    String path,
    KernelExchangeFormat format, {
    required KernelCancellationToken cancellation,
    void Function(KernelProgress progress)? onProgress,
  });
  Future<List<GeometryDiagnostic>> validate(String nativeToken);
  Future<List<HealingProposal>> proposeHealing(String nativeToken);
  Future<OpenCascadeNativeShape> sew(
    List<String> nativeTokens,
    double tolerance,
  );
  Future<KernelMeshData> mesh(
    String nativeToken,
    String outputPath,
    double deflection,
  );
  Future<Map<String, dynamic>> inspectSurfaceTopology(String nativeToken);
  Future<Map<String, dynamic>> intersectSurfaces(
    String firstToken,
    String secondToken,
  );
  Future<Map<String, dynamic>> inspectSurfaceQuality(
    String nativeToken, {
    required List<double> draftDirection,
    required int samples,
  });
}

abstract interface class OpenCascadeMeshNativeBridge {
  Future<OpenCascadeNativeMesh> importStl(
    String path,
    KernelImportFormat format, {
    required KernelCancellationToken cancellation,
    void Function(KernelProgress progress)? onProgress,
  });
  Future<void> destroyMesh(String nativeToken);
  Future<KernelMeshGeometry> inspectMesh(
    String nativeToken, {
    required int vertexCount,
    required int triangleCount,
  });
}

/// Trusted allocation seam for custody tests and future managed mesh producers.
/// No existing STL/import or display producer is migrated by 2B1A.
abstract interface class OpenCascadeManagedMeshNativeBridge {
  Future<OpenCascadeNativeMesh> createManagedMesh();
  Future<void> destroyMesh(String nativeToken);
}

/// Optional OCCT bridge extension for professional surface operators.
abstract interface class OpenCascadeSurfaceNativeBridge {
  Future<OpenCascadeNativeShape> executeSurfaceOperation(
    String operation, {
    String? sourceToken,
    List<String> referenceTokens = const [],
    List<double> values = const [],
  });
}

class OpenCascadeNativeMesh {
  const OpenCascadeNativeMesh({
    required this.token,
    required this.fingerprint,
    required this.vertexCount,
    required this.triangleCount,
    required this.bounds,
    required this.hasNormals,
    this.degenerateTriangleCount = 0,
  });
  final String token, fingerprint;
  final int vertexCount, triangleCount;
  final KernelBounds bounds;
  final bool hasNormals;
  final int degenerateTriangleCount;
}

class OpenCascadeNativeShape {
  const OpenCascadeNativeShape({
    required this.token,
    required this.type,
    required this.fingerprint,
    this.metadata = const {},
  });
  final String token, fingerprint;
  final CADShapeType type;
  final Map<String, dynamic> metadata;
}

class KernelMeshData {
  const KernelMeshData(this.vertexCount, this.triangleCount, this.payloadPath);
  final int vertexCount, triangleCount;
  final String payloadPath;
}

class UnavailableOpenCascadeBridge implements OpenCascadeNativeBridge {
  const UnavailableOpenCascadeBridge([
    this.reason = 'OpenCascade native host is not installed',
  ]);
  final String reason;
  Never _fail() => throw StateError(reason);
  @override
  Future<void> initialize() async => _fail();
  @override
  Future<void> shutdown() async {}
  @override
  Future<String> version() async => _fail();
  @override
  Future<Set<String>> capabilities() async => const {};
  @override
  Future<Map<String, dynamic>> diagnostics() async => {
    'available': false,
    'reason': reason,
  };
  @override
  Future<OpenCascadeNativeShape> createShape(
    String operation,
    Map<String, dynamic> parameters,
    CADShapeType expectedType,
  ) async => _fail();
  @override
  Future<void> destroyShape(String nativeToken) async => _fail();
  @override
  Future<OpenCascadeNativeShape> transformShape(
    String nativeToken,
    List<double> matrix, {
    bool copyGeometry = true,
  }) async => _fail();
  @override
  Future<OpenCascadeNativeShape> importShape(
    String path,
    KernelExchangeFormat format, {
    required KernelCancellationToken cancellation,
    void Function(KernelProgress progress)? onProgress,
  }) async => _fail();
  @override
  Future<void> exportShape(
    String nativeToken,
    String path,
    KernelExchangeFormat format, {
    required KernelCancellationToken cancellation,
    void Function(KernelProgress progress)? onProgress,
  }) async => _fail();
  @override
  Future<List<GeometryDiagnostic>> validate(String nativeToken) async =>
      _fail();
  @override
  Future<List<HealingProposal>> proposeHealing(String nativeToken) async =>
      _fail();
  @override
  Future<OpenCascadeNativeShape> sew(
    List<String> nativeTokens,
    double tolerance,
  ) async => _fail();
  @override
  Future<KernelMeshData> mesh(
    String nativeToken,
    String outputPath,
    double deflection,
  ) async => _fail();
  @override
  Future<Map<String, dynamic>> inspectSurfaceTopology(
    String nativeToken,
  ) async => _fail();
  @override
  Future<Map<String, dynamic>> intersectSurfaces(
    String firstToken,
    String secondToken,
  ) async => _fail();
  @override
  Future<Map<String, dynamic>> inspectSurfaceQuality(
    String nativeToken, {
    required List<double> draftDirection,
    required int samples,
  }) async => _fail();
}
