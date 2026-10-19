import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../camera/cad_camera_controller.dart';
import '../camera/camera_pan_audit.dart';
import '../professional_cad_viewport_widget.dart';
import '../scene/cad_scene_graph.dart';
import '../selection/viewport_picking_controller.dart';
import '../../engineering_bridge/contracts/bridge_selection.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../../operational_entities/operational_entity.dart';
import '../../operational_entities/operational_entity_resolver.dart';
import 'native_viewport_bridge.dart';
import 'viewport_render_diagnostics.dart';
import '../rendering/shaded_debug_experiments.dart';
import '../rendering/reference_visibility_mask.dart';

const bool _viewportDiagnosticsEnabled =
    kDebugMode && bool.fromEnvironment('FLCAD_DEV_VIEWPORT_DIAGNOSTICS');

class CadManagedFaceSelectionController extends ChangeNotifier {
  ManagedCadFaceHighlight? _selection;
  ManagedCadFaceHighlight? get selection => _selection;

  void select(ManagedCadFaceHighlight value) {
    if (_selection == value) return;
    _selection = value;
    notifyListeners();
  }

  void clear() {
    if (_selection == null) return;
    _selection = null;
    notifyListeners();
  }
}

class IntegratedCadViewportWidget extends StatefulWidget {
  const IntegratedCadViewportWidget({
    super.key,
    required this.scene,
    required this.camera,
    this.onPick,
    this.nativeBridgeFactory,
    this.onSketchSupportPick,
    this.onSketchEntityPick,
    this.onSketchEntityDoublePick,
    this.onSketchTap,
    this.onSketchSecondaryTap,
    this.onSketchHover,
    this.onSketchSuggestionHover,
    this.onSketchSuggestionHoverPosition,
    this.sketchSuggestionPickCandidateIds,
    this.onSketchEntityDragStart,
    this.onSketchEntityDragUpdate,
    this.onSketchEntityDragEnd,
    this.showSketchGrid = false,
    this.operationalEntities,
    this.operationalResolver,
    this.operationalSelection,
    this.onViewportReady,
    this.enableInspectionHover = false,
    this.managedFaceSelectionController,
    this.onManagedFaceSelectionCleared,
    this.onViewportSelectionCleared,
    this.onPickCapture,
    this.pickCaptureCandidateIds,
    this.onPickCaptureHover,
    this.technicalRecognitionAvailable = false,
    this.brushActive = false,
    this.brushCandidateIds,
    this.brushDiameterMm = 12,
    this.brushCursorMode,
    this.onBrushDown,
    this.onBrushMove,
    this.onBrushUp,
    this.onBrushCancel,
  });

  /// The viewport owns and disposes the bridge returned by this factory.
  final NativeViewportBridge Function()? nativeBridgeFactory;
  final CadSceneGraph scene;
  final CadCameraController camera;
  final ValueChanged<CadViewportPick>? onPick;
  final ValueChanged<CadViewportPick>? onSketchSupportPick;
  final ValueChanged<CadViewportPick>? onSketchEntityPick;
  final ValueChanged<CadViewportPick>? onSketchEntityDoublePick;
  final ValueChanged<Offset>? onSketchTap;
  final VoidCallback? onSketchSecondaryTap;
  final ValueChanged<Offset>? onSketchHover;
  final ValueChanged<CadViewportPick?>? onSketchSuggestionHover;
  final ValueChanged<Offset?>? onSketchSuggestionHoverPosition;
  final Set<String>? sketchSuggestionPickCandidateIds;
  final void Function(CadViewportPick pick, Offset position)?
  onSketchEntityDragStart;
  final ValueChanged<Offset>? onSketchEntityDragUpdate;
  final ValueChanged<Offset>? onSketchEntityDragEnd;
  final bool showSketchGrid;
  final OperationalEntityRegistry? operationalEntities;
  final OperationalEntityResolver? operationalResolver;
  final OperationalSelectionManager? operationalSelection;
  final VoidCallback? onViewportReady;
  final bool enableInspectionHover;
  final CadManagedFaceSelectionController? managedFaceSelectionController;
  final VoidCallback? onManagedFaceSelectionCleared;
  final VoidCallback? onViewportSelectionCleared;

  /// Gives a transient command first refusal without changing global
  /// operational or managed-face selection.
  final bool Function(CadViewportPick pick)? onPickCapture;
  final Set<String>? pickCaptureCandidateIds;
  final ValueChanged<CadViewportPick?>? onPickCaptureHover;
  final bool technicalRecognitionAvailable;
  final bool brushActive;
  final Set<String>? brushCandidateIds;
  final double brushDiameterMm;
  final CadBrushCursorMode? brushCursorMode;
  final ValueChanged<CadViewportPick>? onBrushDown;
  final ValueChanged<CadViewportPick>? onBrushMove;
  final VoidCallback? onBrushUp;
  final VoidCallback? onBrushCancel;

  @override
  State<IntegratedCadViewportWidget> createState() =>
      _IntegratedCadViewportWidgetState();
}

class _IntegratedCadViewportWidgetState
    extends State<IntegratedCadViewportWidget> {
  late final NativeViewportBridge native;
  int _tapGeneration = 0;
  late final OperationalEntityRegistry operationalEntities;
  late final OperationalEntityResolver operationalResolver;
  late final OperationalSelectionManager operationalSelection;
  bool _ownsOperationalState = false;
  ViewportBackend backend = Platform.isWindows
      ? ViewportBackend.nativeGpu
      : ViewportBackend.flutterCanvas;
  late ViewportBackend _requestedBackend = backend;
  String? get _unsupportedReason =>
      nativeSceneUnsupportedReason(widget.scene, style: native.renderStyle);
  bool get _nativeSupportsMode => _unsupportedReason == null;
  Size? _nativeSize;
  bool _initializing = false;
  bool _switching = false;
  int _backendGeneration = 0;
  int _cameraRevision = 0;
  Future<void>? _nativeWork;
  Future<void> _handoff = Future<void>.value();
  String? _backendNotice;
  bool get _nativeActive =>
      backend == ViewportBackend.nativeGpu &&
      native.available &&
      native.sceneReady &&
      !_switching;
  Timer? _deltaDebounce;
  NativeViewportPick? _nativeHover;
  OperationalResolution? _operationalHover;
  bool _hoverRequestActive = false;
  bool _nativeNavigating = false;
  bool _showReferenceOverlays = true;
  CadRenderStyle _renderStyle = CadRenderStyle.shaded;
  Offset? _pendingHover;
  Offset? _lastHoverPosition;
  ManagedCadFaceHighlight? _managedFaceHover;
  ManagedCadFaceHighlight? _managedFaceSelection;
  ViewportRenderDiagnosticReport? _diagnosticReport;
  final ViewportPickingController _overlayPicking = ViewportPickingController();
  CadViewportPick? _captureHover;
  late final FocusNode _viewportFocusNode;

  void _managedFaceControllerChanged() {
    final next = widget.managedFaceSelectionController?.selection;
    if (_managedFaceSelection == next) return;
    if (next == null && _managedFaceHover != null) {
      _managedFaceHover = null;
      if (_nativeActive) native.clearHover();
    }
    _publishManagedFaceSelection(next);
  }

  void _publishManagedFaceSelection(ManagedCadFaceHighlight? next) {
    if (mounted && _managedFaceSelection != next) {
      setState(() => _managedFaceSelection = next);
    }
    if (!_nativeActive) return;
    if (next == null) {
      native.clearManagedCadFaceSelection();
    } else {
      native.setManagedCadFaceSelection(
        entityId: next.entityId,
        presentationSubId: next.presentationSubId,
      );
    }
  }

  void _selectManagedFace(ManagedCadFaceHighlight? next) {
    final controller = widget.managedFaceSelectionController;
    final previous = controller?.selection ?? _managedFaceSelection;
    if (controller != null) {
      if (next == null) {
        controller.clear();
      } else {
        controller.select(next);
      }
    } else {
      _publishManagedFaceSelection(next);
    }
    if (previous != null && next == null) {
      widget.onManagedFaceSelectionCleared?.call();
    }
  }

  void _setRenderStyle(CadRenderStyle style) {
    _tapGeneration++;
    setState(() {
      _renderStyle = style;
      native.renderStyle = style == CadRenderStyle.hiddenLine
          ? 1
          : style == CadRenderStyle.wireframe
          ? 2
          : style == CadRenderStyle.transparent
          ? 3
          : 0;
    });
    final next =
        _requestedBackend == ViewportBackend.nativeGpu && !_nativeSupportsMode
        ? ViewportBackend.flutterCanvas
        : _requestedBackend;
    if (next != backend) {
      _switchBackend(next, modeFallback: next != _requestedBackend);
    } else if (_nativeActive) {
      native.setCamera(widget.camera);
    }
    _recordViewportDiagnostics();
  }

  void _recordViewportDiagnostics() {
    if (!_viewportDiagnosticsEnabled) return;
    final report = buildViewportRenderDiagnostic(
      scene: widget.scene,
      backend: backend,
      requestedBackend: _requestedBackend,
      style: _renderStyle,
      fallbackReason: _unsupportedReason,
      highlightActive:
          _managedFaceSelection != null || _managedFaceHover != null,
      nativeSceneReady: native.sceneReady,
      nativeStats: native.stats,
      silhouetteUpdates: native.silhouetteUpdates,
      silhouetteStaleDiscards: native.silhouetteStaleDiscards,
      silhouetteSegmentsSent: native.silhouetteSegmentsSent,
      silhouetteDiagnostics: native.silhouetteDiagnostics,
    );
    _diagnosticReport = report;
    debugPrint('[viewport-diagnostic] ${report.toStructuredLog()}');
  }

  bool _canPublishTap(int token, CadSceneGraph scene) =>
      mounted &&
      token == _tapGeneration &&
      identical(scene, widget.scene) &&
      backend == ViewportBackend.nativeGpu &&
      native.available &&
      native.sceneReady &&
      !_switching &&
      !_nativeNavigating;

  Future<void> _pickNativeTap(Offset position) async {
    final token = ++_tapGeneration;
    final scene = widget.scene;
    final additive = HardwareKeyboard.instance.isShiftPressed;
    final toggle = HardwareKeyboard.instance.isControlPressed;
    if (!_canPublishTap(token, scene)) return;
    if (widget.pickCaptureCandidateIds != null &&
        _pickReferenceOverlay(position, scene, additive, toggle)) {
      return;
    }
    final result = await native.pick(position.dx, position.dy);
    if (!_canPublishTap(token, scene)) return;
    // Native D3D deliberately excludes UI/reference overlays and Sketch
    // profiles. Resolve those through the Flutter screen-space picker before
    // treating this as empty.
    if (result == null || result.kind == NativePickKind.none) {
      _selectManagedFace(null);
      if (_pickReferenceOverlay(position, scene, additive, toggle)) return;
      widget.onViewportSelectionCleared?.call();
      return;
    }
    final source = scene.find(result.entityId);
    if (source == null || !source.visible) {
      _selectManagedFace(null);
      return;
    }
    final managedFace = result.kind == NativePickKind.face
        ? managedCadFaceHighlight(source, result.subId)
        : null;
    // Normal entity selection must not segment a STEP display mesh into regions.
    final resolved = managedFace != null
        ? _managedFaceResolution(source, managedFace)
        : !widget.enableInspectionHover &&
              source.kind == CadSceneEntityKind.mesh
        ? _entityResolution(source)
        : await operationalResolver.resolve(result, scene);
    if (!_canPublishTap(token, scene) || resolved == null) return;
    final point = result.point;
    CadViewportPick? pick;
    if (point.length >= 3 && point.take(3).every((value) => value.isFinite)) {
      pick = CadViewportPick(
        entityId: resolved.entity.ownerId,
        ray: cameraRayForViewportPosition(
          position: position,
          camera: widget.camera,
        ),
        subentityKind: switch (result.kind) {
          NativePickKind.face => CadViewportSubentityKind.face,
          NativePickKind.edge => CadViewportSubentityKind.edge,
          NativePickKind.vertex => CadViewportSubentityKind.vertex,
          NativePickKind.none => null,
        },
        presentationSubId: managedFace?.presentationSubId ?? result.subId,
        hit: MeshHit(
          triangleIndex: -1,
          point: Vector3(point[0], point[1], point[2]),
          distance: 0,
        ),
      );
      if (widget.onPickCapture?.call(pick) == true) {
        _selectManagedFace(null);
        return;
      }
    }
    operationalSelection.select(
      resolved.entity.id,
      additive: additive,
      toggle: toggle,
    );
    _selectManagedFace(managedFace);
    if (pick != null) {
      widget.camera.focusOn(Vector3(point[0], point[1], point[2]));
      widget.onPick?.call(pick);
    }
  }

  bool _pickReferenceOverlay(
    Offset position,
    CadSceneGraph scene,
    bool additive,
    bool toggle,
  ) {
    if (!_showReferenceOverlays) return false;
    final pick = _overlayPicking.pick(
      position: position,
      camera: widget.camera,
      scene: scene,
      eligibleEntityIds: widget.pickCaptureCandidateIds,
    );
    if (pick == null) return false;
    final source = scene.find(pick.entityId);
    if (source == null ||
        !const {
          CadSceneEntityKind.plane,
          CadSceneEntityKind.axis,
          CadSceneEntityKind.point,
          CadSceneEntityKind.coordinateSystem,
          CadSceneEntityKind.sketch,
        }.contains(source.kind)) {
      return false;
    }
    if (widget.onPickCapture?.call(pick) == true) {
      _selectManagedFace(null);
      return true;
    }
    operationalSelection.select(
      _entityResolution(source).entity.id,
      additive: additive,
      toggle: toggle,
    );
    _selectManagedFace(null);
    widget.onPick?.call(pick);
    return true;
  }

  OperationalResolution _entityResolution(CadSceneEntity source) {
    final entity = OperationalEntity(
      id: 'operational:${source.id}',
      type: OperationalEntityType.meshRegion,
      ownerId: source.id,
      ownerDomain: 'entity',
      documentId: source.id,
      revision: 1,
      label: source.id,
      capabilities: const {OperationalCapability.selectable},
      properties: const {'presentationOnly': true},
    );
    operationalEntities.replaceOwner(source.id, [entity]);
    return OperationalResolution(entity: entity, triangleIndices: const []);
  }

  OperationalResolution _managedFaceResolution(
    CadSceneEntity source,
    ManagedCadFaceHighlight face,
  ) {
    final entity = OperationalEntity(
      id: 'operational:${source.id}:brep-face:${face.faceIndex}',
      type: OperationalEntityType.cadFace,
      ownerId: source.id,
      ownerDomain: 'brepFace',
      documentId: source.id,
      revision: 1,
      label: '${source.id} · Face ${face.faceIndex}',
      capabilities: const {
        OperationalCapability.selectable,
        OperationalCapability.inspectable,
        OperationalCapability.reference,
        OperationalCapability.topological,
      },
      properties: {
        'sceneEntityId': source.id,
        'faceIndex': face.faceIndex,
        'presentationOnly': true,
      },
    );
    operationalEntities.replaceOwner(source.id, [entity]);
    return OperationalResolution(entity: entity, triangleIndices: const []);
  }

  Future<void> _updateNativeHover(Offset position) async {
    _lastHoverPosition = position;
    final captureHover = widget.pickCaptureCandidateIds == null
        ? null
        : _overlayPicking.pick(
            position: position,
            camera: widget.camera,
            scene: widget.scene,
            eligibleEntityIds: widget.pickCaptureCandidateIds,
          );
    if (_captureHover?.entityId != captureHover?.entityId) {
      setState(() => _captureHover = captureHover);
      widget.onPickCaptureHover?.call(captureHover);
    }
    if (captureHover != null) {
      _pendingHover = null;
      await native.clearHover();
      if (mounted &&
          (_nativeHover != null ||
              _operationalHover != null ||
              _managedFaceHover != null)) {
        setState(() {
          _nativeHover = null;
          _operationalHover = null;
          _managedFaceHover = null;
        });
      }
      return;
    }
    // Sketch/reference curves are Flutter overlays even when the CAD body
    // is rendered by the native backend. Publish overlay hover from the
    // latest pointer before any GPU await, including while a pick is already
    // in flight, so a slow/hung query cannot freeze Assistant hover.
    widget.onSketchSuggestionHover?.call(
      _overlayPicking.pickSuggestionHover(
        position: position,
        camera: widget.camera,
        scene: widget.scene,
        suggestionCandidateIds: widget.sketchSuggestionPickCandidateIds,
      ),
    );
    _pendingHover = position;
    if (_hoverRequestActive || !_nativeActive || _nativeNavigating) return;
    final generation = _backendGeneration;
    _hoverRequestActive = true;
    try {
      while (_pendingHover != null && _nativeActive) {
        final current = _pendingHover!;
        _pendingHover = null;
        final result = await native.pick(current.dx, current.dy);
        final source = result == null
            ? null
            : widget.scene.find(result.entityId);
        final managedFace =
            result?.kind == NativePickKind.face && source != null
            ? managedCadFaceHighlight(source, result!.subId)
            : null;
        final resolved = !widget.enableInspectionHover || managedFace != null
            ? null
            : result == null
            ? null
            : await operationalResolver.resolve(result, widget.scene);
        if (!mounted ||
            !_nativeActive ||
            generation != _backendGeneration ||
            _pendingHover != null ||
            _nativeNavigating) {
          continue;
        }
        if (managedFace != null) {
          await native.setManagedCadFaceHover(
            entityId: managedFace.entityId,
            presentationSubId: managedFace.presentationSubId,
          );
        } else if (resolved == null) {
          await native.clearHover();
        } else {
          await native.setOperationalHover(
            operationalEntityId: resolved.entity.id,
            entityId: resolved.entity.ownerId,
            triangleIndices: resolved.triangleIndices,
          );
        }
        if (mounted) {
          setState(() {
            _nativeHover = result;
            _operationalHover = resolved;
            _managedFaceHover = managedFace;
          });
        }
      }
    } finally {
      _hoverRequestActive = false;
    }
  }

  MouseCursor get _nativeCursor {
    final candidates = widget.pickCaptureCandidateIds;
    if (candidates != null) {
      final candidateId = _captureHover?.entityId ?? _nativeHover?.entityId;
      return candidateId != null && candidates.contains(candidateId)
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden;
    }
    return switch (_nativeHover?.kind) {
      NativePickKind.vertex => SystemMouseCursors.precise,
      NativePickKind.edge => SystemMouseCursors.click,
      NativePickKind.face => SystemMouseCursors.click,
      _ => MouseCursor.defer,
    };
  }

  void _pickCanvas(CadViewportPick pick) {
    final source = widget.scene.find(pick.entityId);
    if (!_showReferenceOverlays &&
        source != null &&
        isAuxiliaryReferenceVisual(source)) {
      return;
    }
    if (widget.onPickCapture?.call(pick) == true) {
      _selectManagedFace(null);
      return;
    }
    final face = source == null || pick.hit.triangleIndex < 0
        ? null
        : managedCadFaceHighlight(source, pick.hit.triangleIndex + 1);
    _selectManagedFace(face);
    widget.onPick?.call(
      face == null
          ? pick
          : CadViewportPick(
              entityId: pick.entityId,
              hit: pick.hit,
              ray: pick.ray,
              subentityKind: CadViewportSubentityKind.face,
              presentationSubId: face.presentationSubId,
            ),
    );
  }

  void _hoverCanvas(CadViewportPick? pick) {
    final source = pick == null ? null : widget.scene.find(pick.entityId);
    final next = source == null || pick == null || pick.hit.triangleIndex < 0
        ? null
        : managedCadFaceHighlight(source, pick.hit.triangleIndex + 1);
    if (_managedFaceHover != next && mounted) {
      setState(() => _managedFaceHover = next);
    }
  }

  @override
  void initState() {
    super.initState();
    _viewportFocusNode = FocusNode(debugLabel: 'CadViewportKeyboard');
    native = widget.nativeBridgeFactory?.call() ?? NativeViewportBridge();
    native.addListener(_changed);
    operationalEntities =
        widget.operationalEntities ?? OperationalEntityRegistry();
    operationalResolver =
        widget.operationalResolver ??
        OperationalEntityResolver(operationalEntities);
    operationalSelection =
        widget.operationalSelection ??
        OperationalSelectionManager(operationalEntities);
    _ownsOperationalState = widget.operationalEntities == null;
    widget.scene.addListener(_sceneChanged);
    widget.camera.addListener(_cameraChanged);
    operationalSelection.addListener(_operationalSelectionChanged);
    widget.managedFaceSelectionController?.addListener(
      _managedFaceControllerChanged,
    );
    _managedFaceSelection = widget.managedFaceSelectionController?.selection;
    if (widget.enableInspectionHover) operationalResolver.prepare(widget.scene);
    _requestedBackend = backend;
    if (!Platform.isWindows) _recordViewportDiagnostics();
  }

  @override
  void didUpdateWidget(covariant IntegratedCadViewportWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final captureHoverId = _captureHover?.entityId;
    if (captureHoverId != null &&
        (widget.pickCaptureCandidateIds == null ||
            !widget.pickCaptureCandidateIds!.contains(captureHoverId))) {
      _captureHover = null;
      widget.onPickCaptureHover?.call(null);
    }
    if (oldWidget.managedFaceSelectionController !=
        widget.managedFaceSelectionController) {
      oldWidget.managedFaceSelectionController?.removeListener(
        _managedFaceControllerChanged,
      );
      widget.managedFaceSelectionController?.addListener(
        _managedFaceControllerChanged,
      );
      _managedFaceControllerChanged();
    }
    if (oldWidget.enableInspectionHover && !widget.enableInspectionHover) {
      _pendingHover = null;
      _nativeHover = null;
      _operationalHover = null;
      _managedFaceHover = null;
      native.clearHover();
    }
    if (oldWidget.scene != widget.scene) {
      _tapGeneration++;
      if (widget.enableInspectionHover) {
        operationalResolver.prepare(widget.scene);
      }
      oldWidget.scene.removeListener(_sceneChanged);
      widget.scene.addListener(_sceneChanged);
      if (_nativeActive && !_initializing) {
        if (_nativeSupportsMode) {
          native.sendDelta(widget.scene);
        } else {
          _switchBackend(ViewportBackend.flutterCanvas, modeFallback: true);
        }
      }
    }
    if (oldWidget.camera != widget.camera) {
      _tapGeneration++;
      oldWidget.camera.removeListener(_cameraChanged);
      widget.camera.addListener(_cameraChanged);
    }
  }

  void _changed() {
    if (!native.available) _tapGeneration++;
    if (mounted &&
        !native.available &&
        !_initializing &&
        !_switching &&
        backend == ViewportBackend.nativeGpu) {
      _switchBackend(ViewportBackend.flutterCanvas, recovery: true);
      return;
    }
    _recordViewportDiagnostics();
    if (mounted) setState(() {});
  }

  void _sceneChanged() {
    _tapGeneration++;
    _recordViewportDiagnostics();
    final selectedFace = _managedFaceSelection;
    final selectedSource = selectedFace == null
        ? null
        : widget.scene.find(selectedFace.entityId);
    if (selectedFace != null &&
        (selectedSource == null || !selectedSource.visible)) {
      _selectManagedFace(null);
    }
    if (widget.enableInspectionHover) operationalResolver.prepare(widget.scene);
    if (backend == ViewportBackend.flutterCanvas &&
        _requestedBackend == ViewportBackend.nativeGpu &&
        _nativeSupportsMode) {
      _switchBackend(ViewportBackend.nativeGpu);
      return;
    }
    if (backend == ViewportBackend.nativeGpu && !_nativeSupportsMode) {
      _switchBackend(ViewportBackend.flutterCanvas, modeFallback: true);
      return;
    }
    if (!_nativeActive || _initializing) return;
    unawaited(
      native.sendDelta(widget.scene).then((_) {
        if (mounted && _nativeActive) {
          _publishManagedFaceSelection(_managedFaceSelection);
        }
      }),
    );
  }

  void _cameraChanged() {
    ++_cameraRevision;
    _tapGeneration++;
    CameraPanAudit.record(
      'Componente IntegratedCadViewportWidget._cameraChanged consome\n'
      '${widget.camera.auditState()}',
    );
    if (_nativeActive && !_initializing) {
      CameraPanAudit.record(
        'NativeViewportBridge.setCamera() publica sem modificar\n'
        '${widget.camera.auditState()}',
      );
      native.setCamera(widget.camera);
      CameraPanAudit.record(
        'NativeViewportHost.SetCamera() -> Render solicitado',
      );
    } else {
      CameraPanAudit.record('Render Flutter Canvas');
    }
  }

  void _operationalSelectionChanged() {
    if (!_nativeActive) return;
    final activeId = operationalSelection.activeId;
    final presentation = activeId == null
        ? null
        : operationalResolver.presentation(activeId);
    if (presentation == null) {
      native.clearOperationalSelection();
      return;
    }
    native.setOperationalSelection(
      operationalEntityId: presentation.entity.id,
      entityId: presentation.entity.ownerId,
      triangleIndices: presentation.triangleIndices,
    );
  }

  Future<void> _ensureNative(Size size) async {
    if (!mounted ||
        backend != ViewportBackend.nativeGpu ||
        _initializing ||
        !Platform.isWindows ||
        !size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 1 ||
        size.height <= 1) {
      return;
    }
    if (native.available && native.sceneReady) {
      if (_nativeSize != size) {
        _nativeSize = size;
        await native.resize(size.width, size.height);
      }
      _recordViewportDiagnostics();
      return;
    }
    if (!_nativeSupportsMode) {
      _switchBackend(ViewportBackend.flutterCanvas, modeFallback: true);
      return;
    }
    _nativeWork = _initializeNative(size);
    await _nativeWork;
  }

  Future<void> _initializeNative(Size size) async {
    _initializing = true;
    final generation = _backendGeneration;
    final ready = await native.initialize(size.width, size.height);
    if (!mounted ||
        generation != _backendGeneration ||
        backend != ViewportBackend.nativeGpu) {
      _initializing = false;
      return;
    }
    _nativeSize = size;
    if (ready) {
      await native.sendInitial(widget.scene);
      if (mounted &&
          generation == _backendGeneration &&
          native.available &&
          native.sceneReady) {
        await native.sendDelta(widget.scene);
        int revision;
        do {
          revision = _cameraRevision;
          await native.setCamera(widget.camera);
        } while (mounted &&
            generation == _backendGeneration &&
            native.available &&
            revision != _cameraRevision);
      }
    }
    _recordViewportDiagnostics();
    _initializing = false;
    if (mounted &&
        generation == _backendGeneration &&
        (!native.available || !native.sceneReady)) {
      // Queue cleanup after this initialization has drained.
      _switchBackend(ViewportBackend.flutterCanvas, recovery: true);
    } else if (mounted && !_switching) {
      _operationalSelectionChanged();
      _publishManagedFaceSelection(_managedFaceSelection);
      setState(() {});
      await _viewportReady();
    }
  }

  void _switchBackend(
    ViewportBackend next, {
    bool recovery = false,
    bool modeFallback = false,
  }) {
    if (!mounted) return;
    final generation = ++_backendGeneration;
    ++_tapGeneration;
    _deltaDebounce?.cancel();
    _pendingHover = null;
    _nativeHover = null;
    _operationalHover = null;
    _managedFaceHover = null;
    _hoverRequestActive = false;
    _nativeNavigating = false;
    setState(() {
      if (recovery) _requestedBackend = ViewportBackend.flutterCanvas;
      backend = next;
      _switching = true;
      _backendNotice = recovery
          ? 'Native GPU indisponível. Recuperando com Flutter Canvas.'
          : modeFallback
          ? 'Flutter Canvas para toda a cena: ${_unsupportedReason ?? 'modo não suportado'}'
          : null;
    });
    _handoff = _handoff.then((_) async {
      await _nativeWork;
      await native.deactivate();
      if (!mounted || generation != _backendGeneration) return;
      // The preceding frame drops Canvas caches before a native snapshot exists.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || generation != _backendGeneration) return;
      if (next == ViewportBackend.nativeGpu) {
        await _ensureNative(
          Size(widget.camera.viewportWidth, widget.camera.viewportHeight),
        );
      }
      if (!mounted || generation != _backendGeneration) return;
      setState(() {
        _switching = false;
        if (recovery) {
          _backendNotice = 'Native GPU indisponível. Flutter Canvas ativo.';
        }
      });
      _recordViewportDiagnostics();
      _operationalSelectionChanged();
      _publishManagedFaceSelection(_managedFaceSelection);
      await _viewportReady();
    });
  }

  @override
  void dispose() {
    ++_backendGeneration;
    _tapGeneration++;
    _deltaDebounce?.cancel();
    widget.scene.removeListener(_sceneChanged);
    widget.camera.removeListener(_cameraChanged);
    native.removeListener(_changed);
    operationalSelection.removeListener(_operationalSelectionChanged);
    widget.managedFaceSelectionController?.removeListener(
      _managedFaceControllerChanged,
    );
    native.dispose();
    if (_ownsOperationalState) {
      operationalSelection.dispose();
      operationalEntities.dispose();
    }
    _viewportFocusNode.dispose();
    super.dispose();
  }

  Future<void> _viewportReady() async {
    final generation = _backendGeneration;
    final scene = widget.scene;
    if (!mounted ||
        _switching ||
        widget.camera.viewportWidth <= 1 ||
        widget.camera.viewportHeight <= 1) {
      return;
    }
    if (backend == ViewportBackend.nativeGpu) {
      if (!native.available || !native.sceneReady || _initializing) return;
      // Publish the scene delta before delivering Fit to the real camera/host.
      await native.sendDelta(widget.scene);
    }
    if (mounted &&
        identical(scene, widget.scene) &&
        !_switching &&
        generation == _backendGeneration &&
        (backend != ViewportBackend.nativeGpu ||
            (native.available && native.sceneReady))) {
      widget.onViewportReady?.call();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (backend == ViewportBackend.nativeGpu && !_switching) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _ensureNative(size),
        );
      }
      final useNative = _nativeActive && !_initializing;
      return Focus(
        focusNode: _viewportFocusNode,
        child: Listener(
          // A native viewport is visually active but is not a text-editing
          // FocusNode. Claim focus on pointer down so a previous Inspector or
          // TextField cannot keep blocking global history shortcuts.
          onPointerDown: (_) => _viewportFocusNode.requestFocus(),
          child: MouseRegion(
            cursor:
                widget.onSketchTap != null ||
                    widget.onSketchSupportPick != null ||
                    widget.onSketchEntityDragStart != null
                ? SystemMouseCursors.precise
                : useNative
                ? _nativeCursor
                : MouseCursor.defer,
            onHover: useNative || widget.onSketchHover != null
                ? (event) {
                    widget.onSketchSuggestionHoverPosition?.call(
                      event.localPosition,
                    );
                    widget.onSketchHover?.call(event.localPosition);
                    if (useNative) _updateNativeHover(event.localPosition);
                  }
                : null,
            onExit: useNative
                ? (_) {
                    _pendingHover = null;
                    native.clearHover();
                    setState(() {
                      _captureHover = null;
                      _nativeHover = null;
                      _operationalHover = null;
                      _managedFaceHover = null;
                    });
                    widget.onPickCaptureHover?.call(null);
                    widget.onSketchSuggestionHover?.call(null);
                    widget.onSketchSuggestionHoverPosition?.call(null);
                  }
                : null,
            child: Stack(
              children: [
                Positioned.fill(
                  child: useNative
                      ? Texture(
                          textureId: native.textureId!,
                          filterQuality: FilterQuality.none,
                        )
                      : const SizedBox.shrink(),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring:
                        _switching ||
                        _initializing ||
                        (backend == ViewportBackend.nativeGpu &&
                            !native.available),
                    child: ProfessionalCadViewportWidget(
                      onViewportReady: _viewportReady,
                      scene: widget.scene,
                      camera: widget.camera,
                      onPick: widget.onPick,
                      onPickCapture: useNative ? null : widget.onPickCapture,
                      pickCaptureCandidateIds: widget.pickCaptureCandidateIds,
                      onPickCaptureHover: useNative
                          ? null
                          : widget.onPickCaptureHover,
                      onSketchSuggestionHover: useNative
                          ? null
                          : widget.onSketchSuggestionHover,
                      onSketchSuggestionHoverPosition: useNative
                          ? null
                          : widget.onSketchSuggestionHoverPosition,
                      sketchSuggestionPickCandidateIds:
                          widget.sketchSuggestionPickCandidateIds,
                      captureHoveredEntityId: _captureHover?.entityId,
                      onManagedFacePick: useNative ? null : _pickCanvas,
                      onEmptyNormalTap: () {
                        _selectManagedFace(null);
                        widget.onViewportSelectionCleared?.call();
                      },
                      onManagedFaceHover: useNative ? null : _hoverCanvas,
                      managedFaceHover: _managedFaceHover,
                      managedFaceSelection: _managedFaceSelection,
                      onNormalTap: useNative ? _pickNativeTap : null,
                      brushActive: widget.brushActive,
                      brushCandidateIds: widget.brushCandidateIds,
                      brushDiameterMm: widget.brushDiameterMm,
                      brushCursorMode: widget.brushCursorMode,
                      onBrushDown: widget.onBrushDown,
                      onBrushMove: widget.onBrushMove,
                      onBrushUp: widget.onBrushUp,
                      onBrushCancel: widget.onBrushCancel,
                      onSketchSupportPick: widget.onSketchSupportPick,
                      onSketchEntityPick: widget.onSketchEntityPick,
                      onSketchEntityDoublePick: widget.onSketchEntityDoublePick,
                      onSketchTap: widget.onSketchTap,
                      onSketchSecondaryTap: widget.onSketchSecondaryTap,
                      onSketchHover: widget.onSketchHover,
                      onSketchEntityDragStart: widget.onSketchEntityDragStart,
                      onSketchEntityDragUpdate: widget.onSketchEntityDragUpdate,
                      onSketchEntityDragEnd: widget.onSketchEntityDragEnd,
                      showSketchGrid: widget.showSketchGrid,
                      renderStyle: _renderStyle,
                      onRenderStyleChanged: _setRenderStyle,
                      showRenderControls: false,
                      technicalRecognitionAvailable:
                          widget.technicalRecognitionAvailable,
                      renderMeshes:
                          backend == ViewportBackend.flutterCanvas &&
                          !_switching,
                      paintBackground: !useNative,
                      // Picking remains on in the transparent Flutter interaction
                      // layer even when meshes are rendered by the native GPU.
                      // Sketch profiles and construction geometry do not exist in
                      // the native triangle-only pick buffer.
                      enablePicking: true,
                      enableEntityHover: !useNative,
                      hideReferenceOverlays: !_showReferenceOverlays,
                      hideExperimentalTransientOverlays:
                          kFlcadDevShadedHideReferenceOverlays,
                      onNavigationChanged: useNative
                          ? (navigating) {
                              _nativeNavigating = navigating;
                              if (navigating) {
                                _tapGeneration++;
                                _pendingHover = null;
                                native.clearHover();
                                if (_nativeHover != null) {
                                  setState(() {
                                    _nativeHover = null;
                                    _operationalHover = null;
                                  });
                                }
                              } else if (_lastHoverPosition != null) {
                                _updateNativeHover(_lastHoverPosition!);
                              }
                            }
                          : null,
                    ),
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: SegmentedButton<CadRenderStyle>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: CadRenderStyle.shaded,
                        label: Text('Shaded'),
                      ),
                      ButtonSegment(
                        value: CadRenderStyle.wireframe,
                        label: Text('Wireframe'),
                      ),
                      ButtonSegment(
                        value: CadRenderStyle.hiddenLine,
                        label: Text('Arestas'),
                      ),
                      ButtonSegment(
                        value: CadRenderStyle.transparent,
                        label: Text('Transparência'),
                      ),
                    ],
                    selected: {_renderStyle},
                    onSelectionChanged: (value) => _setRenderStyle(value.first),
                  ),
                ),
                Positioned(
                  top: 58,
                  left: 10,
                  child: Tooltip(
                    message: 'Mostrar ou ocultar referências visuais.',
                    child: Material(
                      color: Colors.transparent,
                      child: FilterChip(
                        avatar: Icon(
                          _showReferenceOverlays
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                        ),
                        label: const Text('Referências'),
                        selected: _showReferenceOverlays,
                        onSelected: (value) =>
                            setState(() => _showReferenceOverlays = value),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 10,
                  right: 10,
                  child: SegmentedButton<ViewportBackend>(
                    showSelectedIcon: false,
                    segments: [
                      const ButtonSegment(
                        value: ViewportBackend.flutterCanvas,
                        label: Text('Flutter Canvas'),
                      ),
                      ButtonSegment(
                        value: ViewportBackend.nativeGpu,
                        label: const Text('Native GPU'),
                        enabled: Platform.isWindows,
                      ),
                    ],
                    selected: {backend},
                    onSelectionChanged: (selection) {
                      _requestedBackend = selection.first;
                      final next =
                          _requestedBackend == ViewportBackend.nativeGpu &&
                              !_nativeSupportsMode
                          ? ViewportBackend.flutterCanvas
                          : _requestedBackend;
                      if (next != backend) {
                        _switchBackend(
                          next,
                          modeFallback: next != _requestedBackend,
                        );
                      } else if (next != _requestedBackend) {
                        setState(
                          () => _backendNotice =
                              'Flutter Canvas para toda a cena: ${_unsupportedReason ?? 'modo não suportado'}',
                        );
                      } else {
                        setState(() => _backendNotice = null);
                      }
                    },
                  ),
                ),
                if (_backendNotice != null || _switching || _initializing)
                  Positioned(
                    top: 60,
                    left: 10,
                    child: Material(
                      color: Theme.of(context).colorScheme.surface,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          _backendNotice ??
                              'Preparando backend de visualização…',
                        ),
                      ),
                    ),
                  ),
                if (_viewportDiagnosticsEnabled && _diagnosticReport != null)
                  Positioned(
                    right: 10,
                    top: 60,
                    child: IgnorePointer(
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(
                            viewportDiagnosticOverlayText(_diagnosticReport!),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (useNative &&
                    !_nativeNavigating &&
                    _operationalHover != null &&
                    _lastHoverPosition != null)
                  Positioned(
                    left: (_lastHoverPosition!.dx + 16)
                        .clamp(
                          8.0,
                          (size.width - 236).clamp(8.0, double.infinity),
                        )
                        .toDouble(),
                    top: (_lastHoverPosition!.dy + 18)
                        .clamp(
                          8.0,
                          (size.height - 112).clamp(8.0, double.infinity),
                        )
                        .toDouble(),
                    child: IgnorePointer(
                      child: _OperationalHoverCard(
                        entity: _operationalHover!.entity,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _OperationalHoverCard extends StatelessWidget {
  const _OperationalHoverCard({required this.entity});
  final OperationalEntity entity;

  String get _typeLabel => switch (entity.type) {
    OperationalEntityType.meshRegion => 'Mesh Region',
    OperationalEntityType.plane => 'Plane',
    OperationalEntityType.cylinder => 'Cylinder',
    OperationalEntityType.cone => 'Cone',
    OperationalEntityType.sphere => 'Sphere',
    OperationalEntityType.fillet => 'Fillet',
    OperationalEntityType.freeformRegion => 'Freeform Region',
    OperationalEntityType.cadFace => 'CAD Face',
    OperationalEntityType.topologicalEdge => 'Topological Edge',
    OperationalEntityType.topologicalVertex => 'Topological Vertex',
    OperationalEntityType.sketchEntity => 'Sketch Entity',
    OperationalEntityType.curve => 'Curve',
    OperationalEntityType.section => 'Section',
    OperationalEntityType.surface => 'Surface',
  };

  @override
  Widget build(BuildContext context) {
    final capabilities = entity.capabilities
        .take(3)
        .map((capability) => capability.name)
        .join(' · ');
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xEE111923),
        border: Border.all(color: const Color(0x6659D8F5)),
        borderRadius: BorderRadius.circular(5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: Color(0xFFD8E6F0), fontSize: 11),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _typeLabel,
              style: const TextStyle(
                color: Color(0xFF64DDF5),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text('Owner: ${entity.ownerDomain}'),
            Text(entity.available ? 'Available' : 'Unavailable'),
            if (capabilities.isNotEmpty) Text(capabilities),
          ],
        ),
      ),
    );
  }
}
