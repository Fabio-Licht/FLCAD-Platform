# CAD asset filesystem — ABI v1

Independent Windows foundation; no OpenCascade linkage, ABI changes, Flutter
integration, transaction commits, GC, deletion API or document publication.

**Not fully approved:** the real two-NTFS-volume integration test remains
pending because this machine only has C:. The owner explicitly prohibited
creating/mounting/formatting disks or VHDs. The identity-policy double is a unit
test, not evidence that the two-volume integration test passed. **2B1B remains
blocked** until the Dart gateway integrates this foundation for payloads,
descriptors, journal, locking and recovery, and that integration is validated.

## Platform and threat model

Current backend: Windows x64, local NTFS. UNC, device namespaces, volume-root
projects, unsupported filesystems, reparse components and malformed names fail
closed. Tested on Windows build 26200, MSVC 19.51, SDK 10.0.28000.0, C: NTFS.
Other Windows/filesystem versions require qualification; no POSIX fallback.

The guarantee concerns where **these API operations** create/write/rename.
It is not a sandbox against process injection, administrator/kernel privileges,
malicious filesystem drivers, hardware faults or direct modification of files
by an actor already authorized to modify the project. The helper never promises
an immutable snapshot of all assets or crash-proof document publication.
Flush does not promise survival of all hardware/power failures.

## C contract

`include/cad_asset_fs.h` is compiled by both a C11 and a C++ consumer. All entry
points have C linkage; v1 uses the Windows x64 calling convention. `caf_result`
is 96 bytes (object offset 24, SHA-256 offset 64); compile-time assertions check
layout. Counted UTF-16 strings do not require a terminator. Buffers must be valid
caller memory; this ABI is internal, not an untrusted-process IPC boundary.

`caf_abi_version()` must equal 1 before use. Root/directory/file capabilities are
opaque `uint64_t` IDs in a synchronized registry. IDs are not OS handles or
pointers, are never reused during the DLL lifetime and must never be persisted.
Close removes only that capability. Descendants retain shared ownership of
ancestor handles, including when the public root capability has been closed.
Close every returned nonzero capability, **including on error**. Do not unload
the DLL while using capabilities. Repeated/invalid close returns `CAF_HANDLE`.

Results contain:

- `status`: OK, argument, invalid capability, policy, OS, memory or internal error;
- `win32_error` or raw `nt_status`: the actual failing API's code;
- `effect`: NONE, CREATED, WRITTEN or RENAMED, even if subsequent validation fails;
- `object`: acquired/existing capability, if any;
- `bytes`: actual write count, or actual file size for seal/info;
- `volume`, `file_id`: identity from the live handle;
- `sha256`: meaningful only for a successful seal.

Zero result fields not defined for the operation must not be interpreted as
proof of identity/hash. A successful syscall is never undone implicitly. A
creation followed by identity-query failure returns CREATED and a capability
which can be closed but cannot be used until verified (v1 offers no retry of
that verification). The file is retained. Partial writes report actual bytes.
There is no delete-on-close or rollback-by-deletion path.

## Anchoring and APIs

Root opening accepts an absolute drive path, optionally `\\?\C:\...`, and
performs no filesystem mutation. Only the existing volume bootstrap uses
`CreateFileW(OPEN_EXISTING, BACKUP_SEMANTICS | OPEN_REPARSE_POINT)`. It is not a
pathname-create followed by a check. Each project component is then opened
individually by `NtCreateFile`, relative to the previous live directory handle.

Child operations accept one validated segment, never a path. They reject dot
segments, separators, ADS, controls, malformed UTF-16, trailing dot/space,
reserved DOS device names and overlong components. New objects use FILE_CREATE;
existing objects use FILE_OPEN. No OPEN_IF/OVERWRITE/SUPERSEDE operation exists.
`OBJECT_ATTRIBUTES.RootDirectory`, `OBJ_DONT_REPARSE` and
`FILE_OPEN_REPARSE_POINT` avoid following reparses while resolving the child.
`GetFileInformationByHandleEx(FileAttributeTagInfo/FileIdInfo)` validates type,
tag, volume serial and 128-bit file ID on the returned object.

All ancestors remain pinned without FILE_SHARE_DELETE. Directory handles allow
FILE_SHARE_WRITE because NT rename opens its target directory for writing.
**Share-write is not claimed as a reparse defense.** Real-process tests alter
the directory itself into a junction after the final inspection and before the
create/rename syscall: both reject with STATUS_REPARSE_POINT_NOT_RESOLVED on
the tested system, with identical external inventory. Files deny both write and
delete sharing while the helper holds them. Handle inspection is defense in
depth; mutations use the live parent handles, not a checked pathname.

Writing is append-only in chunks of at most 64 KiB. Read/write/size/flush/hash
all use the same file HANDLE. `caf_seal` flushes created files, compares expected
size and computes SHA-256 in streaming through Windows CNG/BCrypt; further
writes are rejected. Existing files are opened read-only/borrowed: they cannot
be written or renamed. No native exception crosses the C boundary.

Rename uses source HANDLE, destination-directory HANDLE, one validated name
and `ReplaceIfExists=FALSE`. Only capabilities belonging to the same authorized
root and volume may be renamed. Ancestor cycles are rejected. The tested
`SetFileInformationByHandle(FileRenameInfo)` wrapper returned error 87 for the
relative RootDirectory; production therefore uses the WDK-documented user-mode
`NtSetInformationFile`, class 10 (FileRenameInformation). **There is no absolute
pathname fallback.** Native entrypoints are resolved before root acquisition.

`NtCreateFile` and `NtSetInformationFile` are Native APIs documented by Microsoft;
they still carry greater compatibility obligations than ordinary Win32. The
SDK winternl.h recommends Win32 where possible. No syscall numbers are used.
The class-10 structure layout is the Windows x64 FILE_RENAME_INFO layout.

### Directory promotion protocol

NTFS refuses directory rename while payload handles deny delete-sharing.
Do not relax file sharing or reopen writable handles as a workaround:

1. Create and write each payload; seal/hash/flush on its original handle.
2. Retain its volume/file ID, size and hash; close the payload capability.
3. Keep all directory ancestors pinned. Rename the directory by handle.
4. Reopen payloads **relative to the promoted directory handle**, read-only;
   compare volume/file ID, size and hash before treating the asset as verified.

The tests demonstrate refusal with payload handles still open, successful
promotion after closing them, and identity-preserving relative reopening.
The future gateway must treat absent/changed payloads as quarantine. Direct
adversarial modification during closed intervals is not silently accepted and
must not be mistaken for a document transaction guarantee.

## Build and verification

From the repository root, using installed CMake/MSVC only:

```powershell
cmake -S native/cad_asset_fs -B build/cad_asset_fs -G "Visual Studio 18 2026" -A x64
cmake --build build/cad_asset_fs --config Debug
ctest --test-dir build/cad_asset_fs -C Debug --output-on-failure
```

The DLL compiles with `/W4 /WX /permissive- /analyze`. Unit/integration tests
load the real DLL. A separate executable compiles the same implementation with
test-only fault/barrier instrumentation; those hooks are absent from the DLL.
All synthetic faults are checked as errors, with effects and resource counts.

19 CTest cases: known SHA-256, invalid names, static junction and symlink,
real-process ancestor races, exclusive collisions, relative no-replace rename,
sharing violation, denied ACL, invalid capabilities, handle counts, Unicode/
spaces/long paths, threads plus concurrent processes, abrupt process exit at
six operation boundaries, volume-policy doubles, real two-volume integration,
in-place reparse during create and rename, and deterministic faults including
post-create/query failure and partial write.

Current result: **18 passed, 1 pending** (`caf_volume`, skip code 77). When a
second real NTFS volume is supplied, set `CAF_SECOND_VOLUME` to an existing test
directory there and run `ctest ... -R '^caf_volume$' -V`. The test checks distinct
real serials and requires cross-volume refusal without a rename effect. It does
not create, mount or format any volume. Do not count a skip as approval.

Race tests use named-event barriers and a real child process. An unpinned
positive control must successfully move/install a junction; pinned attempts
must return the exact sharing error. In-place tests must actually install the
reparse point and reach the pre-syscall hook. External inventory records every
entry, including empty files/directories and file contents, before/after.
Test timeouts are failure bounds, not synchronization sleeps.

## Audited API references

- [NtCreateFile](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile)
- [OBJECT_ATTRIBUTES / OBJ_DONT_REPARSE](https://learn.microsoft.com/en-us/windows/win32/api/ntdef/ns-ntdef-_object_attributes)
- [FILE_ID_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info)
- [FILE_RENAME_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info)
- [NtSetInformationFile](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntsetinformationfile)
