import '../builders/constraint_builders.dart';
import '../diagnostics/constraint_diagnostics.dart';
import '../engine/constraint_engine.dart';
import '../integration/arc_radius_edit_planner.dart';
import '../models/constraint_models.dart';

class ConstraintApi {
  ConstraintApi(this.engine) : builders = ConstraintBuilders(engine);
  final ConstraintEngine engine;
  final ConstraintBuilders builders;
  List<SketchConstraint> get constraints =>
      List.unmodifiable(engine.constraints.values);
  List<SketchDimension> get dimensions =>
      List.unmodifiable(engine.dimensions.values);
  Future<ConstraintSolveResult> solve({
    Iterable<String>? only,
    String? operationId,
  }) => engine.solve(only: only, operationId: operationId);
  void enforceDrivingDimensions() => engine.enforceDrivingDimensions();
  void refreshDrivenDimensions() => engine.refreshDrivenDimensions();
  Future<ConstraintSolveResult> rebuild() => engine.rebuild();
  Future<void> load() => engine.load();
  Future<void> persist() => engine.persist();
  void delete(String id) => engine.delete(id);
  void enable(String id) => engine.enable(id);
  void disable(String id) => engine.disable(id);
  void suppress(String id) => engine.suppress(id);
  void setVisible(String id, bool visible) => engine.setVisible(id, visible);
  SketchDimension updateDimension(
    String id, {
    double? value,
    double? labelX,
    double? labelY,
    String? anchorReference,
  }) => engine.updateDimension(
    id,
    value: value,
    labelX: labelX,
    labelY: labelY,
    anchorReference: anchorReference,
  );
  void deleteDimension(String id) => engine.deleteDimension(id);
  SketchDimension createDrivingDimension({
    required SketchDimensionType type,
    required List<String> references,
    required double value,
    String? anchorReference,
    double labelX = 0,
    double labelY = 0,
    bool confirmAdjacent = false,
    ArcRadiusEditPlan? expectedRadiusPlan,
    bool deferDirectionalConstraints = false,
  }) => engine.createDrivingDimension(
    type: type,
    references: references,
    value: value,
    anchorReference: anchorReference,
    labelX: labelX,
    labelY: labelY,
    confirmAdjacent: confirmAdjacent,
    expectedRadiusPlan: expectedRadiusPlan,
    deferDirectionalConstraints: deferDirectionalConstraints,
  );
  SketchDimension driveDimension(
    String id,
    double value, {
    String? anchorReference,
    bool confirmAdjacent = false,
    ArcRadiusEditPlan? expectedRadiusPlan,
    bool deferDirectionalConstraints = false,
  }) => engine.driveDimension(
    id,
    value,
    anchorReference: anchorReference,
    confirmAdjacent: confirmAdjacent,
    expectedRadiusPlan: expectedRadiusPlan,
    deferDirectionalConstraints: deferDirectionalConstraints,
  );
  SketchDimension createDrivenDimension({
    required SketchDimensionType type,
    required List<String> references,
    required double value,
    String? anchorReference,
    double labelX = 0,
    double labelY = 0,
  }) => engine.createDrivenDimension(
    type: type,
    references: references,
    value: value,
    anchorReference: anchorReference,
    labelX: labelX,
    labelY: labelY,
  );
  SketchDimension convertDimensionMode(String id, {required bool driven}) =>
      engine.convertDimensionMode(id, driven: driven);
  bool undoDimensionEdit() {
    final target = engine.undoTarget;
    // This paired API is reserved for dimension commands that also changed
    // Sketch geometry. Constraint-only Driven creation/conversion is undone
    // by the constraint stack and must never consume an unrelated geometry
    // entry.
    if (target == null ||
        target.contains('create-driven') ||
        target.contains('convert-dimension')) {
      return false;
    }
    if (engine.sketch.engine.undoTarget != target) return false;
    final sketchUndone = engine.sketch.engine.undo();
    if (!sketchUndone) return false;
    final constraintUndone = engine.undo();
    if (!constraintUndone) {
      engine.sketch.engine.redo();
      return false;
    }
    return constraintUndone && sketchUndone;
  }

  bool redoDimensionEdit() {
    final target = engine.redoTarget;
    if (target == null ||
        target.contains('create-driven') ||
        target.contains('convert-dimension')) {
      return false;
    }
    if (engine.sketch.engine.redoTarget != target) return false;
    final constraintRedone = engine.redo();
    if (!constraintRedone) return false;
    final sketchRedone = engine.sketch.engine.redo();
    if (!sketchRedone) {
      engine.undo();
      return false;
    }
    return constraintRedone && sketchRedone;
  }

  bool undoSketchEdit({
    String? expectedSketchTarget,
    String? expectedConstraintTarget,
  }) {
    if (!engine.sketch.engine.canUndo || !engine.canUndo) return false;
    if (expectedSketchTarget != null &&
        engine.sketch.engine.undoTarget != expectedSketchTarget) {
      return false;
    }
    if (expectedConstraintTarget != null &&
        engine.undoTarget != expectedConstraintTarget) {
      return false;
    }
    final sketchUndone = engine.sketch.engine.undo();
    if (!sketchUndone) return false;
    try {
      final constraintUndone = engine.undoConstraintsOnly();
      if (constraintUndone) return true;
    } catch (_) {
      final constraintRestored = engine.redoConstraintsOnly();
      final sketchRestored = engine.sketch.engine.redo();
      if (!constraintRestored || !sketchRestored) {
        throw StateError('Sketch undo compensation failed');
      }
      return false;
    }
    final sketchRestored = engine.sketch.engine.redo();
    if (!sketchRestored) {
      throw StateError('Sketch undo compensation failed');
    }
    return false;
  }

  bool redoSketchEdit({
    String? expectedSketchTarget,
    String? expectedConstraintTarget,
  }) {
    if (!engine.sketch.engine.canRedo || !engine.canRedo) return false;
    if (expectedSketchTarget != null &&
        engine.sketch.engine.redoTarget != expectedSketchTarget) {
      return false;
    }
    if (expectedConstraintTarget != null &&
        engine.redoTarget != expectedConstraintTarget) {
      return false;
    }
    final sketchRedone = engine.sketch.engine.redo();
    if (!sketchRedone) return false;
    try {
      final constraintRedone = engine.redoConstraintsOnly();
      if (constraintRedone) return true;
    } catch (_) {
      final constraintRestored = engine.undoConstraintsOnly();
      final sketchRestored = engine.sketch.engine.undo();
      if (!constraintRestored || !sketchRestored) {
        throw StateError('Sketch redo compensation failed');
      }
      return false;
    }
    final sketchRestored = engine.sketch.engine.undo();
    if (!sketchRestored) {
      throw StateError('Sketch redo compensation failed');
    }
    return false;
  }
}
