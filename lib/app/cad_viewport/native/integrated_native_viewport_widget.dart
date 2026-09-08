import 'dart:async';
import 'dart:io';

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
    this.onSketchEntityDragStart,
    this.onSketchEntityDragUpdate,
    this.onSketchEntityDragEnd,
    this.showSketchGrid = false,
    this.operationalEntities,
    this.operationalResolver,
    this.operationalSelection,
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
  final void Function(CadViewportPick pick, Offset position)?
  onSketchEntityDragStart;
  final ValueChanged<Offset>? onSketchEntityDragUpdate;
  final ValueChanged<Offset>? onSketchEntityDragEnd;
  final bool showSketchGrid;
  final OperationalEntityRegistry? operationalEntities;
  final OperationalEntityResolver? operationalResolver;
  final OperationalSelectionManager? operationalSelection;

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
  Size? _nativeSize;
  bool _initializing = false;
  Timer? _deltaDebounce;
  NativeViewportPick? _nativeHover;
  OperationalResolution? _operationalHover;
  bool _hoverRequestActive = false;
  bool _nativeNavigating = false;
  CadRenderStyle _renderStyle = CadRenderStyle.shaded;
  Offset? _pendingHover;
  Offset? _lastHoverPosition;

  void _setRenderStyle(CadRenderStyle style) {
    _tapGeneration++;
    setState(() {
      _renderStyle = style;
      // The native pipeline currently provides the optimized opaque shaded
      // pass. The canvas pipeline owns the other global CAD display modes.
      // Switching here makes the toolbar authoritative instead of leaving a
      // native texture covering the requested presentation.
      backend = style == CadRenderStyle.shaded && Platform.isWindows
          ? ViewportBackend.nativeGpu
          : ViewportBackend.flutterCanvas;
    });
  }

  bool _canPublishTap(int token, CadSceneGraph scene) =>
      mounted &&
      token == _tapGeneration &&
      identical(scene, widget.scene) &&
      backend == ViewportBackend.nativeGpu &&
      native.available &&
      !_nativeNavigating;

  Future<void> _pickNativeTap(Offset position) async {
    final token = ++_tapGeneration;
    final scene = widget.scene;
    final additive = HardwareKeyboard.instance.isShiftPressed;
    final toggle = HardwareKeyboard.instance.isControlPressed;
    if (!_canPublishTap(token, scene)) return;
    final result = await native.pick(position.dx, position.dy);
    if (!_canPublishTap(token, scene)) return;
    // No hit (or an unresolvable hit) leaves selection unchanged, just as
    // Canvas picking does. Never substitute the last hover for this click.
    if (result == null || result.kind == NativePickKind.none) return;
    final resolved = await operationalResolver.resolve(result, scene);
    if (!_canPublishTap(token, scene) || resolved == null) return;
    operationalSelection.select(
      resolved.entity.id,
      additive: additive,
      toggle: toggle,
    );
    final point = result.point;
    if (point.length >= 3 && point.take(3).every((value) => value.isFinite)) {
      widget.onPick?.call(
        CadViewportPick(
          entityId: resolved.entity.ownerId,
          hit: MeshHit(
            triangleIndex: -1,
            point: Vector3(point[0], point[1], point[2]),
            distance: 0,
          ),
        ),
      );
    }
  }

  Future<void> _updateNativeHover(Offset position) async {
    _lastHoverPosition = position;
    _pendingHover = position;
    if (_hoverRequestActive || !native.available || _nativeNavigating) return;
    _hoverRequestActive = true;
    while (_pendingHover != null && native.available) {
      final current = _pendingHover!;
      _pendingHover = null;
      final result = await native.pick(current.dx, current.dy);
      final resolved = result == null
          ? null
          : await operationalResolver.resolve(result, widget.scene);
      if (_pendingHover != null || _nativeNavigating) continue;
      if (resolved == null) {
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
        });
      }
    }
    _hoverRequestActive = false;
  }

  MouseCursor get _nativeCursor => switch (_nativeHover?.kind) {
    NativePickKind.vertex => SystemMouseCursors.precise,
    NativePickKind.edge => SystemMouseCursors.click,
    NativePickKind.face => SystemMouseCursors.click,
    _ => MouseCursor.defer,
  };

  @override
  void initState() {
    super.initState();
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
    operationalResolver.prepare(widget.scene);
  }

  @override
  void didUpdateWidget(covariant IntegratedCadViewportWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scene != widget.scene) {
      _tapGeneration++;
      operationalResolver.prepare(widget.scene);
      oldWidget.scene.removeListener(_sceneChanged);
      widget.scene.addListener(_sceneChanged);
      if (native.available) native.sendInitial(widget.scene);
    }
    if (oldWidget.camera != widget.camera) {
      _tapGeneration++;
      oldWidget.camera.removeListener(_cameraChanged);
      widget.camera.addListener(_cameraChanged);
    }
  }

  void _changed() {
    if (!native.available) _tapGeneration++;
    if (mounted) setState(() {});
  }

  void _sceneChanged() {
    _tapGeneration++;
    operationalResolver.prepare(widget.scene);
    if (!native.available) return;
    _deltaDebounce?.cancel();
    _deltaDebounce = Timer(const Duration(milliseconds: 16), () {
      native.sendDelta(widget.scene);
    });
  }

  void _cameraChanged() {
    _tapGeneration++;
    CameraPanAudit.record(
      'Componente IntegratedCadViewportWidget._cameraChanged consome\n'
      '${widget.camera.auditState()}',
    );
    if (native.available) {
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
    if (_initializing || !Platform.isWindows) return;
    if (native.available) {
      if (_nativeSize != size) {
        _nativeSize = size;
        await native.resize(size.width, size.height);
      }
      return;
    }
    _initializing = true;
    final ready = await native.initialize(size.width, size.height);
    _nativeSize = size;
    if (ready) {
      await native.sendInitial(widget.scene);
      await native.setCamera(widget.camera);
      _operationalSelectionChanged();
    } else if (mounted) {
      _tapGeneration++;
      setState(() => backend = ViewportBackend.flutterCanvas);
    }
    _initializing = false;
  }

  @override
  void dispose() {
    _tapGeneration++;
    _deltaDebounce?.cancel();
    widget.scene.removeListener(_sceneChanged);
    widget.camera.removeListener(_cameraChanged);
    native.removeListener(_changed);
    operationalSelection.removeListener(_operationalSelectionChanged);
    native.dispose();
    if (_ownsOperationalState) {
      operationalSelection.dispose();
      operationalEntities.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (backend == ViewportBackend.nativeGpu) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _ensureNative(size),
        );
      }
      final useNative =
          backend == ViewportBackend.nativeGpu && native.available;
      return MouseRegion(
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
                widget.onSketchHover?.call(event.localPosition);
                if (useNative) _updateNativeHover(event.localPosition);
              }
            : null,
        onExit: useNative
            ? (_) {
                _pendingHover = null;
                native.clearHover();
                setState(() {
                  _nativeHover = null;
                  _operationalHover = null;
                });
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
              child: ProfessionalCadViewportWidget(
                scene: widget.scene,
                camera: widget.camera,
                onPick: widget.onPick,
                onNormalTap: useNative ? _pickNativeTap : null,
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
                renderMeshes: !useNative,
                paintBackground: !useNative,
                // Picking remains on in the transparent Flutter interaction
                // layer even when meshes are rendered by the native GPU.
                // Sketch profiles and construction geometry do not exist in
                // the native triangle-only pick buffer.
                enablePicking: true,
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
              top: 10,
              right: 10,
              child: SegmentedButton<ViewportBackend>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ViewportBackend.flutterCanvas,
                    label: Text('Flutter Canvas'),
                  ),
                  ButtonSegment(
                    value: ViewportBackend.nativeGpu,
                    label: Text('Native GPU'),
                  ),
                ],
                selected: {backend},
                onSelectionChanged: (selection) {
                  final next = selection.first;
                  _tapGeneration++;
                  setState(() {
                    backend = next;
                    if (next == ViewportBackend.nativeGpu) {
                      _renderStyle = CadRenderStyle.shaded;
                    }
                  });
                  if (next == ViewportBackend.nativeGpu) _ensureNative(size);
                },
              ),
            ),
            if (useNative &&
                !_nativeNavigating &&
                _operationalHover != null &&
                _lastHoverPosition != null)
              Positioned(
                left: (_lastHoverPosition!.dx + 16)
                    .clamp(8.0, (size.width - 236).clamp(8.0, double.infinity))
                    .toDouble(),
                top: (_lastHoverPosition!.dy + 18)
                    .clamp(8.0, (size.height - 112).clamp(8.0, double.infinity))
                    .toDouble(),
                child: IgnorePointer(
                  child: _OperationalHoverCard(
                    entity: _operationalHover!.entity,
                  ),
                ),
              ),
          ],
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
