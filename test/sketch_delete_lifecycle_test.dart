import 'dart:io';

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'recycling the active Sketch detaches the edit session safely',
    () async {
      final directory = await Directory.systemTemp.createTemp('sketch-delete-');
      addTearDown(() => directory.delete(recursive: true));
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProvider,
            (call) async => directory.path,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null),
      );
      final projects = ProjectRepository(
        storage: LocalStorageService(rootDirectory: directory),
      );
      final cad = DesktopCadController(
        kernels: KernelManager()..register(_HealthyKernel(), makeDefault: true),
        projects: ProjectManager.instance,
        projectRepository: projects,
      );
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
      );
      final controller = OperationalReverseEngineeringController(
        recognition: ProfessionalRecognitionApi(),
        commands: commands,
        runtime: cad.runtime,
      );
      addTearDown(controller.dispose);
      addTearDown(cad.dispose);

      await cad.runtime.open('sketch-delete-project', directory);
      await controller.configureProject(
        projectId: 'sketch-delete-project',
        projectDirectory: directory,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch(forceNew: true);
      final sketchId = controller.activeSketch!.id;
      cad.runtime.select({sketchId});

      await controller.deleteToRecycleBin(sketchId, includeDependencies: true);

      expect(controller.activeSketch, isNull);
      expect(controller.selectedSketchEntityIds, isEmpty);
      expect(cad.runtime.selection, isEmpty);
      expect(cad.runtime.document!.entities[sketchId]!.data['deleted'], true);

      await controller.openSketch(forceNew: true);
      expect(controller.activeSketch, isNotNull);
      expect(controller.activeSketch!.id, isNot(sketchId));
    },
  );
}

class _HealthyKernel implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'sketch-delete-healthy',
    name: 'Sketch delete test kernel',
    version: '1',
    capabilities: KernelCapabilities({}),
    vendor: 'FLCAD',
  );

  @override
  Future<KernelHealth> healthCheck() async =>
      KernelHealth(KernelHealthStatus.healthy, 'ok', DateTime(2000));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
