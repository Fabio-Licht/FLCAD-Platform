# 2B2A1: native source bridge

## Scope and separation

The normal merge of `fix/occ-mesh-stream-output` preserves the mesh sink,
BREP sink and source commits. This stage adds an internal Windows x64 C adapter,
`cad_occ_bridge.dll`, between `cad_asset_fs.dll` and `flcad_opencascade.dll`.
No ImportEngine, MeshEngine, desktop import command or productive producer is
migrated. No parser, GC, persistent token, temporary pathname transport or Dart
block callback is added. STL remains a display asset; BREP is durable CAD data.

```
Dart admission + expected identity/size/SHA-256
  -> bridge operation retaining both module references
  -> CAF source lease retaining file and every ancestor
  -> worker isolate invokes one synchronous native run
  -> CAF preparation + C read_at/check -> OCCT source parser
  -> OCCT final validation + atomic registry publication
  -> native escrow -> Dart custody -> native adopt
  -> release source lease and operation module references
```

OCCT includes only its existing abstract source contract. CAF knows bytes and
file identities, not shapes. The adapter explicitly populates `occ_source_v1`
and translates `caf_result` fields; it does not reinterpret one ABI struct as
another. No Windows file handle or pathname enters the OCCT call.

## ABI and callers

All APIs are internal, synchronous C ABI, version 1, Windows x64. Caller buffers
must be live, correctly aligned and non-overlapping for the call. Version and
exact structure sizes are validated before acquiring a source. Function pointers
are trusted, live exports from the two loaded modules, not serialized identifiers.

CAF adds `caf_source_version`, `caf_source_acquire`, `caf_source_prepare`,
`caf_source_read`, `caf_source_check`, `caf_source_release`. Its existing result
layout remains unchanged. A lease is opaque and process-local. Acquire validates
the earlier sealed metadata and pins the same object. Prepare/check take a C poll
callback: zero continues, nonzero cancels. The callback is synchronous, must not
throw/block/reenter CAF and its context remains live until return. The productive
adapter callback only reads an atomic cancellation flag. No filesystem registry
mutex is held during callback execution; the per-object IO mutex is held.

The adapter exports:

```c
uint32_t cob_version(void);
uint32_t cob_result_size_v1(void);
int32_t cob_begin_v1(const void *caf_anchor, const void *occ_anchor,
                    uint64_t file, const caf_result *expected,
                    uint32_t expected_size, uint32_t kind,
                    cob_result_v1 *out, uint32_t size);
int32_t cob_run_v1(uint64_t operation, cob_result_v1 *out, uint32_t size);
int32_t cob_snapshot_v1(uint64_t operation, cob_result_v1 *out, uint32_t size);
int32_t cob_cancel_v1(uint64_t operation);
int32_t cob_adopt_v1(uint64_t operation);
int32_t cob_close_v1(uint64_t operation, cob_result_v1 *out, uint32_t size);
```

Kind 1 restores a BREP shape; kind 2 imports an STL mesh. The anchors are addresses
of version exports, never `HANDLE`s. The result contains independent bridge,
filesystem and OCCT status, phase, confirmed byte count, error domain/code/detail,
publication/escrow state and compensation code/message. Filesystem domain is
`0x434146`; detail carries Win32 in the high 32 bits and NTSTATUS in the low bits.
The complete CAF result remains available. Bridge phases are admission=1,
prepare=2, read=3, final check=4, publication=5, release=6, destroy=7,
separate from the unchanged OCCT parser phase. `source_read.reserved & 1` distinguishes
an exact copied prefix (including on error) from a metadata byte count.

## Anchored validation and bounds

Acquire is short: pin capability and ancestors, validate identity and size. SHA
preparation runs in the worker, with cancellation polling, not on the UI isolate.
Inputs must be nonempty and at most 256 MiB, matching the default OCCT source
limit. OCCT's own geometry/count limits also apply.

Preparation uses the same live handle to compute a whole-file SHA-256 and one
digest per 64 KiB block. Reads verify identity/size, read complete affected blocks
into a private bounded buffer, verify their digests, then copy the requested
subspan. This prevents changed bytes reaching the parser even if a later writer
restores the old hash. The final source check repeats identity, size and whole
hash on that object before OCCT publishes. The digest table is at most 128 KiB
at the input limit; transport buffers are bounded. OCCT still allocates geometry
and its existing parser structures. There is no full file copy in Dart.

CAF refuses close/write/seal/rename of leased nodes; ancestors remain pinned.
Operations on distinct objects can proceed concurrently. Reads of the same object
serialize its file cursor. The operation registry mutex is not held across CAF
IO or callbacks. The first read/check failure is sticky and blocks later reads.
Mismatch is reported as a quarantined source effect to the Dart coordinator;
inputs are preserved, never deleted or repaired.

## Ownership, publication and failure

| Phase | Owner and release authority |
|---|---|
| Before begin | Caller owns CAF capability; no OCCT allocation |
| Admitted | Bridge holds CAF lease and CAF/OCCT module references; Dart pins FS scope |
| Native parse | OCCT holds unregistered local geometry; synchronous callbacks borrow operation |
| Published | OCCT registry owns allocation; bridge escrow must adopt or destroy it |
| Custody capture | Dart registers identity and creates owner without await or notification |
| Adopted | Custody owns destruction; bridge releases source/module references only |
| Failed custody | Unadopted close destroys exactly once and records compensation |
| Failed compensation/release | Escrow/resources remain retained; session and FS quarantined |

The token is registered by OCCT only after complete parser validation and final
source check. It stays in the native operation's result while the worker returns;
Dart does not transport blocks or token buffers through the worker. On the root
isolate the result is snapshotted, registered immediately in custody and adopted
before progress callbacks or other notifications. A test-only assert can reject
custody to prove escrow compensation. The production path does not inject faults.

If an exception occurs after native publication, the adapter reconciles the
published result into escrow and clears `running`; it never reports the allocation
as undone. Dart captures it before raising `NativeSourcePublicationFailure`, which
contains the owner. A failed notification similarly contains the captured owner.
Cleanup failure preserves the original cause/stack, cleanup cause and any owner in
`NativeSourceRecoveryFailure`. It quarantines the native session and filesystem,
preventing destructive shutdown. Manual recovery is outside this stage.

## Cancellation, DLL lifetime and shutdown

`NativeSourceCancellation` is one-shot. Revocation before admission allocates
nothing; afterwards it sets the native atomic flag. Preparation, read callbacks
and final verification poll it. Cancellation after publication disposes through
custody instead of pretending publication did not occur. OS syscalls and OCCT
work between polling points are not forcibly interrupted; no hard latency bound
is promised.

Dart retains the adapter library for process lifetime and exposes no unload API.
Worker calls use its retained function address. Each native operation acquires
additional CAF/OCCT module references using `GetModuleHandleExW` and releases them
with RAII after successful close. Dropping the caller's DLL references during a
call cannot unload either module. Direct external registry shutdown is forbidden;
coordinated calls use the existing native session participant.

Shutdown order: stop admission; await participant operations and CAF source pins;
finish/compensate escrow; release CAF lease and operation DLL references; drain
custody owners/leases; then shut down the OCCT registry and close filesystem
capabilities. Repeated managed shutdown/dispose is idempotent. In quarantine,
shutdown fails observably and retains ambiguous resources rather than destroying
them. Calling native close while run is active returns busy. Caller close of a
CAF file or ancestor with a lease is also refused.

## Validation and instrumentation

`native/cad_occ_bridge/tests/smoke.cpp` uses real OCCT BREP/STL sinks, CAF files,
both DLLs and real parser/publication/destruction. It checks usable shape/mesh,
registry baselines, exclusive long Unicode paths, concurrent operations, module
reference retention, undersized output, missing/incompatible ABI, truncated
content and invalid expected identity/size/hash.

The fault executable has deterministic native thread barriers, cancellation
before/after chunks and at final check, confirmed-prefix IO failure, and exceptions
before parse/after publication. It releases barriers and joins threads before
asserting results, including timeout paths. `cad_asset_fs_source_test.dll`
(test target only) changes bytes through the real original file handle to prove
block/final hash rejection. This is deliberate fault injection, not a claim that
an external writer can bypass Windows sharing policy. Test-only bridge exports
exercise failed compensation and publication followed by error.

The 15 Dart tests exercise real BREP/STL through the bridge into custody,
disposal, metadata mismatch, cancellation, compensation, notification failure,
shutdown with lease, concurrent imports, missing DLL and quarantined cleanup.
Native tests additionally cover mid-stream faults, output capacity and ABI errors.
The existing CAF CTests cover filesystem races and confinement; OCCT CTests cover
parsers, sink/source failures and publication. No production importer is enabled.

`FLCAD_OCC_PATH_AUDIT=ON` (or environment `=1` for the Windows build) adds only
test counters for pathname imports and mesh registry size. Tests require these
counters and assert zero pathname imports. Default is OFF. Fault libraries are
top-level test targets, never installed in the application. The real Windows
smoke uses the built application DLLs; the audit-enabled build is a test build.

## Remaining limits and next stage

BREP is interpreted by the installed OCCT parser in-process. Bounds and atomic
publication do not sandbox malicious OCCT input or guarantee bounded parser CPU
and memory for hostile BREP. A separate process would be needed for such isolation.
Only Windows x64 and C: NTFS are exercised here. The real two-NTFS-volume test
remains pending for public release; a serial comparison double is not evidence
of a real cross-volume integration test. No VHD, partition or disk is changed.

This bridge is a prerequisite for 2B2A2, not its implementation: productive
imports still use their legacy paths. 2B2A2 must wire document admission,
durable payload/journal promotion, revision/session revocation, asset recovery and
document installation around these capabilities. No approval of the entire 2B1B
or of geometric/document correctness is inferred from this bridge smoke.

## Recorded validation (2026-09-09)

- Full Windows Release build succeeded with the installed OCCT 8.0.1 SDK and
  test pathname audit enabled (81.0 seconds on the final gate build, exit code 0).
- Native Debug and Release: CAF 19 passed / 1 skipped (`caf_volume`), OCCT 9
  passed, adapter 2 passed per configuration: 60 passes, 2 explicit skips total.
- Directed Dart suite: 160 passed (15 bridge, 61 staging, 12 gateway, 30 custody,
  42 runtime transactions). The 15 bridge tests passed again against CAF, OCCT
  and bridge DLLs from `build/windows/x64/runner/Release`.
- The isolated native build initially required its runtime DLL directory in PATH
  for Dart loading; the packaged smoke uses the application's bundled directory.
  Missing dependency was a test environment failure, not accepted as a pass.
- Three independent readonly reviews: ABI/lifecycle, ownership/compensation and
  concurrency/test validity. Prefix accounting, exception reconciliation,
  quarantined shutdown, cleanup cause preservation and a test timeout lock were
  corrected. No critical/high/medium findings remained in the final reviews.
- Existing filesystem races remain covered by CAF's real auxiliary-process
  tests. The new adapter concurrency barrier uses real threads; it is not a new
  claim of cross-volume or hostile-process isolation.

- `flutter analyze --no-pub`: no issues. Dart formatting and Git diff checks
  passed. CAF and adapter Debug/Release builds include MSVC static analysis.
  OCCT 8.0.1 emits existing deprecated API warnings; no build failure.
