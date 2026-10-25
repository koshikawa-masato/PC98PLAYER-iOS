// SPDX-License-Identifier: MIT
#include "machine.h"
#include <cstring>

static uint16_t reg(const Pegc& p,int offset) { return p.registers[offset] | (p.registers[offset+1]<<8); }
bool pegc_window(Machine* m,uint32_t a) { return m->cfg.video_colors==256 && m->pegc.enabled && a>=0xA8000 && a<0xB8000; }
static uint32_t pixel_base(Machine* m,uint32_t a) {
    return (((a-0xA8000)*8)+(m->pegc.single_page?0:m->draw_bank*0x40000))&0x7ffff;
}
static int bit_index(int pixel) { return (pixel&~7)+(7-(pixel&7)); }
uint16_t pegc_read(Machine* m,uint32_t a,int bytes) {
    Pegc& p=m->pegc;uint16_t value=0;
    if(!(p.registers[0x100]&1)) {
        for(int i=0;i<bytes;++i) { uint32_t off=a+i-0xA8000;uint32_t bank=p.registers[(off<0x8000)?4:6]&15;value|=p.vram[bank*0x8000+(off&0x7fff)]<<(8*i); }
        return value;
    }
    if(!p.single_page && a>=0xB0000) return 0xffff;
    uint32_t base=pixel_base(m,a);uint16_t rop=reg(p,0x108);uint8_t planes=(uint8_t)~p.registers[0x104];
    for(int i=0;i<bytes*8;++i) {
        uint8_t color=p.vram[(base+i)&0x7ffff];p.source[i]=color;
        if((rop&0x2000) && !(rop&0x0100)) p.pattern[i]=color;
        if((p.registers[0x10a]&1) && !(rop&0x0100) && !((color^p.registers[0x114])&planes)) value|=(uint16_t)(1u<<bit_index(i));
    }
    return value;
}
void pegc_write(Machine* m,uint32_t a,uint16_t value,int bytes) {
    Pegc& p=m->pegc;
    if(!(p.registers[0x100]&1)) {
        for(int i=0;i<bytes;++i) { uint32_t off=a+i-0xA8000;uint32_t bank=p.registers[(off<0x8000)?4:6]&15;p.vram[bank*0x8000+(off&0x7fff)]=(uint8_t)(value>>(8*i)); }
        return;
    }
    if(!p.single_page && a>=0xB0000) return;
    uint32_t base=pixel_base(m,a);uint16_t rop=reg(p,0x108),mask=reg(p,0x10c);uint8_t planes=(uint8_t)~p.registers[0x104];
    int read_shift=reg(p,0x112)&15,write_shift=(reg(p,0x112)>>8)&15;
    for(int i=0;i<bytes*8;++i) {
        if(!(mask&(1u<<bit_index(i)))) continue;
        uint8_t& destination=p.vram[(base+i)&0x7ffff];uint8_t result=0;
        bool cpu_bit=(value&(1u<<bit_index(i)))!=0;
        int shift=i+read_shift-write_shift;uint8_t source=(rop&0x100)?(cpu_bit?255:0):p.source[(shift+32)&31];
        if(!(rop&0x1000)) result=source?255:0;
        else {
            int mode=(rop>>10)&3;uint8_t pattern=mode==0?p.pattern[i]:mode==1?p.registers[0x118]:p.registers[0x114];
            for(int bit=0;bit<8;++bit) {
                int index=(((source>>bit)&1)<<2)|(((destination>>bit)&1)<<1)|((pattern>>bit)&1);
                if(mode==3) index=(((source>>bit)&1)<<2)|(((p.registers[0x114]>>bit)&1)<<1)|((p.registers[0x118]>>bit)&1);
                result|=((rop>>index)&1)<<bit;
            }
        }
        destination=(destination&~planes)|(result&planes);
    }
}
