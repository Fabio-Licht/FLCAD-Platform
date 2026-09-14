#include "../../cad_occ_bridge/include/cad_occ_bridge.h"
#include "flcad_occ_api.h"
#include "flcad_occ_step_source.h"
#include "step_fixture.h"
#include <filesystem>
#include <iostream>
#include <windows.h>
struct StepLibrary {
  HMODULE handle;
  explicit StepLibrary(const wchar_t *path) {
    auto absolute = std::filesystem::canonical(path);
    handle = LoadLibraryExW(absolute.c_str(), nullptr,
                            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                                LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!handle)
      throw std::runtime_error("STEP smoke DLL load");
  }
  ~StepLibrary() { FreeLibrary(handle); }
  template <class T> T fn(const char *name) {
    auto address = GetProcAddress(handle, name);
    if (!address)
      throw std::runtime_error(name);
    return reinterpret_cast<T>(address);
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
int wmain(int argc, wchar_t **argv) {
  if (argc != 3 && argc != 4)
    return 2;
  try {
    StepLibrary caf(argv[1]), cob(argv[2]);
    // Controlled discovery fixtures for the Dart integration suite. No product
    // source is reopened and no temporary file participates in import.
    if (argc == 4) {
      const std::filesystem::path directory(argv[3]);
      auto root = FN(caf, caf_open_root)(
          reinterpret_cast<const uint16_t *>(directory.c_str()),
          static_cast<uint32_t>(directory.native().size()));
      CHECK(!root.status);
      for (int mode = 0; mode < 6; ++mode) {
        auto bytes = mode == 5 ? std::string("invalid STEP")
                               : step_fixture(mode != 1,
                                              mode == 3   ? 1
                                              : mode == 4 ? 3
                                                          : 0,
                                              mode == 2);
        const auto leaf = L"part-" + std::to_wstring(mode) + L".step";
        auto file = FN(caf, caf_create_file)(
            root.object, reinterpret_cast<const uint16_t *>(leaf.data()),
            static_cast<uint32_t>(leaf.size()));
        CHECK(!file.status);
        auto written = FN(caf, caf_write)(
            file.object, reinterpret_cast<const uint8_t *>(bytes.data()),
            static_cast<uint32_t>(bytes.size()));
        CHECK(!written.status && written.bytes == bytes.size());
        CHECK(!FN(caf, caf_seal)(file.object, bytes.size()).status);
        CHECK(!FN(caf, caf_close)(file.object).status);
      }
      CHECK(!FN(caf, caf_close)(root.object).status);
      return 0;
    }
    auto ca = reinterpret_cast<const void *>(
        GetProcAddress(caf.handle, "caf_source_version"));
    auto oc = reinterpret_cast<const void *>(
        GetProcAddress(GetModuleHandleW(L"flcad_opencascade.dll"),
                       "flcad_occ_source_version"));
    char error[256]{}, prior[64]{}, fp[64]{};
    double center[]{0, 0, 0};
    CHECK(flcad_occ_initialize(error, sizeof(error)) == 1);
    CHECK(flcad_occ_create_sphere(center, 1, -1.5707963267948966,
                                  1.5707963267948966, prior, sizeof(prior), fp,
                                  sizeof(fp), error, sizeof(error)) == 1);
    const auto baseline = flcad_occ_shape_count();
    CHECK(FN(cob, cob_step_version)() == 1);
    CHECK(FN(cob, cob_step_result_size_v1)() == sizeof(cob_step_result_v1));
    const auto directory =
        std::filesystem::temp_directory_path() /
        ("flcad-step-caf-" + std::to_string(GetCurrentProcessId()));
    CHECK(std::filesystem::create_directory(directory));
    auto root = FN(caf, caf_open_root)(
        reinterpret_cast<const uint16_t *>(directory.c_str()),
        static_cast<uint32_t>(directory.native().size()));
    CHECK(!root.status);
    char name[4097]{}, unit[257]{};
    occ_step_buffers_v1 buffers{sizeof(buffers), 1,    name,
                                sizeof(name),    unit, sizeof(unit)};
    for (int mode = 0; mode < 6; ++mode) {
      auto bytes = step_fixture(mode != 1, mode == 2 ? 3 : mode == 5 ? 1 : 0);
      auto leaf = L"part-" + std::to_wstring(mode) + L".step";
      auto file = FN(caf, caf_create_file)(
          root.object, reinterpret_cast<const uint16_t *>(leaf.data()),
          static_cast<uint32_t>(leaf.size()));
      CHECK(!file.status);
      for (size_t offset = 0; offset < bytes.size();) {
        const auto count = static_cast<uint32_t>(
            std::min<size_t>(65536, bytes.size() - offset));
        auto written = FN(caf, caf_write)(
            file.object,
            reinterpret_cast<const uint8_t *>(bytes.data() + offset), count);
        CHECK(!written.status && written.bytes == count);
        offset += count;
      }
      auto expected = FN(caf, caf_seal)(file.object, bytes.size());
      CHECK(!expected.status);
      cob_result_v1 begun{};
      CHECK(FN(cob, cob_begin_v1)(ca, oc, file.object, &expected,
                                  sizeof(expected), 3, &begun,
                                  sizeof(begun)) == 0);
      const auto id = begun.operation;
      CHECK(flcad_occ_shape_count() == baseline &&
            !begun.native_result.published);
      CHECK(FN(caf, caf_close)(file.object).win32_error == ERROR_BUSY);
      CHECK(FN(cob, cob_run_v1)(id, &begun, sizeof(begun)) == COB_STATE);
      cob_step_result_v1 result{};
      CHECK(FN(cob, cob_step_run_v1)(id, &buffers, &result,
                                     sizeof(result) - 1) == COB_ARGUMENT);
      CHECK(FN(cob, cob_step_run_v1)(id, nullptr, &result, sizeof(result)) ==
            COB_ARGUMENT);
      if (mode == 3) {
        std::strcpy(name, "stale name");
        std::strcpy(unit, "stale unit");
        CHECK(!FN(cob, cob_cancel_v1)(id));
      }
      auto copy = buffers;
      if (mode == 4)
        copy.unit_capacity = 1;
      CHECK(FN(cob, cob_step_run_v1)(id, &copy, &result, sizeof(result)) == 0);
      auto &native = result.bridge_result.native_result;
      if (mode == 0 || mode == 1) {
        CHECK(native.published && result.bridge_result.token_held);
        CHECK(flcad_occ_shape_count() == baseline + 1);
        CHECK(std::string(name) == u8"Peça única" &&
              std::string(unit) == "millimetre");
        CHECK(result.metadata.has_color == (mode == 0 ? 1u : 0u));
        CHECK(flcad_occ_validate(native.token, error, sizeof(error), fp,
                                 sizeof(fp)) == 1);
        if (mode == 0) {
          // Adopt is the later custody boundary; the bridge does not adopt on
          // run.
          std::string token = native.token;
          CHECK(!FN(cob, cob_adopt_v1)(id));
          CHECK(!FN(cob, cob_close_v1)(id, &begun, sizeof(begun)));
          CHECK(!begun.compensation);
          CHECK(flcad_occ_destroy_shape(token.c_str(), error, sizeof(error)) ==
                1);
        } else {
          CHECK(!FN(cob, cob_close_v1)(id, &begun, sizeof(begun)));
          CHECK(begun.compensation == 1 && !begun.token_held);
        }
      } else {
        CHECK(!native.published && !native.token[0]);
        CHECK(native.status == (mode == 3   ? OCC_READ_CANCELLED
                                : mode == 4 ? OCC_READ_INVALID
                                            : OCC_READ_FORMAT));
        CHECK(!result.metadata.size && !name[0] && !unit[0]);
        CHECK(!FN(cob, cob_close_v1)(id, &begun, sizeof(begun)));
      }
      CHECK(flcad_occ_shape_count() == baseline);
      auto info = FN(caf, caf_info)(file.object);
      CHECK(!info.status && info.bytes == expected.bytes &&
            std::memcmp(info.sha256, expected.sha256, sizeof(info.sha256)) ==
                0);
      CHECK(!FN(caf, caf_close)(file.object).status);
      CHECK(std::filesystem::remove(directory / leaf));
    }
    CHECK(!FN(caf, caf_close)(root.object).status);
    CHECK(std::filesystem::remove(directory));
    CHECK(flcad_occ_destroy_shape(prior, error, sizeof(error)) == 1);
    CHECK(flcad_occ_shape_count() == 0);
    std::cout << "STEP CAF C-to-C productive DLL smoke passed\n";
  } catch (const std::exception &e) {
    std::cerr << e.what() << "\n";
    return 1;
  } catch (...) {
    std::cerr << "Unknown STEP smoke failure\n";
    return 1;
  }
}
