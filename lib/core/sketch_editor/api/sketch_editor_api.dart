import '../../sketch_engine/entities/sketch_entities.dart';
import '../../sketch_engine/models/sketch_models.dart';
import '../engine/sketch_editor_engine.dart';
import '../models/editor_models.dart';
import '../snapping/editor_snapping.dart';

class SketchEditorApi {
  const SketchEditorApi(this.engine);
  final SketchEditorEngine engine;
  EditorOperation preview(
    SketchToolType tool,
    List<SketchVector> points, {
    Map<String, dynamic>? parameters,
  }) => engine.start(tool, points, parameters: parameters);
  List<SketchEntity> confirm(String previewId) => engine.confirm(previewId);
  void cancel(String previewId) => engine.cancel(previewId);
  void edit(
    SketchToolType tool,
    Iterable<String> ids, {
    SketchVector? delta,
    double value = 1,
    Map<String, dynamic> parameters = const {},
    bool confirmConstrained = false,
  }) => engine.edit(
    tool,
    ids,
    delta: delta,
    value: value,
    parameters: parameters,
    confirmConstrained: confirmConstrained,
  );
  bool undo() => engine.undo();
  bool redo() => engine.redo();
  void editCornerFeature(String id, double value) =>
      engine.editCornerFeature(id, value);
  void trimIntersection(
    String firstId,
    SketchVector firstKeepPoint,
    String secondId,
    SketchVector secondKeepPoint,
  ) => engine.trimIntersection(
    firstId,
    firstKeepPoint,
    secondId,
    secondKeepPoint,
  );
  void trimEndpointToNearestIntersection(String id, SketchVector point) =>
      engine.trimEndpointToNearestIntersection(id, point);
  bool hasEndpointBoundedTrimCut(String id) =>
      engine.hasEndpointBoundedTrimCut(id);
  bool hasRemovableEndpointOverhang(String id, SketchVector point) =>
      engine.hasRemovableEndpointOverhang(id, point);
  bool trimEndpointBoundedPortion(String id, SketchVector point) =>
      engine.trimEndpointBoundedPortion(id, point);
  DegreesOfFreedom get dof => engine.readDof();
  SketchQuality get quality => engine.quality();
  List<SketchRecommendation> get recommendations => engine.recommendations();
  SnapCandidate? snap(SketchVector cursor) =>
      engine.snapping.snap(cursor, engine.sketch.engine.entities.values);
  Future<void> persist() => engine.persist();
}
