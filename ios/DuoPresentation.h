// SPDX-License-Identifier: MIT
#pragma once

inline bool duoNeedsFullscreenInset(bool hardware, bool verticalDivision, bool closed, double width, double height) {
    return !closed && (verticalDivision || (hardware && width > height));
}
