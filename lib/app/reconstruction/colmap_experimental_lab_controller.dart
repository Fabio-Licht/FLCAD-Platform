import 'package:flutter/foundation.dart';

import '../../core/acquisition_intelligence/models/evidence_graph.dart';
import '../../core/reconstruction_engine/models/reconstruction_contract.dart';
import '../../core/reconstruction_engine/provisioning/backend_provisioning.dart';
import 'colmap_operational_controller.dart';

typedef ColmapExecutablePicker = Future<String?> Function();
typedef ColmapPhotoDirectoryPicker =
    Future<ColmapPhotoDirectorySelection?> Function();
typedef ColmapRequestIdFactory = String Function();

@immutable
class ColmapPhotoDirectorySelection {
  const ColmapPhotoDirectorySelection({
    required this.path,
    required this.compatibleImagePaths,
  });

  final String path;
  final List<String> compatibleImagePaths;

  int get compatibleImageCount => compatibleImagePaths.length;
}

/// Presentation facade for the isolated COLMAP laboratory.
///
/// Operational state remains owned exclusively by [ColmapOperationalController].
/// This class only coordinates injected selections, provisioning and request
/// construction.
class ColmapExperimentalLabController extends ChangeNotifier {
  ColmapExperimentalLabController({
    required ColmapOperationalController operationalController,
    required BackendProvisioningManager provisioningManager,
    required ColmapExecutablePicker selectExecutable,
    required ColmapPhotoDirectoryPicker selectPhotoDirectory,
    ColmapRequestIdFactory? requestIdFactory,
  }) : _operationalController = operationalController,
       _provisioningManager = provisioningManager,
       _selectExecutable = selectExecutable,
       _selectPhotoDirectory = selectPhotoDirectory,
       _requestIdFactory =
           requestIdFactory ??
           (() => 'colmap-${DateTime.now().toUtc().microsecondsSinceEpoch}') {
    _operationalController.addListener(_forwardOperationalChange);
  }

  final ColmapOperationalController _operationalController;
  final BackendProvisioningManager _provisioningManager;
  final ColmapExecutablePicker _selectExecutable;
  final ColmapPhotoDirectoryPicker _selectPhotoDirectory;
  final ColmapRequestIdFactory _requestIdFactory;

  String? _selectedExecutablePath;
  ColmapPhotoDirectorySelection? _photoDirectory;
  BackendInstallationRecord? _activeInstallation;
  Object? _presentationError;
  bool _provisioning = false;
  bool _disposed = false;

  ColmapOperationalController get operational => _operationalController;
  String? get selectedExecutablePath => _selectedExecutablePath;
  ColmapPhotoDirectorySelection? get photoDirectory => _photoDirectory;
  BackendInstallationRecord? get activeInstallation => _activeInstallation;
  Object? get presentationError => _presentationError;
  bool get isProvisioning => _provisioning;

  Future<void> chooseExecutable() async {
    final selected = await _selectExecutable();
    if (_disposed || selected == null) return;
    _selectedExecutablePath = selected;
    _presentationError = null;
    notifyListeners();
  }

  Future<void> validateAndActivate({required bool consent}) async {
    if (_disposed || _provisioning) return;
    if (!consent) {
      _setPresentationError(
        StateError('O consentimento experimental é obrigatório.'),
      );
      return;
    }
    final executablePath = _selectedExecutablePath;
    if (executablePath == null || executablePath.isEmpty) {
      _setPresentationError(StateError('Selecione colmap.exe primeiro.'));
      return;
    }

    _provisioning = true;
    _presentationError = null;
    notifyListeners();
    try {
      final record = await _provisioningManager.registerExisting(
        'colmap',
        executablePath: executablePath,
        authorized: consent,
      );
      if (_disposed) return;
      if (record.status != BackendInstallationStatus.installed &&
          record.status != BackendInstallationStatus.certified) {
        throw StateError(record.lastError ?? 'A validação do COLMAP falhou.');
      }
      await _operationalController.configureExternal(
        record,
        consent: consent,
        allowExperimental: true,
      );
      if (_disposed) return;
      if (_operationalController.error != null) {
        _presentationError = _operationalController.error;
      } else if (_operationalController.state == ColmapOperationalState.ready) {
        _activeInstallation = record;
      }
    } catch (error) {
      if (!_disposed) _presentationError = error;
    } finally {
      if (!_disposed) {
        _provisioning = false;
        notifyListeners();
      }
    }
  }

  Future<void> choosePhotoDirectory() async {
    final selected = await _selectPhotoDirectory();
    if (_disposed || selected == null) return;
    _photoDirectory = ColmapPhotoDirectorySelection(
      path: selected.path,
      compatibleImagePaths: List.unmodifiable(selected.compatibleImagePaths),
    );
    _presentationError = null;
    notifyListeners();
  }

  Future<void> startReconstruction() async {
    if (_disposed ||
        _operationalController.state == ColmapOperationalState.running ||
        _operationalController.state == ColmapOperationalState.cancelling ||
        _operationalController.state == ColmapOperationalState.activating) {
      return;
    }
    final selection = _photoDirectory;
    if (selection == null || selection.compatibleImagePaths.isEmpty) {
      _setPresentationError(
        StateError('A pasta não contém fotografias compatíveis.'),
      );
      return;
    }
    if (_activeInstallation == null) {
      _setPresentationError(StateError('Valide e ative o COLMAP primeiro.'));
      return;
    }

    _presentationError = null;
    notifyListeners();
    final requestId = _requestIdFactory();
    var graph = const EvidenceGraph();
    for (
      var index = 0;
      index < selection.compatibleImagePaths.length;
      index++
    ) {
      final imagePath = selection.compatibleImagePaths[index];
      graph = graph.addCapture(
        captureId: '$requestId:$index',
        capture: {
          'source': 'photograph',
          'path': imagePath,
          'directory': selection.path,
        },
        evidence: const {'role': 'reconstruction-input'},
      );
    }
    await _operationalController.start(
      ReconstructionRequest(
        id: requestId,
        projectId: 'colmap-experimental-lab',
        evidenceGraph: graph,
      ),
    );
  }

  void cancel() {
    if (_disposed) return;
    _operationalController.cancel();
  }

  void _setPresentationError(Object error) {
    if (_disposed) return;
    _presentationError = error;
    notifyListeners();
  }

  void _forwardOperationalChange() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _operationalController.removeListener(_forwardOperationalChange);
    super.dispose();
  }
}
