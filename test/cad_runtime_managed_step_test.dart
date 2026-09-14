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
        expect(source.listSync().whereType<File>().length, 6);
        await expectLater(
          runtime.open('step-project', project),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'phase',
              contains('STEP-2'),
            ),
          ),
        );
        expect(runtime.document, isNull);
        expect(runtime.scene.entities, isEmpty);
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
}
