import '../scene/cad_scene_graph.dart';

/// Identifies auxiliary reference graphics without treating every planar CAD
/// surface or every gizmo as a reference overlay.
bool isAuxiliaryReferenceVisual(CadSceneEntity entity) {
  if (entity.geometry['previewOnly'] == true) return false;
  final color = entity.geometry['displayColor'];
  if (entity.id.contains(':world:') &&
      const {
        CadSceneEntityKind.plane,
        CadSceneEntityKind.axis,
        CadSceneEntityKind.point,
        CadSceneEntityKind.coordinateSystem,
      }.contains(entity.kind)) {
    return true;
  }
  if (color == 'constructionPlane' ||
      color == 'constructionVector' ||
      color == 'constructionPoint' ||
      color == 'referenceCurve' ||
      color == 'referenceCurveHighlight' ||
      color == 'originalSectionReference') {
    return true;
  }
  return entity.kind == CadSceneEntityKind.coordinateSystem &&
      entity.geometry['type'] == 'coordinateSystem';
}
