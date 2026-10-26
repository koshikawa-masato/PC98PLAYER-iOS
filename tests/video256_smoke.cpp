// SPDX-License-Identifier: MIT
#include "machine.h"
#include "state.h"
#include <cstdio>
#include <stdexcept>
#include <vector>
#include <set>
#include <cstring>
static void check(bool value,const char* message) { if(!value) throw std::runtime_error(message); }
int main() {
    Machine* m=nullptr;
    try {
        Config cfg;cfg.video_colors=256;cfg.midi=0;m=machine_create(cfg);
        check(m->ram[0x45c]&0x40,"HLE reports extended graphics without a ROM");
        check(!m->pegc.enabled,"16-color mode remains the reset mode");
        // Later AGS_9821 drivers use INT18/4D rather than writing port 6A.
        m->cpu.r[EAX]=0x4d00;m->cpu.r[ECX]=0x0100;bios_hle(m,HLE_INT18);
        check(m->pegc.enabled,"INT18/4D CH=1 enables the same extended framebuffer as port 6A");
        io_out8(m,0xa8,200);io_out8(m,0xaa,0x12);io_out8(m,0xac,0x34);io_out8(m,0xae,0x56);
        mem_wb(m,0xa8000,200);m->gdcs.display=1;m->gdcm.display=0;m->gdcs.pitch=80;
        std::vector<uint32_t> biosPixels(640*400);video_render(m,biosPixels.data());
        check(biosPixels[0]==0xff341256,"BIOS switch routes guest pixel writes and palettes to 256-color renderer");
        m->cpu.r[EAX]=0x4d00;m->cpu.r[ECX]=0x0200;bios_hle(m,HLE_INT18);
        check(m->pegc.enabled,"unsupported INT18/4D switch leaves the current mode alone");
        m->cpu.r[EAX]=0x4d00;m->cpu.r[ECX]=0;bios_hle(m,HLE_INT18);
        check(!m->pegc.enabled && m->pegc.vram[0]==200,"BIOS legacy switch preserves extended VRAM");
        mem_wb(m,0xe0123,0x5a);check(m->gvram[0][3][0x123]==0x5a && m->pegc.registers[0x123]==0,"legacy E-plane remains accessible before extended mode");
        io_out8(m,0x6a,7);io_out8(m,0x6a,0x21);io_out8(m,0x6a,6);
        check(m->pegc.enabled,"guest enables extended graphics");
        io_out8(m,0xa8,254);io_out8(m,0xaa,0x12);io_out8(m,0xac,0x34);io_out8(m,0xae,0x56);
        check(io_in8(m,0xa8)==254 && io_in8(m,0xaa)==0x12 && io_in8(m,0xac)==0x34 && io_in8(m,0xae)==0x56,"8-bit RGB palette and full index readback");
        mem_ww(m,0xe0004,15);mem_ww(m,0xe0006,3);
        mem_ww(m,0xa8000,0xabcd);mem_ww(m,0xb0000,0x1234);
        check(m->pegc.vram[15*0x8000]==0xcd && m->pegc.vram[3*0x8000]==0x34,"independent 32K VRAM windows");
        check(mem_rw(m,0xa8000)==0xabcd && mem_rw(m,0xb0000)==0x1234,"banked VRAM reads");
        mem_ww(m,0xe0006,0);mem_ww(m,0xaffff,0x9876);
        check(m->pegc.vram[0x7ffff]==0x76 && m->pegc.vram[0]==0x98,"word access crosses window boundary correctly");
        for(int i=0;i<256;++i) {io_out8(m,0xa8,(uint8_t)i);io_out8(m,0xaa,(uint8_t)i);io_out8(m,0xac,(uint8_t)i);io_out8(m,0xae,(uint8_t)i);}
        for(unsigned i=0;i<256000;++i) m->pegc.vram[i]=(uint8_t)i;
        m->gdcs.display=1;m->gdcm.display=0;m->gdcs.pitch=80;
        std::vector<uint32_t> pixels(640*400);video_render(m,pixels.data());
        check(std::set<uint32_t>(pixels.begin(),pixels.end()).size()==256,"renderer produces all 256 palette entries");
        check(pixels[255]==0xffffffff && pixels[640]==0xff808080,"packed pixel order and pitch");
        m->disp_bank=1;m->pegc.vram[0x40000]=7;video_render(m,pixels.data());check(pixels[0]==0xff070707,"display page selection");m->disp_bank=0;
        memset(m->pegc.vram,0,sizeof m->pegc.vram);mem_ww(m,0xe0100,1);mem_ww(m,0xe0104,0);mem_ww(m,0xe010c,0xffff);mem_ww(m,0xe0108,0x11f0);
        mem_ww(m,0xa8000,0x00aa);
        check(m->pegc.vram[0]==255 && m->pegc.vram[1]==0 && m->pegc.vram[8]==0,"CPU source ROP and planar bit ordering");
        mem_ww(m,0xe0114,255);mem_ww(m,0xe010a,1);mem_ww(m,0xe0108,0x30f0);
        check(mem_rw(m,0xa8000)==0x00aa,"planar color comparison and read latch");
        mem_ww(m,0xe0108,0x10f0);mem_ww(m,0xa8002,0);
        check(m->pegc.vram[16]==255 && m->pegc.vram[17]==0,"latched VRAM source copy");
        mem_ww(m,0xe0104,0x00fe);mem_ww(m,0xe0108,0x11f0);mem_ww(m,0xe010c,0x0080);mem_ww(m,0xa8004,0xffff);
        check(m->pegc.vram[32]==1 && m->pegc.vram[33]==0,"plane write mask and bit mask");
        StateW snapshot;machine_state_save(m,snapshot);m->pegc.palette[255][0]=1;m->pegc.vram[32]=99;m->pegc.enabled=0;
        StateR restore(snapshot.b.data(),snapshot.b.size());machine_state_load(m,restore);
        check(restore.ok && m->pegc.enabled && m->pegc.palette[255][0]==255 && m->pegc.vram[32]==1,"PEGC state roundtrip");
        StateR legacy(snapshot.b.data(),snapshot.b.size()-sizeof(Pegc)-4);machine_state_load(m,legacy);check(legacy.ok && !m->pegc.enabled,"legacy snapshots remain readable");
        machine_destroy(m);m=nullptr;
        cfg.video_colors=16;m=machine_create(cfg);io_out8(m,0x6a,0x21);check(!m->pegc.enabled && !(m->ram[0x45c]&0x40),"16-color hardware capability preserved");
        m->cpu.r[EAX]=0x4d00;m->cpu.r[ECX]=0x0100;bios_hle(m,HLE_INT18);
        check(!m->pegc.enabled,"BIOS switch cannot expose 256 colors on a 16-color configuration");
        machine_destroy(m);puts("PASS: BIOS-free PEGC, palette, bank windows, rendering, planar ROP/masks, state, 16-color compatibility");return 0;
    } catch(const std::exception& error) { fprintf(stderr,"FAIL: %s\n",error.what());if(m) machine_destroy(m);return 1; }
}
