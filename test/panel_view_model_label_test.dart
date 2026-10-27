import 'package:flcad_mobile/app/desktop/panels/panel_view_model.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Explorer keeps stored labels and uses Geometria only for sketch rows', () {
    const uuid = '11111111-2222-3333-4444-555555555555';
    final document = CadDocument(
      projectId: 'p',
      entities: {
        'mesh': CadDocumentEntity(
          id: 'mesh',
          kind: CadDocumentEntityKind.import,
          data: {'name': 'imported-mesh'},
        ),
        'solid': CadDocumentEntity(
          id: 'solid-1',
          kind: CadDocumentEntityKind.solid,
          data: const {},
        ),
        'uuid-curve': CadDocumentEntity(
          id: 'curve-1',
          kind: CadDocumentEntityKind.curve,
          data: {'name': uuid},
        ),
        'sketch-root': CadDocumentEntity(
          id: 'sketch-1',
          kind: CadDocumentEntityKind.sketch,
          data: {'name': 'Sketch 1'},
        ),
        'sketch-line': CadDocumentEntity(
          id: uuid,
          kind: CadDocumentEntityKind.sketch,
          data: {
            'name': uuid,
            'parentSketchId': 'sketch-1',
            'sketchEntity': {'type': 'line'},
          },
        ),
      },
      revisions: [CadDocumentRevision(1, 'create', DateTime.utc(2026, 1, 1))],
      parameters: const {'units': 'mm'},
    );

    final labels = {
      for (final row in PanelViewModel.explorerRows(document))
        row['id']! as String: row['label'],
    };

    expect(labels['mesh'], 'imported-mesh');
    expect(labels['solid-1'], 'solid-1');
    expect(labels['curve-1'], uuid);
    expect(labels['sketch-1'], 'Sketch 1');
    expect(labels[uuid], 'Geometria');
  });
}
