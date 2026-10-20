import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Region Growing isolate accepts omitted optional diagnostics without Null Map cast',
    () {
      final restored = restoreRegionGrowingResult({
        'regions': [
          {
            'id': 'region:1',
            'color': '#ffffff',
            'triangleIndices': [0],
            'vertexIndices': [0, 1, 2],
            'area': 1.0,
            'normal': [0.0, 0.0, 1.0],
            'bounds': [0.0, 0.0, 0.0, 1.0, 1.0, 0.0],
            'meanCurvature': 0.0,
            'confidence': 1.0,
            'health': 0,
          },
        ],
        'graph': {'region:1': <String>[]},
        'diagnostics': null,
      });

      expect(restored.regions, hasLength(1));
      expect(restored.graph.edges, {'region:1': <String>{}});
      expect(restored.diagnostics, isEmpty);
    },
  );

  test('missing required Region Growing graph reports a structural error', () {
    expect(
      () => restoreRegionGrowingResult(const {
        'regions': <Object?>[],
        'graph': null,
        'diagnostics': null,
      }),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('no graph map'),
        ),
      ),
    );
  });
}
