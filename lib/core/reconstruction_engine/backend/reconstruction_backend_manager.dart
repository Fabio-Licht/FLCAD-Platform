import 'dart:convert';
import 'dart:io';

import '../models/reconstruction_contract.dart';
import 'foundation_reconstruction_backend.dart';
import 'reconstruction_backend_contract.dart';

class ReconstructionBackendManager {
  ReconstructionBackendManager({
    Iterable<ReconstructionBackend> backends = const [
      FoundationReconstructionBackend(),
    ],
    this.fallbackId = 'foundation',
  }) : _backends = {for (final backend in backends) backend.id: backend};

  final Map<String, ReconstructionBackend> _backends;
  final String fallbackId;
  String? _preferredId;

  List<ReconstructionBackend> get backends =>
      List.unmodifiable(_backends.values);
  String? get preferredId => _preferredId;

  void register(ReconstructionBackend backend) {
    if (_backends.containsKey(backend.id)) {
      throw StateError('Backend ${backend.id} already registered');
    }
    _backends[backend.id] = backend;
  }

  bool contains(String id) => _backends.containsKey(id);

  /// Atomically replaces an already registered backend with the same id.
  ///
  /// Callers must finish all asynchronous validation before invoking this
  /// method so a failed replacement cannot remove the working backend.
  void replace(ReconstructionBackend backend) {
    if (!_backends.containsKey(backend.id)) {
      throw StateError('Backend ${backend.id} not registered');
    }
    _backends[backend.id] = backend;
  }

  ReconstructionBackend get(String id) =>
      _backends[id] ?? (throw StateError('Backend $id not registered'));

  void setPreferred(String id) {
    get(id);
    _preferredId = id;
  }

  ReconstructionBackend select({
    BackendSelectionMode mode = BackendSelectionMode.automatic,
    String? manualId,
  }) {
    switch (mode) {
      case BackendSelectionMode.manual:
        if (manualId == null) throw ArgumentError('manualId is required');
        return get(manualId);
      case BackendSelectionMode.preferred:
        return get(_preferredId ?? fallbackId);
      case BackendSelectionMode.fallback:
        return get(fallbackId);
      case BackendSelectionMode.automatic:
        return get(_preferredId ?? fallbackId);
    }
  }

  Future<ReconstructionBackendResult> reconstruct(
    ReconstructionRequest request, {
    BackendSelectionMode mode = BackendSelectionMode.automatic,
    String? manualId,
    void Function(ReconstructionStageReport report)? onStage,
    ReconstructionCancellation? cancellation,
  }) async {
    final backend = select(mode: mode, manualId: manualId);
    final result = await backend.reconstruct(
      request,
      onStage: onStage,
      cancellation: cancellation,
    );
    final diagnostics = result.diagnostics;
    if (diagnostics.backendId == backend.id &&
        diagnostics.backendVersion == backend.capabilities.version) {
      return result;
    }
    return ReconstructionBackendResult(
      output: result.output,
      diagnostics: ReconstructionBackendDiagnostics(
        backendId: backend.id,
        backendVersion: backend.capabilities.version,
        durationMs: diagnostics.durationMs,
        memoryBytes: diagnostics.memoryBytes,
        confidence: diagnostics.confidence,
        completedStages: diagnostics.completedStages,
        limitations: diagnostics.limitations,
        explanations: diagnostics.explanations,
      ),
    );
  }

  Future<void> saveSelection(File file) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'preferredId': _preferredId}),
      flush: true,
    );
  }

  Future<void> loadSelection(File file) async {
    if (!await file.exists()) return;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final preferredId = json['preferredId'] as String?;
    // A persisted optional backend may have been removed or may no longer be
    // available on this machine. Selection must remain safely usable.
    _preferredId = preferredId != null && _backends.containsKey(preferredId)
        ? preferredId
        : null;
  }
}
