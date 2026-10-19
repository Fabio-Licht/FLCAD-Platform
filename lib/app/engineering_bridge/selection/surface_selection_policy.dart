import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../../../core/cad_kernel/io/kernel_io_models.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../../../core/geometric_kernel/linear_algebra/matrices.dart';
import '../contracts/bridge_selection.dart';
import 'mesh_bvh.dart';

/// How a selection gesture treats geometry that is not visible from the
/// camera. The policy is independent from the tool shape and from the
/// connectivity policy so click, window, lasso and brush tools can share it.
enum SelectionVisibilityPolicy {
  /// Front-facing triangles with an unobstructed line of sight from the
  /// camera. Occlusion is resolved against the original mesh BVH.
  visibleOnly,

  /// Every triangle inside the tool's influence volume, including hidden and
  /// back-facing triangles. Depth is bounded by the tool volume, not by the
  /// first ray hit.
  throughMesh,
}

/// How selected triangles are related to the seed triangle.
enum SelectionConnectivityPolicy {
  /// Every triangle inside the tool volume is eligible, including disjoint
  /// surfaces. Useful for explicit through-mesh selection.
  local,

  /// Only the connected component containing the seed is selected. Growth
  /// follows mesh adjacency, never Euclidean proximity across a gap.
  connectedSurface,
}

/// Geometric shape of a selection gesture. The brush uses a sphere; future
/// window and lasso tools can implement the same contract without changing
/// the visibility or connectivity policies.
sealed class SelectionToolGeometry {
  const SelectionToolGeometry();

  Set<int> query(MeshBvh bvh);

  bool contains(KernelMeshGeometry geometry, int triangle);
}

/// Spherical brush influence in the original mesh coordinate system.
final class SphereSelectionTool extends SelectionToolGeometry {
  const SphereSelectionTool({required this.center, required this.radius});

  final Vector3 center;
  final double radius;

  @override
  Set<int> query(MeshBvh bvh) =>
      bvh.querySphere(center: center, radius: radius);

  @override
  bool contains(KernelMeshGeometry geometry, int triangle) {
    final offset = triangle * 3;
    final ids = geometry.triangles;
    if (offset + 2 >= ids.length) return false;
    return distancePointToTriangle(
          center,
          pointOf(geometry, ids[offset]),
          pointOf(geometry, ids[offset + 1]),
          pointOf(geometry, ids[offset + 2]),
        ) <=
        radius;
  }
}

/// Camera-aligned brush volume for through-mesh painting.
///
/// The spatial query is the AABB of a cone (perspective) or cylinder
/// (orthographic) running from the camera ray through the active mesh bounds.
/// Exact membership is decided in screen space against the projected brush
/// circle, so hidden layers and back faces under the same projection are
/// included without scanning the whole mesh.
final class ProjectedBrushTool extends SelectionToolGeometry {
  const ProjectedBrushTool({
    required this.ray,
    required this.referencePoint,
    required this.radiusMm,
    required this.orthographic,
    required this.viewProjection,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.centerScreen,
    required this.radiusPx,
    this.localToWorld,
  });

  final MeshRay ray;
  final Vector3 referencePoint;
  final double radiusMm;
  final bool orthographic;
  final Matrix4 viewProjection;
  final Matrix4? localToWorld;
  final double viewportWidth;
  final double viewportHeight;
  final Offset centerScreen;
  final double radiusPx;

  @override
  Set<int> query(MeshBvh bvh) {
    final referenceDepth = (referencePoint - ray.origin).length;
    if (radiusMm <= 0 ||
        referenceDepth <= 1e-9 ||
        viewportWidth <= 1 ||
        viewportHeight <= 1) {
      return const <int>{};
    }
    final bounds = bvh.root.bounds;
    final farDistance = _maxDistanceToBounds(bounds, ray.origin);
    if (farDistance <= referenceDepth) {
      return bvh.querySphere(center: referencePoint, radius: radiusMm);
    }
    final farCenter = ray.origin + ray.direction * farDistance;
    final farRadius = orthographic
        ? radiusMm
        : radiusMm * (farDistance / referenceDepth);
    final Vector3 minimum;
    final Vector3 maximum;
    if (orthographic) {
      minimum = Vector3(
        math.min(ray.origin.x - radiusMm, farCenter.x - farRadius),
        math.min(ray.origin.y - radiusMm, farCenter.y - farRadius),
        math.min(ray.origin.z - radiusMm, farCenter.z - farRadius),
      );
      maximum = Vector3(
        math.max(ray.origin.x + radiusMm, farCenter.x + farRadius),
        math.max(ray.origin.y + radiusMm, farCenter.y + farRadius),
        math.max(ray.origin.z + radiusMm, farCenter.z + farRadius),
      );
    } else {
      minimum = Vector3(
        math.min(ray.origin.x, farCenter.x - farRadius),
        math.min(ray.origin.y, farCenter.y - farRadius),
        math.min(ray.origin.z, farCenter.z - farRadius),
      );
      maximum = Vector3(
        math.max(ray.origin.x, farCenter.x + farRadius),
        math.max(ray.origin.y, farCenter.y + farRadius),
        math.max(ray.origin.z, farCenter.z + farRadius),
      );
    }
    return bvh.queryBox(min: minimum, max: maximum);
  }

  @override
  bool contains(KernelMeshGeometry geometry, int triangle) {
    final offset = triangle * 3;
    if (offset + 2 >= geometry.triangles.length) return false;
    final a = _project(geometry, geometry.triangles[offset]);
    final b = _project(geometry, geometry.triangles[offset + 1]);
    final c = _project(geometry, geometry.triangles[offset + 2]);
    if (a == null || b == null || c == null) return false;
    return triangleIntersectsCircle(a, b, c, centerScreen, radiusPx);
  }

  Offset? _project(KernelMeshGeometry geometry, int vertex) {
    final local = pointOf(geometry, vertex);
    final world = localToWorld?.transformPoint(local) ?? local;
    final ndc = viewProjection.transformPoint(world);
    if (!ndc.x.isFinite ||
        !ndc.y.isFinite ||
        !ndc.z.isFinite ||
        ndc.z < -1 ||
        ndc.z > 1) {
      return null;
    }
    return Offset(
      (ndc.x + 1) * viewportWidth / 2,
      (1 - ndc.y) * viewportHeight / 2,
    );
  }

  static double _maxDistanceToBounds(MeshBvhBounds bounds, Vector3 origin) {
    var maximum = 0.0;
    for (final x in [bounds.min.x, bounds.max.x]) {
      for (final y in [bounds.min.y, bounds.max.y]) {
        for (final z in [bounds.min.z, bounds.max.z]) {
          maximum = math.max(maximum, (Vector3(x, y, z) - origin).length);
        }
      }
    }
    return maximum;
  }
}

bool triangleIntersectsCircle(
  Offset a,
  Offset b,
  Offset c,
  Offset center,
  double radius,
) {
  if (radius <= 0) return false;
  if ((a - center).distance <= radius ||
      (b - center).distance <= radius ||
      (c - center).distance <= radius) {
    return true;
  }
  if (_distanceToSegment(center, a, b) <= radius ||
      _distanceToSegment(center, b, c) <= radius ||
      _distanceToSegment(center, c, a) <= radius) {
    return true;
  }
  return _pointInTriangle(center, a, b, c);
}

double _distanceToSegment(Offset point, Offset a, Offset b) {
  final delta = b - a;
  final lengthSquared = delta.dx * delta.dx + delta.dy * delta.dy;
  if (lengthSquared <= 1e-18) return (point - a).distance;
  final t =
      (((point.dx - a.dx) * delta.dx + (point.dy - a.dy) * delta.dy) /
              lengthSquared)
          .clamp(0.0, 1.0)
          .toDouble();
  return (point - (a + delta * t)).distance;
}

bool _pointInTriangle(Offset p, Offset a, Offset b, Offset c) {
  double cross(Offset first, Offset second, Offset point) =>
      (point.dx - second.dx) * (first.dy - second.dy) -
      (first.dx - second.dx) * (point.dy - second.dy);
  final d1 = cross(a, b, p);
  final d2 = cross(b, c, p);
  final d3 = cross(c, a, p);
  final hasNegative = d1 < 0 || d2 < 0 || d3 < 0;
  final hasPositive = d1 > 0 || d2 > 0 || d3 > 0;
  return !(hasNegative && hasPositive);
}

Vector3 pointOf(KernelMeshGeometry geometry, int vertex) {
  final offset = vertex * 3;
  return Vector3(
    geometry.nodes[offset],
    geometry.nodes[offset + 1],
    geometry.nodes[offset + 2],
  );
}

Vector3 triangleCentroid(KernelMeshGeometry geometry, int triangle) {
  final offset = triangle * 3;
  final ids = geometry.triangles;
  final a = pointOf(geometry, ids[offset]);
  final b = pointOf(geometry, ids[offset + 1]);
  final c = pointOf(geometry, ids[offset + 2]);
  return (a + b + c) * (1 / 3);
}

Vector3 triangleNormal(KernelMeshGeometry geometry, int triangle) {
  final offset = triangle * 3;
  final ids = geometry.triangles;
  final a = pointOf(geometry, ids[offset]);
  final b = pointOf(geometry, ids[offset + 1]);
  final c = pointOf(geometry, ids[offset + 2]);
  final normal = (b - a).cross(c - a);
  final length = normal.length;
  return length <= 1e-12 ? const Vector3(0, 0, 1) : normal / length;
}

double triangleArea(KernelMeshGeometry geometry, int triangle) {
  final offset = triangle * 3;
  final ids = geometry.triangles;
  final a = pointOf(geometry, ids[offset]);
  final b = pointOf(geometry, ids[offset + 1]);
  final c = pointOf(geometry, ids[offset + 2]);
  return (b - a).cross(c - a).length * .5;
}

double distancePointToTriangle(
  Vector3 point,
  Vector3 a,
  Vector3 b,
  Vector3 c,
) => (point - closestPointOnTriangle(point, a, b, c)).length;

/// Closest point on a triangle, following the standard barycentric regions
/// used by triangle distance queries.
Vector3 closestPointOnTriangle(Vector3 p, Vector3 a, Vector3 b, Vector3 c) {
  final ab = b - a;
  final ac = c - a;
  final ap = p - a;
  final d1 = ab.dot(ap);
  final d2 = ac.dot(ap);
  if (d1 <= 0 && d2 <= 0) return a;

  final bp = p - b;
  final d3 = ab.dot(bp);
  final d4 = ac.dot(bp);
  if (d3 >= 0 && d4 <= d3) return b;

  final vc = d1 * d4 - d3 * d2;
  if (vc <= 0 && d1 >= 0 && d3 <= 0) {
    final v = d1 / (d1 - d3);
    return a + ab * v;
  }

  final cp = p - c;
  final d5 = ab.dot(cp);
  final d6 = ac.dot(cp);
  if (d6 >= 0 && d5 <= d6) return c;

  final vb = d5 * d2 - d1 * d6;
  if (vb <= 0 && d2 >= 0 && d6 <= 0) {
    final w = d2 / (d2 - d6);
    return a + ac * w;
  }

  final va = d3 * d6 - d5 * d4;
  if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
    final w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    return b + (c - b) * w;
  }

  final denominator = 1 / (va + vb + vc);
  final v = vb * denominator;
  final w = vc * denominator;
  return a + ab * v + ac * w;
}

double clampDouble(double value, double minimum, double maximum) =>
    math.min(maximum, math.max(minimum, value));
