// SPDX-License-Identifier: MIT
#pragma once
#include "machine.h"
#include <string>

// Inspect only a stopped guest's visible text. Never scan or upload guest memory
// during normal play, and do not treat a normal DOS exit as an error.
namespace feedback_error {
enum class GuestFailure { None, Execution, Compatibility, Command, Memory };
inline GuestFailure guestFailure(const Machine* m) {
    if (!m) return GuestFailure::None;
    if (m->quit == 2) return GuestFailure::Execution;
    if (m->quit == 3) return GuestFailure::Compatibility;
    if (m->quit != 1 || !m->gdcm.display) return GuestFailure::None;
    int rowHeight = (m->gdcm.csrform[0] & 0x1f) + 1;
    if (rowHeight < 8 || rowHeight > 20) rowHeight = 16;
    const unsigned start = m->gdcm.pram[0] | (m->gdcm.pram[1] << 8);
    for (int row = 0; row < 400 / rowHeight; ++row) {
        std::string line;
        for (int col = 0; col < 80; ++col) {
            const unsigned cell = (start + row * 80 + col) & 0xfff;
            const auto lo = m->tvram[cell * 2], hi = m->tvram[cell * 2 + 1];
            const auto attr = m->tvram[0x2000 + cell * 2];
            line += !hi && (attr & 1) && lo >= 32 && lo <= 126 ? char(lo) : ' ';
        }
        auto last = line.find_last_not_of(' ');
        line.resize(last == std::string::npos ? 0 : last + 1);
        if (line == "Bad command or file name") return GuestFailure::Command;
        if (line == "Not enough memory") return GuestFailure::Memory;
    }
    return GuestFailure::None;
}
}
