#include "flcad_occ_api.h"
#include <Adaptor3d_CurveOnSurface.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepBuilderAPI_GTransform.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_NurbsConvert.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <ChFi3d_FilletShape.hxx>
#include <BRepGProp.hxx>
#include <BRepLProp_SLProps.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepOffsetAPI_MakeFilling.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <GProp_GProps.hxx>
#include <GeomLib.hxx>
#include <Geom2dAdaptor_Curve.hxx>
#include <GeomAdaptor_Surface.hxx>
#include <GeomPlate_BuildPlateSurface.hxx>
#include <GeomPlate_CurveConstraint.hxx>
#include <GeomPlate_MakeApprox.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Geom_BoundedSurface.hxx>
#include <Geom_Curve.hxx>
#include <IGESControl_Reader.hxx>
#include <IGESControl_Writer.hxx>
#include <Interface_Static.hxx>
#include <NCollection_Array1.hxx>
#include <OSD_OpenFile.hxx>
#include <Poly_Triangulation.hxx>
#include <RWStl.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Writer.hxx>
#include <ShapeCustom_BSplineRestriction.hxx>
#include <ShapeBuild_ReShape.hxx>
#include <ShapeFix_Face.hxx>
#include <ShapeFix_Wire.hxx>
#include <ShapeFix_Shape.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Version.hxx>
#include <StlAPI_Writer.hxx>
#include <TopExp.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Vertex.hxx>
#include <TopoDS_Wire.hxx>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <fstream>
#include <gp.hxx>
#include <gp_Ax2.hxx>
#include <gp_Cone.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Dir.hxx>
#include <gp_GTrsf.hxx>
#include <gp_Pln.hxx>
#include <gp_Pnt.hxx>
#include <gp_Pnt2d.hxx>
#include <gp_Sphere.hxx>
#include <gp_Torus.hxx>
#include <gp_Trsf.hxx>
#include <gp_Vec.hxx>
#include <mutex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include <cstdint>
#include <limits>
#include <stdexcept>
#include <type_traits>

namespace {
std::unordered_map<std::string, TopoDS_Shape> shapes;
std::unordered_map<std::string, Handle(Poly_Triangulation)> meshes;
std::mutex registry_mutex;
std::atomic<unsigned long long> sequence{1};
thread_local std::string response;
// Error reporting must itself be allocation-free and non-throwing. Only error
// messages may be shortened; successful outputs are always copied in full.
int fail(const char *message, char *error, size_t size) noexcept {
  if (error && size) {
    size_t i = 0;
    if (message) {
      while (i < size - 1 && message[i]) {
        const unsigned char c = static_cast<unsigned char>(message[i]);
        error[i++] = c < 32 || c == 127 ? ' ' : static_cast<char>(c);
      }
    }
    error[i] = '\0';
  }
  return 0;
}
int fail(const std::string &message, char *error, size_t size) noexcept {
  return fail(message.c_str(), error, size);
}
void preflight(const std::string &value, char *out, size_t size) {
  if (!out || size <= value.size())
    throw std::invalid_argument(
        "Missing or insufficient output buffer (NUL required)");
}
void copy_complete(const std::string &value, char *out) noexcept {
  std::memcpy(out, value.c_str(), value.size() + 1);
}
void copy(const std::string &value, char *out, size_t size) {
  preflight(value, out, size);
  copy_complete(value, out);
}
void separate_outputs(
    std::initializer_list<std::pair<const void *, size_t>> outputs) {
  for (auto a = outputs.begin(); a != outputs.end(); ++a) {
    if (!a->second)
      continue;
    const auto start = reinterpret_cast<uintptr_t>(a->first);
    if (!a->first || a->second > UINTPTR_MAX - start)
      throw std::invalid_argument("Invalid output range");
    for (auto b = outputs.begin(); b != a; ++b) {
      const auto other = reinterpret_cast<uintptr_t>(b->first);
      if (b->second && start < other + b->second && other < start + a->second)
        throw std::invalid_argument("Overlapping output buffers");
    }
  }
}
std::string token(const char *prefix = "occ-shape-") {
  auto next = sequence.load();
  for (;;) {
    if (next == std::numeric_limits<unsigned long long>::max())
      throw std::overflow_error("Native token sequence exhausted");
    if (sequence.compare_exchange_weak(next, next + 1))
      return std::string(prefix) + std::to_string(next);
  }
}
#ifdef FLCAD_OCC_TESTING
enum class Fault {
  none,
  fingerprint,
  shape_insert,
  mesh_insert,
  serialization
};
thread_local Fault fault = Fault::none;
thread_local size_t fault_insertion = 1;
thread_local int fault_exception = 0;
thread_local size_t compensated_entries = 0;
void inject(Fault point, size_t insertion = 1) {
  if (fault != point || insertion != fault_insertion)
    return;
  fault = Fault::none;
  if (fault_exception == 1)
    throw Standard_Failure("Injected OCCT failure");
  if (fault_exception == 2)
    throw 42;
  throw std::runtime_error("Injected native failure");
}
#endif
std::string fingerprint(const TopoDS_Shape &shape) {
  auto result = "occ-" + std::to_string(std::hash<TopoDS_Shape>{}(shape));
#ifdef FLCAD_OCC_TESTING
  inject(Fault::fingerprint);
#endif
  return result;
}
// All allocating preparation/preflight belongs to the caller. Keep the registry
// locked through publication/compensation, so no observer sees a partial batch.
// reserve prevents rehash: saved iterators identify only this batch's entries.
template <typename Registry, typename Entries, typename Publish>
void publish_batch(Registry &registry, const Entries &entries,
                   Publish publish) {
  std::vector<typename Registry::iterator> inserted;
  inserted.reserve(entries.size());
  std::lock_guard<std::mutex> lock(registry_mutex);
  registry.reserve(registry.size() + entries.size());
  try {
    for (const auto &entry : entries) {
      auto result = registry.emplace(entry.first, entry.second);
      if (!result.second)
        throw std::runtime_error("Native token collision");
      inserted.push_back(result.first);
#ifdef FLCAD_OCC_TESTING
      inject(std::is_same_v<Registry, decltype(shapes)> ? Fault::shape_insert
                                                        : Fault::mesh_insert,
             inserted.size());
#endif
    }
    publish();
  } catch (...) {
    // Iterator erase does not hash or allocate; OCCT handle destructors do not
    // throw. Compensation cannot fail for these concrete registries.
    for (auto it : inserted) {
      registry.erase(it);
#ifdef FLCAD_OCC_TESTING
      ++compensated_entries;
#endif
    }
    throw;
  }
}

TopoDS_Edge first_edge(const TopoDS_Shape &shape) {
  if (shape.ShapeType() == TopAbs_EDGE)
    return TopoDS::Edge(shape);
  TopExp_Explorer explorer(shape, TopAbs_EDGE);
  if (!explorer.More())
    throw Standard_Failure("Selected shape contains no Edge");
  return TopoDS::Edge(explorer.Current());
}

TopoDS_Face first_face(const TopoDS_Shape &shape) {
  if (shape.ShapeType() == TopAbs_FACE)
    return TopoDS::Face(shape);
  TopExp_Explorer explorer(shape, TopAbs_FACE);
  if (!explorer.More())
    throw Standard_Failure("Selected shape contains no Face");
  return TopoDS::Face(explorer.Current());
}
TopoDS_Shape get(const char *id) {
  std::lock_guard<std::mutex> lock(registry_mutex);
  auto it = shapes.find(id ? id : "");
  if (it == shapes.end())
    throw Standard_Failure("Unknown native shape token");
  return it->second;
}
std::vector<std::string> split(const char *value) {
  std::vector<std::string> result;
  std::stringstream stream(value ? value : "");
  std::string item;
  while (std::getline(stream, item, ',')) {
    if (!item.empty())
      result.push_back(item);
  }
  return result;
}
const char *shape_type(const TopoDS_Shape &s);
int output(const TopoDS_Shape &shape, char *out_token, size_t token_size,
           char *out_fp, size_t fp_size, char *error, size_t error_size,
           char *out_type = nullptr, size_t type_size = 0,
           bool include_type = false) {
  if (shape.IsNull())
    return fail("OCCT produced a null shape", error, error_size);
  const auto fp = fingerprint(shape);
  const std::string type = include_type ? shape_type(shape) : "";
  const auto id = token();
  preflight(id, out_token, token_size);
  preflight(fp, out_fp, fp_size);
  if (include_type)
    preflight(type, out_type, type_size);
  separate_outputs({{out_token, id.size() + 1},
                    {out_fp, fp.size() + 1},
                    {out_type, include_type ? type.size() + 1 : 0}});
  const std::vector<std::pair<std::string, TopoDS_Shape>> entries{{id, shape}};
  publish_batch(shapes, entries, [&]() noexcept {
    copy_complete(id, out_token);
    copy_complete(fp, out_fp);
    if (include_type)
      copy_complete(type, out_type);
  });
  return 1;
}
gp_Pnt point(const double *p) {
  if (!p)
    throw std::invalid_argument("Missing point");
  return gp_Pnt(p[0], p[1], p[2]);
}
gp_Dir direction(const double *p) {
  if (!p)
    throw std::invalid_argument("Missing direction");
  return gp_Dir(p[0], p[1], p[2]);
}
const char *shape_type(const TopoDS_Shape &s) {
  switch (s.ShapeType()) {
  case TopAbs_VERTEX:
    return "vertex";
  case TopAbs_EDGE:
    return "edge";
  case TopAbs_WIRE:
    return "wire";
  case TopAbs_FACE:
    return "face";
  case TopAbs_SHELL:
    return "shell";
  case TopAbs_SOLID:
    return "solid";
  default:
    return "compound";
  }
}
} // namespace

extern "C" {
int flcad_occ_initialize(char *error, size_t error_size) {
  try {
    Interface_Static::SetCVal("write.step.schema", "AP242DIS");
    return 1;
  } catch (const Standard_Failure &e) {
    return fail(e.GetMessageString(), error, error_size);
  }
}
void flcad_occ_shutdown() {
  std::lock_guard<std::mutex> lock(registry_mutex);
  shapes.clear();
  meshes.clear();
}
const char *flcad_occ_version() { return OCC_VERSION_COMPLETE; }
const char *flcad_occ_capabilities() {
  return "STEP,IGES,BREP,STL,Surface,Solid,Meshing,Healing,NURBS,Boolean,Loft,"
         "Sweep,Fill,Patch,Blend,Extend,Reduce,Offset,Trim,Split,Join,Sew,"
         "Match,Boundary";
}
const char *flcad_occ_diagnostics() {
  std::lock_guard<std::mutex> lock(registry_mutex);
  response = "{\"healthy\":true,\"backend\":\"OpenCascade\",\"shapeCount\":" +
             std::to_string(shapes.size()) +
             ",\"meshCount\":" + std::to_string(meshes.size()) + "}";
  return response.c_str();
}
int flcad_occ_create_vertex(double x, double y, double z, char *t, size_t ts,
                            char *f, size_t fs, char *e, size_t es) {
  try {
    return output(BRepBuilderAPI_MakeVertex(gp_Pnt(x, y, z)), t, ts, f, fs, e,
                  es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_destroy_shape(const char *id, char *e, size_t es) {
  try {
    std::lock_guard<std::mutex> lock(registry_mutex);
    auto it = shapes.find(id ? id : "");
    if (it == shapes.end())
      return fail("Unknown native shape token", e, es);
    shapes.erase(it);
    return 1;
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_create_edge(const char *a, const char *b, char *t, size_t ts,
                          char *f, size_t fs, char *e, size_t es) {
  try {
    return output(
        BRepBuilderAPI_MakeEdge(TopoDS::Vertex(get(a)), TopoDS::Vertex(get(b))),
        t, ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_create_wire(const char *ids, char *t, size_t ts, char *f,
                          size_t fs, char *e, size_t es) {
  try {
    BRepBuilderAPI_MakeWire maker;
    for (auto &id : split(ids))
      maker.Add(TopoDS::Edge(get(id.c_str())));
    if (!maker.IsDone())
      return fail("Wire builder did not complete", e, es);
    return output(maker.Wire(), t, ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_create_face(const char *id, char *t, size_t ts, char *f,
                          size_t fs, char *e, size_t es) {
  try {
    BRepBuilderAPI_MakeFace maker(TopoDS::Wire(get(id)), true);
    if (!maker.IsDone())
      return fail("Face builder did not complete", e, es);
    return output(maker.Face(), t, ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_create_shell(const char *ids, double tolerance, char *t,
                           size_t ts, char *f, size_t fs, char *e, size_t es) {
  try {
    BRepBuilderAPI_Sewing sewing(tolerance);
    for (auto &id : split(ids))
      sewing.Add(get(id.c_str()));
    sewing.Perform();
    return output(sewing.SewedShape(), t, ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_create_solid(const char *id, char *t, size_t ts, char *f,
                           size_t fs, char *e, size_t es) {
  try {
    BRepBuilderAPI_MakeSolid maker(TopoDS::Shell(get(id)));
    if (!maker.IsDone())
      return fail("Solid builder did not complete", e, es);
    return output(maker.Solid(), t, ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_extrude(const char *id, const double *d, int solid_output,
                      double draft_angle_degrees,
                      char *t, size_t ts, char *f, size_t fs, char *e,
                      size_t es) {
  try {
    if (!d)
      return fail("Extrude requires a direction vector", e, es);
    TopoDS_Shape source = get(id);
    if (solid_output && source.ShapeType() == TopAbs_WIRE) {
      BRepBuilderAPI_MakeFace face(TopoDS::Wire(source), true);
      if (!face.IsDone())
        return fail("Extrude solid requires a closed planar profile", e, es);
      source = face.Face();
    } else if (!solid_output && source.ShapeType() == TopAbs_FACE) {
      source = BRepTools::OuterWire(TopoDS::Face(source));
    }
    const gp_Vec extrusion(d[0], d[1], d[2]);
    if (extrusion.Magnitude() <= gp::Resolution())
      return fail("Extrude direction must not be zero", e, es);
    if (!std::isfinite(draft_angle_degrees) ||
        std::abs(draft_angle_degrees) >= 89.0)
      return fail("Extrude draft angle must be between -89 and 89 degrees", e,
                  es);
    BRepPrimAPI_MakePrism prism(source, extrusion, false, true);
    prism.Build();
    if (!prism.IsDone())
      return fail("Extrude builder did not complete", e, es);
    TopoDS_Shape result = prism.Shape();
    if (std::abs(draft_angle_degrees) > 1.0e-9) {
      TopExp_Explorer vertices(source, TopAbs_VERTEX);
      if (!vertices.More())
        return fail("Draft angle requires a profile with vertices", e, es);
      const gp_Pnt neutral_origin =
          BRep_Tool::Pnt(TopoDS::Vertex(vertices.Current()));
      const gp_Dir pull_direction(extrusion);
      const gp_Pln neutral_plane(neutral_origin, pull_direction);
      BRepOffsetAPI_DraftAngle drafted(result);
      int lateral_faces = 0;
      for (TopExp_Explorer edges(source, TopAbs_EDGE); edges.More();
           edges.Next()) {
        const TopTools_ListOfShape &generated = prism.Generated(edges.Current());
        for (TopTools_ListOfShape::Iterator item(generated); item.More();
             item.Next()) {
          if (item.Value().ShapeType() != TopAbs_FACE)
            continue;
          drafted.Add(TopoDS::Face(item.Value()), pull_direction,
                      draft_angle_degrees * 3.14159265358979323846 / 180.0,
                      neutral_plane);
          ++lateral_faces;
        }
      }
      if (lateral_faces == 0)
        return fail("Draft angle found no lateral extrusion faces", e, es);
      drafted.Build();
      if (!drafted.IsDone())
        return fail("Draft angle could not be applied to the side faces", e,
                    es);
      result = drafted.Shape();
    }
    return output(result, t, ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_create_plane(const double *o, const double *n, double l, double u,
                           char *t, size_t ts, char *f, size_t fs, char *e,
                           size_t es) {
  try {
    return output(
        BRepBuilderAPI_MakeFace(gp_Pln(point(o), direction(n)), l, u, l, u), t,
        ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_create_planar_face(const double *points, size_t point_count,
                                 char *t, size_t ts, char *f, size_t fs,
                                 char *e, size_t es) {
  try {
    if (!points || point_count < 3)
      return fail("Planar face requires at least three profile points", e, es);
    BRepBuilderAPI_MakePolygon polygon;
    for (size_t i = 0; i < point_count; ++i)
      polygon.Add(gp_Pnt(points[i * 3], points[i * 3 + 1], points[i * 3 + 2]));
    polygon.Close();
    if (!polygon.IsDone())
      return fail("Planar profile wire could not be created", e, es);
    BRepBuilderAPI_MakeFace face(polygon.Wire(), true);
    if (!face.IsDone())
      return fail("Planar profile does not define a valid face", e, es);
    return output(face.Face(), t, ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_create_cylinder(const double *o, const double *d, double r,
                              double l, double u, char *t, size_t ts, char *f,
                              size_t fs, char *e, size_t es) {
  try {
    return output(
        BRepBuilderAPI_MakeFace(gp_Cylinder(gp_Ax2(point(o), direction(d)), r),
                                0, 6.283185307179586, l, u),
        t, ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_create_cone(const double *o, const double *d, double a, double l,
                          double u, char *t, size_t ts, char *f, size_t fs,
                          char *e, size_t es) {
  try {
    return output(
        BRepBuilderAPI_MakeFace(gp_Cone(gp_Ax2(point(o), direction(d)), a, 0),
                                0, 6.283185307179586, l, u),
        t, ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_create_sphere(const double *o, double r, double l, double u,
                            char *t, size_t ts, char *f, size_t fs, char *e,
                            size_t es) {
  try {
    return output(
        BRepBuilderAPI_MakeFace(gp_Sphere(gp_Ax2(point(o), gp::DZ()), r), 0,
                                6.283185307179586, l, u),
        t, ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_create_torus(const double *o, const double *d, double major_r,
                           double minor_r, char *t, size_t ts, char *f,
                           size_t fs, char *e, size_t es) {
  try {
    return output(
        BRepBuilderAPI_MakeFace(
            gp_Torus(gp_Ax2(point(o), direction(d)), major_r, minor_r), 0,
            6.283185307179586, 0, 6.283185307179586),
        t, ts, f, fs, e, es);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_import_shape(const char *p, const char *fmt, char *t, size_t ts,
                           char *f, size_t fs, char *ty, size_t tys, char *e,
                           size_t es) {
  try {
    if (!p || !*p)
      return fail("Shape path is empty", e, es);
    TopoDS_Shape s;
    std::string format = fmt ? fmt : "";
    if (format == "step") {
      STEPControl_Reader r;
      if (r.ReadFile(p) != IFSelect_RetDone)
        return fail("STEP read failed", e, es);
      r.TransferRoots();
      s = r.OneShape();
    } else if (format == "iges") {
      IGESControl_Reader r;
      if (r.ReadFile(p) != IFSelect_RetDone)
        return fail("IGES read failed", e, es);
      r.TransferRoots();
      s = r.OneShape();
    } else {
      BRep_Builder b;
      if (!BRepTools::Read(s, p, b))
        return fail("BREP read failed", e, es);
    }
    return output(s, t, ts, f, fs, e, es, ty, tys, true);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_transform_shape(const char *id, const double *m,
                              int copy_geometry, char *t, size_t ts, char *f,
                              size_t fs, char *ty, size_t tys, char *e,
                              size_t es) {
  try {
    if (!m)
      return fail("Transform matrix is null", e, es);
    if (std::abs(m[12]) > 1e-12 || std::abs(m[13]) > 1e-12 ||
        std::abs(m[14]) > 1e-12 || std::abs(m[15] - 1.0) > 1e-12)
      return fail("Transform matrix must be affine", e, es);
    const TopoDS_Shape source = get(id);
    const double sx = std::sqrt(m[0] * m[0] + m[4] * m[4] + m[8] * m[8]),
                 sy = std::sqrt(m[1] * m[1] + m[5] * m[5] + m[9] * m[9]),
                 sz = std::sqrt(m[2] * m[2] + m[6] * m[6] + m[10] * m[10]);
    const double dotxy = m[0] * m[1] + m[4] * m[5] + m[8] * m[9],
                 dotxz = m[0] * m[2] + m[4] * m[6] + m[8] * m[10],
                 dotyz = m[1] * m[2] + m[5] * m[6] + m[9] * m[10];
    const bool uniform = sx > 1e-15 && std::abs(sx - sy) < 1e-10 &&
                         std::abs(sx - sz) < 1e-10 && std::abs(dotxy) < 1e-10 &&
                         std::abs(dotxz) < 1e-10 && std::abs(dotyz) < 1e-10;
    TopoDS_Shape result;
    if (uniform) {
      gp_Trsf trsf;
      trsf.SetValues(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9],
                     m[10], m[11]);
      BRepBuilderAPI_Transform maker(source, trsf, copy_geometry != 0);
      if (!maker.IsDone())
        return fail("BRepBuilderAPI_Transform failed", e, es);
      result = maker.Shape();
    } else {
      gp_GTrsf trsf;
      for (int row = 1; row <= 3; ++row)
        for (int col = 1; col <= 4; ++col)
          trsf.SetValue(row, col, m[(row - 1) * 4 + (col - 1)]);
      BRepBuilderAPI_GTransform maker(source, trsf, copy_geometry != 0);
      if (!maker.IsDone())
        return fail("BRepBuilderAPI_GTransform failed", e, es);
      result = maker.Shape();
    }
    return output(result, t, ts, f, fs, e, es, ty, tys, true);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_import_stl(const char *p, char *t, size_t ts, char *f, size_t fs,
                         int *v, int *tr, int *deg, double *b, int *n, char *e,
                         size_t es) {
  try {
    if (!p || !*p)
      return fail("STL path is empty", e, es);
    if (!t || !ts || !f || !fs || !v || !tr || !deg || !b || !n)
      return fail("Missing STL output buffer", e, es);
    std::ifstream stream;
    OSD_OpenStream(stream, p, std::ios::in | std::ios::binary);
    if (!stream.good())
      return fail(std::string("STL file is unavailable: ") + p, e, es);
    Handle(Poly_Triangulation) mesh = RWStl::ReadStream(stream);
    if (mesh.IsNull() || mesh->NbTriangles() <= 0 || mesh->NbNodes() <= 0)
      return fail("STL contains no triangulation", e, es);
    double minx = 0, miny = 0, minz = 0, maxx = 0, maxy = 0, maxz = 0;
    for (int i = 1; i <= mesh->NbNodes(); ++i) {
      const gp_Pnt &q = mesh->Node(i);
      if (i == 1) {
        minx = maxx = q.X();
        miny = maxy = q.Y();
        minz = maxz = q.Z();
      } else {
        minx = std::min(minx, q.X());
        miny = std::min(miny, q.Y());
        minz = std::min(minz, q.Z());
        maxx = std::max(maxx, q.X());
        maxy = std::max(maxy, q.Y());
        maxz = std::max(maxz, q.Z());
      }
    }
    int degenerates = 0;
    for (int i = 1; i <= mesh->NbTriangles(); ++i) {
      int a, c, d;
      mesh->Triangle(i).Get(a, c, d);
      const gp_Pnt &p1 = mesh->Node(a), &p2 = mesh->Node(c),
                   &p3 = mesh->Node(d);
      if (a == c || c == d || a == d ||
          gp_Vec(p1, p2).Crossed(gp_Vec(p1, p3)).SquareMagnitude() <= 1e-24)
        ++degenerates;
    }
    const auto id = token("occ-mesh-");
    const int vertices = mesh->NbNodes(), triangles = mesh->NbTriangles();
    const int normals = mesh->HasNormals() ? 1 : 0;
    const std::string fp =
        "stl-" + std::to_string(vertices) + "-" + std::to_string(triangles);
    preflight(id, t, ts);
    preflight(fp, f, fs);
    separate_outputs({{t, id.size() + 1},
                      {f, fp.size() + 1},
                      {v, sizeof(*v)},
                      {tr, sizeof(*tr)},
                      {deg, sizeof(*deg)},
                      {b, 6 * sizeof(*b)},
                      {n, sizeof(*n)}});
    const std::vector<std::pair<std::string, Handle(Poly_Triangulation)>>
        entries{{id, mesh}};
    publish_batch(meshes, entries, [&]() noexcept {
      copy_complete(id, t);
      copy_complete(fp, f);
      *v = vertices;
      *tr = triangles;
      *deg = degenerates;
      b[0] = minx;
      b[1] = miny;
      b[2] = minz;
      b[3] = maxx;
      b[4] = maxy;
      b[5] = maxz;
      *n = normals;
    });
    return 1;
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_destroy_mesh(const char *id, char *e, size_t es) {
  try {
    std::lock_guard<std::mutex> lock(registry_mutex);
    auto it = meshes.find(id ? id : "");
    if (it == meshes.end())
      return fail("Unknown native mesh token", e, es);
    meshes.erase(it);
    return 1;
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_mesh_geometry(const char *id, double *nodes, size_t nv,
                            int *triangles, size_t tv, char *e, size_t es) {
  try {
    Handle(Poly_Triangulation) mesh;
    {
      std::lock_guard<std::mutex> lock(registry_mutex);
      auto it = meshes.find(id ? id : "");
      if (it == meshes.end())
        return fail("Unknown native mesh token", e, es);
      mesh = it->second;
    }
    const size_t expected_nodes = static_cast<size_t>(mesh->NbNodes()) * 3,
                 expected_triangles =
                     static_cast<size_t>(mesh->NbTriangles()) * 3;
    if (!nodes || !triangles || nv < expected_nodes || tv < expected_triangles)
      return fail("Mesh geometry buffer is too small", e, es);
    for (int i = 1; i <= mesh->NbNodes(); ++i) {
      const gp_Pnt &q = mesh->Node(i);
      const size_t o = static_cast<size_t>(i - 1) * 3;
      nodes[o] = q.X();
      nodes[o + 1] = q.Y();
      nodes[o + 2] = q.Z();
    }
    for (int i = 1; i <= mesh->NbTriangles(); ++i) {
      int a, b, c;
      mesh->Triangle(i).Get(a, b, c);
      const size_t o = static_cast<size_t>(i - 1) * 3;
      triangles[o] = a - 1;
      triangles[o + 1] = b - 1;
      triangles[o + 2] = c - 1;
    }
    return 1;
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  }
}
int flcad_occ_surface_topology(const char *id, char *out, size_t os, char *e,
                               size_t es) {
  try {
    const TopoDS_Shape s = get(id);
    if (s.ShapeType() != TopAbs_FACE)
      return fail("Surface topology requires a TopoDS_Face", e, es);
    std::ostringstream json;
    json.exceptions(std::ios::badbit | std::ios::failbit);
    json << "{\"boundaries\":[";
    bool first = true;
    int boundary = 0;
    std::vector<std::vector<int>> loops;
    for (TopExp_Explorer wx(s, TopAbs_WIRE); wx.More(); wx.Next()) {
      std::vector<int> indices;
      for (TopExp_Explorer ex(wx.Current(), TopAbs_EDGE); ex.More();
           ex.Next()) {
        if (!first)
          json << ',';
        first = false;
        const TopoDS_Edge edge = TopoDS::Edge(ex.Current());
        GProp_GProps props;
        BRepGProp::LinearProperties(edge, props);
        json << "{\"index\":" << boundary << ",\"length\":" << props.Mass()
             << ",\"closed\":" << (BRep_Tool::IsClosed(edge) ? "true" : "false")
             << "}";
        indices.push_back(boundary++);
      }
      loops.push_back(indices);
    }
    json << "],\"loops\":[";
    for (size_t i = 0; i < loops.size(); ++i) {
      if (i)
        json << ',';
      json << "{\"index\":" << i << ",\"closed\":true,\"boundaries\":[";
      for (size_t j = 0; j < loops[i].size(); ++j) {
        if (j)
          json << ',';
        json << loops[i][j];
      }
      json << "]}";
    }
    json << "]}";
    copy(json.str(), out, os);
    return 1;
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_intersect_surfaces(const char *a, const char *b, char *out,
                                 size_t os, char *e, size_t es) {
  try {
    BRepAlgoAPI_Section section(get(a), get(b), Standard_False);
    section.ComputePCurveOn1(Standard_True);
    section.ComputePCurveOn2(Standard_True);
    section.Build();
    if (!section.IsDone())
      return fail("OpenCascade surface intersection failed", e, es);
    const TopoDS_Shape result = section.Shape();
    int edges = 0;
    double length = 0;
    for (TopExp_Explorer ex(result, TopAbs_EDGE); ex.More(); ex.Next()) {
      GProp_GProps props;
      BRepGProp::LinearProperties(ex.Current(), props);
      length += props.Mass();
      ++edges;
    }
    std::vector<std::pair<std::string, TopoDS_Shape>> entries;
    std::ostringstream json;
    json.exceptions(std::ios::badbit | std::ios::failbit);
#ifdef FLCAD_OCC_TESTING
    if (fault == Fault::serialization) {
      fault = Fault::none;
      json.setstate(std::ios::badbit);
    }
#endif

    json << "{\"edgeCount\":" << edges << ",\"length\":" << length;
    if (edges > 0) {
      // The ABI returns one aggregate section shape, not one token per edge.
      // Prepare fingerprint even though the legacy JSON does not expose it.
      fingerprint(result);
      const auto id = token();
      entries.emplace_back(id, result);
      json << ",\"token\":\"" << id << "\"";
    }
    json << "}";
    const auto response_json = json.str();
    preflight(response_json, out, os);
    publish_batch(shapes, entries,
                  [&]() noexcept { copy_complete(response_json, out); });
    return 1;
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_surface_quality(const char *id, const double *d, int samples,
                              char *out, size_t os, char *e, size_t es) {
  try {
    const TopoDS_Shape shape = get(id);
    if (shape.ShapeType() != TopAbs_FACE)
      return fail("Surface quality requires a TopoDS_Face", e, es);
    BRepAdaptor_Surface surface(TopoDS::Face(shape), Standard_True);
    const int side =
        std::max(2, static_cast<int>(std::sqrt(std::max(samples, 4))));
    const double u0 = surface.FirstUParameter(), u1 = surface.LastUParameter(),
                 v0 = surface.FirstVParameter(), v1 = surface.LastVParameter();
    gp_Dir draft = direction(d);
    double minK = 1e100, maxK = -1e100, sumMin = 0, sumMax = 0, sumMean = 0,
           sumGaussian = 0, sumNx = 0, sumNy = 0, sumNz = 0, minDraft = 1e100,
           maxDraft = -1e100, normalDelta = 0;
    int valid = 0, negative = 0, critical = 0, approved = 0;
    gp_Dir previous;
    bool hasPrevious = false;
    for (int iu = 0; iu < side; ++iu) {
      for (int iv = 0; iv < side; ++iv) {
        const double u = u0 + (u1 - u0) * (iu + .5) / side,
                     v = v0 + (v1 - v0) * (iv + .5) / side;
        BRepLProp_SLProps props(surface, u, v, 2, 1e-9);
        if (!props.IsNormalDefined() || !props.IsCurvatureDefined())
          continue;
        const double kmin = props.MinCurvature(), kmax = props.MaxCurvature(),
                     mean = props.MeanCurvature(),
                     gaussian = props.GaussianCurvature();
        const gp_Dir n = props.Normal();
        const double angle =
            std::asin(std::max(-1.0, std::min(1.0, n.Dot(draft)))) * 180.0 /
            3.141592653589793;
        minK = std::min(minK, kmin);
        maxK = std::max(maxK, kmax);
        sumMin += kmin;
        sumMax += kmax;
        sumMean += mean;
        sumGaussian += gaussian;
        sumNx += n.X();
        sumNy += n.Y();
        sumNz += n.Z();
        minDraft = std::min(minDraft, angle);
        maxDraft = std::max(maxDraft, angle);
        if (angle < 0)
          ++negative;
        else if (angle < 3)
          ++critical;
        else
          ++approved;
        if (hasPrevious)
          normalDelta += previous.Angle(n);
        previous = n;
        hasPrevious = true;
        ++valid;
      }
    }
    if (valid == 0)
      return fail("OpenCascade produced no differential surface samples", e,
                  es);
    const double avgMean = sumMean / valid,
                 gradient = valid > 1 ? normalDelta / (valid - 1) : 0,
                 stability = 1.0 / (1.0 + gradient), reflection = stability,
                 zebraH = std::abs(std::sin(sumNy / valid * 12)),
                 zebraV = std::abs(std::sin(sumNx / valid * 12)),
                 zebraR = std::abs(std::sin(
                     std::sqrt(sumNx * sumNx + sumNy * sumNy) / valid * 12));
    std::ostringstream json;
    json.exceptions(std::ios::badbit | std::ios::failbit);
    json << "{\"samples\":" << valid << ",\"minimumCurvature\":" << minK
         << ",\"maximumCurvature\":" << maxK
         << ",\"averageMinimumCurvature\":" << sumMin / valid
         << ",\"averageMaximumCurvature\":" << sumMax / valid
         << ",\"meanCurvature\":" << avgMean
         << ",\"gaussianCurvature\":" << sumGaussian / valid
         << ",\"curvatureGradient\":" << gradient
         << ",\"curvatureStability\":" << stability << ",\"averageNormal\":["
         << sumNx / valid << ',' << sumNy / valid << ',' << sumNz / valid
         << "],\"reflectionScore\":" << reflection
         << ",\"zebra\":{\"horizontal\":" << zebraH
         << ",\"vertical\":" << zebraV << ",\"radial\":" << zebraR
         << ",\"free\":" << (zebraH + zebraV + zebraR) / 3
         << "},\"draft\":{\"minimumAngle\":" << minDraft
         << ",\"maximumAngle\":" << maxDraft << ",\"negative\":" << negative
         << ",\"critical\":" << critical << ",\"approved\":" << approved
         << "}}";
    copy(json.str(), out, os);
    return 1;
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_surface_operation(const char *op, const char *source,
                                const char *refs, const double *v, size_t n,
                                char *t, size_t ts, char *f, size_t fs,
                                char *ty, size_t tys, char *e, size_t es) {
  try {
    if (n && !v)
      return fail("Missing surface values", e, es);
    const std::string operation = op ? op : "";
    const auto ids = split(refs);
    TopoDS_Shape result;
    if (operation == "LOFT") {
      if (ids.size() < 2)
        return fail("LOFT requires at least two wire tokens", e, es);
      BRepOffsetAPI_ThruSections maker(false, false, n > 0 ? v[0] : 1e-6);
      for (const auto &id : ids)
        maker.AddWire(TopoDS::Wire(get(id.c_str())));
      maker.Build();
      if (!maker.IsDone())
        return fail("BRepOffsetAPI_ThruSections failed", e, es);
      result = maker.Shape();
    } else if (operation == "SWEEP") {
      if (ids.size() != 2)
        return fail("SWEEP requires profile and path wire tokens", e, es);
      BRepOffsetAPI_MakePipe maker(TopoDS::Wire(get(ids[1].c_str())),
                                   TopoDS::Wire(get(ids[0].c_str())));
      maker.Build();
      if (!maker.IsDone())
        return fail("BRepOffsetAPI_MakePipe failed", e, es);
      result = maker.Shape();
    } else if (operation == "FILL" || operation == "PATCH") {
      if (ids.empty())
        return fail("Filling operation requires official Edge or Wire tokens",
                    e, es);
      BRepOffsetAPI_MakeFilling maker(n > 0 ? static_cast<int>(v[0]) : 3,
                                      n > 1 ? static_cast<int>(v[1]) : 15,
                                      n > 2 ? static_cast<int>(v[2]) : 2, false,
                                      n > 3 ? v[3] : 1e-4, n > 4 ? v[4] : 1e-4,
                                      n > 5 ? v[5] : 1e-3, n > 6 ? v[6] : .1,
                                      n > 7 ? v[7] : 1e-2);
      const size_t declaredCount = n > 8 ? static_cast<size_t>(v[8]) : ids.size();
      const size_t boundaryCount = std::min(declaredCount, ids.size());
      std::vector<std::vector<TopoDS_Edge>> loopEdges;
      size_t boundaryIndex = 0;
      for (size_t idIndex = 0; idIndex < boundaryCount; ++idIndex) {
        const auto &id = ids[idIndex];
        const TopoDS_Shape boundary = get(id.c_str());
        const int requested = n > 9 + boundaryIndex * 3
                                  ? static_cast<int>(v[9 + boundaryIndex * 3])
                                  : 0;
        const int loopIndex = n > 11 + boundaryIndex * 3
                                  ? static_cast<int>(v[11 + boundaryIndex * 3])
                                  : 0;
        const double influence = n > 10 + boundaryIndex * 3
                                     ? std::max(.05, std::min(1.0, v[10 + boundaryIndex * 3]))
                                     : 1.0;
        if (loopEdges.size() <= static_cast<size_t>(std::max(0, loopIndex)))
          loopEdges.resize(static_cast<size_t>(std::max(0, loopIndex)) + 1);
        const GeomAbs_Shape continuity = requested >= 2   ? GeomAbs_C2
                                         : requested == 1 ? GeomAbs_C1
                                                          : GeomAbs_C0;
        if (boundary.ShapeType() == TopAbs_EDGE) {
          loopEdges[static_cast<size_t>(std::max(0, loopIndex))].push_back(
              TopoDS::Edge(boundary));
          if (requested == 1 && boundaryCount + boundaryIndex < ids.size() &&
              get(ids[boundaryCount + boundaryIndex].c_str()).ShapeType() == TopAbs_FACE) {
            Standard_Real first = 0.0, last = 0.0;
            TopLoc_Location location;
            Handle(Geom_Curve) curve = BRep_Tool::Curve(
                TopoDS::Edge(boundary), location, first, last);
            if (curve.IsNull())
              return fail("Fill boundary has no geometric curve", e, es);
            if (!location.IsIdentity())
              curve = Handle(Geom_Curve)::DownCast(
                  curve->Transformed(location.Transformation()));
            const int segments =
                1 + static_cast<int>(std::round(influence * 7));
            for (int segment = 0; segment < segments; ++segment) {
              const double a = first + (last - first) * segment / segments;
              const double b = first + (last - first) * (segment + 1) / segments;
              BRepBuilderAPI_MakeEdge part(curve, a, b);
              if (!part.IsDone())
                return fail("Fill influence subdivision failed", e, es);
              maker.Add(
                  part.Edge(),
                  TopoDS::Face(
                      get(ids[boundaryCount + boundaryIndex].c_str())),
                  continuity);
            }
          } else {
            maker.Add(TopoDS::Edge(boundary), continuity);
          }
          ++boundaryIndex;
        } else if (boundary.ShapeType() == TopAbs_WIRE) {
          for (TopExp_Explorer ex(boundary, TopAbs_EDGE); ex.More();
               ex.Next()) {
            maker.Add(TopoDS::Edge(ex.Current()), continuity);
            loopEdges[static_cast<size_t>(std::max(0, loopIndex))].push_back(
                TopoDS::Edge(ex.Current()));
          }
          ++boundaryIndex;
        } else {
          return fail("Filling boundary must be a TopoDS_Edge or TopoDS_Wire",
                      e, es);
        }
      }
      maker.Build();
      if (!maker.IsDone())
        return fail("BRepOffsetAPI_MakeFilling failed", e, es);
      result = maker.Shape();
      if (loopEdges.size() > 1) {
        std::vector<TopoDS_Wire> loops;
        for (const auto &edges : loopEdges) {
          BRepBuilderAPI_MakeWire wire;
          for (const auto &edge : edges)
            wire.Add(edge);
          if (!wire.IsDone())
            return fail("Fill loop is open or incompatible", e, es);
          loops.push_back(wire.Wire());
        }
        const TopoDS_Face filledFace = first_face(result);
        BRepBuilderAPI_MakeFace trimmed(BRep_Tool::Surface(filledFace),
                                        loops.front(), true);
        for (size_t loop = 1; loop < loops.size(); ++loop)
          trimmed.Add(loops[loop]);
        if (!trimmed.IsDone())
          return fail("Fill internal loop trimming failed", e, es);
        result = trimmed.Face();
      }
    } else if (operation == "NURBS") {
      if (!source || !*source)
        return fail("NURBS conversion requires a source shape", e, es);
      BRepBuilderAPI_NurbsConvert maker(get(source), Standard_True);
      maker.Perform(get(source));
      if (!maker.IsDone())
        return fail("BRepBuilderAPI_NurbsConvert failed", e, es);
      result = maker.Shape();
    } else if (operation == "EXTEND" || operation == "BOUNDARY EXTEND") {
      if (!source || !*source || n < 4)
        return fail("EXTEND requires source,length,continuity,inU,after", e,
                    es);
      Handle(Geom_BoundedSurface) surface =
          Handle(Geom_BoundedSurface)::DownCast(
              BRep_Tool::Surface(TopoDS::Face(get(source)))->Copy());
      if (surface.IsNull())
        return fail("GeomLib::ExtendSurfByLength requires a bounded surface", e,
                    es);
      GeomLib::ExtendSurfByLength(surface, v[0], static_cast<int>(v[1]),
                                  v[2] != 0, v[3] != 0);
      BRepBuilderAPI_MakeFace maker(surface, n > 4 ? v[4] : 1e-6);
      if (!maker.IsDone())
        return fail("Extended surface face construction failed", e, es);
      result = maker.Face();
      if (operation == "BOUNDARY EXTEND" && !ids.empty()) {
        BRepAlgoAPI_Splitter splitter;
        NCollection_List<TopoDS_Shape> arguments, tools;
        arguments.Append(result);
        for (const auto &id : ids)
          tools.Append(get(id.c_str()));
        splitter.SetArguments(arguments);
        splitter.SetTools(tools);
        splitter.SetFuzzyValue(n > 4 ? v[4] : 1e-6);
        splitter.Build();
        if (!splitter.IsDone())
          return fail("Boundary extension could not be limited by target", e,
                      es);
        GProp_GProps sourceProperties;
        BRepGProp::SurfaceProperties(first_face(get(source)), sourceProperties);
        const TopoDS_Vertex anchor =
            BRepBuilderAPI_MakeVertex(sourceProperties.CentreOfMass());
        const double tolerance = n > 4 ? v[4] : 1e-6;
        double bestDistance = 1e100, bestArea = -1.0;
        for (TopExp_Explorer retained(splitter.Shape(), TopAbs_FACE);
             retained.More(); retained.Next()) {
          BRepExtrema_DistShapeShape distance(anchor, retained.Current());
          distance.Perform();
          if (!distance.IsDone())
            continue;
          GProp_GProps properties;
          BRepGProp::SurfaceProperties(retained.Current(), properties);
          if (distance.Value() < bestDistance - tolerance ||
              (std::abs(distance.Value() - bestDistance) <= tolerance &&
               properties.Mass() > bestArea)) {
            bestDistance = distance.Value();
            bestArea = properties.Mass();
            result = retained.Current();
          }
        }
        if (result.IsNull())
          return fail("Boundary extension target produced no retained Face", e,
                      es);
      }
    } else if (operation == "REDUCE") {
      if (!source || !*source)
        return fail("REDUCE requires a source shape", e, es);
      Handle(ShapeCustom_BSplineRestriction) restriction =
          new ShapeCustom_BSplineRestriction(
              true, true, true, n > 0 ? v[0] : 1e-4, n > 1 ? v[1] : 1e-4,
              GeomAbs_C1, GeomAbs_C1, n > 2 ? static_cast<int>(v[2]) : 8,
              n > 3 ? static_cast<int>(v[3]) : 100, true, true);
      BRepTools_Modifier modifier(get(source), restriction);
      result = modifier.ModifiedShape(get(source));
    } else if (operation == "REVERSE NORMAL") {
      if (!source || !*source)
        return fail("REVERSE NORMAL requires a source shape", e, es);
      result = get(source).Reversed();
    } else if (operation == "OFFSET") {
      if (!source || !*source || n < 1)
        return fail("OFFSET requires source and distance", e, es);
      BRepOffsetAPI_MakeOffsetShape maker;
      maker.PerformByJoin(get(source), v[0], n > 1 ? v[1] : 1e-4);
      if (!maker.IsDone())
        return fail("BRepOffsetAPI_MakeOffsetShape failed", e, es);
      result = maker.Shape();
    } else if (operation == "OFFSET WALLS") {
      if (!source || !*source || n < 1)
        return fail("OFFSET WALLS requires source and distance", e, es);
      NCollection_List<TopoDS_Shape> closingFaces;
      for (const auto &id : ids) {
        const TopoDS_Shape candidate = get(id.c_str());
        if (candidate.ShapeType() != TopAbs_FACE)
          return fail("OFFSET WALLS opening selections must be Faces", e, es);
        closingFaces.Append(candidate);
      }
      const int mode = n > 5 ? static_cast<int>(v[5]) : 2;
      const int direction = n > 6 ? static_cast<int>(v[6]) : 1;
      const double tolerance = n > 1 ? v[1] : 1e-4;
      const double distance = direction < 0 ? -std::abs(v[0]) : std::abs(v[0]);
      if (direction == 2) {
        BRepOffsetAPI_MakeOffsetShape inside, outside;
        inside.PerformByJoin(get(source),
                             -(n > 7 ? std::abs(v[7]) : std::abs(v[0])),
                             tolerance);
        outside.PerformByJoin(get(source),
                              n > 8 ? std::abs(v[8]) : std::abs(v[0]),
                              tolerance);
        if (!inside.IsDone() || !outside.IsDone())
          return fail("Bilateral offset failed on one or both sides", e, es);
        TopoDS_Compound compound;
        BRep_Builder builder;
        builder.MakeCompound(compound);
        builder.Add(compound, inside.Shape());
        builder.Add(compound, outside.Shape());
        result = compound;
      } else if (mode <= 1) {
        BRepOffsetAPI_MakeOffsetShape maker;
        maker.PerformByJoin(get(source), distance, tolerance);
        if (!maker.IsDone())
          return fail("BRepOffsetAPI_MakeOffsetShape failed", e, es);
        result = maker.Shape();
      } else {
        BRepOffsetAPI_MakeThickSolid maker;
        maker.MakeThickSolidByJoin(
            get(source), closingFaces, distance, tolerance, BRepOffset_Skin,
            n > 2 && v[2] != 0, false,
            n > 3 && static_cast<int>(v[3]) == 1 ? GeomAbs_Intersection
                                                 : GeomAbs_Arc,
            n > 4 && v[4] != 0);
        if (!maker.IsDone())
          return fail("BRepOffsetAPI_MakeThickSolid failed", e, es);
        result = maker.Shape();
        if (mode == 3) {
          BRepCheck_Analyzer analyzer(result, true);
          TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
          TopExp::MapShapesAndAncestors(result, TopAbs_EDGE, TopAbs_FACE,
                                       edgeFaces);
          int freeEdges = 0;
          for (int index = 1; index <= edgeFaces.Extent(); ++index)
            if (edgeFaces.FindFromIndex(index).Extent() == 1)
              ++freeEdges;
          if (!analyzer.IsValid() || freeEdges != 0)
            return fail("OFFSET CLOSE did not produce a valid closed Shell", e,
                        es);
        }
      }
    } else if (operation == "TRIM") {
      if (!source || !*source || n < 4)
        return fail("TRIM requires source and uMin,uMax,vMin,vMax", e, es);
      const TopoDS_Face face = TopoDS::Face(get(source));
      Handle(Geom_Surface) surface = BRep_Tool::Surface(face);
      BRepBuilderAPI_MakeFace maker(surface, v[0], v[1], v[2], v[3],
                                    n > 4 ? v[4] : 1e-6);
      if (!maker.IsDone())
        return fail("BRepBuilderAPI_MakeFace trim failed", e, es);
      result = maker.Face();
    } else if (operation == "BOUNDARY TRIM") {
      if (!source || !*source || ids.empty())
        return fail("BOUNDARY TRIM requires source and a cutting shape", e,
                    es);
      BRepAlgoAPI_Splitter maker;
      NCollection_List<TopoDS_Shape> arguments, tools;
      arguments.Append(get(source));
      for (const auto &id : ids)
        tools.Append(get(id.c_str()));
      maker.SetArguments(arguments);
      maker.SetTools(tools);
      maker.SetFuzzyValue(n > 0 ? v[0] : 1e-7);
      maker.Build();
      if (!maker.IsDone())
        return fail("BRepAlgoAPI_Splitter boundary trim failed", e, es);
      if (n < 5 || v[4] == 0)
        return fail("BOUNDARY TRIM requires a viewport Keep Point", e, es);
      const TopoDS_Vertex keepPoint =
          BRepBuilderAPI_MakeVertex(gp_Pnt(v[1], v[2], v[3]));
      const double tolerance = v[0];
      double bestDistance = 1e100;
      int equallyValid = 0;
      for (TopExp_Explorer ex(maker.Shape(), TopAbs_FACE); ex.More(); ex.Next()) {
        BRepExtrema_DistShapeShape distance(keepPoint, ex.Current());
        distance.Perform();
        if (!distance.IsDone())
          continue;
        if (distance.Value() < bestDistance - tolerance) {
          bestDistance = distance.Value();
          result = ex.Current();
          equallyValid = 1;
        } else if (std::abs(distance.Value() - bestDistance) <= tolerance) {
          ++equallyValid;
        }
      }
      if (result.IsNull())
        return fail("BOUNDARY TRIM retained region does not exist", e, es);
      if (equallyValid > 1)
        return fail("BOUNDARY TRIM Keep Point is ambiguous; choose another point",
                    e, es);
    } else if (operation == "SPLIT") {
      if (!source || !*source || ids.empty())
        return fail("SPLIT requires source and tool shapes", e, es);
      BRepAlgoAPI_Splitter maker;
      NCollection_List<TopoDS_Shape> arguments, tools;
      arguments.Append(get(source));
      for (const auto &id : ids)
        tools.Append(get(id.c_str()));
      maker.SetArguments(arguments);
      maker.SetTools(tools);
      maker.Build();
      if (!maker.IsDone())
        return fail("BRepAlgoAPI_Splitter failed", e, es);
      result = maker.Shape();
    } else if (operation == "JOIN" || operation == "SEW") {
      BRepBuilderAPI_Sewing maker(n > 0 ? v[0] : 1e-4);
      if (source && *source)
        maker.Add(get(source));
      for (const auto &id : ids)
        maker.Add(get(id.c_str()));
      maker.Perform();
      result = maker.SewedShape();
    } else if (operation == "HEAL") {
      if (!source || !*source)
        return fail("HEAL requires a source shape", e, es);
      Handle(ShapeFix_Shape) maker = new ShapeFix_Shape(get(source));
      maker->Perform();
      result = maker->Shape();
    } else if (operation == "HEAL LOCAL") {
      if (!source || !*source)
        return fail("HEAL LOCAL requires selected Face or Wire", e, es);
      const TopoDS_Shape selected = get(source);
      if (selected.ShapeType() == TopAbs_FACE) {
        Handle(ShapeFix_Face) maker = new ShapeFix_Face(TopoDS::Face(selected));
        maker->Perform();
        result = maker->Face();
      } else if (selected.ShapeType() == TopAbs_WIRE) {
        Handle(ShapeFix_Wire) maker = new ShapeFix_Wire();
        maker->Load(TopoDS::Wire(selected));
        maker->Perform();
        result = maker->Wire();
      } else {
        return fail("HEAL LOCAL supports Face or Wire selection", e, es);
      }
    } else if (operation == "UNSEW FACE" ||
               operation == "UNSEW SELECTED" || operation == "UNSEW ALL") {
      if (!source || !*source)
        return fail("UNSEW requires a source Shell or Body", e, es);
      TopoDS_Compound compound;
      BRep_Builder builder;
      builder.MakeCompound(compound);
      int faceCount = 0;
      auto appendIndependent = [&](const TopoDS_Shape &face) {
        BRepBuilderAPI_Copy copier(face, true, true);
        builder.Add(compound, copier.Shape());
        ++faceCount;
      };
      if (operation == "UNSEW ALL") {
        for (TopExp_Explorer ex(get(source), TopAbs_FACE); ex.More(); ex.Next())
          appendIndependent(ex.Current());
      } else {
        for (const auto &id : ids) {
          const TopoDS_Shape selected = get(id.c_str());
          if (selected.ShapeType() != TopAbs_FACE)
            return fail("UNSEW selections must be Faces", e, es);
          appendIndependent(selected);
        }
      }
      if (faceCount == 0)
        return fail("UNSEW selected no Faces", e, es);
      result = compound;
    } else if (operation == "REPLACE FACE") {
      if (!source || !*source || ids.size() < 2)
        return fail("REPLACE FACE requires owner, old Face and replacement Face",
                    e, es);
      Handle(ShapeBuild_ReShape) reshape = new ShapeBuild_ReShape();
      reshape->Replace(get(ids[0].c_str()), get(ids[1].c_str()));
      result = reshape->Apply(get(source));
      if (!BRepCheck_Analyzer(result, true).IsValid())
        return fail("REPLACE FACE produced invalid topology", e, es);
    } else if (operation == "DELETE FACE") {
      if (!source || !*source || ids.empty())
        return fail("DELETE FACE requires owner and selected Face(s)", e, es);
      Handle(ShapeBuild_ReShape) reshape = new ShapeBuild_ReShape();
      for (const auto &id : ids)
        reshape->Remove(get(id.c_str()));
      result = reshape->Apply(get(source));
    } else if (operation == "MERGE FACES") {
      if (!source || !*source)
        return fail("MERGE FACES requires a source shape", e, es);
      ShapeUpgrade_UnifySameDomain maker(get(source), false, true, false);
      maker.Build();
      result = maker.Shape();
    } else if (operation == "BOUNDARY") {
      if (!source || !*source)
        return fail("BOUNDARY requires a source shape", e, es);
      TopoDS_Compound compound;
      BRep_Builder builder;
      builder.MakeCompound(compound);
      for (TopExp_Explorer ex(get(source), TopAbs_EDGE); ex.More(); ex.Next())
        builder.Add(compound, ex.Current());
      result = compound;
    } else if (operation == "FILLET") {
      std::vector<TopoDS_Shape> supports;
      std::vector<TopoDS_Edge> requestedEdges;
      // The adapter sends the primary support through source_token and the
      // remaining supports/selected edges through reference_tokens.
      if (source && *source)
        supports.push_back(get(source));
      for (const auto &id : ids) {
        const TopoDS_Shape candidate = get(id.c_str());
        if (candidate.ShapeType() == TopAbs_EDGE)
          requestedEdges.push_back(TopoDS::Edge(candidate));
        else
          supports.push_back(candidate);
      }
      if (supports.empty())
        return fail("Surface Fillet requires support geometry", e, es);
      TopoDS_Shape owner;
      if (supports.size() == 1 &&
          (supports.front().ShapeType() == TopAbs_SOLID ||
           supports.front().ShapeType() == TopAbs_SHELL)) {
        owner = supports.front();
      } else {
        BRepBuilderAPI_Sewing sewing(
            n > 7 && v[6] != 0 ? std::max(1e-4, v[7]) : 1e-4);
        for (const auto &support : supports)
          sewing.Add(support);
        sewing.Perform();
        owner = sewing.SewedShape();
      }
      std::vector<TopoDS_Edge> ownerEdges;
      for (TopExp_Explorer ex(owner, TopAbs_EDGE); ex.More(); ex.Next())
        ownerEdges.push_back(TopoDS::Edge(ex.Current()));
      std::vector<TopoDS_Edge> edges;
      for (const auto &requested : requestedEdges) {
        double best = 1e100;
        TopoDS_Edge match;
        for (const auto &candidate : ownerEdges) {
          BRepExtrema_DistShapeShape distance(requested, candidate);
          distance.Perform();
          if (distance.IsDone() && distance.Value() < best) {
            best = distance.Value();
            match = candidate;
          }
        }
        if (!match.IsNull() && best <= (n > 7 && v[6] != 0 ? v[7] : 1e-4))
          edges.push_back(match);
      }
      const int selectionMode = n > 8 ? static_cast<int>(v[8]) : 0;
      if (edges.empty() && selectionMode == 3) {
        edges = ownerEdges;
      } else if (edges.empty()) {
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(owner, TopAbs_EDGE, TopAbs_FACE,
                                     edgeFaces);
        for (int index = 1; index <= edgeFaces.Extent(); ++index) {
          if (edgeFaces.FindFromIndex(index).Extent() >= 2)
            edges.push_back(TopoDS::Edge(edgeFaces.FindKey(index)));
        }
      }
      if (edges.empty())
        return fail("Surface Fillet found no compatible Edge", e, es);
      const int sizeMode = n > 0 ? static_cast<int>(v[0]) : 0;
      const double radius = n > 1 ? v[1] : 5.0;
      const double width = n > 2 ? v[2] : radius;
      const bool trim = n <= 3 || v[3] != 0;
      BRepFilletAPI_MakeFillet maker(owner);
      maker.SetContinuity(n > 5 && static_cast<int>(v[5]) == 0
                              ? GeomAbs_C0
                              : GeomAbs_C1,
                          1e-3);
      if (sizeMode == 2)
        maker.SetFilletShape(ChFi3d_QuasiAngular);
      const int pointCount = n > 9 ? static_cast<int>(v[9]) : 0;
      for (const auto &edge : edges) {
        if (sizeMode == 1 && pointCount >= 2 &&
            n >= static_cast<size_t>(10 + pointCount * 2)) {
          NCollection_Array1<gp_Pnt2d> values(1, pointCount);
          for (int pointIndex = 0; pointIndex < pointCount; ++pointIndex)
            values.SetValue(
                pointIndex + 1,
                gp_Pnt2d(v[10 + pointIndex * 2],
                         v[11 + pointIndex * 2]));
          maker.Add(values, edge);
        } else {
          maker.Add(sizeMode == 2 ? width : radius, edge);
        }
      }
      maker.Build();
      if (!maker.IsDone())
        return fail("Professional Surface Fillet failed", e, es);
      if (trim) {
        result = maker.Shape();
      } else {
        TopoDS_Compound compound;
        BRep_Builder builder;
        builder.MakeCompound(compound);
        for (const auto &edge : edges) {
          const TopTools_ListOfShape &generated = maker.Generated(edge);
          for (TopTools_ListOfShape::Iterator it(generated); it.More();
               it.Next())
            if (it.Value().ShapeType() == TopAbs_FACE)
              builder.Add(compound, it.Value());
        }
        result = compound;
      }
    } else if (operation == "BLEND") {
      std::vector<TopoDS_Face> supportFaces;
      if (source && *source)
        supportFaces.push_back(first_face(get(source)));
      std::vector<TopoDS_Edge> blendEdges;
      for (const auto &id : ids) {
        const TopoDS_Shape candidate = get(id.c_str());
        if (candidate.ShapeType() == TopAbs_FACE)
          supportFaces.push_back(TopoDS::Face(candidate));
        if (candidate.ShapeType() == TopAbs_EDGE)
          blendEdges.push_back(TopoDS::Edge(candidate));
      }
      if (supportFaces.size() != 2 || blendEdges.size() != 2)
        return fail("BLEND requires two support Faces and one Edge from each Face",
                    e, es);
      BRepOffsetAPI_MakeFilling maker(
          3, 15, 2, false,
          n > 2 ? v[2] : 1e-4, n > 2 ? v[2] : 1e-4,
          n > 3 ? v[3] : 1e-3, .1, 1e-2);
      for (size_t side = 0; side < 2; ++side) {
        const int requested = n > 4 + side * 2
                                  ? static_cast<int>(v[4 + side * 2])
                                  : 0;
        const double influence = n > 5 + side * 2
                                     ? std::max(.05, std::min(1.0, v[5 + side * 2]))
                                     : 1.0;
        if (requested == 1) {
          Standard_Real first = 0.0, last = 0.0;
          TopLoc_Location location;
          Handle(Geom_Curve) curve =
              BRep_Tool::Curve(blendEdges[side], location, first, last);
          if (curve.IsNull())
            return fail("Blend boundary has no geometric curve", e, es);
          if (!location.IsIdentity())
            curve = Handle(Geom_Curve)::DownCast(
                curve->Transformed(location.Transformation()));
          const int segments = 1 + static_cast<int>(std::round(influence * 7));
          for (int segment = 0; segment < segments; ++segment) {
            const double a = first + (last - first) * segment / segments;
            const double b = first + (last - first) * (segment + 1) / segments;
            BRepBuilderAPI_MakeEdge part(curve, a, b);
            if (!part.IsDone())
              return fail("Blend influence subdivision failed", e, es);
            maker.Add(part.Edge(), supportFaces[side], GeomAbs_C1);
          }
        } else {
          maker.Add(blendEdges[side], GeomAbs_C0);
        }
      }
      maker.Build();
      if (!maker.IsDone())
        return fail("Blend filling failed for the selected boundaries", e, es);
      result = maker.Shape();
    } else if (operation == "MATCH") {
      if (!source || !*source || ids.empty())
        return fail("MATCH requires a source Face and target geometry", e, es);
      const TopoDS_Face sourceFace = first_face(get(source));
      TopoDS_Face supportFace;
      TopoDS_Edge targetEdge;
      for (const auto &id : ids) {
        const TopoDS_Shape candidate = get(id.c_str());
        if (candidate.ShapeType() == TopAbs_FACE && supportFace.IsNull())
          supportFace = TopoDS::Face(candidate);
        if (candidate.ShapeType() == TopAbs_EDGE && targetEdge.IsNull())
          targetEdge = TopoDS::Edge(candidate);
      }
      if (supportFace.IsNull())
        supportFace = first_face(get(ids.front().c_str()));
      if (targetEdge.IsNull())
        targetEdge = first_edge(supportFace);

      const int continuity = n > 0
                                 ? std::max(0, std::min(2, static_cast<int>(v[0])))
                                 : 0;
      const int points = n > 1 ? std::max(4, static_cast<int>(v[1])) : 10;
      const double tol3d = n > 2 ? v[2] : 1e-4;
      const double tolAng = n > 3 ? v[3] : 1e-2;
      const double tolCurv = n > 4 ? v[4] : 1e-1;
      Handle(Adaptor3d_Curve) constraintCurve;
      if (continuity == 0) {
        constraintCurve = new BRepAdaptor_Curve(targetEdge);
      } else {
        double first = 0, last = 0;
        Handle(Geom2d_Curve) curve2d =
            BRep_Tool::CurveOnSurface(targetEdge, supportFace, first, last);
        if (curve2d.IsNull())
          return fail("MATCH G1/G2 target Edge has no curve on support Face",
                      e, es);
        Handle(Adaptor2d_Curve2d) curveAdaptor =
            new Geom2dAdaptor_Curve(curve2d, first, last);
        Handle(Adaptor3d_Surface) surfaceAdaptor = new GeomAdaptor_Surface(
            BRep_Tool::Surface(supportFace));
        constraintCurve =
            new Adaptor3d_CurveOnSurface(curveAdaptor, surfaceAdaptor);
      }
      GeomPlate_BuildPlateSurface plate(
          BRep_Tool::Surface(sourceFace), n > 5 ? static_cast<int>(v[5]) : 3,
          points, n > 6 ? static_cast<int>(v[6]) : 3,
          n > 7 ? v[7] : 1e-5, tol3d, tolAng, tolCurv, false);
      plate.Add(new GeomPlate_CurveConstraint(
          constraintCurve, continuity, points, tol3d, tolAng, tolCurv));
      plate.SetNbBounds(1);
      plate.Perform();
      if (!plate.IsDone())
        return fail("GeomPlate_BuildPlateSurface MATCH failed", e, es);
      GeomPlate_MakeApprox approximation(
          plate.Surface(), tol3d, n > 8 ? static_cast<int>(v[8]) : 100,
          n > 9 ? static_cast<int>(v[9]) : 8, tol3d, continuity > 0 ? 1 : 0,
          GeomAbs_C1);
      BRepBuilderAPI_MakeFace faceMaker(approximation.Surface(), tol3d);
      if (!faceMaker.IsDone())
        return fail("MATCH BSpline Face construction failed", e, es);
      result = faceMaker.Face();
    } else if (operation == "FAIR") {
      return fail("OCCT 8.0.1 has no general-purpose surface fairing operator",
                  e, es);
    } else if (operation == "MORPH") {
      return fail("OCCT 8.0.1 has no general-purpose surface morphing operator",
                  e, es);
    } else {
      return fail("No OCCT 8.0.1 surface operator mapping for " + operation, e,
                  es);
    }
    if (result.IsNull())
      return fail("OCCT surface operation produced a null shape", e, es);
    return output(result, t, ts, f, fs, e, es, ty, tys, true);
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_export_shape(const char *id, const char *p, const char *fmt,
                           char *e, size_t es) {
  try {
    auto s = get(id);
    std::string format = fmt ? fmt : "";
    if (format == "step") {
      STEPControl_Writer w;
      w.Transfer(s, STEPControl_AsIs);
      if (w.Write(p) != IFSelect_RetDone)
        return fail("STEP write failed", e, es);
    } else if (format == "iges") {
      IGESControl_Writer w;
      w.AddShape(s);
      if (!w.Write(p))
        return fail("IGES write failed", e, es);
    } else if (!BRepTools::Write(s, p))
      return fail("BREP write failed", e, es);
    return 1;
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  }
}
int flcad_occ_validate(const char *id, char *out, size_t os, char *e,
                       size_t es) {
  try {
    auto s = get(id);
    BRepCheck_Analyzer a(s, true);
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(s, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    int openEdges = 0, nonManifoldEdges = 0;
    for (int index = 1; index <= edgeFaces.Extent(); ++index) {
      const int adjacent = edgeFaces.FindFromIndex(index).Extent();
      if (adjacent == 1)
        ++openEdges;
      else if (adjacent > 2)
        ++nonManifoldEdges;
    }
    double maximumTolerance = 0.0;
    for (TopExp_Explorer ex(s, TopAbs_VERTEX); ex.More(); ex.Next())
      maximumTolerance = std::max(
          maximumTolerance, BRep_Tool::Tolerance(TopoDS::Vertex(ex.Current())));
    for (TopExp_Explorer ex(s, TopAbs_EDGE); ex.More(); ex.Next())
      maximumTolerance = std::max(
          maximumTolerance, BRep_Tool::Tolerance(TopoDS::Edge(ex.Current())));
    for (TopExp_Explorer ex(s, TopAbs_FACE); ex.More(); ex.Next())
      maximumTolerance = std::max(
          maximumTolerance, BRep_Tool::Tolerance(TopoDS::Face(ex.Current())));
    std::ostringstream json;
    json.exceptions(std::ios::badbit | std::ios::failbit);
    json << '[';
    bool first = true;
    auto diagnostic = [&](const char *code, const char *severity,
                          const std::string &message) {
      if (!first)
        json << ',';
      first = false;
      json << "{\"code\":\"" << code << "\",\"severity\":\"" << severity
           << "\",\"message\":\"" << message << "\"}";
    };
    if (!a.IsValid())
      diagnostic("brep-invalid", "error", "BRepCheck rejected shape");
    if (nonManifoldEdges > 0)
      diagnostic("non-manifold-edges", "error",
                 std::to_string(nonManifoldEdges) +
                     " edge(s) have more than two adjacent faces");
    if (openEdges > 0)
      diagnostic("open-boundaries", "warning",
                 std::to_string(openEdges) +
                     " boundary edge(s) have one adjacent face");
    if (maximumTolerance > 1e-3)
      diagnostic("high-tolerance", "warning",
                 "Maximum topology tolerance is " +
                     std::to_string(maximumTolerance));
    if (first)
      diagnostic("brep-valid", "info",
                 "BRep is valid, manifold and has no open boundary edges");
    json << ']';
    copy(json.str(), out, os);
    return 1;
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_healing_proposals(const char *id, char *out, size_t os, char *e,
                                size_t es) {
  try {
    auto s = get(id);
    Handle(ShapeFix_Shape) fix = new ShapeFix_Shape(s);
    fix->Perform();
    copy(fix->Status(ShapeExtend_DONE)
             ? "[{\"id\":\"shape-fix\",\"operation\":\"fix-shape\",\"reason\":"
               "\"ShapeFix reports available corrections\"}]"
             : "[]",
         out, os);
    return 1;
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  } catch (const std::exception &x) {
    return fail(x.what(), e, es);
  } catch (...) {
    return fail("Unknown native exception", e, es);
  }
}
int flcad_occ_mesh(const char *id, const char *p, double deflection, int *v,
                   int *t, char *e, size_t es) {
  try {
    auto s = get(id);
    BRepMesh_IncrementalMesh mesh(s, deflection, false, 0.5, true);
    int vertices = 0, triangles = 0;
    for (TopExp_Explorer ex(s, TopAbs_FACE); ex.More(); ex.Next()) {
      TopLoc_Location loc;
      auto tri = BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), loc);
      if (!tri.IsNull()) {
        vertices += tri->NbNodes();
        triangles += tri->NbTriangles();
      }
    }
    if (vertices <= 0 || triangles <= 0)
      return fail("Meshing produced no geometry", e, es);
    *v = vertices;
    *t = triangles;
    StlAPI_Writer writer;
    writer.ASCIIMode() = Standard_False;
    if (!writer.Write(s, p))
      return fail("STL write failed", e, es);
    return 1;
  } catch (const Standard_Failure &x) {
    return fail(x.GetMessageString(), e, es);
  }
}
size_t flcad_occ_shape_count() {
  std::lock_guard<std::mutex> lock(registry_mutex);
  return shapes.size();
}
}
