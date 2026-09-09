#ifndef CAD_ASSET_FS_H
#define CAD_ASSET_FS_H
#include <stdint.h>
#ifdef _WIN32
#ifdef CAF_BUILD
#define CAF_API __declspec(dllexport)
#else
#define CAF_API __declspec(dllimport)
#endif
#else
#define CAF_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
/* ABI v1, Windows x64. Strings are counted UTF-16 (not null terminated).
 * IDs are process-local, non-reused capabilities, never OS handles/pointers.
 * Caller must supply valid memory; this is not an untrusted-process RPC ABI.
 * Every result includes observed effects even on error. No automatic deletion.
 */
enum {
  CAF_OK = 0,
  CAF_ARGUMENT = 1,
  CAF_HANDLE = 2,
  CAF_POLICY = 3,
  CAF_OS = 4,
  CAF_MEMORY = 5,
  CAF_INTERNAL = 6
};
enum { CAF_NONE = 0, CAF_CREATED = 1, CAF_WRITTEN = 2, CAF_RENAMED = 3 };
#pragma pack(push, 8)
typedef struct caf_result {
  uint32_t version, status, win32_error, nt_status;
  uint32_t effect, reserved;
  uint64_t object, bytes, volume;
  uint8_t file_id[16];
  uint8_t sha256[32];
} caf_result;
#pragma pack(pop)
CAF_API uint32_t caf_abi_version(void);
CAF_API caf_result caf_open_root(const uint16_t *absolute, uint32_t units);
CAF_API caf_result caf_open_dir(uint64_t parent, const uint16_t *name,
                                uint32_t units);
CAF_API caf_result caf_create_dir(uint64_t parent, const uint16_t *name,
                                  uint32_t units);
CAF_API caf_result caf_open_file(uint64_t parent, const uint16_t *name,
                                 uint32_t units);
CAF_API caf_result caf_create_file(uint64_t parent, const uint16_t *name,
                                   uint32_t units);
CAF_API caf_result caf_write(uint64_t object, const uint8_t *data,
                             uint32_t bytes);
CAF_API caf_result caf_seal(uint64_t object, uint64_t expected_bytes);
CAF_API caf_result caf_info(uint64_t object);
CAF_API caf_result caf_rename(uint64_t object, uint64_t destination,
                              const uint16_t *name, uint32_t units);
CAF_API caf_result caf_close(uint64_t object);
#ifdef __cplusplus
}
#endif
#endif
