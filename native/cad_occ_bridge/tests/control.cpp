#include "cad_asset_fs.h"
#include <atomic>
#include <stdexcept>
#include <stdint.h>
#include <string>
std::atomic<bool> fail_destroy{false};
extern "C" __declspec(dllexport) void
cob_test_destroy_failure(uint32_t enabled) {
  fail_destroy = enabled != 0;
}
std::atomic<uint32_t> parse_failure{0};
extern "C" __declspec(dllexport) void cob_test_parse_failure(uint32_t phase) {
  parse_failure = phase;
}
void cob_checkpoint(const char *point, uint64_t) {
  if ((parse_failure == 1 && std::string(point) == "before_parse") ||
      (parse_failure == 2 && std::string(point) == "after_publish"))
    throw std::runtime_error("Injected bridge parse failure");
}
caf_result cob_read_override(caf_result r, uint64_t) { return r; }
int cob_destroy_override(uint64_t) { return fail_destroy ? 0 : -999; }
