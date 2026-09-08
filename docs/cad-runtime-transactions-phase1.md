# CadRuntime transaction foundation ? phase 1

This is an incomplete, internal coordinator, not a global transaction guarantee.
The experimental manual transformation changes are not included or enabled.

## Migrated boundary

`mutate`, `undoDocument`, `redoDocument`, `open`, `close`, and `save` share one
private FIFO Future chain. Internal helpers receive the current transaction and
never acquire that chain again. A transaction Zone rejects accidental public
reacquisition; listeners run outside that Zone after synchronous installation
and may enqueue new work. Queue errors do not poison subsequent entries.

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

`shutdown()` closes admission and revokes lifecycle immediately. It returns the
same Future on repeated calls, drains admitted work (obsolete queued entries are
rejected), then disposes child dependencies. Synchronous `dispose()` delegates to
it and detaches runtime listeners immediately. Callers needing confirmed resource
shutdown must await `shutdown()` before unloading external kernel dependencies.

## Persistence and recovery limits

Save freezes document and both history stacks together before the first write.
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
future phases. Existing mutable nested document data is not made globally immutable.

The coordinator is new code written on main; no experimental commits were copied
or cherry-picked. Scene batch installation and repository byte recovery are support
for these six entry points, not migration of geometry or application producers.
