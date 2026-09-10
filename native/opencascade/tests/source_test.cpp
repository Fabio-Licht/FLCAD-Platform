#include "../src/flcad_occ_api.cpp"
#include <BRepBndLib.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <Bnd_Box.hxx>
#include <filesystem>
#include <iostream>
#include <set>
#define CHECK(x)                                                               \
  do {                                                                         \
    if (!(x)) {                                                                \
      std::cerr << "FAIL " << __LINE__ << ": " << #x << " status=" << r.status \
                << " message=" << r.message << "\n";                           \
      return 1;                                                                \
    }                                                                          \
  } while (false)
struct Memory {
  std::string bytes;
  uint32_t chunk = 65536;
  size_t reads = 0, checks = 0, stop = 0;
  int mode = 0, cancel_phase = -1;
  bool failed = false, after_failure = false, reentry = false, nested_ok = true;
  std::thread::id thread = std::this_thread::get_id();
  uint64_t provided = 0;
};
struct MeshOutput {
  std::string bytes;
  int mode = 0;
  size_t fail_call = 1;
  size_t calls = 0;
  bool failed = false, after_failure = false;
};
int32_t OCC_STREAM_CALL mesh_sink(void *p, const uint8_t *bytes, uint32_t n,
                                  uint32_t *accepted) {
  auto &out = *static_cast<MeshOutput *>(p);
  ++out.calls;
  out.after_failure |= out.failed;
  if (out.failed) {
    *accepted = 0;
    return 1;
  }
  if (out.mode != 0 && out.calls == out.fail_call) {
    if (out.mode == 1) {
      *accepted = n - 1;
      out.failed = true;
      return 0;
    }
    if (out.mode == 2) {
      *accepted = 0;
      out.failed = true;
      return -1;
    }
    if (out.mode == 3) {
      *accepted = n + 1;
      out.failed = true;
      return 0;
    }
    *accepted = n - 1;
    out.failed = true;
    return 17;
  }
  out.bytes.append(reinterpret_cast<const char *>(bytes), n);
  *accepted = n;
  return 0;
}
occ_read_limits_v1 defaults() {
  occ_read_limits_v1 l{};
  flcad_occ_source_default_limits_v1(&l, sizeof(l));
  return l;
}
int32_t OCC_STREAM_CALL memory_check(void *p, uint32_t phase,
                                     occ_source_io_v1 *io) {
  auto &m = *static_cast<Memory *>(p);
  ++m.checks;
  if (m.failed)
    m.after_failure = true;
  if (m.thread != std::this_thread::get_id())
    return 90;
  if (m.cancel_phase == static_cast<int>(phase)) {
    m.failed = true;
    io->error_domain = 9;
    io->error_code = 55;
    return -1;
  }
  if (phase == 1 && m.mode == 10) {
    m.failed = true;
    io->error_domain = 8;
    io->error_code = 66;
    return 66;
  }
  return 0;
}
int32_t OCC_STREAM_CALL memory_read(void *p, uint64_t off, uint8_t *dest,
                                    uint32_t n, occ_source_io_v1 *io) {
  auto &m = *static_cast<Memory *>(p);
  if (m.thread != std::this_thread::get_id())
    return 90;
  ++m.reads;
  if (m.failed)
    m.after_failure = true;
  if (m.reentry) {
    occ_source_v1 s{sizeof(s),      1,           &m,
                    m.bytes.size(), memory_read, memory_check};
    auto l = defaults();
    occ_read_result_v1 out{};
    m.nested_ok &=
        flcad_occ_stl_read_v1(&s, &l, &out, sizeof(out)) == OCC_READ_INVALID;
  }
  n = static_cast<uint32_t>(std::min<uint64_t>(
      std::min(n, m.chunk), off < m.bytes.size() ? m.bytes.size() - off : 0));
  if (m.stop == m.reads) {
    m.failed = true;
    if (m.mode == 1) {
      io->bytes_read = 0;
      return 0;
    }
    if (m.mode == 2) {
      io->bytes_read = 65537;
      return 0;
    }
    if (m.mode >= 4 && m.mode <= 6) {
      if (m.mode == 4)
        throw std::runtime_error("source error");
      if (m.mode == 5)
        throw Standard_Failure("source OCCT error");
      throw 42;
    }
    if (m.mode == 7) {
      io->flags = 3;
      n /= 2;
    } else if (m.mode == 8) {
      io->flags = 0;
      return 2;
    } else {
      n /= 2;
      std::memcpy(dest, m.bytes.data() + off, n);
      io->bytes_read = n;
      m.provided += n;
      io->error_domain = 7;
      io->error_code = 42;
      return m.mode == 3 ? -1 : 42;
    }
  }
  std::memcpy(dest, m.bytes.data() + off, n);
  io->bytes_read = n;
  m.provided += n;
  return 0;
}
std::string brep_bytes(const TopoDS_Shape &s, TopTools_FormatVersion v) {
  std::ostringstream out;
  out.imbue(std::locale::classic());
  BRepTools::Write(s, out, true, true, v);
  return out.str();
}
std::string binary_stl(uint32_t count = 2) {
  std::string s(84 + 50 * count, '\0');
  std::memcpy(s.data(), "solid binary", 12);
  stream_u32(reinterpret_cast<uint8_t *>(s.data() + 80), count);
  for (uint32_t i = 0; i < count; ++i) {
    double v[] = {0, 0, 1,         double(i), 0, 0, double(i) + 1,
                  0, 0, double(i), 1,         0};
    for (int j = 0; j < 12; ++j)
      stream_float(reinterpret_cast<uint8_t *>(s.data() + 84 + i * 50 + j * 4),
                   v[j]);
  }
  return s;
}
const std::string ascii =
    "solid sample\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 "
    "0\nvertex 0 1 0\nendloop\nendfacet\nendsolid sample\n";
std::set<std::filesystem::path> inventory() {
  std::set<std::filesystem::path> s;
  for (auto &e : std::filesystem::recursive_directory_iterator(
           std::filesystem::current_path()))
    s.insert(e.path());
  return s;
}
std::vector<double> signature(const TopoDS_Shape &s) {
  std::vector<double> v{double(s.ShapeType())};
  for (auto type : {TopAbs_SOLID, TopAbs_SHELL, TopAbs_FACE, TopAbs_WIRE,
                    TopAbs_EDGE, TopAbs_VERTEX}) {
    TopTools_IndexedMapOfShape map;
    TopExp::MapShapes(s, type, map);
    v.push_back(map.Extent());
  }
  Bnd_Box box;
  BRepBndLib::AddOptimal(s, box, false, false);
  double a, b, c, d, e, f;
  box.Get(a, b, c, d, e, f);
  for (double n : {a, b, c, d, e, f})
    v.push_back(n);
  GProp_GProps area, volume;
  BRepGProp::SurfaceProperties(s, area);
  BRepGProp::VolumeProperties(s, volume);
  v.push_back(area.Mass());
  v.push_back(volume.Mass());
  for (auto p : {area.CentreOfMass(), volume.CentreOfMass()})
    for (double n : {p.X(), p.Y(), p.Z()})
      v.push_back(n);
  return v;
}
bool equivalent(const TopoDS_Shape &a, const TopoDS_Shape &b) {
  auto x = signature(a), y = signature(b);
  if (x.size() != y.size())
    return false;
  for (size_t i = 0; i < x.size(); ++i)
    if (!std::isfinite(x[i]) || !std::isfinite(y[i]) ||
        std::abs(x[i] - y[i]) > 1e-8 * std::max(1., std::abs(x[i])))
      return false;
  return BRepCheck_Analyzer(b).IsValid();
}
std::vector<double> triangulations(const TopoDS_Shape &shape) {
  std::vector<double> result;
  for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
    TopLoc_Location loc;
    auto tri = BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), loc);
    if (tri.IsNull())
      continue;
    result.push_back(tri->NbNodes());
    result.push_back(tri->NbTriangles());
    result.push_back(tri->HasNormals());
    for (int i = 0; i < tri->NbNodes(); ++i) {
      auto p = tri->Node(i + 1);
      result.insert(result.end(), {p.X(), p.Y(), p.Z()});
      if (tri->HasNormals()) {
        auto n = tri->Normal(i + 1);
        result.insert(result.end(), {n.X(), n.Y(), n.Z()});
      }
    }
  }
  return result;
}
bool same_numbers(const std::vector<double> &a, const std::vector<double> &b) {
  if (a.size() != b.size())
    return false;
  for (size_t i = 0; i < a.size(); ++i)
    if (!std::isfinite(a[i]) || !std::isfinite(b[i]) ||
        std::abs(a[i] - b[i]) > 1e-7 * std::max(1., std::abs(a[i])))
      return false;
  return true;
}

int main() {
  occ_read_result_v1 r{};
  auto l = defaults();
  const auto before = inventory();
  char error[4096] = {};
  auto run = [&](Memory &m, bool brep = false) {
    occ_source_v1 s{sizeof(s),      1,           &m,
                    m.bytes.size(), memory_read, memory_check};
    return brep ? flcad_occ_brep_read_v1(&s, &l, &r, sizeof(r))
                : flcad_occ_stl_read_v1(&s, &l, &r, sizeof(r));
  };
  auto clean = [&]() {
    return r.resource_kind == 1
               ? flcad_occ_destroy_shape(r.token, error, sizeof(error))
               : flcad_occ_destroy_mesh(r.token, error, sizeof(error));
  };
  CHECK(flcad_occ_source_version() == 1);
  for (auto data : {ascii, binary_stl()}) {
    Memory m{data};
    CHECK(run(m) == 0 && r.published && r.resource_kind == 2 &&
          r.bytes_provided == m.provided);
    for (int mode : {0, 1, 2}) {
      MeshOutput output;
      output.mode = mode;
      occ_stream_sink_v1 sink{sizeof(sink), 1, &output, mesh_sink};
      occ_stream_result_v1 streamed{};
      const auto status = flcad_occ_triangulation_stream_v1(
          r.token, UINT32_MAX, &sink, &streamed, sizeof(streamed));
      CHECK(status == (mode == 0   ? OCC_STREAM_OK
                       : mode == 2 ? OCC_STREAM_CANCELLED
                                   : OCC_STREAM_SINK));
      CHECK(!output.after_failure && output.calls == 1);
      if (mode == 0)
        CHECK(output.bytes.size() == 84 + streamed.triangles * 50);
    }
    MeshOutput rejected;
    occ_stream_sink_v1 sink{sizeof(sink), 1, &rejected, mesh_sink};
    occ_stream_result_v1 streamed{};
    CHECK(flcad_occ_triangulation_stream_v1(
              "missing", UINT32_MAX, &sink, &streamed, sizeof(streamed)) ==
              OCC_STREAM_SHAPE &&
          rejected.calls == 0);
    CHECK(flcad_occ_triangulation_stream_v1(
              r.token, 1, &sink, &streamed, sizeof(streamed)) ==
              (r.triangles > 1 ? OCC_STREAM_LIMIT : OCC_STREAM_OK));
    CHECK(clean() == 1);
    CHECK(clean() == 0);
  }
  {
    Memory large{binary_stl(2000)};
    CHECK(run(large) == 0 && r.triangles == 2000);
    MeshOutput full;
    occ_stream_sink_v1 sink{sizeof(sink), 1, &full, mesh_sink};
    occ_stream_result_v1 streamed{};
    CHECK(flcad_occ_triangulation_stream_v1(
              r.token, UINT32_MAX, &sink, &streamed, sizeof(streamed)) == 0 &&
          full.calls > 1 && full.bytes.size() == 84 + 2000 * 50);
    for (int mode : {1, 2, 3, 4}) {
      MeshOutput failed;
      failed.mode = mode;
      failed.fail_call = 2;
      sink.context = &failed;
      CHECK(flcad_occ_triangulation_stream_v1(
                r.token, UINT32_MAX, &sink, &streamed, sizeof(streamed)) ==
                (mode == 2 ? OCC_STREAM_CANCELLED : OCC_STREAM_SINK) &&
            failed.calls == 2 && !failed.after_failure);
    }
    MeshOutput untouched;
    occ_stream_sink_v1 invalid{sizeof(invalid), 2, &untouched, mesh_sink};
    CHECK(flcad_occ_triangulation_stream_v1(
              r.token, UINT32_MAX, &invalid, &streamed, sizeof(streamed)) ==
              OCC_STREAM_INVALID &&
          untouched.calls == 0);
    CHECK(flcad_occ_triangulation_stream_v1(
              r.token, UINT32_MAX, nullptr, &streamed, sizeof(streamed)) ==
          OCC_STREAM_INVALID);
    CHECK(clean() == 1);
  }
  auto whitespace = ascii;
  for (size_t pos = 0; (pos = whitespace.find('\n', pos)) != std::string::npos;
       pos += 4)
    whitespace.replace(pos, 1, "\r\n\r\n");
  Memory leading{" \r\n\t\n" + whitespace};
  CHECK(run(leading) == 0 && clean() == 1);
  auto legacy_binary = binary_stl();
  legacy_binary.replace(0, 5, "bytes");
  auto collapsed = legacy_binary;
  for (int k = 0; k < 3; ++k)
    std::memcpy(collapsed.data() + 84 + 50 + 24 + k * 4,
                collapsed.data() + 84 + 50 + 12 + k * 4, 4);
  for (auto bytes : {ascii, legacy_binary, collapsed}) {
    std::istringstream old_input(bytes, std::ios::in | std::ios::binary);
    auto legacy = RWStl::ReadStream(old_input);
    CHECK(!legacy.IsNull());
    Memory m{bytes};
    CHECK(run(m) == 0);
    auto actual = meshes.at(r.token);
    CHECK(actual->NbNodes() == legacy->NbNodes() &&
          actual->NbTriangles() == legacy->NbTriangles());
    for (int i = 1; i <= actual->NbNodes(); ++i)
      CHECK(actual->Node(i).Distance(legacy->Node(i)) < 1e-12);
    for (int i = 1; i <= actual->NbTriangles(); ++i) {
      int a, b, c, x, y, z;
      actual->Triangle(i).Get(a, b, c);
      legacy->Triangle(i).Get(x, y, z);
      CHECK(a == x && b == y && c == z);
    }
    CHECK(clean() == 1);
  }
  for (const char *number : {"+-1", "++1", "-+1"}) {
    auto text = ascii;
    text.replace(text.find("vertex 0") + 7, 1, number);
    Memory m{text};
    CHECK(run(m) == OCC_READ_FORMAT && !r.published);
  }
  auto box = BRepPrimAPI_MakeBox(1, 2, 3).Shape(),
       sphere = BRepPrimAPI_MakeSphere(3).Shape();
  TopoDS_Compound compound;
  BRep_Builder b;
  b.MakeCompound(compound);
  b.Add(compound, box);
  b.Add(compound, sphere);
  BRepMesh_IncrementalMesh mesher(sphere, .1, false, .5, false);
  for (TopExp_Explorer ex(sphere, TopAbs_FACE); ex.More(); ex.Next()) {
    TopLoc_Location loc;
    auto t = BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), loc);
    t->ComputeNormals();
  }
  for (auto shape : {box, sphere, TopoDS_Shape(compound)})
    for (auto version :
         {TopTools_FormatVersion_VERSION_1, TopTools_FormatVersion_VERSION_2,
          TopTools_FormatVersion_VERSION_3}) {
      Memory m{brep_bytes(shape, version)};
      m.chunk = 137;
      CHECK(run(m, true) == 0 && r.published &&
            BRepCheck_Analyzer(get(r.token)).IsValid());
      auto restored = get(r.token);
      CHECK(equivalent(shape, restored));
      if (version == TopTools_FormatVersion_VERSION_3)
        CHECK(same_numbers(triangulations(shape), triangulations(restored)));
      char moved[64]{}, fp[64]{}, type[32]{};
      const double matrix[] = {1, 0, 0, 10, 0, 1, 0, 20,
                               0, 0, 1, 30, 0, 0, 0, 1};
      CHECK(flcad_occ_transform_shape(r.token, matrix, 1, moved, sizeof(moved),
                                      fp, sizeof(fp), type, sizeof(type), error,
                                      sizeof(error)) == 1);
      gp_Trsf tr;
      tr.SetTranslation(gp_Vec(10, 20, 30));
      CHECK(equivalent(BRepBuilderAPI_Transform(restored, tr, true).Shape(),
                       get(moved)));
      CHECK(flcad_occ_destroy_shape(moved, error, sizeof(error)) == 1);
      CHECK(clean() == 1);
      Memory second{brep_bytes(restored, version)};
      CHECK(run(second, true) == 0 && equivalent(shape, get(r.token)));
      CHECK(clean() == 1);
    }
  // Direct streambuf seeks, putback and transport accounting.
  {
    Memory m{"abcdef"};
    m.chunk = 2;
    occ_source_v1 src{sizeof(src),    1,           &m,
                      m.bytes.size(), memory_read, memory_check};
    r = {};
    r.count_valid = 1;
    SourceInput input(src, l, r);
    std::istream stream(&input);
    char c;
    stream.get(c);
    CHECK(c == 'a');
    stream.unget();
    stream.get(c);
    CHECK(c == 'a');
    stream.seekg(-1, std::ios::end);
    stream.get(c);
    CHECK(c == 'f');
    stream.seekg(0);
    std::string text;
    std::getline(stream, text);
    CHECK(text == "abcdef" && r.bytes_provided == m.provided);
    input.finish();
  }
  for (int scenario = 0; scenario < 5; ++scenario) {
    Memory m{"abcdef"};
    m.chunk = 2;
    occ_source_v1 src{sizeof(src),    1,           &m,
                      m.bytes.size(), memory_read, memory_check};
    r = {};
    r.count_valid = 1;
    SourceInput input(src, l, r);
    std::istream st(&input);
    char c;
    st.get(c);
    st.get(c);
    st.get(c);
    st.unget();
    st.unget();
    st.get(c);
    CHECK(c == 'b' && input.position() == 2);
    CHECK(st.tellg() == std::streampos(2));
    st.seekg(1, std::ios::cur);
    st.get(c);
    CHECK(c == 'd');
    if (scenario == 0) {
      input.finish();
      continue;
    }
    if (scenario == 1)
      st.seekg(-7, std::ios::beg);
    if (scenario == 2)
      st.seekg(7, std::ios::beg);
    if (scenario == 3)
      st.putback('X');
    if (scenario == 4) {
      st.seekg(0);
      st.unget();
    }
    CHECK(st.fail() && input.failed() && r.status == OCC_READ_INVALID);
    const auto calls = m.reads + m.checks;
    st.clear();
    st.get(c);
    CHECK(st.fail() && calls == m.reads + m.checks);
  }
  for (auto data : {ascii, binary_stl(2000),
                    brep_bytes(compound, TopTools_FormatVersion_VERSION_3)}) {
    const bool is_brep = data.find("CASCADE") != std::string::npos;
    Memory good{data};
    good.chunk = 64;
    CHECK(run(good, is_brep) == 0);
    const auto reads = good.reads;
    CHECK(clean() == 1);
    for (size_t stop : {size_t(1), (reads + 1) / 2, reads})
      for (int mode = 0; mode <= 8; ++mode) {
        if (mode == 7 && stop == reads)
          continue;
        Memory bad{data};
        bad.chunk = 64;
        bad.stop = stop;
        bad.mode = mode;
        const auto expected = mode == 3                  ? OCC_READ_CANCELLED
                              : (mode == 1 || mode == 7) ? OCC_READ_TRUNCATED
                                                         : OCC_READ_SOURCE;
        CHECK(run(bad, is_brep) == expected && !r.published && !r.token[0]);
        CHECK(r.bytes_provided == bad.provided);
        CHECK(r.count_valid ==
              (mode != 2 && mode != 4 && mode != 5 && mode != 6 && mode != 8));
        CHECK(!bad.after_failure && bad.reads == stop && shapes.empty() &&
              meshes.empty());
        if (mode == 0)
          CHECK(r.error_code == 42 && r.error_domain == 7);
        if (mode == 3)
          CHECK(r.status == OCC_READ_CANCELLED);
      }
    for (int phase : {0, 1}) {
      Memory m{data};
      m.cancel_phase = phase;
      CHECK(run(m, is_brep) == OCC_READ_CANCELLED && !r.published &&
            !m.after_failure);
    }
    Memory mutated{data};
    mutated.mode = 10;
    CHECK(run(mutated, is_brep) == OCC_READ_SOURCE &&
          r.phase == OCC_READ_VERIFY && !r.published);
  }
  Memory re{ascii};
  re.reentry = true;
  CHECK(run(re) == 0 && re.nested_ok);
  CHECK(clean() == 1);
  std::vector<std::string> invalid{ascii + "garbage", ascii + ascii,
                                   binary_stl() + "x", "solid x\n",
                                   binary_stl(1).substr(0, 90)};
  auto nan = binary_stl();
  stream_u32(reinterpret_cast<uint8_t *>(nan.data() + 84), 0x7fc00000);
  invalid.push_back(nan);
  auto inf = ascii;
  inf.replace(inf.find("vertex 0"), 8, "vertex inf");
  invalid.push_back(inf);
  auto huge = binary_stl();
  stream_u32(reinterpret_cast<uint8_t *>(huge.data() + 80), UINT32_MAX);
  invalid.push_back(huge);
  for (auto &data : invalid) {
    Memory m{data};
    CHECK(run(m) != 0 && shapes.empty() && meshes.empty() && !r.published);
  }
  const auto bin = binary_stl();
  for (size_t cut :
       {size_t(1), size_t(79), size_t(83), size_t(84), bin.size() - 1}) {
    Memory m{bin.substr(0, cut)};
    CHECK(run(m) != 0 && !r.published);
  }
  auto brep = brep_bytes(box, TopTools_FormatVersion_VERSION_3);
  for (size_t cut : {size_t(1), brep.size() / 2, brep.size() - 8}) {
    Memory m{brep.substr(0, cut)};
    CHECK(run(m, true) != 0 && !r.published);
  }
  // Truncation at every line boundary before the root record, plus token tails.
  for (size_t cut = 1; cut + 16 < brep.size(); ++cut) {
    if (brep[cut - 1] != '\n')
      continue;
    Memory truncated{brep.substr(0, cut)};
    CHECK(run(truncated, true) != 0 && !r.published && shapes.empty());
  }
  for (size_t tail = 1; tail < 16; ++tail) {
    Memory truncated{brep.substr(0, brep.size() - tail)};
    CHECK(run(truncated, true) != 0 && !r.published && shapes.empty());
  }
  Memory trailing{brep + "garbage"};
  CHECK(run(trailing, true) != 0 && !r.published);
  for (int quota = 0; quota < 6; ++quota) {
    l = defaults();
    Memory m{ascii};
    if (quota == 0)
      l.max_input_bytes = 4;
    if (quota == 1)
      l.max_vertices = 2;
    if (quota == 2) {
      l.max_triangles = 1;
      m.bytes = binary_stl();
    }
    if (quota == 3)
      l.max_line_bytes = 4;
    if (quota == 4)
      l.max_token_bytes = 3;
    if (quota == 5)
      l.max_tokens = 5;
    CHECK(run(m) != 0 && !r.published && meshes.empty());
  }
  l = defaults();
  l.max_read_bytes = 1;
  Memory budget{ascii};
  CHECK(run(budget) == OCC_READ_LIMIT && budget.reads == 0 && !r.published);
  l = defaults();
  Memory m{ascii};
  occ_source_v1 src{sizeof(src),    1,           &m,
                    m.bytes.size(), memory_read, memory_check};
  CHECK(flcad_occ_stl_read_v1(&src, &l, nullptr, sizeof(r)) ==
        OCC_READ_INVALID);
  CHECK(flcad_occ_stl_read_v1(&src, &l, &r, sizeof(r) - 1) ==
            OCC_READ_INVALID &&
        m.reads == 0);
  for (int scenario = 0; scenario < 8; ++scenario) {
    auto invalid_source = src;
    auto invalid_limits = l;
    if (scenario == 0)
      invalid_source.read_at = nullptr;
    if (scenario == 1)
      invalid_source.check = nullptr;
    if (scenario == 2)
      invalid_source.version = 2;
    if (scenario == 3)
      invalid_source.size = 0;
    if (scenario == 4)
      invalid_source.length = UINT64_MAX;
    if (scenario == 5)
      invalid_limits.version = 2;
    if (scenario == 6)
      invalid_limits.max_vertices = UINT32_MAX;
    if (scenario == 7)
      invalid_limits.max_triangles = 0;
    CHECK(flcad_occ_stl_read_v1(&invalid_source, &invalid_limits, &r,
                                sizeof(r)) == OCC_READ_INVALID &&
          m.reads == 0 && !r.published);
  }
  alignas(occ_read_result_v1) std::array<char, sizeof(occ_read_result_v1)>
      overlap{};
  auto *over = reinterpret_cast<occ_source_v1 *>(overlap.data());
  *over = src;
  CHECK(flcad_occ_stl_read_v1(
            over, &l, reinterpret_cast<occ_read_result_v1 *>(overlap.data()),
            sizeof(r)) == OCC_READ_INVALID &&
        m.reads == 0);
  for (bool brep_mode : {false, true})
    for (int point : {1, 2, 3})
      for (int kind : {0, 1, 2}) {
        source_fault = point;
        source_fault_kind = kind;
        Memory x{brep_mode ? brep : ascii};
        CHECK(run(x, brep_mode) != 0 && !r.published && shapes.empty() &&
              meshes.empty());
      }
  for (bool brep_mode : {false, true})
    for (int kind : {0, 1, 2}) {
      fault = brep_mode ? Fault::shape_insert : Fault::mesh_insert;
      fault_exception = kind;
      Memory x{brep_mode ? brep : ascii};
      CHECK(run(x, brep_mode) == OCC_READ_PUBLICATION && !r.published &&
            shapes.empty() && meshes.empty());
    }
  for (int kind : {0, 1, 2}) {
    fault = Fault::fingerprint;
    fault_exception = kind;
    Memory x{brep};
    CHECK(run(x, true) == OCC_READ_FORMAT && !r.published && shapes.empty());
    for (bool is_brep : {false, true}) {
      fault = Fault::registry_reserve;
      fault_exception = kind;
      Memory y{is_brep ? brep : ascii};
      CHECK(run(y, is_brep) == OCC_READ_PUBLICATION && !r.published &&
            shapes.empty() && meshes.empty());
    }
  }
  for (int i = 0; i < 20; ++i) {
    Memory x{brep};
    CHECK(run(x, true) == 0);
    CHECK(clean() == 1);
    Memory y{binary_stl()};
    CHECK(run(y) == 0);
    CHECK(clean() == 1);
  }
  CHECK(shapes.empty() && meshes.empty() && inventory() == before);
  std::cout << "PASS source BREP V1-V3, strict STL, quotas, faults, atomicity, "
               "20 repeats\n";
}
