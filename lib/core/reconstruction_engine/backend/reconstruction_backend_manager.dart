import 'dart:convert';
import 'dart:io';

import '../models/reconstruction_contract.dart';
import 'colmap/colmap_backend.dart';
import 'foundation_reconstruction_backend.dart';
import 'reconstruction_backend_contract.dart';

class ReconstructionBackendManager {
  ReconstructionBackendManager({
    Iterable<ReconstructionBackend> backends = const [
      FoundationReconstructionBackend(),
      ColmapBackend(),
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
  }) => select(
    mode: mode,
    manualId: manualId,
  ).reconstruct(request, onStage: onStage, cancellation: cancellation);

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
    if (preferredId != null) setPreferred(preferredId);
  }
}
