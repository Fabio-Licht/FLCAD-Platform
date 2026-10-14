import '../../operational_entities/operational_entity.dart';
import '../../../core/cad_document/cad_document.dart';

/// Presentation-only keys used by the detached Inspector.
abstract final class PanelInspectorViewModelKeys {
  static const selectionState = 'inspector.selectionState';
  static const documentSelectionIds = 'inspector.documentSelectionIds';
  static const operationalSelectionIds = 'inspector.operationalSelectionIds';
  static const documentEntity = 'inspector.documentEntity';
  static const operationalEntities = 'inspector.operationalEntities';
}

/// Builds a bounded, JSON-safe Inspector projection from authoritative state.
///
/// This class deliberately accepts values rather than a runtime. It cannot
/// leak a CAD object, ShapeHandle, token or closure into a panel snapshot.
abstract final class PanelInspectorViewModel {
  static Map<String, Object?> build({
    required CadDocument? document,
    required Set<String> documentSelection,
    required List<String> operationalSelection,
    required Map<String, OperationalEntity?> operationalEntities,
  }) {
    final documentIds = documentSelection.toList()..sort();
    final operationalIds = operationalSelection.toList(growable: false);
    final documentRows = [
      for (final id in documentIds)
        _documentEntity(document?.entities[id], selectedId: id),
    ];
    final operationalRows = [
      for (final id in operationalIds)
        _operationalEntity(operationalEntities[id], selectedId: id),
    ];
    final hasUnavailable = [
      ...documentRows,
      ...operationalRows,
    ].any((row) => row['available'] != true);
    final selectedCount = documentIds.length + operationalIds.length;
    final selectionState = selectedCount == 0
        ? 'none'
        : hasUnavailable
        ? 'unavailable'
        : selectedCount > 1
        ? 'multiple'
        : 'single';
    return {
      PanelInspectorViewModelKeys.selectionState: selectionState,
      PanelInspectorViewModelKeys.documentSelectionIds: documentIds,
      PanelInspectorViewModelKeys.operationalSelectionIds: operationalIds,
      PanelInspectorViewModelKeys.documentEntity: documentRows.length == 1
          ? documentRows.single
          : null,
      PanelInspectorViewModelKeys.operationalEntities: operationalRows,
    };
  }

  static Map<String, Object?> _documentEntity(
    CadDocumentEntity? entity, {
    required String selectedId,
  }) {
    if (entity == null) {
      return {'id': selectedId, 'available': false};
    }
    final properties = <String, Object?>{};
    final data = entity.data;
    _string(data, properties, 'name');
    _string(data, properties, 'format');
    _string(data, properties, 'sceneKind');
    _string(data, properties, 'cadSemanticKind');
    _string(data, properties, 'cadVisualType');
    _string(data, properties, 'stepTechnicalName');
    _string(data, properties, 'featureLifecycle');
    if (data['sceneVisible'] is bool) {
      properties['visibility'] = data['sceneVisible'];
    }
    final dimension = data['dimension'];
    if (dimension is Map &&
        dimension['value'] is num &&
        dimension['value'].isFinite &&
        (dimension['value'] as num) > 0) {
      final type = dimension['type'];
      properties['drivingDimension'] = {
        'type': type is String ? type : 'linear',
        'value': (dimension['value'] as num).toDouble(),
        'unit': type == 'angular' ? 'deg' : 'mm',
        'editable': true,
      };
    }
    final sceneGeometry = data['sceneGeometry'];
    if (sceneGeometry is Map) {
      final point = sceneGeometry['position'] ?? sceneGeometry['origin'];
      final coordinates = _finiteNumbers(point, expected: 3);
      if (coordinates != null) {
        properties['origin'] = _measurement(coordinates, 'mm');
      }
    }
    final reference = data['reference'];
    if (reference is Map) {
      final recipe = reference['recipe'];
      final parameters = recipe is Map ? recipe['parameters'] : null;
      if (parameters is Map && parameters['tolerance'] is num) {
        properties['tolerance'] = _measurement([
          (parameters['tolerance'] as num).toDouble(),
        ], 'mm');
      }
      final dna = reference['dna'];
      if (dna is Map && dna['confidence'] is num) {
        properties['confidence'] = (dna['confidence'] as num).toDouble();
      }
    }
    final mesh = entity.mesh;
    if (mesh != null) {
      properties['vertexCount'] = mesh.vertexCount;
      properties['triangleCount'] = mesh.triangleCount;
      properties['bounds'] = {
        'min': [mesh.bounds.minX, mesh.bounds.minY, mesh.bounds.minZ],
        'max': [mesh.bounds.maxX, mesh.bounds.maxY, mesh.bounds.maxZ],
        'unit': 'mm',
      };
      properties['normals'] = mesh.hasNormals;
    }
    return {
      'id': entity.id,
      'available': true,
      'selectionDomain': 'document',
      'type': entity.kind.name,
      'name': data['name'] is String ? data['name'] : entity.id,
      'revision': _finiteInt(data['revision']),
      'properties': properties,
    };
  }

  static Map<String, Object?> _operationalEntity(
    OperationalEntity? entity, {
    required String selectedId,
  }) {
    if (entity == null || !entity.available) {
      return {'id': selectedId, 'available': false};
    }
    final properties = <String, Object?>{};
    for (final key in const [
      'triangleCount',
      'meanCurvature',
      'confidence',
      'health',
      'measurementSafe',
      'presentationOnly',
      'sceneEntityId',
    ]) {
      final value = entity.properties[key];
      if (value is String || value is bool || value is num) {
        properties[key] = value;
      }
    }
    _measurementValue(entity.properties, properties, 'area', 'mm²');
    _measurementValue(entity.properties, properties, 'volume', 'mm³');
    _measurementValue(entity.properties, properties, 'length', 'mm');
    return {
      'id': entity.id,
      'available': true,
      'selectionDomain': 'operational',
      'type': entity.type.name,
      'name': entity.label,
      'ownerId': entity.ownerId,
      'ownerDomain': entity.ownerDomain,
      'documentId': entity.documentId,
      'revision': entity.revision,
      'properties': properties,
    };
  }

  static void _string(
    Map<String, dynamic> data,
    Map<String, Object?> output,
    String key,
  ) {
    final value = data[key];
    if (value is String && value.isNotEmpty) output[key] = value;
  }

  static int? _finiteInt(Object? value) =>
      value is num && value.isFinite ? value.toInt() : null;

  static List<double>? _finiteNumbers(Object? value, {required int expected}) {
    if (value is! List || value.length != expected) return null;
    final numbers = value
        .map((item) => item is num && item.isFinite ? item.toDouble() : null)
        .toList();
    return numbers.every((item) => item != null)
        ? numbers.cast<double>()
        : null;
  }

  static Map<String, Object?> _measurement(List<double> values, String unit) =>
      {
        'values': values,
        'unit': unit,
        'display': values.map((value) => value.toStringAsFixed(3)).join(', '),
      };

  static void _measurementValue(
    Map<String, Object?> source,
    Map<String, Object?> output,
    String key,
    String unit,
  ) {
    final value = source[key];
    if (value is num && value.isFinite) {
      output[key] = _measurement([value.toDouble()], unit);
    }
  }
}
