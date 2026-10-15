import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/native/viewport_render_diagnostics.dart';
import 'package:flcad_mobile/app/cad_viewport/professional_cad_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';

CadSceneEntity _entity(
  CadSceneEntityKind kind, {
  bool selected = false,
  bool transparent = false,
  bool withEdges = false,
  String? normalsOrigin,
}) => CadSceneEntity(
  id: 'internal-native-token-shaped-id',
  kind: kind,
  selected: selected,
  transparent: transparent,
  geometry: {
    'nodes': [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
    'triangles': [0, 1, 2],
    'normals': [0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0],
    ...?normalsOrigin == null ? null : {'normalsOrigin': normalsOrigin},
    if (withEdges)
      'topologicalEdges': [
        [0.0, 0.0, 0.0, 1.0, 0.0, 0.0],
      ],
  },
);

CadSceneGraph _scene(CadSceneEntity entity) => CadSceneGraph()..upsert(entity);

void main() {
  test('marca a ausência de normais sem inventar a origem', () {
    final entity = _entity(CadSceneEntityKind.mesh);
    final geometry = Map<String, dynamic>.from(entity.geometry)
      ..remove('normals');
    final report = buildViewportRenderDiagnostic(
      scene: _scene(
        CadSceneEntity(id: entity.id, kind: entity.kind, geometry: geometry),
      ),
      backend: ViewportBackend.flutterCanvas,
      requestedBackend: ViewportBackend.flutterCanvas,
      style: CadRenderStyle.shaded,
      fallbackReason: null,
      highlightActive: false,
    );

    expect(report.entities.single.hasNormals, isFalse);
    expect(report.entities.single.normalsOrigin, isNull);
  });

  test('classifica STL sem topologia e preserva origem das normais', () {
    final report = buildViewportRenderDiagnostic(
      scene: _scene(
        _entity(CadSceneEntityKind.mesh, normalsOrigin: 'calculatedByAdapter'),
      ),
      backend: ViewportBackend.flutterCanvas,
      requestedBackend: ViewportBackend.nativeGpu,
      style: CadRenderStyle.shaded,
      fallbackReason: 'malha sem arestas topológicas CAD para este modo',
      highlightActive: false,
    );

    expect(report.backend, 'flutterCanvas');
    expect(report.fallbackReason, contains('malha'));
    expect(report.entities.single.type, 'stl_or_mesh');
    expect(report.entities.single.triangles, 1);
    expect(report.entities.single.topologicalEdges, 0);
    expect(report.entities.single.normalsOrigin, 'calculatedByAdapter');
    expect(
      report.entities.single.classification,
      'mesh_sem_topologia_explicita',
    );
    expect(report.entities.single.presentationId, 'entity-1');
    expect(report.toStructuredLog(), isNot(contains('internal-native-token')));
  });

  test('classifica BREP com e sem arestas topológicas', () {
    final complete = buildViewportRenderDiagnostic(
      scene: _scene(_entity(CadSceneEntityKind.solid, withEdges: true)),
      backend: ViewportBackend.nativeGpu,
      requestedBackend: ViewportBackend.nativeGpu,
      style: CadRenderStyle.hiddenLine,
      fallbackReason: null,
      highlightActive: true,
    );
    final incomplete = buildViewportRenderDiagnostic(
      scene: _scene(_entity(CadSceneEntityKind.surface)),
      backend: ViewportBackend.flutterCanvas,
      requestedBackend: ViewportBackend.nativeGpu,
      style: CadRenderStyle.wireframe,
      fallbackReason: 'superfície sem arestas topológicas CAD para este modo',
      highlightActive: false,
    );

    expect(complete.entities.single.type, 'brep_solid');
    expect(complete.entities.single.topologicalEdges, 1);
    expect(complete.depthTest, isTrue);
    expect(complete.depthWrite, isTrue);
    expect(complete.highlightActive, isTrue);
    expect(incomplete.entities.single.type, 'brep_surface');
    expect(
      incomplete.entities.single.classification,
      'brep_sem_arestas_topologicas',
    );
  });

  test('transparent mode reports alpha e depth write efetivos', () {
    final report = buildViewportRenderDiagnostic(
      scene: _scene(
        _entity(CadSceneEntityKind.preview, selected: true, transparent: true),
      ),
      backend: ViewportBackend.nativeGpu,
      requestedBackend: ViewportBackend.nativeGpu,
      style: CadRenderStyle.transparent,
      fallbackReason: null,
      highlightActive: false,
    );

    expect(report.alpha, .22);
    expect(report.depthTest, isTrue);
    expect(report.depthWrite, isFalse);
    expect(report.selectedEntityCount, 1);
    expect(report.highlightActive, isTrue);
    expect(report.entities.single.classification, 'preview_transitorio');
  });
}
