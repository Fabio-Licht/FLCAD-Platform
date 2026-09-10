import 'dart:async';
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
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final class _StlStorage extends CadAssetStorage {
  String? failAt;
  Future<void> Function(String phase)? onPhase;

  @override
  Future<void> checkpoint(String phase) async {
    await onPhase?.call(phase);
    if (phase == failAt) throw StateError('injected:$phase');
  }
}

final class _StlRepository extends CadDocumentRepository {
  bool rejectManagedStl = false;

  @override
  Future<void> save(CadDocument document, Directory project) {
    if (rejectManagedStl &&
        document.entities.values.any(
          (entity) => entity.data['managedStlAssets'] != null,
        )) {
      throw StateError('injected:managedStl:persistence');
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
  late _StlStorage storage;
  late _StlRepository repository;
  late OpenCascadeKernelAdapter adapter;
  late CadRuntime runtime;
  late int Function() pathImports;

  Future<CadDocumentEntity> importFile(String leaf) => runtime.importManagedStl(
    p.join(sourceDirectory.path, leaf),
    nativeBridgePath: bridge,
  );

  ManagedStlAssets assets(CadDocumentEntity entity) =>
      ManagedStlAssets.fromJson(
        Map<String, dynamic>.from(entity.data['managedStlAssets'] as Map),
      );

  List<Directory> durableAssets() {
    final root = Directory(p.join(project.path, 'CAD', 'Assets', 'v1'));
    return root.existsSync()
        ? root.listSync().whereType<Directory>().toList()
        : [];
  }

  List<Map> manifests() => Directory(p.join(project.path, '.cad-staging'))
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => p.basename(file.path) == 'manifest.json')
      .map((file) => jsonDecode(file.readAsStringSync()) as Map)
      .toList();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('managed-stl-runtime-');
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
    await File(p.join(sourceDirectory.path, 'ascii.stl')).writeAsString(
      'solid sample\n'
      'facet normal 0 0 1\nouter loop\n'
      'vertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\n'
      'endloop\nendfacet\nendsolid sample\n',
      flush: true,
    );
    storage = _StlStorage();
    repository = _StlRepository();
    adapter = OpenCascadeKernelAdapter(bridge: OpenCascadeFFI.load(path: occ));
    runtime = CadRuntime(
      kernels: KernelManager()..register(adapter, makeDefault: true),
      assetStorage: storage,
      repository: repository,
    );
    await runtime.open('managed-stl-project', project);
    pathImports = DynamicLibrary.open(occ)
        .lookupFunction<Uint64 Function(), int Function()>(
          'flcad_occ_test_path_import_count',
        );
  });

  tearDown(() async {
    await runtime.shutdown();
    expect(adapter.custodyDiagnostics?.leases ?? 0, 0);
    await adapter.unload();
    await root.delete(recursive: true);
    await sourceDirectory.delete(recursive: true);
  });

  test(
    'binary and ASCII STL publish independent managed mesh-only entities',
    () async {
      final binary = await importFile('display.stl');
      final ascii = await importFile('ascii.stl');

      expect(binary.id, isNot(ascii.id));
      expect(
        runtime.document!.entities.values.where(
          (entity) => entity.data['managedStlAssets'] != null,
        ),
        hasLength(2),
      );
      expect(adapter.custodyDiagnostics!.allocations, 2);
      expect(durableAssets(), hasLength(2));
      for (final entity in [binary, ascii]) {
        expect(entity.shape, isNull);
        expect(entity.mesh, isNull);
        expect(entity.data['managedBrepAssets'], isNull);
        final reference = assets(entity);
        expect(reference.toJson().keys.toSet(), {
          'schema',
          'version',
          'displayMeshAssetId',
          'displayMeshSha256',
          'meshOnly',
        });
        final payload = File(
          p.join(
            project.path,
            'CAD',
            'Assets',
            'v1',
            reference.display.value,
            CadAssetFile.display.relativePath,
          ),
        );
        expect(await payload.length(), greaterThan(84));
        expect(
          payload.parent
              .listSync(recursive: true)
              .whereType<File>()
              .map((file) => p.basename(file.path))
              .toSet(),
          {'display.stl', 'asset.json'},
        );
        expect(
          (await sha256.bind(payload.openRead()).first).toString(),
          reference.displaySha256,
        );
        final geometry = runtime.scene.find(entity.id)!.geometry;
        final nodes = (geometry['nodes'] as List).cast<double>();
        final triangles = (geometry['triangles'] as List).cast<int>();
        expect(nodes, isNotEmpty);
        expect(nodes.every((value) => value.isFinite), isTrue);
        expect(triangles.length % 3, 0);
        expect(
          triangles.every((index) => index >= 0 && index < nodes.length ~/ 3),
          isTrue,
        );
        expect(geometry['normalsOrigin'], 'calculatedByAdapter');
        expect(geometry['hasNativeVertexNormals'], isFalse);
        expect(geometry['normals'], isNull);
        expect(
          runtime.managedGeometryDiagnostics(entity.id)!['meshOnly'],
          isTrue,
        );
      }
      expect(
        Directory(p.join(project.path, 'NativeShapes')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(project.path, 'DisplayMeshes')).existsSync(),
        isFalse,
      );
      expect(pathImports(), 0);
      expect(manifests(), hasLength(2));
      expect(
        manifests().every((manifest) {
          final data = manifest['data'] as Map;
          return data['state'] == 'committed' &&
              data['documentPublished'] == true &&
              (data['assets'] as List).length == 1;
        }),
        isTrue,
      );
      final persisted = await File(
        p.join(project.path, 'cad-document.json'),
      ).readAsString();
      for (final forbidden in [
        sourceDirectory.path,
        'sourcePath',
        'registeredPath',
        'shapeAssetId',
        'ShapeHandle',
        'KernelMeshHandle',
        'token',
        'pointer',
        'capability',
        'fingerprint',
      ]) {
        expect(persisted, isNot(contains(forbidden)));
      }
    },
  );

  test(
    'invalid STL before promotion leaves document scene assets and custody unchanged',
    () async {
      final before = jsonEncode(runtime.document!.toJson());
      await File(
        p.join(sourceDirectory.path, 'invalid.stl'),
      ).writeAsString('not an STL', flush: true);
      await expectLater(
        importFile('invalid.stl'),
        throwsA(isA<NativeSourceFailure>()),
      );
      expect(jsonEncode(runtime.document!.toJson()), before);
      expect(
        runtime.scene.entities.where((entity) => entity.id.startsWith('e1_')),
        isEmpty,
      );
      expect(durableAssets(), isEmpty);
      expect(adapter.custodyDiagnostics!.allocations, 0);
      expect(pathImports(), 0);
    },
  );

  test(
    'post-promotion failure preserves one quarantined asset without publication',
    () async {
      storage.failAt = 'managedStl:afterPromotion';
      await expectLater(
        importFile('display.stl'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'phase',
            'injected:managedStl:afterPromotion',
          ),
        ),
      );
      expect(
        runtime.document!.entities.values.where(
          (entity) => entity.data['managedStlAssets'] != null,
        ),
        isEmpty,
      );
      expect(
        runtime.scene.entities.where((entity) => entity.id.startsWith('e1_')),
        isEmpty,
      );
      expect(durableAssets(), hasLength(1));
      expect(adapter.custodyDiagnostics!.allocations, 0);
      expect((manifests().single['data'] as Map)['state'], 'quarantined');
      expect((manifests().single['data'] as Map)['documentPublished'], isFalse);
    },
  );

  test(
    'persistence failure preserves previous document scene and selection',
    () async {
      const legacyId = 'legacy';
      await runtime.mutate(
        command: 'test.legacy',
        upsert: const [
          CadDocumentEntity(
            id: legacyId,
            kind: CadDocumentEntityKind.vertex,
            data: {
              'sceneKind': 'point',
              'sceneGeometry': {
                'position': [1, 2, 3],
              },
            },
          ),
        ],
      );
      runtime.select({legacyId});
      final before = jsonEncode(runtime.document!.toJson());
      repository.rejectManagedStl = true;
      await expectLater(
        importFile('display.stl'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'phase',
            'injected:managedStl:persistence',
          ),
        ),
      );
      expect(jsonEncode(runtime.document!.toJson()), before);
      expect(runtime.scene.find(legacyId), isNotNull);
      expect(runtime.selection, {legacyId});
      expect(adapter.custodyDiagnostics!.allocations, 0);
      expect(durableAssets(), hasLength(1));
      expect((manifests().single['data'] as Map)['state'], 'quarantined');
    },
  );

  test(
    'superseding open deterministically revokes suspended STL import',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      storage.onPhase = (phase) async {
        if (phase == 'managedStl:beforePromotion' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final importing = importFile('display.stl');
      await entered.future;
      storage.onPhase = null;
      final opening = runtime.open('managed-stl-project', project);
      release.complete();
      await expectLater(importing, throwsA(isA<StaleCadTransaction>()));
      await opening;
      expect(durableAssets(), isEmpty);
      expect(adapter.custodyDiagnostics!.allocations, 0);
    },
  );

  test('shutdown waits for suspended STL import cleanup', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final cleanupEntered = Completer<void>();
    final cleanupRelease = Completer<void>();
    storage.onPhase = (phase) async {
      if (phase == 'managedStl:beforePromotion' && !entered.isCompleted) {
        entered.complete();
        await release.future;
      } else if (phase == 'cleanup:started' && !cleanupEntered.isCompleted) {
        cleanupEntered.complete();
        await cleanupRelease.future;
      }
    };
    final importing = importFile('display.stl');
    await entered.future;
    final stopping = runtime.shutdown();
    var stopped = false;
    unawaited(stopping.then((_) => stopped = true));
    release.complete();
    await cleanupEntered.future;
    expect(stopped, isFalse);
    cleanupRelease.complete();
    await expectLater(importing, throwsA(isA<StaleCadTransaction>()));
    await stopping;
    expect(durableAssets(), isEmpty);
    expect(adapter.custodyDiagnostics!.allocations, 0);
  });

  test('ordinary mutation retains managed STL scene and custody', () async {
    final stl = await importFile('display.stl');
    final diagnostics = runtime.managedGeometryDiagnostics(stl.id);
    await runtime.mutate(
      command: 'test.after-stl',
      upsert: const [
        CadDocumentEntity(
          id: 'legacy-after-stl',
          kind: CadDocumentEntityKind.vertex,
          data: {
            'sceneKind': 'point',
            'sceneGeometry': {
              'position': [4, 5, 6],
            },
          },
        ),
      ],
    );
    expect(runtime.document!.entities[stl.id], isNotNull);
    expect(runtime.scene.find(stl.id), isNotNull);
    expect(runtime.scene.find('legacy-after-stl'), isNotNull);
    expect(runtime.managedGeometryDiagnostics(stl.id), diagnostics);
    expect(adapter.custodyDiagnostics!.allocations, 1);
  });

  test(
    'Undo changing STL set is rejected atomically with retention intact',
    () async {
      final stl = await importFile('display.stl');
      final before = jsonEncode(runtime.document!.toJson());
      final sceneBefore = jsonEncode(runtime.scene.find(stl.id)!.geometry);
      final diagnostics = runtime.managedGeometryDiagnostics(stl.id);
      await expectLater(
        runtime.undoDocument(),
        throwsA(isA<UnsupportedError>()),
      );
      expect(jsonEncode(runtime.document!.toJson()), before);
      expect(jsonEncode(runtime.scene.find(stl.id)!.geometry), sceneBefore);
      expect(runtime.managedGeometryDiagnostics(stl.id), diagnostics);
      expect(adapter.custodyDiagnostics!.allocations, 1);
      expect(runtime.canUndo, isTrue);
    },
  );

  test(
    'open of persisted managed STL fails before partial publication',
    () async {
      final stl = await importFile('display.stl');
      await runtime.close();
      expect(adapter.custodyDiagnostics!.allocations, 0);
      await expectLater(
        runtime.open('managed-stl-project', project),
        throwsA(isA<UnsupportedError>()),
      );
      expect(runtime.document, isNull);
      expect(runtime.scene.find(stl.id), isNull);
      expect(adapter.custodyDiagnostics!.allocations, 0);
    },
  );

  test('contradictory and incomplete mesh-only JSON is rejected', () {
    final validId = {
      'schema': 'flcad.geometry-asset',
      'version': 1,
      'id': 'ga1_${'a' * 32}',
    };
    final valid = {
      'schema': 'flcad.managed-stl-assets',
      'version': 1,
      'displayMeshAssetId': validId,
      'displayMeshSha256': 'b' * 64,
      'meshOnly': true,
    };
    Map<String, dynamic> entity(Object managed) => {
      'id': 'entity',
      'kind': 'import',
      'data': {'managedStlAssets': managed},
      'shape': null,
      'mesh': null,
    };
    for (final invalid in [
      {...valid}..remove('displayMeshAssetId'),
      {...valid, 'meshOnly': false},
      {...valid, 'shapeAssetId': validId},
      {...valid, 'displayMeshSha256': 'bad'},
      {
        ...valid,
        'displayMeshAssetId': {...validId, 'token': 'forbidden'},
      },
    ]) {
      expect(
        () => CadDocumentEntity.fromJson(entity(invalid)),
        throwsFormatException,
      );
    }
    expect(
      () => ManagedStlAssets.fromJson({
        ...valid,
        'displayMeshAssetId': {...validId, 'token': 'forbidden'},
      }),
      throwsFormatException,
    );
    expect(
      () => CadDocumentEntity.fromJson({
        ...entity(valid),
        'data': {
          'managedStlAssets': valid,
          'managedBrepAssets': {'schema': 'flcad.managed-brep-assets'},
        },
      }),
      throwsFormatException,
    );
  });
}
