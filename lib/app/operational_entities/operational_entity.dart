import 'package:flutter/foundation.dart';
import '../runtime/notification_gate.dart';

enum OperationalEntityType {
  meshRegion,
  plane,
  cylinder,
  cone,
  sphere,
  fillet,
  freeformRegion,
  cadFace,
  topologicalEdge,
  topologicalVertex,
  sketchEntity,
  curve,
  section,
  surface,
}

enum OperationalCapability {
  selectable,
  measurable,
  transformable,
  hideable,
  inspectable,
  reference,
  alignment,
  recognizable,
  editable,
  sectionable,
  sketchProjectable,
  surfaceConvertible,
  cadConvertible,
  topological,
}

@immutable
class OperationalEntity {
  const OperationalEntity({
    required this.id,
    required this.type,
    required this.ownerId,
    required this.ownerDomain,
    required this.documentId,
    required this.revision,
    required this.label,
    required this.capabilities,
    required this.properties,
    this.available = true,
  });

  final String id;
  final OperationalEntityType type;
  final String ownerId;
  final String ownerDomain;
  final String documentId;
  final int revision;
  final String label;
  final Set<OperationalCapability> capabilities;
  final Map<String, Object?> properties;
  final bool available;
}

class OperationalEntityRegistry extends ChangeNotifier with NotificationGate {
  final Map<String, OperationalEntity> _entities = {};

  OperationalEntity? find(String id) => _entities[id];
  Iterable<OperationalEntity> get entities => _entities.values;

  void replaceOwner(String ownerId, Iterable<OperationalEntity> values) {
    _entities.removeWhere((_, entity) => entity.ownerId == ownerId);
    for (final entity in values) {
      _entities[entity.id] = entity;
    }
    notifyListeners();
  }

  void clear() {
    if (_entities.isEmpty) return;
    _entities.clear();
    notifyListeners();
  }
}

class OperationalSelectionManager extends ChangeNotifier with NotificationGate {
  OperationalSelectionManager(this.registry);
  final OperationalEntityRegistry registry;
  final List<String> _selectedIds = [];
  String? _activeId;

  List<String> get selectedIds => List.unmodifiable(_selectedIds);
  String? get activeId => _activeId;
  OperationalEntity? get active =>
      _activeId == null ? null : registry.find(_activeId!);

  /// Reconciles a prepared document without notifying during installation.
  void publishReconciliation() => notifyListeners();

  bool retainWhere(
    bool Function(OperationalEntity) keep, {
    bool notify = true,
  }) {
    final count = _selectedIds.length;
    _selectedIds.removeWhere((id) {
      final entity = registry.find(id);
      return entity == null || !keep(entity);
    });
    if (!_selectedIds.contains(_activeId)) _activeId = _selectedIds.lastOrNull;
    final changed = count != _selectedIds.length;
    if (changed && notify) notifyListeners();
    return changed;
  }

  void select(String id, {bool additive = false, bool toggle = false}) {
    if (registry.find(id) == null) return;
    if (toggle) {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    } else {
      if (!additive) _selectedIds.clear();
      if (!_selectedIds.contains(id)) _selectedIds.add(id);
    }
    _activeId = _selectedIds.contains(id) ? id : _selectedIds.lastOrNull;
    notifyListeners();
  }

  void clear() {
    if (_selectedIds.isEmpty) return;
    _selectedIds.clear();
    _activeId = null;
    notifyListeners();
  }
}
