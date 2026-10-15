import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../scene/cad_scene_graph.dart';
import '../rendering/cad_root_color.dart';
import '../rendering/cad_canvas_normal_pipeline.dart';
import '../rendering/mesh_derived_edge_classifier.dart';
import '../rendering/mesh_derived_edge_refiner.dart';
import '../rendering/shaded_debug_experiments.dart';
import '../rendering/stl_display_lod.dart';
import '../camera/cad_camera_controller.dart';

enum ViewportBackend { flutterCanvas, nativeGpu }

/// Viewport chrome/reference presentation stays in Flutter above the native
/// texture. It is not CAD geometry and therefore cannot affect backend
/// eligibility or be published to the triangle renderer.
bool isNativeViewportOverlay(CadSceneEntity entity) => switch (entity.kind) {
  CadSceneEntityKind.gizmo ||
  CadSceneEntityKind.axis ||
  CadSceneEntityKind.plane ||
  CadSceneEntityKind.coordinateSystem => true,
  CadSceneEntityKind.point =>
    entity.geometry['type'] == 'point' || entity.id.contains(':world:'),
  CadSceneEntityKind.sketch => true,
  // Reference Curves/Sections are analytic overlays rendered by Flutter over
  // the native CAD texture.  They have no triangle payload; treating them as
  // CAD curves would incorrectly trigger the global Canvas fallback.
  CadSceneEntityKind.curve =>
    entity.geometry['referenceCurve'] == true ||
        (entity.geometry['displayColor'] as String?)?.startsWith(
              'referenceCurve',
            ) ==
            true,
  CadSceneEntityKind.preview =>
    entity.geometry['nodes'] == null &&
        (entity.geometry['points'] is List ||
            entity.geometry['segments'] is List),
  _ => false,
};

String _nativeCadCategory(CadSceneEntityKind kind) => switch (kind) {
  CadSceneEntityKind.mesh => 'malha CAD',
  CadSceneEntityKind.sketch => 'sketch CAD',
  CadSceneEntityKind.curve => 'curva CAD',
  CadSceneEntityKind.surface => 'superfície CAD',
  CadSceneEntityKind.solid => 'sólido CAD',
  CadSceneEntityKind.preview => 'pré-visualização CAD',
  CadSceneEntityKind.point => 'ponto CAD',
  _ => 'entidade CAD',
};

final Expando<
  ({Object nodes, Object triangles, Object? normals, String? issue})
>
_nativePayloadValidation = Expando('native-payload-validation');

String? _nativePayloadIssue(Map<String, dynamic> geometry) {
  final nodes = geometry['nodes'];
  final triangles = geometry['triangles'];
  final normals = geometry['normals'];
  if (nodes is! List ||
      triangles is! List ||
      nodes.isEmpty ||
      triangles.isEmpty ||
      nodes.length % 3 != 0 ||
      triangles.length % 3 != 0) {
    return 'malha triangular ausente ou com dimensões inválidas';
  }
  final cached = _nativePayloadValidation[geometry];
  if (cached != null &&
      identical(cached.nodes, nodes) &&
      identical(cached.triangles, triangles) &&
      identical(cached.normals, normals)) {
    return cached.issue;
  }
  String? issue;
  if (nodes.any((value) => value is! num || !value.isFinite)) {
    issue = 'nodes contêm coordenadas não finitas';
  } else if (triangles.any((value) {
    if (value is! num || !value.isFinite) return true;
    final index = value.toInt();
    return value != index || index < 0 || index >= nodes.length ~/ 3;
  })) {
    issue = 'indices triangulares estão fora do intervalo de nodes';
  } else if (normals != null &&
      (normals is! List ||
          normals.length != nodes.length ||
          normals.any((value) => value is! num || !value.isFinite))) {
    issue = 'normals estão ausentes, desalinhadas ou não finitas';
  }
  _nativePayloadValidation[geometry] = (
    nodes: nodes,
    triangles: triangles,
    normals: normals,
    issue: issue,
  );
  return issue;
}

/// Eligibility is evaluated only for real visible CAD geometry before
/// encoding. Flutter overlays are deliberately outside this policy.
String? nativeSceneUnsupportedReason(
  CadSceneGraph scene, {
  required int style,
}) {
  for (final entity in scene.entities.where(
    (e) => e.visible && !isNativeViewportOverlay(e),
  )) {
    final category = _nativeCadCategory(entity.kind);
    final geometry = cadPresentationGeometry(entity.geometry);
    final payloadIssue = _nativePayloadIssue(geometry);
    if (payloadIssue != null) {
      return 'Payload Native GPU inválido para $category: $payloadIssue.';
    }
    final missingTopologicalEdges = geometry['topologicalEdges'] is! List;
    if ((style == 1 &&
            missingTopologicalEdges &&
            (entity.kind != CadSceneEntityKind.mesh ||
                _meshDerivedEdgesForEntity(entity, geometry) == null)) ||
        (style == 2 && missingTopologicalEdges)) {
      return '$category sem arestas topológicas CAD para este modo.';
    }
    try {
      StlDisplayLod.preflight(geometry);
      cadRootSrgb(entity.geometry);
    } on FormatException {
      return 'Contrato de display Native GPU inválido para $category.';
    }
  }
  return null;
}

enum NativePickKind { none, face, edge, vertex }

@immutable
class NativeViewportPick {
  const NativeViewportPick({
    required this.entityId,
    required this.kind,
    required this.subId,
    required this.point,
  });
  final String entityId;
  final NativePickKind kind;
  final int subId;
  final List<double> point;
}

@immutable
class DisplaySnapshot {
  const DisplaySnapshot({required this.revision, required this.entities});
  final int revision;
  final List<Map<String, Object?>> entities;
  Map<String, Object?> toMessage() => {
    'revision': revision,
    'entities': entities,
  };
}

@immutable
class NativeViewportStats {
  const NativeViewportStats({
    this.fps = 0,
    this.drawCalls = 0,
    this.triangles = 0,
    this.uploadMs = 0,
    this.renderMs = 0,
    this.pickingMs = 0,
    this.gpu = '',
    this.textureId = -1,
    this.textureRegistered = false,
    this.textureCallbacks = 0,
    this.textureCallbackHz = 0,
    this.frameMarks = 0,
    this.successfulFrameMarks = 0,
    this.requestedWidth = 0,
    this.requestedHeight = 0,
    this.sampledBgra = 0,
    this.sampledClearBgra = 0,
    this.setCameraCalls = 0,
    this.renderCalls = 0,
    this.constantBufferUpdates = 0,
    this.drawIndexedCalls = 0,
    this.fitCalls = 0,
    this.cameraDistance = 0,
    this.cameraRadius = 0,
    this.cameraNear = 0,
    this.cameraFar = 0,
  });
  final double fps, uploadMs, renderMs, pickingMs;
  final int drawCalls, triangles;
  final String gpu;
  final int textureId, textureCallbacks, frameMarks, successfulFrameMarks;
  final double textureCallbackHz;
  final int requestedWidth, requestedHeight, sampledBgra, sampledClearBgra;
  final int setCameraCalls,
      renderCalls,
      constantBufferUpdates,
      drawIndexedCalls;
  final int fitCalls;
  final double cameraDistance, cameraRadius, cameraNear, cameraFar;
  final bool textureRegistered;
  factory NativeViewportStats.fromMap(
    Map<Object?, Object?> value,
  ) => NativeViewportStats(
    fps: (value['fps'] as num?)?.toDouble() ?? 0,
    drawCalls: (value['drawCalls'] as num?)?.toInt() ?? 0,
    triangles: (value['triangles'] as num?)?.toInt() ?? 0,
    uploadMs: (value['uploadMs'] as num?)?.toDouble() ?? 0,
    renderMs: (value['renderMs'] as num?)?.toDouble() ?? 0,
    pickingMs: (value['pickingMs'] as num?)?.toDouble() ?? 0,
    gpu: value['gpu'] as String? ?? '',
    textureId: (value['textureId'] as num?)?.toInt() ?? -1,
    textureRegistered: value['textureRegistered'] as bool? ?? false,
    textureCallbacks: (value['textureCallbacks'] as num?)?.toInt() ?? 0,
    textureCallbackHz: (value['textureCallbackHz'] as num?)?.toDouble() ?? 0,
    frameMarks: (value['frameMarks'] as num?)?.toInt() ?? 0,
    successfulFrameMarks: (value['successfulFrameMarks'] as num?)?.toInt() ?? 0,
    requestedWidth: (value['requestedWidth'] as num?)?.toInt() ?? 0,
    requestedHeight: (value['requestedHeight'] as num?)?.toInt() ?? 0,
    sampledBgra: (value['sampledBgra'] as num?)?.toInt() ?? 0,
    sampledClearBgra: (value['sampledClearBgra'] as num?)?.toInt() ?? 0,
    setCameraCalls: (value['setCameraCalls'] as num?)?.toInt() ?? 0,
    renderCalls: (value['renderCalls'] as num?)?.toInt() ?? 0,
    constantBufferUpdates:
        (value['constantBufferUpdates'] as num?)?.toInt() ?? 0,
    drawIndexedCalls: (value['drawIndexedCalls'] as num?)?.toInt() ?? 0,
    fitCalls: (value['fitCalls'] as num?)?.toInt() ?? 0,
    cameraDistance: (value['cameraDistance'] as num?)?.toDouble() ?? 0,
    cameraRadius: (value['cameraRadius'] as num?)?.toDouble() ?? 0,
    cameraNear: (value['cameraNear'] as num?)?.toDouble() ?? 0,
    cameraFar: (value['cameraFar'] as num?)?.toDouble() ?? 0,
  );
}

class CadSceneDisplayAdapter {
  final Map<String, Object> _geometryIdentity = {};
  final Map<String, (bool, bool)> _displayState = {};
  int _revision = 0;

  void clear() {
    _geometryIdentity.clear();
    _displayState.clear();
  }

  @visibleForTesting
  int get retainedGeometryCount => _geometryIdentity.length;

  DisplaySnapshot initial(CadSceneGraph scene) {
    _geometryIdentity.clear();
    _displayState.clear();
    return DisplaySnapshot(
      revision: ++_revision,
      entities: scene.entities
          .where((entity) => !isNativeViewportOverlay(entity))
          .map((entity) => _encode(entity, includeGeometry: true))
          .whereType<Map<String, Object?>>()
          .toList(),
    );
  }

  DisplaySnapshot delta(CadSceneGraph scene) {
    final changed = <Map<String, Object?>>[];
    final live = <String>{};
    for (final entity in scene.entities.where(
      (entity) => !isNativeViewportOverlay(entity),
    )) {
      live.add(entity.id);
      final geometryChanged = _geometryIdentity[entity.id] != _identity(entity);
      final displayChanged =
          _displayState[entity.id] != (entity.visible, entity.selected);
      if (geometryChanged || displayChanged) {
        final encoded = _encode(entity, includeGeometry: geometryChanged);
        if (encoded != null) changed.add(encoded);
      }
    }
    final removed = _geometryIdentity.keys
        .where((id) => !live.contains(id))
        .toList();
    _geometryIdentity.removeWhere((id, _) => !live.contains(id));
    _displayState.removeWhere((id, _) => !live.contains(id));
    return DisplaySnapshot(
      revision: ++_revision,
      entities: [
        ...changed,
        ...removed.map((id) => {'id': id, 'removed': true}),
      ],
    );
  }

  Map<String, Object?>? _encode(
    CadSceneEntity entity, {
    required bool includeGeometry,
  }) {
    if (isNativeViewportOverlay(entity)) return null;
    if (!entity.visible && !_geometryIdentity.containsKey(entity.id)) {
      return null;
    }
    _geometryIdentity[entity.id] = _identity(entity);
    _displayState[entity.id] = (entity.visible, entity.selected);
    final presentation = cadPresentationGeometry(entity.geometry);
    final nodes = presentation['nodes'];
    final triangles = presentation['triangles'];
    if (nodes is! List || triangles is! List) return null;
    final result = <String, Object?>{
      'id': entity.id,
      'kind': entity.kind.name,
      'visible': entity.visible,
      'selected': entity.selected,
    };
    if (includeGeometry) {
      final presentationNormals = kFlcadDevShadedDerivedNormals
          ? (shadedDerivedNormals(presentation) ?? presentation['normals'])
          : presentation['normals'];
      StlDisplayLod.preflight(presentation);
      if (StlDisplayLod.simplified(presentation)) {
        // Native LOD already carries indexed vertices and winding normals.
        // Keep sharing them: no corner expansion or full List copies here.
        result['nodes'] = presentation['nodes'];
        result['normals'] = presentationNormals;
        result['triangles'] = presentation['triangles'];
        result['presentationLod'] = presentation['presentationLod'];
        final meshEdges = _meshDerivedEdgesForEntity(entity, presentation);
        if (meshEdges != null) result['meshDerivedEdges'] = meshEdges;
        return result;
      }
      final chunks = CadCanvasNormalPipeline.build(
        (presentation['nodes'] as List).cast<num>(),
        (presentation['triangles'] as List).cast<num>(),
        nativeNormals: (presentationNormals as List?)?.cast<num>(),
      );
      result['nodes'] = [for (final chunk in chunks) ...chunk.xyz];
      result['normals'] = [for (final chunk in chunks) ...chunk.normals];
      result['triangles'] = List<int>.generate(
        (presentation['triangles'] as List).length,
        (i) => i,
      );
      final edges = presentation['topologicalEdges'];
      if (edges is List) result['topologicalEdges'] = edges;
      final meshEdges = _meshDerivedEdgesForEntity(entity, presentation);
      if (meshEdges != null) result['meshDerivedEdges'] = meshEdges;
      final faceRanges = presentation['faceTriangleRanges'];
      if (faceRanges is List) result['faceTriangleRanges'] = faceRanges;
      final rgb = cadRootSrgb(entity.geometry);
      if (rgb != null) result['rootSrgb'] = rgb;
    }
    return result;
  }

  Object _identity(CadSceneEntity entity) {
    final geometry = cadPresentationGeometry(entity.geometry);
    final rgb = entity.geometry['rootLinearRgb'];
    return (
      geometry['nodes'],
      geometry['triangles'],
      geometry['normals'],
      geometry['topologicalEdges'],
      geometry['meshDerivedEdges'],
      geometry['faceTriangleRanges'],
      rgb is List && rgb.length == 3 ? (rgb[0], rgb[1], rgb[2]) : null,
    );
  }
}

final Expando<MeshDerivedEdgeObservation> _meshDerivedCache = Expando(
  'mesh-derived-edges',
);

MeshDerivedEdgeObservation? cachedMeshDerivedEdgeObservation(
  CadSceneEntity entity,
) {
  if (entity.kind != CadSceneEntityKind.mesh ||
      cadPresentationGeometry(entity.geometry)['topologicalEdges'] is List) {
    return null;
  }
  final geometry = cadPresentationGeometry(entity.geometry);
  return _meshDerivedCache[geometry];
}

Map<String, Object?>? _meshDerivedEdgesForEntity(
  CadSceneEntity entity,
  Map<String, dynamic> geometry,
) {
  if (entity.kind != CadSceneEntityKind.mesh ||
      geometry['topologicalEdges'] is List) {
    return null;
  }
  final nodes = geometry['nodes'];
  final triangles = geometry['triangles'];
  if (nodes is! List || triangles is! List) return null;
  final observation = _meshDerivedCache[geometry] ??= (() {
    final stopwatch = Stopwatch()..start();
    final classification = const MeshDerivedEdgeClassifier().classify(
      vertices: nodes.cast<num>(),
      triangles: triangles.cast<num>(),
      normals: (geometry['normals'] as List?)?.cast<num>(),
      config: const MeshDerivedEdgeClassifierConfig(
        maxTriangles: 250000,
        maxEdges: 250000,
      ),
    );
    stopwatch.stop();
    return MeshDerivedEdgeObservation(
      classification: classification,
      elapsedMicros: stopwatch.elapsedMicroseconds,
    );
  })();
  final classification = observation.classification;
  if (classification.segments.isEmpty ||
      classification.statistics.truncated ||
      classification.diagnostics.contains('invalid_triangle_indices') ||
      classification.diagnostics.contains(
        'vertices_contain_non_finite_values',
      )) {
    return null;
  }
  final segments = kFlcadDevMeshDerivedEdgeRefinement
      ? meshDerivedPresentationSegments(classification)
      : classification.segments;
  if (segments.isEmpty) return null;
  return {
    'source': meshDerivedEdgeSource,
    'segments': [
      for (final segment in segments)
        {'start': segment.start, 'end': segment.end, 'kind': segment.kind.name},
    ],
  };
}

class NativeViewportBridge extends ChangeNotifier {
  int renderStyle = 0;
  static const MethodChannel _channel = MethodChannel('flcad/native_viewport');
  final CadSceneDisplayAdapter adapter = CadSceneDisplayAdapter();
  int? textureId;
  bool available = false;

  /// True only after the host has acknowledged the current scene snapshot.
  /// A texture alone is not evidence that presentation buffers are ready.
  bool sceneReady = true;
  NativeViewportStats stats = const NativeViewportStats();
  Timer? _statsTimer;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _shutdown;
  Future<void>? _publishing;
  CadSceneGraph? _pendingScene;
  bool _replacePending = false;
  int acknowledgedSceneRevision = 0;
  Future<void>? _cameraDelivery;
  CadCameraController? _pendingCamera;
  // The channel/host belongs to the window, including across widget rebuilds.
  static Future<void>? _hostDrain;
  static NativeViewportBridge? _hostOwner;

  void _failed() {
    if (_disposed) return;
    available = false;
    sceneReady = false;
    _statsTimer?.cancel();
    notifyListeners();
  }

  /// Drain the channel before permitting Canvas to allocate its display cache.
  Future<void> deactivate() {
    if (_shutdown != null) return _shutdown!;
    final ownsHost = identical(_hostOwner, this);
    ++_generation;
    available = false;
    sceneReady = false;
    _statsTimer?.cancel();
    adapter.clear();
    _pendingScene = null;
    _replacePending = false;
    _pendingCamera = null;
    textureId = null;
    if (!ownsHost) return Future<void>.value();
    _hostOwner = null;
    final closing = (_hostDrain ?? Future<void>.value()).then((_) async {
      await _publishing;
      await _cameraDelivery;
      try {
        await _channel.invokeMethod<void>('shutdown');
      } on PlatformException {
        // The failed host may already be gone. No scene authority is affected.
      } on MissingPluginException {
        // No host was installed (tests or unsupported platform).
      }
    });
    late final Future<void> drained;
    drained = closing.whenComplete(() {
      _shutdown = null;
      if (identical(_hostDrain, drained)) _hostDrain = null;
    });
    _shutdown = drained;
    _hostDrain = _shutdown!;
    return _shutdown!;
  }

  Future<bool> initialize(double width, double height) async {
    if (!Platform.isWindows) return false;
    await _hostDrain;
    if (_disposed) return false;
    final previous = _hostOwner;
    if (previous != null && !identical(previous, this)) {
      await previous.deactivate();
    }
    if (_disposed) return false;
    final generation = ++_generation;
    _hostOwner = this;
    sceneReady = false;
    try {
      final initializedTextureId = await _channel
          .invokeMethod<int>('initialize', {
            'width': width.round().clamp(1, 16384),
            'height': height.round().clamp(1, 16384),
            'shadedLightingExperiment': kFlcadDevShadedLightingExperiment,
          });
      if (_disposed || generation != _generation) return false;
      textureId = initializedTextureId;
      available = textureId != null && textureId! >= 0;
      if (available) {
        _statsTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) => refreshStats(),
        );
      }
      notifyListeners();
      return available;
    } on PlatformException {
      if (generation == _generation) _failed();
      return false;
    } on MissingPluginException {
      if (generation == _generation) _failed();
      return false;
    }
  }

  Future<void> resize(double width, double height) => _invoke('resize', {
    'width': width.round().clamp(1, 16384),
    'height': height.round().clamp(1, 16384),
  });
  Future<void> sendInitial(CadSceneGraph scene) =>
      _publish(scene, replace: true);
  Future<void> sendDelta(CadSceneGraph scene) =>
      _publish(scene, replace: false);

  Future<void> _publish(CadSceneGraph scene, {required bool replace}) {
    if (!available || _disposed) return Future<void>.value();
    _pendingScene = scene;
    _replacePending |= replace;
    if (_publishing != null) return _publishing!;
    final generation = _generation;
    // One call in flight; intervening visibility changes coalesce before encode.
    late final Future<void> draining;
    draining =
        Future<void>.microtask(() async {
          while (available &&
              !_disposed &&
              generation == _generation &&
              _pendingScene != null) {
            final next = _pendingScene!;
            final replace = _replacePending;
            _pendingScene = null;
            _replacePending = false;
            if (nativeSceneUnsupportedReason(next, style: renderStyle) !=
                null) {
              _failed();
              break;
            }
            final snapshot = replace
                ? adapter.initial(next)
                : adapter.delta(next);
            if (snapshot.entities.isEmpty) {
              if (replace) sceneReady = true;
              continue;
            }
            try {
              final ack = await _channel.invokeMethod<int>(
                replace ? 'snapshot' : 'delta',
                snapshot.toMessage(),
              );
              if (!_disposed && available && generation == _generation) {
                if (ack == snapshot.revision) {
                  acknowledgedSceneRevision = ack!;
                }
                // Method completion is the host acknowledgement. Real host
                // snapshots return the revision, while older test/platform
                // handlers may complete with no value.
                if (replace) sceneReady = true;
              }
            } on PlatformException {
              if (generation == _generation) _failed();
            } on MissingPluginException {
              if (generation == _generation) _failed();
            }
          }
        }).whenComplete(() {
          if (identical(_publishing, draining)) _publishing = null;
        });
    _publishing = draining;
    return draining;
  }

  Future<void> orbit(double dx, double dy) =>
      _invoke('orbit', {'dx': dx, 'dy': dy});
  Future<void> pan(double dx, double dy) =>
      _invoke('pan', {'dx': dx, 'dy': dy});
  Future<void> zoom(double factor) => _invoke('zoom', {'factor': factor});
  Future<void> fit() => _invoke('fit');
  Future<void> textureProbe() => _invoke('textureProbe');
  Future<void> clearHover() => _invoke('clearHover');
  Future<void> setManagedCadFaceHover({
    required String entityId,
    required int presentationSubId,
  }) => _invoke('setManagedCadFaceHover', {
    'entityId': entityId,
    'presentationSubId': presentationSubId,
  });
  Future<void> setManagedCadFaceSelection({
    required String entityId,
    required int presentationSubId,
  }) => _invoke('setManagedCadFaceSelection', {
    'entityId': entityId,
    'presentationSubId': presentationSubId,
  });
  Future<void> clearManagedCadFaceSelection() =>
      _invoke('clearManagedCadFaceSelection');
  Future<void> setOperationalHover({
    required String operationalEntityId,
    required String entityId,
    required List<int> triangleIndices,
  }) => _invoke('setOperationalHover', {
    'operationalEntityId': operationalEntityId,
    'entityId': entityId,
    'triangles': triangleIndices,
  });
  Future<void> setOperationalSelection({
    required String operationalEntityId,
    required String entityId,
    required List<int> triangleIndices,
  }) => _invoke('setOperationalSelection', {
    'operationalEntityId': operationalEntityId,
    'entityId': entityId,
    'triangles': triangleIndices,
  });
  Future<void> clearOperationalSelection() =>
      _invoke('clearOperationalSelection');
  Future<NativeViewportPick?> pick(double x, double y) async {
    if (!available) return null;
    final generation = _generation;
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('pick', {
        'x': x.round(),
        'y': y.round(),
      });
      if (_disposed || !available || generation != _generation) return null;
      if (value == null || value['entityId'] is! String) return null;
      final rawPoint = value['point'] as List<Object?>? ?? const [];
      return NativeViewportPick(
        entityId: value['entityId']! as String,
        kind: NativePickKind
            .values[(value['kind'] as num?)?.toInt().clamp(0, 3) ?? 0],
        subId: (value['subId'] as num?)?.toInt() ?? 0,
        point: rawPoint
            .map((item) => (item as num).toDouble())
            .toList(growable: false),
      );
    } on PlatformException {
      if (generation == _generation) _failed();
      return null;
    } on MissingPluginException {
      if (generation == _generation) _failed();
      return null;
    }
  }

  Future<void> setCamera(CadCameraController camera) {
    if (!available || _disposed) return Future<void>.value();
    _pendingCamera = camera;
    if (_cameraDelivery != null) return _cameraDelivery!;
    final generation = _generation;
    late final Future<void> delivery;
    delivery =
        Future<void>.microtask(() async {
          while (available &&
              !_disposed &&
              generation == _generation &&
              _pendingCamera != null) {
            final next = _pendingCamera!;
            _pendingCamera = null;
            await _deliverCamera(next);
          }
        }).whenComplete(() {
          if (identical(_cameraDelivery, delivery)) _cameraDelivery = null;
        });
    _cameraDelivery = delivery;
    return delivery;
  }

  Future<void> _deliverCamera(CadCameraController camera) =>
      _invoke('setCamera', {
        'renderStyle': renderStyle,
        'eye': [
          camera.presentationEye.x,
          camera.presentationEye.y,
          camera.presentationEye.z,
        ],
        'target': [
          camera.presentationTarget.x,
          camera.presentationTarget.y,
          camera.presentationTarget.z,
        ],
        'up': [camera.up.x, camera.up.y, camera.up.z],
        'fov': camera.fieldOfViewRadians,
        'near': camera.nearPlane,
        'far': camera.farPlane,
        'projectionMode': camera.projectionMode.name,
        'orthographicHeight': camera.orthographicHeight,
        'panOffsetX': camera.presentationOffsetNdcX,
        'panOffsetY': camera.presentationOffsetNdcY,
      });

  Future<void> refreshStats() async {
    if (!available) return;
    final generation = _generation;
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('stats');
      if (!_disposed &&
          available &&
          generation == _generation &&
          value != null) {
        stats = NativeViewportStats.fromMap(value);
        notifyListeners();
      }
    } on PlatformException {
      if (generation == _generation) _failed();
    } on MissingPluginException {
      if (generation == _generation) _failed();
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    if (!available || _disposed) return;
    final generation = _generation;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException {
      if (generation == _generation) _failed();
    } on MissingPluginException {
      if (generation == _generation) _failed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _statsTimer?.cancel();
    unawaited(deactivate());
    super.dispose();
  }
}
