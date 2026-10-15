import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/cad_viewport/rendering/reference_visibility_mask.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';

CadSceneEntity entity(
  String id,
  CadSceneEntityKind kind, {
  Map<String, dynamic> geometry = const {},
}) => CadSceneEntity(id: id, kind: kind, geometry: geometry);

void main() {
  test('classifica WCS e referências auxiliares', () {
    expect(
      isAuxiliaryReferenceVisual(
        entity('project:world:xy-plane', CadSceneEntityKind.plane),
      ),
      isTrue,
    );
    expect(
      isAuxiliaryReferenceVisual(
        entity(
          'managed-plane:1',
          CadSceneEntityKind.plane,
          geometry: {'displayColor': 'constructionPlane'},
        ),
      ),
      isTrue,
    );
    expect(
      isAuxiliaryReferenceVisual(
        entity(
          'managed-axis:1',
          CadSceneEntityKind.axis,
          geometry: {'displayColor': 'constructionVector'},
        ),
      ),
      isTrue,
    );
  });

  test('preserva superfícies planares documentais e previews', () {
    expect(
      isAuxiliaryReferenceVisual(
        entity(
          'surface:documented',
          CadSceneEntityKind.surface,
          geometry: {'surfaceKind': 'plane'},
        ),
      ),
      isFalse,
    );
    expect(
      isAuxiliaryReferenceVisual(
        entity(
          'surface:preview',
          CadSceneEntityKind.preview,
          geometry: {'surfaceKind': 'plane', 'previewOnly': true},
        ),
      ),
      isFalse,
    );
    expect(
      isAuxiliaryReferenceVisual(
        entity(
          'preview:guide',
          CadSceneEntityKind.preview,
          geometry: {'displayColor': 'constructionPlane', 'previewOnly': true},
        ),
      ),
      isFalse,
    );
  });

  test('classifica curvas de referência sem afetar curvas documentais', () {
    expect(
      isAuxiliaryReferenceVisual(
        entity(
          'reference:curve',
          CadSceneEntityKind.curve,
          geometry: {'displayColor': 'referenceCurve'},
        ),
      ),
      isTrue,
    );
    expect(
      isAuxiliaryReferenceVisual(
        entity(
          'curve:documented',
          CadSceneEntityKind.curve,
          geometry: {'displayColor': 'solidEdge'},
        ),
      ),
      isFalse,
    );
  });
}
