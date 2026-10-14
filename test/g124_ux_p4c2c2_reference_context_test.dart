import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/desktop/reference_context_presentation.dart';

void main() {
  const planes = [ReferenceContextOption(id: 'p1', label: 'Plano XY')];
  const axes = [ReferenceContextOption(id: 'a1', label: 'Eixo X')];

  test('derives the real operation phases and action gates', () {
    final idle = ReferenceContextPresentation.planeAxisIntersection(
      planeOptions: planes,
      axisOptions: axes,
      planeId: null,
      axisId: null,
      activeSlot: null,
      previewActive: false,
      busy: false,
    );
    expect(idle.phase, ReferenceContextPhase.idle);
    expect(idle.canPreview, isFalse);
    expect(idle.canApply, isFalse);

    final configuring = ReferenceContextPresentation.planeAxisIntersection(
      planeOptions: planes,
      axisOptions: axes,
      planeId: 'p1',
      axisId: 'a1',
      activeSlot: null,
      previewActive: false,
      busy: false,
    );
    expect(configuring.phase, ReferenceContextPhase.configuring);
    expect(configuring.canPreview, isTrue);
    expect(configuring.canApply, isFalse);

    final previewing = ReferenceContextPresentation.planeAxisIntersection(
      planeOptions: planes,
      axisOptions: axes,
      planeId: 'p1',
      axisId: 'a1',
      activeSlot: null,
      previewActive: true,
      busy: false,
    );
    expect(previewing.phase, ReferenceContextPhase.previewing);
    expect(previewing.canApply, isTrue);
    expect(
      previewing.toJson()['operationId'],
      'reference.plane_axis_intersection_point',
    );
  });

  test('busy state disables preview and apply without losing selection', () {
    final model = ReferenceContextPresentation.planeAxisIntersection(
      planeOptions: planes,
      axisOptions: axes,
      planeId: 'p1',
      axisId: 'a1',
      activeSlot: null,
      previewActive: true,
      busy: true,
    );
    expect(model.planeId, 'p1');
    expect(model.axisId, 'a1');
    expect(model.canPreview, isFalse);
    expect(model.canApply, isFalse);
  });

  test('error is explicit and serializable', () {
    final model = ReferenceContextPresentation.planeAxisIntersection(
      planeOptions: planes,
      axisOptions: axes,
      planeId: null,
      axisId: null,
      activeSlot: null,
      previewActive: false,
      busy: false,
      diagnostic: 'Selecione um plano e um eixo válidos.',
    );
    expect(model.phase, ReferenceContextPhase.error);
    expect(model.toJson()['diagnostic'], contains('plano'));
  });
}
