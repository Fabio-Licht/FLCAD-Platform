# STEP source streaming — STEP-1A0

## Scope and symbols

This stage adds only a native single-part STEP boundary. It does not connect STEP
to CadRuntime, Dart, staging, appearance persistence, scene publication or
save/open/Undo/Redo.

| DLL | New exports |
| --- | --- |
| flcad_opencascade | `flcad_occ_step_source_version`, `flcad_occ_step_read_v1` |
| cad_occ_bridge | `cob_step_version`, `cob_step_result_size_v1`, `cob_step_run_v1` |

Headers: `include/flcad_occ_step_source.h` and
`../cad_occ_bridge/include/cad_occ_bridge.h`. All new contracts are additive v1,
natural host C layout, using existing calling conventions. Existing signatures,
result layouts and source versions are unchanged. Source kind **3** is an additive
option to `cob_begin_v1`; kinds 1/2 still mean BREP/STL. STEP operations must run
through `cob_step_run_v1`; the old run rejects them without consuming the operation.

The bridge dynamically resolves versioned functions from retained module anchors.
It retains the existing CAF source lease, passes callbacks directly C→C, and uses
the existing prepare/check/release and cancellation machinery. There is no STEP
byte callback in Dart, temporary file, pathname parameter, reopen, or pathname
fallback. Test fixtures are serialized by XDE into an in-memory stream; the
integration smoke creates a controlled CAF file solely to exercise admission.

## Stream safety and completeness

The installed SDK is OCCT 8.0.1. `STEPCAFControl_Reader::ReadStream` delegates
the principal parse to `STEPControl_Reader::ReadStream`. Transfer can subsequently
load external files. This is visible in the
[upstream OCCT reader](https://github.com/Open-Cascade-SAS/OCCT/blob/V8_0_0/src/DataExchange/TKDESTEP/STEPCAFControl/STEPCAFControl_Reader.cxx)
(`ReadStream`, `Transfer`, `ReadExternFile`) and is the reason rejection occurs
**before** transfer.

The shared SourceInput streambuf performs all STEP transport through the admitted
source. A bounded lexical pass checks one Part21 HEADER/DATA frame, balanced
parameters, complete termination, unique checked entity labels, token/line/count
limits, and absence of trailing content. It then rewinds the same source for
`STEPCAFControl_Reader::ReadStream("caf-step-source", stream)`. This identifier is
diagnostic only, never a filename supplied to ReadFile.

The accepted subset has exactly FILE_DESCRIPTION, FILE_NAME, FILE_SCHEMA in its
header, one DATA section, one PRODUCT, one PRODUCT_DEFINITION, one transferable
root, one free non-reference/non-assembly XDE root and one solid. Optional Part21
header records, edition-3 anchors/references, binary parameters, shells, hybrid
compounds and multiple roots/products are outside this boundary and rejected.
Whitespace and comments after the final terminator are permitted; another file
or any other trailing content is rejected.

External-related entity keywords are rejected conservatively during framing.
A second gate uses `STEPConstruct_ExternRefs::LoadExternRefs/NbExternRefs`
and checks product relationships before transfer. Unknown/error model entities,
load/semantic failures and transfer failures are rejected, and the loaded entity
count must equal the framed count. Thus an external fixture does not even enter
ReadStream, and neither external nor assembly fixtures enter Transfer, as checked
by test-only counters. No ReadFile call exists in this implementation.

Shape validation reuses BREP source validation: non-null valid topology, bounded
subshape count, finite vertices/triangulations/normals and valid triangle indices.
There is no artificial shape or STEP→STL conversion.

## Metadata

The caller supplies two synchronous writable UTF-8 buffers in
`occ_step_buffers_v1`: name and unit, each with capacity including the NUL.
Descriptor, result, buffers, source and limits must not overlap. Exact struct
capacities and versions are required. Missing buffers are rejected before parse;
insufficient capacities are rejected after metadata preparation and before any
shape registry insertion.

`occ_step_metadata_v1` contains only fixed-width scalars:

- UTF-8 name/unit byte lengths excluding NUL;
- declared length scale in meters per source unit;
- resolved geometry scale, fixed to 0.001 meters per unit (millimeters);
- `has_color`, and four doubles for linear RGB plus alpha.

The name comes from the single XDE root's TDataStd_Name. OCCT handles STEP string
escapes; raw UTF-8 transport strings and decoded output are validated. Embedded
NUL, controls and unpaired Unicode surrogates in names are rejected. The current
reader requires its model encoding configuration to be UTF-8 and fails closed
otherwise. Unit names come from FileUnits; the declared scale is computed from
global unit contexts with STEPConstruct_UnitContext. Unresolved or conflicting
length units fail. XDE document units are explicitly set to millimeters before
transfer, independently of the source unit. Tests check both the source scale
and the actual restored solid dimensions for meter and millimeter fixtures.

Only a root surface color, falling back to root general color, is returned.
There is no body/face color extraction or flattened color inference. If absent,
`has_color=0` and all RGBA values are zero: no invented gray. Present colors are
finite linear RGB in [0,1], alpha exactly 1. Transparency entities or nonopaque
root alpha are rejected. Textures, PMI and PBR are not supported. Other XDE modes
are explicitly disabled. Nothing in this stage persists or renders this metadata.

## Atomicity, ownership and exceptions

All OCCT/XDE parsing, transfer, metadata extraction, shape validation, fingerprint
preflight and metadata copies happen before registry publication. The shared
locked publish_batch mechanism reserves/inserts one shape and publishes the POD
result without throwing. Insertion failure erases only the new entry. A metadata
preparation/copy failure leaves no new token, and valid string buffers are reset
to empty; prior registered shapes remain usable. Token sequence gaps are allowed.

The shape token is process-local, borrowed while held in the bridge's escrow.
Run does not adopt or transfer ownership to Dart. A later custody capture may
call the existing adopt; close destroys an unadopted token and releases the CAF
lease. Adopted resources are the custody owner's responsibility. The XDE document,
reader and intermediate data stay under local RAII and are not retained.

Standard_Failure, standard C++ and unknown exceptions are contained by the shared
source C boundary and bridge. Provider domain/code/detail survive source errors.
The ABI requires valid caller memory; bad addresses/access violations are not
covered by C++ exception handling and are not an untrusted-process RPC interface.

## Limits and cancellation

Existing occ_read_limits_v1 is reused without changing layout: input/read budgets,
topology/entity count, token count, line bytes, token/string bytes and mesh limits.
Defaults remain 256 MiB input, 1 GiB cumulative transport, 1,000,000 topology
entities, 32,000,000 lexical tokens, 16,384 line bytes and 128 token bytes.
Additional hard limits are 256 nesting levels, positive entity labels <= INT_MAX,
4,096 UTF-8 output-name bytes and 256 unit-name bytes. The framing pass and replay
both contribute to cumulative transport bytes.

Cancellation is cooperative before calls, during source refills/framing,
during transfer progress and at final source verification. ReadStream exposes no
progress range: parsing already underway within an OCCT call without another
source refill cannot be forcibly interrupted. The boundary polls after parse and
will not transfer/publish canceled work. No timeout, hard CPU/memory sandbox or
forced parser interruption is promised. Parser-internal allocations are not fully
bounded by input quotas. Source callbacks stop after terminal failure or the final
successful check; no callback occurs during registry publication or destruction.

## Test matrix

| Guarantee | Native test |
| --- | --- |
| XDE name, mm/m source unit, canonical mm geometry, exact root RGB | step_source_test |
| Explicit absent color | step_source_test; step_bridge_smoke |
| Assemblies, multiple products, externals before Transfer | step_source_test + parser/transfer counters |
| Truncation, invalid/unknown entity, trailing content, duplicate/oversized label, invalid UTF-8 | step_source_test |
| Source failures and OCCT/standard/unknown callback exceptions | step_source_test |
| Input, transport, token and entity quotas | step_source_test |
| Before-call/final cooperative cancel | step_source_test; step_bridge_smoke |
| Missing/small/overlapping output storage | step_source_test; step_source_c_abi; step_bridge_smoke |
| Fault after metadata preparation and between copies, insertion/reserve/fingerprint | step_source_test + test-only source/publication hooks |
| No token while source is being read; old resources remain valid | step_source_test callback counts and registry baseline |
| C layout and versioned productive exports | step_source_c_abi |
| CAF admission once, busy lease, escrow/adopt/compensating close, unchanged SHA-256/size | step_bridge_smoke with productive DLLs |
| Existing BREP/STL input and atomic output contracts | existing source, BREP/mesh stream and atomic output CTests |

The security review follows source authority, external rejection before transfer,
buffer alias checks and rollback ordering. The STEP/XDE review follows product/root
counts, resolved versus declared units, UTF-8 names, root-color precedence and
explicit absence. No medium-or-higher findings remain after the documented gates
and regression checks.


## Validation completed

| Configuration | Result |
| --- | --- |
| OpenCascade Debug / Release builds | Passed |
| cad_occ_bridge Debug / Release builds | Passed, including /W4 /WX /analyze |
| OpenCascade CTest Debug / Release | 12/12 passed per configuration |
| OpenCascade existing ASAN configuration, RelWithDebInfo | Build and 12/12 CTests passed |
| cad_occ_bridge CTest Debug / Release | 2/2 passed per configuration |
| CAF CTest Debug / Release | 19 passed and cross-volume test skipped per configuration |
| Productive STEP C→C DLL smoke | Passed in Debug, Release and ASAN |
| clang-format dry run; git diff --check | Passed |

The ASAN run uses the installed MSVC ASAN runtime directory in its execution PATH;
CAF and cad_occ_bridge dependencies in that smoke are the existing Release DLLs.
This is native validation, not deployment into the application. An initial CTest
run concurrent with a Release build failed the old filesystem inventory assertions;
the complete suites passed after builds finished. An initial ASAN launch lacked
its runtime DLL; the run with the scoped execution PATH passed.
