import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/desktop/panels/panel_presentation_models.dart';

void main() {
  test('Explorer model preserves groups, hierarchy, selection and round-trip', () {
    final model = ExplorerTreeModel.fromSnapshot({
      'entities': [
        {
          'id': 'edge-1',
          'label': 'Edge 1',
          'kind': 'edge',
          'group': 'Construction',
          'parent': 'sketch-1',
          'iconSemantic': 'edge',
          'visible': true,
        },
      ],
      'groups': {'Construction': 1},
      'documentSelection': ['edge-1'],
      'operationalSelection': ['op-1'],
      'expandedGroups': ['Construction'],
    });

    final construction = model.groups.singleWhere((group) => group.id == 'Construction');
    expect(construction.nodes.single.parentId, 'sketch-1');
    expect(construction.nodes.single.iconSemantic, 'edge');
    expect(model.documentSelection, contains('edge-1'));
    expect(model.operationalSelection, contains('op-1'));
    expect(ExplorerTreeModel.fromJson(model.toJson()).toJson(), model.toJson());
  });

  test('Inspector model keeps friendly labels, units and authorized edit only', () {
    final model = InspectorPresentationModel.fromSnapshot({
      'inspector.selectionState': 'single',
      'inspector.documentEntity': {
        'id': 'd1',
        'name': 'Diameter',
        'type': 'constraint',
        'selectionDomain': 'document',
        'available': true,
        'properties': {
          'drivingDimension': {
            'value': 20.0,
            'unit': 'mm',
            'editable': true,
          },
          'triangleCount': 12,
        },
      },
    });

    final sections = model.entities.single.sections;
    final properties = [
      for (final section in sections)
        ...section.properties,
    ];
    final dimension = properties.singleWhere((property) => property.id == 'drivingDimension');
    final triangles = properties.singleWhere((property) => property.id == 'triangleCount');
    expect(dimension.label, 'Cota');
    expect(dimension.unit, 'mm');
    expect(dimension.access, PanelPropertyAccess.editable);
    expect(dimension.intent, 'inspector.sketch.dimension.edit');
    expect(triangles.label, 'Triângulos');
    expect(triangles.access, PanelPropertyAccess.readOnly);
    expect(InspectorPresentationModel.fromJson(model.toJson()).toJson(), model.toJson());
  });

  test('presentation values reject non-serializable objects and format technical values', () {
    expect(
      () => InspectorPropertyModel(
        id: 'bad',
        label: 'Bad',
        value: Object(),
      ),
      throwsArgumentError,
    );
    expect(TechnicalValueFormatter.format(2.5, unit: 'mm'), '2.500 mm');
    expect(TechnicalValueFormatter.format(null), 'Unavailable');
  });
}
