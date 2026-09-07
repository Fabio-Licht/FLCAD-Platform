import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core/reconstruction_engine/backend/colmap/colmap_backend.dart';
import '../../core/reconstruction_engine/backend/colmap/colmap_backend_activation.dart';
import '../../core/reconstruction_engine/backend/reconstruction_backend_contract.dart';
import '../../core/reconstruction_engine/backend/reconstruction_backend_manager.dart';
import '../../core/reconstruction_engine/provisioning/backend_provisioning.dart';
import 'colmap_experimental_lab_controller.dart';
import 'colmap_operational_controller.dart';
import 'widgets/colmap_experimental_lab.dart';

typedef DesktopColmapLabRuntimeFactory =
    Future<DesktopColmapLabRuntime> Function();

class DesktopColmapLabRuntime {
  DesktopColmapLabRuntime._({
    required this.backendManager,
    required this.provisioningManager,
    required this.operationalController,
    required this.labController,
    required this.applicationSupportDirectory,
    required this.workspaceRoot,
    required this.persistedInstallations,
    this.onDispose,
  });

  final ReconstructionBackendManager backendManager;
  final BackendProvisioningManager provisioningManager;
  final ColmapOperationalController operationalController;
  final ColmapExperimentalLabController labController;
  final Directory applicationSupportDirectory;
  final Directory workspaceRoot;
  final List<BackendInstallationRecord> persistedInstallations;
  final VoidCallback? onDispose;
  bool _disposed = false;

  Widget buildLab(BuildContext context) =>
      ColmapExperimentalLab(controller: labController);

  static Future<DesktopColmapLabRuntime> create({
    Future<Directory> Function()? applicationSupportDirectoryProvider,
    ColmapExecutablePicker? selectExecutable,
    ColmapPhotoDirectoryPicker? selectPhotoDirectory,
    ColmapProcessRunner? processRunner,
    VoidCallback? onDispose,
  }) async {
    final support =
        await (applicationSupportDirectoryProvider ??
            getApplicationSupportDirectory)();
    final privateRoot = Directory(
      path.join(support.path, 'FLCAD Platform', 'COLMAP'),
    );
    final workspaceRoot = Directory(path.join(privateRoot.path, 'workspaces'));
    await workspaceRoot.create(recursive: true);
    final repository = FileBackendProvisioningRepository(
      catalogFile: File(path.join(privateRoot.path, 'approved-releases.json')),
      installationsFile: File(
        path.join(privateRoot.path, 'installations.json'),
      ),
      approvedReleases: const [],
    );
    final runner = processRunner ?? const IoColmapProcessRunner();
    final provisioning = BackendProvisioningManager(
      repository: repository,
      downloader: const _ExternalOnlyDownloadManager(),
      installer: const _ExternalOnlyArchiveInstaller(),
      checksumVerifier: const _ExternalOnlyChecksumVerifier(),
      signatureVerifier: const _ExternalOnlySignatureVerifier(),
      selfTest: ColmapVersionSelfTest(processRunner: runner),
      installationRoot: Directory(path.join(privateRoot.path, 'managed')),
    );
    final persisted = await provisioning.loadRecordedInstallations();
    String? knownColmapPath;
    for (final record in persisted.reversed) {
      if (record.backendId == 'colmap' &&
          record.origin == BackendInstallationOrigin.external) {
        knownColmapPath = record.executablePath;
        break;
      }
    }
    final backendManager = ReconstructionBackendManager();
    final operational = ColmapOperationalController(
      backendManager: backendManager,
      activate: ColmapBackendActivation(processRunner: runner).activate,
    );
    final lab = ColmapExperimentalLabController(
      operationalController: operational,
      provisioningManager: provisioning,
      selectExecutable: selectExecutable ?? _pickExecutable,
      selectPhotoDirectory: selectPhotoDirectory ?? _pickPhotoDirectory,
      workspaceRootProvider: () async => workspaceRoot.path,
      knownExecutablePath: knownColmapPath,
    );
    return DesktopColmapLabRuntime._(
      backendManager: backendManager,
      provisioningManager: provisioning,
      operationalController: operational,
      labController: lab,
      applicationSupportDirectory: support,
      workspaceRoot: workspaceRoot,
      persistedInstallations: List.unmodifiable(persisted),
      onDispose: onDispose,
    );
  }

  static Future<String?> _pickExecutable() async {
    final result = await FilePicker.pickFile(
      type: FileType.any,
      dialogTitle: 'Selecionar executável externo do COLMAP',
    );
    return result?.path;
  }

  static Future<String?> _pickPhotoDirectory() => FilePicker.getDirectoryPath(
    dialogTitle: 'Selecionar pasta de fotografias',
  );

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (operationalController.state == ColmapOperationalState.running) {
      operationalController.cancel();
    }
    labController.dispose();
    operationalController.dispose();
    onDispose?.call();
  }
}

class ColmapVersionSelfTest implements BackendSelfTest {
  const ColmapVersionSelfTest({required ColmapProcessRunner processRunner})
    : _processRunner = processRunner;

  final ColmapProcessRunner _processRunner;

  @override
  Future<ReconstructionBackendCapabilities> validate(
    String backendId,
    String executablePath,
  ) async {
    if (backendId != 'colmap') {
      throw StateError('Unsupported backend for the COLMAP version probe');
    }
    final version = await _processRunner.version(executablePath);
    if (version == null || version.trim().isEmpty) {
      throw StateError('COLMAP version probe failed');
    }
    return ReconstructionBackendCapabilities(
      supportsGpu: true,
      supportsCpu: true,
      incremental: true,
      denseReconstruction: true,
      texturing: false,
      automaticCalibration: true,
      license: 'BSD-3-Clause',
      version: version.trim(),
    );
  }
}

class _ExternalOnlyDownloadManager implements BackendDownloadManager {
  const _ExternalOnlyDownloadManager();
  @override
  Future<File> download(Uri uri, File destination) =>
      throw UnsupportedError('Automatic COLMAP download is not available');
}

class _ExternalOnlyArchiveInstaller implements BackendArchiveInstaller {
  const _ExternalOnlyArchiveInstaller();
  @override
  Future<void> extract(File archive, Directory destination) =>
      throw UnsupportedError('Automatic COLMAP installation is not available');
}

class _ExternalOnlyChecksumVerifier implements BackendChecksumVerifier {
  const _ExternalOnlyChecksumVerifier();
  @override
  Future<bool> verify(File file, String expectedSha256) =>
      throw UnsupportedError('Managed COLMAP installation is not available');
}

class _ExternalOnlySignatureVerifier implements BackendSignatureVerifier {
  const _ExternalOnlySignatureVerifier();
  @override
  Future<bool> verify(File file, String signature) =>
      throw UnsupportedError('Managed COLMAP installation is not available');
}
