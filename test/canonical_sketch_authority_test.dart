import 'dart:io';

import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/canonical_sketch_authority.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('geometry and constraints share one canonical engine', () async {
    final directory = await Directory.systemTemp.createTemp('canonical-sketch-');
    addTearDown(() => directory.delete(recursive: true));
    final authority = CanonicalSketchAuthority.open(directory);
    expect(authority.isCanonical, isTrue);

    authority.sketch.createSketch('Canonical');
    final line = authority.sketch.builders.line.build(
      const SketchVector(0, 0),
      const SketchVector(10, 0),
    );
    final dimension = authority.constraints.createDrivingDimension(
      type: SketchDimensionType.linear,
      references: [line.id],
      value: 10,
    );
    await authority.solve();
    authority.driveDimension(dimension.id, 25);
    expect(
      (authority.sketch.entity(line.id)!.parameters['length'] as num).toDouble(),
      closeTo(25, 1e-9),
    );
    expect(authority.undoParameterEdit(), isTrue);
    expect(
      (authority.sketch.entity(line.id)!.parameters['length'] as num).toDouble(),
      closeTo(10, 1e-9),
    );
    expect(authority.redoParameterEdit(), isTrue);
    expect(
      (authority.sketch.entity(line.id)!.parameters['length'] as num).toDouble(),
      closeTo(25, 1e-9),
    );
    await authority.persist();
  });
}
