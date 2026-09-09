import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:flcad_mobile/app/runtime/cad_asset_fs_native.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';

class _Storage extends CadAssetStorage {
  Future<void> Function(String)? hook;
  @override
  Future<void> checkpoint(String phase) async {
    await hook?.call(phase);
  }
}

Future<Map<String, String>> inventory(Directory directory) async {
  final result = <String, String>{};
  await for (final e in directory.list(recursive: true, followLinks: false)) {
    result[p.relative(e.path, from: directory.path)] = e is File
        ? base64Encode(await e.readAsBytes())
        : e.runtimeType.toString();
  }
  return result;
}

void main() {
  late Directory root, project, outside;
  late CadRuntime runtime;
  late _Storage storage;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('caf-gateway-');
    project = await Directory(
      p.join(root.path, 'projeto 日本 com espaços'),
    ).create();
    outside = await Directory(p.join(root.path, 'outside')).create();
    await File(p.join(outside.path, 'sentinel')).writeAsString('external');
    storage = _Storage();
    runtime = CadRuntime(kernels: KernelManager(), assetStorage: storage);
    await runtime.open('project', project);
  });
  tearDown(() async {
    await runtime.shutdown();
    await root.delete(recursive: true);
  });
  Future<PreparedGeometryAssets> promote() => runtime.withGeometryStaging((
    op,
  ) async {
    final id = await op.planAsset();
    await op.write(id, CadAssetFile.brep, Stream.value(utf8.encode('payload')));
    await op.prepare();
    return op.promote();
  });

  for (final mode in ['missing', 'abi']) {
    test(
      '$mode helper fails before filesystem mutation in fresh process',
      () async {
        final before = await inventory(project);
        var search = File(Platform.resolvedExecutable).parent;
        String? executable;
        for (var i = 0; i < 8; i++) {
          for (final candidate in [
            p.join(search.path, 'dart-sdk', 'bin', 'dart.exe'),
            p.join(search.path, 'bin', 'cache', 'dart-sdk', 'bin', 'dart.exe'),
          ]) {
            if (await File(candidate).exists()) executable = candidate;
          }
          if (executable != null) break;
          search = search.parent;
        }
        expect(executable, isNotNull);
        final dll = Platform.environment['FLCAD_CAD_ASSET_FS_DLL']!;
        final selected = mode == 'abi'
            ? p.join(p.dirname(dll), 'cad_asset_fs_incompatible.dll')
            : p.join(root.path, 'absent.dll');
        if (mode == 'abi') expect(await File(selected).exists(), isTrue);
        final result = await Process.run(
          executable!,
          ['run', 'test/support/cad_asset_fs_probe.dart', mode, project.path],
          environment: {'FLCAD_CAD_ASSET_FS_DLL': selected},
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout.toString(), contains('EXPECTED'));
        expect(await inventory(project), before);
      },
    );
  }

  test(
    'real process cannot swap pinned ancestor at journal and promotion barriers',
    () async {
      final before = await inventory(outside);
      var attacks = 0;
      storage.hook = (phase) async {
        if (![
          'manifest:prepared:beforeReplace',
          'promotion:beforeMove',
        ].contains(phase)) {
          return;
        }
        final script =
            r"try { [IO.Directory]::Move($env:CAF_FROM, $env:CAF_TO); exit 9 } catch [IO.IOException] { if (($_.Exception.HResult -band 65535) -eq 32) { exit 0 }; throw }";
        final result = await Process.run(
          'powershell.exe',
          ['-NoProfile', '-NonInteractive', '-Command', script],
          environment: {
            'CAF_FROM': project.path,
            'CAF_TO': p.join(outside.path, 'escaped'),
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(await inventory(outside), before);
        attacks++;
      };
      final result = await promote();
      expect(result.assets, hasLength(1));
      expect(attacks, 2);
      expect(await inventory(outside), before);
    },
  );

  for (final modification in ['identity', 'size', 'hash']) {
    test(
      '$modification divergence after seal quarantines without deletion',
      () async {
        late String stage, payload;
        await expectLater(
          runtime.withGeometryStaging((op) async {
            stage = op.stagingDirectory;
            final id = await op.planAsset();
            await op.write(
              id,
              CadAssetFile.brep,
              Stream.value(utf8.encode('payload')),
            );
            await op.prepare();
            payload = p.join(stage, 'files', id.value, 'shape.brep');
            if (modification == 'identity') {
              await File(payload).rename('$payload.retained');
              await File(payload).writeAsString('payload');
            } else {
              await File(payload).writeAsString(
                modification == 'size' ? 'longer payload' : 'changed',
              );
            }
            await op.promote();
          }),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'cause',
              'Payload changed after validation',
            ),
          ),
        );
        final recovered = (await inspectCadAssetStaging(project)).single;
        expect(recovered.classification, 'quarantinedRecordedFailure');
        expect(await File(payload).exists(), isTrue);
        expect(await Directory(stage).exists(), isTrue);
        if (modification == 'identity') {
          expect(await File('$payload.retained').exists(), isTrue);
        }
      },
    );
  }

  test(
    'native capabilities close idempotently and reject subsequent calls',
    () {
      final fs = CadAssetNativeFs(project.path);
      final rootId = fs.root;
      fs.dispose();
      fs.dispose();
      expect(() => fs.info(rootId), throwsStateError);
    },
  );

  test(
    'collision immediately before native rename preserves existing directory',
    () async {
      late String destination;
      storage.hook = (phase) async {
        if (phase != 'promotion:renameReady') return;
        final stage = Directory(p.join(project.path, '.cad-staging'));
        final payload = await stage
            .list(recursive: true)
            .where((e) => e is File && p.basename(e.path) == 'shape.brep')
            .single;
        destination = p.join(
          project.path,
          'CAD',
          'Assets',
          'v1',
          p.basename(p.dirname(payload.path)),
        );
        await Directory(destination).create();
      };
      await expectLater(
        promote(),
        throwsA(
          isA<CadAssetNativeError>()
              .having((e) => e.collision, 'native collision', isTrue)
              .having((e) => e.effect, 'no rename effect', 0),
        ),
      );
      expect(await Directory(destination).exists(), isTrue);
      expect(await Directory(destination).list().toList(), isEmpty);
      final recovery = (await inspectCadAssetStaging(project)).single;
      expect(recovery.classification, 'quarantinedInvalidManifestOrPath');
      final data =
          (jsonDecode(
                    await File(
                      p.join(recovery.directory, 'manifest.json'),
                    ).readAsString(),
                  )
                  as Map)['data']
              as Map;
      expect(data['state'], 'quarantined');
      expect(data['promoted'], isEmpty);
    },
  );

  test(
    'post-rename divergence preserves completed move in quarantine',
    () async {
      late String payload;
      storage.hook = (phase) async {
        if (phase != 'promotion:renamed') return;
        final entry =
            await Directory(p.join(project.path, 'CAD', 'Assets', 'v1'))
                .list(recursive: true)
                .where((e) => e is File && p.basename(e.path) == 'shape.brep')
                .single;
        payload = entry.path;
        await File(payload).writeAsString('changed');
      };
      await expectLater(
        promote(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'cause',
            'Payload changed after validation',
          ),
        ),
      );
      expect(await File(payload).readAsString(), 'changed');
      final recovery = (await inspectCadAssetStaging(project)).single;
      final data =
          (jsonDecode(
                    await File(
                      p.join(recovery.directory, 'manifest.json'),
                    ).readAsString(),
                  )
                  as Map)['data']
              as Map;
      expect(data['state'], 'quarantined');
      expect(data['promoted'], hasLength(1));
    },
  );

  test(
    'recovery quarantines reparse instance and still inspects valid operation',
    () async {
      await promote();
      final before = await inventory(outside);
      final junction = p.join(project.path, '.cad-staging', 'i1_${'a' * 32}');
      final child = await Process.run('cmd.exe', [
        '/d',
        '/c',
        'mklink',
        '/J',
        junction,
        outside.path,
      ]);
      expect(child.exitCode, 0, reason: '${child.stderr}');
      final results = await inspectCadAssetStaging(project);
      expect(
        results.map((r) => r.classification),
        unorderedEquals([
          'awaitingDocumentReconciliation',
          'quarantinedInvalidInstance',
        ]),
      );
      expect(await inventory(outside), before);
    },
  );

  test('gateway handles project paths beyond MAX_PATH', () async {
    var longPath = project.path;
    for (var i = 0; i < 8; i++) {
      longPath = p.join(longPath, '日本 espaços segmento_${'x' * 20}');
    }
    final longProject = await Directory(
      '\\\\?\\$longPath',
    ).create(recursive: true);
    final fs = CadAssetNativeFs(longProject.path);
    try {
      final file = fs.child(fs.root, 'payload.bin', create: true);
      fs.write(file, [1, 2, 3]);
      expect(fs.info(file, digest: true)['size'], 3);
      expect(fs.read(file, 0, 3), [1, 2, 3]);
    } finally {
      fs.dispose();
    }
    expect(longPath.length, greaterThan(260));
  });

  test(
    'restart recovery traverses helper and preserves durable identity',
    () async {
      final result = await promote();
      await runtime.save();
      await runtime.shutdown();
      final before = await inventory(project);
      runtime = CadRuntime(kernels: KernelManager());
      await runtime.open('project', project);
      final recovered = (await inspectCadAssetStaging(project)).single;
      expect(recovered.assetsVerified, isTrue);
      expect(recovered.classification, 'awaitingDocumentReconciliation');
      expect(await inventory(project), before);
      final id = result.assets.single.value;
      final fs = CadAssetNativeFs(project.path);
      try {
        var dir = fs.root;
        for (final name in ['CAD', 'Assets', 'v1', id]) {
          dir = fs.child(dir, name, directory: true);
        }
        final file = fs.child(dir, 'shape.brep');
        final info = fs.info(file, digest: true);
        expect(info['size'], 7);
        expect(info['fileId'], matches(r'^[a-f0-9]{32}$'));
        expect(utf8.decode(fs.read(file, 0, 7)), 'payload');
      } finally {
        fs.dispose();
      }
    },
  );
}
