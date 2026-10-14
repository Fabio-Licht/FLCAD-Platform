/// Immutable presentation data for a contextual Reference operation.
///
/// This model contains no runtime, geometry, controller or callback. It is
/// derived from the existing operation state and is safe to use by a compact
/// contextual panel.
enum ReferenceContextPhase { idle, configuring, previewing, error }

final class ReferenceContextOption {
  const ReferenceContextOption({required this.id, required this.label});

  final String id;
  final String label;

  Map<String, Object?> toJson() => {'id': id, 'label': label};
}

final class ReferenceContextPresentation {
  const ReferenceContextPresentation({
    required this.operationId,
    required this.title,
    required this.phase,
    required this.planeOptions,
    required this.axisOptions,
    this.planeId,
    this.axisId,
    this.activeSlot,
    this.diagnostic,
    this.canPreview = false,
    this.canApply = false,
    this.canCancel = false,
  });

  final String operationId;
  final String title;
  final ReferenceContextPhase phase;
  final List<ReferenceContextOption> planeOptions;
  final List<ReferenceContextOption> axisOptions;
  final String? planeId;
  final String? axisId;
  final String? activeSlot;
  final String? diagnostic;
  final bool canPreview;
  final bool canApply;
  final bool canCancel;

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'title': title,
    'phase': phase.name,
    'planeOptions': [for (final option in planeOptions) option.toJson()],
    'axisOptions': [for (final option in axisOptions) option.toJson()],
    if (planeId != null) 'planeId': planeId,
    if (axisId != null) 'axisId': axisId,
    if (activeSlot != null) 'activeSlot': activeSlot,
    if (diagnostic != null) 'diagnostic': diagnostic,
    'canPreview': canPreview,
    'canApply': canApply,
    'canCancel': canCancel,
  };

  factory ReferenceContextPresentation.planeAxisIntersection({
    required List<ReferenceContextOption> planeOptions,
    required List<ReferenceContextOption> axisOptions,
    required String? planeId,
    required String? axisId,
    required String? activeSlot,
    required bool previewActive,
    required bool busy,
    String? diagnostic,
  }) {
    final phase = diagnostic != null
        ? ReferenceContextPhase.error
        : previewActive
        ? ReferenceContextPhase.previewing
        : planeId != null || axisId != null || activeSlot != null
        ? ReferenceContextPhase.configuring
        : ReferenceContextPhase.idle;
    return ReferenceContextPresentation(
      operationId: 'reference.plane_axis_intersection_point',
      title: 'Ponto de interseção',
      phase: phase,
      planeOptions: List.unmodifiable(planeOptions),
      axisOptions: List.unmodifiable(axisOptions),
      planeId: planeId,
      axisId: axisId,
      activeSlot: activeSlot,
      diagnostic: diagnostic,
      canPreview: !busy && planeId != null && axisId != null,
      canApply: !busy && previewActive,
      canCancel:
          previewActive ||
          planeId != null ||
          axisId != null ||
          activeSlot != null,
    );
  }
}
