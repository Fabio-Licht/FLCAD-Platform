import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/navigation/cad_camera_navigation_adapter.dart';
import 'package:flcad_mobile/app/navigation/navigation_contracts.dart';
import 'package:flcad_mobile/app/navigation/navigation_engine.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('object test moves presentation without changing camera state', () {
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);
    final commands = <String>[];
    final engine = NavigationEngine(
      profile: NavigationProfile.objectManipulationTest,
      camera: CadCameraNavigationAdapter(camera),
      resolvePoint: (_, _) => Vector3.zero,
      onDebugChanged: (debug) => commands.add(debug.command),
    );
    addTearDown(engine.dispose);
    final before = camera.snapshot();

    engine.pointerDown(x: 400, y: 300, buttons: NavigationEngine.middleButton);
    engine.pointerMove(x: 470, y: 340, buttons: NavigationEngine.middleButton);
    engine.pointerUp(x: 470, y: 340, buttons: 0);
    final after = engine.camera.snapshot as CadCameraState;

    expect(
      commands,
      containsAllInOrder([
        'ManipulateOperationalSceneCommand',
        'ManipulateOperationalSceneCommand',
      ]),
    );
    expect(after.eye.distanceTo(before.eye), lessThan(1e-12));
    expect(after.target.distanceTo(before.target), lessThan(1e-12));
    expect(commands, isNot(contains('PanCommand')));
    expect(camera.presentationOffsetNdcX.abs(), greaterThan(0));
    expect(camera.presentationOffsetNdcY.abs(), greaterThan(0));
    expect(camera.presentationTranslation.length, greaterThan(0));
    expect(
      (after.target - after.eye).distanceTo(before.target - before.eye),
      lessThan(1e-10),
    );
    expect(after.up.distanceTo(before.up), lessThan(1e-12));
    expect(
      after.rotationCenter.distanceTo(before.rotationCenter),
      lessThan(1e-12),
    );
    expect(after.focusPoint.distanceTo(before.focusPoint), lessThan(1e-12));
    expect(after.viewScale, before.viewScale);
    expect(engine.state, NavigationState.idle);
  });

  test(
    'production middle-pan moves camera and preserves presentation offsets',
    () {
      for (final orthographic in [false, true]) {
        final camera = CadCameraController(
          eye: const Vector3(0, 0, 5),
          target: Vector3.zero,
          up: const Vector3(0, 1, 0),
        )..resize(800, 600);
        if (orthographic) camera.toggleProjection();
        camera.translateOperationalScene(const Vector3(.2, -.1, 0));
        final before = camera.snapshot();
        final commands = <String>[];
        final engine = NavigationEngine(
          profile: NavigationProfile.flcadReverseEngineering,
          camera: CadCameraNavigationAdapter(camera),
          resolvePoint: (_, _) => null,
          onDebugChanged: (debug) => commands.add(debug.command),
        );
        addTearDown(engine.dispose);

        engine.pointerDown(
          x: 400,
          y: 300,
          buttons: NavigationEngine.middleButton,
        );
        engine.pointerMove(
          x: 470,
          y: 340,
          buttons: NavigationEngine.middleButton,
        );
        engine.pointerUp(x: 470, y: 340, buttons: 0);

        final eyeDelta = camera.eye - before.eye;
        final targetDelta = camera.target - before.target;
        expect(commands, ['PanCommand', 'PanCommand', 'PanCommand']);
        expect(eyeDelta.length, greaterThan(0));
        expect(targetDelta.length, greaterThan(0));
        expect(eyeDelta.distanceTo(targetDelta), lessThan(1e-10));
        expect(camera.presentationTranslation, before.presentationTranslation);
        expect(camera.presentationOffsetNdcX, before.presentationOffsetNdcX);
        expect(camera.presentationOffsetNdcY, before.presentationOffsetNdcY);
      }
    },
  );

  test('professional Pan translates near and far geometry by equal pixels', () {
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 10),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    )..resize(1000, 700);
    const nearPoint = Vector3(1.5, .5, 2);
    const farPoint = Vector3(1.5, .5, -2);
    final nearBefore = camera.viewProjectionMatrix.transformPoint(nearPoint);
    final farBefore = camera.viewProjectionMatrix.transformPoint(farPoint);

    camera.translateOperationalScene(const Vector3(1.2, -.7, 0));

    final nearAfter = camera.viewProjectionMatrix.transformPoint(nearPoint);
    final farAfter = camera.viewProjectionMatrix.transformPoint(farPoint);
    final nearDelta = Vector3(
      nearAfter.x - nearBefore.x,
      nearAfter.y - nearBefore.y,
      0,
    );
    final farDelta = Vector3(
      farAfter.x - farBefore.x,
      farAfter.y - farBefore.y,
      0,
    );
    expect(nearDelta.distanceTo(farDelta), lessThan(1e-12));
    expect(camera.eye, const Vector3(0, 0, 10));
    expect(camera.target, Vector3.zero);
    expect(camera.up, const Vector3(0, 1, 0));
  });

  test('right button does not activate Pan', () {
    final camera = CadCameraController()..resize(800, 600);
    final commands = <String>[];
    final engine = NavigationEngine(
      profile: NavigationProfile.flcadReverseEngineering,
      camera: CadCameraNavigationAdapter(camera),
      resolvePoint: (_, _) => null,
      onDebugChanged: (debug) => commands.add(debug.command),
    );
    addTearDown(engine.dispose);

    engine.pointerDown(
      x: 300,
      y: 250,
      buttons: NavigationEngine.secondaryButton,
    );
    engine.pointerMove(
      x: 380,
      y: 310,
      buttons: NavigationEngine.secondaryButton,
    );
    engine.pointerUp(x: 380, y: 310, buttons: 0);

    expect(commands, isEmpty);
    expect(camera.presentationTranslation, Vector3.zero);
  });

  test('FreeCAD pan uses a fixed focal plane and never picks a surface', () {
    final oneStepCamera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);
    final manyStepsCamera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);
    var pickCount = 0;
    NavigationEngine engine(CadCameraController camera) => NavigationEngine(
      camera: CadCameraNavigationAdapter(camera),
      resolvePoint: (_, _) {
        pickCount++;
        return const Vector3(100, 100, 100);
      },
      profile: NavigationProfile.cadOpenCascade,
    );
    final oneStep = engine(oneStepCamera);
    final manySteps = engine(manyStepsCamera);
    addTearDown(oneStep.dispose);
    addTearDown(manySteps.dispose);

    oneStep.pointerDown(x: 400, y: 300, buttons: NavigationEngine.middleButton);
    oneStep.pointerMove(x: 520, y: 360, buttons: NavigationEngine.middleButton);
    oneStep.pointerUp(x: 520, y: 360, buttons: 0);

    manySteps.pointerDown(
      x: 400,
      y: 300,
      buttons: NavigationEngine.middleButton,
    );
    for (var step = 1; step <= 6; step++) {
      manySteps.pointerMove(
        x: 400 + 20.0 * step,
        y: 300 + 10.0 * step,
        buttons: NavigationEngine.middleButton,
      );
    }
    manySteps.pointerUp(x: 520, y: 360, buttons: 0);

    expect(pickCount, 0);
    expect(oneStepCamera.eye.distanceTo(manyStepsCamera.eye), lessThan(1e-9));
    expect(
      oneStepCamera.target.distanceTo(manyStepsCamera.target),
      lessThan(1e-9),
    );
  });

  test('CAD/OpenCascade combos are interpreted only by NavigationStyle', () {
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);
    final commands = <String>[];
    final engine = NavigationEngine(
      camera: CadCameraNavigationAdapter(camera),
      resolvePoint: (_, _) => Vector3.zero,
      profile: NavigationProfile.catia,
      onDebugChanged: (debug) => commands.add(debug.command),
    );
    addTearDown(engine.dispose);

    engine.pointerDown(x: 400, y: 300, buttons: NavigationEngine.middleButton);
    engine.pointerMove(
      x: 460,
      y: 330,
      buttons: NavigationEngine.middleButton | NavigationEngine.primaryButton,
    );
    expect(engine.state, NavigationState.orbiting);
    engine.pointerMove(
      x: 470,
      y: 335,
      buttons: NavigationEngine.middleButton | NavigationEngine.primaryButton,
    );
    engine.pointerMove(x: 460, y: 250, buttons: NavigationEngine.middleButton);

    expect(engine.state, NavigationState.zooming);
    expect(commands, contains('OrbitCommand'));
    expect(commands, contains('ZoomCommand'));
  });

  test(
    'Orbit entry primes at the post-Pan position without a micro-rotation',
    () {
      final camera = CadCameraController(
        eye: const Vector3(0, 0, 5),
        target: Vector3.zero,
        up: const Vector3(0, 1, 0),
      )..resize(800, 600);
      final commands = <String>[];
      final engine = NavigationEngine(
        profile: NavigationProfile.flcadReverseEngineering,
        camera: CadCameraNavigationAdapter(camera),
        resolvePoint: (_, _) => null,
        onDebugChanged: (debug) => commands.add(debug.command),
      );
      addTearDown(engine.dispose);

      engine.pointerDown(
        x: 300,
        y: 260,
        buttons: NavigationEngine.middleButton,
      );
      engine.pointerMove(
        x: 380,
        y: 310,
        buttons: NavigationEngine.middleButton,
      );
      engine.pointerUp(x: 380, y: 310, buttons: 0);
      final afterPan = camera.viewProjectionMatrix.values.toList();

      engine.pointerDown(
        x: 380,
        y: 310,
        buttons: NavigationEngine.middleButton | NavigationEngine.primaryButton,
      );
      engine.pointerMove(
        x: 382,
        y: 311,
        buttons: NavigationEngine.middleButton | NavigationEngine.primaryButton,
      );

      expect(camera.viewProjectionMatrix.values, afterPan);
      expect(commands.where((value) => value == 'OrbitCommand'), isEmpty);

      engine.pointerMove(
        x: 402,
        y: 321,
        buttons: NavigationEngine.middleButton | NavigationEngine.primaryButton,
      );
      expect(commands, contains('OrbitCommand'));
    },
  );

  test('production Orbit uses a controlled response relative to classic', () {
    CadCameraController makeCamera() => CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);
    final controlledCamera = makeCamera();
    final classicCamera = makeCamera();
    final controlled = NavigationEngine(
      profile: NavigationProfile.flcadReverseEngineering,
      camera: CadCameraNavigationAdapter(controlledCamera),
      resolvePoint: (_, _) => null,
    );
    final classic = NavigationEngine(
      camera: CadCameraNavigationAdapter(classicCamera),
      resolvePoint: (_, _) => null,
      profile: NavigationProfile.cadOpenCascade,
    );
    addTearDown(controlled.dispose);
    addTearDown(classic.dispose);

    void orbit(NavigationEngine engine) {
      const buttons =
          NavigationEngine.middleButton | NavigationEngine.primaryButton;
      engine.pointerDown(x: 400, y: 300, buttons: buttons);
      engine.pointerMove(x: 402, y: 301, buttons: buttons);
      engine.pointerMove(x: 462, y: 331, buttons: buttons);
      engine.pointerUp(x: 462, y: 331, buttons: 0);
    }

    orbit(controlled);
    orbit(classic);
    const initialEye = Vector3(0, 0, 5);
    final controlledDisplacement = controlledCamera.eye.distanceTo(initialEye);
    final classicDisplacement = classicCamera.eye.distanceTo(initialEye);

    expect(controlledDisplacement, greaterThan(0));
    expect(controlledDisplacement, lessThan(classicDisplacement));
  });

  test('Fit and Focus also cross the command boundary', () {
    final camera = CadCameraController();
    final commands = <String>[];
    final engine = NavigationEngine(
      camera: CadCameraNavigationAdapter(camera),
      resolvePoint: (_, _) => null,
      context: NavigationContext.mesh,
      profile: NavigationProfile.flcadReverseEngineering,
      onDebugChanged: (debug) => commands.add(debug.command),
    );
    addTearDown(engine.dispose);

    engine.fit(const Vector3(-2, -1, -1), const Vector3(2, 1, 1));
    engine.focus(const Vector3(1, 0, 0));

    expect(commands, ['FitCommand', 'FocusCommand']);
    expect(camera.focusPoint, const Vector3(1, 0, 0));
    expect(engine.camera.snapshot, isA<CadCameraState>());
  });

  test('Geomagic/CATIA wheel session keeps one anchor and stable center', () {
    final camera = CadCameraController(
      eye: const Vector3(0, 0, 5),
      target: Vector3.zero,
      rotationCenter: const Vector3(1, 2, 3),
      focusPoint: const Vector3(1, 2, 3),
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);
    var resolved = 0;
    final engine = NavigationEngine(
      camera: CadCameraNavigationAdapter(camera),
      resolvePoint: (_, _) {
        resolved++;
        return Vector3.zero;
      },
      profile: NavigationProfile.geomagicCatia,
    );
    addTearDown(engine.dispose);

    engine.wheel(x: 400, y: 300, deltaY: -120);
    engine.wheel(x: 600, y: 300, deltaY: -120);

    expect(resolved, 1);
    expect(camera.rotationCenter, const Vector3(1, 2, 3));
    expect(camera.focusPoint, const Vector3(1, 2, 3));
  });

  test('Geomagic/CATIA Fit preserves orientation and adds safe margin', () {
    final camera = CadCameraController(
      eye: const Vector3(3, 2, 5),
      target: Vector3.zero,
      up: const Vector3(0, 1, 0),
    )..resize(800, 600);
    final engine = NavigationEngine(
      camera: CadCameraNavigationAdapter(camera),
      resolvePoint: (_, _) => null,
      profile: NavigationProfile.geomagicCatia,
    );
    addTearDown(engine.dispose);
    final direction = (camera.eye - camera.target).normalized;

    engine.fit(const Vector3(-1, -1, -1), const Vector3(1, 1, 1));

    expect(
      (camera.eye - camera.target).normalized.distanceTo(direction),
      lessThan(1e-12),
    );
    expect(camera.target.distanceTo(Vector3.zero), lessThan(1e-12));
    expect(camera.viewScale, greaterThan(4));
  });

  test('CAD/OpenCascade transitions from Zoom back to Orbit', () {
    final camera = CadCameraController()..resize(800, 600);
    final engine = NavigationEngine(
      camera: CadCameraNavigationAdapter(camera),
      resolvePoint: (_, _) => Vector3.zero,
      profile: NavigationProfile.cadOpenCascade,
    );
    addTearDown(engine.dispose);

    engine.pointerDown(
      x: 400,
      y: 300,
      buttons: NavigationEngine.primaryButton,
      control: true,
    );
    engine.pointerMove(
      x: 430,
      y: 300,
      buttons: NavigationEngine.primaryButton,
      control: true,
    );
    expect(engine.state, NavigationState.zooming);
    engine.pointerMove(
      x: 450,
      y: 260,
      buttons: NavigationEngine.middleButton | NavigationEngine.primaryButton,
    );

    expect(engine.state, NavigationState.orbiting);
  });
}
