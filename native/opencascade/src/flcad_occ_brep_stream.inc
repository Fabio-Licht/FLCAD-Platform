#include "flcad_occ_brep_stream.h"
#include <locale>
#include <streambuf>
namespace {
thread_local bool brep_stream_active = false;
#ifdef FLCAD_OCC_TESTING
thread_local int brep_fault_point = 0, brep_fault_kind = 0;
void brep_inject(int point) {
  if (brep_fault_point != point)
    return;
  brep_fault_point = 0;
  if (brep_fault_kind == 1)
    throw Standard_Failure("BREP OCCT injection");
  if (brep_fault_kind == 2)
    throw 42;
  throw std::runtime_error("BREP standard injection");
}
#else
void brep_inject(int) {}
#endif
int32_t brep_error(occ_stream_result_v1 &r, uint32_t status,
                   const char *text) noexcept {
  if (r.status == OCC_STREAM_OK) {
    r.status = status;
    fail(text, r.message, sizeof(r.message));
  }
  return static_cast<int32_t>(r.status);
}
class BrepSinkBuffer final : public std::streambuf {
  const occ_stream_sink_v1 sink;
  occ_stream_result_v1 &result;
  const uint64_t limit;
  uint64_t generated = 0;
  std::array<uint8_t, 64000> bytes{};
  size_t used = 0;
  bool flush_block() {
    if (result.status != OCC_STREAM_OK)
      return false;
    if (!used)
      return true;
    uint32_t accepted = 0;
    int32_t cause = 0;
    try {
      cause = sink.write(sink.context, bytes.data(),
                         static_cast<uint32_t>(used), &accepted);
    } catch (const Standard_Failure &e) {
      result.accepted_count_valid = 0;
      brep_error(result, OCC_STREAM_SINK, e.GetMessageString());
      return false;
    } catch (const std::exception &e) {
      result.accepted_count_valid = 0;
      brep_error(result, OCC_STREAM_SINK, e.what());
      return false;
    } catch (...) {
      result.accepted_count_valid = 0;
      brep_error(result, OCC_STREAM_SINK, "Unknown consumer exception");
      return false;
    }
    result.consumer_code = cause;
    if (accepted > used) {
      result.accepted_count_valid = 0;
      brep_error(result, OCC_STREAM_SINK, "Invalid sink accepted count");
      return false;
    }
    result.bytes_accepted +=
        accepted; // <= generated <= limit, checked before buffer writes
    if (cause != 0 || accepted != used) {
      brep_error(result, cause == -1 ? OCC_STREAM_CANCELLED : OCC_STREAM_SINK,
                 "Sink stopped BREP stream");
      return false;
    }
    used = 0;
    brep_inject(3);
    return true;
  }

protected:
  std::streamsize xsputn(const char *source, std::streamsize count) override {
    if (result.status != OCC_STREAM_OK)
      return 0;
    if (count < 0 || static_cast<uint64_t>(count) > limit - generated) {
      brep_error(result, OCC_STREAM_LIMIT, "BREP byte limit exceeded");
      return 0;
    }
    std::streamsize written = 0;
    while (written < count) {
      if (used == bytes.size() && !flush_block())
        return written;
      const auto n = static_cast<size_t>(std::min<uint64_t>(
          bytes.size() - used, static_cast<uint64_t>(count - written)));
      std::memcpy(bytes.data() + used, source + written, n);
      used += n;
      generated += n;
      written += static_cast<std::streamsize>(n);
      brep_inject(2);
    }
    return written;
  }
  int_type overflow(int_type value = traits_type::eof()) override {
    if (result.status != OCC_STREAM_OK)
      return traits_type::eof();
    if (traits_type::eq_int_type(value, traits_type::eof()))
      return sync() == 0 ? traits_type::not_eof(value) : traits_type::eof();
    const char c = traits_type::to_char_type(value);
    return xsputn(&c, 1) == 1 ? value : traits_type::eof();
  }
  int sync() override { return flush_block() ? 0 : -1; }

public:
  BrepSinkBuffer(occ_stream_sink_v1 s, occ_stream_result_v1 &r, uint64_t max)
      : sink(s), result(r), limit(max) {}
#ifdef FLCAD_OCC_TESTING
  void seed_generated_for_test(uint64_t value) { generated = value; }
#endif
  // No put area bypasses xsputn/overflow; every write observes terminal
  // failure. Destruction deliberately discards buffered bytes, never calls the
  // consumer.
};
struct BrepScope {
  BrepScope() { brep_stream_active = true; }
  ~BrepScope() { brep_stream_active = false; }
};
} // namespace
extern "C" uint32_t OCC_STREAM_CALL flcad_occ_brep_stream_version(void) {
  return 1;
}
extern "C" int32_t OCC_STREAM_CALL flcad_occ_brep_stream_v1(
    const char *token, uint64_t limit, const occ_stream_sink_v1 *input,
    occ_stream_result_v1 *out, uint32_t size) {
  if (!out || size != sizeof(*out))
    return OCC_STREAM_INVALID;
  *out = {};
  out->version = 1;
  out->accepted_count_valid = 1;
  uint32_t phase = OCC_STREAM_INVALID;
  try {
    if (brep_stream_active || !input || input->size != sizeof(*input) ||
        input->version != 1 || !input->write || !token || !limit)
      return brep_error(*out, OCC_STREAM_INVALID,
                        "Invalid or reentrant BREP stream call");
    BrepScope scope;
    phase = OCC_STREAM_SHAPE;
    const auto borrowed = get(token);
    phase = OCC_STREAM_SERIALIZATION;
    brep_inject(1);
    BrepSinkBuffer buffer(*input, *out, limit);
    std::ostream stream(&buffer);
    stream.imbue(std::locale::classic());
    stream.exceptions(std::ios::badbit | std::ios::failbit);
    BRepTools::Write(borrowed, stream, true, true,
                     TopTools_FormatVersion_VERSION_3);
    if (out->status != OCC_STREAM_OK)
      return static_cast<int32_t>(out->status);
    brep_inject(4);
    stream.flush();
    brep_inject(5);
    if (!stream.good())
      return brep_error(*out, OCC_STREAM_SERIALIZATION,
                        "BREP stream finalization failed");
    return static_cast<int32_t>(out->status);
  } catch (const Standard_Failure &e) {
    return brep_error(*out, phase, e.GetMessageString());
  } catch (const std::exception &e) {
    return brep_error(*out, phase, e.what());
  } catch (...) {
    return brep_error(*out, phase, "Unknown BREP serialization exception");
  }
}
