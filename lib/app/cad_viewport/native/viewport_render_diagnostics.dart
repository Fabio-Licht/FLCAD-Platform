import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../professional_cad_viewport_widget.dart';
import '../rendering/cad_canvas_normal_pipeline.dart';
import '../rendering/mesh_derived_edge_classifier.dart';
import '../rendering/shaded_debug_experiments.dart';
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
    this.nativeSceneReady = false,
    this.referenceOverlaysVisible = true,
    this.derivedNormalsActive = false,
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
  final bool nativeSceneReady;
  final bool referenceOverlaysVisible;
  final bool derivedNormalsActive;

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
    'nativeSceneReady': nativeSceneReady,
    'referenceOverlaysVisible': referenceOverlaysVisible,
    'derivedNormalsActive': derivedNormalsActive,
  };

  String toStructuredLog() => jsonEncode(toJson());
}

String viewportDiagnosticOverlayText(ViewportRenderDiagnosticReport report) {
  final triangles = report.entities.fold<int>(
    0,
    (sum, item) => sum + item.triangles,
  );
  final edges = report.entities.fold<int>(
    0,
    (sum, item) => sum + item.topologicalEdges,
  );
  final meshSegments = report.entities.fold<int>(
    0,
    (sum, item) => sum + ((item.meshDerived?['segments'] as int?) ?? 0),
  );
  final lines = <String>[
    '${report.backend} · ${report.mode} · ${report.entities.length} ent.',
    'tri: $triangles · arestas: $edges',
    'sceneReady: ${report.nativeSceneReady}',
    'meshDerived: $meshSegments→$meshSegments',
    'overlays: ${report.referenceOverlaysVisible ? 'on' : 'off'} · derivedNormals: ${report.derivedNormalsActive}',
  ];
  return lines.join('\n');
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
    this.meshDerived,
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
  final Map<String, Object?>? meshDerived;

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
    if (meshDerived != null) 'meshDerived': meshDerived,
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
  bool nativeSceneReady = false,
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
        _entityDiagnostic(
          visible.elementAt(index),
          index,
          nativeSceneReady: native && nativeSceneReady,
        ),
    ],
    depthTest: native,
    depthWrite: native && style != CadRenderStyle.transparent,
    alpha: style == CadRenderStyle.transparent ? .22 : 1,
    selectedEntityCount: visible.where((entity) => entity.selected).length,
    highlightActive:
        highlightActive || visible.any((entity) => entity.selected),
    nativeSceneReady: native && nativeSceneReady,
    referenceOverlaysVisible: !kFlcadDevShadedHideReferenceOverlays,
    derivedNormalsActive: kFlcadDevShadedDerivedNormals,
  );
}

ViewportEntityDiagnostic _entityDiagnostic(
  CadSceneEntity entity,
  int index, {
  required bool nativeSceneReady,
}) {
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
  final observation = cachedMeshDerivedEdgeObservation(entity);
  final meshDerived = observation == null
      ? null
      : <String, Object?>{
          'source': meshDerivedEdgeSource,
          'segments': observation.classification.statistics.segments,
          'openBoundary':
              observation.classification.statistics.openBoundaryEdges,
          'crease': observation.classification.statistics.creaseEdges,
          'ambiguous': observation.classification.statistics.ambiguousEdges,
          'coplanarDiscarded':
              observation.classification.statistics.coplanarEdgesDiscarded,
          'creaseAngleHistogram':
              observation.classification.statistics.creaseAngleHistogram,
          'length': <String, Object?>{
            'min': observation.lengthStatistics.minimum,
            'mean': observation.lengthStatistics.average,
            'max': observation.lengthStatistics.maximum,
            'p50': observation.lengthStatistics.p50,
            'p90': observation.lengthStatistics.p90,
            'p95': observation.lengthStatistics.p95,
            'p99': observation.lengthStatistics.p99,
          },
          'classificationMicros': observation.elapsedMicros,
          'estimatedBytes':
              observation.classification.statistics.estimatedBytes,
          'truncated': observation.classification.statistics.truncated,
          'diagnostics': observation.classification.diagnostics,
          'nativeBufferAcknowledged': nativeSceneReady,
        };
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
    meshDerived: meshDerived,
  );
}
