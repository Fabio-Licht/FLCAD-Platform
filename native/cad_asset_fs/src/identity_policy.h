#pragma once
#include <cstring>
#include <windows.h>
namespace caf_policy {
inline bool same_volume(const FILE_ID_INFO &a, const FILE_ID_INFO &b) noexcept {
  return a.VolumeSerialNumber == b.VolumeSerialNumber;
}
inline bool same_object(const FILE_ID_INFO &a, const FILE_ID_INFO &b) noexcept {
  return same_volume(a, b) &&
         std::memcmp(a.FileId.Identifier, b.FileId.Identifier, 16) == 0;
}
} // namespace caf_policy
