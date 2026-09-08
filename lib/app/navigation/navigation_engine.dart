import 'dart:async';
import 'dart:math' as math;

import '../../core/geometric_kernel/geometry/vectors.dart';
import 'navigation_contracts.dart';
import 'navigation_state_machine.dart';
import 'navigation_style.dart';

class NavigationEngine implements NavigationStyleHost {
  NavigationEngine({
    required this.camera,
    required this.resolvePoint,
    required this.profile,
    this.context = NavigationContext.viewport,
    NavigationStyle? style,
    this.onNavigationChanged,
    this.onRotationCenterSet,
    this.onDebugChanged,
  }) : style = style ?? const CadOpenCascadeNavigationStyle();

  static const int primaryButton = CadOpenCascadeNavigationStyle.primaryButton;
  static const int secondaryButton =
      CadOpenCascadeNavigationStyle.secondaryButton;
  static const int middleButton = CadOpenCascadeNavigationStyle.middleButton;

  final NavigationCameraContract camera;
  final NavigationPointResolver resolvePoint;
  final NavigationStyle style;
  final void Function(bool active)? onNavigationChanged;
  final void Function(Vector3 point)? onRotationCenterSet;
  final void Function(NavigationDebugSnapshot snapshot)? onDebugChanged;
  NavigationProfile profile;
  NavigationContext context;
  final NavigationStateMachine _machine = NavigationStateMachine();

  @override
  NavigationState get state => _machine.state;
  bool get isNavigating => _machine.isNavigating;
  NavigationProfileCalibration get _calibration =>
      NavigationProfileCalibration.forProfile(profile);

  double? _startX, _startY, _previousX, _previousY;
  bool _moved = false;
  bool _panSessionActive = false;
  bool _orbitInputPrimed = false;
  Vector3? _zoomAnchor;
  Timer? _zoomTimer;
  final StreamController<NavigationDebugSnapshot> _debug =
      StreamController<NavigationDebugSnapshot>.broadcast(sync: true);

  Stream<NavigationDebugSnapshot> get debugSnapshots => _debug.stream;

  void pointerDown({
    required double x,
    required double y,
    required int buttons,
    bool control = false,
    bool shift = false,
    bool alt = false,
  }) {
    if (_startX == null) {
      _startX = _previousX = x;
      _startY = _previousY = y;
      _moved = false;
    }
    _dispatch(NavigationPointerPhase.down, x, y, buttons, control, shift, alt);
  }

  void pointerMove({
    required double x,
    required double y,
    required int buttons,
    bool control = false,
    bool shift = false,
    bool alt = false,
  }) {
    if (_startX == null) return;
    _dispatch(NavigationPointerPhase.move, x, y, buttons, control, shift, alt);
  }

  void pointerUp({
    required double x,
    required double y,
    required int buttons,
    bool control = false,
    bool shift = false,
    bool alt = false,
  }) =>
      _dispatch(NavigationPointerPhase.up, x, y, buttons, control, shift, alt);

  void pointerCancel() =>
      _dispatch(NavigationPointerPhase.cancel, 0, 0, 0, false, false, false);

  void _dispatch(
    NavigationPointerPhase phase,
    double x,
    double y,
    int buttons,
    bool control,
    bool shift,
    bool alt,
  ) => style.processPointer(
    NavigationPointerEvent(
      phase: phase,
      x: x,
      y: y,
      buttons: buttons,
      control: control,
      shift: shift,
      alt: alt,
    ),
    this,
  );

  @override
  void beginPan(double x, double y) {
    if (_panSessionActive) return;
    _startX = _previousX = x;
    _startY = _previousY = y;
    _panSessionActive = true;
    if (profile == NavigationProfile.objectManipulationTest) {
      _emit(
        const ManipulateOperationalSceneCommand(
          phase: NavigationCommandPhase.begin,
        ),
      );
    } else {
      _emit(const PanCommand(phase: NavigationCommandPhase.begin));
    }
  }

  @override
  void updatePan(double x, double y) {
    if (_startX == null || _startY == null) return;
    final previousX = _previousX ?? x;
    final previousY = _previousY ?? y;
    if (!_markMovement(x, y)) return;
    final currentX = previousX + (x - previousX) * _calibration.panGain;
    final currentY = previousY + (y - previousY) * _calibration.panGain;
    if (profile == NavigationProfile.objectManipulationTest) {
      _emit(
        ManipulateOperationalSceneCommand(
          phase: NavigationCommandPhase.update,
          previousX: previousX,
          previousY: previousY,
          currentX: currentX,
          currentY: currentY,
        ),
      );
    } else {
      _emit(
        PanCommand(
          phase: NavigationCommandPhase.update,
          previousX: previousX,
          previousY: previousY,
          currentX: currentX,
          currentY: currentY,
        ),
      );
    }
  }

  @override
  void orbitBy(double x, double y) {
    if (!_orbitInputPrimed) {
      _previousX = x;
      _previousY = y;
      _orbitInputPrimed = true;
      return;
    }
    final dx = x - (_previousX ?? x);
    final dy = y - (_previousY ?? y);
    if (!_markMovement(x, y)) return;
    _emit(
      OrbitCommand(
        dx / _calibration.orbitPixelsPerRadian,
        dy / _calibration.orbitPixelsPerRadian,
      ),
    );
  }

  @override
  void zoomByDrag(double y) {
    final dy = y - (_previousY ?? y);
    if (!_markMovement(_previousX ?? 0, y)) return;
    _emit(
      ZoomCommand(
        math.exp(dy.clamp(-80.0, 80.0) * _calibration.dragZoomExponent),
      ),
    );
  }

  @override
  void finishPointerGesture(double x, double y) {
    if (!_moved && state == NavigationState.panning) {
      final point = resolvePoint(x, y);
      if (point != null) {
        _emit(SetRotationCenterCommand(point));
        onRotationCenterSet?.call(point);
      }
    }
    _finishPan();
    _resetPointerGesture();
  }

  @override
  void cancelPointerGesture() {
    _finishPan();
    _resetPointerGesture();
  }

  @override
  void transitionTo(NavigationState next) {
    final wasNavigating = isNavigating;
    final previousState = state;
    final transition = _machine.transitionTo(next);
    if (transition == null) return;
    if (next == NavigationState.orbiting &&
        previousState != NavigationState.orbiting) {
      _orbitInputPrimed = false;
    } else if (next != NavigationState.orbiting) {
      _orbitInputPrimed = false;
    }
    if (transition.from == NavigationState.panning &&
        transition.to != NavigationState.panning) {
      _finishPan();
    }
    if (wasNavigating != isNavigating) {
      onNavigationChanged?.call(isNavigating);
    }
  }

  void wheel({required double x, required double y, required double deltaY}) {
    if (_zoomAnchor == null) {
      _zoomAnchor = resolvePoint(x, y);
      transitionTo(NavigationState.zooming);
    }
    _zoomTimer?.cancel();
    _zoomTimer = Timer(_calibration.zoomSessionTimeout, () {
      _zoomAnchor = null;
      transitionTo(NavigationState.idle);
    });
    _emit(
      ZoomCommand(
        math.exp(deltaY.clamp(-240.0, 240.0) * _calibration.wheelExponent),
        anchor: _zoomAnchor,
      ),
    );
  }

  void scale(double factor) {
    if (factor.isFinite && factor > 0) _emit(ZoomCommand(factor));
  }

  void fit(Vector3 minimum, Vector3 maximum) {
    final center = (minimum + maximum) / 2;
    final halfExtent =
        (maximum - minimum) / 2 * _calibration.fitBoundsExpansion;
    _emit(FitCommand(center - halfExtent, center + halfExtent));
  }

  void focus(Vector3 point) => _emit(FocusCommand(point));

  void dispose() {
    _zoomTimer?.cancel();
    _debug.close();
  }

  bool _markMovement(double x, double y) {
    final dx = x - (_previousX ?? x);
    final dy = y - (_previousY ?? y);
    _previousX = x;
    _previousY = y;
    if (dx * dx + dy * dy < .01) return false;
    _moved = true;
    return true;
  }

  void _finishPan() {
    if (!_panSessionActive) return;
    _panSessionActive = false;
    if (profile == NavigationProfile.objectManipulationTest) {
      _emit(
        const ManipulateOperationalSceneCommand(
          phase: NavigationCommandPhase.end,
        ),
      );
    } else {
      _emit(const PanCommand(phase: NavigationCommandPhase.end));
    }
  }

  void _resetPointerGesture() {
    _startX = _startY = _previousX = _previousY = null;
    _moved = false;
    _orbitInputPrimed = false;
    transitionTo(NavigationState.idle);
  }

  void _emit(NavigationCommand command) {
    camera.execute(command);
    final debug = NavigationDebugSnapshot(
      state: state,
      profile: profile,
      context: context,
      command: command.runtimeType.toString(),
      timestamp: DateTime.now(),
      destination: camera.runtimeType.toString(),
    );
    onDebugChanged?.call(debug);
    if (!_debug.isClosed) _debug.add(debug);
  }
}
