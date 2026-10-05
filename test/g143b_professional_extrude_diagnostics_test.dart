import 'package:flcad_mobile/core/professional_extrude/professional_extrude.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const adapter = ProfessionalExtrudeConstraintAdapter();

  String diagnostic(Object error, double draft) =>
      ProfessionalExtrudeConstraintAdapter.diagnosticForKernelFailure(
        error,
        draftAngleDegrees: draft,
      );

  test('open profile in Solid is never masked as a generic Draft failure', () {
    // A Draft angle is present, but the real cause is the open profile. The
    // profile text must survive untouched.
    final message = diagnostic(
      StateError('Solid / Cylinder exige um perfil fechado. Complete o loop.'),
      12,
    );
    expect(message, contains('perfil fechado'));
    expect(message.toLowerCase(), isNot(contains('draft falhou no kernel')));
  });

  test('wires and gaps keep their real cause even with Draft', () {
    for (final raw in const [
      'O perfil selecionado esta aberto.',
      'Existe um gap entre as extremidades.',
      'O wire nao forma um loop fechado.',
      'Perfil incompleto para Solid.',
    ]) {
      final message = diagnostic(StateError(raw), 8);
      expect(message, raw);
    }
  });

  test('genuine Draft topology failures are still classified', () {
    final message = diagnostic(
      StateError('Draft angle could not be applied to the side faces'),
      5,
    );
    expect(message, contains('topologia deste perfil'));
  });

  test('no Draft returns the raw kernel message', () {
    expect(
      diagnostic(StateError('Extrude builder did not complete'), 0),
      'Extrude builder did not complete',
    );
  });

  test('Solid requires a closed profile while Surface accepts open wires', () {
    // Contract-level distinction: the profile gate is a controller rule, but
    // the adapter must solve both outputs without inventing a profile error.
    for (final output in ProfessionalExtrudeOutput.values) {
      final contract = ProfessionalExtrudeContract(
        sourceEntityId: 'Sketch001',
        sourceKind: ProfessionalExtrudeSourceKind.sketch,
        sourceRevision: 1,
        sourceShapeId: 'profile-shape',
        distance: 10,
        output: output,
      );
      expect(adapter.health(contract).ready, isTrue);
      expect(adapter.solve(contract).moving, 'extrude.distance');
    }
  });
}
