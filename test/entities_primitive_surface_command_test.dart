import 'dart:io';

import 'package:flcad_mobile/app/entities/entity_primitive_surface_service.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Entidades · Superfícies primitivas manuais', () {
    late Directory directory;
    late _PrimitiveKernel kernel;
    late CadRuntime runtime;
    late EntityPrimitiveSurfaceService surfaces;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('manual_surfaces_');
      kernel = _PrimitiveKernel();
      runtime = CadRuntime(
        kernels: KernelManager()..register(kernel, makeDefault: true),
      );
      await runtime.open('project', directory);
      surfaces = EntityPrimitiveSurfaceService(runtime);
    });

    tearDown(() async {
      runtime.dispose();
      await directory.delete(recursive: true);
    });

    test(
      'creates all five B-Rep primitives without mesh or region input',
      () async {
        for (final type in PrimitiveSurfaceType.values) {
          final id = await surfaces.create(type: type);
          final entity = runtime.document!.entities[id]!;
          expect(entity.shape, isNotNull);
          expect(entity.shape!.type, CADShapeType.face);
          expect(entity.data['constructionEntity']['meshRequired'], isFalse);
          expect(entity.data['constructionEntity']['primitive'], type.name);
          expect(entity.data['sourceEntityIds'], isNull);
        }
        expect(kernel.operations, [
          'GENERATE PLANE',
          'GENERATE CYLINDER',
          'GENERATE CONE',
          'GENERATE SPHERE',
          'GENERATE TORUS',
        ]);
        expect(kernel.commits, 5);
        expect(kernel.persistedPaths, hasLength(5));
        expect(
          kernel.persistedPaths.every(
            (value) => !RegExp(
              r'[<>:"|?*]',
            ).hasMatch(Uri.file(value, windows: true).pathSegments.last),
          ),
          isTrue,
        );
        expect(runtime.canUndo, isTrue);
      },
    );

    test('normalizes directions and preserves analytic parameters', () async {
      final cylinder = await surfaces.create(
        type: PrimitiveSurfaceType.cylinder,
        origin: const Vector3(1, 2, 3),
        direction: const Vector3(0, 0, 5),
        radius: 7,
        height: 25,
      );
      final parameters = runtime
          .document!
          .entities[cylinder]!
          .data['constructionEntity']['parameters'];
      expect(parameters['axisOrigin'], [1.0, 2.0, 3.0]);
      expect(parameters['axisDirection'], [0.0, 0.0, 1.0]);
      expect(parameters['radius'], 7);
      expect(parameters['upperBound'], 25);
    });

    test(
      'rejects invalid definitions before starting a kernel transaction',
      () async {
        await expectLater(
          surfaces.create(
            type: PrimitiveSurfaceType.torus,
            majorRadius: 4,
            minorRadius: 5,
          ),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          surfaces.create(
            type: PrimitiveSurfaceType.cone,
            semiAngleDegrees: 90,
          ),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          surfaces.create(
            type: PrimitiveSurfaceType.plane,
            direction: Vector3.zero,
          ),
          throwsA(isA<StateError>()),
        );
        expect(kernel.operations, isEmpty);
      },
    );
  });
}

class _PrimitiveKernel implements PersistentGeometryKernelAPI {
  final operations = <String>[];
  final persistedPaths = <String>[];
  int commits = 0;

  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'primitive-test',
    name: 'Primitive Test Kernel',
    version: '1',
    vendor: 'FLCAD',
    capabilities: KernelCapabilities({
      KernelCapability.planeSurface,
      KernelCapability.cylinderSurface,
      KernelCapability.coneSurface,
      KernelCapability.sphereSurface,
      KernelCapability.torusSurface,
    }),
  );

  @override
  Future<KernelHealth> healthCheck() async =>
      KernelHealth(KernelHealthStatus.healthy, 'ok', DateTime.now());

  @override
  Future<void> begin(KernelTransaction transaction) async {}

  @override
  Future<void> commit(KernelTransaction transaction) async => commits++;

  @override
  Future<void> rollback(KernelTransaction transaction) async {}

  @override
  Future<ShapeHandle> create(
    String operation,
    Map<String, dynamic> parameters, {
    required String persistentId,
    required CADShapeType expectedType,
    required KernelTransaction transaction,
  }) async {
    operations.add(operation);
    return ShapeHandle.reference(
      persistentId: persistentId,
      kernelId: descriptor.id,
      type: expectedType,
      fingerprint: '$operation:${parameters.hashCode}',
    );
  }

  @override
  Future<List<String>> validate(ShapeHandle handle, Set<String> checks) async =>
      const [];

  @override
  Future<void> unload() async {}

  @override
  Future<void> persistShape(ShapeHandle handle, String payloadPath) async {
    persistedPaths.add(payloadPath);
  }

  @override
  Future<ShapeHandle> restoreShape(
    String payloadPath, {
    required String persistentId,
  }) async => ShapeHandle.reference(
    persistentId: persistentId,
    kernelId: descriptor.id,
    type: CADShapeType.face,
  );
}
