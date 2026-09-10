import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/cad_document_repository.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final class _ManagedImportStorage extends CadAssetStorage {
  String? failAt;

  @override
  Future<void> checkpoint(String phase) async {
    if (phase == failAt) throw StateError('injected:$phase');
  }
}

final class _ManagedImportRepository extends CadDocumentRepository {
  bool rejectManagedSave = false;

  @override
  Future<void> save(CadDocument document, Directory project) {
    if (rejectManagedSave &&
        document.entities.values.any(
          (entity) => entity.data['managedBrepAssets'] != null,
        )) {
      throw StateError('injected:managedBrep:persistence');
    }
    return super.save(document, project);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final caf = Platform.environment['FLCAD_CAD_ASSET_FS_DLL']!;
  final occ = Platform.environment['FLCAD_SOURCE_OCC_DLL']!;
  final bridge = Platform.environment['FLCAD_SOURCE_BRIDGE_DLL']!;
  final fixture = Platform.environment['FLCAD_SOURCE_FIXTURE_EXE']!;
  late Directory root, sourceDirectory, project;
  late _ManagedImportStorage storage;
  late _ManagedImportRepository repository;
  late OpenCascadeKernelAdapter adapter;
  late CadRuntime runtime;
  late int Function() pathImports;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('managed-brep-runtime-');
    sourceDirectory = await Directory(
      p.join(Directory.systemTemp.path, 'cob-dart-${root.path.hashCode.abs()}'),
    ).create();
    project = await Directory(p.join(root.path, 'project')).create();
    final generated = await Process.run(fixture, [
      caf,
      occ,
      sourceDirectory.path,
    ]);
    expect(
      generated.exitCode,
      0,
      reason: '${generated.stdout}\n${generated.stderr}',
    );
    storage = _ManagedImportStorage();
    repository = _ManagedImportRepository();
    adapter = OpenCascadeKernelAdapter(bridge: OpenCascadeFFI.load(path: occ));
    final kernels = KernelManager()..register(adapter, makeDefault: true);
    runtime = CadRuntime(
      kernels: kernels,
      assetStorage: storage,
      repository: repository,
    );
    await runtime.open('managed-brep-project', project);
    pathImports = DynamicLibrary.open(occ)
        .lookupFunction<Uint64 Function(), int Function()>(
          'flcad_occ_test_path_import_count',
        );
  });

  tearDown(() async {
    await runtime.shutdown();
    await adapter.unload();
    await root.delete(recursive: true);
    await sourceDirectory.delete(recursive: true);
  });

  test(
    'real BREP commits document, scene, durable assets and custody',
    () async {
      final source = p.join(sourceDirectory.path, 'shape.brep');
      const existingId = 'existing-selection';
      await runtime.mutate(
        command: 'test.existing-selection',
        upsert: const [
          CadDocumentEntity(
            id: existingId,
            kind: CadDocumentEntityKind.vertex,
            data: {
              'sceneKind': 'point',
              'sceneGeometry': {
                'position': [0, 0, 0],
              },
            },
          ),
        ],
      );
      runtime.select({existingId});
      final first = await runtime.importManagedBrep(
        source,
        nativeBridgePath: bridge,
      );
      final second = await runtime.importManagedBrep(
        source,
        name: 'second managed shape',
        nativeBridgePath: bridge,
      );

      expect(first.id, isNot(second.id));
      expect(runtime.document!.entities[first.id], isNotNull);
      expect(runtime.document!.entities[second.id], isNotNull);
      expect(runtime.scene.find(first.id)?.geometry['nodes'], isNotEmpty);
      expect(runtime.scene.find(first.id)?.geometry['triangles'], isNotEmpty);
      expect(runtime.hasManagedGeometry(first.id), isTrue);
      expect(runtime.hasManagedGeometry(second.id), isTrue);
      expect(runtime.selection, {existingId});
      expect(adapter.custodyDiagnostics!.allocations, 4);
      expect(
        runtime.managedGeometryDiagnostics(first.id)!['shape'],
        isA<Map<String, dynamic>>(),
      );

      for (final entity in [first, second]) {
        expect(entity.shape, isNull);
        expect(entity.mesh, isNull);
        final assets = ManagedBrepAssets.fromJson(
          Map<String, dynamic>.from(entity.data['managedBrepAssets'] as Map),
        );
        final shape = File(
          p.join(
            project.path,
            'CAD',
            'Assets',
            'v1',
            assets.shape.value,
            CadAssetFile.brep.relativePath,
          ),
        );
        final display = File(
          p.join(
            project.path,
            'CAD',
            'Assets',
            'v1',
            assets.display.value,
            CadAssetFile.display.relativePath,
          ),
        );
        expect(await shape.exists(), isTrue);
        expect(await display.exists(), isTrue);
        expect(await shape.length(), greaterThan(0));
        expect(await display.length(), greaterThan(84));
        expect(
          (await sha256.bind(shape.openRead()).first).toString(),
          assets.shapeSha256,
        );
        expect(
          (await sha256.bind(display.openRead()).first).toString(),
          assets.displaySha256,
        );
      }

      final persisted = jsonDecode(
        await File(p.join(project.path, 'cad-document.json')).readAsString(),
      );
      final encoded = jsonEncode(persisted);
      for (final forbidden in [
        source,
        'sourcePath',
        'registeredPath',
        'ShapeHandle',
        'KernelMeshHandle',
        'token',
        'pointer',
        'capability',
      ]) {
        expect(encoded, isNot(contains(forbidden)));
      }
      expect(
        pathImports(),
        0,
        reason: 'Managed import must not use path importers',
      );
      final manifests = Directory(p.join(project.path, '.cad-staging'))
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => p.basename(file.path) == 'manifest.json')
          .map((file) => jsonDecode(file.readAsStringSync()) as Map)
          .toList();
      expect(manifests, hasLength(2));
      expect(
        manifests.every(
          (manifest) =>
              (manifest['data'] as Map)['state'] == 'committed' &&
              (manifest['data'] as Map)['documentPublished'] == true,
        ),
        isTrue,
      );
    },
  );

  test(
    'failure before promotion publishes no entity or runtime owner',
    () async {
      final before = jsonEncode(runtime.document!.toJson());
      storage.failAt = 'managedBrep:beforePromotion';
      await expectLater(
        runtime.importManagedBrep(
          p.join(sourceDirectory.path, 'shape.brep'),
          nativeBridgePath: bridge,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'phase',
            'injected:managedBrep:beforePromotion',
          ),
        ),
      );
      expect(jsonEncode(runtime.document!.toJson()), before);
      expect(
        runtime.scene.entities.where((entity) => entity.id.startsWith('e1_')),
        isEmpty,
      );
      expect(
        Directory(p.join(project.path, 'CAD', 'Assets', 'v1')).existsSync()
            ? Directory(p.join(project.path, 'CAD', 'Assets', 'v1'))
                  .listSync()
                  .whereType<Directory>()
                  .where((entry) => p.basename(entry.path).startsWith('ga1_'))
                  .toList()
            : const <Directory>[],
        isEmpty,
      );
      expect(pathImports(), 0);
    },
  );

  test(
    'failure after promotion quarantines assets without publication',
    () async {
      storage.failAt = 'managedBrep:afterPromotion';
      await expectLater(
        runtime.importManagedBrep(
          p.join(sourceDirectory.path, 'shape.brep'),
          nativeBridgePath: bridge,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'phase',
            'injected:managedBrep:afterPromotion',
          ),
        ),
      );
      expect(
        runtime.document!.entities.values.where(
          (entity) => entity.data['managedBrepAssets'] != null,
        ),
        isEmpty,
      );
      expect(
        runtime.scene.entities.where((entity) => entity.id.startsWith('e1_')),
        isEmpty,
      );
      final promoted = Directory(
        p.join(project.path, 'CAD', 'Assets', 'v1'),
      ).listSync().whereType<Directory>().toList();
      expect(promoted, hasLength(2));
      final manifests = Directory(p.join(project.path, '.cad-staging'))
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => p.basename(file.path) == 'manifest.json');
      expect(
        manifests,
        contains(
          predicate<File>((file) {
            final data = jsonDecode(file.readAsStringSync()) as Map;
            return (data['data'] as Map)['state'] == 'quarantined';
          }),
        ),
      );
    },
  );

  test(
    'persistence failure installs neither entity nor native ownership',
    () async {
      repository.rejectManagedSave = true;
      await expectLater(
        runtime.importManagedBrep(
          p.join(sourceDirectory.path, 'shape.brep'),
          nativeBridgePath: bridge,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'phase',
            'injected:managedBrep:persistence',
          ),
        ),
      );
      expect(
        runtime.document!.entities.values.where(
          (entity) => entity.data['managedBrepAssets'] != null,
        ),
        isEmpty,
      );
      expect(adapter.custodyDiagnostics!.allocations, 0);
      expect(
        Directory(p.join(project.path, 'CAD', 'Assets', 'v1')).listSync(),
        hasLength(2),
      );
    },
  );

  test(
    'observer failure after commit does not roll back managed import',
    () async {
      final previous = FlutterError.onError;
      final observed = <FlutterErrorDetails>[];
      FlutterError.onError = observed.add;
      runtime.addListener(() => throw StateError('observer failed'));
      try {
        final entity = await runtime.importManagedBrep(
          p.join(sourceDirectory.path, 'shape.brep'),
          nativeBridgePath: bridge,
        );
        await Future<void>.delayed(Duration.zero);
        expect(runtime.document!.entities[entity.id], isNotNull);
        expect(runtime.scene.find(entity.id), isNotNull);
        expect(runtime.hasManagedGeometry(entity.id), isTrue);
        expect(observed, hasLength(1));
        expect(
          observed.single.exceptionAsString(),
          contains('observer failed'),
        );
      } finally {
        FlutterError.onError = previous;
      }
    },
  );
}
