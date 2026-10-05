import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/sketch_surface_preview_builder.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';

void main() {
  const builder = SketchSurfacePreviewBuilder();

  test('creates a translucent disposable mesh from the actual profile', () {
    final preview = builder.build(
      entities: [
        SketchLine(const SketchVector(0, 0), const SketchVector(4, 0)),
        SketchLine(const SketchVector(4, 0), const SketchVector(4, 2)),
        SketchLine(const SketchVector(4, 2), const SketchVector(0, 2)),
        SketchLine(const SketchVector(0, 2), const SketchVector(0, 0)),
      ],
      coordinates: const SketchCoordinateSystem(),
    );

    expect(preview.kind, CadSceneEntityKind.preview);
    expect(preview.transparent, isTrue);
    expect(preview.geometry['previewOnly'], isTrue);
    expect(preview.geometry['displayColor'], 'surfacePreviewBlue');
    expect((preview.geometry['triangles'] as List), hasLength(6));
  });

  test('supports circular profiles and respects Sketch coordinates', () {
    final preview = builder.build(
      entities: [SketchCircle(const SketchVector(2, 3), 5)],
      coordinates: const SketchCoordinateSystem(
        origin: SketchVector(10, 20, 30),
      ),
    );
    final nodes = (preview.geometry['nodes'] as List).cast<double>();

    expect(nodes, isNotEmpty);
    expect(nodes[2], closeTo(30, 1e-9));
    expect((preview.geometry['triangles'] as List), isNotEmpty);
  });

  test('rejects open profiles instead of inventing a surface', () {
    expect(
      () => builder.build(
        entities: [
          SketchLine(const SketchVector(0, 0), const SketchVector(1, 0)),
        ],
        coordinates: const SketchCoordinateSystem(),
      ),
      throwsStateError,
    );
  });

  test('uses closed profile and ignores loose section leftovers', () {
    final profile = builder.buildProfile(
      entities: [
        SketchLine(const SketchVector(0, 0), const SketchVector(4, 0)),
        SketchLine(const SketchVector(4, 0), const SketchVector(4, 2)),
        SketchLine(const SketchVector(4, 2), const SketchVector(0, 2)),
        SketchLine(const SketchVector(0, 2), const SketchVector(0, 0)),
        SketchLine(const SketchVector(10, 10), const SketchVector(11, 10)),
      ],
      coordinates: const SketchCoordinateSystem(),
    );

    expect(profile.loops, hasLength(1));
    expect(profile.triangles, hasLength(6));
  });
}
