#include "../src/identity_policy.h"
#include "cad_asset_fs.h"
#include <aclapi.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <bcrypt.h>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <sddl.h>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <windows.h>
#include <winioctl.h>
#ifdef CAF_TEST_INSTRUMENTATION
std::function<void(const char *)> checkpoint;
bool shortWrite = false;
uint32_t caf_test_write_size(uint32_t bytes) {
  return shortWrite && bytes > 1 ? 1 : bytes;
}
void caf_test_checkpoint(const char *name) {
  if (checkpoint)
    checkpoint(name);
}
#endif
namespace fs = std::filesystem;
extern "C" int caf_c_header_test(void);
void check(bool value, const char *why) {
  if (!value)
    throw std::runtime_error(why);
}
void good(caf_result r) {
  if (r.status) {
    std::cerr << "status=" << r.status << " win=" << r.win32_error
              << " nt=" << std::hex << r.nt_status << std::dec
              << " effect=" << r.effect << "\n";
    throw std::runtime_error("unexpected ABI failure");
  }
}
const uint16_t *u(const std::wstring &s) {
  return reinterpret_cast<const uint16_t *>(s.data());
}
uint32_t count(const std::wstring &s) {
  return static_cast<uint32_t>(s.size());
}
struct H {
  HANDLE h = nullptr;
  ~H() {
    if (h && h != INVALID_HANDLE_VALUE)
      CloseHandle(h);
  }
  H() = default;
  H(const H &) = delete;
  H &operator=(const H &) = delete;
};
struct Object {
  uint64_t id = 0;
  explicit Object(caf_result r) {
    good(r);
    id = r.object;
  }
  ~Object() {
    if (id)
      caf_close(id);
  }
  Object(const Object &) = delete;
  Object &operator=(const Object &) = delete;
  void close() {
    good(caf_close(id));
    id = 0;
  }
};
caf_result root(const fs::path &p) {
  auto s = p.wstring();
  return caf_open_root(u(s), count(s));
}
caf_result dir(uint64_t p, const std::wstring &s, bool create = true) {
  return create ? caf_create_dir(p, u(s), count(s))
                : caf_open_dir(p, u(s), count(s));
}
caf_result file(uint64_t p, const std::wstring &s) {
  return caf_create_file(p, u(s), count(s));
}
caf_result rename(uint64_t p, uint64_t d, const std::wstring &s) {
  return caf_rename(p, d, u(s), count(s));
}
std::wstring executable() {
  std::wstring s(32768, 0);
  auto n = GetModuleFileNameW(nullptr, s.data(), static_cast<DWORD>(s.size()));
  check(n > 0 && n < s.size(), "exe path");
  s.resize(n);
  return s;
}
struct Fixture {
  fs::path base, project, outside;
  Fixture() {
    wchar_t temp[32768]{};
    check(GetTempPathW(32768, temp) > 0, "temp");
    std::array<uint64_t, 2> nonce{};
    check(BCryptGenRandom(nullptr, reinterpret_cast<PUCHAR>(nonce.data()),
                          sizeof(nonce), BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0,
          "fixture nonce");
    base = fs::path(temp) /
           (L"caf-test-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
            std::to_wstring(nonce[0]) + L"-" + std::to_wstring(nonce[1]));
    check(!fs::exists(base), "exclusive fixture");
    check(fs::create_directory(base), "fixture created exclusively");
    project = base / L"project";
    outside = base / L"outside";
    fs::create_directory(project);
    fs::create_directory(outside);
    std::ofstream(outside / L"sentinel", std::ios::binary) << "untouched";
  }
  ~Fixture() {
    std::error_code ec;
    fs::remove_all(base, ec);
  }
};
using Inventory = std::map<std::wstring, std::string>;
Inventory inventory(const fs::path &p) {
  Inventory result;
  for (const auto &e : fs::recursive_directory_iterator(p)) {
    const auto key = fs::relative(e.path(), p).wstring();
    if (e.is_directory())
      result[key] = "<dir>";
    else {
      std::ifstream f(e.path(), std::ios::binary);
      result[key] = std::string(std::istreambuf_iterator<char>(f), {});
    }
  }
  return result;
}
void junction(const fs::path &link, const fs::path &target) {
  fs::create_directory(link);
  H h;
  h.h = CreateFileW(link.c_str(), GENERIC_WRITE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    nullptr, OPEN_EXISTING,
                    FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
                    nullptr);
  check(h.h != INVALID_HANDLE_VALUE, "junction open");
  const auto substitute = L"\\??\\" + target.wstring(),
             print = target.wstring();
  const size_t subBytes = substitute.size() * 2, printBytes = print.size() * 2;
  std::vector<uint8_t> data(16 + subBytes + 2 + printBytes + 2);
  const DWORD tag = IO_REPARSE_TAG_MOUNT_POINT;
  std::memcpy(data.data(), &tag, 4);
  const WORD length = static_cast<WORD>(data.size() - 8),
             subLength = static_cast<WORD>(subBytes),
             printOffset = static_cast<WORD>(subBytes + 2),
             printLength = static_cast<WORD>(printBytes);
  std::memcpy(data.data() + 4, &length, 2);
  std::memcpy(data.data() + 10, &subLength, 2);
  std::memcpy(data.data() + 12, &printOffset, 2);
  std::memcpy(data.data() + 14, &printLength, 2);
  std::memcpy(data.data() + 16, substitute.data(), subBytes);
  std::memcpy(data.data() + 16 + subBytes + 2, print.data(), printBytes);
  DWORD used = 0;
  check(DeviceIoControl(h.h, FSCTL_SET_REPARSE_POINT, data.data(),
                        static_cast<DWORD>(data.size()), nullptr, 0, &used,
                        nullptr) != 0,
        "set junction");
}
std::wstring quote(const std::wstring &s) {
  check(s.find(L'"') == std::wstring::npos, "quote");
  return L"\"" + s + L"\"";
}
// Instrumentation/barriers live only in this executable; the DLL has no hooks.
struct Attacker {
  H ready, go, process;
  std::wstring readyName, goName;
  Attacker(const fs::path &victim, const fs::path &outside,
           const std::wstring &mode) {
    static unsigned seq = 0;
    auto key = L"Local\\caf-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
               std::to_wstring(++seq);
    readyName = key + L"-ready";
    goName = key + L"-go";
    ready.h = CreateEventW(nullptr, TRUE, FALSE, readyName.c_str());
    go.h = CreateEventW(nullptr, TRUE, FALSE, goName.c_str());
    check(ready.h && go.h, "events");
    auto cmd = quote(executable()) + L" child " + quote(victim.wstring()) +
               L" " + quote(outside.wstring()) + L" " + quote(readyName) +
               L" " + quote(goName) + L" " + mode;
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    check(CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE,
                         CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi) != 0,
          "child start");
    process.h = pi.hProcess;
    CloseHandle(pi.hThread);
    check(WaitForSingleObject(ready.h, 10000) == WAIT_OBJECT_0, "child ready");
  }
  DWORD run() {
    check(SetEvent(go.h) != 0, "go");
    check(WaitForSingleObject(process.h, 10000) == WAIT_OBJECT_0,
          "child exited");
    DWORD code = 0;
    check(GetExitCodeProcess(process.h, &code) != 0, "child code");
    return code;
  }
  ~Attacker() {
    if (process.h && WaitForSingleObject(process.h, 0) == WAIT_TIMEOUT) {
      TerminateProcess(process.h, 99);
      WaitForSingleObject(process.h, 10000);
    }
  }
};
int child(int argc, wchar_t **argv) {
  check(argc == 7, "child arguments");
  H ready, go;
  ready.h = OpenEventW(EVENT_MODIFY_STATE, FALSE, argv[4]);
  go.h = OpenEventW(SYNCHRONIZE, FALSE, argv[5]);
  check(ready.h && go.h, "child events");
  SetEvent(ready.h);
  check(WaitForSingleObject(go.h, 10000) == WAIT_OBJECT_0, "child barrier");
  fs::path victim = argv[2], backup = victim.wstring() + L"-moved";
  const std::wstring mode = argv[6];
  if (mode.rfind(L"crash", 0) == 0 || mode == L"writer") {
    const int phase = mode == L"writer" ? 6 : std::stoi(mode.substr(5));
    Object r(root(victim));
    if (phase == 0)
      ExitProcess(100);
    Object d(dir(r.id, L"child-" + std::to_wstring(GetCurrentProcessId())));
    if (phase == 1)
      ExitProcess(101);
    Object a(file(d.id, L"payload"));
    if (phase == 2)
      ExitProcess(102);
    const uint8_t value = 42;
    good(caf_write(a.id, &value, 1));
    if (phase == 3)
      ExitProcess(103);
    good(caf_seal(a.id, 1));
    if (phase == 4)
      ExitProcess(104);
    good(rename(a.id, d.id, L"sealed"));
    if (phase == 5)
      ExitProcess(105);
    return 0;
  }
  if (std::wstring(argv[6]) == L"reparse") {
    junction(victim, argv[3]);
    return 0;
  }
  if (!MoveFileExW(victim.c_str(), backup.c_str(), 0))
    return static_cast<int>(GetLastError());
  if (std::wstring(argv[6]) == L"swap")
    junction(victim, argv[3]);
  return 0;
}
void basic() {
  Fixture f;
  Object r(root(f.project)), d(dir(r.id, L"stage")),
      a(file(d.id, L"shape.brep"));
  const uint8_t bytes[] = {'a', 'b', 'c'};
  auto w = caf_write(a.id, bytes, 3);
  good(w);
  check(w.effect == CAF_WRITTEN && w.bytes == 3, "write result");
  auto result = caf_seal(a.id, 3);
  good(result);
  const uint8_t expected[] = {0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
                              0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
                              0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
                              0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad};
  check(std::memcmp(result.sha256, expected, 32) == 0, "known SHA256");
  check(caf_write(a.id, bytes, 3).status == CAF_ARGUMENT, "sealed immutable");
  check(result.volume != 0, "identity volume");
}
void names() {
  Fixture f;
  Object r(root(f.project));
  const auto before = inventory(f.outside);
  for (const auto &name :
       {L".", L"..", L"a/b", L"a\\b", L"C:evil", L"/absolute", L"x:ads", L"nul",
        L"a.", L"a ", L"a\n"}) {
    auto s = std::wstring(name);
    auto x = file(r.id, s);
    check(x.status == CAF_ARGUMENT && x.effect == CAF_NONE, "bad segment");
  }
  check(caf_create_file(r.id, nullptr, 0).status == CAF_ARGUMENT, "null");
  check(root(L"\\\\server\\share").status == CAF_ARGUMENT, "UNC");
  check(root(L"\\\\.\\C:\\").status == CAF_ARGUMENT, "namespace");
  check(inventory(f.outside) == before, "outside");
}
void static_junction() {
  Fixture f;
  const auto before = inventory(f.outside);
  junction(f.project / L"link", f.outside);
  auto result = root(f.project / L"link");
  check(result.status != CAF_OK && result.effect == CAF_NONE && !result.object,
        "static root rejected");
  Object r(root(f.project));
  result = dir(r.id, L"link", false);
  check(result.status != CAF_OK && result.effect == CAF_NONE,
        "static child rejected");
  check(inventory(f.outside) == before, "no outside entries including empty");
}
void races() {
  Fixture f;
  const auto before = inventory(f.outside);
  // Positive control: helper process can move and install a junction when
  // unpinned.
  fs::create_directory(f.project / L"unpinned");
  {
    Attacker a(f.project / L"unpinned", f.outside, L"swap");
    check(a.run() == 0, "attack positive control");
  }
  {
    Object r(root(f.project));
    auto x = dir(r.id, L"unpinned", false);
    check(x.status != CAF_OK && x.effect == CAF_NONE,
          "swap before open rejected");
  }
  for (int i = 0; i < 12; ++i) {
    auto name = L"ancestor" + std::to_wstring(i);
    fs::create_directory(f.project / name);
    Object r(root(f.project)), p(dir(r.id, name, false));
    Attacker a(f.project / name, f.outside, L"swap");
    check(a.run() == ERROR_SHARING_VIOLATION, "pinned ancestor must deny move");
    Object output(file(p.id, L"empty-or-data"));
    check(caf_info(output.id).bytes == 0, "new file in authorized dir");
  }
  // Project root itself remains pinned after its public ID closes: child
  // retains it.
  {
    Object r(root(f.project)), p(dir(r.id, L"retained"));
    r.close();
    Attacker a(f.project, f.outside, L"move");
    check(a.run() == ERROR_SHARING_VIOLATION, "root lifetime");
    Object output(file(p.id, L"inside"));
  }
  check(inventory(f.outside) == before, "race outside inventory identical");
}
void collision() {
  Fixture f;
  Object r(root(f.project)), d(dir(r.id, L"empty"));
  auto x = dir(r.id, L"empty");
  check(x.status != CAF_OK && x.effect == CAF_NONE, "exclusive directory");
  Object a(file(r.id, L"asset"));
  x = file(r.id, L"asset");
  check(x.status != CAF_OK && x.effect == CAF_NONE, "exclusive file");
  check(fs::is_empty(f.project / L"empty"), "empty remains empty");
}
void rename_test() {
  Fixture f;
  Object r(root(f.project)), a(dir(r.id, L"stage")), dest(dir(r.id, L"assets")),
      existing(dir(dest.id, L"collision"));
  Object brep(file(a.id, L"shape.brep")), stl(file(a.id, L"display.stl"));
  const uint8_t payload[] = {1, 2, 3};
  good(caf_write(brep.id, payload, 3));
  good(caf_write(stl.id, payload, 3));
  good(caf_seal(brep.id, 3));
  good(caf_seal(stl.id, 3));
  auto x = rename(a.id, dest.id, L"collision");
  check(x.status != CAF_OK && x.effect == CAF_NONE, "rename collision");
  check(fs::is_empty(f.project / L"assets" / L"collision"),
        "empty target retained");
  x = rename(a.id, dest.id, L"new");
  check(x.status == CAF_OS && x.nt_status == 0xC0000022u &&
            x.effect == CAF_NONE,
        "NTFS refuses pinned children; no unsafe share-delete fallback");
  const auto original = caf_seal(brep.id, 3);
  good(original);
  brep.close();
  stl.close();
  x = rename(a.id, dest.id, L"new");
  good(x);
  check(x.effect == CAF_RENAMED, "rename fact");
  check(!fs::exists(f.project / L"stage") &&
            fs::exists(f.project / L"assets" / L"new"),
        "actual rename");
  const std::wstring payloadName = L"shape.brep";
  Object reopened(caf_open_file(a.id, u(payloadName), count(payloadName)));
  auto confirmed = caf_seal(reopened.id, 3);
  good(confirmed);
  check(confirmed.volume == original.volume &&
            std::memcmp(confirmed.file_id, original.file_id, 16) == 0,
        "relative reopen same file identity");
  check(std::memcmp(confirmed.sha256, original.sha256, 32) == 0,
        "relative reopen same SHA256");
  check(caf_write(reopened.id, payload, 3).status == CAF_ARGUMENT,
        "borrowed readonly");
  check(rename(reopened.id, dest.id, L"borrowed").status == CAF_POLICY,
        "borrowed cannot rename");
  Object b(file(a.id, L"data"));
  good(caf_seal(b.id, 0));
  x = rename(b.id, dest.id, L"data.ply");
  good(x);
  check(x.effect == CAF_RENAMED, "file rename");
}
void sharing() {
  Fixture f;
  fs::create_directory(f.project / L"held");
  H h;
  h.h =
      CreateFileW((f.project / L"held").c_str(), DELETE,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  check(h.h != INVALID_HANDLE_VALUE, "external deletion handle");
  Object r(root(f.project));
  auto x = dir(r.id, L"held", false);
  check(x.status == CAF_OS && x.nt_status == 0xC0000043u &&
            x.effect == CAF_NONE,
        "sharing violation");
}
void denied() {
  Fixture f;
  auto path = f.project / L"denied";
  fs::create_directory(path);
  PSECURITY_DESCRIPTOR raw = nullptr;
  check(ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(D;;FA;;;WD)", SDDL_REVISION_1, &raw, nullptr) != 0,
        "SDDL");
  struct Local {
    PSECURITY_DESCRIPTOR p;
    ~Local() { LocalFree(p); }
  } sd{raw};
  check(SetFileSecurityW(path.c_str(),
                         DACL_SECURITY_INFORMATION |
                             PROTECTED_DACL_SECURITY_INFORMATION,
                         sd.p) != 0,
        "deny ACL");
  const auto x = root(path);
  // Restore only the private test directory, even when the assertion below
  // fails.
  check(SetNamedSecurityInfoW(
            const_cast<wchar_t *>(path.c_str()), SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | UNPROTECTED_DACL_SECURITY_INFORMATION,
            nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS,
        "restore ACL");
  check(x.status == CAF_OS && x.nt_status == 0xC0000022u &&
            x.effect == CAF_NONE,
        "access denied");
}
void invalid() {
  check(caf_info(0).status == CAF_HANDLE, "null ID");
  check(caf_close(UINT64_MAX).status == CAF_HANDLE, "invalid ID");
  Fixture f;
  Object r(root(f.project));
  auto id = r.id;
  r.close();
  check(caf_info(id).status == CAF_HANDLE, "closed ID");
  Object q(root(f.project));
  check(q.id != id, "ID never reused");
}
void leaks() {
  Fixture f;
  Object r(root(f.project));
  Object warm(file(r.id, L"warm"));
  good(caf_seal(warm.id, 0));
  warm.close();
  DWORD before = 0, after = 0;
  check(GetProcessHandleCount(GetCurrentProcess(), &before) != 0,
        "initial handle count");
  for (int i = 0; i < 100; ++i) {
    check(dir(r.id, L"absent", false).status != CAF_OK, "missing open");
    check(file(0, L"bad").status == CAF_HANDLE, "failed ID");
    Object a(file(r.id, L"f" + std::to_wstring(i)));
    check(caf_seal(a.id, 1).status == CAF_POLICY, "size failure");
    check(rename(a.id, r.id, L"no").status == CAF_POLICY, "unsealed rename");
  }
  check(GetProcessHandleCount(GetCurrentProcess(), &after) != 0,
        "final handle count");
  check(before == after, "OS handle count unchanged");
}
void unicode() {
  Fixture f;
  Object r(root(f.project));
  std::vector<std::unique_ptr<Object>> chain;
  uint64_t parent = r.id;
  auto fullPath = f.project;
  for (int i = 0; i < 8; ++i) {
    auto s = L"diretório com espaços 日本語 " + std::to_wstring(i) +
             std::wstring(40, L'x');
    auto next = std::make_unique<Object>(dir(parent, s));
    fullPath /= s;
    parent = next->id;
    chain.push_back(std::move(next));
  }
  Object a(file(parent, L"peça 日本語.ply"));
  good(caf_seal(a.id, 0));
  check(caf_info(a.id).bytes == 0, "long Unicode file");
  const auto original = caf_info(a.id);
  good(original);
  a.close();
  chain.clear();
  check(fullPath.wstring().size() > 260, "root path actually exceeds MAX_PATH");
  Object longRoot(root(fs::path(L"\\\\?\\" + fullPath.wstring())));
  const std::wstring leaf = L"peça 日本語.ply";
  Object reopened(caf_open_file(longRoot.id, u(leaf), count(leaf)));
  const auto identity = caf_info(reopened.id);
  good(identity);
  check(identity.volume == original.volume &&
            std::memcmp(identity.file_id, original.file_id, 16) == 0,
        "long UTF16 root reopened correctly");
}
void concurrency() {
  Fixture f;
  Object r(root(f.project));
  auto before = inventory(f.outside);
  std::atomic<int> failures{0};
  std::vector<std::thread> threads;
  for (int t = 0; t < 8; ++t)
    threads.emplace_back([&, t] {
      try {
        Object d(dir(r.id, L"op" + std::to_wstring(t)));
        for (int i = 0; i < 12; ++i) {
          Object a(file(d.id, L"f" + std::to_wstring(i)));
          const uint8_t b = 42;
          good(caf_write(a.id, &b, 1));
          good(caf_seal(a.id, 1));
        }
      } catch (...) {
        ++failures;
      }
    });
  for (auto &t : threads)
    t.join();
  check(failures == 0, "concurrent operations");
  std::vector<std::unique_ptr<Attacker>> workers;
  for (int i = 0; i < 4; ++i)
    workers.push_back(
        std::make_unique<Attacker>(f.project, f.outside, L"writer"));
  for (auto &worker : workers)
    check(SetEvent(worker->go.h) != 0, "parallel worker release");
  for (auto &worker : workers)
    check(worker->run() == 0, "real concurrent writer process");
  check(inventory(f.outside) == before, "parallel confinement");
}
void termination() {
  Fixture f;
  const auto before = inventory(f.outside);
  for (int phase = 0; phase < 6; ++phase) {
    Attacker childProcess(f.project, f.outside,
                          L"crash" + std::to_wstring(phase));
    check(childProcess.run() == DWORD(100 + phase),
          "child exited exactly at requested phase");
    Object r(root(f.project));
    Object probe(file(r.id, L"probe" + std::to_wstring(phase)));
    good(caf_seal(probe.id, 0));
    // A DELETE open would fail if an exited child's deny-delete handle
    // survived.
    H probeHandle;
    probeHandle.h = CreateFileW(
        f.project.c_str(), DELETE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    check(probeHandle.h == INVALID_HANDLE_VALUE &&
              GetLastError() == ERROR_SHARING_VIOLATION,
          "our own live root still pins identity");
    probe.close();
    r.close();
    probeHandle.h = CreateFileW(
        f.project.c_str(), DELETE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    check(probeHandle.h != INVALID_HANDLE_VALUE,
          "OS released crashed process handles");
  }
  check(inventory(f.outside) == before, "termination retained confinement");
}
int symlink_test() {
  Fixture f;
  const auto before = inventory(f.outside);
  const auto link = f.project / L"symlink";
  if (!CreateSymbolicLinkW(link.c_str(), f.outside.c_str(),
                           SYMBOLIC_LINK_FLAG_DIRECTORY |
                               SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) {
    const auto error = GetLastError();
    if (error == ERROR_PRIVILEGE_NOT_HELD) {
      std::cout << "PENDING: symlink privilege unavailable\n";
      return 77;
    }
    throw std::runtime_error("symlink fixture failed");
  }
  auto result = root(link);
  check(result.status != CAF_OK && result.effect == CAF_NONE,
        "symlink root rejected");
  Object r(root(f.project));
  result = dir(r.id, L"symlink", false);
  check(result.status != CAF_OK && result.effect == CAF_NONE,
        "symlink child rejected");
  check(inventory(f.outside) == before, "symlink outside unchanged");
  return 0;
}
void volume() {
  Fixture f;
  Object r(root(f.project)), a(file(r.id, L"a"));
  good(caf_seal(a.id, 0));
  fs::create_directory(f.base / L"other-root");
  Object other(root(f.base / L"other-root"));
  auto x = rename(a.id, other.id, L"a");
  check(x.status == CAF_POLICY && x.effect == CAF_NONE, "cross root denied");
  // A second real NTFS volume is required for this mandatory test, not
  // simulated.
  wchar_t env[32768]{};
  auto n = GetEnvironmentVariableW(L"CAF_SECOND_VOLUME", env, 32768);
  check(n > 0 && n < 32768,
        "CAF_SECOND_VOLUME must name a test directory on another NTFS volume");
  Object second(root(env));
  check(caf_info(second.id).volume != caf_info(r.id).volume,
        "distinct volume serials");
  x = rename(a.id, second.id, L"cross-volume-forbidden");
  check(x.status == CAF_POLICY && x.win32_error == ERROR_NOT_SAME_DEVICE &&
            x.effect == CAF_NONE,
        "cross volume refused");
}
void volume_policy() {
  FILE_ID_INFO a{}, b{};
  a.VolumeSerialNumber = 1;
  b.VolumeSerialNumber = 2;
  check(!caf_policy::same_volume(a, b) && !caf_policy::same_object(a, b),
        "controlled distinct volume double");
  b.VolumeSerialNumber = 1;
  b.FileId.Identifier[0] = 1;
  check(caf_policy::same_volume(a, b) && !caf_policy::same_object(a, b),
        "same volume distinct file");
  a = b;
  check(caf_policy::same_object(a, b), "same identity");
  std::cout << "DOUBLES ONLY; not a two-volume integration proof\n";
}
#ifdef CAF_TEST_INSTRUMENTATION
void inplace(bool renaming) {
  Fixture f;
  auto before = inventory(f.outside);
  fs::create_directory(f.project / L"target");
  Object r(root(f.project)), d(dir(r.id, L"target", false)),
      a(file(r.id, L"source"));
  good(caf_seal(a.id, 0));
  bool attacked = false;
  Attacker attacker(f.project / L"target", f.outside, L"reparse");
  checkpoint = [&](const char *name) {
    if (std::string(name) == (renaming ? "before_rename" : "before_create")) {
      check(attacker.run() == 0, "inplace attacker actually sets reparse");
      attacked = true;
    }
  };
  auto result =
      renaming ? rename(a.id, d.id, L"escaped") : file(d.id, L"escaped");
  checkpoint = {};
  std::cerr << "inplace result status=" << result.status
            << " effect=" << result.effect << " nt=" << std::hex
            << result.nt_status << std::dec << "\n";
  if (result.object && result.object != a.id)
    caf_close(result.object);
  check(attacked, "inplace barrier reached");
  check(inventory(f.outside) == before, "inplace outside inventory unchanged");
  check(result.status == CAF_OS && result.nt_status == 0xC0000280u &&
            result.effect == CAF_NONE,
        "reparse must reject before any mutation");
}
void faults() {
  Fixture f;
  Object r(root(f.project));
  Object warm(file(r.id, L"warm"));
  good(caf_seal(warm.id, 0));
  warm.close();
  for (const std::string phase :
       {"before_reserve", "before_create", "after_create_before_inspect",
        "after_create", "before_write", "after_write", "before_seal",
        "after_seal", "before_rename", "after_rename"}) {
    DWORD before = 0, after = 0;
    check(GetProcessHandleCount(GetCurrentProcess(), &before) != 0,
          "initial fault handle count");
    {
      Object d(dir(r.id, std::wstring(phase.begin(), phase.end())));
      std::unique_ptr<Object> a;
      const bool creating = phase.find("create") != std::string::npos ||
                            phase == "before_reserve";
      if (!creating) {
        a = std::make_unique<Object>(file(d.id, L"source"));
        if (phase.find("rename") != std::string::npos)
          good(caf_seal(a->id, 0));
      }
      bool hit = false;
      checkpoint = [&](const char *name) {
        if (phase == name) {
          hit = true;
          throw std::runtime_error("injected");
        }
      };
      caf_result result{};
      if (creating)
        result = file(d.id, L"source");
      else if (phase.find("write") != std::string::npos) {
        const uint8_t x = 7;
        result = caf_write(a->id, &x, 1);
      } else if (phase.find("seal") != std::string::npos)
        result = caf_seal(a->id, 0);
      else
        result = rename(a->id, d.id, L"renamed");
      checkpoint = {};
      check(hit && result.status == CAF_INTERNAL, "specific injected failure");
      auto effect = phase.rfind("after_create", 0) == 0 ? CAF_CREATED
                    : phase == "after_write"            ? CAF_WRITTEN
                    : phase == "after_rename"           ? CAF_RENAMED
                                                        : CAF_NONE;
      check(result.effect == static_cast<uint32_t>(effect),
            "actual effects survived failure");
      if (creating) {
        check(fs::exists(f.project / std::wstring(phase.begin(), phase.end()) /
                         L"source") == bool(result.effect == CAF_CREATED),
              "creation fact on disk");
        if (result.object)
          good(caf_close(result.object));
      }
    }
    check(GetProcessHandleCount(GetCurrentProcess(), &after) != 0,
          "final fault handle count");
    check(before == after, "fault resource handles drained");
  }
  {
    Object a(file(r.id, L"partial"));
    shortWrite = true;
    const uint8_t data[] = {1, 2, 3};
    auto x = caf_write(a.id, data, 3);
    shortWrite = false;
    check(x.status == CAF_OS && x.win32_error == ERROR_WRITE_FAULT &&
              x.bytes == 1 && x.effect == CAF_WRITTEN,
          "actual partial write reported");
    check(caf_info(a.id).bytes == 1, "partial file real size");
  }
}
#endif
int wmain(int argc, wchar_t **argv) {
  try {
    if (argc > 1 && std::wstring(argv[1]) == L"child")
      return child(argc, argv);
    check(argc == 2, "case required");
    check(caf_c_header_test() != 0, "C ABI");
    const std::wstring name = argv[1];
    if (name == L"symlink")
      return symlink_test();
    if (name == L"termination") {
      termination();
      return 0;
    }
#ifdef CAF_TEST_INSTRUMENTATION
    if (name == L"inplace_create") {
      inplace(false);
      return 0;
    }
    if (name == L"inplace_rename") {
      inplace(true);
      return 0;
    }
    if (name == L"faults") {
      faults();
      return 0;
    }
#endif
    if (name == L"volume_policy") {
      volume_policy();
      return 0;
    }
    if (name == L"volume" &&
        !GetEnvironmentVariableW(L"CAF_SECOND_VOLUME", nullptr, 0)) {
      std::cout << "PENDING: second real NTFS volume unavailable; no "
                   "integration claim\n";
      return 77;
    }
    if (name == L"basic")
      basic();
    else if (name == L"names")
      names();
    else if (name == L"static_junction")
      static_junction();
    else if (name == L"races")
      races();
    else if (name == L"collision")
      collision();
    else if (name == L"rename")
      rename_test();
    else if (name == L"sharing")
      sharing();
    else if (name == L"denied")
      denied();
    else if (name == L"invalid")
      invalid();
    else if (name == L"leaks")
      leaks();
    else if (name == L"unicode")
      unicode();
    else if (name == L"concurrency")
      concurrency();
    else if (name == L"volume")
      volume();
    else
      throw std::runtime_error("unknown case");
    std::cout << "PASS\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "FAIL: " << e.what() << "\n";
    return 1;
  }
}
