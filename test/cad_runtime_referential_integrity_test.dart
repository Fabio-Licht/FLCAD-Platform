import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/feature_lifecycle/feature_dependencies.dart';
import 'package:flcad_mobile/core/feature_lifecycle/feature_lifecycle.dart';
import 'package:flcad_mobile/core/feature_lifecycle/feature_lifecycle_projector.dart';
import 'package:flcad_mobile/core/cad_document/dependency_walk.dart';
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
  Future<void> legacy(
    List<CadDocumentEntity> entities, {
    String? official,
  }) async {
    final old = runtime.document!;
    await repository.save(
      CadDocument(
        projectId: old.projectId,
        entities: {...old.entities, for (final e in entities) e.id: e},
        revisions: old.revisions,
        parameters: old.parameters,
        officialExportShapeId: official ?? old.officialExportShapeId,
      ),
      directory,
    );
    await runtime.open('A', directory);
  }

  CadDocumentEntity recycled(CadDocumentEntity e) => CadDocumentEntity(
    id: e.id,
    kind: e.kind,
    shape: e.shape,
    mesh: e.mesh,
    data: {
      ...e.data,
      'deleted': true,
      'collectionId': 'collection:recycle-bin',
    },
  );
  CadDocumentEntity exportable(String id, {bool temporary = false}) =>
      CadDocumentEntity(
        id: id,
        kind: CadDocumentEntityKind.vertex,
        data: point(id).data,
        shape: ShapeHandle.reference(
          persistentId: id,
          kernelId: 'fixture',
          type: CADShapeType.solid,
          metadata: {'temporary': temporary},
        ),
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
      await legacy([
        recycled(feature('B', dependencies: ['A'])),
      ]);
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
      await runtime.moveToRecycleBin('A', includeDependencies: true);
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
    await legacy([
      feature('B', dependencies: ['A']),
      recycled(feature('C', dependencies: ['B'])),
    ]);
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
      await runtime.moveToRecycleBin('A', includeDependencies: true);
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
        expect(
          runtime.document!.entities['A']!.data.containsKey('collectionId'),
          isTrue,
        );
        expect(runtime.document!.entities['A']!.data['collectionId'], expected);
        await runtime.undoDocument();
        expect(runtime.document!.entities['A']!.data['deleted'], isTrue);
        await runtime.redoDocument();
        expect(
          runtime.document!.entities['A']!.data.containsKey('collectionId'),
          isTrue,
        );
        expect(runtime.document!.entities['A']!.data['collectionId'], expected);
        await runtime.save();
        await runtime.close();
        await runtime.open('A', directory);
        expect(
          runtime.document!.entities['A']!.data.containsKey('collectionId'),
          isTrue,
        );
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
    await legacy([
      recycled(feature('A', dependencies: ['B'])),
    ]);
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
      await runtime.mutate(command: 'add', upsert: [exportable('official')]);
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
  for (final invalid in ['missing', 'no-shape', 'deleted', 'temporary']) {
    test(
      'invalid official set $invalid rejects all state including redo',
      () async {
        await runtime.mutate(
          command: 'official',
          upsert: [exportable('official')],
          officialExport: const OfficialExportUpdate.set('official'),
        );
        await add('selected');
        runtime.select({'selected'});
        await add('redo');
        await runtime.undoDocument();
        final target = switch (invalid) {
          'missing' => <CadDocumentEntity>[],
          'no-shape' => [feature('invalid')],
          'deleted' => [recycled(exportable('invalid'))],
          _ => [exportable('invalid', temporary: true)],
        };
        await rejectUnchanged(
          () => runtime.mutate(
            command: 'invalid',
            upsert: target,
            remove: ['selected'],
            officialExport: const OfficialExportUpdate.set('invalid'),
          ),
        );
        expect(runtime.document!.officialExportShapeId, 'official');
        await runtime.redoDocument();
        expect(runtime.document!.entities.containsKey('redo'), isTrue);
      },
    );
  }

  test(
    'legacy invalid export keep is unconditional and set same ID rejects',
    () async {
      await legacy([
        feature('broken', dependencies: ['absent']),
      ], official: 'absent');
      final diagnostics = runtime.read<List<String>>(
        'document.integrityDiagnostics',
      )!;
      expect(diagnostics, contains('Invalid official export: absent'));
      expect(diagnostics, contains('Invalid dependency: broken -> absent'));
      await rejectUnchanged(
        () => runtime.mutate(
          command: 'set',
          officialExport: const OfficialExportUpdate.set('absent'),
        ),
      );
      await add('unrelated');
      await runtime.setEntityVisibility('broken', false);
      expect(runtime.document!.officialExportShapeId, 'absent');
      await runtime.undoDocument();
      await runtime.redoDocument();
      await runtime.save();
      await runtime.close();
      await runtime.open('A', directory);
      expect(runtime.document!.officialExportShapeId, 'absent');
      expect(runtime.document!.entities['broken']!.data['dependencies'], [
        'absent',
      ]);
    },
  );

  for (final operation in [
    'removeCollection',
    'removeMembership',
    'recycleCollection',
  ]) {
    test(
      '$operation persists intentional root through undo redo and open',
      () async {
        await runtime.mutate(
          command: 'collection',
          upsert: [
            const CadDocumentEntity(
              id: 'C',
              kind: CadDocumentEntityKind.collection,
              data: {},
            ),
            feature('member', collection: 'C'),
          ],
        );
        switch (operation) {
          case 'removeCollection':
            await runtime.removeEntity('C', command: 'remove');
          case 'removeMembership':
            await runtime.updateCollection('C', removeMembers: ['member']);
          case 'recycleCollection':
            await recycle('C');
        }
        void root() {
          final data = runtime.document!.entities['member']!.data;
          expect(data.containsKey('collectionId'), isTrue);
          expect(data['collectionId'], isNull);
        }

        root();
        await runtime.undoDocument();
        expect(runtime.document!.entities['member']!.data['collectionId'], 'C');
        await runtime.redoDocument();
        root();
        await runtime.save();
        await runtime.close();
        await runtime.open('A', directory);
        root();
      },
    );
  }

  test(
    'open migrates missing collection key but preserves explicit null',
    () async {
      final explicit = feature('root')..data['collectionId'] = null;
      await legacy([feature('missing-key'), explicit]);
      expect(
        runtime.document!.entities['missing-key']!.data['collectionId'],
        isNotNull,
      );
      expect(
        runtime.document!.entities['root']!.data.containsKey('collectionId'),
        isTrue,
      );
      expect(runtime.document!.entities['root']!.data['collectionId'], isNull);
    },
  );

  for (final reverse in [false, true]) {
    test(
      'active cycle accepts external restoration, reversed=$reverse',
      () async {
        final entities = [
          feature('A', dependencies: ['B']),
          feature('B', dependencies: ['A']),
          recycled(feature('X', dependencies: ['A'])),
        ];
        await legacy(reverse ? entities.reversed.toList() : entities);
        await runtime.restoreFromRecycleBin('X', additionalIds: ['X']);
        expect(runtime.document!.entities['X']!.data['deleted'], isNot(true));
      },
    );
    test(
      'complete cycle restoration is independent of batch order $reverse',
      () async {
        await legacy([
          recycled(feature('A', dependencies: ['B'])),
          recycled(feature('B', dependencies: ['A'])),
        ]);
        await runtime.restoreFromRecycleBin(
          reverse ? 'B' : 'A',
          additionalIds: reverse ? ['A', 'B'] : ['B', 'A'],
        );
        expect(runtime.scene.find('A'), isNotNull);
        expect(runtime.scene.find('B'), isNotNull);
      },
    );
    for (final purge in [false, true]) {
      test(
        'explicit full retirement batch undo redo purge=$purge reverse=$reverse',
        () async {
          await runtime.mutate(
            command: 'chain',
            upsert: [
              feature('A'),
              feature('B', dependencies: ['A']),
              feature('C', dependencies: ['B']),
            ],
          );
          final ids = reverse ? ['C', 'B', 'A'] : ['A', 'B', 'C'];
          final revision = runtime.runtimeRevision;
          if (purge) {
            await runtime.mutate(command: 'remove.batch', remove: ids);
          } else {
            await runtime.mutate(
              command: 'recycle.batch',
              upsert: ids.map(
                (id) => recycled(runtime.document!.entities[id]!),
              ),
            );
          }
          expect(runtime.runtimeRevision, revision + 1);
          for (final id in ids) {
            expect(
              purge
                  ? !runtime.document!.entities.containsKey(id)
                  : runtime.document!.entities[id]!.data['deleted'] == true,
              isTrue,
            );
          }
          await runtime.undoDocument();
          for (final id in ids) {
            expect(runtime.scene.find(id), isNotNull);
          }
          await runtime.redoDocument();
          for (final id in ids) {
            expect(runtime.scene.find(id), isNull);
          }
        },
      );
    }
  }

  test('cycle with missing reference cannot be restored', () async {
    await legacy([
      recycled(feature('A', dependencies: ['B'])),
      recycled(feature('B', dependencies: ['A', 'absent'])),
    ]);
    await rejectUnchanged(
      () => runtime.restoreFromRecycleBin('A', additionalIds: ['B']),
    );
  });

  test(
    'partial recycling chain rejects wrappers and generic batches preserving redo',
    () async {
      await runtime.mutate(
        command: 'chain',
        upsert: [
          feature('A'),
          feature('B', dependencies: ['A']),
          feature('C', dependencies: ['B']),
        ],
      );
      runtime.select({'C'});
      await add('redo');
      await runtime.undoDocument();
      await rejectUnchanged(() => recycle('A'));
      await rejectUnchanged(
        () => runtime.mutate(
          command: 'partial',
          upsert: [
            recycled(runtime.document!.entities['A']!),
            recycled(runtime.document!.entities['B']!),
          ],
        ),
      );
      await rejectUnchanged(() => runtime.removeEntity('A', command: 'remove'));
      await rejectUnchanged(
        () => runtime.mutate(command: 'remove', remove: ['A', 'B']),
      );
      await runtime.redoDocument();
      expect(runtime.document!.entities.containsKey('redo'), isTrue);
      await runtime.moveToRecycleBin('A', includeDependencies: true);
      for (final id in ['A', 'B', 'C']) {
        expect(runtime.document!.entities[id]!.data['deleted'], isTrue);
      }
    },
  );

  for (final dependentDeleted in [false, true]) {
    test(
      'purge protects preserved dependent deleted=$dependentDeleted',
      () async {
        final b = feature('B', dependencies: ['A']);
        await legacy([
          recycled(feature('A')),
          dependentDeleted ? recycled(b) : b,
        ]);
        await rejectUnchanged(() => runtime.permanentlyDelete('A'));
        await rejectUnchanged(
          () => runtime.mutate(command: 'purge', remove: ['A']),
        );
        await runtime.mutate(command: 'purge.batch', remove: ['B', 'A']);
        expect(runtime.document!.entities.containsKey('A'), isFalse);
        await runtime.undoDocument();
        expect(runtime.document!.entities.containsKey('A'), isTrue);
        await runtime.redoDocument();
        expect(runtime.document!.entities.containsKey('B'), isFalse);
      },
    );
  }

  test(
    'replacement removes dependency before retirement; unrelated legacy defect survives',
    () async {
      await legacy([
        feature('broken', dependencies: ['missing']),
      ]);
      await runtime.mutate(
        command: 'chain',
        upsert: [
          feature('A'),
          feature('B', dependencies: ['A']),
        ],
      );
      final b = runtime.document!.entities['B']!;
      await runtime.mutate(
        command: 'detach.and.remove',
        remove: ['A'],
        upsert: [
          CadDocumentEntity(
            id: b.id,
            kind: b.kind,
            data: {...b.data, 'dependencies': []},
          ),
        ],
      );
      expect(runtime.document!.entities.containsKey('A'), isFalse);
      expect(runtime.dependencyImpact('A'), isEmpty);
      await runtime.save();
      await runtime.open('A', directory);
      expect(runtime.dependencyImpact('A'), isEmpty);
      expect(
        runtime.read<List<String>>('document.integrityDiagnostics'),
        contains('Invalid dependency: broken -> missing'),
      );
      await rejectUnchanged(() => add('new', dependencies: ['broken']));
    },
  );
  for (final key in ['references', 'sourceIds']) {
    test('explicit empty $key removes dependency atomically', () async {
      final b = point('B')..data[key] = ['A'];
      await runtime.mutate(command: 'create', upsert: [feature('A'), b]);
      final previous = runtime.document!.entities['B']!;
      await runtime.mutate(
        command: 'detach',
        remove: ['A'],
        upsert: [
          CadDocumentEntity(
            id: 'B',
            kind: previous.kind,
            data: {...previous.data, key: []},
          ),
        ],
      );
      expect(runtime.dependencyImpact('A'), isEmpty);
      await runtime.save();
      await runtime.open('A', directory);
      expect(runtime.dependencyImpact('A'), isEmpty);
    });
  }

  test(
    'open preserves legacy lifecycle fallback and reports invalid collection',
    () async {
      await runtime.mutate(
        command: 'chain',
        upsert: [
          feature('A'),
          feature('B', dependencies: ['A']),
        ],
      );
      final previous = runtime.document!.entities['B']!;
      await legacy([
        CadDocumentEntity(
          id: 'B',
          kind: previous.kind,
          data: {...previous.data, 'collectionId': 'absent'}
            ..remove('dependencies'),
        ),
      ]);
      expect(runtime.dependencyImpact('A').map((e) => e.id), ['B']);
      expect(
        runtime.read<List<String>>('document.integrityDiagnostics'),
        contains('Invalid collection: B -> absent'),
      );
      await runtime.setEntityVisibility('B', false);
      expect(runtime.dependencyImpact('A').map((e) => e.id), ['B']);
      await runtime.close();
      expect(
        runtime.read<List<String>>('document.integrityDiagnostics'),
        isNull,
      );
    },
  );

  test(
    'active indirect dependent across recycled intermediary rejects recycling',
    () async {
      await legacy([
        feature('A'),
        recycled(feature('B', dependencies: ['A'])),
        feature('C', dependencies: ['B']),
      ]);
      await rejectUnchanged(() => recycle('A'));
    },
  );
  void consistentDependencies(List<String> expected, {required bool explicit}) {
    final document = runtime.document!;
    final entity = document.entities['X']!;
    expect(entity.data.containsKey('dependencies'), explicit);
    expect(FeatureDependencies.resolve(entity.data), expected);
    final roundTrip = CadDocument.fromJson(document.toJson());
    expect(roundTrip.entities['X']!.data.containsKey('dependencies'), explicit);
    expect(
      FeatureDependencies.resolve(roundTrip.entities['X']!.data),
      expected,
    );
    final projected = FeatureLifecycleProjector.normalize(
      roundTrip,
      command: 'check',
    );
    expect(
      FeatureDependencies.resolve(projected.entities['X']!.data),
      expected,
    );
    if (FeatureLifecycleContract.appliesTo(entity)) {
      expect(FeatureLifecycleContract.require(entity).dependencyIds, expected);
      expect(
        FeatureLifecycleContract.require(
          projected.entities['X']!,
        ).dependencyIds,
        expected,
      );
    }
    final walk = DependencyWalk([
      'X',
      'X',
    ], (id) => FeatureDependencies.resolve(document.entities[id]!.data));
    expect(walk.components.expand((c) => c).toSet(), {'X', ...expected});
    for (final source in ['A', 'B']) {
      expect(
        runtime.dependencyImpact(source).any((e) => e.id == 'X'),
        expected.contains(source),
      );
    }
  }

  for (final authored in [false, true]) {
    for (final reverse in [false, true]) {
      for (final policy in ['empty', 'values', 'absent']) {
        test(
          'persisted dependencies $policy authored=$authored reversed=$reverse',
          () async {
            final fields = <String, dynamic>{
              if (policy != 'absent')
                'dependencies': policy == 'empty' ? <String>[] : ['A'],
              'references': policy == 'values' ? ['B'] : ['A'],
              'authoringRoot': authored,
            };
            final x = point('X')
              ..data.addAll(
                Map.fromEntries(
                  reverse ? fields.entries.toList().reversed : fields.entries,
                ),
              );
            await runtime.mutate(
              command: 'create',
              upsert: [feature('A'), feature('B'), x],
            );
            final expected = policy == 'empty' ? <String>[] : ['A'];
            consistentDependencies(expected, explicit: policy != 'absent');
            await runtime.save();
            final disk = await repository.load('A', directory);
            expect(
              FeatureDependencies.resolve(disk.entities['X']!.data),
              expected,
            );
            await runtime.close();
            await runtime.open('A', directory);
            consistentDependencies(expected, explicit: policy != 'absent');
            expect(
              runtime.document!.entities['X']!.data['references'],
              fields['references'],
            );
            if (policy == 'empty') {
              await runtime.removeEntity('A', command: 'remove');
            } else {
              await rejectUnchanged(
                () => runtime.removeEntity('A', command: 'remove'),
              );
            }
            // B is a reference, never an implicit addition to explicit dependencies.
            await runtime.removeEntity('B', command: 'remove');
            await add('unrelated');
          },
        );
      }
    }
  }

  test(
    'review regression references A to B and remove B stays empty after open',
    () async {
      final x = feature('X')..data['references'] = ['A'];
      await runtime.mutate(
        command: 'create',
        upsert: [feature('A'), feature('B'), x],
      );
      final before = runtime.document!.entities['X']!;
      await runtime.mutate(
        command: 'references-and-remove',
        remove: ['B'],
        upsert: [
          CadDocumentEntity(
            id: 'X',
            kind: before.kind,
            data: {
              ...before.data,
              'references': ['B'],
            },
          ),
        ],
      );
      consistentDependencies([], explicit: true);
      await runtime.undoDocument();
      consistentDependencies([], explicit: true);
      expect(runtime.document!.entities['X']!.data['references'], ['A']);
      expect(runtime.document!.entities.containsKey('B'), isTrue);
      await runtime.redoDocument();
      consistentDependencies([], explicit: true);
      await runtime.save(recordLifecycle: true);
      await runtime.close();
      await runtime.open('A', directory);
      consistentDependencies([], explicit: true);
      expect(runtime.document!.entities['X']!.data['references'], ['B']);
      expect(runtime.document!.entities.containsKey('B'), isFalse);
      expect(
        runtime.read<List<String>>('document.integrityDiagnostics'),
        isEmpty,
      );
    },
  );

  test(
    'undo redo preserves absent versus explicit empty dependencies',
    () async {
      final x = point('X')
        ..data.addAll({
          'authoringRoot': true,
          'references': ['A'],
        });
      await runtime.mutate(command: 'legacy', upsert: [feature('A'), x]);
      consistentDependencies(['A'], explicit: false);
      final old = runtime.document!.entities['X']!;
      await runtime.mutate(
        command: 'explicit-empty',
        upsert: [
          CadDocumentEntity(
            id: 'X',
            kind: old.kind,
            data: {...old.data, 'dependencies': []},
          ),
        ],
      );
      consistentDependencies([], explicit: true);
      await runtime.undoDocument();
      consistentDependencies(['A'], explicit: false);
      await rejectUnchanged(() => runtime.removeEntity('A', command: 'remove'));
      await runtime.redoDocument();
      consistentDependencies([], explicit: true);
      await runtime.save();
      await runtime.close();
      await runtime.open('A', directory);
      consistentDependencies([], explicit: true);
      await runtime.undoDocument();
      consistentDependencies(['A'], explicit: false);
      await runtime.redoDocument();
      consistentDependencies([], explicit: true);
    },
  );
}
