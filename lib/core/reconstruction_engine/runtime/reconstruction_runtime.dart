import 'dart:async';
import 'dart:isolate';

import '../backend/reconstruction_backend_contract.dart';
import '../engine/reconstruction_engine.dart';
import '../models/reconstruction_contract.dart';

typedef ReconstructionIsolateSpawner = Future<Isolate> Function(
  Future<void> Function(Map<String, dynamic>) entry,
  Map<String, dynamic> message,
  SendPort errorPort,
);

Future<Isolate> _spawnReconstructionIsolate(
  Future<void> Function(Map<String, dynamic>) entry,
  Map<String, dynamic> message,
  SendPort errorPort,
) => Isolate.spawn(entry, message, onError: errorPort);

class ReconstructionCancellationToken implements ReconstructionCancellation {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};

  @override
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void _addListener(void Function() listener) {
    _listeners.add(listener);
    if (_cancelled) listener();
  }

  void _removeListener(void Function() listener) => _listeners.remove(listener);
}

class ReconstructionRuntime {
  ReconstructionRuntime({
    ReconstructionIsolateSpawner spawnIsolate = _spawnReconstructionIsolate,
  }) : _spawnIsolate = spawnIsolate;

  final ReconstructionIsolateSpawner _spawnIsolate;
  _RuntimeOperation? _active;

  Stream<ReconstructionStageReport> get progress => _progress.stream;
  final StreamController<ReconstructionStageReport> _progress =
      StreamController<ReconstructionStageReport>.broadcast(sync: true);

  Future<ReconstructionOutput> start(
    ReconstructionRequest request, {
    ReconstructionCancellationToken? cancellation,
  }) async {
    await stop();
    if (cancellation?.isCancelled ?? false) {
      throw const ReconstructionCancelled();
    }
    final operation = _RuntimeOperation();
    _active = operation;
    final operationResult = operation.completer.future;
    // Cancellation can happen while Isolate.spawn is still pending. Observe
    // the internal future immediately so that its error is not reported as
    // unhandled before start() reaches the final await below.
    operationResult.ignore();
    void cancelFromToken() => operation.cancel();
    cancellation?._addListener(cancelFromToken);

    operation.replySubscription = operation.replies.listen((message) {
      if (message is SendPort) {
        operation.control = message;
        return;
      }
      if (message is! Map || operation.completer.isCompleted) return;
      final data = message.cast<String, dynamic>();
      if (data['kind'] == 'stage') {
        _progress.add(
          ReconstructionStageReport.fromJson(
            (data['data'] as Map).cast<String, dynamic>(),
          ),
        );
      } else if (data['kind'] == 'result') {
        operation.completer.complete(
          ReconstructionOutput.fromJson(
            (data['data'] as Map).cast<String, dynamic>(),
          ),
        );
      } else if (data['kind'] == 'error') {
        operation.completer.completeError(
          StateError(data['message'] as String),
        );
      }
    });
    operation.errorSubscription = operation.errors.listen((message) {
      if (!operation.completer.isCompleted) {
        operation.completer.completeError(message);
      }
    });
    try {
      operation.attachIsolate(
        await _spawnIsolate(
          _entry,
          {
            'reply': operation.replies.sendPort,
            'request': request.toJson(),
          },
          operation.errors.sendPort,
        ),
      );
      return await operationResult;
    } finally {
      cancellation?._removeListener(cancelFromToken);
      await operation.close();
      if (identical(_active, operation)) _active = null;
    }
  }

  void cancel() => _active?.cancel();

  Future<void> stop() async {
    final operation = _active;
    if (operation == null) return;
    _active = null;
    operation.cancel();
    await operation.close();
  }

  Future<void> dispose() async {
    await stop();
    await _progress.close();
  }

  static Future<void> _entry(Map<String, dynamic> message) async {
    final reply = message['reply'] as SendPort;
    final control = ReceivePort();
    final cancellation = ReconstructionCancellationToken();
    control.listen((command) {
      if (command == 'cancel') cancellation.cancel();
    });
    reply.send(control.sendPort);
    try {
      final request = ReconstructionRequest.fromJson(
        (message['request'] as Map).cast<String, dynamic>(),
      );
      final output = await const ReconstructionEngine().run(
        request,
        cancellation: cancellation,
        onStage: (report) =>
            reply.send({'kind': 'stage', 'data': report.toJson()}),
      );
      reply.send({'kind': 'result', 'data': output.toJson()});
    } on ReconstructionCancelled {
      reply.send({'kind': 'error', 'message': 'Reconstruction cancelled'});
    } catch (error) {
      reply.send({'kind': 'error', 'message': error.toString()});
    } finally {
      control.close();
    }
  }
}

class _RuntimeOperation {
  final ReceivePort replies = ReceivePort();
  final ReceivePort errors = ReceivePort();
  final Completer<ReconstructionOutput> completer =
      Completer<ReconstructionOutput>();
  StreamSubscription<dynamic>? replySubscription;
  StreamSubscription<dynamic>? errorSubscription;
  Isolate? isolate;
  SendPort? control;
  bool _closed = false;

  void attachIsolate(Isolate spawnedIsolate) {
    if (_closed) {
      spawnedIsolate.kill(priority: Isolate.immediate);
      return;
    }
    isolate = spawnedIsolate;
  }

  void cancel() {
    control?.send('cancel');
    if (!completer.isCompleted) {
      completer.completeError(const ReconstructionCancelled());
    }
    isolate?.kill(priority: Isolate.immediate);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    isolate?.kill(priority: Isolate.immediate);
    await replySubscription?.cancel();
    await errorSubscription?.cancel();
    replies.close();
    errors.close();
    isolate = null;
    control = null;
  }
}
