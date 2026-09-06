# M-005 Post-Merge Hardening Backlog

## Purpose

This backlog records the engineering work that must follow the M-005 merge. It
turns audit findings into independently verifiable tasks and deliberately does
not describe experimental foundations as production-ready features.

The current reconstruction, metric-reference, surface, picking and native
viewport code establishes contracts and integration seams. Passing unit tests
proves those contracts at their present scope; it does not prove field-grade
photogrammetry, dimensional accuracy, watertight CAD reconstruction or
production deployment.

## Priority convention

- **P1 — release gate:** required before the affected capability can be enabled
  for users or represented as operational.
- **P2 — capability hardening:** required before the affected capability can be
  represented as accurate, complete or suitable for engineering use.

Every task must land in a focused pull request with automated tests, evidence
from the supported Windows environment where applicable, and documentation of
known limitations. A fallback or placeholder must be labeled as such in code,
diagnostics and UI.

## P1 — Release gates

### P1.1 Isolate the COLMAP process boundary

**Current limitation:** the backend contract exists, but process execution is
not yet a production-grade isolation boundary. A failed, stalled or maliciously
configured external process could compromise a reconstruction run.

**Work**

- Run COLMAP outside the application process with a per-run working directory.
- Pass arguments as an argument list; never interpolate user-controlled values
  into a shell command.
- Constrain input, workspace and output paths to validated roots.
- Capture stdout, stderr, exit code, elapsed time and cancellation reason.
- Enforce stage-specific timeouts and terminate the complete child-process tree
  on cancellation or shutdown.
- Prevent concurrent runs from sharing mutable files.

**Dependencies:** backend provisioning, reconstruction cancellation lifecycle,
Windows process management.

**Acceptance criteria**

- Tests demonstrate that spaces and metacharacters in legal paths are passed
  literally and do not create additional commands.
- Traversal and output paths outside the allowed run root are rejected before
  process launch.
- Cancellation and timeout leave no COLMAP child process running and produce a
  terminal, typed stage report.
- Two concurrent fixture runs use distinct directories and cannot overwrite
  each other's artifacts.
- A non-zero exit returns captured diagnostics and never reports completion.

### P1.2 Certify the COLMAP binary and validate artifacts

**Current limitation:** locating an executable is not proof that it is the
expected, supported or safe binary, and an exit code of zero is not proof that
usable reconstruction artifacts were produced.

**Work**

- Resolve COLMAP to an absolute canonical path from an approved installation.
- Record supported versions and SHA-256 hashes for distributed binaries.
- Reject ambiguous PATH-only resolution in production mode.
- Validate each stage's required files, formats, non-zero sizes and internal
  consistency before advancing.
- Produce a manifest containing executable identity, input fingerprint,
  parameters and output checksums.

**Dependencies:** P1.1; release packaging policy.

**Acceptance criteria**

- A relative executable path, unsupported version or mismatched hash is
  rejected with an actionable diagnostic.
- The process cannot be launched through a symlink or path that resolves
  outside the certified installation root.
- Fixture tests reject missing, empty, truncated and stale artifacts even when
  the external process returns zero.
- A valid fixture produces a reproducible manifest and only then marks the
  corresponding stage successful.

### P1.3 Make triangulation completion explicit

**Current limitation:** a partially populated or degenerate triangle set may be
accepted as geometry even though it is not complete enough for downstream CAD
operations.

**Work**

- Define completeness separately for renderable, measurable and solid-capable
  meshes.
- Validate index bounds, finite coordinates, triangle area, duplicate faces,
  orientation, boundary edges, non-manifold edges and disconnected components.
- Return structured quality diagnostics instead of a single success flag.

**Dependencies:** mesh import contract; reconstruction artifact validation.

**Acceptance criteria**

- Automated fixtures cover valid, truncated, degenerate, non-manifold,
  inconsistently oriented and multi-component meshes.
- No out-of-range index or non-finite vertex reaches the renderer or CAD kernel.
- A mesh is never labeled watertight or solid-capable unless boundary and
  manifold checks pass.
- UI/export gates consume the explicit quality classification and expose the
  reason for rejection or downgrade.

### P1.4 Return picking depth and the actual hit point

**Current limitation:** selection identity alone is insufficient for precise
navigation, measurement and construction. Inferred or proxy points can drift
from the visible surface.

**Work**

- Extend the picking result with ray distance/depth, world-space hit point,
  primitive identifier and barycentric or parametric coordinates when known.
- Choose the nearest valid visible hit with deterministic tie-breaking.
- Preserve precision through scene, controller and native bridge boundaries.

**Dependencies:** complete triangulation data; stable camera matrices; mesh BVH.

**Acceptance criteria**

- Tests with overlapping triangles select the nearest visible intersection.
- Perspective and orthographic fixtures round-trip the reported world hit to
  the expected screen position within a documented tolerance.
- Surface-anchored pan and rotation-center capture use the reported hit point,
  not a bounding-box or entity-origin approximation.
- Misses return an explicit no-hit result with no stale depth or coordinates.

### P1.5 Recover native hover state and bound native caches

**Current limitation:** lost pointer events or native-view recreation can leave
hover/selection presentation stale, while unbounded cached native resources can
accumulate across projects.

**Work**

- Clear hover deterministically on pointer exit, focus loss, view disposal,
  project change and native-surface recreation.
- Key cached resources by project/revision and define ownership and eviction.
- Rebuild invalidated resources without retaining stale native handles.
- Expose cache counts and recovery events to debug diagnostics.

**Dependencies:** native viewport lifecycle; project/revision identity.

**Acceptance criteria**

- Automated lifecycle tests cover pointer exit, focus loss, disposal, project
  switching and native-view recreation.
- No hover survives after its geometry revision is invalidated.
- Repeated project-open/close and viewport-recreate stress tests keep cache and
  native-handle counts within documented bounds.
- Native smoke tests complete without use-after-free, leaked handle or stale
  selection symptoms.

### P1.6 Add license, notice and SBOM release gates

**Current limitation:** open-source availability does not automatically grant
commercial redistribution rights, and the repository does not yet demonstrate
a complete dependency and model-license review.

**Work**

- Inventory Dart, native, external executable, model-weight and build-time
  dependencies.
- Record version, source, license, copyright notice, redistribution obligations
  and commercial-use status.
- Generate a machine-readable SBOM and distributable third-party notices.
- Block release when a dependency, model or binary has unknown or incompatible
  terms.

**Dependencies:** packaging inventory; legal review for ambiguous terms.

**Acceptance criteria**

- CI generates an SBOM from locked dependency versions and stores it as a build
  artifact.
- Every shipped component maps to a reviewed license entry and required notice.
- Restricted or research-only model weights cannot be selected by a commercial
  build configuration.
- A documented approval owner signs off the license manifest before release.

### P1.7 Run native OpenCascade validation in CI

**Current limitation:** the OpenCascade smoke test passed manually on the
supported Windows workstation, but native ABI and packaging regressions are not
yet guarded continuously.

**Work**

- Add a pinned Windows CI job that configures and builds the native bridge.
- Provision a certified OpenCascade SDK and verify its version/hash.
- Run the native smoke test through CTest and preserve logs/artifacts.
- Add an ABI/export-symbol check for the functions consumed by Dart FFI.

**Dependencies:** P1.6 for redistribution/provisioning; CI secret and cache
policy.

**Acceptance criteria**

- A clean Windows runner builds Release x64 and reports `1/1` native smoke tests
  passed.
- CI fails on a missing export, signature mismatch, wrong architecture or
  unsupported OpenCascade package.
- The job is required for merge on changes under `native/opencascade`, its CMake
  files, or the Dart FFI boundary.
- Build instructions reproduce the same result outside the original developer
  workstation.

### P1.8 Gate Foundation and automatic backends honestly

**Current limitation:** Foundation is a contract/test implementation and the
automatic selector can choose only among the backends that are actually
provisioned. Neither constitutes a production reconstruction engine by itself.

**Work**

- Mark Foundation as non-production and prevent it from satisfying a real
  geometry-output request.
- Make automatic selection require declared capability, successful provisioning
  and runtime health.
- Distinguish `unsupported`, `unavailable`, `failed`, `cancelled` and
  `completed-with-validated-artifact` outcomes.
- Reflect those states in UI and telemetry without optimistic wording.

**Dependencies:** P1.1, P1.2 and backend capability registry.

**Acceptance criteria**

- Production mode cannot select Foundation for a reconstruction that promises
  geometry.
- Automatic selection has tests for no backend, unhealthy preferred backend,
  valid fallback, cancellation and invalid artifact.
- Only a validated artifact can produce the completed state.
- Product documentation states which backend is required, how it is provisioned
  and which capabilities remain experimental.

## P2 — Capability hardening

### P2.1 Implement a weighted metric-reference solver

**Current limitation:** current metric-reference foundations do not establish a
robust, uncertainty-aware dimensional solution for real captures.

**Work**

- Model each reference with units, confidence, measurement uncertainty and
  provenance.
- Solve scale (and, when justified, alignment) using weighted residuals.
- Detect contradictory references and robustly limit outlier influence.
- Report residuals, confidence and observability instead of only a corrected
  value.

**Dependencies:** calibrated acquisition evidence; stable coordinate frames;
validated unit conversions.

**Acceptance criteria**

- Synthetic tests recover known scale under noise within a documented tolerance.
- Low-confidence outliers cannot dominate consistent high-confidence evidence.
- Contradictory or underconstrained inputs return an explicit unsolved state.
- Golden datasets report per-reference residuals and a reproducible confidence
  score; no claim of metrology-grade accuracy is made without field validation.

### P2.2 Reconstruct and validate closed spline surfaces

**Current limitation:** spline/surface scaffolding does not yet prove creation of
a closed, editable and geometrically valid surface model from captured data.

**Work**

- Define patch topology, continuity targets and seam ownership.
- Fit splines with bounded approximation error and controlled degree/control
  point growth.
- Join and heal seams, detect gaps/self-intersections and validate shell closure.
- Preserve editable surface definitions separately from visualization meshes.

**Dependencies:** validated mesh/point evidence; metric-reference solution;
OpenCascade surface and sewing operations.

**Acceptance criteria**

- Canonical sphere, cylinder-transition and freeform fixtures produce editable
  spline patches with reported maximum/RMS deviation.
- Seam continuity is classified (`C0`, `G1` or better) and checked against an
  explicit tolerance.
- A model is labeled closed only when the kernel confirms a closed valid shell;
  invalid or self-intersecting cases are rejected with diagnostics.
- STEP round-trip preserves patch count, closure and deviation within documented
  tolerances.

## Recommended execution order

1. P1.8 capability gating and honest states.
2. P1.1 process isolation.
3. P1.2 binary certification and artifact validation.
4. P1.3 triangulation completeness.
5. P1.4 picking depth and hit point.
6. P1.5 native hover recovery and cache bounds.
7. P1.6 license/SBOM/notices.
8. P1.7 native OpenCascade CI.
9. P2.1 weighted metric solver.
10. P2.2 closed spline-surface reconstruction.

P2 work may be researched in parallel, but it must not bypass the P1 release
gates or be marketed as complete based solely on synthetic tests.

## Definition of done for this backlog

This backlog is complete only when every item has linked implementation and
test evidence, all P1 gates are required by CI/release configuration, supported
platforms are documented, and remaining limitations are visible to users. A
green Flutter suite alone is necessary but not sufficient evidence for these
claims.
