import 'dart:async';
import 'dart:io';

import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';

CadDocumentEntity _stepEntity({String name = 'Bracket'}) => CadDocumentEntity(
  id: 'step-entity',
  kind: CadDocumentEntityKind.import,
  data: {'name': name, 'format': 'step'},
);

Future<
  ({ProjectManager projects, ProjectRepository repository, Directory root})
>
_projectContext() async {
  final root = await Directory.systemTemp.createTemp('flcad-step-command-');
  final repository = ProjectRepository(
    storage: LocalStorageService(rootDirectory: root),
  );
  final projects = ProjectManager(repository: repository);
  await projects.create(name: 'STEP command', client: 'FLCAD');
  return (projects: projects, repository: repository, root: root);
}

void main() {
  group('managed STEP desktop command', () {
    test('requires an active project before it opens the picker', () async {
      var pickerCalls = 0;
      final root = await Directory.systemTemp.createTemp('flcad-step-command-');
      addTearDown(() => root.delete(recursive: true));
      final controller = DesktopCadController(
        kernels: KernelManager(),
        projects: ProjectManager(
          repository: ProjectRepository(
            storage: LocalStorageService(rootDirectory: root),
          ),
        ),
        managedStepFilePicker: (_) async {
          pickerCalls++;
          return r'C:\secret\part.step';
        },
      );
      addTearDown(controller.dispose);

      expect(controller.canImportManagedStep, isFalse);
      await controller.pickAndImportManagedStep();

      expect(pickerCalls, 0);
      expect(
        controller.message,
        'Abra ou crie um projeto antes de importar STEP.',
      );
    });

    test(
      'uses only STEP extensions and leaves state untouched on picker cancel',
      () async {
        final context = await _projectContext();
        addTearDown(() => context.root.delete(recursive: true));
        List<String>? extensions;
        final controller = DesktopCadController(
          kernels: KernelManager(),
          projects: context.projects,
          projectRepository: context.repository,
          managedStepFilePicker: (value) async {
            extensions = value;
            return null;
          },
        );
        addTearDown(controller.dispose);

        await controller.pickAndImportManagedStep();

        expect(extensions, ['step', 'stp']);
        expect(controller.runtime.document, isNull);
        expect(controller.runtime.scene.entities, isEmpty);
        expect(controller.runtime.geometrySelection.selectedIds, isEmpty);
        expect(controller.managedStepOperationActive, isFalse);
        expect(controller.message, isNull);
      },
    );

    test(
      'prevents a second picker while the first STEP command is active',
      () async {
        final context = await _projectContext();
        addTearDown(() => context.root.delete(recursive: true));
        final pickerGate = Completer<String?>();
        var pickerCalls = 0;
        final controller = DesktopCadController(
          kernels: KernelManager(),
          projects: context.projects,
          projectRepository: context.repository,
          managedStepFilePicker: (_) {
            pickerCalls++;
            return pickerGate.future;
          },
        );
        addTearDown(controller.dispose);
        final first = controller.pickAndImportManagedStep();
        final second = controller.pickAndImportManagedStep();
        expect(pickerCalls, 1);
        expect(controller.managedStepOperationActive, isTrue);
        pickerGate.complete(null);
        await Future.wait([first, second]);

        expect(controller.managedStepOperationActive, isFalse);
        expect(controller.runtime.document, isNull);
      },
    );

    test(
      'uses the managed runtime admission, selects the result, and stays busy',
      () async {
        final context = await _projectContext();
        addTearDown(() => context.root.delete(recursive: true));
        final importGate = Completer<CadDocumentEntity>();
        final importStarted = Completer<void>();
        String? admittedLocator;
        var openerCalls = 0;
        final controller = DesktopCadController(
          kernels: KernelManager(),
          projects: context.projects,
          projectRepository: context.repository,
          managedStepFilePicker: (_) async => r'C:\incoming\bracket.step',
          managedStepProjectOpener: (_, _) async => openerCalls++,
          managedStepImporter: (locator, _) {
            admittedLocator = locator;
            importStarted.complete();
            return importGate.future;
          },
        );
        addTearDown(controller.dispose);
        controller.runtime.scene.upsert(
          const CadSceneEntity(
            id: 'step-entity',
            kind: CadSceneEntityKind.mesh,
            geometry: {},
          ),
        );

        final operation = controller.pickAndImportManagedStep();
        await importStarted.future;
        expect(openerCalls, 1);
        expect(admittedLocator, r'C:\incoming\bracket.step');
        expect(controller.isBusy, isTrue);
        expect(controller.canImportManagedStep, isFalse);
        expect(controller.canCancelManagedStepImport, isTrue);

        importGate.complete(_stepEntity());
        await operation;

        expect(controller.runtime.geometrySelection.selectedIds, {
          'step-entity',
        });
        expect(controller.message, 'Peça STEP "Bracket" importada.');
        expect(controller.isBusy, isFalse);
      },
    );

    test(
      'cancellation returns to normal without publishing an error',
      () async {
        final context = await _projectContext();
        addTearDown(() => context.root.delete(recursive: true));
        final importGate = Completer<CadDocumentEntity>();
        final importStarted = Completer<void>();
        final controller = DesktopCadController(
          kernels: KernelManager(),
          projects: context.projects,
          projectRepository: context.repository,
          managedStepFilePicker: (_) async => r'C:\incoming\part.stp',
          managedStepProjectOpener: (_, _) async {},
          managedStepImporter: (_, _) {
            importStarted.complete();
            return importGate.future;
          },
        );
        addTearDown(controller.dispose);

        final operation = controller.pickAndImportManagedStep();
        await importStarted.future;
        controller.cancelManagedStepImport();
        importGate.completeError(StateError(r'C:\incoming\part.stp internal'));
        await operation;

        expect(controller.message, 'Importação STEP cancelada.');
        expect(controller.runtime.geometrySelection.selectedIds, isEmpty);
        expect(controller.isBusy, isFalse);
      },
    );

    test(
      'failure does not change selection or expose the selected pathname',
      () async {
        final context = await _projectContext();
        addTearDown(() => context.root.delete(recursive: true));
        final controller = DesktopCadController(
          kernels: KernelManager(),
          projects: context.projects,
          projectRepository: context.repository,
          managedStepFilePicker: (_) async => r'C:\private\bad.step',
          managedStepProjectOpener: (_, _) async {},
          managedStepImporter: (_, _) => Future<CadDocumentEntity>.error(
            StateError(r'C:\private\bad.step token=42'),
          ),
        );
        addTearDown(controller.dispose);
        controller.runtime.scene.upsert(
          const CadSceneEntity(
            id: 'existing-selection',
            kind: CadSceneEntityKind.mesh,
            geometry: {},
          ),
        );
        controller.runtime.select({'existing-selection'});

        await controller.pickAndImportManagedStep();

        expect(controller.runtime.document, isNull);
        expect(controller.runtime.scene.entities.map((entity) => entity.id), {
          'existing-selection',
        });
        expect(controller.runtime.geometrySelection.selectedIds, {
          'existing-selection',
        });
        expect(controller.message, isNot(contains(r'C:\private')));
        expect(controller.message, isNot(contains('token=42')));
        expect(controller.message, contains('Não foi possível importar'));
      },
    );

    test(
      'the STEP command route is registered once and uses the managed flow',
      () async {
        final context = await _projectContext();
        addTearDown(() => context.root.delete(recursive: true));
        var managedCalls = 0;
        final controller = DesktopCadController(
          kernels: KernelManager(),
          projects: context.projects,
          projectRepository: context.repository,
          managedStepFilePicker: (_) async => r'C:\incoming\route.step',
          managedStepProjectOpener: (_, _) async {},
          managedStepImporter: (_, _) async {
            managedCalls++;
            return _stepEntity();
          },
        );
        addTearDown(controller.dispose);
        controller.runtime.scene.upsert(
          const CadSceneEntity(
            id: 'step-entity',
            kind: CadSceneEntityKind.mesh,
            geometry: {},
          ),
        );
        final commands = DesktopCommandCoordinator(
          cad: controller,
          projects: context.projects,
          repository: context.repository,
        );
        await commands.refreshContext();

        expect(
          commands.registry.commands.where(
            (command) => command.id == 'import.step',
          ),
          hasLength(1),
        );
        await commands.dispatch('import.step');

        expect(managedCalls, 1);
        expect(controller.runtime.geometrySelection.selectedIds, {
          'step-entity',
        });
      },
    );
  });
}
