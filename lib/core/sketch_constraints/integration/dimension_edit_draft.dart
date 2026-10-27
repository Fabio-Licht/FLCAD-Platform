import '../models/constraint_models.dart';

/// UI-facing draft for a driving-dimension edit.
///
/// This object deliberately owns no Sketch geometry.  The canonical
/// ConstraintEngine remains the only authority that can apply a value; the
/// draft only validates user input and controls the Apply/Cancel lifecycle.
enum DimensionEditDraftStatus {
  idle,
  previewing,
  confirmed,
  cancelled,
  rejected,
}

class DimensionEditDraft {
  DimensionEditDraft(this.dimension) : originalValue = dimension.value;

  final SketchDimension dimension;
  final double originalValue;
  double? previewValue;
  DimensionEditDraftStatus status = DimensionEditDraftStatus.idle;
  String? error;

  bool get hasPreview => previewValue != null;
  bool get changed => hasPreview && previewValue != originalValue;

  void begin() {
    previewValue = null;
    error = null;
    status = DimensionEditDraftStatus.idle;
  }

  bool preview(double value) {
    final validation = _validate(value);
    if (validation != null) {
      error = validation;
      previewValue = null;
      status = DimensionEditDraftStatus.rejected;
      return false;
    }
    previewValue = value;
    error = null;
    status = DimensionEditDraftStatus.previewing;
    return true;
  }

  double confirm() {
    final value = previewValue;
    if (value == null || status != DimensionEditDraftStatus.previewing) {
      throw StateError('A valid dimension preview is required before Apply.');
    }
    status = DimensionEditDraftStatus.confirmed;
    return value;
  }

  void cancel() {
    previewValue = null;
    error = null;
    status = DimensionEditDraftStatus.cancelled;
  }

  String? _validate(double value) {
    if (!value.isFinite) return 'Dimension value must be finite.';
    final positive = switch (dimension.type) {
      SketchDimensionType.linear ||
      SketchDimensionType.horizontal ||
      SketchDimensionType.vertical ||
      SketchDimensionType.parallelDistance ||
      SketchDimensionType.radius ||
      SketchDimensionType.diameter ||
      SketchDimensionType.offset => value > 0,
      _ => true,
    };
    if (!positive) return 'This dimension must be greater than zero.';
    return null;
  }
}
