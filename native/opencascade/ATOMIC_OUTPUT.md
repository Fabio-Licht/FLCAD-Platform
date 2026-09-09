# Atomic native outputs

Scope: shape creation through `output`, STL import, and surface intersection.
The C ABI and Dart FFI signatures are unchanged. This change does not introduce
Dart ownership, leases, adapter coordination, file staging, or physical GC.

## Buffer contract

Successful textual outputs require a non-null writable buffer with capacity
including the NUL terminator. Zero, insufficient capacity, and overlapping
result fields are errors. There is no size-query mode. Success never truncates
a token, fingerprint, type, or JSON. The shared textual copy helper also applies
this rule to topology, quality, validation, and healing-proposal JSON.

Callers must provide valid pointers and the advertised writable capacity;
the ABI cannot verify arbitrary pointer validity. STL scalar outputs each
require one object and bounds requires six doubles (the ABI has no separate
bounds capacity). Inputs must remain readable during the call. Output buffers
and the error buffer must not alias inputs or each other.

On failure, result fields are not published by the three allocation paths.
The integer status is authoritative. Error text alone may be shortened to fit,
is NUL-terminated when capacity is positive, and has control bytes sanitized.
A missing/zero-capacity error buffer cannot turn failure into success; reporting
performs no allocation and throws no exception.

There is no required-size output in the existing ABI. Insufficient capacity
returns an explicit error without registration. If size negotiation is needed,
the compatible extension would be a separately named API/version with required
length output(s), preserving these existing symbols and signatures. No such
extension is introduced here.

## Publication and compensation

1. Validate geometry and inputs; compute fingerprint and metadata locally.
2. Reserve a sequence token without registering it. Exhaustion fails before
   wraparound; gaps are allowed. Shutdown does not reset the sequence.
3. Assemble the entire response and preflight every output.
4. Reserve bookkeeping, acquire the registry mutex, reserve registry capacity,
   and insert using `emplace`, rejecting collisions without replacement.
5. Copy only already prepared bytes/scalars, then return success.

The internal batch publisher holds the mutex throughout insertion, publication,
and compensation. It reserves capacity before insertion so saved iterators
remain valid. If insertion/publication throws, it erases only those iterators,
then rethrows the original error. Iterator erase does not hash or allocate;
the stored OCCT handles have non-throwing destruction. Thus this compensation
path has no fallible secondary operation or swallowed rollback error. It never
calls the public destroy API. Existing entries cannot be removed by collision.

Public destroy still reports an unknown token as an error, including a second
destroy of a resource already removed. Registries remain global to the loaded
library; adapter coordination remains a separate task. Token non-reuse here is
within that library lifetime, not an identity guarantee across DLL reloads.

## Intersection and exceptions

The existing intersection ABI returns one aggregate section shape, optionally
identified by the existing `token` JSON field. It does not return one allocation
per edge. This schema is preserved. No-hit produces complete JSON without a
new allocation. Fingerprint, token and JSON are prepared before publication.
JSON streams enable `badbit`/`failbit` exceptions so serialization failure cannot
silently publish a prefix. The same batch publisher supports multiple entries;
tests directly exercise two actual registry entries and rollback on the second.

Affected exports contain `Standard_Failure`, `std::exception`, and unknown
exceptions using the existing failure status. Shared-copy consumers have the
same containment. Unrelated exports still requiring separate review are
`flcad_occ_shutdown`, `flcad_occ_diagnostics`, and `flcad_occ_shape_count`
(mutex/allocation failure); `initialize`, `export_shape`, `mesh_geometry`, and
`mesh` retain their existing OCCT-only catches. Static `version`/`capabilities`
return literals.
No change to meshing geometry or `flcad_occ_mesh` output behavior is intended.

## Tests and production isolation

`flcad_occ_atomic_output_test` compiles the implementation into its own executable
with `FLCAD_OCC_TESTING`; the production DLL never receives that definition.
No test-only exported ABI is added. Hooks inject deterministic errors after
fingerprint, after selected shape/mesh insertion, and in JSON stream state.
Tests inspect actual token presence and exact compensated-entry counts in the
actual OCCT registries. They exercise all three exception families, collisions,
buffer boundaries, aliases, existing-entry preservation, sequence exhaustion,
STL import, real planar intersection and transformation. The existing native
smoke additionally covers primitives, extrusions, surface operations, STEP and
STL roundtrips. No application/GPU build is needed.

Run only the native targets:

```text
cmake --build build/opencascade-native --config Release --target flcad_occ_atomic_output_test flcad_occ_native_smoke
ctest --test-dir build/opencascade-native -C Release --output-on-failure -R "^flcad_occ_(atomic_output_test|native_smoke)$" --timeout 60
```
