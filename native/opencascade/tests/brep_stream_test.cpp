#include "../src/flcad_occ_api.cpp"
#include <BRepBndLib.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <Bnd_Box.hxx>
#include <filesystem>
#include <iostream>
#include <set>
#include <thread>
#define CHECK(x)                                                               \
  do {                                                                         \
    if (!(x)) {                                                                \
      std::cerr << "FAIL " << __LINE__ << ": " << #x << "\n";                  \
      return 1;                                                                \
    }                                                                          \
  } while (false)
struct Sink {
  std::string bytes;
  size_t calls = 0, stop = 0;
  int mode = 0;
  bool thread_ok = true, reentry_ok = false;
  std::thread::id thread = std::this_thread::get_id();
};
int32_t OCC_STREAM_CALL consume(void *ctx, const uint8_t *p, uint32_t n,
                                uint32_t *accepted) {
  if (!ctx) {
    *accepted = n;
    return 0;
  }
  auto &s = *static_cast<Sink *>(ctx);
  ++s.calls;
  s.thread_ok &= s.thread == std::this_thread::get_id() && n <= 64000;
  if (s.mode == 8) {
    occ_stream_sink_v1 nested{sizeof(nested), 1, nullptr, consume};
    occ_stream_result_v1 r{};
    s.reentry_ok = flcad_occ_brep_stream_v1("large", UINT64_MAX, &nested, &r,
                                            sizeof(r)) == OCC_STREAM_INVALID &&
                   r.bytes_accepted == 0;
  }
  if (s.calls == s.stop) {
    if (s.mode >= 4 && s.mode <= 6) {
      *accepted = n / 2;
      s.bytes.append(reinterpret_cast<const char *>(p), *accepted);
      if (s.mode == 5)
        throw Standard_Failure("consumer OCCT");
      if (s.mode == 6)
        throw 42;
      throw std::runtime_error("consumer standard");
    }
    *accepted = s.mode == 1 || s.mode == 7 ? n / 2 : s.mode == 2 ? n + 1 : 0;
    if (*accepted <= n)
      s.bytes.append(reinterpret_cast<const char *>(p), *accepted);
    return s.mode == 3 ? -1 : s.mode == 1 ? 0 : 73;
  }
  *accepted = n;
  s.bytes.append(reinterpret_cast<const char *>(p), n);
  return 0;
}
std::set<std::filesystem::path> inventory() {
  std::set<std::filesystem::path> r;
  for (auto &e : std::filesystem::recursive_directory_iterator(
           std::filesystem::current_path()))
    r.insert(e.path());
  return r;
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
  const auto before = inventory();
  auto box = BRepPrimAPI_MakeBox(1, 2, 3).Shape(),
       sphere = BRepPrimAPI_MakeSphere(4).Shape();
  TopoDS_Compound compound;
  BRep_Builder builder;
  builder.MakeCompound(compound);
  for (int i = 0; i < 100; ++i) {
    gp_Trsf t;
    t.SetTranslation(gp_Vec(i * 3, 0, 0));
    builder.Add(compound, BRepBuilderAPI_Transform(box, t, true).Shape());
  }
  auto triangulated = BRepPrimAPI_MakeSphere(5).Shape();
  BRepMesh_IncrementalMesh mesh(triangulated, .1, false, .5, false);
  for (TopExp_Explorer ex(triangulated, TopAbs_FACE); ex.More(); ex.Next()) {
    TopLoc_Location loc;
    auto tri = BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), loc);
    CHECK(!tri.IsNull());
    tri->ComputeNormals();
    CHECK(tri->HasNormals());
  }
  shapes.emplace("triangulated", triangulated);
  shapes.emplace("box", box);
  shapes.emplace("sphere", sphere);
  shapes.emplace("large", compound);
  const auto tokens = shapes.size();
  const auto seq = sequence.load();
  const auto fp = fingerprint(compound);
  occ_stream_result_v1 r{};
  auto run = [&](const char *id, Sink &s, uint64_t max = UINT64_MAX) {
    occ_stream_sink_v1 sink{sizeof(sink), 1, &s, consume};
    return flcad_occ_brep_stream_v1(id, max, &sink, &r, sizeof(r));
  };
  CHECK(flcad_occ_brep_stream_version() == 1);
  Sink all;
  CHECK(run("large", all) == OCC_STREAM_OK);
  CHECK(all.calls >= 3 && all.thread_ok &&
        r.bytes_accepted == all.bytes.size());
  CHECK(all.bytes.find("CASCADE Topology V3") != std::string::npos &&
        r.triangles == 0);
  for (size_t stop : {size_t(1), all.calls / 2, all.calls})
    for (int mode = 0; mode <= 7; ++mode) {
      Sink s;
      s.stop = stop;
      s.mode = mode;
      CHECK(run("large", s) ==
            (mode == 3 ? OCC_STREAM_CANCELLED : OCC_STREAM_SINK));
      CHECK(s.calls == stop);
      if (mode >= 4 && mode <= 6)
        CHECK(!r.accepted_count_valid && r.bytes_accepted < s.bytes.size());
      else if (mode == 2)
        CHECK(!r.accepted_count_valid);
      else
        CHECK(r.accepted_count_valid && r.bytes_accepted == s.bytes.size());
      if (mode == 0 || mode == 7)
        CHECK(r.consumer_code == 73);
      CHECK(shapes.size() == tokens && meshes.empty() &&
            sequence.load() == seq && BRepCheck_Analyzer(compound).IsValid());
    }
  for (int point : {1, 2, 3, 4, 5})
    for (int kind : {0, 1, 2}) {
      brep_fault_point = point;
      brep_fault_kind = kind;
      Sink s;
      CHECK(run("large", s) == OCC_STREAM_SERIALIZATION);
      CHECK(r.bytes_accepted == s.bytes.size() && r.accepted_count_valid &&
            r.message[0]);
      if (point <= 2)
        CHECK(s.calls == 0);
      if (point == 3)
        CHECK(s.calls == 1);
    }
  Sink nested;
  nested.mode = 8;
  CHECK(run("large", nested) == 0 && nested.reentry_ok);
  Sink missing;
  CHECK(run("absent", missing) == OCC_STREAM_SHAPE && missing.calls == 0);
  Sink budget;
  CHECK(run("large", budget, 1) == OCC_STREAM_LIMIT && budget.calls == 0);
  occ_stream_sink_v1 sink{sizeof(sink), 1, nullptr, consume};
  CHECK(flcad_occ_brep_stream_v1("box", UINT64_MAX, &sink, &r, sizeof(r)) == 0);
  sink.write = nullptr;
  CHECK(flcad_occ_brep_stream_v1("box", UINT64_MAX, &sink, &r, sizeof(r)) ==
        OCC_STREAM_INVALID);
  CHECK(flcad_occ_brep_stream_v1("box", UINT64_MAX, nullptr, &r, sizeof(r)) ==
        OCC_STREAM_INVALID);
  sink.write = consume;
  sink.version = 2;
  CHECK(flcad_occ_brep_stream_v1("box", UINT64_MAX, &sink, &r, sizeof(r)) ==
        OCC_STREAM_INVALID);
  sink.version = 1;
  CHECK(flcad_occ_brep_stream_v1("box", 0, &sink, &r, sizeof(r)) ==
        OCC_STREAM_INVALID);
  CHECK(flcad_occ_brep_stream_v1("box", UINT64_MAX, &sink, nullptr,
                                 sizeof(r)) == OCC_STREAM_INVALID);
  CHECK(flcad_occ_brep_stream_v1("box", UINT64_MAX, &sink, &r, sizeof(r) - 1) ==
        OCC_STREAM_INVALID);
  // Direct streambuf contract checks without a whole shape or giant allocation.
  r = {};
  r.accepted_count_valid = 1;
  Sink direct;
  occ_stream_sink_v1 ds{sizeof(ds), 1, &direct, consume};
  {
    BrepSinkBuffer buf(ds, r, 2);
    CHECK(buf.sputc('a') == 'a');
    CHECK(buf.sputn("b", 1) == 1);
    CHECK(buf.pubsync() == 0);
    CHECK(buf.sputc('c') == std::char_traits<char>::eof());
    CHECK(buf.pubsync() == -1);
  }
  CHECK(r.status == OCC_STREAM_LIMIT && r.bytes_accepted == 2 &&
        direct.calls == 1);
  r = {};
  r.accepted_count_valid = 1;
  Sink huge;
  occ_stream_sink_v1 hs{sizeof(hs), 1, &huge, consume};
  {
    BrepSinkBuffer buf(hs, r, UINT64_MAX);
    buf.seed_generated_for_test(UINT64_MAX - 1);
    CHECK(buf.sputn("ab", 2) == 0);
  }
  CHECK(r.status == OCC_STREAM_LIMIT && r.bytes_accepted == 0 &&
        huge.calls == 0);
  for (int i = 0; i < 20; ++i) {
    Sink s;
    CHECK(run("large", s) == 0 && s.bytes == all.bytes);
  }
  CHECK(fingerprint(compound) == fp && shapes.size() == tokens &&
        meshes.empty() && sequence.load() == seq);
  CHECK(inventory() == before);
  // Test-only materialization for the unmodified productive pathname restore.
  const auto dir =
      std::filesystem::temp_directory_path() /
      ("occ-brep-roundtrip-" +
       std::to_string(
           std::chrono::steady_clock::now().time_since_epoch().count()));
  CHECK(std::filesystem::create_directory(dir));
  char token[256] = {}, finger[256] = {}, type[64] = {}, error[4096] = {};
  for (const char *id : {"box", "sphere", "large", "triangulated"}) {
    auto original = get(id);
    Sink first;
    CHECK(run(id, first) == 0);
    const auto payload = dir / (std::string(id) + ".brep");
    {
      std::ofstream file(payload, std::ios::binary);
      file.write(first.bytes.data(), first.bytes.size());
      CHECK(file.good());
    }
    CHECK(flcad_occ_import_shape(payload.string().c_str(), "brep", token,
                                 sizeof(token), finger, sizeof(finger), type,
                                 sizeof(type), error, sizeof(error)) == 1);
    auto restored = get(token);
    CHECK(equivalent(original, restored));
    CHECK(same_numbers(triangulations(original), triangulations(restored)));
    Sink second;
    CHECK(run(token, second) == 0);
    CHECK(flcad_occ_destroy_shape(token, error, sizeof(error)) == 1);
    {
      std::ofstream file(payload, std::ios::binary);
      file.write(second.bytes.data(), second.bytes.size());
      CHECK(file.good());
    }
    CHECK(flcad_occ_import_shape(payload.string().c_str(), "brep", token,
                                 sizeof(token), finger, sizeof(finger), type,
                                 sizeof(type), error, sizeof(error)) == 1);
    CHECK(equivalent(original, get(token)));
    // An operation after reopen remains valid.
    gp_Trsf move;
    move.SetTranslation(gp_Vec(1, 2, 3));
    auto moved = BRepBuilderAPI_Transform(get(token), move, true).Shape();
    CHECK(BRepCheck_Analyzer(moved).IsValid());
    CHECK(std::abs(signature(moved)[7] - (signature(get(token))[7] + 1)) <
          1e-7);
    const auto legacy = dir / (std::string(id) + "-legacy.brep");
    CHECK(flcad_occ_export_shape(token, legacy.string().c_str(), "brep", error,
                                 sizeof(error)) == 1);
    CHECK(flcad_occ_destroy_shape(token, error, sizeof(error)) == 1);
    CHECK(flcad_occ_import_shape(legacy.string().c_str(), "brep", token,
                                 sizeof(token), finger, sizeof(finger), type,
                                 sizeof(type), error, sizeof(error)) == 1);
    CHECK(equivalent(original, get(token)));
    Sink imported;
    CHECK(run(token, imported) == 0);
    CHECK(flcad_occ_destroy_shape(token, error, sizeof(error)) == 1);
  }
  std::filesystem::remove_all(dir);
  CHECK(shapes.size() == tokens && meshes.empty());
  shapes.clear();
  std::cout << "PASS BREP 24 sink failures, 15 injected exceptions, 20 "
               "repeats, box/sphere/compound/imported roundtrips\n";
}
