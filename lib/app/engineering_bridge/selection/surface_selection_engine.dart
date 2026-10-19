import '../../../core/cad_kernel/io/kernel_io_models.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../contracts/bridge_selection.dart';
import 'mesh_bvh.dart';
import 'mesh_hit_testing.dart';
import 'surface_selection_policy.dart';

/// Result of evaluating one selection gesture sample.
final class SurfaceSelectionResult {
  const SurfaceSelectionResult({
    required this.triangles,
    required this.spatialCandidates,
    required this.volumeCandidates,
    required this.visibleCandidates,
    required this.occludedCandidates,
    required this.backfaceCandidates,
  });

  final Set<int> triangles;
  final int spatialCandidates;
  final int volumeCandidates;
  final int visibleCandidates;
  final int occludedCandidates;
  final int backfaceCandidates;

  int get selectedCount => triangles.length;
}

/// Evaluates a tool volume against the original mesh and applies the
/// independent visibility and connectivity policies.
///
/// Visibility is resolved against the durable mesh BVH, never the presentation
/// LOD. A candidate is visible only when it is front-facing and the first
/// triangle hit by a camera-to-centroid ray is that same triangle. Through
/// mesh mode skips the visibility filter; depth is still bounded by the tool
/// volume. Connected-surface mode then keeps only the adjacency-connected
/// component containing [seedTriangle].
final class SurfaceSelectionEngine {
  const SurfaceSelectionEngine({this.maxSpatialCandidates = 8192});

  final int maxSpatialCandidates;

  SurfaceSelectionResult collect({
    required KernelMeshGeometry geometry,
    required MeshBvh bvh,
    required SelectionToolGeometry tool,
    required int seedTriangle,
    required Vector3 cameraOrigin,
    required SelectionVisibilityPolicy visibility,
    required SelectionConnectivityPolicy connectivity,
    required Set<int> Function(int triangle) neighborsOf,
  }) {
    final spatial = tool.query(bvh);
    if (spatial.length > maxSpatialCandidates) {
      throw StateError(
        'O pincel atinge ${spatial.length} triângulos candidatos; '
        'reduza o diâmetro para manter a pintura responsiva.',
      );
    }

    final volume = <int>{seedTriangle};
    for (final triangle in spatial) {
      if (triangle == seedTriangle || tool.contains(geometry, triangle)) {
        volume.add(triangle);
      }
    }

    var visible = 0;
    var occluded = 0;
    var backface = 0;
    var selected = <int>{};
    if (visibility == SelectionVisibilityPolicy.throughMesh) {
      selected = volume;
    } else {
      selected.add(seedTriangle);
      visible = 1;
      for (final triangle in volume) {
        if (triangle == seedTriangle) continue;
        switch (_visibility(geometry, bvh, triangle, cameraOrigin)) {
          case _CandidateVisibility.visible:
            selected.add(triangle);
            visible++;
          case _CandidateVisibility.occluded:
            occluded++;
          case _CandidateVisibility.backface:
            backface++;
        }
      }
    }

    if (connectivity == SelectionConnectivityPolicy.connectedSurface) {
      selected = _connected(selected, seedTriangle, neighborsOf);
    }

    return SurfaceSelectionResult(
      triangles: selected,
      spatialCandidates: spatial.length,
      volumeCandidates: volume.length,
      visibleCandidates: visible,
      occludedCandidates: occluded,
      backfaceCandidates: backface,
    );
  }

  _CandidateVisibility _visibility(
    KernelMeshGeometry geometry,
    MeshBvh bvh,
    int triangle,
    Vector3 cameraOrigin,
  ) {
    final centroid = triangleCentroid(geometry, triangle);
    final toCamera = cameraOrigin - centroid;
    if (toCamera.length <= 1e-12) return _CandidateVisibility.occluded;
    if (triangleNormal(geometry, triangle).dot(toCamera) <= 0) {
      return _CandidateVisibility.backface;
    }
    final ray = MeshRay(cameraOrigin, (centroid - cameraOrigin).normalized);
    final near = bvh.query(ray);
    if (near.isEmpty) return _CandidateVisibility.occluded;
    final selection = BridgeSelection(
      id: 'selection:visibility',
      kind: BridgeSelectionKind.triangle,
      geometry: geometry,
      triangleIndices: near,
    );
    final hit = const MeshHitTesting().hit(selection, ray);
    return hit?.triangleIndex == triangle
        ? _CandidateVisibility.visible
        : _CandidateVisibility.occluded;
  }

  Set<int> _connected(
    Set<int> candidates,
    int seedTriangle,
    Set<int> Function(int triangle) neighborsOf,
  ) {
    if (!candidates.contains(seedTriangle)) return const <int>{};
    final visited = <int>{seedTriangle};
    final pending = <int>[seedTriangle];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      for (final neighbor in neighborsOf(current)) {
        if (candidates.contains(neighbor) && visited.add(neighbor)) {
          pending.add(neighbor);
        }
      }
    }
    return visited;
  }
}

enum _CandidateVisibility { visible, occluded, backface }
