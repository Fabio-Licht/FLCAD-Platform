import 'package:flutter/foundation.dart';

import '../../core/reconstruction_engine/backend/colmap/colmap_backend.dart';
import '../../core/reconstruction_engine/backend/colmap/colmap_backend_activation.dart';
import '../../core/reconstruction_engine/backend/reconstruction_backend_contract.dart';
import '../../core/reconstruction_engine/backend/reconstruction_backend_manager.dart';
import '../../core/reconstruction_engine/engine/reconstruction_engine.dart';
import '../../core/reconstruction_engine/models/reconstruction_contract.dart';
import '../../core/reconstruction_engine/provisioning/backend_provisioning.dart';

enum ColmapOperationalState {
  idle,
  activating,
  ready,
  running,
  cancelling,
  succeeded,
  failed,
  cancelled,
  disposed,
}

abstract interface class OperationalReconstructionCancellation
    implements ReconstructionCancellation {
  void cancel();
}

class _OperationalCancellationToken
    implements OperationalReconstructionCancellation {
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  @override
  void cancel() => _cancelled = true;
}

typedef ColmapActivationCallback = Future<ReconstructionBackend> Function(
  BackendInstallationRecord record, {
  required bool allowUncertifiedExternal,
});

typedef OperationalCancellationFactory =
    OperationalReconstructionCancellation Function();

/// Coordinates explicitly authorized COLMAP work without depending on the
/// legacy alpha stack or [ReconstructionRuntime].
class ColmapOperationalController extends ChangeNotifier {
  ColmapOperationalController({
    required ReconstructionBackendManager backendManager,
    ColmapActivationCallback? activate,
    OperationalCancellationFactory? cancellationFactory,
  }) : _backendManager = backendManager,
       _activate = activate ?? const ColmapBackendActivation().activate,
       _cancellationFactory =
           cancellationFactory ?? (() => _OperationalCancellationToken());

  final ReconstructionBackendManager _backendManager;
  final ColmapActivationCallback _activate;
  final OperationalCancellationFactory _cancellationFactory;

  ColmapOperationalState _state = ColmapOperationalState.idle;
  List<ReconstructionStageReport> _reports = const [];
  ReconstructionBackendResult? _result;
  Object? _error;
  StackTrace? _errorStackTrace;
  OperationalReconstructionCancellation? _cancellation;
  int _generation = 0;

  ColmapOperationalState get state => _state;
  List<ReconstructionStageReport> get reports => _reports;
  ReconstructionBackendResult? get result => _result;
  Object? get error => _error;
  StackTrace? get errorStackTrace => _errorStackTrace;
  bool get isDisposed => _state == ColmapOperationalState.disposed;

  Future<void> configureExternal(
    BackendInstallationRecord record, {
    required bool consent,
    required bool allowExperimental,
  }) async {
    _ensureUsable();
    if (_state == ColmapOperationalState.running ||
        _state == ColmapOperationalState.cancelling ||
        _state == ColmapOperationalState.activating) {
      throw StateError('COLMAP is busy');
    }
    if (!consent || !allowExperimental) {
      throw StateError('Explicit consent and experimental use are required');
    }
    final hadBackend = _backendManager.contains('colmap');
    final generation = ++_generation;
    _clearOperation();
    _setState(ColmapOperationalState.activating);
    try {
      final backend = await _activate(
        record,
        allowUncertifiedExternal: true,
      );
      if (!_isCurrent(generation)) return;
      if (hadBackend) {
        _backendManager.replace(backend);
      } else {
        _backendManager.register(backend);
      }
      _setState(ColmapOperationalState.ready);
    } catch (failure, stackTrace) {
      if (!_isCurrent(generation)) return;
      _error = failure;
      _errorStackTrace = stackTrace;
      _setState(
        hadBackend
            ? ColmapOperationalState.ready
            : ColmapOperationalState.failed,
      );
    }
  }

  Future<void> start(ReconstructionRequest request) async {
    _ensureUsable();
    if (_state == ColmapOperationalState.running ||
        _state == ColmapOperationalState.cancelling ||
        _state == ColmapOperationalState.activating) {
      throw StateError('COLMAP is busy');
    }
    _backendManager.get('colmap');
    final generation = ++_generation;
    _clearOperation();
    final cancellation = _cancellationFactory();
    _cancellation = cancellation;
    _setState(ColmapOperationalState.running);
    var acceptStageUpdates = true;
    try {
      final result = await _backendManager.reconstruct(
        request,
        mode: BackendSelectionMode.manual,
        manualId: 'colmap',
        cancellation: cancellation,
        onStage: (report) {
          if (!acceptStageUpdates || !_isCurrent(generation)) return;
          _reports = List.unmodifiable([..._reports, report]);
          _notify();
        },
      );
      acceptStageUpdates = false;
      if (!_isCurrent(generation)) return;
      _result = result;
      _reports = List.unmodifiable(result.output.stageReports);
      _setState(ColmapOperationalState.succeeded);
    } on ReconstructionCancelled catch (failure, stackTrace) {
      acceptStageUpdates = false;
      if (!_isCurrent(generation)) return;
      _error = failure;
      _errorStackTrace = stackTrace;
      _setState(ColmapOperationalState.cancelled);
    } catch (failure, stackTrace) {
      acceptStageUpdates = false;
      if (!_isCurrent(generation)) return;
      _error = failure;
      _errorStackTrace = stackTrace;
      _setState(ColmapOperationalState.failed);
    } finally {
      acceptStageUpdates = false;
      if (_isCurrent(generation)) _cancellation = null;
    }
  }

  void cancel() {
    _ensureUsable();
    if (_state != ColmapOperationalState.running) return;
    _cancellation?.cancel();
    _setState(ColmapOperationalState.cancelling);
  }

  void _clearOperation() {
    _reports = const [];
    _result = null;
    _error = null;
    _errorStackTrace = null;
  }

  bool _isCurrent(int generation) => !isDisposed && generation == _generation;

  void _setState(ColmapOperationalState value) {
    if (isDisposed) return;
    _state = value;
    _notify();
  }

  void _notify() {
    if (!isDisposed) notifyListeners();
  }

  void _ensureUsable() {
    if (isDisposed) throw StateError('Controller is disposed');
  }

  @override
  void dispose() {
    if (isDisposed) return;
    _generation++;
    _cancellation?.cancel();
    _cancellation = null;
    _state = ColmapOperationalState.disposed;
    super.dispose();
  }
}
