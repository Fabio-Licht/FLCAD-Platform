import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('region growing isolate accepts only primitive mesh payloads', () async {
    final result = await dispatchRegionGrowingIsolate(
      RegionGrowingIsolatePayload(
        nodes: const [
          0.0,
          0.0,
          0.0,
          1.0,
          0.0,
          0.0,
          1.0,
          0.0,
          1.0,
          0.0,
          0.0,
          1.0,
        ],
        triangles: const [0, 1, 2, 0, 2, 3],
        fingerprint: 'fixture-plane',
        normalAngleDegrees: 28.0,
        curvatureDelta: .35,
        minimumTriangles: 1,
        planar: false,
        planarToleranceMm: .5,
        seedTriangle: null,
        seedNeighborhoodTriangles: 24,
      ),
    );

    expect(result['regions'], isNotEmpty);
    expect(result['graph'], isA<Map>());
    expect(result['diagnostics'], isA<Map>());
  });
}
