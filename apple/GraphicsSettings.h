// SPDX-License-Identifier: MIT
#pragma once
#include "machine.h"
// A user-selected 16-color mode must override even a PC9821=1 source INI.
inline void apple_set_video_colors(Config& cfg, int colors) {
    cfg.video_colors = colors == 256 ? 256 : 16;
    cfg.pc9821 = cfg.video_colors == 256;
    cfg.pc9821_ask = false;
}
