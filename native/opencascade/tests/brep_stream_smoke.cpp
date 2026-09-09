#include "flcad_occ_api.h"
#include "flcad_occ_brep_stream.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
struct Consumer {
  std::string bytes;
  bool cancel = false;
  size_t calls = 0;
  std::thread::id thread = std::this_thread::get_id();
};
int32_t OCC_STREAM_CALL output(void *c, const uint8_t *p, uint32_t n,
                               uint32_t *accepted) {
  auto &s = *static_cast<Consumer *>(c);
  ++s.calls;
  if (s.thread != std::this_thread::get_id() || n > 64000)
    return 91;
  if (s.cancel) {
    *accepted = 0;
    return -1;
  }
  s.bytes.append(reinterpret_cast<const char *>(p), n);
  *accepted = n;
  return 0;
}
#define CHECK(x)                                                               \
  do {                                                                         \
    if (!(x)) {                                                                \
      std::cerr << "FAIL " << __LINE__ << " " << error << "\n";                \
      return 1;                                                                \
    }                                                                          \
  } while (false)
int main() {
  char error[4096] = {}, token[256] = {}, fp[256] = {}, type[64] = {},
       restored[256] = {};
  double center[] = {2, 3, 4};
  CHECK(flcad_occ_initialize(error, sizeof(error)) == 1);
  CHECK(flcad_occ_create_sphere(center, 4, -1.5707963267948966,
                                1.5707963267948966, token, sizeof(token), fp,
                                sizeof(fp), error, sizeof(error)) == 1);
  const auto count = flcad_occ_shape_count();
  Consumer c;
  occ_stream_sink_v1 sink{sizeof(sink), 1, &c, output};
  occ_stream_result_v1 r{};
  CHECK(flcad_occ_brep_stream_version() == 1);
  CHECK(flcad_occ_brep_stream_v1(token, UINT64_MAX, &sink, &r, sizeof(r)) == 0);
  CHECK(c.bytes.size() == r.bytes_accepted &&
        c.bytes.find("CASCADE Topology V3") != std::string::npos &&
        flcad_occ_shape_count() == count);
  c.cancel = true;
  CHECK(flcad_occ_brep_stream_v1(token, UINT64_MAX, &sink, &r, sizeof(r)) ==
            OCC_STREAM_CANCELLED &&
        r.bytes_accepted == 0);
  CHECK(flcad_occ_validate(token, error, sizeof(error), fp, sizeof(fp)) == 1);
  const auto dir =
      std::filesystem::temp_directory_path() /
      ("brep-dll-smoke-" +
       std::to_string(
           std::chrono::steady_clock::now().time_since_epoch().count()));
  CHECK(std::filesystem::create_directory(dir));
  const auto file = dir / "roundtrip.brep";
  {
    std::ofstream f(file, std::ios::binary);
    f.write(c.bytes.data(), c.bytes.size());
    CHECK(f.good());
  }
  CHECK(flcad_occ_import_shape(file.string().c_str(), "brep", restored,
                               sizeof(restored), fp, sizeof(fp), type,
                               sizeof(type), error, sizeof(error)) == 1);
  CHECK(flcad_occ_validate(restored, error, sizeof(error), fp, sizeof(fp)) ==
        1);
  Consumer again;
  sink.context = &again;
  CHECK(flcad_occ_brep_stream_v1(restored, UINT64_MAX, &sink, &r, sizeof(r)) ==
            0 &&
        !again.bytes.empty());
  CHECK(flcad_occ_destroy_shape(restored, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(token, error, sizeof(error)) == 1 &&
        flcad_occ_shape_count() == count - 1);
  std::filesystem::remove_all(dir);
  flcad_occ_shutdown();
  std::cout << "PASS productive BREP DLL restore " << c.bytes.size()
            << " bytes, cancellation, owner cleanup\n";
}
