import 'package:flutter/foundation.dart';
import '../../runtime/notification_gate.dart';

import '../../../core/cad_kernel/models/kernel_models.dart';
import '../../cad_viewport/scene/cad_scene_graph.dart';

/// Synchronizes Explorer and viewport entity selection and resolves only
/// kernel handles that were persisted by the producing geometry API.
class GeometrySelectionManager extends ChangeNotifier with NotificationGate {
  GeometrySelectionManager(this.scene) {
    scene.addListener(_sceneChanged);
  }

  final CadSceneGraph scene;
  final List<String> _orderedIds = [];
  final Set<String> _selectedIds = {};
  String? _anchorId;

  Set<String> get selectedIds => Set.unmodifiable(_selectedIds);

  List<CadSceneEntity> get entities => _selectedIds
      .map(scene.find)
      .whereType<CadSceneEntity>()
      .toList(growable: false);

  List<ShapeHandle> get shapeHandles => entities
      .map(_persistedHandle)
      .whereType<ShapeHandle>()
      .toList(growable: false);

  bool hasOfficialHandle(String entityId) =>
      _persistedHandle(scene.find(entityId)) != null;

  void replace(Set<String> ids) {
    final existing = scene.entities.map((entity) => entity.id).toSet();
    _selectedIds
      ..clear()
      ..addAll(ids.where(existing.contains));
    _anchorId = _selectedIds.lastOrNull;
    scene.select(_selectedIds);
    notifyListeners();
  }

  void select(
    String entityId, {
    bool additive = false,
    bool toggle = false,
    bool range = false,
  }) {
    if (scene.find(entityId) == null) return;
    _refreshOrder();
    if (range && _anchorId != null) {
      final first = _orderedIds.indexOf(_anchorId!);
      final last = _orderedIds.indexOf(entityId);
      if (first >= 0 && last >= 0) {
        if (!additive) _selectedIds.clear();
        final low = first < last ? first : last;
        final high = first > last ? first : last;
        _selectedIds.addAll(_orderedIds.sublist(low, high + 1));
      }
    } else if (toggle) {
      if (!_selectedIds.add(entityId)) _selectedIds.remove(entityId);
      _anchorId = entityId;
    } else {
      if (!additive) _selectedIds.clear();
      _selectedIds.add(entityId);
      _anchorId = entityId;
    }
    scene.select(_selectedIds);
    notifyListeners();
  }

  void clear() {
    if (_selectedIds.isEmpty) return;
    _selectedIds.clear();
    _anchorId = null;
    scene.select(const {});
    notifyListeners();
  }

  void _sceneChanged() {
    final existing = scene.entities.map((entity) => entity.id).toSet();
    final count = _selectedIds.length;
    _selectedIds.removeWhere((id) => !existing.contains(id));
    if (_selectedIds.length != count) notifyListeners();
    _refreshOrder();
  }

  void _refreshOrder() {
    _orderedIds
      ..clear()
      ..addAll(scene.entities.map((entity) => entity.id));
  }

  ShapeHandle? _persistedHandle(CadSceneEntity? entity) {
    final value = entity?.geometry['handle'];
    if (value is! Map) return null;
    try {
      return ShapeHandle.fromJson(Map<String, dynamic>.from(value));
    } on Object {
      return null;
    }
  }

  @override
  void dispose() {
    scene.removeListener(_sceneChanged);
    super.dispose();
  }
}
