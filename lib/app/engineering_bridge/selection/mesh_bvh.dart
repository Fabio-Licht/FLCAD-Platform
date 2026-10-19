import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/cad_kernel/io/kernel_io_models.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../contracts/bridge_selection.dart';

class MeshBvh {
  factory MeshBvh(KernelMeshGeometry geometry, {int leafSize = 32}) {
    final builder = _MeshBvhBuilder(geometry, leafSize);
    return MeshBvh._(geometry, leafSize, builder.build());
  }

  const MeshBvh._(this._geometry, this.leafSize, this.root);
  final KernelMeshGeometry _geometry;
  KernelMeshGeometry get geometry => _geometry;
  final int leafSize;
  final MeshBvhNode root;

  Set<int> query(MeshRay ray) {
    final result = <int>{};
    void visit(MeshBvhNode node) {
      if (!_intersects(node.bounds, ray)) return;
      if (node.triangles != null) {
        result.addAll(node.triangles!);
      } else {
        visit(node.left!);
        visit(node.right!);
      }
    }

    visit(root);
    return result;
  }

  Set<int> queryPlane({
    required Vector3 origin,
    required Vector3 normal,
    required double tolerance,
  }) {
    final unit = normal.normalized;
    if (unit.length == 0) throw ArgumentError('Plane normal is zero.');
    final result = <int>{};
    void visit(MeshBvhNode node) {
      if (!_planeIntersectsBounds(node.bounds, origin, unit, tolerance)) return;
      if (node.triangles != null) {
        result.addAll(node.triangles!);
      } else {
        visit(node.left!);
        visit(node.right!);
      }
    }

    visit(root);
    return result;
  }

  /// Bounded spatial query for a spherical tool (brush dab or future
  /// volumetric gesture). Returns triangle indices whose AABB intersects the
  /// sphere; callers still apply an exact distance test to the tool geometry.
  Set<int> querySphere({required Vector3 center, required double radius}) {
    if (radius <= 0) return const <int>{};
    final result = <int>{};
    void visit(MeshBvhNode node) {
      if (!_sphereIntersectsBounds(node.bounds, center, radius)) return;
      if (node.triangles != null) {
        result.addAll(node.triangles!);
      } else {
        visit(node.left!);
        visit(node.right!);
      }
    }

    visit(root);
    return result;
  }

  /// Bounded box query used by the through-mesh projected brush volume.
  Set<int> queryBox({required Vector3 min, required Vector3 max}) {
    final result = <int>{};
    void visit(MeshBvhNode node) {
      if (!_boxIntersectsBounds(node.bounds, min, max)) return;
      if (node.triangles != null) {
        result.addAll(node.triangles!);
      } else {
        visit(node.left!);
        visit(node.right!);
      }
    }

    visit(root);
    return result;
  }

  static bool _boxIntersectsBounds(
    MeshBvhBounds bounds,
    Vector3 min,
    Vector3 max,
  ) =>
      !(max.x < bounds.min.x ||
          min.x > bounds.max.x ||
          max.y < bounds.min.y ||
          min.y > bounds.max.y ||
          max.z < bounds.min.z ||
          min.z > bounds.max.z);

  static bool _sphereIntersectsBounds(
    MeshBvhBounds bounds,
    Vector3 center,
    double radius,
  ) {
    final dx = center.x < bounds.min.x
        ? bounds.min.x - center.x
        : center.x > bounds.max.x
        ? center.x - bounds.max.x
        : 0.0;
    final dy = center.y < bounds.min.y
        ? bounds.min.y - center.y
        : center.y > bounds.max.y
        ? center.y - bounds.max.y
        : 0.0;
    final dz = center.z < bounds.min.z
        ? bounds.min.z - center.z
        : center.z > bounds.max.z
        ? center.z - bounds.max.z
        : 0.0;
    return dx * dx + dy * dy + dz * dz <= radius * radius;
  }

  static bool _planeIntersectsBounds(
    MeshBvhBounds bounds,
    Vector3 origin,
    Vector3 normal,
    double tolerance,
  ) {
    final center = (bounds.min + bounds.max) * .5;
    final extent = (bounds.max - bounds.min) * .5;
    final distance = normal.dot(center - origin).abs();
    final radius =
        normal.x.abs() * extent.x +
        normal.y.abs() * extent.y +
        normal.z.abs() * extent.z;
    return distance <= radius + tolerance;
  }

  BridgeSelection candidates(BridgeSelection source, MeshRay ray) {
    final queried = query(ray);
    // An empty set is the viewport's compact representation of a whole-mesh
    // selection. It avoids allocating a million-entry Set before BVH culling.
    final found = source.triangleIndices.isEmpty
        ? queried
        : queried.intersection(source.triangleIndices);
    return BridgeSelection(
      id: source.id,
      kind: source.kind,
      geometry: _geometry,
      triangleIndices: found,
      entityId: source.entityId,
    );
  }

  static bool _intersects(MeshBvhBounds bounds, MeshRay ray) {
    var near = double.negativeInfinity, far = double.infinity;
    for (var axis = 0; axis < 3; axis++) {
      final origin = [ray.origin.x, ray.origin.y, ray.origin.z][axis];
      final direction = [
        ray.direction.x,
        ray.direction.y,
        ray.direction.z,
      ][axis];
      final minimum = [bounds.min.x, bounds.min.y, bounds.min.z][axis];
      final maximum = [bounds.max.x, bounds.max.y, bounds.max.z][axis];
      if (direction.abs() < 1e-12) {
        if (origin < minimum || origin > maximum) return false;
        continue;
      }
      var first = (minimum - origin) / direction,
          second = (maximum - origin) / direction;
      if (first > second) {
        final swap = first;
        first = second;
        second = swap;
      }
      near = math.max(near, first);
      far = math.min(far, second);
      if (near > far) return false;
    }
    return far >= math.max(near, 0);
  }
}

class _MeshBvhBuilder {
  _MeshBvhBuilder(this.geometry, this.leafSize)
    : ids = List<int>.generate(geometry.triangles.length ~/ 3, (i) => i),
      centers = Float64List(geometry.triangles.length);

  final KernelMeshGeometry geometry;
  final int leafSize;
  final List<int> ids;
  final Float64List centers;

  MeshBvhNode build() {
    if (ids.isEmpty) throw ArgumentError('BVH requires at least one triangle.');
    for (var triangle = 0; triangle < ids.length; triangle++) {
      final offset = triangle * 3;
      for (var vertex = 0; vertex < 3; vertex++) {
        final node = geometry.triangles[offset + vertex] * 3;
        centers[triangle * 3] += geometry.nodes[node] / 3;
        centers[triangle * 3 + 1] += geometry.nodes[node + 1] / 3;
        centers[triangle * 3 + 2] += geometry.nodes[node + 2] / 3;
      }
    }
    return _buildRange(0, ids.length);
  }

  MeshBvhNode _buildRange(int start, int end) {
    if (end - start <= leafSize) {
      return MeshBvhNode(
        bounds: _triangleBounds(start, end),
        triangles: List<int>.unmodifiable(ids.sublist(start, end)),
      );
    }
    final centroidBounds = _centroidBounds(start, end);
    final extents = [
      centroidBounds.max.x - centroidBounds.min.x,
      centroidBounds.max.y - centroidBounds.min.y,
      centroidBounds.max.z - centroidBounds.min.z,
    ];
    var axis = 0;
    if (extents[1] > extents[axis]) axis = 1;
    if (extents[2] > extents[axis]) axis = 2;
    final middle = (start + end) ~/ 2;
    _select(start, end - 1, middle, axis);
    final left = _buildRange(start, middle);
    final right = _buildRange(middle, end);
    return MeshBvhNode(
      bounds: _union(left.bounds, right.bounds),
      left: left,
      right: right,
    );
  }

  void _select(int left, int right, int target, int axis) {
    while (left < right) {
      final pivot = centers[ids[(left + right) ~/ 2] * 3 + axis];
      var i = left, j = right;
      while (i <= j) {
        while (centers[ids[i] * 3 + axis] < pivot) {
          i++;
        }
        while (centers[ids[j] * 3 + axis] > pivot) {
          j--;
        }
        if (i <= j) {
          final value = ids[i];
          ids[i] = ids[j];
          ids[j] = value;
          i++;
          j--;
        }
      }
      if (target <= j) {
        right = j;
      } else if (target >= i) {
        left = i;
      } else {
        return;
      }
    }
  }

  MeshBvhBounds _centroidBounds(int start, int end) {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = double.negativeInfinity,
        maxY = double.negativeInfinity,
        maxZ = double.negativeInfinity;
    for (var i = start; i < end; i++) {
      final offset = ids[i] * 3;
      final x = centers[offset],
          y = centers[offset + 1],
          z = centers[offset + 2];
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      minZ = math.min(minZ, z);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
      maxZ = math.max(maxZ, z);
    }
    return MeshBvhBounds(Vector3(minX, minY, minZ), Vector3(maxX, maxY, maxZ));
  }

  MeshBvhBounds _triangleBounds(int start, int end) {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = double.negativeInfinity,
        maxY = double.negativeInfinity,
        maxZ = double.negativeInfinity;
    for (var i = start; i < end; i++) {
      final triangle = ids[i] * 3;
      for (var j = 0; j < 3; j++) {
        final vertex = geometry.triangles[triangle + j] * 3;
        final x = geometry.nodes[vertex],
            y = geometry.nodes[vertex + 1],
            z = geometry.nodes[vertex + 2];
        minX = math.min(minX, x);
        minY = math.min(minY, y);
        minZ = math.min(minZ, z);
        maxX = math.max(maxX, x);
        maxY = math.max(maxY, y);
        maxZ = math.max(maxZ, z);
      }
    }
    return MeshBvhBounds(Vector3(minX, minY, minZ), Vector3(maxX, maxY, maxZ));
  }

  MeshBvhBounds _union(MeshBvhBounds a, MeshBvhBounds b) => MeshBvhBounds(
    Vector3(
      math.min(a.min.x, b.min.x),
      math.min(a.min.y, b.min.y),
      math.min(a.min.z, b.min.z),
    ),
    Vector3(
      math.max(a.max.x, b.max.x),
      math.max(a.max.y, b.max.y),
      math.max(a.max.z, b.max.z),
    ),
  );
}

class MeshBvhNode {
  const MeshBvhNode({
    required this.bounds,
    this.triangles,
    this.left,
    this.right,
  });
  final MeshBvhBounds bounds;
  final List<int>? triangles;
  final MeshBvhNode? left, right;
}

class MeshBvhBounds {
  const MeshBvhBounds(this.min, this.max);
  final Vector3 min, max;
}
