import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/native/viewport_render_diagnostics.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_derived_edge_classifier.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_derived_edge_refiner.dart';
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
  test('inclui estatísticas meshDerived do resultado já classificado', () {
    final scene = _scene(_entity(CadSceneEntityKind.mesh));
    // Prime the same cache used by the native adapter. The diagnostic itself
    // must not classify the mesh again.
    CadSceneDisplayAdapter().initial(scene);
    final report = buildViewportRenderDiagnostic(
      scene: scene,
      backend: ViewportBackend.nativeGpu,
      requestedBackend: ViewportBackend.nativeGpu,
      style: CadRenderStyle.hiddenLine,
      fallbackReason: null,
      highlightActive: false,
      nativeSceneReady: true,
    );
    final mesh = report.entities.single.meshDerived!;
    expect(mesh['source'], meshDerivedEdgeSource);
    expect(mesh['segments'], 3);
    expect(mesh['openBoundary'], 3);
    expect(mesh['crease'], 0);
    expect(mesh['ambiguous'], 0);
    expect(mesh['coplanarDiscarded'], 0);
    expect(mesh['classificationMicros'], isA<int>());
    expect(mesh['estimatedBytes'], greaterThan(0));
    expect(mesh['nativeBufferAcknowledged'], isTrue);
    expect((mesh['length'] as Map)['min'], greaterThan(0));
    expect(mesh.containsKey('refinement'), isFalse);
    expect(report.nativeSceneReady, isTrue);
    final overlay = viewportDiagnosticOverlayText(report);
    expect(overlay, contains('d3d11 · hiddenLine'));
    expect(overlay, contains('sceneReady: true'));
    expect(overlay, contains('meshDerived: 3→3'));
    scene.dispose();
  });

  test(
    'appliedToPresentation só liga com flag experimental e filtro aplicado',
    () {
      final scene = _scene(_entity(CadSceneEntityKind.mesh));
      CadSceneDisplayAdapter().initial(scene);
      final observation = cachedMeshDerivedEdgeObservation(
        scene.entities.single,
      )!;
      expect(kFlcadDevMeshDerivedEdgeRefinement, isFalse);
      expect(
        const MeshDerivedEdgeRefiner().refine(observation.classification).toDiagnostics(
          experimentalFlag: false,
        )['appliedToPresentation'],
        isFalse,
      );
      expect(
        const MeshDerivedEdgeRefiner().refine(observation.classification).toDiagnostics(
          experimentalFlag: true,
        )['appliedToPresentation'],
        const MeshDerivedEdgeRefiner().refine(observation.classification).applied,
      );
      scene.dispose();
    },
  );

  test(
    'Shaded nativo não exige arestas e Wireframe STL permanece CAD-only',
    () {
      final scene = _scene(_entity(CadSceneEntityKind.mesh));
      CadSceneDisplayAdapter().initial(scene);
      final shaded = buildViewportRenderDiagnostic(
        scene: scene,
        backend: ViewportBackend.nativeGpu,
        requestedBackend: ViewportBackend.nativeGpu,
        style: CadRenderStyle.shaded,
        fallbackReason: null,
        highlightActive: false,
        nativeSceneReady: true,
      );
      expect(shaded.mode, 'shaded');
      expect(nativeSceneUnsupportedReason(scene, style: 0), isNull);
      expect(
        nativeSceneUnsupportedReason(scene, style: 2),
        contains('arestas topológicas'),
      );
      expect(viewportDiagnosticOverlayText(shaded), contains('d3d11 · shaded'));
      scene.dispose();
    },
  );

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
