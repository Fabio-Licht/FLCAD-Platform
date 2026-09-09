#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef _WIN32
#define OCC_STREAM_API __declspec(dllexport)
#define OCC_STREAM_CALL __cdecl
#else
#define OCC_STREAM_API __attribute__((visibility("default")))
#define OCC_STREAM_CALL
#endif
#ifdef __cplusplus
extern "C" {
#endif
/* ABI v1: natural C layout, same architecture/compiler C ABI as the host.
   Inputs/result must be valid, nonoverlapping storage throughout the call.
   Caller retains ownership and prevents concurrent mutation of the borrowed
   shape (including legacy tessellation) until return. No callback reentry into
   geometry mutation/shutdown is permitted. Context must outlive the call;
   byte span and accepted pointer are valid only within each callback.
   No flush/commit is performed: consumer commits its storage only on success.
   Deflection range [1e-6,1e6] model units; angle [1e-4,pi] radians;
   max_triangles in [1,UINT32_MAX]. Thread-synchronous, no background callbacks.
   accepted_count_valid=0 means bytes_accepted is only the confirmed prefix;
   current callback effects are unknown (invalid count or consumer exception).
   Success emits binary STL: 80-byte stable header, u32 little-endian count,
   50-byte triangles: normal and 3 positions float32 LE, u16 attribute zero.
   Cancellation is consumer code -1 at a chunk boundary; meshing is not
   asynchronously interruptible. Consumer error causes are returned verbatim.
   Synchronous caller-thread callback. Context may be NULL. Set accepted to the
   actual prefix consumed, even on error. 0 = success, -1 = cancellation, other
   values = consumer cause. No exceptions may escape a consumer callback. */
typedef int32_t(OCC_STREAM_CALL *occ_stream_write_v1)(void *context,
                                                      const uint8_t *bytes,
                                                      uint32_t length,
                                                      uint32_t *accepted);
typedef struct occ_stream_sink_v1 {
  uint32_t size;
  uint32_t version;
  void *context;
  occ_stream_write_v1 write;
} occ_stream_sink_v1;
enum occ_stream_status_v1 {
  OCC_STREAM_OK = 0,
  OCC_STREAM_INVALID = 1,
  OCC_STREAM_SHAPE = 2,
  OCC_STREAM_TESSELLATION = 3,
  OCC_STREAM_SERIALIZATION = 4,
  OCC_STREAM_SINK = 5,
  OCC_STREAM_CANCELLED = 6,
  OCC_STREAM_LIMIT = 7
};
typedef struct occ_stream_result_v1 {
  uint32_t version;
  uint32_t status;
  int32_t consumer_code;
  uint32_t accepted_count_valid;
  uint64_t bytes_accepted;
  uint64_t triangles;
  char message[256];
} occ_stream_result_v1;
OCC_STREAM_API uint32_t OCC_STREAM_CALL flcad_occ_mesh_stream_version(void);
OCC_STREAM_API int32_t OCC_STREAM_CALL flcad_occ_mesh_stream_v1(
    const char *shape_token, double deflection, double angular_deflection,
    uint64_t max_triangles, const occ_stream_sink_v1 *sink,
    occ_stream_result_v1 *result, uint32_t result_size);
#ifdef __cplusplus
}
#endif
