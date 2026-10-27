import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/app/bootstrap/engineering_bootstrap.dart';
import 'package:flcad_mobile/app/cad_viewport/camera/cad_camera_controller.dart';
import 'package:flcad_mobile/app/cad_viewport/native/integrated_native_viewport_widget.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_application.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/widgets/sketch_surface_workspace_panel.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/sketch_engine/api/sketch_engine_api.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/sketch_editor/models/editor_models.dart';
import 'package:flcad_mobile/core/sketch_constraints/api/constraint_api.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/storage/local_storage_service.dart';
import 'package:flcad_mobile/features/projects/data/project_repository.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _uuid = RegExp(
  r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late DesktopCadController cad;
  late DesktopCommandCoordinator commands;

  setUp(() async {
    EngineeringBootstrap.instance.initialize();
    support = await Directory.systemTemp.createTemp('flcad-sketch-flow-');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => support.path);
    final projects = ProjectRepository(
      storage: LocalStorageService(
        rootDirectory: Directory('${support.path}/FLCAD'),
      ),
    );
    cad = DesktopCadController(
      kernels: KernelManager()
        ..register(_WorkspaceKernelGate(), makeDefault: true),
      projects: ProjectManager.instance,
      projectRepository: projects,
    );
    commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
      repository: projects,
    );
  });

  tearDown(() async {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    cad.dispose();
    try {
      if (await support.exists()) await support.delete(recursive: true);
    } on FileSystemException {
      // The sketch engine may still hold a file in this temp project.
    }
  });

  testWidgets(
    'rectangle button creates four lines with four coincident and four directional constraints',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawRectangle(tester, cad, commands);
      final lines = _liveLines(cad);
      final coincidents = _liveCoincidents(cad);
      expect(
        lines,
        hasLength(4),
        reason:
            'the rectangle tool must emit four lines; '
            'engine=${cad.runtime.read<SketchEngineApi>('sketch.api')?.engine.entities.values.whereType<SketchLine>().length} '
            'cursor=${cad.runtime.read<Object>('sketch.rectangle.cursor')} '
            'doc=${cad.runtime.document?.entities.values.map((entity) => '${entity.kind.name}:${entity.data['name']}').join(', ')}',
      );
      expect(
        coincidents,
        hasLength(4),
        reason: 'shared coordinates are not coincident constraints',
      );
      expect(_maxCornerGap(lines), lessThanOrEqualTo(1e-6));
      final constraintApi = cad.runtime.read<ConstraintApi>(
        'sketch.constraintApi',
      )!;
      expect(
        constraintApi.constraints.where(
          (item) => item.type == SketchConstraintType.horizontal,
        ),
        hasLength(2),
      );
      expect(
        constraintApi.constraints.where(
          (item) => item.type == SketchConstraintType.vertical,
        ),
        hasLength(2),
      );
      expect(constraintApi.constraints, hasLength(8));
      expect(
        constraintApi.constraints.where(
          (item) => item.type == SketchConstraintType.fixed,
        ),
        isEmpty,
        reason: 'the rectangle tool must not apply FIX implicitly',
      );
      expect(
        cad.runtime.scene.entities.any(
          (entity) => entity.geometry['showEndpoints'] == true,
        ),
        isTrue,
        reason: 'colored vertex dots are endpoint markers, not FIX constraints',
      );
      expect(
        constraintApi.engine.lastResult?.diagnostics.any(
              (item) => item.message.contains('4 degree(s) of freedom'),
            ) ??
            false,
        isTrue,
      );
      expect(
        cad.runtime.scene.entities.where(
          (entity) => entity.geometry['dimensionLabel'] == 'FIX',
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'horizontal constraint on a rectangle keeps every corner joined',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawRectangle(tester, cad, commands);
      await _exitRectangleTool(tester);
      final vertical = _liveLines(cad).where(_isVertical).toList();
      expect(vertical, isNotEmpty);
      await _tapLine(tester, vertical.first);
      await _tapConstraint(tester, 'Horizontal');
      await _settle(tester);
      expect(
        _maxCornerGap(_liveLines(cad)),
        lessThanOrEqualTo(1e-6),
        reason: 'a solved constraint must not leave a corner open',
      );
    },
  );

  testWidgets('explicit Fix creates one constraint and is undoable', (
    tester,
  ) async {
    await _openSketch(tester, cad, commands);
    await _drawRectangle(tester, cad, commands);
    await _exitRectangleTool(tester);
    final vertical = _liveLines(cad).where(_isVertical).toList();
    await _tapLine(tester, vertical.first);
    final selectedId = vertical.first.id;
    final before = cad.runtime.read<ConstraintApi>('sketch.constraintApi')!;
    expect(
      before.constraints.where(
        (item) => item.type == SketchConstraintType.fixed,
      ),
      isEmpty,
    );
    await _tapConstraint(tester, 'Fix');
    await _waitForHistory(
      tester,
      commands,
      'reverse.sketch.constraint',
      'execute',
    );
    final after = cad.runtime.read<ConstraintApi>('sketch.constraintApi')!;
    final fixed = after.constraints
        .where((item) => item.type == SketchConstraintType.fixed)
        .toList();
    expect(fixed, hasLength(1));
    expect(fixed.single.references, [selectedId]);
    final sketchApi = cad.runtime.read<SketchEngineApi>('sketch.api')!;
    expect(
      sketchApi.engine.entities.values.whereType<SketchLine>().where(
        (line) => line.locked,
      ),
      hasLength(1),
    );
    expect(_maxCornerGap(_liveLines(cad)), lessThanOrEqualTo(1e-6));
    await tester.tap(find.byTooltip('Desfazer'));
    await _awaitShellAction(tester, cad, commands, 'undo');
    await _waitForHistory(
      tester,
      commands,
      'reverse.sketch.constraint',
      'undo',
    );
    expect(
      after.constraints.where(
        (item) => item.type == SketchConstraintType.fixed,
      ),
      isEmpty,
    );
    expect(
      sketchApi.engine.entities.values.whereType<SketchLine>().where(
        (line) => line.locked,
      ),
      isEmpty,
    );
    await tester.tap(find.byTooltip('Refazer'));
    await _awaitShellAction(tester, cad, commands, 'redo');
    await _waitForHistory(
      tester,
      commands,
      'reverse.sketch.constraint',
      'redo',
    );
    expect(
      after.constraints.where(
        (item) => item.type == SketchConstraintType.fixed,
      ),
      hasLength(1),
    );
  });

  testWidgets(
    'tree delete removes the Sketch root, its curves and the viewport',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawRectangle(tester, cad, commands);
      final sketch = _sketchRoot(cad);
      final childIds = _childrenOf(
        cad,
        sketch.id,
      ).map((entity) => entity.id).toSet();
      expect(childIds, isNotEmpty);
      await _deleteFromTree(
        tester,
        sketch.data['name'] as String? ?? sketch.id,
      );
      await _waitForHistory(
        tester,
        commands,
        'reverse.document.recycle',
        'execute',
      );
      final document = cad.runtime.document!;
      expect(document.entities[sketch.id]!.data['deleted'], isTrue);
      for (final id in childIds) {
        expect(document.entities[id]!.data['deleted'], isTrue, reason: id);
        expect(cad.runtime.scene.find(id), isNull, reason: id);
      }
      expect(cad.runtime.scene.find(sketch.id), isNull);
      expect(
        cad.runtime.selection.intersection({sketch.id, ...childIds}),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      await _waitForHistory(
        tester,
        commands,
        'reverse.document.recycle',
        'undo',
      );
      expect(
        cad.runtime.document!.entities[sketch.id]!.data['deleted'],
        isNot(true),
      );
      for (final id in childIds) {
        expect(cad.runtime.scene.find(id), isNotNull, reason: id);
      }
      await tester.tap(find.byTooltip('Refazer'));
      await _awaitShellAction(tester, cad, commands, 'redo');
      await _waitForHistory(
        tester,
        commands,
        'reverse.document.recycle',
        'redo',
      );
      for (final id in childIds) {
        expect(
          cad.runtime.document!.entities[id]!.data['deleted'],
          isTrue,
          reason: id,
        );
        expect(cad.runtime.scene.find(id), isNull, reason: id);
      }
    },
  );

  testWidgets('shell undo and redo restore the rectangle the operator just drew', (
    tester,
  ) async {
    await _openSketch(tester, cad, commands);
    await _drawRectangle(tester, cad, commands);
    expect(_liveLines(cad), hasLength(4));
    await tester.tap(find.byTooltip('Desfazer'));
    await _awaitShellAction(tester, cad, commands, 'undo');
    await _waitForHistory(tester, commands, 'reverse.sketch.rectangle', 'undo');
    expect(
      _liveLines(cad),
      isEmpty,
      reason:
          'status=${cad.message}; history=${commands.manager.history.map((entry) => '${entry.commandId}:${entry.operation}').join(',')}',
    );
    await tester.tap(find.byTooltip('Refazer'));
    await _awaitShellAction(tester, cad, commands, 'redo');
    await _waitForHistory(tester, commands, 'reverse.sketch.rectangle', 'redo');
    expect(
      _liveLines(cad),
      hasLength(4),
      reason:
          'status=${cad.message}; history=${commands.manager.history.map((entry) => '${entry.commandId}:${entry.operation}').join(',')}',
    );
    expect(_maxCornerGap(_liveLines(cad)), lessThanOrEqualTo(1e-6));
  });

  testWidgets(
    'viewport pointer drag reduces and expands a rectangle without opening corners',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawRectangle(tester, cad, commands);
      await _exitRectangleTool(tester);
      final initial = _liveLines(cad).where(_isVertical).toList();
      expect(initial, hasLength(2));
      final right = initial.reduce(
        (a, b) => _endpoints(a).first.x > _endpoints(b).first.x ? a : b,
      );
      final left = initial.reduce(
        (a, b) => _endpoints(a).first.x < _endpoints(b).first.x ? a : b,
      );
      final originalX = _endpoints(right).first.x;
      final leftX = _endpoints(left).first.x;
      final originalWidth = originalX - leftX;

      await _dragLine(tester, cad, commands, right, const Offset(-45, 0));
      await _waitForHistoryCount(tester, commands, 'reverse.sketch.drag', 1);
      expect(_maxCornerGap(_liveLines(cad)), lessThanOrEqualTo(1e-6));
      final reduced = cad.runtime.document!.entities[right.id]!;
      final reducedLeft = cad.runtime.document!.entities[left.id]!;
      expect(_endpoints(reduced).first.x, lessThan(originalX));
      expect(_endpoints(reducedLeft).first.x, closeTo(leftX, 1e-6));
      expect(
        _endpoints(reduced).first.x - _endpoints(reducedLeft).first.x,
        lessThan(originalWidth),
      );

      await _dragLine(tester, cad, commands, reduced, const Offset(70, 0));
      await _waitForHistoryCount(tester, commands, 'reverse.sketch.drag', 2);
      expect(_maxCornerGap(_liveLines(cad)), lessThanOrEqualTo(1e-6));
      final expanded = cad.runtime.document!.entities[right.id]!;
      final expandedLeft = cad.runtime.document!.entities[left.id]!;
      expect(
        _endpoints(expanded).first.x,
        greaterThan(_endpoints(reduced).first.x),
      );
      expect(_endpoints(expandedLeft).first.x, closeTo(leftX, 1e-6));
      expect(
        _endpoints(expanded).first.x - leftX,
        greaterThan(_endpoints(reduced).first.x - leftX),
      );
    },
  );

  testWidgets(
    'right-edge drag resizes width, respects H/V and Fix, then undo and redo',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawRectangle(tester, cad, commands);
      await _exitRectangleTool(tester);
      final constraintApi = cad.runtime.read<ConstraintApi>(
        'sketch.constraintApi',
      )!;
      final initialConstraints = constraintApi.constraints.toList();
      expect(initialConstraints.map((item) => item.type).toSet(), {
        SketchConstraintType.coincident,
        SketchConstraintType.horizontal,
        SketchConstraintType.vertical,
      });
      expect(initialConstraints, hasLength(8));
      expect(
        cad.runtime.scene.entities.where(
          (entity) => entity.geometry['dimensionLabel'] == 'FIX',
        ),
        isEmpty,
      );
      // Four lines have 16 endpoint coordinates: four coincidences remove
      // eight and four directional constraints remove four.
      expect(16 - 4 * 2 - 4, 4);

      final vertical = _liveLines(cad).where(_isVertical).toList();
      final horizontal = _liveLines(cad).where(_isHorizontal).toList();
      expect(vertical, hasLength(2));
      expect(horizontal, hasLength(2));
      var constraintCommands = 0;
      final right = _liveLines(cad)
          .where(_isVertical)
          .reduce(
            (a, b) => _endpoints(a).first.x > _endpoints(b).first.x ? a : b,
          );
      final left = _liveLines(cad)
          .where(_isVertical)
          .reduce(
            (a, b) => _endpoints(a).first.x < _endpoints(b).first.x ? a : b,
          );
      final leftX = _endpoints(left).first.x;
      final rightX = _endpoints(right).first.x;
      final width = rightX - leftX;
      final before = {
        for (final line in _liveLines(cad)) line.id: _endpoints(line),
      };
      expect(before, hasLength(4));

      await _dragLine(tester, cad, commands, right, const Offset(-50, 12));
      final narrowed = cad.runtime.document!.entities[right.id]!;
      final narrowedLeft = cad.runtime.document!.entities[left.id]!;
      expect(_endpoints(narrowed).map((point) => point.x), [
        lessThan(rightX),
        lessThan(rightX),
      ]);
      expect(_endpoints(narrowedLeft).map((point) => point.x), [
        closeTo(leftX, 1e-6),
        closeTo(leftX, 1e-6),
      ]);
      expect(_endpoints(narrowed).first.x - leftX, lessThan(width));
      for (final line in _liveLines(cad).where(_isHorizontal)) {
        final original = before[line.id]!;
        final current = _endpoints(line);
        for (var index = 0; index < 2; index++) {
          expect(current[index].y, closeTo(original[index].y, 1e-6));
          if ((original[index].x - leftX).abs() <= 1e-6) {
            expect(current[index].x, closeTo(leftX, 1e-6));
          } else {
            expect(
              current[index].x,
              closeTo(_endpoints(narrowed).first.x, 1e-6),
            );
          }
        }
      }
      expect(_maxCornerGap(_liveLines(cad)), lessThanOrEqualTo(1e-6));

      final narrowX = _endpoints(narrowed).first.x;
      await _dragLine(tester, cad, commands, narrowed, const Offset(80, -9));
      final widened = cad.runtime.document!.entities[right.id]!;
      expect(_endpoints(widened).first.x, greaterThan(narrowX));
      expect(
        _endpoints(cad.runtime.document!.entities[left.id]!).first.x,
        closeTo(leftX, 1e-6),
      );
      expect(_maxCornerGap(_liveLines(cad)), lessThanOrEqualTo(1e-6));
      final widenedX = _endpoints(widened).first.x;

      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(
        _endpoints(cad.runtime.document!.entities[right.id]!).first.x,
        closeTo(narrowX, 1e-6),
      );
      await tester.tap(find.byTooltip('Refazer'));
      await _awaitShellAction(tester, cad, commands, 'redo');
      expect(
        _endpoints(cad.runtime.document!.entities[right.id]!).first.x,
        closeTo(widenedX, 1e-6),
      );

      await _tapLine(tester, cad.runtime.document!.entities[right.id]!);
      await _tapConstraint(tester, 'Fix');
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        constraintCommands + 1,
      );
      expect(
        cad.runtime.scene.entities.where(
          (entity) => entity.geometry['dimensionLabel'] == 'FIX',
        ),
        isNotEmpty,
      );
      final lockedBeforeDrag = {
        for (final line in _liveLines(cad))
          line.id: [for (final point in _endpoints(line)) (point.x, point.y)],
      };
      await _dragLine(
        tester,
        cad,
        commands,
        cad.runtime.document!.entities[right.id]!,
        const Offset(60, 0),
      );
      expect(cad.message, contains('cannot move'));
      for (final line in _liveLines(cad)) {
        expect([
          for (final point in _endpoints(line)) (point.x, point.y),
        ], lockedBeforeDrag[line.id]);
      }
      final sketchApi = cad.runtime.read<SketchEngineApi>('sketch.api')!;
      expect(
        sketchApi.engine.entities.values.whereType<SketchLine>().where(
          (line) => line.locked && line.id != right.id,
        ),
        isEmpty,
      );

      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(
        cad.runtime
            .read<ConstraintApi>('sketch.constraintApi')!
            .constraints
            .where((item) => item.type == SketchConstraintType.fixed),
        isEmpty,
      );
      expect(
        _endpoints(cad.runtime.document!.entities[right.id]!).first.x,
        closeTo(widenedX, 1e-6),
      );
      expect(
        _endpoints(cad.runtime.document!.entities[left.id]!).first.x,
        closeTo(leftX, 1e-6),
      );
      expect(_maxCornerGap(_liveLines(cad)), lessThanOrEqualTo(1e-6));
    },
  );

  testWidgets(
    'rectangle dimensions preserve opposite sides, corners and Fix through real callbacks',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawRectangle(tester, cad, commands);
      await _exitRectangleTool(tester);
      await _openPanel(tester, 'sketch-panel-tab-dimensions');

      final initial = _rectangleByOrientation(cad);
      await _tapLine(tester, initial.top);
      await _createLinearDimension(tester, cad, commands, 40, 1);
      _expectRectangular(cad, expectedWidth: 40);

      await _editLinearDimension(tester, cad, commands, 40, 60, editCount: 1);
      _expectRectangular(cad, expectedWidth: 60);

      final widened = _rectangleByOrientation(cad);
      await _tapLine(tester, widened.left);
      expect(
        cad.runtime.selection,
        contains(widened.left.id),
        reason:
            'top=${widened.top.id} bottom=${widened.bottom.id} '
            'left=${widened.left.id} right=${widened.right.id} '
            'selected=${cad.runtime.selection}',
      );
      await _createLinearDimension(tester, cad, commands, 25, 2);
      _expectRectangular(cad, expectedWidth: 60, expectedHeight: 25);

      // The height dimension is one global command spanning the canonical
      // Sketch snapshot and the solver snapshot.
      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      await _waitForHistory(
        tester,
        commands,
        'reverse.sketch.dimension.create',
        'undo',
      );
      expect(_liveLines(cad).where(_isVertical), hasLength(2));
      expect(_maxCornerGap(_liveLines(cad)), lessThanOrEqualTo(1e-6));
      await tester.tap(find.byTooltip('Refazer'));
      await _awaitShellAction(tester, cad, commands, 'redo');
      await _waitForHistory(
        tester,
        commands,
        'reverse.sketch.dimension.create',
        'redo',
      );
      _expectRectangular(cad, expectedWidth: 60, expectedHeight: 25);

      final beforeFix = _rectangleByOrientation(cad);
      await _tapLine(tester, beforeFix.top);
      await _tapConstraint(tester, 'Fix');
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        1,
      );
      final snapped = {
        for (final line in _liveLines(cad))
          line.id: [for (final point in _endpoints(line)) (point.x, point.y)],
      };
      final parameterHistoryBefore = commands.manager.history
          .where((entry) => entry.commandId == 'reverse.sketch.parameters')
          .length;
      final dimensionEditHistoryBefore = commands.manager.history
          .where((entry) => entry.commandId == 'reverse.sketch.dimension.edit')
          .length;
      await _openPanel(tester, 'sketch-panel-tab-dimensions');
      await _editLinearDimension(tester, cad, commands, 60, 80);
      expect(
        commands.manager.history
            .where((entry) => entry.commandId == 'reverse.sketch.parameters')
            .length,
        parameterHistoryBefore,
      );
      expect(
        commands.manager.history
            .where(
              (entry) => entry.commandId == 'reverse.sketch.dimension.edit',
            )
            .length,
        dimensionEditHistoryBefore,
      );
      for (final line in _liveLines(cad)) {
        expect([
          for (final point in _endpoints(line)) (point.x, point.y),
        ], snapped[line.id]);
      }

      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(
        cad.runtime
            .read<ConstraintApi>('sketch.constraintApi')!
            .constraints
            .where((item) => item.type == SketchConstraintType.fixed),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Refazer'));
      await _awaitShellAction(tester, cad, commands, 'redo');
      expect(
        cad.runtime
            .read<ConstraintApi>('sketch.constraintApi')!
            .constraints
            .where((item) => item.type == SketchConstraintType.fixed),
        hasLength(1),
      );
      _expectRectangular(cad, expectedWidth: 60, expectedHeight: 25);

      await _awaitFuture(tester, commands.saveProject(), 'project save');
      expect(cad.message, isNot(contains('failed')));

      await _finishSketchFromWidget(tester, commands);
      await _awaitFuture(tester, commands.saveProject(), 'finished save');
      expect(_rectangleByOrientation(cad), isNotNull);
      final project = commands.projects.current!;
      await _awaitFuture(
        tester,
        commands.openProject(project),
        'project reopen',
      );
      _expectRectangular(cad, expectedWidth: 60, expectedHeight: 25);
      expect(_liveLines(cad), hasLength(4));
      expect(_liveCoincidents(cad), hasLength(4));
      expect(
        cad.runtime.document!.entities.values.where(
          (entity) =>
              entity.data['deleted'] != true &&
              entity.data['constraint'] is Map &&
              {
                'horizontal',
                'vertical',
              }.contains((entity.data['constraint'] as Map)['type']),
        ),
        hasLength(4),
      );
    },
  );

  testWidgets(
    'Inspector length edits propagate across a constrained rectangle',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawRectangle(tester, cad, commands);
      await _exitRectangleTool(tester);

      var rectangle = _rectangleByOrientation(cad);
      await _tapLine(tester, rectangle.top);
      await _submitInspectorNumber(tester, 'Length', 40);
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.parameters',
        1,
      );
      _expectRectangular(cad, expectedWidth: 40);

      rectangle = _rectangleByOrientation(cad);
      await _tapLine(tester, rectangle.top);
      await _submitInspectorNumber(tester, 'Length', 60);
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.parameters',
        2,
      );
      _expectRectangular(cad, expectedWidth: 60);

      rectangle = _rectangleByOrientation(cad);
      final originalHeight = _lineLength(rectangle.left);
      await _tapLine(tester, rectangle.left);
      await _submitInspectorNumber(tester, 'Length', 25);
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.parameters',
        3,
      );
      _expectRectangular(cad, expectedWidth: 60, expectedHeight: 25);

      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(
        _lineLength(_rectangleByOrientation(cad).left),
        closeTo(originalHeight, 1e-6),
      );
      await tester.tap(find.byTooltip('Refazer'));
      await _awaitShellAction(tester, cad, commands, 'redo');
      _expectRectangular(cad, expectedWidth: 60, expectedHeight: 25);

      rectangle = _rectangleByOrientation(cad);
      await _tapLine(tester, rectangle.top);
      await _tapConstraint(tester, 'Fix');
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        1,
      );
      final fixedGeometry = {
        for (final line in _liveLines(cad))
          line.id: [for (final point in _endpoints(line)) (point.x, point.y)],
      };
      final parametersBeforeFixedEdit = commands.manager.history
          .where((entry) => entry.commandId == 'reverse.sketch.parameters')
          .length;
      await _tapLine(tester, rectangle.top);
      await _submitInspectorNumber(tester, 'Length', 80);
      for (var attempt = 0; attempt < 80; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        if (!commands.manager.hasPendingOperations) break;
      }
      expect(commands.manager.hasPendingOperations, isFalse);
      expect(
        commands.manager.history
            .where((entry) => entry.commandId == 'reverse.sketch.parameters')
            .length,
        parametersBeforeFixedEdit,
      );
      for (final line in _liveLines(cad)) {
        expect([
          for (final point in _endpoints(line)) (point.x, point.y),
        ], fixedGeometry[line.id]);
      }
    },
  );

  testWidgets(
    'rectangle rejects an angular dimension that conflicts with Horizontal',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawRectangle(tester, cad, commands);
      await _exitRectangleTool(tester);
      final rectangle = _rectangleByOrientation(cad);
      await _tapLine(tester, rectangle.top);
      await _openPanel(tester, 'sketch-panel-tab-dimensions');

      final angular = find.widgetWithText(OutlinedButton, 'Angular');
      await tester.ensureVisible(angular);
      await tester.tap(angular);
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      await tester.enterText(
        find.descendant(of: dialog, matching: find.byType(TextField)),
        '45',
      );
      await tester.tap(
        find.descendant(of: dialog, matching: find.text('Create')),
      );
      for (var attempt = 0; attempt < 160; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        if (!commands.manager.hasPendingOperations &&
            find.byType(AlertDialog).evaluate().isEmpty) {
          break;
        }
      }

      expect(find.byType(AlertDialog), findsNothing);
      final constraintApi = cad.runtime.read<ConstraintApi>(
        'sketch.constraintApi',
      )!;
      expect(constraintApi.constraints, hasLength(8));
      expect(constraintApi.dimensions, isEmpty);
      expect(
        commands.manager.history.where(
          (entry) =>
              entry.commandId == 'reverse.sketch.dimension.create' &&
              entry.operation == 'execute',
        ),
        isEmpty,
      );
      _expectRectangular(cad, expectedWidth: _lineLength(rectangle.top));
    },
  );

  testWidgets('failed constrained edit preserves the existing Redo command', (
    tester,
  ) async {
    await _openSketch(tester, cad, commands);
    await _drawRectangle(tester, cad, commands);
    await _exitRectangleTool(tester);

    var rectangle = _rectangleByOrientation(cad);
    await _tapLine(tester, rectangle.bottom);
    await _tapConstraint(tester, 'Fix');
    await _waitForHistoryCount(
      tester,
      commands,
      'reverse.sketch.constraint',
      1,
    );

    final independent = cad.runtime
        .read<SketchEngineApi>('sketch.api')!
        .builders
        .line
        .build(const SketchVector(100, 100), const SketchVector(105, 107));
    await _awaitFuture(
      tester,
      commands.dispatch('reverse.sketch.parameters', {
        'id': independent.id,
        'values': {'length': 5},
      }),
      'setup parameter edit',
    );
    expect(
      cad.runtime
          .read<SketchEngineApi>('sketch.api')!
          .entity(independent.id)!
          .parameters['length'],
      closeTo(5, 1e-6),
    );

    await tester.tap(find.byTooltip('Desfazer'));
    await _awaitShellAction(tester, cad, commands, 'undo');
    await _waitForHistory(
      tester,
      commands,
      'reverse.sketch.parameters',
      'undo',
    );
    expect(
      cad.runtime
          .read<SketchEngineApi>('sketch.api')!
          .entity(independent.id)!
          .parameters['length'],
      isNot(closeTo(5, 1e-6)),
    );

    rectangle = _rectangleByOrientation(cad);
    await _tapLine(tester, rectangle.top);
    await _submitInspectorNumber(tester, 'Length', 60);
    for (var attempt = 0; attempt < 80; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (!commands.manager.hasPendingOperations) break;
    }
    expect(commands.manager.hasPendingOperations, isFalse);
    expect(
      commands.manager.history.where(
        (entry) =>
            entry.commandId == 'reverse.sketch.parameters' &&
            entry.operation == 'execute',
      ),
      hasLength(1),
    );

    await tester.tap(find.byTooltip('Refazer'));
    await _awaitShellAction(tester, cad, commands, 'redo');
    await _waitForHistory(
      tester,
      commands,
      'reverse.sketch.parameters',
      'redo',
    );
    expect(
      cad.runtime
          .read<SketchEngineApi>('sketch.api')!
          .entity(independent.id)!
          .parameters['length'],
      closeTo(5, 1e-6),
    );
    _expectRectangular(cad, expectedWidth: _lineLength(rectangle.top));
  });

  testWidgets(
    'two Sketches alternate through the tree without residual viewport geometry',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawRectangle(tester, cad, commands);
      final first = _sketchRoot(cad);
      final firstLineIds = _childrenOf(cad, first.id)
          .where((entity) => entity.data['sketchEntity'] is Map)
          .map((entity) => entity.id)
          .toSet();

      await _finishSketchFromWidget(tester, commands);
      await _openNewSketchFromWidget(tester, cad, commands);
      await _drawRectangle(tester, cad, commands);
      final activeSecond = cad.runtime.read<Sketch>('sketch.active')!;
      final second = cad.runtime.document!.entities[activeSecond.id]!;
      expect(second.id, isNot(first.id));
      final secondLineIds = _childrenOf(cad, second.id)
          .where((entity) => entity.data['sketchEntity'] is Map)
          .map((entity) => entity.id)
          .toSet();
      expect(secondLineIds, hasLength(4));
      expect(firstLineIds, hasLength(4));

      for (final id in firstLineIds) {
        expect(cad.runtime.scene.find(id)?.visible, isFalse, reason: id);
      }
      for (final id in secondLineIds) {
        expect(cad.runtime.scene.find(id)?.visible, isTrue, reason: id);
      }

      await _reopenSketchFromTree(tester, name: first.data['name'] as String);
      expect(
        cad.runtime.selection,
        contains(first.id),
        reason:
            'selection=${cad.runtime.selection} active=${cad.runtime.read<Sketch>('sketch.active')?.id} status=${cad.message}',
      );
      for (final id in firstLineIds) {
        expect(cad.runtime.scene.find(id)?.visible, isTrue, reason: id);
      }
      for (final id in secondLineIds) {
        expect(
          cad.runtime.scene.find(id)?.visible,
          isFalse,
          reason:
              '$id active=${cad.runtime.read<Object>('sketch.isolation.activeId')} hidden=${cad.runtime.read<Object>('sketch.isolation.hiddenCount')}',
        );
      }

      await _reopenSketchFromTree(tester, name: second.data['name'] as String);
      expect(cad.runtime.selection, contains(second.id));
      for (final id in secondLineIds) {
        expect(cad.runtime.scene.find(id)?.visible, isTrue, reason: id);
      }
    },
  );

  testWidgets(
    'an opening larger than the gap band is not reported as zero gaps passing',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(tester);
      await _settle(tester);
      expect(find.text('0 gaps in active profile'), findsNothing);
      expect(find.textContaining('extremidades abertas'), findsOneWidget);
    },
  );

  testWidgets(
    'parallel distance is created from two viewport lines and edited by the solver',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawRectangle(tester, cad, commands);
      await _exitRectangleTool(tester);
      final lines = _liveLines(cad);
      final horizontal = lines.where(_isHorizontal).toList();
      expect(horizontal, hasLength(2));
      await _openPanel(tester, 'sketch-panel-tab-dimensions');
      await tester.ensureVisible(find.text('Distância entre linhas'));
      await tester.tap(find.text('Distância entre linhas'));
      await _settle(tester);
      await _tapLine(tester, horizontal[0]);
      await _tapLine(tester, horizontal[1]);
      await tester.tap(find.text('Definir cota'));
      await _settle(tester);
      expect(find.text('Distância perpendicular entre linhas'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '4');
      await tester.tap(find.text('Aplicar'));
      await _waitForHistory(
        tester,
        commands,
        'reverse.sketch.dimension.create',
        'execute',
      );
      expect(
        _parallelSeparation(_liveLines(cad).where(_isHorizontal).toList()),
        closeTo(4, 1e-4),
      );
      expect(_maxCornerGap(_liveLines(cad)), lessThanOrEqualTo(1e-6));
      expect(_visibleText(tester).any(_uuid.hasMatch), isFalse);
    },
  );

  testWidgets(
    'perpendicular and point coincidence remain valid through widget callbacks',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.3, .4),
        end: const Offset(.7, .4),
      );
      await _waitForHistoryCount(tester, commands, 'reverse.sketch.draw', 1);
      await _drawOpenLine(
        tester,
        start: const Offset(.55, .3),
        end: const Offset(.55, .7),
      );
      await _waitForHistoryCount(tester, commands, 'reverse.sketch.draw', 2);
      final lines = _liveLines(cad);
      final horizontal = lines.singleWhere(_isHorizontal);
      final vertical = lines.singleWhere(_isVertical);
      // The desktop callback treats a plain viewport pick as a replacement
      // selection; the second entity must use the same controller callback
      // with additive=true (the production UI gets this from Ctrl-click).
      final foundation =
          tester.widget(
                find.byWidgetPredicate(
                  (widget) =>
                      widget.runtimeType.toString() ==
                      '_SketchWorkspaceFoundation',
                ),
              )
              as dynamic;
      final sketchController = foundation.controller;
      sketchController.selectSketchEntity(horizontal.id);
      sketchController.selectSketchEntity(vertical.id, additive: true);
      await _settle(tester);
      expect(
        sketchController.selectedSketchEntityIds,
        containsAll(<String>{horizontal.id, vertical.id}),
      );
      sketchController.applyConstraint(SketchConstraintType.perpendicular);
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        1,
      );

      final beforeGeometryLines = _liveLines(cad);
      final beforeHorizontal = beforeGeometryLines.singleWhere(
        (line) => line.id == horizontal.id,
      );
      final beforeVertical = beforeGeometryLines.singleWhere(
        (line) => line.id == vertical.id,
      );
      final beforeCoincident = _lineVectors(beforeHorizontal, beforeVertical);
      final beforeHorizontalEndpoints = _endpoints(beforeHorizontal);
      _expectPerpendicular(beforeCoincident.$1, beforeCoincident.$2);
      final beforeConstraints = cad.runtime.read<ConstraintApi>(
        'sketch.constraintApi',
      )!;
      expect(
        beforeConstraints.constraints.where(
          (item) => item.type == SketchConstraintType.perpendicular,
        ),
        hasLength(1),
      );

      sketchController.beginSketchPointReferenceCapture('coincident');
      await _settle(tester);
      final viewport = find.byType(IntegratedCadViewportWidget);
      final view = tester.widget<IntegratedCadViewportWidget>(viewport);
      expect(view.onSketchEntityPick, isNotNull);
      final horizontalEnd = _endpoints(beforeHorizontal).last;
      final verticalEnd = _endpoints(beforeVertical).last;
      await tester.runAsync(() async {
        view.onSketchEntityPick!(_endpointPick(horizontal, horizontalEnd));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        view.onSketchEntityPick!(_endpointPick(vertical, verticalEnd));
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      sketchController.confirmSketchPointReferenceCapture();
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        2,
      );

      final solvedLines = _liveLines(cad);
      final solvedHorizontal = solvedLines.singleWhere(
        (line) => line.id == horizontal.id,
      );
      final solvedVertical = solvedLines.singleWhere(
        (line) => line.id == vertical.id,
      );
      final after = _lineVectors(solvedHorizontal, solvedVertical);
      _expectPerpendicular(after.$1, after.$2);
      final horizontalDelta =
          _endpoints(solvedHorizontal).first - beforeHorizontalEndpoints.first;
      final targetDelta = after.$2 - beforeCoincident.$2;
      expect(horizontalDelta.dot(horizontalDelta), lessThanOrEqualTo(1e-12));
      expect(targetDelta.dot(targetDelta), lessThanOrEqualTo(1e-12));
      final coincident =
          _endpoints(solvedHorizontal).last - _endpoints(solvedVertical).last;
      final constraints = cad.runtime.read<ConstraintApi>(
        'sketch.constraintApi',
      )!;
      expect(
        coincident.dot(coincident),
        lessThanOrEqualTo(1e-12),
        reason:
            'h=${solvedHorizontal.data['sceneGeometry']} '
            'v=${solvedVertical.data['sceneGeometry']} '
            'engineH=${cad.runtime.read<SketchEngineApi>('sketch.api')?.entity(horizontal.id)?.parameters} '
            'engineV=${cad.runtime.read<SketchEngineApi>('sketch.api')?.entity(vertical.id)?.parameters} '
            'refs=${constraints.constraints.map((item) => '${item.type}:${item.references}').join('|')}',
      );
      expect(
        constraints.constraints.where(
          (item) => item.type == SketchConstraintType.perpendicular,
        ),
        hasLength(1),
      );
      expect(
        constraints.constraints.where(
          (item) => item.type == SketchConstraintType.coincident,
        ),
        hasLength(1),
      );
      expect(constraints.constraints.every((item) => item.enabled), isTrue);
    },
  );

  testWidgets(
    'inverted endpoint selection keeps the first line fixed and translates the second',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.3, .35),
        end: const Offset(.5, .45),
      );
      await _waitForHistoryCount(tester, commands, 'reverse.sketch.draw', 1);
      await _drawOpenLine(
        tester,
        start: const Offset(.65, .55),
        end: const Offset(.85, .65),
      );
      await _waitForHistoryCount(tester, commands, 'reverse.sketch.draw', 2);
      final lines = _liveLines(cad);
      expect(lines, hasLength(2));
      final first = lines[0];
      final second = lines[1];
      final firstBefore = _endpoints(first);
      final secondBefore = _endpoints(second);
      final firstDirection = firstBefore.last - firstBefore.first;
      final secondDirection = secondBefore.last - secondBefore.first;
      final foundation =
          tester.widget(
                find.byWidgetPredicate(
                  (widget) =>
                      widget.runtimeType.toString() ==
                      '_SketchWorkspaceFoundation',
                ),
              )
              as dynamic;
      final controller = foundation.controller;
      controller.beginSketchPointReferenceCapture('coincident');
      await _settle(tester);
      final viewport = find.byType(IntegratedCadViewportWidget);
      final view = tester.widget<IntegratedCadViewportWidget>(viewport);
      await tester.runAsync(() async {
        // Inverted order: the second line is the trusted anchor and the
        // first line is the entity that must be translated.
        view.onSketchEntityPick!(_endpointPick(second, secondBefore.last));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        view.onSketchEntityPick!(_endpointPick(first, firstBefore.first));
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      controller.confirmSketchPointReferenceCapture();
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        1,
      );
      final solved = _liveLines(cad);
      final solvedFirst = solved.singleWhere((line) => line.id == first.id);
      final solvedSecond = solved.singleWhere((line) => line.id == second.id);
      final firstAfter = _endpoints(solvedFirst);
      final secondAfter = _endpoints(solvedSecond);
      final firstAfterDirection = firstAfter.last - firstAfter.first;
      final secondAfterDirection = secondAfter.last - secondAfter.first;
      expect(
        (secondAfter.first - secondBefore.first).dot(
          secondAfter.first - secondBefore.first,
        ),
        lessThanOrEqualTo(1e-12),
      );
      expect(
        (firstAfterDirection - firstDirection).dot(
          firstAfterDirection - firstDirection,
        ),
        lessThanOrEqualTo(1e-12),
      );
      expect(
        (secondAfterDirection - secondDirection).dot(
          secondAfterDirection - secondDirection,
        ),
        lessThanOrEqualTo(1e-12),
      );
      expect(
        (firstAfter.first - secondAfter.last).dot(
          firstAfter.first - secondAfter.last,
        ),
        lessThanOrEqualTo(1e-12),
      );
    },
  );

  testWidgets('sketch, constraints and dimensions are separate panels', (
    tester,
  ) async {
    await _openSketch(tester, cad, commands);
    expect(
      find.byKey(const ValueKey('sketch-panel-tab-sketch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sketch-panel-tab-constraints')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sketch-panel-tab-dimensions')),
      findsOneWidget,
    );
    await _openPanel(tester, 'sketch-panel-tab-constraints');
    expect(
      find.text('Horizontal'),
      findsOneWidget,
      reason: _visibleText(tester).join(' | '),
    );
    expect(find.text('Rectangle · Two Corners'), findsNothing);
    await _openPanel(tester, 'sketch-panel-tab-dimensions');
    expect(find.textContaining('Dist'), findsOneWidget);
    expect(find.text('Horizontal'), findsNothing);
  });

  testWidgets('constraint references shown to the operator are not UUIDs', (
    tester,
  ) async {
    await _openSketch(tester, cad, commands);
    await _drawRectangle(tester, cad, commands);
    await _openPanel(tester, 'sketch-panel-tab-constraints');
    final visible = _visibleText(tester).join('\n');
    expect(visible.contains('Constraints'), isTrue);
    expect(_uuid.hasMatch(visible), isFalse);
  });

  testWidgets(
    'Fillet preview Confirm persists an arc through the real button callback',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.30, .46),
        end: const Offset(.52, .46),
      );
      await _drawOpenLine(
        tester,
        start: const Offset(.52, .46),
        end: const Offset(.52, .68),
      );
      final controller = _sketchController(tester);
      final before = _engineLines(cad).length;
      expect(before, 2);
      final lineBeforeFillet = _engineLines(
        cad,
      ).map(_parameterSnapshot).toList(growable: false);
      final constraintApi = cad.runtime.read<ConstraintApi>(
        'sketch.constraintApi',
      )!;
      final constrainedLines = _engineLines(cad);
      constraintApi.builders.horizontal.build([constrainedLines[0].id]);
      constraintApi.builders.vertical.build([constrainedLines[1].id]);
      final constraintSolve = await constraintApi.solve();
      expect(constraintSolve.success, isTrue);

      controller.beginSketchEditingTool(SketchToolType.fillet);
      await _settle(tester);
      await _openPanel(tester, 'sketch-panel-tab-sketch');
      controller.setSketchEditingValue(5.0);
      await _settle(tester);

      final lines = _liveLines(cad);
      expect(lines, hasLength(2));
      await _tapLine(tester, lines[0]);
      await _tapLine(tester, lines[1]);
      expect(cad.runtime.scene.find('sketch-edit-preview'), isNotNull);

      final confirm = find.widgetWithText(FilledButton, 'Confirm');
      expect(confirm, findsOneWidget);
      final confirmButton = tester.widget<FilledButton>(confirm);
      expect(confirmButton.onPressed, isNotNull);
      confirmButton.onPressed!();
      await _waitForHistory(tester, commands, 'reverse.sketch.edit', 'execute');
      await _settle(tester);

      final arcs = cad.runtime
          .read<SketchEngineApi>('sketch.api')!
          .engine
          .entities
          .values
          .whereType<SketchArc>()
          .toList(growable: false);
      expect(arcs, hasLength(1), reason: 'Confirm did not persist the fillet');
      expect(arcs.single.parameters['radius'], closeTo(5, 1e-8));
      expect(_engineLines(cad), hasLength(2));
      final filletResidual = _filletResiduals(cad);
      expect(filletResidual.maxEndpointGap, lessThanOrEqualTo(1e-8));
      expect(filletResidual.maxTangencyResidual, lessThanOrEqualTo(1e-8));
      expect(filletResidual.sweep, closeTo(math.pi / 2, 1e-8));
      expect(filletResidual.sweep, lessThan(math.pi));
      final arcScene = cad.runtime.scene.find(arcs.single.id);
      final arcDocument = cad.runtime.document!.entities[arcs.single.id];
      expect(
        arcScene,
        isNotNull,
        reason: 'fillet ${arcs.single.id} left the viewport',
      );
      expect(
        arcScene!.visible,
        isTrue,
        reason: 'fillet ${arcs.single.id} is persisted but hidden',
      );
      expect(arcDocument?.data['sceneVisible'], isNot(false));
      final arcPoints = arcScene.geometry['points'] as List;
      expect(arcPoints.length, greaterThanOrEqualTo(3));
      final healthIssues = controller.sketchHealth.issues
          .map((issue) => issue.type.toString())
          .toList(growable: false);
      expect(
        healthIssues.where(
          (name) => name.endsWith('.gap') || name.endsWith('.disconnected'),
        ),
        isEmpty,
        reason: healthIssues.join(' | '),
      );
      expect(
        constraintApi.constraints
            .where((item) => item.type == SketchConstraintType.horizontal)
            .single
            .status,
        ConstraintStatus.satisfied,
      );
      expect(
        constraintApi.constraints
            .where((item) => item.type == SketchConstraintType.vertical)
            .single
            .status,
        ConstraintStatus.satisfied,
      );
      expect(cad.runtime.scene.find('sketch-edit-preview'), isNull);
      expect(controller.error, isNull, reason: '${controller.error}');

      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(
        cad.runtime
            .read<SketchEngineApi>('sketch.api')!
            .engine
            .entities
            .values
            .whereType<SketchArc>(),
        isEmpty,
      );
      expect(_engineLines(cad).map(_parameterSnapshot), lineBeforeFillet);

      await tester.tap(find.byTooltip('Refazer'));
      await _awaitShellAction(tester, cad, commands, 'redo');
      final restored = cad.runtime
          .read<SketchEngineApi>('sketch.api')!
          .engine
          .entities
          .values
          .whereType<SketchArc>()
          .toList(growable: false);
      expect(restored, hasLength(1));
      expect(cad.runtime.scene.find(restored.single.id)?.visible, isTrue);
      expect(_filletResiduals(cad).sweep, closeTo(math.pi / 2, 1e-8));
      await _awaitFuture(tester, commands.saveProject(), 'fillet save');
      await _finishSketchFromWidget(tester, commands);
      await _awaitFuture(
        tester,
        commands.saveProject(),
        'finished fillet save',
      );
      final project = commands.projects.current!;
      await _awaitFuture(
        tester,
        commands.openProject(project),
        'fillet project reopen',
      );
      final reopenedArcs = cad.runtime.document!.entities.values.where(
        (entity) =>
            entity.data['deleted'] != true &&
            entity.data['sketchEntity'] is Map &&
            (entity.data['sketchEntity'] as Map)['type'] == 'arc',
      );
      expect(reopenedArcs, hasLength(1));
      final reopened = reopenedArcs.single;
      expect(reopened.data['sceneVisible'], isNot(false));
      final reopenedParameters =
          (reopened.data['sketchEntity'] as Map)['parameters'] as Map;
      final reopenedSweep =
          ((reopenedParameters['endAngle'] as num) -
                  (reopenedParameters['startAngle'] as num))
              .abs();
      expect(reopenedSweep, closeTo(math.pi / 2, 1e-8));
      expect(cad.runtime.scene.find(reopened.id)?.visible, isNot(false));
    },
  );

  testWidgets(
    'Fillet accepts another radius and preserves source lines with Automatic Trim off',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.30, .46),
        end: const Offset(.52, .46),
      );
      await _drawOpenLine(
        tester,
        start: const Offset(.52, .46),
        end: const Offset(.52, .68),
      );
      final controller = _sketchController(tester);
      final before = _engineLines(cad).map(_parameterSnapshot).toList();
      controller.beginSketchEditingTool(SketchToolType.fillet);
      await _settle(tester);
      await _openPanel(tester, 'sketch-panel-tab-sketch');
      controller.setSketchEditingValue(7.5);
      controller.setSketchFilletAutoTrim(false);
      await _settle(tester);
      final lines = _liveLines(cad);
      await _tapLine(tester, lines[0]);
      await _tapLine(tester, lines[1]);
      final confirm = find.widgetWithText(FilledButton, 'Confirm');
      expect(confirm, findsOneWidget);
      tester.widget<FilledButton>(confirm).onPressed!();
      await _waitForHistory(tester, commands, 'reverse.sketch.edit', 'execute');
      await _settle(tester);
      final arc = _engineArc(cad);
      expect(arc.parameters['radius'], closeTo(7.5, 1e-8));
      expect(cad.runtime.scene.find(arc.id)?.visible, isTrue);
      expect(_filletResiduals(cad).sweep, closeTo(math.pi / 2, 1e-8));
      expect(_engineLines(cad).map(_parameterSnapshot), before);
      expect(cad.runtime.scene.find('sketch-edit-preview'), isNull);
      expect(controller.error, isNull, reason: '${controller.error}');
    },
  );

  testWidgets(
    'Fillet Confirm reports an excessive radius and rolls back atomically',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.30, .46),
        end: const Offset(.52, .46),
      );
      await _drawOpenLine(
        tester,
        start: const Offset(.52, .46),
        end: const Offset(.52, .68),
      );
      final controller = _sketchController(tester);
      final before = _engineLines(
        cad,
      ).map(_parameterSnapshot).toList(growable: false);
      controller.beginSketchEditingTool(SketchToolType.fillet);
      await _settle(tester);
      controller.setSketchEditingValue(1000.0);
      await _settle(tester);
      final lines = _liveLines(cad);
      await _tapLine(tester, lines[0]);
      await _tapLine(tester, lines[1]);

      final confirm = find.widgetWithText(FilledButton, 'Confirm');
      final confirmButton = tester.widget<FilledButton>(confirm);
      expect(confirmButton.onPressed, isNotNull);
      confirmButton.onPressed!();
      for (var attempt = 0; attempt < 160; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        if (controller.busy != true && !commands.manager.hasPendingOperations) {
          break;
        }
      }
      await _settle(tester);

      expect(
        controller.sketchEditingDiagnostic,
        isNotNull,
        reason: 'controllerError=${controller.error}',
      );
      expect(
        cad.runtime
            .read<SketchEngineApi>('sketch.api')!
            .engine
            .entities
            .values
            .whereType<SketchArc>(),
        isEmpty,
      );
      expect(_engineLines(cad).map(_parameterSnapshot), before);
      expect(cad.runtime.scene.find('sketch-edit-preview'), isNull);
      expect(commands.manager.hasPendingOperations, isFalse);
    },
  );

  testWidgets(
    'Fillet Confirm reports FIX conflict without changing the Sketch',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.30, .46),
        end: const Offset(.52, .46),
      );
      await _drawOpenLine(
        tester,
        start: const Offset(.52, .46),
        end: const Offset(.52, .68),
      );
      final controller = _sketchController(tester);
      final fixedLine = _liveLines(cad).first;
      controller.selectSketchEntity(fixedLine.id);
      await _tapConstraint(tester, 'Fix');
      expect(controller.error, isNull, reason: '${controller.error}');
      // Start the corner command with a clean entity selection; the Fix
      // command may leave its source selected in the constraint panel.
      controller.selectedSketchEntityIds.clear();
      controller.runtime.select(const <String>{});
      await _settle(tester);
      final before = _engineLines(
        cad,
      ).map(_parameterSnapshot).toList(growable: false);

      controller.beginSketchEditingTool(SketchToolType.fillet);
      await _settle(tester);
      await _openPanel(tester, 'sketch-panel-tab-sketch');
      controller.setSketchEditingValue(5.0);
      await _settle(tester);
      final lines = _liveLines(cad);
      await _tapLine(tester, lines[0]);
      await _tapLine(tester, lines[1]);
      // A locked source is intentionally not pickable by the normal geometry
      // hit-test; preserve the real two-entity command path by adding the
      // already identified fixed source to the viewport selection.
      controller.selectSketchEntity(fixedLine.id, additive: true);
      controller.selectSketchEntity(lines[0].id);
      controller.selectSketchEntity(lines[1].id, additive: true);
      await _settle(tester);
      expect(controller.sketchEditingCommandActive, isTrue);
      expect(controller.selectedSketchEntityIds, hasLength(2));
      expect(find.text('Confirm'), findsOneWidget);
      final confirm = find.widgetWithText(FilledButton, 'Confirm');
      final confirmButton = tester.widget<FilledButton>(confirm);
      expect(confirmButton.onPressed, isNotNull);
      confirmButton.onPressed!();
      // The locked source is deliberately excluded from the viewport hit-test,
      // so this fixture reaches the same controller callback used by Confirm
      // after the real widget selection/preview path above.
      for (var attempt = 0; attempt < 160; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        if (controller.busy != true && !commands.manager.hasPendingOperations) {
          break;
        }
      }
      await _settle(tester);

      expect(
        controller.sketchEditingDiagnostic,
        isNotNull,
        reason: 'FIX rejection was silent; controllerError=${controller.error}',
      );
      expect(_engineLines(cad).map(_parameterSnapshot), before);
      expect(
        cad.runtime
            .read<SketchEngineApi>('sketch.api')!
            .engine
            .entities
            .values
            .whereType<SketchArc>(),
        isEmpty,
      );
      expect(cad.runtime.scene.find('sketch-edit-preview'), isNull);
    },
  );

  testWidgets(
    'Fillet Confirm rejects a driving dimension instead of trimming the line',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.30, .46),
        end: const Offset(.52, .46),
      );
      await _drawOpenLine(
        tester,
        start: const Offset(.52, .46),
        end: const Offset(.52, .68),
      );
      final activeLine = find.text('Line · ativo');
      if (activeLine.evaluate().isNotEmpty) {
        final button = find.ancestor(
          of: activeLine,
          matching: find.byType(FilledButton),
        );
        expect(button, findsOneWidget);
        tester.widget<FilledButton>(button).onPressed!();
        await _settle(tester);
      }
      final controller = _sketchController(tester);
      final drawn = _liveLines(cad);
      expect(drawn, hasLength(2));
      final dimensioned = drawn.first;
      final drivenLength = _lineLength(dimensioned);
      expect(drivenLength, greaterThan(5));
      await _openPanel(tester, 'sketch-panel-tab-dimensions');
      await _tapLine(tester, dimensioned);
      await _createLinearDimension(tester, cad, commands, drivenLength, 1);

      final api = cad.runtime.read<ConstraintApi>('sketch.constraintApi')!;
      final dimension = api.dimensions.single;
      final dimensionValue = dimension.value;
      final dimensionId = dimension.id;
      final constraintId = dimension.constraintId;
      final references = List<String>.from(dimension.references);
      expect(references, [dimensioned.id]);
      expect(dimensionValue, closeTo(drivenLength, 1e-6));
      expect(
        _lineLength(
          _liveLines(cad).singleWhere((line) => line.id == dimensioned.id),
        ),
        closeTo(dimensionValue, 1e-6),
      );
      final lineIds = _engineLines(cad).map((line) => line.id).toList();
      final geometryBefore = _engineLines(
        cad,
      ).map(_parameterSnapshot).toList(growable: false);
      final constraintsBefore = api.constraints
          .map(
            (item) =>
                '${item.id}|${item.type.name}|${item.value}|${item.status.name}|${item.references.join(',')}',
          )
          .toList(growable: false);
      final relationsBefore = api.constraints
          .where(
            (item) =>
                item.type == SketchConstraintType.coincident ||
                item.type == SketchConstraintType.tangent,
          )
          .map((item) => '${item.id}|${item.status.name}')
          .toList(growable: false);
      final historyBefore = commands.manager.history
          .map((entry) => '${entry.commandId}:${entry.operation}')
          .toList(growable: false);
      final revisionBefore = cad.runtime.document!.revision;
      final editExecutions = historyBefore
          .where((entry) => entry == 'reverse.sketch.edit:execute')
          .length;

      controller.beginSketchEditingTool(SketchToolType.fillet);
      await _settle(tester);
      await _openPanel(tester, 'sketch-panel-tab-sketch');
      controller.setSketchEditingValue(5.0);
      await _settle(tester);
      final trim = find.widgetWithText(SwitchListTile, 'Automatic Trim');
      expect(trim, findsOneWidget);
      final trimSwitch = tester.widget<SwitchListTile>(trim);
      expect(trimSwitch.value, isTrue);
      expect(controller.sketchFilletAutoTrim, isTrue);
      final lines = _liveLines(cad);
      await _tapLine(tester, lines[0]);
      await _tapLine(tester, lines[1]);
      expect(cad.runtime.scene.find('sketch-edit-preview'), isNotNull);
      final confirm = find.widgetWithText(FilledButton, 'Confirm');
      expect(confirm, findsOneWidget);
      final confirmButton = tester.widget<FilledButton>(confirm);
      expect(confirmButton.onPressed, isNotNull);
      confirmButton.onPressed!();
      for (var attempt = 0; attempt < 160; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        if (controller.busy != true && !commands.manager.hasPendingOperations) {
          break;
        }
      }
      await _settle(tester);

      expect(
        controller.sketchEditingDiagnostic,
        contains('incompatible with driving dimension $dimensionId'),
      );
      expect(
        cad.runtime
            .read<SketchEngineApi>('sketch.api')!
            .engine
            .entities
            .values
            .whereType<SketchArc>(),
        isEmpty,
      );
      expect(_engineLines(cad).map((line) => line.id), lineIds);
      expect(_engineLines(cad).map(_parameterSnapshot), geometryBefore);
      final preserved = api.dimensions.single;
      expect(preserved.id, dimensionId);
      expect(preserved.constraintId, constraintId);
      expect(preserved.value, dimensionValue);
      expect(preserved.references, references);
      expect(
        api.constraints.map(
          (item) =>
              '${item.id}|${item.type.name}|${item.value}|${item.status.name}|${item.references.join(',')}',
        ),
        constraintsBefore,
      );
      expect(
        api.constraints
            .where(
              (item) =>
                  item.type == SketchConstraintType.coincident ||
                  item.type == SketchConstraintType.tangent,
            )
            .map((item) => '${item.id}|${item.status.name}'),
        relationsBefore,
      );
      expect(
        commands.manager.history.map(
          (entry) => '${entry.commandId}:${entry.operation}',
        ),
        historyBefore,
      );
      expect(
        commands.manager.history
            .where(
              (entry) =>
                  entry.commandId == 'reverse.sketch.edit' &&
                  entry.operation == 'execute',
            )
            .length,
        editExecutions,
      );
      expect(cad.runtime.document!.revision, revisionBefore);
      expect(cad.runtime.scene.find('sketch-edit-preview'), isNull);
      expect(commands.manager.hasPendingOperations, isFalse);

      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(api.dimensions, isEmpty);
      expect(
        cad.runtime
            .read<SketchEngineApi>('sketch.api')!
            .engine
            .entities
            .values
            .whereType<SketchArc>(),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Refazer'));
      await _awaitShellAction(tester, cad, commands, 'redo');
      final restored = api.dimensions.single;
      expect(restored.id, dimensionId);
      expect(restored.value, dimensionValue);
      expect(restored.references, references);
      expect(_engineLines(cad).map(_parameterSnapshot), geometryBefore);
      expect(
        cad.runtime
            .read<SketchEngineApi>('sketch.api')!
            .engine
            .entities
            .values
            .whereType<SketchArc>(),
        isEmpty,
      );

      await _awaitFuture(tester, commands.saveProject(), 'dimension save');
      await _finishSketchFromWidget(tester, commands);
      await _awaitFuture(
        tester,
        commands.saveProject(),
        'finished dimension save',
      );
      final project = commands.projects.current!;
      await _awaitFuture(
        tester,
        commands.openProject(project),
        'dimension project reopen',
      );
      final reopened = cad.runtime.document!.entities.values.where(
        (entity) =>
            entity.data['deleted'] != true && entity.data['dimension'] is Map,
      );
      expect(reopened, hasLength(1));
      final stored = reopened.single.data['dimension'] as Map;
      expect(stored['id'], dimensionId);
      expect(stored['value'], dimensionValue);
      expect(stored['references'], references);
      expect(stored['constraintId'], constraintId);
      expect(
        cad.runtime.document!.entities.values.where(
          (entity) =>
              entity.data['deleted'] != true &&
              entity.data['sketchEntity'] is Map &&
              (entity.data['sketchEntity'] as Map)['type'] == 'arc',
        ),
        isEmpty,
      );
      expect(
        cad.runtime.document!.entities.values.where(
          (entity) =>
              entity.data['deleted'] != true &&
              entity.data['sketchEntity'] is Map &&
              (entity.data['sketchEntity'] as Map)['type'] == 'line' &&
              lineIds.contains(entity.id),
        ),
        hasLength(2),
      );
    },
  );

  testWidgets(
    'line and arc endpoints accept tangent and coincidence together',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.28, .46),
        end: const Offset(.46, .62),
      );
      await _waitForHistoryCount(tester, commands, 'reverse.sketch.draw', 1);
      await _drawCenterArc(
        tester,
        const Offset(.62, .42),
        const Offset(.74, .42),
        const Offset(.62, .28),
      );
      await _waitForHistoryCount(tester, commands, 'reverse.sketch.draw', 2);
      final drawingArc = find.text('Drawing Arc');
      if (drawingArc.evaluate().isNotEmpty) {
        final button = find.ancestor(
          of: drawingArc,
          matching: find.byType(FilledButton),
        );
        expect(button, findsOneWidget);
        tester.widget<FilledButton>(button).onPressed!();
        await _settle(tester);
      }
      final controller = _sketchController(tester);
      final arc = _engineArc(cad);
      final line = _engineLines(cad).single;
      expect(arc.id, isNotEmpty);
      expect(line.id, isNot(arc.id));
      final scene = cad.runtime.scene.find(arc.id);
      expect(scene?.geometry['showEndpoints'], isTrue);
      final samples = scene!.geometry['points'] as List;
      expect(samples.length, greaterThanOrEqualTo(2));

      await _awaitFuture(
        tester,
        controller.updateSketchEntityParameters(line.id, {
          'startX': 0.0,
          'startY': 0.0,
          'endX': 400.0,
          'endY': 0.0,
        }),
        'place line',
      );
      await _awaitFuture(
        tester,
        controller.updateSketchEntityParameters(arc.id, {
          'centerX': 120.0,
          'centerY': 150.0,
          'radius': 90.0,
          'startAngleDegrees': -90.0,
          'endAngleDegrees': 90.0,
        }),
        'place arc',
      );
      expect(_engineArc(cad).id, arc.id);
      expect(_arcEndpoint(_engineArc(cad), 'start').x, closeTo(120, 1e-6));
      expect(_arcEndpoint(_engineArc(cad), 'start').y, closeTo(60, 1e-6));
      expect(_arcEndpoint(_engineArc(cad), 'end').y, closeTo(240, 1e-6));

      final api = cad.runtime.read<ConstraintApi>('sketch.constraintApi')!;
      for (final item
          in api.constraints
              .where(
                (item) =>
                    item.type == SketchConstraintType.horizontal ||
                    item.type == SketchConstraintType.vertical,
              )
              .toList()) {
        await controller.deleteConstraint(item.id);
        await _settle(tester);
      }

      controller.selectSketchEntity(arc.id);
      await _settle(tester);
      final fixCount = _constraintExecutions(commands);
      await _tapConstraint(tester, 'Fix');
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        fixCount + 1,
      );
      final fixedArc = _parameterSnapshot(_engineArc(cad));
      final fixedLine = _parameterSnapshot(_engineLines(cad).single);
      await _applyPointCoincidence(
        tester,
        cad,
        controller,
        lineId: line.id,
        lineEndpoint: 'end',
        arcId: arc.id,
        arcEndpoint: 'start',
      );
      expect(controller.error, isNotNull);
      expect(
        cad.runtime
            .read<ConstraintApi>('sketch.constraintApi')!
            .constraints
            .where((item) => item.type == SketchConstraintType.coincident),
        isEmpty,
      );
      expect(_parameterSnapshot(_engineArc(cad)), fixedArc);
      expect(_parameterSnapshot(_engineLines(cad).single), fixedLine);
      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(
        cad.runtime
            .read<ConstraintApi>('sketch.constraintApi')!
            .constraints
            .where((item) => item.type == SketchConstraintType.fixed),
        isEmpty,
      );

      final startCount = _constraintExecutions(commands);
      await _applyPointCoincidence(
        tester,
        cad,
        controller,
        lineId: line.id,
        lineEndpoint: 'end',
        arcId: arc.id,
        arcEndpoint: 'start',
      );
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        startCount + 1,
      );
      expect(
        _gap(cad, line.id, 'end', arc.id, 'start'),
        lessThanOrEqualTo(1e-8),
      );
      expect(_engineLines(cad).single.parameters['end'], [400.0, 0.0, 0.0]);
      final startCoincidence = cad.runtime
          .read<ConstraintApi>('sketch.constraintApi')!
          .constraints
          .singleWhere((item) => item.type == SketchConstraintType.coincident);
      expect(startCoincidence.references, [
        '${line.id}:end',
        '${arc.id}:start',
      ]);
      expect(startCoincidence.status, ConstraintStatus.satisfied);
      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');

      final invertedCount = _constraintExecutions(commands);
      await _applyPointCoincidence(
        tester,
        cad,
        controller,
        lineId: line.id,
        lineEndpoint: 'start',
        arcId: arc.id,
        arcEndpoint: 'end',
        arcFirst: true,
      );
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        invertedCount + 1,
      );
      expect(
        _gap(cad, line.id, 'start', arc.id, 'end'),
        lessThanOrEqualTo(1e-8),
      );
      expect(_engineArc(cad).parameters['center'], [120.0, 150.0, 0.0]);
      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');

      controller.selectSketchEntity(line.id);
      controller.selectSketchEntity(arc.id, additive: true);
      await _settle(tester);
      final tangentCount = _constraintExecutions(commands);
      await _tapConstraint(tester, 'Tangent');
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        tangentCount + 1,
      );
      expect(controller.error, isNull);
      expect(_engineLines(cad).single.parameters['start'], [0.0, 0.0, 0.0]);
      expect(_engineLines(cad).single.parameters['end'], [400.0, 0.0, 0.0]);
      expect(_tangentAlignment(cad, 'start'), lessThanOrEqualTo(1e-8));
      expect(_tangentDistanceResidual(cad), lessThanOrEqualTo(1e-8));
      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');

      await _awaitFuture(
        tester,
        controller.updateSketchEntityParameters(arc.id, {
          'startAngleDegrees': -180.0,
          'endAngleDegrees': 179.0,
        }),
        'widen arc',
      );
      final arcBeforeOrder = _parameterSnapshot(_engineArc(cad));
      controller.selectSketchEntity(arc.id);
      controller.selectSketchEntity(line.id, additive: true);
      await _settle(tester);
      final arcFirstCount = _constraintExecutions(commands);
      await _tapConstraint(tester, 'Tangent');
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        arcFirstCount + 1,
      );
      expect(_parameterSnapshot(_engineArc(cad)), arcBeforeOrder);
      expect(_tangentDistanceResidual(cad), lessThanOrEqualTo(1e-8));
      expect(_tangentAlignment(cad, null), lessThanOrEqualTo(1e-8));
      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(_engineArc(cad).parameters['radius'], 90);

      controller.selectSketchEntity(line.id);
      controller.selectSketchEntity(arc.id, additive: true);
      await _settle(tester);
      final pairedTangentCount = _constraintExecutions(commands);
      await _tapConstraint(tester, 'Tangent');
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        pairedTangentCount + 1,
      );
      await _applyPointCoincidence(
        tester,
        cad,
        controller,
        lineId: line.id,
        lineEndpoint: 'end',
        arcId: arc.id,
        arcEndpoint: 'end',
      );
      await _waitForHistoryCount(
        tester,
        commands,
        'reverse.sketch.constraint',
        pairedTangentCount + 2,
      );
      expect(_gap(cad, line.id, 'end', arc.id, 'end'), lessThanOrEqualTo(1e-8));
      expect(_tangentAlignment(cad, 'end'), lessThanOrEqualTo(1e-8));
      expect(_tangentDistanceResidual(cad), lessThanOrEqualTo(1e-8));
      expect(_engineLines(cad).single.parameters['end'], [400.0, 0.0, 0.0]);
      expect(_engineArc(cad).parameters['radius'], 90);
      final relations = cad.runtime.read<ConstraintApi>(
        'sketch.constraintApi',
      )!;
      expect(
        relations.constraints.map((item) => item.type).toSet(),
        containsAll([
          SketchConstraintType.tangent,
          SketchConstraintType.coincident,
        ]),
      );
      expect(
        relations.constraints.every(
          (item) => item.status == ConstraintStatus.satisfied,
        ),
        isTrue,
      );

      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(
        cad.runtime
            .read<ConstraintApi>('sketch.constraintApi')!
            .constraints
            .where((item) => item.type == SketchConstraintType.coincident),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Refazer'));
      await _awaitShellAction(tester, cad, commands, 'redo');
      expect(_gap(cad, line.id, 'end', arc.id, 'end'), lessThanOrEqualTo(1e-8));
      expect(_tangentAlignment(cad, 'end'), lessThanOrEqualTo(1e-8));

      controller.selectSketchEntity(arc.id);
      await _settle(tester);
      await _submitInspectorNumber(tester, 'Radius', 120);
      await _settle(tester);
      final confirm = find.byKey(const ValueKey('arc-radius-preview-confirm'));
      expect(
        confirm,
        findsOneWidget,
        reason: 'a constrained radius edit must request explicit confirmation',
      );
      final confirmButton = tester.widget<FilledButton>(confirm);
      expect(confirmButton.onPressed, isNotNull);
      confirmButton.onPressed!();
      for (var attempt = 0; attempt < 240; attempt++) {
        if (controller.busy != true &&
            controller.arcRadiusEditPreview == null) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
      }
      expect(controller.arcRadiusEditPreview, isNull);
      expect(controller.error, isNull, reason: '${controller.error}');
      expect(_engineArc(cad).parameters['radius'], closeTo(120, 1e-6));
      expect(_gap(cad, line.id, 'end', arc.id, 'end'), lessThanOrEqualTo(1e-8));
      expect(_tangentAlignment(cad, 'end'), lessThanOrEqualTo(1e-8));

      final lineEntity = _liveLines(
        cad,
      ).singleWhere((item) => item.id == line.id);
      final anchorBeforeDrag = List<double>.from(
        (_engineLines(cad).single.parameters['start'] as List).map(
          (value) => (value as num).toDouble(),
        ),
      );
      final viewport = find.byType(IntegratedCadViewportWidget);
      final view = tester.widget<IntegratedCadViewportWidget>(viewport);
      expect(view.onSketchEntityDragStart, isNotNull);
      expect(view.onSketchEntityDragUpdate, isNotNull);
      expect(view.onSketchEntityDragEnd, isNotNull);
      final box = tester.getRect(viewport);
      final points = _endpoints(lineEntity);
      final mid = (points.first + points.last) * .5;
      final projected = view.camera.viewProjectionMatrix.transformPoint(mid);
      final dragStart =
          box.topLeft +
          Offset(
            (projected.x + 1) * box.width / 2,
            (1 - projected.y) * box.height / 2,
          );
      final dragEnd = dragStart + const Offset(0, -70);
      view.onSketchEntityDragStart!(_endpointPick(lineEntity, mid), dragStart);
      await _settle(tester);
      expect(
        cad.runtime.read<bool>('sketch.drag.active'),
        isTrue,
        reason: 'line body drag did not start from the explicit midpoint pick',
      );
      view.onSketchEntityDragUpdate!(dragEnd);
      await _settle(tester);
      view.onSketchEntityDragEnd!(dragEnd);
      for (var attempt = 0; attempt < 80; attempt++) {
        if (!commands.manager.hasPendingOperations &&
            cad.runtime.read<bool>('sketch.drag.active') != true) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(
        commands.manager.hasPendingOperations,
        isFalse,
        reason: 'sketch drag did not finish; status=${cad.message}',
      );
      expect(_gap(cad, line.id, 'end', arc.id, 'end'), lessThanOrEqualTo(1e-6));
      expect(_tangentAlignment(cad, 'end'), lessThanOrEqualTo(1e-6));
      expect(_engineArc(cad).parameters['radius'], closeTo(120, 1e-6));
      expect(
        _engineLines(cad).single.parameters['start'],
        isNot(anchorBeforeDrag),
      );

      await _awaitFuture(tester, commands.saveProject(), 'project save');
      await _finishSketchFromWidget(tester, commands);
      await _awaitFuture(tester, commands.saveProject(), 'finished save');
      final project = commands.projects.current!;
      await _awaitFuture(
        tester,
        commands.openProject(project),
        'project reopen',
      );
      final reopenedArc = cad.runtime.document!.entities.values.firstWhere(
        (entity) =>
            entity.data['deleted'] != true &&
            entity.data['sketchEntity'] is Map &&
            (entity.data['sketchEntity'] as Map)['type'] == 'arc',
      );
      final reopened =
          (reopenedArc.data['sketchEntity'] as Map)['parameters'] as Map;
      expect((reopened['radius'] as num).toDouble(), closeTo(120, 1e-6));
      expect(
        cad.runtime.document!.entities.values.where(
          (entity) =>
              entity.data['deleted'] != true &&
              entity.data['constraint'] is Map &&
              (entity.data['constraint'] as Map)['type'] == 'coincident',
        ),
        hasLength(1),
      );
      expect(
        cad.runtime.document!.entities.values.where(
          (entity) =>
              entity.data['deleted'] != true &&
              entity.data['constraint'] is Map &&
              (entity.data['constraint'] as Map)['type'] == 'tangent',
        ),
        hasLength(1),
      );
      final stored =
          cad.runtime.document!.entities.values
                  .where(
                    (entity) =>
                        entity.data['deleted'] != true &&
                        entity.data['constraint'] is Map &&
                        (entity.data['constraint'] as Map)['type'] ==
                            'coincident',
                  )
                  .single
                  .data['constraint']
              as Map;
      expect(stored['references'], ['${line.id}:end', '${arc.id}:end']);
    },
  );

  testWidgets(
    'successive Trim turns a crossing into a T and then the clicked L',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.22, .50),
        end: const Offset(.78, .50),
      );
      await _drawOpenLine(
        tester,
        start: const Offset(.50, .28),
        end: const Offset(.50, .74),
      );
      final crossing = _crossingPair(cad);
      final horizontalId = crossing.horizontal.id;
      final verticalId = crossing.vertical.id;
      final horizontalBefore = _sceneEnds(crossing.horizontal);
      final verticalBefore = _sceneEnds(crossing.vertical);
      final junction = _lineCross(horizontalBefore, verticalBefore);
      // ignore: avoid_print
      print(
        'TRIM_TRACE crossing H $horizontalId ${_endsText(horizontalBefore)} '
        'V $verticalId ${_endsText(verticalBefore)} junction=${_xy(junction)}',
      );

      await _beginEditingTool(tester, 'Trim');
      await _tapWorldPoint(
        tester,
        _insetToward(verticalBefore, _lower(verticalBefore), .08),
      );
      await _waitForTrim(tester, commands, 1);
      final tHorizontal = _liveLine(cad, horizontalId);
      final tVertical = _liveLine(cad, verticalId);
      final tJunction = _endpointOnInterior(
        _sceneEnds(tVertical),
        _sceneEnds(tHorizontal),
      );
      expect(tJunction, isNotNull, reason: _traceLines(cad));
      expect(
        _samePointSet(_sceneEnds(tHorizontal), horizontalBefore),
        isTrue,
        reason: _traceLines(cad),
      );
      expect(
        _sceneEnds(tVertical).where((point) => point.y < junction.y - 1e-4),
        isEmpty,
        reason: 'the lower vertical portion must be gone: ${_traceLines(cad)}',
      );
      expect(_liveLines(cad), hasLength(2));
      // ignore: avoid_print
      print('TRIM_TRACE T ${_traceLines(cad)} junction=${_xy(junction)}');

      final left = _farEnd(_sceneEnds(tHorizontal), junction, smallerX: true);
      await _tapWorldPoint(tester, _mix(left, junction, .5));
      await _waitForTrim(tester, commands, 2);
      final lHorizontal = _sceneEnds(_liveLine(cad, horizontalId));
      final lVertical = _sceneEnds(_liveLine(cad, verticalId));
      expect(_hasEnd(lHorizontal, junction), isTrue, reason: _traceLines(cad));
      expect(
        _hasEnd(lHorizontal, left),
        isFalse,
        reason: 'the clicked left portion must be removed',
      );
      expect(
        _hasEnd(
          lHorizontal,
          _farEnd(horizontalBefore, junction, smallerX: false),
        ),
        isTrue,
      );
      expect(_samePointSet(lVertical, _sceneEnds(tVertical)), isTrue);
      expect(_liveLines(cad), hasLength(2));
      expect(_sketchController(tester).error, isNull);
      // ignore: avoid_print
      print(
        'TRIM_TRACE L-left ${_traceLines(cad)} selectedLeft=${_xy(_mix(left, junction, .5))}',
      );

      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(
        _samePointSet(
          _sceneEnds(_liveLine(cad, horizontalId)),
          horizontalBefore,
        ),
        isTrue,
        reason: 'undo must restore only the second cut',
      );
      expect(
        _endpointOnInterior(
          _sceneEnds(_liveLine(cad, verticalId)),
          _sceneEnds(_liveLine(cad, horizontalId)),
        ),
        isNotNull,
      );
      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(
        _samePointSet(_sceneEnds(_liveLine(cad, verticalId)), verticalBefore),
        isTrue,
        reason: 'undo must restore the first cut separately',
      );

      await tester.tap(find.byTooltip('Refazer'));
      await _awaitShellAction(tester, cad, commands, 'redo');
      expect(
        _endpointOnInterior(
          _sceneEnds(_liveLine(cad, verticalId)),
          _sceneEnds(_liveLine(cad, horizontalId)),
        ),
        isNotNull,
      );
      await tester.tap(find.byTooltip('Refazer'));
      await _awaitShellAction(tester, cad, commands, 'redo');
      expect(
        _hasEnd(_sceneEnds(_liveLine(cad, horizontalId)), junction),
        isTrue,
      );
      expect(_liveLines(cad), hasLength(2));

      await _awaitFuture(tester, commands.saveProject(), 'trim save');
      await _finishSketchFromWidget(tester, commands);
      await _awaitFuture(tester, commands.saveProject(), 'finished trim save');
      final project = commands.projects.current!;
      await _awaitFuture(tester, commands.openProject(project), 'trim reopen');
      final reopened = _liveLines(cad);
      expect(reopened, hasLength(2));
      final reopenedHorizontal = _liveLine(cad, horizontalId);
      final reopenedVertical = _liveLine(cad, verticalId);
      expect(
        _hasEnd(_sceneEnds(reopenedHorizontal), junction),
        isTrue,
        reason:
            'reopened H ${_endsText(_sceneEnds(reopenedHorizontal))} '
            'V ${_endsText(_sceneEnds(reopenedVertical))}',
      );
      expect(
        _samePointSet(_sceneEnds(reopenedVertical), lVertical),
        isTrue,
        reason:
            'reopened V ${_endsText(_sceneEnds(reopenedVertical))} '
            'expected ${_endsText(lVertical)}',
      );
    },
  );

  testWidgets(
    'T-junction Trim removes the right portion in either click order',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.22, .50),
        end: const Offset(.78, .50),
      );
      await _drawOpenLine(
        tester,
        start: const Offset(.50, .28),
        end: const Offset(.50, .74),
      );
      final crossing = _crossingPair(cad);
      final horizontalId = crossing.horizontal.id;
      final verticalId = crossing.vertical.id;
      await _beginEditingTool(tester, 'Trim');
      await _tapWorldPoint(
        tester,
        _insetToward(
          _sceneEnds(crossing.vertical),
          _lower(_sceneEnds(crossing.vertical)),
          .08,
        ),
      );
      await _waitForTrim(tester, commands, 1);
      final junction = _endpointOnInterior(
        _sceneEnds(_liveLine(cad, verticalId)),
        _sceneEnds(_liveLine(cad, horizontalId)),
      );
      expect(junction, isNotNull, reason: _traceLines(cad));
      final right = _farEnd(
        _sceneEnds(_liveLine(cad, horizontalId)),
        junction!,
        smallerX: false,
      );
      final verticalEnds = _sceneEnds(_liveLine(cad, verticalId));

      await _tapWorldPoint(tester, _mix(verticalEnds[0], verticalEnds[1], .55));
      await _tapWorldPoint(tester, _mix(right, junction, .45));
      await _waitForTrim(tester, commands, 2);
      expect(
        _hasEnd(_sceneEnds(_liveLine(cad, horizontalId)), right),
        isFalse,
        reason: 'vertical-first then right portion: ${_traceLines(cad)}',
      );
      expect(
        _hasEnd(_sceneEnds(_liveLine(cad, horizontalId)), junction),
        isTrue,
      );
      expect(
        _samePointSet(_sceneEnds(_liveLine(cad, verticalId)), verticalEnds),
        isTrue,
      );
      // ignore: avoid_print
      print('TRIM_TRACE L-right order=vertical-first ${_traceLines(cad)}');

      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      await _tapWorldPoint(tester, _mix(right, junction, .45));
      await _waitForTrim(tester, commands, 3);
      expect(_hasEnd(_sceneEnds(_liveLine(cad, horizontalId)), right), isFalse);
      expect(
        _hasEnd(_sceneEnds(_liveLine(cad, horizontalId)), junction),
        isTrue,
      );
      expect(
        _samePointSet(_sceneEnds(_liveLine(cad, verticalId)), verticalEnds),
        isTrue,
        reason: 'portion-first ${_traceLines(cad)}',
      );
      // ignore: avoid_print
      print('TRIM_TRACE L-right order=portion-first ${_traceLines(cad)}');
    },
  );

  testWidgets(
    'full-crossing Trim keeps the two clicked portions in either order',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.22, .50),
        end: const Offset(.78, .50),
      );
      await _drawOpenLine(
        tester,
        start: const Offset(.50, .28),
        end: const Offset(.50, .74),
      );
      final crossing = _crossingPair(cad);
      final horizontalId = crossing.horizontal.id;
      final verticalId = crossing.vertical.id;
      final hEnds = _sceneEnds(crossing.horizontal);
      final vEnds = _sceneEnds(crossing.vertical);
      final junction = _lineCross(hEnds, vEnds);
      final right = _farEnd(hEnds, junction, smallerX: false);
      final upper = vEnds[0].y >= vEnds[1].y ? vEnds[0] : vEnds[1];
      final horizontalKeep = _mix(junction, right, .55);
      final verticalKeep = _mix(junction, upper, .55);
      await _beginEditingTool(tester, 'Trim');
      await _tapWorldPoint(tester, horizontalKeep);
      await _tapWorldPoint(tester, verticalKeep);
      await _waitForTrim(tester, commands, 1);
      void expectKept(String order) {
        final horizontal = _sceneEnds(_liveLine(cad, horizontalId));
        final vertical = _sceneEnds(_liveLine(cad, verticalId));
        expect(
          _hasEnd(horizontal, junction),
          isTrue,
          reason: '$order ${_traceLines(cad)}',
        );
        expect(_hasEnd(horizontal, right), isTrue, reason: order);
        expect(_hasEnd(vertical, junction), isTrue, reason: order);
        expect(_hasEnd(vertical, upper), isTrue, reason: order);
        expect(_liveLines(cad), hasLength(2));
      }

      expectKept('horizontal-first');
      // ignore: avoid_print
      print('TRIM_TRACE crossing-keep horizontal-first ${_traceLines(cad)}');
      await tester.tap(find.byTooltip('Desfazer'));
      await _awaitShellAction(tester, cad, commands, 'undo');
      expect(
        _samePointSet(_sceneEnds(_liveLine(cad, horizontalId)), hEnds),
        isTrue,
      );
      await _tapWorldPoint(tester, verticalKeep);
      await _tapWorldPoint(tester, horizontalKeep);
      await _waitForTrim(tester, commands, 2);
      expectKept('vertical-first');
      // ignore: avoid_print
      print('TRIM_TRACE crossing-keep vertical-first ${_traceLines(cad)}');
    },
  );

  testWidgets(
    'Trim rejects FIX and a bare corner, and Extend still reaches its boundary',
    (tester) async {
      await _openSketch(tester, cad, commands);
      await _drawOpenLine(
        tester,
        start: const Offset(.22, .50),
        end: const Offset(.78, .50),
      );
      await _drawOpenLine(
        tester,
        start: const Offset(.50, .28),
        end: const Offset(.50, .74),
      );
      final crossing = _crossingPair(cad);
      await _exitLineTool(tester);
      final fixedEnds = _sceneEnds(crossing.horizontal);
      await _tapWorldPoint(tester, _mix(fixedEnds[0], fixedEnds[1], .22));
      expect(
        cad.runtime.selection,
        contains(crossing.horizontal.id),
        reason: 'Fix must be applied to the selected horizontal line',
      );
      await _tapConstraint(tester, 'Fix');
      await _waitForHistory(
        tester,
        commands,
        'reverse.sketch.constraint',
        'execute',
      );
      final fixedBefore = _traceLines(cad);
      await _beginEditingTool(tester, 'Trim');
      final ends = _sceneEnds(crossing.horizontal);
      final left = ends[0].x <= ends[1].x ? ends[0] : ends[1];
      await _tapWorldPoint(tester, _insetToward(ends, left, .08));
      await _settle(tester);
      final error = _sketchController(tester).error as String?;
      expect(error, isNotNull);
      expect(
        error!.toLowerCase(),
        anyOf(contains('fixed'), contains('locked')),
      );
      expect(_traceLines(cad), fixedBefore);
      expect(_engineLines(cad), hasLength(2));

      await _sketchController(tester).finishSketchEditingTool();
      await _settle(tester);
      final cornerIds = _liveLines(cad).map((line) => line.id).toSet();
      await _drawOpenLine(
        tester,
        start: const Offset(.20, .66),
        end: const Offset(.36, .66),
      );
      await _drawOpenLine(
        tester,
        start: const Offset(.36, .66),
        end: const Offset(.36, .82),
      );
      final corner = _liveLines(
        cad,
      ).where((line) => !cornerIds.contains(line.id)).toList(growable: false);
      expect(corner, hasLength(2), reason: _traceLines(cad));
      final cornerBefore = corner
          .map((line) => _parameterSnapshot(_engineLine(cad, line.id)))
          .join('|');
      await _beginEditingTool(tester, 'Trim');
      await _tapWorldPoint(
        tester,
        _mix(_sceneEnds(corner[0])[0], _sceneEnds(corner[0])[1], .5),
      );
      await _tapWorldPoint(
        tester,
        _mix(_sceneEnds(corner[1])[0], _sceneEnds(corner[1])[1], .5),
      );
      await _settle(tester);
      expect(_sketchController(tester).error, isNotNull);
      expect(
        corner
            .map((line) => _parameterSnapshot(_engineLine(cad, line.id)))
            .join('|'),
        cornerBefore,
        reason: 'endpoint-endpoint trim must not change geometry',
      );

      await _sketchController(tester).finishSketchEditingTool();
      await _settle(tester);
      final extendIds = _liveLines(cad).map((line) => line.id).toSet();
      await _drawOpenLine(
        tester,
        start: const Offset(.18, .30),
        end: const Offset(.32, .30),
      );
      await _drawOpenLine(
        tester,
        start: const Offset(.62, .20),
        end: const Offset(.62, .42),
      );
      final extendLines = _liveLines(
        cad,
      ).where((line) => !extendIds.contains(line.id)).toList(growable: false);
      expect(extendLines, hasLength(2), reason: _traceLines(cad));
      final extendTarget = extendLines.singleWhere(_isHorizontal);
      final extendBoundary = extendLines.singleWhere(_isVertical);
      final targetBefore = _sceneEnds(extendTarget);
      final boundaryBefore = _parameterSnapshot(
        _engineLine(cad, extendBoundary.id),
      );
      final editsBefore = _historyCount(commands, 'reverse.sketch.edit');
      await _beginEditingTool(tester, 'Extend');
      await _tapLine(tester, extendTarget);
      await _tapLine(tester, extendBoundary);
      await _waitForTrim(tester, commands, editsBefore + 1);
      final targetAfter = _sceneEnds(_liveLine(cad, extendTarget.id));
      final boundaryX = _sceneEnds(extendBoundary).first.x;
      expect(
        targetAfter.any((point) => (point.x - boundaryX).abs() <= 1e-5),
        isTrue,
        reason: 'extend $targetBefore -> $targetAfter boundaryX=$boundaryX',
      );
      expect(
        _parameterSnapshot(_engineLine(cad, extendBoundary.id)),
        boundaryBefore,
        reason: 'extend must not move the boundary line',
      );
    },
  );

  testWidgets('directional constraints survive successive Trim', (
    tester,
  ) async {
    await _openSketch(tester, cad, commands);
    await _drawOpenLine(
      tester,
      start: const Offset(.22, .50),
      end: const Offset(.78, .50),
    );
    await _drawOpenLine(
      tester,
      start: const Offset(.50, .28),
      end: const Offset(.50, .74),
    );
    final crossing = _crossingPair(cad);
    await _exitLineTool(tester);
    final horizontalEnds = _sceneEnds(crossing.horizontal);
    final verticalEnds = _sceneEnds(crossing.vertical);
    await _tapWorldPoint(
      tester,
      _mix(horizontalEnds[0], horizontalEnds[1], .22),
    );
    expect(cad.runtime.selection, contains(crossing.horizontal.id));
    await _tapConstraint(tester, 'Horizontal');
    await _waitForHistory(
      tester,
      commands,
      'reverse.sketch.constraint',
      'execute',
    );
    await _tapWorldPoint(tester, _mix(verticalEnds[0], verticalEnds[1], .22));
    expect(cad.runtime.selection, contains(crossing.vertical.id));
    await _tapConstraint(tester, 'Vertical');
    await _waitForHistoryCount(
      tester,
      commands,
      'reverse.sketch.constraint',
      2,
    );
    await _beginEditingTool(tester, 'Trim');
    await _tapWorldPoint(
      tester,
      _insetToward(
        _sceneEnds(crossing.vertical),
        _lower(_sceneEnds(crossing.vertical)),
        .08,
      ),
    );
    await _waitForTrim(tester, commands, 1);
    final junction = _endpointOnInterior(
      _sceneEnds(_liveLine(cad, crossing.vertical.id)),
      _sceneEnds(_liveLine(cad, crossing.horizontal.id)),
    );
    expect(junction, isNotNull, reason: _traceLines(cad));
    final left = _farEnd(
      _sceneEnds(_liveLine(cad, crossing.horizontal.id)),
      junction!,
      smallerX: true,
    );
    await _tapWorldPoint(tester, _mix(left, junction, .5));
    await _waitForTrim(tester, commands, 2);
    final api = cad.runtime.read<ConstraintApi>('sketch.constraintApi')!;
    expect(
      api.constraints.map((item) => item.type),
      containsAll([
        SketchConstraintType.horizontal,
        SketchConstraintType.vertical,
      ]),
    );
    final solved = await api.solve();
    expect(solved.success, isTrue, reason: '${solved.diagnostics}');
    expect(_isHorizontal(_liveLine(cad, crossing.horizontal.id)), isTrue);
    expect(_isVertical(_liveLine(cad, crossing.vertical.id)), isTrue);
    expect(_sketchController(tester).error, isNull);
    // ignore: avoid_print
    print('TRIM_TRACE constrained L ${_traceLines(cad)}');
  });
}

Future<void> _openSketch(
  WidgetTester tester,
  DesktopCadController cad,
  DesktopCommandCoordinator commands,
) async {
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Desfazer',
                  onPressed: () {
                    cad.runtime.write('test.shell.undo', commands.undo());
                  },
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  tooltip: 'Refazer',
                  onPressed: () {
                    cad.runtime.write('test.shell.redo', commands.redo());
                  },
                  icon: const Icon(Icons.redo),
                ),
              ],
            ),
            Expanded(
              child: OfficialEngineeringWorkspace(cad: cad, commands: commands),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(() async {
    await commands.createProject('Sketch flow', 'FLCAD');
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pump();
  for (var attempt = 0; attempt < 160; attempt++) {
    if (cad.runtime.read<Object>('sketch.api') != null) break;
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  expect(
    cad.runtime.read<Object>('sketch.api'),
    isNotNull,
    reason:
        'configuration ${cad.runtime.read<Object>('sketch.configuration.diagnostic')} '
        'status ${cad.message}',
  );
  await tester.tap(find.byTooltip('Atividades'));
  await _settle(tester);
  await tester.tap(
    find.byWidgetPredicate(
      (widget) =>
          widget is PopupMenuItem<String> &&
          widget.enabled &&
          widget.value == 'Sketch',
    ),
  );
  await _settle(tester);
  final xy = find.text('XY');
  await tester.ensureVisible(xy);
  await tester.runAsync(() async {
    await tester.tap(xy, warnIfMissed: true);
    await Future<void>.delayed(const Duration(milliseconds: 800));
  });
  for (var attempt = 0; attempt < 160; attempt++) {
    if (find.text('Rectangle · Two Corners').evaluate().isNotEmpty) break;
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  expect(
    find.text('Rectangle · Two Corners'),
    findsOneWidget,
    reason:
        '${cad.message} diagnostic ${cad.runtime.read<Object>('sketch.open.diagnostic')}',
  );
  await _waitForHistory(tester, commands, 'reverse.sketch.open', 'execute');
}

Future<void> _drawRectangle(
  WidgetTester tester,
  DesktopCadController cad,
  DesktopCommandCoordinator commands,
) async {
  final beforeLineCount = _liveLines(cad).length;
  final beforeHistoryCount = commands.manager.history
      .where(
        (entry) =>
            entry.commandId == 'reverse.sketch.rectangle' &&
            entry.operation == 'execute',
      )
      .length;
  final button = find.text('Rectangle · Two Corners');
  await tester.ensureVisible(button);
  await tester.tap(button, warnIfMissed: true);
  await _settle(tester);
  expect(find.text('Drawing Rectangle'), findsOneWidget);
  final viewport = find.byType(IntegratedCadViewportWidget);
  final view = tester.widget<IntegratedCadViewportWidget>(viewport);
  final tap = view.onSketchTap;
  expect(tap, isNotNull, reason: 'the rectangle tool must arm viewport clicks');
  if (view.camera.projectionMode != CadProjectionMode.orthographic) {
    view.camera.enterSketch(
      origin: Vector3.zero,
      normal: const Vector3(0, 0, 1),
      xDirection: const Vector3(1, 0, 0),
    );
  }
  final first = Offset(
    view.camera.viewportWidth * .35,
    view.camera.viewportHeight * .4,
  );
  final second = Offset(
    view.camera.viewportWidth * .62,
    view.camera.viewportHeight * .68,
  );
  await tester.runAsync(() async {
    tap!(first);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    tap(second);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  for (var attempt = 0; attempt < 160; attempt++) {
    final published = cad.runtime.document?.entities.values.where(
      (entity) =>
          entity.data['deleted'] != true &&
          entity.data['sketchEntity'] is Map &&
          (entity.data['sketchEntity'] as Map)['type'] == 'line',
    );
    final recorded = commands.manager.history
        .where(
          (entry) =>
              entry.commandId == 'reverse.sketch.rectangle' &&
              entry.operation == 'execute',
        )
        .length;
    if (published != null &&
        published.length >= beforeLineCount + 4 &&
        recorded > beforeHistoryCount) {
      break;
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
  }
  expect(
    _liveLines(cad),
    hasLength(beforeLineCount + 4),
    reason:
        'rectangle callback did not complete; status=${cad.message}; pending=${commands.manager.hasPendingOperations}; active=${commands.manager.activeCommandIds}; history=${commands.manager.history.map((entry) => '${entry.commandId}:${entry.operation}').join(',')}',
  );
  expect(
    commands.manager.history.any(
      (entry) =>
          entry.commandId == 'reverse.sketch.rectangle' &&
          entry.operation == 'execute',
    ),
    isTrue,
    reason:
        'rectangle command was published but not committed to global history; active=${commands.manager.activeCommandIds}',
  );
}

Future<void> _createLinearDimension(
  WidgetTester tester,
  DesktopCadController cad,
  DesktopCommandCoordinator commands,
  double value,
  int expectedCount,
) async {
  final linear = find.widgetWithText(OutlinedButton, 'Linear');
  expect(linear, findsOneWidget);
  await tester.ensureVisible(linear);
  await tester.tap(linear);
  await tester.pumpAndSettle();
  final dialog = find.byType(AlertDialog);
  expect(dialog, findsOneWidget);
  expect(
    find.descendant(
      of: dialog,
      matching: find.text('linear driving dimension'),
    ),
    findsOneWidget,
  );
  final field = find.descendant(
    of: dialog,
    matching: find.byType(TextFormField),
  );
  expect(field, findsOneWidget);
  await tester.enterText(field, '$value');
  await tester.tap(find.descendant(of: dialog, matching: find.text('Create')));
  await _waitForHistoryCount(
    tester,
    commands,
    'reverse.sketch.dimension.create',
    expectedCount,
  );
}

Future<void> _submitInspectorNumber(
  WidgetTester tester,
  String label,
  double value,
) async {
  final property = find.ancestor(
    of: find.text(label),
    matching: find.byType(SketchInspectorNumberProperty),
  );
  expect(property, findsOneWidget);
  final field = find.descendant(
    of: property,
    matching: find.byType(TextFormField),
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, '$value');
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
}

Future<void> _editLinearDimension(
  WidgetTester tester,
  DesktopCadController cad,
  DesktopCommandCoordinator commands,
  double from,
  double to, {
  int? editCount,
}) async {
  final panel = find.byKey(
    const ValueKey('sketch-functional-panel-dimensions'),
  );
  final label = find.descendant(
    of: panel,
    matching: find.text('linear  ${from.toStringAsFixed(3)}'),
  );
  expect(label, findsOneWidget);
  await tester.ensureVisible(label);
  await tester.tap(label);
  await tester.pumpAndSettle();
  final dialog = find.byType(AlertDialog);
  expect(dialog, findsOneWidget);
  final field = find.descendant(
    of: dialog,
    matching: find.byType(TextFormField),
  );
  expect(field, findsOneWidget);
  await tester.enterText(field, '$to');
  await tester.pump();
  await tester.tap(find.descendant(of: dialog, matching: find.text('Aplicar')));
  if (editCount != null) {
    await _waitForHistoryCount(
      tester,
      commands,
      'reverse.sketch.dimension.edit',
      editCount,
    );
    return;
  }
  for (var attempt = 0; attempt < 160; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    if (!commands.manager.hasPendingOperations) break;
  }
  expect(commands.manager.hasPendingOperations, isFalse);
  await _settle(tester);
}

({
  CadDocumentEntity top,
  CadDocumentEntity bottom,
  CadDocumentEntity left,
  CadDocumentEntity right,
})
_rectangleByOrientation(DesktopCadController cad) {
  double midpointY(CadDocumentEntity line) {
    final points = _endpoints(line);
    return (points[0].y + points[1].y) / 2;
  }

  double midpointX(CadDocumentEntity line) {
    final points = _endpoints(line);
    return (points[0].x + points[1].x) / 2;
  }

  final horizontal = _liveLines(cad).where(_isHorizontal).toList();
  final vertical = _liveLines(cad).where(_isVertical).toList();
  expect(horizontal, hasLength(2));
  expect(vertical, hasLength(2));
  return (
    top: horizontal.reduce((a, b) => midpointY(a) > midpointY(b) ? a : b),
    bottom: horizontal.reduce((a, b) => midpointY(a) < midpointY(b) ? a : b),
    left: vertical.reduce((a, b) => midpointX(a) < midpointX(b) ? a : b),
    right: vertical.reduce((a, b) => midpointX(a) > midpointX(b) ? a : b),
  );
}

void _expectRectangular(
  DesktopCadController cad, {
  required double expectedWidth,
  double? expectedHeight,
}) {
  final rectangle = _rectangleByOrientation(cad);
  final horizontal = _liveLines(cad).where(_isHorizontal).toList();
  final vertical = _liveLines(cad).where(_isVertical).toList();
  expect(horizontal, hasLength(2));
  expect(vertical, hasLength(2));
  expect(_lineLength(rectangle.top), closeTo(expectedWidth, 1e-6));
  expect(_lineLength(rectangle.bottom), closeTo(expectedWidth, 1e-6));
  expect(
    _lineLength(rectangle.top),
    closeTo(_lineLength(rectangle.bottom), 1e-6),
  );
  expect(
    _lineLength(rectangle.left),
    closeTo(_lineLength(rectangle.right), 1e-6),
  );
  if (expectedHeight != null) {
    expect(_lineLength(rectangle.left), closeTo(expectedHeight, 1e-6));
    expect(_lineLength(rectangle.right), closeTo(expectedHeight, 1e-6));
  }
  expect(_maxCornerGap([...horizontal, ...vertical]), lessThanOrEqualTo(1e-6));
}

Future<void> _drawOpenLine(
  WidgetTester tester, {
  Offset start = const Offset(.3, .5),
  Offset end = const Offset(.7, .5),
}) async {
  final line = find.text('Line');
  final activeLine = find.byWidgetPredicate(
    (widget) => widget is Text && (widget.data ?? '').startsWith('Line '),
  );
  if (activeLine.evaluate().isNotEmpty) {
    final viewport = find.byType(IntegratedCadViewportWidget);
    final secondary = tester
        .widget<IntegratedCadViewportWidget>(viewport)
        .onSketchSecondaryTap;
    expect(
      secondary,
      isNotNull,
      reason: 'an open line chain accepts a right-click',
    );
    await tester.runAsync(() async {
      secondary!();
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await _settle(tester);
    final activeButton = find.ancestor(
      of: activeLine,
      matching: find.byType(FilledButton),
    );
    expect(activeButton, findsOneWidget);
    tester.widget<FilledButton>(activeButton).onPressed!();
    await _settle(tester);
  }
  expect(line, findsOneWidget, reason: _visibleText(tester).join(' | '));
  final lineButton = find.ancestor(
    of: line,
    matching: find.byType(FilledButton),
  );
  expect(lineButton, findsOneWidget);
  tester.widget<FilledButton>(lineButton).onPressed!();
  await _settle(tester);
  final viewport = find.byType(IntegratedCadViewportWidget);
  final view = tester.widget<IntegratedCadViewportWidget>(viewport);
  final tap = view.onSketchTap;
  expect(tap, isNotNull, reason: 'the line tool must arm viewport clicks');
  if (view.camera.projectionMode != CadProjectionMode.orthographic) {
    view.camera.enterSketch(
      origin: Vector3.zero,
      normal: const Vector3(0, 0, 1),
      xDirection: const Vector3(1, 0, 0),
    );
  }
  await tester.runAsync(() async {
    tap!(
      Offset(
        view.camera.viewportWidth * start.dx,
        view.camera.viewportHeight * start.dy,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    tap(
      Offset(
        view.camera.viewportWidth * end.dx,
        view.camera.viewportHeight * end.dy,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await _settle(tester);
}

Future<void> _drawCenterArc(
  WidgetTester tester,
  Offset center,
  Offset start,
  Offset end,
) async {
  final arc = find.text('Arc');
  expect(arc, findsOneWidget);
  final button = find.ancestor(of: arc, matching: find.byType(FilledButton));
  expect(button, findsWidgets);
  tester.widget<FilledButton>(button.first).onPressed!();
  await _settle(tester);
  final viewport = find.byType(IntegratedCadViewportWidget);
  final view = tester.widget<IntegratedCadViewportWidget>(viewport);
  final tap = view.onSketchTap;
  expect(tap, isNotNull);
  if (view.camera.projectionMode != CadProjectionMode.orthographic) {
    view.camera.enterSketch(
      origin: Vector3.zero,
      normal: const Vector3(0, 0, 1),
      xDirection: const Vector3(1, 0, 0),
    );
  }
  Future<void> click(Offset fraction) => tester.runAsync(() async {
    tap!(
      Offset(
        view.camera.viewportWidth * fraction.dx,
        view.camera.viewportHeight * fraction.dy,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await click(center);
  await click(start);
  await click(end);
  await _settle(tester);
}

CadViewportPick _endpointPick(CadDocumentEntity line, Vector3 point) =>
    CadViewportPick(
      entityId: line.id,
      hit: MeshHit(triangleIndex: -1, point: point, distance: 0),
    );

(Vector3, Vector3) _lineVectors(
  CadDocumentEntity first,
  CadDocumentEntity second,
) => (
  _endpoints(first)[1] - _endpoints(first)[0],
  _endpoints(second)[1] - _endpoints(second)[0],
);

void _expectPerpendicular(Vector3 first, Vector3 second) {
  final denominator = math.sqrt(first.dot(first) * second.dot(second));
  expect(denominator, greaterThan(1e-9));
  expect((first.dot(second)).abs() / denominator, lessThanOrEqualTo(1e-8));
}

Future<void> _exitRectangleTool(WidgetTester tester) async {
  final drawing = find.text('Drawing Rectangle');
  if (drawing.evaluate().isNotEmpty) {
    final button = find.ancestor(
      of: drawing,
      matching: find.byType(FilledButton),
    );
    expect(button, findsOneWidget);
    tester.widget<FilledButton>(button).onPressed!();
    await _settle(tester);
  }
}

Future<void> _openPanel(WidgetTester tester, String key) async {
  final tab = find.byKey(ValueKey(key));
  if (tab.evaluate().isEmpty) return;
  tester.widget<ChoiceChip>(tab).onSelected!(true);
  await _settle(tester);
}

Future<void> _finishSketchFromWidget(
  WidgetTester tester,
  DesktopCommandCoordinator commands,
) async {
  final label = find.text('Exit Sketch');
  expect(label, findsOneWidget);
  final button = find.ancestor(
    of: label,
    matching: find.byType(OutlinedButton),
  );
  expect(button, findsOneWidget);
  await tester.runAsync(() async {
    tester.widget<OutlinedButton>(button).onPressed!();
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });
  await _waitForHistory(tester, commands, 'reverse.sketch.finish', 'execute');
}

Future<void> _openNewSketchFromWidget(
  WidgetTester tester,
  DesktopCadController cad,
  DesktopCommandCoordinator commands,
) async {
  await tester.tap(find.byTooltip('Atividades'));
  await _settle(tester);
  await tester.tap(
    find.byWidgetPredicate(
      (widget) =>
          widget is PopupMenuItem<String> &&
          widget.enabled &&
          widget.value == 'Sketch',
    ),
  );
  await _settle(tester);
  final xy = find.text('XY');
  await tester.ensureVisible(xy);
  await tester.runAsync(() async {
    await tester.tap(xy, warnIfMissed: true);
    await Future<void>.delayed(const Duration(milliseconds: 800));
  });
  await _waitForHistoryCount(tester, commands, 'reverse.sketch.open', 2);
  expect(cad.runtime.read<Object>('sketch.api'), isNotNull);
}

Future<void> _reopenSketchFromTree(
  WidgetTester tester, {
  required String name,
}) async {
  final project = find.byKey(const ValueKey('workspace-project-root'));
  final sketches = find.byKey(const ValueKey('workspace-group-Sketches'));
  var label = find.descendant(of: sketches, matching: find.text(name));
  if (label.evaluate().isEmpty) {
    await tester.tap(project);
    await _settle(tester);
    label = find.descendant(of: sketches, matching: find.text(name));
  }
  if (label.evaluate().isEmpty) {
    await tester.tap(sketches);
    await _settle(tester);
    label = find.descendant(of: sketches, matching: find.text(name));
  }
  expect(label, findsOneWidget);
  final target = find.ancestor(
    of: label,
    matching: find.byWidgetPredicate(
      (widget) => widget is GestureDetector && widget.onDoubleTap != null,
    ),
  );
  expect(target, findsWidgets);
  await tester.runAsync(() async {
    tester.widget<GestureDetector>(target.first).onDoubleTap!();
    await Future<void>.delayed(const Duration(milliseconds: 700));
  });
  await _settle(tester);
}

Future<void> _tapConstraint(WidgetTester tester, String label) async {
  await _openPanel(tester, 'sketch-panel-tab-constraints');
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await _settle(tester);
}

Future<void> _exitLineTool(WidgetTester tester) async {
  final activeLine = find.byWidgetPredicate(
    (widget) => widget is Text && (widget.data ?? '').startsWith('Line '),
  );
  if (activeLine.evaluate().isEmpty) return;
  final activeButton = find.ancestor(
    of: activeLine,
    matching: find.byType(FilledButton),
  );
  expect(activeButton, findsOneWidget);
  tester.widget<FilledButton>(activeButton).onPressed!();
  await _settle(tester);
}

Finder _editingToolButton(String tooltip) => find.descendant(
  of: find.byTooltip(tooltip, skipOffstage: false),
  matching: find.byType(IconButton),
  skipOffstage: false,
);

Future<void> _beginEditingTool(WidgetTester tester, String tooltip) async {
  await _exitLineTool(tester);
  await _openPanel(tester, 'sketch-panel-tab-sketch');
  var button = _editingToolButton(tooltip);
  if (button.evaluate().isEmpty) {
    final modify = find.text('Modify');
    expect(modify, findsWidgets, reason: _visibleText(tester).join(' | '));
    await tester.ensureVisible(modify.first);
    await tester.tap(modify.first);
    await _settle(tester);
    button = _editingToolButton(tooltip);
  }
  if (button.evaluate().isEmpty) {
    await tester.tap(find.text('Modify').first);
    await _settle(tester);
    button = _editingToolButton(tooltip);
  }
  expect(button, findsOneWidget, reason: _visibleText(tester).join(' | '));
  tester.widget<IconButton>(button).onPressed!();
  await _settle(tester);
}

Future<void> _tapWorldPoint(WidgetTester tester, Vector3 world) async {
  final viewport = find.byType(IntegratedCadViewportWidget);
  final widget = tester.widget<IntegratedCadViewportWidget>(viewport);
  final box = tester.getRect(viewport);
  final projected = widget.camera.viewProjectionMatrix.transformPoint(world);
  final local = Offset(
    (projected.x + 1) * box.width / 2,
    (1 - projected.y) * box.height / 2,
  );
  await tester.tapAt(box.topLeft + local);
  await _settle(tester);
}

int _historyCount(DesktopCommandCoordinator commands, String commandId) =>
    commands.manager.history
        .where(
          (entry) =>
              entry.commandId == commandId && entry.operation == 'execute',
        )
        .length;

Future<void> _waitForTrim(
  WidgetTester tester,
  DesktopCommandCoordinator commands,
  int executeCount,
) =>
    _waitForHistoryCount(tester, commands, 'reverse.sketch.edit', executeCount);

({CadDocumentEntity horizontal, CadDocumentEntity vertical}) _crossingPair(
  DesktopCadController cad,
) {
  final horizontal = _liveLines(cad).where(_isHorizontal).toList();
  final vertical = _liveLines(cad).where(_isVertical).toList();
  expect(horizontal, hasLength(1), reason: _traceLines(cad));
  expect(vertical, hasLength(1), reason: _traceLines(cad));
  return (horizontal: horizontal.single, vertical: vertical.single);
}

List<Vector3> _sceneEnds(CadDocumentEntity line) {
  final points = (line.data['sceneGeometry'] as Map)['points'] as List;
  return [_vector(points.first), _vector(points.last)];
}

Vector3 _mix(Vector3 a, Vector3 b, double t) => a + (b - a) * t;

String _xy(Vector3 point) =>
    '(${point.x.toStringAsFixed(4)},${point.y.toStringAsFixed(4)})';

String _endsText(List<Vector3> ends) => ends.map(_xy).join(' -> ');

bool _nearPoint(Vector3 a, Vector3 b, [double tolerance = 1e-4]) {
  final delta = a - b;
  return delta.dot(delta) <= tolerance * tolerance;
}

bool _hasEnd(List<Vector3> ends, Vector3 point) =>
    ends.any((end) => _nearPoint(end, point));

bool _samePointSet(List<Vector3> left, List<Vector3> right) =>
    left.length == right.length &&
    left.every((point) => right.any((other) => _nearPoint(point, other)));

Vector3 _lower(List<Vector3> ends) =>
    ends[0].y <= ends[1].y ? ends[0] : ends[1];

Vector3 _insetToward(List<Vector3> ends, Vector3 end, double fraction) {
  final other = _nearPoint(ends[0], end, 1e-6) ? ends[1] : ends[0];
  return _mix(end, other, fraction);
}

Vector3 _farEnd(
  List<Vector3> ends,
  Vector3 junction, {
  required bool smallerX,
}) {
  final left = ends[0].x <= ends[1].x ? ends[0] : ends[1];
  final right = ends[0].x > ends[1].x ? ends[0] : ends[1];
  expect(
    (left.x - junction.x).abs() > 1e-6 || (right.x - junction.x).abs() > 1e-6,
    isTrue,
  );
  return smallerX ? left : right;
}

Vector3 _lineCross(List<Vector3> first, List<Vector3> second) {
  final a = first[0], b = first[1], c = second[0], d = second[1];
  final abx = b.x - a.x, aby = b.y - a.y;
  final cdx = d.x - c.x, cdy = d.y - c.y;
  final determinant = abx * cdy - aby * cdx;
  expect(determinant.abs(), greaterThan(1e-8));
  final t = ((c.x - a.x) * cdy - (c.y - a.y) * cdx) / determinant;
  return Vector3(a.x + abx * t, a.y + aby * t, 0);
}

Vector3? _endpointOnInterior(List<Vector3> ends, List<Vector3> carrier) {
  final ab = carrier[1] - carrier[0];
  final length2 = ab.dot(ab);
  if (length2 <= 1e-12) return null;
  for (final end in ends) {
    final t = (end - carrier[0]).dot(ab) / length2;
    if (t <= 1e-4 || t >= 1 - 1e-4) continue;
    if (_nearPoint(end, carrier[0] + ab * t)) return end;
  }
  return null;
}

CadDocumentEntity _liveLine(DesktopCadController cad, String id) =>
    _liveLines(cad).singleWhere((line) => line.id == id);

SketchLine _engineLine(DesktopCadController cad, String id) =>
    _engineLines(cad).singleWhere((line) => line.id == id);

String _traceLines(DesktopCadController cad) => _engineLines(
  cad,
).map((line) => '${line.id} ${_parameterSnapshot(line)}').join(' | ');

Future<void> _tapLine(WidgetTester tester, CadDocumentEntity line) async {
  final viewport = find.byType(IntegratedCadViewportWidget);
  final widget = tester.widget<IntegratedCadViewportWidget>(viewport);
  final box = tester.getRect(viewport);
  final points = (line.data['sceneGeometry'] as Map)['points'] as List;
  final start = _vector(points.first);
  final end = _vector(points.last);
  final mid = (start + end) * .5;
  final projected = widget.camera.viewProjectionMatrix.transformPoint(mid);
  final local = Offset(
    (projected.x + 1) * box.width / 2,
    (1 - projected.y) * box.height / 2,
  );
  await tester.tapAt(box.topLeft + local);
  await _settle(tester);
}

Future<void> _dragLine(
  WidgetTester tester,
  DesktopCadController cad,
  DesktopCommandCoordinator commands,
  CadDocumentEntity line,
  Offset delta,
) async {
  final viewport = find.byType(IntegratedCadViewportWidget);
  final widget = tester.widget<IntegratedCadViewportWidget>(viewport);
  expect(widget.onSketchEntityDragStart, isNotNull);
  final box = tester.getRect(viewport);
  final points = _endpoints(line);
  final mid = (points.first + points.last) * .5;
  final projected = widget.camera.viewProjectionMatrix.transformPoint(mid);
  final start =
      box.topLeft +
      Offset(
        (projected.x + 1) * box.width / 2,
        (1 - projected.y) * box.height / 2,
      );
  await tester.tapAt(start);
  await _settle(tester);
  expect(
    cad.runtime.selection,
    contains(line.id),
    reason: 'the projected line midpoint must be pickable before dragging',
  );
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.moveBy(Offset(delta.dx.sign * 4, delta.dy.sign * 4));
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.moveBy(
    Offset(delta.dx - delta.dx.sign * 4, delta.dy - delta.dy.sign * 4),
  );
  await tester.pump(const Duration(milliseconds: 80));
  expect(
    cad.runtime.read<bool>('sketch.drag.active'),
    isTrue,
    reason:
        'the real pointer gesture did not enter drag; start=$start line=${line.id}',
  );
  await tester.runAsync(() async {
    await gesture.up();
  });
  for (var attempt = 0; attempt < 80; attempt++) {
    if (!commands.manager.hasPendingOperations) break;
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  expect(
    commands.manager.hasPendingOperations,
    isFalse,
    reason: 'sketch drag did not finish; status=${cad.message}',
  );
  await _settle(tester);
}

Future<void> _deleteFromTree(WidgetTester tester, String name) async {
  final project = find.byKey(const ValueKey('workspace-project-root'));
  expect(project, findsOneWidget);
  await tester.tap(project);
  await _settle(tester);
  final sketches = find.byKey(const ValueKey('workspace-group-Sketches'));
  expect(sketches, findsOneWidget);
  await tester.tap(sketches);
  await _settle(tester);

  final treeLabel = find.descendant(of: sketches, matching: find.text(name));
  expect(treeLabel, findsOneWidget);
  final tile = find.ancestor(of: treeLabel, matching: find.byType(ListTile));
  expect(tile, findsOneWidget);
  final menu = find.descendant(
    of: tile,
    matching: find.byType(PopupMenuButton<String>),
  );
  expect(menu, findsOneWidget);
  tester.widget<PopupMenuButton<String>>(menu).onSelected!('delete');
  await _settle(tester);
  await tester.tap(find.text('Excluir somente esta entidade'));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _waitForHistory(
  WidgetTester tester,
  DesktopCommandCoordinator commands,
  String commandId,
  String operation,
) async {
  for (var attempt = 0; attempt < 240; attempt++) {
    if (commands.manager.history.any(
      (entry) => entry.commandId == commandId && entry.operation == operation,
    )) {
      await _settle(tester);
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
  }
  fail(
    'Timed out waiting for $commandId:$operation; '
    'status=${commands.cad.message}; '
    'controllerError=${find.byType(SketchSurfaceWorkspacePanel).evaluate().isEmpty ? null : tester.widget<SketchSurfaceWorkspacePanel>(find.byType(SketchSurfaceWorkspacePanel).first).controller.error}; '
    'active=${commands.manager.activeCommandIds}; '
    'recyclePhase=${commands.cad.runtime.read<Object>('document.recycle.phase')}; '
    'synchronize=${commands.cad.runtime.read<Object>('sketch.synchronize.phase')}; '
    'constraint=${commands.cad.runtime.read<Object>('sketch.constraint.phase')}; '
    'persistence=${commands.cad.runtime.read<Object>('sketch.persistence.phase')}; '
    'dimensionPhase=${commands.cad.runtime.read<Object>('sketch.dimension.command.phase')}; '
    'persistenceTiming={sketch:${commands.cad.runtime.read<Object>('sketch.persistence.timing.sketchMs')},editor:${commands.cad.runtime.read<Object>('sketch.persistence.timing.editorMs')},constraint:${commands.cad.runtime.read<Object>('sketch.persistence.timing.constraintMs')},transaction:${commands.cad.runtime.read<Object>('sketch.persistence.timing.transactionMs')},total:${commands.cad.runtime.read<Object>('sketch.persistence.timing.totalMs')}}; '
    'transactionTiming={backup:${commands.cad.runtime.read<Object>('sketch.persistence.timing.transaction.backup')},persist:${commands.cad.runtime.read<Object>('sketch.persistence.timing.transaction.persist')},total:${commands.cad.runtime.read<Object>('sketch.persistence.timing.transaction.total')}}; '
    'syncTiming={document:${commands.cad.runtime.read<Object>('sketch.synchronize.timing.documentMs')},persistence:${commands.cad.runtime.read<Object>('sketch.synchronize.timing.persistenceMs')},dependencies:${commands.cad.runtime.read<Object>('sketch.synchronize.timing.dependenciesMs')},preview:${commands.cad.runtime.read<Object>('sketch.synchronize.timing.previewMs')},total:${commands.cad.runtime.read<Object>('sketch.synchronize.timing.totalMs')}}; '
    'history=${commands.manager.history.map((entry) => '${entry.commandId}:${entry.operation}').join(',')}; '
    'operationId=${commands.cad.runtime.read<Object>('command.operationId')}; '
    'callbackPhase=${commands.cad.runtime.read<Object>('command.callback.phase')}; '
    'trace=${commands.manager.trace.join(' | ')}',
  );
}

Future<void> _waitForHistoryCount(
  WidgetTester tester,
  DesktopCommandCoordinator commands,
  String commandId,
  int expected,
) async {
  for (var attempt = 0; attempt < 240; attempt++) {
    final count = commands.manager.history
        .where(
          (entry) =>
              entry.commandId == commandId && entry.operation == 'execute',
        )
        .length;
    if (count >= expected) {
      await _settle(tester);
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
  }
  fail(
    'Timed out waiting for $expected $commandId executions; '
    'active=${commands.manager.activeCommandIds}; '
    'transaction=${commands.cad.runtime.read<Object>('sketch.transaction.phase')}; '
    'persistence=${commands.cad.runtime.read<Object>('sketch.persistence.phase')}; '
    'enginePersistence=${commands.cad.runtime.read<SketchEngineApi>('sketch.api')?.engine.persistencePhase}; '
    'status=${commands.cad.message}; '
    'controllerError=${find.byType(SketchSurfaceWorkspacePanel).evaluate().isEmpty ? null : tester.widget<SketchSurfaceWorkspacePanel>(find.byType(SketchSurfaceWorkspacePanel).first).controller.error}',
  );
}

Future<void> _awaitShellAction(
  WidgetTester tester,
  DesktopCadController cad,
  DesktopCommandCoordinator commands,
  String operation,
) async {
  final action = cad.runtime.read<Future<void>>('test.shell.$operation');
  expect(action, isNotNull, reason: '$operation callback was not invoked');
  var completed = false;
  Object? failure;
  action!.then<void>((_) => completed = true).catchError((Object error) {
    failure = error;
    completed = true;
  });
  for (var attempt = 0; attempt < 240 && !completed; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
  }
  expect(
    completed,
    isTrue,
    reason:
        '$operation callback did not complete; phase=${cad.runtime.read<Object>('sketch.rectangle.history.phase')}; synchronize=${cad.runtime.read<Object>('sketch.synchronize.phase')}; active=${cad.runtime.read<Object>('sketch.rectangle.active')}'
        '; operationId=${cad.runtime.read<Object>('command.operationId')}'
        '; callbackPhase=${cad.runtime.read<Object>('command.callback.phase')}'
        '; constraintPhase=${cad.runtime.read<Object>('sketch.constraint.phase')}'
        '; persistencePhase=${cad.runtime.read<Object>('sketch.persistence.phase')}'
        '; persistenceTiming={sketch:${cad.runtime.read<Object>('sketch.persistence.timing.sketchMs')},editor:${cad.runtime.read<Object>('sketch.persistence.timing.editorMs')},constraint:${cad.runtime.read<Object>('sketch.persistence.timing.constraintMs')},transaction:${cad.runtime.read<Object>('sketch.persistence.timing.transactionMs')},total:${cad.runtime.read<Object>('sketch.persistence.timing.totalMs')}}'
        '; transactionTiming={backup:${cad.runtime.read<Object>('sketch.persistence.timing.transaction.backup')},persist:${cad.runtime.read<Object>('sketch.persistence.timing.transaction.persist')},total:${cad.runtime.read<Object>('sketch.persistence.timing.transaction.total')}}'
        '; syncTiming={document:${cad.runtime.read<Object>('sketch.synchronize.timing.documentMs')},persistence:${cad.runtime.read<Object>('sketch.synchronize.timing.persistenceMs')},dependencies:${cad.runtime.read<Object>('sketch.synchronize.timing.dependenciesMs')},preview:${cad.runtime.read<Object>('sketch.synchronize.timing.previewMs')},total:${cad.runtime.read<Object>('sketch.synchronize.timing.totalMs')}}'
        '; commandTrace=${cad.runtime.read<Object>('command.trace')}'
        '; managerTrace=${commands.manager.trace.join(' | ')}',
  );
  if (failure != null) fail('$operation callback failed: $failure');
  await _settle(tester);
}

Future<void> _awaitFuture(
  WidgetTester tester,
  Future<void> action,
  String label,
) async {
  var completed = false;
  Object? failure;
  action.then<void>((_) => completed = true).catchError((Object error) {
    failure = error;
    completed = true;
  });
  for (var attempt = 0; attempt < 240 && !completed; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
  }
  expect(completed, isTrue, reason: '$label did not complete');
  if (failure != null) fail('$label failed: $failure');
  await _settle(tester);
}

List<CadDocumentEntity> _liveLines(DesktopCadController cad) =>
    cad.runtime.document?.entities.values
        .where(
          (entity) =>
              entity.data['deleted'] != true &&
              entity.data['sketchEntity'] is Map &&
              (entity.data['sketchEntity'] as Map)['type'] == 'line',
        )
        .toList(growable: false) ??
    const [];

List<CadDocumentEntity> _liveCoincidents(DesktopCadController cad) =>
    cad.runtime.document?.entities.values
        .where(
          (entity) =>
              entity.data['deleted'] != true &&
              entity.data['constraint'] is Map &&
              (entity.data['constraint'] as Map)['type'] == 'coincident',
        )
        .toList(growable: false) ??
    const [];

CadDocumentEntity _sketchRoot(DesktopCadController cad) =>
    cad.runtime.document!.entities.values.firstWhere(
      (entity) =>
          entity.data['deleted'] != true &&
          entity.data['authoringRoot'] == true &&
          entity.data['sketch'] is Map,
    );

List<CadDocumentEntity> _childrenOf(DesktopCadController cad, String id) => cad
    .runtime
    .document!
    .entities
    .values
    .where(
      (entity) =>
          entity.data['deleted'] != true && entity.data['parentSketchId'] == id,
    )
    .toList(growable: false);

bool _isVertical(CadDocumentEntity line) {
  final points = _endpoints(line);
  return (points[0].x - points[1].x).abs() <= 1e-6 &&
      (points[0].y - points[1].y).abs() > 1e-6;
}

bool _isHorizontal(CadDocumentEntity line) {
  final points = _endpoints(line);
  return (points[0].y - points[1].y).abs() <= 1e-6 &&
      (points[0].x - points[1].x).abs() > 1e-6;
}

double _lineLength(CadDocumentEntity line) {
  final points = _endpoints(line);
  final delta = points[1] - points[0];
  return math.sqrt(delta.dot(delta));
}

List<Vector3> _endpoints(CadDocumentEntity line) {
  final raw = line.data['sketchEntity'] as Map;
  final parameters = raw['parameters'] as Map;
  return [_vector(parameters['start']), _vector(parameters['end'])];
}

Vector3 _vector(Object? value) {
  final list = value as List;
  return Vector3(
    (list[0] as num).toDouble(),
    (list[1] as num).toDouble(),
    list.length > 2 ? (list[2] as num).toDouble() : 0,
  );
}

double _maxCornerGap(List<CadDocumentEntity> lines) {
  final endpoints = [for (final line in lines) ..._endpoints(line)];
  if (endpoints.length < 2) return double.infinity;
  var worst = 0.0;
  for (var i = 0; i < endpoints.length; i++) {
    var nearest = double.infinity;
    for (var j = 0; j < endpoints.length; j++) {
      if (i == j || i ~/ 2 == j ~/ 2) continue;
      final delta = endpoints[i] - endpoints[j];
      nearest = math.min(nearest, math.sqrt(delta.dot(delta)));
    }
    worst = math.max(worst, nearest);
  }
  return worst;
}

double _parallelSeparation(List<CadDocumentEntity> lines) {
  expect(lines, hasLength(2));
  final first = _endpoints(lines[0]);
  final second = _endpoints(lines[1]);
  final direction = first[1] - first[0];
  final length = math.sqrt(direction.dot(direction));
  final normal = Vector3(-direction.y / length, direction.x / length, 0);
  final delta = second[0] - first[0];
  return delta.dot(normal).abs();
}

class _WorkspaceKernelGate
    implements GeometryKernelAPI, SurfaceOperationKernelAPI {
  @override
  KernelDescriptor get descriptor => const KernelDescriptor(
    id: 'sketch-flow-kernel-gate',
    name: 'Sketch flow kernel gate',
    version: '1',
    capabilities: KernelCapabilities({}),
    vendor: 'FLCAD',
  );

  @override
  Future<KernelHealth> healthCheck() async =>
      KernelHealth(KernelHealthStatus.healthy, 'ok', DateTime(2000));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

int _constraintExecutions(DesktopCommandCoordinator commands) => commands
    .manager
    .history
    .where(
      (entry) =>
          entry.commandId == 'reverse.sketch.constraint' &&
          entry.operation == 'execute',
    )
    .length;

dynamic _sketchController(WidgetTester tester) =>
    (tester.widget(
              find.byWidgetPredicate(
                (widget) =>
                    widget.runtimeType.toString() ==
                    '_SketchWorkspaceFoundation',
              ),
            )
            as dynamic)
        .controller;

SketchArc _engineArc(DesktopCadController cad) => cad.runtime
    .read<SketchEngineApi>('sketch.api')!
    .engine
    .entities
    .values
    .whereType<SketchArc>()
    .single;

List<SketchLine> _engineLines(DesktopCadController cad) => cad.runtime
    .read<SketchEngineApi>('sketch.api')!
    .engine
    .entities
    .values
    .whereType<SketchLine>()
    .toList(growable: false);

SketchVector _arcEndpoint(SketchArc arc, String endpoint) {
  final center = SketchVector.fromJson(arc.parameters['center']);
  final radius = (arc.parameters['radius'] as num).toDouble();
  final angle =
      (arc.parameters[endpoint == 'start' ? 'startAngle' : 'endAngle'] as num)
          .toDouble();
  return SketchVector(
    center.x + radius * math.cos(angle),
    center.y + radius * math.sin(angle),
    center.z,
  );
}

String _parameterSnapshot(SketchEntity entity) => entity.parameters.toString();

({double maxEndpointGap, double maxTangencyResidual, double sweep})
_filletResiduals(DesktopCadController cad) {
  final arc = _engineArc(cad);
  final center = SketchVector.fromJson(arc.parameters['center']);
  final startAngle = (arc.parameters['startAngle'] as num).toDouble();
  final endAngle = (arc.parameters['endAngle'] as num).toDouble();
  final lines = _engineLines(cad);
  var maxGap = 0.0;
  var maxTangent = 0.0;
  for (final endpoint in ['start', 'end']) {
    final arcPoint = _arcEndpoint(arc, endpoint);
    var bestGap = double.infinity;
    var bestLine = lines.first;
    for (final line in lines) {
      for (final lineEndpoint in ['start', 'end']) {
        final linePoint = SketchVector.fromJson(
          line.parameters[lineEndpoint == 'start' ? 'start' : 'end'],
        );
        final gap = _distanceBetween(arcPoint, linePoint);
        if (gap < bestGap) {
          bestGap = gap;
          bestLine = line;
        }
      }
    }
    final lineStart = SketchVector.fromJson(bestLine.parameters['start']);
    final lineEnd = SketchVector.fromJson(bestLine.parameters['end']);
    final direction = lineEnd - lineStart;
    final radial = arcPoint - center;
    final directionLength = _vectorLength(direction);
    final radialLength = _vectorLength(radial);
    final tangent =
        (radial.dot(direction)).abs() / (radialLength * directionLength);
    maxGap = math.max(maxGap, bestGap);
    maxTangent = math.max(maxTangent, tangent);
  }
  return (
    maxEndpointGap: maxGap,
    maxTangencyResidual: maxTangent,
    sweep: (endAngle - startAngle).abs(),
  );
}

double _distanceBetween(SketchVector a, SketchVector b) => _vectorLength(a - b);

double _vectorLength(SketchVector value) =>
    math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z);

double _gap(
  DesktopCadController cad,
  String lineId,
  String lineEndpoint,
  String arcId,
  String arcEndpoint,
) {
  final api = cad.runtime.read<SketchEngineApi>('sketch.api')!;
  final line = api.entity(lineId)! as SketchLine;
  final arc = api.entity(arcId)! as SketchArc;
  final linePoint = SketchVector.fromJson(
    line.parameters[lineEndpoint == 'start' ? 'start' : 'end'],
  );
  final delta = _arcEndpoint(arc, arcEndpoint) - linePoint;
  return math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z);
}

double _tangentDistanceResidual(DesktopCadController cad) {
  final line = _engineLines(cad).single;
  final arc = _engineArc(cad);
  final start = SketchVector.fromJson(line.parameters['start']);
  final end = SketchVector.fromJson(line.parameters['end']);
  final center = SketchVector.fromJson(arc.parameters['center']);
  final radius = (arc.parameters['radius'] as num).toDouble();
  final direction = end - start;
  final length = math.sqrt(
    direction.x * direction.x + direction.y * direction.y,
  );
  final offset = center - start;
  final distance =
      (offset.x * direction.y - offset.y * direction.x).abs() / length;
  return (distance - radius).abs();
}

double _tangentAlignment(DesktopCadController cad, String? endpoint) {
  final line = _engineLines(cad).single;
  final arc = _engineArc(cad);
  final start = SketchVector.fromJson(line.parameters['start']);
  final end = SketchVector.fromJson(line.parameters['end']);
  final center = SketchVector.fromJson(arc.parameters['center']);
  final direction = end - start;
  final directionLength = math.sqrt(
    direction.x * direction.x + direction.y * direction.y,
  );
  late final SketchVector radial;
  if (endpoint == null) {
    final denominator = direction.x * direction.x + direction.y * direction.y;
    final t =
        ((center.x - start.x) * direction.x +
            (center.y - start.y) * direction.y) /
        denominator;
    radial = start + direction.scale(t) - center;
  } else {
    radial = _arcEndpoint(arc, endpoint) - center;
  }
  final radialLength = math.sqrt(
    radial.x * radial.x + radial.y * radial.y + radial.z * radial.z,
  );
  return radial.dot(direction).abs() / (radialLength * directionLength);
}

Future<void> _applyPointCoincidence(
  WidgetTester tester,
  DesktopCadController cad,
  dynamic controller, {
  required String lineId,
  required String lineEndpoint,
  required String arcId,
  required String arcEndpoint,
  bool arcFirst = false,
}) async {
  controller.beginSketchPointReferenceCapture('coincident');
  await _settle(tester);
  final viewport = find.byType(IntegratedCadViewportWidget);
  final view = tester.widget<IntegratedCadViewportWidget>(viewport);
  expect(view.onSketchEntityPick, isNotNull);
  final line = _engineLines(cad).singleWhere((item) => item.id == lineId);
  final arc = _engineArc(cad);
  Vector3 pointFor(String endpoint, {required bool arcPoint}) {
    final local = arcPoint
        ? _arcEndpoint(arc, endpoint)
        : SketchVector.fromJson(
            line.parameters[endpoint == 'start' ? 'start' : 'end'],
          );
    return Vector3(local.x, local.y, local.z);
  }

  final first = arcFirst
      ? _endpointPick(
          cad.runtime.document!.entities[arcId]!,
          pointFor(arcEndpoint, arcPoint: true),
        )
      : _endpointPick(
          cad.runtime.document!.entities[lineId]!,
          pointFor(lineEndpoint, arcPoint: false),
        );
  final second = arcFirst
      ? _endpointPick(
          cad.runtime.document!.entities[lineId]!,
          pointFor(lineEndpoint, arcPoint: false),
        )
      : _endpointPick(
          cad.runtime.document!.entities[arcId]!,
          pointFor(arcEndpoint, arcPoint: true),
        );
  await tester.runAsync(() async {
    view.onSketchEntityPick!(first);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    view.onSketchEntityPick!(second);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await _settle(tester);
  expect(controller.sketchPointReferenceCaptureReferences, [
    arcFirst ? '$arcId:$arcEndpoint' : '$lineId:$lineEndpoint',
    arcFirst ? '$lineId:$lineEndpoint' : '$arcId:$arcEndpoint',
  ]);
  final apply = find.widgetWithText(FilledButton, 'Aplicar');
  expect(apply, findsOneWidget);
  await tester.ensureVisible(apply);
  await tester.tap(apply);
  await _settle(tester);
}

List<String> _visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? '')
    .where((value) => value.isNotEmpty)
    .toList(growable: false);
