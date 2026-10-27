import 'dart:io';
import 'dart:math' as math;

import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flcad_mobile/core/sketch_engine/integration/canonical_sketch_authority.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dll = Platform.environment['FLCAD_SOURCE_OCC_DLL'];
  test(
    'canonical Sketch dimension edit rebuilds a real OCCT BRep',
    () async {
      final ffi = OpenCascadeFFI.load(path: dll);
      await ffi.initialize();
      final directory = await Directory.systemTemp.createTemp('sketch-occ-');
      addTearDown(() async {
        await directory.delete(recursive: true);
        await ffi.shutdown();
      });
      final authority = CanonicalSketchAuthority.open(directory);
      authority.sketch.createSketch('OCCT profile');
      final circle = authority.sketch.builders.circle.build(
        const SketchVector(0, 0),
        5,
      );
      final radius = authority.constraints.createDrivingDimension(
        type: SketchDimensionType.radius,
        references: [circle.id],
        value: 5,
      );
      await authority.solve();

      Future<({String face, List<double> bounds})> rebuild() async {
        final entity = authority.sketch.entity(circle.id)! as SketchCircle;
        final center = SketchVector.fromJson(entity.parameters['center']);
        final radius = (entity.parameters['radius'] as num).toDouble();
        final points = <double>[];
        for (var index = 0; index < 64; index++) {
          final angle = 2 * math.pi * index / 64;
          points
            ..add(center.x + radius * math.cos(angle))
            ..add(center.y + radius * math.sin(angle))
            ..add(0);
        }
        final face = await ffi.createShape(
          'CREATE PLANAR FACE',
          {'profilePoints': points},
          CADShapeType.face,
        );
        final display = await ffi.inspectDisplayGeometry(face.token);
        final bounds = (display['bounds'] as List).cast<num>();
        await ffi.destroyShape(face.token);
        return (
          face: face.token,
          bounds: [
            bounds[0].toDouble(),
            bounds[3].toDouble(),
            bounds[1].toDouble(),
            bounds[4].toDouble(),
          ],
        );
      }

      final first = await rebuild();
      authority.driveDimension(radius.id, 8);
      final second = await rebuild();
      expect(second.bounds[1] - second.bounds[0], closeTo(16, .05));
      expect(second.bounds[3] - second.bounds[2], closeTo(16, .05));
      expect(first.bounds[1] - first.bounds[0], closeTo(10, .05));
      expect(authority.undoParameterEdit(), isTrue);
      expect(authority.sketch.entity(circle.id)!.parameters['radius'], 5);
      expect(authority.redoParameterEdit(), isTrue);
      expect(authority.sketch.entity(circle.id)!.parameters['radius'], 8);
    },
    skip: dll == null ? 'FLCAD_SOURCE_OCC_DLL is not set' : false,
  );
}
