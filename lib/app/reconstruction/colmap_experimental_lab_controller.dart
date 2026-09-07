import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../core/acquisition_intelligence/models/evidence_graph.dart';
import '../../core/reconstruction_engine/backend/colmap/colmap_input_validation.dart';
import '../../core/reconstruction_engine/models/reconstruction_contract.dart';
import '../../core/reconstruction_engine/provisioning/backend_provisioning.dart';
import 'colmap_operational_controller.dart';

typedef ColmapExecutablePicker = Future<String?> Function();
typedef ColmapPhotoDirectoryPicker = Future<String?> Function();

/// Supplies the private workspace root managed by FLCAD Platform.
///
/// This is a trusted internal application dependency. It must never return a
/// path selected by the user; the returned root is reserved for application-
/// managed COLMAP execution directories.
typedef ColmapWorkspaceRootProvider = Future<String> Function();
typedef ColmapRequestIdFactory = String Function();

@immutable
class ColmapLabFailure {
  const ColmapLabFailure({
    required this.code,
    required this.userMessage,
    this.controlledTechnicalDetail,
  });

  final String code;
  final String userMessage;
  final String? controlledTechnicalDetail;

  static ColmapLabFailure from(Object error, {required String operation}) {
    final detail = _sanitizeTechnicalDetail(
      'operation=$operation; exception=${error.runtimeType}',
    );
    final message = switch (operation) {
      'executable-picker' => 'Não foi possível selecionar o executável.',
      'photo-picker' => 'Não foi possível selecionar a pasta de fotografias.',
      'photo-validation' =>
        'A pasta selecionada não contém fotografias válidas para reconstrução.',
      'workspace' =>
        'Não foi possível preparar a área privada de reconstrução.',
      'activation' => 'A nova configuração do COLMAP foi rejeitada.',
      'start' => 'Não foi possível iniciar a reconstrução experimental.',
      'consent' => 'O consentimento experimental atual é obrigatório.',
      'pending-configuration' =>
        'Valide e ative o executável selecionado antes de iniciar.',
      _ => 'A operação do laboratório COLMAP não pôde ser concluída.',
    };
    return ColmapLabFailure(
      code: operation,
      userMessage: message,
      controlledTechnicalDetail: detail.isEmpty ? null : detail,
    );
  }

  static String _sanitizeTechnicalDetail(String value) {
    final withoutControls = value.replaceAll(
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
      '',
    );
    final singleLine = withoutControls.replaceAll(RegExp(r'[\r\n]+'), ' ');
    final compact = singleLine.replaceAll(RegExp(r'\s+'), ' ').trim();
    return compact.length <= 512 ? compact : compact.substring(0, 512);
  }
}

/// Presentation facade for the isolated COLMAP laboratory.
///
/// Operational state remains owned exclusively by [ColmapOperationalController].
/// Injected controllers are borrowed: this facade removes its listener but never
/// disposes or cancels them. The future desktop owner must cancel/close them when
/// the application scope ends. Leaving this presentation does not cancel work.
class ColmapExperimentalLabController extends ChangeNotifier {
  ColmapExperimentalLabController({
    required ColmapOperationalController operationalController,
    required BackendProvisioningManager provisioningManager,
    required ColmapExecutablePicker selectExecutable,
    required ColmapPhotoDirectoryPicker selectPhotoDirectory,
    required ColmapWorkspaceRootProvider workspaceRootProvider,
    ColmapInputValidator? inputValidator,
    ColmapRequestIdFactory? requestIdFactory,
    String? knownExecutablePath,
  }) : _operationalController = operationalController,
       _provisioningManager = provisioningManager,
       _selectExecutable = selectExecutable,
       _selectPhotoDirectory = selectPhotoDirectory,
       _workspaceRootProvider = workspaceRootProvider,
       _inputValidator = inputValidator ?? const IoColmapInputValidator(),
       _requestIdFactory =
           requestIdFactory ??
           (() => 'colmap-${DateTime.now().toUtc().microsecondsSinceEpoch}'),
       _selectedExecutablePath = _knownColmapPath(knownExecutablePath) {
    _operationalController.addListener(_forwardOperationalChange);
  }

  final ColmapOperationalController _operationalController;
  final BackendProvisioningManager _provisioningManager;
  final ColmapExecutablePicker _selectExecutable;
  final ColmapPhotoDirectoryPicker _selectPhotoDirectory;
  final ColmapWorkspaceRootProvider _workspaceRootProvider;
  final ColmapInputValidator _inputValidator;
  final ColmapRequestIdFactory _requestIdFactory;

  String? _selectedExecutablePath;
  ValidatedColmapPhotoDirectory? _photoDirectory;
  BackendInstallationRecord? _activeInstallation;
  ColmapLabFailure? _presentationFailure;
  bool _provisioning = false;
  bool _disposed = false;

  ColmapOperationalController get operational => _operationalController;
  String? get selectedExecutablePath => _selectedExecutablePath;
  String? get activeExecutablePath => _activeInstallation?.executablePath;
  ValidatedColmapPhotoDirectory? get photoDirectory => _photoDirectory;
  BackendInstallationRecord? get activeInstallation => _activeInstallation;
  ColmapLabFailure? get presentationFailure => _presentationFailure;

  @Deprecated('Use presentationFailure; raw exceptions are never UI content.')
  Object? get presentationError => _presentationFailure;
  bool get isProvisioning => _provisioning;
  bool get hasPendingConfiguration {
    final selected = _selectedExecutablePath;
    return selected != null && selected != activeExecutablePath;
  }

  static String? _knownColmapPath(String? value) {
    if (value == null || !path.isAbsolute(value)) return null;
    final expected = Platform.isWindows ? 'colmap.exe' : 'colmap';
    return path.basename(value).toLowerCase() == expected ? value : null;
  }

  bool canStart({required bool consent}) {
    final stateAllowsStart = switch (_operationalController.state) {
      ColmapOperationalState.ready ||
      ColmapOperationalState.succeeded ||
      ColmapOperationalState.failed ||
      ColmapOperationalState.cancelled => true,
      ColmapOperationalState.idle ||
      ColmapOperationalState.activating ||
      ColmapOperationalState.running ||
      ColmapOperationalState.cancelling ||
      ColmapOperationalState.disposed => false,
    };
    return !_disposed &&
        consent &&
        !_provisioning &&
        stateAllowsStart &&
        !hasPendingConfiguration &&
        _activeInstallation != null &&
        (_photoDirectory?.imageCount ?? 0) > 0;
  }

  Future<void> chooseExecutable() async {
    try {
      final selected = await _selectExecutable();
      if (_disposed || selected == null) return;
      _selectedExecutablePath = selected;
      _presentationFailure = null;
      notifyListeners();
    } catch (error) {
      _setFailure(error, operation: 'executable-picker');
    }
  }

  Future<void> validateAndActivate({required bool consent}) async {
    if (_disposed || _provisioning) return;
    if (!consent) {
      _setFailure(StateError('consent required'), operation: 'consent');
      return;
    }
    final executablePath = _selectedExecutablePath;
    if (executablePath == null || executablePath.isEmpty) {
      _setFailure(StateError('executable missing'), operation: 'activation');
      return;
    }

    _provisioning = true;
    _presentationFailure = null;
    notifyListeners();
    try {
      final result = await _operationalController.configureExternalSelection(
        provisioningManager: _provisioningManager,
        executablePath: executablePath,
        consent: consent,
        allowExperimental: true,
      );
      if (_disposed) return;
      if (result != null &&
          _operationalController.state == ColmapOperationalState.ready) {
        _activeInstallation = result.installation;
        _selectedExecutablePath = result.installation.executablePath;
      } else {
        _setFailure(
          _operationalController.error ?? StateError('activation rejected'),
          operation: 'activation',
          notify: false,
        );
      }
    } catch (error) {
      _setFailure(error, operation: 'activation', notify: false);
    } finally {
      if (!_disposed) {
        _provisioning = false;
        notifyListeners();
      }
    }
  }

  Future<void> choosePhotoDirectory() async {
    String? selected;
    try {
      selected = await _selectPhotoDirectory();
    } catch (error) {
      _setFailure(error, operation: 'photo-picker');
      return;
    }
    if (_disposed || selected == null) return;
    try {
      final validated = await _inputValidator.validatePhotoDirectory(selected);
      if (_disposed) return;
      _photoDirectory = validated;
      _presentationFailure = null;
      notifyListeners();
    } catch (error) {
      _setFailure(error, operation: 'photo-validation');
    }
  }

  Future<void> startReconstruction({required bool consent}) async {
    if (_disposed ||
        _operationalController.state == ColmapOperationalState.running ||
        _operationalController.state == ColmapOperationalState.cancelling ||
        _operationalController.state == ColmapOperationalState.activating) {
      return;
    }
    if (!consent) {
      _setFailure(StateError('consent required'), operation: 'consent');
      return;
    }
    if (hasPendingConfiguration) {
      _setFailure(
        StateError('pending executable'),
        operation: 'pending-configuration',
      );
      return;
    }
    final selectedSnapshot = _photoDirectory;
    if (selectedSnapshot == null ||
        selectedSnapshot.canonicalImagePaths.isEmpty) {
      _setFailure(StateError('empty photo set'), operation: 'photo-validation');
      return;
    }
    if (_activeInstallation == null) {
      _setFailure(StateError('COLMAP not active'), operation: 'activation');
      return;
    }

    try {
      final selection = await _inputValidator.validatePhotoDirectory(
        selectedSnapshot.canonicalPath,
      );
      if (_disposed) return;
      _photoDirectory = selection;
      String managedRoot;
      try {
        managedRoot = await _workspaceRootProvider();
      } catch (error) {
        _setFailure(error, operation: 'workspace');
        return;
      }
      final workspaceRoot = await _inputValidator.prepareWorkspaceRoot(
        managedRoot,
      );
      if (_disposed) return;
      _presentationFailure = null;
      notifyListeners();
      final requestId = _requestIdFactory();
      var graph = const EvidenceGraph();
      for (
        var index = 0;
        index < selection.canonicalImagePaths.length;
        index++
      ) {
        final imagePath = selection.canonicalImagePaths[index];
        graph = graph.addCapture(
          captureId: '$requestId:$index',
          capture: {
            'source': 'photograph',
            'path': imagePath,
            'directory': selection.canonicalPath,
          },
          evidence: const {'role': 'reconstruction-input'},
        );
      }
      await _operationalController.start(
        ReconstructionRequest(
          id: requestId,
          projectId: 'colmap-experimental-lab',
          evidenceGraph: graph,
          calibration: {
            'imagePath': selection.canonicalPath,
            'workspacePath': workspaceRoot,
          },
        ),
      );
      if (_disposed) return;
      if (_operationalController.state == ColmapOperationalState.failed &&
          _operationalController.error != null) {
        _setFailure(
          _operationalController.error!,
          operation: 'start',
          notify: false,
        );
      } else if (_operationalController.state ==
              ColmapOperationalState.succeeded ||
          _operationalController.state == ColmapOperationalState.cancelled) {
        _presentationFailure = null;
      }
      notifyListeners();
    } catch (error) {
      if (!_disposed) _setFailure(error, operation: 'start');
    }
  }

  void cancel() {
    if (_disposed) return;
    _operationalController.cancel();
  }

  void _setFailure(
    Object error, {
    required String operation,
    bool notify = true,
  }) {
    if (_disposed) return;
    _presentationFailure = ColmapLabFailure.from(error, operation: operation);
    if (notify) notifyListeners();
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
