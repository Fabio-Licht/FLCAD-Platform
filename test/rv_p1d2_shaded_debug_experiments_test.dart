import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/cad_viewport/rendering/shaded_debug_experiments.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';

void main() {
  test('experiências Shaded permanecem desligadas por padrão', () {
    expect(kFlcadDevShadedHideReferenceOverlays, isFalse);
    expect(kFlcadDevShadedDerivedNormals, isFalse);
  });

  test('normais derivadas são apresentação-only e não mutam a entrada', () {
    final geometry = <String, dynamic>{
      'nodes': [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
      'triangles': [0, 1, 2],
      'normals': [0.0, 0.0, -1.0, 0.0, 0.0, -1.0, 0.0, 0.0, -1.0],
    };
    final nodes = List<num>.from(geometry['nodes'] as List);
    final normals = List<num>.from(geometry['normals'] as List);
    final derived = shadedDerivedNormals(geometry)!;
    expect(derived, [0, 0, 1, 0, 0, 1, 0, 0, 1]);
    expect(geometry['nodes'], nodes);
    expect(geometry['normals'], normals);
    expect(shadedDerivedNormals(geometry), same(derived));
  });

  test('classifica referências e curvas de referência como overlays', () {
    CadSceneEntity entity(
      CadSceneEntityKind kind, [
      String? displayColor,
      bool previewOnly = false,
    ]) =>
        CadSceneEntity(
          id: 'test',
          kind: kind,
          geometry: {
            'displayColor': ?displayColor,
            if (previewOnly) 'previewOnly': true,
          },
        );

    expect(isShadedReferenceOverlay(entity(CadSceneEntityKind.plane)), isTrue);
    expect(
      isShadedReferenceOverlay(
        entity(CadSceneEntityKind.surface, 'surfacePreviewBlue', true),
      ),
      isTrue,
    );
    expect(
      isShadedReferenceOverlay(entity(CadSceneEntityKind.surface)),
      isFalse,
    );
    expect(
      isShadedReferenceOverlay(
        entity(CadSceneEntityKind.curve, 'referenceCurve'),
      ),
      isTrue,
    );
    expect(isShadedReferenceOverlay(entity(CadSceneEntityKind.mesh)), isFalse);
  });
}
