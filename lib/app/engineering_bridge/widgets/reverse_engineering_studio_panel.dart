import 'package:flutter/material.dart';

import '../../../core/reverse_engineering_studio/reverse_engineering_studio.dart';
import '../../../core/surface_reconstruction_manager/surface_reconstruction_manager.dart';

class ReverseEngineeringStudioPanel extends StatelessWidget {
  const ReverseEngineeringStudioPanel({
    super.key,
    required this.state,
    required this.reconstruction,
    required this.onOpenNext,
    required this.onRegionSelected,
    required this.onRegionIgnored,
  });

  final ReverseEngineeringStudioState state;
  final SurfaceReconstructionState reconstruction;
  final VoidCallback onOpenNext;
  final ValueChanged<String> onRegionSelected;
  final void Function(String id, bool ignored) onRegionIgnored;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          const Icon(Icons.account_tree_outlined, size: 18),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              'Fluxo de engenharia reversa',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      for (final mesh in reconstruction.meshes) ...[
        _CoverageCard(mesh: mesh),
        ExpansionTile(
          initiallyExpanded: true,
          dense: true,
          tilePadding: EdgeInsets.zero,
          leading: const Icon(Icons.hub_outlined, size: 17),
          title: Text(mesh.meshId, style: const TextStyle(fontSize: 11)),
          subtitle: Text(
            '${mesh.surfaceCount} superfície(s) · ${mesh.pendingRegionCount} pendente(s)',
            style: const TextStyle(fontSize: 9),
          ),
          children: [
            const _ReconstructionBranch('Reconhecimento'),
            const _ReconstructionBranch('Curvas de referência'),
            const _ReconstructionBranch('Sketches'),
            const _ReconstructionBranch('Superfícies'),
            const _ReconstructionBranch('Regiões pendentes'),
            for (final region in mesh.regions)
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: Icon(
                  switch (region.status) {
                    ReconstructionRegionStatus.reconstructed =>
                      Icons.check_circle,
                    ReconstructionRegionStatus.inProgress => Icons.timelapse,
                    ReconstructionRegionStatus.pending => Icons.error,
                    ReconstructionRegionStatus.ignored =>
                      Icons.remove_circle_outline,
                  },
                  color: switch (region.status) {
                    ReconstructionRegionStatus.reconstructed => Colors.green,
                    ReconstructionRegionStatus.inProgress => Colors.amber,
                    ReconstructionRegionStatus.pending => Colors.red,
                    ReconstructionRegionStatus.ignored => Colors.grey,
                  },
                  size: 15,
                ),
                title: Text(
                  region.recognitionResultId,
                  style: const TextStyle(fontSize: 9.5),
                ),
                subtitle: Text(
                  '${region.area.toStringAsFixed(2)} mm² · ${region.status.name}',
                  style: const TextStyle(fontSize: 8.5),
                ),
                trailing: IconButton(
                  tooltip: region.status == ReconstructionRegionStatus.ignored
                      ? 'Restaurar região'
                      : 'Ignorar região',
                  icon: Icon(
                    region.status == ReconstructionRegionStatus.ignored
                        ? Icons.undo
                        : Icons.visibility_off_outlined,
                    size: 15,
                  ),
                  onPressed: () => onRegionIgnored(
                    region.recognitionResultId,
                    region.status != ReconstructionRegionStatus.ignored,
                  ),
                ),
                onTap: () => onRegionSelected(region.recognitionResultId),
              ),
          ],
        ),
        if (mesh.nextRegionId != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lightbulb_outline, size: 17),
            title: const Text(
              'Próxima região recomendada',
              style: TextStyle(fontSize: 10),
            ),
            subtitle: Text(
              mesh.nextRegionId!,
              style: const TextStyle(fontSize: 9.5),
            ),
            onTap: () => onRegionSelected(mesh.nextRegionId!),
          ),
        const Divider(height: 20),
      ],
      for (final step in state.steps)
        _WorkflowStepTile(step: step, active: step.stage == state.currentStage),
      const Divider(height: 20),
      Text(
        'Assistente de engenharia',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 5),
      Text(state.explanation, style: const TextStyle(fontSize: 10.5)),
      if (state.blockReason != null)
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            'Bloqueado: ${state.blockReason}',
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      const SizedBox(height: 8),
      FilledButton.tonalIcon(
        onPressed: onOpenNext,
        icon: const Icon(Icons.arrow_forward, size: 16),
        label: Text(state.nextAction),
      ),
      if (state.timelines.isNotEmpty) ...[
        const Divider(height: 20),
        Text('Linha do tempo', style: Theme.of(context).textTheme.titleSmall),
        for (final timeline in state.timelines)
          ExpansionTile(
            dense: true,
            tilePadding: EdgeInsets.zero,
            title: Text(timeline.id, style: const TextStyle(fontSize: 10.5)),
            children: [
              for (var index = 0; index < timeline.entityIds.length; index++)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Icon(
                    index == 0 ? Icons.flag_outlined : Icons.arrow_upward,
                    size: 14,
                  ),
                  title: Text(
                    timeline.entityIds[index],
                    style: const TextStyle(fontSize: 9.5),
                  ),
                ),
            ],
          ),
      ],
    ],
  );
}

class _CoverageCard extends StatelessWidget {
  const _CoverageCard({required this.mesh});
  final MeshReconstructionCoverage mesh;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Cobertura da malha',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 7),
          LinearProgressIndicator(value: mesh.reconstructedPercent / 100),
          const SizedBox(height: 5),
          Text(
            '${mesh.reconstructedPercent.toStringAsFixed(1)}% reconstruída · '
            '${mesh.pendingPercent.toStringAsFixed(1)}% pendente',
            style: const TextStyle(fontSize: 9.5),
          ),
          Text(
            '${mesh.reconstructedArea.toStringAsFixed(2)} mm² reconstruída · '
            '${mesh.pendingArea.toStringAsFixed(2)} mm² restante',
            style: const TextStyle(fontSize: 9),
          ),
        ],
      ),
    ),
  );
}

class _ReconstructionBranch extends StatelessWidget {
  const _ReconstructionBranch(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    visualDensity: const VisualDensity(vertical: -4),
    leading: const Icon(Icons.subdirectory_arrow_right, size: 13),
    title: Text(label, style: const TextStyle(fontSize: 9)),
  );
}

class _WorkflowStepTile extends StatelessWidget {
  const _WorkflowStepTile({required this.step, required this.active});
  final ReverseEngineeringStep step;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final completed = step.status == ReverseEngineeringStageStatus.completed;
    return Container(
      margin: const EdgeInsets.only(bottom: 3),
      decoration: BoxDecoration(
        color: active
            ? Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: .45)
            : null,
        borderRadius: BorderRadius.circular(5),
      ),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -4),
        leading: Icon(
          completed
              ? Icons.check_circle
              : active
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
          size: 16,
          color: completed
              ? Colors.green
              : active
              ? Theme.of(context).colorScheme.primary
              : null,
        ),
        title: Text(_label(step.stage), style: const TextStyle(fontSize: 10.5)),
        trailing: step.count == 0
            ? null
            : Text('${step.count}', style: const TextStyle(fontSize: 9)),
      ),
    );
  }

  String _label(ReverseEngineeringStage stage) => switch (stage) {
    ReverseEngineeringStage.mesh => 'Mesh',
    ReverseEngineeringStage.recognition => 'Recognition',
    ReverseEngineeringStage.referenceCurves => 'Reference Curves',
    ReverseEngineeringStage.sketch => 'Sketch',
    ReverseEngineeringStage.surface => 'Surface',
    ReverseEngineeringStage.topology => 'Topology',
    ReverseEngineeringStage.solid => 'Solid',
  };
}
