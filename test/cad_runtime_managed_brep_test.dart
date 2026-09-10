import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flcad_mobile/app/runtime/cad_asset_fs_native.dart';
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
  Future<void> Function(String phase)? onPhase;

  @override
  Future<void> checkpoint(String phase) async {
    await onPhase?.call(phase);
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

  Future<CadDocumentEntity> importOne({String? name}) =>
      runtime.importManagedBrep(
        p.join(sourceDirectory.path, 'shape.brep'),
        name: name,
        nativeBridgePath: bridge,
      );

  ManagedBrepAssets managedAssets(CadDocumentEntity entity) =>
      ManagedBrepAssets.fromJson(
        Map<String, dynamic>.from(entity.data['managedBrepAssets'] as Map),
      );

  File assetFile(GeometryAssetId id, CadAssetFile kind) => File(
    p.join(project.path, 'CAD', 'Assets', 'v1', id.value, kind.relativePath),
  );

  Future<List<int>> damageOneByte(File file) async {
    final original = await file.readAsBytes();
    final changed = List<int>.of(original)..[0] ^= 0xff;
    await file.writeAsBytes(changed, flush: true);
    return original;
  }

  Future<void> restoreOneByte(File file, List<int> value) =>
      file.writeAsBytes(value, flush: true);

  Future<void> makeInvalidButConsistent(
    CadDocumentEntity entity,
    GeometryAssetId id,
    CadAssetFile kind,
  ) async {
    final payload = assetFile(id, kind);
    final length = await payload.length();
    await payload.writeAsBytes(List<int>.filled(length, 0), flush: true);
    final hash = (await sha256.bind(payload.openRead()).first).toString();
    final descriptorFile = File(p.join(payload.parent.path, 'asset.json'));
    final descriptor =
        jsonDecode(await descriptorFile.readAsString()) as Map<String, dynamic>;
    (descriptor['files'] as Map<String, dynamic>)[kind.name]['sha256'] = hash;
    await descriptorFile.writeAsString(jsonEncode(descriptor), flush: true);
    final documentFile = File(p.join(project.path, 'cad-document.json'));
    final document =
        jsonDecode(await documentFile.readAsString()) as Map<String, dynamic>;
    final encodedEntity = (document['entities'] as List)
        .cast<Map>()
        .singleWhere((entry) => entry['id'] == entity.id);
    final managed =
        ((encodedEntity['data'] as Map)['managedBrepAssets'] as Map);
    managed[kind == CadAssetFile.brep ? 'shapeSha256' : 'displayMeshSha256'] =
        hash;
    await documentFile.writeAsString(jsonEncode(document), flush: true);
  }

  void expectNoManagedPublication(Iterable<String> ids) {
    expect(runtime.document, isNull);
    expect(runtime.scene.entities, isEmpty);
    for (final id in ids) {
      expect(runtime.hasManagedGeometry(id), isFalse);
    }
    expect(adapter.custodyDiagnostics?.allocations ?? 0, 0);
    expect(pathImports(), 0);
  }

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
    expect(adapter.custodyDiagnostics?.leases ?? 0, 0);
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
      final journal = jsonEncode(manifests);
      for (final forbidden in [
        source,
        project.path,
        'ShapeHandle',
        'KernelMeshHandle',
        'token',
        'pointer',
        'capability',
      ]) {
        expect(journal, isNot(contains(forbidden)));
      }
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
      expect(adapter.custodyDiagnostics!.allocations, 0);
      final manifests = Directory(p.join(project.path, '.cad-staging'))
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => p.basename(file.path) == 'manifest.json')
          .map((file) => jsonDecode(file.readAsStringSync()) as Map)
          .toList();
      expect(manifests, hasLength(1));
      expect(
        manifests.every(
          (manifest) =>
              (manifest['data'] as Map)['state'] == 'quarantined' &&
              (manifest['data'] as Map)['documentPublished'] == false &&
              ((manifest['data'] as Map)['assets'] as List).length == 2,
        ),
        isTrue,
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
      expect(
        promoted.every(
          (directory) => directory
              .listSync(recursive: true)
              .whereType<File>()
              .any((file) => file.lengthSync() > 0),
        ),
        isTrue,
      );
      expect(adapter.custodyDiagnostics!.allocations, 0);
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
    'persistence failure preserves prior managed state and history',
    () async {
      final first = await importOne(name: 'first');
      runtime.select({first.id});
      final documentBefore = jsonEncode(runtime.document!.toJson());
      final sceneBefore = runtime.scene.entities
          .map((entity) => (entity.id, jsonEncode(entity.geometry)))
          .toList();
      final ownerBefore = runtime.managedGeometryDiagnostics(first.id);
      final historyBefore = (
        runtime.canUndo,
        runtime.canRedo,
        runtime.runtimeRevision,
      );
      final assetsDirectory = Directory(
        p.join(project.path, 'CAD', 'Assets', 'v1'),
      );
      final assetsBefore = assetsDirectory
          .listSync()
          .map((entry) => entry.path)
          .toSet();
      repository.rejectManagedSave = true;

      await expectLater(
        importOne(name: 'second'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'phase',
            'injected:managedBrep:persistence',
          ),
        ),
      );

      expect(jsonEncode(runtime.document!.toJson()), documentBefore);
      expect(
        runtime.scene.entities
            .map((entity) => (entity.id, jsonEncode(entity.geometry)))
            .toList(),
        sceneBefore,
      );
      expect(runtime.selection, {first.id});
      expect(runtime.managedGeometryDiagnostics(first.id), ownerBefore);
      expect(adapter.custodyDiagnostics!.allocations, 2);
      expect((
        runtime.canUndo,
        runtime.canRedo,
        runtime.runtimeRevision,
      ), historyBefore);
      final assetsAfter = assetsDirectory
          .listSync()
          .map((entry) => entry.path)
          .toSet();
      expect(assetsAfter.difference(assetsBefore), hasLength(2));
      expect(pathImports(), 0);
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
        await Future<void>.value();
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

  test(
    'managed BREP save close open restores document scene and custody',
    () async {
      final first = await importOne(name: 'first');
      final second = await importOne(name: 'second');
      final beforeDocument = jsonEncode(runtime.document!.toJson());
      final firstAssets = managedAssets(first);
      final secondAssets = managedAssets(second);
      final durable = <File>[
        assetFile(firstAssets.shape, CadAssetFile.brep),
        assetFile(firstAssets.display, CadAssetFile.display),
        assetFile(secondAssets.shape, CadAssetFile.brep),
        assetFile(secondAssets.display, CadAssetFile.display),
      ];
      durable.addAll([
        for (final payload in List<File>.of(durable))
          File(p.join(payload.parent.path, 'asset.json')),
      ]);
      final beforeFiles = <String, (int, String, DateTime)>{};
      for (final file in durable) {
        beforeFiles[file.path] = (
          await file.length(),
          (await sha256.bind(file.openRead()).first).toString(),
          await file.lastModified(),
        );
      }

      await runtime.close();
      expect(runtime.document, isNull);
      expect(runtime.scene.entities, isEmpty);
      expect(runtime.hasManagedGeometry(first.id), isFalse);
      expect(adapter.custodyDiagnostics!.allocations, 0);

      await runtime.open('managed-brep-project', project);

      expect(jsonEncode(runtime.document!.toJson()), beforeDocument);
      expect(runtime.scene.find(first.id)?.geometry['nodes'], isNotEmpty);
      expect(runtime.scene.find(second.id)?.geometry['triangles'], isNotEmpty);
      expect(runtime.hasManagedGeometry(first.id), isTrue);
      expect(runtime.hasManagedGeometry(second.id), isTrue);
      expect(adapter.custodyDiagnostics!.allocations, 4);
      expect(pathImports(), 0);
      for (final file in durable) {
        final before = beforeFiles[file.path]!;
        expect(await file.length(), before.$1);
        expect(
          (await sha256.bind(file.openRead()).first).toString(),
          before.$2,
        );
        expect(await file.lastModified(), before.$3);
      }
    },
  );

  test('post-commit open cleanup failure requires recovery', () async {
    final entity = await importOne();
    final documentBefore = jsonEncode(runtime.document!.toJson());
    final previousError = FlutterError.onError;
    final observed = <FlutterErrorDetails>[];
    FlutterError.onError = observed.add;
    storage.failAt = 'managedGeometry:beforeDispose';
    try {
      await runtime.open('managed-brep-project', project);
      await Future<void>.value();
      expect(jsonEncode(runtime.document!.toJson()), documentBefore);
      expect(runtime.scene.find(entity.id), isNotNull);
      expect(runtime.hasManagedGeometry(entity.id), isTrue);
      expect(adapter.custodyDiagnostics!.allocations, 2);
      expect(adapter.custodyDiagnostics!.leases, 0);
      expect(runtime.recoveryRequired, isTrue);
      expect(observed, hasLength(1));
      expect(observed.single.library, 'CAD managed geometry cleanup');
      expect(observed.single.context.toString(), contains('confirmed open'));
      await expectLater(
        runtime.open('managed-brep-project', project),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'recovery gate',
            'CAD runtime requires verified recovery.',
          ),
        ),
      );
    } finally {
      FlutterError.onError = previousError;
    }
  });

  test('missing shape and display assets reject the whole open', () async {
    final entity = await importOne();
    final assets = managedAssets(entity);
    await runtime.close();

    for (final value in [
      (assetFile(assets.shape, CadAssetFile.brep), 'shape'),
      (assetFile(assets.display, CadAssetFile.display), 'display'),
    ]) {
      final originalDirectory = value.$1.parent;
      final missing = Directory('${originalDirectory.path}.missing');
      await originalDirectory.rename(missing.path);
      await expectLater(
        runtime.open('managed-brep-project', project),
        throwsA(
          isA<CadAssetNativeError>().having(
            (error) => error.notFound,
            '${value.$2} asset not found',
            isTrue,
          ),
        ),
      );
      expectNoManagedPublication([entity.id]);
      await missing.rename(originalDirectory.path);
    }
  });

  test('shape and display hash divergence reject the whole open', () async {
    final entity = await importOne();
    final assets = managedAssets(entity);
    await runtime.close();

    for (final file in [
      assetFile(assets.shape, CadAssetFile.brep),
      assetFile(assets.display, CadAssetFile.display),
    ]) {
      final original = await damageOneByte(file);
      await expectLater(
        runtime.open('managed-brep-project', project),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'identity check',
            'Managed asset identity, size or hash diverged',
          ),
        ),
      );
      expectNoManagedPublication([entity.id]);
      await restoreOneByte(file, original);
    }
  });

  test('anchored open rejects mutation after preparation', () async {
    final entity = await importOne();
    final assets = managedAssets(entity);
    final payload = assetFile(assets.display, CadAssetFile.display);
    await runtime.close();
    final originalHash = (await sha256.bind(payload.openRead()).first)
        .toString();
    storage.onPhase = (phase) async {
      if (phase == 'managedOpen:beforePublish') {
        await damageOneByte(payload);
      }
    };

    await expectLater(
      runtime.open('managed-brep-project', project),
      throwsA(
        isA<PathAccessException>().having(
          (error) => error.osError?.errorCode,
          'sharing violation',
          32,
        ),
      ),
    );

    expectNoManagedPublication([entity.id]);
    expect(
      (await sha256.bind(payload.openRead()).first).toString(),
      originalHash,
    );
  });

  test('payload size divergence rejects the whole open', () async {
    final entity = await importOne();
    final assets = managedAssets(entity);
    await runtime.close();
    final payload = assetFile(assets.display, CadAssetFile.display);
    await payload.writeAsBytes([0], mode: FileMode.append, flush: true);

    await expectLater(
      runtime.open('managed-brep-project', project),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'identity check',
          'Managed asset identity, size or hash diverged',
        ),
      ),
    );
    expectNoManagedPublication([entity.id]);
  });

  test('invalid durable asset schema rejects the whole open', () async {
    final entity = await importOne();
    final assets = managedAssets(entity);
    await runtime.close();
    final descriptorFile = File(
      p.join(
        assetFile(assets.shape, CadAssetFile.brep).parent.path,
        'asset.json',
      ),
    );
    final descriptor =
        jsonDecode(await descriptorFile.readAsString()) as Map<String, dynamic>;
    descriptor['version'] = 999;
    await descriptorFile.writeAsString(jsonEncode(descriptor), flush: true);

    await expectLater(
      runtime.open('managed-brep-project', project),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'schema check',
          'Invalid managed asset descriptor',
        ),
      ),
    );
    expectNoManagedPublication([entity.id]);
  });

  test('valid BREP with invalid consistent STL is rejected natively', () async {
    final entity = await importOne();
    final assets = managedAssets(entity);
    await runtime.close();
    await makeInvalidButConsistent(
      entity,
      assets.display,
      CadAssetFile.display,
    );

    await expectLater(
      runtime.open('managed-brep-project', project),
      throwsA(isA<NativeSourceFailure>()),
    );
    expectNoManagedPublication([entity.id]);
  });

  test('valid STL with invalid consistent BREP is rejected natively', () async {
    final entity = await importOne();
    final assets = managedAssets(entity);
    await runtime.close();
    await makeInvalidButConsistent(entity, assets.shape, CadAssetFile.brep);

    await expectLater(
      runtime.open('managed-brep-project', project),
      throwsA(isA<NativeSourceFailure>()),
    );
    expectNoManagedPublication([entity.id]);
  });

  test('failure preparing second managed entity publishes neither', () async {
    final first = await importOne(name: 'first');
    final second = await importOne(name: 'second');
    final secondAssets = managedAssets(second);
    await runtime.close();
    await damageOneByte(assetFile(secondAssets.display, CadAssetFile.display));

    await expectLater(
      runtime.open('managed-brep-project', project),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'identity check',
          'Managed asset identity, size or hash diverged',
        ),
      ),
    );
    expectNoManagedPublication([first.id, second.id]);
    final probe = Directory('${project.path}.closed-handle-probe');
    await project.rename(probe.path);
    await probe.rename(project.path);
  });

  test(
    'a superseding open revokes managed restoration without leaks',
    () async {
      final entity = await importOne();
      await runtime.close();
      final entered = Completer<void>();
      final release = Completer<void>();
      storage.onPhase = (phase) async {
        if (phase == 'managedOpen:afterShape' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final revoked = runtime.open('managed-brep-project', project);
      await entered.future;
      storage.onPhase = null;
      final replacement = runtime.open('managed-brep-project', project);
      release.complete();

      await expectLater(revoked, throwsA(isA<StaleCadTransaction>()));
      await replacement;
      expect(runtime.hasManagedGeometry(entity.id), isTrue);
      expect(adapter.custodyDiagnostics!.allocations, 2);
      expect(pathImports(), 0);
    },
  );

  test('shutdown revokes restoration and waits for native cleanup', () async {
    final entity = await importOne();
    await runtime.close();
    final entered = Completer<void>();
    final release = Completer<void>();
    final cleanupEntered = Completer<void>();
    final cleanupRelease = Completer<void>();
    storage.onPhase = (phase) async {
      if (phase == 'managedOpen:afterShape') {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      } else if (phase == 'managedOpen:beforeEntityCleanup') {
        if (!cleanupEntered.isCompleted) cleanupEntered.complete();
        await cleanupRelease.future;
      }
    };
    final opening = runtime.open('managed-brep-project', project);
    await entered.future;
    var shutdownFinished = false;
    final stopping = runtime.shutdown().then((_) => shutdownFinished = true);
    release.complete();
    await cleanupEntered.future;
    expect(shutdownFinished, isFalse);
    cleanupRelease.complete();

    await expectLater(opening, throwsA(isA<StaleCadTransaction>()));
    await stopping;
    expect(runtime.hasManagedGeometry(entity.id), isFalse);
    expect(adapter.custodyDiagnostics!.allocations, 0);
    expect(pathImports(), 0);
  });

  test('legacy-only document keeps the existing open behavior', () async {
    const id = 'legacy-point';
    await runtime.mutate(
      command: 'test.legacy',
      upsert: const [
        CadDocumentEntity(
          id: id,
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
    await runtime.close();
    await runtime.open('managed-brep-project', project);

    expect(runtime.document!.entities[id], isNotNull);
    expect(runtime.hasManagedGeometry(id), isFalse);
    expect(adapter.custodyDiagnostics?.allocations ?? 0, 0);
  });

  test(
    'managed Undo removes scene before disposal and Redo restores assets',
    () async {
      final entity = await importOne();
      final assets = managedAssets(entity);
      final payloads = [
        assetFile(assets.shape, CadAssetFile.brep),
        assetFile(assets.display, CadAssetFile.display),
      ];
      payloads.addAll([
        for (final payload in List<File>.of(payloads))
          File(p.join(payload.parent.path, 'asset.json')),
      ]);
      final durableBefore = <String, (int, String, DateTime)>{};
      for (final file in payloads) {
        durableBefore[file.path] = (
          await file.length(),
          (await sha256.bind(file.openRead()).first).toString(),
          await file.lastModified(),
        );
      }
      runtime.select({entity.id});
      final observed = <(bool, bool, int)>[];
      runtime.addListener(() {
        observed.add((
          runtime.document?.entities.containsKey(entity.id) ?? false,
          runtime.scene.find(entity.id) != null,
          adapter.custodyDiagnostics?.allocations ?? 0,
        ));
      });

      await runtime.undoDocument();

      expect(runtime.document!.entities[entity.id], isNull);
      expect(runtime.scene.find(entity.id), isNull);
      expect(runtime.selection, isEmpty);
      expect(runtime.hasManagedGeometry(entity.id), isFalse);
      expect(adapter.custodyDiagnostics!.allocations, 0);
      expect(runtime.canRedo, isTrue);
      expect(observed.last, (false, false, 0));
      for (final file in payloads) {
        final before = durableBefore[file.path]!;
        expect(await file.length(), before.$1);
        expect(
          (await sha256.bind(file.openRead()).first).toString(),
          before.$2,
        );
        expect(await file.lastModified(), before.$3);
      }

      await runtime.redoDocument();

      final restored = runtime.document!.entities[entity.id]!;
      expect(managedAssets(restored).toJson(), assets.toJson());
      expect(runtime.scene.find(entity.id)?.geometry['nodes'], isNotEmpty);
      expect(runtime.hasManagedGeometry(entity.id), isTrue);
      expect(adapter.custodyDiagnostics!.allocations, 2);
      expect(pathImports(), 0);
    },
  );

  test(
    'repeated managed Undo Redo has no duplicates and survives reopen',
    () async {
      final entity = await importOne();
      final assets = managedAssets(entity);
      for (var cycle = 0; cycle < 3; cycle++) {
        await runtime.undoDocument();
        expect(runtime.document!.entities[entity.id], isNull);
        expect(
          runtime.scene.entities.where((item) => item.id == entity.id),
          isEmpty,
        );
        expect(runtime.hasManagedGeometry(entity.id), isFalse);
        expect(adapter.custodyDiagnostics!.allocations, 0);
        await runtime.redoDocument();
        expect(
          runtime.document!.entities.values.where(
            (item) => item.id == entity.id,
          ),
          hasLength(1),
        );
        expect(
          runtime.scene.entities.where((item) => item.id == entity.id),
          hasLength(1),
        );
        expect(runtime.hasManagedGeometry(entity.id), isTrue);
        expect(adapter.custodyDiagnostics!.allocations, 2);
      }
      await runtime.save();
      await runtime.close();
      await runtime.open('managed-brep-project', project);
      expect(
        managedAssets(runtime.document!.entities[entity.id]!).toJson(),
        assets.toJson(),
      );
      expect(runtime.scene.find(entity.id), isNotNull);
      expect(runtime.hasManagedGeometry(entity.id), isTrue);
      expect(adapter.custodyDiagnostics!.allocations, 2);
      expect(pathImports(), 0);
    },
  );

  test('complete managed BREP lifecycle preserves durable identity', () async {
    final entity = await importOne();
    final assets = managedAssets(entity);
    final files = [
      assetFile(assets.shape, CadAssetFile.brep),
      assetFile(assets.display, CadAssetFile.display),
    ];
    final before = <String, (int, String, DateTime)>{
      for (final file in files)
        file.path: (
          await file.length(),
          (await sha256.bind(file.openRead()).first).toString(),
          await file.lastModified(),
        ),
    };

    await runtime.save();
    await runtime.close();
    await runtime.open('managed-brep-project', project);
    await runtime.undoDocument();
    await runtime.redoDocument();

    final restored = runtime.document!.entities[entity.id]!;
    expect(managedAssets(restored).toJson(), assets.toJson());
    expect(runtime.scene.find(entity.id), isNotNull);
    expect(runtime.hasManagedGeometry(entity.id), isTrue);
    expect(adapter.custodyDiagnostics!.allocations, 2);
    for (final file in files) {
      final expected = before[file.path]!;
      expect(await file.length(), expected.$1);
      expect(
        (await sha256.bind(file.openRead()).first).toString(),
        expected.$2,
      );
      expect(await file.lastModified(), expected.$3);
    }
    await runtime.close();
    expect(runtime.document, isNull);
    expect(runtime.scene.entities, isEmpty);
    expect(adapter.custodyDiagnostics!.allocations, 0);
    for (final legacyFolder in ['NativeShapes', 'DisplayMeshes']) {
      expect(
        Directory(p.join(project.path, legacyFolder)).existsSync(),
        isFalse,
        reason: 'Managed lifecycle must not create $legacyFolder',
      );
    }
    expect(pathImports(), 0);
  });

  test(
    'Undo of last managed entity preserves first and Redo restores only last',
    () async {
      final first = await importOne(name: 'first');
      final second = await importOne(name: 'second');
      final firstDiagnostics = runtime.managedGeometryDiagnostics(first.id);

      await runtime.undoDocument();

      expect(runtime.document!.entities[first.id], isNotNull);
      expect(runtime.document!.entities[second.id], isNull);
      expect(runtime.scene.find(first.id), isNotNull);
      expect(runtime.scene.find(second.id), isNull);
      expect(runtime.hasManagedGeometry(first.id), isTrue);
      expect(runtime.hasManagedGeometry(second.id), isFalse);
      expect(runtime.managedGeometryDiagnostics(first.id), firstDiagnostics);
      expect(adapter.custodyDiagnostics!.allocations, 2);

      await runtime.redoDocument();

      expect(runtime.document!.entities[first.id], isNotNull);
      expect(runtime.document!.entities[second.id], isNotNull);
      expect(
        runtime.scene.entities.where((item) => item.id == first.id),
        hasLength(1),
      );
      expect(
        runtime.scene.entities.where((item) => item.id == second.id),
        hasLength(1),
      );
      expect(runtime.managedGeometryDiagnostics(first.id), firstDiagnostics);
      expect(runtime.hasManagedGeometry(second.id), isTrue);
      expect(adapter.custodyDiagnostics!.allocations, 4);
      expect(pathImports(), 0);
    },
  );

  test('managed history preserves an unchanged legacy entity', () async {
    const legacyId = 'legacy-point';
    await runtime.mutate(
      command: 'test.add-legacy-point',
      upsert: const [
        CadDocumentEntity(
          id: legacyId,
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
    final legacyScene = runtime.scene.find(legacyId)!.geometry;
    final managed = await importOne();

    await runtime.undoDocument();

    expect(runtime.document!.entities[legacyId], isNotNull);
    expect(runtime.document!.entities[managed.id], isNull);
    expect(runtime.scene.find(legacyId)?.geometry, legacyScene);
    expect(runtime.scene.find(managed.id), isNull);
    expect(runtime.hasManagedGeometry(managed.id), isFalse);

    await runtime.redoDocument();

    expect(runtime.document!.entities[legacyId], isNotNull);
    expect(runtime.document!.entities[managed.id], isNotNull);
    expect(runtime.scene.find(legacyId)?.geometry, legacyScene);
    expect(runtime.scene.find(managed.id), isNotNull);
    expect(runtime.hasManagedGeometry(managed.id), isTrue);
    expect(adapter.custodyDiagnostics!.allocations, 2);
    expect(pathImports(), 0);
  });

  test(
    'failed managed Redo preserves document history scene selection and owners',
    () async {
      final first = await importOne(name: 'first');
      final second = await importOne(name: 'second');
      final secondAssets = managedAssets(second);
      await runtime.undoDocument();
      runtime.select({first.id});
      final documentBefore = jsonEncode(runtime.document!.toJson());
      final sceneBefore = runtime.scene.entities
          .map((item) => item.id)
          .toList();
      final ownerBefore = runtime.managedGeometryDiagnostics(first.id);
      final historyBefore = (
        runtime.canUndo,
        runtime.canRedo,
        runtime.runtimeRevision,
      );

      Future<void> verifyFailure(
        Future<void> Function() damage,
        Future<void> Function() restore,
        Matcher expected,
      ) async {
        await damage();
        await expectLater(runtime.redoDocument(), throwsA(expected));
        expect(jsonEncode(runtime.document!.toJson()), documentBefore);
        expect(
          runtime.scene.entities.map((item) => item.id).toList(),
          sceneBefore,
        );
        expect(runtime.selection, {first.id});
        expect(runtime.managedGeometryDiagnostics(first.id), ownerBefore);
        expect(runtime.hasManagedGeometry(second.id), isFalse);
        expect(adapter.custodyDiagnostics!.allocations, 2);
        expect(runtime.canRedo, isTrue);
        expect((
          runtime.canUndo,
          runtime.canRedo,
          runtime.runtimeRevision,
        ), historyBefore);
        expect(pathImports(), 0);
        await restore();
      }

      for (final payload in [
        assetFile(secondAssets.shape, CadAssetFile.brep),
        assetFile(secondAssets.display, CadAssetFile.display),
      ]) {
        final original = payload.parent;
        final missing = Directory('${original.path}.missing');
        await verifyFailure(
          () async {
            await original.rename(missing.path);
          },
          () async {
            await missing.rename(original.path);
          },
          isA<CadAssetNativeError>().having(
            (error) => error.notFound,
            'asset absent',
            isTrue,
          ),
        );
      }
      for (final payload in [
        assetFile(secondAssets.shape, CadAssetFile.brep),
        assetFile(secondAssets.display, CadAssetFile.display),
      ]) {
        late List<int> originalBytes;
        await verifyFailure(
          () async => originalBytes = await damageOneByte(payload),
          () => restoreOneByte(payload, originalBytes),
          isA<StateError>().having(
            (error) => error.message,
            'hash divergence',
            'Managed asset identity, size or hash diverged',
          ),
        );
      }
      final descriptorFile = File(
        p.join(
          assetFile(secondAssets.shape, CadAssetFile.brep).parent.path,
          'asset.json',
        ),
      );
      late String descriptorBefore;
      await verifyFailure(
        () async {
          descriptorBefore = await descriptorFile.readAsString();
          final descriptor =
              jsonDecode(descriptorBefore) as Map<String, dynamic>;
          descriptor['version'] = 999;
          await descriptorFile.writeAsString(
            jsonEncode(descriptor),
            flush: true,
          );
        },
        () => descriptorFile.writeAsString(descriptorBefore, flush: true),
        isA<FormatException>().having(
          (error) => error.message,
          'schema check',
          'Invalid managed asset descriptor',
        ),
      );
    },
  );

  test('anchored Redo rejects late mutation and preserves state', () async {
    final entity = await importOne();
    final assets = managedAssets(entity);
    final payload = assetFile(assets.shape, CadAssetFile.brep);
    await runtime.undoDocument();
    final documentBefore = jsonEncode(runtime.document!.toJson());
    final sceneBefore = runtime.scene.entities
        .map((item) => (item.id, jsonEncode(item.geometry)))
        .toList();
    final historyBefore = (
      runtime.canUndo,
      runtime.canRedo,
      runtime.runtimeRevision,
    );
    final originalHash = (await sha256.bind(payload.openRead()).first)
        .toString();
    storage.onPhase = (phase) async {
      if (phase == 'managedHistory:beforePublish') {
        await damageOneByte(payload);
      }
    };

    await expectLater(
      runtime.redoDocument(),
      throwsA(
        isA<PathAccessException>().having(
          (error) => error.osError?.errorCode,
          'sharing violation',
          32,
        ),
      ),
    );

    expect(jsonEncode(runtime.document!.toJson()), documentBefore);
    expect(
      runtime.scene.entities
          .map((item) => (item.id, jsonEncode(item.geometry)))
          .toList(),
      sceneBefore,
    );
    expect((
      runtime.canUndo,
      runtime.canRedo,
      runtime.runtimeRevision,
    ), historyBefore);
    expect(runtime.hasManagedGeometry(entity.id), isFalse);
    expect(adapter.custodyDiagnostics!.allocations, 0);
    expect(
      (await sha256.bind(payload.openRead()).first).toString(),
      originalHash,
    );
    expect(pathImports(), 0);
  });

  test(
    'post-commit cleanup failure is observable without undoing Undo',
    () async {
      final entity = await importOne();
      final previousError = FlutterError.onError;
      final observed = <FlutterErrorDetails>[];
      FlutterError.onError = observed.add;
      storage.failAt = 'managedGeometry:beforeDispose';
      try {
        await runtime.undoDocument();
        await Future<void>.value();
        expect(runtime.document!.entities[entity.id], isNull);
        expect(runtime.scene.find(entity.id), isNull);
        expect(runtime.hasManagedGeometry(entity.id), isFalse);
        expect(adapter.custodyDiagnostics!.allocations, 0);
        expect(runtime.canRedo, isTrue);
        expect(runtime.recoveryRequired, isTrue);
        expect(observed, hasLength(1));
        expect(observed.single.library, 'CAD managed geometry cleanup');
        expect(
          observed.single.context.toString(),
          contains('confirmed Undo/Redo'),
        );
        await expectLater(
          runtime.redoDocument(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'recovery gate',
              'CAD runtime requires verified recovery.',
            ),
          ),
        );
      } finally {
        FlutterError.onError = previousError;
      }
    },
  );

  test('superseding open revokes managed import before promotion', () async {
    final sceneBefore = runtime.scene.entities
        .map((entity) => (entity.id, jsonEncode(entity.geometry)))
        .toList();
    final entered = Completer<void>();
    final release = Completer<void>();
    storage.onPhase = (phase) async {
      if (phase == 'managedBrep:beforePromotion' && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final importing = importOne();
    await entered.future;
    storage.onPhase = null;
    final replacement = runtime.open('managed-brep-project', project);
    release.complete();

    await expectLater(importing, throwsA(isA<StaleCadTransaction>()));
    await replacement;
    expect(
      runtime.document!.entities.values.where(
        (entity) => entity.data['managedBrepAssets'] != null,
      ),
      isEmpty,
    );
    expect(
      runtime.scene.entities
          .map((entity) => (entity.id, jsonEncode(entity.geometry)))
          .toList(),
      sceneBefore,
    );
    expect(adapter.custodyDiagnostics!.allocations, 0);
    final assetRoot = Directory(p.join(project.path, 'CAD', 'Assets', 'v1'));
    expect(assetRoot.existsSync() ? assetRoot.listSync() : const [], isEmpty);
    expect(pathImports(), 0);
  });

  test(
    'shutdown revokes managed import before promotion and drains it',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final cleanupEntered = Completer<void>();
      final cleanupRelease = Completer<void>();
      storage.onPhase = (phase) async {
        if (phase == 'managedBrep:beforePromotion' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        } else if (phase == 'cleanup:started') {
          if (!cleanupEntered.isCompleted) cleanupEntered.complete();
          await cleanupRelease.future;
        }
      };
      final importing = importOne();
      await entered.future;
      final stopping = runtime.shutdown();
      var shutdownFinished = false;
      unawaited(stopping.then((_) => shutdownFinished = true));
      release.complete();
      await cleanupEntered.future;
      expect(shutdownFinished, isFalse);
      cleanupRelease.complete();

      await expectLater(importing, throwsA(isA<StaleCadTransaction>()));
      await stopping;
      expect(adapter.custodyDiagnostics!.allocations, 0);
      final assetRoot = Directory(p.join(project.path, 'CAD', 'Assets', 'v1'));
      expect(assetRoot.existsSync() ? assetRoot.listSync() : const [], isEmpty);
      expect(pathImports(), 0);
    },
  );

  test('superseding open revokes a suspended managed Redo', () async {
    final entity = await importOne();
    await runtime.undoDocument();
    final entered = Completer<void>();
    final release = Completer<void>();
    storage.onPhase = (phase) async {
      if (phase == 'managedOpen:afterShape' && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final redo = runtime.redoDocument();
    await entered.future;
    storage.onPhase = null;
    final replacement = runtime.open('managed-brep-project', project);
    release.complete();

    await expectLater(redo, throwsA(isA<StaleCadTransaction>()));
    await replacement;
    expect(runtime.document!.entities[entity.id], isNull);
    expect(runtime.scene.find(entity.id), isNull);
    expect(runtime.hasManagedGeometry(entity.id), isFalse);
    expect(adapter.custodyDiagnostics!.allocations, 0);
    expect(runtime.canRedo, isTrue);
    expect(pathImports(), 0);
  });

  test(
    'shutdown revokes a suspended managed Redo and drains custody',
    () async {
      final entity = await importOne();
      await runtime.undoDocument();
      final entered = Completer<void>();
      final release = Completer<void>();
      final cleanupEntered = Completer<void>();
      final cleanupRelease = Completer<void>();
      storage.onPhase = (phase) async {
        if (phase == 'managedOpen:afterShape' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        } else if (phase == 'managedOpen:beforeEntityCleanup') {
          if (!cleanupEntered.isCompleted) cleanupEntered.complete();
          await cleanupRelease.future;
        }
      };
      final redo = runtime.redoDocument();
      await entered.future;
      final stopping = runtime.shutdown();
      release.complete();
      await cleanupEntered.future;
      cleanupRelease.complete();

      await expectLater(redo, throwsA(isA<StaleCadTransaction>()));
      await stopping;
      expect(runtime.hasManagedGeometry(entity.id), isFalse);
      expect(adapter.custodyDiagnostics!.allocations, 0);
      expect(pathImports(), 0);
    },
  );
}
