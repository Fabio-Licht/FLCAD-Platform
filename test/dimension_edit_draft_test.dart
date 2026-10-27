import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/core/sketch_constraints/integration/dimension_edit_draft.dart';
import 'package:flcad_mobile/core/sketch_constraints/models/constraint_models.dart';

SketchDimension dimension(SketchDimensionType type, [double value = 10]) =>
    SketchDimension(type: type, constraintId: 'c1', value: value);

void main() {
  test('preview/apply keeps geometry authority outside the draft', () {
    final d = dimension(SketchDimensionType.linear);
    final draft = DimensionEditDraft(d)..begin();

    expect(draft.preview(25), isTrue);
    expect(draft.status, DimensionEditDraftStatus.previewing);
    expect(d.value, 10); // no silent mutation before Apply
    expect(draft.confirm(), 25);
    expect(draft.status, DimensionEditDraftStatus.confirmed);
  });

  test('cancel discards the proposed value', () {
    final draft = DimensionEditDraft(dimension(SketchDimensionType.radius))
      ..begin();
    expect(draft.preview(4), isTrue);
    draft.cancel();
    expect(draft.previewValue, isNull);
    expect(draft.status, DimensionEditDraftStatus.cancelled);
  });

  test('invalid and non-finite values are rejected', () {
    final draft = DimensionEditDraft(dimension(SketchDimensionType.diameter))
      ..begin();
    expect(draft.preview(0), isFalse);
    expect(draft.status, DimensionEditDraftStatus.rejected);
    expect(draft.preview(double.nan), isFalse);
    expect(() => draft.confirm(), throwsStateError);
  });

  test('angular dimensions may be signed but must be finite', () {
    final draft = DimensionEditDraft(dimension(SketchDimensionType.angular))
      ..begin();
    expect(draft.preview(-30), isTrue);
    expect(draft.confirm(), -30);
  });
}
