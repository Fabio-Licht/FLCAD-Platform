#include "cad_occ_bridge.h"
#include "flcad_occ_api.h"
#include "flcad_occ_brep_stream.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <windows.h>
struct Library {
  HMODULE h = nullptr;
  bool owns = true;
  void drop() {
    if (owns) {
      FreeLibrary(h);
      owns = false;
    }
  }
  void retain(const void *anchor) {
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                            reinterpret_cast<LPCWSTR>(anchor), &h))
      throw std::runtime_error("retain");
    owns = true;
  }
  explicit Library(const wchar_t *path) {
    const auto absolute = std::filesystem::canonical(path);
    h = LoadLibraryExW(absolute.c_str(), nullptr,
                       LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                           LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!h) {
      std::wcerr << absolute << L" error " << GetLastError() << L"\n";
      throw std::runtime_error("DLL unavailable");
    }
  }
  ~Library() {
    if (h && owns)
      FreeLibrary(h);
  }
  template <class T> T fn(const char *name) {
    auto p = GetProcAddress(h, name);
    if (!p)
      throw std::runtime_error(name);
    return reinterpret_cast<T>(p);
  }
};
#define FN(lib, name) lib.fn<decltype(&name)>(#name)
#define CHECK(x)                                                               \
  do {                                                                         \
    if (!(x)) {                                                                \
      std::cerr << "FAIL " << __LINE__ << " " << #x << "\n";                   \
      return 1;                                                                \
    }                                                                          \
  } while (false)
std::atomic<int> point_mode{0}, read_calls{0};
std::mutex barrier_mutex;
std::condition_variable barrier;
bool reached = false, proceed = false;
uint8_t *mapped_bytes = nullptr;
size_t mapped_size = 0;
using Damage = caf_result (*)(uint64_t, uint64_t);
Damage damage = nullptr;
uint64_t damage_file = 0;
int cob_destroy_override(uint64_t) { return -999; }
caf_result cob_read_override(caf_result r, uint64_t) {
  if (point_mode == 9 && read_calls == 3) {
    r.status = CAF_OS;
    r.win32_error = ERROR_READ_FAULT;
    r.bytes = 3;
    r.reserved = 1;
  }
  return r;
}
void cob_checkpoint(const char *name, uint64_t operation) {
  if ((point_mode == 10 && std::string(name) == "before_parse") ||
      (point_mode == 11 && std::string(name) == "after_publish"))
    throw std::runtime_error("Injected bridge exception");
  int mode = point_mode.load();
  if (std::string(name) == "before_read") {
    int count = ++read_calls;
    if (mode == 6 && count == 1 && damage)
      damage(damage_file, 100);
    if (mode == 1 || (mode == 2 && count == 3))
      cob_cancel_v1(operation);
    if (mode == 4 && count == 1) {
      std::unique_lock<std::mutex> lock(barrier_mutex);
      reached = true;
      barrier.notify_all();
      barrier.wait(lock, [] { return proceed; });
    }
  }
  if (mode == 7 && std::string(name) == "before_final" && damage)
    damage(damage_file, 100);
  if (mode == 3 && std::string(name) == "before_final")
    cob_cancel_v1(operation);
}
int32_t OCC_STREAM_CALL sink(void *p, const uint8_t *bytes, uint32_t count,
                             uint32_t *accepted) {
  static_cast<std::string *>(p)->append(reinterpret_cast<const char *>(bytes),
                                        count);
  *accepted = count;
  return 0;
}
int wmain(int argc, wchar_t **argv) {
  if (argc != 3 && argc != 4)
    return 2;
  try {
    Library caf(argv[1]), occ(argv[2]);
    const auto incompatiblePath =
        std::filesystem::canonical(argv[0]).parent_path() /
        L"cad_occ_bridge_incompatible.dll";
    Library incompatible(incompatiblePath.c_str());
    auto ca = reinterpret_cast<const void *>(
        GetProcAddress(caf.h, "caf_abi_version"));
    auto oc = reinterpret_cast<const void *>(
        GetProcAddress(occ.h, "flcad_occ_source_version"));
    const auto temp = std::filesystem::temp_directory_path();
    const auto dir =
        argc == 4 ? std::filesystem::path(argv[3])
                  : temp / (L"cob-" + std::to_wstring(GetCurrentProcessId()) +
                            L"-" + std::to_wstring(GetTickCount64()));
    CHECK(std::filesystem::equivalent(dir.parent_path(), temp));
    if (argc == 3)
      CHECK(std::filesystem::create_directory(dir));
    else
      CHECK(std::filesystem::is_directory(dir) &&
            dir.filename().native().find(L"cob-dart-") == 0);
    auto root =
        FN(caf, caf_open_root)(reinterpret_cast<const uint16_t *>(dir.c_str()),
                               static_cast<uint32_t>(dir.native().size()));
    CHECK(!root.status);
    std::vector<uint64_t> owned{root.object};
    auto parent = root.object;
    for (int i = 0; i < (argc == 4 ? 0 : 7); ++i) {
      std::wstring name = L"geometria \u00e7 espa\u00e7os " +
                          std::to_wstring(i) + std::wstring(30, L'x');
      auto d = FN(caf, caf_create_pinned_dir)(
          parent, reinterpret_cast<const uint16_t *>(name.data()),
          static_cast<uint32_t>(name.size()));
      if (d.status)
        std::cerr << "directory " << i << " status " << d.status << " win "
                  << d.win32_error << " nt " << d.nt_status << "\n";
      CHECK(!d.status);
      owned.push_back(d.object);
      parent = d.object;
    }
    char error[4096]{}, token[64]{}, fp[64]{};
    double center[] = {1, 2, 3};
    CHECK(FN(occ, flcad_occ_initialize)(error, sizeof(error)) == 1);
    CHECK(FN(occ, flcad_occ_create_sphere)(
              center, 5, -1.5707963267948966, 1.5707963267948966, token,
              sizeof(token), fp, sizeof(fp), error, sizeof(error)) == 1);
    std::string brep, stl;
    occ_stream_result_v1 sr{};
    occ_stream_sink_v1 target{sizeof(target), 1, &brep, sink};
    CHECK(FN(occ, flcad_occ_brep_stream_v1)(token, UINT64_MAX, &target, &sr,
                                            sizeof(sr)) == 0);
    target.context = &stl;
    CHECK(FN(occ, flcad_occ_mesh_stream_v1)(token, .02, .15, 1000000, &target,
                                            &sr, sizeof(sr)) == 0 &&
          stl.size() > 65536);
    auto pathCount = occ.fn<uint64_t (*)()>("flcad_occ_test_path_import_count");
    const auto pathsBefore = pathCount();
    auto shapeCount = FN(occ, flcad_occ_shape_count);
    auto meshCount = occ.fn<uint64_t (*)()>("flcad_occ_test_mesh_count");
    auto baseline = shapeCount();
    auto meshBaseline = meshCount();
    for (int kind : {1, 2}) {
      const auto &bytes = kind == 1 ? brep : stl;
      std::wstring name = kind == 1 ? L"shape.brep" : L"display.stl";
      auto file = FN(caf, caf_create_file)(
          parent, reinterpret_cast<const uint16_t *>(name.data()),
          static_cast<uint32_t>(name.size()));
      CHECK(!file.status);
      owned.push_back(file.object);
      for (size_t offset = 0; offset < bytes.size();) {
        auto count = static_cast<uint32_t>(
            std::min<size_t>(65536, bytes.size() - offset));
        auto r = FN(caf, caf_write)(
            file.object,
            reinterpret_cast<const uint8_t *>(bytes.data() + offset), count);
        CHECK(!r.status && r.bytes == count);
        offset += count;
      }
      auto expected = FN(caf, caf_seal)(file.object, bytes.size());
      CHECK(!expected.status);
      cob_result_v1 result{};
      CHECK(cob_begin_v1(ca, oc, file.object, &expected, sizeof(expected), kind,
                         &result, sizeof(result) - 1) == COB_ARGUMENT);
      CHECK(cob_begin_v1(ca, ca, file.object, &expected, sizeof(expected), kind,
                         &result, sizeof(result)) == COB_ABI);
      CHECK(cob_begin_v1(ca,
                         reinterpret_cast<const void *>(GetProcAddress(
                             incompatible.h, "flcad_occ_source_version")),
                         file.object, &expected, sizeof(expected), kind,
                         &result, sizeof(result)) == COB_ABI);
      for (int mismatch = 0; mismatch < 3; ++mismatch) {
        auto wrong = expected;
        if (mismatch == 0)
          wrong.file_id[0] ^= 1;
        if (mismatch == 1)
          ++wrong.bytes;
        if (mismatch == 2)
          wrong.sha256[0] ^= 1;
        auto begun = cob_begin_v1(ca, oc, file.object, &wrong, sizeof(wrong),
                                  kind, &result, sizeof(result));
        if (mismatch < 2)
          CHECK(begun == COB_FILESYSTEM && !result.operation);
        else {
          CHECK(begun == 0);
          auto rejected = result.operation;
          CHECK(cob_run_v1(rejected, &result, sizeof(result)) == 0 &&
                result.native_result.status == OCC_READ_SOURCE &&
                !result.native_result.published);
          CHECK(cob_close_v1(rejected, &result, sizeof(result)) == 0);
        }
        CHECK(shapeCount() == baseline && meshCount() == meshBaseline);
      }
      CHECK(cob_begin_v1(ca, oc, file.object, &expected, sizeof(expected), kind,
                         &result, sizeof(result)) == 0);
      auto id = result.operation;
      CHECK(FN(caf, caf_close)(file.object).win32_error == ERROR_BUSY);
      CHECK(FN(caf, caf_close)(root.object).win32_error == ERROR_BUSY);
      CHECK(cob_run_v1(id, &result, sizeof(result) - 1) == COB_ARGUMENT);
      caf.drop();
      CHECK(GetModuleHandleW(L"cad_asset_fs.dll") != nullptr);
      occ.drop();
      CHECK(GetModuleHandleW(L"flcad_opencascade.dll") != nullptr);
      CHECK(cob_run_v1(id, &result, sizeof(result)) == 0 &&
            result.native_result.published && result.token_held);
      caf.retain(ca);
      occ.retain(oc);
      std::string imported = result.native_result.token;
      CHECK(cob_adopt_v1(id) == 0);
      CHECK(cob_close_v1(id, &result, sizeof(result)) == 0 &&
            !result.compensation);
      if (kind == 1) {
        CHECK(FN(occ, flcad_occ_validate)(imported.c_str(), error,
                                          sizeof(error), fp, sizeof(fp)) == 1);
        CHECK(FN(occ, flcad_occ_destroy_shape)(imported.c_str(), error,
                                               sizeof(error)) == 1);
        CHECK(FN(occ, flcad_occ_destroy_shape)(imported.c_str(), error,
                                               sizeof(error)) == 0);
      } else {
        std::vector<double> vertices(
            static_cast<size_t>(result.native_result.vertices) * 3);
        std::vector<int> triangles(
            static_cast<size_t>(result.native_result.triangles) * 3);
        CHECK(FN(occ, flcad_occ_mesh_geometry)(
                  imported.c_str(), vertices.data(), vertices.size(),
                  triangles.data(), triangles.size(), error,
                  sizeof(error)) == 1);
        CHECK(!vertices.empty() && !triangles.empty());
        CHECK(FN(occ, flcad_occ_destroy_mesh)(imported.c_str(), error,
                                              sizeof(error)) == 1);
        CHECK(FN(occ, flcad_occ_destroy_mesh)(imported.c_str(), error,
                                              sizeof(error)) == 0);
      }
      CHECK(cob_begin_v1(ca, oc, file.object, &expected, sizeof(expected), kind,
                         &result, sizeof(result)) == 0);
      id = result.operation;
      CHECK(cob_run_v1(id, &result, sizeof(result)) == 0 &&
            result.native_result.published);
      CHECK(cob_close_v1(id, &result, sizeof(result)) == 0 &&
            result.compensation == 1 && shapeCount() == baseline &&
            meshCount() == meshBaseline);
      CHECK(cob_begin_v1(ca, oc, file.object, &expected, sizeof(expected), kind,
                         &result, sizeof(result)) == 0);
      id = result.operation;
      CHECK(cob_cancel_v1(id) == 0);
      CHECK(cob_run_v1(id, &result, sizeof(result)) == 0 &&
            result.native_result.status == OCC_READ_CANCELLED &&
            !result.token_held);
      CHECK(cob_close_v1(id, &result, sizeof(result)) == 0);
#ifdef COB_TESTING
      for (int mode : {1, 2, 3, 4, 9, 10, 11}) {
        if (kind == 1 && (mode == 2 || mode == 9))
          continue;
        point_mode = mode;
        read_calls = 0;
        reached = false;
        proceed = false;
        CHECK(cob_begin_v1(ca, oc, file.object, &expected, sizeof(expected),
                           kind, &result, sizeof(result)) == 0);
        id = result.operation;
        if (mode == 4) {
          std::thread thread([&] { cob_run_v1(id, &result, sizeof(result)); });
          {
            std::unique_lock<std::mutex> lock(barrier_mutex);
            if (!barrier.wait_for(lock, std::chrono::seconds(10),
                                  [] { return reached; })) {
              proceed = true;
              barrier.notify_all();
              lock.unlock();
              thread.join();
              return 3;
            }
          }
          cob_result_v1 closeResult{};
          const auto busyClose =
              cob_close_v1(id, &closeResult, sizeof(closeResult));
          const auto busyFile = FN(caf, caf_close)(file.object).win32_error;
          const auto cancelled = cob_cancel_v1(id);
          {
            std::lock_guard<std::mutex> lock(barrier_mutex);
            proceed = true;
          }
          barrier.notify_all();
          thread.join();
          CHECK(busyClose == COB_BUSY);
          CHECK(busyFile == ERROR_BUSY);
          CHECK(cancelled == 0);
        } else
          CHECK(cob_run_v1(id, &result, sizeof(result)) ==
                (mode >= 10 ? COB_INTERNAL : 0));
        if (mode == 9)
          CHECK(result.native_result.status == OCC_READ_SOURCE &&
                result.native_result.bytes_provided == 131075 &&
                result.native_result.error_domain == 0x434146 &&
                result.native_result.error_code == CAF_OS);
        else if (mode >= 10)
          CHECK(result.native_result.published == (mode == 11));
        else
          CHECK(result.native_result.status == OCC_READ_CANCELLED &&
                !result.native_result.published);
        const auto stopped = read_calls.load();
        CHECK(cob_close_v1(id, &result, sizeof(result)) == 0 &&
              read_calls == stopped);
      }
      point_mode = 0;
#endif
      // Independent operations on the same pinned node; neither cursor is
      // shared.
      cob_result_v1 a{}, b{};
      CHECK(cob_begin_v1(ca, oc, file.object, &expected, sizeof(expected), kind,
                         &a, sizeof(a)) == 0);
      CHECK(cob_begin_v1(ca, oc, file.object, &expected, sizeof(expected), kind,
                         &b, sizeof(b)) == 0);
      auto ai = a.operation, bi = b.operation;
      std::thread t1([&] { cob_run_v1(ai, &a, sizeof(a)); }),
          t2([&] { cob_run_v1(bi, &b, sizeof(b)); });
      t1.join();
      t2.join();
      CHECK(a.native_result.published && b.native_result.published &&
            std::string(a.native_result.token) != b.native_result.token);
      CHECK(cob_close_v1(ai, &a, sizeof(a)) == 0);
      CHECK(cob_close_v1(bi, &b, sizeof(b)) == 0);
    }
    for (int kind : {1, 2}) {
      const auto &all = kind == 1 ? brep : stl;
      const auto bytes = all.substr(0, all.size() / 2);
      const std::wstring name =
          kind == 1 ? L"truncated.brep" : L"truncated.stl";
      auto file = FN(caf, caf_create_file)(
          parent, reinterpret_cast<const uint16_t *>(name.data()),
          static_cast<uint32_t>(name.size()));
      CHECK(!file.status);
      owned.push_back(file.object);
      for (size_t offset = 0; offset < bytes.size();) {
        auto count = static_cast<uint32_t>(
            std::min<size_t>(65536, bytes.size() - offset));
        CHECK(!FN(caf, caf_write)(
                   file.object,
                   reinterpret_cast<const uint8_t *>(bytes.data() + offset),
                   count)
                   .status);
        offset += count;
      }
      auto expected = FN(caf, caf_seal)(file.object, bytes.size());
      CHECK(!expected.status);
      cob_result_v1 r{};
      CHECK(cob_begin_v1(ca, oc, file.object, &expected, sizeof(expected), kind,
                         &r, sizeof(r)) == 0);
      auto id = r.operation;
      CHECK(cob_run_v1(id, &r, sizeof(r)) == 0 && !r.native_result.published &&
            r.native_result.status != 0);
      CHECK(cob_close_v1(id, &r, sizeof(r)) == 0 && shapeCount() == baseline &&
            meshCount() == meshBaseline);
    }

#ifdef COB_TESTING
    if (argc == 3) {
      const auto damage_path =
          std::filesystem::canonical(argv[1]).parent_path() /
          L"cad_asset_fs_source_test.dll";
      Library testCaf(damage_path.c_str());
      auto testAnchor = reinterpret_cast<const void *>(
          GetProcAddress(testCaf.h, "caf_abi_version"));
      auto droot = FN(testCaf, caf_open_root)(
          reinterpret_cast<const uint16_t *>(dir.c_str()),
          static_cast<uint32_t>(dir.native().size()));
      CHECK(!droot.status);
      const std::wstring name = L"physical-tamper.stl";
      auto file = FN(testCaf, caf_create_file)(
          droot.object, reinterpret_cast<const uint16_t *>(name.data()),
          static_cast<uint32_t>(name.size()));
      CHECK(!file.status);
      for (size_t offset = 0; offset < stl.size();) {
        auto count =
            static_cast<uint32_t>(std::min<size_t>(65536, stl.size() - offset));
        CHECK(!FN(testCaf, caf_write)(
                   file.object,
                   reinterpret_cast<const uint8_t *>(stl.data() + offset),
                   count)
                   .status);
        offset += count;
      }
      auto expected = FN(testCaf, caf_seal)(file.object, stl.size());
      CHECK(!expected.status);
      damage = testCaf.fn<Damage>("caf_source_test_damage");
      damage_file = file.object;
      for (int mode : {6, 7}) {
        point_mode = mode;
        read_calls = 0;
        cob_result_v1 r{};
        CHECK(cob_begin_v1(testAnchor, oc, file.object, &expected,
                           sizeof(expected), 2, &r, sizeof(r)) == 0);
        auto id = r.operation;
        CHECK(cob_run_v1(id, &r, sizeof(r)) == 0 &&
              r.native_result.status == OCC_READ_SOURCE &&
              !r.native_result.published);
        CHECK(r.filesystem.status == CAF_POLICY &&
              r.filesystem.win32_error == ERROR_FILE_INVALID);
        CHECK(cob_close_v1(id, &r, sizeof(r)) == 0 &&
              meshCount() == meshBaseline);
        CHECK(!damage(damage_file, 100).status);
      }
      point_mode = 0;
      damage = nullptr;
      CHECK(!FN(testCaf, caf_close)(file.object).status);
      CHECK(!FN(testCaf, caf_close)(droot.object).status);
    }
#endif
    CHECK(shapeCount() == baseline && meshCount() == meshBaseline &&
          pathCount() == pathsBefore);
    CHECK(FN(occ, flcad_occ_destroy_shape)(token, error, sizeof(error)) == 1);
    FN(occ, flcad_occ_shutdown)();
    for (auto i = owned.rbegin(); i != owned.rend(); ++i)
      CHECK(!FN(caf, caf_close)(*i).status);
    CHECK(std::filesystem::equivalent(dir.parent_path(), temp));
    if (argc == 3)
      std::filesystem::remove_all(
          std::filesystem::path(L"\\\\?\\" + dir.native()));
    std::cout << "PASS real CAF/OCCT bridge: BREP/STL, escrow/custody handoff, "
                 "compensations, cancellation, concurrent operations, Unicode "
                 "long paths\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
