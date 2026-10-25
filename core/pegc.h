// SPDX-License-Identifier: MIT
#pragma once
#include <stdint.h>
// PC-9821 display registers and framebuffer, implemented without a firmware image.
struct Pegc {
    uint8_t vram[0x80000] = {};
    uint8_t palette[256][3] = {};
    uint8_t registers[0x200] = {};
    uint8_t source[32] = {}, pattern[32] = {};
    uint8_t enabled = 0, single_page = 0, selector = 0;
};
struct Machine;
bool pegc_window(Machine* m,uint32_t address);
uint16_t pegc_read(Machine* m,uint32_t address,int bytes);
void pegc_write(Machine* m,uint32_t address,uint16_t value,int bytes);
