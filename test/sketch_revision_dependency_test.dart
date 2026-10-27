import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/sketch_factory.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';

void main() {
  test('owning Sketch revision tracks geometry lifecycle changes', () async {
    final project = await Directory.systemTemp.createTemp('sketch-revision-');
    addTearDown(() => project.delete(recursive: true));
    final api = const SketchEngineFactory().create(project);
    final sketch = api.createSketch('revision-test');
    final initial = sketch.version;
    final line = api.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(4, 0),
    );
    expect(sketch.version, greaterThan(initial));
    final afterCreate = sketch.version;
    api.updateParameters(line.id, {'endX': 5});
    expect(sketch.version, greaterThan(afterCreate));
    final afterEdit = sketch.version;
    api.deleteEntity(line.id);
    expect(sketch.version, greaterThan(afterEdit));
  });
}
