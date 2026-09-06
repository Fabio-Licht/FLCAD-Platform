import 'package:flutter/painting.dart';

import '../../../core/cad_kernel/io/kernel_io_models.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../../engineering_bridge/contracts/bridge_selection.dart';
import '../../engineering_bridge/selection/camera_picking.dart';
import '../../engineering_bridge/selection/mesh_bvh.dart';
import '../../engineering_bridge/selection/professional_picking_pipeline.dart';
import '../camera/cad_camera_controller.dart';
import '../scene/cad_scene_graph.dart';

class CadViewportPick {
  const CadViewportPick({required this.entityId, required this.hit});
  final String entityId;
  final MeshHit hit;
}

class ViewportPickingController {
  final Map<String, MeshBvh> _indexes = {};
  final Map<String, KernelMeshGeometry> _geometries = {};
  final Map<String, Object> _nodeSources = {};
  final Map<String, Object> _triangleSources = {};
  final ProfessionalPickingPipeline pipeline =
      const ProfessionalPickingPipeline();

  CadViewportPick? pick({
    required Offset position,
    required CadCameraController camera,
    required CadSceneGraph scene,
  }) {
    CadViewportPick? nearest;
    for (final entity in scene.entities.where(
      (item) =>
          item.visible &&
          const {
            CadSceneEntityKind.mesh,
            CadSceneEntityKind.surface,
            CadSceneEntityKind.solid,
          }.contains(item.kind) &&
          item.geometry['nodes'] is List &&
          item.geometry['triangles'] is List,
    )) {
      final nodes = (entity.geometry['nodes'] as List).cast<num>();
      final triangles = (entity.geometry['triangles'] as List).cast<num>();
      final nodesSource = entity.geometry['nodes'] as Object;
      final trianglesSource = entity.geometry['triangles'] as Object;
      if (!identical(_nodeSources[entity.id], nodesSource) ||
          !identical(_triangleSources[entity.id], trianglesSource)) {
        _geometries[entity.id] = KernelMeshGeometry(
          nodes: nodes.map((value) => value.toDouble()).toList(growable: false),
          triangles: triangles
              .map((value) => value.toInt())
              .toList(growable: false),
        );
        _nodeSources[entity.id] = nodesSource;
        _triangleSources[entity.id] = trianglesSource;
        _indexes.remove(entity.id);
      }
      final geometry = _geometries[entity.id]!;
      if (triangles.isEmpty) continue;
      final index = _indexes.putIfAbsent(entity.id, () => MeshBvh(geometry));
      final selection = BridgeSelection(
        id: '${entity.id}:mesh',
        entityId: entity.id,
        kind: BridgeSelectionKind.triangle,
        geometry: geometry,
        triangleIndices: const {},
      );
      final rowMajor = camera.inverseViewProjectionMatrix.values;
      final columnMajor = [
        for (var column = 0; column < 4; column++)
          for (var row = 0; row < 4; row++) rowMajor[row * 4 + column],
      ];
      final hit = pipeline.pick(
        screenX: position.dx,
        screenY: position.dy,
        cameraContext: CameraPickingContext(
          viewportWidth: camera.viewportWidth,
          viewportHeight: camera.viewportHeight,
          inverseViewProjection: columnMajor,
        ),
        mesh: selection,
        spatialIndex: index,
      );
      if (hit != null &&
          (nearest == null || hit.distance < nearest.hit.distance)) {
        nearest = CadViewportPick(entityId: entity.id, hit: hit);
      }
    }
    // Screen-space references intentionally take precedence over the mesh.
    // This makes thin sketches/sections and translucent world planes usable
    // even when they are visually superimposed on an imported STL.
    return _pickReference(position, camera, scene) ?? nearest;
  }

  CadViewportPick? _pickReference(
    Offset position,
    CadCameraController camera,
    CadSceneGraph scene,
  ) {
    CadViewportPick? best;
    var bestPriority = 1 << 30;
    var bestDistance = double.infinity;
    final worldScale = _worldReferenceScale(scene, camera);

    Vector3? vector(Object? value) {
      if (value is! List || value.length < 3) return null;
      return Vector3(
        (value[0] as num).toDouble(),
        (value[1] as num).toDouble(),
        (value[2] as num).toDouble(),
      );
    }

    Offset project(Vector3 value) {
      final point = camera.viewProjectionMatrix.transformPoint(value);
      return Offset(
        (point.x + 1) * camera.viewportWidth / 2,
        (1 - point.y) * camera.viewportHeight / 2,
      );
    }

    ({double distance, double parameter}) segmentProjection(
      Offset point,
      Offset a,
      Offset b,
    ) {
      final delta = b - a;
      final squared = delta.dx * delta.dx + delta.dy * delta.dy;
      if (squared <= 1e-9) {
        return (distance: (point - a).distance, parameter: 0);
      }
      final relative = point - a;
      final t = ((relative.dx * delta.dx + relative.dy * delta.dy) / squared)
          .clamp(0.0, 1.0);
      return (distance: (point - (a + delta * t)).distance, parameter: t);
    }

    double segmentDistance(Offset point, Offset a, Offset b) {
      return segmentProjection(point, a, b).distance;
    }

    void consider(
      CadSceneEntity entity,
      int priority,
      double screenDistance,
      Vector3 worldPoint,
    ) {
      if (screenDistance > 9) return;
      if (priority > bestPriority ||
          (priority == bestPriority && screenDistance >= bestDistance)) {
        return;
      }
      bestPriority = priority;
      bestDistance = screenDistance;
      best = CadViewportPick(
        entityId: entity.id,
        hit: MeshHit(
          triangleIndex: -1,
          point: worldPoint,
          distance: (worldPoint - camera.eye).length,
        ),
      );
    }

    for (final entity in scene.entities.where((item) => item.visible)) {
      final priority = switch (entity.kind) {
        CadSceneEntityKind.sketch || CadSceneEntityKind.curve => 0,
        CadSceneEntityKind.plane => 1,
        CadSceneEntityKind.axis || CadSceneEntityKind.point => 2,
        _ => 10,
      };
      if (priority == 10) continue;

      final rawSegments = entity.geometry['segments'];
      if (rawSegments is List) {
        for (final raw in rawSegments.whereType<List>()) {
          if (raw.length < 2) continue;
          final a = vector(raw[0]), b = vector(raw[1]);
          if (a == null || b == null) continue;
          final projection = segmentProjection(
            position,
            project(a),
            project(b),
          );
          consider(
            entity,
            priority,
            projection.distance,
            a + (b - a) * projection.parameter,
          );
        }
        continue;
      }

      final rawPoints = entity.geometry['points'];
      if (rawPoints is List) {
        final points = rawPoints.map(vector).whereType<Vector3>().toList();
        if (entity.geometry['pickOnlyClosedProfile'] == true &&
            points.length >= 3) {
          final polygon = Path()
            ..addPolygon(points.map(project).toList(), true);
          if (polygon.contains(position)) {
            consider(entity, -2, 0, points.first);
          }
        }
        if (entity.kind == CadSceneEntityKind.sketch &&
            entity.geometry['showEndpoints'] == true &&
            points.isNotEmpty) {
          for (final endpoint in {points.first, points.last}) {
            consider(
              entity,
              -1,
              (position - project(endpoint)).distance,
              endpoint,
            );
          }
        }
        for (var i = 1; i < points.length; i++) {
          final a = points[i - 1], b = points[i];
          final projection = segmentProjection(
            position,
            project(a),
            project(b),
          );
          consider(
            entity,
            priority,
            projection.distance,
            a + (b - a) * projection.parameter,
          );
        }
        continue;
      }

      final pointPosition = vector(entity.geometry['position']);
      if (entity.kind == CadSceneEntityKind.point && pointPosition != null) {
        consider(
          entity,
          priority,
          (position - project(pointPosition)).distance,
          pointPosition,
        );
        continue;
      }

      final origin = vector(entity.geometry['origin']);
      if (origin == null) continue;
      final isWorld = entity.id.contains(':world:');
      if (entity.kind == CadSceneEntityKind.plane) {
        final normal = vector(entity.geometry['normal'])?.normalized;
        if (normal == null) continue;
        final preferred = vector(entity.geometry['xDirection']);
        final x =
            preferred ??
            normal
                .cross(
                  normal.z.abs() < .9
                      ? const Vector3(0, 0, 1)
                      : const Vector3(0, 1, 0),
                )
                .normalized;
        final y = normal.cross(x).normalized;
        final visualSize = isWorld
            ? worldScale * 1.16
            : (entity.geometry['visualSize'] as num?)?.toDouble() ?? 60;
        final half = visualSize / 2;
        final path = Path()
          ..addPolygon(
            [
              origin - x * half - y * half,
              origin + x * half - y * half,
              origin + x * half + y * half,
              origin - x * half + y * half,
            ].map(project).toList(),
            true,
          );
        if (path.contains(position)) consider(entity, priority, 0, origin);
      } else if (entity.kind == CadSceneEntityKind.axis) {
        final direction = vector(entity.geometry['direction'])?.normalized;
        if (direction == null) continue;
        final length = isWorld
            ? worldScale
            : (entity.geometry['visualLength'] as num?)?.toDouble() ?? 30;
        consider(
          entity,
          priority,
          segmentDistance(
            position,
            project(isWorld ? origin : origin - direction * (length / 2)),
            project(
              isWorld
                  ? origin + direction * length
                  : origin + direction * (length / 2),
            ),
          ),
          origin,
        );
      } else {
        consider(
          entity,
          priority,
          (position - project(origin)).distance,
          origin,
        );
      }
    }
    return best;
  }

  double _worldReferenceScale(CadSceneGraph scene, CadCameraController camera) {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (final entity in scene.entities.where(
      (item) => item.visible && !item.id.contains(':world:'),
    )) {
      final nodes = entity.geometry['nodes'];
      if (nodes is! List) continue;
      for (var i = 0; i + 2 < nodes.length; i += 3) {
        final x = (nodes[i] as num).toDouble();
        final y = (nodes[i + 1] as num).toDouble();
        final z = (nodes[i + 2] as num).toDouble();
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (z < minZ) minZ = z;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
        if (z > maxZ) maxZ = z;
      }
    }
    if (minX.isFinite && maxX.isFinite) {
      final diagonal = Vector3(maxX - minX, maxY - minY, maxZ - minZ).length;
      if (diagonal > 1e-9) return diagonal * .12;
    }
    final distance = (camera.eye - camera.target).length;
    // Must match the renderer fallback exactly: a plane that is visible must
    // expose the same hit area, including in an otherwise empty project.
    return (distance * .32).clamp(1.0, double.infinity).toDouble();
  }

  Vector3? pointOnPlane({
    required Offset position,
    required CadCameraController camera,
    required Vector3 origin,
    required Vector3 normal,
  }) {
    if (camera.viewportWidth <= 0 || camera.viewportHeight <= 0) return null;
    final unitNormal = normal.normalized;
    final ray = pipeline.camera.ray(
      screenX: position.dx,
      screenY: position.dy,
      camera: _cameraContext(camera),
    );
    final denominator = unitNormal.dot(ray.direction);
    if (denominator.abs() < 1e-12) return null;
    final distance = unitNormal.dot(origin - ray.origin) / denominator;
    if (!distance.isFinite || distance < 0) return null;
    final hit = ray.origin + ray.direction * distance;
    return Vector3(
      hit.x.isFinite ? hit.x : origin.x,
      hit.y.isFinite ? hit.y : origin.y,
      hit.z.isFinite ? hit.z : origin.z,
    );
  }

  CameraPickingContext _cameraContext(CadCameraController camera) {
    final rowMajor = camera.inverseViewProjectionMatrix.values;
    final columnMajor = [
      for (var column = 0; column < 4; column++)
        for (var row = 0; row < 4; row++) rowMajor[row * 4 + column],
    ];
    return CameraPickingContext(
      viewportWidth: camera.viewportWidth,
      viewportHeight: camera.viewportHeight,
      inverseViewProjection: columnMajor,
    );
  }
}
