import 'package:flutter/material.dart';

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
                    Text('Tipo: ${result.type.name}'),
                    Text(
                      'Confiança: ${(result.confidence * 100).toStringAsFixed(1)}%',
                    ),
                    Text('Qualidade: ${result.quality}'),
                    for (final parameter in result.parameters.entries)
                      Text('${parameter.key}: ${parameter.value}'),
                    const SizedBox(height: 4),
                    Text('Sugestão: ${result.suggestion}'),
                    if (controller.activeSurfaceAssistantSuggestion
                        case final assistant?) ...[
                      const SizedBox(height: 6),
                      Text('Estratégia: ${assistant.strategy.name}'),
                      if (assistant.alternatives.isNotEmpty)
                        Text(
                          'Alternativas: ${assistant.alternatives.map((item) => item.name).join(', ')}',
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: assistant.canCreate && !controller.busy
                                  ? () async {
                                      try {
                                        await controller
                                            .confirmSurfaceAssistantSuggestion();
                                      } catch (_) {}
                                    }
                                  : null,
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('Criar superfície'),
                            ),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton(
                            onPressed:
                                controller.ignoreSurfaceAssistantSuggestion,
                            child: const Text('Ignorar'),
                          ),
                        ],
                      ),
                      if (!assistant.canCreate)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            result.type.name == 'freeform'
                                ? 'Advisory only in G-136.'
                                : 'Confiança abaixo do limite aprovado.',
                            style: TextStyle(
                              fontSize: 9.5,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                    const Text(
                      'Somente conhecimento · nenhuma geometria CAD criada',
                      style: TextStyle(fontSize: 9.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (controller.activeContext?.region case final region?) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Região de malha reconhecida',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text('${region.triangleIndices.length} triângulos'),
                    Text('Área ${region.area.toStringAsFixed(3)}'),
                    if (controller.hypotheses.isNotEmpty)
                      Text(
                        'Confiança ${(controller.hypotheses.first.recognition.dna.confidence * 100).toStringAsFixed(1)}%',
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
            if (controller.hypotheses.any(
              (item) => item.recognition.winner.type.name == 'plane',
            ))
              FilledButton.icon(
                onPressed: controller.busy
                    ? null
                    : () async {
                        final plane = controller.hypotheses.firstWhere(
                          (item) =>
                              item.recognition.winner.type.name == 'plane',
                        );
                        controller.decide(
                          plane.recognition.id,
                          RecognitionDecision.accepted,
                        );
                        await controller.createRecognizedPlane();
                      },
                icon: const Icon(Icons.verified_outlined),
                label: const Text('Aceitar plano e criar referência'),
              ),
            if (controller.hypotheses.any(
              (item) => item.recognition.winner.type.name != 'plane',
            ))
              FilledButton.icon(
                onPressed: controller.busy
                    ? null
                    : () async {
                        final primitive = controller.hypotheses.firstWhere(
                          (item) =>
                              item.recognition.winner.type.name != 'plane',
                        );
                        controller.decide(
                          primitive.recognition.id,
                          RecognitionDecision.accepted,
                        );
                        await controller.createRecognizedReference();
                      },
                icon: const Icon(Icons.verified_outlined),
                label: Text(
                  'Aceitar ${controller.hypotheses.firstWhere((item) => item.recognition.winner.type.name != 'plane').recognition.winner.type.name} e criar referência',
                ),
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
            if (controller.hypotheses.any(
              (item) =>
                  item.recognition.winner.type.name == 'plane' &&
                  controller.decisions[item.recognition.id] ==
                      RecognitionDecision.accepted,
            ))
              FilledButton.icon(
                onPressed: controller.busy
                    ? null
                    : controller.createRecognizedPlane,
                icon: const Icon(Icons.crop_16_9),
                label: const Text('Criar referência de plano'),
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
