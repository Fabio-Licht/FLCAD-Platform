import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/sketch_editor/models/editor_models.dart';
import '../../../core/sketch_editor/snapping/editor_snapping.dart';
import '../../../core/sketch_constraints/models/constraint_models.dart';
import '../../../core/professional_surface/models/professional_surface_models.dart';
import '../../../core/professional_continuity/professional_continuity.dart';
import '../../../core/professional_blend/professional_blend.dart';
import '../../../core/professional_fill/professional_fill.dart';
import '../../../core/professional_surface_fillet/professional_surface_fillet.dart';
import '../../../core/professional_sew/professional_sew.dart';

import '../operational_reverse_engineering_controller.dart';

class SketchSurfaceWorkspacePanel extends StatefulWidget {
  const SketchSurfaceWorkspacePanel({
    super.key,
    required this.controller,
    this.initialSurfaceTool,
    this.onOpenSketch,
    this.onFinishSketch,
  });
  final OperationalReverseEngineeringController controller;
  final ProfessionalSurfaceTool? initialSurfaceTool;
  final Future<void> Function()? onOpenSketch;
  final Future<void> Function()? onFinishSketch;

  @override
  State<SketchSurfaceWorkspacePanel> createState() =>
      _SketchSurfaceWorkspacePanelState();
}

class _SketchSurfaceWorkspacePanelState
    extends State<SketchSurfaceWorkspacePanel> {
  bool showSnapManager = false;
  bool showConstraintGlyphs = true;
  bool snapMesh = false;
  bool snapSection = true;
  bool snapSketch = true;
  bool snapReferences = true;
  bool snapGrid = true;
  double categoryBValue = 1;
  SurfaceContinuity categoryBContinuity = SurfaceContinuity.g1;
  SurfaceOffsetMode offsetMode = SurfaceOffsetMode.walls;
  SurfaceOffsetDirection offsetDirection = SurfaceOffsetDirection.outside;
  final Set<String> wallBoundaryIds = {};
  ProfessionalSurfaceTool? guidedSurfaceTool;
  BlendContinuity firstBlendContinuity = BlendContinuity.g0;
  BlendContinuity secondBlendContinuity = BlendContinuity.g0;
  double firstBlendInfluence = 1;
  double secondBlendInfluence = 1;
  final Map<String, FillBoundaryContinuity> fillContinuities = {};
  final Map<String, double> fillInfluences = {};
  final Map<String, String> fillLoopIds = {};
  SurfaceFilletSelectionMode filletSelectionMode =
      SurfaceFilletSelectionMode.edge;
  SurfaceFilletSizeMode filletSizeMode = SurfaceFilletSizeMode.constantRadius;
  SurfaceFilletContinuity filletContinuity = SurfaceFilletContinuity.g1;
  double filletRadius = 5, filletWidth = 5, filletGap = 0;
  bool filletTrim = true, filletExtend = false, filletCompensate = false;
  final List<SurfaceFilletRadiusPoint> filletRadiusPoints = [
    const SurfaceFilletRadiusPoint(0, 5),
    const SurfaceFilletRadiusPoint(1, 5),
  ];
  final Set<ProfessionalAnalysisKind> filletPreviewAnalyses = {};
  SewSelectionMode sewSelectionMode = SewSelectionMode.individual;
  double sewTolerance = .05;
  bool sewCompensate = false;

  OperationalReverseEngineeringController get controller => widget.controller;
  bool get _dedicatedSurfaceCommand => widget.initialSurfaceTool != null;

  @override
  void initState() {
    super.initState();
    guidedSurfaceTool = widget.initialSurfaceTool;
  }

  void _openGuidedSurfaceCommand(ProfessionalSurfaceTool tool) {
    setState(() {
      guidedSurfaceTool = tool;
      if (tool == ProfessionalSurfaceTool.fillet) {
        final recognized = controller.selectedRecognitionFilletRadius;
        if (recognized != null && recognized > 0) {
          filletRadius = recognized;
          filletWidth = recognized;
          filletRadiusPoints
            ..clear()
            ..addAll([
              SurfaceFilletRadiusPoint(0, recognized),
              SurfaceFilletRadiusPoint(1, recognized),
            ]);
        }
      }
    });
  }

  bool get _guidedSelectionReady => switch (guidedSurfaceTool) {
    ProfessionalSurfaceTool.offset =>
      controller.canPreviewSelectedSurfaceOffset,
    ProfessionalSurfaceTool.fill => controller.canPreviewFill,
    ProfessionalSurfaceTool.fillet => controller.canPreviewSurfaceFillet(
      filletSelectionMode,
    ),
    ProfessionalSurfaceTool.sew => controller.canPreviewSew,
    final tool? => controller.canPreviewProfessional(tool),
    null => false,
  };

  String get _guidedSelectionInstruction => switch (guidedSurfaceTool) {
    ProfessionalSurfaceTool.loft =>
      'Select two compatible Sketches, Reference Curves or Edges.',
    ProfessionalSurfaceTool.sweep =>
      'Select the Profile first and then the compatible Path.',
    ProfessionalSurfaceTool.blend =>
      'Select two Surfaces. Compatible boundary Edges are optional.',
    ProfessionalSurfaceTool.offset => 'Select one Surface to offset.',
    ProfessionalSurfaceTool.fill =>
      'Select every Edge of the outer loop and any inner loops. There is no four-edge limit.',
    ProfessionalSurfaceTool.patch =>
      'Select the boundary Curves or Edges that define the Patch.',
    ProfessionalSurfaceTool.fillet =>
      'Select support Surface(s), then Edge, Loop, Face or Tangent Chain.',
    ProfessionalSurfaceTool.sew =>
      'Select two or more Surfaces. The originals remain independent.',
    _ => '',
  };

  Future<void> _previewGuidedSurfaceCommand() async {
    switch (guidedSurfaceTool) {
      case ProfessionalSurfaceTool.loft:
        await controller.previewProfessionalLoft();
      case ProfessionalSurfaceTool.sweep:
        await controller.previewProfessionalSweep();
      case ProfessionalSurfaceTool.blend:
        await controller.previewProfessionalBlend(
          firstContinuity: firstBlendContinuity,
          secondContinuity: secondBlendContinuity,
          firstInfluence: firstBlendInfluence,
          secondInfluence: secondBlendInfluence,
        );
      case ProfessionalSurfaceTool.offset:
        await controller.previewSelectedSurfaceOffset(categoryBValue);
      case ProfessionalSurfaceTool.fill:
        await controller.previewProfessionalFill();
      case ProfessionalSurfaceTool.fillet:
        await controller.previewProfessionalSurfaceFillet(
          ProfessionalSurfaceFilletContract(
            sourceEntityIds: controller.selectedSurfaceFilletSourceIds,
            edgeEntityIds: controller.selectedSurfaceFilletEdgeIds,
            selectionMode: filletSelectionMode,
            sizeMode: filletSizeMode,
            radius: filletRadius,
            width: filletWidth,
            radiusPoints: filletRadiusPoints,
            trim: filletTrim,
            extend: filletExtend,
            compensate: filletCompensate,
            compensationGap: filletGap,
            continuity: filletContinuity,
          ),
        );
      case ProfessionalSurfaceTool.sew:
        await controller.previewProfessionalSew(
          tolerance: sewTolerance,
          compensate: sewCompensate,
          selectionMode: sewSelectionMode,
        );
      case _:
        final tool = guidedSurfaceTool;
        if (tool != null) await controller.previewProfessionalSurface(tool);
    }
  }

  Future<void> _updateBlendSideConditions() async {
    final preview = controller.professionalSurfacePreview;
    if (preview?.definition.tool != ProfessionalSurfaceTool.blend) return;
    final raw =
        (preview!.definition.parameters['participants'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);
    if (raw.length != 2) return;
    raw[0]['continuity'] = firstBlendContinuity.name;
    raw[0]['influence'] = firstBlendInfluence;
    raw[1]['continuity'] = secondBlendContinuity.name;
    raw[1]['influence'] = secondBlendInfluence;
    await controller.updateProfessionalSurfacePreview(
      parameters: {
        'participants': raw,
        'sideContinuities': [
          firstBlendContinuity.name,
          secondBlendContinuity.name,
        ],
        'sideInfluences': [firstBlendInfluence, secondBlendInfluence],
      },
      continuity:
          firstBlendContinuity == BlendContinuity.g1 ||
              secondBlendContinuity == BlendContinuity.g1
          ? SurfaceContinuity.g1
          : SurfaceContinuity.g0,
    );
  }

  Future<void> _updateFillBoundaryConditions() async {
    final preview = controller.professionalSurfacePreview;
    if (preview?.definition.tool != ProfessionalSurfaceTool.fill) return;
    final raw =
        (preview!.definition.parameters['boundaryConditions'] as List? ??
                const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);
    for (final condition in raw) {
      final id = condition['boundaryEntityId'] as String;
      condition['continuity'] =
          (fillContinuities[id] ?? FillBoundaryContinuity.g0).name;
      condition['influence'] = fillInfluences[id] ?? 1;
      condition['loopId'] = fillLoopIds[id] ?? condition['loopId'] ?? 'outer';
    }
    await controller.updateProfessionalSurfacePreview(
      parameters: {
        'boundaryConditions': raw,
        'boundaryContinuities': raw.map((item) => item['continuity']).toList(),
        'boundaryInfluences': raw.map((item) => item['influence']).toList(),
      },
    );
  }

  Future<void> _cancelGuidedSurfaceCommand() async {
    if (controller.professionalSurfacePreview != null) {
      controller.cancelProfessionalSurface();
    } else if (controller.surfaceOffsetPreviewActive) {
      controller.cancelSurfaceOffset();
    }
    if (mounted && !_dedicatedSurfaceCommand) {
      setState(() => guidedSurfaceTool = null);
    }
  }

  void _toggleSnap(EditorSnapType type, bool enabled) {
    final settings = controller.editorApi?.engine.snapping.settings;
    if (settings == null) return;
    setState(() {
      enabled ? settings.enabled.add(type) : settings.enabled.remove(type);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Stage: ${controller.stage.name}'),
        const SizedBox(height: 8),
        if (controller.error != null)
          Text(
            controller.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (!_dedicatedSurfaceCommand) ...[
          if (controller.stage == SketchSurfaceStage.idle) ...[
            const Text(
              'Create a Sketch on a world plane or on selected planar geometry.',
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: controller.busy
                  ? null
                  : (widget.onOpenSketch ?? controller.openSketch),
              icon: const Icon(Icons.edit_note),
              label: const Text('New Sketch'),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: controller.busy
                  ? null
                  : controller.createRecognizedPlane,
              icon: const Icon(Icons.layers_outlined),
              label: const Text('Create recognized plane'),
            ),
          ],
          if (controller.stage == SketchSurfaceStage.referenceReady) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  onPressed: controller.busy ? null : controller.createAxis,
                  icon: const Icon(Icons.straighten),
                  label: const Text('Create Axis'),
                ),
                OutlinedButton.icon(
                  onPressed: controller.busy ? null : controller.createPoint,
                  icon: const Icon(Icons.adjust),
                  label: const Text('Create Point'),
                ),
                OutlinedButton.icon(
                  onPressed: controller.busy
                      ? null
                      : controller.createCoordinateSystem,
                  icon: const Icon(Icons.threed_rotation),
                  label: const Text('Create Coordinate System'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: controller.busy
                  ? null
                  : (widget.onOpenSketch ?? controller.openSketch),
              icon: const Icon(Icons.edit_note),
              label: const Text('New Sketch'),
            ),
          ],
          if (controller.stage == SketchSurfaceStage.sketchActive) ...[
            _ProfessionalSketchToolbar(
              controller: controller,
              onSnapManager: () =>
                  setState(() => showSnapManager = !showSnapManager),
            ),
            if (showSnapManager)
              _SnapManager(
                controller: controller,
                mesh: snapMesh,
                section: snapSection,
                sketch: snapSketch,
                references: snapReferences,
                grid: snapGrid,
                onMesh: (value) => setState(() => snapMesh = value),
                onSection: (value) => setState(() => snapSection = value),
                onSketch: (value) => setState(() => snapSketch = value),
                onReferences: (value) => setState(() => snapReferences = value),
                onGrid: (value) {
                  setState(() => snapGrid = value);
                  _toggleSnap(EditorSnapType.grid, value);
                },
                onCoreSnap: _toggleSnap,
              ),
            _SketchHeadsUpDisplay(controller: controller),
            _ConstraintStateBanner(controller: controller),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Constraint glyphs'),
              subtitle: const Text(
                'Tangent · Parallel · Coincident · Equal · H/V',
              ),
              value: showConstraintGlyphs,
              onChanged: (value) =>
                  setState(() => showConstraintGlyphs = value),
            ),
            if (showConstraintGlyphs)
              _ConstraintGlyphSummary(controller: controller),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: controller.sketchEntities.length < 4 || controller.busy
                  ? null
                  : controller.constrainRectangle,
              icon: const Icon(Icons.square_foot),
              label: Text(
                'Apply rectangle constraints (${controller.constraints.length})',
              ),
            ),
            Text(
              '${controller.selectedSketchEntityIds.length} Sketch entities selected',
            ),
            Wrap(
              spacing: 4,
              children: [
                for (final type in const [
                  SketchConstraintType.coincident,
                  SketchConstraintType.parallel,
                  SketchConstraintType.perpendicular,
                  SketchConstraintType.tangent,
                  SketchConstraintType.horizontal,
                  SketchConstraintType.vertical,
                  SketchConstraintType.equal,
                  SketchConstraintType.radius,
                  SketchConstraintType.diameter,
                  SketchConstraintType.distance,
                  SketchConstraintType.angle,
                ])
                  ActionChip(
                    label: Text(type.name),
                    onPressed: controller.selectedSketchEntityIds.isEmpty
                        ? null
                        : () => controller.applyConstraint(
                            type,
                            value: switch (type) {
                              SketchConstraintType.radius ||
                              SketchConstraintType.diameter ||
                              SketchConstraintType.distance => 10,
                              SketchConstraintType.angle => 1.5707963267948966,
                              _ => null,
                            },
                          ),
                  ),
              ],
            ),
            FilledButton.icon(
              onPressed: controller.sketchEntities.isEmpty || controller.busy
                  ? null
                  : (widget.onFinishSketch ?? controller.finishSketch),
              icon: const Icon(Icons.done),
              label: const Text('Finish Sketch'),
            ),
          ],
          if (controller.stage == SketchSurfaceStage.sketchFinished) ...[
            FilledButton.icon(
              onPressed: controller.busy || !controller.sketchReadyForSurface
                  ? null
                  : controller.previewPlanarSurface,
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Preview Surface'),
            ),
            if (!controller.sketchReadyForSurface)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  controller.sketchSurfaceBlockReason,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
          if (controller.stage == SketchSurfaceStage.surfacePreview) ...[
            const ListTile(
              dense: true,
              leading: Icon(
                Icons.layers_outlined,
                color: Colors.lightBlueAccent,
              ),
              title: Text('Dynamic Surface Preview'),
              subtitle: Text(
                'Temporary translucent film. Editing the Sketch updates it immediately.',
              ),
            ),
          ],
          if (controller.stage == SketchSurfaceStage.surfaceGenerated)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.check_circle),
              title: Text('CAD Surface generated'),
              subtitle: Text('Registered, persisted and visible in the scene.'),
            ),
          ...[
            const Divider(),
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.waves_outlined),
              title: Text('Surface Continuity'),
              subtitle: Text('Build → measure → approve'),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                OutlinedButton(
                  onPressed:
                      controller.busy || !controller.canInspectSurfaceContinuity
                      ? null
                      : controller.inspectSelectedG0,
                  child: const Text('Inspect G0'),
                ),
                OutlinedButton(
                  onPressed:
                      controller.busy ||
                          !controller.canInspectSurfaceContinuity ||
                          controller.continuityPreview != null
                      ? null
                      : controller.previewSelectedG1,
                  child: const Text('Preview G1'),
                ),
              ],
            ),
            if (!controller.canInspectSurfaceContinuity)
              const Text(
                'Select exactly two Surfaces to inspect G0 or preview G1.',
                style: TextStyle(fontSize: 11),
              ),
            if (controller.continuityPreview != null)
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: controller.busy
                          ? null
                          : controller.confirmSelectedG1,
                      child: const Text('Confirm G1'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: controller.busy
                          ? null
                          : controller.cancelSelectedG1,
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            if (controller.selectedSurfaceForQuality != null) ...[
              const SizedBox(height: 8),
              const Text(
                'Independent analysis',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final kind in ProfessionalAnalysisKind.values)
                Builder(
                  builder: (context) {
                    final setting = controller.selectedSurfaceAnalysisSettings
                        .where((item) => item.kind == kind)
                        .firstOrNull;
                    final enabled = setting?.enabled ?? false;
                    final intensity = setting?.intensity ?? 0.7;
                    return Column(
                      children: [
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(switch (kind) {
                            ProfessionalAnalysisKind.zebra => 'Zebra',
                            ProfessionalAnalysisKind.reflection => 'Reflection',
                            ProfessionalAnalysisKind.curvature => 'Curvature',
                          }),
                          value: enabled,
                          onChanged: controller.busy
                              ? null
                              : (value) => controller.setSurfaceQualityAnalysis(
                                  kind,
                                  enabled: value ?? false,
                                  intensity: intensity,
                                ),
                        ),
                        if (enabled)
                          Slider(
                            value: intensity,
                            min: 0,
                            max: 1,
                            divisions: 20,
                            label: intensity.toStringAsFixed(2),
                            onChanged: controller.busy
                                ? null
                                : (value) =>
                                      controller.setSurfaceQualityAnalysis(
                                        kind,
                                        enabled: true,
                                        intensity: value,
                                      ),
                          ),
                      ],
                    );
                  },
                ),
            ] else ...[
              const SizedBox(height: 8),
              const Text(
                'Independent analysis',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: const [
                  OutlinedButton(onPressed: null, child: Text('Zebra')),
                  OutlinedButton(onPressed: null, child: Text('Reflection')),
                  OutlinedButton(onPressed: null, child: Text('Curvature')),
                ],
              ),
              const Text(
                'Select one Surface to enable the quality analyses.',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ],
        ],
        ...[
          const Divider(),
          if (!_dedicatedSurfaceCommand) ...[
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.auto_awesome_motion),
              title: Text('Professional Surface'),
              subtitle: Text('Loft · Sweep · Blend · Offset'),
            ),
            Text(
              '${controller.geometrySelection.shapeHandles.length} kernel shape(s) · ${controller.activeSketch == null ? 0 : 1} active Sketch',
            ),
            const Text('Create', style: TextStyle(fontWeight: FontWeight.w600)),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tool in const [
                  ProfessionalSurfaceTool.loft,
                  ProfessionalSurfaceTool.sweep,
                  ProfessionalSurfaceTool.fill,
                  ProfessionalSurfaceTool.patch,
                  ProfessionalSurfaceTool.blend,
                  ProfessionalSurfaceTool.fillet,
                  ProfessionalSurfaceTool.sew,
                ])
                  OutlinedButton.icon(
                    icon: Icon(switch (tool) {
                      ProfessionalSurfaceTool.loft => Icons.view_in_ar,
                      ProfessionalSurfaceTool.sweep => Icons.route,
                      ProfessionalSurfaceTool.fill => Icons.format_color_fill,
                      ProfessionalSurfaceTool.patch => Icons.grid_4x4,
                      ProfessionalSurfaceTool.blend => Icons.rounded_corner,
                      ProfessionalSurfaceTool.fillet => Icons.blur_circular,
                      ProfessionalSurfaceTool.sew => Icons.hub_outlined,
                      _ => Icons.layers,
                    }),
                    onPressed: controller.busy
                        ? null
                        : () {
                            if (tool == ProfessionalSurfaceTool.loft ||
                                tool == ProfessionalSurfaceTool.sweep ||
                                tool == ProfessionalSurfaceTool.blend ||
                                tool == ProfessionalSurfaceTool.fill ||
                                tool == ProfessionalSurfaceTool.fillet ||
                                tool == ProfessionalSurfaceTool.sew) {
                              _openGuidedSurfaceCommand(tool);
                              return;
                            }
                            controller.previewProfessionalSurface(tool);
                          },
                    label: Text(
                      tool.name[0].toUpperCase() + tool.name.substring(1),
                    ),
                  ),
              ],
            ),
          ] else
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.auto_awesome_motion),
              title: Text(
                '${(guidedSurfaceTool ?? widget.initialSurfaceTool)!.name[0].toUpperCase()}${(guidedSurfaceTool ?? widget.initialSurfaceTool)!.name.substring(1)} Surface',
              ),
              subtitle: const Text('Dedicated command editor'),
            ),
          const SizedBox(height: 8),
          if (guidedSurfaceTool == ProfessionalSurfaceTool.sew &&
              controller.selectedSewBody != null) ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.call_split),
                    label: const Text('Unsew selected'),
                    onPressed: controller.busy
                        ? null
                        : () async {
                            final body = controller.selectedSewBody!;
                            final selected = controller.runtime.selection
                                .where((id) => id != body.id)
                                .toSet();
                            await controller.unsewBody(
                              body.id,
                              surfaceIds: selected.isEmpty ? null : selected,
                            );
                          },
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.link_off),
                    label: const Text('Unsew all'),
                    onPressed: controller.busy
                        ? null
                        : () => controller.unsewBody(
                            controller.selectedSewBody!.id,
                          ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (!_dedicatedSurfaceCommand ||
              guidedSurfaceTool == ProfessionalSurfaceTool.offset) ...[
            const Text(
              'Surface Operations',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            TextFormField(
              initialValue: categoryBValue.toStringAsFixed(2),
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Offset distance',
                suffixText: 'mm',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              onChanged: (value) {
                final parsed = double.tryParse(value.replaceAll(',', '.'));
                if (parsed != null) setState(() => categoryBValue = parsed);
              },
            ),
          ],
          const SizedBox(height: 6),
          if (!_dedicatedSurfaceCommand)
            OutlinedButton.icon(
              onPressed: controller.busy
                  ? null
                  : () => _openGuidedSurfaceCommand(
                      ProfessionalSurfaceTool.offset,
                    ),
              icon: const Icon(Icons.layers_outlined),
              label: const Text('Offset'),
            ),
          if (guidedSurfaceTool != null &&
              controller.professionalSurfacePreview == null &&
              !controller.surfaceOffsetPreviewActive)
            Card(
              margin: const EdgeInsets.only(top: 8),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${guidedSurfaceTool!.name[0].toUpperCase()}${guidedSurfaceTool!.name.substring(1)} active',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(_guidedSelectionInstruction),
                    if (guidedSurfaceTool == ProfessionalSurfaceTool.sew) ...[
                      DropdownButtonFormField<SewSelectionMode>(
                        initialValue: sewSelectionMode,
                        decoration: const InputDecoration(
                          labelText: 'Selection mode',
                        ),
                        items: SewSelectionMode.values
                            .map(
                              (item) => DropdownMenuItem(
                                value: item,
                                child: Text(item.name),
                              ),
                            )
                            .toList(),
                        onChanged: controller.busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => sewSelectionMode = value);
                                }
                              },
                      ),
                      TextFormField(
                        initialValue: sewTolerance.toStringAsFixed(3),
                        decoration: const InputDecoration(
                          labelText: 'Sew tolerance',
                          suffixText: 'mm',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (value) {
                          final parsed = double.tryParse(
                            value.replaceAll(',', '.'),
                          );
                          if (parsed != null && parsed > 0) {
                            sewTolerance = parsed;
                          }
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: sewCompensate,
                        title: const Text('Authorize gap compensation'),
                        subtitle: const Text(
                          'Never compensates without explicit authorization.',
                        ),
                        onChanged: controller.busy
                            ? null
                            : (value) => setState(() => sewCompensate = value),
                      ),
                      Builder(
                        builder: (context) {
                          final gap = controller.analyzeSelectedSewGaps();
                          return Text(
                            'Gap min ${gap.minimum.toStringAsFixed(3)} · '
                            'avg ${gap.average.toStringAsFixed(3)} · '
                            'max ${gap.maximum.toStringAsFixed(3)} mm\n'
                            '${gap.within(sewTolerance) ? 'Within tolerance' : 'Outside tolerance'} · '
                            '${gap.coincidentEdges} coincident edge(s) · '
                            '${gap.incompatibleRegions} incompatible region(s)',
                            style: const TextStyle(fontSize: 11),
                          );
                        },
                      ),
                    ],
                    if (guidedSurfaceTool ==
                        ProfessionalSurfaceTool.fillet) ...[
                      DropdownButtonFormField<SurfaceFilletSelectionMode>(
                        initialValue: filletSelectionMode,
                        decoration: const InputDecoration(
                          labelText: 'Selection mode',
                        ),
                        items: SurfaceFilletSelectionMode.values
                            .map(
                              (item) => DropdownMenuItem(
                                value: item,
                                child: Text(item.name),
                              ),
                            )
                            .toList(),
                        onChanged: controller.busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => filletSelectionMode = value);
                                }
                              },
                      ),
                      DropdownButtonFormField<SurfaceFilletSizeMode>(
                        initialValue: filletSizeMode,
                        decoration: const InputDecoration(
                          labelText: 'Size mode',
                        ),
                        items: SurfaceFilletSizeMode.values
                            .map(
                              (item) => DropdownMenuItem(
                                value: item,
                                child: Text(item.name),
                              ),
                            )
                            .toList(),
                        onChanged: controller.busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => filletSizeMode = value);
                                }
                              },
                      ),
                      TextFormField(
                        initialValue:
                            (filletSizeMode ==
                                        SurfaceFilletSizeMode.constantWidth
                                    ? filletWidth
                                    : filletRadius)
                                .toString(),
                        decoration: InputDecoration(
                          labelText:
                              filletSizeMode ==
                                  SurfaceFilletSizeMode.constantWidth
                              ? 'Chordal width'
                              : 'Radius',
                          suffixText: 'mm',
                        ),
                        onChanged: (value) {
                          final parsed = double.tryParse(
                            value.replaceAll(',', '.'),
                          );
                          if (parsed == null || parsed <= 0) return;
                          if (filletSizeMode ==
                              SurfaceFilletSizeMode.constantWidth) {
                            filletWidth = parsed;
                          } else {
                            filletRadius = parsed;
                          }
                        },
                      ),
                      if (filletSizeMode ==
                          SurfaceFilletSizeMode.variableRadius) ...[
                        for (
                          var index = 0;
                          index < filletRadiusPoints.length;
                          index++
                        )
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'P${index + 1} · ${(filletRadiusPoints[index].parameter * 100).round()}%',
                                ),
                              ),
                              SizedBox(
                                width: 90,
                                child: TextFormField(
                                  initialValue: filletRadiusPoints[index].value
                                      .toString(),
                                  decoration: const InputDecoration(
                                    suffixText: 'mm',
                                  ),
                                  onChanged: (value) {
                                    final radius = double.tryParse(
                                      value.replaceAll(',', '.'),
                                    );
                                    if (radius != null && radius > 0) {
                                      filletRadiusPoints[index] =
                                          SurfaceFilletRadiusPoint(
                                            filletRadiusPoints[index].parameter,
                                            radius,
                                          );
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        TextButton.icon(
                          onPressed: filletRadiusPoints.length >= 12
                              ? null
                              : () => setState(() {
                                  final count = filletRadiusPoints.length + 1;
                                  final values = List.generate(
                                    count,
                                    (index) => SurfaceFilletRadiusPoint(
                                      index / (count - 1),
                                      filletRadius,
                                    ),
                                  );
                                  filletRadiusPoints
                                    ..clear()
                                    ..addAll(values);
                                }),
                          icon: const Icon(Icons.add),
                          label: const Text('Add radius point'),
                        ),
                      ],
                      DropdownButtonFormField<SurfaceFilletContinuity>(
                        initialValue: filletContinuity,
                        decoration: const InputDecoration(
                          labelText: 'Continuity',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: SurfaceFilletContinuity.g0,
                            child: Text('G0'),
                          ),
                          DropdownMenuItem(
                            value: SurfaceFilletContinuity.g1,
                            child: Text('G1'),
                          ),
                        ],
                        onChanged: controller.busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => filletContinuity = value);
                                }
                              },
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Trim'),
                        value: filletTrim,
                        onChanged: (value) =>
                            setState(() => filletTrim = value),
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Extend'),
                        value: filletExtend,
                        onChanged: (value) =>
                            setState(() => filletExtend = value),
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          'Compensation${filletGap > 0 ? ' · ${filletGap.toStringAsFixed(3)} mm' : ''}',
                        ),
                        value: filletCompensate,
                        onChanged: (value) =>
                            setState(() => filletCompensate = value),
                      ),
                      if (filletCompensate)
                        TextFormField(
                          initialValue: filletGap.toString(),
                          decoration: const InputDecoration(
                            labelText: 'Authorized compensation gap',
                            suffixText: 'mm',
                          ),
                          onChanged: (value) {
                            final parsed = double.tryParse(
                              value.replaceAll(',', '.'),
                            );
                            if (parsed != null && parsed >= 0) {
                              filletGap = parsed;
                            }
                          },
                        ),
                      const Text(
                        'Zebra · Reflection · Curvature are available during Preview. G2, Smooth/Cliff overflow are prepared.',
                        style: TextStyle(fontSize: 11),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: controller.busy || !_guidedSelectionReady
                                ? null
                                : _previewGuidedSurfaceCommand,
                            child: const Text('Preview'),
                          ),
                        ),
                        TextButton(
                          onPressed: controller.busy
                              ? null
                              : _cancelGuidedSurfaceCommand,
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (controller.surfaceOffsetPreviewActive)
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: controller.busy
                        ? null
                        : () async {
                            await controller.confirmSurfaceOffset();
                            if (mounted && !_dedicatedSurfaceCommand) {
                              setState(() => guidedSurfaceTool = null);
                            }
                          },
                    child: const Text('Confirm Offset'),
                  ),
                ),
                TextButton(
                  onPressed: controller.busy
                      ? null
                      : controller.cancelSurfaceOffset,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          Text(
            controller.professionalSurfaceSelectionGuidance,
            style: const TextStyle(fontSize: 11),
          ),
          if (!_dedicatedSurfaceCommand &&
              controller.selectedProfessionalSurface != null) ...[
            const SizedBox(height: 10),
            const Text('Edit', style: TextStyle(fontWeight: FontWeight.w600)),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tool in const [
                  ProfessionalSurfaceTool.extend,
                  ProfessionalSurfaceTool.trim,
                  ProfessionalSurfaceTool.offset,
                  ProfessionalSurfaceTool.offsetWalls,
                  ProfessionalSurfaceTool.boundaryExtend,
                  ProfessionalSurfaceTool.boundaryTrim,
                  ProfessionalSurfaceTool.match,
                  ProfessionalSurfaceTool.heal,
                  ProfessionalSurfaceTool.mergeFaces,
                ])
                  OutlinedButton(
                    onPressed: controller.busy
                        ? null
                        : () => controller.previewProfessionalSurfaceEdit(tool),
                    child: Text(
                      tool == ProfessionalSurfaceTool.mergeFaces
                          ? 'Merge Faces'
                          : tool == ProfessionalSurfaceTool.offsetWalls
                          ? 'Offset + Walls'
                          : tool == ProfessionalSurfaceTool.boundaryExtend
                          ? 'Boundary Extend'
                          : tool == ProfessionalSurfaceTool.boundaryTrim
                          ? 'Boundary Trim'
                          : tool == ProfessionalSurfaceTool.match
                          ? 'Match Surface'
                          : tool.name[0].toUpperCase() + tool.name.substring(1),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Topology',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tool in const [
                  ProfessionalSurfaceTool.split,
                  ProfessionalSurfaceTool.join,
                  ProfessionalSurfaceTool.unsewFace,
                  ProfessionalSurfaceTool.unsewSelected,
                  ProfessionalSurfaceTool.unsewAll,
                  ProfessionalSurfaceTool.replaceFace,
                  ProfessionalSurfaceTool.deleteFace,
                  ProfessionalSurfaceTool.healLocal,
                ])
                  OutlinedButton(
                    onPressed: controller.busy
                        ? null
                        : () => controller.previewProfessionalSurfaceEdit(tool),
                    child: Text(
                      tool == ProfessionalSurfaceTool.join
                          ? 'Sew'
                          : tool == ProfessionalSurfaceTool.unsewFace
                          ? 'Unsew Face'
                          : tool == ProfessionalSurfaceTool.unsewSelected
                          ? 'Unsew Selected'
                          : tool == ProfessionalSurfaceTool.unsewAll
                          ? 'Unsew All'
                          : tool == ProfessionalSurfaceTool.replaceFace
                          ? 'Replace Face'
                          : tool == ProfessionalSurfaceTool.deleteFace
                          ? 'Delete Face'
                          : tool == ProfessionalSurfaceTool.healLocal
                          ? 'Heal Local'
                          : tool.name[0].toUpperCase() + tool.name.substring(1),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: controller.busy
                      ? null
                      : controller.validateSelectedProfessionalSurface,
                  icon: const Icon(Icons.fact_check_outlined, size: 18),
                  label: const Text('Validate'),
                ),
              ],
            ),
            if (controller.professionalSurfaceValidation.isNotEmpty)
              Text(controller.professionalSurfaceValidation.join('\n')),
            const SizedBox(height: 8),
            const Text(
              'Analysis',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final mode in const [
                  SurfaceAnalysisMode.zebra,
                  SurfaceAnalysisMode.reflection,
                  SurfaceAnalysisMode.curvature,
                  SurfaceAnalysisMode.gaussian,
                  SurfaceAnalysisMode.draft,
                ])
                  OutlinedButton(
                    onPressed: controller.busy
                        ? null
                        : () => controller.analyzeSelectedProfessionalSurface(
                            mode,
                          ),
                    child: Text(
                      mode.name[0].toUpperCase() + mode.name.substring(1),
                    ),
                  ),
                TextButton(
                  onPressed: controller.clearProfessionalSurfaceAnalysis,
                  child: const Text('Close Analysis'),
                ),
              ],
            ),
          ],
        ],
        if (controller.professionalSurfacePreview != null) ...[
          if (controller.professionalSurfacePreview!.definition.tool ==
              ProfessionalSurfaceTool.fillet) ...[
            const Text(
              'Preview quality analysis',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final kind in ProfessionalAnalysisKind.values)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(switch (kind) {
                  ProfessionalAnalysisKind.zebra => 'Zebra',
                  ProfessionalAnalysisKind.reflection => 'Reflection',
                  ProfessionalAnalysisKind.curvature => 'Curvature',
                }),
                value: filletPreviewAnalyses.contains(kind),
                onChanged: controller.busy
                    ? null
                    : (enabled) async {
                        setState(() {
                          if (enabled ?? false) {
                            filletPreviewAnalyses.add(kind);
                          } else {
                            filletPreviewAnalyses.remove(kind);
                          }
                        });
                        await controller.updateProfessionalSurfacePreview(
                          parameters: {
                            'previewAnalyses': filletPreviewAnalyses
                                .map((item) => item.name)
                                .toList(),
                          },
                        );
                      },
              ),
            TextFormField(
              initialValue:
                  '${controller.professionalSurfacePreview!.definition.parameters['radius'] ?? 5}',
              decoration: const InputDecoration(
                labelText: 'Radius',
                suffixText: 'mm',
              ),
              onFieldSubmitted: controller.busy
                  ? null
                  : (value) {
                      final parsed = double.tryParse(
                        value.replaceAll(',', '.'),
                      );
                      if (parsed != null && parsed > 0) {
                        controller.updateProfessionalSurfacePreview(
                          parameters: {'radius': parsed},
                        );
                      }
                    },
            ),
            TextFormField(
              initialValue:
                  '${controller.professionalSurfacePreview!.definition.parameters['width'] ?? 5}',
              decoration: const InputDecoration(
                labelText: 'Chordal width',
                suffixText: 'mm',
              ),
              onFieldSubmitted: controller.busy
                  ? null
                  : (value) {
                      final parsed = double.tryParse(
                        value.replaceAll(',', '.'),
                      );
                      if (parsed != null && parsed > 0) {
                        controller.updateProfessionalSurfacePreview(
                          parameters: {'width': parsed},
                        );
                      }
                    },
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Trim'),
              value:
                  controller
                      .professionalSurfacePreview!
                      .definition
                      .parameters['trim'] !=
                  false,
              onChanged: controller.busy
                  ? null
                  : (value) => controller.updateProfessionalSurfacePreview(
                      parameters: {'trim': value},
                    ),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Extend'),
              value:
                  controller
                      .professionalSurfacePreview!
                      .definition
                      .parameters['extend'] ==
                  true,
              onChanged: controller.busy
                  ? null
                  : (value) => controller.updateProfessionalSurfacePreview(
                      parameters: {'extend': value},
                    ),
            ),
          ],
          if (controller.professionalSurfacePreview!.definition.tool ==
              ProfessionalSurfaceTool.blend) ...[
            const Text(
              'Independent boundary conditions',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final side in [0, 1])
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Side ${side + 1}'),
                      DropdownButtonFormField<BlendContinuity>(
                        initialValue: side == 0
                            ? firstBlendContinuity
                            : secondBlendContinuity,
                        decoration: const InputDecoration(
                          labelText: 'Continuity',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: BlendContinuity.g0,
                            child: Text('G0 · Position'),
                          ),
                          DropdownMenuItem(
                            value: BlendContinuity.g1,
                            child: Text('G1 · Tangent'),
                          ),
                        ],
                        onChanged: controller.busy
                            ? null
                            : (value) async {
                                if (value == null) return;
                                setState(() {
                                  if (side == 0) {
                                    firstBlendContinuity = value;
                                  } else {
                                    secondBlendContinuity = value;
                                  }
                                });
                                await _updateBlendSideConditions();
                              },
                      ),
                      Text(
                        'Tangency influence: ${((side == 0 ? firstBlendInfluence : secondBlendInfluence) * 100).round()}%',
                      ),
                      Slider(
                        value: side == 0
                            ? firstBlendInfluence
                            : secondBlendInfluence,
                        min: 0.05,
                        max: 1,
                        divisions: 19,
                        onChanged: controller.busy
                            ? null
                            : (value) => setState(() {
                                if (side == 0) {
                                  firstBlendInfluence = value;
                                } else {
                                  secondBlendInfluence = value;
                                }
                              }),
                        onChangeEnd: controller.busy
                            ? null
                            : (_) => _updateBlendSideConditions(),
                      ),
                    ],
                  ),
                ),
              ),
            const Text(
              'G2 is architecturally prepared and unavailable in this version.',
              style: TextStyle(fontSize: 11),
            ),
          ],
          if (controller.professionalSurfacePreview!.definition.tool ==
              ProfessionalSurfaceTool.fill) ...[
            const Text(
              'Fill boundary conditions',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final raw
                in (controller
                            .professionalSurfacePreview!
                            .definition
                            .parameters['boundaryConditions']
                        as List? ??
                    const []))
              if (raw is Map)
                Builder(
                  builder: (context) {
                    final condition = Map<String, dynamic>.from(raw);
                    final id = condition['boundaryEntityId'] as String;
                    final hasSupport = condition['supportSurfaceId'] != null;
                    final continuity =
                        fillContinuities[id] ?? FillBoundaryContinuity.g0;
                    final influence = fillInfluences[id] ?? 1;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(id),
                            Text('Loop: ${condition['loopId']}'),
                            TextFormField(
                              initialValue:
                                  fillLoopIds[id] ?? '${condition['loopId']}',
                              decoration: const InputDecoration(
                                labelText: 'Loop ID',
                                hintText: 'outer, inner-1, inner-2…',
                              ),
                              onFieldSubmitted: controller.busy
                                  ? null
                                  : (value) async {
                                      final normalized = value.trim();
                                      if (normalized.isEmpty) return;
                                      setState(
                                        () => fillLoopIds[id] = normalized,
                                      );
                                      await _updateFillBoundaryConditions();
                                    },
                            ),
                            DropdownButtonFormField<FillBoundaryContinuity>(
                              initialValue: continuity,
                              decoration: const InputDecoration(
                                labelText: 'Continuity',
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: FillBoundaryContinuity.g0,
                                  child: Text('G0 · Free/Position'),
                                ),
                                DropdownMenuItem(
                                  value: FillBoundaryContinuity.g1,
                                  enabled: hasSupport,
                                  child: Text(
                                    hasSupport
                                        ? 'G1 · Tangent'
                                        : 'G1 · Select support Surface',
                                  ),
                                ),
                              ],
                              onChanged: controller.busy
                                  ? null
                                  : (value) async {
                                      if (value == null) return;
                                      setState(
                                        () => fillContinuities[id] = value,
                                      );
                                      await _updateFillBoundaryConditions();
                                    },
                            ),
                            Text(
                              'Tangency influence: ${(influence * 100).round()}%',
                            ),
                            Slider(
                              value: influence,
                              min: 0.05,
                              max: 1,
                              divisions: 19,
                              onChanged:
                                  controller.busy ||
                                      continuity != FillBoundaryContinuity.g1
                                  ? null
                                  : (value) => setState(
                                      () => fillInfluences[id] = value,
                                    ),
                              onChangeEnd:
                                  controller.busy ||
                                      continuity != FillBoundaryContinuity.g1
                                  ? null
                                  : (_) => _updateFillBoundaryConditions(),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            const Text(
              'Any number of boundaries and loops is supported. G2 is prepared only.',
              style: TextStyle(fontSize: 11),
            ),
          ],
          _CategoryBTaskPanel(
            preview: controller.professionalSurfacePreview!,
            value: categoryBValue,
            continuity: categoryBContinuity,
            busy: controller.busy,
            onValueChanged: (value) => setState(() => categoryBValue = value),
            onValueCommitted: (value) {
              final tool =
                  controller.professionalSurfacePreview!.definition.tool;
              controller.updateProfessionalSurfacePreview(
                parameters: {
                  if (tool == ProfessionalSurfaceTool.blend) 'radius': value,
                  if (tool == ProfessionalSurfaceTool.offsetWalls)
                    'distance': value,
                  if (tool == ProfessionalSurfaceTool.boundaryExtend)
                    'length': value,
                  if (tool == ProfessionalSurfaceTool.boundaryTrim)
                    'keepRegionIndex': value.round(),
                  if (tool == ProfessionalSurfaceTool.match)
                    'tolerance3d': value,
                },
              );
            },
            onContinuityChanged: (value) {
              setState(() => categoryBContinuity = value);
              controller.updateProfessionalSurfacePreview(continuity: value);
            },
            offsetMode: offsetMode,
            offsetDirection: offsetDirection,
            onOffsetModeChanged: (value) {
              setState(() => offsetMode = value);
              controller.updateProfessionalSurfacePreview(
                parameters: {
                  'offsetMode': value.name,
                  'closeResult': value == SurfaceOffsetMode.close,
                },
              );
            },
            onOffsetDirectionChanged: (value) {
              setState(() => offsetDirection = value);
              controller.updateProfessionalSurfacePreview(
                parameters: {'direction': value.name},
              );
            },
            wallBoundaryIds: wallBoundaryIds,
            onWallBoundaryChanged: (id, enabled) {
              setState(() {
                enabled ? wallBoundaryIds.add(id) : wallBoundaryIds.remove(id);
              });
              final available = controller
                  .professionalSurfacePreview!
                  .definition
                  .references
                  .skip(1)
                  .toSet();
              controller.updateProfessionalSurfacePreview(
                parameters: {
                  'wallBoundaryIds': wallBoundaryIds.toList(),
                  'openBoundaryIds': available
                      .difference(wallBoundaryIds)
                      .toList(),
                },
              );
            },
          ),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: controller.busy
                      ? null
                      : () async {
                          await controller.confirmProfessionalSurface();
                          if (mounted && !_dedicatedSurfaceCommand) {
                            setState(() => guidedSurfaceTool = null);
                          }
                        },
                  child: Text(switch (controller
                      .professionalSurfacePreview!
                      .definition
                      .tool) {
                    ProfessionalSurfaceTool.loft => 'Create Loft',
                    ProfessionalSurfaceTool.sweep => 'Create Sweep',
                    ProfessionalSurfaceTool.blend => 'Create Blend',
                    ProfessionalSurfaceTool.sew => 'Create Body',
                    _ => 'Apply',
                  }),
                ),
              ),
              TextButton(
                onPressed: controller.busy ? null : _cancelGuidedSurfaceCommand,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
        const Divider(),
        Wrap(
          spacing: 6,
          children: [
            IconButton(
              tooltip: 'Undo',
              onPressed: controller.busy ? null : controller.undo,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: 'Redo',
              onPressed: controller.busy ? null : controller.redo,
              icon: const Icon(Icons.redo),
            ),
            IconButton(
              tooltip: 'Save Project',
              onPressed: controller.busy ? null : controller.saveProject,
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        if (controller.busy) const LinearProgressIndicator(),
      ],
    ),
  );
}

class _CategoryBTaskPanel extends StatelessWidget {
  const _CategoryBTaskPanel({
    required this.preview,
    required this.value,
    required this.continuity,
    required this.busy,
    required this.onValueChanged,
    required this.onValueCommitted,
    required this.onContinuityChanged,
    required this.offsetMode,
    required this.offsetDirection,
    required this.onOffsetModeChanged,
    required this.onOffsetDirectionChanged,
    required this.wallBoundaryIds,
    required this.onWallBoundaryChanged,
  });

  final SurfacePreviewState preview;
  final double value;
  final SurfaceContinuity continuity;
  final bool busy;
  final ValueChanged<double> onValueChanged, onValueCommitted;
  final ValueChanged<SurfaceContinuity> onContinuityChanged;
  final SurfaceOffsetMode offsetMode;
  final SurfaceOffsetDirection offsetDirection;
  final ValueChanged<SurfaceOffsetMode> onOffsetModeChanged;
  final ValueChanged<SurfaceOffsetDirection> onOffsetDirectionChanged;
  final Set<String> wallBoundaryIds;
  final void Function(String id, bool enabled) onWallBoundaryChanged;

  @override
  Widget build(BuildContext context) {
    final tool = preview.definition.tool;
    if (!const {
      ProfessionalSurfaceTool.match,
      ProfessionalSurfaceTool.blend,
      ProfessionalSurfaceTool.offsetWalls,
      ProfessionalSurfaceTool.boundaryExtend,
      ProfessionalSurfaceTool.boundaryTrim,
    }.contains(tool)) {
      return const SizedBox.shrink();
    }
    final (
      title,
      selection,
      parameter,
      minimum,
      maximum,
      divisions,
    ) = switch (tool) {
      ProfessionalSurfaceTool.match => (
        'Match Surface',
        'Surface → Boundary → Target Surface',
        'Tolerance',
        0.00001,
        0.01,
        100,
      ),
      ProfessionalSurfaceTool.blend => (
        'Blend Surface',
        'Shared Edge, or Surface 1 → Boundary 1 → Surface 2 → Boundary 2',
        'Radius',
        0.1,
        100.0,
        999,
      ),
      ProfessionalSurfaceTool.offsetWalls => (
        'Offset + Walls',
        'Shape → Opening Faces → Distance/Direction',
        'Distance',
        -100.0,
        100.0,
        400,
      ),
      ProfessionalSurfaceTool.boundaryExtend => (
        'Boundary Extend',
        'Surface → Boundary → Side or Target',
        'Length',
        0.1,
        100.0,
        999,
      ),
      ProfessionalSurfaceTool.boundaryTrim => (
        'Boundary Trim',
        'Surface → Boundary → Cutting Tool → Region to Keep',
        'Region',
        0.0,
        20.0,
        20,
      ),
      _ => throw StateError('Not a Category B tool'),
    };
    final safeValue = value.clamp(minimum, maximum).toDouble();
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(selection, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text('$parameter: ${safeValue.toStringAsPrecision(4)}'),
            Slider(
              value: safeValue,
              min: minimum,
              max: maximum,
              divisions: divisions,
              onChanged: busy ? null : onValueChanged,
              onChangeEnd: busy ? null : onValueCommitted,
            ),
            if (tool == ProfessionalSurfaceTool.offsetWalls) ...[
              DropdownButtonFormField<SurfaceOffsetMode>(
                initialValue: offsetMode,
                decoration: const InputDecoration(labelText: 'Offset mode'),
                items: SurfaceOffsetMode.values
                    .map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text(switch (item) {
                          SurfaceOffsetMode.offset => 'Offset',
                          SurfaceOffsetMode.replace => 'Replace',
                          SurfaceOffsetMode.walls => 'Offset + Walls',
                          SurfaceOffsetMode.close => 'Offset + Close',
                        }),
                      ),
                    )
                    .toList(growable: false),
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null) onOffsetModeChanged(value);
                      },
              ),
              DropdownButtonFormField<SurfaceOffsetDirection>(
                initialValue: offsetDirection,
                decoration: const InputDecoration(labelText: 'Direction'),
                items: SurfaceOffsetDirection.values
                    .map(
                      (item) =>
                          DropdownMenuItem(value: item, child: Text(item.name)),
                    )
                    .toList(growable: false),
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null) onOffsetDirectionChanged(value);
                      },
              ),
              const Text(
                'Choose every Boundary explicitly. No wall is created implicitly.',
                style: TextStyle(fontSize: 11),
              ),
              for (final id in preview.definition.references.skip(1))
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(id, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    wallBoundaryIds.contains(id) ? 'Wall' : 'Open',
                  ),
                  value: wallBoundaryIds.contains(id),
                  onChanged: busy
                      ? null
                      : (value) => onWallBoundaryChanged(id, value ?? false),
                ),
            ],
            if (tool == ProfessionalSurfaceTool.match)
              DropdownButtonFormField<SurfaceContinuity>(
                initialValue: continuity,
                decoration: const InputDecoration(labelText: 'Continuity'),
                items: SurfaceContinuity.values
                    .where(
                      (item) =>
                          tool != ProfessionalSurfaceTool.blend ||
                          item != SurfaceContinuity.g2,
                    )
                    .map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text(item.name.toUpperCase()),
                      ),
                    )
                    .toList(growable: false),
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null) onContinuityChanged(value);
                      },
              ),
            const SizedBox(height: 4),
            const Text(
              'Orange: preview · Cyan: modified · Green: target · Red: invalid',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfessionalSketchToolbar extends StatelessWidget {
  const _ProfessionalSketchToolbar({
    required this.controller,
    required this.onSnapManager,
  });
  final OperationalReverseEngineeringController controller;
  final VoidCallback onSnapManager;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Sketch', style: TextStyle(fontWeight: FontWeight.w700)),
      for (final group in <String, List<(SketchToolType, IconData)>>{
        'Draw': [
          (SketchToolType.line, Icons.show_chart),
          (SketchToolType.arc, Icons.architecture),
          (SketchToolType.circle, Icons.circle_outlined),
          (SketchToolType.rectangle, Icons.crop_square),
          (SketchToolType.spline, Icons.gesture),
        ],
        'Edit': [
          (SketchToolType.move, Icons.open_with),
          (SketchToolType.rotate, Icons.rotate_right),
          (SketchToolType.scale, Icons.aspect_ratio),
        ],
        'Modify': [
          (SketchToolType.offset, Icons.content_copy),
          (SketchToolType.trim, Icons.content_cut),
          (SketchToolType.extend, Icons.trending_flat),
          (SketchToolType.fillet, Icons.rounded_corner),
          (SketchToolType.chamfer, Icons.change_history),
        ],
      }.entries)
        ExpansionTile(
          dense: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text(group.key),
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final item in group.value)
                  IconButton.filledTonal(
                    tooltip: item.$1.name,
                    isSelected: controller.activeTool == item.$1,
                    onPressed: () => controller.selectSketchTool(item.$1),
                    icon: Icon(item.$2, size: 18),
                  ),
              ],
            ),
          ],
        ),
      ExpansionTile(
        dense: true,
        tilePadding: EdgeInsets.zero,
        title: const Text('Constraints'),
        trailing: const Icon(Icons.rule, size: 18),
        children: [
          Text('${controller.constraints.length} applied constraints'),
        ],
      ),
      ExpansionTile(
        dense: true,
        tilePadding: EdgeInsets.zero,
        title: const Text('Reverse Engineering'),
        trailing: const Icon(Icons.auto_fix_high, size: 18),
        children: const [Text('Section → Polyline → Best Fit Spline')],
      ),
      OutlinedButton.icon(
        onPressed: onSnapManager,
        icon: const Icon(Icons.gps_fixed),
        label: const Text('Snap Manager'),
      ),
    ],
  );
}

class _SnapManager extends StatelessWidget {
  const _SnapManager({
    required this.controller,
    required this.mesh,
    required this.section,
    required this.sketch,
    required this.references,
    required this.grid,
    required this.onMesh,
    required this.onSection,
    required this.onSketch,
    required this.onReferences,
    required this.onGrid,
    required this.onCoreSnap,
  });
  final OperationalReverseEngineeringController controller;
  final bool mesh, section, sketch, references, grid;
  final ValueChanged<bool> onMesh, onSection, onSketch, onReferences, onGrid;
  final void Function(EditorSnapType, bool) onCoreSnap;

  @override
  Widget build(BuildContext context) {
    final enabled =
        controller.editorApi?.engine.snapping.settings.enabled ?? {};
    Widget toggle(String label, bool value, ValueChanged<bool> changed) =>
        FilterChip(label: Text(label), selected: value, onSelected: changed);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Snap sources'),
            Wrap(
              spacing: 4,
              children: [
                toggle('Mesh', mesh, onMesh),
                toggle('Section', section, onSection),
                toggle('Sketch', sketch, onSketch),
                toggle('References', references, onReferences),
                toggle('Grid', grid, onGrid),
              ],
            ),
            const Text('Smart cursor'),
            Wrap(
              spacing: 4,
              children: [
                for (final type in const [
                  EditorSnapType.endpoint,
                  EditorSnapType.midpoint,
                  EditorSnapType.center,
                  EditorSnapType.tangent,
                  EditorSnapType.perpendicular,
                  EditorSnapType.intersection,
                  EditorSnapType.nearest,
                ])
                  FilterChip(
                    label: Text(type.name),
                    selected: enabled.contains(type),
                    onSelected: (value) => onCoreSnap(type, value),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SketchHeadsUpDisplay extends StatelessWidget {
  const _SketchHeadsUpDisplay({required this.controller});
  final OperationalReverseEngineeringController controller;
  @override
  Widget build(BuildContext context) {
    final points = controller.previewPoints;
    final snap = controller.editorApi?.engine.snapping.preview;
    double dx = 0, dy = 0, length = 0, angle = 0;
    if (points.length >= 2) {
      dx = points.last.x - points.first.x;
      dy = points.last.y - points.first.y;
      length = math.sqrt(dx * dx + dy * dy);
      angle = math.atan2(dy, dx) * 180 / math.pi;
    }
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${controller.activeTool.name.toUpperCase()} · HEADS-UP'),
            Text(
              'X ${points.isEmpty ? '0.000' : points.last.x.toStringAsFixed(3)}  '
              'Y ${points.isEmpty ? '0.000' : points.last.y.toStringAsFixed(3)}',
            ),
            Text(
              'Length ${length.toStringAsFixed(3)} mm  ·  '
              'Angle ${angle.toStringAsFixed(2)}°',
            ),
            Text('Snap: ${snap?.type.name ?? 'grid'}'),
            const Text('ENTER confirm  ·  ESC cancel  ·  type value to edit'),
          ],
        ),
      ),
    );
  }
}

class _ConstraintStateBanner extends StatelessWidget {
  const _ConstraintStateBanner({required this.controller});
  final OperationalReverseEngineeringController controller;
  @override
  Widget build(BuildContext context) {
    final dof = controller.editorApi?.dof.remaining ?? 0;
    final quality = controller.editorApi?.quality;
    final over = quality?.factors['overdefined']?.toInt() ?? 0;
    final label = over > 0
        ? 'Over Constrained'
        : dof == 0
        ? 'Fully Constrained'
        : 'Under Constrained · $dof DOF';
    final color = over > 0
        ? Colors.red
        : dof == 0
        ? Colors.green
        : Colors.blue;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.circle, color: color, size: 14),
      title: Text(label),
      subtitle: const Text('Green fully · Blue under · Red over constrained'),
    );
  }
}

class _ConstraintGlyphSummary extends StatelessWidget {
  const _ConstraintGlyphSummary({required this.controller});
  final OperationalReverseEngineeringController controller;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    runSpacing: 4,
    children: [
      for (final constraint in controller.constraints)
        Tooltip(
          message: constraint.type.name,
          child: Chip(
            avatar: const Icon(Icons.link, size: 14, color: Colors.green),
            label: Text(
              constraint.type.name,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ),
    ],
  );
}
