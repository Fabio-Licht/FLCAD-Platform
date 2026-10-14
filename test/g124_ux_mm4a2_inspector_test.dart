import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_inspector_view_model.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_protocol.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_view_model.dart';
import 'package:flcad_mobile/app/operational_entities/operational_entity.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final documentEntity = CadDocumentEntity(
    id: 'face:1',
    kind: CadDocumentEntityKind.face,
    data: const {
      'name': 'Face 1',
      'sceneGeometry': {
        'origin': [1, 2, 3],
      },
      'sceneVisible': true,
    },
  );
  final document = CadDocument(
    projectId: 'project-1',
    entities: {'face:1': documentEntity},
    revisions: const [],
    parameters: const {},
  );
  final operational = OperationalEntity(
    id: 'mesh-region:1',
    type: OperationalEntityType.meshRegion,
    ownerId: 'face:1',
    ownerDomain: 'document',
    documentId: 'project-1',
    revision: 1,
    label: 'Region 1',
    capabilities: const {OperationalCapability.inspectable},
    properties: const {
      'area': 12.5,
      'measurementSafe': true,
      'sceneEntityId': 'scene:1',
    },
  );

  test('projeta seleção documental e operacional sem objetos CAD', () {
    final snapshot = PanelInspectorViewModel.build(
      document: document,
      documentSelection: const {'face:1'},
      operationalSelection: const ['mesh-region:1'],
      operationalEntities: {'mesh-region:1': operational},
    );

    expect(snapshot[PanelInspectorViewModelKeys.selectionState], 'multiple');
    expect(snapshot[PanelInspectorViewModelKeys.documentSelectionIds], [
      'face:1',
    ]);
    expect(snapshot[PanelInspectorViewModelKeys.operationalSelectionIds], [
      'mesh-region:1',
    ]);
    final documentRow =
        snapshot[PanelInspectorViewModelKeys.documentEntity] as Map;
    expect(documentRow['selectionDomain'], 'document');
    expect((documentRow['properties'] as Map)['origin'], {
      'values': [1.0, 2.0, 3.0],
      'unit': 'mm',
      'display': '1.000, 2.000, 3.000',
    });
    final operationalRow =
        (snapshot[PanelInspectorViewModelKeys.operationalEntities] as List)
                .single
            as Map;
    expect(operationalRow['selectionDomain'], 'operational');
    expect((operationalRow['properties'] as Map)['area']['unit'], 'mm²');
    expect(_containsForbiddenPayload(snapshot), isFalse);
  });

  test('representa sem seleção, múltipla e entidade indisponível', () {
    Map<String, Object?> build(Set<String> ids) =>
        PanelInspectorViewModel.build(
          document: document,
          documentSelection: ids,
          operationalSelection: const [],
          operationalEntities: const {},
        );

    expect(build(const {})[PanelInspectorViewModelKeys.selectionState], 'none');
    expect(
      build(const {
        'face:1',
        'missing:1',
      })[PanelInspectorViewModelKeys.selectionState],
      'unavailable',
    );
    expect(
      PanelInspectorViewModel.build(
        document: document,
        documentSelection: const {'face:1'},
        operationalSelection: const ['missing-op'],
        operationalEntities: const {},
      )[PanelInspectorViewModelKeys.selectionState],
      'unavailable',
    );
  });

  test('Inspector recebe snapshot versionado sem permissão de mutação', () {
    final viewModel = PanelViewModel.build(
      panelId: PanelId.inspector,
      sessionId: 7,
      projectId: 'project-1',
      stateRevision: 9,
      document: document,
      selection: const {'face:1'},
      documentSelection: const {'face:1'},
      operationalSelection: const [],
      operationalEntities: const {},
      limits: const PanelProtocolLimits(),
    );

    expect(viewModel[PanelViewModelKeys.panelId], 'inspector');
    expect(viewModel[PanelViewModelKeys.sessionId], 7);
    expect(viewModel[PanelViewModelKeys.stateRevision], 9);
    expect(
      PanelViewModelKeys.all,
      contains(PanelViewModelKeys.inspectorSelectionState),
    );
    expect(_containsForbiddenPayload(viewModel), isFalse);
  });
}

bool _containsForbiddenPayload(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key.toString().toLowerCase();
      if (key.contains('handle') ||
          key.contains('token') ||
          key.contains('closure') ||
          key.contains('native')) {
        return true;
      }
      if (_containsForbiddenPayload(entry.value)) return true;
    }
  } else if (value is Iterable) {
    for (final item in value) {
      if (_containsForbiddenPayload(item)) return true;
    }
  }
  return false;
}
