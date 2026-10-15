import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('painel de superfícies mantém grupos compactos e callbacks CAD', () {
    final source = File(
      'lib/app/engineering_bridge/widgets/sketch_surface_workspace_panel.dart',
    ).readAsStringSync();

    expect(source, contains("title: const Text('Continuidade')"));
    expect(source, contains("title: const Text('Ferramentas de superfície')"));

    for (final callback in const [
      'controller.previewProfessionalSurface',
      'controller.confirmProfessionalSurface',
      'controller.cancelProfessionalSurface',
      'controller.previewSelectedG1',
      'controller.confirmSelectedG1',
      'controller.cancelSelectedG1',
    ]) {
      expect(
        source,
        contains(callback),
        reason: 'callback removido: $callback',
      );
    }

    expect(source, isNot(contains('class SurfacePanelController')));
    expect(source, isNot(contains('class _SurfacePanelController')));
  });
}
