import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../scene/cad_scene_graph.dart';

/// Debug-only comparison switches. Both are false in normal and release builds.
const bool kFlcadDevShadedHideReferenceOverlays =
    kDebugMode &&
    bool.fromEnvironment(
      'FLCAD_DEV_SHADED_HIDE_REFERENCE_OVERLAYS',
      defaultValue: false,
    );

const bool kFlcadDevShadedDerivedNormals =
    kDebugMode &&
    bool.fromEnvironment(
      'FLCAD_DEV_SHADED_DERIVED_NORMALS',
      defaultValue: false,
    );

const bool kFlcadDevShadedLightingExperiment =
    kDebugMode &&
    bool.fromEnvironment(
      'FLCAD_DEV_SHADED_LIGHTING_EXPERIMENT',
      defaultValue: false,
    );

/// Camera-dependent STL edge comparison modes. These are deliberately
/// compile-time Debug switches: the commercial renderer has no alternate
/// path unless one of the explicit experiments is requested.
enum FlcadDevStlSilhouetteMode { original, silhouette, silhouetteWithCreases }

const bool kFlcadDevStlSilhouetteModeB =
    kDebugMode &&
    bool.fromEnvironment(
      'FLCAD_DEV_STL_SILHOUETTE_MODE_B',
      defaultValue: false,
    );

const bool kFlcadDevStlSilhouetteModeC =
    kDebugMode &&
    bool.fromEnvironment(
      'FLCAD_DEV_STL_SILHOUETTE_MODE_C',
      defaultValue: false,
    );

const FlcadDevStlSilhouetteMode kFlcadDevStlSilhouetteMode =
    kFlcadDevStlSilhouetteModeC
    ? FlcadDevStlSilhouetteMode.silhouetteWithCreases
    : kFlcadDevStlSilhouetteModeB
    ? FlcadDevStlSilhouetteMode.silhouette
    : FlcadDevStlSilhouetteMode.original;

String get flcadDevStlSilhouetteModeLabel => switch (
  kFlcadDevStlSilhouetteMode
) {
  FlcadDevStlSilhouetteMode.original => 'A',
  FlcadDevStlSilhouetteMode.silhouette => 'B',
  FlcadDevStlSilhouetteMode.silhouetteWithCreases => 'C',
};

bool isShadedReferenceOverlay(CadSceneEntity entity) {
  // Transient previews explicitly marked by the owning operation are safe to
  // hide for this visual comparison. Documented planar CAD surfaces are not.
  if (entity.geometry['previewOnly'] == true) return true;
  if (entity.kind == CadSceneEntityKind.gizmo ||
      entity.kind == CadSceneEntityKind.axis ||
      entity.kind == CadSceneEntityKind.plane ||
      entity.kind == CadSceneEntityKind.coordinateSystem) {
    return true;
  }
  final color = entity.geometry['displayColor'];
  return color == 'referenceCurve' ||
      color == 'referenceCurveHighlight' ||
      color == 'originalSectionReference' ||
      color == 'alignmentGuide';
}

/// Derives presentation-only vertex normals from the current triangle data.
/// The input map and its lists are never mutated. Invalid data returns null.
final Expando<List<double>> _derivedNormalCache = Expando(
  'shaded-derived-normals',
);

List<double>? shadedDerivedNormals(Map<String, dynamic> geometry) {
  final cached = _derivedNormalCache[geometry];
  if (cached != null) return cached;
  final nodes = geometry['nodes'];
  final triangles = geometry['triangles'];
  if (nodes is! List || triangles is! List || nodes.length % 3 != 0) {
    return null;
  }
  final vertexCount = nodes.length ~/ 3;
  final result = List<double>.filled(nodes.length, 0);
  for (var offset = 0; offset + 2 < triangles.length; offset += 3) {
    final ia = triangles[offset];
    final ib = triangles[offset + 1];
    final ic = triangles[offset + 2];
    if (ia is! num || ib is! num || ic is! num) return null;
    final a = ia.toInt(), b = ib.toInt(), c = ic.toInt();
    if (a < 0 ||
        b < 0 ||
        c < 0 ||
        a >= vertexCount ||
        b >= vertexCount ||
        c >= vertexCount) {
      return null;
    }
    final ax =
        (nodes[b * 3] as num).toDouble() - (nodes[a * 3] as num).toDouble();
    final ay =
        (nodes[b * 3 + 1] as num).toDouble() -
        (nodes[a * 3 + 1] as num).toDouble();
    final az =
        (nodes[b * 3 + 2] as num).toDouble() -
        (nodes[a * 3 + 2] as num).toDouble();
    final bx =
        (nodes[c * 3] as num).toDouble() - (nodes[a * 3] as num).toDouble();
    final by =
        (nodes[c * 3 + 1] as num).toDouble() -
        (nodes[a * 3 + 1] as num).toDouble();
    final bz =
        (nodes[c * 3 + 2] as num).toDouble() -
        (nodes[a * 3 + 2] as num).toDouble();
    final nx = ay * bz - az * by;
    final ny = az * bx - ax * bz;
    final nz = ax * by - ay * bx;
    for (final index in [a, b, c]) {
      result[index * 3] += nx;
      result[index * 3 + 1] += ny;
      result[index * 3 + 2] += nz;
    }
  }
  for (var index = 0; index < vertexCount; index++) {
    final offset = index * 3;
    final length = math.sqrt(
      result[offset] * result[offset] +
          result[offset + 1] * result[offset + 1] +
          result[offset + 2] * result[offset + 2],
    );
    if (!length.isFinite || length <= 1e-20) return null;
    result[offset] /= length;
    result[offset + 1] /= length;
    result[offset + 2] /= length;
  }
  final immutable = List<double>.unmodifiable(result);
  _derivedNormalCache[geometry] = immutable;
  return immutable;
}
