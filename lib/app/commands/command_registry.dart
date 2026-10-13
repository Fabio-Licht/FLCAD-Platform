import 'command_context.dart';
import 'command_validation.dart';

typedef CommandAction =
    Future<Object?> Function(
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
  });
  final String id;
  final String module;
  final CommandAction execute;
  final CommandAction undo;
  final CommandAction redo;
  final CommandValidator? validator;
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
