import '../models/kernel_models.dart';
import '../io/kernel_io_models.dart';

abstract interface class GeometryKernelAPI {
  KernelDescriptor get descriptor;
  Future<KernelHealth> healthCheck();
  Future<ShapeHandle> create(
    String operation,
    Map<String, dynamic> parameters, {
    required String persistentId,
    required CADShapeType expectedType,
    required KernelTransaction transaction,
  });
  Future<List<String>> validate(ShapeHandle handle, Set<String> checks);
  Future<void> begin(KernelTransaction transaction);
  Future<void> commit(KernelTransaction transaction);
  Future<void> rollback(KernelTransaction transaction);
  Future<void> unload();
}

abstract interface class InterchangeGeometryKernelAPI
    implements GeometryKernelAPI {
  Future<ShapeHandle> importFile(
    String path,
    KernelExchangeFormat format, {
    required String projectId,
    KernelCancellationToken cancellation = const NoKernelCancellation(),
    void Function(KernelProgress progress)? onProgress,
  });
  Future<void> exportFile(
    ShapeHandle handle,
    String path,
    KernelExchangeFormat format, {
    KernelCancellationToken cancellation = const NoKernelCancellation(),
    void Function(KernelProgress progress)? onProgress,
  });
  Future<List<GeometryDiagnostic>> diagnose(ShapeHandle handle);
  Future<List<HealingProposal>> proposeHealing(ShapeHandle handle);
  Future<ShapeHandle> sew(
    List<ShapeHandle> faces, {
    required String projectId,
    required double tolerance,
  });
  Future<KernelMeshResult> mesh(
    ShapeHandle handle, {
    required String outputPath,
    required double deflection,
  });
}

/// Persists kernel-owned BREP payloads; ShapeHandle JSON is not geometry.
abstract interface class PersistentGeometryKernelAPI
    implements GeometryKernelAPI {
  Future<void> persistShape(ShapeHandle handle, String payloadPath);
  Future<ShapeHandle> restoreShape(
    String payloadPath, {
    required String persistentId,
  });
}

/// Optional native BREP presentation used by renderers that need real
/// topological edges rather than tessellation-derived contours.
abstract interface class BrepPresentationGeometryKernelAPI
    implements GeometryKernelAPI {
  /// Returns the native display payload for [handle], or null when the active
  /// host cannot expose an OCCT BREP presentation.
  Future<Map<String, dynamic>?> inspectBrepPresentation(ShapeHandle handle);
}

/// Official kernel contract for real BRep transformations.
/// Implementations must return a new kernel-owned shape; callers decide
/// whether it replaces the document entity or becomes a Working Copy.
abstract interface class ShapeTransformGeometryKernelAPI
    implements GeometryKernelAPI {
  Future<ShapeHandle> transformShape(
    ShapeHandle source,
    List<double> matrix, {
    required String projectId,
    bool copyGeometry = true,
  });
}

class UnavailableGeometryKernel implements GeometryKernelAPI {
  const UnavailableGeometryKernel();
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'none',
    name: 'No CAD Kernel',
    version: '0.0.0',
    vendor: 'FLCAD',
    capabilities: KernelCapabilities.none,
  );
  @override
  Future<KernelHealth> healthCheck() async => KernelHealth(
    KernelHealthStatus.unavailable,
    'No CAD kernel plugin installed',
    DateTime.now(),
  );
  @override
  Future<ShapeHandle> create(
    String operation,
    Map<String, dynamic> parameters, {
    required String persistentId,
    required CADShapeType expectedType,
    required KernelTransaction transaction,
  }) => throw UnsupportedError('CAD kernel operation unavailable: $operation');
  @override
  Future<List<String>> validate(ShapeHandle handle, Set<String> checks) =>
      throw UnsupportedError(
        'Geometry validation requires a CAD kernel plugin',
      );
  @override
  Future<void> begin(KernelTransaction transaction) async {}
  @override
  Future<void> commit(KernelTransaction transaction) async {}
  @override
  Future<void> rollback(KernelTransaction transaction) async {}
  @override
  Future<void> unload() async {}
}
