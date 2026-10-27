import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/sketch_factory.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/sketch_engine/persistence/sketch_persistence_transaction.dart';
import 'package:flcad_mobile/core/sketch_engine/repository/sketch_repository.dart';

void main() {
  test(
    'restores all Sketch contract trees after a partial save failure',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'sketch-persistence-test-',
      );
      addTearDown(() => project.delete(recursive: true));
      final sketch = Directory('${project.path}/CAD/Sketch')
        ..createSync(recursive: true);
      final constraints = Directory('${project.path}/CAD/Constraints')
        ..createSync(recursive: true);
      final beforeSketch = File('${sketch.path}/canonical.json')
        ..writeAsStringSync('{"value":1}');
      final beforeConstraint = File('${constraints.path}/canonical.json')
        ..writeAsStringSync('{"value":1}');

      await expectLater(
        const SketchPersistenceTransaction().run(project, () async {
          await beforeSketch.writeAsString('{"value":2}');
          await File('${constraints.path}/partial.json').writeAsString('{}');
          throw StateError('simulated interruption');
        }),
        throwsStateError,
      );

      expect(await beforeSketch.readAsString(), '{"value":1}');
      expect(await beforeConstraint.readAsString(), '{"value":1}');
      expect(await File('${constraints.path}/partial.json').exists(), isFalse);
    },
  );

  test('backup preserves nested repository directories', () async {
    final project = await Directory.systemTemp.createTemp(
      'sketch-nested-backup-',
    );
    addTearDown(() => project.delete(recursive: true));
    final nested =
        File('${project.path}/CAD/SketchEntities/sketch-a/entities.bundle.json')
          ..createSync(recursive: true)
          ..writeAsStringSync('{"value":"previous"}');

    await expectLater(
      const SketchPersistenceTransaction().run(project, () async {
        nested.writeAsStringSync('{"value":"partial"}');
        throw StateError('simulated interruption');
      }),
      throwsStateError,
    );

    expect(nested.readAsStringSync(), '{"value":"previous"}');
  });

  test('failed rollback preserves manifest and backup for retry', () async {
    final project = await Directory.systemTemp.createTemp(
      'sketch-recovery-failure-',
    );
    addTearDown(() => project.delete(recursive: true));
    final target = File('${project.path}/CAD/Sketch/state.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"value":"previous"}');

    await expectLater(
      const SketchPersistenceTransaction().run(project, () async {
        target.writeAsStringSync('{"value":"partial"}');
        Directory(
          '${project.path}/CAD/${SketchPersistenceTransaction.backupDirectoryName}'
          '/CAD/Sketch',
        ).deleteSync(recursive: true);
        throw StateError('primary failure');
      }),
      throwsA(isA<SketchPersistenceRecoveryFailure>()),
    );

    expect(
      File(
        '${project.path}/CAD/${SketchPersistenceTransaction.manifestFileName}',
      ).existsSync(),
      isTrue,
    );
    expect(
      Directory(
        '${project.path}/CAD/${SketchPersistenceTransaction.backupDirectoryName}',
      ).existsSync(),
      isTrue,
    );
  });

  test('truncated backup with wrong hash is preserved and rejected', () async {
    final project = await Directory.systemTemp.createTemp(
      'sketch-hash-failure-',
    );
    addTearDown(() => project.delete(recursive: true));
    final cad = Directory('${project.path}/CAD')..createSync(recursive: true);
    final target = File('${cad.path}/Sketch/state.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"value":"partial"}');
    final backup = Directory(
      '${cad.path}/${SketchPersistenceTransaction.backupDirectoryName}',
    )..createSync(recursive: true);
    final backedUp = File('${backup.path}/CAD/Sketch/state.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"value":"previous"}');
    File('${backup.path}/backup.complete').writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.sketch-snapshot-backup',
        'version': 1,
        'files': {
          'CAD/Sketch/state.json': sha256
              .convert(utf8.encode('{"value":"previous"}'))
              .toString(),
        },
      }),
    );
    final expectedHash = sha256
        .convert(utf8.encode('{"value":"previous"}'))
        .toString();
    backedUp.writeAsStringSync('{"value":"truncated"}');
    File(
      '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
    ).writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.sketch-save-transaction',
        'version': 1,
        'phase': 'prepared',
        'backup': SketchPersistenceTransaction.backupDirectoryName,
        'files': {'CAD/Sketch/state.json': expectedHash},
      }),
    );

    await expectLater(
      const SketchPersistenceTransaction().recoverIfNeeded(project),
      throwsA(isA<SketchPersistenceRecoveryFailure>()),
    );
    expect(
      File(
        '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
      ).existsSync(),
      isTrue,
    );
    expect(backup.existsSync(), isTrue);
    expect(target.readAsStringSync(), '{"value":"partial"}');
  });

  test(
    'wrong manifest hash restores a backup proven by its independent marker',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'sketch-divergent-hash-recovery-',
      );
      addTearDown(() => project.delete(recursive: true));
      final cad = Directory('${project.path}/CAD')..createSync(recursive: true);
      final target = File('${cad.path}/Sketch/state.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"value":"partial"}');
      final backup = Directory(
        '${cad.path}/${SketchPersistenceTransaction.backupDirectoryName}',
      )..createSync(recursive: true);
      final backedUp = File('${backup.path}/CAD/Sketch/state.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"value":"previous"}');
      final backupHash = sha256
          .convert(utf8.encode('{"value":"previous"}'))
          .toString();
      File('${backup.path}/backup.complete').writeAsStringSync(
        jsonEncode({
          'schema': 'flcad.sketch-snapshot-backup',
          'version': 1,
          'files': {'CAD/Sketch/state.json': backupHash},
        }),
      );
      File(
        '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
      ).writeAsStringSync(
        jsonEncode({
          'schema': 'flcad.sketch-save-transaction',
          'version': 1,
          'phase': 'prepared',
          'backup': SketchPersistenceTransaction.backupDirectoryName,
          'files': {'CAD/Sketch/state.json': List.filled(64, '0').join()},
        }),
      );

      await const SketchPersistenceTransaction().recoverIfNeeded(project);

      expect(target.readAsStringSync(), '{"value":"previous"}');
      expect(backedUp.existsSync(), isFalse);
      expect(
        File(
          '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('recovery cleanup is idempotent after the backup was removed', () async {
    final project = await Directory.systemTemp.createTemp(
      'sketch-cleanup-recovery-',
    );
    addTearDown(() => project.delete(recursive: true));
    final cad = Directory('${project.path}/CAD')..createSync(recursive: true);
    final target = File('${cad.path}/Sketch/state.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"value":"previous"}');
    final targetHash = sha256
        .convert(utf8.encode('{"value":"previous"}'))
        .toString();
    final manifest =
        File('${cad.path}/${SketchPersistenceTransaction.manifestFileName}')
          ..writeAsStringSync(
            jsonEncode({
              'schema': 'flcad.sketch-save-transaction',
              'version': 1,
              'phase': 'prepared',
              'backup': SketchPersistenceTransaction.backupDirectoryName,
              'files': {'CAD/Sketch/state.json': targetHash},
            }),
            flush: true,
          );

    await const SketchPersistenceTransaction().recoverIfNeeded(project);
    await const SketchPersistenceTransaction().recoverIfNeeded(project);

    expect(target.readAsStringSync(), '{"value":"previous"}');
    expect(manifest.existsSync(), isFalse);
  });

  test('empty prepared snapshot recovers an untouched project', () async {
    final project = await Directory.systemTemp.createTemp(
      'sketch-empty-prepared-',
    );
    addTearDown(() => project.delete(recursive: true));
    final cad = Directory('${project.path}/CAD')..createSync(recursive: true);
    final partial = File('${cad.path}/Sketch/partial.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"partial":true}');
    final backup = Directory(
      '${cad.path}/${SketchPersistenceTransaction.backupDirectoryName}',
    )..createSync(recursive: true);
    File('${backup.path}/backup.complete').writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.sketch-snapshot-backup',
        'version': 1,
        'files': const <String, String>{},
      }),
    );
    File(
      '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
    ).writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.sketch-save-transaction',
        'version': 1,
        'phase': 'prepared',
        'backup': SketchPersistenceTransaction.backupDirectoryName,
        'files': const <String, String>{},
      }),
    );

    await const SketchPersistenceTransaction().recoverIfNeeded(project);

    expect(partial.existsSync(), isFalse);
    expect(backup.existsSync(), isFalse);
    expect(
      File(
        '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
      ).existsSync(),
      isFalse,
    );
  });

  test('legacy marker alone cannot restore a truncated backup', () async {
    final project = await Directory.systemTemp.createTemp(
      'sketch-legacy-marker-',
    );
    addTearDown(() => project.delete(recursive: true));
    final cad = Directory('${project.path}/CAD')..createSync(recursive: true);
    final target = File('${cad.path}/Sketch/state.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"value":"current"}');
    final backup = Directory(
      '${cad.path}/${SketchPersistenceTransaction.backupDirectoryName}',
    )..createSync(recursive: true);
    File('${backup.path}/CAD/Sketch/state.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"value":"partial"}');
    File('${backup.path}/backup.complete').writeAsStringSync('1', flush: true);
    final manifest = File(
      '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
    )..writeAsStringSync('{"phase":', flush: true);

    await expectLater(
      const SketchPersistenceTransaction().recoverIfNeeded(project),
      throwsA(isA<SketchPersistenceRecoveryFailure>()),
    );

    expect(target.readAsStringSync(), '{"value":"current"}');
    expect(backup.existsSync(), isTrue);
    expect(manifest.existsSync(), isTrue);
  });

  test('marker without hashes cannot authorize restoration', () async {
    final project = await Directory.systemTemp.createTemp(
      'sketch-empty-marker-',
    );
    addTearDown(() => project.delete(recursive: true));
    final cad = Directory('${project.path}/CAD')..createSync(recursive: true);
    final target = File('${cad.path}/Sketch/state.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"value":"current"}');
    final backup = Directory(
      '${cad.path}/${SketchPersistenceTransaction.backupDirectoryName}',
    )..createSync(recursive: true);
    File('${backup.path}/backup.complete').writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.sketch-snapshot-backup',
        'version': 1,
        'files': const <String, String>{},
      }),
    );
    File(
      '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
    ).writeAsStringSync('{"phase":', flush: true);

    await expectLater(
      const SketchPersistenceTransaction().recoverIfNeeded(project),
      throwsA(isA<SketchPersistenceRecoveryFailure>()),
    );

    expect(target.readAsStringSync(), '{"value":"current"}');
    expect(backup.existsSync(), isTrue);
  });

  test(
    'syntactically valid committed manifest without schema is not trusted',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'sketch-invalid-commit-',
      );
      addTearDown(() => project.delete(recursive: true));
      final cad = Directory('${project.path}/CAD')..createSync(recursive: true);
      final target = File('${cad.path}/Sketch/state.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"value":"new"}');
      final backup = Directory(
        '${cad.path}/${SketchPersistenceTransaction.backupDirectoryName}',
      )..createSync(recursive: true);
      final previous = utf8.encode('{"value":"previous"}');
      File('${backup.path}/CAD/Sketch/state.json')
        ..createSync(recursive: true)
        ..writeAsBytesSync(previous);
      File('${backup.path}/backup.complete').writeAsStringSync(
        jsonEncode({
          'schema': 'flcad.sketch-snapshot-backup',
          'version': 1,
          'files': {
            'CAD/Sketch/state.json': sha256.convert(previous).toString(),
          },
        }),
      );
      File(
        '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
      ).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'phase': 'committed',
          'backup': SketchPersistenceTransaction.backupDirectoryName,
          'files': {
            'CAD/Sketch/state.json': sha256.convert(previous).toString(),
          },
        }),
      );

      await const SketchPersistenceTransaction().recoverIfNeeded(project);

      expect(target.readAsStringSync(), '{"value":"previous"}');
      expect(backup.existsSync(), isFalse);
    },
  );

  test(
    'committed manifest with divergent published hash restores backup',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'sketch-divergent-commit-',
      );
      addTearDown(() => project.delete(recursive: true));
      final cad = Directory('${project.path}/CAD')..createSync(recursive: true);
      final target = File('${cad.path}/Sketch/state.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"value":"partial"}');
      final backup = Directory(
        '${cad.path}/${SketchPersistenceTransaction.backupDirectoryName}',
      )..createSync(recursive: true);
      final previous = utf8.encode('{"value":"previous"}');
      File('${backup.path}/CAD/Sketch/state.json')
        ..createSync(recursive: true)
        ..writeAsBytesSync(previous);
      final previousHash = sha256.convert(previous).toString();
      File('${backup.path}/backup.complete').writeAsStringSync(
        jsonEncode({
          'schema': 'flcad.sketch-snapshot-backup',
          'version': 1,
          'files': {'CAD/Sketch/state.json': previousHash},
        }),
      );
      File(
        '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
      ).writeAsStringSync(
        jsonEncode({
          'schema': 'flcad.sketch-save-transaction',
          'version': 1,
          'phase': 'committed',
          'backup': SketchPersistenceTransaction.backupDirectoryName,
          'files': {'CAD/Sketch/state.json': previousHash},
          'committedFiles': {
            'CAD/Sketch/state.json': List.filled(64, '0').join(),
          },
        }),
      );

      await const SketchPersistenceTransaction().recoverIfNeeded(project);

      expect(target.readAsStringSync(), '{"value":"previous"}');
      expect(backup.existsSync(), isFalse);
    },
  );

  test('commits the existing repository layout as one successful save', () async {
    final project = await Directory.systemTemp.createTemp(
      'sketch-persistence-test-',
    );
    addTearDown(() => project.delete(recursive: true));
    final file = File('${project.path}/CAD/Sketch/state.json');
    await const SketchPersistenceTransaction().run(project, () async {
      await file.parent.create(recursive: true);
      await file.writeAsString('{"value":3}');
    });
    expect(await file.readAsString(), '{"value":3}');
    expect(
      Directory(
        '${project.path}${Platform.pathSeparator}CAD'
        '${Platform.pathSeparator}${SketchPersistenceTransaction.backupDirectoryName}',
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        '${project.path}${Platform.pathSeparator}CAD'
        '${Platform.pathSeparator}${SketchPersistenceTransaction.manifestFileName}',
      ).existsSync(),
      isFalse,
    );
  });

  test('corrupt manifest restores the durable previous snapshot', () async {
    final project = await Directory.systemTemp.createTemp(
      'sketch-corrupt-manifest-',
    );
    addTearDown(() => project.delete(recursive: true));
    final cad = Directory('${project.path}/CAD')..createSync(recursive: true);
    final target = File('${cad.path}/Sketch/state.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"value":"partial"}');
    final backup = Directory(
      '${cad.path}/${SketchPersistenceTransaction.backupDirectoryName}',
    )..createSync(recursive: true);
    File('${backup.path}/CAD/Sketch/state.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"value":"previous"}');
    File('${backup.path}/backup.complete').writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.sketch-snapshot-backup',
        'version': 1,
        'files': {
          'CAD/Sketch/state.json': sha256
              .convert(utf8.encode('{"value":"previous"}'))
              .toString(),
        },
      }),
    );
    File(
      '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
    ).writeAsStringSync('{"phase":');

    await const SketchPersistenceTransaction().recoverIfNeeded(project);

    expect(target.readAsStringSync(), '{"value":"previous"}');
    expect(backup.existsSync(), isFalse);
    expect(
      File(
        '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
      ).existsSync(),
      isFalse,
    );
  });

  test(
    'committed manifest keeps the new snapshot and cleans recovery files',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'sketch-committed-manifest-',
      );
      addTearDown(() => project.delete(recursive: true));
      final cad = Directory('${project.path}/CAD')..createSync(recursive: true);
      final target = File('${cad.path}/Sketch/state.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"value":"new"}');
      final backup = Directory(
        '${cad.path}/${SketchPersistenceTransaction.backupDirectoryName}',
      )..createSync(recursive: true);
      File('${backup.path}/CAD/Sketch/state.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"value":"previous"}');
      final backupHash = sha256
          .convert(utf8.encode('{"value":"previous"}'))
          .toString();
      File('${backup.path}/backup.complete').writeAsStringSync(
        jsonEncode({
          'schema': 'flcad.sketch-snapshot-backup',
          'version': 1,
          'files': {'CAD/Sketch/state.json': backupHash},
        }),
      );
      File(
        '${cad.path}/${SketchPersistenceTransaction.manifestFileName}',
      ).writeAsStringSync(
        jsonEncode({
          'schema': 'flcad.sketch-save-transaction',
          'version': 1,
          'phase': 'committed',
          'backup': SketchPersistenceTransaction.backupDirectoryName,
          'files': {'CAD/Sketch/state.json': backupHash},
          'committedFiles': {
            'CAD/Sketch/state.json': sha256
                .convert(utf8.encode('{"value":"new"}'))
                .toString(),
          },
        }),
      );

      await const SketchPersistenceTransaction().recoverIfNeeded(project);

      expect(target.readAsStringSync(), '{"value":"new"}');
      expect(backup.existsSync(), isFalse);
    },
  );

  test('bundle save preserves a loose file without reabsorbing it', () async {
    final project = await Directory.systemTemp.createTemp('sketch-bundle-');
    addTearDown(() => project.delete(recursive: true));
    final repository = SketchRepository(project);
    final kept = SketchLine(const SketchVector(0, 0), const SketchVector(1, 0));
    final removed = SketchLine(
      const SketchVector(0, 1),
      const SketchVector(1, 1),
    );
    await repository.saveEntities('sketch-a', [kept, removed]);
    final extra = SketchLine(
      const SketchVector(2, 2),
      const SketchVector(3, 2),
    );
    final dir = Directory(
      '${project.path}${Platform.pathSeparator}CAD'
      '${Platform.pathSeparator}SketchEntities'
      '${Platform.pathSeparator}sketch-a',
    );
    final safeExtra = extra.id.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    await File(
      '${dir.path}${Platform.pathSeparator}$safeExtra.json',
    ).writeAsString(jsonEncode(extra.toJson()));

    await repository.saveEntities('sketch-a', [kept]);
    final ids = (await repository.loadEntities(
      'sketch-a',
    )).map((entity) => entity.id).toSet();
    expect(ids, {kept.id});
    expect(
      File('${dir.path}${Platform.pathSeparator}$safeExtra.json').existsSync(),
      isTrue,
    );
    expect(
      await File(
        '${dir.path}${Platform.pathSeparator}entities.bundle.json',
      ).exists(),
      isFalse,
    );
  });

  test(
    'legacy individual entities removed by the engine do not return',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'sketch-legacy-delete-',
      );
      addTearDown(() => project.delete(recursive: true));
      final repository = SketchRepository(project);
      final kept = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final removed = SketchLine(
        const SketchVector(0, 1),
        const SketchVector(1, 1),
      );
      final dir = Directory('${project.path}/CAD/SketchEntities/sketch-a')
        ..createSync(recursive: true);
      String fileName(SketchEntity entity) =>
          '${entity.id.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.json';
      File(
        '${dir.path}/${fileName(kept)}',
      ).writeAsStringSync(jsonEncode(kept.toJson()));
      final removedFile = File('${dir.path}/${fileName(removed)}')
        ..writeAsStringSync(jsonEncode(removed.toJson()));

      await repository.saveEntities(
        'sketch-a',
        [kept],
        previousEntityIds: [kept.id, removed.id],
      );

      expect(removedFile.existsSync(), isFalse);
      expect(
        (await repository.loadEntities('sketch-a')).map((item) => item.id),
        [kept.id],
      );
    },
  );

  test(
    'orphan file absent from legacy root membership is not reabsorbed',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'sketch-legacy-orphan-',
      );
      addTearDown(() => project.delete(recursive: true));
      final repository = SketchRepository(project);
      final kept = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final orphan = SketchLine(
        const SketchVector(0, 1),
        const SketchVector(1, 1),
      );
      final sketch = Sketch(name: 'Legacy', id: 'sketch-a');
      sketch.entityIds.add(kept.id);
      await repository.saveSketch(sketch);
      final dir = Directory('${project.path}/CAD/SketchEntities/sketch-a')
        ..createSync(recursive: true);
      String fileName(SketchEntity entity) =>
          '${entity.id.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.json';
      File(
        '${dir.path}/${fileName(kept)}',
      ).writeAsStringSync(jsonEncode(kept.toJson()));
      File(
        '${dir.path}/${fileName(orphan)}',
      ).writeAsStringSync(jsonEncode(orphan.toJson()));

      final engine = const SketchEngineFactory().create(project);
      await engine.load();

      expect(engine.engine.entities.keys, contains(kept.id));
      expect(engine.engine.entities.keys, isNot(contains(orphan.id)));
      engine.openSketch(sketch.id);
      engine.deleteEntity(kept.id);
      expect(engine.engine.entities.keys, isNot(contains(kept.id)));
      expect(engine.engine.undo(), isTrue);
      expect(engine.engine.entities.keys, contains(kept.id));
      expect(engine.engine.redo(), isTrue);
      expect(engine.engine.entities.keys, isNot(contains(kept.id)));
      expect(engine.engine.undo(), isTrue);
      await const SketchPersistenceTransaction().run(project, engine.persist);

      final reopened = const SketchEngineFactory().create(project);
      await reopened.load();
      expect(reopened.engine.entities.keys, contains(kept.id));
      expect(reopened.engine.entities.keys, isNot(contains(orphan.id)));
    },
  );

  test(
    'true pre-membership legacy files load and migrate without loss',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'sketch-pre-membership-legacy-',
      );
      addTearDown(() => project.delete(recursive: true));
      final repository = SketchRepository(project);
      final entity = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
      );
      final sketch = Sketch(name: 'Ancestral', id: 'sketch-a');
      await repository.saveSketch(sketch);
      final dir = Directory('${project.path}/CAD/SketchEntities/sketch-a')
        ..createSync(recursive: true);
      final safeId = entity.id.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      File(
        '${dir.path}/$safeId.json',
      ).writeAsStringSync(jsonEncode(entity.toJson()));

      final engine = const SketchEngineFactory().create(project);
      await engine.load();
      expect(engine.engine.entities.keys, contains(entity.id));
      await const SketchPersistenceTransaction().run(project, engine.persist);

      expect(File('${dir.path}/entities.owner.json').existsSync(), isTrue);
      final reopened = const SketchEngineFactory().create(project);
      await reopened.load();
      expect(reopened.engine.entities.keys, contains(entity.id));
    },
  );

  test('ownership entries cannot escape the Sketch entity directory', () async {
    final project = await Directory.systemTemp.createTemp(
      'sketch-owner-confinement-',
    );
    addTearDown(() => project.delete(recursive: true));
    final repository = SketchRepository(project);
    final entity = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
    );
    final sketch = Sketch(name: 'Confinement', id: 'sketch-a');
    sketch.entityIds.add(entity.id);
    await repository.saveSketch(sketch);
    final dir = Directory('${project.path}/CAD/SketchEntities/sketch-a')
      ..createSync(recursive: true);
    final safeId = entity.id.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    File(
      '${dir.path}/$safeId.json',
    ).writeAsStringSync(jsonEncode(entity.toJson()));
    File('${dir.path}/entities.owner.json').writeAsStringSync(
      jsonEncode({
        'schema': 'flcad.sketch-entity-ownership',
        'version': 1,
        'files': ['$safeId.json', '../../../cad-document.json'],
      }),
    );
    final cadDocument = File('${project.path}/cad-document.json')
      ..writeAsStringSync('{"sentinel":true}');

    await repository.saveEntities(
      'sketch-a',
      [entity],
      previousEntityIds: [entity.id],
    );

    expect(cadDocument.existsSync(), isTrue);
    expect(cadDocument.readAsStringSync(), '{"sentinel":true}');
  });

  test(
    'special Sketch ids cannot resolve the entity directory to CAD',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'sketch-id-confinement-',
      );
      addTearDown(() => project.delete(recursive: true));
      final repository = SketchRepository(project);
      final cad = Directory('${project.path}/CAD')..createSync(recursive: true);
      final cadDocument = File('${cad.path}/cad-document.json')
        ..writeAsStringSync('{"sentinel":true}');
      File(
        '${cad.path}/cad-document-history.json',
      ).writeAsStringSync('{"sentinel":"history"}');
      final entity = SketchLine(
        const SketchVector(0, 0),
        const SketchVector(1, 0),
        id: 'cad-document',
      );

      await repository.saveEntities('..', [entity]);

      expect(cadDocument.readAsStringSync(), '{"sentinel":true}');
      expect(
        File(
          '${project.path}/CAD/SketchEntities/_/entities.bundle.json',
        ).existsSync(),
        isTrue,
      );
    },
  );

  test('legacy create delete Save/Open does not resurrect geometry', () async {
    final project = await Directory.systemTemp.createTemp(
      'sketch-legacy-engine-',
    );
    addTearDown(() => project.delete(recursive: true));
    final first = const SketchEngineFactory().create(project);
    final sketch = first.createSketch('Legacy');
    final kept = first.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
    );
    final removed = first.builders.line.build(
      const SketchVector(0, 1),
      const SketchVector(1, 1),
    );
    await const SketchPersistenceTransaction().run(project, first.persist);

    final safeSketchId = sketch.id.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final dir = Directory('${project.path}/CAD/SketchEntities/$safeSketchId');
    File('${dir.path}/entities.bundle.json').deleteSync();
    File('${dir.path}/entities.owner.json').deleteSync();
    String fileName(SketchEntity entity) =>
        '${entity.id.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.json';
    File(
      '${dir.path}/${fileName(kept)}',
    ).writeAsStringSync(jsonEncode(kept.toJson()));
    File(
      '${dir.path}/${fileName(removed)}',
    ).writeAsStringSync(jsonEncode(removed.toJson()));

    final second = const SketchEngineFactory().create(project);
    await second.load();
    second.openSketch(sketch.id);
    expect(second.engine.entities.keys, containsAll([kept.id, removed.id]));
    second.deleteEntity(removed.id);
    await const SketchPersistenceTransaction().run(project, second.persist);

    final reopened = const SketchEngineFactory().create(project);
    await reopened.load();
    expect(reopened.engine.entities.keys, contains(kept.id));
    expect(reopened.engine.entities.keys, isNot(contains(removed.id)));
  });
}
