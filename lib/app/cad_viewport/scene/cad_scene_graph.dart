import 'package:flutter/foundation.dart';

enum CadSceneEntityKind {
  mesh,
  plane,
  axis,
  point,
  coordinateSystem,
  sketch,
  curve,
  surface,
  solid,
  preview,
  gizmo,
}

class CadSceneEntity {
  const CadSceneEntity({
    required this.id,
    required this.kind,
    required this.geometry,
    this.visible = true,
    this.selected = false,
    this.transparent = false,
  });
  final String id;
  final CadSceneEntityKind kind;
  final Map<String, dynamic> geometry;
  final bool visible, selected, transparent;
  CadSceneEntity copyWith({bool? visible, bool? selected, bool? transparent}) =>
      CadSceneEntity(
        id: id,
        kind: kind,
        geometry: geometry,
        visible: visible ?? this.visible,
        selected: selected ?? this.selected,
        transparent: transparent ?? this.transparent,
      );
}

class CadSceneGraph extends ChangeNotifier {
  final Map<String, CadSceneEntity> _entities = {};
  Iterable<CadSceneEntity> get entities => _entities.values;
  CadSceneEntity? find(String id) => _entities[id];

  /// Installs a prepared scene without exposing intermediate entities.
  void replaceAll(Iterable<CadSceneEntity> entities, {bool notify = true}) {
    final replacement = {for (final entity in entities) entity.id: entity};
    _entities
      ..clear()
      ..addAll(replacement);
    if (notify) notifyListeners();
  }

  void upsert(CadSceneEntity entity) {
    _entities[entity.id] = entity;
    notifyListeners();
  }

  void remove(String id) {
    if (_entities.remove(id) != null) {
      notifyListeners();
    }
  }

  void clear() {
    if (_entities.isEmpty) return;
    _entities.clear();
    notifyListeners();
  }

  void select(Set<String> ids) {
    for (final entry in _entities.entries.toList()) {
      _entities[entry.key] = entry.value.copyWith(
        selected: ids.contains(entry.key),
      );
    }
    notifyListeners();
  }

  /// Requests a display-only repaint without rebuilding or mutating geometry.
  /// Used after compositor overlays change above a native-backed viewport.
  void invalidatePresentation() => notifyListeners();
}
