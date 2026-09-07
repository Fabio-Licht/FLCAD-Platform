# FLSCAN — Product Strategy and Development Roadmap

> **Documento histórico.** O [ADR-084](adr/ADR-084-flcad-platform-product-boundaries.md)
> substitui somente sua taxonomia de produto: **FLCAD Scan** é o nome canônico
> do domínio/produto. `FLSCAN` permanece como nomenclatura histórica e como
> formato/contrato de intercâmbio `.flscan`. O conteúdo técnico e o roadmap
> abaixo não foram reescritos.

## Status

**PLANNED — NOT AUTHORIZED FOR IMPLEMENTATION**

This document records the product direction agreed on 2026-08-21. It does not
authorize implementation or changes to the FLCAD Alpha baseline.

## Product vision

FLSCAN is an independent but complementary product family for intelligent 3D
acquisition. It must help the operator capture physical objects, assess capture
quality, establish scale, reconstruct meshes and deliver trustworthy evidence
to FLCAD.

FLSCAN must not be tied to Creality or any other scanner manufacturer. The
Raptor Pro is the first available validation device, not the architectural
foundation.

## Product ecosystem

```text
FLSCAN Mobile
Capture guidance, photographs, scale and quick printable mesh
                ↓
FLSCAN Desktop
Universal scanner adapters, photogrammetry and hybrid fusion
                ↓
FLCAD Reverse
CAD reconstruction and reverse engineering
                ↓
FLCAD Inspection
Deviation, tolerance and inspection reporting
                ↓
FLCAD CAM
Manufacturing preparation and toolpath processes
```

Each product must provide independent value. Integration adds capability but
must not make one product unusable without the others.

## Existing mobile foundation

The current workspace already contains a reusable FLSCAN Mobile foundation:

- smartphone camera capture and preview;
- zoom and photograph storage;
- projects, sessions and gallery;
- initial capture-quality and coverage analysis;
- initial scale-method selection;
- Capture Coach / intelligent assistant structure;
- resumable reconstruction pipeline running outside the UI isolate;
- formal stages for feature detection, matching, camera poses, sparse cloud,
  dense cloud, mesh generation, optimization and texture;
- extension contracts for scale, reconstruction and export.

The current reconstruction backend is an Alpha scaffold. Several stages create
demonstration artifacts and the generated mesh is synthetic. A real
photogrammetry backend is still required.

## Universal scanner architecture

```text
Scanner / Smartphone / Camera
              ↓
        Device Adapter
              ↓
 Universal Capture Contract
              ↓
   Scan Intelligence Engine
              ↓
 Point cloud + Photos + Confidence
              ↓
             FLCAD
```

The core must never contain manufacturer-specific decisions. Each device
adapter declares its capabilities:

- live point cloud;
- RGB, IR and depth frames;
- pose tracking;
- exposure control;
- laser-power control;
- lighting control;
- calibration access;
- hardware trigger;
- raw-data access.

Unavailable capabilities must be hidden or clearly disabled. No unsupported
control may be simulated.

## Compatibility levels

### Level 1 — File compatibility

Import common scanner outputs such as STL, OBJ, PLY, XYZ, E57, LAS/LAZ, PTX,
images and organized point clouds. This is the universal baseline.

### Level 2 — Assisted integration

Use documented project files, watched folders, official plugins, command-line
interfaces or export APIs while acquisition remains in manufacturer software.

### Level 3 — Direct hardware control

Use an official manufacturer SDK to control capture, exposure, illumination,
laser power, range and tracking. Each supported family receives an isolated
adapter. Proprietary USB protocols must not be reverse-engineered for the
commercial product.

## Mobile reconstruction promise

The first commercial promise should be narrow and verifiable:

> Transform guided photographs into a dimensioned mesh ready for 3D printing.

The first release must not claim metrological certification. It reports
estimated accuracy and confidence based on the available evidence.

## Metric scale foundation

Photogrammetry reconstructs shape and proportion but does not provide absolute
metric scale without a reference. FLSCAN must support:

1. one known distance between two selected points;
2. multiple known measurements;
3. calibrated FLSCAN fiducial markers or scale bars;
4. recognized reference objects;
5. ARCore, ARKit or LiDAR as an initial estimate when available.

Supported measurement types include:

- distance;
- length;
- width;
- height;
- thickness;
- radius;
- diameter.

A dimensional Solver must reconcile multiple measurements, show residual error,
identify conflicting inputs and estimate uncertainty. It must never distort a
mesh silently to satisfy incompatible measurements.

## Accuracy contract

Projects may declare a target accuracy, for example visual-only, 1.0 mm,
0.5 mm, 0.2 mm or a custom value. The software must compare requested and
estimated accuracy and clearly refuse certification when evidence is
insufficient.

Every reconstructed region must preserve provenance and confidence:

- direct scanner measurement;
- photogrammetric reconstruction;
- small interpolation;
- supervised hole filling;
- algorithmic inference;
- unresolved region.

## Mobile and desktop processing

Use a hybrid strategy:

- Mobile performs capture guidance, immediate validation, preliminary
  reconstruction and quick STL export for suitable projects.
- Desktop performs GPU reconstruction, large datasets, precision refinement,
  scanner fusion and complete FLCAD integration.

Original photographs, calibration, measurements and capture metadata must
remain available for later desktop reprocessing.

## Printing export contract

Before STL export, validate:

- scale and millimetre convention;
- watertight topology;
- manifold edges;
- normal orientation;
- self-intersections;
- gaps and supervised repairs;
- problematic wall thickness;
- estimated dimensional accuracy.

STL is supported for printer compatibility. 3MF should also be supported later
because it preserves units and richer metadata.

## Proposed development Sprints

### M-004 — Metric Reference Foundation

Known distance between two points plus explicit length, width and diameter
references. Persist scale evidence and units.

### M-005 — Calibrated Scale Markers

Create and recognize calibrated FLSCAN fiducial sheets, plates and scale bars.

### M-006 — Real Photogrammetry Backend

Replace Alpha artifacts with real feature extraction, matching, camera
calibration, pose estimation and sparse reconstruction.

### M-007 — Dense Reconstruction

Generate and filter a dense point cloud while preserving camera evidence and
confidence.

### M-008 — Mobile Mesh Generation

Generate, clean, simplify and display a real mesh on supported smartphones.
Provide resource-aware quality levels.

### M-009 — Dimensional Solver

Reconcile multiple measurements, report residuals and conflicts, estimate
uncertainty and preserve the original reconstruction.

### M-010 — Mesh Health for Printing

Validate watertightness, manifold topology, normals, gaps, intersections and
wall-thickness risks. Repairs always require authorization.

### M-011 — STL / 3MF Export

Export a validated, dimensioned model for 3D printing and generate an accuracy
and processing report.

### M-012 — Capture Coach Pro

Provide live focus, blur, exposure, glare, overlap, stability, coverage,
distance and next-view guidance.

### M-013 — FLSCAN Desktop Bridge

Transfer complete projects and original evidence to FLSCAN Desktop/FLCAD for
continued reconstruction without loss of identity or provenance.

## Commercial structure

Potential product editions:

- FLSCAN Mobile — guided capture and quick STL;
- FLSCAN Mobile Pro — multiple metric references and advanced reconstruction;
- FLSCAN Desktop — scanners, GPU processing, fusion and large projects;
- FLCAD Reverse — CAD reconstruction;
- FLCAD Inspection — dimensional comparison and reporting;
- FLCAD CAM — manufacturing workflows.

Licensing must be reviewed for every reconstruction dependency before commercial
distribution.

## Permanent product rules

- Original evidence is immutable.
- No hole is filled without operator authorization.
- Estimated geometry is never presented as direct measurement.
- Precision claims are evidence-based and never inferred from mesh density.
- Device-specific code remains inside adapters.
- FLSCAN and FLCAD keep independent release cycles.
- Units, coordinate systems, IDs, provenance and confidence remain compatible.
- Photography privacy, local/cloud processing and telemetry consent are explicit.

## Recommended next action

When implementation is authorized, begin only with **M-004 — Metric Reference
Foundation**. Do not begin the real photogrammetry backend until the metric,
unit, evidence and uncertainty contracts are frozen.
