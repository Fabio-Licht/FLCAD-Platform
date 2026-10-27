import 'command_context.dart';
import 'command_validation.dart';

typedef CommandAction =
    Future<Object?> Function(
      CommandContext context,
      Map<String, Object?> parameters,
    );
typedef CommandEffect =
    bool Function(Object? result, Map<String, Object?> parameters);

/// Captures a domain snapshot before execute, undo, or redo.
/// The returned function restores that snapshot. CommandManager calls it when
/// that operation throws before it is considered applied, so a mutation that
/// escapes as an exception does not remain committed.
typedef CommandCheckpoint =
    Future<Future<void> Function()> Function(
      CommandContext context,
      Map<String, Object?> parameters,
    );

class RegisteredEngineeringCommand {
  const RegisteredEngineeringCommand({
    required this.id,
    required this.module,
    required this.execute,
    required this.undo,
    required this.redo,
    this.validator,
    this.undoable = true,
    this.hasEffect,
    this.checkpoint,
  });
  final String id;
  final String module;
  final CommandAction execute;
  final CommandAction undo;
  final CommandAction redo;
  final CommandValidator? validator;
  final bool undoable;

  /// Lets a command execute and validate without changing history when the
  /// requested operation is already satisfied. Commands that omit this stay
  /// fully backward compatible and always record their execution.
  final CommandEffect? hasEffect;

  /// When set, a failure before the operation is applied restores this
  /// snapshot. The same closure covers execute, undo, and redo. Commands that
  /// omit it do not get a domain rollback; the original error still propagates.
  final CommandCheckpoint? checkpoint;
}

class CommandRegistry {
  final Map<String, RegisteredEngineeringCommand> _commands = {};
  Iterable<RegisteredEngineeringCommand> get commands => _commands.values;

  void register(RegisteredEngineeringCommand command) {
    if (_commands.containsKey(command.id)) {
      throw StateError('Command already registered: ${command.id}');
    }
    _commands[command.id] = command;
  }

  bool contains(String id) => _commands.containsKey(id);

  /// Removes a previously registered command.  Callers own the lifecycle of
  /// the ids they registered, so removing an unknown id is a contract
  /// violation rather than something to ignore.
  void unregister(String id) {
    if (_commands.remove(id) == null) {
      throw StateError('Command is not registered: $id');
    }
  }

  RegisteredEngineeringCommand resolve(String id) {
    final command = _commands[id];
    if (command == null) throw StateError('Command is not registered: $id');
    return command;
  }
}
