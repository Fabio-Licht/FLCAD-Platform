import 'dart:async';
import 'dart:isolate';

import '../engine/reconstruction_engine.dart';
import '../models/reconstruction_contract.dart';

class ReconstructionCancellationToken implements ReconstructionCancellation {
  bool _cancelled = false;
  @override
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class ReconstructionRuntime {
  Isolate? _isolate;
  SendPort? _control;

  Stream<ReconstructionStageReport> get progress => _progress.stream;
  final StreamController<ReconstructionStageReport> _progress =
      StreamController<ReconstructionStageReport>.broadcast();

  Future<ReconstructionOutput> start(
    ReconstructionRequest request, {
    ReconstructionCancellationToken? cancellation,
  }) async {
    await stop();
    final replies = ReceivePort();
    final errors = ReceivePort();
    final completer = Completer<ReconstructionOutput>();
    late final StreamSubscription replySubscription;
    late final StreamSubscription errorSubscription;
    replySubscription = replies.listen((message) {
      if (message is SendPort) {
        _control = message;
        return;
      }
      if (message is! Map) return;
      final data = message.cast<String, dynamic>();
      if (data['kind'] == 'stage') {
        _progress.add(
          ReconstructionStageReport.fromJson(
            (data['data'] as Map).cast<String, dynamic>(),
          ),
        );
      } else if (data['kind'] == 'result' && !completer.isCompleted) {
        completer.complete(
          ReconstructionOutput.fromJson(
            (data['data'] as Map).cast<String, dynamic>(),
          ),
        );
      } else if (data['kind'] == 'error' && !completer.isCompleted) {
        completer.completeError(StateError(data['message'] as String));
      }
    });
    errorSubscription = errors.listen((message) {
      if (!completer.isCompleted) completer.completeError(message);
    });
    _isolate = await Isolate.spawn(_entry, {
      'reply': replies.sendPort,
      'request': request.toJson(),
    }, onError: errors.sendPort);
    try {
      final output = await completer.future;
      if (cancellation?.isCancelled ?? false) {
        throw const ReconstructionCancelled();
      }
      return output;
    } finally {
      await replySubscription.cancel();
      await errorSubscription.cancel();
      replies.close();
      errors.close();
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _control = null;
    }
  }

  void cancel() => _control?.send('cancel');

  Future<void> stop() async {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _control = null;
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
