import '../../../core/cad_document/cad_document.dart';
import '../../../core/cad_kernel/io/kernel_io_models.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../../../core/geometric_kernel/linear_algebra/matrices.dart';
import '../../runtime/cad_runtime.dart';
import '../contracts/bridge_selection.dart';
import 'mesh_bvh.dart';
import 'mesh_hit_testing.dart';

typedef TechnicalStlGeometryLoader =
    Future<KernelMeshGeometry?> Function(String entityId);
typedef TechnicalStlEntityProvider =
    CadDocumentEntity? Function(String entityId);

/// A hit on the durable STL mesh, never on its display LOD.
final class TechnicalStlHit {
  const TechnicalStlHit({
    required this.entityId,
    required this.triangleIndex,
    required this.point,
    required this.localPoint,
    required this.normal,
    required this.localNormal,
    required this.distance,
    required this.geometryRevision,
    required this.geometry,
    required this.worldToLocal,
  });

  final String entityId;
  final int triangleIndex;
  final Vector3 point, localPoint, normal, localNormal;
  final double distance;
  final String geometryRevision;
  final KernelMeshGeometry geometry;
  final Matrix4 worldToLocal;
}

/// Resolves technical picks against a managed STL's complete mesh.
///
/// This service is deliberately not connected to recognition yet. It reuses
/// [MeshBvh] and [MeshHitTesting], while the managed runtime remains the sole
/// owner of the native mesh asset.
final class TechnicalStlPickResolver {
  TechnicalStlPickResolver(
    CadRuntime? runtime, {
    this.maxCachedMeshes = 2,
    this.maxTriangles = 2000000,
    TechnicalStlGeometryLoader? geometryLoader,
    TechnicalStlEntityProvider? entityProvider,
  }) : _geometryLoader =
           geometryLoader ??
           (runtime?.managedMeshGeometryFor ??
               (throw ArgumentError('runtime or geometryLoader is required'))),
       _entityProvider =
           entityProvider ??
           (runtime == null
               ? (throw ArgumentError('runtime or entityProvider is required'))
               : ((entityId) => runtime.document?.entities[entityId]));

  final TechnicalStlGeometryLoader _geometryLoader;
  final TechnicalStlEntityProvider _entityProvider;
  final int maxCachedMeshes;
  final int maxTriangles;
  final Map<String, _TechnicalStlCacheEntry> _cache = {};
  final Map<String, int> _requests = {};
  int _clock = 0;

  int get cachedMeshCount => _cache.length;

  /// Resolves a world-space ray. Managed placements are applied automatically
  /// unless [localToWorld] is supplied explicitly by the caller.
  Future<TechnicalStlHit?> resolve({
    required String entityId,
    required MeshRay worldRay,
    Matrix4? localToWorld,
  }) async {
    final entity = _entityProvider(entityId);
    final assets = entity?.data['managedStlAssets'];
    if (entity == null || entity.kind != CadDocumentEntityKind.import) {
      invalidate(entityId);
      return null;
    }
    if (assets is! Map || assets['displayMeshSha256'] is! String) {
      invalidate(entityId);
      return null;
    }
    if (!_finiteRay(worldRay)) return null;

    final revision = '${assets['displayMeshSha256']}:${entity.id}';
    final request = (_requests[entityId] ?? 0) + 1;
    _requests[entityId] = request;
    _removeStaleEntityEntries(entityId, revision);
    var entry = _cache['$entityId:$revision'];
    if (entry == null) {
      final geometry = await _geometryLoader(entityId);
      if (!_isCurrent(entityId, request)) return null;
      if (!_hasRevision(entityId, revision)) {
        invalidate(entityId);
        return null;
      }
      if (geometry == null || !_validGeometry(geometry)) return null;
      final triangleCount = geometry.triangles.length ~/ 3;
      if (triangleCount > maxTriangles) return null;
      entry = _TechnicalStlCacheEntry(
        geometryRevision: revision,
        geometry: geometry,
        bvh: MeshBvh(geometry),
        lastUsed: ++_clock,
      );
      _cache['$entityId:$revision'] = entry;
      _evictIfNeeded(protectedKey: '$entityId:$revision');
    } else {
      entry.lastUsed = ++_clock;
    }
    if (!_isCurrent(entityId, request)) return null;
    if (!_hasRevision(entityId, revision)) {
      invalidate(entityId);
      return null;
    }
    final currentEntity = _entityProvider(entityId);
    if (currentEntity == null) {
      invalidate(entityId);
      return null;
    }

    final placement =
        localToWorld ?? currentEntity.placement?.matrix ?? Matrix4.identity();
    final inverse = placement.inverse();
    final localOrigin = inverse.transformPoint(worldRay.origin);
    final localDirection = _transformDirection(inverse, worldRay.direction);
    if (localDirection.length <= 1e-12) return null;
    final localHit = const MeshHitTesting().hit(
      entry.bvh.candidates(
        BridgeSelection(
          id: '$entityId:original',
          entityId: entityId,
          kind: BridgeSelectionKind.triangle,
          geometry: entry.geometry,
          triangleIndices: const {},
        ),
        MeshRay(localOrigin, localDirection),
      ),
      MeshRay(localOrigin, localDirection),
    );
    if (localHit == null || localHit.triangleIndex < 0) {
      return null;
    }
    final offset = localHit.triangleIndex * 3;
    if (offset + 2 >= entry.geometry.triangles.length) return null;
    final a = _vertex(entry.geometry, entry.geometry.triangles[offset]);
    final b = _vertex(entry.geometry, entry.geometry.triangles[offset + 1]);
    final c = _vertex(entry.geometry, entry.geometry.triangles[offset + 2]);
    final localNormal = (b - a).cross(c - a).normalized;
    if (localNormal.length <= 1e-12) return null;
    final worldPoint = placement.transformPoint(localHit.point);
    final worldNormal = _transformDirection(placement, localNormal).normalized;
    if (!_isCurrent(entityId, request) || worldNormal.length <= 1e-12) {
      return null;
    }
    return TechnicalStlHit(
      entityId: entityId,
      triangleIndex: localHit.triangleIndex,
      point: worldPoint,
      localPoint: localHit.point,
      normal: worldNormal,
      localNormal: localNormal,
      distance: localHit.distance,
      geometryRevision: entry.geometryRevision,
      geometry: entry.geometry,
      worldToLocal: inverse,
    );
  }

  /// Returns the cached durable mesh and BVH for [entityId]. The resolver
  /// already owns the original-mesh BVH used for technical picking, so brush
  /// and future selection tools can reuse it instead of building a duplicate.
  ({KernelMeshGeometry geometry, MeshBvh bvh, String revision})? cachedMesh(
    String entityId,
  ) {
    final entity = _entityProvider(entityId);
    final assets = entity?.data['managedStlAssets'];
    if (entity == null ||
        entity.kind != CadDocumentEntityKind.import ||
        assets is! Map ||
        assets['displayMeshSha256'] is! String) {
      return null;
    }
    final revision = '${assets['displayMeshSha256']}:$entityId';
    final entry = _cache['$entityId:$revision'];
    if (entry == null) return null;
    entry.lastUsed = ++_clock;
    return (
      geometry: entry.geometry,
      bvh: entry.bvh,
      revision: entry.geometryRevision,
    );
  }

  /// Invalidates all cached geometry and pending results for [entityId].
  void invalidate(String entityId) {
    _requests[entityId] = (_requests[entityId] ?? 0) + 1;
    _cache.removeWhere((key, _) => key.startsWith('$entityId:'));
  }

  /// Clears all cache entries and logically cancels all pending requests.
  void clear() {
    for (final entityId in _requests.keys.toList()) {
      _requests[entityId] = (_requests[entityId] ?? 0) + 1;
    }
    _cache.clear();
  }

  bool _isCurrent(String entityId, int request) =>
      _requests[entityId] == request;

  bool _hasRevision(String entityId, String revision) {
    final entity = _entityProvider(entityId);
    final assets = entity?.data['managedStlAssets'];
    if (entity == null ||
        entity.kind != CadDocumentEntityKind.import ||
        assets is! Map) {
      return false;
    }
    return '${assets['displayMeshSha256']}:${entity.id}' == revision;
  }

  void _removeStaleEntityEntries(String entityId, String revision) {
    _cache.removeWhere(
      (key, _) => key.startsWith('$entityId:') && key != '$entityId:$revision',
    );
  }

  void _evictIfNeeded({required String protectedKey}) {
    while (_cache.length > maxCachedMeshes) {
      final candidates =
          _cache.entries.where((entry) => entry.key != protectedKey).toList()
            ..sort((a, b) => a.value.lastUsed.compareTo(b.value.lastUsed));
      if (candidates.isEmpty) {
        return;
      }
      _cache.remove(candidates.first.key);
    }
  }

  bool _validGeometry(KernelMeshGeometry geometry) {
    if (geometry.nodes.isEmpty || geometry.triangles.isEmpty) return false;
    if (geometry.nodes.length % 3 != 0 || geometry.triangles.length % 3 != 0) {
      return false;
    }
    final vertexCount = geometry.nodes.length ~/ 3;
    if (geometry.nodes.any((value) => !value.isFinite)) return false;
    return geometry.triangles.every(
      (value) => value >= 0 && value < vertexCount,
    );
  }

  bool _finiteRay(MeshRay ray) => [
    ray.origin.x,
    ray.origin.y,
    ray.origin.z,
    ray.direction.x,
    ray.direction.y,
    ray.direction.z,
  ].every((value) => value.isFinite);

  Vector3 _vertex(KernelMeshGeometry geometry, int index) {
    final offset = index * 3;
    return Vector3(
      geometry.nodes[offset],
      geometry.nodes[offset + 1],
      geometry.nodes[offset + 2],
    );
  }

  Vector3 _transformDirection(Matrix4 matrix, Vector3 direction) {
    final m = matrix.values;
    return Vector3(
      m[0] * direction.x + m[1] * direction.y + m[2] * direction.z,
      m[4] * direction.x + m[5] * direction.y + m[6] * direction.z,
      m[8] * direction.x + m[9] * direction.y + m[10] * direction.z,
    );
  }
}

final class _TechnicalStlCacheEntry {
  _TechnicalStlCacheEntry({
    required this.geometryRevision,
    required this.geometry,
    required this.bvh,
    required this.lastUsed,
  });

  final String geometryRevision;
  final KernelMeshGeometry geometry;
  final MeshBvh bvh;
  int lastUsed;
}
