#include "cad_occ_bridge.h"
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <unordered_map>
#include <windows.h>
#ifdef COB_TESTING
extern void cob_checkpoint(const char *, uint64_t);
extern int cob_destroy_override(uint64_t);
extern caf_result cob_read_override(caf_result, uint64_t);
#define COB_POINT(n, id) cob_checkpoint(n, id)
#else
#define COB_POINT(n, id) ((void)0)
#endif
namespace {
struct Module {
  HMODULE value = nullptr;
  void retain(const void *address) {
    if (!address ||
        !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                            reinterpret_cast<LPCWSTR>(address), &value))
      throw std::runtime_error("module");
  }
  ~Module() {
    if (value)
      FreeLibrary(value);
  }
  template <class T> T fn(const char *name) {
    auto f = GetProcAddress(value, name);
    if (!f)
      throw std::runtime_error("symbol");
    return reinterpret_cast<T>(f);
  }
};
struct Operation {
  Module caf, occ;
  decltype(&caf_source_acquire) acquire = nullptr;
  decltype(&caf_source_read) read = nullptr;
  decltype(&caf_source_check) check = nullptr;
  decltype(&caf_source_prepare) prepare = nullptr;
  decltype(&caf_source_release) release = nullptr;
  decltype(&flcad_occ_brep_read_v1) parse = nullptr;
  using Destroy = int (*)(const char *, char *, size_t);
  Destroy destroy = nullptr;
  uint64_t lease = 0, length = 0;
  uint32_t kind = 0;
  std::atomic<bool> cancelled{false};
  bool running = false, finished = false, closed = false, failed = false,
       held = false, adopted = false;
  std::mutex state;
  cob_result_v1 result{};
};
std::mutex registry_mutex;
std::unordered_map<uint64_t, std::shared_ptr<Operation>> operations;
uint64_t sequence = 0;
std::shared_ptr<Operation> get(uint64_t id) {
  std::lock_guard<std::mutex> g(registry_mutex);
  auto it = operations.find(id);
  if (it == operations.end())
    throw std::runtime_error("operation");
  return it->second;
}
bool output(cob_result_v1 *out, uint32_t size) {
  return out && size == sizeof(*out);
}
void init(cob_result_v1 &out) {
  out = {};
  out.size = sizeof(out);
  out.version = 1;
}
int32_t source_failure(Operation &op, caf_result r, occ_source_io_v1 *io) {
  op.failed = true;
  op.result.filesystem = r;
  io->error_domain = 0x434146;
  io->error_code = static_cast<int32_t>(r.status);
  io->detail = (uint64_t(r.win32_error) << 32) | r.nt_status;
  return r.win32_error == ERROR_OPERATION_ABORTED ? -1 : 1;
}
int32_t cancelled(Operation &op) {
  if (op.failed)
    return 1;
  if (op.cancelled.load()) {
    op.failed = true;
    return -1;
  }
  return 0;
}
int32_t poll(void *p) {
  return static_cast<Operation *>(p)->cancelled.load() ? 1 : 0;
}
int32_t OCC_STREAM_CALL read(void *p, uint64_t off, uint8_t *bytes,
                             uint32_t count, occ_source_io_v1 *io) {
  auto &op = *static_cast<Operation *>(p);
  if (auto c = cancelled(op))
    return c;
  op.result.phase = COB_READ;
  COB_POINT("before_read", op.result.operation);
  if (auto c = cancelled(op))
    return c;
  auto r = op.read(op.lease, off, bytes, count);
#ifdef COB_TESTING
  r = cob_read_override(r, op.result.operation);
#endif
  if (r.version != 1) {
    io->flags = 0;
    return source_failure(op, r, io);
  }
  if (r.reserved & 1) {
    if (r.bytes > count) {
      io->flags = 0;
      return source_failure(op, r, io);
    }
    io->bytes_read = static_cast<uint32_t>(r.bytes);
  }
  if (r.status)
    return source_failure(op, r, io);
  if (r.bytes > count) {
    io->flags = 0;
    return source_failure(op, r, io);
  }
  io->bytes_read = static_cast<uint32_t>(r.bytes);
  COB_POINT("after_read", op.result.operation);
  return cancelled(op);
}
int32_t OCC_STREAM_CALL check(void *p, uint32_t phase, occ_source_io_v1 *io) {
  auto &op = *static_cast<Operation *>(p);
  if (auto c = cancelled(op))
    return c;
  if (phase == 1) {
    op.result.phase = COB_CHECK;
    COB_POINT("before_final", op.result.operation);
    if (auto c = cancelled(op))
      return c;
    const auto r = op.check(op.lease, poll, &op);
    if (r.version != 1 || r.status)
      return source_failure(op, r, io);
  }
  return cancelled(op);
}
} // namespace
extern "C" uint32_t cob_version(void) { return 1; }
extern "C" uint32_t cob_result_size_v1(void) { return sizeof(cob_result_v1); }
extern "C" int32_t cob_begin_v1(const void *ca, const void *oc, uint64_t file,
                                const caf_result *expected, uint32_t es,
                                uint32_t kind, cob_result_v1 *out,
                                uint32_t size) {
  if (!output(out, size))
    return COB_ARGUMENT;
  init(*out);
  if (!expected || es != sizeof(*expected) || expected->version != 1 ||
      expected->status || expected->bytes > 268435456 ||
      (kind != 1 && kind != 2)) {
    out->status = COB_ARGUMENT;
    return COB_ARGUMENT;
  }
  try {
    auto op = std::make_shared<Operation>();
    init(op->result);
    op->kind = kind;
    op->caf.retain(ca);
    op->occ.retain(oc);
    if (op->caf.fn<decltype(&caf_source_version)>("caf_source_version")() !=
            1 ||
        op->occ.fn<decltype(&flcad_occ_source_version)>(
            "flcad_occ_source_version")() != 1)
      throw std::runtime_error("ABI");
    op->acquire = op->caf.fn<decltype(op->acquire)>("caf_source_acquire");
    op->read = op->caf.fn<decltype(op->read)>("caf_source_read");
    op->check = op->caf.fn<decltype(op->check)>("caf_source_check");
    op->prepare = op->caf.fn<decltype(op->prepare)>("caf_source_prepare");
    op->release = op->caf.fn<decltype(op->release)>("caf_source_release");
    op->parse = op->occ.fn<decltype(op->parse)>(
        kind == 1 ? "flcad_occ_brep_read_v1" : "flcad_occ_stl_read_v1");
    op->destroy = op->occ.fn<Operation::Destroy>(
        kind == 1 ? "flcad_occ_destroy_shape" : "flcad_occ_destroy_mesh");
    // Register allocation before acquiring a filesystem lease; failure is
    // effect-free.
    uint64_t id = 0;
    {
      std::lock_guard<std::mutex> guard(registry_mutex);
      if (sequence == UINT64_MAX)
        throw std::runtime_error("ids");
      id = ++sequence;
      operations.emplace(id, op);
      op->result.operation = id;
    }
    op->result.phase = COB_ADMISSION;
    const auto r = op->acquire(file, expected, es);
    op->result.filesystem = r;
    if (r.status || r.version != 1) {
      {
        std::lock_guard<std::mutex> guard(registry_mutex);
        operations.erase(id);
      }
      *out = op->result;
      out->operation = 0;
      out->status = COB_FILESYSTEM;
      return COB_FILESYSTEM;
    }
    op->lease = r.object;
    op->length = expected->bytes;
    *out = op->result;
    return COB_OK;
  } catch (...) {
    out->status = COB_ABI;
    return COB_ABI;
  }
}
extern "C" int32_t cob_run_v1(uint64_t id, cob_result_v1 *out, uint32_t size) {
  if (!output(out, size))
    return COB_ARGUMENT;
  init(*out);
  try {
    auto op = get(id);
    {
      std::lock_guard<std::mutex> guard(op->state);
      if (op->running || op->finished || op->closed)
        return COB_STATE;
      op->running = true;
    }
    occ_source_v1 source{sizeof(source), 1, op.get(), op->length, read, check};
    occ_read_limits_v1 limits{sizeof(limits), 1,       268435456, 1073741824,
                              1000000,        2000000, 1000000,   32000000,
                              16384,          128};
    try {
      op->result.phase = COB_PREPARE;
      const auto prepared = op->prepare(op->lease, poll, op.get());
      if (prepared.status || prepared.version != 1) {
        op->result.filesystem = prepared;
        auto &n = op->result.native_result;
        n.size = sizeof(n);
        n.version = 1;
        n.count_valid = 1;
        n.status = prepared.win32_error == ERROR_OPERATION_ABORTED
                       ? OCC_READ_CANCELLED
                       : OCC_READ_SOURCE;
        n.error_domain = 0x434146;
        n.error_code = static_cast<int32_t>(prepared.status);
        n.detail = (uint64_t(prepared.win32_error) << 32) | prepared.nt_status;
      } else {
        COB_POINT("before_parse", id);
        op->parse(&source, &limits, &op->result.native_result,
                  sizeof(occ_read_result_v1));
        if (op->result.native_result.published)
          op->result.phase = COB_PUBLICATION;
        COB_POINT("after_publish", id);
      }
    } catch (const std::exception &error) {
      op->result.status = COB_INTERNAL;
      const auto count = std::min<size_t>(std::strlen(error.what()), 255);
      std::memcpy(op->result.native_result.message, error.what(), count);
      op->result.native_result.message[count] = 0;
    } catch (...) {
      op->result.status = COB_INTERNAL;
    }
    {
      std::lock_guard<std::mutex> guard(op->state);
      op->held = op->result.native_result.published != 0;
      op->result.token_held = op->held;
      op->running = false;
      op->finished = true;
      *out = op->result;
    }
    return static_cast<int32_t>(out->status);
  } catch (...) {
    out->status = COB_INTERNAL;
    return COB_INTERNAL;
  }
}
extern "C" int32_t cob_cancel_v1(uint64_t id) {
  try {
    get(id)->cancelled = true;
    return 0;
  } catch (...) {
    return COB_STATE;
  }
}
extern "C" int32_t cob_adopt_v1(uint64_t id) {
  try {
    auto op = get(id);
    std::lock_guard<std::mutex> guard(op->state);
    if (op->running || !op->finished || !op->held)
      return COB_STATE;
    op->held = false;
    op->adopted = true;
    op->result.token_held = 0;
    return 0;
  } catch (...) {
    return COB_STATE;
  }
}
extern "C" int32_t cob_close_v1(uint64_t id, cob_result_v1 *out,
                                uint32_t size) {
  if (!output(out, size))
    return COB_ARGUMENT;
  init(*out);
  try {
    auto op = get(id);
    std::lock_guard<std::mutex> guard(op->state);
    if (op->running)
      return COB_BUSY;
    if (op->closed)
      return COB_STATE;
    if (op->held) {
      char message[256]{};
      int destroyed = -999;
#ifdef COB_TESTING
      destroyed = cob_destroy_override(id);
      if (destroyed != -999)
        std::memcpy(message, "Injected destroy failure", 24);
#endif
      if (destroyed == -999)
        destroyed = op->destroy(op->result.native_result.token, message,
                                sizeof(message));
      if (destroyed != 1) {
        op->result.cleanup_code = destroyed;
        std::memcpy(op->result.cleanup_message, message, sizeof(message));
        *out = op->result;
        out->phase = COB_DESTROY;
        out->status = COB_COMPENSATION;
        return COB_COMPENSATION;
      }
      op->held = false;
      op->result.token_held = 0;
      op->result.compensation = 1;
    }
    if (op->lease) {
      const auto r = op->release(op->lease);
      if (r.status) {
        *out = op->result;
        out->filesystem = r;
        out->phase = COB_RELEASE;
        out->status = COB_FILESYSTEM;
        return COB_FILESYSTEM;
      }
      op->lease = 0;
    }
    op->closed = true;
    *out = op->result;
    {
      std::lock_guard<std::mutex> registry(registry_mutex);
      operations.erase(id);
    }
    return 0;
  } catch (...) {
    out->status = COB_INTERNAL;
    return COB_INTERNAL;
  }
}

extern "C" int32_t cob_snapshot_v1(uint64_t id, cob_result_v1 *out,
                                   uint32_t size) {
  if (!output(out, size))
    return COB_ARGUMENT;
  init(*out);
  try {
    auto op = get(id);
    std::lock_guard<std::mutex> guard(op->state);
    if (op->running)
      return COB_BUSY;
    *out = op->result;
    return 0;
  } catch (...) {
    return COB_STATE;
  }
}
