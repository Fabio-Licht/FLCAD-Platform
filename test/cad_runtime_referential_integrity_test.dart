import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'cad_runtime_transaction_test.dart' show Repository, Gate, point;

void main() {
  late CadRuntime runtime;
  late Repository repository;
  late Directory directory;
  CadDocumentEntity feature(
    String id, {
    List<String> dependencies = const [],
    String? collection,
  }) {
    final entity = point(id);
    entity.data.addAll({
      'authoringRoot': true,
      'dependencies': dependencies,
      'collectionId': ?collection,
    });
    return entity;
  }

  Future<void> add(
    String id, {
    List<String> dependencies = const [],
    String? collection,
  }) => runtime.mutate(
    command: 'add',
    upsert: [feature(id, dependencies: dependencies, collection: collection)],
  );
  Future<void> recycle(String id) =>
      runtime.moveToRecycleBin(id, includeDependencies: false);
  Future<void> rejectUnchanged(Future<void> Function() operation) async {
    final before = runtime.document;
    final revision = runtime.runtimeRevision;
    final undo = runtime.canUndo, redo = runtime.canRedo;
    final scene = runtime.scene.entities.toList();
    final selected = runtime.selection;
    final files = await repository.captureFiles(directory);
    var notifications = 0;
    void changed() => notifications++;
    runtime.addListener(changed);
    runtime.scene.addListener(changed);
    try {
      await expectLater(operation(), throwsStateError);
      expect(runtime.document, same(before));
      expect(runtime.runtimeRevision, revision);
      expect(runtime.canUndo, undo);
      expect(runtime.canRedo, redo);
      expect(runtime.scene.entities.toList(), scene);
      expect(runtime.selection, selected);
      expect(await repository.captureFiles(directory), files);
      expect(notifications, 0);
    } finally {
      runtime.removeListener(changed);
      runtime.scene.removeListener(changed);
    }
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cad-referential-');
    repository = Repository();
    runtime = CadRuntime(kernels: KernelManager(), repository: repository);
    await runtime.open('A', directory);
  });
  tearDown(() async {
    await runtime.shutdown();
    await directory.delete(recursive: true);
  });

  test(
    'purged direct dependency rejects whole restore without notifications',
    () async {
      await add('A');
      await add('B', dependencies: ['A']);
      await recycle('A');
      await recycle('B');
      await runtime.permanentlyDelete('A');
      await add('selected');
      runtime.select({'selected'});
      await add('redo');
      await runtime.undoDocument();
      await rejectUnchanged(() => runtime.restoreFromRecycleBin('B'));
    },
  );

  test(
    'deleted dependency rejects single restore but whole batch succeeds and undoes',
    () async {
      await add('A');
      await add('B', dependencies: ['A']);
      await recycle('A');
      await recycle('B');
      await rejectUnchanged(() => runtime.restoreFromRecycleBin('B'));
      final revision = runtime.runtimeRevision;
      await runtime.restoreFromRecycleBin('B', additionalIds: ['A']);
      expect(runtime.runtimeRevision, revision + 1);
      expect(runtime.scene.find('A'), isNotNull);
      expect(runtime.scene.find('B'), isNotNull);
      await runtime.undoDocument();
      expect(runtime.scene.find('A'), isNull);
      expect(runtime.scene.find('B'), isNull);
      await runtime.redoDocument();
      expect(runtime.scene.find('A'), isNotNull);
      expect(runtime.scene.find('B'), isNotNull);
    },
  );

  test('missing indirect dependency rejects restoration', () async {
    await add('A');
    await add('B', dependencies: ['A']);
    await add('C', dependencies: ['B']);
    await recycle('C');
    await runtime.removeEntity('A', command: 'remove');
    await rejectUnchanged(() => runtime.restoreFromRecycleBin('C'));
  });

  test(
    'complete documentary cycle restores together, partial cycle rejects',
    () async {
      await runtime.mutate(
        command: 'cycle',
        upsert: [
          feature('A', dependencies: ['B']),
          feature('B', dependencies: ['A']),
        ],
      );
      await recycle('A');
      await recycle('B');
      await rejectUnchanged(() => runtime.restoreFromRecycleBin('A'));
      await runtime.restoreFromRecycleBin('A', additionalIds: ['B']);
      expect(runtime.scene.find('A'), isNotNull);
      expect(runtime.scene.find('B'), isNotNull);
    },
  );

  for (final status in ['active', 'removed', 'recycled']) {
    test(
      'original collection $status restores association or explicit root through undo redo open',
      () async {
        await runtime.mutate(
          command: 'collection',
          upsert: [
            const CadDocumentEntity(
              id: 'C',
              kind: CadDocumentEntityKind.collection,
              data: {'name': 'C'},
            ),
          ],
        );
        await add('A', collection: 'C');
        await recycle('A');
        if (status == 'removed') {
          await runtime.removeEntity('C', command: 'remove');
        }
        if (status == 'recycled') await recycle('C');
        await runtime.restoreFromRecycleBin('A');
        final expected = status == 'active' ? 'C' : null;
        expect(runtime.document!.entities['A']!.data['collectionId'], expected);
        await runtime.undoDocument();
        expect(runtime.document!.entities['A']!.data['deleted'], isTrue);
        await runtime.redoDocument();
        expect(runtime.document!.entities['A']!.data['collectionId'], expected);
        await runtime.save();
        await runtime.close();
        await runtime.open('A', directory);
        expect(runtime.document!.entities['A']!.data['collectionId'], expected);
      },
    );
  }

  test('active dependency cycle cannot be partially revived', () async {
    await runtime.mutate(
      command: 'cycle',
      upsert: [
        feature('A', dependencies: ['B']),
        feature('B', dependencies: ['A']),
      ],
    );
    await recycle('A');
    await rejectUnchanged(() => runtime.restoreFromRecycleBin('A'));
  });

  for (final operation in ['recycle', 'removeBatch', 'clear', 'purge']) {
    test(
      'official export $operation clears atomically and undo redo persist the ID',
      () async {
        final shape = ShapeHandle.reference(
          persistentId: 'shape',
          kernelId: 'fixture',
          type: CADShapeType.solid,
        );
        final source = point('official');
        source.data['collectionId'] = 'collection:modified';
        await runtime.mutate(
          command: 'official',
          upsert: [
            CadDocumentEntity(
              id: source.id,
              kind: source.kind,
              data: source.data,
              shape: shape,
            ),
          ],
          officialExport: const OfficialExportUpdate.set('official'),
        );
        await add('other');
        if (operation == 'purge') {
          // Finish legacy collection defaults while the official entity is active.
          await runtime.open('A', directory);
          // Load a legacy recycled entity with an unreconciled official ID.
          final old = runtime.document!;
          final data = {...old.entities['official']!.data, 'deleted': true};
          final legacy = CadDocument(
            projectId: old.projectId,
            entities: {
              ...old.entities,
              'official': CadDocumentEntity(
                id: source.id,
                kind: source.kind,
                data: data,
                shape: shape,
              ),
            },
            revisions: old.revisions,
            parameters: old.parameters,
            officialExportShapeId: 'official',
          );
          await repository.save(legacy, directory);
          await runtime.open('A', directory);
        }
        final before = runtime.document!.officialExportShapeId;
        expect(before, 'official');
        switch (operation) {
          case 'recycle':
            await recycle('official');
          case 'removeBatch':
            await runtime.mutate(
              command: 'remove',
              remove: ['official', 'other'],
            );
          case 'clear':
            await runtime.mutate(
              command: 'clear',
              officialExport: const OfficialExportUpdate.clear(),
            );
          case 'purge':
            await runtime.permanentlyDelete('official');
        }
        expect(runtime.document!.officialExportShapeId, isNull);
        expect(runtime.document!.officialExportShape, isNull);
        await runtime.undoDocument();
        expect(runtime.document!.officialExportShapeId, before);
        await runtime.redoDocument();
        expect(runtime.document!.officialExportShapeId, isNull);
        await runtime.save();
        await runtime.close();
        await runtime.open('A', directory);
        expect(runtime.document!.officialExportShapeId, isNull);
        expect(
          (await repository.load('A', directory)).officialExportShapeId,
          isNull,
        );
      },
    );
  }

  test(
    'nonofficial removal keeps export and cleared no-op preserves redo',
    () async {
      await add('official');
      await runtime.mutate(command: 'set', officialExportShapeId: 'official');
      await add('other');
      await runtime.removeEntity('other', command: 'remove');
      expect(runtime.document!.officialExportShapeId, 'official');
      await runtime.mutate(
        command: 'clear',
        officialExport: const OfficialExportUpdate.clear(),
      );
      await add('redo');
      await runtime.undoDocument();
      final before = runtime.document;
      final files = await repository.captureFiles(directory);
      final revision = runtime.runtimeRevision;
      await runtime.mutate(
        command: 'clear',
        officialExport: const OfficialExportUpdate.clear(),
      );
      expect(runtime.document, same(before));
      expect(runtime.runtimeRevision, revision);
      expect(runtime.canRedo, isTrue);
      expect(await repository.captureFiles(directory), files);
    },
  );

  test('official getter is safe for deleted and missing targets', () {
    final shape = ShapeHandle.reference(
      persistentId: 'shape',
      kernelId: 'fixture',
      type: CADShapeType.solid,
    );
    final deleted = CadDocument(
      projectId: 'A',
      entities: {
        'official': CadDocumentEntity(
          id: 'official',
          kind: CadDocumentEntityKind.solid,
          data: const {'deleted': true},
          shape: shape,
        ),
      },
      revisions: const [],
      parameters: const {},
      officialExportShapeId: 'official',
    );
    expect(deleted.officialExportShape, isNull);
    final missing = CadDocument(
      projectId: 'A',
      entities: const {},
      revisions: const [],
      parameters: const {},
      officialExportShapeId: 'absent',
    );
    expect(missing.officialExportShape, isNull);
  });

  test(
    'recycled collection rejects association from wrapper and generic mutate',
    () async {
      await add('one');
      await recycle('collection:modified');
      await rejectUnchanged(
        () => runtime.updateCollection(
          'collection:modified',
          addMembers: ['one'],
        ),
      );
      await rejectUnchanged(
        () => runtime.mutate(
          command: 'associate',
          upsert: [feature('one', collection: 'collection:modified')],
        ),
      );
      await runtime.restoreFromRecycleBin('collection:modified');
      await runtime.updateCollection(
        'collection:modified',
        addMembers: ['one'],
      );
      expect(
        runtime.document!.entities['one']!.data['collectionId'],
        'collection:modified',
      );
    },
  );

  test(
    'retiring collection detaches active members and undo restores',
    () async {
      await add('one', collection: 'collection:modified');
      final revision = runtime.runtimeRevision;
      await recycle('collection:modified');
      expect(runtime.runtimeRevision, revision + 1);
      expect(runtime.document!.entities['one']!.data['collectionId'], isNull);
      expect(runtime.document!.entities['one']!.data['deleted'], isNot(true));
      await runtime.undoDocument();
      expect(
        runtime.document!.entities['one']!.data['collectionId'],
        'collection:modified',
      );
      await runtime.redoDocument();
      expect(runtime.document!.entities['one']!.data['collectionId'], isNull);
    },
  );

  test(
    'removing membership from recycled collection remains allowed',
    () async {
      await add('one', collection: 'collection:modified');
      await recycle('collection:modified');
      await runtime.updateCollection(
        'collection:modified',
        removeMembers: ['one'],
      );
      expect(runtime.document!.entities['one']!.data['collectionId'], isNull);
      expect(runtime.document!.entities['one']!.data['deleted'], isNot(true));
    },
  );

  test('association queued behind recycling validates at execution', () async {
    await add('one');
    final gate = Gate();
    addTearDown(() {
      if (!gate.release.isCompleted) gate.release.complete();
    });
    repository.onSave = (_) => gate.wait();
    final first = recycle('collection:modified');
    await gate.entered.future;
    final second = runtime.updateCollection(
      'collection:modified',
      addMembers: ['one'],
    );
    final rejected = expectLater(second, throwsStateError);
    gate.release.complete();
    await first;
    final committed = runtime.document;
    await rejected;
    expect(runtime.document, same(committed));
    expect(runtime.document!.entities['one']!.data['collectionId'], isNull);
  });
}
