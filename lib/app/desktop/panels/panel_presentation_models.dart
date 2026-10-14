/// Immutable, JSON-safe presentation models shared by docked and detached
/// panel renderers.
///
/// These types deliberately know nothing about Flutter, desktop_multi_window,
/// CAD runtime objects, FFI handles, or commands. They are adapters over the
/// existing panel snapshots, not a second source of document state.
library;

enum PanelPropertyAvailability { available, unavailable }

enum PanelPropertyAccess { readOnly, editable }

final class ExplorerTreeModel {
  static const semanticGroups = [
    'Entidades',
    'Meshes',
    'References',
    'Sketches',
    'Curves',
    'Surfaces',
    'Solids',
    'Reference Curves',
    'Inspection',
    'Construction',
  ];

  ExplorerTreeModel({
    required this.groups,
    required Iterable<String> documentSelection,
    required Iterable<String> operationalSelection,
    required Iterable<String> expandedGroups,
  })  : documentSelection = Set.unmodifiable(documentSelection),
        operationalSelection = Set.unmodifiable(operationalSelection),
        expandedGroups = Set.unmodifiable(expandedGroups);

  final List<ExplorerGroupModel> groups;
  final Set<String> documentSelection;
  final Set<String> operationalSelection;
  final Set<String> expandedGroups;

  factory ExplorerTreeModel.fromSnapshot(Map<String, Object?> snapshot) {
    final rawRows = snapshot['entities'];
    final rows = rawRows is List ? rawRows.whereType<Map>() : const <Map>[];
    final rawGroups = snapshot['groups'];
    final rowGroups = rows
        .map((row) => row['group'])
        .whereType<String>()
        .toSet();
    final groupNames = <String>{
      ...semanticGroups,
      ...rowGroups,
      if (rawGroups is Map)
        ...rawGroups.keys.whereType<String>().where(rowGroups.contains),
    }.toList()..sort();
    final groups = <String, List<ExplorerNodeModel>>{
      for (final name in groupNames) name: <ExplorerNodeModel>[],
    };
    for (final raw in rows) {
      final node = ExplorerNodeModel.fromSnapshot(raw);
      (groups[node.group] ??= <ExplorerNodeModel>[]).add(node);
    }
    for (final nodes in groups.values) {
      nodes.sort((a, b) {
        final aChild = a.parentId == null ? 0 : 1;
        final bChild = b.parentId == null ? 0 : 1;
        return aChild != bChild
            ? aChild.compareTo(bChild)
            : a.id.compareTo(b.id);
      });
    }
    final sortedGroups = groups.entries
        .map(
          (entry) => ExplorerGroupModel(
            id: entry.key,
            label: entry.key,
            nodes: entry.value,
          ),
        )
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return ExplorerTreeModel(
      groups: sortedGroups,
      documentSelection: _strings(
        snapshot['explorer.documentSelection'] ??
            snapshot['documentSelection'] ??
            snapshot['selection'],
      ),
      operationalSelection: _strings(
        snapshot['explorer.operationalSelection'] ??
            snapshot['operationalSelection'],
      ),
      expandedGroups: _strings(snapshot['expandedGroups']),
    );
  }

  Map<String, Object?> toJson() => {
        'groups': [for (final group in groups) group.toJson()],
        'documentSelection': documentSelection.toList()..sort(),
        'operationalSelection': operationalSelection.toList()..sort(),
        'expandedGroups': expandedGroups.toList()..sort(),
      };

  factory ExplorerTreeModel.fromJson(Map<String, Object?> json) {
    final rawGroups = json['groups'];
    return ExplorerTreeModel(
      groups: rawGroups is List
          ? rawGroups
                .whereType<Map>()
                .map(ExplorerGroupModel.fromJson)
                .toList()
          : const [],
      documentSelection: _strings(json['documentSelection']),
      operationalSelection: _strings(json['operationalSelection']),
      expandedGroups: _strings(json['expandedGroups']),
    );
  }

  static Set<String> _strings(Object? value) => value is Iterable
      ? value.whereType<String>().toSet()
      : <String>{};
}

final class ExplorerGroupModel {
  ExplorerGroupModel({
    required this.id,
    required this.label,
    required Iterable<ExplorerNodeModel> nodes,
  }) : nodes = List.unmodifiable(nodes);

  final String id;
  final String label;
  final List<ExplorerNodeModel> nodes;

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'nodes': [for (final node in nodes) node.toJson()],
      };

  factory ExplorerGroupModel.fromJson(Map raw) => ExplorerGroupModel(
        id: raw['id'] as String? ?? '',
        label: raw['label'] as String? ?? raw['id'] as String? ?? '',
        nodes: raw['nodes'] is List
            ? (raw['nodes'] as List)
                  .whereType<Map>()
                  .map(ExplorerNodeModel.fromSnapshot)
            : const <ExplorerNodeModel>[],
      );
}

final class ExplorerNodeModel {
  ExplorerNodeModel({
    required this.id,
    required this.label,
    required this.kind,
    required this.iconSemantic,
    required this.group,
    this.parentId,
    required this.visible,
    required this.available,
    required Iterable<String> actions,
  }) : actions = Set.unmodifiable(actions);

  final String id;
  final String label;
  final String kind;
  final String iconSemantic;
  final String group;
  final String? parentId;
  final bool visible;
  final bool available;
  final Set<String> actions;

  factory ExplorerNodeModel.fromSnapshot(Map raw) {
    final kind = raw['kind'] as String? ?? 'unknown';
    final id = raw['id'] as String? ?? '';
    return ExplorerNodeModel(
      id: id,
      label: raw['label'] as String? ?? id,
      kind: kind,
      iconSemantic: raw['iconSemantic'] as String? ?? kind,
      group: raw['group'] as String? ?? kind,
      parentId: raw['parent'] as String?,
      visible: raw['visible'] is bool ? raw['visible'] as bool : true,
      available: raw['available'] is bool ? raw['available'] as bool : true,
      actions: raw['actions'] is Iterable
          ? (raw['actions'] as Iterable).whereType<String>()
          : const <String>[],
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'kind': kind,
        'iconSemantic': iconSemantic,
        'group': group,
        if (parentId != null) 'parent': parentId,
        'visible': visible,
        'available': available,
        'actions': actions.toList()..sort(),
      };
}

final class InspectorPresentationModel {
  InspectorPresentationModel({
    required this.selectionState,
    required Iterable<InspectorEntityModel> entities,
  }) : entities = List.unmodifiable(entities);

  final String selectionState;
  final List<InspectorEntityModel> entities;

  factory InspectorPresentationModel.fromSnapshot(Map<String, Object?> snapshot) {
    final entities = <InspectorEntityModel>[];
    final document = snapshot['inspector.documentEntity'];
    if (document is Map) entities.add(InspectorEntityModel.fromSnapshot(document));
    final operational = snapshot['inspector.operationalEntities'];
    if (operational is List) {
      for (final entity in operational.whereType<Map>()) {
        entities.add(InspectorEntityModel.fromSnapshot(entity));
      }
    }
    return InspectorPresentationModel(
      selectionState: snapshot['inspector.selectionState'] as String? ?? 'none',
      entities: entities,
    );
  }

  factory InspectorPresentationModel.fromJson(Map<String, Object?> json) =>
      InspectorPresentationModel(
        selectionState: json['selectionState'] as String? ?? 'none',
        entities: json['entities'] is List
            ? (json['entities'] as List)
                  .whereType<Map>()
                  .map(InspectorEntityModel.fromJson)
            : const <InspectorEntityModel>[],
      );

  Map<String, Object?> toJson() => {
        'selectionState': selectionState,
        'entities': [for (final entity in entities) entity.toJson()],
      };
}

final class InspectorEntityModel {
  InspectorEntityModel({
    required this.id,
    required this.name,
    required this.type,
    required this.selectionDomain,
    required this.available,
    required Iterable<InspectorSectionModel> sections,
  }) : sections = List.unmodifiable(sections);

  final String id;
  final String name;
  final String type;
  final String selectionDomain;
  final bool available;
  final List<InspectorSectionModel> sections;

  factory InspectorEntityModel.fromSnapshot(Map raw) {
    final properties = raw['properties'];
    final entries = properties is Map ? properties.entries : const <MapEntry>[];
    return InspectorEntityModel(
      id: raw['id'] as String? ?? '',
      name: raw['name'] as String? ?? raw['id'] as String? ?? 'Entidade',
      type: raw['type'] as String? ?? 'unknown',
      selectionDomain: raw['selectionDomain'] as String? ?? 'unknown',
      available: raw['available'] == true,
      sections: [
        for (final category in _categories)
          InspectorSectionModel(
            id: category.$1,
            label: category.$2,
            advanced: category.$3,
            properties: [
              for (final entry in entries)
                if (_categoryFor(entry.key.toString()) == category.$1)
                  InspectorPropertyModel.fromSnapshot(
                    key: entry.key.toString(),
                    value: entry.value,
                  ),
            ],
          ),
      ],
    );
  }

  factory InspectorEntityModel.fromJson(Map raw) => InspectorEntityModel(
        id: raw['id'] as String? ?? '',
        name: raw['name'] as String? ?? '',
        type: raw['type'] as String? ?? 'unknown',
        selectionDomain: raw['selectionDomain'] as String? ?? 'unknown',
        available: raw['available'] == true,
        sections: raw['sections'] is List
            ? (raw['sections'] as List)
                  .whereType<Map>()
                  .map(InspectorSectionModel.fromJson)
            : const <InspectorSectionModel>[],
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'selectionDomain': selectionDomain,
        'available': available,
        'sections': [for (final section in sections) section.toJson()],
      };

  static const _categories = [
    ('identity', 'Identidade', false),
    ('reference', 'Referência', false),
    ('geometry', 'Geometria', false),
    ('feature', 'Feature', true),
    ('sketch', 'Sketch', true),
    ('dimension', 'Cota', false),
    ('topology', 'Topologia', true),
    ('surface', 'Superfície', true),
    ('advanced', 'Avançado', true),
  ];

  static String _categoryFor(String key) => switch (key) {
        'name' || 'format' || 'sceneKind' || 'visibility' => 'identity',
        'origin' || 'tolerance' || 'confidence' => 'reference',
        'vertexCount' ||
        'triangleCount' ||
        'bounds' ||
        'normals' ||
        'area' ||
        'volume' ||
        'length' => 'geometry',
        'featureLifecycle' => 'feature',
        'drivingDimension' => 'dimension',
        'cadSemanticKind' || 'cadVisualType' || 'stepTechnicalName' =>
          'advanced',
        _ => 'advanced',
      };
}

final class InspectorSectionModel {
  InspectorSectionModel({
    required this.id,
    required this.label,
    required Iterable<InspectorPropertyModel> properties,
    this.advanced = false,
  }) : properties = List.unmodifiable(properties);

  final String id;
  final String label;
  final bool advanced;
  final List<InspectorPropertyModel> properties;

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'advanced': advanced,
        'properties': [for (final property in properties) property.toJson()],
      };

  factory InspectorSectionModel.fromJson(Map raw) => InspectorSectionModel(
        id: raw['id'] as String? ?? '',
        label: raw['label'] as String? ?? '',
        advanced: raw['advanced'] == true,
        properties: raw['properties'] is List
            ? (raw['properties'] as List)
                  .whereType<Map>()
                  .map(InspectorPropertyModel.fromJson)
            : const <InspectorPropertyModel>[],
      );
}

final class InspectorPropertyModel {
  InspectorPropertyModel({
    required this.id,
    required this.label,
    required Object? value,
    this.unit,
    this.precision = 3,
    this.availability = PanelPropertyAvailability.available,
    this.access = PanelPropertyAccess.readOnly,
    this.intent,
  }) : value = _jsonValue(value);

  final String id;
  final String label;
  final Object? value;
  final String? unit;
  final int precision;
  final PanelPropertyAvailability availability;
  final PanelPropertyAccess access;
  final String? intent;

  factory InspectorPropertyModel.fromSnapshot({
    required String key,
    required Object? value,
  }) {
    final map = value is Map ? value : const <Object?, Object?>{};
    final rawValue = map.containsKey('value') ? map['value'] : value;
    final editable = map['editable'] == true &&
        key == 'drivingDimension' &&
        rawValue is num &&
        rawValue.isFinite;
    return InspectorPropertyModel(
      id: key,
      label: _friendlyLabel(key),
      value: rawValue,
      unit: map['unit'] as String?,
      availability: value == null
          ? PanelPropertyAvailability.unavailable
          : PanelPropertyAvailability.available,
      access: editable
          ? PanelPropertyAccess.editable
          : PanelPropertyAccess.readOnly,
      intent: editable ? 'inspector.sketch.dimension.edit' : null,
    );
  }

  factory InspectorPropertyModel.fromJson(Map raw) => InspectorPropertyModel(
        id: raw['id'] as String? ?? '',
        label: raw['label'] as String? ?? '',
        value: raw['value'],
        unit: raw['unit'] as String?,
        precision: raw['precision'] is int ? raw['precision'] as int : 3,
        availability: raw['availability'] == 'unavailable'
            ? PanelPropertyAvailability.unavailable
            : PanelPropertyAvailability.available,
        access: raw['access'] == 'editable'
            ? PanelPropertyAccess.editable
            : PanelPropertyAccess.readOnly,
        intent: raw['intent'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'value': value,
        if (unit != null) 'unit': unit,
        'precision': precision,
        'availability': availability.name,
        'access': access.name,
        if (intent != null) 'intent': intent,
      };

  static String _friendlyLabel(String key) => switch (key) {
        'name' => 'Nome',
        'format' => 'Formato',
        'visibility' => 'Visibilidade',
        'origin' => 'Origem',
        'tolerance' => 'Tolerância',
        'confidence' => 'Confiança',
        'drivingDimension' => 'Cota',
        'triangleCount' => 'Triângulos',
        'vertexCount' => 'Vértices',
        'bounds' => 'Caixa envolvente',
        'normals' => 'Normais',
        'area' => 'Área',
        'volume' => 'Volume',
        'length' => 'Comprimento',
        'sceneKind' => 'Tipo de cena',
        'cadSemanticKind' => 'Tipo semântico CAD',
        'cadVisualType' => 'Tipo visual CAD',
        'stepTechnicalName' => 'Nome STEP',
        'featureLifecycle' => 'Ciclo de vida',
        'sceneEntityId' => 'Entidade de cena',
        'meanCurvature' => 'Curvatura média',
        'measurementSafe' => 'Medição segura',
        'presentationOnly' => 'Somente apresentação',
        'ownerId' => 'ID do proprietário',
        'ownerDomain' => 'Proprietário',
        'documentId' => 'ID do documento',
        'revision' => 'Revisão',
        'health' => 'Saúde',
        _ => _humanize(key),
      };

  static String _humanize(String key) {
    final spaced = key
        .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (match) {
          return '${match.group(1)} ${match.group(2)}';
        })
        .replaceAll('_', ' ')
        .trim();
    if (spaced.isEmpty) return 'Technical property';
    return spaced[0].toUpperCase() + spaced.substring(1);
  }
}

abstract final class TechnicalValueFormatter {
  static String format(Object? value, {String? unit, int precision = 3}) {
    if (value == null) return 'Unavailable';
    if (value is Map && value['display'] is String) {
      return value['display'] as String;
    }
    if (value is Map && value['min'] is List && value['max'] is List) {
      final min = (value['min'] as List).join(', ');
      final max = (value['max'] as List).join(', ');
      return '($min) → ($max)${value['unit'] == null ? '' : ' ${value['unit']}'}';
    }
    if (value is double) {
      return '${(value as num).toStringAsFixed(precision)}${unit == null ? '' : ' $unit'}';
    }
    if (value is num) return '$value${unit == null ? '' : ' $unit'}';
    if (value is bool) return value ? 'Yes' : 'No';
    return value.toString();
  }
}

Object? _jsonValue(Object? value) {
  if (value == null || value is String || value is bool) return value;
  if (value is num) {
    if (!value.isFinite) throw ArgumentError('non-finite values are not serializable');
    return value;
  }
  if (value is List) return List.unmodifiable(value.map(_jsonValue));
  if (value is Map) {
    return Map.unmodifiable({
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: _jsonValue(entry.value),
    });
  }
  throw ArgumentError('unsupported presentation value: ${value.runtimeType}');
}
