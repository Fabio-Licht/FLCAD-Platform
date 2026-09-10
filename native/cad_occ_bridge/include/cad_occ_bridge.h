#pragma once
#include "cad_asset_fs.h"
#include "flcad_occ_source.h"
#include "flcad_occ_brep_stream.h"
#ifdef COB_BUILD
#define COB_API __declspec(dllexport)
#else
#define COB_API __declspec(dllimport)
#endif
#ifdef __cplusplus
extern "C" {
#endif
enum {
  COB_OK = 0,
  COB_ARGUMENT = 1,
  COB_ABI = 2,
  COB_FILESYSTEM = 3,
  COB_BUSY = 4,
  COB_STATE = 5,
  COB_COMPENSATION = 6,
  COB_INTERNAL = 7
};
enum {
  COB_ADMISSION = 1,
  COB_PREPARE = 2,
  COB_READ = 3,
  COB_CHECK = 4,
  COB_PUBLICATION = 5,
  COB_RELEASE = 6,
  COB_DESTROY = 7
};
typedef struct cob_result_v1 {
  uint32_t size, version, status, phase;
  uint64_t operation;
  caf_result filesystem;
  occ_read_result_v1 native_result;
  uint32_t token_held, compensation;
  int32_t cleanup_code;
  char cleanup_message[256];
} cob_result_v1;
typedef struct cob_stream_result_v1 {
  uint32_t size, version, status, phase;
  caf_result filesystem;
  occ_stream_result_v1 native_result;
} cob_stream_result_v1;
/* Module anchors are addresses of exported version functions, not OS handles.
 * Library references and filesystem lease remain owned by the operation until
 * close succeeds. Native token stays in escrow until adopt. Nothing serialized.
 */
COB_API uint32_t cob_version(void);
COB_API uint32_t cob_result_size_v1(void);
COB_API int32_t cob_begin_v1(const void *caf_anchor, const void *occ_anchor,
                             uint64_t file, const caf_result *expected,
                             uint32_t expected_size, uint32_t kind,
                             cob_result_v1 *out, uint32_t size);
COB_API int32_t cob_run_v1(uint64_t operation, cob_result_v1 *out,
                           uint32_t size);
COB_API int32_t cob_snapshot_v1(uint64_t operation, cob_result_v1 *out,
                                uint32_t size);
COB_API int32_t cob_cancel_v1(uint64_t operation);
COB_API int32_t cob_adopt_v1(uint64_t operation);
COB_API int32_t cob_close_v1(uint64_t operation, cob_result_v1 *out,
                             uint32_t size);
/* Synchronous C-to-C output. `token` remains process-local and is borrowed
 * only for this call. Writer is an already-acquired opaque CAF writer lease;
 * Dart owns its acquire/seal/release lifetime. kind 1 emits BREP, kind 2 emits
 * binary STL from a shape, and additive kind 3 emits binary STL from a
 * custody-owned Poly_Triangulation token. */
COB_API uint32_t cob_stream_result_size_v1(void);
COB_API int32_t cob_shape_write_v1(const void *caf_anchor,
                                   const void *occ_anchor, uint64_t writer,
                                   const char *token, uint32_t kind,
                                   cob_stream_result_v1 *out, uint32_t size);
#ifdef __cplusplus
}
#endif
