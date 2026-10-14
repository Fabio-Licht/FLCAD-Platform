import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/desktop/panels/panel_inspector_widgets.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_presentation_models.dart';

InspectorPropertyModel _property({
  String id = 'area',
  String label = 'Área',
  Object? value = 12.3456,
  String? unit = 'mm²',
  PanelPropertyAvailability availability = PanelPropertyAvailability.available,
}) => InspectorPropertyModel(
      id: id,
      label: label,
      value: value,
      unit: unit,
      availability: availability,
    );

void main() {
  testWidgets('shared Inspector components render PT-BR labels and units', (
    tester,
  ) async {
    final entity = InspectorEntityModel(
      id: 'e1',
      name: 'Face 1',
      type: 'face',
      selectionDomain: 'document',
      available: true,
      sections: const [],
    );
    final section = InspectorSectionModel(
      id: 'geometry',
      label: 'Geometria',
      properties: [_property()],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 240,
              child: Column(
                children: [
                  InspectorEntityHeader(entity: entity),
                  InspectorPropertySection(
                    section: section,
                    children: [InspectorPropertyRow(property: _property())],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Face 1'), findsOneWidget);
    expect(find.text('Geometria'), findsOneWidget);
    expect(find.text('12.346 mm²'), findsOneWidget);
    expect(find.text('Área'), findsOneWidget);
  });

  testWidgets('section expands and collapses and mode selector changes', (
    tester,
  ) async {
    var advanced = false;
    final section = InspectorSectionModel(
      id: 'identity',
      label: 'Identidade',
      properties: const [],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              InspectorModeSelector(
                advanced: advanced,
                onChanged: (value) => advanced = value,
              ),
              InspectorPropertySection(
                section: section,
                children: const [Text('Conteúdo')],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Conteúdo'), findsOneWidget);
    await tester.tap(find.text('Identidade'));
    await tester.pump();
    expect(find.text('Conteúdo'), findsNothing);
    await tester.tap(find.text('Avançado'));
    await tester.pump();
    expect(advanced, isTrue);
  });

  testWidgets('unavailable and read-only indicators are accessible at narrow width', (
    tester,
  ) async {
    final unavailable = _property(
      availability: PanelPropertyAvailability.unavailable,
      value: null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 150,
            child: Column(
              children: [
                InspectorPropertyRow(property: unavailable),
                const InspectorAccessIndicator(
                  access: PanelPropertyAccess.readOnly,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Indisponível'), findsOneWidget);
    expect(find.bySemanticsLabel('Somente leitura'), findsOneWidget);
  });

  testWidgets('numeric editor validates and submits the existing value contract', (
    tester,
  ) async {
    double? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InspectorNumericEditor(
            label: 'Cota',
            value: 20,
            unit: 'mm',
            onSubmitted: (value) => submitted = value,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '30');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, 30);
    expect(find.text('mm'), findsOneWidget);
  });
}
