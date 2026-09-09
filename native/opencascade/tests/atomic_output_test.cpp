// Same translation unit gives tests access to actual registries and the actual
// batch publisher, without test exports or a simulated replacement registry.
#include "../src/flcad_occ_api.cpp"
#include <cstdio>
#include <filesystem>

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      std::fprintf(stderr, "FAIL line %d: %s (error: %s)\n", __LINE__,         \
                   #condition, error);                                         \
      return 1;                                                                \
    }                                                                          \
  } while (false)

int main() {
  char error[1024] = {}, t[256] = {}, fp[256] = {};
  int cases = 0;
  auto vertex = [&](char *out, size_t size) {
    return flcad_occ_create_vertex(1, 2, 3, out, size, fp, sizeof(fp), error,
                                   sizeof(error));
  };
  CHECK(flcad_occ_initialize(error, sizeof(error)) == 1);
  CHECK(vertex(nullptr, sizeof(t)) == 0 && shapes.empty());
  ++cases;
  CHECK(vertex(t, 0) == 0 && shapes.empty());
  ++cases;
  // Set a long monotonic sequence in this isolated test process only.
  sequence.store(1000000000000000000ULL);
  const auto required = std::string("occ-shape-1000000000000000000").size() + 1;
  std::strcpy(t, "unchanged");
  CHECK(vertex(t, required - 1) == 0 && shapes.empty());
  CHECK(std::strcmp(t, "unchanged") == 0);
  ++cases;
  CHECK(vertex(t, required) == 1 && std::strlen(t) + 1 == required);
  CHECK(shapes.count(t) == 1);
  ++cases;
  const std::string original = t;
  CHECK(original == "occ-shape-1000000000000000001");
  ++cases;
  const auto original_shape = get(original.c_str());
  // Output fields must remain wholly unchanged on preflight failure.
  std::strcpy(t, "unchanged");
  CHECK(flcad_occ_create_vertex(0, 0, 0, t, sizeof(t), fp, 1, error,
                                sizeof(error)) == 0);
  CHECK(std::strcmp(t, "unchanged") == 0 && shapes.size() == 1);
  ++cases;
  CHECK(flcad_occ_create_vertex(0, 0, 0, t, sizeof(t), t, sizeof(t), error,
                                sizeof(error)) == 0 &&
        shapes.size() == 1);
  ++cases;
  for (int kind : {0, 1, 2}) {
    fault = Fault::fingerprint;
    fault_exception = kind;
    CHECK(vertex(t, sizeof(t)) == 0 && shapes.size() == 1);
    CHECK(shapes.count(original) == 1);
    ++cases;
  }
  const auto before_failure = sequence.load();
  for (int kind : {0, 1, 2}) {
    fault = Fault::shape_insert;
    fault_exception = kind;
    const auto removed = compensated_entries;
    CHECK(vertex(t, sizeof(t)) == 0 && shapes.size() == 1);
    CHECK(compensated_entries == removed + 1);
    CHECK(shapes.count(original) == 1);
    ++cases;
  }
  CHECK(sequence.load() == before_failure + 3);
  ++cases;
  CHECK(vertex(t, sizeof(t)) == 1);
  CHECK(std::string(t) == "occ-shape-" + std::to_string(before_failure + 3));
  CHECK(flcad_occ_destroy_shape(t, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(t, error, sizeof(error)) == 0);
  CHECK(shapes.size() == 1);
  ++cases;
  // Exact iterator compensation: a collision on entry 2 must preserve the
  // pre-existing resource and remove only entry 1.
  const std::string first = token(), second = token();
  const std::vector<std::pair<std::string, TopoDS_Shape>> collision{
      {first, original_shape}, {original, original_shape}};
  bool published = false;
  try {
    publish_batch(shapes, collision, [&] { published = true; });
    CHECK(false);
  } catch (const std::runtime_error &) {
  }
  CHECK(!published && !shapes.count(first) && shapes.count(original));
  ++cases;
  const std::vector<std::pair<std::string, TopoDS_Shape>> batch{
      {first, original_shape}, {second, original_shape}};
  fault = Fault::shape_insert;
  fault_insertion = 2;
  fault_exception = 0;
  const auto removed = compensated_entries;
  try {
    publish_batch(shapes, batch, [&] { published = true; });
    CHECK(false);
  } catch (const std::runtime_error &) {
  }
  CHECK(!published && !shapes.count(first) && !shapes.count(second));
  CHECK(compensated_entries == removed + 2 && shapes.count(original));
  ++cases;
  publish_batch(shapes, batch, [&] { published = true; });
  CHECK(published && shapes.count(first) && shapes.count(second));
  ++cases;
  // An exception from publication also compensates the entire batch.
  const std::string third = token();
  const std::vector<std::pair<std::string, TopoDS_Shape>> one{
      {third, original_shape}};
  try {
    publish_batch(shapes, one, [] { throw 17; });
    CHECK(false);
  } catch (int) {
  }
  CHECK(!shapes.count(third) && shapes.count(original));
  ++cases;
  fault_insertion = 1;

  // Use a real, tiny STL created in an exclusively claimed test directory.
  const auto base = std::filesystem::temp_directory_path();
  std::filesystem::path directory;
  for (unsigned i = 0;; ++i) {
    directory = base / ("flcad-atomic-output-" + std::to_string(i));
    if (std::filesystem::create_directory(directory))
      break;
  }
  struct Cleanup {
    std::filesystem::path path;
    ~Cleanup() {
      std::error_code ec;
      std::filesystem::remove_all(path, ec);
    }
  } cleanup{directory};
  const auto path = directory / "triangle.stl";
  {
    std::ofstream file(path);
    file << "solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\n"
            "vertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid t\n";
  }
  int v = -1, tr = -1, deg = -1, normals = -1;
  double bounds[6] = {};
  const auto filename = path.string();
  auto stl = [&](size_t capacity) {
    return flcad_occ_import_stl(filename.c_str(), t, capacity, fp, sizeof(fp),
                                &v, &tr, &deg, bounds, &normals, error,
                                sizeof(error));
  };
  CHECK(stl(1) == 0 && meshes.empty() && v == -1);
  ++cases;
  CHECK(stl(sizeof(t)) == 1 && meshes.count(t));
  const std::string old_mesh = t;
  CHECK(v == 3 && tr == 1);
  ++cases;
  for (int kind : {0, 1, 2}) {
    fault = Fault::mesh_insert;
    fault_exception = kind;
    const auto count = compensated_entries;
    CHECK(stl(sizeof(t)) == 0);
    CHECK(meshes.size() == 1 && meshes.count(old_mesh));
    CHECK(compensated_entries == count + 1);
    ++cases;
  }
  CHECK(flcad_occ_destroy_mesh(old_mesh.c_str(), error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_mesh(old_mesh.c_str(), error, sizeof(error)) == 0);
  CHECK(meshes.empty());
  ++cases;

  // Real crossing planar faces exercise the exported intersection, including
  // real geometric preparation before preflight and the shared batch commit.
  char a[256] = {}, b[256] = {}, json[1024] = {};
  const double origin[3] = {}, nz[3] = {0, 0, 1}, nx[3] = {1, 0, 0};
  CHECK(flcad_occ_create_plane(origin, nz, -1, 1, a, sizeof(a), fp, sizeof(fp),
                               error, sizeof(error)) == 1);
  CHECK(flcad_occ_create_plane(origin, nx, -1, 1, b, sizeof(b), fp, sizeof(fp),
                               error, sizeof(error)) == 1);
  const auto shape_count = shapes.size();
  auto intersect = [&](char *out, size_t size) {
    return flcad_occ_intersect_surfaces(a, b, out, size, error, sizeof(error));
  };
  fault = Fault::serialization;
  std::strcpy(json, "unchanged");
  CHECK(intersect(json, sizeof(json)) == 0 && shapes.size() == shape_count);
  CHECK(std::strcmp(json, "unchanged") == 0);
  ++cases;
  CHECK(intersect(nullptr, sizeof(json)) == 0 && shapes.size() == shape_count);
  ++cases;
  CHECK(intersect(json, 1) == 0 && shapes.size() == shape_count);
  ++cases;
  for (int kind : {0, 1, 2}) {
    fault = Fault::shape_insert;
    fault_exception = kind;
    CHECK(intersect(json, sizeof(json)) == 0 && shapes.size() == shape_count);
    CHECK(shapes.count(a) && shapes.count(b));
    ++cases;
  }
  CHECK(intersect(json, sizeof(json)) == 1 && shapes.size() == shape_count + 1);
  const std::string response_text = json;
  const auto start = response_text.find("\"token\":\"");
  CHECK(start != std::string::npos);
  const auto end = response_text.find('"', start + 9);
  const auto intersection_token =
      response_text.substr(start + 9, end - start - 9);
  CHECK(shapes.count(intersection_token));
  ++cases;

  // Type is part of the same response: it cannot be written before all other
  // fields pass preflight (transform and BREP restore share this path).
  const double identity[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
  char type[64] = "unchanged";
  const auto count = shapes.size();
  CHECK(flcad_occ_transform_shape(a, identity, 1, t, 1, fp, sizeof(fp), type,
                                  sizeof(type), error, sizeof(error)) == 0);
  CHECK(shapes.size() == count && std::strcmp(type, "unchanged") == 0);
  ++cases;
  CHECK(flcad_occ_transform_shape(a, identity, 1, t, sizeof(t), fp, sizeof(fp),
                                  nullptr, 0, error, sizeof(error)) == 0 &&
        shapes.size() == count);
  ++cases;
  CHECK(flcad_occ_transform_shape(a, identity, 1, t, sizeof(t), fp, sizeof(fp),
                                  type, sizeof(type), error,
                                  sizeof(error)) == 1 &&
        shapes.count(t));
  ++cases;
  char tiny_error[2] = {'x', 'y'};
  CHECK(flcad_occ_create_vertex(0, 0, 0, nullptr, 0, fp, sizeof(fp), tiny_error,
                                1) == 0);
  CHECK(tiny_error[0] == '\0' && tiny_error[1] == 'y');
  ++cases;
  CHECK(flcad_occ_create_vertex(0, 0, 0, nullptr, 0, fp, sizeof(fp), nullptr,
                                0) == 0);
  ++cases;
  // Exhaustion never wraps or reuses an earlier token.
  sequence.store(std::numeric_limits<unsigned long long>::max());
  const auto final_count = shapes.size();
  CHECK(vertex(t, sizeof(t)) == 0 && shapes.size() == final_count);
  ++cases;
  flcad_occ_shutdown();
  CHECK(shapes.empty() && meshes.empty());
  std::printf("PASS: %d native atomic-output cases\n", cases);
  return 0;
}
