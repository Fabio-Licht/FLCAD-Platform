#include "flcad_occ_brep_stream.h"
#include "flcad_occ_mesh_stream.h"
int main(void) {
  occ_stream_result_v1 result;
  if (sizeof(result) != 288 || flcad_occ_mesh_stream_version() != 1)
    return 1;
  if (flcad_occ_brep_stream_version() != 1 ||
      flcad_occ_brep_stream_v1(0, 0, 0, &result, sizeof(result)) !=
          OCC_STREAM_INVALID)
    return 2;
  return flcad_occ_mesh_stream_v1(0, 0, 0, 0, 0, &result, sizeof(result)) !=
         OCC_STREAM_INVALID;
}
