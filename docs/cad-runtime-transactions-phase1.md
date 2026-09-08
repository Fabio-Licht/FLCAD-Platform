# CadRuntime transaction foundation - phases 1 and 2A

This is an incomplete, internal coordinator, not a global transaction guarantee.
The experimental manual transformation changes are not included or enabled.

## Migrated boundary

`mutate`, `undoDocument`, `redoDocument`, `open`, `close`, `save`,
`transitionFeature`, `setEntityVisibility`, `updateCollection`, `removeEntity`,
`moveToRecycleBin`, `restoreFromRecycleBin`, and `permanentlyDelete` share one
private FIFO Future chain. Internal helpers receive the current transaction and
never acquire that chain again. A private lightweight capability records a standalone runtime identity object,
exact transaction ID and active/revoked flag. It has no runtime back-reference,
document, history, directory, scene, kernel or snapshot. The full context is held
only by the controlled transaction execution. Active capability identity must
match the capability of that context. It is revoked in finally on success or
failure. The Zone carries that capability for reentry detection only: authority
requires identity with the runtime's active transaction and an active capability.
Inherited contexts from finished transactions do not block new work or authorize
internal shutdown. Listeners may enqueue work. Queue errors do not poison later entries.

At execution the context captures runtime owner, transaction ID, independent
monotonic runtime revision, session identity, lifecycle generation, document,
and directory. Admission captures lifecycle and, for ordinary writes, session,
so work queued for a preceding document cannot silently move into a new one.
Open and close revoke older requests synchronously. Stale running operations
finish their awaited producer, recover any JSON writes, and never install their
candidate. FIFO intentionally does not execute two open loaders simultaneously.

Document/history candidates and detached projection complete before active
installation. Scene notifications are withheld during that installation, and
current selection IDs determine the installed selected flags. Bounds/import
metadata are prepared first. Each installation increments the runtime revision
once; plain save and unsuccessful operations do not. This counter is independent
of the revision stored in documents and therefore never rewinds with undo.

`shutdown()` is the public drainage API: successful completion always means
admitted work has drained and dependencies have been disposed. External callers,
including callbacks with revoked or foreign contexts, receive the same Future.
A call from the active transaction requests shutdown using a private helper that
validates its explicit capability, then returns a StateError rather than allowing
self-wait. It never returns a false successful drainage acknowledgement. Private
helpers needing only the request call that capability-checked helper directly.

Synchronous dispose requests the same shutdown. Admission closes immediately.
Per-listener gates stop further delivery while dependency disposal waits for the
queue. Callers must await public shutdown before unloading external dependencies.

## Persistence and recovery limits

Public input is detached synchronously at call time after admission validation.
The accepted contract remains finite JSON numbers, strings, booleans, null, lists,
string-keyed maps and values supported by the existing toJson persistence contract.
NaN, Infinity, cycles and nonserializable objects remain unsupported. Capture
errors return through Future.error with the original error and stack; no partial
queue entry is admitted. Shutdown rejection precedes any attempt to serialize.

A private per-runtime snapshot store uses weak identity marks (Expando). Only
recursively immutable objects created by that store are trusted. There is no
public marker, no strong cache and no cross-runtime reuse of authority. Published
documents, entity data, metadata, parameters and history lists reject mutation.
Snapshots live only in the existing document/undo/redo references. The exact new
candidate prepared for projection is persisted and installed using existing JSON
APIs. Historical documents already marked as frozen are reused by identity, and
unchanged immutable geometry can be shared by normalized successor snapshots.
Public entities are always detached again even if previously published by us.
Save captures document and both history stacks before its first write, reusing
trusted snapshots instead of reconstructing historical payloads.
Every write, including recovery, owns an OS-created exclusive temporary directory
on the destination volume. No transaction shares another transaction's temporary
file. Existing repository overrides of save/saveHistory still participate.

Before a write pair, the runtime captures both existing JSON files (including
absence). If a write or post-await validation fails, it restores those bytes and
verifies both files before admitting another write. Recovery failure reports both
errors/stacks as CadRecoveryFailure, sets recoveryRequired, and blocks subsequent
writes. No automatic reset of recoveryRequired is exposed in this phase: recovery
outside this instance must be verified before constructing/reopening a new runtime.

There is NO manifest or crash recovery protocol. Two JSON files are not atomically
replaced together; interruption, process termination, disk faults during recovery,
or an external writer can leave them inconsistent. Exclusive temporaries prevent
temporary-name collisions, not concurrent writers to the same destination from
other runtime instances/processes. The repository still uses delete + rename.

## Explicitly not migrated

- Manual Apply/alignment and its native creation/persistence before mutate.
- registerImport, upsertEntity/Batch, duplicateCollection and other producers.
- CommandManager's independent command history/piles.
- loadShape, persistShape, native token restoration and kernel unload.
- Mesh/BREP pipeline files, transient operations and direct scene consumers.

Their eventual calls into mutate/save are queued, but the whole producer is NOT
transactional. External direct document publications are detected by transaction
identity validation where possible; this is not isolation from unmigrated writers.
Kernel meshing/restore can still have persistent file/token side effects during
detached projection. Ownership, native rollback, paired crash-atomic persistence,
read-only document exposure, and asynchronous disposal of external producers remain
future phases. Writers outside the migrated boundary may still expose mutable state.

The coordinator is new code written on main; no experimental commits were copied
or cherry-picked. Scene batch installation and repository byte recovery are support
for the migrated documentary entry points, not migration of geometry or application producers.

## Corrective invariants

No-op detection first checks the requested delta against a snapshot privately
marked as normalized: no effective removal/upsert/export change can return before
whole-document normalization or comparison. Unknown/unmigrated documents still
use full normalization and structural comparison (map order is irrelevant),
excluding the command revision list. An unchanged document does not
write files, project, notify, increment revision, or clear redo. A genuine
normalization/export/entity change still commits once.

A transaction records confirmed installation separately from notification delivery.
Notifications check shutdown between boundaries, and runtime-owned notifiers gate
each listener. Listener errors use FlutterError reporting; they do not undo a
confirmed commit or replace the result of a failed transaction.

Tests use controlled producer/storage gates, including two runtime instances with
simultaneously live distinct temporaries. Their final writes are deliberately
sequenced: cross-process final-file arbitration remains outside this phase.

Identity tests retain a document with a 12,000-value payload through small edits,
assert exact reuse of earlier history entries and immutable geometry, exercise
undo/redo, and reject mutations through published references. This removes
historical deep-cloning; serialization of the existing history file still costs
O(serialized history size). Persistent/structural document normalization is not
rewritten in this phase.


## Phase 2A inventory and migration

Inventory below describes the paths before migration. D = document; S = scene;
U = undo/redo; P = persistence. None explicitly changed selection, but scene
notifications could prune IDs before persistence had succeeded.

| Entry | Previous effects | Calls public mutate | Await before mutate |
| --- | --- | --- | --- |
| transitionFeature | D/S/U directly, P via save | no | not applicable |
| setEntityVisibility | S before D/U/P, incomplete rollback | no | not applicable |
| updateCollection, visibility only | D/S/U directly, P via save | no | not applicable |
| updateCollection, rename/lock/activate | reads collection/members before queue; D/S/U/P through mutate | yes | no |
| removeEntity | protection check before queue; D/S/U/P through mutate | yes | no |
| moveToRecycleBin | target/dependency preparation before queue; D/S/U/P through mutate | yes | no |
| restoreFromRecycleBin | target preparation before queue; D/S/U/P through mutate | yes | no |
| permanentlyDelete | validation before public removeEntity | indirectly | no |
| duplicateCollection | logical copying mixed with native transform and BREP persistence | yes | yes, native operations |
| upsertEntity / upsertEntityBatch / registerImport | document preparation mixed with native/import resources | yes | yes, potentially |
| applyEntityTransform / applyAlignmentTransform | native transformation and persistence | yes | yes |
| _ensureProfessionalCollections / sanitization | pure candidate preparation within migrated open | no | no |

No separate createCollection/renameCollection/removeCollection/member APIs existed.
Collection creation and generic entity association use the already queued mutate;
rename uses updateCollection, and removal uses removeEntity. Native-capable upsert
and duplicateCollection remain deliberately unmigrated in their entirety, including
their logical branches, to avoid splitting a resource-producing operation.
External command/Sketch/surface producers are not migrated by this block.

The migrated wrappers now read/validate within their single queue admission and
call _mutateDocument with their existing context, never public mutate/save. The
common helper owns normalization, no-op detection and one document/history commit.
Membership lists passed to updateCollection(addMembers/removeMembers) are captured
at call time, then every member is validated inside the transaction before commit.
A batch can create no partial association. Removing a collection with removeEntity
also detaches its surviving members in the same revision. Generic mutate remains
a low-level document delta API, not a validator for every producer's domain rules.

restoreFromRecycleBin accepts optional additionalIds for one atomic restoration.
Unknown restore targets reject the whole batch. Already-restored targets, repeated
recycling, same lifecycle state, unchanged visibility/collection fields, removal
of absent IDs and purge of an absent ID are idempotent no-ops. Purge of an existing
non-recycled entity still rejects. These explicit no-ops preserve redo and files.
Visibility-only operations preserve lifecycle state/history; actual transitions
retain their lifecycle revision and event rules.

Detached scene preparation reuses the existing display geometry when shape, mesh,
scene kind and geometric definition are unchanged. Metadata and visibility changes
do not invoke tessellation. Effective visibility includes the owning collection;
collection visibility still updates its members' sceneVisible flags. Nothing is
installed until persistence completes. At installation the latest selection is
pruned to existing visible scene entities, including operational owner IDs; visual
flags and selection are reconciled silently before post-commit notifications.
A failed candidate never restores an old selection over a newer user selection.
Restoration does not resurrect old selection. Notifiers still stop after dispose.

permanentlyDelete only commits logical removal. Physical cleanup is deferred,
not attempted or silently assumed successful: undo/redo and other snapshots may
still reference BREP/STL/mesh payloads. No ownership registry or safe physical
reclamation protocol is introduced here. Native resources created by unmigrated
producers and detached native projection still have the phase 1 ownership limits.
The two JSON files still lack crash-atomic joint publication. Global transaction
safety requires the remaining writer migrations.

The additional tests use Completers (no delays), repository failure barriers and
real temporary JSON files. They cover FIFO writers, old-document rejection,
member/dependency/restore atomicity, no-op preservation, selection reconciliation,
physical-payload retention, and a failed transaction's escaped lightweight
capability awaiting real shutdown drainage. A kernel double rejects any unexpected
meshing during documentary display/lifecycle updates.
