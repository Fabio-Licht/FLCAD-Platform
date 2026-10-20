import 'package:flutter/material.dart';

import '../../../core/geometric_recognition/models/recognition_models.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../../../core/recognition_engine/recognition_result.dart';
import '../../../core/recognition_engine/recognition_parameter_editor.dart';
import '../../../core/surface_assistant/surface_assistant.dart';
import '../../engineering_bridge/operational_reverse_engineering_controller.dart';
import '../selection/editable_surface_selection.dart';
import '../selection/surface_selection_policy.dart';

class RecognitionWorkspacePanel extends StatelessWidget {
  const RecognitionWorkspacePanel({
    super.key,
    required this.controller,
    this.onApplyAlignment,
  });
  final OperationalReverseEngineeringController controller;
  final Future<void> Function()? onApplyAlignment;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.busy) const LinearProgressIndicator(),
          if (controller.recognitionProgress case final progress?)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'Reconhecimento: ${_recognitionProgressLabel(progress['stage'])} · ${_formatMilliseconds(progress['elapsedMs'])}',
                style: const TextStyle(fontSize: 9.5),
              ),
            ),
          if (controller.error != null) _BlockReason(controller.error!),
          if (controller.recognitionDebugTrace case final trace?)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'Debug reconhecimento: ${trace['stage']}${trace['message'] == null ? '' : ' Â· ${trace['message']}'}',
                style: TextStyle(
                  fontSize: 9,
                  color: trace['stage'] == 'FAILED'
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
            ),
          if (controller.canAlign) ...[
            Text(
              'Bancada de alinhamento',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.straighten),
                  label: const Text('Eixo'),
                  onPressed: controller.createAxis,
                ),
                ActionChip(
                  avatar: const Icon(Icons.adjust),
                  label: const Text('Origem'),
                  onPressed: controller.createPoint,
                ),
                ActionChip(
                  avatar: const Icon(Icons.threed_rotation),
                  label: const Text('CSYS'),
                  onPressed: controller.createCoordinateSystem,
                ),
              ],
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'XY', label: Text('XY')),
                ButtonSegment(value: 'XZ', label: Text('XZ')),
                ButtonSegment(value: 'YZ', label: Text('YZ')),
              ],
              emptySelectionAllowed: true,
              selected: {
                if (controller.alignmentTarget != null)
                  controller.alignmentTarget!,
              },
              onSelectionChanged: (value) {
                if (value.isNotEmpty) {
                  controller.previewAlignment(value.first);
                }
              },
            ),
            if (controller.alignmentTransform != null)
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: onApplyAlignment ?? controller.applyAlignment,
                      child: const Text('Aplicar alinhamento'),
                    ),
                  ),
                  TextButton(
                    onPressed: controller.cancelAlignment,
                    child: const Text('Cancelar'),
                  ),
                ],
              ),
            const Divider(),
          ],
          if (controller.canDetect || controller.hasRecognizableMesh) ...[
            const Text(
              'Automático executa o motor multiprimitiva. Reconhecer Plano executa somente o PlaneRecognizer. '
              'Os demais chips filtram o resultado automático.',
              style: TextStyle(fontSize: 9.5),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.auto_awesome, size: 14),
                  label: const Text('Automático'),
                  onPressed: controller.busy
                      ? null
                      : () => controller.chooseRecognitionMode(null),
                ),
                ActionChip(
                  avatar: const Icon(Icons.crop_16_9, size: 14),
                  label: const Text('Reconhecer Plano'),
                  onPressed: controller.busy || !controller.hasRecognizableMesh
                      ? null
                      : () => controller.chooseRecognitionMode(
                          PrimitiveType.plane,
                        ),
                ),
                ActionChip(
                  avatar: const Icon(Icons.circle_outlined, size: 14),
                  label: const Text('Reconhecer Cilindro'),
                  onPressed: controller.busy || !controller.hasRecognizableMesh
                      ? null
                      : () => controller.chooseRecognitionMode(
                          PrimitiveType.cylinder,
                        ),
                ),
                for (final type in const [
                  'cylinder',
                  'cone',
                  'sphere',
                  'torus',
                ])
                  ActionChip(
                    label: Text('Filtrar ${_typeNameLabel(type)}'),
                    onPressed: controller.busy
                        ? null
                        : () => controller.detect(type),
                  ),
              ],
            ),
            if (controller.requestedRecognitionPrimitive != null)
              if (controller.directedRecognitionBlockReason case final reason?)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _BlockReason(reason),
                ),
            if (controller.requestedRecognitionPrimitive case final requested?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  controller.activeContext == null
                      ? 'Modo Reconhecer ${_typeNameLabel(requested.name)} ativo. Clique na parede ${_typeNameLabel(requested.name)} da STL para iniciar o reconhecimento.'
                      : 'Modo dirigido: ${_typeNameLabel(requested.name)}. Tipo obtido: ${_obtainedRecognitionTypeLabel(controller)}.',
                  style: const TextStyle(fontSize: 9.5),
                ),
              ),
            if (controller.recognitionFilter case final filter?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  controller.hasRecognitionModeMismatch
                      ? 'Filtro ${_typeNameLabel(filter)} sem correspondência. '
                            'Vencedor automático: '
                            '${_typeNameLabel(controller.automaticRecognitionWinnerType ?? '')}. '
                            'Ações CAD bloqueadas.'
                      : 'Filtro ativo: ${_typeNameLabel(filter)}. '
                            'O resultado exibido corresponde ao vencedor automático.',
                  style: TextStyle(
                    fontSize: 9.5,
                    color: controller.hasRecognitionModeMismatch
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                ),
              ),
          ] else if (!controller.hasEditableSelection &&
              !controller.hasRecognizableMesh)
            const Text(
              'Selecione a malha na viewport para criar uma região homogênea.',
            ),
          if (controller.hasEditableSelection) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Edição da região',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        ChoiceChip(
                          label: const Text('Selecionar'),
                          selected:
                              controller.selectionTool ==
                              RecognitionSelectionTool.select,
                          onSelected: (_) => controller.setSelectionTool(
                            RecognitionSelectionTool.select,
                          ),
                        ),
                        ChoiceChip(
                          label: const Text('Adicionar (clique)'),
                          selected:
                              controller.selectionTool ==
                              RecognitionSelectionTool.add,
                          onSelected: controller.selectionIsEmpty
                              ? null
                              : (_) => controller.setSelectionTool(
                                  RecognitionSelectionTool.add,
                                ),
                        ),
                        ChoiceChip(
                          label: const Text('Remover (clique)'),
                          selected:
                              controller.selectionTool ==
                              RecognitionSelectionTool.remove,
                          onSelected: controller.selectionIsEmpty
                              ? null
                              : (_) => controller.setSelectionTool(
                                  RecognitionSelectionTool.remove,
                                ),
                        ),
                        ChoiceChip(
                          label: const Text('Pincel +'),
                          selected:
                              controller.selectionTool ==
                              RecognitionSelectionTool.brushAdd,
                          onSelected: (_) => controller.setSelectionTool(
                            RecognitionSelectionTool.brushAdd,
                          ),
                        ),
                        ChoiceChip(
                          label: const Text('Pincel −'),
                          selected:
                              controller.selectionTool ==
                              RecognitionSelectionTool.brushRemove,
                          onSelected: controller.selectionIsEmpty
                              ? null
                              : (_) => controller.setSelectionTool(
                                  RecognitionSelectionTool.brushRemove,
                                ),
                        ),
                      ],
                    ),
                    const Text(
                      'Adicionar/Remover usam clique. Pincel +/− usa arraste '
                      'com o botão esquerdo.',
                      style: TextStyle(fontSize: 9.5),
                    ),
                    if (controller.brushModeActive) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Alcance do pincel',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          ChoiceChip(
                            label: const Text('Somente visível'),
                            selected:
                                controller.brushVisibility ==
                                SelectionVisibilityPolicy.visibleOnly,
                            onSelected: (_) => controller.setBrushVisibility(
                              SelectionVisibilityPolicy.visibleOnly,
                            ),
                          ),
                          ChoiceChip(
                            label: const Text('Através da malha'),
                            selected:
                                controller.brushVisibility ==
                                SelectionVisibilityPolicy.throughMesh,
                            onSelected: (_) => controller.setBrushVisibility(
                              SelectionVisibilityPolicy.throughMesh,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              key: ValueKey(
                                controller.brushDiameterMm.toStringAsFixed(1),
                              ),
                              initialValue: controller.brushDiameterMm
                                  .toStringAsFixed(1),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: const InputDecoration(
                                labelText: 'Diâmetro do pincel (mm)',
                                isDense: true,
                              ),
                              onFieldSubmitted: (value) {
                                final parsed = double.tryParse(
                                  value.replaceAll(',', '.'),
                                );
                                if (parsed != null) {
                                  controller.setBrushDiameterMm(parsed);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${controller.brushDiameterMm.toStringAsFixed(1)} mm',
                            style: const TextStyle(fontSize: 10),
                          ),
                        ],
                      ),
                      Slider(
                        value: controller.brushDiameterMm,
                        min: OperationalReverseEngineeringController
                            .minBrushDiameterMm,
                        max: OperationalReverseEngineeringController
                            .maxBrushDiameterMm,
                        divisions: 49,
                        label:
                            '${controller.brushDiameterMm.toStringAsFixed(1)} mm',
                        onChanged: controller.setBrushDiameterMm,
                      ),
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Somente superfície conectada',
                          style: TextStyle(fontSize: 10),
                        ),
                        value:
                            controller.brushConnectivity ==
                            SelectionConnectivityPolicy.connectedSurface,
                        onChanged: (value) => controller.setBrushConnectivity(
                          value == true
                              ? SelectionConnectivityPolicy.connectedSurface
                              : SelectionConnectivityPolicy.local,
                        ),
                      ),
                      if (controller.brushVisibility ==
                              SelectionVisibilityPolicy.throughMesh &&
                          controller.brushConnectivity ==
                              SelectionConnectivityPolicy.connectedSurface)
                        const Text(
                          'Através da malha + superfície conectada inclui apenas '
                          'faces ligadas topologicamente à semente. Desative a '
                          'conectividade para atingir paredes traseiras separadas.',
                          style: TextStyle(fontSize: 9.5),
                        ),
                      const Text(
                        'Somente visível respeita a oclusão da malha. '
                        'Através da malha inclui faces ocultas dentro do volume '
                        'do pincel. O diâmetro é aplicado em milímetros na '
                        'geometria original, não em pixels.',
                        style: TextStyle(fontSize: 9.5),
                      ),
                      if (controller.brushStrokeActive)
                        const Text(
                          'Pintando…',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        OutlinedButton(
                          onPressed:
                              controller.busy || controller.selectionIsEmpty
                              ? null
                              : controller.expandRecognitionSelection,
                          child: const Text('Expandir'),
                        ),
                        OutlinedButton(
                          onPressed:
                              controller.busy || controller.selectionIsEmpty
                              ? null
                              : controller.contractRecognitionSelection,
                          child: const Text('Contrair'),
                        ),
                        OutlinedButton(
                          onPressed:
                              controller.busy ||
                                  !(controller.selectionIsEdited ||
                                      controller.selectionIsEmpty)
                              ? null
                              : controller.restoreAutomaticRecognitionSelection,
                          child: const Text('Restaurar automática'),
                        ),
                        OutlinedButton(
                          onPressed:
                              controller.busy ||
                                  !controller.canUndoSelectionEdit
                              ? null
                              : controller.undoRecognitionSelection,
                          child: const Text('Desfazer seleção'),
                        ),
                        OutlinedButton(
                          onPressed:
                              controller.busy ||
                                  !controller.canRedoSelectionEdit
                              ? null
                              : controller.redoRecognitionSelection,
                          child: const Text('Refazer seleção'),
                        ),
                        TextButton(
                          onPressed: controller.clearRecognitionSelection,
                          child: const Text('Limpar seleção'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Triângulos selecionados: '
                      '${controller.selectionTriangleCount} · '
                      'Área: ${controller.selectionArea.toStringAsFixed(3)} mm²',
                      style: const TextStyle(fontSize: 10),
                    ),
                    if (controller.selectionIsEdited)
                      Text(
                        'Região editada · revisão ${controller.selectionRevision}',
                        style: const TextStyle(fontSize: 9.5),
                      ),
                    if (controller.lastSelectionAdded > 0)
                      Text(
                        'Adicionados: ${controller.lastSelectionAdded} triângulos',
                        style: const TextStyle(fontSize: 9.5),
                      ),
                    if (controller.lastSelectionRemoved > 0)
                      Text(
                        'Removidos: ${controller.lastSelectionRemoved} triângulos',
                        style: const TextStyle(fontSize: 9.5),
                      ),
                    if (controller.selectionIsEmpty)
                      const _BlockReason(
                        'Seleção vazia. Restaure a região automática ou limpe a seleção.',
                      ),
                    if (controller.selectionDiagnostic case final reason?)
                      _BlockReason(reason),
                  ],
                ),
              ),
            ),
          ],
          if (controller.activeRecognitionResult case final result?) ...[
            const SizedBox(height: 8),
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reconhecimento',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (controller.isActiveRecognitionDiagnosticOnly)
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          'Diagnóstico · criação CAD bloqueada',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(height: 6),
                    if (controller.requestedRecognitionPrimitive
                        case final requested?)
                      _RecognitionMetric(
                        label: 'Tipo solicitado',
                        value: _typeNameLabel(requested.name),
                      ),
                    _RecognitionMetric(
                      label: 'Tipo',
                      value: _recognitionTypeLabel(result.type),
                    ),
                    if (result.type == RecognitionResultType.cylinder) ...[
                      _RecognitionMetric(
                        label: 'Origem do eixo',
                        value: _formatParameterValue(
                          result.parameters['origin'],
                        ),
                      ),
                      _RecognitionMetric(
                        label: 'Direção do eixo',
                        value: _formatParameterValue(result.parameters['axis']),
                      ),
                      _RecognitionMetric(
                        label: 'Raio',
                        value: _formatMillimeters(result.parameters['radius']),
                      ),
                      _RecognitionMetric(
                        label: 'Diâmetro',
                        value: _formatMillimeters(
                          result.parameters['diameter'],
                        ),
                      ),
                      _RecognitionMetric(
                        label: 'Comprimento axial observado',
                        value: _formatMillimeters(result.parameters['length']),
                      ),
                      _RecognitionMetric(
                        label: 'Cobertura de inliers',
                        value: _formatPercent(
                          result.parameters['inlierCoverage'],
                        ),
                      ),
                      _RecognitionMetric(
                        label: 'Cobertura angular real',
                        value:
                            result.parameters['angularCoverageDegrees'] is num
                            ? '${(result.parameters['angularCoverageDegrees'] as num).toStringAsFixed(1)}°'
                            : '—',
                      ),
                      _RecognitionMetric(
                        label: 'Estabilidade do eixo',
                        value: _formatPercent(
                          result.parameters['axisStability'],
                        ),
                      ),
                      _RecognitionMetric(
                        label: 'Condicionamento',
                        value: result.parameters['conditioning'] is num
                            ? (result.parameters['conditioning'] as num)
                                  .toStringAsFixed(3)
                            : '—',
                      ),
                      _RecognitionMetric(
                        label: 'Pontos',
                        value: '${result.parameters['pointCount'] ?? '—'}',
                      ),
                    ],
                    _RecognitionMetric(
                      label: 'Classificação geométrica',
                      value: result.type == RecognitionResultType.plane
                          ? _classificationLabel(
                              result.parameters['planarClassification'],
                            )
                          : 'Não aplicável a este tipo',
                    ),
                    _RecognitionMetric(
                      label: 'Confiança',
                      value: '${(result.confidence * 100).toStringAsFixed(1)}%',
                    ),
                    _RecognitionMetric(
                      label: result.type == RecognitionResultType.cylinder
                          ? 'RMS radial'
                          : 'RMS',
                      value: _formatMillimeters(
                        result.parameters['rmsDeviation'],
                      ),
                    ),
                    _RecognitionMetric(
                      label: result.type == RecognitionResultType.cylinder
                          ? 'Desvio máximo radial'
                          : 'Desvio máximo',
                      value: _formatMillimeters(
                        result.parameters['maximumDeviation'],
                      ),
                    ),
                    if (result.type == RecognitionResultType.plane)
                      _RecognitionMetric(
                        label: 'Tolerância planar',
                        value: _formatMillimeters(
                          _recognitionTolerance(controller, result),
                        ),
                      ),
                    _RecognitionMetric(
                      label: 'Status dimensional',
                      value: _dimensionalStatusLabel(
                        result.parameters['dimensionalStatus'],
                      ),
                      color:
                          result.parameters['dimensionalStatus'] == 'rejected'
                          ? Theme.of(context).colorScheme.error
                          : result.parameters['dimensionalStatus'] ==
                                'diagnostic-only'
                          ? Colors.amber.shade800
                          : null,
                    ),
                    if (result.type == RecognitionResultType.cylinder)
                      _RecognitionMetric(
                        label: 'Qualidade do ajuste',
                        value: _cylinderQualityLabel(
                          result.parameters['qualityStatus'],
                        ),
                      ),
                    _RecognitionMetric(
                      label: 'Triângulos',
                      value: _selectedTriangleCount(controller),
                    ),
                    _RecognitionMetric(
                      label: 'Área selecionada',
                      value: _selectedArea(controller, result),
                    ),
                    if (result.parameters['selectionComponentCount'] is num &&
                        (result.parameters['selectionComponentCount'] as num) >
                            1)
                      _RecognitionMetric(
                        label: 'Componentes desconectados',
                        value:
                            '${result.parameters['selectionComponentCount']}',
                        color: Colors.amber.shade800,
                      ),
                    if (result.parameters['dimensionalReason']
                        case final String reason)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          reason,
                          style: const TextStyle(fontSize: 9.5),
                        ),
                      ),
                    if (result.type == RecognitionResultType.plane)
                      if (result.parameters['planarClassificationReason']
                          case final String classificationReason)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            classificationReason,
                            style: const TextStyle(fontSize: 9.5),
                          ),
                        ),
                    if (controller.isActiveRecognitionDiagnosticOnly)
                      if (result.parameters['diagnosticReason']
                          case final String reason)
                        _BlockReason(reason),
                    if (result.type == RecognitionResultType.cylinder &&
                        controller.cylinderParameterEditor != null)
                      _CylinderParameterEditorCard(controller: controller),
                    if (result.type == RecognitionResultType.plane) ...[
                      const SizedBox(height: 6),
                      TextFormField(
                        initialValue: _recognitionTolerance(
                          controller,
                          result,
                        ).toString(),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Tolerância planar (mm)',
                          isDense: true,
                        ),
                        onFieldSubmitted: (value) {
                          final parsed = double.tryParse(
                            value.replaceAll(',', '.'),
                          );
                          if (parsed != null) {
                            controller.planarToleranceMm = parsed;
                          }
                        },
                      ),
                    ],
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: controller.busy
                          ? null
                          : controller.previewActiveRecognition,
                      icon: const Icon(Icons.visibility_outlined, size: 16),
                      label: const Text('Pré-visualizar diagnóstico'),
                    ),
                    if (result.type == RecognitionResultType.plane &&
                        controller.activeSurfaceAssistantSuggestion ==
                            null) ...[
                      const SizedBox(height: 4),
                      FilledButton.icon(
                        onPressed:
                            controller.busy ||
                                !controller.canOpenSurfaceCreation
                            ? null
                            : controller.previewActiveRecognition,
                        icon: const Icon(Icons.layers_outlined, size: 16),
                        label: const Text('Criar superfÃ­cie'),
                      ),
                      if (!controller.canOpenSurfaceCreation)
                        if (controller.surfaceCreationEntryBlockReason
                            case final reason?)
                          _BlockReason(reason),
                    ],
                    if (controller.hypotheses.any(
                      (item) => item.recognition.winner.type.name == 'plane',
                    )) ...[
                      const SizedBox(height: 4),
                      FilledButton.icon(
                        onPressed:
                            controller.busy ||
                                (!controller.canCreatePlaneReference &&
                                    !controller
                                        .canRequestManualPlaneReferenceAction)
                            ? null
                            : () async {
                                final plane = controller.hypotheses.firstWhere(
                                  (item) =>
                                      item.recognition.winner.type.name ==
                                      'plane',
                                );
                                if (controller
                                        .canRequestManualPlaneReferenceAction &&
                                    !controller.canCreatePlaneReference) {
                                  final confirmed =
                                      await showDialog<bool>(
                                        context: context,
                                        builder: (dialogContext) => AlertDialog(
                                          title: const Text(
                                            'Confirmar criação manual',
                                          ),
                                          content: Text(
                                            'A região excede os critérios recomendados para ajuste planar.\n\n'
                                            'RMS: ${_formatMillimeters(plane.recognition.winner.statistics.rms)}\n'
                                            'Máximo: ${_formatMillimeters(plane.recognition.winner.statistics.maximum)}\n'
                                            'Tolerância: ${_formatMillimeters(controller.planarToleranceMm)}\n'
                                            'Confiança: ${(plane.recognition.dna.confidence * 100).toStringAsFixed(1)}%\n'
                                            'Classificação: ${_classificationLabel(controller.activeRecognitionResult?.parameters['planarClassification'])}\n\n'
                                            'A geometria será criada por decisão manual, mantendo os desvios registrados.',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(
                                                dialogContext,
                                                false,
                                              ),
                                              child: const Text('Cancelar'),
                                            ),
                                            FilledButton(
                                              onPressed: () => Navigator.pop(
                                                dialogContext,
                                                true,
                                              ),
                                              child: const Text('Confirmar'),
                                            ),
                                          ],
                                        ),
                                      ) ??
                                      false;
                                  if (!confirmed) return;
                                  controller.prepareManualRecognitionApproval(
                                    'reference',
                                  );
                                }
                                controller.decide(
                                  plane.recognition.id,
                                  RecognitionDecision.accepted,
                                );
                                await controller.createRecognizedPlane();
                              },
                        icon: const Icon(Icons.verified_outlined, size: 16),
                        label: const Text('Aceitar plano e criar referência'),
                      ),
                      if (controller.planeReferenceBlockReason
                          case final reason?)
                        _BlockReason(reason),
                    ],
                    if (controller.hypotheses.any(
                      (item) => item.recognition.winner.type.name != 'plane',
                    )) ...[
                      const SizedBox(height: 4),
                      FilledButton.icon(
                        onPressed:
                            controller.busy ||
                                !controller.canCreateNonPlaneReference
                            ? null
                            : () async {
                                final primitive = controller.hypotheses
                                    .firstWhere(
                                      (item) =>
                                          item.recognition.winner.type.name !=
                                          'plane',
                                    );
                                controller.decide(
                                  primitive.recognition.id,
                                  RecognitionDecision.accepted,
                                );
                                await controller.createRecognizedReference();
                              },
                        icon: const Icon(Icons.verified_outlined, size: 16),
                        label: Text(
                          'Aceitar ${_primitiveTypeLabel(_firstNonPlaneType(controller))} e criar referência',
                        ),
                      ),
                      if (controller.nonPlaneReferenceBlockReason
                          case final reason?)
                        _BlockReason(reason),
                    ],
                    if (controller.activeSurfaceAssistantSuggestion
                        case final assistant?) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Superfície sugerida: ${_strategyLabel(assistant.strategy)}',
                        style: const TextStyle(fontSize: 10),
                      ),
                      if (assistant.alternatives.isNotEmpty)
                        Text(
                          'Alternativas: ${assistant.alternatives.map(_strategyLabel).join(', ')}',
                          style: const TextStyle(fontSize: 9.5),
                        ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed:
                                  controller.busy ||
                                      (!controller
                                              .canCreateSurfaceFromAssistant &&
                                          !controller
                                              .canRequestManualSurfaceAction)
                                  ? null
                                  : () async {
                                      try {
                                        if (controller
                                                .canRequestManualSurfaceAction &&
                                            !controller
                                                .canCreateSurfaceFromAssistant) {
                                          final confirmed =
                                              await showDialog<bool>(
                                                context: context,
                                                builder: (dialogContext) =>
                                                    AlertDialog(
                                                      title: const Text(
                                                        'Confirmar criação manual',
                                                      ),
                                                      content: const Text(
                                                        'A região excede os critérios recomendados para superfície planar. Você pode criar a geometria por decisão explícita, mantendo os desvios registrados.',
                                                      ),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                dialogContext,
                                                                false,
                                                              ),
                                                          child: const Text(
                                                            'Cancelar',
                                                          ),
                                                        ),
                                                        FilledButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                dialogContext,
                                                                true,
                                                              ),
                                                          child: const Text(
                                                            'Confirmar',
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                              ) ??
                                              false;
                                          if (!confirmed) return;
                                          controller
                                              .prepareManualRecognitionApproval(
                                                'surface',
                                              );
                                        }
                                        await controller
                                            .confirmSurfaceAssistantSuggestion();
                                      } catch (_) {}
                                    },
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('Criar superfície'),
                            ),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton(
                            onPressed:
                                controller.ignoreSurfaceAssistantSuggestion,
                            child: const Text('Cancelar'),
                          ),
                        ],
                      ),
                      if (controller.surfaceCreationBlockReason
                          case final reason?)
                        _BlockReason(reason),
                    ],
                    const SizedBox(height: 4),
                    ExpansionTile(
                      dense: true,
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: const Text(
                        'Detalhes avançados',
                        style: TextStyle(fontSize: 10.5),
                      ),
                      children: [
                        for (final parameter in _advancedParameters(
                          result.parameters,
                        ))
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '${_parameterLabel(parameter.key)}: ${_formatParameterValue(parameter.value)}',
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Qualidade: ${result.quality}',
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Sugestão: ${result.suggestion}',
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      ],
                    ),
                    const Text(
                      'Somente conhecimento · nenhuma geometria CAD criada',
                      style: TextStyle(fontSize: 9.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (controller.activeRecognitionResult == null &&
              controller.recognitionDiagnostic != null) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Diagnóstico de reconhecimento dirigido',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      'Tipo solicitado: '
                      '${_typeNameLabel(controller.recognitionDiagnostic!['requestedPrimitiveType']?.toString() ?? '')}',
                    ),
                    Text(
                      'Tipo obtido: '
                      '${_obtainedRecognitionTypeLabel(controller)}',
                    ),
                    if (controller.recognitionDiagnostic!['rmsDeviation']
                        case final num rms)
                      Text('RMS: ${_formatMillimeters(rms)}'),
                    if (controller.recognitionDiagnostic!['maximumDeviation']
                        case final num maximum)
                      Text('Desvio máximo: ${_formatMillimeters(maximum)}'),
                    if (controller.recognitionDiagnostic!['reason']
                        case final String reason)
                      _BlockReason(reason),
                    const Text(
                      'Sem ajuste suficiente para Preview ou criação CAD.',
                      style: TextStyle(fontSize: 9.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (controller.hypotheses.isEmpty && controller.canDetect) ...[
            const SizedBox(height: 8),
            const Text('Nenhuma hipótese do tipo selecionado foi detectada.'),
          ],
          if (controller.hypotheses.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${controller.hypotheses.length} hipóteses',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            for (final primitive in controller.hypotheses)
              Card(
                child: ExpansionTile(
                  title: Text(primitive.recognition.winner.type.name),
                  subtitle: Text(
                    'Confiança ${(primitive.recognition.dna.confidence * 100).toStringAsFixed(1)}% · Pontuação ${(primitive.recognition.explanation.score * 100).toStringAsFixed(1)}%',
                  ),
                  childrenPadding: const EdgeInsets.all(12),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(primitive.recognition.explanation.why),
                    ),
                    for (final evidence
                        in primitive.recognition.explanation.evidence)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '• ${evidence.description}: ${evidence.value.toStringAsFixed(4)}',
                        ),
                      ),
                    if (primitive.recognition.alternatives.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Alternativas: ${primitive.recognition.alternatives.map((item) => item.type.name).join(', ')}',
                        ),
                      ),
                    SegmentedButton<RecognitionDecision>(
                      segments: const [
                        ButtonSegment(
                          value: RecognitionDecision.pending,
                          label: Text('Pendente'),
                        ),
                        ButtonSegment(
                          value: RecognitionDecision.accepted,
                          label: Text('Aceitar'),
                        ),
                        ButtonSegment(
                          value: RecognitionDecision.rejected,
                          label: Text('Rejeitar'),
                        ),
                      ],
                      selected: {
                        controller.decisions[primitive.recognition.id] ??
                            RecognitionDecision.pending,
                      },
                      onSelectionChanged: (value) => controller.decide(
                        primitive.recognition.id,
                        value.first,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (controller.canAlign) ...[
            const Divider(),
            Text(
              'Bancada de alinhamento',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const Text(
              'Crie o eixo, a origem e o sistema de coordenadas a partir do plano aprovado.',
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  onPressed: controller.createAxis,
                  icon: const Icon(Icons.straighten),
                  label: const Text('Criar eixo'),
                ),
                OutlinedButton.icon(
                  onPressed: controller.createPoint,
                  icon: const Icon(Icons.adjust),
                  label: const Text('Criar origem'),
                ),
                OutlinedButton.icon(
                  onPressed: controller.createCoordinateSystem,
                  icon: const Icon(Icons.threed_rotation),
                  label: const Text('Criar sistema de coordenadas'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Alinhar plano aprovado a:'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'XY', label: Text('XY')),
                ButtonSegment(value: 'XZ', label: Text('XZ')),
                ButtonSegment(value: 'YZ', label: Text('YZ')),
              ],
              emptySelectionAllowed: true,
              selected: {
                if (controller.alignmentTarget != null)
                  controller.alignmentTarget!,
              },
              onSelectionChanged: (value) {
                if (value.isNotEmpty) controller.previewAlignment(value.first);
              },
            ),
            if (controller.alignmentTransform != null)
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: controller.busy
                          ? null
                          : (onApplyAlignment ?? controller.applyAlignment),
                      icon: const Icon(Icons.check),
                      label: const Text('Aplicar alinhamento'),
                    ),
                  ),
                  TextButton(
                    onPressed: controller.cancelAlignment,
                    child: const Text('Cancelar'),
                  ),
                ],
              ),
          ],
        ],
      );
    },
  );
}

String _recognitionProgressLabel(dynamic stage) => switch (stage) {
  'picking' => 'preparando seleção',
  'selecting-region' => 'selecionando região cilíndrica',
  'region-selected' => 'região selecionada',
  'region-visible' => 'seleção publicada',
  'fitting' => 'ajustando geometria',
  'calculating-diagnostics' => 'calculando diagnósticos',
  'publishing-result' => 'publicando resultado',
  'completed' => 'concluído',
  'failed' => 'falhou',
  _ => stage?.toString() ?? 'aguardando',
};

String _formatMilliseconds(dynamic value) =>
    value is num ? '${value.toDouble().toStringAsFixed(0)} ms' : '—';

class _CylinderParameterEditorCard extends StatelessWidget {
  const _CylinderParameterEditorCard({required this.controller});

  final OperationalReverseEngineeringController controller;

  @override
  Widget build(BuildContext context) {
    final editor = controller.cylinderParameterEditor!;
    final target = editor.target;
    final measured = editor.measured.parameters;
    final frames = controller.cylinderEditorFrames;
    final axisOptions = <String>[
      'recognized',
      for (final frame in frames)
        for (final axis in const ['X', 'Y', 'Z']) '${frame.id}:$axis',
    ];
    final selectedAxis = axisOptions.contains(target.axisSource)
        ? target.axisSource
        : null;
    final inverted = target.axis.dot(_editorVector(measured['axis'])) < 0;
    final error = controller.cylinderParameterEditorError;
    return Card(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, left: 8, right: 8, bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Editor paramétrico · cilindro',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const Text(
              'MEDIDO permanece imutável. CORRIGIDO altera somente o preview transitório.',
              style: TextStyle(fontSize: 9.5),
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: ValueKey('diameter-${target.diameter}'),
                    initialValue: target.diameter.toStringAsFixed(6),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Diâmetro corrigido (mm)',
                      isDense: true,
                    ),
                    onChanged: controller.setCylinderDiameterDraft,
                    onFieldSubmitted:
                        controller.setCylinderTargetDiameterFromText,
                    onTapOutside: (_) =>
                        controller.commitCylinderParameterDrafts(),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('radius-${target.diameter}'),
                    initialValue: (target.diameter / 2).toStringAsFixed(6),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Raio equivalente (mm)',
                      isDense: true,
                    ),
                    onChanged: controller.setCylinderRadiusDraft,
                    onFieldSubmitted:
                        controller.setCylinderTargetRadiusFromText,
                    onTapOutside: (_) =>
                        controller.commitCylinderParameterDrafts(),
                  ),
                ),
              ],
            ),
            if (error case final value?) _BlockReason(value),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              key: ValueKey('axis-${target.axisSource}'),
              initialValue: selectedAxis,
              isExpanded: true,
              isDense: true,
              decoration: const InputDecoration(
                labelText: 'Orientação do eixo',
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(
                  value: 'recognized',
                  child: Text(
                    'Manter direção reconhecida',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                for (final frame in frames)
                  for (final axis in const ['X', 'Y', 'Z'])
                    DropdownMenuItem(
                      value: '${frame.id}:$axis',
                      child: Text(
                        '${frame.label} · eixo $axis',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
              ],
              onChanged: (value) {
                if (value != null) controller.setCylinderAxisAlignment(value);
              },
            ),
            const SizedBox(height: 4),
            TextFormField(
              key: ValueKey('manual-axis-${target.axis.toJson()}'),
              initialValue: target.axis.toJson().join(', '),
              decoration: const InputDecoration(
                labelText: 'Direção manual (X, Y, Z)',
                isDense: true,
              ),
              onChanged: controller.setCylinderManualAxisDraft,
              onFieldSubmitted: controller.setCylinderManualAxisFromText,
              onTapOutside: (_) => controller.commitCylinderParameterDrafts(),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Inverter sentido do eixo',
                style: TextStyle(fontSize: 10),
              ),
              value: inverted,
              onChanged: (value) =>
                  controller.setCylinderAxisInverted(value == true),
            ),
            Text(
              'Âncora: ponto central reconhecido · origem preservada ao alinhar.',
              style: TextStyle(
                fontSize: 9.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            TextFormField(
              key: ValueKey('origin-${target.origin.toJson()}'),
              initialValue: target.origin.toJson().join(', '),
              decoration: const InputDecoration(
                labelText: 'Origem do eixo corrigida (X, Y, Z mm)',
                isDense: true,
              ),
              onChanged: controller.setCylinderOriginDraft,
              onFieldSubmitted: controller.setCylinderTargetOriginFromText,
              onTapOutside: (_) => controller.commitCylinderParameterDrafts(),
            ),
            if (controller.cylinderParameterEditorDraftPending)
              const _BlockReason(
                'EdiÃ§Ã£o pendente: confirme o campo ou use Confirmar parÃ¢metros para aplicar o texto.',
              ),
            const SizedBox(height: 5),
            _RecognitionMetric(
              label: 'MEDIDO · diâmetro',
              value: _formatMillimeters(
                measured['diameter'] ?? measured['radius'],
              ),
            ),
            _RecognitionMetric(
              label: 'CORRIGIDO · diâmetro',
              value: _formatMillimeters(target.diameter),
            ),
            _RecognitionMetric(
              label: 'CORRIGIDO · RMS radial',
              value: _formatMillimeters(editor.metrics.rms),
            ),
            _RecognitionMetric(
              label: 'CORRIGIDO · desvio máximo',
              value: _formatMillimeters(editor.metrics.maximum),
            ),
            _RecognitionMetric(
              label: 'Diferença dimensional',
              value: _formatMillimeters(editor.metrics.diameterDelta),
            ),
            if (controller.cylinderParameterEditorStale)
              const _BlockReason(
                'Seleção ou malha alterada. O preview e a confirmação foram bloqueados.',
              ),
            if (editor.state == RecognitionParameterEditorState.confirmed)
              const Text(
                'Parâmetros confirmados como estado transitório; nenhuma BRep foi criada.',
                style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600),
              ),
            const SizedBox(height: 5),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                OutlinedButton(
                  onPressed: controller.resetCylinderParameterEditing,
                  child: const Text('Reset reconhecido'),
                ),
                TextButton(
                  onPressed: controller.cancelCylinderParameterEditing,
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed:
                      controller.cylinderParameterEditorStale ||
                          controller.cylinderParameterEditorError != null
                      ? null
                      : controller.confirmCylinderParameterEditing,
                  child: const Text('Confirmar parâmetros'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Vector3 _editorVector(dynamic value) =>
    value is List && value.length == 3 && value.every((item) => item is num)
    ? Vector3.fromJson(value)
    : Vector3.zero;

class _RecognitionMetric extends StatelessWidget {
  const _RecognitionMetric({
    required this.label,
    required this.value,
    this.color,
  });

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );
}

class _BlockReason extends StatelessWidget {
  const _BlockReason(this.reason);

  final String reason;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      reason,
      style: TextStyle(
        fontSize: 9.5,
        color: Theme.of(context).colorScheme.error,
      ),
    ),
  );
}

String _recognitionTypeLabel(RecognitionResultType type) => switch (type) {
  RecognitionResultType.plane => 'Plano',
  RecognitionResultType.cylinder => 'Cilindro',
  RecognitionResultType.cone => 'Cone',
  RecognitionResultType.sphere => 'Esfera',
  RecognitionResultType.fillet => 'Toro',
  RecognitionResultType.freeform => 'Livre',
};

String _primitiveTypeLabel(String name) => switch (name) {
  'plane' => 'plano',
  'cylinder' => 'cilindro',
  'cone' => 'cone',
  'sphere' => 'esfera',
  'torus' => 'toro',
  _ => name,
};

String _typeNameLabel(String name) => switch (name) {
  'plane' => 'Plano',
  'cylinder' => 'Cilindro',
  'cone' => 'Cone',
  'sphere' => 'Esfera',
  'torus' => 'Toro',
  '' => 'nenhum',
  _ => name,
};

String _obtainedRecognitionTypeLabel(
  OperationalReverseEngineeringController controller,
) {
  final active = controller.activeRecognitionResult;
  if (active != null) return _recognitionTypeLabel(active.type);
  final diagnosticType = controller.recognitionDiagnostic?['primitiveType'];
  if (diagnosticType is String) return _typeNameLabel(diagnosticType);
  final winner = controller.report?.primitives.firstOrNull?.recognition.winner;
  return winner == null ? 'nenhum' : _typeNameLabel(winner.type.name);
}

String _firstNonPlaneType(OperationalReverseEngineeringController controller) {
  for (final item in controller.hypotheses) {
    if (item.recognition.winner.type.name != 'plane') {
      return item.recognition.winner.type.name;
    }
  }
  return '';
}

String _classificationLabel(Object? classification) => switch (classification) {
  null => 'Não classificada',
  'localReference' => 'Referência local',
  'planarCadCandidate' => 'Candidato a superfície planar CAD',
  'curvedPatch' => 'Trecho de superfície curva',
  'ambiguous' => 'Ambígua',
  _ => '$classification',
};

String _dimensionalStatusLabel(Object? status) => switch (status) {
  'approved' => 'Aprovada',
  'rejected' => 'Reprovada',
  'diagnostic-only' => 'Somente diagnóstico',
  'not-applicable' => 'Não aplicável',
  _ => 'Não aplicável',
};

String _cylinderQualityLabel(Object? status) => switch (status) {
  'reliable' => 'Ajuste confiável',
  'conditioned' => 'Ajuste condicionado',
  'insufficient-angular-coverage' => 'Cobertura insuficiente',
  'high-residuals' => 'Resíduos elevados',
  'ill-conditioned' => 'Mal condicionado',
  'convergence-failed' => 'Falha de convergência',
  _ => 'Não avaliado',
};

String _strategyLabel(SurfaceAssistantStrategy strategy) => switch (strategy) {
  SurfaceAssistantStrategy.planarSurface => 'superfície planar',
  SurfaceAssistantStrategy.cylindricalSurface => 'superfície cilíndrica',
  SurfaceAssistantStrategy.conicalSurface => 'superfície cônica',
  SurfaceAssistantStrategy.sphericalSurface => 'superfície esférica',
  SurfaceAssistantStrategy.filletSurface => 'superfície de filete',
  SurfaceAssistantStrategy.freeSurface => 'superfície livre',
  SurfaceAssistantStrategy.loft => 'loft',
  SurfaceAssistantStrategy.sweep => 'varredura',
  SurfaceAssistantStrategy.networkSurface => 'superfície de rede',
};

double _recognitionTolerance(
  OperationalReverseEngineeringController controller,
  RecognitionResult result,
) =>
    (result.parameters['dimensionalToleranceMm'] as num?)?.toDouble() ??
    controller.planarToleranceMm;

String _selectedTriangleCount(
  OperationalReverseEngineeringController controller,
) {
  final region = controller.activeContext?.region;
  return region == null ? '—' : '${region.triangleIndices.length}';
}

String _selectedArea(
  OperationalReverseEngineeringController controller,
  RecognitionResult result,
) {
  final region = controller.activeContext?.region;
  final area = region?.area ?? (result.parameters['area'] as num?)?.toDouble();
  return area == null ? '—' : '${area.toStringAsFixed(3)} mm²';
}

String _formatMillimeters(Object? value) =>
    value is num ? '${value.toStringAsFixed(3)} mm' : '—';

String _formatPercent(Object? value) =>
    value is num ? '${(value * 100).toStringAsFixed(1)}%' : '—';

List<MapEntry<String, dynamic>> _advancedParameters(
  Map<String, dynamic> parameters,
) {
  const summaryKeys = {
    'rmsDeviation',
    'maximumDeviation',
    'dimensionalToleranceMm',
    'dimensionalStatus',
    'dimensionalApproved',
    'dimensionalReason',
    'planarClassification',
    'referenceApproved',
    'cadSurfaceApproved',
    'area',
  };
  const orderedKeys = [
    'origin',
    'normal',
    'center',
    'axis',
    'axisDirection',
    'radius',
    'diameter',
    'length',
    'angularCoverageDegrees',
    'inlierCoverage',
    'inlierCount',
    'conditioning',
    'axisStability',
    'qualityStatus',
    'angleDegrees',
    'planarClassificationReason',
    'pointCount',
  ];
  final entries = <MapEntry<String, dynamic>>[];
  final included = <String>{};
  for (final key in orderedKeys) {
    final value = parameters[key];
    if (value != null) {
      entries.add(MapEntry(key, value));
      included.add(key);
    }
  }
  for (final entry in parameters.entries) {
    if (summaryKeys.contains(entry.key) || included.contains(entry.key)) {
      continue;
    }
    entries.add(entry);
  }
  return entries;
}

String _parameterLabel(String key) => switch (key) {
  'origin' => 'Origem',
  'normal' => 'Normal',
  'center' => 'Centro',
  'axis' => 'Eixo',
  'axisDirection' => 'Direção do eixo',
  'radius' => 'Raio',
  'diameter' => 'Diâmetro',
  'length' => 'Comprimento',
  'angleDegrees' => 'Ângulo',
  'planarClassificationReason' => 'Motivo da classificação',
  'pointCount' => 'Pontos',
  'meanRadius' => 'Raio médio',
  'minimumRadius' => 'Raio mínimo',
  'maximumRadius' => 'Raio máximo',
  'minorRadius' => 'Raio menor',
  'referenceRadius' => 'Raio de referência',
  'halfAngle' => 'Meio ângulo',
  _ => key,
};

String _formatParameterValue(Object? value) {
  if (value is num) return value.toStringAsFixed(3);
  if (value is List) {
    return '(${value.map((item) => item is num ? item.toStringAsFixed(3) : '$item').join(', ')})';
  }
  return '$value';
}
