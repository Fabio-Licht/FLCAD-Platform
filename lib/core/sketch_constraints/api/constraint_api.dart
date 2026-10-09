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
  Future<ConstraintSolveResult> solve({Iterable<String>? only}) =>
      engine.solve(only: only);
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
  }) => engine.createDrivingDimension(
    type: type,
    references: references,
    value: value,
    anchorReference: anchorReference,
    labelX: labelX,
    labelY: labelY,
    confirmAdjacent: confirmAdjacent,
    expectedRadiusPlan: expectedRadiusPlan,
  );
  SketchDimension driveDimension(
    String id,
    double value, {
    String? anchorReference,
    bool confirmAdjacent = false,
    ArcRadiusEditPlan? expectedRadiusPlan,
  }) => engine.driveDimension(
    id,
    value,
    anchorReference: anchorReference,
    confirmAdjacent: confirmAdjacent,
    expectedRadiusPlan: expectedRadiusPlan,
  );
  bool undoDimensionEdit() {
    final sketchUndone = engine.sketch.engine.undo();
    final constraintUndone = engine.undo();
    return constraintUndone && sketchUndone;
  }

  bool redoDimensionEdit() {
    final constraintRedone = engine.redo();
    final sketchRedone = engine.sketch.engine.redo();
    return constraintRedone && sketchRedone;
  }
}
