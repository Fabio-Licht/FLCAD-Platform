import 'package:flutter/material.dart';

import '../../../core/sketch_assistant/sketch_continuity_repair_planner.dart';
import '../../../core/sketch_assistant/sketch_g1_continuity_repair_planner.dart';
import '../../../core/sketch_assistant/sketch_reconstruction.dart';
import '../../engineering_bridge/operational_reverse_engineering_controller.dart';

class SketchContinuityRepairPanel extends StatefulWidget {
  const SketchContinuityRepairPanel({
    super.key,
    required this.controller,
    required this.joins,
    required this.allJoins,
    required this.preview,
    required this.g1Preview,
  });

  final OperationalReverseEngineeringController controller;
  final List<SketchContinuityJoinDiagnostic> joins;
  final List<SketchContinuityJoinDiagnostic> allJoins;
  final SketchContinuityRepairPlan? preview;
  final SketchG1RepairPlan? g1Preview;

  @override
  State<SketchContinuityRepairPanel> createState() =>
      _SketchContinuityRepairPanelState();
}

class _SketchContinuityRepairPanelState
    extends State<SketchContinuityRepairPanel> {
  bool _showAll = false;

  OperationalReverseEngineeringController get controller => widget.controller;
  SketchContinuityRepairPlan? get preview => widget.preview;
  SketchG1RepairPlan? get g1Preview => widget.g1Preview;

  String _continuityLabel(SketchContinuityLevel level) => switch (level) {
    SketchContinuityLevel.g1 => 'G1 tangente',
    SketchContinuityLevel.c0 => 'C0 coincidente',
    SketchContinuityLevel.disconnected => 'desconectada',
  };

  String _joinLabel(SketchContinuityJoinDiagnostic join) =>
      '${join.first.entityId}:${join.first.name} ↔ '
      '${join.second.entityId}:${join.second.name}';

  String _joinDisplayLabel(SketchContinuityJoinDiagnostic join) =>
      '${controller.sketchContinuityEntityDisplayLabel(join.first.entityId)} '
      '↔ ${controller.sketchContinuityEntityDisplayLabel(join.second.entityId)}';

  String _alternativeLabel(SketchContinuityRepairAlternative alternative) =>
      switch (alternative.kind) {
        SketchContinuityRepairAlternativeKind.moveFirstEndpoint =>
          'Mover endpoint inicial',
        SketchContinuityRepairAlternativeKind.moveSecondEndpoint =>
          'Mover endpoint final',
        SketchContinuityRepairAlternativeKind.moveBothEndpoints =>
          'Mover os dois endpoints',
        SketchContinuityRepairAlternativeKind.extendFirstLine =>
          'Estender primeira linha',
        SketchContinuityRepairAlternativeKind.trimFirstLine =>
          'Aparar primeira linha',
        SketchContinuityRepairAlternativeKind.extendSecondLine =>
          'Estender segunda linha',
        SketchContinuityRepairAlternativeKind.trimSecondLine =>
          'Aparar segunda linha',
        SketchContinuityRepairAlternativeKind.preserveProtectedEndpoint =>
          'Preservar endpoint protegido',
      };

  String _g1AlternativeLabel(SketchG1RepairAlternative alternative) =>
      switch (alternative.kind) {
        SketchG1RepairAlternativeKind.lineArcPreserveLineContact =>
          'Linha–Arco: preservar contato da linha',
        SketchG1RepairAlternativeKind.lineArcPreserveArcContact =>
          'Linha–Arco: preservar contato do arco',
        SketchG1RepairAlternativeKind.arcArcPreserveFirstContact =>
          'Arco–Arco: preservar primeiro contato',
        SketchG1RepairAlternativeKind.arcArcPreserveSecondContact =>
          'Arco–Arco: preservar segundo contato',
      };

  String _g1Metric(double? value, {String unit = 'mm'}) =>
      value == null ? 'indisponível' : '${value.toStringAsFixed(6)} $unit';

  Widget _g1MetricRow(String label, String before, String after) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 3, child: Text(label, style: const TextStyle(fontSize: 8.5))),
        Expanded(
          flex: 2,
          child: Text(before, key: ValueKey('sketch-g1-metric-before-$label'), style: const TextStyle(fontSize: 8.5)),
        ),
        Expanded(
          flex: 2,
          child: Text(after, key: ValueKey('sketch-g1-metric-after-$label'), style: const TextStyle(fontSize: 8.5)),
        ),
      ],
    ),
  );

  Future<void> _confirmSelectedAlternative() async {
    final token = controller.sketchContinuityRepairPreviewToken;
    if (token == null || !controller.canConfirmSketchContinuityRepair) return;
    try {
      await controller.confirmSketchContinuityRepairPreview(token: token);
    } catch (_) {
      // The controller publishes the diagnostic and releases its busy guard.
    }
  }

  Future<void> _confirmSelectedG1Alternative() async {
    final token = controller.sketchG1ContinuityRepairPreviewToken;
    if (token == null || !controller.canConfirmSketchG1ContinuityRepair) {
      return;
    }
    try {
      await controller.confirmSketchG1ContinuityRepairPreview(token: token);
    } catch (_) {
      // The controller publishes the diagnostic and releases its busy guard.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedJoin = controller.selectedSketchContinuityJoin;
    final selectedAlternative =
        controller.selectedSketchContinuityRepairAlternative;
    final selectedG1Alternative = controller.selectedSketchG1RepairAlternative;
    final displayedJoins = _showAll ? widget.allJoins : widget.joins;
    final healthyCount = widget.allJoins.length - widget.joins.length;
    final gapCount = widget.joins
        .where((join) => join.issue == SketchContinuityIssue.gap)
        .length;
    final blockingCount = widget.joins.length - gapCount;
    final joins = displayedJoins;
    return Card(
      key: const ValueKey('sketch-continuity-repair-panel'),
      margin: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .45),
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Correções C0/G1',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            const Text(
              'Selecione uma junção próxima para examinar alternativas. O preview é transitório e não altera o Sketch.',
              style: TextStyle(fontSize: 9.5),
            ),
            const SizedBox(height: 4),
            Text(
              '$gapCount gaps · $blockingCount bloqueios · $healthyCount conexões sem problemas',
              style: TextStyle(
                fontSize: 9,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _showAll
                        ? 'Todas as junções próximas'
                        : widget.joins.isEmpty
                        ? 'Nenhuma junção exige atenção'
                        : 'Junções que exigem atenção',
                    style: const TextStyle(fontSize: 9.5),
                  ),
                ),
                TextButton(
                  onPressed: widget.allJoins.isEmpty
                      ? null
                      : () => setState(() => _showAll = !_showAll),
                  child: Text(_showAll ? 'Ocultar saudáveis' : 'Ver todas'),
                ),
              ],
            ),
            for (final join in joins)
              ListTile(
                key: ValueKey(
                  'sketch-continuity-join-${join.first.entityId}-${join.first.name}-${join.second.entityId}-${join.second.name}',
                ),
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
                selected:
                    selectedJoin != null &&
                    selectedJoin.first.entityId == join.first.entityId &&
                    selectedJoin.second.entityId == join.second.entityId &&
                    selectedJoin.first.name == join.first.name &&
                    selectedJoin.second.name == join.second.name,
                title: Text(
                  _joinDisplayLabel(join),
                  style: const TextStyle(fontSize: 9.5),
                ),
                subtitle: Text(
                  'gap ${join.gapMillimeters.toStringAsFixed(3)} mm · ${_continuityLabel(join.continuity)}'
                  '${join.tangentAngleDegrees == null ? '' : ' · Δ ${join.tangentAngleDegrees!.toStringAsFixed(2)}°'}',
                  style: const TextStyle(fontSize: 9),
                ),
                onTap: () => controller.selectSketchContinuityJoin(join),
              ),
            OutlinedButton.icon(
              key: const ValueKey('sketch-continuity-use-cad-selection'),
              onPressed: controller.selectedSketchEntityIds.length == 2
                  ? controller.selectSketchContinuityJoinFromSketchSelection
                  : null,
              icon: const Icon(Icons.ads_click, size: 14),
              label: const Text('Usar 2 curvas selecionadas'),
            ),
            if (selectedJoin != null) ...[
              const Divider(height: 8),
              Text(
                'Junção: ${_joinLabel(selectedJoin)} · C0 medido: ${selectedJoin.measuredC0 ? 'sim' : 'não'} · G1 medido: ${selectedJoin.measuredG1 ? 'sim' : 'não'}',
                style: const TextStyle(fontSize: 9.5),
              ),
              if (selectedJoin.declaredCoincident ||
                  selectedJoin.declaredTangent)
                Text(
                  'Constraints declaradas: ${[if (selectedJoin.declaredCoincident) 'coincident', if (selectedJoin.declaredTangent) 'tangent'].join(', ')} (continuidade medida separadamente)',
                  style: const TextStyle(fontSize: 9),
                ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('sketch-continuity-plan'),
                      onPressed: controller.canPreviewSketchContinuityRepair
                          ? controller.previewSketchContinuityRepair
                          : null,
                      icon: const Icon(Icons.preview_outlined, size: 15),
                      label: const Text('Planejar preview'),
                    ),
                  ),
                  const SizedBox(width: 5),
                  TextButton(
                    onPressed: controller.clearSketchContinuityJoinSelection,
                    child: const Text('Limpar'),
                  ),
                ],
              ),
            ],
            if (preview != null) ...[
              const Divider(height: 8),
              Text(
                preview!.status == SketchContinuityRepairStatus.impossible
                    ? 'Plano impossível'
                    : preview!.status == SketchContinuityRepairStatus.valid
                    ? 'Junção já coincidente'
                    : 'Plano requer confirmação',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color:
                      preview!.status == SketchContinuityRepairStatus.impossible
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
              Text(
                'Gap atual ${preview!.currentGapMillimeters.toStringAsFixed(3)} mm · limite reparável ${preview!.repairGapToleranceMillimeters.toStringAsFixed(3)} mm',
                style: const TextStyle(fontSize: 9),
              ),
              if (preview!.protectedEntityIds.isNotEmpty)
                Text(
                  'Protegidas: ${preview!.protectedEntityIds.join(', ')}',
                  style: const TextStyle(fontSize: 9),
                ),
              for (var index = 0; index < preview!.alternatives.length; index++)
                ListTile(
                  key: ValueKey('sketch-continuity-alternative-$index'),
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: EdgeInsets.zero,
                  selected: identical(
                    selectedAlternative,
                    preview!.alternatives[index],
                  ),
                  title: Text(
                    _alternativeLabel(preview!.alternatives[index]),
                    style: const TextStyle(fontSize: 9.5),
                  ),
                  subtitle: Text(
                    '${preview!.alternatives[index].status.name} · desloc. máx ${preview!.alternatives[index].maxDisplacementMillimeters.toStringAsFixed(3)} mm · C0 ${preview!.alternatives[index].c0ResidualMillimeters.toStringAsFixed(6)} mm${preview!.alternatives[index].g1ResidualRadians == null ? '' : ' · G1 ${preview!.alternatives[index].g1ResidualRadians!.toStringAsFixed(6)} rad'}',
                    style: const TextStyle(fontSize: 8.5),
                  ),
                  onTap: () =>
                      controller.selectSketchContinuityRepairAlternative(index),
                ),
              for (final diagnostic in preview!.diagnostics)
                Text(
                  diagnostic,
                  style: TextStyle(
                    fontSize: 8.5,
                    color:
                        preview!.status ==
                            SketchContinuityRepairStatus.impossible
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              if (selectedAlternative != null)
                for (final diagnostic in selectedAlternative.diagnostics)
                  Text(diagnostic, style: const TextStyle(fontSize: 8.5)),
              Row(
                children: [
                  TextButton(
                    onPressed: controller.busy
                        ? null
                        : controller.cancelSketchContinuityRepairPreview,
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 5),
                  OutlinedButton.icon(
                    key: const ValueKey('sketch-continuity-repair-confirm'),
                    onPressed: controller.canConfirmSketchContinuityRepair
                        ? _confirmSelectedAlternative
                        : null,
                    icon: const Icon(Icons.check, size: 14),
                    label: const Text('Confirmar'),
                  ),
                ],
              ),
            ],
            if (g1Preview != null) ...[
              const Divider(height: 8),
              Text(
                'Preview G1 tangencial',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color:
                      g1Preview!.status ==
                          SketchContinuityRepairStatus.impossible
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
              Text(
                'Junção: ${controller.sketchContinuityEntityDisplayLabel(g1Preview!.firstEntityId)} ↔ '
                '${controller.sketchContinuityEntityDisplayLabel(g1Preview!.secondEntityId)}',
                key: const ValueKey('sketch-g1-continuity-join-label'),
                style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700),
              ),
              Text(
                '${g1Preview!.alternatives.length} alternativa(s) calculada(s) · '
                'limite C0 ${g1Preview!.connectionToleranceMillimeters.toStringAsFixed(6)} mm · '
                'limite G1 ${g1Preview!.tangencyToleranceRadians.toStringAsFixed(6)} rad',
                style: const TextStyle(fontSize: 8.5),
              ),
              Text(
                'C0: ${g1Preview!.currentGapMillimeters.toStringAsFixed(6)} mm · '
                'G1: ${g1Preview!.currentG1ResidualRadians == null ? 'indisponível' : '${g1Preview!.currentG1ResidualRadians!.toStringAsFixed(6)} rad'} · '
                'limite angular ${g1Preview!.tangencyToleranceRadians.toStringAsFixed(6)} rad',
                style: const TextStyle(fontSize: 8.5),
              ),
              if (selectedG1Alternative != null) ...[
                Text(
                  'Alternativa selecionada: ${_g1AlternativeLabel(selectedG1Alternative)}',
                  key: const ValueKey('sketch-g1-selected-alternative'),
                  style: const TextStyle(fontSize: 8.5),
                ),
                Text(
                  'Métricas do planner (somente diagnóstico visual)',
                  key: const ValueKey('sketch-g1-metrics-title'),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Container(
                  key: const ValueKey('sketch-g1-metrics'),
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Column(
                    children: [
                      const Row(
                        children: [
                          Expanded(flex: 3, child: SizedBox()),
                          Expanded(flex: 2, child: Text('Antes', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700))),
                          Expanded(flex: 2, child: Text('Proposta', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700))),
                        ],
                      ),
                      _g1MetricRow(
                        'Gap C0',
                        _g1Metric(selectedG1Alternative.beforeGapMillimeters),
                        _g1Metric(selectedG1Alternative.afterGapMillimeters),
                      ),
                      _g1MetricRow(
                        'Resíduo G1',
                        _g1Metric(selectedG1Alternative.beforeG1ResidualRadians, unit: 'rad'),
                        _g1Metric(selectedG1Alternative.afterG1ResidualRadians, unit: 'rad'),
                      ),
                      _g1MetricRow(
                        'Deslocamento máx.',
                        '—',
                        _g1Metric(selectedG1Alternative.maxDisplacementMillimeters),
                      ),
                    ],
                  ),
                ),
                Text(
                  g1Preview!.protectedEntityIds.isEmpty
                      ? 'Elementos protegidos: nenhum informado pelo planner.'
                      : 'Elementos protegidos: ${g1Preview!.protectedEntityIds.map(controller.sketchContinuityEntityDisplayLabel).join(', ')}',
                  key: const ValueKey('sketch-g1-protected-elements'),
                  style: const TextStyle(fontSize: 8.5),
                ),
              ],
              Text(
                'Valores calculados pelo planner; não são constraint paramétrica.',
                style: TextStyle(fontSize: 8, color: theme.colorScheme.onSurfaceVariant),
              ),
              if (g1Preview!.diagnostics.isNotEmpty)
                Container(
                  key: const ValueKey('sketch-g1-diagnostics'),
                  padding: const EdgeInsets.only(top: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Bloqueios e avisos', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w700)),
                      for (final diagnostic in g1Preview!.diagnostics)
                        Text(diagnostic, style: TextStyle(fontSize: 8.5, color: theme.colorScheme.error)),
                    ],
                  ),
                ),
              Text(
                'Alternativas válidas',
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurfaceVariant),
              ),
              for (
                var index = 0;
                index < g1Preview!.alternatives.length;
                index++
              )
                if (g1Preview!.alternatives[index].isViable)
                  ListTile(
                    key: ValueKey('sketch-g1-continuity-alternative-$index'),
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: EdgeInsets.zero,
                    selected: identical(
                      selectedG1Alternative,
                      g1Preview!.alternatives[index],
                    ),
                    title: Text(
                      _g1AlternativeLabel(g1Preview!.alternatives[index]),
                      style: const TextStyle(fontSize: 9.5),
                    ),
                    subtitle: Text(
                      'C0 ${g1Preview!.alternatives[index].afterGapMillimeters.toStringAsFixed(6)} mm · '
                      'G1 ${g1Preview!.alternatives[index].afterG1ResidualRadians?.toStringAsFixed(6) ?? 'indisponível'} rad · '
                      'desloc. máx ${g1Preview!.alternatives[index].maxDisplacementMillimeters.toStringAsFixed(3)} mm',
                      style: const TextStyle(fontSize: 8.5),
                    ),
                    onTap: () => controller
                        .selectSketchG1ContinuityRepairAlternative(index),
                  ),
              if (g1Preview!.alternatives.every((item) => !item.isViable))
                Text(
                  g1Preview!.diagnostics.join(' '),
                  style: TextStyle(
                    fontSize: 8.5,
                    color: theme.colorScheme.error,
                  ),
                ),
              if (selectedG1Alternative != null)
                for (final diagnostic in selectedG1Alternative.diagnostics)
                  Text(diagnostic, style: const TextStyle(fontSize: 8.5)),
              OutlinedButton.icon(
                key: const ValueKey('sketch-g1-continuity-repair-confirm'),
                onPressed: controller.canConfirmSketchG1ContinuityRepair
                    ? _confirmSelectedG1Alternative
                    : null,
                icon: const Icon(Icons.check, size: 13),
                label: const Text('Confirmar G1'),
              ),
              const Text(
                'Disponível somente para uma alternativa G1 válida do preview atual.',
                style: TextStyle(fontSize: 8.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
