#include "flcad_occ_step_source.h"
#include <stddef.h>
typedef char rgba_layout[(sizeof(((occ_step_metadata_v1 *)0)->rgba) ==
                          4 * sizeof(double))
                             ? 1
                             : -1];
typedef char
    result_layout[(offsetof(occ_step_read_result_v1, native_result) == 8) ? 1
                                                                          : -1];
int main(void) {
  occ_step_read_result_v1 result = {0};
  if (flcad_occ_step_source_version() != 1)
    return 1;
  if (flcad_occ_step_read_v1(NULL, NULL, NULL, &result, sizeof(result)) !=
          OCC_READ_INVALID ||
      result.native_result.published)
    return 2;
  if (flcad_occ_step_read_v1(NULL, NULL, NULL, &result, sizeof(result) - 1) !=
      OCC_READ_INVALID)
    return 3;
  return 0;
}
