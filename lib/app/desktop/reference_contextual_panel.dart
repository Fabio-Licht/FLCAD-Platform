import 'package:flutter/material.dart';

import 'reference_context_presentation.dart';

/// Compact presentation for one existing Reference operation.
///
/// The panel owns no operation state. All mutations are delegated to the
/// callbacks supplied by the existing Reference controller/panel.
final class ReferenceContextualPanel extends StatelessWidget {
  const ReferenceContextualPanel({
    required this.presentation,
    required this.onChoosePlane,
    required this.onPickPlane,
    required this.onChooseAxis,
    required this.onPickAxis,
    required this.onPreview,
    required this.onApply,
    required this.onCancel,
    required this.onShowDetailed,
    super.key,
  });

  final ReferenceContextPresentation presentation;
  final ValueChanged<String?> onChoosePlane;
  final VoidCallback onPickPlane;
  final ValueChanged<String?> onChooseAxis;
  final VoidCallback onPickAxis;
  final VoidCallback onPreview;
  final VoidCallback onApply;
  final VoidCallback onCancel;
  final VoidCallback onShowDetailed;

  String get _phaseLabel => switch (presentation.phase) {
    ReferenceContextPhase.idle => 'Aguardando seleção',
    ReferenceContextPhase.configuring => 'Configurando',
    ReferenceContextPhase.previewing => 'Prévia ativa',
    ReferenceContextPhase.error => 'Não disponível',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final disabled = presentation.phase == ReferenceContextPhase.error;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.control_point_duplicate_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    presentation.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  _phaseLabel,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: presentation.planeId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Plano'),
              hint: const Text('Selecione o plano'),
              items: [
                for (final option in presentation.planeOptions)
                  DropdownMenuItem(value: option.id, child: Text(option.label)),
              ],
              onChanged: disabled ? null : onChoosePlane,
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: disabled ? null : onPickPlane,
              icon: const Icon(Icons.ads_click_outlined, size: 17),
              label: Text(
                presentation.activeSlot == 'plane'
                    ? 'Selecionando plano na viewport…'
                    : 'Selecionar plano na viewport',
              ),
            ),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: presentation.axisId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Eixo'),
              hint: const Text('Selecione o eixo'),
              items: [
                for (final option in presentation.axisOptions)
                  DropdownMenuItem(value: option.id, child: Text(option.label)),
              ],
              onChanged: disabled ? null : onChooseAxis,
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: disabled ? null : onPickAxis,
              icon: const Icon(Icons.ads_click_outlined, size: 17),
              label: Text(
                presentation.activeSlot == 'axis'
                    ? 'Selecionando eixo na viewport…'
                    : 'Selecionar eixo na viewport',
              ),
            ),
            if (presentation.diagnostic != null) ...[
              const SizedBox(height: 6),
              Text(
                presentation.diagnostic!,
                style: TextStyle(color: colors.error, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton(
                  onPressed: presentation.canCancel ? onCancel : null,
                  child: const Text('Cancelar'),
                ),
                OutlinedButton(
                  onPressed: presentation.canPreview ? onPreview : null,
                  child: const Text('Prévia'),
                ),
                FilledButton(
                  onPressed: presentation.canApply ? onApply : null,
                  child: const Text('Aplicar'),
                ),
                TextButton(
                  onPressed: onShowDetailed,
                  child: const Text('Editor detalhado'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
