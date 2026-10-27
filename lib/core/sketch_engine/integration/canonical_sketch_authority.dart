import 'dart:io';

import '../../sketch_constraints/api/constraint_api.dart';
import '../../sketch_constraints/diagnostics/constraint_diagnostics.dart';
import '../../sketch_constraints/diagnostics/mathematical_dof_analyzer.dart';
import '../../sketch_constraints/engine/constraint_engine.dart';
import '../../sketch_constraints/models/constraint_models.dart';
import '../../sketch_constraints/repository/constraint_repository.dart';
import '../api/sketch_engine_api.dart';
import 'sketch_factory.dart';
import '../models/sketch_models.dart';

/// The single application-facing authority for an editable parametric Sketch.
///
/// The geometry engine remains the owner of entities and history; the
/// constraint engine remains the owner of constraints and dimensions. Both
/// are bound to the same SketchEngine instance, so a dimensional edit and its
/// geometric consequence cannot silently diverge into two models.
final class CanonicalSketchAuthority {
  CanonicalSketchAuthority({required this.sketch, required this.constraints})
    : assert(
        identical(constraints.engine.sketch.engine, sketch.engine),
        'Sketch and constraint APIs must share one SketchEngine.',
      );

  factory CanonicalSketchAuthority.open(Directory projectDirectory) {
    final sketch = const SketchEngineFactory().create(projectDirectory);
    final constraints = ConstraintApi(
      ConstraintEngine(
        sketch: sketch,
        repository: ConstraintRepository(projectDirectory),
      ),
    );
    return CanonicalSketchAuthority(sketch: sketch, constraints: constraints);
  }

  final SketchEngineApi sketch;
  final ConstraintApi constraints;

  Sketch get activeSketch => sketch.engine.activeSketch;

  /// True only when both public APIs are backed by the same canonical engine.
  bool get isCanonical =>
      identical(constraints.engine.sketch.engine, sketch.engine);

  Future<ConstraintSolveResult> solve({String? operationId}) =>
      constraints.solve(operationId: operationId);

  Future<ConstraintSolveResult> rebuild() => constraints.rebuild();

  /// Mathematical diagnostic for the subset with explicit residual support.
  /// It never disguises unsupported geometry or constraints as an exact DOF.
  MathematicalDofResult analyzeDof([
    MathematicalDofAnalyzer analyzer = const MathematicalDofAnalyzer(),
  ]) => analyzer.analyze(sketch, constraints);

  SketchDimension driveDimension(String id, double value) =>
      constraints.driveDimension(id, value);

  bool undoParameterEdit() => constraints.undoDimensionEdit();

  bool redoParameterEdit() => constraints.redoDimensionEdit();

  bool undoSketchEdit({
    String? expectedSketchTarget,
    String? expectedConstraintTarget,
  }) => constraints.undoSketchEdit(
    expectedSketchTarget: expectedSketchTarget,
    expectedConstraintTarget: expectedConstraintTarget,
  );

  bool redoSketchEdit({
    String? expectedSketchTarget,
    String? expectedConstraintTarget,
  }) => constraints.redoSketchEdit(
    expectedSketchTarget: expectedSketchTarget,
    expectedConstraintTarget: expectedConstraintTarget,
  );

  Future<void> load() async {
    await sketch.load();
    await constraints.load();
  }

  Future<void> persist() async {
    await sketch.persist();
    await constraints.persist();
  }
}
