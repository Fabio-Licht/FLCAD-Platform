import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../core/cad_document/cad_document_repository.dart';
import 'command_context.dart';
import 'command_registry.dart';

typedef CommandJournalWriter = void Function(File file, String line);
typedef CommandOperationGate = Future<void> Function();

class CommandExecutionRecord {
  const CommandExecutionRecord({
    required this.commandId,
    required this.module,
    required this.parameters,
    required this.result,
    required this.timestamp,
    required this.durationMicros,
    required this.operation,
  });
  final String commandId;
  final String module;
  final Map<String, Object?> parameters;
  final String result;
  final DateTime timestamp;
  final int durationMicros;
  final String operation;
  Map<String, Object?> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'command': commandId,
    'module': module,
    'parameters': parameters,
    'result': result,
    'durationMicros': durationMicros,
    'operation': operation,
  };
}

class CommandTraceEvent {
  const CommandTraceEvent({
    required this.operationId,
    required this.commandId,
    required this.operation,
    required this.stage,
    required this.elapsedMicros,
  });

  final String operationId;
  final String commandId;
  final String operation;
  final String stage;
  final int elapsedMicros;

  Map<String, Object> toJson() => {
    'operationId': operationId,
    'commandId': commandId,
    'operation': operation,
    'stage': stage,
    'elapsedMicros': elapsedMicros,
  };

  @override
  String toString() =>
      '$operationId $commandId:$operation $stage ${elapsedMicros}us';
}

class CommandManager {
  CommandManager({
    required this.registry,
    DateTime Function()? clock,
    int Function()? durationProvider,
    this.traceSink,
    this.journalWriter,
    this.operationGate,
  }) : clock = clock ?? DateTime.now,
       durationProvider = durationProvider ?? (() => 0);

  /// Internal command trace key used by the controller. It is removed before
  /// validation, execution and journal serialization.
  static const traceOperationIdKey = '_flcadOperationId';

  final CommandRegistry registry;
  final DateTime Function() clock;
  final int Function() durationProvider;
  final void Function(CommandTraceEvent event)? traceSink;
  final CommandJournalWriter? journalWriter;
  final CommandOperationGate? operationGate;
  final List<_ExecutedCommand> _undo = [];
  final List<_ExecutedCommand> _redo = [];
  Future<void> _historyTail = Future<void>.value();
  int _pendingHistoryOperations = 0;
  final List<String> _activeCommandIds = <String>[];
  Completer<void>? _idleCompleter;
  final List<CommandExecutionRecord> history = [];
  final List<CommandTraceEvent> trace = <CommandTraceEvent>[];
  final Stopwatch _traceClock = Stopwatch()..start();
  int _operationSequence = 0;
  String? lastCompletedOperationId;
  Object? lastPersistenceFailure;
  Object? lastRecoveryFailure;

  /// Set when a command throws before it is applied and no checkpoint exists.
  /// The manager does not claim the domain was restored.
  Object? lastUncheckpointedFailure;
  bool get persistenceHealthy => lastPersistenceFailure == null;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoDepth => _undo.length;
  int get redoDepth => _redo.length;
  bool get hasPendingOperations =>
      _activeCommandIds.isNotEmpty || _pendingHistoryOperations > 0;
  List<String> get activeCommandIds =>
      List<String>.unmodifiable(_activeCommandIds);
  Future<void> get idle => !hasPendingOperations
      ? Future<void>.value()
      : (_idleCompleter ??= Completer<void>()).future;

  Future<Object?> execute(
    String id,
    CommandContext context, [
    Map<String, Object?> parameters = const {},
  ]) async {
    await _awaitOperationGate();
    final suppliedOperationId = parameters[traceOperationIdKey];
    if (suppliedOperationId != null) {
      parameters.remove(traceOperationIdKey);
    }
    final operationId = suppliedOperationId is String
        ? suppliedOperationId
        : 'command-${DateTime.now().microsecondsSinceEpoch}-${++_operationSequence}';
    _activeCommandIds.add(id);
    _emit(operationId, id, 'execute', 'enqueue');
    return _serializeHistory(operationId, id, 'execute', () async {
      try {
        final result = await _execute(operationId, id, context, parameters);
        lastCompletedOperationId = operationId;
        _emit(operationId, id, 'execute', 'future.complete');
        return result;
      } finally {
        _activeCommandIds.remove(id);
        _completeIdleIfIdle();
        _emit(operationId, id, 'execute', 'active.released');
      }
    });
  }

  Future<Object?> _execute(
    String operationId,
    String id,
    CommandContext context,
    Map<String, Object?> parameters,
  ) async {
    final command = registry.resolve(id);
    _emit(operationId, id, 'execute', 'command.resolve');
    final validation = command.validator?.call(context, parameters);
    if (validation != null && !validation.isValid) {
      throw StateError(validation.message!);
    }
    final undoBefore = List<_ExecutedCommand>.of(_undo);
    final redoBefore = List<_ExecutedCommand>.of(_redo);
    final executed = _ExecutedCommand(command, context, parameters);
    Object? result;
    var applied = false;
    var hasEffect = true;
    final restoreFailedExecute = await _captureCheckpoint(
      operationId,
      id,
      'execute',
      command,
      context,
      parameters,
    );
    _emit(operationId, id, 'execute', 'command.begin');
    try {
      result = await command.execute(context, parameters);
      applied = true;
      _emit(operationId, id, 'execute', 'command.end');
      hasEffect = command.hasEffect?.call(result, parameters) ?? true;
      if (hasEffect) {
        await _record(
          operationId,
          command,
          context,
          parameters,
          result,
          'execute',
        );
      } else {
        _emit(operationId, id, 'execute', 'no-op');
      }
    } catch (error, stackTrace) {
      _emit(operationId, id, 'execute', 'failure');
      if (applied) {
        await _rollbackDomain(
          operationId: operationId,
          commandId: id,
          operation: 'execute',
          context: context,
          parameters: parameters,
          inverse: command.undo,
          original: error,
          originalStack: stackTrace,
        );
      } else if (restoreFailedExecute != null) {
        await _rollbackDomain(
          operationId: operationId,
          commandId: id,
          operation: 'execute',
          context: context,
          parameters: parameters,
          inverse: (_, _) => restoreFailedExecute(),
          original: error,
          originalStack: stackTrace,
        );
      } else {
        _noteUncheckpointedFailure(
          operation: 'execute',
          commandId: id,
          original: error,
        );
      }
      _restoreStacks(undoBefore, redoBefore);
      rethrow;
    }
    if (command.undoable && hasEffect) {
      _undo.add(executed);
      _redo.clear();
    }
    _emit(operationId, id, 'execute', 'stacks.committed');
    return result;
  }

  Future<Object?> undo([String? operationId]) async {
    await _awaitOperationGate();
    final id =
        operationId ??
        'undo-${DateTime.now().microsecondsSinceEpoch}-${++_operationSequence}';
    final commandId = _undo.lastOrNull?.command.id ?? '<empty>';
    return _serializeHistory(id, commandId, 'undo', () => _undoLast(id));
  }

  Future<Object?> _undoLast(String operationId) async {
    if (_undo.isEmpty) throw StateError('There is no command to undo.');
    final executed = _undo.last;
    final undoBefore = List<_ExecutedCommand>.of(_undo);
    final redoBefore = List<_ExecutedCommand>.of(_redo);
    Object? result;
    var applied = false;
    final restoreFailedUndo = await _captureCheckpoint(
      operationId,
      executed.command.id,
      'undo',
      executed.command,
      executed.context,
      executed.parameters,
    );
    _emit(operationId, executed.command.id, 'undo', 'command.begin');
    try {
      result = await executed.command.undo(
        executed.context,
        executed.parameters,
      );
      applied = true;
      _emit(operationId, executed.command.id, 'undo', 'command.end');
      await _record(
        operationId,
        executed.command,
        executed.context,
        executed.parameters,
        result,
        'undo',
      );
    } catch (error, stackTrace) {
      _emit(operationId, executed.command.id, 'undo', 'failure');
      if (applied) {
        await _rollbackDomain(
          operationId: operationId,
          commandId: executed.command.id,
          operation: 'undo',
          context: executed.context,
          parameters: executed.parameters,
          inverse: executed.command.redo,
          original: error,
          originalStack: stackTrace,
        );
      } else if (restoreFailedUndo != null) {
        await _rollbackDomain(
          operationId: operationId,
          commandId: executed.command.id,
          operation: 'undo',
          context: executed.context,
          parameters: executed.parameters,
          inverse: (_, _) => restoreFailedUndo(),
          original: error,
          originalStack: stackTrace,
        );
      } else {
        _noteUncheckpointedFailure(
          operation: 'undo',
          commandId: executed.command.id,
          original: error,
        );
      }
      _restoreStacks(undoBefore, redoBefore);
      rethrow;
    }
    _undo.removeLast();
    _redo.add(executed);
    _emit(operationId, executed.command.id, 'undo', 'stacks.committed');
    lastCompletedOperationId = operationId;
    _emit(operationId, executed.command.id, 'undo', 'future.complete');
    return result;
  }

  Future<Object?> redo([String? operationId]) async {
    await _awaitOperationGate();
    final id =
        operationId ??
        'redo-${DateTime.now().microsecondsSinceEpoch}-${++_operationSequence}';
    final commandId = _redo.lastOrNull?.command.id ?? '<empty>';
    return _serializeHistory(id, commandId, 'redo', () => _redoLast(id));
  }

  Future<Object?> _redoLast(String operationId) async {
    if (_redo.isEmpty) throw StateError('There is no command to redo.');
    final executed = _redo.last;
    final undoBefore = List<_ExecutedCommand>.of(_undo);
    final redoBefore = List<_ExecutedCommand>.of(_redo);
    Object? result;
    var applied = false;
    final restoreFailedRedo = await _captureCheckpoint(
      operationId,
      executed.command.id,
      'redo',
      executed.command,
      executed.context,
      executed.parameters,
    );
    _emit(operationId, executed.command.id, 'redo', 'command.begin');
    try {
      result = await executed.command.redo(
        executed.context,
        executed.parameters,
      );
      applied = true;
      _emit(operationId, executed.command.id, 'redo', 'command.end');
      await _record(
        operationId,
        executed.command,
        executed.context,
        executed.parameters,
        result,
        'redo',
      );
    } catch (error, stackTrace) {
      _emit(operationId, executed.command.id, 'redo', 'failure');
      if (applied) {
        await _rollbackDomain(
          operationId: operationId,
          commandId: executed.command.id,
          operation: 'redo',
          context: executed.context,
          parameters: executed.parameters,
          inverse: executed.command.undo,
          original: error,
          originalStack: stackTrace,
        );
      } else if (restoreFailedRedo != null) {
        await _rollbackDomain(
          operationId: operationId,
          commandId: executed.command.id,
          operation: 'redo',
          context: executed.context,
          parameters: executed.parameters,
          inverse: (_, _) => restoreFailedRedo(),
          original: error,
          originalStack: stackTrace,
        );
      } else {
        _noteUncheckpointedFailure(
          operation: 'redo',
          commandId: executed.command.id,
          original: error,
        );
      }
      _restoreStacks(undoBefore, redoBefore);
      rethrow;
    }
    _redo.removeLast();
    _undo.add(executed);
    _emit(operationId, executed.command.id, 'redo', 'stacks.committed');
    lastCompletedOperationId = operationId;
    _emit(operationId, executed.command.id, 'redo', 'future.complete');
    return result;
  }

  Future<T> _serializeHistory<T>(
    String operationId,
    String commandId,
    String kind,
    Future<T> Function() operation,
  ) {
    final completer = Completer<T>();
    _pendingHistoryOperations++;
    _emit(operationId, commandId, kind, 'history.queued');
    _historyTail = _historyTail.catchError((Object _) {}).then((_) async {
      _emit(operationId, commandId, kind, 'history.begin');
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _pendingHistoryOperations--;
        _emit(operationId, commandId, kind, 'history.end');
        _completeIdleIfIdle();
      }
    });
    return completer.future;
  }

  Future<void> _awaitOperationGate() async {
    final gate = operationGate;
    if (gate != null) await gate();
  }

  void _completeIdleIfIdle() {
    if (hasPendingOperations) return;
    _idleCompleter?.complete();
    _idleCompleter = null;
    if (lastCompletedOperationId case final operationId?) {
      _emit(operationId, '<manager>', 'idle', 'complete');
    }
  }

  Future<void> _record(
    String operationId,
    RegisteredEngineeringCommand command,
    CommandContext context,
    Map<String, Object?> parameters,
    Object? result,
    String operation,
  ) async {
    final record = CommandExecutionRecord(
      commandId: command.id,
      module: command.module,
      parameters: parameters,
      result: result?.toString() ?? 'completed',
      timestamp: clock(),
      durationMicros: durationProvider(),
      operation: operation,
    );
    final root = context.projectDirectory;
    _emit(operationId, command.id, operation, 'record.begin');
    if (root == null) {
      history.add(record);
      lastPersistenceFailure = null;
      _emit(operationId, command.id, operation, 'history.published');
      return;
    }
    try {
      _emit(operationId, command.id, operation, 'journal.begin');
      await _writeRecord(root, operation, record);
      _emit(operationId, command.id, operation, 'journal.end');
    } catch (error, stack) {
      lastPersistenceFailure = CommandPersistenceFailure(
        operation: operation,
        cause: error,
        stack: stack,
      );
      _emit(operationId, command.id, operation, 'journal.failed');
      throw lastPersistenceFailure!;
    }
    history.add(record);
    lastPersistenceFailure = null;
    _emit(operationId, command.id, operation, 'history.published');
  }

  Future<void> _writeRecord(
    Directory root,
    String operation,
    CommandExecutionRecord record,
  ) async {
    final folder = switch (operation) {
      'undo' => 'UndoHistory',
      'redo' => 'RedoHistory',
      _ => 'CommandHistory',
    };
    await const CadDocumentRepository().withProjectLock(root, () async {
      final directory = Directory(path.join(root.path, 'CAD', folder));
      directory.createSync(recursive: true);
      final journal = File(path.join(directory.path, 'history.jsonl'));
      _repairJournal(journal);
      final previousLength = journal.existsSync() ? journal.lengthSync() : 0;
      final line = '${jsonEncode(record.toJson())}\n';
      try {
        final writer = journalWriter;
        if (writer != null) {
          writer(journal, line);
        } else {
          _appendJournal(journal, line);
        }
      } catch (_) {
        _truncateJournal(journal, previousLength);
        rethrow;
      }
    });
  }

  /// Repairs unconfirmed JSONL tails left by process termination. Confirmed
  /// complete records remain byte-for-byte unchanged.
  Future<void> recoverJournals(Directory root) =>
      const CadDocumentRepository().withProjectLock(root, () async {
        for (final folder in const [
          'CommandHistory',
          'UndoHistory',
          'RedoHistory',
        ]) {
          _repairJournal(
            File(path.join(root.path, 'CAD', folder, 'history.jsonl')),
          );
        }
      });

  void _appendJournal(File journal, String line) {
    journal.writeAsStringSync(line, mode: FileMode.append, flush: true);
  }

  void _repairJournal(File journal) {
    if (!journal.existsSync()) return;
    final bytes = journal.readAsBytesSync();
    var validEnd = 0;
    var start = 0;
    while (start < bytes.length) {
      final newline = bytes.indexOf(10, start);
      if (newline < 0) break;
      final lineBytes = bytes.sublist(start, newline);
      if (lineBytes.isEmpty) {
        validEnd = newline + 1;
        start = newline + 1;
        continue;
      }
      try {
        final decoded = jsonDecode(utf8.decode(lineBytes));
        if (decoded is! Map) break;
      } on Object {
        break;
      }
      validEnd = newline + 1;
      start = newline + 1;
    }
    if (validEnd == bytes.length) return;
    _truncateJournal(journal, validEnd);
  }

  void _truncateJournal(File journal, int length) {
    if (!journal.existsSync()) {
      if (length > 0) throw StateError('Command journal disappeared.');
      return;
    }
    if (journal.lengthSync() <= length) return;
    final handle = journal.openSync(mode: FileMode.append);
    try {
      handle.truncateSync(length);
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
  }

  Future<Future<void> Function()?> _captureCheckpoint(
    String operationId,
    String commandId,
    String operation,
    RegisteredEngineeringCommand command,
    CommandContext context,
    Map<String, Object?> parameters,
  ) async {
    final checkpoint = command.checkpoint;
    if (checkpoint == null) return null;
    _emit(operationId, commandId, operation, 'checkpoint.begin');
    final restore = await checkpoint(context, parameters);
    _emit(operationId, commandId, operation, 'checkpoint.end');
    return restore;
  }

  void _noteUncheckpointedFailure({
    required String operation,
    required String commandId,
    required Object original,
  }) {
    lastUncheckpointedFailure = CommandUncheckpointedFailure(
      operation: operation,
      commandId: commandId,
      original: original,
    );
  }

  Future<void> _rollbackDomain({
    required String operationId,
    required String commandId,
    required String operation,
    required CommandContext context,
    required Map<String, Object?> parameters,
    required CommandAction inverse,
    required Object original,
    required StackTrace originalStack,
  }) async {
    _emit(operationId, commandId, operation, 'domain.rollback.begin');
    try {
      await inverse(context, parameters);
      _emit(operationId, commandId, operation, 'domain.rollback.end');
    } catch (recovery, recoveryStack) {
      lastRecoveryFailure = CommandRecoveryFailure(
        operation: operation,
        original: original,
        recovery: recovery,
        originalStack: originalStack,
        recoveryStack: recoveryStack,
      );
      _emit(operationId, commandId, operation, 'domain.rollback.failed');
      Error.throwWithStackTrace(lastRecoveryFailure!, originalStack);
    }
  }

  void _restoreStacks(
    List<_ExecutedCommand> undo,
    List<_ExecutedCommand> redo,
  ) {
    _undo
      ..clear()
      ..addAll(undo);
    _redo
      ..clear()
      ..addAll(redo);
  }

  void _emit(
    String operationId,
    String commandId,
    String operation,
    String stage,
  ) {
    final event = CommandTraceEvent(
      operationId: operationId,
      commandId: commandId,
      operation: operation,
      stage: stage,
      elapsedMicros: _traceClock.elapsedMicroseconds,
    );
    trace.add(event);
    if (trace.length > 512) trace.removeAt(0);
    try {
      traceSink?.call(event);
    } on Object {
      // Diagnostics must never change the command transaction outcome.
    }
  }
}

class CommandPersistenceFailure implements Exception {
  const CommandPersistenceFailure({
    required this.operation,
    required this.cause,
    required this.stack,
  });
  final String operation;
  final Object cause;
  final StackTrace stack;

  @override
  String toString() => 'Command persistence failed during $operation: $cause';
}

class CommandRecoveryFailure implements Exception {
  const CommandRecoveryFailure({
    required this.operation,
    required this.original,
    required this.recovery,
    required this.originalStack,
    required this.recoveryStack,
  });
  final String operation;
  final Object original;
  final Object recovery;
  final StackTrace originalStack;
  final StackTrace recoveryStack;

  @override
  String toString() =>
      'Command $operation failed and its domain rollback also failed: '
      '$original; recovery: $recovery';
}

/// A command threw before it was applied and no checkpoint was registered.
/// The manager restored its own stacks and left the domain as the command
/// left it. This is a visible failure, not a claimed rollback.
class CommandUncheckpointedFailure implements Exception {
  const CommandUncheckpointedFailure({
    required this.operation,
    required this.commandId,
    required this.original,
  });

  final String operation;
  final String commandId;
  final Object original;

  @override
  String toString() =>
      'Command $commandId failed during $operation without a checkpoint. '
      'Changes made before the failure were not rolled back: $original';
}

class _ExecutedCommand {
  const _ExecutedCommand(this.command, this.context, this.parameters);
  final RegisteredEngineeringCommand command;
  final CommandContext context;
  final Map<String, Object?> parameters;
}
