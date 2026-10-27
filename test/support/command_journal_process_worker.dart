import 'dart:convert';
import 'dart:io';

import 'package:flcad_mobile/app/commands/command_context.dart';
import 'package:flcad_mobile/app/commands/command_manager.dart';
import 'package:flcad_mobile/app/commands/command_registry.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) exit(64);
  final mode = args[0];
  final project = Directory(args[1]);
  final registry = CommandRegistry()
    ..register(
      RegisteredEngineeringCommand(
        id: 'audit.command',
        module: 'Test',
        execute: (_, _) async => 'confirmed',
        undo: (_, _) async => 'undo',
        redo: (_, _) async => 'redo',
      ),
    );
  final context = CommandContext(
    projectId: 'journal-process',
    projectDirectory: project,
  );

  if (mode == 'crash' || mode == 'lock') {
    final manager = CommandManager(
      registry: registry,
      journalWriter: (file, line) {
        if (mode == 'crash') {
          file.writeAsStringSync(
            line.substring(0, line.length ~/ 2),
            mode: FileMode.append,
            flush: true,
          );
          stdout.writeln('READY:partial-journal');
        } else {
          file.writeAsStringSync(line, mode: FileMode.append, flush: true);
          stdout.writeln('READY:journal-locked');
        }
        stdout.flush();
        stdin.readLineSync();
      },
    );
    await manager.execute('audit.command', context);
    exit(mode == 'crash' ? 70 : 0);
  }

  final manager = CommandManager(registry: registry);
  if (mode == 'concurrent') {
    stdout.writeln('STARTED');
    await stdout.flush();
  }
  await manager.recoverJournals(project);
  if (mode == 'append') {
    await manager.execute('audit.command', context);
  } else if (mode == 'concurrent') {
    await manager.execute('audit.command', context);
  }
  final journal = File(
    '${project.path}${Platform.pathSeparator}CAD'
    '${Platform.pathSeparator}CommandHistory'
    '${Platform.pathSeparator}history.jsonl',
  );
  final lines = journal.existsSync()
      ? journal
            .readAsLinesSync()
            .where((line) => line.isNotEmpty)
            .map((line) => Map<String, dynamic>.from(jsonDecode(line) as Map))
            .toList()
      : <Map<String, dynamic>>[];
  stdout.writeln(
    jsonEncode({
      'count': lines.length,
      'commands': lines.map((line) => line['command']).toList(),
      'operations': lines.map((line) => line['operation']).toList(),
    }),
  );
}
