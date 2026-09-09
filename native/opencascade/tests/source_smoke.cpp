#include "flcad_occ_api.h"
#include "flcad_occ_brep_stream.h"
#include "flcad_occ_source.h"
#include <algorithm>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <set>
#include <string>
#include <thread>
#ifdef _WIN32
#include <windows.h>
#endif
struct Bytes {
  std::string data;
  size_t reads = 0, checks = 0, final = 0;
  uint64_t provided = 0;
  size_t captured = 0;
  bool mutate = false, after_final = false;
  std::thread::id thread = std::this_thread::get_id();
};
int32_t OCC_STREAM_CALL sink(void *p, const uint8_t *b, uint32_t n,
                             uint32_t *done) {
  auto &x = *static_cast<Bytes *>(p);
  x.data.append(reinterpret_cast<const char *>(b), n);
  *done = n;
  return 0;
}
int32_t OCC_STREAM_CALL read_at(void *p, uint64_t off, uint8_t *b, uint32_t n,
                                occ_source_io_v1 *io) {
  auto &x = *static_cast<Bytes *>(p);
  if (x.thread != std::this_thread::get_id())
    return 90;
  x.after_final |= x.final != 0;
  ++x.reads;
  n = static_cast<uint32_t>(std::min<uint64_t>({n, 137, x.data.size() - off}));
  std::memcpy(b, x.data.data() + off, n);
  io->bytes_read = n;
  x.provided += n;
  if (x.mutate && x.reads == 2)
    x.data.back() = x.data.back() == ' ' ? '\n' : ' ';
  return 0;
}
int32_t OCC_STREAM_CALL check(void *p, uint32_t phase, occ_source_io_v1 *io) {
  auto &x = *static_cast<Bytes *>(p);
  if (x.thread != std::this_thread::get_id())
    return 90;
  x.after_final |= x.final != 0;
  ++x.checks;
  if (phase == 1) {
    ++x.final;
    if (std::hash<std::string>{}(x.data) != x.captured) {
      io->error_domain = 17;
      io->error_code = 71;
      return 71;
    }
  }
  return 0;
}
std::set<std::filesystem::path> inventory() {
  std::set<std::filesystem::path> out;
  for (auto &p : std::filesystem::recursive_directory_iterator(
           std::filesystem::current_path()))
    out.insert(p.path());
  return out;
}
#define CHECK(x)                                                               \
  do {                                                                         \
    if (!(x)) {                                                                \
      std::cerr << "FAIL " << __LINE__ << " " << error << " " << r.message     \
                << "\n";                                                       \
      return 1;                                                                \
    }                                                                          \
  } while (false)
int main() {
  char error[4096]{}, token[64]{}, fp[64]{};
  occ_read_result_v1 r{};
  occ_stream_result_v1 output{};
  const auto before = inventory();
  CHECK(flcad_occ_initialize(error, sizeof(error)) == 1);
  CHECK(flcad_occ_source_version() == 1);
  double center[] = {2, 3, 4};
  CHECK(flcad_occ_create_sphere(center, 4, -1.5707963267948966,
                                1.5707963267948966, token, sizeof(token), fp,
                                sizeof(fp), error, sizeof(error)) == 1);
  const auto count = flcad_occ_shape_count();
  occ_read_limits_v1 limits{};
  CHECK(flcad_occ_source_default_limits_v1(&limits, sizeof(limits)) == 0);
  Bytes brep;
  occ_stream_sink_v1 target{sizeof(target), 1, &brep, sink};
  CHECK(flcad_occ_brep_stream_v1(token, UINT64_MAX, &target, &output,
                                 sizeof(output)) == 0);
  brep.captured = std::hash<std::string>{}(brep.data);
  occ_source_v1 source{sizeof(source),   1,       &brep,
                       brep.data.size(), read_at, check};
  CHECK(flcad_occ_brep_read_v1(&source, &limits, &r, sizeof(r)) == 0 &&
        r.published && r.resource_kind == 1);
  CHECK(brep.reads > 1 && brep.final == 1 && !brep.after_final &&
        r.bytes_provided == brep.provided);
  CHECK(flcad_occ_shape_count() == count + 1 &&
        std::strcmp(token, r.token) != 0);
  CHECK(flcad_occ_validate(r.token, error, sizeof(error), fp, sizeof(fp)) == 1);
  const std::string restored = r.token;
  Bytes again;
  target.context = &again;
  CHECK(flcad_occ_brep_stream_v1(restored.c_str(), UINT64_MAX, &target, &output,
                                 sizeof(output)) == 0 &&
        !again.data.empty());
  Bytes stl;
  target.context = &stl;
  CHECK(flcad_occ_mesh_stream_v1(restored.c_str(), .1, .5, 2000000, &target,
                                 &output, sizeof(output)) == 0);
  const auto triangles = output.triangles;
  stl.captured = std::hash<std::string>{}(stl.data);
  source.context = &stl;
  source.length = stl.data.size();
  CHECK(flcad_occ_stl_read_v1(&source, &limits, &r, sizeof(r)) == 0 &&
        r.published && r.resource_kind == 2);
  CHECK(r.triangles > 0 && r.triangles <= triangles && r.vertices > 0 &&
        stl.final == 1 && !stl.after_final);
  CHECK(flcad_occ_destroy_mesh(r.token, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_mesh(r.token, error, sizeof(error)) == 0);
  Bytes changed;
  changed.data = brep.data;
  changed.captured = brep.captured;
  changed.mutate = true;
  source.context = &changed;
  source.length = changed.data.size();
  CHECK(flcad_occ_brep_read_v1(&source, &limits, &r, sizeof(r)) ==
            OCC_READ_SOURCE &&
        r.phase == OCC_READ_VERIFY && r.error_code == 71 && !r.published);
  CHECK(flcad_occ_shape_count() == count + 1 && changed.final == 1 &&
        !changed.after_final);
  CHECK(flcad_occ_destroy_shape(restored.c_str(), error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(token, error, sizeof(error)) == 1 &&
        flcad_occ_shape_count() == count - 1);
  flcad_occ_shutdown();
  CHECK(inventory() == before);
#ifdef _WIN32
  wchar_t path[32768]{};
  CHECK(GetModuleFileNameW(GetModuleHandleW(L"flcad_opencascade.dll"), path,
                           32768) > 0);
  std::wcout << L"DLL " << path << L"\n";
#endif
  std::cout << "PASS productive source DLL: BREP roundtrip, STL " << triangles
            << " triangles, real memory mutation detected; zero new files, "
               "released resources\n";
}
