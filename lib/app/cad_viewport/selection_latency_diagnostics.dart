import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Development-only correlation for one selection gesture.
/// Durations use Stopwatch and are never derived from wall-clock time.
class SelectionLatencyOperation {
  SelectionLatencyOperation(this.id, {required bool enabled})
    : _enabled = enabled,
      _watch = Stopwatch()..start();

  final String id;
  final bool _enabled;
  final Stopwatch _watch;
  final Map<String, Map<String, Object?>> _stages = {};
  bool _finished = false;

  bool get enabled => _enabled;

  void mark(String stage, {Map<String, Object?> details = const {}}) {
    if (!_enabled || _finished) return;
    _stages[stage] = {
      'timestamp_monotonic_ms': _watch.elapsedMicroseconds / 1000,
      ...details,
    };
  }

  Map<String, Object?> finish({Map<String, Object?> details = const {}}) {
    if (!_finished) {
      _finished = true;
      _watch.stop();
    }
    return {
      'selection_operation_id': id,
      'duration_monotonic_ms': _watch.elapsedMicroseconds / 1000,
      'stages': Map<String, Object?>.from(_stages),
      ...details,
    };
  }
}

/// Process-local diagnostic registry. It is inert unless explicitly enabled.
abstract final class SelectionLatencyDiagnostics {
  static const enabled =
      kDebugMode && bool.fromEnvironment('FLCAD_DEV_SELECTION_LATENCY');
  static int _nextId = 0;
  static SelectionLatencyOperation? _latestPending;
  static Map<String, Object?>? lastSummary;
  static String? get currentOperationId => _latestPending?.id;

  static SelectionLatencyOperation? begin() {
    if (!enabled) return null;
    final operation = SelectionLatencyOperation(
      'selection-${(++_nextId).toString().padLeft(6, '0')}',
      enabled: true,
    );
    _latestPending = operation;
    operation.mark('pointer_received');
    return operation;
  }

  static SelectionLatencyOperation? claimLatestPending() {
    final operation = _latestPending;
    _latestPending = null;
    return operation;
  }

  static void complete(
    SelectionLatencyOperation? operation, {
    Map<String, Object?> details = const {},
  }) {
    if (operation == null) return;
    lastSummary = operation.finish(details: details);
    debugPrint('[selection-latency] ${jsonEncode(lastSummary)}');
  }

  @visibleForTesting
  static void resetForTesting() {
    _latestPending = null;
    lastSummary = null;
    _nextId = 0;
  }
}
