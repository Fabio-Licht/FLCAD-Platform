import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/sketch_surface_preview_builder.dart';
import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/core/sketch_editor/health/sketch_health_analyzer.dart';
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

  test(
    'surface profile does not reuse a stale closed loop as the active profile',
    () {
      // Same entity filter the controller applies via _surfaceProfileEntities:
      // keep only the entities the analyzer marked as the active profile.
      const analyzer = SketchHealthAnalyzer();
      final entities = <SketchEntity>[
        SketchLine(
          const SketchVector(0, 0),
          const SketchVector(1, 0),
          id: 'old-a',
        ),
        SketchLine(
          const SketchVector(1, 0),
          const SketchVector(1, 1),
          id: 'old-b',
        ),
        SketchLine(
          const SketchVector(1, 1),
          const SketchVector(0, 1),
          id: 'old-c',
        ),
        SketchLine(
          const SketchVector(0, 1),
          const SketchVector(0, 0),
          id: 'old-d',
        ),
        SketchLine(
          const SketchVector(20, 0),
          const SketchVector(30, 0),
          id: 'new-a',
        ),
        SketchLine(
          const SketchVector(30, 0),
          const SketchVector(30, 10),
          id: 'new-b',
        ),
        SketchLine(
          const SketchVector(30, 10),
          const SketchVector(20, 10),
          id: 'new-c',
        ),
      ];

      final health = analyzer.analyze(entities);
      expect(health.readyForSurface, isFalse);

      final activeIds = health.activeProfileEntityIds;
      final profileEntities = activeIds.isEmpty
          ? entities
          : entities.where((e) => activeIds.contains(e.id)).toList();

      // The stale closed loop is not part of the preview profile.
      expect(
        profileEntities.map((e) => e.id),
        isNot(containsAll(<String>['old-a', 'old-b', 'old-c', 'old-d'])),
      );
      expect(
        profileEntities.map((e) => e.id),
        containsAll(<String>['new-a', 'new-b', 'new-c']),
      );

      // And because the active profile is genuinely open, the preview cannot
      // silently close it over the stale loop.
      expect(
        () => builder.build(
          entities: profileEntities,
          coordinates: const SketchCoordinateSystem(),
        ),
        throwsStateError,
      );
    },
  );
}
