#include "cad_asset_fs.h"
#include "identity_policy.h"
#include <array>
#include <bcrypt.h>
#include <cstring>
#include <cwctype>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>
#include <windows.h>
#include <winternl.h>
#ifdef CAF_TEST_INSTRUMENTATION
extern void caf_test_checkpoint(const char *);
extern uint32_t caf_test_write_size(uint32_t);
#define CAF_CHECKPOINT(name) caf_test_checkpoint(name)
#else
#define CAF_CHECKPOINT(name) ((void)0)
#endif

namespace {
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  ~Handle() {
    if (value != INVALID_HANDLE_VALUE && value)
      CloseHandle(value);
  }
  Handle() = default;
  Handle(const Handle &) = delete;
  Handle &operator=(const Handle &) = delete;
};
struct Node {
  Handle handle;
  std::mutex io;
  uint32_t source_leases = 0, writer_leases = 0;
  FILE_ID_INFO identity{};
  std::shared_ptr<Node> parent;
  FILE_ID_INFO root{};
  bool directory = false, created = false, sealed = false, verified = false;
  std::array<uint8_t, 32> digest{};
};
std::mutex mutex;
std::unordered_map<uint64_t, std::shared_ptr<Node>> objects;
uint64_t sequence = 0;
struct Failure {
  uint32_t status, win32, nt;
};
[[noreturn]] void fail(uint32_t status, DWORD win32 = 0, ULONG nt = 0) {
  throw Failure{status, win32, nt};
}
void os(bool success) {
  if (!success)
    fail(CAF_OS, GetLastError());
}
using NtCreate = decltype(&NtCreateFile);
NtCreate nt_create() {
  static const auto fn = reinterpret_cast<NtCreate>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtCreateFile"));
  if (!fn)
    fail(CAF_POLICY, ERROR_NOT_SUPPORTED);
  return fn;
}
// WDK-documented user-mode entrypoint; class 10 is FileRenameInformation.
// SetFileInformationByHandle rejected a relative RootDirectory with error 87
// on the tested Windows build. Never fall back to an absolute destination.
using NtSet = NTSTATUS(NTAPI *)(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, ULONG);
NtSet nt_set() {
  static const auto fn = reinterpret_cast<NtSet>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtSetInformationFile"));
  if (!fn)
    fail(CAF_POLICY, ERROR_NOT_SUPPORTED);
  return fn;
}
bool equal(const FILE_ID_INFO &a, const FILE_ID_INFO &b) {
  return caf_policy::same_object(a, b);
}
void inspect(Node &n) {
  FILE_ATTRIBUTE_TAG_INFO tag{};
  os(GetFileInformationByHandleEx(n.handle.value, FileAttributeTagInfo, &tag,
                                  sizeof(tag)) != 0);
  if ((tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      bool(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != n.directory)
    fail(CAF_POLICY);
  FILE_ID_INFO id{};
  os(GetFileInformationByHandleEx(n.handle.value, FileIdInfo, &id,
                                  sizeof(id)) != 0);
  if (n.verified && !equal(id, n.identity))
    fail(CAF_POLICY);
  if (n.parent &&
      id.VolumeSerialNumber != n.parent->identity.VolumeSerialNumber)
    fail(CAF_POLICY, ERROR_NOT_SAME_DEVICE);
  n.identity = id;
  n.verified = true;
}
std::shared_ptr<Node> get(uint64_t id) {
  const auto it = objects.find(id);
  if (it == objects.end() || !it->second->verified)
    fail(CAF_HANDLE, ERROR_INVALID_HANDLE);
  auto n = it->second;
  // Check each pinned ancestor. Opens below use handles, not the names checked.
  for (auto p = n; p; p = p->parent)
    inspect(*p);
  return n;
}
std::wstring text(const uint16_t *s, uint32_t count) {
  if (!s || !count || count > 32760)
    fail(CAF_ARGUMENT);
  std::wstring value(reinterpret_cast<const wchar_t *>(s), count);
  for (size_t i = 0; i < value.size(); ++i) {
    const auto c = static_cast<uint16_t>(value[i]);
    if (c < 32 || c == 127)
      fail(CAF_ARGUMENT);
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (++i == value.size() || value[i] < 0xDC00 || value[i] > 0xDFFF)
        fail(CAF_ARGUMENT);
    } else if (c >= 0xDC00 && c <= 0xDFFF)
      fail(CAF_ARGUMENT);
  }
  return value;
}
void segment(const std::wstring &s) {
  if (s.empty() || s.size() > 255 || s == L"." || s == L".." ||
      s.back() == L'.' || s.back() == L' ' ||
      s.find_first_of(L"\\/:*?\"<>|") != std::wstring::npos)
    fail(CAF_ARGUMENT);
  std::wstring base = s.substr(0, s.find(L'.'));
  for (auto &c : base)
    c = static_cast<wchar_t>(towupper(c));
  if (base == L"CON" || base == L"PRN" || base == L"AUX" || base == L"NUL" ||
      (base.size() == 4 &&
       (base.substr(0, 3) == L"COM" || base.substr(0, 3) == L"LPT") &&
       base[3] >= L'0' && base[3] <= L'9'))
    fail(CAF_ARGUMENT);
}
void open_relative(Node &n, const std::wstring &name, bool create) {
  segment(name);
  UNICODE_STRING str{};
  str.Buffer = const_cast<wchar_t *>(name.data());
  str.Length = static_cast<USHORT>(name.size() * sizeof(wchar_t));
  str.MaximumLength = str.Length;
  OBJECT_ATTRIBUTES attributes{};
  InitializeObjectAttributes(&attributes, &str,
                             OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE,
                             n.parent->handle.value, nullptr);
  IO_STATUS_BLOCK io{};
  HANDLE raw = nullptr;
  const ACCESS_MASK access =
      FILE_READ_ATTRIBUTES | SYNCHRONIZE |
      (n.directory ? FILE_LIST_DIRECTORY : FILE_GENERIC_READ) |
      (create ? (n.created ? DELETE : 0) | (n.directory ? 0 : FILE_WRITE_DATA)
              : 0);
  // No SHARE_DELETE: directory identity cannot be moved out of the pinned tree.
  // Directory share-write is necessary for the target-directory open performed
  // by NT rename. It is NOT a reparse defense; relative opens refuse reparsing.
  const NTSTATUS status = nt_create()(
      &raw, access, &attributes, &io, nullptr, FILE_ATTRIBUTE_NORMAL,
      FILE_SHARE_READ | (n.directory ? FILE_SHARE_WRITE : 0),
      create ? FILE_CREATE : FILE_OPEN,
      FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT |
          (n.directory ? FILE_DIRECTORY_FILE : FILE_NON_DIRECTORY_FILE),
      nullptr, 0);
  if (status < 0)
    fail(CAF_OS, 0, static_cast<ULONG>(status));
  n.handle.value = raw;
}
void fill(caf_result &r, const Node &n) {
  r.volume = n.identity.VolumeSerialNumber;
  std::memcpy(r.file_id, n.identity.FileId.Identifier, 16);
}
template <class F> caf_result boundary(F action) noexcept {
  caf_result r{};
  r.version = 1;
  try {
    std::lock_guard<std::mutex> guard(mutex);
    action(r);
  } catch (const Failure &e) {
    r.status = e.status;
    r.win32_error = e.win32;
    r.nt_status = e.nt;
  } catch (const std::bad_alloc &) {
    r.status = CAF_MEMORY;
  } catch (...) {
    r.status = CAF_INTERNAL;
  }
  return r;
}
uint64_t reserve(const std::shared_ptr<Node> &n) {
  if (sequence == UINT64_MAX)
    fail(CAF_INTERNAL);
  const auto id = ++sequence;
  objects.emplace(id, n); // All registration allocation occurs before mutation.
  return id;
}
caf_result child(uint64_t parent, const uint16_t *name, uint32_t units,
                 bool directory, bool create, bool movable = true) {
  return boundary([&](caf_result &r) {
    auto p = get(parent);
    if (!p->directory)
      fail(CAF_POLICY);
    const auto s = text(name, units);
    segment(s);
    auto n = std::make_shared<Node>();
    n->parent = p;
    n->directory = directory;
    n->created = create && movable;
    n->root = p->root;
    CAF_CHECKPOINT("before_reserve");
    const auto id = reserve(n);
    try {
      CAF_CHECKPOINT("before_create");
      open_relative(*n, s, create);
      r.object = id;
      if (create)
        r.effect = CAF_CREATED;
      CAF_CHECKPOINT("after_create_before_inspect");
      inspect(*n);
      fill(r, *n);
      CAF_CHECKPOINT("after_create");
    } catch (...) {
      if (!r.object)
        objects.erase(id);
      // Post-create IO failure retains the capability for close and reports the
      // real creation. Never delete or claim that mutation was rolled back.
      throw;
    }
  });
}
struct Algorithm {
  BCRYPT_ALG_HANDLE h = nullptr;
  ~Algorithm() {
    if (h)
      BCryptCloseAlgorithmProvider(h, 0);
  }
};
struct Hash {
  BCRYPT_HASH_HANDLE h = nullptr;
  ~Hash() {
    if (h)
      BCryptDestroyHash(h);
  }
};
void crypto(NTSTATUS s) {
  if (s < 0)
    fail(CAF_OS, 0, static_cast<ULONG>(s));
}
} // namespace
extern "C" {
uint32_t caf_abi_version(void) { return 1; }
uint32_t caf_gateway_version(void) { return 1; }
caf_result caf_read(uint64_t id, uint64_t offset, uint8_t *data,
                    uint32_t capacity) {
  return boundary([&](caf_result &r) {
    auto n = get(id);
    if (n->source_leases || n->writer_leases)
      fail(CAF_POLICY, ERROR_BUSY);
    if (n->directory || !data || capacity > 65536 || offset > INT64_MAX)
      fail(CAF_ARGUMENT);
    LARGE_INTEGER position{};
    position.QuadPart = static_cast<LONGLONG>(offset);
    os(SetFilePointerEx(n->handle.value, position, nullptr, FILE_BEGIN) != 0);
    DWORD count = 0;
    os(ReadFile(n->handle.value, data, capacity, &count, nullptr) != 0);
    r.bytes = count;
    fill(r, *n);
  });
}
caf_result caf_lock(uint64_t id) {
  return boundary([&](caf_result &r) {
    auto n = get(id);
    if (n->directory)
      fail(CAF_ARGUMENT);
    OVERLAPPED overlapped{};
    os(LockFileEx(n->handle.value,
                  LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0,
                  &overlapped) != 0);
    r.object = id;
  });
}
caf_result caf_entry(uint64_t id, uint32_t index, uint16_t *name,
                     uint32_t capacity) {
  return boundary([&](caf_result &r) {
    auto n = get(id);
    if (!n->directory || !name || capacity < 256)
      fail(CAF_ARGUMENT);
    std::vector<uint8_t> buffer(65536);
    uint32_t current = 0;
    bool restart = true;
    for (;;) {
      const auto ok = GetFileInformationByHandleEx(
          n->handle.value,
          restart ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo,
          buffer.data(), static_cast<DWORD>(buffer.size()));
      restart = false;
      if (!ok) {
        const auto error = GetLastError();
        if (error == ERROR_NO_MORE_FILES)
          return;
        fail(CAF_OS, error);
      }
      size_t offset = 0;
      for (;;) {
        if (offset + offsetof(FILE_ID_BOTH_DIR_INFO, FileName) > buffer.size())
          fail(CAF_INTERNAL);
        const auto e = reinterpret_cast<const FILE_ID_BOTH_DIR_INFO *>(
            buffer.data() + offset);
        if (e->FileNameLength > 510 ||
            offset + offsetof(FILE_ID_BOTH_DIR_INFO, FileName) +
                    e->FileNameLength >
                buffer.size())
          fail(CAF_POLICY);
        const std::wstring s(e->FileName, e->FileNameLength / sizeof(wchar_t));
        if (s != L"." && s != L".." && current++ == index) {
          segment(s);
          std::memcpy(name, s.data(), e->FileNameLength);
          r.bytes = s.size();
          r.reserved =
              ((e->FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 1U : 0U) |
              ((e->FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ? 2U : 0U);
          return;
        }
        if (!e->NextEntryOffset)
          break;
        offset += e->NextEntryOffset;
      }
    }
  });
}
caf_result caf_open_root(const uint16_t *absolute, uint32_t units) {
  return boundary([&](caf_result &r) {
    nt_create();
    nt_set();
    auto s = text(absolute, units);
    if (s.rfind(L"\\\\?\\", 0) == 0)
      s = s.substr(4);
    if (s.size() < 3 ||
        !((s[0] >= L'A' && s[0] <= L'Z') || (s[0] >= L'a' && s[0] <= L'z')) ||
        s[1] != L':' || s[2] != L'\\')
      fail(CAF_ARGUMENT);
    std::vector<std::wstring> parts;
    for (size_t begin = 3; begin < s.size();) {
      auto end = s.find(L'\\', begin);
      if (end == std::wstring::npos)
        end = s.size();
      auto part = s.substr(begin, end - begin);
      segment(part);
      parts.push_back(part);
      begin = end + 1;
    }
    if (parts.empty())
      fail(CAF_POLICY); // A volume root is never an asset project.
    auto current = std::make_shared<Node>();
    current->directory = true;
    const auto drive = std::wstring(L"\\\\?\\") + s.substr(0, 3);
    current->handle.value = CreateFileW(
        drive.c_str(), FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    os(current->handle.value != INVALID_HANDLE_VALUE);
    inspect(*current);
    wchar_t fs[32]{};
    os(GetVolumeInformationByHandleW(current->handle.value, nullptr, 0, nullptr,
                                     nullptr, nullptr, fs, 32) != 0);
    if (std::wcscmp(fs, L"NTFS") != 0)
      fail(CAF_POLICY, ERROR_NOT_SUPPORTED);
    // Only this existing volume bootstrap uses a pathname; all project
    // components are opened individually relative to live handles before any
    // mutation.
    for (const auto &part : parts) {
      auto next = std::make_shared<Node>();
      next->directory = true;
      next->parent = current;
      open_relative(*next, part, false);
      inspect(*next);
      current = next;
    }
    current->root = current->identity;
    r.object = reserve(current);
    fill(r, *current);
  });
}
caf_result caf_open_dir(uint64_t p, const uint16_t *n, uint32_t u) {
  return child(p, n, u, true, false);
}
caf_result caf_create_dir(uint64_t p, const uint16_t *n, uint32_t u) {
  return child(p, n, u, true, true);
}
caf_result caf_create_pinned_dir(uint64_t p, const uint16_t *n, uint32_t u) {
  return child(p, n, u, true, true, false);
}
caf_result caf_open_file(uint64_t p, const uint16_t *n, uint32_t u) {
  return child(p, n, u, false, false);
}
caf_result caf_create_file(uint64_t p, const uint16_t *n, uint32_t u) {
  return child(p, n, u, false, true);
}
caf_result caf_write(uint64_t id, const uint8_t *data, uint32_t bytes) {
  return boundary([&](caf_result &r) {
    auto n = get(id);
    r.object = id;
    if (n->source_leases || n->writer_leases)
      fail(CAF_POLICY, ERROR_BUSY);
    if (n->directory || !n->created || n->sealed || (!data && bytes) ||
        bytes > 65536)
      fail(CAF_ARGUMENT);
    CAF_CHECKPOINT("before_write");
    LARGE_INTEGER end{};
    os(SetFilePointerEx(n->handle.value, end, nullptr, FILE_END) != 0);
    DWORD written = 0;
    DWORD requested = bytes;
#ifdef CAF_TEST_INSTRUMENTATION
    requested = caf_test_write_size(bytes);
#endif
    const auto ok =
        WriteFile(n->handle.value, data, requested, &written, nullptr);
    const auto error = ok ? 0 : GetLastError();
    r.bytes = written;
    if (written)
      r.effect = CAF_WRITTEN;
    if (!ok)
      fail(CAF_OS, error);
    if (written != bytes)
      fail(CAF_OS, ERROR_WRITE_FAULT);
    CAF_CHECKPOINT("after_write");
  });
}
caf_result caf_seal(uint64_t id, uint64_t expected) {
  return boundary([&](caf_result &r) {
    auto n = get(id);
    r.object = id;
    if (n->directory)
      fail(CAF_ARGUMENT);
    if (n->source_leases || n->writer_leases)
      fail(CAF_POLICY, ERROR_BUSY);
    CAF_CHECKPOINT("before_seal");
    if (n->created)
      os(FlushFileBuffers(n->handle.value) != 0);
    LARGE_INTEGER size{};
    os(GetFileSizeEx(n->handle.value, &size) != 0);
    r.bytes = static_cast<uint64_t>(size.QuadPart);
    if (r.bytes != expected)
      fail(CAF_POLICY, ERROR_FILE_INVALID);
    Algorithm a;
    crypto(
        BCryptOpenAlgorithmProvider(&a.h, BCRYPT_SHA256_ALGORITHM, nullptr, 0));
    DWORD length = 0, used = 0;
    crypto(BCryptGetProperty(a.h, BCRYPT_OBJECT_LENGTH,
                             reinterpret_cast<PUCHAR>(&length), sizeof(length),
                             &used, 0));
    std::vector<uint8_t> storage(length);
    Hash hash;
    crypto(
        BCryptCreateHash(a.h, &hash.h, storage.data(), length, nullptr, 0, 0));
    LARGE_INTEGER zero{};
    os(SetFilePointerEx(n->handle.value, zero, nullptr, FILE_BEGIN) != 0);
    std::vector<uint8_t> buffer(65536);
    uint64_t total = 0;
    while (true) {
      DWORD read = 0;
      os(ReadFile(n->handle.value, buffer.data(),
                  static_cast<DWORD>(buffer.size()), &read, nullptr) != 0);
      if (!read)
        break;
      total += read;
      crypto(BCryptHashData(hash.h, buffer.data(), read, 0));
    }
    if (total != expected)
      fail(CAF_POLICY, ERROR_FILE_INVALID);
    crypto(BCryptFinishHash(hash.h, r.sha256, 32, 0));
    std::memcpy(n->digest.data(), r.sha256, 32);
    n->sealed = true;
    fill(r, *n);
    if (n->sealed)
      std::memcpy(r.sha256, n->digest.data(), 32);
    CAF_CHECKPOINT("after_seal");
  });
}
caf_result caf_info(uint64_t id) {
  return boundary([&](caf_result &r) {
    auto n = get(id);
    r.object = id;
    fill(r, *n);
    if (!n->directory) {
      LARGE_INTEGER size{};
      os(GetFileSizeEx(n->handle.value, &size) != 0);
      r.bytes = static_cast<uint64_t>(size.QuadPart);
      if (n->sealed)
        std::memcpy(r.sha256, n->digest.data(), 32);
    }
  });
}
caf_result caf_rename(uint64_t id, uint64_t dest, const uint16_t *name,
                      uint32_t units) {
  return boundary([&](caf_result &r) {
    auto n = get(id), d = get(dest);
    r.object = id;
    if (n->source_leases || n->writer_leases)
      fail(CAF_POLICY, ERROR_BUSY);
    if (!n->created || !d->directory || (!n->directory && !n->sealed))
      fail(CAF_POLICY);
    if (!caf_policy::same_volume(n->identity, d->identity))
      fail(CAF_POLICY, ERROR_NOT_SAME_DEVICE);
    if (!equal(n->root, d->root))
      fail(CAF_POLICY, ERROR_ACCESS_DENIED);
    for (auto a = d; a; a = a->parent)
      if (a == n)
        fail(CAF_POLICY);
    const auto s = text(name, units);
    segment(s);
    const size_t length =
        offsetof(FILE_RENAME_INFO, FileName) + s.size() * sizeof(wchar_t);
    std::vector<uint8_t> buffer(length);
    auto info = reinterpret_cast<FILE_RENAME_INFO *>(buffer.data());
    info->ReplaceIfExists = FALSE;
    info->RootDirectory = d->handle.value;
    info->FileNameLength = static_cast<DWORD>(s.size() * sizeof(wchar_t));
    std::memcpy(info->FileName, s.data(), info->FileNameLength);
    CAF_CHECKPOINT("before_rename");
    IO_STATUS_BLOCK io{};
    const auto status =
        nt_set()(n->handle.value, &io, info, static_cast<ULONG>(length), 10);
    if (status < 0)
      fail(CAF_OS, 0, static_cast<ULONG>(status));
    r.effect = CAF_RENAMED;
    n->parent = d;
    fill(r, *n); // No fallible operation after successful rename.
    CAF_CHECKPOINT("after_rename");
  });
}
caf_result caf_close(uint64_t id) {
  return boundary([&](caf_result &) {
    const auto it = objects.find(id);
    if (it != objects.end() &&
        (it->second->source_leases || it->second->writer_leases))
      fail(CAF_POLICY, ERROR_BUSY);
    if (!objects.erase(id))
      fail(CAF_HANDLE, ERROR_INVALID_HANDLE);
  });
}
}

#include "cad_asset_source.inc"
