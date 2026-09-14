# STL-2C lifecycle gate

This gate records the evidence for managed mesh-only STL lifecycle behavior.
The durable identity is `displayMeshAssetId` plus `displayMeshSha256`; no
native token, pointer, capability, pathname, residence fingerprint, shape, or
shape asset is part of the document contract.

| Failure or lifecycle boundary | Evidence |
| --- | --- |
| Source failure before promotion | `invalid STL before promotion leaves document scene assets and custody unchanged` |
| Failure after promotion before documentary commit | `post-promotion failure preserves one quarantined asset without publication` |
| Documentary persistence failure | `persistence failure preserves previous document scene and selection` |
| Confirmed post-commit cleanup/recovery | `post-commit cleanup failure is observable without undoing Undo` |
| Open validation: missing, hash, schema, content, contradictory mesh-only contract, second entity | `STL open rejects ... and preserves complete prior state` |
| Redo validation and no partial history publication | `failed STL Redo preserves document, history, scene, selection and owner` |
| Import, open, and Redo revocation | `superseding open deterministically revokes suspended STL import`; `... revokes suspended STL open ...`; `superseding operation and shutdown revoke suspended STL Redo` |
| Shutdown drainage and lease ownership | `shutdown waits for suspended STL import cleanup`; `shutdown ... STL open ...`; `native_allocation_custody_test.dart` lease and quarantine cases |
| Undo/Redo visual ordering, durable asset stability, repeated owners | `managed STL Undo removes visual state before mesh disposal`; `repeated STL Undo Redo has one mesh owner per entity and reopens` |
| BREP, legacy, mixed, and multi-STL compatibility | `managed_brep_test.dart` legacy/history cases; `mixed managed BREP and STL restore their distinct ownership`; `STL history preserves managed BREP ownership and scene` |
| No legacy pipeline/pathname fallback | `pathImports() == 0` assertions in managed STL/BREP tests and `native_source_bridge_test.dart` |

The shared preparation path is intentionally tested once where a guarantee is
identical for BREP and STL: CAF identity/inventory checks, C-to-C source
import, custody admission, descriptor validation, prepared scene geometry,
leases, quarantine, and recovery. STL-specific tests assert the mesh-only
variant has no shape retention or shape asset.
