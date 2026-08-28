#pragma once

#include <string>

namespace tc_unc_guard {

// Replaces a Cyrillic es used as a drive letter at the start of a path or as
// the drive letter of an administrative UNC share.
// Examples: с:\\path -> c:\\path and \\server\с$ -> \\server\c$.
bool NormalizePath(std::wstring& path) noexcept;

}  // namespace tc_unc_guard
