import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

/// Pure geometry helpers for the local tool-window overlay.
///
/// The overlay lives inside the central viewport Stack, so these helpers do
/// not know about or modify the detached PanelWindowHost layout.
abstract final class ToolWindowLayout {
  static Offset initialPosition({
    required Size viewport,
    required Size window,
    double margin = 16,
  }) {
    final maxLeft = math.max(0.0, viewport.width - window.width - margin);
    return Offset(maxLeft.toDouble(), margin);
  }

  static Offset clampPosition({
    required Offset position,
    required Size viewport,
    required Size window,
    double margin = 8,
  }) {
    final maxLeft = math.max(margin, viewport.width - window.width - margin);
    final maxTop = math.max(margin, viewport.height - window.height - margin);
    return Offset(
      position.dx.clamp(margin, maxLeft).toDouble(),
      position.dy.clamp(margin, maxTop).toDouble(),
    );
  }

  static Size resize({
    required Size current,
    required Offset delta,
    required Size viewport,
    Size min = const Size(260, 240),
    Size max = const Size(520, 720),
  }) {
    final viewportMaxWidth = (viewport.width - 16).clamp(min.width, max.width);
    final viewportMaxHeight = (viewport.height - 16).clamp(
      min.height,
      max.height,
    );
    return Size(
      (current.width + delta.dx).clamp(min.width, viewportMaxWidth).toDouble(),
      (current.height + delta.dy)
          .clamp(min.height, viewportMaxHeight)
          .toDouble(),
    );
  }
}
