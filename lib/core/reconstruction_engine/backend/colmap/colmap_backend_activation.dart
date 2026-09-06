import 'dart:io';

import 'package:path/path.dart' as path;

import '../../provisioning/backend_provisioning.dart';
import 'colmap_backend.dart';

class ColmapBackendActivation {
  const ColmapBackendActivation({
    ColmapProcessRunner? processRunner,
    Directory? managedInstallationRoot,
  }) : _processRunner = processRunner ?? const IoColmapProcessRunner(),
       _managedInstallationRoot = managedInstallationRoot;

  final ColmapProcessRunner _processRunner;
  final Directory? _managedInstallationRoot;

  Future<ColmapBackend> activate(
    BackendInstallationRecord record, {
    bool allowUncertifiedExternal = false,
  }) async {
    if (record.backendId != 'colmap') {
      throw StateError('Only a COLMAP installation can activate this backend');
    }
    final executable = File(record.executablePath);
    if (!path.isAbsolute(executable.path) || !await executable.exists()) {
      throw StateError('COLMAP executable is missing or is not absolute');
    }
    final expectedName = Platform.isWindows ? 'colmap.exe' : 'colmap';
    if (path.basename(executable.path).toLowerCase() != expectedName) {
      throw StateError('COLMAP executable must be named $expectedName');
    }
    final canonical = await executable.resolveSymbolicLinks();
    if (path.basename(canonical).toLowerCase() != expectedName) {
      throw StateError('Canonical COLMAP executable must be named $expectedName');
    }
    if (record.origin == BackendInstallationOrigin.external) {
      if (record.status != BackendInstallationStatus.installed ||
          !allowUncertifiedExternal ||
          record.certification != BackendCertificationStatus.notCertified) {
        throw StateError(
          'External COLMAP requires explicit experimental activation',
        );
      }
    } else {
      if (record.certification != BackendCertificationStatus.certified ||
          record.status != BackendInstallationStatus.certified) {
        throw StateError('Managed COLMAP must be certified');
      }
      final root = _managedInstallationRoot;
      if (root == null) {
        throw StateError('Managed installation root is required');
      }
      final canonicalRoot = await root.resolveSymbolicLinks();
      if (!_isWithin(canonicalRoot, canonical)) {
        throw StateError('Managed COLMAP escapes its installation root');
      }
    }
    final version = await _processRunner.version(canonical);
    if (version == null || version.trim().isEmpty) {
      throw StateError('COLMAP version probe failed');
    }
    return ColmapBackend(
      executable: canonical,
      detectedVersion: version.trim(),
      processRunner: _processRunner,
    );
  }

  static bool _isWithin(String root, String candidate) {
    final rootWithSeparator = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    final normalizedRoot = Platform.isWindows
        ? rootWithSeparator.toLowerCase()
        : rootWithSeparator;
    final normalizedCandidate = Platform.isWindows
        ? candidate.toLowerCase()
        : candidate;
    return normalizedCandidate.startsWith(normalizedRoot);
  }
}
