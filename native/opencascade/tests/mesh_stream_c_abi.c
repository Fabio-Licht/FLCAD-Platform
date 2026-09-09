#include <stddef.h>

#include "flcad_occ_brep_stream.h"
#include "flcad_occ_mesh_stream.h"
#include "flcad_occ_source.h"
#include <string.h>
OCC_STREAM_API int OCC_STREAM_CALL flcad_occ_destroy_mesh(const char *, char *,
                                                          size_t);
static const char text[] =
    "solid s\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 "
    "0\nvertex 0 1 0\nendloop\nendfacet\nendsolid s\n";
static int32_t OCC_STREAM_CALL read_bytes(void *context, uint64_t off,
                                          uint8_t *out, uint32_t size,
                                          occ_source_io_v1 *io) {
  if (context || off > sizeof(text) - 1)
    return 8;
  if (size > sizeof(text) - 1 - off)
    size = (uint32_t)(sizeof(text) - 1 - off);
  memcpy(out, text + off, size);
  io->bytes_read = size;
  return 0;
}
static int32_t OCC_STREAM_CALL check_source(void *context, uint32_t phase,
                                            occ_source_io_v1 *io) {
  (void)phase;
  (void)io;
  return context ? 9 : 0;
}
int main(void) {
  occ_stream_result_v1 result;
  occ_read_limits_v1 limits;
  occ_read_result_v1 read_result;
  occ_source_v1 source = {sizeof(source),   1,          0,
                          sizeof(text) - 1, read_bytes, check_source};
  char error[256];
  if (flcad_occ_source_version() != 1 ||
      flcad_occ_source_default_limits_v1(&limits, sizeof(limits)))
    return 3;
  if (flcad_occ_stl_read_v1(&source, &limits, &read_result,
                            sizeof(read_result)) ||
      !read_result.published)
    return 4;
  if (flcad_occ_destroy_mesh(read_result.token, error, sizeof(error)) != 1)
    return 5;
  if (sizeof(result) != 288 || flcad_occ_mesh_stream_version() != 1)
    return 1;
  if (flcad_occ_brep_stream_version() != 1 ||
      flcad_occ_brep_stream_v1(0, 0, 0, &result, sizeof(result)) !=
          OCC_STREAM_INVALID)
    return 2;
  return flcad_occ_mesh_stream_v1(0, 0, 0, 0, 0, &result, sizeof(result)) !=
         OCC_STREAM_INVALID;
}
