import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/engineering_bridge/selection/section_sketch_connectivity.dart';

List<List<List<double>>> _segments(List<List<double>> points) => [
  for (var i = 1; i < points.length; i++) [points[i - 1], points[i]],
];

void main() {
  const tolerance = .1;

  test('joins below tolerance without changing coordinates', () {
    final source = _segments([
      [0, 0, 0],
      [1, 0, 0],
      [1.05, 0, 0],
      [2, 0, 0],
    ]);
    final chains = SectionSketchConnectivity.orderChains(
      source,
      tolerance: tolerance,
    );
    expect(chains, hasLength(1));
    expect(chains.single[1].x, 1);
    expect(chains.single.last.x, 2);
  });

  test(
    'boundary follows quantized Section semantics; larger gap separates',
    () {
      for (final (gap, expectedChains) in [(0.1, 2), (0.2, 2)]) {
        final chains = SectionSketchConnectivity.orderChains(<Object?>[
          <Object?>[
            [0, 0, 0],
            [1, 0, 0],
          ],
          <Object?>[
            [1 + gap, 0, 0],
            [2, 0, 0],
          ],
        ], tolerance: tolerance);
        expect(chains, hasLength(expectedChains), reason: 'gap=$gap');
      }
    },
  );

  test('closed, open, independent and inner loops stay identifiable', () {
    final outer = _segments([
      [0, 0, 0],
      [1, 0, 0],
      [1, 1, 0],
      [0, 1, 0],
      [0, 0, 0],
    ]);
    final open = _segments([
      [3, 0, 0],
      [4, 0, 0],
      [4, 1, 0],
    ]);
    final inner = _segments([
      [.2, .2, 0],
      [.4, .2, 0],
      [.4, .4, 0],
      [.2, .2, 0],
    ]);
    expect(
      SectionSketchConnectivity.orderChains(outer, tolerance: tolerance),
      hasLength(1),
    );
    expect(
      SectionSketchConnectivity.orderChains(open, tolerance: tolerance),
      hasLength(1),
    );
    expect(
      SectionSketchConnectivity.orderChains([
        ...outer,
        ...inner,
      ], tolerance: tolerance),
      hasLength(2),
    );
  });

  test('spline source endpoints and interior points are preserved', () {
    final chains = SectionSketchConnectivity.orderChains(
      _segments([
        [0, 0, 0],
        [.5, .2, 0],
        [1, 0, 0],
      ]),
      tolerance: tolerance,
    );
    expect(chains.single.first.x, 0);
    expect(chains.single[1].y, .2);
    expect(chains.single.last.x, 1);
  });
}
