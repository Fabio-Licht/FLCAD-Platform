import 'package:flutter/material.dart';

import '../../../core/reconstruction_engine/models/reconstruction_contract.dart';
import '../colmap_experimental_lab_controller.dart';
import '../colmap_operational_controller.dart';

class ColmapExperimentalLab extends StatefulWidget {
  const ColmapExperimentalLab({super.key, required this.controller});

  final ColmapExperimentalLabController controller;

  @override
  State<ColmapExperimentalLab> createState() => _ColmapExperimentalLabState();
}

class _ColmapExperimentalLabState extends State<ColmapExperimentalLab> {
  bool _consent = false;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final operational = controller.operational;
      final state = operational.state;
      final isBusy =
          controller.isProvisioning ||
          state == ColmapOperationalState.activating ||
          state == ColmapOperationalState.running ||
          state == ColmapOperationalState.cancelling;
      final canCancel = state == ColmapOperationalState.running;
      final canStart =
          !isBusy &&
          controller.activeInstallation != null &&
          (controller.photoDirectory?.imageCount ?? 0) > 0;

      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'FLCAD Platform — laboratório experimental de reconstrução',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('COLMAP externo e não certificado.'),
                  SizedBox(height: 6),
                  Text('O cancelamento é best effort.'),
                  SizedBox(height: 6),
                  Text('Sucesso técnico não certifica precisão dimensional.'),
                  SizedBox(height: 6),
                  Text(
                    'Capture = aquisição • Scan = reconstrução • '
                    'Reverse AI = engenharia reversa posterior',
                  ),
                ],
              ),
            ),
          ),
          CheckboxListTile(
            key: const Key('colmap-consent'),
            contentPadding: EdgeInsets.zero,
            value: _consent,
            title: const Text(
              'Autorizo o uso experimental deste COLMAP externo.',
            ),
            onChanged: isBusy
                ? null
                : (value) => setState(() => _consent = value ?? false),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('select-colmap'),
                onPressed: isBusy ? null : controller.chooseExecutable,
                icon: const Icon(Icons.folder_open),
                label: const Text('Selecionar colmap.exe'),
              ),
              FilledButton.icon(
                key: const Key('activate-colmap'),
                onPressed:
                    isBusy ||
                        !_consent ||
                        controller.selectedExecutablePath == null
                    ? null
                    : () => controller.validateAndActivate(consent: _consent),
                icon: const Icon(Icons.verified_outlined),
                label: const Text('Validar e ativar'),
              ),
            ],
          ),
          if (controller.selectedExecutablePath case final path?) ...[
            const SizedBox(height: 8),
            SelectableText('Selecionado: $path'),
          ],
          const SizedBox(height: 16),
          _StatusPanel(controller: controller),
          const Divider(height: 32),
          OutlinedButton.icon(
            key: const Key('select-photos'),
            onPressed: isBusy ? null : controller.choosePhotoDirectory,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Selecionar pasta de fotografias'),
          ),
          if (controller.photoDirectory case final selection?) ...[
            const SizedBox(height: 8),
            SelectableText('Pasta: ${selection.canonicalPath}'),
            Text(
              '${selection.imageCount} imagens compatíveis',
              key: const Key('compatible-image-count'),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('start-reconstruction'),
                onPressed: canStart ? controller.startReconstruction : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Iniciar reconstrução'),
              ),
              FilledButton.tonalIcon(
                key: const Key('cancel-reconstruction'),
                onPressed: canCancel ? controller.cancel : null,
                icon: const Icon(Icons.stop),
                label: const Text('Cancelar'),
              ),
            ],
          ),
          if (operational.reports.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Etapas', style: Theme.of(context).textTheme.titleMedium),
            ...operational.reports.map(_StageRow.new),
          ],
          if (state == ColmapOperationalState.succeeded) ...[
            const SizedBox(height: 20),
            const Text(
              'Reconstrução concluída: candidato de malha disponível.',
              key: Key('mesh-candidate-result'),
            ),
            ..._artifactPaths(
              operational.result?.output.meshCandidate,
            ).map((path) => SelectableText('Artefato: $path')),
          ],
          if (controller.presentationError ?? operational.error
              case final error?) ...[
            const SizedBox(height: 16),
            Text(
              'Erro: $error',
              key: const Key('colmap-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      );
    },
  );

  static Iterable<String> _artifactPaths(Map<String, dynamic>? artifact) sync* {
    if (artifact == null) return;
    for (final entry in artifact.entries) {
      if (entry.value is String &&
          (entry.key.toLowerCase().contains('path') ||
              entry.key.toLowerCase().contains('file'))) {
        yield entry.value as String;
      }
    }
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.controller});

  final ColmapExperimentalLabController controller;

  @override
  Widget build(BuildContext context) {
    final operational = controller.operational;
    final installation = controller.activeInstallation;
    final label =
        controller.isProvisioning &&
            operational.state != ColmapOperationalState.activating
        ? 'Validando instalação externa'
        : _stateLabel(operational.state);
    return Semantics(
      label: 'Estado do COLMAP: $label',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.info_outline),
                  const SizedBox(width: 8),
                  Text('Estado: $label', key: const Key('colmap-status')),
                ],
              ),
              if (installation != null) ...[
                const SizedBox(height: 6),
                Text('Versão: ${installation.version}'),
                SelectableText('Caminho ativo: ${installation.executablePath}'),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _stateLabel(ColmapOperationalState state) => switch (state) {
    ColmapOperationalState.idle => 'inativo',
    ColmapOperationalState.activating => 'ativando',
    ColmapOperationalState.ready => 'pronto',
    ColmapOperationalState.running => 'executando',
    ColmapOperationalState.cancelling => 'cancelando',
    ColmapOperationalState.succeeded => 'concluído',
    ColmapOperationalState.failed => 'falhou',
    ColmapOperationalState.cancelled => 'cancelado',
    ColmapOperationalState.disposed => 'encerrado',
  };
}

class _StageRow extends StatelessWidget {
  const _StageRow(this.report);

  final ReconstructionStageReport report;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: Icon(_statusIcon(report.status)),
    title: Text(_stageLabel(report.stage)),
    subtitle: Text(report.explanation),
    trailing: Text(_statusLabel(report.status)),
  );

  static IconData _statusIcon(ReconstructionStageStatus status) =>
      switch (status) {
        ReconstructionStageStatus.pending => Icons.schedule,
        ReconstructionStageStatus.running => Icons.sync,
        ReconstructionStageStatus.completed => Icons.check_circle_outline,
        ReconstructionStageStatus.skipped => Icons.skip_next,
        ReconstructionStageStatus.failed => Icons.error_outline,
      };

  static String _statusLabel(ReconstructionStageStatus status) =>
      switch (status) {
        ReconstructionStageStatus.pending => 'pendente',
        ReconstructionStageStatus.running => 'executando',
        ReconstructionStageStatus.completed => 'concluída',
        ReconstructionStageStatus.skipped => 'ignorada',
        ReconstructionStageStatus.failed => 'falhou',
      };

  static String _stageLabel(ReconstructionStage stage) => switch (stage) {
    ReconstructionStage.featureDetection => 'Detecção de características',
    ReconstructionStage.featureMatching => 'Correspondência de características',
    ReconstructionStage.cameraCalibration => 'Calibração de câmera',
    ReconstructionStage.poseEstimation => 'Estimativa de poses',
    ReconstructionStage.sparseReconstruction => 'Reconstrução esparsa',
    ReconstructionStage.denseReconstruction => 'Reconstrução densa',
    ReconstructionStage.meshGeneration => 'Geração do candidato de malha',
    ReconstructionStage.optimization => 'Otimização',
  };
}
