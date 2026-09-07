import 'package:flutter/material.dart';

import '../../../core/reconstruction_engine/models/reconstruction_contract.dart';
import '../colmap_experimental_lab_controller.dart';
import '../colmap_operational_controller.dart';

/// Isolated presentation for the experimental COLMAP laboratory.
///
/// The injected controller is borrowed and is never disposed by this widget.
class ColmapExperimentalLab extends StatefulWidget {
  const ColmapExperimentalLab({super.key, required this.controller});

  final ColmapExperimentalLabController controller;

  @override
  State<ColmapExperimentalLab> createState() => _ColmapExperimentalLabState();
}

class _ColmapExperimentalLabState extends State<ColmapExperimentalLab> {
  bool _consent = false;

  @override
  void didUpdateWidget(covariant ColmapExperimentalLab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) _consent = false;
  }

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
            onChanged: (value) => setState(() => _consent = value ?? false),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Tooltip(
                message: 'Selecionar o executável externo do COLMAP',
                child: OutlinedButton.icon(
                  key: const Key('select-colmap'),
                  onPressed: isBusy ? null : controller.chooseExecutable,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Selecionar colmap.exe'),
                ),
              ),
              Tooltip(
                message: 'Validar e tornar ativo o executável selecionado',
                child: FilledButton.icon(
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
              ),
            ],
          ),
          if (controller.selectedExecutablePath case final path?) ...[
            const SizedBox(height: 8),
            SelectableText('Executável selecionado: $path'),
          ],
          if (controller.hasPendingConfiguration) ...[
            const SizedBox(height: 6),
            const Text(
              'Novo executável selecionado, ainda não ativo.',
              key: Key('pending-colmap-configuration'),
            ),
          ],
          const SizedBox(height: 16),
          _StatusPanel(controller: controller),
          const Divider(height: 32),
          Tooltip(
            message: 'Selecionar uma pasta com fotografias compatíveis',
            child: OutlinedButton.icon(
              key: const Key('select-photos'),
              onPressed: isBusy ? null : controller.choosePhotoDirectory,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Selecionar pasta de fotografias'),
            ),
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
            runSpacing: 8,
            children: [
              Tooltip(
                message: 'Iniciar a reconstrução experimental',
                child: FilledButton.icon(
                  key: const Key('start-reconstruction'),
                  onPressed: controller.canStart(consent: _consent)
                      ? () => controller.startReconstruction(consent: _consent)
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Iniciar reconstrução'),
                ),
              ),
              Tooltip(
                message: 'Solicitar cancelamento da reconstrução em execução',
                child: FilledButton.tonalIcon(
                  key: const Key('cancel-reconstruction'),
                  onPressed: canCancel ? controller.cancel : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Cancelar'),
                ),
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
          if (controller.presentationFailure case final failure?) ...[
            const SizedBox(height: 16),
            _FailurePanel(failure: failure),
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
      container: true,
      label: 'Estado do COLMAP: $label',
      excludeSemantics: true,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Estado: $label',
                      key: const Key('colmap-status'),
                    ),
                  ),
                ],
              ),
              if (installation != null) ...[
                const SizedBox(height: 6),
                Text('Versão: ${installation.version}'),
                SelectableText(
                  'Executável ativo: ${installation.executablePath}',
                  key: const Key('active-colmap-path'),
                ),
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

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({required this.failure});

  final ColmapLabFailure failure;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Falha: ${failure.userMessage}',
    excludeSemantics: true,
    child: Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Falha: ${failure.userMessage}',
              key: const Key('colmap-error'),
            ),
            if (failure.controlledTechnicalDetail case final detail?)
              ExpansionTile(
                key: const Key('colmap-technical-detail'),
                tilePadding: EdgeInsets.zero,
                title: const Text('Detalhes técnicos'),
                children: [SelectableText(detail)],
              ),
          ],
        ),
      ),
    ),
  );
}

class _StageRow extends StatelessWidget {
  const _StageRow(this.report);

  final ReconstructionStageReport report;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: Icon(_statusIcon(report.status)),
    title: Text(_stageLabel(report.stage)),
    subtitle: Text('Status: ${_statusLabel(report.status)}'),
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
