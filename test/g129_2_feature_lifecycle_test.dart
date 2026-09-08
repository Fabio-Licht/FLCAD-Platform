import 'dart:io';

import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/feature_lifecycle/feature_lifecycle.dart';
import 'package:flcad_mobile/core/feature_lifecycle/feature_lifecycle_projector.dart';
import 'package:flcad_mobile/core/feature_lifecycle/feature_update_solver.dart';
import 'package:flcad_mobile/core/parametric_solver/parametric_solver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CadDocumentEntity sketch({Map<String, dynamic> extra = const {}}) =>
      CadDocumentEntity(
        id: 'Sketch001',
        kind: CadDocumentEntityKind.sketch,
        data: {
          'name': 'Sketch001',
          'authoringRoot': true,
          'authoringWorkspace': 'Sketch',
          'collectionId': 'collection:sketches',
          'parameters': {'plane': 'XY'},
          'geometricEntities': ['Line001'],
          'constraints': ['Constraint001'],
          'dimensions': ['Dimension001'],
          'references': ['world:xy-plane'],
          'sketch': {
            'id': 'Sketch001',
            'metadata': {'supportEntityId': 'world:xy-plane'},
          },
          ...extra,
        },
      );

  test(
    'all authored entities share one durable lifecycle and dependency graph',
    () {
      final document = CadDocument.empty('project').mutate(
        command: 'feature.create',
        upsert: [
          sketch(),
          const CadDocumentEntity(
            id: 'Surface001',
            kind: CadDocumentEntityKind.surface,
            data: {
              'name': 'Surface001',
              'authoringRoot': true,
              'authoringWorkspace': 'Surfaces',
              'parameters': {'continuity': 'G1'},
              'references': ['Sketch001'],
              'dependencies': ['Sketch001'],
            },
          ),
          const CadDocumentEntity(
            id: 'Fillet001',
            kind: CadDocumentEntityKind.sketch,
            data: {
              'name': 'Fillet001',
              'authoringRoot': true,
              'authoringWorkspace': 'Sketch',
              'parentSketchId': 'Sketch001',
              'sketchEntity': {
                'parameters': {'radius': 2.5},
                'metadata': {
                  'sourceEntityIds': ['Line001', 'Line002'],
                },
              },
            },
          ),
        ],
      );
      final normalized = FeatureLifecycleProjector.normalize(
        document,
        command: 'feature.create',
        touchedIds: {'Sketch001', 'Surface001', 'Fillet001'},
      );
      final sketchLife = FeatureLifecycleContract.require(
        normalized.entities['Sketch001']!,
      );
      final surfaceLife = FeatureLifecycleContract.require(
        normalized.entities['Surface001']!,
      );
      final filletLife = FeatureLifecycleContract.require(
        normalized.entities['Fillet001']!,
      );

      expect(sketchLife.featureId, 'Sketch001');
      expect(sketchLife.parameters, {'plane': 'XY'});
      expect(
        sketchLife.childIds,
        containsAll(['Line001', 'Constraint001', 'Dimension001']),
      );
      expect(sketchLife.references, contains('world:xy-plane'));
      expect(sketchLife.dependentIds, ['Surface001']);
      expect(surfaceLife.dependencyIds, ['Sketch001']);
      expect(surfaceLife.createdBy, 'feature.create');
      expect(filletLife.parameters['radius'], 2.5);
      expect(filletLife.references, ['Line001', 'Line002']);
      expect(filletLife.treeParentId, 'Sketch001');
      expect(
        normalized.entities.keys.where((id) => id == 'Surface001'),
        hasLength(1),
      );
    },
  );

  test('replacement projection preserves identity and appends history', () {
    final first = FeatureLifecycleProjector.normalize(
      CadDocument.empty(
        'project',
      ).mutate(command: 'feature.create', upsert: [sketch()]),
      command: 'feature.create',
      touchedIds: {'Sketch001'},
    );
    final replacement = sketch(
      extra: {
        'parameters': {'plane': 'XY', 'scale': 2},
      },
    );
    final rawUpdate = first.mutate(
      command: 'feature.edit',
      upsert: [replacement],
    );
    final updated = FeatureLifecycleProjector.normalize(
      rawUpdate,
      previousDocument: first,
      command: 'feature.edit',
      touchedIds: {'Sketch001'},
    );
    final lifecycle = FeatureLifecycleContract.require(
      updated.entities['Sketch001']!,
    );

    expect(lifecycle.featureId, 'Sketch001');
    expect(lifecycle.createdBy, 'feature.create');
    expect(lifecycle.parameters['scale'], 2);
    expect(lifecycle.revision, 2);
    expect(lifecycle.history.map((event) => event.action), [
      'created',
      'updated',
    ]);
  });

  test('runtime closes, saves, reopens and edits the same Feature', () async {
    final directory = await Directory.systemTemp.createTemp('flcad_g129_2_');
    addTearDown(() async => directory.delete(recursive: true));
    final runtime = CadRuntime(kernels: KernelManager());
    await runtime.open('project', directory);
    await runtime.mutate(
      command: 'feature.create',
      upsert: [
        const CadDocumentEntity(
          id: 'collection:sketches',
          kind: CadDocumentEntityKind.collection,
          data: {'name': 'Sketches'},
        ),
        sketch(
          extra: {
            'references': ['project:world:xy-plane'],
            'sketch': {
              'id': 'Sketch001',
              'metadata': {'supportEntityId': 'project:world:xy-plane'},
            },
          },
        ),
      ],
    );
    await runtime.transitionFeature(
      'Sketch001',
      FeatureLifecycleState.closed,
      command: 'feature.close',
    );
    await runtime.save(recordLifecycle: true);
    await runtime.close();

    final reopened = CadRuntime(kernels: KernelManager());
    await reopened.open('project', directory);
    var lifecycle = FeatureLifecycleContract.require(
      reopened.document!.entities['Sketch001']!,
    );
    expect(lifecycle.featureId, 'Sketch001');
    expect(lifecycle.state, FeatureLifecycleState.closed);
    expect(
      lifecycle.history.map((event) => event.action),
      containsAllInOrder(['created', 'closed', 'saved']),
    );

    await reopened.transitionFeature(
      'Sketch001',
      FeatureLifecycleState.editing,
      command: 'feature.reenter',
    );
    lifecycle = FeatureLifecycleContract.require(
      reopened.document!.entities['Sketch001']!,
    );
    expect(lifecycle.state, FeatureLifecycleState.editing);
    expect(
      reopened.document!.entities.keys.where((id) => id == 'Sketch001'),
      hasLength(1),
    );
    await reopened.undoDocument();
    expect(
      FeatureLifecycleContract.require(
        reopened.document!.entities['Sketch001']!,
      ).state,
      FeatureLifecycleState.closed,
    );
    await reopened.redoDocument();
    expect(
      FeatureLifecycleContract.require(
        reopened.document!.entities['Sketch001']!,
      ).state,
      FeatureLifecycleState.editing,
    );
  });

  test('feature update gateway always resolves the abstract Solver first', () {
    var applied = false;
    final result = const FeatureUpdateSolver().update(
      request: const ParametricSolveRequest(
        first: 'definition',
        second: 'parameter',
        degreesOfFreedom: [
          ParametricDegreeOfFreedom('definition'),
          ParametricDegreeOfFreedom('parameter', parameterIds: {'value'}),
        ],
        parameters: [ParametricParameter('value', 12)],
        anchors: {'definition'},
      ),
      apply: (plan) {
        applied = true;
        expect(plan.anchor, 'definition');
        return 12;
      },
    );
    expect(result, 12);
    expect(applied, isTrue);

    applied = false;
    expect(
      () => const FeatureUpdateSolver().update(
        request: const ParametricSolveRequest(
          first: 'a',
          second: 'b',
          degreesOfFreedom: [
            ParametricDegreeOfFreedom('a'),
            ParametricDegreeOfFreedom('b'),
          ],
          anchors: {'a', 'b'},
        ),
        apply: (_) {
          applied = true;
          return 0;
        },
      ),
      throwsA(isA<ParametricSolveConflict>()),
    );
    expect(applied, isFalse);
  });
}
