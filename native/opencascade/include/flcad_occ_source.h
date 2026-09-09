#pragma once
#include "flcad_occ_mesh_stream.h"
#ifdef __cplusplus
extern "C" {
#endif
enum occ_read_status_v1 {
  OCC_READ_OK = 0,
  OCC_READ_INVALID = 1,
  OCC_READ_SOURCE = 2,
  OCC_READ_CANCELLED = 3,
  OCC_READ_TRUNCATED = 4,
  OCC_READ_FORMAT = 5,
  OCC_READ_LIMIT = 6,
  OCC_READ_GEOMETRY = 7,
  OCC_READ_PUBLICATION = 8
};
enum occ_read_phase_v1 {
  OCC_READ_PREFLIGHT = 0,
  OCC_READ_TRANSPORT = 1,
  OCC_READ_PARSE = 2,
  OCC_READ_VALIDATE = 3,
  OCC_READ_VERIFY = 4,
  OCC_READ_PUBLISH = 5
};
/* callback code 0 success, -1 cancelled, other consumer cause. All byte counts
   must be initialized. flags bit0=count valid, bit1=EOF; no other flags.
   Error with a valid prefix contributes to bytes_provided but is terminal. */
typedef struct occ_source_io_v1 {
  uint32_t size, version, bytes_read, flags, error_domain;
  int32_t error_code;
  uint64_t detail;
} occ_source_io_v1;
typedef int32_t(OCC_STREAM_CALL *occ_source_read_at_v1)(void *, uint64_t,
                                                        uint8_t *, uint32_t,
                                                        occ_source_io_v1 *);
/* phase 0 polls cancellation; phase 1 verifies source stability and
   cancellation. Mandatory. Never called after source failure or registry
   publication. */
typedef int32_t(OCC_STREAM_CALL *occ_source_check_v1)(void *, uint32_t,
                                                      occ_source_io_v1 *);
typedef struct occ_source_v1 {
  uint32_t size, version;
  void *context;
  uint64_t length;
  occ_source_read_at_v1 read_at;
  occ_source_check_v1 check;
} occ_source_v1;
typedef struct occ_read_limits_v1 {
  uint32_t size, version;
  uint64_t max_input_bytes, max_read_bytes;
  uint32_t max_vertices, max_triangles, max_topology, max_tokens,
      max_line_bytes, max_token_bytes;
} occ_read_limits_v1;
typedef struct occ_read_result_v1 {
  uint32_t size, version, status, phase, error_domain;
  int32_t error_code;
  uint64_t detail, bytes_provided;
  uint32_t count_valid, published, resource_kind, reserved;
  uint64_t vertices, triangles;
  double bounds[6];
  char token[64], fingerprint[64], shape_type[32], message[256];
} occ_read_result_v1;
/* Natural host C layout, same architecture as host. Valid nonoverlapping
   source/limits/result storage required.
   NULL context is allowed when callbacks do not need context; context/bytes
   remain caller-owned. read_at/check execute synchronously on calling thread,
   no reentrant import, mutation or shutdown. Callbacks must not throw;
   exceptions are contained. Result published=1 means caller must immediately
   adopt token into custody. resource_kind: 1 shape, 2 mesh. No
   pointers/capabilities are retained. Source MUST remain immutable; final check
   must verify its own guarantees. */
OCC_STREAM_API uint32_t OCC_STREAM_CALL flcad_occ_source_version(void);
OCC_STREAM_API int32_t OCC_STREAM_CALL
flcad_occ_source_default_limits_v1(occ_read_limits_v1 *, uint32_t);
OCC_STREAM_API int32_t OCC_STREAM_CALL
flcad_occ_brep_read_v1(const occ_source_v1 *, const occ_read_limits_v1 *,
                       occ_read_result_v1 *, uint32_t);
OCC_STREAM_API int32_t OCC_STREAM_CALL
flcad_occ_stl_read_v1(const occ_source_v1 *, const occ_read_limits_v1 *,
                      occ_read_result_v1 *, uint32_t);
#ifdef __cplusplus
}
#endif
