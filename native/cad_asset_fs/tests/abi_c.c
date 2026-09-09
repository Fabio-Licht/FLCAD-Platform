#include "cad_asset_fs.h"
#include <stddef.h>
_Static_assert(sizeof(caf_result) == 96, "ABI result layout");
_Static_assert(offsetof(caf_result, object) == 24, "ABI object offset");
_Static_assert(offsetof(caf_result, sha256) == 64, "ABI hash offset");
int caf_c_header_test(void) { return caf_abi_version() == 1; }
