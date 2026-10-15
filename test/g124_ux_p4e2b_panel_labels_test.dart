import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_presentation_models.dart';

void main() {
  test('docked and detached Inspector labels share the same presentation', () {
    expect(
      InspectorPresentationLabels.section('Driving Dimension'),
      'Cota controladora',
    );
    expect(
      InspectorPresentationLabels.section('Feature Lifecycle'),
      'Ciclo de vida do recurso',
    );
    expect(
      InspectorPresentationLabels.property('Source Entity'),
      'Entidade de origem',
    );
    expect(
      InspectorPresentationLabels.selectionDomain('document'),
      'documental',
    );
    expect(
      InspectorPresentationLabels.selectionDomain('operational'),
      'operacional',
    );
  });

  test('presentation labels do not change stable panel identities', () {
    expect(panelDescriptor(PanelId.explorer).title, 'Explorer');
    expect(panelDescriptor(PanelId.inspector).title, 'Inspector');
    expect(panelIdFromName('explorer'), PanelId.explorer);
    expect(panelIdFromName('inspector'), PanelId.inspector);
  });

  test('unavailable and editable property contracts remain typed', () {
    final unavailable = InspectorPropertyModel(
      id: 'drivingDimension',
      label: 'Cota controladora',
      value: null,
      availability: PanelPropertyAvailability.unavailable,
    );
    final editable = InspectorPropertyModel(
      id: 'drivingDimension',
      label: 'Cota controladora',
      value: 20,
      unit: 'mm',
      access: PanelPropertyAccess.editable,
      intent: 'inspector.sketch.dimension.edit',
    );

    expect(unavailable.availability, PanelPropertyAvailability.unavailable);
    expect(editable.access, PanelPropertyAccess.editable);
    expect(editable.intent, 'inspector.sketch.dimension.edit');
  });
}
