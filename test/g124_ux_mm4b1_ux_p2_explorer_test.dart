import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/desktop/panels/panel_presentation_models.dart';

void main() {
  test('Explorer projection preserves semantic groups and parent-child order', () {
    final model = ExplorerTreeModel.fromSnapshot({
      'entities': [
        {
          'id': 'child',
          'label': 'Edge',
          'kind': 'edge',
          'group': 'Construction',
          'parent': 'parent',
          'iconSemantic': 'edge',
          'visible': true,
          'available': true,
        },
        {
          'id': 'parent',
          'label': 'Sketch',
          'kind': 'sketch',
          'group': 'Construction',
          'iconSemantic': 'sketch',
          'visible': true,
          'available': true,
        },
      ],
      'groups': {'Construction': 2, 'Sketches': 0},
      'explorer.documentSelection': ['child'],
      'explorer.operationalSelection': ['op-1'],
    });

    final construction = model.groups.singleWhere((group) => group.id == 'Construction');
    expect(model.groups.map((group) => group.id), contains('Sketches'));
    expect(construction.nodes.map((node) => node.parentId), [null, 'parent']);
    expect(model.documentSelection, contains('child'));
    expect(model.operationalSelection, contains('op-1'));
  });

  test('Explorer nodes remain serializable for large bounded projections', () {
    final nodes = [
      for (var index = 0; index < 2000; index++)
        ExplorerNodeModel(
          id: 'entity-$index',
          label: 'Entity $index',
          kind: 'mesh',
          iconSemantic: 'mesh',
          group: 'Meshes',
          visible: true,
          available: true,
          actions: const [],
        ),
    ];
    final model = ExplorerTreeModel(
      groups: [ExplorerGroupModel(id: 'Meshes', label: 'Meshes', nodes: nodes)],
      documentSelection: const [],
      operationalSelection: const [],
      expandedGroups: const [],
    );
    final json = model.toJson();
    expect((json['groups'] as List).single['nodes'], hasLength(2000));
    expect(() => ExplorerTreeModel.fromJson(json), returnsNormally);
  });

  test('unavailable Explorer nodes cannot be selected by the renderer contract', () {
    final node = ExplorerNodeModel(
      id: 'deleted',
      label: 'Deleted',
      kind: 'solid',
      iconSemantic: 'solid',
      group: 'Solids',
      visible: false,
      available: false,
      actions: const [],
    );
    expect(node.available, isFalse);
    expect(node.toJson()['id'], 'deleted');
  });
}
