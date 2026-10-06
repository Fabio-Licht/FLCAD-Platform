import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/professional_extrude/professional_extrude.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<(DesktopCadController, OperationalReverseEngineeringController)> open(
    Directory directory,
    String projectId, {
    GeometryKernelAPI? kernel,
  }) async {
    final projects = ProjectRepository(
      storage: LocalStorageService(rootDirectory: directory),
    );
    final kernels = KernelManager()
      ..register(kernel ?? _UnsupportedKernel(), makeDefault: true);
    final cad = DesktopCadController(
      kernels: kernels,
      projects: ProjectManager.instance,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    final controller = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
      referenceApi: ReferenceApi(
        engine: ReferenceEngine(
          repository: ReferenceRepository(projects: projects),
        ),
      ),
    );
    addTearDown(controller.dispose);
    addTearDown(cad.dispose);
    await cad.runtime.open(projectId, directory);
    await controller.configureProject(
      projectId: projectId,
      projectDirectory: directory,
    );
    return (cad, controller);
  }

  Future<OperationalReverseEngineeringController> openWithSketch(
    Directory directory,
    String projectId,
  ) async {
    final (_, controller) = await open(directory, projectId);
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch();
    await controller.drawRectangle(
      const SketchVector(0, 0),
      const SketchVector(2, 2),
    );
    return controller;
  }

  test(
    'no selected source reports a clear diagnostic before any kernel use',
    () async {
      final directory = await Directory.systemTemp.createTemp('g143c_none_');
      addTearDown(() => directory.delete(recursive: true));
      final (_, controller) = await open(directory, 'g143c-none');

      expect(controller.selectedExtrudeSource, isNull);
      expect(controller.canPreviewExtrude, isFalse);

      await expectLater(
        controller.previewProfessionalExtrude(),
        throwsA(isA<StateError>()),
      );
      expect(
        controller.error,
        'Select one Sketch or Surface to start Extrude.',
      );
    },
  );

  test('a valid Sketch is accepted as an Extrude source', () async {
    final directory = await Directory.systemTemp.createTemp('g143c_src_');
    addTearDown(() => directory.delete(recursive: true));
    final controller = await openWithSketch(directory, 'g143c-src');

    final sketchId = controller.activeSketch!.id;
    controller.selectExtrudeSource(sketchId);

    expect(controller.selectedExtrudeSource, isNotNull);
    expect(controller.selectedExtrudeSource!.id, sketchId);
    expect(controller.canPreviewExtrude, isTrue);
  });

  test('changing a parameter keeps a still-relevant diagnostic', () async {
    final directory = await Directory.systemTemp.createTemp('g143c_keep_');
    addTearDown(() => directory.delete(recursive: true));
    final controller = await openWithSketch(directory, 'g143c-keep');

    // A failed attempt publishes a diagnostic.
    controller.error = 'Solid / Cylinder exige um perfil fechado.';
    await controller.updateProfessionalExtrudePreview(distance: 25);

    // No preview yet, so the update is a no-op, and the diagnostic must remain
    // visible until a new attempt, a new selection, or Cancel.
    expect(controller.error, 'Solid / Cylinder exige um perfil fechado.');
  });

  test('selecting a new source clears the previous diagnostic', () async {
    final directory = await Directory.systemTemp.createTemp('g143c_sel_');
    addTearDown(() => directory.delete(recursive: true));
    final controller = await openWithSketch(directory, 'g143c-sel');

    controller.error = 'diagnostico antigo';
    controller.selectExtrudeSource(controller.activeSketch!.id);
    expect(controller.error, isNull);
  });

  test('Cancel clears the diagnostic and the transient preview', () async {
    final directory = await Directory.systemTemp.createTemp('g143c_cancel_');
    addTearDown(() => directory.delete(recursive: true));
    final controller = await openWithSketch(directory, 'g143c-cancel');

    controller.error = 'diagnostico pendente';
    controller.cancelProfessionalExtrude();
    expect(controller.error, isNull);
    expect(controller.professionalExtrudePreview, isNull);
  });

  test('a native/kernel failure surfaces through controller.error', () async {
    final directory = await Directory.systemTemp.createTemp('g143c_kern_');
    addTearDown(() => directory.delete(recursive: true));
    final controller = await openWithSketch(directory, 'g143c-kern');

    final sketchId = controller.activeSketch!.id;
    controller.selectExtrudeSource(sketchId);

    // The registered kernel does not implement WIRE/EXTRUDE, so the attempt
    // fails; the failure must be published instead of swallowed.
    await expectLater(
      controller.previewProfessionalExtrude(
        output: ProfessionalExtrudeOutput.surface,
      ),
      throwsA(anything),
    );
    expect(controller.error, isNotNull);
    expect(controller.error, isNotEmpty);
  });

  test(
    'closed reconstructed arc profile extrudes only its visible active loop',
    () async {
      final directory = await Directory.systemTemp.createTemp('g143c-arc_');
      addTearDown(() => directory.delete(recursive: true));
      final kernel = _RecordingKernel();
      final (_, controller) = await open(
        directory,
        'g143c-arc',
        kernel: kernel,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      final api = controller.sketchApi!;
      final arc = api.builders.arc.build(
        const SketchVector(1, 0),
        1,
        3.141592653589793,
        0,
      );
      api.builders.line.build(
        const SketchVector(2, 0),
        const SketchVector(2, 2),
      );
      api.builders.line.build(
        const SketchVector(2, 2),
        const SketchVector(0, 2),
      );
      api.builders.line.build(
        const SketchVector(0, 2),
        const SketchVector(0, 0),
      );
      final hiddenOriginal = api.builders.line.build(
        const SketchVector(50, 50),
        const SketchVector(51, 50),
      )..visible = false;
      await controller.finishSketch();
      final sketch = controller.activeSketch!;
      controller.selectExtrudeSource(sketch.id);

      await controller.previewProfessionalExtrude(distance: 5);

      expect(controller.professionalExtrudePreview, isNotNull);
      expect(
        controller.professionalExtrudePreview!['contract']['profileEntityIds'],
        contains(arc.id),
      );
      expect(kernel.operations, contains('CREATE WIRE'));
      expect(
        kernel.persistentIds.any((id) => id.contains(hiddenOriginal.id)),
        isFalse,
      );

      // A single persisted profile must be resolved again on Preview update and
      // feature re-entry, not fall through to an empty resolvedLoops list.
      await controller.updateProfessionalExtrudePreview(
        distance: 7,
        draftAngleDegrees: 2,
      );
      expect(
        (controller.professionalExtrudePreview!['contract'] as Map)['distance'],
        7,
      );
      final featureId = controller.professionalExtrudePreview!['id'] as String;
      await controller.confirmProfessionalExtrude();
      await controller.reenterProfessionalExtrude(featureId);
      expect(controller.professionalExtrudePreview, isNotNull);
      expect(
        (controller.professionalExtrudePreview!['contract'] as Map)['distance'],
        7,
      );
    },
  );

  test(
    'Surface without an explicit selection uses only the visible active wire',
    () async {
      final directory = await Directory.systemTemp.createTemp('g143c-surface_');
      addTearDown(() => directory.delete(recursive: true));
      final kernel = _RecordingKernel();
      final (_, controller) = await open(
        directory,
        'g143c-surface',
        kernel: kernel,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      final visible = controller.sketchApi!.builders.arc.build(
        const SketchVector(0, 1),
        1,
        3.141592653589793,
        0,
      );
      final hidden = controller.sketchApi!.builders.line.build(
        const SketchVector(50, 0),
        const SketchVector(51, 0),
      )..visible = false;
      await controller.finishSketch();
      controller.selectExtrudeSource(controller.activeSketch!.id);

      await controller.previewProfessionalExtrude(
        distance: 3,
        output: ProfessionalExtrudeOutput.surface,
      );

      final contract = Map<String, dynamic>.from(
        controller.professionalExtrudePreview!['contract'] as Map,
      );
      expect(contract['profileEntityIds'], [visible.id]);
      expect(kernel.operations, contains('CREATE WIRE'));
      expect(kernel.persistentIds.any((id) => id.contains(hidden.id)), isFalse);
    },
  );

  test('solid single line profile uses the official Sketch wire in global '
      'coordinates with a deterministic profileEntityIds order', () async {
    final directory = await Directory.systemTemp.createTemp('g143c-line_');
    addTearDown(() => directory.delete(recursive: true));
    final kernel = _RecordingKernel();
    final (cad, controller) = await open(
      directory,
      'g143c-line',
      kernel: kernel,
    );
    // An oriented support plane makes local != global, so a Wire built from
    // raw local samples would land away from the Sketch.
    controller.selectWorldSketchPlane(SketchPlaneType.yz);
    await controller.openSketch();
    await controller.drawRectangle(
      const SketchVector(0, 0),
      const SketchVector(2, 3),
    );
    await controller.finishSketch();
    final sketch = controller.activeSketch!;
    final expectedOrder = List<String>.from(sketch.entityIds);
    controller.selectExtrudeSource(sketch.id);

    await controller.previewProfessionalExtrude(distance: 5);

    final contract = Map<String, dynamic>.from(
      controller.professionalExtrudePreview!['contract'] as Map,
    );
    expect(contract['profileEntityIds'], expectedOrder);
    expect(kernel.operations, contains('CREATE WIRE'));

    final expectedGlobal = <SketchVector>[];
    for (final id in expectedOrder) {
      final line = controller.sketchApi!.entity(id)! as SketchLine;
      for (final key in const ['start', 'end']) {
        final global = sketch.coordinates.localToGlobal(
          SketchVector.fromJson(line.parameters[key]),
        );
        if (!expectedGlobal.any(
          (point) => (point - global).dot(point - global) <= 1e-9,
        )) {
          expectedGlobal.add(global);
        }
      }
    }
    expect(expectedGlobal, hasLength(4));
    expect(kernel.vertexPositions, hasLength(4));
    for (final global in expectedGlobal) {
      expect(
        kernel.vertexPositions.any(
          (position) =>
              (position.x - global.x).abs() <= 1e-6 &&
              (position.y - global.y).abs() <= 1e-6 &&
              (position.z - global.z).abs() <= 1e-6,
        ),
        isTrue,
        reason: 'wire vertex missing at ${global.x},${global.y},${global.z}',
      );
    }

    // Distance and Draft updates re-resolve without reordering the profile.
    await controller.updateProfessionalExtrudePreview(
      distance: 7,
      draftAngleDegrees: 2,
    );
    final updated = Map<String, dynamic>.from(
      controller.professionalExtrudePreview!['contract'] as Map,
    );
    expect(updated['distance'], 7);
    expect(updated['draftAngleDegrees'], 2);
    expect(updated['profileEntityIds'], expectedOrder);

    // Confirm, Save/Open and re-enter: the official wire and the ordered
    // profile must survive the round trip.
    final featureId = controller.professionalExtrudePreview!['id'] as String;
    await controller.confirmProfessionalExtrude();
    await cad.runtime.save();
    await cad.runtime.open('g143c-line', directory);
    await controller.configureProject(
      projectId: 'g143c-line',
      projectDirectory: directory,
    );
    await controller.reenterProfessionalExtrude(featureId);
    final reentered = Map<String, dynamic>.from(
      controller.professionalExtrudePreview!['contract'] as Map,
    );
    expect(reentered['distance'], 7);
    expect(reentered['profileEntityIds'], expectedOrder);
  });

  test('construction, reference and hidden entities are excluded from an '
      'implicit solid profile', () async {
    final directory = await Directory.systemTemp.createTemp('g143c-filter_');
    addTearDown(() => directory.delete(recursive: true));
    final kernel = _RecordingKernel();
    final (_, controller) = await open(
      directory,
      'g143c-filter',
      kernel: kernel,
    );
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch();
    await controller.drawRectangle(
      const SketchVector(0, 0),
      const SketchVector(4, 4),
    );
    final construction = controller.sketchApi!.builders.circle.build(
      const SketchVector(2, 2),
      9,
    )..construction = true;
    final reference = controller.sketchApi!.builders.line.build(
      const SketchVector(-10, 0),
      const SketchVector(10, 0),
    )..reference = true;
    final hidden = controller.sketchApi!.builders.line.build(
      const SketchVector(0, -10),
      const SketchVector(0, 10),
    )..visible = false;
    await controller.finishSketch();
    final sketch = controller.activeSketch!;
    final rectangleIds = sketch.entityIds
        .where(
          (id) =>
              id != construction.id && id != reference.id && id != hidden.id,
        )
        .toList(growable: false);
    controller.selectExtrudeSource(sketch.id);

    await controller.previewProfessionalExtrude(distance: 3);

    final contract = Map<String, dynamic>.from(
      controller.professionalExtrudePreview!['contract'] as Map,
    );
    expect(contract['profileEntityIds'], rectangleIds);
    for (final excluded in [construction.id, reference.id, hidden.id]) {
      expect(contract['profileEntityIds'], isNot(contains(excluded)));
    }
  });

  test(
    'Surface without a visible active profile reports a clear diagnostic',
    () async {
      final directory = await Directory.systemTemp.createTemp('g143c-novis_');
      addTearDown(() => directory.delete(recursive: true));
      final kernel = _RecordingKernel();
      final (_, controller) = await open(
        directory,
        'g143c-novis',
        kernel: kernel,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      controller.sketchApi!.builders.line
              .build(const SketchVector(0, 0), const SketchVector(2, 0))
              .visible =
          false;
      await controller.finishSketch();
      controller.selectExtrudeSource(controller.activeSketch!.id);

      await expectLater(
        controller.previewProfessionalExtrude(
          distance: 3,
          output: ProfessionalExtrudeOutput.surface,
        ),
        throwsA(isA<StateError>()),
      );
      expect(controller.error, contains('Surface / Walls'));
      expect(kernel.operations, isNot(contains('CREATE WIRE')));
    },
  );

  test(
    'a branched surface profile is reported as geometry, not a Draft failure',
    () async {
      final directory = await Directory.systemTemp.createTemp('g143c-branch_');
      addTearDown(() => directory.delete(recursive: true));
      final kernel = _RecordingKernel();
      final (_, controller) = await open(
        directory,
        'g143c-branch',
        kernel: kernel,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(2, 0),
      );
      controller.sketchApi!.builders.line.build(
        const SketchVector(2, 0),
        const SketchVector(4, 0),
      );
      controller.sketchApi!.builders.line.build(
        const SketchVector(2, 0),
        const SketchVector(2, 2),
      );
      await controller.finishSketch();
      controller.selectExtrudeSource(controller.activeSketch!.id);

      await expectLater(
        controller.previewProfessionalExtrude(
          distance: 3,
          output: ProfessionalExtrudeOutput.surface,
          draftAngleDegrees: 5,
        ),
        throwsA(isA<StateError>()),
      );
      expect(controller.error, contains('Surface / Walls'));
      expect(controller.error, contains('ramificações'));
      expect(controller.error!.toLowerCase(), isNot(contains('draft')));
    },
  );

  test(
    'a closed spline profile extrudes as a loop instead of a degenerate curve',
    () async {
      final directory = await Directory.systemTemp.createTemp('g143c-spline_');
      addTearDown(() => directory.delete(recursive: true));
      final kernel = _RecordingKernel();
      final (_, controller) = await open(
        directory,
        'g143c-spline',
        kernel: kernel,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      final spline = controller.sketchApi!.builders.spline.build(const [
        SketchVector(0, 0),
        SketchVector(3, 0),
        SketchVector(3, 3),
        SketchVector(0, 3),
        SketchVector(0, 0),
      ]);
      await controller.finishSketch();
      controller.selectExtrudeSource(controller.activeSketch!.id);

      await controller.previewProfessionalExtrude(distance: 4);

      final contract = Map<String, dynamic>.from(
        controller.professionalExtrudePreview!['contract'] as Map,
      );
      expect(contract['profileEntityIds'], [spline.id]);
      expect(kernel.operations, contains('CREATE WIRE'));
      expect(controller.error, isNull);
    },
  );

  test('a full 360 degree arc is extruded as a closed loop', () async {
    final directory = await Directory.systemTemp.createTemp('g143c-arc360_');
    addTearDown(() => directory.delete(recursive: true));
    final kernel = _RecordingKernel();
    final (_, controller) = await open(
      directory,
      'g143c-arc360',
      kernel: kernel,
    );
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch();
    final arc = controller.sketchApi!.builders.arc.build(
      const SketchVector(0, 0),
      2,
      0,
      2 * math.pi,
    );
    await controller.finishSketch();
    controller.selectExtrudeSource(controller.activeSketch!.id);

    await controller.previewProfessionalExtrude(distance: 4);

    final contract = Map<String, dynamic>.from(
      controller.professionalExtrudePreview!['contract'] as Map,
    );
    expect(contract['profileEntityIds'], [arc.id]);
    expect(kernel.operations, contains('CREATE WIRE'));
    expect(controller.error, isNull);
  });

  test(
    'a closing gap under the sketch tolerance is materialized as a closed wire',
    () async {
      final directory = await Directory.systemTemp.createTemp('g143c-gap_');
      addTearDown(() => directory.delete(recursive: true));
      final kernel = _RecordingKernel();
      final (_, controller) = await open(
        directory,
        'g143c-gap',
        kernel: kernel,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      final api = controller.sketchApi!;
      // The closure stops 5e-5 mm short of the first vertex: coincident for
      // the Sketch/profile tolerance (1e-4) but far above the former 1e-7
      // Wire threshold, which accepted the profile as closed and then built
      // it as an open wire.
      const gap = 5e-5;
      api.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(2, 0),
      );
      api.builders.line.build(
        const SketchVector(2, 0),
        const SketchVector(2, 2),
      );
      api.builders.line.build(
        const SketchVector(2, 2),
        const SketchVector(0, 2),
      );
      api.builders.line.build(
        const SketchVector(0, 2),
        const SketchVector(0, gap),
      );
      await controller.finishSketch();
      controller.selectExtrudeSource(controller.activeSketch!.id);

      await controller.previewProfessionalExtrude(distance: 4);

      final contract = Map<String, dynamic>.from(
        controller.professionalExtrudePreview!['contract'] as Map,
      );
      expect(contract['profileEntityIds'], hasLength(4));
      expect(kernel.operations, contains('CREATE WIRE'));
      // A closed wire reuses the first vertex and drops the coincident final
      // sample (4 vertices); an open wire would keep all 5.
      expect(
        kernel.operations.where((operation) => operation == 'CREATE VERTEX'),
        hasLength(4),
      );
      expect(controller.error, isNull);
    },
  );

  test(
    'a legacy Extrude that only stored profileEntityId re-enters by expanding '
    'the seed',
    () async {
      final directory = await Directory.systemTemp.createTemp('g143c-legacy_');
      addTearDown(() => directory.delete(recursive: true));
      final kernel = _RecordingKernel();
      final (cad, controller) = await open(
        directory,
        'g143c-legacy',
        kernel: kernel,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      await controller.drawRectangle(
        const SketchVector(0, 0),
        const SketchVector(2, 2),
      );
      await controller.finishSketch();
      final sketch = controller.activeSketch!;
      final lineIds = List<String>.from(sketch.entityIds);
      controller.selectExtrudeSource(sketch.id);
      await controller.previewProfessionalExtrude(distance: 6);
      final featureId = controller.professionalExtrudePreview!['id'] as String;
      await controller.confirmProfessionalExtrude();

      // Simulate a pre-multi-profile contract: keep only profileEntityId.
      final entity = cad.runtime.document!.entities[featureId]!;
      final feature = Map<String, dynamic>.from(
        entity.data['extrudeFeature'] as Map,
      );
      final contract = Map<String, dynamic>.from(feature['contract'] as Map)
        ..['profileEntityIds'] = const <String>[]
        ..['profileEntityId'] = lineIds.first;
      feature['contract'] = contract;
      feature.remove('profileSelectionEntityIds');
      feature.remove('profileSelectionGroups');
      final data = Map<String, dynamic>.from(entity.data)
        ..['extrudeFeature'] = feature
        ..remove('profileEntityIds')
        ..remove('profileSelectionGroups');
      await cad.runtime.mutate(
        command: 'test.legacy-extrude',
        upsert: [
          CadDocumentEntity(
            id: entity.id,
            kind: entity.kind,
            shape: entity.shape,
            mesh: entity.mesh,
            data: data,
          ),
        ],
      );

      await controller.reenterProfessionalExtrude(featureId);

      final reentered = Map<String, dynamic>.from(
        controller.professionalExtrudePreview!['contract'] as Map,
      );
      expect(reentered['distance'], 6);
      expect(reentered['profileEntityIds'], lineIds);
    },
  );

  test(
    'document undo and redo restore a confirmed single-profile extrude',
    () async {
      final directory = await Directory.systemTemp.createTemp('g143c-undo_');
      addTearDown(() => directory.delete(recursive: true));
      final kernel = _RecordingKernel();
      final (cad, controller) = await open(
        directory,
        'g143c-undo',
        kernel: kernel,
      );
      controller.selectWorldSketchPlane(SketchPlaneType.xy);
      await controller.openSketch();
      await controller.drawRectangle(
        const SketchVector(0, 0),
        const SketchVector(2, 2),
      );
      await controller.finishSketch();
      controller.selectExtrudeSource(controller.activeSketch!.id);
      await controller.previewProfessionalExtrude(distance: 5);
      final featureId = controller.professionalExtrudePreview!['id'] as String;
      await controller.confirmProfessionalExtrude();
      expect(cad.runtime.document!.entities[featureId], isNotNull);

      // The durable Undo/Redo step for a confirmed Feature is the document
      // history (the controller command stack holds the earlier Sketch
      // commands, so `controller.undo()` alone would revert those first).
      await cad.runtime.undoDocument();
      expect(cad.runtime.document!.entities[featureId], isNull);

      await cad.runtime.redoDocument();
      expect(cad.runtime.document!.entities[featureId], isNotNull);
    },
  );
}

class _UnsupportedKernel
    implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'g143c-unsupported',
    name: 'G-143C unsupported kernel',
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

class _RecordingKernel implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  final operations = <String>[];
  final persistentIds = <String>[];
  final vertexPositions = <SketchVector>[];

  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'g143c-recording',
    name: 'G-143C recording kernel',
    version: '1',
    capabilities: KernelCapabilities({}),
    vendor: 'FLCAD',
  );

  @override
  Future<void> begin(KernelTransaction transaction) async {}

  @override
  Future<void> commit(KernelTransaction transaction) async {}

  @override
  Future<ShapeHandle> create(
    String operation,
    Map<String, dynamic> parameters, {
    required String persistentId,
    required CADShapeType expectedType,
    required KernelTransaction transaction,
  }) async {
    operations.add(operation);
    persistentIds.add(persistentId);
    if (operation == 'CREATE VERTEX') {
      vertexPositions.add(
        SketchVector(
          (parameters['x'] as num).toDouble(),
          (parameters['y'] as num).toDouble(),
          (parameters['z'] as num).toDouble(),
        ),
      );
    }
    return ShapeHandle.reference(
      persistentId: persistentId,
      kernelId: descriptor.id,
      type: expectedType,
    );
  }

  @override
  Future<KernelHealth> healthCheck() async =>
      KernelHealth(KernelHealthStatus.healthy, 'ok', DateTime(2000));

  @override
  Future<void> rollback(KernelTransaction transaction) async {}

  @override
  Future<void> unload() async {}

  @override
  Future<List<String>> validate(ShapeHandle handle, Set<String> checks) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
