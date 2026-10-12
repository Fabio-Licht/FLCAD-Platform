import 'package:flutter/painting.dart';
import 'dart:collection';

import '../../../core/cad_kernel/io/kernel_io_models.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../../engineering_bridge/contracts/bridge_selection.dart';
import '../../engineering_bridge/selection/camera_picking.dart';
import '../../engineering_bridge/selection/mesh_bvh.dart';
import '../../engineering_bridge/selection/professional_picking_pipeline.dart';
import '../camera/cad_camera_controller.dart';
import '../scene/cad_scene_graph.dart';
import '../scene/cad_scene_bounds.dart';
import '../rendering/stl_display_lod.dart';
import '../rendering/cad_canvas_normal_pipeline.dart';

// In the native interaction overlay, picking borrows canonical display arrays.
// No second complete Canvas geometry is allocated or retained for navigation.
class _DoubleView extends ListBase<double> {
  _DoubleView(this.source);
  final List<num> source;
  @override
  int get length => source.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only display view');
  @override
  double operator [](int index) => source[index].toDouble();
  @override
  void operator []=(int index, double value) =>
      throw UnsupportedError('Read-only display view');
}

class _IntView extends ListBase<int> {
  _IntView(this.source);
  final List<num> source;
  @override
  int get length => source.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only display view');
  @override
  int operator [](int index) => source[index].toInt();
  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('Read-only display view');
}

enum CadViewportSubentityKind { face, edge, vertex }

bool cadSceneEntityIsPickOnly(CadSceneEntity? entity) =>
    entity != null &&
    (entity.geometry['pickOnly'] == true ||
        entity.geometry['pickOnlyClosedProfile'] == true);

class ManagedCadFaceHighlight {
  const ManagedCadFaceHighlight({
    required this.entityId,
    required this.faceIndex,
    required this.presentationSubId,
    required this.firstTriangle,
    required this.triangleCount,
  });

  final String entityId;
  final int faceIndex;
  final int presentationSubId;

  /// Zero-based presentation triangle range. This is transient viewport state.
  final int firstTriangle;
  final int triangleCount;

  @override
  bool operator ==(Object other) =>
      other is ManagedCadFaceHighlight &&
      other.entityId == entityId &&
      other.faceIndex == faceIndex &&
      other.presentationSubId == presentationSubId &&
      other.firstTriangle == firstTriangle &&
      other.triangleCount == triangleCount;

  @override
  int get hashCode => Object.hash(
    entityId,
    faceIndex,
    presentationSubId,
    firstTriangle,
    triangleCount,
  );
}

ManagedCadFaceHighlight? managedCadFaceHighlight(
  CadSceneEntity source,
  int presentationSubId,
) {
  if (presentationSubId <= 0 ||
      source.geometry['brepPresentation'] is! Map ||
      StlDisplayLod.simplified(source.geometry)) {
    return null;
  }
  final ranges = cadPresentationGeometry(source.geometry)['faceTriangleRanges'];
  if (ranges is! List) return null;
  for (var face = 0; face < ranges.length; face++) {
    final range = ranges[face];
    if (range is! List || range.length != 2) return null;
    final first = range[0];
    final count = range[1];
    if (first is! num || count is! num) return null;
    final firstId = first.toInt();
    final triangleCount = count.toInt();
    if (first != firstId ||
        count != triangleCount ||
        firstId <= 0 ||
        triangleCount < 0) {
      return null;
    }
    if (presentationSubId >= firstId &&
        presentationSubId < firstId + triangleCount) {
      return ManagedCadFaceHighlight(
        entityId: source.id,
        faceIndex: face + 1,
        // Normalize all triangles of one face to its first presentation ID so
        // pointer motion within the face emits no redundant host delta.
        presentationSubId: firstId,
        firstTriangle: firstId - 1,
        triangleCount: triangleCount,
      );
    }
  }
  return null;
}

class CadViewportPick {
  const CadViewportPick({
    required this.entityId,
    required this.hit,
    this.subentityKind,
    this.presentationSubId,
  });
  final String entityId;
  final MeshHit hit;
  final CadViewportSubentityKind? subentityKind;

  /// Transient renderer-local ID. It must be resolved against native B-Rep
  /// before any durable command is created.
  final int? presentationSubId;
}

class ViewportPickingController {
  bool _copyMeshArrays = true;
  bool get copyMeshArrays => _copyMeshArrays;
  set copyMeshArrays(bool value) {
    if (_copyMeshArrays != value) clear();
    _copyMeshArrays = value;
  }

  int get copiedMeshCount => _geometries.values
      .where(
        (mesh) => mesh.nodes is! _DoubleView || mesh.triangles is! _IntView,
      )
      .length;
  void clear() {
    _indexes.clear();
    _geometries.clear();
    _nodeSources.clear();
    _triangleSources.clear();
  }

  /// Visibility/selection notifications must not rebuild a navigation BVH.
  void synchronize(CadSceneGraph scene) {
    for (final id in _geometries.keys.toList()) {
      final entity = scene.find(id);
      final presentation = entity == null
          ? null
          : cadPresentationGeometry(entity.geometry);
      if (entity == null ||
          !identical(_nodeSources[id], presentation?['nodes']) ||
          !identical(_triangleSources[id], presentation?['triangles'])) {
        _geometries.remove(id);
        _indexes.remove(id);
        _nodeSources.remove(id);
        _triangleSources.remove(id);
      }
    }
  }

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
    Set<String>? eligibleEntityIds,
    bool includePickOnlyProfiles = true,
  }) {
    CadViewportPick? nearest;
    for (final entity in scene.entities.where(
      (item) =>
          item.visible &&
          (eligibleEntityIds == null || eligibleEntityIds.contains(item.id)) &&
          const {
            CadSceneEntityKind.mesh,
            CadSceneEntityKind.surface,
            CadSceneEntityKind.solid,
          }.contains(item.kind) &&
          cadPresentationGeometry(item.geometry)['nodes'] is List &&
          cadPresentationGeometry(item.geometry)['triangles'] is List,
    )) {
      final presentation = cadPresentationGeometry(entity.geometry);
      final nodes = (presentation['nodes'] as List).cast<num>();
      final triangles = (presentation['triangles'] as List).cast<num>();
      final nodesSource = presentation['nodes'] as Object;
      final trianglesSource = presentation['triangles'] as Object;
      if (!identical(_nodeSources[entity.id], nodesSource) ||
          !identical(_triangleSources[entity.id], trianglesSource)) {
        _geometries[entity.id] = KernelMeshGeometry(
          nodes: copyMeshArrays
              ? nodes.map((value) => value.toDouble()).toList(growable: false)
              : _DoubleView(nodes),
          triangles: copyMeshArrays
              ? triangles.map((value) => value.toInt()).toList(growable: false)
              : _IntView(triangles),
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
        nearest = CadViewportPick(
          entityId: entity.id,
          hit: StlDisplayLod.simplified(entity.geometry)
              ? MeshHit(
                  triangleIndex: -1,
                  point: hit.point,
                  distance: hit.distance,
                )
              : hit,
        );
      }
    }
    // Screen-space references intentionally take precedence over the mesh.
    // This makes thin sketches/sections and translucent world planes usable
    // even when they are visually superimposed on an imported STL.
    return _pickReference(
          position,
          camera,
          scene,
          eligibleEntityIds: eligibleEntityIds,
          includePickOnlyProfiles: includePickOnlyProfiles,
        ) ??
        nearest;
  }

  CadViewportPick? _pickReference(
    Offset position,
    CadCameraController camera,
    CadSceneGraph scene, {
    Set<String>? eligibleEntityIds,
    bool includePickOnlyProfiles = true,
  }) {
    CadViewportPick? best;
    var bestPriority = 1 << 30;
    var bestDistance = double.infinity;
    CadSceneEntity? pickOnlyProfile;
    Vector3? pickOnlyWorld;
    final worldScale = cadReferencePresentationScale(scene, camera);

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

    for (final entity in scene.entities.where(
      (item) =>
          item.visible &&
          (eligibleEntityIds == null || eligibleEntityIds.contains(item.id)),
    )) {
      final pickOnly = cadSceneEntityIsPickOnly(entity);
      if (pickOnly && !includePickOnlyProfiles) continue;
      final priority = switch (entity.kind) {
        CadSceneEntityKind.sketch || CadSceneEntityKind.curve => 0,
        CadSceneEntityKind.plane => 1,
        CadSceneEntityKind.axis ||
        CadSceneEntityKind.point ||
        CadSceneEntityKind.coordinateSystem => 2,
        _ => 10,
      };
      if (priority == 10) continue;

      final rawSegments = entity.geometry['segments'];
      if (rawSegments is List && rawSegments.isNotEmpty) {
        if (pickOnly) continue;
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
        if (pickOnly) {
          if (includePickOnlyProfiles &&
              entity.geometry['pickOnlyClosedProfile'] == true &&
              points.length >= 3) {
            final polygon = Path()
              ..addPolygon(points.map(project).toList(), true);
            if (polygon.contains(position)) {
              // Apply after painted geometry so children (0 / -1) win. Still
              // displaces world planes (1) so Extrude keeps the closed
              // profile in empty interior.
              pickOnlyProfile = entity;
              pickOnlyWorld = points.first;
            }
          }
          continue;
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
        final visualSize = worldScale * 2;
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
        final length = worldScale * 2;
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
      } else if (entity.kind == CadSceneEntityKind.coordinateSystem) {
        final xAxis = vector(entity.geometry['xAxis'])?.normalized;
        final yAxis = vector(entity.geometry['yAxis'])?.normalized;
        final zAxis = vector(entity.geometry['zAxis'])?.normalized;
        if (xAxis == null || yAxis == null || zAxis == null) continue;
        final length = worldScale * 2;
        for (final direction in [xAxis, yAxis, zAxis]) {
          consider(
            entity,
            priority,
            segmentDistance(
              position,
              project(origin),
              project(origin + direction * length),
            ),
            origin,
          );
        }
      } else {
        consider(
          entity,
          priority,
          (position - project(origin)).distance,
          origin,
        );
      }
    }
    // Painted sketch/curve/endpoints already won (priority <= 0). Otherwise
    // the closed profile replaces a world plane so Extrude still hits.
    if (pickOnlyProfile != null &&
        pickOnlyWorld != null &&
        (best == null || bestPriority > 0)) {
      consider(pickOnlyProfile, 0, 0, pickOnlyWorld);
    }
    return best;
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

  /// Resolves reconstruction-suggestion hover for Canvas and native GPU.
  ///
  /// Three candidate-filter cases:
  /// - `null`: feature unused. Unrestricted overlay pick of painted
  ///   geometry (not pick-only), via [generalHit] / [fallbackEligibleEntityIds].
  /// - empty `{}`: do not steal hits and do not fall through to mesh,
  ///   Section, or unrelated bodies. Hover misses (clear overlay).
  /// - non-empty: pick only those IDs (`includePickOnlyProfiles: false`).
  CadViewportPick? pickSuggestionHover({
    required Offset position,
    required CadCameraController camera,
    required CadSceneGraph scene,
    Set<String>? suggestionCandidateIds,
    Set<String>? fallbackEligibleEntityIds,
    CadViewportPick? generalHit,
  }) {
    if (suggestionCandidateIds != null) {
      return pick(
        position: position,
        camera: camera,
        scene: scene,
        eligibleEntityIds: suggestionCandidateIds,
        includePickOnlyProfiles: false,
      );
    }
    if (generalHit != null &&
        !cadSceneEntityIsPickOnly(scene.find(generalHit.entityId))) {
      return generalHit;
    }
    return pick(
      position: position,
      camera: camera,
      scene: scene,
      eligibleEntityIds: fallbackEligibleEntityIds,
      includePickOnlyProfiles: false,
    );
  }
}
