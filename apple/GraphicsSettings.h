// SPDX-License-Identifier: MIT
#pragma once
#include "machine.h"
// A user-selected 16-color mode must override even a PC9821=1 source INI.
inline void apple_set_video_colors(Config& cfg, int colors) {
    cfg.video_colors = colors == 256 ? 256 : 16;
    cfg.pc9821 = cfg.video_colors == 256;
    cfg.pc9821_ask = false;
}
// 画面モード（0 = 自動、1 = 31kHz・640×480、2 = 24kHz・640×400）。31kHz は PC-9821 として見せる（色数とは別）
inline void apple_apply_crt_mode(Config& cfg, int mode) {
    cfg.crt_mode = mode == 1 || mode == 2 ? mode : 0;
    if (cfg.crt_mode == 1) cfg.pc9821 = true;
}
