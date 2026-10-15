import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../professional_cad_viewport_widget.dart';
import '../rendering/cad_canvas_normal_pipeline.dart';
import '../scene/cad_scene_graph.dart';
import 'native_viewport_bridge.dart';

/// Development-only, presentation-safe description of one viewport decision.
/// It intentionally contains no native handles, tokens or CAD objects.
@immutable
class ViewportRenderDiagnosticReport {
  const ViewportRenderDiagnosticReport({
    required this.backend,
    required this.requestedBackend,
    required this.mode,
    required this.fallbackReason,
    required this.entities,
    required this.depthTest,
    required this.depthWrite,
    required this.alpha,
    required this.selectedEntityCount,
    required this.highlightActive,
  });

  final String backend;
  final String requestedBackend;
  final String mode;
  final String? fallbackReason;
  final List<ViewportEntityDiagnostic> entities;
  final bool depthTest;
  final bool depthWrite;
  final double alpha;
  final int selectedEntityCount;
  final bool highlightActive;

  Map<String, Object?> toJson() => {
    'backend': backend,
    'requestedBackend': requestedBackend,
    'mode': mode,
    'fallbackReason': fallbackReason,
    'entities': entities.map((entity) => entity.toJson()).toList(),
    'depthTest': depthTest,
    'depthWrite': depthWrite,
    'alpha': alpha,
    'selectedEntityCount': selectedEntityCount,
    'highlightActive': highlightActive,
  };

  String toStructuredLog() => jsonEncode(toJson());
}

@immutable
class ViewportEntityDiagnostic {
  const ViewportEntityDiagnostic({
    required this.presentationId,
    required this.type,
    required this.triangles,
    required this.topologicalEdges,
    required this.hasNormals,
    required this.normalsOrigin,
    required this.selected,
    required this.transparent,
    required this.classification,
  });

  final String presentationId;
  final String type;
  final int triangles;
  final int topologicalEdges;
  final bool hasNormals;
  final String? normalsOrigin;
  final bool selected;
  final bool transparent;
  final String classification;

  Map<String, Object?> toJson() => {
    'presentationId': presentationId,
    'type': type,
    'triangles': triangles,
    'topologicalEdges': topologicalEdges,
    'hasNormals': hasNormals,
    'normalsOrigin': normalsOrigin,
    'selected': selected,
    'transparent': transparent,
    'classification': classification,
  };
}

String viewportDiagnosticMode(CadRenderStyle style) => switch (style) {
  CadRenderStyle.shaded => 'shaded',
  CadRenderStyle.wireframe => 'wireframe',
  CadRenderStyle.hiddenLine => 'hiddenLine',
  CadRenderStyle.transparent => 'transparent',
  CadRenderStyle.ghost => 'ghost',
};

String viewportDiagnosticBackend(ViewportBackend backend) => switch (backend) {
  ViewportBackend.nativeGpu => 'd3d11',
  ViewportBackend.flutterCanvas => 'flutterCanvas',
};

ViewportRenderDiagnosticReport buildViewportRenderDiagnostic({
  required CadSceneGraph scene,
  required ViewportBackend backend,
  required ViewportBackend requestedBackend,
  required CadRenderStyle style,
  required String? fallbackReason,
  required bool highlightActive,
}) {
  final native = backend == ViewportBackend.nativeGpu;
  final effectiveFallback = native
      ? null
      : fallbackReason ??
            (requestedBackend == ViewportBackend.flutterCanvas
                ? 'Flutter Canvas solicitado'
                : 'backend nativo indisponível');
  final visible = scene.entities.where(
    (entity) => entity.visible && !isNativeViewportOverlay(entity),
  );
  return ViewportRenderDiagnosticReport(
    backend: viewportDiagnosticBackend(backend),
    requestedBackend: viewportDiagnosticBackend(requestedBackend),
    mode: viewportDiagnosticMode(style),
    fallbackReason: effectiveFallback,
    entities: [
      for (var index = 0; index < visible.length; index++)
        _entityDiagnostic(visible.elementAt(index), index),
    ],
    depthTest: native,
    depthWrite: native && style != CadRenderStyle.transparent,
    alpha: style == CadRenderStyle.transparent ? .22 : 1,
    selectedEntityCount: visible.where((entity) => entity.selected).length,
    highlightActive:
        highlightActive || visible.any((entity) => entity.selected),
  );
}

ViewportEntityDiagnostic _entityDiagnostic(CadSceneEntity entity, int index) {
  final geometry = cadPresentationGeometry(entity.geometry);
  final triangles = geometry['triangles'];
  final normals = geometry['normals'];
  final edges = geometry['topologicalEdges'];
  final hasNormals = normals is List && normals.isNotEmpty;
  final edgeCount = edges is List ? edges.length : 0;
  final hasTopology = edgeCount > 0;
  final type = switch (entity.kind) {
    CadSceneEntityKind.mesh => 'stl_or_mesh',
    CadSceneEntityKind.surface => 'brep_surface',
    CadSceneEntityKind.solid => 'brep_solid',
    CadSceneEntityKind.preview => 'preview',
    _ => entity.kind.name,
  };
  final classification = type == 'preview'
      ? 'preview_transitorio'
      : type == 'stl_or_mesh' && !hasTopology
      ? 'mesh_sem_topologia_explicita'
      : type == 'brep_surface' && !hasTopology
      ? 'brep_sem_arestas_topologicas'
      : type == 'brep_solid' && !hasTopology
      ? 'brep_solido_sem_arestas_topologicas'
      : 'apresentacao_geometrica';
  return ViewportEntityDiagnostic(
    presentationId: 'entity-${index + 1}',
    type: type,
    triangles: triangles is List ? triangles.length ~/ 3 : 0,
    topologicalEdges: edgeCount,
    hasNormals: hasNormals,
    normalsOrigin: geometry['normalsOrigin'] as String?,
    selected: entity.selected,
    transparent: entity.transparent,
    classification: classification,
  );
}
