import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../../../core/geometric_kernel/linear_algebra/matrices.dart';
import 'camera_pan_audit.dart';

enum CadProjectionMode { perspective, orthographic }

enum CadStandardView {
  perspective,
  top,
  bottom,
  front,
  back,
  right,
  left,
  isometric,
}

class CadCameraState {
  const CadCameraState({
    required this.eye,
    required this.target,
    required this.rotationCenter,
    required this.focusPoint,
    required this.up,
    required this.projectionMode,
    required this.viewScale,
    required this.fieldOfViewRadians,
    required this.nearPlane,
    required this.farPlane,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.presentationTranslation,
    required this.presentationOffsetNdcX,
    required this.presentationOffsetNdcY,
  });
  final Vector3 eye;
  final Vector3 target;
  final Vector3 rotationCenter;
  final Vector3 focusPoint;
  final Vector3 up;
  final CadProjectionMode projectionMode;
  final double viewScale;
  final double fieldOfViewRadians;
  final double nearPlane;
  final double farPlane;
  final double viewportWidth;
  final double viewportHeight;
  final Vector3 presentationTranslation;
  final double presentationOffsetNdcX;
  final double presentationOffsetNdcY;
}

class CadCameraController extends ChangeNotifier {
  CadCameraController({
    // Same initial yaw (.55), pitch (.38), distance (3) and Y-up convention
    // used by the Render Lab reference camera.
    this.eye = const Vector3(
      1.45620343492616,
      1.112761408238948,
      -2.3751281237952884,
    ),
    this.target = Vector3.zero,
    Vector3? rotationCenter,
    Vector3? focusPoint,
    this.up = const Vector3(0, 1, 0),
  }) : rotationCenter = rotationCenter ?? target,
       focusPoint = focusPoint ?? rotationCenter ?? target;

  Vector3 eye;
  Vector3 target;
  Vector3 rotationCenter;
  Vector3 focusPoint;
  Vector3 up;
  Vector3 presentationTranslation = Vector3.zero;
  double presentationOffsetNdcX = 0;
  double presentationOffsetNdcY = 0;
  CadProjectionMode projectionMode = CadProjectionMode.perspective;
  double viewportWidth = 1;
  double viewportHeight = 1;
  // Shared with the Render Lab reference camera.
  double fieldOfViewRadians = 42 * math.pi / 180;
  double nearPlane = .01;
  double farPlane = 100000;
  double viewScale = 10;
  double get orthographicHeight => viewScale;
  set orthographicHeight(double value) => viewScale = value;
  CadCameraState? _preSketchState;
  double? _preSketchModelRadius;
  double _modelRadius = 1;

  bool get isInSketchMode => _preSketchState != null;

  CadCameraState snapshot() => CadCameraState(
    eye: eye,
    target: target,
    rotationCenter: rotationCenter,
    focusPoint: focusPoint,
    up: up,
    projectionMode: projectionMode,
    viewScale: viewScale,
    fieldOfViewRadians: fieldOfViewRadians,
    nearPlane: nearPlane,
    farPlane: farPlane,
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
    presentationTranslation: presentationTranslation,
    presentationOffsetNdcX: presentationOffsetNdcX,
    presentationOffsetNdcY: presentationOffsetNdcY,
  );

  void enterSketch({
    required Vector3 origin,
    required Vector3 normal,
    required Vector3 xDirection,
    double visualSize = 60,
  }) {
    _preSketchState ??= snapshot();
    _preSketchModelRadius ??= _modelRadius;
    _modelRadius = math.max(visualSize, .01);
    final n = normal.normalized;
    final x = xDirection.normalized;
    final y = n.cross(x).normalized;
    final distance = math.max(visualSize * 1.5, .01);
    target = origin;
    rotationCenter = origin;
    focusPoint = origin;
    // Sketch entry is deterministic and never inherits the side of the
    // previous camera: observe the positive side of the support normal, with
    // local +X to the right and local +Y upward.
    eye = origin + n * distance;
    up = y;
    projectionMode = CadProjectionMode.orthographic;
    viewScale = math.max(visualSize * 1.1, .01);
    nearPlane = math.max(distance / 10000, 1e-6);
    farPlane = math.max(distance * 1000, 10);
    notifyListeners();
  }

  void exitSketch() {
    final state = _preSketchState;
    if (state == null) return;
    eye = state.eye;
    target = state.target;
    rotationCenter = state.rotationCenter;
    focusPoint = state.focusPoint;
    up = state.up;
    projectionMode = state.projectionMode;
    viewScale = state.viewScale;
    fieldOfViewRadians = state.fieldOfViewRadians;
    nearPlane = state.nearPlane;
    farPlane = state.farPlane;
    _modelRadius = _preSketchModelRadius ?? _modelRadius;
    _preSketchModelRadius = null;
    presentationTranslation = state.presentationTranslation;
    presentationOffsetNdcX = state.presentationOffsetNdcX;
    presentationOffsetNdcY = state.presentationOffsetNdcY;
    _preSketchState = null;
    notifyListeners();
  }

  /// Closes the Sketch camera session while retaining its normal-to-support
  /// orientation. A following Fit can then frame the profile and part without
  /// restoring the unrelated pre-Sketch view.
  void retainSketchView() {
    if (_preSketchState == null) return;
    _preSketchState = null;
    notifyListeners();
  }

  Matrix4 get viewMatrix {
    final effectiveEye = eye;
    final effectiveTarget = target;
    final forward = (effectiveTarget - effectiveEye).normalized;
    final right = forward.cross(_safeUp()).normalized;
    final cameraUp = right.cross(forward);
    return Matrix4([
      right.x,
      right.y,
      right.z,
      -right.dot(effectiveEye),
      cameraUp.x,
      cameraUp.y,
      cameraUp.z,
      -cameraUp.dot(effectiveEye),
      -forward.x,
      -forward.y,
      -forward.z,
      forward.dot(effectiveEye),
      0,
      0,
      0,
      1,
    ]);
  }

  Vector3 get presentationEye => eye;
  Vector3 get presentationTarget => target;

  void translateOperationalScene(Vector3 delta) {
    if (!delta.x.isFinite || !delta.y.isFinite || !delta.z.isFinite) return;
    presentationTranslation = presentationTranslation + delta;
    final view = target - eye;
    final distance = view.length;
    if (distance <= 1e-12 || viewportWidth <= 0 || viewportHeight <= 0) return;
    final forward = view / distance;
    final right = forward.cross(_safeUp()).normalized;
    final cameraUp = right.cross(forward).normalized;
    if (projectionMode == CadProjectionMode.orthographic) {
      presentationOffsetNdcX +=
          2 * right.dot(delta) / (viewScale * viewportWidth / viewportHeight);
      presentationOffsetNdcY += 2 * cameraUp.dot(delta) / viewScale;
    } else {
      final focal = 1 / math.tan(fieldOfViewRadians / 2);
      presentationOffsetNdcX +=
          right.dot(delta) *
          focal /
          (distance * viewportWidth / viewportHeight);
      presentationOffsetNdcY += cameraUp.dot(delta) * focal / distance;
    }
    notifyListeners();
  }

  Matrix4 get projectionMatrix {
    final aspect = viewportWidth / viewportHeight;
    if (projectionMode == CadProjectionMode.orthographic) {
      final halfH = viewScale / 2;
      final halfW = halfH * aspect;
      final base = Matrix4([
        1 / halfW,
        0,
        0,
        0,
        0,
        1 / halfH,
        0,
        0,
        0,
        0,
        -2 / (farPlane - nearPlane),
        -(farPlane + nearPlane) / (farPlane - nearPlane),
        0,
        0,
        0,
        1,
      ]);
      return _withPresentationOffset(base);
    }
    final f = 1 / math.tan(fieldOfViewRadians / 2);
    final base = Matrix4([
      f / aspect,
      0,
      0,
      0,
      0,
      f,
      0,
      0,
      0,
      0,
      (farPlane + nearPlane) / (nearPlane - farPlane),
      2 * farPlane * nearPlane / (nearPlane - farPlane),
      0,
      0,
      -1,
      0,
    ]);
    return _withPresentationOffset(base);
  }

  Matrix4 _withPresentationOffset(Matrix4 projection) {
    if (presentationOffsetNdcX == 0 && presentationOffsetNdcY == 0) {
      return projection;
    }
    final shift = Matrix4([
      1,
      0,
      0,
      presentationOffsetNdcX,
      0,
      1,
      0,
      presentationOffsetNdcY,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
    ]);
    return shift * projection;
  }

  Matrix4 get viewProjectionMatrix => projectionMatrix * viewMatrix;
  Matrix4 get inverseViewMatrix => viewMatrix.inverse();
  Matrix4 get inverseProjectionMatrix => projectionMatrix.inverse();
  Matrix4 get inverseViewProjectionMatrix => viewProjectionMatrix.inverse();

  void resize(double width, double height) {
    if (width <= 0 || height <= 0) return;
    if (viewportWidth == width && viewportHeight == height) return;
    viewportWidth = width;
    viewportHeight = height;
    notifyListeners();
  }

  void orbit(double yaw, double pitch) {
    if (!yaw.isFinite || !pitch.isFinite) return;
    final pivotBefore = viewProjectionMatrix.transformPoint(focusPoint);
    final safeUp = _safeUp();
    var eyeOffset = eye - focusPoint;
    var targetOffset = target - focusPoint;
    eyeOffset = _rotate(eyeOffset, safeUp, -yaw);
    targetOffset = _rotate(targetOffset, safeUp, -yaw);
    final yawEye = focusPoint + eyeOffset;
    final yawTarget = focusPoint + targetOffset;
    final yawForward = (yawTarget - yawEye).normalized;
    var right = yawForward.cross(safeUp);
    if (right.length <= 1e-10) return;
    right = right.normalized;
    final safePitch = pitch.clamp(-math.pi / 2 + .01, math.pi / 2 - .01);
    eyeOffset = _rotate(eyeOffset, right, safePitch);
    targetOffset = _rotate(targetOffset, right, safePitch);
    eye = focusPoint + eyeOffset;
    target = focusPoint + targetOffset;
    final forward = (target - eye).normalized;
    up = right.cross(forward).normalized;
    final pivotAfter = viewProjectionMatrix.transformPoint(focusPoint);
    final correctionX = pivotBefore.x - pivotAfter.x;
    final correctionY = pivotBefore.y - pivotAfter.y;
    if (correctionX.isFinite && correctionY.isFinite) {
      presentationOffsetNdcX += correctionX;
      presentationOffsetNdcY += correctionY;
    }
    notifyListeners();
  }

  void pan(double horizontal, double vertical) {
    if (!horizontal.isFinite || !vertical.isFinite) return;
    final viewDirection = target - eye;
    final viewDistance = viewDirection.length;
    if (viewDistance <= 1e-12) return;
    final forward = viewDirection / viewDistance;
    final right = forward.cross(_safeUp()).normalized;
    final cameraUp = right.cross(forward).normalized;
    final delta = right * horizontal + cameraUp * vertical;
    final translatedEye = eye + delta;
    // Reconstruct Target from the unchanged orthonormal camera basis instead
    // of adding to Eye and Target independently. This prevents floating-point
    // cancellation from introducing a residual angular drift during long pan
    // sequences, especially for geometry far from the world origin.
    eye = translatedEye;
    target = translatedEye + forward * viewDistance;
    up = cameraUp;
    rotationCenter = rotationCenter + delta;
    focusPoint = focusPoint + delta;
    notifyListeners();
  }

  /// FreeCAD-compatible camera-position translation. `target` is translated
  /// only because this camera stores orientation as Eye -> Target; it is the
  /// representational focal point, not an operational navigation center.
  /// RotationCenter, FocusPoint, Up, projection and scale remain unchanged.
  void translateCameraPosition(Vector3 delta) {
    if (!delta.x.isFinite || !delta.y.isFinite || !delta.z.isFinite) return;
    CameraPanAudit.record('camera.pan()');
    eye = eye + delta;
    target = target + delta;
    CameraPanAudit.record('Estado da câmera\n${auditState()}');
    notifyListeners();
    CameraPanAudit.record(
      'CadCameraController.notifyListeners() concluído\n${auditState()}',
    );
  }

  String auditState() =>
      'Eye=(${eye.x},${eye.y},${eye.z}) '
      'Target=(${target.x},${target.y},${target.z}) '
      'Up=(${up.x},${up.y},${up.z}) '
      'RotationCenter=(${rotationCenter.x},${rotationCenter.y},${rotationCenter.z}) '
      'FocusPoint=(${focusPoint.x},${focusPoint.y},${focusPoint.z})';

  /// Translates the camera parallel to the viewport without changing its
  /// orientation. Positive screen X drags the view to the right; positive
  /// screen Y drags it down, matching a "sheet of paper" pan gesture.
  void panViewportPixels(double deltaX, double deltaY) {
    if (!deltaX.isFinite || !deltaY.isFinite) return;
    final viewDirection = target - eye;
    final worldPerPixel = projectionMode == CadProjectionMode.orthographic
        ? viewScale / math.max(viewportHeight, 1)
        : 2 *
              viewDirection.length *
              math.tan(fieldOfViewRadians / 2) /
              math.max(viewportHeight, 1);
    pan(-deltaX * worldPerPixel, deltaY * worldPerPixel);
  }

  /// Applies a pan from one immutable gesture baseline. The result depends
  /// only on the total cursor displacement, never on pointer-event frequency.
  void panViewportPixelsFrom(
    CadCameraState baseline,
    double totalDeltaX,
    double totalDeltaY, {
    Vector3? surfaceAnchor,
  }) {
    if (!totalDeltaX.isFinite || !totalDeltaY.isFinite) return;
    final viewDirection = baseline.target - baseline.eye;
    final viewDistance = viewDirection.length;
    if (viewDistance <= 1e-12) return;
    final forward = viewDirection / viewDistance;
    final right = forward.cross(baseline.up).normalized;
    final cameraUp = right.cross(forward).normalized;
    final panDepth = surfaceAnchor == null
        ? viewDistance
        : (surfaceAnchor - baseline.eye).dot(forward);
    if (panDepth <= 1e-12) return;
    final worldPerPixel =
        baseline.projectionMode == CadProjectionMode.orthographic
        ? baseline.viewScale / math.max(baseline.viewportHeight, 1)
        : 2 *
              panDepth *
              math.tan(baseline.fieldOfViewRadians / 2) /
              math.max(baseline.viewportHeight, 1);
    final delta =
        right * (-totalDeltaX * worldPerPixel) +
        cameraUp * (totalDeltaY * worldPerPixel);

    eye = baseline.eye + delta;
    target = eye + viewDirection;
    rotationCenter = baseline.rotationCenter + delta;
    focusPoint = baseline.focusPoint + delta;
    up = baseline.up;
    projectionMode = baseline.projectionMode;
    viewScale = baseline.viewScale;
    fieldOfViewRadians = baseline.fieldOfViewRadians;
    nearPlane = baseline.nearPlane;
    farPlane = baseline.farPlane;
    notifyListeners();
  }

  void zoom(double factor, {Vector3? anchor}) {
    if (!factor.isFinite || factor <= 0) return;
    if (projectionMode == CadProjectionMode.orthographic) {
      final scale = (viewScale * factor)
          // Sketch sections can be very small relative to the document
          // bounds; keep enough headroom for inspecting sub-millimetric gaps.
          .clamp(_modelRadius * .002, _modelRadius * 1000000)
          .toDouble();
      final ratio = scale / viewScale;
      if (anchor != null) {
        final shift = (anchor - target) * (1 - ratio);
        eye = eye + shift;
        target = target + shift;
      }
      viewScale = scale;
    } else {
      final offset = eye - target;
      final direction = offset.length <= 1e-12
          ? const Vector3(1, -1, .7).normalized
          : offset.normalized;
      // Never let the eye cross the target or enter the near clipping plane.
      // Keeping a finite upper bound also prevents a wheel burst from making
      // the model effectively impossible to recover without Fit View.
      final distance = (offset.length * factor)
          .clamp(
            math.max(nearPlane * 4, _modelRadius * .002),
            math.min(farPlane * .8, _modelRadius * 1000000),
          )
          .toDouble();
      if (anchor == null) {
        eye = target + direction * distance;
      } else {
        final ratio = distance / math.max(offset.length, 1e-12);
        eye = anchor + (eye - anchor) * ratio;
        target = anchor + (target - anchor) * ratio;
      }
      viewScale = (viewScale * distance / math.max(offset.length, 1e-12))
          .clamp(_modelRadius * .002, _modelRadius * 1000000)
          .toDouble();
    }
    notifyListeners();
  }

  void setRotationCenter(Vector3 point) {
    if (!point.x.isFinite || !point.y.isFinite || !point.z.isFinite) return;
    rotationCenter = point;
    focusPoint = point;
    notifyListeners();
  }

  void focusOn(Vector3 point) {
    if (!point.x.isFinite || !point.y.isFinite || !point.z.isFinite) return;
    focusPoint = point;
    notifyListeners();
  }

  void fit(Vector3 minimum, Vector3 maximum) {
    if (![
          minimum.x,
          minimum.y,
          minimum.z,
          maximum.x,
          maximum.y,
          maximum.z,
        ].every((v) => v.isFinite) ||
        minimum.x > maximum.x ||
        minimum.y > maximum.y ||
        minimum.z > maximum.z) {
      return;
    }
    presentationTranslation = Vector3.zero;
    presentationOffsetNdcX = 0;
    presentationOffsetNdcY = 0;
    final previousDirection = eye - target;
    target = (minimum + maximum) / 2;
    rotationCenter = target;
    focusPoint = target;
    final radius = math.max((maximum - minimum).length / 2, .0001);
    _modelRadius = radius;
    final direction = previousDirection.length == 0
        ? const Vector3(1, -1, .7).normalized
        : previousDirection.normalized;
    final aspect = viewportWidth / math.max(viewportHeight, 1);
    final halfFov = math.min(
      fieldOfViewRadians / 2,
      math.atan(math.tan(fieldOfViewRadians / 2) * aspect),
    );
    final distance = math.max(radius / math.sin(halfFov) * 1.08, .01);
    eye = target + direction * distance;
    viewScale = math.max(radius * 2.16 / math.min(aspect, 1), .01);
    nearPlane = math.max(radius * .001, .001);
    farPlane = math.max(radius * 100, 1000);
    notifyListeners();
  }

  /// Reconstructs the non-persistent camera state at a project boundary.
  /// Workspace recovery must never inherit Sketch mode, projection offsets,
  /// pan presentation, or the orientation of the previously opened project.
  void restoreWorkspace(Vector3 minimum, Vector3 maximum) {
    _preSketchState = null;
    projectionMode = CadProjectionMode.perspective;
    presentationTranslation = Vector3.zero;
    presentationOffsetNdcX = 0;
    presentationOffsetNdcY = 0;
    setStandardView(CadStandardView.perspective, minimum, maximum);
  }

  void setStandardView(CadStandardView view, Vector3 minimum, Vector3 maximum) {
    final (direction, viewUp) = switch (view) {
      CadStandardView.perspective => (
        const Vector3(1, -1, .75).normalized,
        const Vector3(0, 0, 1),
      ),
      CadStandardView.top => (const Vector3(0, 0, 1), const Vector3(0, 1, 0)),
      CadStandardView.bottom => (
        const Vector3(0, 0, -1),
        const Vector3(0, -1, 0),
      ),
      CadStandardView.front => (
        const Vector3(0, -1, 0),
        const Vector3(0, 0, 1),
      ),
      CadStandardView.back => (const Vector3(0, 1, 0), const Vector3(0, 0, 1)),
      CadStandardView.right => (const Vector3(1, 0, 0), const Vector3(0, 0, 1)),
      CadStandardView.left => (const Vector3(-1, 0, 0), const Vector3(0, 0, 1)),
      CadStandardView.isometric => (
        const Vector3(1, -1, 1).normalized,
        const Vector3(0, 0, 1),
      ),
    };
    final center = (minimum + maximum) / 2;
    presentationTranslation = Vector3.zero;
    presentationOffsetNdcX = 0;
    presentationOffsetNdcY = 0;
    target = center;
    rotationCenter = center;
    focusPoint = center;
    eye = center + direction;
    up = viewUp;
    fit(minimum, maximum);
  }

  void toggleProjection() {
    projectionMode = projectionMode == CadProjectionMode.perspective
        ? CadProjectionMode.orthographic
        : CadProjectionMode.perspective;
    notifyListeners();
  }

  static Vector3 _rotate(Vector3 value, Vector3 axis, double angle) {
    final cosine = math.cos(angle), sine = math.sin(angle);
    return value * cosine +
        axis.cross(value) * sine +
        axis * (axis.dot(value) * (1 - cosine));
  }

  Vector3 _safeUp() {
    final forward = (target - eye).normalized;
    var candidate = up.length <= 1e-10 ? const Vector3(0, 0, 1) : up.normalized;
    if (forward.cross(candidate).length <= 1e-8) {
      candidate = forward.z.abs() < .9
          ? const Vector3(0, 0, 1)
          : const Vector3(0, 1, 0);
    }
    final right = forward.cross(candidate).normalized;
    return right.cross(forward).normalized;
  }
}
