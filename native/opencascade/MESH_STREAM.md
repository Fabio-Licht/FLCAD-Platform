# Mesh stream ABI v1

Independent additive native foundation for 2B2A, based on main 87bab03.
The transactional inventory at 2cda9eb identified that flcad_occ_mesh required
an output pathname. Its existing contract and all legacy exports are unchanged.
No Dart, filesystem helper, producer migration or documentary commit is included.

## Contract

`flcad_occ_mesh_stream_version()` returns 1. `flcad_occ_mesh_stream_v1` takes
an existing borrowed shape token, absolute linear deflection (model units),
angular deflection (radians), triangle budget, sink and result storage.
No pathname or OS file handle is accepted. C header: `include/flcad_occ_mesh_stream.h`.
Symbols use the host C ABI (`__cdecl` on Windows), natural packing, fixed-width
integers. Sink size/version and result size must match exactly. On Windows x64,
sink is 24 bytes and result is 288 bytes. Other architectures are not validated.
Foreign pointers must be valid and buffers nonoverlapping for the whole call.
Invalid result storage/size returns INVALID without writing the result.

Sink has opaque context (NULL permitted) and a synchronous byte callback. Context
and code remain alive until return; byte span and accepted pointer are borrowed
only during callback. Maximum chunk is 64,000 bytes. No callback runs on another
thread. The sink is snapshotted before use. No finish/abort callback is needed:
the caller receives a final result and alone decides whether to seal/commit its
storage. Successful callbacks are not evidence that storage was flushed/durable.

The callback sets accepted to the actual consumed prefix, even on error:

- code 0 and full count: continue;
- code -1: cooperative cancellation;
- any other code: sink failure, consumer code preserved verbatim;
- short count (including code 0): terminal sink failure, no retry;
- count greater than offered: terminal sink failure, unknown current effects.

No callback occurs after failure. bytes_accepted records the confirmed prefix,
including a valid partial count. accepted_count_valid=0 means current callback
consumption is unknown; prior confirmed bytes are retained as a lower bound.
Callbacks must not throw. Defensive containment handles OCCT, standard and
unknown exceptions anyway, classifies them as SINK, and marks consumption unknown.
Exception messages are copied/truncated to 255 bytes; returned consumer codes
are the preferred stable way to preserve an application-specific cause.
No rollback, flush, deletion or promotion is attempted.

Statuses distinguish invalid arguments, absent shape, tessellation, serialization,
sink, cancellation and representation/budget limits. Every C boundary contains
OCCT, standard and unknown exceptions; reporting is allocation-free. A failed
stream can contain a complete-looking header and only a prefix of the payload:
only OK permits the caller to consider it complete. Failure after accepting the
last chunk still reports failure and retains all accepted bytes.

## Geometry and format

The implementation holds an OCCT reference to the input and deep-copies geometry
without existing triangulations. It tessellates only this private copy, serially.
Input token, ownership, registry and original triangulation remain unchanged.
Caller must hold its ownership/lease and prevent concurrent legacy mutations
or shutdown/reentrant mutation during the operation. Registry lookup is locked;
no registry lock is held while calling the consumer. This API does not implement
Dart custody or acquire a Dart lease.

Linear deflection must be finite in [1e-6,1e6], angle in [1e-4,pi], budget in
[1,UINT32_MAX]. These explicit guardrails reject pathological requests, but are
not a bound on OCCT tessellation memory/time. Budget is checked after meshing
and before the first byte. Meshing itself is synchronous and not cooperatively
interruptible; cancellation is observed when the sink receives a chunk.

Output is binary STL, preserving the existing viewport path's format:

- 80-byte deterministic header (`FLCAD binary STL stream v1`, then zeros);
- uint32 little-endian triangle count;
- exactly count records of 50 bytes each: unit facet normal and three positions
  as 12 IEEE-754 float32 little-endian values, then zero uint16 attributes;
- transformed positions and winding adjusted for reversed faces;
- degenerate facet normal is zero; nonfinite/out-of-float32 values fail;
- exact success length is 84 + 50 * count, computed with 64-bit accounting.

No mesh token is generated. Native topology and triangulations necessarily occupy
memory, plus one private shape copy; serialization uses only a fixed 64,000-byte
buffer, without a second full serialized mesh. Counts use checked 64-bit addition
and the STL uint32 limit. Triangle iteration avoids signed terminal overflow.

STL carries flat normals/positions, not persistent topology IDs, UVs, colors or
per-vertex smooth normals. The existing display pipeline already consumes STL,
so an internal replacement format is unnecessary for visual compatibility.
Serialized bytes do not establish native shape identity. Identity must remain
with the shape/reference; the eventual asset hash identifies serialized payload.

Determinism is scoped to identical geometry/parameters, SDK version and platform.
Private remeshing and disabled parallel tessellation avoid prior triangulation
cache and worker ordering differences. OCCT versions/platforms may change mesh
choices; no cross-version byte stability is promised. Legacy uses parallel
meshing; controlled fixtures compare exact records, not an unsupported claim of
byte equality for every OCCT shape. Header text intentionally differs.

## Validation

Tests include an implementation-level executable with hooks compiled only there,
a smoke linked to the productive DLL, and a C translation-unit ABI smoke.
The existing native smoke and atomic-output regressions remain in CTest.
New cases cover multi-chunk output; fail/partial/invalid-count/cancel at first,
second and last chunk; consumer exceptions after consumption (standard, OCCT,
unknown); missing callback/context/version/result; unknown token; no faces;
unmeshed shape; invalid and accepted extreme parameters; budget/overflow;
exceptions before/at/after first write; original triangulation and registry
preservation; unchanged filesystem entry inventory; 20 identical repetitions.

Legacy comparison uses a box, sphere, and translated/reversed sphere. Except
for the producer-specific first 80 header bytes, count and all triangle bytes
must match exactly. Legacy reference files are created only in tests after the
no-file assertion and removed by the test. New production code has no IO calls.
The DLL smoke verifies successful streaming and cancellation, original validity,
unchanged registry count and final destruction by its original owner.

Validation on Windows x64, MSVC 14.51 / Visual Studio 18 2026, OCCT 8.0.1:

| Configuration | Build | CTest |
|---|---|---|
| Debug | passed | 5/5, 2.27 s |
| Release | passed | 5/5, 2.90 s |
| Release + MSVC AddressSanitizer | passed | 5/5, 3.00 s, no sanitizer report |

The DLL smoke delivered 249,984 bytes in four chunks (4,998 triangles), then
cancelled a second operation and validated/destroyed the original shape normally.
Atomic-output regression reports 38 cases. Streaming matrix includes 21
consumer-failure permutations, nine injected exception permutations and 20
repeat outputs, in addition to preflight/geometry/equivalence assertions. These
are checks inside executables, not additional CTest tests.

Reproduction (Visual Studio bundled CMake/CTest): configure native/opencascade
with `-G "Visual Studio 18 2026" -A x64 -DFLCAD_OCCT_ROOT=<SDK>`;
build `--config Debug` / `--config Release`, run CTest `-C <config>
--output-on-failure`. ASan uses a separate build directory and
`-DFLCAD_OCC_ADDRESS_SANITIZER=ON`, Release; MSVC Hostx64/x64 runtime directory
must be on PATH. Instrumented targets include the production DLL, streaming
matrix and streaming DLL smoke. OCCT SDK deprecation warnings remain unchanged.
Logs/build artifacts are ignored under `build/occ_mesh_stream*` and
`build/occ-stream-*.log`. No build artifact is committed.

Three independent read-only reviews covered ABI/callbacks/exceptions,
ownership/lifetime, and equivalence/test quality. Medium findings were corrected:
unknown effects after consumer exception, terminal signed-index overflow,
specific exception-status assertions, curved/transformed legacy comparisons,
and a smoke actually linked to the productive DLL. Revalidation found no
remaining critical/high/medium findings. clang-format verification and Git
whitespace checks passed.

AddressSanitizer
instruments our code, not the prebuilt OCCT DLLs; Windows ASan is not LeakSanitizer.
Registry/sequence invariants and repetition exercise logical resource lifetime;
they do not constitute an exhaustive heap-leak proof for the third-party SDK.

## Remaining integration work

The native display-stream obstruction is addressed by this API, once validation
passes. 2B2A still needs a typed FFI sink adapter on the calling isolate, custody
and lease acquisition, bounded delivery into staging, error/cancellation mapping,
seal/promotion and documentary/scene/Undo lifecycle. Callback code must not use
an asynchronous Dart callback or outlive its native call. BREP serialization
still has its legacy pathname API; preserving imported BREP source via staging
or adding native BREP streaming remains a separate decision. No producer is
migrated and no 2B2A/2B2B approval is implied.
