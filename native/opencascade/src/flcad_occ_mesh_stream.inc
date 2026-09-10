// Included in the registry translation unit; no new registry or token.
#include "flcad_occ_mesh_stream.h"
#include <array>

namespace {
#ifdef FLCAD_OCC_TESTING
thread_local int stream_fault_point = 0, stream_fault_kind = 0;
thread_local uint64_t stream_count_override = 0;
void stream_inject(int point) {
  if (stream_fault_point != point)
    return;
  stream_fault_point = 0;
  if (stream_fault_kind == 1)
    throw Standard_Failure("stream OCCT fault");
  if (stream_fault_kind == 2)
    throw 42;
  throw std::runtime_error("stream standard fault");
}
#else
void stream_inject(int) {}
#endif
struct StreamStop {};
void stream_u32(uint8_t *p, uint32_t v) {
  for (int i = 0; i < 4; ++i)
    p[i] = static_cast<uint8_t>(v >> (8 * i));
}
void stream_float(uint8_t *p, double value) {
  if (!std::isfinite(value) ||
      std::abs(value) > std::numeric_limits<float>::max())
    throw std::overflow_error("STL float32 coordinate out of range");
  const float f = static_cast<float>(value);
  uint32_t bits;
  static_assert(sizeof(f) == 4 && std::numeric_limits<float>::is_iec559);
  std::memcpy(&bits, &f, 4);
  stream_u32(p, bits);
}
void stream_add_count(uint64_t &total, uint64_t n, uint64_t limit) {
  if (n > limit || total > limit - n)
    throw std::overflow_error("STL triangle limit exceeded");
  total += n;
}
} // namespace
extern "C" uint32_t OCC_STREAM_CALL flcad_occ_mesh_stream_version(void) {
  return 1;
}
extern "C" int32_t OCC_STREAM_CALL flcad_occ_mesh_stream_v1(
    const char *shape_token, double deflection, double angle, uint64_t limit,
    const occ_stream_sink_v1 *input, occ_stream_result_v1 *out,
    uint32_t out_size) {
  if (!out || out_size != sizeof(*out))
    return OCC_STREAM_INVALID;
  *out = {};
  out->version = 1;
  out->accepted_count_valid = 1;
  uint32_t phase = OCC_STREAM_INVALID;
  auto error = [&](uint32_t status, const char *message) {
    out->status = status;
    fail(message, out->message, sizeof(out->message));
    return static_cast<int32_t>(status);
  };
  try {
    if (!input || input->size != sizeof(*input) || input->version != 1 ||
        !input->write || !shape_token || !std::isfinite(deflection) ||
        deflection < 1e-6 || deflection > 1e6 || !std::isfinite(angle) ||
        angle < 1e-4 || angle > 3.141592653589793 || !limit ||
        limit > UINT32_MAX)
      return error(OCC_STREAM_INVALID,
                   "Invalid stream arguments/version/budget");
    const auto sink = *input;
    phase = OCC_STREAM_SHAPE;
    const auto borrowed = get(
        shape_token); // live OCCT reference, no registry lock during callbacks
    phase = OCC_STREAM_TESSELLATION;
    stream_inject(1);
    BRepBuilderAPI_Copy copier(borrowed, true, false);
    auto shape = copier.Shape();
    BRepMesh_IncrementalMesh mesher(shape, deflection, false, angle, false);
    if (!mesher.IsDone())
      return error(phase, "Tessellation did not complete");
    phase = OCC_STREAM_SERIALIZATION;
    uint64_t count = 0;
    for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
      TopLoc_Location loc;
      auto tri = BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), loc);
      if (!tri.IsNull())
        stream_add_count(count, static_cast<uint64_t>(tri->NbTriangles()),
                         limit);
    }
#ifdef FLCAD_OCC_TESTING
    if (stream_count_override)
      stream_add_count(count, stream_count_override, limit);
#endif
    if (!count)
      return error(OCC_STREAM_TESSELLATION, "Shape has no triangles");
    out->triangles = count;
    std::array<uint8_t, 64000> buffer{};
    size_t used = 84;
    const char header[] = "FLCAD binary STL stream v1";
    std::memcpy(buffer.data(), header, sizeof(header) - 1);
    stream_u32(buffer.data() + 80, static_cast<uint32_t>(count));
    auto flush = [&]() {
      if (!used)
        return;
      phase = OCC_STREAM_SINK;
      uint32_t accepted = 0;
      stream_inject(2);
      int32_t code = 0;
      try {
        code = sink.write(sink.context, buffer.data(),
                          static_cast<uint32_t>(used), &accepted);
      } catch (const Standard_Failure &e) {
        out->accepted_count_valid = 0;
        error(OCC_STREAM_SINK, e.GetMessageString());
        throw StreamStop{};
      } catch (const std::exception &e) {
        out->accepted_count_valid = 0;
        error(OCC_STREAM_SINK, e.what());
        throw StreamStop{};
      } catch (...) {
        out->accepted_count_valid = 0;
        error(OCC_STREAM_SINK, "Unknown consumer exception");
        throw StreamStop{};
      }
      out->consumer_code = code;
      if (accepted > used) {
        out->accepted_count_valid = 0;
        error(OCC_STREAM_SINK, "Sink returned invalid accepted count");
        throw StreamStop{};
      }
      out->bytes_accepted += accepted;
      if (code != 0 || accepted != used) {
        error(code == -1 ? OCC_STREAM_CANCELLED : OCC_STREAM_SINK,
              "Sink stopped stream; accepted prefix retained");
        throw StreamStop{};
      }
      used = 0;
      phase = OCC_STREAM_SERIALIZATION;
      stream_inject(3);
    };
    uint64_t emitted = 0;
    for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
      const auto face = TopoDS::Face(ex.Current());
      TopLoc_Location loc;
      const auto tri = BRep_Tool::Triangulation(face, loc);
      if (tri.IsNull())
        continue;
      for (int i = 0; i < tri->NbTriangles(); ++i) {
        if (used + 50 > buffer.size())
          flush();
        int a, b, c;
        tri->Triangle(i + 1).Get(a, b, c);
        if (face.Orientation() == TopAbs_REVERSED)
          std::swap(b, c);
        const auto p1 = tri->Node(a).Transformed(loc.Transformation());
        const auto p2 = tri->Node(b).Transformed(loc.Transformation());
        const auto p3 = tri->Node(c).Transformed(loc.Transformation());
        gp_Vec normal = gp_Vec(p1, p2).Crossed(gp_Vec(p1, p3));
        const double length = normal.Magnitude();
        if (!std::isfinite(length))
          throw std::overflow_error("STL normal out of range");
        if (length > gp::Resolution())
          normal /= length;
        else
          normal = gp_Vec(0, 0, 0);
        auto p = buffer.data() + used;
        stream_float(p, normal.X());
        stream_float(p + 4, normal.Y());
        stream_float(p + 8, normal.Z());
        for (const auto &point : {p1, p2, p3}) {
          p += 12;
          stream_float(p, point.X());
          stream_float(p + 4, point.Y());
          stream_float(p + 8, point.Z());
        }
        p[12] = p[13] = 0;
        used += 50;
        ++emitted;
      }
    }
    if (emitted != count)
      return error(OCC_STREAM_SERIALIZATION, "Triangle count changed");
    flush();
    out->status = OCC_STREAM_OK;
    return OCC_STREAM_OK;
  } catch (const StreamStop &) {
    return static_cast<int32_t>(out->status);
  } catch (const std::overflow_error &e) {
    return error(OCC_STREAM_LIMIT, e.what());
  } catch (const Standard_Failure &e) {
    return error(phase, e.GetMessageString());
  } catch (const std::exception &e) {
    return error(phase, e.what());
  } catch (...) {
    return error(phase, "Unknown stream exception");
  }
}

extern "C" int32_t OCC_STREAM_CALL flcad_occ_triangulation_stream_v1(
    const char *mesh_token, uint64_t limit, const occ_stream_sink_v1 *input,
    occ_stream_result_v1 *out, uint32_t out_size) {
  if (!out || out_size != sizeof(*out))
    return OCC_STREAM_INVALID;
  *out = {};
  out->version = 1;
  out->accepted_count_valid = 1;
  uint32_t phase = OCC_STREAM_INVALID;
  auto error = [&](uint32_t status, const char *message) {
    out->status = status;
    fail(message, out->message, sizeof(out->message));
    return static_cast<int32_t>(status);
  };
  try {
    if (!input || input->size != sizeof(*input) || input->version != 1 ||
        !input->write || !mesh_token || !*mesh_token || !limit ||
        limit > UINT32_MAX)
      return error(OCC_STREAM_INVALID,
                   "Invalid stream arguments/version/budget");
    const auto sink = *input;
    phase = OCC_STREAM_SHAPE;
    Handle(Poly_Triangulation) mesh;
    {
      std::lock_guard<std::mutex> lock(registry_mutex);
      const auto found = meshes.find(mesh_token);
      if (found == meshes.end())
        return error(phase, "Unknown native mesh token");
      mesh = found->second;
    }
    phase = OCC_STREAM_SERIALIZATION;
    const auto count = static_cast<uint64_t>(mesh->NbTriangles());
    if (!count)
      return error(OCC_STREAM_TESSELLATION, "Mesh has no triangles");
    if (count > limit)
      return error(OCC_STREAM_LIMIT, "STL triangle limit exceeded");
    out->triangles = count;
    std::array<uint8_t, 64000> buffer{};
    size_t used = 84;
    const char header[] = "FLCAD binary STL triangulation stream v1";
    std::memcpy(buffer.data(), header, sizeof(header) - 1);
    stream_u32(buffer.data() + 80, static_cast<uint32_t>(count));
    auto flush = [&]() {
      if (!used)
        return;
      phase = OCC_STREAM_SINK;
      uint32_t accepted = 0;
      int32_t code = 0;
      try {
        code = sink.write(sink.context, buffer.data(),
                          static_cast<uint32_t>(used), &accepted);
      } catch (const Standard_Failure &e) {
        out->accepted_count_valid = 0;
        error(OCC_STREAM_SINK, e.GetMessageString());
        throw StreamStop{};
      } catch (const std::exception &e) {
        out->accepted_count_valid = 0;
        error(OCC_STREAM_SINK, e.what());
        throw StreamStop{};
      } catch (...) {
        out->accepted_count_valid = 0;
        error(OCC_STREAM_SINK, "Unknown consumer exception");
        throw StreamStop{};
      }
      out->consumer_code = code;
      if (accepted > used) {
        out->accepted_count_valid = 0;
        error(OCC_STREAM_SINK, "Sink returned invalid accepted count");
        throw StreamStop{};
      }
      out->bytes_accepted += accepted;
      if (code != 0 || accepted != used) {
        error(code == -1 ? OCC_STREAM_CANCELLED : OCC_STREAM_SINK,
              "Sink stopped stream; accepted prefix retained");
        throw StreamStop{};
      }
      used = 0;
      phase = OCC_STREAM_SERIALIZATION;
    };
    for (int i = 1; i <= mesh->NbTriangles(); ++i) {
      if (used + 50 > buffer.size())
        flush();
      int a, b, c;
      mesh->Triangle(i).Get(a, b, c);
      const auto p1 = mesh->Node(a);
      const auto p2 = mesh->Node(b);
      const auto p3 = mesh->Node(c);
      gp_Vec normal = gp_Vec(p1, p2).Crossed(gp_Vec(p1, p3));
      const double length = normal.Magnitude();
      if (!std::isfinite(length))
        throw std::overflow_error("STL normal out of range");
      if (length > gp::Resolution())
        normal /= length;
      else
        normal = gp_Vec(0, 0, 0);
      auto p = buffer.data() + used;
      stream_float(p, normal.X());
      stream_float(p + 4, normal.Y());
      stream_float(p + 8, normal.Z());
      for (const auto &point : {p1, p2, p3}) {
        p += 12;
        stream_float(p, point.X());
        stream_float(p + 4, point.Y());
        stream_float(p + 8, point.Z());
      }
      p[12] = p[13] = 0;
      used += 50;
    }
    flush();
    out->status = OCC_STREAM_OK;
    return OCC_STREAM_OK;
  } catch (const StreamStop &) {
    return static_cast<int32_t>(out->status);
  } catch (const std::overflow_error &e) {
    return error(OCC_STREAM_LIMIT, e.what());
  } catch (const Standard_Failure &e) {
    return error(phase, e.GetMessageString());
  } catch (const std::exception &e) {
    return error(phase, e.what());
  } catch (...) {
    return error(phase, "Unknown stream exception");
  }
}
