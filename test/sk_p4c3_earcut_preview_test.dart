import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/sketch_surface_preview_builder.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';

void main() {
  const builder = SketchSurfacePreviewBuilder();
  const coordinates = SketchCoordinateSystem();

  test('triangulates a simple loop with Earcut-backed preview geometry', () {
    final profile = builder.buildProfile(
      entities: _rectangle('outer', 0, 0, 10, 10),
      coordinates: coordinates,
    );

    expect(profile.loops, hasLength(1));
    expect(profile.triangles, hasLength(6));
    expect(_triangleArea(profile), closeTo(100, 1e-9));
  });

  test('subtracts one and two direct holes from the preview area', () {
    final oneHole = builder.buildProfile(
      entities: [
        ..._rectangle('outer', 0, 0, 10, 10),
        ..._rectangle('hole', 2, 2, 8, 8),
      ],
      coordinates: coordinates,
    );
    final twoHoles = builder.buildProfile(
      entities: [
        ..._rectangle('outer', 0, 0, 10, 10),
        ..._rectangle('hole-a', 1, 1, 3, 3),
        ..._rectangle('hole-b', 7, 7, 9, 9),
      ],
      coordinates: coordinates,
    );

    expect(oneHole.loops, hasLength(2));
    expect(_triangleArea(oneHole), closeTo(64, 1e-9));
    expect(twoHoles.loops, hasLength(3));
    expect(_triangleArea(twoHoles), closeTo(92, 1e-9));
  });

  test('renders an island inside a hole as an independent material region', () {
    final profile = builder.buildProfile(
      entities: [
        ..._rectangle('outer', 0, 0, 20, 20),
        ..._rectangle('hole', 2, 2, 18, 18),
        ..._rectangle('island', 5, 5, 10, 10),
      ],
      coordinates: coordinates,
    );

    expect(profile.loops, hasLength(3));
    expect(_triangleArea(profile), closeTo(169, 1e-9));
    final centroidsInHole = _centroidsInside(profile, profile.loops[1]);
    expect(centroidsInHole, isNotEmpty);
    expect(
      centroidsInHole.every((centroid) => _inside(centroid, profile.loops[2])),
      isTrue,
    );
  });

  test(
    'supports independent outers, reversed winding, and scaled profiles',
    () {
      final profile = builder.buildProfile(
        entities: [
          ..._rectangle('a', 0, 0, 4, 3),
          ..._rectangle('b', 10, 10, 12, 12, reverse: true),
        ],
        coordinates: coordinates,
      );
      final small = SketchSurfacePreviewBuilder(tolerance: 1e-9).buildProfile(
        entities: _rectangle('small', 0, 0, .001, .002),
        coordinates: coordinates,
      );

      expect(profile.loops, hasLength(2));
      expect(_triangleArea(profile), closeTo(16, 1e-9));
      expect(_triangleArea(small), closeTo(0.000002, 1e-12));
    },
  );

  test('rejects crossing and tangent/ambiguous regions', () {
    expect(
      () => builder.buildProfile(
        entities: [
          ..._rectangle('outer', 0, 0, 10, 10),
          ..._rectangle('crossing', 5, -1, 12, 5),
        ],
        coordinates: coordinates,
      ),
      throwsStateError,
    );
    expect(
      () => builder.buildProfile(
        entities: [
          ..._rectangle('outer', 0, 0, 10, 10),
          ..._rectangle('tangent', 10, 2, 12, 4),
        ],
        coordinates: coordinates,
      ),
      throwsStateError,
    );
  });

  test('does not mutate source entities while building transient preview', () {
    final entities = _rectangle('profile', 0, 0, 4, 2);
    final before = entities.map((entity) => entity.toJson()).toList();

    builder.build(entities: entities, coordinates: coordinates);

    expect(entities.map((entity) => entity.toJson()).toList(), before);
  });
}

List<SketchLine> _rectangle(
  String prefix,
  double left,
  double bottom,
  double right,
  double top, {
  bool reverse = false,
}) {
  final points = <SketchVector>[
    SketchVector(left, bottom),
    SketchVector(right, bottom),
    SketchVector(right, top),
    SketchVector(left, top),
  ];
  final ordered = reverse ? points.reversed.toList() : points;
  return [
    for (var i = 0; i < ordered.length; i++)
      SketchLine(
        ordered[i],
        ordered[(i + 1) % ordered.length],
        id: '$prefix-$i',
      ),
  ];
}

double _triangleArea(SketchSurfaceProfile profile) {
  var area = 0.0;
  for (var i = 0; i < profile.triangles.length; i += 3) {
    final a = _node(profile, profile.triangles[i]);
    final b = _node(profile, profile.triangles[i + 1]);
    final c = _node(profile, profile.triangles[i + 2]);
    area += ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)).abs() / 2;
  }
  return area;
}

List<SketchVector> _centroidsInside(
  SketchSurfaceProfile profile,
  List<SketchVector> polygon,
) {
  final result = <SketchVector>[];
  for (var i = 0; i < profile.triangles.length; i += 3) {
    final a = _node(profile, profile.triangles[i]);
    final b = _node(profile, profile.triangles[i + 1]);
    final c = _node(profile, profile.triangles[i + 2]);
    final centroid = SketchVector((a.x + b.x + c.x) / 3, (a.y + b.y + c.y) / 3);
    if (_inside(centroid, polygon)) result.add(centroid);
  }
  return result;
}

SketchVector _node(SketchSurfaceProfile profile, int index) {
  final offset = index * 3;
  return SketchVector(
    profile.nodes[offset],
    profile.nodes[offset + 1],
    profile.nodes[offset + 2],
  );
}

bool _inside(SketchVector point, List<SketchVector> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i], b = polygon[j];
    if ((a.y > point.y) != (b.y > point.y)) {
      final x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x;
      if (point.x < x) inside = !inside;
    }
  }
  return inside;
}
