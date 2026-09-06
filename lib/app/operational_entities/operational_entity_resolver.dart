import 'dart:isolate';

import '../../core/cad_kernel/io/kernel_io_models.dart';
import '../../core/surface_recognition/models/surface_recognition_models.dart';
import '../../core/surface_recognition/segmentation/region_growing.dart';
import '../cad_viewport/native/native_viewport_bridge.dart';
import '../cad_viewport/scene/cad_scene_graph.dart';
import 'operational_entity.dart';

class OperationalResolution {
  const OperationalResolution({
    required this.entity,
    required this.triangleIndices,
  });
  final OperationalEntity entity;
  final List<int> triangleIndices;
}

class OperationalEntityResolver {
  OperationalEntityResolver(this.registry);

  final OperationalEntityRegistry registry;
  final Map<String, _CachedMeshResolution> _meshResolutions = {};
  final Map<String, OperationalResolution> _presentations = {};

  OperationalResolution? presentation(String operationalEntityId) =>
      _presentations[operationalEntityId];

  void prepare(CadSceneGraph scene) {
    for (final entity in scene.entities) {
      if (entity.kind == CadSceneEntityKind.mesh) {
        _resolutionFor(entity);
      }
    }
  }

  void invalidate(String sceneEntityId) {
    _meshResolutions.remove(sceneEntityId);
    _presentations.removeWhere(
      (_, presentation) => presentation.entity.ownerId == sceneEntityId,
    );
    registry.replaceOwner(sceneEntityId, const []);
  }

  void clear() {
    _meshResolutions.clear();
    _presentations.clear();
  }

  Future<OperationalResolution?> resolve(
    NativeViewportPick raw,
    CadSceneGraph scene,
  ) async {
    final source = scene.find(raw.entityId);
    if (source == null || !source.visible) return null;
    if (source.kind == CadSceneEntityKind.mesh) {
      final resolution = await _resolutionFor(source);
      final triangle = raw.subId - 1;
      if (resolution == null || triangle < 0) return null;
      final region = resolution.byTriangle[triangle];
      if (region == null) return null;
      return OperationalResolution(
        entity: region.entity,
        triangleIndices: region.triangleIndices,
      );
    }
    final selectedSource = _topologySource(raw, source, scene) ?? source;
    final type = switch (raw.kind) {
      NativePickKind.edge => OperationalEntityType.topologicalEdge,
      NativePickKind.vertex => OperationalEntityType.topologicalVertex,
      NativePickKind.face => OperationalEntityType.cadFace,
      _ => switch (selectedSource.kind) {
        CadSceneEntityKind.surface => OperationalEntityType.surface,
        CadSceneEntityKind.curve => OperationalEntityType.curve,
        CadSceneEntityKind.sketch => OperationalEntityType.sketchEntity,
        CadSceneEntityKind.point => OperationalEntityType.topologicalVertex,
        _ => OperationalEntityType.cadFace,
      },
    };
    final entity = OperationalEntity(
      id: 'operational:${selectedSource.id}',
      type: type,
      ownerId: selectedSource.id,
      ownerDomain: type.name,
      documentId: selectedSource.id,
      revision: 1,
      label: selectedSource.id,
      capabilities: const {
        OperationalCapability.selectable,
        OperationalCapability.inspectable,
      },
      properties: {'sceneEntityId': selectedSource.id, 'type': type.name},
    );
    registry.replaceOwner(selectedSource.id, [entity]);
    return OperationalResolution(entity: entity, triangleIndices: const []);
  }

  Future<_MeshResolution?> _resolutionFor(CadSceneEntity source) {
    final signature = _signature(source);
    final cached = _meshResolutions[source.id];
    if (cached != null && cached.signature == signature) return cached.value;
    if (cached != null) invalidate(source.id);
    final value = _segment(source, signature);
    _meshResolutions[source.id] = _CachedMeshResolution(signature, value);
    return value;
  }

  Object _signature(CadSceneEntity source) => Object.hash(
    source.geometry['fingerprint'],
    source.geometry['revision'],
    identityHashCode(source.geometry['nodes']),
    identityHashCode(source.geometry['triangles']),
  );

  CadSceneEntity? _topologySource(
    NativeViewportPick raw,
    CadSceneEntity owner,
    CadSceneGraph scene,
  ) {
    final indexKey = switch (raw.kind) {
      NativePickKind.edge => 'surfaceEdgeIndex',
      NativePickKind.vertex => 'surfaceVertexIndex',
      _ => null,
    };
    if (indexKey == null) return null;
    return scene.entities.where((candidate) {
      return candidate.geometry['parentSurfaceId'] == owner.id &&
          candidate.geometry[indexKey] == raw.subId;
    }).firstOrNull;
  }

  Future<_MeshResolution?> _segment(
    CadSceneEntity source,
    Object signature,
  ) async {
    final rawNodes = source.geometry['nodes'];
    final rawTriangles = source.geometry['triangles'];
    if (rawNodes is! List || rawTriangles is! List) return null;
    final geometry = KernelMeshGeometry(
      nodes: rawNodes.map((value) => (value as num).toDouble()).toList(),
      triangles: rawTriangles.map((value) => (value as num).toInt()).toList(),
    );
    final fingerprint = source.geometry['fingerprint'] as String? ?? source.id;
    final result = await Isolate.run(
      () => const ProfessionalRegionGrowing().segment(
        MeshSurfaceData.fromKernel(geometry),
        fingerprint,
        settings: const SurfaceRecognitionSettings(
          normalAngleDegrees: 12,
          curvatureDelta: .10,
          minimumTriangles: 24,
        ),
      ),
    );
    final regions = <_ResolvedRegion>[];
    final byTriangle = <int, _ResolvedRegion>{};
    for (final region in result.regions) {
      final entity = OperationalEntity(
        id: 'operational:${source.id}:${region.id}',
        type: OperationalEntityType.meshRegion,
        ownerId: source.id,
        ownerDomain: 'mesh',
        documentId: source.id,
        revision: 1,
        label: 'Mesh Region ${regions.length + 1}',
        capabilities: const {
          OperationalCapability.selectable,
          OperationalCapability.measurable,
          OperationalCapability.inspectable,
          OperationalCapability.recognizable,
          OperationalCapability.hideable,
          OperationalCapability.sectionable,
        },
        properties: {
          'sceneEntityId': source.id,
          'area': region.area,
          'triangleCount': region.triangleIndices.length,
          'meanCurvature': region.meanCurvature,
          'confidence': region.confidence,
          'health': region.health.name,
        },
      );
      final resolved = _ResolvedRegion(entity, region.triangleIndices);
      if (_isCurrent(source.id, signature)) {
        _presentations[entity.id] = OperationalResolution(
          entity: entity,
          triangleIndices: region.triangleIndices,
        );
      }
      regions.add(resolved);
      for (final triangle in region.triangleIndices) {
        byTriangle[triangle] = resolved;
      }
    }
    if (_isCurrent(source.id, signature)) {
      registry.replaceOwner(source.id, regions.map((region) => region.entity));
    }
    return _MeshResolution(byTriangle);
  }

  bool _isCurrent(String sourceId, Object signature) =>
      _meshResolutions[sourceId]?.signature == signature;
}

class _CachedMeshResolution {
  const _CachedMeshResolution(this.signature, this.value);
  final Object signature;
  final Future<_MeshResolution?> value;
}

class _MeshResolution {
  const _MeshResolution(this.byTriangle);
  final Map<int, _ResolvedRegion> byTriangle;
}

class _ResolvedRegion {
  const _ResolvedRegion(this.entity, this.triangleIndices);
  final OperationalEntity entity;
  final List<int> triangleIndices;
}
