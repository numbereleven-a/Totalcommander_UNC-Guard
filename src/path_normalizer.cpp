#include "path_normalizer.h"

#include <string_view>

namespace tc_unc_guard {
namespace {

constexpr wchar_t kCyrillicLowerEs = L'\u0441';
constexpr wchar_t kCyrillicUpperEs = L'\u0421';

bool StartsWith(std::wstring_view value, std::wstring_view prefix) noexcept {
  return value.size() >= prefix.size() &&
         value.compare(0, prefix.size(), prefix) == 0;
}

}  // namespace

bool NormalizePath(std::wstring& path) noexcept {
  try {
    // Only inspect the first two characters, so other path components remain
    // untouched.
    if (path.size() >= 2 && path[1] == L':') {
      if (path[0] == kCyrillicLowerEs) {
        path[0] = L'c';
        return true;
      }

      if (path[0] == kCyrillicUpperEs) {
        path[0] = L'C';
        return true;
      }
    }

    std::size_t server_start = 0;

    if (StartsWith(path, LR"(\\?\UNC\)")) {
      server_start = 8;
    } else if (StartsWith(path, LR"(\\)")) {
      server_start = 2;
    } else {
      return false;
    }

    const std::size_t server_end = path.find(L'\\', server_start);
    if (server_end == std::wstring::npos || server_end == server_start) {
      return false;
    }

    const std::size_t share_start = server_end + 1;
    const std::size_t share_end = path.find(L'\\', share_start);
    const std::size_t share_length =
        (share_end == std::wstring::npos ? path.size() : share_end) - share_start;

    if (share_length != 2 || path[share_start + 1] != L'$') {
      return false;
    }

    if (path[share_start] == kCyrillicLowerEs) {
      path[share_start] = L'c';
      return true;
    }

    if (path[share_start] == kCyrillicUpperEs) {
      path[share_start] = L'C';
      return true;
    }

    return false;
  } catch (...) {
    return false;
  }
}

}  // namespace tc_unc_guard
