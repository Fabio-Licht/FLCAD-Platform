import 'dart:math' as math;
import 'dart:ui';

/// Reserved UI colors. Imported meshes must never receive a color that is
/// visually confusable with the active selection.
const Color kCadSelectionColor = Color(0xFFF5F7FA);
const Color kCadBrushOutlineColor = Color(0xFFFFBF45);
const Color kCadDefaultMeshColor = Color.from(
  alpha: 1,
  red: .30,
  green: .50,
  blue: .68,
);

/// Minimum WCAG-style contrast between a mesh color and the selection fill.
/// The selection is a graphical object, so 3:1 is the minimum accepted value.
const double kMinimumSelectionContrast = 3.0;

/// Curated, non-white mesh palette. Every entry is checked against the
/// selection color at runtime; the list is deliberately small and stable.
const List<Color> kImportedMeshPalette = [
  Color(0xFF3D6B8C),
  Color(0xFF2F7A6A),
  Color(0xFF8A6A2F),
  Color(0xFF6B4C7A),
  Color(0xFF8A4B3A),
  Color(0xFF3E6B45),
  Color(0xFF48558A),
  Color(0xFF4F5B66),
];

double _linearChannel(double channel) => channel <= .04045
    ? channel / 12.92
    : math.pow((channel + .055) / 1.055, 2.4).toDouble();

double _srgbChannel(double linear) => linear <= .0031308
    ? linear * 12.92
    : 1.055 * math.pow(linear, 1 / 2.4) - .055;

double relativeLuminance(Color color) =>
    .2126 * _linearChannel(color.r) +
    .7152 * _linearChannel(color.g) +
    .0722 * _linearChannel(color.b);

double contrastRatio(Color first, Color second) {
  final a = relativeLuminance(first);
  final b = relativeLuminance(second);
  final lighter = math.max(a, b);
  final darker = math.min(a, b);
  return (lighter + .05) / (darker + .05);
}

double colorDistance(Color first, Color second) {
  final dr = first.r - second.r;
  final dg = first.g - second.g;
  final db = first.b - second.b;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

bool isSelectionReservedColor(
  Color color, {
  Color selectionColor = kCadSelectionColor,
}) => contrastRatio(color, selectionColor) < kMinimumSelectionContrast;

/// Chooses a mesh color that is distinct from the colors already in use and
/// keeps at least [kMinimumSelectionContrast] against the selection color.
/// Palette reuse is allowed only after the controlled rotation is exhausted.
Color chooseImportedMeshColor({
  required Iterable<Color> existing,
  Color selectionColor = kCadSelectionColor,
  int offset = 0,
}) {
  final used = existing.toList(growable: false);
  final eligible = kImportedMeshPalette
      .where(
        (color) =>
            contrastRatio(color, selectionColor) >= kMinimumSelectionContrast,
      )
      .toList(growable: false);
  if (eligible.isEmpty) {
    throw StateError('No imported mesh color meets the selection contrast.');
  }
  for (var pass = 0; pass < eligible.length; pass++) {
    final candidate = eligible[(offset + pass) % eligible.length];
    if (used.every((color) => colorDistance(color, candidate) > .04)) {
      return candidate;
    }
  }
  for (var pass = 0; pass < eligible.length; pass++) {
    final candidate = eligible[(offset + pass) % eligible.length];
    if (used.isEmpty || colorDistance(used.last, candidate) > .04) {
      return candidate;
    }
  }
  return eligible[offset % eligible.length];
}

List<double> linearRgbForColor(Color color) => [
  _linearChannel(color.r),
  _linearChannel(color.g),
  _linearChannel(color.b),
];

final List<double> kCadSelectionLinearRgb = List.unmodifiable(
  linearRgbForColor(kCadSelectionColor),
);

Color? colorFromLinearRgb(Object? raw) {
  if (raw is! List ||
      raw.length != 3 ||
      raw.any((value) => value is! num || !value.isFinite)) {
    return null;
  }
  final values = raw.cast<num>().map((value) => value.toDouble()).toList();
  if (values.any((value) => value < 0 || value > 1)) return null;
  return Color.from(
    alpha: 1,
    red: _srgbChannel(values[0]),
    green: _srgbChannel(values[1]),
    blue: _srgbChannel(values[2]),
  );
}

Color importedMeshColorFor({
  required Object? rootLinearRgb,
  Color fallback = kCadDefaultMeshColor,
}) => colorFromLinearRgb(rootLinearRgb) ?? fallback;
