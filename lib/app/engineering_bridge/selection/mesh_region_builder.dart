// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:math' as math;

import '../../../core/cad_kernel/io/kernel_io_models.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../contracts/bridge_selection.dart';

class MeshRegionBuilder {
  const MeshRegionBuilder();
  MeshRegion build({
    required String meshId,
    required BridgeSelection selection,
    bool requireConnected = true,
  }) {
    if (selection.triangleIndices.isEmpty)
      throw StateError('No selected triangles.');
    final triangles = selection.geometry.triangles;
    final selected = selection.triangleIndices.toList()..sort();
    final vertices = <int>{},
        normals = <Vector3>[],
        connectivity = <int, Set<int>>{};
    var area = 0.0;
    final edgeOwners = <String, List<int>>{};
    for (final triangle in selected) {
      final offset = triangle * 3;
      if (offset + 2 >= triangles.length)
        throw RangeError('Triangle $triangle is outside kernel geometry.');
      final ids = {
        triangles[offset],
        triangles[offset + 1],
        triangles[offset + 2],
      };
      final ordered = ids.toList()..sort();
      for (final edge in [
        (ordered[0], ordered[1]),
        (ordered[0], ordered[2]),
        (ordered[1], ordered[2]),
      ]) {
        (edgeOwners['${edge.$1}:${edge.$2}'] ??= <int>[]).add(triangle);
      }
      vertices.addAll(ids);
      final p = ids.map((id) => _point(selection.geometry, id)).toList();
      final cross = (p[1] - p[0]).cross(p[2] - p[0]);
      final magnitude = math.sqrt(cross.dot(cross));
      if (magnitude == 0)
        throw StateError('Degenerate selected triangle: $triangle');
      normals.add(cross * (1 / magnitude));
      area += magnitude / 2;
    }
    for (final triangle in selected) connectivity[triangle] = <int>{};
    for (final owners in edgeOwners.values) {
      for (final first in owners) {
        for (final second in owners) {
          if (first != second) connectivity[first]!.add(second);
        }
      }
    }
    if (requireConnected && !_connected(selected, connectivity))
      throw StateError(
        'Selected triangles do not form one connected mesh region.',
      );
    final orderedVertices = vertices.toList()..sort();
    final points = orderedVertices
        .map((id) => _point(selection.geometry, id))
        .toList();
    final xs = points.map((e) => e.x),
        ys = points.map((e) => e.y),
        zs = points.map((e) => e.z);
    final bounds = KernelBounds(
      xs.reduce(math.min),
      ys.reduce(math.min),
      zs.reduce(math.min),
      xs.reduce(math.max),
      ys.reduce(math.max),
      zs.reduce(math.max),
    );
    final fingerprint =
        '$meshId:${selected.join(',')}:${orderedVertices.join(',')}';
    return MeshRegion(
      id: 'region:$fingerprint',
      meshId: meshId,
      triangleIndices: selected,
      vertexIndices: orderedVertices,
      points: points,
      normals: normals,
      bounds: bounds,
      area: area,
      connectivity: connectivity,
      fingerprint: fingerprint,
    );
  }

  Vector3 _point(KernelMeshGeometry geometry, int vertex) {
    final offset = vertex * 3;
    if (offset + 2 >= geometry.nodes.length)
      throw RangeError('Vertex $vertex is outside kernel geometry.');
    return Vector3(
      geometry.nodes[offset],
      geometry.nodes[offset + 1],
      geometry.nodes[offset + 2],
    );
  }

  bool _connected(List<int> selected, Map<int, Set<int>> graph) {
    final visited = <int>{}, pending = <int>[selected.first];
    while (pending.isNotEmpty) {
      final value = pending.removeLast();
      if (visited.add(value))
        pending.addAll(graph[value]!.where((e) => !visited.contains(e)));
    }
    return visited.length == selected.length;
  }
}
