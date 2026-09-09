#pragma once
#include "flcad_occ_mesh_stream.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Additive BREP ABI v1. Same sink/lifetime/error rules as mesh stream v1.
   Result.triangles is reserved and always zero. Emits OCCT ASCII BREP format 3,
   with triangulations and their normals, classic locale. max_bytes > 0 bounds
   serialized bytes (not OCCT memory/time). No pathname, transfer or new token.
   Callback reentry into this BREP API returns INVALID before producing bytes.
   The consumer decides whether nested rejection should stop its outer stream.
   Caller holds a lease and excludes mutation/shutdown during serialization.
   Cancellation is observed only at sink calls, not during shape enumeration.
   Failed output is an uncommitted prefix, even if the last byte was accepted.
   No destructor flush; finalization is explicit and failure is observable. */
OCC_STREAM_API uint32_t OCC_STREAM_CALL flcad_occ_brep_stream_version(void);
OCC_STREAM_API int32_t OCC_STREAM_CALL flcad_occ_brep_stream_v1(
    const char *shape_token, uint64_t max_bytes, const occ_stream_sink_v1 *sink,
    occ_stream_result_v1 *result, uint32_t result_size);
#ifdef __cplusplus
}
#endif
