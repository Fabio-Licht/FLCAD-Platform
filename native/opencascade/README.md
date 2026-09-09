# FLCAD OpenCascade native host

The build first uses `FLCAD_OCCT_ROOT` (environment variable or CMake cache entry), then `OCCT_ROOT`, `CMAKE_PREFIX_PATH`, conventional Program Files locations, and finally the local SDK catalog under `C:/FLCAD/SDKs/OCCT`. The selected root must contain `inc` and an `OpenCASCADEConfig.cmake`; library and binary directories are read from that package, including layouts such as `win64/vc14/{lib,bin}`. Example override:

```powershell
$env:FLCAD_OCCT_ROOT = 'C:/SDKs/OCCT'
flutter build windows --debug
# Or configure CMake directly with -DFLCAD_OCCT_ROOT=C:/SDKs/OCCT
```

The Windows build links `flcad_opencascade` into the Flutter build graph and copies the bridge plus all OCCT runtime DLLs beside `flcad_mobile.exe`. The library exposes the legacy C ABI in `include/flcad_occ_api.h` and additive versioned streaming ABIs; no OCCT type crosses the boundary. See [source streaming](SOURCE_STREAM.md), [BREP output](BREP_STREAM.md) and [mesh output](MESH_STREAM.md).

This workspace intentionally does not vendor OCCT. Configuration fails explicitly when the SDK is absent.
