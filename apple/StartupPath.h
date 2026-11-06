// SPDX-License-Identifier: MIT
#pragma once
#include <string>

namespace apple_startup {
// Convert the host path at the Apple frontend boundary, before calling Player.
// Start can also contain arguments: leave slash switches and their values alone.
// cfg.args is a separate field and must never pass through this conversion.
inline std::string dos_start_path(std::string start) {
    const auto end = start.find_first_of(" \t");
    for (size_t i = 0; i < start.size() && (end == std::string::npos || i < end); ++i)
        if (start[i] == '/') start[i] = '\\';
    return start;
}
} // namespace apple_startup
