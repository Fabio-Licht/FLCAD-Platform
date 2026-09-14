import 'dart:math' as math;
import 'dart:ui';

/// Converts imported linear-sRGB root color to the sRGB presentation channels
/// consumed by Canvas and the viewport's UNORM render target. No source mutation.
List<double>? cadRootSrgb(Map<String, dynamic> geometry) {
  final rgb = geometry['rootLinearRgb'];
  if (rgb == null) return null;
  if (rgb is! List ||
      rgb.length != 3 ||
      rgb.any((v) => v is! num || !v.isFinite || v < 0 || v > 1)) {
    throw const FormatException('Invalid root linear RGB presentation');
  }
  return List.unmodifiable(
    rgb.map((v) {
      final linear = (v as num).toDouble();
      return linear <= 0.0031308
          ? linear * 12.92
          : 1.055 * math.pow(linear, 1 / 2.4) - 0.055;
    }),
  );
}

Color? cadRootColor(Map<String, dynamic> geometry) {
  final rgb = cadRootSrgb(geometry);
  return rgb == null
      ? null
      : Color.from(alpha: 1, red: rgb[0], green: rgb[1], blue: rgb[2]);
}
