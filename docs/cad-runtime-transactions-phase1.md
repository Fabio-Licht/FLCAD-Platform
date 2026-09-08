# CadRuntime transaction foundation ? phase 1

This is an incomplete, internal coordinator, not a global transaction guarantee.
The experimental manual transformation changes are not included or enabled.

## Migrated boundary

`mutate`, `undoDocument`, `redoDocument`, `open`, `close`, and `save` share one
private FIFO Future chain. Internal helpers receive the current transaction and
never acquire that chain again. A private revocable capability records owner,
exact transaction ID and active instance. It is revoked in finally on success or
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
- transitionFeature, setEntityVisibility and updateCollection direct writers.
- Recycle-bin wrappers and their pre-mutation validation.
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
for these six entry points, not migration of geometry or application producers.

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
