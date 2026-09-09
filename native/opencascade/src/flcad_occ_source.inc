#include "flcad_occ_source.h"
#include <Message_ProgressIndicator.hxx>
#include <atomic>
#include <charconv>
#include <map>
#include <thread>
namespace {
thread_local bool source_active = false;
#ifdef FLCAD_OCC_TESTING
thread_local int source_fault = 0, source_fault_kind = 0;
void source_inject(int point) {
  if (source_fault != point)
    return;
  source_fault = 0;
  if (source_fault_kind == 1)
    throw Standard_Failure("source OCCT fault");
  if (source_fault_kind == 2)
    throw 42;
  throw std::runtime_error("source standard fault");
}
#else
void source_inject(int) {}
#endif
struct SourceFailure {};
class SourceInput final : public std::streambuf {
  occ_source_v1 source;
  const occ_read_limits_v1 &limits;
  occ_read_result_v1 &result;
  std::array<char, 65536> buffer{};
  uint64_t base = 0;
  bool stopped = false, closed = false;
  template <class Call> int32_t callback(Call call, occ_source_io_v1 &io) {
    try {
      return call();
    } catch (const Standard_Failure &e) {
      result.count_valid = 0;
      stop(OCC_READ_SOURCE, e.GetMessageString());
    } catch (const std::exception &e) {
      result.count_valid = 0;
      stop(OCC_READ_SOURCE, e.what());
    } catch (...) {
      result.count_valid = 0;
      stop(OCC_READ_SOURCE, "Unknown source exception");
    }
    return 0;
  }
  void inspect_io(const occ_source_io_v1 &io) {
    if (io.size != sizeof(io) || io.version != 1 || (io.flags & ~3u) ||
        !(io.flags & 1)) {
      result.count_valid = 0;
      stop(OCC_READ_SOURCE, "Invalid source result/count");
    }
  }

protected:
  int_type underflow() override {
    if (stopped || closed)
      throw SourceFailure{};
    if (gptr() && gptr() < egptr())
      return traits_type::to_int_type(*gptr());
    const auto pos = position();
    if (pos == source.length)
      return traits_type::eof();
    check(0);
    auto n = static_cast<uint32_t>(
        std::min<uint64_t>(buffer.size(), source.length - pos));
    if (n > limits.max_read_bytes - result.bytes_provided)
      stop(OCC_READ_LIMIT, "Transport byte budget exceeded");
    const auto prior_phase = result.phase;
    result.phase = OCC_READ_TRANSPORT;
    occ_source_io_v1 io{sizeof(io), 1, 0, 1, 0, 0, 0};
    const int32_t code = callback(
        [&] {
          return source.read_at(source.context, pos,
                                reinterpret_cast<uint8_t *>(buffer.data()), n,
                                &io);
        },
        io);
    inspect_io(io);
    if (io.bytes_read > n) {
      result.count_valid = 0;
      stop(OCC_READ_SOURCE, "Source count exceeds destination");
    }
    result.bytes_provided += io.bytes_read;
    if (code) {
      result.error_domain = io.error_domain;
      result.error_code = io.error_code ? io.error_code : code;
      result.detail = io.detail;
      stop(code == -1 ? OCC_READ_CANCELLED : OCC_READ_SOURCE,
           "Source read failed");
    }
    if (!io.bytes_read ||
        ((io.flags & 2) && pos + io.bytes_read != source.length))
      stop(OCC_READ_TRUNCATED, "Premature source EOF/zero read");
    result.phase = prior_phase;
    base = pos;
    setg(buffer.data(), buffer.data(), buffer.data() + io.bytes_read);
    return traits_type::to_int_type(*gptr());
  }
  std::streamsize xsgetn(char *dst, std::streamsize count) override {
    if (stopped || closed)
      throw SourceFailure{};
    if (count < 0)
      stop(OCC_READ_INVALID, "Negative read length");
    std::streamsize copied = 0;
    while (copied < count) {
      if (traits_type::eq_int_type(underflow(), traits_type::eof()))
        break;
      const auto n = static_cast<int>(
          std::min<std::streamsize>(count - copied, egptr() - gptr()));
      std::memcpy(dst + copied, gptr(), n);
      gbump(n);
      copied += n;
    }
    return copied;
  }
  pos_type seekoff(off_type off, std::ios_base::seekdir dir,
                   std::ios_base::openmode mode) override {
    if (stopped || closed)
      throw SourceFailure{};
    if (!(mode & std::ios::in) || (mode & std::ios::out))
      stop(OCC_READ_INVALID, "Invalid seek mode");
    uint64_t start = dir == std::ios::beg   ? 0
                     : dir == std::ios::cur ? position()
                                            : source.length;
    if (dir != std::ios::beg && dir != std::ios::cur && dir != std::ios::end)
      stop(OCC_READ_INVALID, "Invalid seek direction");
    uint64_t target;
    if (off >= 0) {
      if (static_cast<uint64_t>(off) > source.length - start)
        stop(OCC_READ_INVALID, "Seek beyond source");
      target = start + static_cast<uint64_t>(off);
    } else {
      uint64_t distance = static_cast<uint64_t>(-(off + 1)) + 1;
      if (distance > start)
        stop(OCC_READ_INVALID, "Seek before source");
      target = start - distance;
    }
    base = target;
    setg(nullptr, nullptr, nullptr);
    return pos_type(static_cast<off_type>(target));
  }
  pos_type seekpos(pos_type pos, std::ios_base::openmode mode) override {
    return seekoff(static_cast<off_type>(pos), std::ios::beg, mode);
  }
  int_type pbackfail(int_type c = traits_type::eof()) override {
    if (stopped || closed)
      throw SourceFailure{};
    const auto pos = position();
    if (!pos)
      stop(OCC_READ_INVALID, "Putback before source");
    seekoff(static_cast<off_type>(pos - 1), std::ios::beg, std::ios::in);
    const auto actual = underflow();
    if (!traits_type::eq_int_type(c, traits_type::eof()) && c != actual)
      stop(OCC_READ_INVALID, "Putback changes source");
    return traits_type::not_eof(c);
  }

public:
  SourceInput(occ_source_v1 s, const occ_read_limits_v1 &l,
              occ_read_result_v1 &r)
      : source(s), limits(l), result(r) {}
  uint64_t position() const {
    return base + (gptr() ? static_cast<uint64_t>(gptr() - eback()) : 0);
  }
  uint64_t length() const { return source.length; }
  [[noreturn]] void stop(uint32_t status, const char *message) {
    if (!stopped) {
      result.status = status;
      fail(message, result.message, sizeof(result.message));
    }
    stopped = true;
    setg(nullptr, nullptr, nullptr);
    throw SourceFailure{};
  }
  void phase(uint32_t value) { result.phase = value; }
  bool failed() const { return stopped; }
  void check(uint32_t phase) {
    if (stopped || closed)
      throw SourceFailure{};
    occ_source_io_v1 io{sizeof(io), 1, 0, 1, 0, 0, 0};
    const auto code =
        callback([&] { return source.check(source.context, phase, &io); }, io);
    inspect_io(io);
    if (io.bytes_read)
      stop(OCC_READ_SOURCE, "check must not return transport bytes");
    if (code) {
      result.error_domain = io.error_domain;
      result.error_code = io.error_code ? io.error_code : code;
      result.detail = io.detail;
      stop(code == -1 ? OCC_READ_CANCELLED : OCC_READ_SOURCE,
           "Source verification/cancellation failed");
    }
  }
  void finish() {
    check(1);
    closed = true;
    setg(nullptr, nullptr, nullptr);
  }
};
class SourceProgress final : public Message_ProgressIndicator {
  SourceInput &source;
  const std::thread::id thread = std::this_thread::get_id();

public:
  std::atomic<bool> unexpected_thread{false};
  explicit SourceProgress(SourceInput &s) : source(s) {}
  bool UserBreak() override {
    if (std::this_thread::get_id() != thread) {
      unexpected_thread = true;
      return true;
    }
    try {
      source.check(0);
      return false;
    } catch (...) {
      return true;
    }
  }
  void Show(const Message_ProgressScope &, const bool) override {}
};
struct SourceScope {
  SourceScope() { source_active = true; }
  ~SourceScope() { source_active = false; }
};
bool overlaps(const void *a, size_t na, const void *b, size_t nb) {
  const auto x = reinterpret_cast<uintptr_t>(a),
             y = reinterpret_cast<uintptr_t>(b);
  return na > UINTPTR_MAX - x || nb > UINTPTR_MAX - y ||
         (x < y + nb && y < x + na);
}
void read_exact(std::istream &s, SourceInput &input, char *data,
                std::streamsize n) {
  s.read(data, n);
  if (s.gcount() != n)
    input.stop(OCC_READ_TRUNCATED, "Truncated structure");
}
void validate_shape(const TopoDS_Shape &shape, SourceInput &input,
                    const occ_read_limits_v1 &limits) {
  if (shape.IsNull())
    input.stop(OCC_READ_GEOMETRY, "BREP produced no shape");
  TopTools_IndexedMapOfShape all;
  TopExp::MapShapes(shape, all);
  if (static_cast<uint64_t>(all.Extent()) > limits.max_topology)
    input.stop(OCC_READ_LIMIT, "BREP topology limit");
  uint64_t vertices = 0, triangles = 0;
  for (int i = 0; i < all.Extent(); ++i) {
    if (i % 128 == 1)
      input.check(0);
    const auto &part = all(i + 1);
    if (part.ShapeType() == TopAbs_VERTEX) {
      const auto p = BRep_Tool::Pnt(TopoDS::Vertex(part));
      if (!std::isfinite(p.X()) || !std::isfinite(p.Y()) ||
          !std::isfinite(p.Z()))
        input.stop(OCC_READ_GEOMETRY, "Nonfinite BREP vertex");
    }
    if (part.ShapeType() == TopAbs_FACE) {
      TopLoc_Location loc;
      auto tri = BRep_Tool::Triangulation(TopoDS::Face(part), loc);
      if (tri.IsNull())
        continue;
      vertices += tri->NbNodes();
      triangles += tri->NbTriangles();
      if (vertices > limits.max_vertices || triangles > limits.max_triangles)
        input.stop(OCC_READ_LIMIT, "BREP triangulation limit");
      for (int n = 0; n < tri->NbNodes(); ++n) {
        if (n % 1024 == 0)
          input.check(0);
        if (tri->HasNormals()) {
          const auto normal = tri->Normal(n + 1);
          if (!std::isfinite(normal.X()) || !std::isfinite(normal.Y()) ||
              !std::isfinite(normal.Z()))
            input.stop(OCC_READ_GEOMETRY, "Nonfinite BREP normal");
        }
        const auto p = tri->Node(n + 1);
        if (!std::isfinite(p.X()) || !std::isfinite(p.Y()) ||
            !std::isfinite(p.Z()))
          input.stop(OCC_READ_GEOMETRY, "Nonfinite BREP triangulation");
      }
      for (int n = 0; n < tri->NbTriangles(); ++n) {
        if (n % 1024 == 0)
          input.check(0);
        int a, b, c;
        tri->Triangle(n + 1).Get(a, b, c);
        if (a < 1 || b < 1 || c < 1 || a > tri->NbNodes() ||
            b > tri->NbNodes() || c > tri->NbNodes())
          input.stop(OCC_READ_GEOMETRY, "Invalid BREP triangle index");
      }
    }
  }
  input.check(0);
  if (!BRepCheck_Analyzer(shape, true, false).IsValid())
    input.stop(OCC_READ_GEOMETRY, "Invalid BREP topology");
  input.check(0);
}
TopoDS_Shape read_brep(std::istream &s, SourceInput &input,
                       const occ_read_limits_v1 &limits) {
  // Only inspect the bounded format header; OCCT remains the BREP parser.
  std::array<char, 256> header{};
  const auto n = std::min<uint64_t>(input.length(), header.size());
  read_exact(s, input, header.data(), static_cast<std::streamsize>(n));
  const std::string h(header.data(), static_cast<size_t>(n));
  if (h.find("CASCADE Topology V1") == std::string::npos &&
      h.find("CASCADE Topology V2") == std::string::npos &&
      h.find("CASCADE Topology V3") == std::string::npos)
    input.stop(OCC_READ_FORMAT, "Only ASCII BREP TopTools V1-V3 accepted");
  s.clear();
  s.seekg(0);
  TopoDS_Shape shape;
  BRep_Builder builder;
  {
    occ::handle<SourceProgress> progress = new SourceProgress(input);
    // Formatted extraction failure must abort before OCCT can use partial
    // fields.
    s.exceptions(std::ios::badbit | std::ios::failbit | std::ios::eofbit);
    BRepTools::Read(shape, s, builder, progress->Start());
    s.exceptions(std::ios::badbit);
    if (progress->unexpected_thread)
      input.stop(OCC_READ_SOURCE, "Unexpected OCCT progress thread");
  }
  if (input.failed())
    throw SourceFailure{};
  if (s.fail())
    input.stop(OCC_READ_TRUNCATED, "BREP reader did not complete");
  char c;
  while (s.get(c)) {
    if (c != ' ' && c != '\t' && c != '\r' && c != '\n')
      input.stop(OCC_READ_FORMAT, "BREP trailing content");
  }
  if (input.failed())
    throw SourceFailure{};
  input.phase(OCC_READ_VALIDATE);
  validate_shape(shape, input, limits);
  return shape;
}
struct StrictMesh {
  SourceInput &input;
  const occ_read_limits_v1 &limits;
  std::map<std::array<double, 3>, int> ids;
  std::vector<gp_Pnt> points;
  std::vector<Poly_Triangle> triangles;
  void facet(const std::array<double, 12> &v) {
    for (double n : v)
      if (!std::isfinite(n))
        input.stop(OCC_READ_FORMAT, "Nonfinite STL coordinate/normal");
    if (triangles.size() >= limits.max_triangles)
      input.stop(OCC_READ_LIMIT, "STL triangle limit");
    int node[3];
    for (int i = 0; i < 3; ++i) {
      std::array<double, 3> p{v[3 + i * 3], v[4 + i * 3], v[5 + i * 3]};
      auto it = ids.find(p);
      if (it == ids.end()) {
        if (points.size() >= limits.max_vertices)
          input.stop(OCC_READ_LIMIT, "STL vertex limit");
        int id = static_cast<int>(points.size() + 1);
        points.emplace_back(p[0], p[1], p[2]);
        ids.emplace(p, id);
        node[i] = id;
      } else
        node[i] = it->second;
    }
    if (node[0] == node[1] || node[0] == node[2] || node[1] == node[2])
      return; // RWStl drops collapsed facets.
    triangles.emplace_back(node[0], node[1], node[2]);
  }
  occ::handle<Poly_Triangulation> finish() {
    if (triangles.empty())
      input.stop(OCC_READ_GEOMETRY, "STL contains no triangles");
    auto mesh =
        new Poly_Triangulation(static_cast<int>(points.size()),
                               static_cast<int>(triangles.size()), false);
    occ::handle<Poly_Triangulation> result = mesh;
    for (size_t i = 0; i < points.size(); ++i) {
      if (i % 1024 == 0)
        input.check(0);
      mesh->SetNode(static_cast<int>(i + 1), points[i]);
    }
    for (size_t i = 0; i < triangles.size(); ++i) {
      if (i % 1024 == 0)
        input.check(0);
      mesh->SetTriangle(static_cast<int>(i + 1), triangles[i]);
    }
    return result;
  }
};
uint32_t source_u32(const char *p) {
  const auto b = reinterpret_cast<const uint8_t *>(p);
  return uint32_t(b[0]) | (uint32_t(b[1]) << 8) | (uint32_t(b[2]) << 16) |
         (uint32_t(b[3]) << 24);
}
double source_float(const char *p) {
  uint32_t bits = source_u32(p);
  float v;
  std::memcpy(&v, &bits, 4);
  return v;
}
class StlLines {
  std::istream &s;
  SourceInput &input;
  const occ_read_limits_v1 &limits;
  uint64_t tokens = 0;

public:
  StlLines(std::istream &is, SourceInput &i, const occ_read_limits_v1 &l)
      : s(is), input(i), limits(l) {}
  std::vector<std::string> next() {
    for (;;) {
      input.check(0);
      std::string line;
      char c;
      while (s.get(c)) {
        if (c == '\n')
          break;
        if (line.size() >= limits.max_line_bytes)
          input.stop(OCC_READ_LIMIT, "STL line limit");
        if ((static_cast<unsigned char>(c) < 32 && c != '\r' && c != '\t') ||
            static_cast<unsigned char>(c) > 126)
          input.stop(OCC_READ_FORMAT, "Non-ASCII STL text");
        line += c;
      }
      if (input.failed())
        throw SourceFailure{};
      std::vector<std::string> words;
      std::istringstream in(line);
      in.imbue(std::locale::classic());
      std::string w;
      while (in >> w) {
        if (w.size() > limits.max_token_bytes || ++tokens > limits.max_tokens)
          input.stop(OCC_READ_LIMIT, "STL token limit");
        words.push_back(w);
      }
      if (!words.empty() || s.eof())
        return words;
    }
  }
  double number(const std::string &w) {
    double n = 0;
    auto first = w.data();
    auto last = first + w.size();
    if (first != last && *first == '+') {
      ++first;
      if (first == last || *first == '+' || *first == '-')
        input.stop(OCC_READ_FORMAT, "Invalid STL sign");
    }
    auto parsed = std::from_chars(first, last, n);
    if (parsed.ec != std::errc() || parsed.ptr != last || !std::isfinite(n))
      input.stop(OCC_READ_FORMAT, "Invalid STL number");
    return n;
  }
};
occ::handle<Poly_Triangulation> read_stl(std::istream &s, SourceInput &input,
                                         const occ_read_limits_v1 &limits) {
  StrictMesh collector{input, limits, {}, {}, {}};
  bool binary = false;
  uint32_t count = 0;
  if (input.length() >= 84) {
    std::array<char, 84> h{};
    read_exact(s, input, h.data(), 84);
    count = source_u32(h.data() + 80);
    binary = input.length() == 84 + uint64_t(count) * 50;
    s.clear();
    s.seekg(0);
  }
  if (binary) {
    if (!count || count > limits.max_triangles)
      input.stop(OCC_READ_LIMIT, "Binary STL triangle count");
    std::array<char, 84> h{};
    read_exact(s, input, h.data(), 84);
    for (uint32_t i = 0; i < count; ++i) {
      if (i % 1024 == 0)
        input.check(0);
      std::array<char, 50> b{};
      read_exact(s, input, b.data(), 50);
      std::array<double, 12> v{};
      for (int j = 0; j < 12; ++j)
        v[j] = source_float(b.data() + j * 4);
      collector.facet(v);
    }
  } else {
    StlLines lines(s, input, limits);
    auto words = lines.next();
    if (words.empty() || words[0] != "solid")
      input.stop(OCC_READ_FORMAT, "Invalid STL framing/size");
    uint64_t facets = 0;
    for (;;) {
      input.check(0);
      words = lines.next();
      if (words.empty())
        input.stop(OCC_READ_TRUNCATED, "Missing STL facet/endsolid");
      if (words[0] == "endsolid")
        break;
      if (words.size() != 5 || words[0] != "facet" || words[1] != "normal")
        input.stop(OCC_READ_FORMAT, "Invalid STL facet");
      if (++facets > limits.max_triangles)
        input.stop(OCC_READ_LIMIT, "STL facet limit");
      std::array<double, 12> v{};
      for (int j = 0; j < 3; ++j)
        v[j] = lines.number(words[j + 2]);
      words = lines.next();
      if (words != std::vector<std::string>{"outer", "loop"})
        input.stop(OCC_READ_FORMAT, "Expected outer loop");
      for (int j = 0; j < 3; ++j) {
        words = lines.next();
        if (words.size() != 4 || words[0] != "vertex")
          input.stop(OCC_READ_FORMAT, "Expected STL vertex");
        for (int k = 0; k < 3; ++k)
          v[3 + j * 3 + k] = lines.number(words[k + 1]);
      }
      if (lines.next() != std::vector<std::string>{"endloop"} ||
          lines.next() != std::vector<std::string>{"endfacet"})
        input.stop(OCC_READ_FORMAT, "Invalid STL facet terminator");
      collector.facet(v);
    }
    char c;
    while (s.get(c))
      if (c != ' ' && c != '\t' && c != '\r' && c != '\n')
        input.stop(OCC_READ_FORMAT,
                   "Multiple solids/trailing content not supported");
  }
  if (input.failed())
    throw SourceFailure{};
  return collector.finish();
}
int32_t source_read(bool brep, const occ_source_v1 *src,
                    const occ_read_limits_v1 *lim, occ_read_result_v1 *out,
                    uint32_t size) {
  if (!out || size != sizeof(*out))
    return OCC_READ_INVALID;
  if ((src && overlaps(out, sizeof(*out), src, sizeof(*src))) ||
      (lim && overlaps(out, sizeof(*out), lim, sizeof(*lim))))
    return OCC_READ_INVALID;
  *out = {};
  out->size = sizeof(*out);
  out->version = 1;
  out->count_valid = 1;
  try {
    if (source_active || !src || !lim || src->size != sizeof(*src) ||
        src->version != 1 || lim->size != sizeof(*lim) || lim->version != 1 ||
        !src->read_at || !src->check || !src->length ||
        src->length > INT64_MAX || !lim->max_input_bytes ||
        !lim->max_read_bytes || !lim->max_vertices ||
        lim->max_vertices > INT_MAX || !lim->max_triangles ||
        lim->max_triangles > INT_MAX || !lim->max_topology ||
        lim->max_topology > INT_MAX || !lim->max_line_bytes ||
        !lim->max_token_bytes || !lim->max_tokens) {
      out->status = OCC_READ_INVALID;
      fail("Invalid source/limits/result ABI", out->message,
           sizeof(out->message));
      return out->status;
    }
    if (src->length > lim->max_input_bytes) {
      out->status = OCC_READ_LIMIT;
      fail("Input byte limit", out->message, sizeof(out->message));
      return out->status;
    }
    SourceScope scope;
    const auto limits = *lim;
    SourceInput input(*src, limits, *out);
    input.check(0);
    std::istream stream(&input);
    stream.exceptions(std::ios::badbit);
    stream.imbue(std::locale::classic());
    out->phase = OCC_READ_PARSE;
    source_inject(1);
    TopoDS_Shape shape;
    occ::handle<Poly_Triangulation> mesh;
    if (brep)
      shape = read_brep(stream, input, limits);
    else
      mesh = read_stl(stream, input, limits);
    out->phase = OCC_READ_VALIDATE;
    input.check(0);
    occ_read_result_v1 prepared{};
    prepared.resource_kind = brep ? 1 : 2;
    source_inject(2);
    const auto fp = brep ? fingerprint(shape)
                         : "stl-" + std::to_string(mesh->NbNodes()) + "-" +
                               std::to_string(mesh->NbTriangles());
    const auto id = token(brep ? "occ-shape-" : "occ-mesh-");
    const std::string type = brep ? shape_type(shape) : "mesh";
    preflight(id, prepared.token, sizeof(prepared.token));
    preflight(fp, prepared.fingerprint, sizeof(prepared.fingerprint));
    preflight(type, prepared.shape_type, sizeof(prepared.shape_type));
    copy_complete(id, prepared.token);
    copy_complete(fp, prepared.fingerprint);
    copy_complete(type, prepared.shape_type);
    if (!brep) {
      prepared.vertices = mesh->NbNodes();
      prepared.triangles = mesh->NbTriangles();
      for (int i = 0; i < mesh->NbNodes(); ++i) {
        if (i % 1024 == 0)
          input.check(0);
        const auto p = mesh->Node(i + 1);
        for (int j = 0; j < 3; ++j) {
          const double v = p.Coord(j + 1);
          if (i == 0)
            prepared.bounds[j] = prepared.bounds[j + 3] = v;
          else {
            prepared.bounds[j] = std::min(prepared.bounds[j], v);
            prepared.bounds[j + 3] = std::max(prepared.bounds[j + 3], v);
          }
        }
      }
    }
    out->phase = OCC_READ_VERIFY;
    input.finish();
    out->phase = OCC_READ_PUBLISH;
    source_inject(3);
    auto publish = [&]() noexcept {
      prepared.size = sizeof(prepared);
      prepared.version = 1;
      prepared.phase = OCC_READ_PUBLISH;
      prepared.count_valid = out->count_valid;
      prepared.bytes_provided = out->bytes_provided;
      prepared.published = 1;
      *out = prepared;
    };
    if (brep) {
      const std::vector<std::pair<std::string, TopoDS_Shape>> entries{
          {id, shape}};
      publish_batch(shapes, entries, publish);
    } else {
      const std::vector<std::pair<std::string, occ::handle<Poly_Triangulation>>>
          entries{{id, mesh}};
      publish_batch(meshes, entries, publish);
    }
    return OCC_READ_OK;
  } catch (const SourceFailure &) {
    return out->status;
  } catch (const Standard_Failure &e) {
    if (!out->status) {
      out->status = out->phase == OCC_READ_PUBLISH ? OCC_READ_PUBLICATION
                                                   : OCC_READ_FORMAT;
      fail(e.GetMessageString(), out->message, sizeof(out->message));
    }
    return out->status;
  } catch (const std::exception &e) {
    if (!out->status) {
      out->status = out->phase == OCC_READ_PUBLISH ? OCC_READ_PUBLICATION
                                                   : OCC_READ_FORMAT;
      fail(e.what(), out->message, sizeof(out->message));
    }
    return out->status;
  } catch (...) {
    if (!out->status) {
      out->status = out->phase == OCC_READ_PUBLISH ? OCC_READ_PUBLICATION
                                                   : OCC_READ_FORMAT;
      fail("Unknown source import exception", out->message,
           sizeof(out->message));
    }
    return out->status;
  }
}
} // namespace
extern "C" uint32_t OCC_STREAM_CALL flcad_occ_source_version(void) { return 1; }
extern "C" int32_t OCC_STREAM_CALL
flcad_occ_source_default_limits_v1(occ_read_limits_v1 *out, uint32_t size) {
  if (!out || size != sizeof(*out))
    return OCC_READ_INVALID;
  *out = {sizeof(*out), 1,       268435456, 1073741824, 1000000,
          2000000,      1000000, 32000000,  16384,      128};
  return 0;
}
extern "C" int32_t OCC_STREAM_CALL
flcad_occ_brep_read_v1(const occ_source_v1 *s, const occ_read_limits_v1 *l,
                       occ_read_result_v1 *r, uint32_t n) {
  return source_read(true, s, l, r, n);
}
extern "C" int32_t OCC_STREAM_CALL
flcad_occ_stl_read_v1(const occ_source_v1 *s, const occ_read_limits_v1 *l,
                      occ_read_result_v1 *r, uint32_t n) {
  return source_read(false, s, l, r, n);
}
