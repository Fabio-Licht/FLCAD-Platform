import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/desktop/panels/panel_presentation_models.dart';

void main() {
  test('Inspector projection creates ordered Basic and Advanced sections', () {
    final model = InspectorPresentationModel.fromSnapshot({
      'inspector.selectionState': 'single',
      'inspector.documentEntity': {
        'id': 'dimension-1',
        'name': 'Diameter',
        'type': 'constraint',
        'selectionDomain': 'document',
        'available': true,
        'properties': {
          'name': 'Diameter',
          'visibility': true,
          'triangleCount': 12,
          'drivingDimension': {
            'value': 20.0,
            'unit': 'mm',
            'editable': true,
          },
          'stepTechnicalName': 'DIM_001',
        },
      },
    });

    final entity = model.entities.single;
    expect(
      entity.sections.map((section) => section.id),
      ['identity', 'reference', 'geometry', 'feature', 'sketch', 'dimension',
        'topology', 'surface', 'advanced'],
    );
    expect(entity.sections.where((section) => !section.advanced).map((s) => s.id),
        ['identity', 'reference', 'geometry', 'dimension']);
    expect(entity.sections.where((section) => section.advanced).map((s) => s.id),
        ['feature', 'sketch', 'topology', 'surface', 'advanced']);
    final dimension = entity.sections
        .singleWhere((section) => section.id == 'dimension')
        .properties
        .single;
    expect(dimension.label, 'Cota');
    expect(dimension.unit, 'mm');
    expect(dimension.access, PanelPropertyAccess.editable);
    expect(dimension.intent, 'inspector.sketch.dimension.edit');
  });

  test('Inspector projection keeps selection domains and unavailable values explicit', () {
    final model = InspectorPresentationModel.fromSnapshot({
      'inspector.selectionState': 'multiple',
      'inspector.documentEntity': null,
      'inspector.operationalEntities': [
        {
          'id': 'op-1',
          'name': 'Mesh region',
          'type': 'region',
          'selectionDomain': 'operational',
          'available': true,
          'properties': {'ownerId': 'doc-1', 'area': null},
        },
      ],
    });

    expect(model.selectionState, 'multiple');
    expect(model.entities.single.selectionDomain, 'operational');
    final area = model.entities.single.sections
        .singleWhere((section) => section.id == 'geometry')
        .properties
        .single;
    expect(area.availability, PanelPropertyAvailability.unavailable);
    expect(area.label, 'Área');
  });

  test('technical keys are not exposed as raw labels and values remain JSON-safe', () {
    final property = InspectorPropertyModel.fromSnapshot(
      key: 'sceneKind',
      value: 'mesh',
    );
    expect(property.label, 'Tipo de cena');
    expect(property.label, isNot('sceneKind'));
    expect(
      TechnicalValueFormatter.format({
        'min': [0, 1, 2],
        'max': [3, 4, 5],
        'unit': 'mm',
      }),
      '(0, 1, 2) → (3, 4, 5) mm',
    );
  });
}
