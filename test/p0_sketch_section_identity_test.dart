import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/import_export/api/import_export_api.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/reference_engine/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_engine/engine/reference_engine.dart';
import 'package:flcad_mobile/core/reference_engine/repository/reference_repository.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flcad_mobile/features/projects/models/project.dart';
import 'package:flcad_mobile/features/projects/models/project_status.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'File Save without engine persist still enters and edits the Sketch',
    () async {
      final harness = await _p0Harness('p0-save-open-enter', openSketch: true);
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final sketch = harness.controller.activeSketch!;
      expect(sketch.id, startsWith('sketch:'));
      final line = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(8, 0),
      );
      await harness.controller.reopenSketchForEditing(sketch.id);
      expect(harness.controller.stage, SketchSurfaceStage.sketchActive);
      expect(
        harness.cad.runtime.document!.entities[sketch.id]?.kind,
        CadDocumentEntityKind.sketch,
      );

      // Arquivo → Salvar Projeto now flushes SketchEngine then the CAD document.
      await harness.controller.saveProject();

      final reopened = await _reopen(harness, 'p0-save-open-enter');
      addTearDown(reopened.controller.dispose);
      addTearDown(reopened.cad.dispose);

      final documentRoot = reopened.cad.runtime.document!.entities[sketch.id];
      expect(documentRoot?.kind, CadDocumentEntityKind.sketch);
      expect(documentRoot?.data['sketch'], isA<Map>());
      expect((documentRoot!.data['sketch'] as Map)['id'], sketch.id);
      expect(
        reopened.controller.sketchApi!.sketches.map((item) => item.id),
        contains(sketch.id),
      );
      await reopened.controller.reopenSketchForEditing(sketch.id);
      expect(reopened.controller.stage, SketchSurfaceStage.sketchActive);
      expect(reopened.controller.activeSketch!.id, sketch.id);
      expect(reopened.controller.sketchApi!.engine.activeSketchId, sketch.id);
      final restored = reopened.controller.sketchApi!.entity(line.id);
      expect(restored, isA<SketchLine>());
      await reopened.controller.updateSketchEntityParameters(line.id, {
        'length': 12,
      });
      final edited =
          reopened.controller.sketchApi!.entity(line.id)! as SketchLine;
      expect(edited.parameters['length'], closeTo(12, 1e-9));
    },
  );

  test(
    'document Sketch roots rehydrate after engine files are missing',
    () async {
      final harness = await _p0Harness(
        'p0-missing-engine-files',
        openSketch: true,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final sketch = harness.controller.activeSketch!;
      final line = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(1, 0),
        const SketchVector(4, 0),
      );
      await harness.controller.reopenSketchForEditing(sketch.id);
      await harness.controller.saveProject();
      for (final relative in const [
        'Sketch',
        'SketchEntities',
        'SketchHistory',
      ]) {
        final dir = Directory(
          '${harness.directory.path}${Platform.pathSeparator}CAD'
          '${Platform.pathSeparator}$relative',
        );
        if (await dir.exists()) await dir.delete(recursive: true);
      }

      final reopened = await _reopen(harness, 'p0-missing-engine-files');
      addTearDown(reopened.controller.dispose);
      addTearDown(reopened.cad.dispose);
      expect(
        reopened.cad.runtime.document!.entities[sketch.id]?.kind,
        CadDocumentEntityKind.sketch,
      );
      await reopened.controller.reopenSketchForEditing(sketch.id);
      expect(reopened.controller.activeSketch!.id, sketch.id);
      expect(reopened.controller.stage, SketchSurfaceStage.sketchActive);
      expect(reopened.controller.sketchApi!.entity(line.id), isA<SketchLine>());
    },
  );

  test(
    'two independent Sketches survive Save/Open and each can enter+edit',
    () async {
      final harness = await _p0Harness('p0-two-sketches', openSketch: true);
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final first = harness.controller.activeSketch!;
      final firstLine = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(3, 0),
      );
      harness.controller.selectWorldSketchPlane(SketchPlaneType.yz);
      await harness.controller.openSketch(forceNew: true);
      final second = harness.controller.activeSketch!;
      expect(second.id, isNot(first.id));
      expect(second.id, startsWith('sketch:'));
      final secondLine = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(0, 4),
      );
      await harness.controller.reopenSketchForEditing(second.id);
      expect({first.id, second.id}, hasLength(2));
      expect(
        harness.controller.sketchApi!.sketches
            .firstWhere((item) => item.id == first.id)
            .entityIds,
        contains(firstLine.id),
      );
      expect(
        harness.controller.sketchApi!.entity(firstLine.id),
        isA<SketchLine>(),
      );
      expect(
        harness
            .cad
            .runtime
            .document!
            .entities[firstLine.id]
            ?.data['parentSketchId'],
        first.id,
      );

      await harness.cad.runtime.save(recordLifecycle: true);
      final reopened = await _reopen(harness, 'p0-two-sketches');
      addTearDown(reopened.controller.dispose);
      addTearDown(reopened.cad.dispose);

      expect(
        reopened.controller.sketchApi!.sketches.map((item) => item.id).toSet(),
        {first.id, second.id},
      );
      expect(
        reopened
            .cad
            .runtime
            .document!
            .entities[firstLine.id]
            ?.data['parentSketchId'],
        first.id,
      );
      await reopened.controller.reopenSketchForEditing(first.id);
      expect(reopened.controller.activeSketch!.id, first.id);
      expect(
        reopened.controller.activeSketch!.entityIds,
        contains(firstLine.id),
      );
      expect(
        reopened.controller.activeSketch!.entityIds,
        isNot(contains(secondLine.id)),
      );
      expect(
        reopened.controller.sketchApi!.entity(firstLine.id),
        isA<SketchLine>(),
      );
      await reopened.controller.reopenSketchForEditing(second.id);
      expect(reopened.controller.activeSketch!.id, second.id);
      expect(
        reopened.controller.activeSketch!.entityIds,
        contains(secondLine.id),
      );
      expect(
        reopened.controller.activeSketch!.entityIds,
        isNot(contains(firstLine.id)),
      );
      expect(
        reopened.controller.sketchApi!.entity(secondLine.id),
        isA<SketchLine>(),
      );
    },
  );

  test(
    'controller, document and engine share the sketch: prefix identity',
    () async {
      final harness = await _p0Harness('p0-sketch-prefix', openSketch: true);
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final sketch = harness.controller.activeSketch!;
      expect(sketch.id, startsWith('sketch:'));
      expect(
        harness.controller.sketchApi!.engine.sketches.containsKey(sketch.id),
        isTrue,
      );
      expect(
        harness.cad.runtime.document!.entities[sketch.id]?.kind,
        CadDocumentEntityKind.sketch,
      );
      expect(
        (harness.cad.runtime.document!.entities[sketch.id]!.data['sketch']
            as Map)['id'],
        sketch.id,
      );
      harness.controller.selectSketch(sketch.id);
      expect(harness.controller.activeSketch!.id, sketch.id);
      expect(harness.controller.sketchApi!.engine.activeSketchId, sketch.id);
    },
  );

  test(
    'reopening any Sketch preserves all document roots and Explorer inputs',
    () async {
      final harness = await _p0Harness('p0-three-sketch-roots', openSketch: true);
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final ids = <String>[];
      for (var index = 0; index < 3; index++) {
        if (index > 0) {
          harness.controller.selectWorldSketchPlane(
            index == 1 ? SketchPlaneType.yz : SketchPlaneType.zx,
          );
          await harness.controller.openSketch(forceNew: true);
        }
        final sketch = harness.controller.activeSketch!;
        ids.add(sketch.id);
        harness.controller.sketchApi!.builders.line.build(
          SketchVector(index.toDouble(), 0),
          SketchVector(index.toDouble() + 1, 0),
        );
      }

      Future<Set<String>> documentRoots() async => harness.cad.runtime.document!
          .entities
          .values
          .where(
            (entity) =>
                entity.kind == CadDocumentEntityKind.sketch &&
                entity.data['sketch'] is Map,
          )
          .map((entity) => entity.id)
          .toSet();

      expect(await documentRoots(), ids.toSet());
      for (final id in ids) {
        await harness.controller.reopenSketchForEditing(id);
        expect(harness.controller.activeSketch!.id, id);
        expect(await documentRoots(), ids.toSet());
        expect(
          harness.controller.sketchApi!.sketches.map((item) => item.id).toSet(),
          ids.toSet(),
        );
      }
    },
  );

  test(
    'incomplete engine synchronization never removes persisted Sketch roots',
    () async {
      final harness = await _p0Harness(
        'p0-incomplete-sketch-sync',
        openSketch: true,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final ids = <String>[];
      for (var index = 0; index < 3; index++) {
        if (index > 0) {
          harness.controller.selectWorldSketchPlane(
            index == 1 ? SketchPlaneType.yz : SketchPlaneType.zx,
          );
          await harness.controller.openSketch(forceNew: true);
        }
        final sketch = harness.controller.activeSketch!;
        ids.add(sketch.id);
        harness.controller.sketchApi!.builders.line.build(
          SketchVector(index.toDouble(), 0),
          SketchVector(index.toDouble() + 1, 0),
        );
      }
      await harness.controller.persist();
      final document = harness.cad.runtime.document!;
      expect(
        document.entities.values
            .where(
              (entity) =>
                  entity.kind == CadDocumentEntityKind.sketch &&
                  entity.data['sketch'] is Map,
            )
            .map((entity) => entity.id)
            .toSet(),
        ids.toSet(),
      );

      // Simulate the transient state produced when configureProject has only
      // restored the active root while the other roots are still loading.
      final engine = harness.controller.sketchApi!.engine;
      for (final id in ids.skip(1)) {
        final removed = engine.sketches.remove(id);
        for (final entityId in removed?.entityIds ?? const <String>[]) {
          engine.entities.remove(entityId);
        }
      }
      engine.activeSketchId = ids.first;

      await harness.controller.reopenSketchForEditing(ids.first);
      final remainingRoots = harness.cad.runtime.document!.entities.values
          .where(
            (entity) =>
                entity.kind == CadDocumentEntityKind.sketch &&
                entity.data['sketch'] is Map,
          )
          .map((entity) => entity.id)
          .toSet();
      expect(remainingRoots, ids.toSet());
      expect(
        harness.controller.sketchApi!.sketches.map((item) => item.id).toSet(),
        contains(ids.first),
      );
    },
  );

  test(
    'partial Engine after Save/Open still enters sibling Sketches and keeps geometry',
    () async {
      final harness = await _p0Harness(
        'p0-switch-partial-engine',
        openSketch: false,
        mesh: true,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final created = await _createThreeSketchesIncludingSection(harness);
      _logSketchState(
        harness.cad,
        harness.controller,
        'after-create',
        created.ids,
      );
      await _enterExitEachSketch(harness, created.ids);
      await harness.controller.saveProject();
      _logSketchState(
        harness.cad,
        harness.controller,
        'after-save',
        created.ids,
      );

      final reopened = await _reopen(harness, 'p0-switch-partial-engine');
      addTearDown(reopened.controller.dispose);
      addTearDown(reopened.cad.dispose);
      _logSketchState(
        reopened.cad,
        reopened.controller,
        'after-open',
        created.ids,
      );
      expect(
        reopened.controller.sketchApi!.sketches.map((item) => item.id).toSet(),
        created.ids.toSet(),
      );

      _simulatePartialEngine(reopened.controller, keepId: created.ids.first);
      _logSketchState(
        reopened.cad,
        reopened.controller,
        'partial-engine',
        created.ids,
      );

      await reopened.controller.reopenSketchForEditing(created.ids.first);
      expect(reopened.controller.error, isNull);
      expect(reopened.controller.activeSketch!.id, created.ids.first);
      expect(
        reopened.controller.sketchApi!.engine.activeSketchId,
        created.ids.first,
      );
      _logSketchState(
        reopened.cad,
        reopened.controller,
        'entered-sketch-1',
        created.ids,
      );
      expect(
        _documentSketchRoots(reopened.cad).toSet(),
        created.ids.toSet(),
        reason:
            '7730604 roots must stay in Explorer after the first enter-edit',
      );
      for (final id in created.ids) {
        expect(
          _documentSketchChildren(reopened.cad, id),
          isNotEmpty,
          reason: 'Sibling geometry of $id must survive entering Sketch 1',
        );
      }
      await _editLineLength(
        reopened.controller,
        created.lineIds[created.ids.first]!,
        11.0,
      );
      await reopened.controller.finishSketch();
      expect(
        reopened.controller.error,
        isNull,
        reason: reopened.controller.error,
      );
      _logSketchState(
        reopened.cad,
        reopened.controller,
        'exited-sketch-1',
        created.ids,
      );

      for (var index = 1; index < created.ids.length; index++) {
        final id = created.ids[index];
        try {
          await reopened.controller.reopenSketchForEditing(id);
        } catch (error, stack) {
          debugPrint('P0 original switch exception: $error');
          debugPrint('$stack');
          rethrow;
        }
        expect(
          reopened.controller.error,
          isNull,
          reason: reopened.controller.error,
        );
        expect(reopened.controller.activeSketch!.id, id);
        expect(reopened.controller.sketchApi!.engine.activeSketchId, id);
        expect(reopened.controller.stage, SketchSurfaceStage.sketchActive);
        expect(
          reopened.controller.sketchApi!.entity(created.lineIds[id]!),
          isA<SketchLine>(),
        );
        await _editLineLength(
          reopened.controller,
          created.lineIds[id]!,
          12.0 + index,
        );
        _logSketchState(
          reopened.cad,
          reopened.controller,
          'entered-sketch-${index + 1}',
          created.ids,
        );
        await reopened.controller.finishSketch();
        expect(
          reopened.controller.error,
          isNull,
          reason: reopened.controller.error,
        );
        _logSketchState(
          reopened.cad,
          reopened.controller,
          'exited-sketch-${index + 1}',
          created.ids,
        );
      }

      await reopened.controller.saveProject();
      final verified = await _reopen(harness, 'p0-switch-partial-engine');
      addTearDown(verified.controller.dispose);
      addTearDown(verified.cad.dispose);
      _logSketchState(
        verified.cad,
        verified.controller,
        'final-open',
        created.ids,
      );
      expect(
        verified.controller.sketchApi!.sketches.map((item) => item.id).toSet(),
        created.ids.toSet(),
      );
      expect(_documentSketchRoots(verified.cad).toSet(), created.ids.toSet());
      for (final id in created.ids) {
        await verified.controller.reopenSketchForEditing(id);
        expect(verified.controller.error, isNull);
        expect(verified.controller.activeSketch!.id, id);
        expect(
          verified.controller.sketchApi!.entity(created.lineIds[id]!),
          isA<SketchLine>(),
        );
        expect(_documentSketchChildren(verified.cad, id), isNotEmpty);
        expect(
          _visibleSketchChildIds(verified.cad, id),
          isNotEmpty,
          reason: 'Visible geometry of $id must survive Save/Open',
        );
        await verified.controller.finishSketch();
        expect(verified.controller.error, isNull);
      }
    },
  );

  test(
    'three Sketches including a Section conversion survive enter-exit Save/Open',
    () async {
      final harness = await _p0Harness(
        'p0-three-sketch-section-switch',
        openSketch: false,
        mesh: true,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final created = await _createThreeSketchesIncludingSection(harness);
      await _enterExitEachSketch(harness, created.ids);
      await harness.controller.saveProject();

      final reopened = await _reopen(harness, 'p0-three-sketch-section-switch');
      addTearDown(reopened.controller.dispose);
      addTearDown(reopened.cad.dispose);
      expect(
        reopened.controller.sketchApi!.sketches.map((item) => item.id).toSet(),
        created.ids.toSet(),
      );
      for (final id in created.ids) {
        await reopened.controller.reopenSketchForEditing(id);
        expect(reopened.controller.error, isNull);
        expect(reopened.controller.activeSketch!.id, id);
        expect(
          reopened.controller.sketchApi!.entity(created.lineIds[id]!),
          isA<SketchLine>(),
        );
        expect(_visibleSketchChildIds(reopened.cad, id), isNotEmpty);
        await reopened.controller.finishSketch();
        expect(reopened.controller.error, isNull);
      }
    },
  );

  test(
    'explicitly deleted Sketch roots are not resurrected by synchronization',
    () async {
      final harness = await _p0Harness(
        'p0-explicit-sketch-delete',
        openSketch: true,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final ids = <String>[];
      for (var index = 0; index < 3; index++) {
        if (index > 0) {
          harness.controller.selectWorldSketchPlane(
            index == 1 ? SketchPlaneType.yz : SketchPlaneType.zx,
          );
          await harness.controller.openSketch(forceNew: true);
        }
        final sketch = harness.controller.activeSketch!;
        ids.add(sketch.id);
        harness.controller.sketchApi!.builders.line.build(
          SketchVector(index.toDouble(), 0),
          SketchVector(index.toDouble() + 1, 0),
        );
      }
      final deletedId = ids.last;
      harness.controller.sketchApi!.engine.deleteSketch(deletedId);
      await harness.cad.runtime.mutate(
        command: 'test.delete-sketch-root',
        remove: [deletedId],
      );
      await harness.controller.reopenSketchForEditing(ids.first);

      final roots = harness.cad.runtime.document!.entities.values
          .where(
            (entity) =>
                entity.kind == CadDocumentEntityKind.sketch &&
                entity.data['sketch'] is Map,
          )
          .map((entity) => entity.id)
          .toSet();
      expect(roots, {ids[0], ids[1]});
      expect(
        harness.controller.sketchApi!.sketches.map((item) => item.id).toSet(),
        {ids[0], ids[1]},
      );
    },
  );

  test(
    'persist rejects an unloaded child before writing any Sketch file',
    () async {
      final harness = await _p0Harness(
        'p0-persist-preflight',
        openSketch: true,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final sketch = harness.controller.activeSketch!;
      final line = harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(4, 0),
      );
      await harness.controller.persist();
      final rootFile = File(
        '${harness.directory.path}${Platform.pathSeparator}CAD'
        '${Platform.pathSeparator}Sketch${Platform.pathSeparator}'
        '${sketch.id.replaceAll(':', '_')}.json',
      );
      final before = await rootFile.readAsString();
      harness.controller.sketchApi!.engine.entities.remove(line.id);

      await expectLater(
        harness.controller.persist(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('not loaded'),
          ),
        ),
      );
      expect(await rootFile.readAsString(), before);
    },
  );

  test(
    'Create Section immediately after Plane YZ keeps YZ support metadata',
    () async {
      final harness = await _p0Harness(
        'p0-plane-yz-immediate',
        openSketch: false,
        mesh: true,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      // Leftover default is XY. Operator sequence: Plane YZ, then Create
      // Section, with no Sketch or other command in between.
      harness.controller.selectWorldSketchPlane(SketchPlaneType.xy);
      expect(harness.controller.activeSketchPlaneId, endsWith('xy-plane'));
      await harness.controller.createWorldReferenceCurve(SketchPlaneType.yz);
      expect(
        harness.controller.activeSketchPlaneId,
        endsWith('yz-plane'),
        reason: 'Plane YZ must publish the support consumed by Create Section.',
      );
      expect(harness.controller.activeSketchPlane!.normal.x, closeTo(1, 1e-12));
      expect(harness.controller.activeSketchPlane!.normal.y, closeTo(0, 1e-12));
      expect(harness.controller.activeSketchPlane!.normal.z, closeTo(0, 1e-12));
      await harness.controller.createSection();
      final created =
          harness.controller.sections.sections.last.data['section'] as Map;
      expect(created['planeId'], endsWith('yz-plane'));
      expect(created['planeId'], isNot(contains('xy-plane')));
      expect(created['normal'], [1.0, 0.0, 0.0]);
    },
  );

  test(
    'XY YZ ZX sections of an asymmetric box keep their world normals',
    () async {
      final harness = await _p0Harness(
        'p0-asymmetric-planes',
        openSketch: false,
        mesh: true,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      Future<Map<String, dynamic>> cut(SketchPlaneType type) async {
        await harness.controller.createWorldReferenceCurve(type);
        final section = harness.controller.sections.sections.last;
        final definition = section.data['section'] as Map;
        final segments = (definition['segments'] as List)
            .map(
              (raw) => (raw as List)
                  .map((point) => Vector3.fromJson(point as List))
                  .toList(),
            )
            .toList();
        var min = Vector3(1e9, 1e9, 1e9);
        var max = Vector3(-1e9, -1e9, -1e9);
        for (final segment in segments) {
          for (final point in segment) {
            min = Vector3(
              math.min(min.x, point.x),
              math.min(min.y, point.y),
              math.min(min.z, point.z),
            );
            max = Vector3(
              math.max(max.x, point.x),
              math.max(max.y, point.y),
              math.max(max.z, point.z),
            );
          }
        }
        return {
          'planeId': definition['planeId'],
          'normal': definition['normal'],
          'span': max - min,
        };
      }

      final xy = await cut(SketchPlaneType.xy);
      final yz = await cut(SketchPlaneType.yz);
      final zx = await cut(SketchPlaneType.zx);

      expect(xy['planeId'], endsWith('xy-plane'));
      expect(yz['planeId'], endsWith('yz-plane'));
      expect(zx['planeId'], endsWith('xz-plane'));
      expect(xy['normal'], [0.0, 0.0, 1.0]);
      expect(yz['normal'], [1.0, 0.0, 0.0]);
      expect(zx['normal'], [0.0, 1.0, 0.0]);

      final xySpan = xy['span'] as Vector3;
      final yzSpan = yz['span'] as Vector3;
      final zxSpan = zx['span'] as Vector3;
      expect(xySpan.x, greaterThan(15));
      expect(xySpan.y, greaterThan(3));
      expect(xySpan.z.abs(), lessThan(1e-6));
      expect(yzSpan.y, greaterThan(3));
      expect(yzSpan.z, greaterThan(8));
      expect(yzSpan.x.abs(), lessThan(1e-6));
      expect(zxSpan.x, greaterThan(15));
      expect(zxSpan.z, greaterThan(8));
      expect(zxSpan.y.abs(), lessThan(1e-6));
    },
  );

  test(
    'disconnected section loops stay disconnected through Sketch conversion',
    () async {
      final harness = await _p0Harness(
        'p0-disconnected-loops',
        openSketch: false,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);
      await _registerMesh(
        harness,
        id: 'TwoBoxes',
        nodes: [
          ..._boxNodes(-18, -16, -2, 2, -3, 3),
          ..._boxNodes(16, 18, -2, 2, -3, 3),
        ],
        triangles: [..._boxTriangles(0), ..._boxTriangles(8)],
      );

      await harness.controller.createWorldReferenceCurve(SketchPlaneType.xy);
      final section = harness.controller.sections.sections.single;
      final definition = section.data['section'] as Map;
      expect(definition['loopCount'], 2);
      harness.cad.runtime.select({section.id});
      final started = DateTime.now();
      await harness.controller.createSketchFromSelectedSection();
      final elapsed = DateTime.now().difference(started);
      final sketch = harness.controller.activeSketch!;
      expect(sketch.entityIds, isNotEmpty);
      expect(elapsed.inSeconds, lessThan(2));
      final lines = sketch.entityIds
          .map(harness.controller.sketchApi!.entity)
          .whereType<SketchLine>()
          .toList();
      expect(lines, isNotEmpty);
      final xs = lines
          .expand(
            (line) => [
              SketchVector.fromJson(line.parameters['start']).x,
              SketchVector.fromJson(line.parameters['end']).x,
            ],
          )
          .toList();
      expect(xs.where((x) => x < -10).length, greaterThan(0));
      expect(xs.where((x) => x > 10).length, greaterThan(0));
      expect(
        lines.any((line) {
          final start = SketchVector.fromJson(line.parameters['start']);
          final end = SketchVector.fromJson(line.parameters['end']);
          return start.x.sign != end.x.sign &&
              start.x.abs() > 5 &&
              end.x.abs() > 5;
        }),
        isFalse,
        reason: 'A line must not join the two disconnected loops.',
      );
    },
  );

  test(
    'modest Section to Sketch conversion keeps documentary identity',
    () async {
      final harness = await _p0Harness(
        'p0-modest-conversion',
        openSketch: false,
        mesh: true,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      await harness.controller.createWorldReferenceCurve(SketchPlaneType.xy);
      final section = harness.controller.sections.sections.single;
      final rawCount =
          ((section.data['section'] as Map)['segments'] as List).length;
      expect(rawCount, greaterThan(0));
      expect(rawCount, lessThan(80));
      harness.cad.runtime.select({section.id});
      final started = DateTime.now();
      await harness.controller.createSketchFromSelectedSection();
      final elapsed = DateTime.now().difference(started);
      final sketch = harness.controller.activeSketch!;
      expect(sketch.id, startsWith('sketch:'));
      expect(
        harness.cad.runtime.document!.entities[sketch.id]?.kind,
        CadDocumentEntityKind.sketch,
      );
      expect(sketch.entityIds.length, lessThanOrEqualTo(rawCount + 4));
      expect(elapsed.inMilliseconds, lessThan(1500));
      await harness.controller.reopenSketchForEditing(sketch.id);
      expect(harness.controller.stage, SketchSurfaceStage.sketchActive);
      expect(harness.controller.sketchEntities, isNotEmpty);
    },
  );

  test(
    'canonical Save serializes concurrent requests and persists active Sketch',
    () async {
      final harness = await _p0Harness('p0-canonical-save', openSketch: true);
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final sketch = harness.controller.activeSketch!;
      harness.controller.sketchApi!.builders.line.build(
        const SketchVector(0, 0),
        const SketchVector(5, 0),
      );
      final previous = harness.cad.runtime.read<Future<void> Function()>(
        'project.beforeSave',
      );
      expect(previous, isNotNull);
      var persistCalls = 0;
      harness.cad.runtime.write<Future<void> Function()>(
        'project.beforeSave',
        () async {
          persistCalls++;
          await previous!();
        },
      );
      await Future.wait([
        harness.commands.dispatch('project.save'),
        harness.controller.saveProject(),
      ]);
      expect(persistCalls, 2);

      final activeFile = File(
        '${harness.directory.path}${Platform.pathSeparator}CAD'
        '${Platform.pathSeparator}SketchHistory'
        '${Platform.pathSeparator}active-sketch.json',
      );
      final metadata = jsonDecode(await activeFile.readAsString()) as Map;
      expect(metadata['schema'], 'flcad.sketch-active');
      expect(metadata['projectId'], 'p0-canonical-save');
      expect(metadata['activeSketchId'], sketch.id);
      expect(
        jsonDecode(
          await File(
            '${harness.directory.path}${Platform.pathSeparator}CAD'
            '${Platform.pathSeparator}Sketch'
            '${Platform.pathSeparator}${sketch.id.replaceAll(':', '_')}.json',
          ).readAsString(),
        ),
        isA<Map>(),
      );
    },
  );

  test(
    'canonical Save reports pre-save failure and recovers on retry',
    () async {
      final harness = await _p0Harness(
        'p0-save-failure-recovery',
        openSketch: true,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final previous = harness.cad.runtime.read<Future<void> Function()>(
        'project.beforeSave',
      );
      harness.cad.runtime.write<Future<void> Function()>(
        'project.beforeSave',
        () async => throw StateError('simulated persistence failure'),
      );
      await expectLater(
        harness.controller.saveProject(),
        throwsA(isA<StateError>()),
      );
      harness.cad.runtime.write('project.beforeSave', previous);
      await harness.controller.saveProject();
      expect(
        await File(
          '${harness.directory.path}${Platform.pathSeparator}cad-document.json',
        ).exists(),
        isTrue,
      );
    },
  );

  test(
    'queued Save rejects a project switch without mixing documents',
    () async {
      final harness = await _p0Harness(
        'p0-save-project-switch',
        openSketch: true,
      );
      addTearDown(() => harness.directory.delete(recursive: true));
      addTearDown(harness.controller.dispose);
      addTearDown(harness.cad.dispose);

      final previous = harness.cad.runtime.read<Future<void> Function()>(
        'project.beforeSave',
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      harness.cad.runtime.write<Future<void> Function()>(
        'project.beforeSave',
        () async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          await previous!();
        },
      );
      final pending = harness.controller.saveProject();
      await entered.future;
      await harness.projectManager.open(
        Project(
          id: 'p0-save-project-switch-other',
          name: 'other',
          client: 'P0',
          description: 'other temporary project',
          createdAt: DateTime(2020),
          status: ProjectStatus.created,
        ),
      );
      release.complete();
      await expectLater(pending, throwsA(isA<StateError>()));
      expect(harness.cad.runtime.document!.projectId, 'p0-save-project-switch');
    },
  );
}

typedef _P0Harness = ({
  Directory directory,
  DesktopCadController cad,
  DesktopCommandCoordinator commands,
  OperationalReverseEngineeringController controller,
  ProjectManager projectManager,
  ProjectRepository projects,
});

Future<_P0Harness> _p0Harness(
  String name, {
  required bool openSketch,
  bool mesh = false,
}) async {
  final directory = await Directory.systemTemp.createTemp('${name}_');
  final projects = ProjectRepository(
    storage: LocalStorageService(rootDirectory: directory),
  );
  final projectManager = ProjectManager(repository: projects);
  await projectManager.open(
    Project(
      id: name,
      name: name,
      client: 'P0',
      description: 'P0 test project',
      createdAt: DateTime(2020),
      status: ProjectStatus.created,
    ),
  );
  final kernels = KernelManager()
    ..register(_HealthySurfaceKernel(), makeDefault: true);
  final cad = DesktopCadController(kernels: kernels, projects: projectManager);
  final commands = DesktopCommandCoordinator(
    cad: cad,
    projects: projectManager,
    repository: projects,
  );
  final controller = OperationalReverseEngineeringController(
    recognition: ProfessionalRecognitionApi(),
    commands: commands,
    runtime: cad.runtime,
    referenceApi: ReferenceApi(
      engine: ReferenceEngine(
        repository: ReferenceRepository(projects: projects),
      ),
    ),
  );
  await cad.runtime.open(name, directory);
  await controller.configureProject(
    projectId: name,
    projectDirectory: directory,
  );
  await commands.refreshContext();
  if (mesh) {
    await _registerMesh(
      (
        directory: directory,
        cad: cad,
        commands: commands,
        controller: controller,
        projectManager: projectManager,
        projects: projects,
      ),
      id: 'Mesh001',
      nodes: _boxNodes(-10, 10, -2, 2, -5, 5),
      triangles: _boxTriangles(0),
    );
  }
  if (openSketch) {
    controller.selectWorldSketchPlane(SketchPlaneType.xy);
    await controller.openSketch();
  }
  return (
    directory: directory,
    cad: cad,
    commands: commands,
    controller: controller,
    projectManager: projectManager,
    projects: projects,
  );
}

typedef _ThreeSketches = ({List<String> ids, Map<String, String> lineIds});

Future<_ThreeSketches> _createThreeSketchesIncludingSection(
  _P0Harness harness,
) async {
  final ids = <String>[];
  final lineIds = <String, String>{};
  harness.controller.selectWorldSketchPlane(SketchPlaneType.xy);
  await harness.controller.openSketch();
  var sketch = harness.controller.activeSketch!;
  ids.add(sketch.id);
  lineIds[sketch.id] = harness.controller.sketchApi!.builders.line
      .build(const SketchVector(0, 0), const SketchVector(6, 0))
      .id;
  await harness.controller.finishSketch();
  expect(harness.controller.error, isNull);

  harness.controller.selectWorldSketchPlane(SketchPlaneType.yz);
  await harness.controller.openSketch(forceNew: true);
  sketch = harness.controller.activeSketch!;
  ids.add(sketch.id);
  lineIds[sketch.id] = harness.controller.sketchApi!.builders.line
      .build(const SketchVector(0, 0), const SketchVector(0, 7))
      .id;
  await harness.controller.finishSketch();
  expect(harness.controller.error, isNull);

  await harness.controller.createWorldReferenceCurve(SketchPlaneType.xy);
  final section = harness.controller.sections.sections.last;
  harness.cad.runtime.select({section.id});
  await harness.controller.createSketchFromSelectedSection();
  sketch = harness.controller.activeSketch!;
  ids.add(sketch.id);
  expect(sketch.metadata['sourceSectionId'], section.id);
  final sectionLine = sketch.entityIds
      .map(harness.controller.sketchApi!.entity)
      .whereType<SketchLine>()
      .firstOrNull;
  expect(
    sectionLine,
    isNotNull,
    reason: 'Section conversion must create lines',
  );
  lineIds[sketch.id] = sectionLine!.id;
  await harness.controller.finishSketch();
  expect(harness.controller.error, isNull);
  expect(ids, hasLength(3));
  expect(ids.toSet(), hasLength(3));
  return (ids: ids, lineIds: lineIds);
}

Future<void> _enterExitEachSketch(_P0Harness harness, List<String> ids) async {
  for (final id in ids) {
    await harness.controller.reopenSketchForEditing(id);
    expect(harness.controller.error, isNull);
    expect(harness.controller.activeSketch!.id, id);
    expect(harness.controller.sketchApi!.engine.activeSketchId, id);
    await harness.controller.finishSketch();
    expect(harness.controller.error, isNull);
  }
}

Future<void> _editLineLength(
  OperationalReverseEngineeringController controller,
  String lineId,
  double length,
) async {
  await controller.updateSketchEntityParameters(lineId, {'length': length});
  expect(controller.error, isNull, reason: controller.error);
  final edited = controller.sketchApi!.entity(lineId)! as SketchLine;
  expect(edited.parameters['length'], closeTo(length, 1e-9));
}

void _simulatePartialEngine(
  OperationalReverseEngineeringController controller, {
  required String keepId,
}) {
  final engine = controller.sketchApi!.engine;
  for (final id in engine.sketches.keys.toList()) {
    if (id == keepId) continue;
    final removed = engine.sketches.remove(id);
    for (final entityId in removed?.entityIds ?? const <String>[]) {
      engine.entities.remove(entityId);
    }
  }
  engine.activeSketchId = keepId;
}

Iterable<String> _documentSketchRoots(DesktopCadController cad) => cad
    .runtime
    .document!
    .entities
    .values
    .where(
      (entity) =>
          entity.kind == CadDocumentEntityKind.sketch &&
          entity.data['sketch'] is Map &&
          entity.data['deleted'] != true,
    )
    .map((entity) => entity.id);

Iterable<CadDocumentEntity> _documentSketchChildren(
  DesktopCadController cad,
  String sketchId,
) => cad.runtime.document!.entities.values.where(
  (entity) =>
      entity.data['parentSketchId'] == sketchId &&
      entity.data['sketchEntity'] is Map &&
      entity.data['deleted'] != true,
);

Iterable<String> _visibleSketchChildIds(
  DesktopCadController cad,
  String sketchId,
) => _documentSketchChildren(cad, sketchId)
    .where((entity) {
      if (entity.data['sceneVisible'] == false) return false;
      final scene = cad.runtime.scene.find(entity.id);
      return scene == null || scene.visible;
    })
    .map((entity) => entity.id);

void _logSketchState(
  DesktopCadController cad,
  OperationalReverseEngineeringController controller,
  String step,
  List<String> ids,
) {
  final document = cad.runtime.document;
  final engine = controller.sketchApi?.engine;
  final sceneIds = cad.runtime.scene.entities.map((item) => item.id).toList();
  debugPrint(
    '[p0-switch $step] '
    'edit=${controller.stage.name} '
    'controller=${controller.activeSketch?.id} '
    'engineActive=${engine?.activeSketchId} '
    'engineCount=${engine?.sketches.length} '
    'documentRoots=${_documentSketchRoots(cad).length} '
    'ids=$ids '
    'children=${ids.map((id) => '$id:${_documentSketchChildren(cad, id).length}').join(',')} '
    'visible=${ids.map((id) => '$id:${_visibleSketchChildIds(cad, id).length}').join(',')} '
    'scene=${sceneIds.length} '
    'docEntities=${document?.entities.length}',
  );
}

Future<
  ({
    DesktopCadController cad,
    OperationalReverseEngineeringController controller,
  })
>
_reopen(_P0Harness harness, String projectId) async {
  final projects = harness.projects;
  final projectManager = ProjectManager(repository: projects);
  final project = await projects.findById(projectId);
  if (project == null) throw StateError('Missing P0 project: $projectId');
  await projectManager.open(project);
  final kernels = KernelManager()
    ..register(_HealthySurfaceKernel(), makeDefault: true);
  final cad = DesktopCadController(kernels: kernels, projects: projectManager);
  final commands = DesktopCommandCoordinator(
    cad: cad,
    projects: projectManager,
    repository: projects,
  );
  final controller = OperationalReverseEngineeringController(
    recognition: ProfessionalRecognitionApi(),
    commands: commands,
    runtime: cad.runtime,
    referenceApi: ReferenceApi(
      engine: ReferenceEngine(
        repository: ReferenceRepository(projects: harness.projects),
      ),
    ),
  );
  await cad.runtime.open(projectId, harness.directory);
  await controller.configureProject(
    projectId: projectId,
    projectDirectory: harness.directory,
  );
  await commands.refreshContext();
  return (cad: cad, controller: controller);
}

Future<void> _registerMesh(
  _P0Harness harness, {
  required String id,
  required List<double> nodes,
  required List<int> triangles,
}) async {
  final xs = [for (var i = 0; i < nodes.length; i += 3) nodes[i]];
  final ys = [for (var i = 1; i < nodes.length; i += 3) nodes[i]];
  final zs = [for (var i = 2; i < nodes.length; i += 3) nodes[i]];
  await harness.cad.runtime.registerImport(
    ImportedCadDocument(
      id: id,
      projectId: harness.cad.runtime.document!.projectId,
      sourcePath: '$id.stl',
      format: CadImportFormat.stl,
      registeredPath: 'CAD/Imports/$id.stl',
      validation: const [],
      mesh: KernelMeshHandle(
        persistentId: '$id-mesh',
        kernelId: 'test',
        fingerprint: id,
        vertexCount: nodes.length ~/ 3,
        triangleCount: triangles.length ~/ 3,
        bounds: KernelBounds(
          xs.reduce(math.min),
          ys.reduce(math.min),
          zs.reduce(math.min),
          xs.reduce(math.max),
          ys.reduce(math.max),
          zs.reduce(math.max),
        ),
        hasNormals: false,
        metadata: const {},
      ),
    ),
    geometry: KernelMeshGeometry(nodes: nodes, triangles: triangles),
  );
}

List<double> _boxNodes(
  double x0,
  double x1,
  double y0,
  double y1,
  double z0,
  double z1,
) => [
  x0,
  y0,
  z0,
  x1,
  y0,
  z0,
  x1,
  y1,
  z0,
  x0,
  y1,
  z0,
  x0,
  y0,
  z1,
  x1,
  y0,
  z1,
  x1,
  y1,
  z1,
  x0,
  y1,
  z1,
];

List<int> _boxTriangles(int base) => [
  base,
  base + 1,
  base + 2,
  base,
  base + 2,
  base + 3,
  base + 4,
  base + 6,
  base + 5,
  base + 4,
  base + 7,
  base + 6,
  base,
  base + 5,
  base + 1,
  base,
  base + 4,
  base + 5,
  base + 3,
  base + 2,
  base + 6,
  base + 3,
  base + 6,
  base + 7,
  base,
  base + 3,
  base + 7,
  base,
  base + 7,
  base + 4,
  base + 1,
  base + 5,
  base + 6,
  base + 1,
  base + 6,
  base + 2,
];

class _HealthySurfaceKernel
    implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'p0-test',
    name: 'P0 test kernel',
    version: '1',
    capabilities: KernelCapabilities({KernelCapability.planeSurface}),
    vendor: 'FLCAD',
  );

  @override
  Future<KernelHealth> healthCheck() async =>
      KernelHealth(KernelHealthStatus.healthy, 'ok', DateTime(2000));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
