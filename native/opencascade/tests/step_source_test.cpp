#include "../src/flcad_occ_api.cpp"
#include "step_fixture.h"
#include <BRepBndLib.hxx>
#include <iostream>
#define CHECK(x)                                                               \
  do {                                                                         \
    if (!(x)) {                                                                \
      std::cerr << "FAIL " << __LINE__ << " " << #x                            \
                << " status=" << r.native_result.status                        \
                << " message=" << r.native_result.message << "\n";             \
      return 1;                                                                \
    }                                                                          \
  } while (false)
struct StepMemory {
  std::string bytes;
  size_t reads = 0, checks = 0;
  uint32_t chunk = 65536;
  int mode = 0;
  bool failed = false, after_failure = false, baseline_valid = true;
  size_t baseline = 0;
};
int32_t OCC_STREAM_CALL step_read(void *p, uint64_t off, uint8_t *dst,
                                  uint32_t count, occ_source_io_v1 *io) {
  auto &m = *static_cast<StepMemory *>(p);
  ++m.reads;
  m.after_failure |= m.failed;
  m.baseline_valid &= shapes.size() == m.baseline;
  if (m.mode == 1) {
    m.failed = true;
    io->error_domain = 77;
    io->error_code = 123;
    return 1;
  }
  if (m.mode >= 4 && m.mode <= 6) {
    m.failed = true;
    if (m.mode == 4)
      throw Standard_Failure("STEP callback OCCT");
    if (m.mode == 5)
      throw std::runtime_error("STEP callback standard");
    throw 42;
  }
  auto n = static_cast<uint32_t>(
      std::min<uint64_t>(std::min(count, m.chunk), m.bytes.size() - off));
  if (m.mode == 2) {
    m.failed = true;
    io->bytes_read = 0;
    return 0;
  }
  std::memcpy(dst, m.bytes.data() + off, n);
  io->bytes_read = n;
  return 0;
}
int32_t OCC_STREAM_CALL step_check(void *p, uint32_t phase,
                                   occ_source_io_v1 *io) {
  auto &m = *static_cast<StepMemory *>(p);
  ++m.checks;
  m.after_failure |= m.failed;
  m.baseline_valid &= shapes.size() == m.baseline;
  if (m.mode == 3 || (m.mode == 7 && phase == 1)) {
    m.failed = true;
    io->error_domain = 78;
    io->error_code = 124;
    return -1;
  }
  return 0;
}
int main() {
  char error[256]{}, prior[64]{}, fp[64]{};
  double center[]{0, 0, 0};
  flcad_occ_initialize(error, sizeof(error));
  flcad_occ_create_sphere(center, 1, -1.5707963267948966, 1.5707963267948966,
                          prior, sizeof(prior), fp, sizeof(fp), error,
                          sizeof(error));
  const auto baseline = shapes.size();
  const auto mesh_baseline = meshes.size();
  occ_step_read_result_v1 r{};
  CHECK(baseline == 1);
  auto bytes = step_fixture();
  char name[4097]{}, unit[257]{};
  occ_step_buffers_v1 buffers{sizeof(buffers), 1,    name,
                              sizeof(name),    unit, sizeof(unit)};
  occ_read_limits_v1 limits{};
  flcad_occ_source_default_limits_v1(&limits, sizeof(limits));
  auto run = [&](StepMemory &m) {
    m.baseline = baseline;
    occ_source_v1 s{sizeof(s), 1, &m, m.bytes.size(), step_read, step_check};
    return flcad_occ_step_read_v1(&s, &limits, &buffers, &r, sizeof(r));
  };
  for (bool meter : {false, true}) {
    StepMemory m{step_fixture(true, 0, meter)};
    m.chunk = 7;
    CHECK(run(m) == OCC_READ_OK);
    CHECK(r.native_result.published == 1 && r.native_result.resource_kind == 1);
    CHECK(std::string(name) == u8"Peça única");
    std::cout << "unit=" << unit
              << " declared=" << r.metadata.declared_meters_per_unit << "\n";
    CHECK(std::string(unit) == (meter ? "metre" : "millimetre"));
    CHECK(std::abs(r.metadata.declared_meters_per_unit - (meter ? 1 : .001)) <
          1e-12);
    CHECK(r.metadata.resolved_meters_per_unit == .001);
    CHECK(r.metadata.has_color == 1 && r.metadata.rgba[3] == 1);
    CHECK(std::abs(r.metadata.rgba[0] - .125) < 1e-6);
    CHECK(std::abs(r.metadata.rgba[1] - .5) < 1e-6);
    CHECK(std::abs(r.metadata.rgba[2] - .75) < 1e-6);
    CHECK(r.metadata.name_bytes == std::strlen(name) &&
          r.metadata.unit_bytes == std::strlen(unit));
    CHECK(m.baseline_valid && !m.after_failure);
    CHECK(shapes.size() == baseline + 1);
    CHECK(BRepCheck_Analyzer(shapes.at(r.native_result.token)).IsValid());
    Bnd_Box bounds;
    BRepBndLib::Add(shapes.at(r.native_result.token), bounds);
    double x0, y0, z0, x1, y1, z1;
    bounds.Get(x0, y0, z0, x1, y1, z1);
    CHECK(std::abs((x1 - x0) - 10) < 1e-4);
    CHECK(flcad_occ_destroy_shape(r.native_result.token, error,
                                  sizeof(error)) == 1);
  }
  StepMemory no_color{step_fixture(false)};
  CHECK(run(no_color) == 0 && !r.metadata.has_color);
  for (double c : r.metadata.rgba)
    CHECK(c == 0);
  CHECK(flcad_occ_destroy_shape(r.native_result.token, error, sizeof(error)) ==
        1);
  auto reject = [&](StepMemory &m, uint32_t expected) {
    const auto status = run(m);
    return status == expected && !r.native_result.published &&
           !r.native_result.token[0] && !r.metadata.size && !name[0] &&
           !unit[0] && shapes.size() == baseline &&
           meshes.size() == mesh_baseline && m.baseline_valid &&
           !m.after_failure && shapes.find(prior) != shapes.end();
  };
  for (int mode : {1, 2, 3}) {
    StepMemory m{step_fixture(true, mode)};
    const auto transfers = step_transfer_calls;
    const auto parses = step_readstream_calls;
    CHECK(reject(m, OCC_READ_FORMAT));
    CHECK(step_transfer_calls == transfers);
    if (mode == 3)
      CHECK(step_readstream_calls == parses);
  }
  StepMemory transparent{step_fixture(true, 0, false, true)};
  CHECK(reject(transparent, OCC_READ_FORMAT));
  for (auto bad :
       {bytes.substr(0, bytes.size() - 40), std::string("bad step")}) {
    StepMemory m{bad};
    CHECK(reject(m, bad == "bad step" ? OCC_READ_FORMAT : OCC_READ_TRUNCATED));
  }
  for (auto suffix : {"garbage", "ISO-10303-21;"}) {
    StepMemory m{bytes + suffix};
    CHECK(reject(m, OCC_READ_FORMAT));
  }
  StepMemory bad_utf8{bytes};
  const auto name_pos = bad_utf8.bytes.find(u8"Peça única");
  CHECK(name_pos != std::string::npos);
  bad_utf8.bytes[name_pos] = static_cast<char>(0xff);
  CHECK(reject(bad_utf8, OCC_READ_FORMAT));
  StepMemory large_label{bytes};
  large_label.bytes.replace(large_label.bytes.find("#1"), 2,
                            "#99999999999999999999");
  CHECK(reject(large_label, OCC_READ_LIMIT));
  StepMemory duplicate{bytes};
  const auto data_end = duplicate.bytes.rfind("ENDSEC;");
  CHECK(data_end != std::string::npos);
  duplicate.bytes.insert(data_end, "#1=CARTESIAN_POINT('',(0.,0.,0.));\n");
  CHECK(reject(duplicate, OCC_READ_FORMAT));
  StepMemory invalid{bytes};
  const auto point = invalid.bytes.find("CARTESIAN_POINT");
  CHECK(point != std::string::npos);
  invalid.bytes.replace(point, std::strlen("CARTESIAN_POINT"), "BOGUS_ENTITY");
  CHECK(reject(invalid, OCC_READ_FORMAT));
  for (int mode : {1, 2, 3, 4, 5, 6, 7}) {
    StepMemory m{bytes};
    m.mode = mode;
    CHECK(reject(m, mode == 2                ? OCC_READ_TRUNCATED
                    : mode == 3 || mode == 7 ? OCC_READ_CANCELLED
                                             : OCC_READ_SOURCE));
    if (mode == 1)
      CHECK(r.native_result.error_domain == 77 &&
            r.native_result.error_code == 123);
    if (mode == 3)
      CHECK(!m.reads);
  }
  for (int constraint = 0; constraint < 5; ++constraint) {
    auto saved = limits;
    if (constraint == 0)
      limits.max_input_bytes = bytes.size() - 1;
    if (constraint == 1)
      limits.max_read_bytes = bytes.size() - 1;
    if (constraint == 2)
      limits.max_tokens = 10;
    if (constraint == 3)
      limits.max_topology = 10;
    if (constraint == 4)
      limits.max_token_bytes = 3;
    StepMemory m{bytes};
    CHECK(reject(m, OCC_READ_LIMIT));
    limits = saved;
  }
  for (int fault_point : {1, 2, 3, 4, 5})
    for (int kind : {0, 1, 2}) {
      source_fault = fault_point;
      source_fault_kind = kind;
      StepMemory m{bytes};
      CHECK(
          reject(m, fault_point == 3 ? OCC_READ_PUBLICATION : OCC_READ_FORMAT));
    }
  for (Fault f :
       {Fault::shape_insert, Fault::registry_reserve, Fault::fingerprint}) {
    fault = f;
    fault_insertion = 1;
    StepMemory m{bytes};
    CHECK(reject(m, f == Fault::fingerprint ? OCC_READ_FORMAT
                                            : OCC_READ_PUBLICATION));
  }
  for (int output_mode : {0, 1, 2, 3}) {
    auto saved = buffers;
    if (output_mode == 0)
      buffers.name_utf8 = nullptr;
    if (output_mode == 1)
      buffers.name_capacity = 1;
    if (output_mode == 2)
      buffers.unit_capacity = 1;
    if (output_mode == 3)
      buffers.unit_utf8 = name;
    StepMemory m{bytes};
    CHECK(run(m) == OCC_READ_INVALID && shapes.size() == baseline);
    CHECK(!r.native_result.published);
    buffers = saved;
  }
  CHECK(flcad_occ_destroy_shape(prior, error, sizeof(error)) == 1);
  CHECK(shapes.empty() && meshes.size() == mesh_baseline);
  std::cout << "STEP source atomic contract passed\n";
}
