import 'dart:async';
import 'dart:io';
import 'package:flcad_mobile/app/operational_entities/operational_entity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/feature_lifecycle/feature_lifecycle.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'cad_runtime_transaction_test.dart' show Repository, Gate, point;

class UnexpectedMeshingKernel extends UnavailableGeometryKernel
    implements InterchangeGeometryKernelAPI, MeshGeometryKernelAPI {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('Document-only operation called the kernel');
  }
}

void main() {
  late Repository repository;
  late CadRuntime runtime;
  late Directory root, a, b;
  Future<void> add(String id) {
    final entity = point(id);
    entity.data['authoringRoot'] = true;
    return runtime.mutate(command: id, upsert: [entity]);
  }

  Gate barrier() {
    final gate = Gate();
    addTearDown(() {
      if (!gate.release.isCompleted) gate.release.complete();
    });
    return gate;
  }

  FeatureLifecycleState state(String id) =>
      FeatureLifecycleContract.require(runtime.document!.entities[id]!).state;
  Future<void> closeFeature() => runtime.transitionFeature(
    'one',
    FeatureLifecycleState.closed,
    command: 'feature.close',
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cad-document-writers-');
    a = await Directory('${root.path}/A').create();
    b = await Directory('${root.path}/B').create();
    repository = Repository();
    runtime = CadRuntime(kernels: KernelManager(), repository: repository);
    await runtime.open('A', a);
    await add('one');
  });
  tearDown(() async {
    await runtime.shutdown();
    await root.delete(recursive: true);
  });

  test(
    'native-backed display and lifecycle changes never call meshing',
    () async {
      final source = point('shape');
      source.data['authoringRoot'] = true;
      final entity = CadDocumentEntity(
        id: source.id,
        kind: source.kind,
        data: source.data,
        shape: ShapeHandle.reference(
          persistentId: 'native',
          kernelId: 'fixture',
          type: CADShapeType.solid,
        ),
      );
      await runtime.mutate(command: 'fixture', upsert: [entity]);
      final kernel = UnexpectedMeshingKernel();
      runtime.kernels.register(kernel, makeDefault: true);
      final geometry = runtime.scene.find('shape')!.geometry;
      final before = FeatureLifecycleContract.require(
        runtime.document!.entities['shape']!,
      );
      await runtime.setEntityVisibility('shape', false);
      expect(
        FeatureLifecycleContract.require(
          runtime.document!.entities['shape']!,
        ).state,
        before.state,
      );
      await runtime.setEntityVisibility('shape', true);
      await runtime.updateCollection(
        'collection:modified',
        addMembers: ['shape'],
      );
      await runtime.updateCollection('collection:modified', visible: false);
      await runtime.updateCollection('collection:modified', visible: true);
      final previous = FeatureLifecycleContract.require(
        runtime.document!.entities['shape']!,
      ).revision;
      await runtime.transitionFeature(
        'shape',
        FeatureLifecycleState.closed,
        command: 'close',
      );
      expect(
        FeatureLifecycleContract.require(
          runtime.document!.entities['shape']!,
        ).revision,
        previous + 1,
      );
      expect(kernel.calls, 0);
      expect(runtime.scene.find('shape')!.geometry, same(geometry));
    },
  );

  test('restore batch validates every target and commits once', () async {
    await add('two');
    await runtime.moveToRecycleBin('one', includeDependencies: false);
    await runtime.moveToRecycleBin('two', includeDependencies: false);
    final before = runtime.document;
    final files = await repository.captureFiles(a);
    await expectLater(
      runtime.restoreFromRecycleBin('one', additionalIds: ['missing']),
      throwsStateError,
    );
    expect(runtime.document, same(before));
    repository.onHistory = () async => throw StateError('second write');
    await expectLater(
      runtime.restoreFromRecycleBin('one', additionalIds: ['two']),
      throwsStateError,
    );
    expect(runtime.document, same(before));
    expect(await repository.captureFiles(a), files);
    repository.onHistory = null;
    final revision = runtime.runtimeRevision;
    await runtime.restoreFromRecycleBin('one', additionalIds: ['two']);
    expect(runtime.runtimeRevision, revision + 1);
    expect(runtime.scene.find('one')!.visible, isTrue);
    expect(runtime.scene.find('two')!.visible, isTrue);
    await runtime.undoDocument();
    expect(runtime.scene.find('one'), isNull);
    expect(runtime.scene.find('two'), isNull);
  });

  test(
    'dispose from reconciliation listener preserves committed hide',
    () async {
      runtime.select({'one'});
      final revision = runtime.runtimeRevision;
      runtime.geometrySelection.addListener(runtime.dispose);
      await runtime.setEntityVisibility('one', false);
      await runtime.shutdown();
      expect(runtime.runtimeRevision, revision + 1);
      expect(runtime.document!.entities['one']!.data['sceneVisible'], isFalse);
      expect(runtime.selection, isEmpty);
    },
  );

  test(
    'operational selection is pruned by visible owner before notification',
    () async {
      runtime.operationalEntities.replaceOwner('one', [
        const OperationalEntity(
          id: 'pick-one',
          type: OperationalEntityType.topologicalVertex,
          ownerId: 'one',
          ownerDomain: 'scene',
          documentId: 'A',
          revision: 1,
          label: 'one',
          capabilities: {},
          properties: {},
        ),
      ]);
      runtime.operationalSelection.select('pick-one');
      var notifications = 0;
      runtime.operationalSelection.addListener(() {
        notifications++;
        expect(
          runtime.document!.entities['one']!.data['sceneVisible'],
          isFalse,
        );
        expect(runtime.operationalSelection.selectedIds, isEmpty);
      });
      await runtime.setEntityVisibility('one', false);
      expect(runtime.operationalSelection.selectedIds, isEmpty);
      expect(notifications, 1);
    },
  );

  test('lifecycle waits for mutate and commits one revision', () async {
    final gate = barrier();
    repository.onSave = (_) => gate.wait();
    final revision = runtime.runtimeRevision;
    final first = add('two');
    await gate.entered.future;
    final second = closeFeature();
    expect(state('one'), FeatureLifecycleState.created);
    gate.release.complete();
    await first;
    await second;
    expect(runtime.runtimeRevision, revision + 2);
    expect(state('one'), FeatureLifecycleState.closed);
    expect(runtime.document!.entities.containsKey('two'), isTrue);
  });

  test('undo queued behind lifecycle restores the previous state', () async {
    final gate = barrier();
    repository.onSave = (_) => gate.wait();
    final first = closeFeature();
    await gate.entered.future;
    final second = runtime.undoDocument();
    gate.release.complete();
    await first;
    await second;
    expect(state('one'), FeatureLifecycleState.created);
    expect(runtime.canRedo, isTrue);
  });

  test('visibility is FIFO and does not replace geometry', () async {
    final geometry = runtime.scene.find('one')!.geometry;
    final revision = runtime.runtimeRevision;
    final gate = barrier();
    repository.onSave = (_) => gate.wait();
    final first = runtime.setEntityVisibility('one', false);
    await gate.entered.future;
    final second = runtime.setEntityVisibility('one', true);
    expect(runtime.scene.find('one')!.visible, isTrue);
    gate.release.complete();
    await first;
    await second;
    expect(runtime.scene.find('one')!.visible, isTrue);
    expect(runtime.scene.find('one')!.geometry, same(geometry));
    expect(runtime.runtimeRevision, revision + 2);
  });

  test(
    'visibility history failure preserves scene files redo and latest selection',
    () async {
      await add('two');
      await add('three');
      await runtime.undoDocument();
      runtime.select({'one'});
      final before = runtime.document;
      final files = await repository.captureFiles(a);
      final gate = barrier();
      repository.onHistory = () async {
        await gate.wait();
        throw StateError('history');
      };
      final first = runtime.setEntityVisibility('one', false);
      final rejected = expectLater(first, throwsStateError);
      await gate.entered.future;
      runtime.select({'two'});
      gate.release.complete();
      await rejected;
      expect(runtime.document, same(before));
      expect(runtime.canRedo, isTrue);
      expect(runtime.scene.find('one')!.visible, isTrue);
      expect(runtime.selection, {'two'});
      expect(runtime.scene.find('two')!.selected, isTrue);
      expect(await repository.captureFiles(a), files);
    },
  );

  test('collection update then removal detaches members atomically', () async {
    await runtime.updateCollection('collection:modified', addMembers: ['one']);
    final gate = barrier();
    repository.onSave = (_) => gate.wait();
    final first = runtime.updateCollection(
      'collection:modified',
      name: 'Renamed',
    );
    await gate.entered.future;
    final second = runtime.removeEntity(
      'collection:modified',
      command: 'remove',
    );
    gate.release.complete();
    await first;
    await second;
    expect(
      runtime.document!.entities.containsKey('collection:modified'),
      isFalse,
    );
    expect(runtime.document!.entities['one']!.data['collectionId'], isNull);
    await runtime.undoDocument();
    expect(
      runtime.document!.entities['collection:modified']!.data['name'],
      'Renamed',
    );
    expect(
      runtime.document!.entities['one']!.data['collectionId'],
      'collection:modified',
    );
  });

  test(
    'invalid second collection member leaves no partial association',
    () async {
      final before = runtime.document;
      final files = await repository.captureFiles(a);
      await expectLater(
        runtime.updateCollection(
          'collection:modified',
          addMembers: ['one', 'missing'],
        ),
        throwsStateError,
      );
      expect(runtime.document, same(before));
      expect(await repository.captureFiles(a), files);
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

  test('member batch persistence failure restores all members', () async {
    await add('two');
    final before = runtime.document;
    final files = await repository.captureFiles(a);
    repository.onHistory = () async => throw StateError('after document write');
    await expectLater(
      runtime.updateCollection(
        'collection:modified',
        addMembers: ['one', 'two'],
      ),
      throwsStateError,
    );
    expect(runtime.document, same(before));
    expect(await repository.captureFiles(a), files);
  });

  test('queued entity A cannot be interpreted in B', () async {
    final gate = barrier();
    repository.onSave = (_) => gate.wait();
    final first = runtime.setEntityVisibility('one', false);
    final rejected = expectLater(first, throwsA(isA<StaleCadTransaction>()));
    await gate.entered.future;
    final old = runtime.updateCollection(
      'collection:modified',
      addMembers: ['one'],
    );
    final oldRejected = expectLater(old, throwsA(isA<StaleCadTransaction>()));
    final opened = runtime.open('B', b);
    gate.release.complete();
    await rejected;
    await oldRejected;
    await opened;
    expect(runtime.document!.projectId, 'B');
    expect(runtime.document!.entities.containsKey('one'), isFalse);
  });

  test(
    'dependency recycle batch is all or nothing on persistence failure',
    () async {
      final dependent = point('dependent');
      dependent.data['sourceEntityId'] = 'one';
      await runtime.mutate(command: 'dependent', upsert: [dependent]);
      final before = runtime.document;
      final files = await repository.captureFiles(a);
      repository.onHistory = () async => throw StateError('history');
      await expectLater(
        runtime.moveToRecycleBin('one', includeDependencies: true),
        throwsStateError,
      );
      expect(runtime.document, same(before));
      expect(runtime.scene.find('one'), isNotNull);
      expect(runtime.scene.find('dependent'), isNotNull);
      expect(await repository.captureFiles(a), files);
      repository.onHistory = null;
      final revision = runtime.runtimeRevision;
      await runtime.moveToRecycleBin('one', includeDependencies: true);
      expect(runtime.runtimeRevision, revision + 1);
      expect(runtime.document!.entities['one']!.data['deleted'], isTrue);
      expect(runtime.document!.entities['dependent']!.data['deleted'], isTrue);
    },
  );

  test('restore then undo then redo are FIFO and restore geometry', () async {
    await runtime.moveToRecycleBin('one', includeDependencies: false);
    final gate = barrier();
    repository.onSave = (_) => gate.wait();
    final first = runtime.restoreFromRecycleBin('one');
    await gate.entered.future;
    final second = runtime.undoDocument();
    final third = runtime.redoDocument();
    gate.release.complete();
    await first;
    await second;
    await third;
    expect(runtime.document!.entities['one']!.data['deleted'], isNull);
    expect(runtime.scene.find('one')!.visible, isTrue);
  });

  test('purge retains physical payload referenced by undo history', () async {
    final payload = File('${a.path}/retained.brep');
    await payload.writeAsString('owned by persisted history');
    final source = point('resource');
    source.data['payloadPath'] = payload.path;
    await runtime.mutate(command: 'resource', upsert: [source]);
    await runtime.moveToRecycleBin('resource', includeDependencies: false);
    await runtime.permanentlyDelete('resource');
    expect(await payload.exists(), isTrue);
    expect(runtime.document!.entities.containsKey('resource'), isFalse);
    await runtime.undoDocument();
    expect(
      runtime.document!.entities['resource']!.data['payloadPath'],
      payload.path,
    );
    expect(await payload.readAsString(), 'owned by persisted history');
  });

  test(
    'hide remove restore reconcile selection before notifications',
    () async {
      await add('two');
      runtime.select({'one', 'two'});
      var observations = 0;
      runtime.addListener(() {
        observations++;
        for (final visual in runtime.scene.entities) {
          expect(visual.selected, runtime.selection.contains(visual.id));
          if (visual.selected) expect(visual.visible, isTrue);
        }
      });
      await runtime.setEntityVisibility('one', false);
      expect(runtime.selection, {'two'});
      await runtime.moveToRecycleBin('two', includeDependencies: false);
      expect(runtime.selection, isEmpty);
      await runtime.restoreFromRecycleBin('two');
      expect(runtime.selection, isEmpty);
      expect(runtime.scene.find('two')!.selected, isFalse);
      expect(observations, 3);
    },
  );

  test(
    'collection hide is coherent with entity visibility and selection',
    () async {
      await runtime.updateCollection(
        'collection:modified',
        addMembers: ['one'],
      );
      runtime.select({'one'});
      final geometry = runtime.scene.find('one')!.geometry;
      await runtime.updateCollection('collection:modified', visible: false);
      expect(runtime.scene.find('one')!.visible, isFalse);
      expect(runtime.selection, isEmpty);
      await runtime.setEntityVisibility('one', true);
      expect(runtime.scene.find('one')!.visible, isFalse);
      await runtime.updateCollection('collection:modified', visible: true);
      expect(runtime.scene.find('one')!.visible, isTrue);
      expect(runtime.scene.find('one')!.geometry, same(geometry));
    },
  );

  test('listener reentrant documentary writer enters queue', () async {
    final completed = Completer<void>();
    var requested = false;
    runtime.addListener(() {
      if (requested) return;
      requested = true;
      runtime
          .setEntityVisibility('one', false)
          .then(completed.complete, onError: completed.completeError);
    });
    await closeFeature();
    await completed.future;
    expect(runtime.scene.find('one')!.visible, isFalse);
  });

  test(
    'failed transaction escaped capability is light and awaits real drainage',
    () async {
      final resume = Completer<void>();
      final requested = Completer<void>();
      late Future<void> escaped;
      late dynamic capability;
      repository.onSave = (_) async {
        escaped = resume.future.then((_) {
          final drained = runtime.shutdown();
          requested.complete();
          return drained;
        });
        throw StateError('first');
      };
      await runZoned(
        () async {
          await expectLater(closeFeature(), throwsStateError);
        },
        zoneSpecification: ZoneSpecification(
          fork: (self, parent, zone, spec, values) {
            for (final value in values?.values ?? const []) {
              if (value.runtimeType.toString() == '_CadCapability') {
                capability = value;
              }
            }
            return parent.fork(zone, spec, values);
          },
        ),
      );
      expect(capability.active, isFalse);
      expect(() => capability.active = true, throwsNoSuchMethodError);
      expect(capability.active, isFalse);
      expect(capability.runtimeIdentity.runtimeType, Object);
      expect(() => capability.owner, throwsNoSuchMethodError);
      expect(() => capability.document, throwsNoSuchMethodError);
      expect(() => capability.directory, throwsNoSuchMethodError);
      expect(() => capability.capability, throwsNoSuchMethodError);
      final gate = barrier();
      repository.onSave = (_) => gate.wait();
      final second = runtime.setEntityVisibility('one', false);
      final rejected = expectLater(second, throwsA(isA<StaleCadTransaction>()));
      await gate.entered.future;
      var drained = false;
      final completed = escaped.then((_) => drained = true);
      resume.complete();
      await requested.future;
      expect(drained, isFalse);
      runtime.scene.addListener(() {});
      gate.release.complete();
      await rejected;
      await completed;
      expect(drained, isTrue);
    },
  );

  test('failed visibility does not poison already queued lifecycle', () async {
    final gate = barrier();
    var count = 0;
    repository.onSave = (_) async {
      if (count++ == 0) {
        await gate.wait();
        throw StateError('first');
      }
    };
    final first = runtime.setEntityVisibility('one', false);
    final rejected = expectLater(first, throwsStateError);
    await gate.entered.future;
    final second = closeFeature();
    gate.release.complete();
    await rejected;
    await second;
    expect(state('one'), FeatureLifecycleState.closed);
    expect(runtime.scene.find('one')!.visible, isTrue);
  });

  for (final family in [
    'lifecycle',
    'visibility',
    'collection',
    'members',
    'remove',
    'purge',
    'recycle',
    'restore',
  ]) {
    test('$family no-op preserves revision redo scene and files', () async {
      if (family == 'recycle') {
        await runtime.moveToRecycleBin('one', includeDependencies: false);
      }
      await add('redo-entry');
      await runtime.undoDocument();
      final before = runtime.document;
      final revision = runtime.runtimeRevision;
      final scene = runtime.scene.entities.toList();
      final files = await repository.captureFiles(a);
      switch (family) {
        case 'lifecycle':
          await runtime.transitionFeature('one', state('one'), command: 'same');
        case 'visibility':
          await runtime.setEntityVisibility('one', true);
        case 'collection':
          await runtime.updateCollection(
            'collection:modified',
            name: 'Modified',
          );
        case 'members':
          await runtime.updateCollection(
            'collection:modified',
            removeMembers: ['one'],
          );
        case 'remove':
          await runtime.removeEntity('absent', command: 'absent');
        case 'purge':
          await runtime.permanentlyDelete('absent');
        case 'recycle':
          await runtime.moveToRecycleBin('one', includeDependencies: false);
        case 'restore':
          await runtime.restoreFromRecycleBin('one');
      }
      expect(runtime.document, same(before));
      expect(runtime.runtimeRevision, revision);
      expect(runtime.scene.entities.toList(), scene);
      expect(runtime.canRedo, isTrue);
      expect(await repository.captureFiles(a), files);
      await runtime.redoDocument();
      expect(runtime.document!.entities.containsKey('redo-entry'), isTrue);
    });
  }
}
