import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flcad_mobile/app/bootstrap/engineering_bootstrap.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/commands/command_registry.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/core/cad_document/cad_document_repository.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final rootPath = Platform.environment['FLCAD_STARTUP_ROOT'];

  test(
    'production coordinator repairs the journal before initialization returns',
    () async {
      final root = Directory(rootPath!);
      final projectId = Platform.environment['FLCAD_STARTUP_PROJECT_ID'];
      if (projectId == null || projectId.isEmpty) {
        throw StateError('FLCAD_STARTUP_PROJECT_ID is required.');
      }
      final repository = ProjectRepository(
        storage: LocalStorageService(rootDirectory: root),
      );
      final projectDirectory = await repository.directoryFor(projectId);
      final lockHeld = Completer<void>();
      final releaseLock = Completer<void>();
      final heldLock = const CadDocumentRepository().withProjectLock(
        projectDirectory,
        () async {
          lockHeld.complete();
          await releaseLock.future;
        },
      );
      await lockHeld.future;
      final projects = ProjectManager(repository: repository);
      final cad = DesktopCadController(
        kernels: KernelManager(),
        projects: projects,
        projectRepository: repository,
      );
      addTearDown(cad.dispose);
      EngineeringBootstrap.instance.initialize();
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: projects,
        repository: repository,
      );
      var gatedCommandRan = false;
      commands.registry.register(
        RegisteredEngineeringCommand(
          id: 'startup.audit',
          module: 'Startup',
          execute: (_, _) async => gatedCommandRan = true,
          undo: (_, _) async => null,
          redo: (_, _) async => null,
        ),
      );

      final initialization = commands.initialize();
      final gatedCommand = commands.dispatch('startup.audit');
      await Future<void>.delayed(Duration.zero);
      expect(gatedCommandRan, isFalse);
      releaseLock.complete();
      await heldLock;
      await initialization;
      await gatedCommand;

      final project = projects.current;
      expect(project, isNotNull);
      final directory = await repository.directoryFor(project!.id);
      final journal = File(
        '${directory.path}${Platform.pathSeparator}CAD'
        '${Platform.pathSeparator}CommandHistory'
        '${Platform.pathSeparator}history.jsonl',
      );
      final repaired =
          journal.existsSync() && journal.readAsStringSync().endsWith('\n');
      File(
        '${root.path}${Platform.pathSeparator}startup-result.json',
      ).writeAsStringSync(
        jsonEncode({
          'projectId': project.id,
          'repaired': repaired,
          'gatedCommandRan': gatedCommandRan,
          'historyCount': commands.manager.history.length,
          'canUndo': commands.manager.canUndo,
          'persistenceHealthy': commands.manager.persistenceHealthy,
        }),
        flush: true,
      );
      expect(repaired, isTrue);
    },
    skip: rootPath == null || rootPath.isEmpty
        ? 'FLCAD_STARTUP_ROOT is required.'
        : false,
  );
}
