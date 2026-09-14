import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../scene/cad_scene_graph.dart';
import '../rendering/cad_root_color.dart';
import '../camera/cad_camera_controller.dart';

enum ViewportBackend { flutterCanvas, nativeGpu }

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

  DisplaySnapshot initial(CadSceneGraph scene) {
    _geometryIdentity.clear();
    _displayState.clear();
    return DisplaySnapshot(
      revision: ++_revision,
      entities: scene.entities
          .map((entity) => _encode(entity, includeGeometry: true))
          .whereType<Map<String, Object?>>()
          .toList(),
    );
  }

  DisplaySnapshot delta(CadSceneGraph scene) {
    final changed = <Map<String, Object?>>[];
    final live = <String>{};
    for (final entity in scene.entities) {
      live.add(entity.id);
      final geometry = entity.geometry;
      final geometryChanged = !identical(
        _geometryIdentity[entity.id],
        geometry,
      );
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
    _geometryIdentity[entity.id] = entity.geometry;
    _displayState[entity.id] = (entity.visible, entity.selected);
    final nodes = entity.geometry['nodes'];
    final triangles = entity.geometry['triangles'];
    if (nodes is! List || triangles is! List) return null;
    final result = <String, Object?>{
      'id': entity.id,
      'kind': entity.kind.name,
      'visible': entity.visible,
      'selected': entity.selected,
    };
    if (includeGeometry) {
      result['nodes'] = nodes;
      result['triangles'] = triangles;
      final rgb = cadRootSrgb(entity.geometry);
      if (rgb != null) result['rootSrgb'] = rgb;
    }
    return result;
  }
}

class NativeViewportBridge extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('flcad/native_viewport');
  final CadSceneDisplayAdapter adapter = CadSceneDisplayAdapter();
  int? textureId;
  bool available = false;
  NativeViewportStats stats = const NativeViewportStats();
  Timer? _statsTimer;

  Future<bool> initialize(double width, double height) async {
    if (!Platform.isWindows) return false;
    try {
      textureId = await _channel.invokeMethod<int>('initialize', {
        'width': width.round().clamp(1, 16384),
        'height': height.round().clamp(1, 16384),
      });
      available = textureId != null && textureId! >= 0;
      if (available && kDebugMode) {
        _statsTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) => refreshStats(),
        );
      }
      notifyListeners();
      return available;
    } on PlatformException {
      available = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> resize(double width, double height) => _invoke('resize', {
    'width': width.round().clamp(1, 16384),
    'height': height.round().clamp(1, 16384),
  });
  Future<void> sendInitial(CadSceneGraph scene) =>
      _invoke('snapshot', adapter.initial(scene).toMessage());
  Future<void> sendDelta(CadSceneGraph scene) async {
    final value = adapter.delta(scene);
    if (value.entities.isNotEmpty) await _invoke('delta', value.toMessage());
  }

  Future<void> orbit(double dx, double dy) =>
      _invoke('orbit', {'dx': dx, 'dy': dy});
  Future<void> pan(double dx, double dy) =>
      _invoke('pan', {'dx': dx, 'dy': dy});
  Future<void> zoom(double factor) => _invoke('zoom', {'factor': factor});
  Future<void> fit() => _invoke('fit');
  Future<void> textureProbe() => _invoke('textureProbe');
  Future<void> clearHover() => _invoke('clearHover');
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
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('pick', {
        'x': x.round(),
        'y': y.round(),
      });
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
      return null;
    }
  }

  Future<void> setCamera(CadCameraController camera) => _invoke('setCamera', {
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
    final value = await _channel.invokeMapMethod<Object?, Object?>('stats');
    if (value != null) {
      stats = NativeViewportStats.fromMap(value);
      notifyListeners();
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    if (!available) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException {
      available = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    if (available) _channel.invokeMethod<void>('shutdown');
    super.dispose();
  }
}
