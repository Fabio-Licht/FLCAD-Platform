import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/app/cad_viewport/native/native_viewport_bridge.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/cad_root_color.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/cad_document_repository.dart';
import 'package:flcad_mobile/core/cad_document/managed_step_contract.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final class _Storage extends CadAssetStorage {
  String? failAt;
  Future<void> Function(String)? gate;
  @override
  Future<void> checkpoint(String phase) async {
    await gate?.call(phase);
    if (phase == failAt) throw StateError('injected:$phase');
  }
}

final class _Repository extends CadDocumentRepository {
  bool reject = false;
  @override
  Future<void> save(CadDocument document, Directory project) {
    if (reject &&
        document.entities.values.any(
          (e) => e.data['managedStepAssets'] != null,
        )) {
      throw StateError('injected:step:persistence');
    }
    return super.save(document, project);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final caf = Platform.environment['FLCAD_CAD_ASSET_FS_DLL']!;
  final occ = Platform.environment['FLCAD_SOURCE_OCC_DLL']!;
  final bridge = Platform.environment['FLCAD_SOURCE_BRIDGE_DLL']!;
  final fixture = Platform.environment['FLCAD_STEP_FIXTURE_EXE']!;
  late Directory root, source, project;
  late _Storage storage;
  late _Repository repository;
  late CadRuntime runtime;
  late OpenCascadeKernelAdapter adapter;
  late int Function() pathImports;

  Future<CadDocumentEntity> import(
    int mode, {
    CadAssetCancellation? cancellation,
  }) => runtime.importManagedStep(
    p.join(source.path, 'part-$mode.step'),
    cancellation: cancellation,
    nativeBridgePath: bridge,
  );
  File asset(GeometryAssetId id, CadAssetFile kind) => File(
    p.join(project.path, 'CAD', 'Assets', 'v1', id.value, kind.relativePath),
  );
  Future<Map<String, String>> inventory(Directory directory) async => {
    for (final file
        in directory.existsSync()
            ? directory.listSync(recursive: true).whereType<File>()
            : <File>[])
      p.relative(file.path, from: directory.path):
          '${file.lengthSync()}:${(await sha256.bind(file.openRead()).first)}',
  };
  List<Map> journals() => Directory(p.join(project.path, '.cad-staging'))
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => p.basename(f.path) == 'manifest.json')
      .map((f) => (jsonDecode(f.readAsStringSync()) as Map)['data'] as Map)
      .toList();
  List<Directory> promoted() {
    final dir = Directory(p.join(project.path, 'CAD', 'Assets', 'v1'));
    return dir.existsSync()
        ? dir.listSync().whereType<Directory>().toList()
        : [];
  }

  void noOwners() {
    expect(adapter.custodyDiagnostics!.allocations, 0);
    expect(adapter.custodyDiagnostics!.leases, 0);
    expect(pathImports(), 0);
  }

  ManagedStepAssets references(CadDocumentEntity entity) =>
      ManagedStepAssets.fromJson(
        Map<String, dynamic>.from(entity.data['managedStepAssets'] as Map),
      );

  Future<void> corruptManifest(
    CadDocumentEntity entity,
    List<int> bytes,
  ) async {
    final refs = references(entity);
    final file = asset(refs.appearance, CadAssetFile.appearance);
    await file.writeAsBytes(bytes, flush: true);
    final hash = sha256.convert(bytes).toString();
    final descriptor = File(p.join(file.parent.path, 'asset.json'));
    final metadata = jsonDecode(descriptor.readAsStringSync()) as Map;
    final record =
        (metadata['files'] as Map)[CadAssetFile.appearance.name] as Map;
    record['size'] = bytes.length;
    record['sha256'] = hash;
    descriptor.writeAsStringSync(jsonEncode(metadata));
    final document = File(p.join(project.path, 'cad-document.json'));
    final json = jsonDecode(document.readAsStringSync()) as Map;
    final entities = json['entities'] as List;
    final data =
        (entities.singleWhere((e) => e['id'] == entity.id) as Map)['data']
            as Map;
    (data['managedStepAssets'] as Map)['appearanceManifestSha256'] = hash;
    document.writeAsStringSync(jsonEncode(json));
  }

  Future<CadDocumentEntity> establishPrevious(CadDocumentEntity target) async {
    await runtime.open(
      'previous',
      await Directory(p.join(root.path, 'previous')).create(),
    );
    final prior = await runtime.importManagedStl(
      asset(references(target).display, CadAssetFile.display).path,
      nativeBridgePath: bridge,
    );
    runtime.select({prior.id});
    return prior;
  }

  void capabilitiesReleased(CadDocumentEntity entity) {
    final refs = references(entity);
    for (final pair in [
      (refs.shape, CadAssetFile.brep),
      (refs.display, CadAssetFile.display),
      (refs.appearance, CadAssetFile.appearance),
    ]) {
      final file = asset(pair.$1, pair.$2);
      if (file.existsSync()) {
        file.renameSync('${file.path}.probe').renameSync(file.path);
      }
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('managed-step-');
    source = await Directory(p.join(root.path, 'source')).create();
    project = await Directory(p.join(root.path, 'project')).create();
    final result = await Process.run(fixture, [caf, bridge, source.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    storage = _Storage();
    repository = _Repository();
    adapter = OpenCascadeKernelAdapter(bridge: OpenCascadeFFI.load(path: occ));
    runtime = CadRuntime(
      kernels: KernelManager()..register(adapter, makeDefault: true),
      assetStorage: storage,
      repository: repository,
    );
    await runtime.open('step-project', project);
    pathImports = DynamicLibrary.open(occ)
        .lookupFunction<Uint64 Function(), int Function()>(
          'flcad_occ_test_path_import_count',
        );
  });
  tearDown(() async {
    storage.gate = null;
    storage.failAt = null;
    repository.reject = false;
    await runtime.shutdown();
    noOwners();
    await adapter.unload();
    await root.delete(recursive: true);
  });

  for (final mode in [0, 1, 2]) {
    test(
      'real STEP mode $mode persists root appearance and canonical geometry',
      () async {
        final original = await inventory(source);
        final entity = await import(mode);
        final refs = ManagedStepAssets.fromJson(
          Map<String, dynamic>.from(entity.data['managedStepAssets'] as Map),
        );
        expect(runtime.hasManagedGeometry(entity.id), isTrue);
        expect(adapter.custodyDiagnostics!.allocations, 2);
        expect(adapter.custodyDiagnostics!.leases, 0);
        for (final entry in [
          (refs.shape, CadAssetFile.brep, refs.shapeSha256),
          (refs.display, CadAssetFile.display, refs.displaySha256),
          (refs.appearance, CadAssetFile.appearance, refs.appearanceSha256),
        ]) {
          final file = asset(entry.$1, entry.$2);
          expect(file.lengthSync(), greaterThan(0));
          expect(
            (await sha256.bind(file.openRead()).first).toString(),
            entry.$3,
          );
        }
        final manifestFile = asset(refs.appearance, CadAssetFile.appearance);
        final manifest = StepAppearanceManifest.fromJson(
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>,
        );
        expect(manifestFile.readAsBytesSync(), manifest.encode());
        expect(manifest.name, 'Peça única');
        expect(entity.data['name'], manifest.name);
        expect(manifest.declaredMetersPerUnit, mode == 2 ? 1 : 0.001);
        expect(manifest.resolvedMetersPerUnit, 0.001);
        expect(manifest.hasColor, mode != 1);
        final scene = runtime.scene.find(entity.id)!;
        final bounds = (scene.geometry['bounds'] as List).cast<double>();
        expect(bounds[3] - bounds[0], closeTo(10, 1e-5));
        expect(bounds[4] - bounds[1], closeTo(20, 1e-5));
        expect(bounds[5] - bounds[2], closeTo(30, 1e-5));
        expect(scene.geometry['normalsOrigin'], 'calculatedByAdapter');
        final encodedScene = CadSceneDisplayAdapter()
            .initial(runtime.scene)
            .entities
            .single;
        if (mode == 1) {
          expect(manifest.toJson()['rootRgb'], isNull);
          expect(manifest.toJson()['alpha'], isNull);
          expect(scene.geometry.containsKey('rootLinearRgb'), isFalse);
          expect(cadRootColor(scene.geometry), isNull);
          expect(encodedScene.containsKey('rootSrgb'), isFalse);
        } else {
          expect(manifest.linearRgb, [.125, .5, .75]);
          expect(scene.geometry['rootLinearRgb'], manifest.linearRgb);
          final rgb = cadRootSrgb(scene.geometry)!;
          expect(rgb[0], closeTo(.388572859, 1e-8));
          expect(cadRootColor(scene.geometry)!.r, closeTo(rgb[0], 1e-7));
          expect(encodedScene['rootSrgb'], rgb);
        }
        final document = File(
          p.join(project.path, 'cad-document.json'),
        ).readAsStringSync();
        final encoded =
            '$document${jsonEncode(journals())}${manifestFile.readAsStringSync()}';
        for (final forbidden in [
          'sourcePath',
          'registeredPath',
          'pointer',
          'capability',
          'ShapeHandle',
          'KernelMeshHandle',
          'fingerprint',
          'token',
          source.path,
        ]) {
          expect(encoded, isNot(contains(forbidden)));
        }
        CadDocument.fromJson(jsonDecode(document) as Map<String, dynamic>);
        expect(journals().single['documentPublished'], isTrue);
        expect(
          Directory(p.join(project.path, 'NativeShapes')).existsSync(),
          isFalse,
        );
        expect(
          Directory(p.join(project.path, 'DisplayMeshes')).existsSync(),
          isFalse,
        );
        expect(
          project
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => p.extension(f.path) == '.tmp'),
          isEmpty,
        );
        final durable = await inventory(
          Directory(p.join(project.path, 'CAD', 'Assets')),
        );
        await runtime.save();
        await runtime.close();
        noOwners();
        expect(await inventory(source), original);
        expect(
          await inventory(Directory(p.join(project.path, 'CAD', 'Assets'))),
          durable,
        );
        expect(
          Directory(p.join(source.path, 'must-not-open.step')).existsSync(),
          isFalse,
        );
        expect(source.listSync().whereType<File>().length, 7);
        await runtime.open('step-project', project);
        final reopened = runtime.document!.entities[entity.id]!;
        expect(reopened.data['managedStepAssets'], refs.toJson());
        expect(reopened.data['name'], manifest.name);
        expect(runtime.hasManagedGeometry(entity.id), isTrue);
        expect(adapter.custodyDiagnostics!.allocations, 2);
        expect(
          runtime.scene.find(entity.id)!.geometry['rootLinearRgb'],
          manifest.linearRgb,
        );
        expect(
          cadRootSrgb(runtime.scene.find(entity.id)!.geometry),
          cadRootSrgb(scene.geometry),
        );
        expect(
          await inventory(Directory(p.join(project.path, 'CAD', 'Assets'))),
          durable,
        );
        expect(pathImports(), 0);
      },
    );
  }

  for (final mode in [3, 4, 5]) {
    test(
      'invalid, assembly or external STEP mode $mode publishes nothing',
      () async {
        final before = jsonEncode(runtime.document!.toJson());
        final original = await inventory(source);
        await expectLater(
          import(mode),
          throwsA(
            isA<NativeSourceFailure>().having(
              (e) => e.nativeStatus,
              'native rejection',
              5, // OCC_READ_FORMAT; not an arbitrary exception.
            ),
          ),
        );
        expect(jsonEncode(runtime.document!.toJson()), before);
        expect(promoted(), isEmpty);
        expect(
          runtime.scene.entities.where((e) => e.id.startsWith('e1_')),
          isEmpty,
        );
        expect(await inventory(source), original);
        noOwners();
      },
    );
  }

  for (final phase in [
    'managedStep:beforeShapeWrite',
    'managedStep:beforeDisplayWrite',
    'managedStep:beforeAppearance',
    'file:chunkWritten',
    'managedStep:beforePromotion',
    'managedStep:afterPromotion',
    'managedStep:beforePersistence',
    'manifest:committed:flushed',
  ]) {
    test(
      'failure at $phase preserves prior publication and quarantines assets',
      () async {
        final before = jsonEncode(runtime.document!.toJson());
        final scene = runtime.scene.entities.toList();
        final files = await inventory(source);
        storage.failAt = phase;
        await expectLater(
          import(0),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'injected boundary',
              'injected:$phase',
            ),
          ),
        );
        expect(jsonEncode(runtime.document!.toJson()), before);
        expect(runtime.scene.entities.toList(), scene);
        expect(await inventory(source), files);
        noOwners();
        expect(journals().single['documentPublished'], isFalse);
        if (phase == 'managedStep:afterPromotion' ||
            phase == 'managedStep:beforePersistence' ||
            phase == 'manifest:committed:flushed') {
          expect(promoted(), hasLength(3));
          expect(journals().single['state'], 'quarantined');
          for (final directory in promoted()) {
            expect(directory.listSync().whereType<File>().length, 2);
          }
        } else {
          expect(promoted(), isEmpty);
        }
      },
    );
  }

  test(
    'persistence failure preserves prior confirmed owners and asset bytes',
    () async {
      final entity = await import(0);
      runtime.select({entity.id});
      final before = jsonEncode(runtime.document!.toJson());
      final priorFiles = await inventory(
        Directory(p.join(project.path, 'CAD', 'Assets')),
      );
      final priorScene = runtime.scene.find(entity.id);
      final documentBytes = File(
        p.join(project.path, 'cad-document.json'),
      ).readAsBytesSync();
      final historyBytes = File(
        p.join(project.path, 'cad-document-history.json'),
      ).readAsBytesSync();
      final undo = runtime.canUndo, redo = runtime.canRedo;
      repository.reject = true;
      await expectLater(
        import(1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'persistence',
            'injected:step:persistence',
          ),
        ),
      );
      expect(jsonEncode(runtime.document!.toJson()), before);
      expect(identical(runtime.scene.find(entity.id), priorScene), isTrue);
      expect(runtime.selection, {entity.id});
      expect(
        File(p.join(project.path, 'cad-document.json')).readAsBytesSync(),
        documentBytes,
      );
      expect(
        File(
          p.join(project.path, 'cad-document-history.json'),
        ).readAsBytesSync(),
        historyBytes,
      );
      expect(runtime.canUndo, undo);
      expect(runtime.canRedo, redo);
      expect(runtime.hasManagedGeometry(entity.id), isTrue);
      expect(adapter.custodyDiagnostics!.allocations, 2);
      final after = await inventory(
        Directory(p.join(project.path, 'CAD', 'Assets')),
      );
      for (final entry in priorFiles.entries) {
        expect(after[entry.key], entry.value);
      }
      expect(
        journals().where((j) => j['state'] == 'quarantined'),
        hasLength(1),
      );
    },
  );

  for (final action in ['cancel', 'replace', 'shutdown']) {
    test('$action revokes suspended import before promotion', () async {
      final entered = Completer<void>(), release = Completer<void>();
      final cancellation = CadAssetCancellation();
      storage.gate = (phase) async {
        if (phase == 'managedStep:beforePromotion') {
          entered.complete();
          await release.future;
        }
      };
      final pending = import(0, cancellation: cancellation);
      final assertion = expectLater(
        pending,
        throwsA(isA<StaleCadTransaction>()),
      );
      await entered.future;
      Future<void>? boundary;
      if (action == 'cancel') {
        cancellation.cancel();
      }
      if (action == 'replace') {
        boundary = runtime.open(
          'replacement',
          await Directory(p.join(root.path, 'replacement')).create(),
        );
      }
      if (action == 'shutdown') {
        boundary = runtime.shutdown();
      }
      release.complete();
      await assertion;
      await boundary;
      expect(promoted(), isEmpty);
      expect(
        runtime.scene.entities.where((e) => e.id.startsWith('e1_')),
        isEmpty,
      );
      noOwners();
    });
  }
  test(
    'confirmation failure reports persisted commit and requires recovery',
    () async {
      var committedWrites = 0;
      storage.gate = (phase) async {
        if (phase == 'manifest:committed:flushed' && ++committedWrites == 2) {
          throw StateError('injected:step:confirmation');
        }
      };
      await expectLater(
        import(0),
        throwsA(
          isA<CadManagedStepPostCommitFailure>().having(
            (e) => e.cause,
            'confirmation',
            isA<StateError>().having(
              (e) => e.message,
              'cause',
              'injected:step:confirmation',
            ),
          ),
        ),
      );
      expect(runtime.recoveryRequired, isTrue);
      final entity = runtime.document!.entities.values.singleWhere(
        (e) => e.data['managedStepAssets'] != null,
      );
      expect(runtime.hasManagedGeometry(entity.id), isTrue);
      expect(runtime.scene.find(entity.id), isNotNull);
      expect(adapter.custodyDiagnostics!.allocations, 2);
      final persisted = CadDocument.fromJson(
        jsonDecode(
              File(
                p.join(project.path, 'cad-document.json'),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>,
      );
      expect(persisted.entities.containsKey(entity.id), isTrue);
      expect(promoted(), hasLength(3));
      expect(journals().single['state'], 'quarantined');
      expect(journals().single['documentPublished'], isFalse);
    },
  );

  test('two STEP colors survive repeated atomic open and close', () async {
    final first = await import(0);
    final second = await import(6);
    final before = await inventory(Directory(p.join(project.path, 'CAD')));
    for (var cycle = 0; cycle < 3; cycle++) {
      await runtime.close();
      noOwners();
      final observations = <bool>[];
      void observe() {
        observations.add(
          runtime.hasManagedGeometry(first.id) &&
              runtime.hasManagedGeometry(second.id) &&
              runtime.scene.find(first.id)?.geometry['rootLinearRgb'] != null &&
              runtime.scene.find(second.id)?.geometry['rootLinearRgb'] !=
                  null &&
              adapter.custodyDiagnostics!.allocations == 4,
        );
      }

      runtime.addListener(observe);
      runtime.scene.addListener(observe);
      await runtime.open('step-project', project);
      runtime.removeListener(observe);
      runtime.scene.removeListener(observe);
      expect(observations, isNotEmpty);
      expect(observations, everyElement(isTrue));
      expect(adapter.custodyDiagnostics!.allocations, 4);
      expect(runtime.hasManagedGeometry(first.id), isTrue);
      expect(runtime.hasManagedGeometry(second.id), isTrue);
      expect(runtime.scene.find(first.id)!.geometry['rootLinearRgb'], [
        .125,
        .5,
        .75,
      ]);
      expect(runtime.scene.find(second.id)!.geometry['rootLinearRgb'], [
        .75,
        .125,
        .5,
      ]);
      final encoded = CadSceneDisplayAdapter().initial(runtime.scene).entities;
      expect(
        encoded.singleWhere((e) => e['id'] == first.id)['rootSrgb'],
        cadRootSrgb(runtime.scene.find(first.id)!.geometry),
      );
      expect(
        encoded.singleWhere((e) => e['id'] == second.id)['rootSrgb'],
        cadRootSrgb(runtime.scene.find(second.id)!.geometry),
      );
      expect(await inventory(Directory(p.join(project.path, 'CAD'))), before);
      expect(pathImports(), 0);
    }
    storage.gate = (phase) async {
      if (phase == 'managedGeometry:beforeDispose') {
        expect(runtime.scene.find(first.id), isNull);
        expect(runtime.scene.find(second.id), isNull);
        expect(runtime.hasManagedGeometry(first.id), isFalse);
        expect(runtime.hasManagedGeometry(second.id), isFalse);
      }
    };
    await runtime.close();
    noOwners();
    expect(CadSceneDisplayAdapter().initial(runtime.scene).entities, isEmpty);
    expect(await inventory(Directory(p.join(project.path, 'CAD'))), before);
  });

  for (final kind in CadAssetFile.values.where(
    (k) => [
      CadAssetFile.brep,
      CadAssetFile.display,
      CadAssetFile.appearance,
    ].contains(k),
  )) {
    test(
      'open rejects missing ${kind.name} without partial publication',
      () async {
        final entity = await import(0);
        final refs = references(entity);
        await runtime.close();
        final prior = await establishPrevious(entity);
        final previous = runtime.document!.toJson();
        final visual = runtime.scene.find(prior.id);
        final id = kind == CadAssetFile.brep
            ? refs.shape
            : kind == CadAssetFile.display
            ? refs.display
            : refs.appearance;
        asset(id, kind).deleteSync();
        await expectLater(
          runtime.open('step-project', project),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'inventory',
              'Managed asset contains unexpected entries',
            ),
          ),
        );
        expect(runtime.document!.toJson(), previous);
        expect(runtime.scene.find(prior.id), same(visual));
        expect(runtime.hasManagedGeometry(prior.id), isTrue);
        expect(adapter.custodyDiagnostics!.allocations, 1);
        expect(adapter.custodyDiagnostics!.leases, 0);
        expect(pathImports(), 0);
      },
    );
    test(
      'open rejects divergent ${kind.name} hash without publication',
      () async {
        final entity = await import(0);
        final refs = references(entity);
        await runtime.close();
        final prior = await establishPrevious(entity);
        final previous = runtime.document!.toJson();
        final visual = runtime.scene.find(prior.id);
        final id = kind == CadAssetFile.brep
            ? refs.shape
            : kind == CadAssetFile.display
            ? refs.display
            : refs.appearance;
        final file = asset(id, kind);
        final size = file.lengthSync();
        final handle = file.openSync(mode: FileMode.append);
        handle.setPositionSync(0);
        handle.writeByteSync(0);
        handle.closeSync();
        expect(file.lengthSync(), size);
        await expectLater(
          runtime.open('step-project', project),
          throwsA(isA<StateError>()),
        );
        expect(runtime.document!.toJson(), previous);
        expect(runtime.scene.find(prior.id), same(visual));
        expect(runtime.hasManagedGeometry(prior.id), isTrue);
        expect(adapter.custodyDiagnostics!.allocations, 1);
        expect(adapter.custodyDiagnostics!.leases, 0);
        expect(pathImports(), 0);
      },
    );
  }

  for (final fault in [
    'json',
    'utf8',
    'schema',
    'version',
    'rgb',
    'unit',
    'name',
    'duplicate',
    'limit',
  ]) {
    test('open rejects appearance $fault after hash verification', () async {
      final entity = await import(0);
      final manifest =
          jsonDecode(
                asset(
                  references(entity).appearance,
                  CadAssetFile.appearance,
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      await runtime.close();
      final prior = await establishPrevious(entity);
      final previous = runtime.document!.toJson();
      final visual = runtime.scene.find(prior.id);
      List<int> bytes;
      switch (fault) {
        case 'json':
          bytes = utf8.encode('{');
        case 'utf8':
          bytes = [255];
        case 'schema':
          manifest['schema'] = 'invalid';
          bytes = utf8.encode(jsonEncode(manifest));
        case 'version':
          manifest['version'] = 2;
          bytes = utf8.encode(jsonEncode(manifest));
        case 'rgb':
          manifest['rootRgb'] = [2, .5, .75];
          bytes = utf8.encode(jsonEncode(manifest));
        case 'unit':
          manifest['resolvedMetersPerUnit'] = 1;
          bytes = utf8.encode(jsonEncode(manifest));
        case 'name':
          manifest['name'] = 'contradiction';
          bytes = utf8.encode(jsonEncode(manifest));
        case 'duplicate':
          bytes = utf8.encode(
            '${jsonEncode(manifest).substring(0, jsonEncode(manifest).length - 1)},"name":"${manifest['name']}"}',
          );
        default:
          bytes = List.filled(16 * 1024 + 1, 32);
      }
      await corruptManifest(entity, bytes);
      await expectLater(
        runtime.open('step-project', project),
        throwsA(isA<FormatException>()),
      );
      expect(runtime.document!.toJson(), previous);
      expect(runtime.scene.find(prior.id), same(visual));
      expect(runtime.hasManagedGeometry(prior.id), isTrue);
      expect(adapter.custodyDiagnostics!.allocations, 1);
      expect(adapter.custodyDiagnostics!.leases, 0);
      expect(pathImports(), 0);
      capabilitiesReleased(entity);
    });
  }

  for (final action in ['cancel', 'replace', 'shutdown', 'second']) {
    test(
      'STEP open $action drains prepared owners deterministically',
      () async {
        final entity = await import(0);
        await import(6);
        final before = await inventory(Directory(p.join(project.path, 'CAD')));
        await runtime.close();
        final entered = Completer<void>();
        final release = Completer<void>();
        var prepared = 0;
        storage.gate = (phase) async {
          if (phase == 'managedOpen:afterMesh' && ++prepared == 1) {
            entered.complete();
            await release.future;
          }
          if (action == 'second' &&
              phase == 'managedOpen:beforeEntity' &&
              prepared == 1) {
            throw StateError('injected:second');
          }
        };
        final cancellation = CadAssetCancellation();
        final pending = runtime.open(
          'step-project',
          project,
          cancellation: cancellation,
        );
        final assertion = expectLater(
          pending,
          throwsA(
            action == 'second'
                ? isA<StateError>().having(
                    (e) => e.message,
                    'cause',
                    'injected:second',
                  )
                : isA<StaleCadTransaction>(),
          ),
        );
        await entered.future;
        expect(adapter.custodyDiagnostics!.allocations, 2);
        expect(runtime.scene.entities, isEmpty);
        Future<void>? boundary;
        if (action == 'cancel') cancellation.cancel();
        if (action == 'replace') {
          boundary = runtime.open(
            'replacement',
            await Directory(p.join(root.path, 'replacement')).create(),
          );
        }
        if (action == 'shutdown') boundary = runtime.shutdown();
        release.complete();
        await assertion;
        await boundary;
        noOwners();
        capabilitiesReleased(entity);
        expect(await inventory(Directory(p.join(project.path, 'CAD'))), before);
      },
    );
  }

  test('mixed STEP BREP STL and serialized legacy reopen together', () async {
    await runtime.mutate(
      command: 'test.legacy',
      upsert: const [
        CadDocumentEntity(
          id: 'legacy',
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
    // The bridge smoke fixture requires a direct child with this prefix.
    final folder = await Directory.systemTemp.createTemp('cob-dart-');
    addTearDown(() => folder.delete(recursive: true));
    final result = await Process.run(
      Platform.environment['FLCAD_SOURCE_FIXTURE_EXE']!,
      [caf, occ, folder.path],
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final brep = await runtime.importManagedBrep(
      p.join(folder.path, 'shape.brep'),
      nativeBridgePath: bridge,
    );
    final stl = await runtime.importManagedStl(
      p.join(folder.path, 'display.stl'),
      nativeBridgePath: bridge,
    );
    final step = await import(0);
    final before = await inventory(Directory(p.join(project.path, 'CAD')));
    await runtime.close();
    await runtime.open('step-project', project);
    expect(
      runtime.scene.entities.where(
        (e) => ['legacy', brep.id, stl.id, step.id].contains(e.id),
      ),
      hasLength(4),
    );
    expect(adapter.custodyDiagnostics!.allocations, 5);
    for (final id in [brep.id, stl.id, step.id]) {
      expect(runtime.hasManagedGeometry(id), isTrue);
    }
    expect(runtime.scene.find('legacy')!.geometry['position'], [4, 5, 6]);
    expect(runtime.scene.find(step.id)!.geometry['rootLinearRgb'], [
      .125,
      .5,
      .75,
    ]);
    expect(
      runtime.scene.find(brep.id)!.geometry.containsKey('rootLinearRgb'),
      isFalse,
    );
    expect(
      runtime.scene.find(stl.id)!.geometry.containsKey('rootLinearRgb'),
      isFalse,
    );
    expect(await inventory(Directory(p.join(project.path, 'CAD'))), before);
    expect(
      Directory(p.join(project.path, 'NativeShapes')).existsSync(),
      isFalse,
    );
    expect(
      Directory(p.join(project.path, 'DisplayMeshes')).existsSync(),
      isFalse,
    );
    expect(pathImports(), 0);
  });

  for (final kind in [
    CadAssetFile.brep,
    CadAssetFile.display,
    CadAssetFile.appearance,
  ]) {
    test('anchored STEP ${kind.name} rejects late mutation', () async {
      final entity = await import(0);
      final refs = references(entity);
      final id = kind == CadAssetFile.brep
          ? refs.shape
          : kind == CadAssetFile.display
          ? refs.display
          : refs.appearance;
      final file = asset(id, kind);
      final before = await inventory(Directory(p.join(project.path, 'CAD')));
      await runtime.close();
      storage.gate = (phase) async {
        if (phase == 'managedOpen:beforePublish') {
          // CAF keeps deny-write handles alive through publication.
          final handle = file.openSync(mode: FileMode.append);
          try {
            handle.writeByteSync(0);
          } finally {
            handle.closeSync();
          }
        }
      };
      await expectLater(
        runtime.open('step-project', project),
        throwsA(
          isA<PathAccessException>().having(
            (e) => e.osError?.errorCode,
            'sharing violation',
            32,
          ),
        ),
      );
      expect(runtime.document, isNull);
      expect(runtime.scene.entities, isEmpty);
      noOwners();
      capabilitiesReleased(entity);
      expect(await inventory(Directory(p.join(project.path, 'CAD'))), before);
    });
  }
}
