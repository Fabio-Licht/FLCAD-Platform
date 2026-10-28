# SKETCH-10A — Sketch Offset

## Geometry contract

- Offset is a geometric copy operation. It leaves its source entities unchanged
  and creates independent Sketch entities through `SketchEditorEngine` and the
  canonical Sketch builders.
- The generated entities record their source IDs, distance and side in metadata.
  `associative: false` is intentional: editing the source later does not update
  the result. This metadata is provenance, not a parametric constraint.
- A single circle or circular arc is supported for compatibility. The center
  remains unchanged; for arcs the angular interval remains unchanged. Radius
  changes according to the chosen direction and must stay positive.
- A single ellipse is also supported by adjusting both axis radii equally. This
  is an axis-based approximation, not an exact constant-distance offset.
- Connected line chains and closed line profiles are supported. The chain must
  be one unbranched connected path. Closed profiles choose inside/outside
  independently of winding direction.
- All line joins use sharp, unlimited miter intersections. A parallel or
  reversing join, collapsed segment/profile, non-finite result, or detected
  self-intersection is rejected before any entity is created.
- Splines, mixed line/arc chains, branched networks and disconnected selections
  are not supported in SKETCH-10A. Interpolated spline support was added later
  in SKETCH-10C1.

## Transaction and interaction

- Preview uses the same geometry calculation as Apply and is displayed as a
  transient viewport entity. It does not mutate the document or Sketch history.
- Apply creates the complete result inside one SketchEngine transaction, so
  the operation has one Undo/Redo boundary. Failed calculations leave source
  geometry and history unchanged.
- Cancel and Escape remove the transient Preview without touching the Sketch.
- The Sketch plane's local XY coordinates are used for calculation; generated
  entities remain in that Sketch and are projected through its coordinate
  system by the existing scene adapter.

## Validation

`test/sketch_offset_geometry_test.dart` covers signed line offsets, arc radius
and sweep, connected chains, rectangular and concave profiles, invalid inputs,
Preview/Cancel immutability, atomic Apply, Undo/Redo and persistence reload.
`test/sketch_operator_functional_flow_test.dart` drives viewport picking and the
real Apply button callback, and checks Escape cancellation.
