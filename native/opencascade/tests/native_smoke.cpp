#include "flcad_occ_api.h"
#include <cstring>
#include <cstdio>
#include <filesystem>

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      std::fprintf(stderr, "CHECK failed at %s:%d: %s; native error: %s\n",   \
                   __FILE__, __LINE__, #condition, error);                     \
      return 1;                                                                \
    }                                                                          \
  } while (false)

int main() {
  char error[1024] = {}, token[256] = {}, fingerprint[256] = {};
  CHECK(flcad_occ_initialize(error, sizeof(error)) == 1);
  CHECK(std::strlen(flcad_occ_version()) > 0);
  CHECK(std::strstr(flcad_occ_capabilities(), "STEP") != nullptr);
  CHECK(std::strstr(flcad_occ_capabilities(), "IGES") != nullptr);
  CHECK(std::strstr(flcad_occ_capabilities(), "Loft") != nullptr);
  CHECK(flcad_occ_create_vertex(1, 2, 3, token, sizeof(token), fingerprint,
                                 sizeof(fingerprint), error, sizeof(error)) == 1);
  CHECK(flcad_occ_shape_count() == 1);
  CHECK(flcad_occ_destroy_shape(token, error, sizeof(error)) == 1);
  CHECK(flcad_occ_shape_count() == 0);
  const double square[12] = {0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0};
  char profile[256] = {}, drafted_extrude[256] = {};
  CHECK(flcad_occ_create_planar_face(
            square, 4, profile, sizeof(profile), fingerprint,
            sizeof(fingerprint), error, sizeof(error)) == 1);
  const double extrusion[3] = {0, 0, 20};
  CHECK(flcad_occ_extrude(
            profile, extrusion, 1, 5.0, drafted_extrude,
            sizeof(drafted_extrude), fingerprint, sizeof(fingerprint), error,
            sizeof(error)) == 1);
  // UI smoke contract: an independently selected geometric edge must be
  // matched back to the owning body and produce a real fillet.
  char edge_start[256] = {}, edge_end[256] = {}, selected_edge[256] = {};
  CHECK(flcad_occ_create_vertex(0, 0, 0, edge_start, sizeof(edge_start),
                                fingerprint, sizeof(fingerprint), error,
                                sizeof(error)) == 1);
  CHECK(flcad_occ_create_vertex(10, 0, 0, edge_end, sizeof(edge_end),
                                fingerprint, sizeof(fingerprint), error,
                                sizeof(error)) == 1);
  CHECK(flcad_occ_create_edge(edge_start, edge_end, selected_edge,
                              sizeof(selected_edge), fingerprint,
                              sizeof(fingerprint), error,
                              sizeof(error)) == 1);
  char filleted[256] = {}, operated_type[64] = {};
  const double fillet_values[10] = {0, 1.0, 1.0, 1, 0, 1, 0, 1e-4, 0, 0};
  CHECK(flcad_occ_surface_operation(
            "FILLET", drafted_extrude, selected_edge, fillet_values, 10,
            filleted, sizeof(filleted), fingerprint, sizeof(fingerprint),
            operated_type, sizeof(operated_type), error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(filleted, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(selected_edge, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(edge_start, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(edge_end, error, sizeof(error)) == 1);

  // Two independent planar supports plus one selected boundary Edge from
  // each support must produce a real Blend face.
  const double second_square[12] = {0, 15, 0, 10, 15, 0,
                                    10, 25, 0, 0, 25, 0};
  char second_face[256] = {}, blend_a0[256] = {}, blend_a1[256] = {},
       blend_b0[256] = {}, blend_b1[256] = {}, blend_edge_a[256] = {},
       blend_edge_b[256] = {}, blended[256] = {};
  CHECK(flcad_occ_create_planar_face(
            second_square, 4, second_face, sizeof(second_face), fingerprint,
            sizeof(fingerprint), error, sizeof(error)) == 1);
  CHECK(flcad_occ_create_vertex(0, 10, 0, blend_a0, sizeof(blend_a0),
                                fingerprint, sizeof(fingerprint), error,
                                sizeof(error)) == 1);
  CHECK(flcad_occ_create_vertex(10, 10, 0, blend_a1, sizeof(blend_a1),
                                fingerprint, sizeof(fingerprint), error,
                                sizeof(error)) == 1);
  CHECK(flcad_occ_create_vertex(0, 15, 0, blend_b0, sizeof(blend_b0),
                                fingerprint, sizeof(fingerprint), error,
                                sizeof(error)) == 1);
  CHECK(flcad_occ_create_vertex(10, 15, 0, blend_b1, sizeof(blend_b1),
                                fingerprint, sizeof(fingerprint), error,
                                sizeof(error)) == 1);
  CHECK(flcad_occ_create_edge(blend_a0, blend_a1, blend_edge_a,
                              sizeof(blend_edge_a), fingerprint,
                              sizeof(fingerprint), error,
                              sizeof(error)) == 1);
  CHECK(flcad_occ_create_edge(blend_b0, blend_b1, blend_edge_b,
                              sizeof(blend_edge_b), fingerprint,
                              sizeof(fingerprint), error,
                              sizeof(error)) == 1);
  const std::string blend_refs = std::string(second_face) + "," +
                                 blend_edge_a + "," + blend_edge_b;
  const double blend_values[8] = {0, 0, 1e-4, 1e-3, 0, 1, 0, 1};
  CHECK(flcad_occ_surface_operation(
            "BLEND", profile, blend_refs.c_str(), blend_values, 8, blended,
            sizeof(blended), fingerprint, sizeof(fingerprint), operated_type,
            sizeof(operated_type), error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(blended, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(blend_edge_a, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(blend_edge_b, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(blend_a0, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(blend_a1, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(blend_b0, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(blend_b1, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(second_face, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(drafted_extrude, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(profile, error, sizeof(error)) == 1);
  CHECK(flcad_occ_shape_count() == 0);
  const double center[3] = {0, 0, 0}, axis[3] = {0, 0, 1};
  CHECK(flcad_occ_create_torus(center, axis, 5, 1, token, sizeof(token),
                                fingerprint, sizeof(fingerprint), error,
                                sizeof(error)) == 1);
  char topology[4096] = {};
  CHECK(flcad_occ_surface_topology(token, topology, sizeof(topology), error,
                                    sizeof(error)) == 1);
  CHECK(std::strstr(topology, "boundaries") != nullptr);
  char quality[4096] = {};
  CHECK(flcad_occ_surface_quality(token, axis, 100, quality, sizeof(quality),
                                   error, sizeof(error)) == 1);
  CHECK(std::strstr(quality, "meanCurvature") != nullptr);
  CHECK(std::strstr(quality, "averageNormal") != nullptr);
  CHECK(std::strstr(quality, "draft") != nullptr);
  char operated[256] = {}, operated_fp[256] = {};
  CHECK(flcad_occ_surface_operation("NURBS", token, "", nullptr, 0,
      operated, sizeof(operated), operated_fp, sizeof(operated_fp),
      operated_type, sizeof(operated_type), error, sizeof(error)) == 1);
  CHECK(std::strlen(operated_fp) > 0);
  CHECK(flcad_occ_destroy_shape(operated, error, sizeof(error)) == 1);
  const double trim_values[5] = {0, 3.0, 0, 3.0, 1e-6};
  CHECK(flcad_occ_surface_operation("TRIM", token, "", trim_values, 5,
      operated, sizeof(operated), operated_fp, sizeof(operated_fp),
      operated_type, sizeof(operated_type), error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(operated, error, sizeof(error)) == 1);
  CHECK(flcad_occ_surface_operation("BOUNDARY", token, "", nullptr, 0,
      operated, sizeof(operated), operated_fp, sizeof(operated_fp),
      operated_type, sizeof(operated_type), error, sizeof(error)) == 1);
  CHECK(std::strcmp(operated_type, "compound") == 0);
  CHECK(flcad_occ_destroy_shape(operated, error, sizeof(error)) == 1);
  CHECK(flcad_occ_surface_operation("HEAL", token, "", nullptr, 0,
      operated, sizeof(operated), operated_fp, sizeof(operated_fp),
      operated_type, sizeof(operated_type), error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(operated, error, sizeof(error)) == 1);
  CHECK(flcad_occ_surface_operation("HEAL LOCAL", token, "", nullptr, 0,
      operated, sizeof(operated), operated_fp, sizeof(operated_fp),
      operated_type, sizeof(operated_type), error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(operated, error, sizeof(error)) == 1);
  CHECK(flcad_occ_surface_operation("UNSEW ALL", token, "", nullptr, 0,
      operated, sizeof(operated), operated_fp, sizeof(operated_fp),
      operated_type, sizeof(operated_type), error, sizeof(error)) == 1);
  CHECK(std::strcmp(operated_type, "compound") == 0);
  CHECK(flcad_occ_destroy_shape(operated, error, sizeof(error)) == 1);
  CHECK(flcad_occ_shape_count() == 1);
  CHECK(flcad_occ_destroy_shape(token, error, sizeof(error)) == 1);
  char plane[256] = {}, cylinder[256] = {}, intersection[4096] = {};
  CHECK(flcad_occ_create_plane(center, axis, -10, 10, plane, sizeof(plane),
                                fingerprint, sizeof(fingerprint), error,
                                sizeof(error)) == 1);
  CHECK(flcad_occ_create_cylinder(center, axis, 3, -1, 1, cylinder,
                                   sizeof(cylinder), fingerprint,
                                   sizeof(fingerprint), error,
                                   sizeof(error)) == 1);
  CHECK(flcad_occ_intersect_surfaces(plane, cylinder, intersection,
                                      sizeof(intersection), error,
                                      sizeof(error)) == 1);
  CHECK(std::strstr(intersection, "edgeCount") != nullptr);
  CHECK(flcad_occ_destroy_shape(plane, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(cylinder, error, sizeof(error)) == 1);
  char exported[256] = {}, imported_fp[256] = {}, imported_type[64] = {};
  CHECK(flcad_occ_create_torus(center, axis, 5, 1, exported,
                                sizeof(exported), fingerprint,
                                sizeof(fingerprint), error,
                                sizeof(error)) == 1);
  const char* step_path = "flcad_native_roundtrip.step";
  const char* iges_path = "flcad_native_roundtrip.iges";
  const char* stl_path = "flcad_native_roundtrip.stl";
  CHECK(flcad_occ_export_shape(exported, step_path, "step", error,
                                sizeof(error)) == 1);
  CHECK(std::filesystem::file_size(step_path) > 0);
  char roundtrip[256] = {};
  CHECK(flcad_occ_import_shape(step_path, "step", roundtrip,
                                sizeof(roundtrip), imported_fp,
                                sizeof(imported_fp), imported_type,
                                sizeof(imported_type), error,
                                sizeof(error)) == 1);
  const double transform[16] = {
      1, 0, 0, 10,
      0, 1, 0, 20,
      0, 0, 1, 30,
      0, 0, 0, 1};
  char transformed[256] = {}, transformed_fp[256] = {}, transformed_type[64] = {};
  if (flcad_occ_transform_shape(
          roundtrip, transform, 1, transformed, sizeof(transformed),
          transformed_fp, sizeof(transformed_fp), transformed_type,
          sizeof(transformed_type), error, sizeof(error)) != 1) {
    fprintf(stderr, "transform failed: %s\n", error);
    return 2;
  }
  CHECK(std::strlen(transformed_fp) > 0);
  CHECK(flcad_occ_destroy_shape(transformed, error, sizeof(error)) == 1);
  CHECK(flcad_occ_export_shape(roundtrip, iges_path, "iges", error,
                                sizeof(error)) == 1);
  CHECK(std::filesystem::file_size(iges_path) > 0);
  int vertices = 0, triangles = 0;
  CHECK(flcad_occ_mesh(roundtrip, stl_path, 0.1, &vertices, &triangles,
                        error, sizeof(error)) == 1);
  CHECK(vertices > 0 && triangles > 0);
  CHECK(std::filesystem::file_size(stl_path) > 84);
  const char* unicode_stl_path = u8"flcad_peça.stl";
  std::filesystem::copy_file(
      stl_path, std::filesystem::u8path(unicode_stl_path),
      std::filesystem::copy_options::overwrite_existing);
  char mesh_token[256] = {}, mesh_fingerprint[256] = {};
  int mesh_vertices = 0, mesh_triangles = 0, mesh_degenerates = 0,
      mesh_normals = 0;
  double mesh_bounds[6] = {};
  CHECK(flcad_occ_import_stl(
             unicode_stl_path, mesh_token, sizeof(mesh_token),
             mesh_fingerprint, sizeof(mesh_fingerprint), &mesh_vertices,
             &mesh_triangles, &mesh_degenerates, mesh_bounds, &mesh_normals,
             error, sizeof(error)) == 1);
  CHECK(mesh_vertices > 0 && mesh_triangles > 0);
  CHECK(flcad_occ_destroy_mesh(mesh_token, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(exported, error, sizeof(error)) == 1);
  CHECK(flcad_occ_destroy_shape(roundtrip, error, sizeof(error)) == 1);
  std::filesystem::remove(step_path);
  std::filesystem::remove(iges_path);
  std::filesystem::remove(stl_path);
  std::filesystem::remove(std::filesystem::u8path(unicode_stl_path));
  for (int i = 0; i < 1000; ++i) {
    CHECK(flcad_occ_create_vertex(i, i, i, token, sizeof(token), fingerprint,
                                   sizeof(fingerprint), error, sizeof(error)) == 1);
    CHECK(flcad_occ_destroy_shape(token, error, sizeof(error)) == 1);
  }
  // Surface intersection above intentionally remains registered until shutdown.
  CHECK(flcad_occ_shape_count() == 1);
  flcad_occ_shutdown();
  CHECK(flcad_occ_shape_count() == 0);
  return 0;
}
