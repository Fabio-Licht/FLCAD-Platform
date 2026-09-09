// Test-only physical mutation through the original open object. Never shipped.
#include "../src/cad_asset_fs.cpp"
extern "C" __declspec(dllexport) caf_result
caf_source_test_damage(uint64_t id, uint64_t offset) {
  return boundary([&](caf_result &r) {
    auto n = get(id);
    std::lock_guard<std::mutex> io(n->io);
    LARGE_INTEGER at{};
    at.QuadPart = static_cast<LONGLONG>(offset);
    os(SetFilePointerEx(n->handle.value, at, nullptr, FILE_BEGIN) != 0);
    uint8_t byte = 0;
    DWORD count = 0;
    os(ReadFile(n->handle.value, &byte, 1, &count, nullptr) != 0);
    if (count != 1)
      fail(CAF_ARGUMENT);
    byte ^= 1;
    os(SetFilePointerEx(n->handle.value, at, nullptr, FILE_BEGIN) != 0);
    os(WriteFile(n->handle.value, &byte, 1, &count, nullptr) != 0);
    if (count != 1)
      fail(CAF_OS, ERROR_WRITE_FAULT);
    os(FlushFileBuffers(n->handle.value) != 0);
    r.bytes = 1;
    r.effect = CAF_WRITTEN;
  });
}
