#pragma once
#include "flcad_occ_source.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Synchronous caller-owned, writable, nonoverlapping UTF-8 buffers.
 * Capacities include NUL. No pointers are retained or persistible. */
typedef struct occ_step_buffers_v1 {
  uint32_t size, version;
  char *name_utf8;
  uint32_t name_capacity;
  char *unit_utf8;
  uint32_t unit_capacity;
} occ_step_buffers_v1;
typedef struct occ_step_metadata_v1 {
  uint32_t size, version, name_bytes, unit_bytes;
  uint32_t has_color, reserved;
  double declared_meters_per_unit, resolved_meters_per_unit;
  /* Linear RGB, alpha exactly 1 when has_color=1; all zero when absent. */
  double rgba[4];
} occ_step_metadata_v1;
typedef struct occ_step_read_result_v1 {
  uint32_t size, version;
  occ_read_result_v1 native_result;
  occ_step_metadata_v1 metadata;
} occ_step_read_result_v1;
/* Additive ABI. Only single-file Part21, one product/solid, no assembly,
 * external references, body/face colors or transparency. ReadStream only.
 * Published shape token is borrowed/escrowed until custody capture.
 * On failure no new registry entry; valid string buffers are empty.
 * The C ABI requires valid memory; access violations are not C++ exceptions. */
OCC_STREAM_API uint32_t OCC_STREAM_CALL flcad_occ_step_source_version(void);
OCC_STREAM_API int32_t OCC_STREAM_CALL flcad_occ_step_read_v1(
    const occ_source_v1 *, const occ_read_limits_v1 *,
    const occ_step_buffers_v1 *, occ_step_read_result_v1 *, uint32_t);
#ifdef __cplusplus
}
#endif
