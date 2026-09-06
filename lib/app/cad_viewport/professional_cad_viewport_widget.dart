import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:ui' show PointMode, VertexMode, Vertices;
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';

import '../../core/geometric_kernel/geometry/vectors.dart';
import '../navigation/cad_camera_navigation_adapter.dart';
import '../navigation/navigation_contracts.dart';
import '../navigation/navigation_engine.dart';
import '../navigation/navigation_debug_panel.dart';
import 'camera/cad_camera_controller.dart';
import 'rendering/cad_canvas_normal_pipeline.dart';
import 'rendering/cad_tonal_separation.dart';
import 'scene/cad_scene_graph.dart';
import 'selection/viewport_picking_controller.dart';

enum CadRenderStyle { shaded, wireframe, hiddenLine, transparent, ghost }

class ProfessionalCadViewportWidget extends StatefulWidget {
  const ProfessionalCadViewportWidget({
    super.key,
    required this.scene,
    required this.camera,
    this.onPick,
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
    this.renderMeshes = true,
    this.paintBackground = true,
    this.enablePicking = true,
    this.onNavigationChanged,
    this.showNavigationDebug = false,
    this.renderStyle,
    this.onRenderStyleChanged,
    this.showRenderControls = true,
  });

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
  final bool renderMeshes;
  final bool paintBackground;
  final bool enablePicking;
  final ValueChanged<bool>? onNavigationChanged;
  final bool showNavigationDebug;
  final CadRenderStyle? renderStyle;
  final ValueChanged<CadRenderStyle>? onRenderStyleChanged;
  final bool showRenderControls;

  @override
  State<ProfessionalCadViewportWidget> createState() =>
      _ProfessionalCadViewportWidgetState();
}

class _ProfessionalCadViewportWidgetState
    extends State<ProfessionalCadViewportWidget> {
  CadRenderStyle _localStyle = CadRenderStyle.shaded;
  CadRenderStyle get style => widget.renderStyle ?? _localStyle;

  void _setRenderStyle(CadRenderStyle value) {
    if (widget.onRenderStyleChanged != null) {
      widget.onRenderStyleChanged!(value);
    } else {
      setState(() => _localStyle = value);
    }
  }

  double previousScale = 1;
  final picking = ViewportPickingController();
  final Map<String, _MeshRenderCache> meshRenderCaches = {};

  bool get _sketchToolActive =>
      widget.onSketchTap != null ||
      widget.onSketchSupportPick != null ||
      widget.onSketchEntityDragStart != null;
  bool _draggingSketchEntity = false;
  Offset? _lastSketchDragPosition;
  String? hoveredEntityId;
  late NavigationEngine navigation;
  Vector3? _rotationCenterMarker;
  Timer? _rotationCenterMarkerTimer;
  bool get _isMouseNavigating => navigation.isNavigating;
  bool get _isOrbiting => navigation.state == NavigationState.orbiting;

  @override
  void initState() {
    super.initState();
    navigation = _createNavigationEngine();
  }

  @override
  void didUpdateWidget(covariant ProfessionalCadViewportWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.camera != widget.camera || oldWidget.scene != widget.scene) {
      navigation.dispose();
      navigation = _createNavigationEngine();
    }
  }

  NavigationEngine _createNavigationEngine() => NavigationEngine(
    camera: CadCameraNavigationAdapter(widget.camera),
    resolvePoint: (x, y) => picking
        .pick(
          position: Offset(x, y),
          camera: widget.camera,
          scene: widget.scene,
        )
        ?.hit
        .point,
    onNavigationChanged: widget.onNavigationChanged,
    onRotationCenterSet: _showRotationCenterMarker,
  );

  void _orbitFromViewCube(Offset delta) {
    const calibration = NavigationProfileCalibration.geomagicCatia;
    CadCameraNavigationAdapter(widget.camera).execute(
      OrbitCommand(
        delta.dx / calibration.orbitPixelsPerRadian,
        delta.dy / calibration.orbitPixelsPerRadian,
      ),
    );
  }

  void _startMouseNavigation(PointerDownEvent event) {
    if (_sketchToolActive && (event.buttons & kMiddleMouseButton) == 0) return;
    navigation.pointerDown(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      buttons: event.buttons,
    );
  }

  void _updateMouseNavigation(PointerMoveEvent event) {
    if (_sketchToolActive && !_isMouseNavigating) return;
    navigation.pointerMove(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      buttons: event.buttons,
    );
  }

  void _endMouseNavigation(PointerUpEvent event) {
    if (_sketchToolActive && !_isMouseNavigating) return;
    navigation.pointerUp(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      buttons: event.buttons,
    );
  }

  void _showRotationCenterMarker(Vector3 point) {
    _rotationCenterMarkerTimer?.cancel();
    setState(() => _rotationCenterMarker = point);
    _rotationCenterMarkerTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _rotationCenterMarker = null);
    });
  }

  void _zoomFromWheel(PointerScrollEvent event) {
    navigation.wheel(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      deltaY: event.scrollDelta.dy,
    );
  }

  @override
  void dispose() {
    _rotationCenterMarkerTimer?.cancel();
    navigation.dispose();
    super.dispose();
  }

  void _updateHover(Offset position) {
    final hit = picking.pick(
      position: position,
      camera: widget.camera,
      scene: widget.scene,
    );
    final next = hit?.entityId;
    if (next != hoveredEntityId && mounted) {
      setState(() => hoveredEntityId = next);
    }
  }

  void _fitVisibleScene([CadStandardView? standardView]) {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;

    void include(Object? raw) {
      if (raw is! List || raw.length < 3) return;
      final x = (raw[0] as num).toDouble();
      final y = (raw[1] as num).toDouble();
      final z = (raw[2] as num).toDouble();
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      minZ = math.min(minZ, z);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
      maxZ = math.max(maxZ, z);
    }

    for (final entity in widget.scene.entities.where((item) => item.visible)) {
      final nodes = entity.geometry['nodes'];
      if (nodes is List) {
        for (var i = 0; i + 2 < nodes.length; i += 3) {
          include([nodes[i], nodes[i + 1], nodes[i + 2]]);
        }
      }
      final points = entity.geometry['points'];
      if (points is List) {
        for (final point in points) {
          include(point);
        }
      }
      final segments = entity.geometry['segments'];
      if (segments is List) {
        for (final segment in segments.whereType<List>()) {
          for (final point in segment) {
            include(point);
          }
        }
      }
    }
    if (!minX.isFinite || !maxX.isFinite) return;
    final minimum = Vector3(minX, minY, minZ);
    final maximum = Vector3(maxX, maxY, maxZ);
    if (standardView == null) {
      navigation.fit(minimum, maximum);
    } else {
      widget.camera.setStandardView(standardView, minimum, maximum);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) =>
              widget.camera.resize(constraints.maxWidth, constraints.maxHeight),
        );
        final colors = Theme.of(context).colorScheme;
        return MouseRegion(
          cursor: _sketchToolActive
              ? SystemMouseCursors.precise
              : !widget.enablePicking || hoveredEntityId == null
              ? MouseCursor.defer
              : SystemMouseCursors.click,
          onHover: (event) {
            if (!_isMouseNavigating) {
              widget.onSketchHover?.call(event.localPosition);
            }
            if (widget.enablePicking && !_isMouseNavigating) {
              _updateHover(event.localPosition);
            }
          },
          onExit: (_) {
            if (hoveredEntityId != null) {
              setState(() => hoveredEntityId = null);
            }
          },
          child: Listener(
            onPointerDown: _startMouseNavigation,
            onPointerMove: _updateMouseNavigation,
            onPointerUp: _endMouseNavigation,
            onPointerCancel: (_) {
              navigation.pointerCancel();
            },
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _zoomFromWheel(event);
              }
            },
            child: GestureDetector(
              onScaleStart: (event) {
                previousScale = 1;
                if (widget.onSketchEntityDragStart != null) {
                  final hit = picking.pick(
                    position: event.localFocalPoint,
                    camera: widget.camera,
                    scene: widget.scene,
                  );
                  if (hit != null &&
                      widget.scene.find(hit.entityId)?.kind ==
                          CadSceneEntityKind.sketch) {
                    _draggingSketchEntity = true;
                    _lastSketchDragPosition = event.localFocalPoint;
                    widget.onSketchEntityDragStart!(
                      hit,
                      event.localFocalPoint,
                    );
                  }
                }
              },
              onDoubleTapDown: widget.onSketchEntityDoublePick == null
                  ? null
                  : (event) {
                      final hit = picking.pick(
                        position: event.localPosition,
                        camera: widget.camera,
                        scene: widget.scene,
                      );
                      if (hit != null &&
                          widget.scene.find(hit.entityId)?.kind ==
                              CadSceneEntityKind.sketch) {
                        widget.onSketchEntityDoublePick!(hit);
                      }
                    },
              onTapUp: widget.onSketchTap != null
                  ? (event) {
                      final hit = picking.pick(
                        position: event.localPosition,
                        camera: widget.camera,
                        scene: widget.scene,
                      );
                      final existing = hit == null
                          ? null
                          : widget.scene.find(hit.entityId);
                      if (hit != null &&
                          existing?.kind == CadSceneEntityKind.sketch &&
                          widget.onSketchEntityPick != null) {
                        widget.onSketchEntityPick!(hit);
                      } else {
                        widget.onSketchTap!(event.localPosition);
                      }
                    }
                  : widget.onSketchSupportPick != null
                  ? (event) {
                      final hit = picking.pick(
                        position: event.localPosition,
                        camera: widget.camera,
                        scene: widget.scene,
                      );
                      if (hit != null) widget.onSketchSupportPick!(hit);
                    }
                  : !widget.enablePicking
                  ? null
                  : widget.onPick == null
                  ? null
                  : (event) {
                      final hit = picking.pick(
                        position: event.localPosition,
                        camera: widget.camera,
                        scene: widget.scene,
                      );
                      if (hit != null) {
                        navigation.focus(hit.hit.point);
                        widget.onPick!(hit);
                      }
                    },
              onSecondaryTapUp: widget.onSketchSecondaryTap == null
                  ? null
                  : (_) => widget.onSketchSecondaryTap!(),
              onScaleUpdate: (event) {
                if (_draggingSketchEntity && event.pointerCount == 1) {
                  _lastSketchDragPosition = event.localFocalPoint;
                  widget.onSketchEntityDragUpdate?.call(event.localFocalPoint);
                }
                if (!_sketchToolActive &&
                    event.pointerCount > 1 &&
                    event.scale != previousScale) {
                  navigation.scale(previousScale / event.scale);
                  previousScale = event.scale;
                }
              },
              onScaleEnd: (_) {
                previousScale = 1;
                if (_draggingSketchEntity) {
                  _draggingSketchEntity = false;
                  final position = _lastSketchDragPosition;
                  _lastSketchDragPosition = null;
                  if (position != null) {
                    widget.onSketchEntityDragEnd?.call(position);
                  }
                }
              },
              child: ColoredBox(
                color: widget.paintBackground
                    ? colors.surfaceContainerLowest
                    : Colors.transparent,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          isComplex: true,
                          willChange: true,
                          painter: _CadScenePainter(
                            scene: widget.scene,
                            camera: widget.camera,
                            style: style,
                            colors: colors,
                            showGrid: widget.showSketchGrid,
                            meshRenderCaches: meshRenderCaches,
                            hoveredEntityId: hoveredEntityId,
                            rotationCenterMarker: _rotationCenterMarker,
                            renderMeshes: widget.renderMeshes,
                            paintBackground: widget.paintBackground,
                            highlightSketchSupports:
                                widget.onSketchSupportPick != null,
                            navigationActive: _isMouseNavigating,
                            orbitActive: _isOrbiting,
                          ),
                        ),
                      ),
                    ),
                    if (widget.showRenderControls)
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
                              label: Text('Wire'),
                            ),
                            ButtonSegment(
                              value: CadRenderStyle.hiddenLine,
                              label: Text('Hidden line'),
                            ),
                            ButtonSegment(
                              value: CadRenderStyle.transparent,
                              label: Text('X-Ray'),
                            ),
                          ],
                          selected: {style},
                          onSelectionChanged: (value) =>
                              _setRenderStyle(value.first),
                        ),
                      ),
                    if (widget.showNavigationDebug)
                      Positioned(
                        left: 10,
                        bottom: 10,
                        child: NavigationDebugPanel(engine: navigation),
                      ),
                    Positioned(
                      right: 152,
                      top: 10,
                      child: Column(
                        children: [
                          IconButton.filledTonal(
                            tooltip: 'Fit View',
                            onPressed: _fitVisibleScene,
                            icon: const Icon(Icons.fit_screen),
                          ),
                          const SizedBox(height: 6),
                          IconButton.filledTonal(
                            tooltip: widget.camera.projectionMode.name,
                            onPressed: widget.camera.toggleProjection,
                            icon: const Icon(Icons.view_in_ar),
                          ),
                          const SizedBox(height: 6),
                          Material(
                            color: Colors.transparent,
                            child: PopupMenuButton<CadStandardView>(
                              tooltip: 'Views',
                              onSelected: _fitVisibleScene,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colors.secondaryContainer,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.view_in_ar_outlined, size: 18),
                                      SizedBox(width: 5),
                                      Text('Views'),
                                      Icon(Icons.arrow_drop_down, size: 18),
                                    ],
                                  ),
                                ),
                              ),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: CadStandardView.perspective,
                                  child: Text('Perspective  F1'),
                                ),
                                PopupMenuItem(
                                  value: CadStandardView.top,
                                  child: Text('Top  F2'),
                                ),
                                PopupMenuItem(
                                  value: CadStandardView.bottom,
                                  child: Text('Bottom  F3'),
                                ),
                                PopupMenuItem(
                                  value: CadStandardView.front,
                                  child: Text('Front  F4'),
                                ),
                                PopupMenuItem(
                                  value: CadStandardView.back,
                                  child: Text('Back  F5'),
                                ),
                                PopupMenuItem(
                                  value: CadStandardView.right,
                                  child: Text('Right  F6'),
                                ),
                                PopupMenuItem(
                                  value: CadStandardView.left,
                                  child: Text('Left  F7'),
                                ),
                                PopupMenuItem(
                                  value: CadStandardView.isometric,
                                  child: Text('Isometric  F8'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      right: 10,
                      top: 10,
                      child: _ProfessionalViewCube(
                        camera: widget.camera,
                        orbitActive: _isOrbiting,
                        onViewSelected: _fitVisibleScene,
                        onOrbit: _orbitFromViewCube,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProfessionalViewCube extends StatelessWidget {
  const _ProfessionalViewCube({
    required this.camera,
    required this.orbitActive,
    required this.onViewSelected,
    required this.onOrbit,
  });

  static const size = Size(132, 132);
  final CadCameraController camera;
  final bool orbitActive;
  final ValueChanged<CadStandardView> onViewSelected;
  final ValueChanged<Offset> onOrbit;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: camera,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final geometry = _ViewCubeGeometry(camera, size);
      return AnimatedOpacity(
        duration: Duration.zero,
        opacity: orbitActive ? .24 : 1,
        child: Semantics(
          key: const ValueKey('professional-view-cube'),
          label: 'ViewCube',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (event) {
              final view = geometry.viewAt(event.localPosition);
              if (view != null) onViewSelected(view);
            },
            onPanUpdate: (event) => onOrbit(event.delta),
            child: CustomPaint(
              size: size,
              painter: _ViewCubePainter(geometry: geometry, colors: colors),
            ),
          ),
        ),
      );
    },
  );
}

class _ViewCubeFace {
  const _ViewCubeFace({
    required this.view,
    required this.label,
    required this.path,
    required this.depth,
  });
  final CadStandardView view;
  final String label;
  final Path path;
  final double depth;
}

class _ViewCubeGeometry {
  _ViewCubeGeometry(this.camera, this.size) {
    _build();
  }

  final CadCameraController camera;
  final Size size;
  final faces = <_ViewCubeFace>[];
  final axisEndpoints = <String, Offset>{};
  late Offset center;
  late double isoRadius;

  void _build() {
    center = size.center(Offset.zero);
    isoRadius = 16.5;
    final forward = (camera.target - camera.eye).normalized;
    final right = forward.cross(camera.up).normalized;
    final viewUp = right.cross(forward).normalized;
    const extent = 34.0;

    Offset project(Vector3 point) => Offset(
      center.dx + point.dot(right) * extent,
      center.dy - point.dot(viewUp) * extent,
    );

    const definitions = <(CadStandardView, String, Vector3, List<Vector3>)>[
      (
        CadStandardView.right,
        'RIGHT',
        Vector3(1, 0, 0),
        [
          Vector3(1, -1, -1),
          Vector3(1, 1, -1),
          Vector3(1, 1, 1),
          Vector3(1, -1, 1),
        ],
      ),
      (
        CadStandardView.left,
        'LEFT',
        Vector3(-1, 0, 0),
        [
          Vector3(-1, 1, -1),
          Vector3(-1, -1, -1),
          Vector3(-1, -1, 1),
          Vector3(-1, 1, 1),
        ],
      ),
      (
        CadStandardView.back,
        'BACK',
        Vector3(0, 1, 0),
        [
          Vector3(1, 1, -1),
          Vector3(-1, 1, -1),
          Vector3(-1, 1, 1),
          Vector3(1, 1, 1),
        ],
      ),
      (
        CadStandardView.front,
        'FRONT',
        Vector3(0, -1, 0),
        [
          Vector3(-1, -1, -1),
          Vector3(1, -1, -1),
          Vector3(1, -1, 1),
          Vector3(-1, -1, 1),
        ],
      ),
      (
        CadStandardView.top,
        'TOP',
        Vector3(0, 0, 1),
        [
          Vector3(-1, -1, 1),
          Vector3(1, -1, 1),
          Vector3(1, 1, 1),
          Vector3(-1, 1, 1),
        ],
      ),
      (
        CadStandardView.bottom,
        'BOTTOM',
        Vector3(0, 0, -1),
        [
          Vector3(-1, 1, -1),
          Vector3(1, 1, -1),
          Vector3(1, -1, -1),
          Vector3(-1, -1, -1),
        ],
      ),
    ];
    for (final definition in definitions) {
      final (view, label, normal, vertices) = definition;
      if (normal.dot(forward) >= -.0001) continue;
      final projected = vertices.map(project).toList();
      final path = Path()..moveTo(projected.first.dx, projected.first.dy);
      for (final point in projected.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      path.close();
      final depth =
          vertices.map((point) => point.dot(forward)).reduce((a, b) => a + b) /
          vertices.length;
      faces.add(
        _ViewCubeFace(view: view, label: label, path: path, depth: depth),
      );
    }
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    axisEndpoints['X'] = project(const Vector3(1.55, 0, 0));
    axisEndpoints['Y'] = project(const Vector3(0, 1.55, 0));
    axisEndpoints['Z'] = project(const Vector3(0, 0, 1.55));
  }

  CadStandardView? viewAt(Offset position) {
    if ((position - center).distance <= isoRadius) {
      return CadStandardView.isometric;
    }
    for (final face in faces.reversed) {
      if (face.path.contains(position)) return face.view;
    }
    return null;
  }
}

class _ViewCubePainter extends CustomPainter {
  const _ViewCubePainter({required this.geometry, required this.colors});
  final _ViewCubeGeometry geometry;
  final ColorScheme colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)),
      Paint()..color = colors.surfaceContainerHighest.withValues(alpha: .76),
    );
    for (var index = 0; index < geometry.faces.length; index++) {
      final face = geometry.faces[index];
      canvas.drawPath(
        face.path,
        Paint()
          ..color = Color.lerp(
            colors.surfaceContainer,
            colors.primaryContainer,
            .25 + index * .12,
          )!,
      );
      canvas.drawPath(
        face.path,
        Paint()
          ..color = colors.outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      final bounds = face.path.getBounds();
      final painter = TextPainter(
        text: TextSpan(
          text: face.label,
          style: TextStyle(
            color: colors.onSurface,
            fontSize: face.label.length > 5 ? 7 : 8,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: bounds.width);
      painter.paint(
        canvas,
        Offset(
          bounds.center.dx - painter.width / 2,
          bounds.center.dy - painter.height / 2,
        ),
      );
    }
    final axisColors = <String, Color>{
      'X': Colors.redAccent,
      'Y': Colors.green,
      'Z': Colors.lightBlueAccent,
    };
    for (final entry in geometry.axisEndpoints.entries) {
      canvas.drawLine(
        geometry.center,
        entry.value,
        Paint()
          ..color = axisColors[entry.key]!
          ..strokeWidth = 1.3,
      );
      final painter = TextPainter(
        text: TextSpan(
          text: entry.key,
          style: TextStyle(
            color: axisColors[entry.key],
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, entry.value - const Offset(4, 5));
    }
    canvas.drawCircle(
      geometry.center,
      geometry.isoRadius,
      Paint()..color = colors.primary,
    );
    final iso = TextPainter(
      text: TextSpan(
        text: 'ISO',
        style: TextStyle(
          color: colors.onPrimary,
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    iso.paint(canvas, geometry.center - Offset(iso.width / 2, iso.height / 2));
  }

  @override
  bool shouldRepaint(covariant _ViewCubePainter oldDelegate) => true;
}

class _ProjectedTriangle {
  const _ProjectedTriangle(
    this.path,
    this.depth,
    this.intensity,
    this.selected,
    this.reconstructionStatus,
  );
  final Path path;
  final double depth;
  final double intensity;
  final bool selected;
  final String? reconstructionStatus;
}

class _MeshRenderChunk {
  _MeshRenderChunk({
    required this.xyz,
    required this.indices,
    required this.normals,
  }) : screen = Float32List(xyz.length ~/ 3 * 2),
       depth = Float32List(xyz.length ~/ 3),
       colors = Int32List(xyz.length ~/ 3),
       drawIndices = Uint16List(indices.length),
       depthBuckets = List.generate(256, (_) => <int>[]);

  final Float64List xyz;
  final Uint16List indices;
  final Float32List normals;
  final Float32List screen;
  final Float32List depth;
  final Int32List colors;
  final Uint16List drawIndices;
  final List<List<int>> depthBuckets;
  int colorKey = -1;
  double averageDepth = 0;

  void updateDepthOrder() {
    if (indices.isEmpty) return;
    var minimum = double.infinity;
    var maximum = double.negativeInfinity;
    var sum = 0.0;
    final faceCount = indices.length ~/ 3;
    final faceDepth = Float32List(faceCount);
    for (var face = 0; face < faceCount; face++) {
      final offset = face * 3;
      final value =
          (depth[indices[offset]] +
              depth[indices[offset + 1]] +
              depth[indices[offset + 2]]) /
          3;
      faceDepth[face] = value;
      minimum = math.min(minimum, value);
      maximum = math.max(maximum, value);
      sum += value;
    }
    averageDepth = sum / math.max(faceCount, 1);
    for (final bucket in depthBuckets) {
      bucket.clear();
    }
    final extent = math.max(maximum - minimum, 1e-12);
    for (var face = 0; face < faceCount; face++) {
      final bucket = (((faceDepth[face] - minimum) / extent) * 255)
          .round()
          .clamp(0, 255);
      depthBuckets[bucket].add(face);
    }
    var output = 0;
    for (var bucket = depthBuckets.length - 1; bucket >= 0; bucket--) {
      for (final face in depthBuckets[bucket]) {
        final offset = face * 3;
        drawIndices[output++] = indices[offset];
        drawIndices[output++] = indices[offset + 1];
        drawIndices[output++] = indices[offset + 2];
      }
    }
  }
}

class _MeshRenderCache {
  _MeshRenderCache._(this.chunks, this.nodesSource, this.trianglesSource);
  final List<_MeshRenderChunk> chunks;
  final Object nodesSource;
  final Object trianglesSource;

  factory _MeshRenderCache.from(CadSceneEntity entity) {
    final nodes = (entity.geometry['nodes'] as List).cast<num>();
    final triangles = (entity.geometry['triangles'] as List).cast<num>();
    final chunks = CadCanvasNormalPipeline.build(nodes, triangles)
        .map(
          (chunk) => _MeshRenderChunk(
            xyz: chunk.xyz,
            indices: chunk.indices,
            normals: chunk.normals,
          ),
        )
        .toList(growable: false);
    return _MeshRenderCache._(
      chunks,
      entity.geometry['nodes'] as Object,
      entity.geometry['triangles'] as Object,
    );
  }
}

class _CadScenePainter extends CustomPainter {
  _CadScenePainter({
    required this.scene,
    required this.camera,
    required this.style,
    required this.colors,
    required this.showGrid,
    required this.meshRenderCaches,
    required this.hoveredEntityId,
    required this.rotationCenterMarker,
    required this.renderMeshes,
    required this.paintBackground,
    required this.highlightSketchSupports,
    required this.navigationActive,
    required this.orbitActive,
  }) : super(repaint: Listenable.merge([scene, camera]));
  final CadSceneGraph scene;
  final CadCameraController camera;
  final CadRenderStyle style;
  final ColorScheme colors;
  final bool showGrid;
  final Map<String, _MeshRenderCache> meshRenderCaches;
  final String? hoveredEntityId;
  final Vector3? rotationCenterMarker;
  final bool renderMeshes, paintBackground;
  final bool highlightSketchSupports;
  final bool navigationActive;
  final bool orbitActive;

  @override
  void paint(Canvas canvas, Size size) {
    if (paintBackground) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors.brightness == Brightness.dark
                ? const [Color(0xff111923), Color(0xff080d12)]
                : const [Color(0xffeef2f5), Color(0xffd7dde2)],
          ).createShader(Offset.zero & size),
      );
    }
    final currentEntityIds = scene.entities.map((entity) => entity.id).toSet();
    meshRenderCaches.removeWhere((id, _) => !currentEntityIds.contains(id));
    if (showGrid) {
      const spacing = 24.0;
      final center = Offset(size.width / 2, size.height / 2);
      for (var x = center.dx % spacing; x < size.width; x += spacing) {
        final major = ((x - center.dx) / spacing).round() % 5 == 0;
        canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          Paint()
            ..color = colors.outlineVariant.withValues(alpha: major ? .24 : .10)
            ..strokeWidth = major ? .7 : .4,
        );
      }
      for (var y = center.dy % spacing; y < size.height; y += spacing) {
        final major = ((y - center.dy) / spacing).round() % 5 == 0;
        canvas.drawLine(
          Offset(0, y),
          Offset(size.width, y),
          Paint()
            ..color = colors.outlineVariant.withValues(alpha: major ? .24 : .10)
            ..strokeWidth = major ? .7 : .4,
        );
      }
      canvas.drawLine(
        Offset(center.dx, 0),
        Offset(center.dx, size.height),
        Paint()
          ..color = Colors.greenAccent.withValues(alpha: .42)
          ..strokeWidth = 1,
      );
      canvas.drawLine(
        Offset(0, center.dy),
        Offset(size.width, center.dy),
        Paint()
          ..color = Colors.redAccent.withValues(alpha: .42)
          ..strokeWidth = 1,
      );
    }
    final projected = <_ProjectedTriangle>[];
    for (final entity in scene.entities.where((item) => item.visible)) {
      if (entity.kind == CadSceneEntityKind.surface &&
          entity.geometry['shaded'] == false) {
        continue;
      }
      if (renderMeshes &&
          entity.geometry['nodes'] is List &&
          entity.geometry['triangles'] is List) {
        final entityMode = entity.geometry['displayMode'] as String?;
        if (style == CadRenderStyle.wireframe) {
          _paintMeshFeatureEdges(canvas, entity, size, alpha: .96);
        } else if (style == CadRenderStyle.transparent) {
          _paintMeshBatched(canvas, entity, size, alphaOverride: .24);
          _paintMeshFeatureEdges(canvas, entity, size, alpha: .72);
        } else if (style == CadRenderStyle.hiddenLine) {
          _paintMeshBatched(canvas, entity, size, alphaOverride: 1);
          _paintMeshFeatureEdges(canvas, entity, size, alpha: .92);
        } else if (style == CadRenderStyle.shaded) {
          _paintMeshBatched(canvas, entity, size, alphaOverride: 1);
        } else if (entityMode == 'shadedWithEdges') {
          _paintMeshBatched(canvas, entity, size, alphaOverride: 1);
          _paintMeshFeatureEdges(canvas, entity, size, alpha: .92);
        } else if (entityMode == 'transparent') {
          _paintMeshBatched(canvas, entity, size, alphaOverride: .24);
          _paintMeshFeatureEdges(canvas, entity, size, alpha: .42);
        } else {
          _paintMeshBatched(canvas, entity, size);
        }
      } else {
        _paintReference(canvas, size, entity);
      }
    }
    projected.sort((a, b) => b.depth.compareTo(a.depth));
    for (final triangle in projected) {
      final selected = triangle.selected
          ? colors.tertiary
          : switch (triangle.reconstructionStatus) {
              'reconstructed' => Colors.green,
              'inProgress' => Colors.amber,
              'pending' => Colors.red,
              'ignored' => Colors.grey,
              _ => colors.primary,
            };
      final alpha = style == CadRenderStyle.transparent ? .22 : .82;
      if (style != CadRenderStyle.wireframe) {
        canvas.drawPath(
          triangle.path,
          Paint()
            ..style = PaintingStyle.fill
            ..color = Color.lerp(
              colors.surfaceContainer,
              selected,
              triangle.intensity,
            )!.withValues(alpha: alpha),
        );
      }
      if (style != CadRenderStyle.shaded || triangle.selected) {
        canvas.drawPath(
          triangle.path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = triangle.selected ? 1.8 : .65
            ..color = selected.withValues(alpha: .9),
        );
      }
    }
    _paintRotationCenterMarker(canvas, size);
    _paintOrientationTriad(canvas, size);
  }

  void _paintRotationCenterMarker(Canvas canvas, Size size) {
    final marker = rotationCenterMarker;
    if (marker == null) return;
    final point = camera.viewProjectionMatrix.transformPoint(marker);
    if (!point.x.isFinite || !point.y.isFinite) return;
    final center = Offset(
      (point.x + 1) * size.width / 2,
      (1 - point.y) * size.height / 2,
    );
    final paint = Paint()
      ..color = colors.tertiary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..isAntiAlias = true;
    canvas.drawCircle(center, 9, paint);
    canvas.drawLine(
      center - const Offset(13, 0),
      center + const Offset(13, 0),
      paint,
    );
    canvas.drawLine(
      center - const Offset(0, 13),
      center + const Offset(0, 13),
      paint,
    );
  }

  void _paintOrientationTriad(Canvas canvas, Size size) {
    if (size.width < 70 || size.height < 70) return;
    final origin = Offset(39, size.height - 39);
    final viewOrigin = camera.viewMatrix.transformPoint(Vector3.zero);
    final passiveOpacity = orbitActive
        ? .22
        : navigationActive
        ? .62
        : .78;

    Offset direction(Vector3 axis) {
      final viewed = camera.viewMatrix.transformPoint(axis) - viewOrigin;
      final projected = Offset(viewed.x, -viewed.y);
      final length = projected.distance;
      return length < 1e-8 ? Offset.zero : projected / length * 22;
    }

    void axis(Vector3 vector, String label, Color color) {
      final delta = direction(vector);
      final end = origin + delta;
      if (delta == Offset.zero) {
        canvas.drawCircle(
          origin,
          4,
          Paint()
            ..color = color.withValues(alpha: passiveOpacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.25
            ..isAntiAlias = true,
        );
        canvas.drawCircle(
          origin,
          1.4,
          Paint()..color = color.withValues(alpha: passiveOpacity),
        );
      } else {
        canvas.drawLine(
          origin,
          end,
          Paint()
            ..color = color.withValues(alpha: passiveOpacity)
            ..strokeWidth = 1.35
            ..strokeCap = StrokeCap.round
            ..isAntiAlias = true,
        );
      }
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: color.withValues(alpha: passiveOpacity),
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelPosition = delta == Offset.zero
          ? origin + const Offset(6, -13)
          : end + delta / 8 - const Offset(3, 5);
      painter.paint(canvas, labelPosition);
    }

    canvas.drawCircle(
      origin,
      28,
      Paint()
        ..color = colors.surfaceContainerHighest.withValues(alpha: .34)
        ..isAntiAlias = true,
    );
    canvas.drawCircle(
      origin,
      28,
      Paint()
        ..color = colors.outline.withValues(alpha: .18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .65
        ..isAntiAlias = true,
    );
    axis(const Vector3(1, 0, 0), 'X', Colors.redAccent);
    axis(const Vector3(0, 1, 0), 'Y', Colors.green);
    axis(const Vector3(0, 0, 1), 'Z', Colors.lightBlueAccent);
    canvas.drawCircle(
      origin,
      2,
      Paint()..color = colors.onSurface.withValues(alpha: passiveOpacity),
    );
  }

  void _paintMeshBatched(
    Canvas canvas,
    CadSceneEntity entity,
    Size size, {
    double? alphaOverride,
  }) {
    // Shaded is deliberately opaque: partial alpha made dense STL meshes look
    // hollow because Flutter's 2D canvas has no per-triangle depth buffer.
    final alpha =
        alphaOverride ??
        (style == CadRenderStyle.transparent
            ? .22
            : entity.transparent || entity.kind == CadSceneEntityKind.preview
            ? .34
            : 1.0);
    var cache = meshRenderCaches[entity.id];
    if (cache == null ||
        !identical(cache.nodesSource, entity.geometry['nodes']) ||
        !identical(cache.trianglesSource, entity.geometry['triangles'])) {
      cache = _MeshRenderCache.from(entity);
      meshRenderCaches[entity.id] = cache;
    }
    final matrix = camera.viewProjectionMatrix.values;
    final isHovered = entity.id == hoveredEntityId;
    final foregroundColor = switch ((
      entity.selected,
      isHovered,
      entity.kind,
      entity.geometry['displayColor'],
    )) {
      (true, _, _, _) => const Color(0xffffb02e),
      (_, true, _, _) => const Color(0xff38d6ff),
      (_, _, _, 'destructiveRed') => Colors.redAccent,
      (_, _, _, 'surfacePreviewBlue') => const Color(0xff38bdf8),
      (_, _, CadSceneEntityKind.preview, _) => const Color(0xffff9f43),
      (_, _, CadSceneEntityKind.surface, _) => const Color(0xffe2e7ee),
      (_, _, CadSceneEntityKind.solid, _) => const Color(0xffd8e0e9),
      _ => const Color(0xff7899ad),
    };
    final foreground = foregroundColor.toARGB32();
    final legacyAnalysisMode =
        entity.geometry['surfaceAnalysisMode'] as String?;
    final analysisModes = <String>[
      ...(entity.geometry['surfaceAnalysisModes'] as List? ?? const [])
          .whereType<String>(),
      if (entity.geometry['surfaceAnalysisModes'] == null &&
          legacyAnalysisMode != null)
        legacyAnalysisMode,
    ];
    final analysisIntensities = Map<String, dynamic>.from(
      entity.geometry['surfaceAnalysisIntensities'] as Map? ?? const {},
    );
    final reconstructionStatuses = Map<String, dynamic>.from(
      entity.geometry['reconstructionTriangleStatuses'] as Map? ?? const {},
    );
    final alphaByte = (alpha * 255).round();
    final forward = (camera.target - camera.eye).normalized;
    final right = forward.cross(camera.up).normalized;
    final cameraUp = right.cross(forward).normalized;
    final towardEye = forward * -1;
    final keyLight =
        (towardEye * .78 + cameraUp * .48 - right * .22).normalized;
    final fillLight =
        (towardEye * .42 - cameraUp * .28 + right * .66).normalized;
    final viewKey = Object.hash(
      forward.x.toStringAsFixed(4),
      forward.y.toStringAsFixed(4),
      forward.z.toStringAsFixed(4),
      cameraUp.x.toStringAsFixed(4),
      cameraUp.y.toStringAsFixed(4),
      cameraUp.z.toStringAsFixed(4),
    );
    final colorKey = Object.hash(
      foreground,
      alphaByte,
      Object.hashAll(analysisModes),
      Object.hashAll(
        analysisModes.map((mode) => analysisIntensities[mode] ?? 1.0),
      ),
      Object.hashAll(reconstructionStatuses.entries),
      viewKey,
    );
    var minX = double.infinity,
        minY = double.infinity,
        maxX = double.negativeInfinity,
        maxY = double.negativeInfinity;
    for (final chunk in cache.chunks) {
      for (var i = 0, p = 0; i < chunk.xyz.length; i += 3, p += 2) {
        final x = chunk.xyz[i], y = chunk.xyz[i + 1], z = chunk.xyz[i + 2];
        final w = matrix[12] * x + matrix[13] * y + matrix[14] * z + matrix[15];
        final px =
            (matrix[0] * x + matrix[1] * y + matrix[2] * z + matrix[3]) / w;
        final py =
            (matrix[4] * x + matrix[5] * y + matrix[6] * z + matrix[7]) / w;
        final pz =
            (matrix[8] * x + matrix[9] * y + matrix[10] * z + matrix[11]) / w;
        chunk.screen[p] = (px + 1) * size.width / 2;
        chunk.screen[p + 1] = (1 - py) * size.height / 2;
        chunk.depth[i ~/ 3] = pz;
        if (chunk.screen[p].isFinite && chunk.screen[p + 1].isFinite) {
          minX = math.min(minX, chunk.screen[p]);
          maxX = math.max(maxX, chunk.screen[p]);
          minY = math.min(minY, chunk.screen[p + 1]);
          maxY = math.max(maxY, chunk.screen[p + 1]);
        }
      }
      chunk.updateDepthOrder();
    }
    if (style == CadRenderStyle.shaded &&
        minX.isFinite &&
        minY.isFinite &&
        maxX > minX &&
        maxY > minY) {
      final width = (maxX - minX).clamp(12.0, size.width * .75);
      final height = (maxY - minY).clamp(12.0, size.height * .75);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset((minX + maxX) / 2, maxY + height * .025),
          width: width * .72,
          height: math.max(5, height * .11),
        ),
        Paint()
          ..color = Colors.black.withValues(alpha: .24)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12)
          ..isAntiAlias = true,
      );
    }
    final orderedChunks = cache.chunks.toList(growable: false)
      ..sort((a, b) => b.averageDepth.compareTo(a.averageDepth));
    final chunkVertexOffsets = <_MeshRenderChunk, int>{};
    var vertexOffset = 0;
    for (final chunk in cache.chunks) {
      chunkVertexOffsets[chunk] = vertexOffset;
      vertexOffset += chunk.colors.length;
    }
    for (final chunk in orderedChunks) {
      if (chunk.colorKey != colorKey) {
        for (var i = 0; i < chunk.colors.length; i++) {
          final normalOffset = i * 3;
          var normal = Vector3(
            chunk.normals[normalOffset],
            chunk.normals[normalOffset + 1],
            chunk.normals[normalOffset + 2],
          );
          if (normal.dot(towardEye) < 0) normal = normal * -1;
          final key = math.max(0.0, normal.dot(keyLight));
          final fill = math.max(0.0, normal.dot(fillLight));
          final facing = math.max(0.0, normal.dot(towardEye));
          final t = entity.kind == CadSceneEntityKind.surface
              ? (.62 + .24 * key + .08 * fill + .06 * facing).clamp(.58, 1.0)
              : (.16 + .56 * key + .18 * fill + .07 * facing).clamp(.14, .97);
          final triangleIndex = ((chunkVertexOffsets[chunk] ?? 0) + i) ~/ 3;
          final reconstructionStatus =
              reconstructionStatuses['$triangleIndex'] as String?;
          if (reconstructionStatus != null) {
            final reconstructionColor = switch (reconstructionStatus) {
              'reconstructed' => Colors.green,
              'inProgress' => Colors.amber,
              'pending' => Colors.red,
              'ignored' => Colors.grey,
              _ => foregroundColor,
            };
            chunk.colors[i] = CadTonalSeparation.shade(
              reconstructionColor,
              t,
              alpha: alpha,
            ).toARGB32();
            continue;
          }
          if (analysisModes.isNotEmpty) {
            final x = chunk.xyz[i * 3];
            final y = chunk.xyz[i * 3 + 1];
            final z = chunk.xyz[i * 3 + 2];
            var analysisColor = Color(foreground);
            for (final analysisMode in analysisModes) {
              final effect = switch (analysisMode) {
                'zebra' =>
                  math.sin((x + y + z + camera.eye.x * .03) * .12) > 0
                      ? Colors.white
                      : Colors.black,
                'reflection' => Color.lerp(
                  Colors.indigo.shade900,
                  Colors.white,
                  (math.sin(t * 5 + z * .03) * .5 + .5),
                )!,
                'curvature' => Color.lerp(
                  Colors.blue,
                  Colors.red,
                  t.clamp(0.0, 1.0),
                )!,
                'gaussian' =>
                  t < .48
                      ? Color.lerp(Colors.blue, Colors.white, t / .48)!
                      : Color.lerp(Colors.white, Colors.red, (t - .48) / .52)!,
                'draft' =>
                  t < .35
                      ? Colors.red
                      : t < .58
                      ? Colors.yellow
                      : Colors.green,
                _ => Color(foreground),
              };
              final intensity =
                  (analysisIntensities[analysisMode] as num?)?.toDouble() ??
                  1.0;
              analysisColor = Color.lerp(
                analysisColor,
                effect,
                intensity.clamp(0.0, 1.0),
              )!;
            }
            chunk.colors[i] = analysisColor.withValues(alpha: alpha).toARGB32();
            continue;
          }
          chunk.colors[i] = CadTonalSeparation.shade(
            foregroundColor,
            t,
            alpha: alpha,
          ).toARGB32();
        }
        chunk.colorKey = colorKey;
      }
      final renderedVertices = Vertices.raw(
        VertexMode.triangles,
        chunk.screen,
        colors: chunk.colors,
        indices: chunk.drawIndices,
      );
      canvas.drawVertices(
        renderedVertices,
        BlendMode.srcOver,
        Paint()..color = Colors.white,
      );
      renderedVertices.dispose();
    }
  }

  // Retained for diagnostic tessellation display; production Wireframe uses
  // welded feature edges.
  // ignore: unused_element
  void _paintMeshWireframe(
    Canvas canvas,
    CadSceneEntity entity,
    Size size, {
    double alpha = .9,
  }) {
    final nodes = (entity.geometry['nodes'] as List).cast<num>();
    final triangles = (entity.geometry['triangles'] as List).cast<num>();
    if (nodes.length < 3 || triangles.length < 3) return;
    Offset projectIndex(int index) {
      final projected = camera.viewProjectionMatrix.transformPoint(
        Vector3(
          nodes[index * 3].toDouble(),
          nodes[index * 3 + 1].toDouble(),
          nodes[index * 3 + 2].toDouble(),
        ),
      );
      return Offset(
        (projected.x + 1) * size.width / 2,
        (1 - projected.y) * size.height / 2,
      );
    }

    final paint = Paint()
      ..color =
          (entity.selected ? const Color(0xffffb02e) : const Color(0xff83d8e8))
              .withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = entity.selected ? 1.25 : .72
      ..isAntiAlias = true;
    final path = Path();
    for (var offset = 0; offset + 2 < triangles.length; offset += 3) {
      final a = projectIndex(triangles[offset].toInt());
      final b = projectIndex(triangles[offset + 1].toInt());
      final c = projectIndex(triangles[offset + 2].toInt());
      path
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..lineTo(c.dx, c.dy)
        ..close();
    }
    canvas.drawPath(path, paint);
  }

  void _paintMeshFeatureEdges(
    Canvas canvas,
    CadSceneEntity entity,
    Size size, {
    double alpha = .9,
  }) {
    final nodes = (entity.geometry['nodes'] as List).cast<num>();
    final triangles = (entity.geometry['triangles'] as List).cast<num>();
    if (nodes.length < 3 || triangles.length < 3) return;
    Vector3 vertex(int index) => Vector3(
      nodes[index * 3].toDouble(),
      nodes[index * 3 + 1].toDouble(),
      nodes[index * 3 + 2].toDouble(),
    );
    Offset project(int index) {
      final point = camera.viewProjectionMatrix.transformPoint(vertex(index));
      return Offset(
        (point.x + 1) * size.width / 2,
        (1 - point.y) * size.height / 2,
      );
    }

    String vertexKey(int index) {
      final value = vertex(index);
      // OCC tessellation may duplicate the same geometric vertex for each
      // face. Position-based welding reconstructs CAD adjacency and prevents
      // coplanar triangle diagonals from becoming visible edges.
      String component(double coordinate) =>
          (coordinate * 1000000).round().toString();
      return '${component(value.x)},${component(value.y)},${component(value.z)}';
    }

    final edges = <String, ({int a, int b, List<Vector3> normals})>{};
    void addEdge(int first, int second, Vector3 normal) {
      final firstKey = vertexKey(first);
      final secondKey = vertexKey(second);
      final ordered = firstKey.compareTo(secondKey) <= 0;
      final a = ordered ? first : second;
      final b = ordered ? second : first;
      final key = ordered ? '$firstKey|$secondKey' : '$secondKey|$firstKey';
      final current = edges[key];
      if (current == null) {
        edges[key] = (a: a, b: b, normals: [normal]);
      } else {
        current.normals.add(normal);
      }
    }

    for (var offset = 0; offset + 2 < triangles.length; offset += 3) {
      final a = triangles[offset].toInt();
      final b = triangles[offset + 1].toInt();
      final c = triangles[offset + 2].toInt();
      final normal = (vertex(b) - vertex(a)).cross(vertex(c) - vertex(a));
      if (normal.length <= 1e-12) continue;
      final unit = normal.normalized;
      addEdge(a, b, unit);
      addEdge(b, c, unit);
      addEdge(c, a, unit);
    }

    const creaseCosine = .906307787; // 25 degrees.
    final path = Path();
    for (final edge in edges.values) {
      final boundary = edge.normals.length == 1;
      final crease =
          edge.normals.length > 1 &&
          edge.normals.first.dot(edge.normals[1]).abs() < creaseCosine;
      if (!boundary && !crease) continue;
      final a = project(edge.a);
      final b = project(edge.b);
      if (![a.dx, a.dy, b.dx, b.dy].every((value) => value.isFinite)) {
        continue;
      }
      path
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color =
            (entity.selected
                    ? const Color(0xffffb02e)
                    : const Color(0xff15212b))
                .withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = entity.selected ? 1.7 : 1.15
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
  }

  // Retained for the diagnostic triangle-depth renderer.
  // ignore: unused_element
  void _projectMesh(
    CadSceneEntity entity,
    Size size,
    List<_ProjectedTriangle> output,
  ) {
    final nodes = (entity.geometry['nodes'] as List).cast<num>();
    final indices = (entity.geometry['triangles'] as List).cast<num>();
    final reconstructionStatuses = Map<String, dynamic>.from(
      entity.geometry['reconstructionTriangleStatuses'] as Map? ?? const {},
    );
    Vector3 vertex(int index) => Vector3(
      nodes[index * 3].toDouble(),
      nodes[index * 3 + 1].toDouble(),
      nodes[index * 3 + 2].toDouble(),
    );
    Offset screen(Vector3 point) {
      final p = camera.viewProjectionMatrix.transformPoint(point);
      return Offset((p.x + 1) * size.width / 2, (1 - p.y) * size.height / 2);
    }

    for (var index = 0; index + 2 < indices.length; index += 3) {
      final a = vertex(indices[index].toInt());
      final b = vertex(indices[index + 1].toInt());
      final c = vertex(indices[index + 2].toInt());
      final viewA = camera.viewMatrix.transformPoint(a);
      final viewB = camera.viewMatrix.transformPoint(b);
      final viewC = camera.viewMatrix.transformPoint(c);
      if (viewA.z >= -camera.nearPlane &&
          viewB.z >= -camera.nearPlane &&
          viewC.z >= -camera.nearPlane) {
        continue;
      }
      final normal = (b - a).cross(c - a).normalized;
      final key = normal.dot(const Vector3(.32, -.48, .81).normalized).abs();
      final fill = normal.dot(const Vector3(-.72, .22, .36).normalized).abs();
      final intensity = (.14 + .61 * key + .19 * fill).clamp(.12, .96);
      final pa = screen(a), pb = screen(b), pc = screen(c);
      if (![pa, pb, pc].every((p) => p.dx.isFinite && p.dy.isFinite)) continue;
      output.add(
        _ProjectedTriangle(
          Path()
            ..moveTo(pa.dx, pa.dy)
            ..lineTo(pb.dx, pb.dy)
            ..lineTo(pc.dx, pc.dy)
            ..close(),
          (viewA.z + viewB.z + viewC.z) / 3,
          intensity,
          entity.selected,
          reconstructionStatuses['${index ~/ 3}'] as String?,
        ),
      );
    }
  }

  void _paintReference(Canvas canvas, Size size, CadSceneEntity entity) {
    if (entity.geometry['pickOnlyClosedProfile'] == true) return;
    Vector3 vector(Object? value) {
      final values = value as List;
      return Vector3(
        (values[0] as num).toDouble(),
        (values[1] as num).toDouble(),
        (values[2] as num).toDouble(),
      );
    }

    Offset project(Vector3 value) {
      final point = camera.viewProjectionMatrix.transformPoint(value);
      return Offset(
        (point.x + 1) * size.width / 2,
        (1 - point.y) * size.height / 2,
      );
    }

    void line(Vector3 from, Vector3 to, Color color, {double width = 1.5}) {
      canvas.drawLine(
        project(from),
        project(to),
        Paint()
          ..color = color
          ..strokeWidth = width,
      );
    }

    final scale = (camera.eye - camera.target).length * .16;
    final isWorld = entity.id.contains(':world:');
    final worldScale = _worldReferenceScale();
    final isPlanarSupport =
        entity.kind == CadSceneEntityKind.plane ||
        ((entity.kind == CadSceneEntityKind.surface ||
                entity.kind == CadSceneEntityKind.preview) &&
            entity.geometry['surfaceKind'] == 'plane');
    final highlighted = entity.selected || entity.id == hoveredEntityId;
    final selectableSupport = highlightSketchSupports && isPlanarSupport;
    // World references are permanent workspace context. Their visibility must
    // never depend on which authoring command/tool window is active.
    final persistentWorldSupport = isWorld && isPlanarSupport;
    final constructionEntity =
        entity.geometry['displayColor'] == 'constructionPoint' ||
        entity.geometry['displayColor'] == 'constructionPlane' ||
        entity.geometry['displayColor'] == 'constructionVector';
    final visibleSupport =
        selectableSupport || persistentWorldSupport || constructionEntity;
    final passiveFactor = orbitActive
        ? .28
        : navigationActive
        ? .55
        : 1.0;
    if ((entity.kind == CadSceneEntityKind.surface ||
            entity.kind == CadSceneEntityKind.preview) &&
        entity.geometry['surfaceKind'] == 'plane') {
      final parameters = (entity.geometry['parameters'] as Map)
          .cast<String, dynamic>();
      final origin = vector(parameters['origin']);
      final normal = vector(parameters['normal']).normalized;
      final x = normal
          .cross(
            normal.z.abs() < .9
                ? const Vector3(0, 0, 1)
                : const Vector3(0, 1, 0),
          )
          .normalized;
      final y = normal.cross(x).normalized;
      final halfWidth =
          ((parameters['width'] as num?)?.toDouble() ?? scale) / 2;
      final halfHeight =
          ((parameters['height'] as num?)?.toDouble() ?? scale) / 2;
      final path = Path()
        ..addPolygon(
          [
            origin - x * halfWidth - y * halfHeight,
            origin + x * halfWidth - y * halfHeight,
            origin + x * halfWidth + y * halfHeight,
            origin - x * halfWidth + y * halfHeight,
          ].map(project).toList(),
          true,
        );
      final preview = entity.kind == CadSceneEntityKind.preview;
      final activeColor = highlighted
          ? (entity.selected
                ? const Color(0xffffb02e)
                : const Color(0xff38d6ff))
          : preview
          ? const Color(0xffff9f43)
          : const Color(0xff53a8a6);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..color = activeColor.withValues(
            alpha: preview
                ? .22
                : highlighted
                ? .28
                : selectableSupport
                ? .065
                : .035,
          ),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = highlighted
              ? 1.45
              : preview
              ? 1.25
              : selectableSupport
              ? .65
              : .45
          ..color = activeColor.withValues(
            alpha: highlighted
                ? 1
                : selectableSupport
                ? .52
                : .32,
          ),
      );
      return;
    }
    switch (entity.kind) {
      case CadSceneEntityKind.point:
        canvas.drawCircle(
          project(vector(entity.geometry['position'])),
          entity.selected
              ? 7
              : (entity.geometry['markerRadius'] as num?)?.toDouble() ?? 5,
          Paint()
            ..color = entity.geometry['displayColor'] == 'endpointSnap'
                ? const Color(0xff62d98b)
                : colors.tertiary,
        );
      case CadSceneEntityKind.axis:
        final origin = vector(entity.geometry['origin']);
        final direction = vector(entity.geometry['direction']).normalized;
        final length = isWorld
            ? worldScale
            : (entity.geometry['visualLength'] as num?)?.toDouble() ??
                  scale * 2;
        final axisColor = switch (entity.geometry['axisColor']) {
          'x' => Colors.red,
          'y' => Colors.green,
          'z' => Colors.blue,
          _ =>
            entity.geometry['displayColor'] == 'constructionVector'
                ? const Color(0xfff0c85a)
                : colors.secondary,
        };
        final start = isWorld ? origin : origin - direction * (length / 2);
        final end = isWorld
            ? origin + direction * length
            : origin + direction * (length / 2);
        line(
          start,
          end,
          highlighted
              ? colors.tertiary
              : axisColor.withValues(
                  alpha: isWorld || constructionEntity
                      ? .88
                      : .46 * passiveFactor,
                ),
          width: highlighted
              ? 1.55
              : isWorld
              ? .82
              : constructionEntity
              ? 1.65
              : .68,
        );
        if (isWorld) {
          final label = switch (entity.geometry['axisColor']) {
            'x' => 'X',
            'y' => 'Y',
            'z' => 'Z',
            _ => '',
          };
          if (label.isNotEmpty) {
            final text = TextPainter(
              text: TextSpan(
                text: label,
                style: TextStyle(
                  color: highlighted
                      ? colors.tertiary
                      : axisColor.withValues(
                          alpha: isWorld ? .68 : .55 * passiveFactor,
                        ),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout();
            text.paint(canvas, project(end) - const Offset(4, 7));
          }
        }
      case CadSceneEntityKind.plane:
        final origin = vector(entity.geometry['origin']);
        final normal = vector(entity.geometry['normal']).normalized;
        final preferred = entity.geometry['xDirection'];
        final x = preferred is List
            ? vector(preferred).normalized
            : normal
                  .cross(
                    normal.z.abs() < .9
                        ? const Vector3(0, 0, 1)
                        : const Vector3(0, 1, 0),
                  )
                  .normalized;
        final y = normal.cross(x).normalized;
        final extent = isWorld
            ? worldScale * .58
            : ((entity.geometry['visualSize'] as num?)?.toDouble() ??
                      scale * 1.4) /
                  2;
        final planeColor = switch (entity.geometry['planeColor']) {
          'xy' => Colors.blue,
          'xz' => Colors.green,
          'yz' => Colors.red,
          _ =>
            entity.geometry['displayColor'] == 'constructionPlane'
                ? const Color(0xff68c7ef)
                : colors.secondary,
        };
        final corners = [
          origin - x * extent - y * extent,
          origin + x * extent - y * extent,
          origin + x * extent + y * extent,
          origin - x * extent + y * extent,
        ].map(project).toList();
        final path = Path()..addPolygon(corners, true);
        canvas.drawPath(
          path,
          Paint()
            ..color = planeColor.withValues(
              alpha: highlighted
                  ? .10
                  : visibleSupport
                  ? .034
                  : .012 * passiveFactor,
            )
            ..style = PaintingStyle.fill,
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = (highlighted ? colors.tertiary : planeColor).withValues(
              alpha: highlighted
                  ? .92
                  : visibleSupport
                  ? .42
                  : .14 * passiveFactor,
            )
            ..strokeWidth = highlighted
                ? 1.45
                : visibleSupport
                ? .62
                : .38
            ..style = PaintingStyle.stroke
            ..isAntiAlias = true,
        );
      case CadSceneEntityKind.coordinateSystem:
        if (isWorld) break;
        final origin = vector(entity.geometry['origin']);
        line(
          origin,
          origin + vector(entity.geometry['xAxis']).normalized * scale,
          Colors.red,
        );
        line(
          origin,
          origin + vector(entity.geometry['yAxis']).normalized * scale,
          Colors.green,
        );
        line(
          origin,
          origin + vector(entity.geometry['zAxis']).normalized * scale,
          Colors.blue,
        );
      case CadSceneEntityKind.curve:
      case CadSceneEntityKind.sketch:
      case CadSceneEntityKind.preview:
        final rawSegments = entity.geometry['segments'];
        if (rawSegments is List) {
          final alignmentGuide =
              entity.geometry['displayColor'] == 'alignmentGuide';
          final referenceCurve =
              entity.geometry['displayColor'] == 'referenceCurve';
          final referenceCurveHighlight =
              entity.geometry['displayColor'] == 'referenceCurveHighlight';
          final assistantSuggestion =
              entity.geometry['displayColor'] == 'assistantSuggestion';
          final referenceColor = entity.selected
              ? const Color(0xffffb02e)
              : highlighted
              ? const Color(0xff38d6ff)
              : alignmentGuide
              ? const Color(0x9965c7ff)
              : referenceCurveHighlight
              ? const Color(0xffffc857)
              : referenceCurve
              ? const Color(0xffb56cff)
              : assistantSuggestion
              ? const Color(0xff4de1d2)
              : entity.kind == CadSceneEntityKind.preview
              ? const Color(0xffff9f43)
              : entity.kind == CadSceneEntityKind.sketch
              ? const Color(0xff7cda72)
              : const Color(0xff55b8df);
          final paint = Paint()
            ..color = referenceColor
            ..strokeWidth = entity.selected
                ? 2.1
                : (entity.geometry['strokeWidth'] as num?)?.toDouble() ?? 1.35
            ..strokeCap = StrokeCap.round
            ..isAntiAlias = true;
          for (final raw in rawSegments) {
            final segment = raw as List;
            final from = project(vector(segment[0]));
            final to = project(vector(segment[1]));
            if (entity.geometry['dashed'] == true) {
              final delta = to - from;
              final length = delta.distance;
              if (length <= 1e-9) continue;
              final direction = delta / length;
              const dash = 5.0, gap = 4.0;
              for (var offset = 0.0; offset < length; offset += dash + gap) {
                canvas.drawLine(
                  from + direction * offset,
                  from + direction * math.min(offset + dash, length),
                  paint,
                );
              }
            } else {
              canvas.drawLine(from, to, paint);
            }
          }
          break;
        }
        final points = (entity.geometry['points'] as List? ?? const [])
            .map(vector)
            .map(project)
            .toList();
        if (points.length > 1) {
          final displayColor = switch (entity.geometry['displayColor']) {
            'destructiveRed' => Colors.redAccent,
            'splineMagenta' => const Color(0xffd489ff),
            'sketchGreen' => const Color(0xff7cda72),
            'previewOrange' => const Color(0xffff9f43),
            'assistantSuggestion' => const Color(0xff4de1d2),
            'sectionBlue' => const Color(0xff4cb9e8),
            'drivingDimension' => const Color(0xff65c7ff),
            _ => const Color(0xff55b8df),
          };
          canvas.drawPoints(
            PointMode.polygon,
            points,
            Paint()
              ..color = entity.selected
                  ? const Color(0xffffb02e)
                  : highlighted
                  ? const Color(0xff38d6ff)
                  : displayColor
              ..strokeWidth =
                  (entity.geometry['strokeWidth'] as num?)?.toDouble() ?? 2
              ..strokeCap = StrokeCap.round
              ..isAntiAlias = true,
          );
          if (entity.kind == CadSceneEntityKind.sketch &&
              entity.geometry['showEndpoints'] == true) {
            final endpointPaint = Paint()
              ..color = highlighted
                  ? const Color(0xff38d6ff)
                  : const Color(0xff62d98b)
              ..style = PaintingStyle.fill
              ..isAntiAlias = true;
            final outlinePaint = Paint()
              ..color = colors.surface
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2
              ..isAntiAlias = true;
            for (final endpoint in {points.first, points.last}) {
              canvas.drawCircle(
                endpoint,
                highlighted ? 4.8 : 4.0,
                endpointPaint,
              );
              canvas.drawCircle(
                endpoint,
                highlighted ? 4.8 : 4.0,
                outlinePaint,
              );
            }
          }
        }
        final dimensionLabel = entity.geometry['dimensionLabel'] as String?;
        final labelPosition = entity.geometry['labelPosition'];
        if (dimensionLabel != null && labelPosition is List) {
          final rawOffset = entity.geometry['labelScreenOffset'];
          final screenOffset = rawOffset is List && rawOffset.length >= 2
              ? Offset(
                  (rawOffset[0] as num).toDouble(),
                  (rawOffset[1] as num).toDouble(),
                )
              : Offset.zero;
          final position = project(vector(labelPosition)) + screenOffset;
          final floatingHud = entity.geometry['floatingHud'] == true;
          final text = TextPainter(
            text: TextSpan(
              text: dimensionLabel,
              style: TextStyle(
                color: floatingHud
                    ? const Color(0xffdff7ff)
                    : entity.selected
                    ? const Color(0xffffb02e)
                    : const Color(0xff65c7ff),
                fontSize: floatingHud ? 10.5 : 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          final textOrigin = position - Offset(text.width / 2, text.height / 2);
          if (floatingHud) {
            final box = RRect.fromRectAndRadius(
              Rect.fromLTWH(
                textOrigin.dx - 7,
                textOrigin.dy - 4,
                text.width + 14,
                text.height + 8,
              ),
              const Radius.circular(5),
            );
            canvas.drawRRect(box, Paint()..color = const Color(0xe61a252d));
            canvas.drawRRect(
              box,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1
                ..color = const Color(0xaa65c7ff),
            );
          }
          text.paint(canvas, textOrigin);
        }
      case CadSceneEntityKind.mesh:
      case CadSceneEntityKind.surface:
      case CadSceneEntityKind.solid:
      case CadSceneEntityKind.gizmo:
        break;
    }
  }

  double _worldReferenceScale() {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (final entity in scene.entities.where(
      (item) => item.visible && !item.id.contains(':world:'),
    )) {
      final nodes = entity.geometry['nodes'];
      if (nodes is! List) continue;
      for (var i = 0; i + 2 < nodes.length; i += 3) {
        final x = (nodes[i] as num).toDouble();
        final y = (nodes[i + 1] as num).toDouble();
        final z = (nodes[i + 2] as num).toDouble();
        minX = math.min(minX, x);
        minY = math.min(minY, y);
        minZ = math.min(minZ, z);
        maxX = math.max(maxX, x);
        maxY = math.max(maxY, y);
        maxZ = math.max(maxZ, z);
      }
    }
    if (minX.isFinite && maxX.isFinite) {
      final diagonal = Vector3(maxX - minX, maxY - minY, maxZ - minZ).length;
      if (diagonal > 1e-9) return diagonal * .12;
    }
    // With no model bounds, world planes are the only available Sketch
    // supports. Keep them large enough to remain visible and selectable.
    return math.max((camera.eye - camera.target).length * .32, 1.0);
  }

  @override
  bool shouldRepaint(covariant _CadScenePainter oldDelegate) =>
      oldDelegate.style != style ||
      oldDelegate.colors != colors ||
      oldDelegate.showGrid != showGrid ||
      oldDelegate.highlightSketchSupports != highlightSketchSupports ||
      oldDelegate.navigationActive != navigationActive ||
      oldDelegate.orbitActive != orbitActive ||
      oldDelegate.hoveredEntityId != hoveredEntityId ||
      oldDelegate.rotationCenterMarker != rotationCenterMarker;
}
