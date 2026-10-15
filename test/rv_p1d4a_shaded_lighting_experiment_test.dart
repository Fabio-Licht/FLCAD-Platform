import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/cad_viewport/rendering/shaded_debug_experiments.dart';

void main() {
  test('iluminação experimental permanece desligada por padrão', () {
    expect(kFlcadDevShadedLightingExperiment, isFalse);
  });
}
