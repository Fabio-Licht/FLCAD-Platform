#include "flcad_occ_api.h"
#include "flcad_occ_mesh_stream.h"
#include <iostream>
#include <thread>
struct State {
  uint64_t bytes = 0;
  int calls = 0;
  bool cancel = false;
  std::thread::id thread = std::this_thread::get_id();
};
int32_t OCC_STREAM_CALL sink(void *c, const uint8_t *, uint32_t size,
                             uint32_t *accepted) {
  auto &s = *static_cast<State *>(c);
  if (s.cancel) {
    *accepted = 0;
    return -1;
  }
  if (std::this_thread::get_id() != s.thread || size > 64000)
    return 99;
  s.bytes += size;
  ++s.calls;
  *accepted = size;
  return 0;
}
int main() {
  char token[256] = {}, fp[256] = {}, error[4096] = {};
  double center[] = {0, 0, 0};
  if (flcad_occ_initialize(error, sizeof(error)) != 1)
    return 1;
  if (flcad_occ_create_sphere(center, 10, -1.5707963267948966,
                              1.5707963267948966, token, sizeof(token), fp,
                              sizeof(fp), error, sizeof(error)) != 1)
    return 2;
  const auto count = flcad_occ_shape_count();
  State s;
  occ_stream_sink_v1 output{sizeof(output), 1, &s, sink};
  occ_stream_result_v1 r{};
  if (flcad_occ_mesh_stream_version() != 1 ||
      flcad_occ_mesh_stream_v1(token, .02, .15, UINT32_MAX, &output, &r,
                               sizeof(r)) != 0) {
    std::cerr << r.message;
    return 3;
  }
  if (s.calls < 2 || s.bytes != 84 + 50 * r.triangles ||
      r.bytes_accepted != s.bytes || flcad_occ_shape_count() != count)
    return 4;
  const auto completedBytes = s.bytes;
  const auto completedCalls = s.calls;
  s.cancel = true;
  if (flcad_occ_mesh_stream_v1(token, .02, .15, UINT32_MAX, &output, &r,
                               sizeof(r)) != OCC_STREAM_CANCELLED ||
      r.bytes_accepted != 0 || flcad_occ_shape_count() != count)
    return 7;
  if (flcad_occ_validate(token, error, sizeof(error), fp, sizeof(fp)) != 1)
    return 5;
  if (flcad_occ_destroy_shape(token, error, sizeof(error)) != 1 ||
      flcad_occ_shape_count() != count - 1)
    return 6;
  flcad_occ_shutdown();
  std::cout << "PASS production DLL ABI1 " << completedCalls << " chunks "
            << completedBytes << " bytes\n";
}
