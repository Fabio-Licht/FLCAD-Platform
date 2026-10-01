/// The Sketch domain owns a deterministic planar constraint solver.
///
/// This flag is consumed by capability surfaces; keep it truthful so callers do
/// not expose parametric editing while running against a geometry-only engine.
abstract final class SketchConstraintsScope {
  static const implemented = true;
}
