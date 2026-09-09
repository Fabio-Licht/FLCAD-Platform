# Native source ABI v1 (BREP and STL)

`flcad_occ_source.h` adds `flcad_occ_source_version`,
`flcad_occ_source_default_limits_v1`, `flcad_occ_brep_read_v1` and
`flcad_occ_stl_read_v1`. Existing pathname entry points and sink ABIs are unchanged.
BREP is durable CAD state; STL is a display mesh, not an implicit shape conversion.

## Contract and ownership

Natural C layout on the host architecture, fixed-width integers, `__cdecl` on
Windows. No C++/OCCT types cross this boundary. Source, limits and callback IO
have explicit `size`/`version`; the result receives its explicit byte capacity and
returns `size`/`version`. Exact v1 sizes are required. Invalid/null/small/overlapping
result storage is rejected before callbacks/publication. Caller supplies valid,
aligned, nonoverlapping memory; this ABI cannot validate arbitrary hostile pointers.
Context may be NULL for context-free callbacks (tested from a C translation unit).

The caller owns a live immutable source and captures its length once. `read_at`
receives `(context, uint64_t offset, uint8_t* destination, uint32_t capacity, io*)`.
It supplies at most capacity bytes. Zero before captured length is truncation;
short positive reads are valid. Every callback runs synchronously on the invoking
thread. No pointer, callback or context is retained after return. Callbacks must
not call import/mutation/shutdown recursively or throw. Nested source calls are
explicitly rejected; legacy APIs are not retrofitted with a reentry guard.

`check(context, 0, io)` polls cancellation; `check(context, 1, io)` MUST verify
source stability and cancellation immediately before publication. Neither callback
may asynchronously access supplied storage. A future native adapter must retain
its capability/library/lease for the entire call. OpenCascade knows neither
filesystem paths nor Windows handles nor the `cad_asset_fs` implementation.

Each IO response is initialized to v1 with known zero count. Callback return 0 is
success, -1 is cancellation, any other value is failure. Set error domain/code/detail
to preserve the provider cause. Flags bit 0 means count known, bit 1 means EOF;
all other bits are invalid. `check` must report zero bytes. A valid prefix returned
with error is counted but never parsed. Invalid counts or callback exceptions set
`count_valid=0`; earlier confirmed bytes remain observable. No callback follows the
first failure or the final successful check, including destructors/publication.
Exceptions from callbacks are contained defensively, but throwing is not the C contract.

`bytes_provided` measures confirmed transport bytes including probes, cache fills,
seeks and replay; it is NOT a distinct-byte count or the parser cursor. A 64 KiB
streambuf bounds individual requests. Seek/tell/putback maintain a checked local
cursor in [0,length]; putback cannot change bytes. Transport budget admits whole
requests conservatively, so a provider making short reads can reach its budget
before the parser's logical end. There is no retry/wait loop for zero reads.

Result has status, failure phase, provider error domain/code/detail, publication,
resource kind (1=shape, 2=mesh), token, fingerprint, shape type and bounded message.
Transport failures report TRANSPORT; parsing/validation/final verification/publication
report their respective phases. Native parser exceptions have no provider domain
(domain/code zero) and are classified FORMAT; allocation/publication exceptions
at publication are PUBLICATION. STL counts and bounds describe the published mesh;
BREP counts/bounds fields are reserved as zero, not geometry measurements.

OCCT objects stay local under RAII while parsing/validation/fingerprint/output
preflight occur. Final check closes the source before registry work. Registry
reservation/insertion and result publication use the existing locked batch
mechanism; failure erases only this call's inserted entries. The result copy is
nonthrowing. Token sequence gaps after failed prepublication preparation are allowed;
no registered token is hidden. `published=1` transfers responsibility for exactly
one new registry resource to the caller, which must immediately adopt it into
2B1A custody. There is no ownership transfer of the input capability. No destructor
calls back into the source. No filesystem effect is performed by these APIs.

## Formats and completeness

BREP: ASCII CASCADE Topology/TopTools V1, V2 and V3 only. A bounded header check
selects these formats, then `BRepTools::Read(std::istream&, BRep_Builder, progress)`
remains the sole BREP parser. Shape must be non-null and pass topological validation;
vertices, triangulation positions/normals and triangle indices are checked.
Only trailing ASCII whitespace is accepted. Whitespace after the final root token
is required, matching the productive writer. During OCCT parsing the stream throws
on badbit, failbit AND eofbit: checking state only after Read was insufficient in
the installed OCCT 8.0.1 SDK, which dereferenced a partial record after truncation.
Structural cuts exercise this boundary under the three build configurations.
V3 preserves serialized triangulations and normals; V1/V2 retain only information
represented by those legacy versions. Missing normals are not synthesized.

STL: binary with exact `84 + uint64_t(count)*50` length takes precedence, including
headers beginning with `solid`. Count must be positive and within quota; every
float32 normal/coordinate is finite, little-endian. The two attribute bytes are
accepted and ignored, matching the display pipeline. Binary trailing bytes are
forbidden, including whitespace. If exact binary framing does not match, strict
ASCII parsing must succeed in full; malformed binary is not accepted as partial mesh.

ASCII accepts one `solid`/`endsolid` block, ordered facet/outer loop/three vertices/
endloop/endfacet records, finite decimal numbers (one optional sign), ASCII whitespace,
blank lines and CRLF. Names are metadata and need not match. Multiple solids and
non-whitespace trailing content are rejected. Malformed facet records are never
silently skipped. Binary/ASCII facet normals are checked but not stored: like the
legacy default `RWStl` path, the result is a `Poly_Triangulation` without normals.
Coordinates are deduplicated exactly; facets with repeated vertex IDs are discarded
as in RWStl, preserving unused unique nodes. Collinear distinct nodes are retained.
A mesh with no surviving triangles fails. No tolerance or nearest-neighbor merge.

Tests compare nodes/indices directly with the installed RWStl default reader,
including a collapsed facet. Leading whitespace and blank lines are a controlled
syntax extension: this SDK's RWStl rejected those fixtures, so their acceptance
is tested separately and is not claimed as legacy-reader equivalence. The productive
sphere mesh sink can emit collapsed pole facets; source counts can therefore be
smaller than raw sink facet count without constituting incomplete parsing.

## Limits and cancellation

All quotas must be positive. Defaults (caller may reduce/change within ABI limits):

| Limit | Default |
|---|---:|
| Captured input length | 256 MiB |
| Confirmed transport/request budget including rereads | 1 GiB |
| Vertices / triangulation nodes | 1,000,000 |
| Triangles / declared STL facets | 2,000,000 |
| BREP topology entries | 1,000,000 |
| ASCII STL tokens | 32,000,000 |
| ASCII STL bytes per line | 16,384 |
| ASCII STL bytes per token | 128 |

Source length must fit INT64_MAX; OCCT node/triangle/topology quotas must fit INT_MAX.
Binary count arithmetic uses uint64_t before multiplication. STL memory grows with
bounded unique nodes/facets plus lookup overhead, not an entire serialized input
copy. BREP has a bounded transport buffer but the OCCT model is materialized.
Topological/triangulation BREP limits are checked AFTER OCCT parsing and allocations.

Cancellation polls run before reads, through OCCT's supplied progress interface,
in STL record loops and periodically in large validation/copy loops, then at final
verification. Unexpected OCCT progress on another thread requests abort without
calling the source there. Individual OCCT allocations, map construction, topology
analysis/fingerprint and registry allocation/publication lack interruptible progress;
there is no hard latency bound. Final check is the admission boundary: cancellation
arriving after it cannot pretend the ensuing real publication was rolled back.
The caller must reconcile the returned published token using custody.

## Security boundary and exclusions

This source boundary removes pathname resolution from OCCT and supports TOCTOU-safe
operational integrity only when the caller supplies a live, identified, immutable
capability and real final verification. A fixed length alone does not ensure identity
or immutability. The adapter does not independently hash or lock filesystem objects.
Memory tests detect actual byte mutation with a captured test fingerprint; they do
not prove `cad_asset_fs` integration, Windows races or filesystem identity checks.

Byte limits are NOT absolute containment against deliberately hostile BREP expanding
inside the OCCT parser. Unchecked internal OCCT indices, excessive allocations or
native faults on adversarial content are not made safe by postvalidation or C++
exception handling. OS faults are not swallowed with SEH. Parsing completely
untrusted BREP requires an additional isolated-process policy, outside this task.
The registry fingerprint is the legacy identity/count fingerprint, not a stable
geometric content hash. Tests use geometry metrics/triangulations for equivalence.

## Validation and integration gate

Source test uses memory providers, short reads, first/middle/last errors, cancellation,
mutation rejection, all count semantics, seek/putback, ABI errors, quotas, truncated
records and injected fingerprint/reserve/insertion failures. The productive DLL
smoke performs BREP sink/source/re-serialization, native validation, STL sink/source,
real memory mutation detection, resource destruction and unchanged file inventory.
Geometry tests cover box/sphere/compound, V1-V3, tessellated normals, topology counts,
bounds, mass/centroid signatures and a productive transform after restoration.
Repeats assert empty registries; test-only fault code is absent from the DLL.

Build: `cmake --build build/occ_mesh_stream --config Debug` (then Release), with
`ctest --test-dir build/occ_mesh_stream -C Debug --output-on-failure` (then Release).
ASan: `build/occ_mesh_stream_asan`, Release, FLCAD_OCC_ADDRESS_SANITIZER=ON and the
MSVC Hostx64/x64 ASan runtime on PATH. The DLL and source test/smoke are instrumented;
prebuilt OCCT is not. Windows ASan is not LeakSanitizer; repeated owner/registry checks
are not an exhaustive third-party heap-leak proof. No build artifacts are versioned.

No Dart, filesystem adapter, custody migration or producer integration is included.
Next gate: native source/sink connection with `cad_asset_fs`, lease/lifecycle/error
mapping, final identity/volume/size/hash verification, and real inter-DLL smoke before
2B2A migration. The real two-NTFS-volume test remains pending in the filesystem work;
no memory double replaces it. These native APIs do not themselves approve 2B2A.

Validation recorded on Windows x64 / OCCT SDK 8.0.1, 2026-09-09:

| Configuration | Build | CTest |
|---|---|---|
| Debug | Passed | 9/9, 9.89 s |
| Release | Passed | 9/9, 7.75 s |
| Release + AddressSanitizer | Passed | 9/9, 30.45 s |

There are nine registered tests (two new source executables and the extended C ABI
check), not 27 distinct tests. Across configurations there were 27 successful test
executions. Source tests include twenty repeated BREP/STL create/destroy cycles.
Productive smokes resolved the DLL from the respective Debug/Release output directory
and the ASan Release directory; no missing dependency or sanitizer diagnostic remained.
Existing OCCT deprecated-type warnings remain. Logs are ignored under
`build/occ-source-{debug,release,asan}.log` and each CTest Temporary directory.

Three independent read-only reviews covered ABI/streambuf, parsing/atomicity, and
ownership/failure tests. Invalid double-sign parsing, whitespace handling and missing
transport/geometry/reservation tests were corrected. ASan located the truncated-field
OCCT fault; enabling eofbit exceptions and adding structural cuts resolved the tested
case. Final reviews found no critical/high/medium findings in scope, with the explicit
hostile-BREP and future filesystem integration limitations above. Formatting and
`git diff --check` passed. No Dart, helper or producer files changed.
