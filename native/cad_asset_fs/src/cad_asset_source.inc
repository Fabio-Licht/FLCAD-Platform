
namespace {
struct SourceLease {
  std::shared_ptr<Node> node;
  caf_result expected{};
  std::vector<std::array<uint8_t, 32>> pages;
  bool pinned = false, prepared = false;
  ~SourceLease() {
    if (!pinned)
      return;
    std::lock_guard<std::mutex> guard(mutex);
    for (auto p = node; p; p = p->parent)
      --p->source_leases;
  }
};
std::unordered_map<uint64_t, std::shared_ptr<SourceLease>> sources;
std::shared_ptr<SourceLease> source_get(uint64_t id) {
  std::lock_guard<std::mutex> guard(mutex);
  const auto it = sources.find(id);
  if (it == sources.end())
    fail(CAF_HANDLE, ERROR_INVALID_HANDLE);
  return it->second;
}
template <class F> caf_result source_boundary(F fn) noexcept {
  caf_result r{};
  r.version = 1;
  try {
    fn(r);
  } catch (const Failure &e) {
    r.status = e.status;
    r.win32_error = e.win32;
    r.nt_status = e.nt;
  } catch (const std::bad_alloc &) {
    r.status = CAF_MEMORY;
  } catch (...) {
    r.status = CAF_INTERNAL;
  }
  return r;
}
void source_identity(SourceLease &lease, caf_result &r) {
  FILE_ID_INFO id{};
  FILE_ATTRIBUTE_TAG_INFO tag{};
  LARGE_INTEGER size{};
  const auto h = lease.node->handle.value;
  os(GetFileInformationByHandleEx(h, FileIdInfo, &id, sizeof(id)) != 0);
  os(GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, sizeof(tag)) !=
     0);
  os(GetFileSizeEx(h, &size) != 0);
  r.volume = id.VolumeSerialNumber;
  r.bytes = static_cast<uint64_t>(size.QuadPart);
  std::memcpy(r.file_id, id.FileId.Identifier, 16);
  if ((tag.FileAttributes &
       (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
      r.volume != lease.expected.volume ||
      std::memcmp(r.file_id, lease.expected.file_id, 16) ||
      r.bytes != lease.expected.bytes)
    fail(CAF_POLICY, ERROR_FILE_INVALID);
}
std::array<uint8_t, 32> page_digest(Algorithm &a, const uint8_t *bytes,
                                    DWORD count) {
  DWORD length = 0, used = 0;
  crypto(BCryptGetProperty(a.h, BCRYPT_OBJECT_LENGTH,
                           reinterpret_cast<PUCHAR>(&length), sizeof(length),
                           &used, 0));
  std::vector<uint8_t> storage(length);
  Hash hash;
  crypto(BCryptCreateHash(a.h, &hash.h, storage.data(), length, nullptr, 0, 0));
  crypto(BCryptHashData(hash.h, const_cast<PUCHAR>(bytes), count, 0));
  std::array<uint8_t, 32> result{};
  crypto(BCryptFinishHash(hash.h, result.data(), 32, 0));
  return result;
}
void page_read(SourceLease &lease, uint64_t base, uint8_t *bytes, DWORD count) {
  LARGE_INTEGER pos{};
  pos.QuadPart = static_cast<LONGLONG>(base);
  os(SetFilePointerEx(lease.node->handle.value, pos, nullptr, FILE_BEGIN) != 0);
  DWORD total = 0;
  while (total < count) {
    DWORD read = 0;
    os(ReadFile(lease.node->handle.value, bytes + total, count - total, &read,
                nullptr) != 0);
    if (!read)
      fail(CAF_POLICY, ERROR_HANDLE_EOF);
    total += read;
  }
}
void source_digest(SourceLease &lease, caf_result &r, bool capture,
                   caf_source_poll_v1 poll, void *context) {
  if (!poll || poll(context))
    fail(CAF_POLICY, ERROR_OPERATION_ABORTED);
  source_identity(lease, r);
  Algorithm a;
  crypto(
      BCryptOpenAlgorithmProvider(&a.h, BCRYPT_SHA256_ALGORITHM, nullptr, 0));
  DWORD length = 0, used = 0;
  crypto(BCryptGetProperty(a.h, BCRYPT_OBJECT_LENGTH,
                           reinterpret_cast<PUCHAR>(&length), sizeof(length),
                           &used, 0));
  std::vector<uint8_t> storage(length);
  Hash hash;
  crypto(BCryptCreateHash(a.h, &hash.h, storage.data(), length, nullptr, 0, 0));
  std::vector<uint8_t> buffer(65536);
  for (uint64_t offset = 0; offset < lease.expected.bytes;) {
    if (poll(context))
      fail(CAF_POLICY, ERROR_OPERATION_ABORTED);
    const auto count = static_cast<DWORD>(
        std::min<uint64_t>(65536, lease.expected.bytes - offset));
    page_read(lease, offset, buffer.data(), count);
    crypto(BCryptHashData(hash.h, buffer.data(), count, 0));
    if (capture)
      lease.pages.push_back(page_digest(a, buffer.data(), count));
    offset += count;
  }
  crypto(BCryptFinishHash(hash.h, r.sha256, 32, 0));
  source_identity(lease, r);
  if (std::memcmp(r.sha256, lease.expected.sha256, 32))
    fail(CAF_POLICY, ERROR_FILE_INVALID);
}

} // namespace
extern "C" uint32_t caf_source_version(void) { return 1; }
extern "C" caf_result
caf_source_acquire(uint64_t id, const caf_result *expected, uint32_t size) {
  return source_boundary([&](caf_result &r) {
    if (!expected || size != sizeof(*expected) || expected->version != 1 ||
        expected->status || !expected->bytes || expected->bytes > 268435456)
      fail(CAF_ARGUMENT);
    auto lease = std::make_shared<SourceLease>();
    lease->expected = *expected;
    {
      std::lock_guard<std::mutex> guard(mutex);
      lease->node = get(id);
      if (lease->node->directory || !lease->node->sealed)
        fail(CAF_POLICY);
      for (auto p = lease->node; p; p = p->parent)
        if (p->source_leases == UINT32_MAX)
          fail(CAF_POLICY);
      for (auto p = lease->node; p; p = p->parent)
        ++p->source_leases;
      lease->pinned = true;
    }
    {
      std::lock_guard<std::mutex> io(lease->node->io);
      source_identity(*lease, r);
    }
    std::lock_guard<std::mutex> guard(mutex);
    if (sequence == UINT64_MAX)
      fail(CAF_INTERNAL);
    const auto key = ++sequence;
    sources.emplace(key, lease);
    r.object = key;
  });
}
extern "C" caf_result caf_source_read(uint64_t id, uint64_t offset,
                                      uint8_t *data, uint32_t count) {
  return source_boundary([&](caf_result &r) {
    auto lease = source_get(id);
    std::lock_guard<std::mutex> io(lease->node->io);
    if (!lease->prepared)
      fail(CAF_POLICY, ERROR_NOT_READY);
    source_identity(*lease, r);
    if (!data || count > 65536 || offset > lease->expected.bytes ||
        count > lease->expected.bytes - offset)
      fail(CAF_ARGUMENT);
    r.bytes = 0;
    r.reserved = 1;
    Algorithm algorithm;
    crypto(BCryptOpenAlgorithmProvider(&algorithm.h, BCRYPT_SHA256_ALGORITHM,
                                       nullptr, 0));
    std::vector<uint8_t> page(65536);
    while (r.bytes < count) {
      const auto pos = offset + r.bytes, base = pos / 65536 * 65536;
      const auto length = static_cast<DWORD>(
          std::min<uint64_t>(65536, lease->expected.bytes - base));
      page_read(*lease, base, page.data(), length);
      if (page_digest(algorithm, page.data(), length) !=
          lease->pages.at(static_cast<size_t>(base / 65536)))
        fail(CAF_POLICY, ERROR_FILE_INVALID);
      const auto start = static_cast<size_t>(pos - base);
      const auto copied = static_cast<size_t>(
          std::min<uint64_t>(count - r.bytes, length - start));
      std::memcpy(data + r.bytes, page.data() + start, copied);
      r.bytes += copied;
    }
  });
}
extern "C" caf_result caf_source_prepare(uint64_t id, caf_source_poll_v1 poll,
                                         void *context) {
  return source_boundary([&](caf_result &r) {
    auto lease = source_get(id);
    std::lock_guard<std::mutex> io(lease->node->io);
    if (lease->prepared)
      fail(CAF_POLICY, ERROR_ALREADY_INITIALIZED);
    lease->pages.clear();
    source_digest(*lease, r, true, poll, context);
    lease->prepared = true;
  });
}
extern "C" caf_result caf_source_check(uint64_t id, caf_source_poll_v1 poll,
                                       void *context) {
  return source_boundary([&](caf_result &r) {
    auto lease = source_get(id);
    std::lock_guard<std::mutex> io(lease->node->io);
    if (!lease->prepared)
      fail(CAF_POLICY, ERROR_NOT_READY);
    source_digest(*lease, r, false, poll, context);
  });
}
extern "C" caf_result caf_source_release(uint64_t id) {
  return source_boundary([&](caf_result &) {
    std::shared_ptr<SourceLease> lease;
    {
      std::lock_guard<std::mutex> guard(mutex);
      auto it = sources.find(id);
      if (it == sources.end())
        fail(CAF_HANDLE, ERROR_INVALID_HANDLE);
      if (it->second.use_count() != 1)
        fail(CAF_POLICY, ERROR_BUSY);
      lease = std::move(it->second);
      sources.erase(it);
    }
  });
}
