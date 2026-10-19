import 'package:flutter/material.dart';

import '../../../core/recognition_engine/recognition_result.dart';
import '../../../core/surface_assistant/surface_assistant.dart';
import '../../engineering_bridge/operational_reverse_engineering_controller.dart';

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
      if (controller.busy) {
        return const Center(child: CircularProgressIndicator());
      }
      if (controller.error != null) {
        return Text(
          controller.error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
          if (controller.canDetect)
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final type in const [
                  'plane',
                  'cylinder',
                  'cone',
                  'sphere',
                  'torus',
                ])
                  ActionChip(
                    label: Text(
                      'Detectar ${type[0].toUpperCase()}${type.substring(1)}',
                    ),
                    onPressed: () => controller.detect(type),
                  ),
              ],
            )
          else
            const Text(
              'Selecione a malha na viewport para criar uma região homogênea.',
            ),
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
                    const SizedBox(height: 6),
                    _RecognitionMetric(
                      label: 'Tipo',
                      value: _recognitionTypeLabel(result.type),
                    ),
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
                      label: 'RMS',
                      value: _formatMillimeters(
                        result.parameters['rmsDeviation'],
                      ),
                    ),
                    _RecognitionMetric(
                      label: 'Desvio máximo',
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
                    _RecognitionMetric(
                      label: 'Triângulos',
                      value: _selectedTriangleCount(controller),
                    ),
                    _RecognitionMetric(
                      label: 'Área selecionada',
                      value: _selectedArea(controller, result),
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
                    if (controller.hypotheses.any(
                      (item) => item.recognition.winner.type.name == 'plane',
                    )) ...[
                      const SizedBox(height: 4),
                      FilledButton.icon(
                        onPressed:
                            controller.busy ||
                                !controller.canCreatePlaneReference
                            ? null
                            : () async {
                                final plane = controller.hypotheses.firstWhere(
                                  (item) =>
                                      item.recognition.winner.type.name ==
                                      'plane',
                                );
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
                        onPressed: controller.busy
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
                                      !controller.canCreateSurfaceFromAssistant
                                  ? null
                                  : () async {
                                      try {
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
