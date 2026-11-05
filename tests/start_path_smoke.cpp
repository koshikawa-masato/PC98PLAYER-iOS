// SPDX-License-Identifier: MIT
#include "player.h"
#include "hostfs.h"
#include "../apple/StartupPath.h"
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <cstdio>
#include <vector>
#include <iterator>
#include <unistd.h>
namespace fs=std::filesystem;
static void check(bool ok,const char* message) { if(!ok) throw std::runtime_error(message); }
int main() {
    char temporary[]="/tmp/retrodos-start-path-XXXXXX";
    if(!mkdtemp(temporary)) return 1;
    fs::path root=temporary;
    std::unique_ptr<Player> player;
    try {
        check(apple_startup::dos_start_path("").empty(),"empty boot start retained");
        check(apple_startup::dos_start_path("DEPTH.EXE /Q /path/data")=="DEPTH.EXE /Q /path/data","root program and inline switches retained");
        check(apple_startup::dos_start_path("aa3558f/DEPTH.EXE /Q /path/data")=="aa3558f\\DEPTH.EXE /Q /path/data","only executable token converted");
        check(apple_startup::dos_start_path("aa3558f/DEPTH.EXE\t/Q")=="aa3558f\\DEPTH.EXE\t/Q","tab-delimited arguments retained");
        const std::string japanese=hostfs::to_sjis("ゲーム/DEPTH.EXE");
        check(apple_startup::dos_start_path(japanese)==hostfs::to_sjis("ゲーム\\DEPTH.EXE"),"CP932 path bytes retained");
        fs::create_directories(root/"aa3558f");
        // COM opens a sibling file relative to the guest CWD, reads its marker,
        // and writes it plus the first argument byte to text VRAM. Loop on error.
        const unsigned char code[]={
            0x1E,0x0E,0x1F,                    // save PSP DS; push cs; pop ds
            0xBA,0x40,0x01,                   // mov dx,0140 (DATA.BIN)
            0xB8,0x00,0x3D,0xCD,0x21,         // DOS open read-only
            0x73,0x02,0xEB,0xFE,              // loop on carry
            0x89,0xC3,0xB9,0x01,0x00,         // bx=handle; cx=1
            0xBA,0x00,0x02,0xB4,0x3F,0xCD,0x21,
            0x73,0x02,0xEB,0xFE,
            0xB8,0x00,0xA0,0x8E,0xC0,         // es=text VRAM
            0xA0,0x00,0x02,0x26,0xA2,0x00,0x00,
            0x1F,0xA0,0x82,0x00,0x26,0xA2,0x02,0x00, // restore PSP DS; argument
            0xEB,0xFE
        };
        std::ofstream executable(root/"aa3558f"/"DEPTH.COM",std::ios::binary);
        executable.write(reinterpret_cast<const char*>(code),sizeof(code));
        for(size_t i=sizeof(code);i<0x40;++i) executable.put(0);
        executable.write("DATA.BIN",9); executable.close();
        // Wrap the same fixture in a real MZ executable, matching DEPTH.EXE.
        std::ifstream com(root/"aa3558f"/"DEPTH.COM",std::ios::binary);
        std::vector<unsigned char> module(0x100,0);
        module.insert(module.end(),std::istreambuf_iterator<char>(com),std::istreambuf_iterator<char>());
        const unsigned total=32+module.size();
        unsigned short header[16]={0x5A4D,(unsigned short)(total%512),(unsigned short)((total+511)/512),0,2,0,0xFFFF,0,0xFFFE,0,0x100,0,0x1C,0,0,0};
        std::ofstream mz(root/"aa3558f"/"DEPTH.EXE",std::ios::binary);
        mz.write(reinterpret_cast<const char*>(header),sizeof(header));
        mz.write(reinterpret_cast<const char*>(module.data()),module.size());mz.close();
        std::ofstream(root/"aa3558f"/"DATA.BIN",std::ios::binary).put('K');
        std::ofstream(root/"aa3558f"/"START.BAT") << "@DEPTH.COM %1\r\n";
        for(bool overlay:{false,true}) {
            hostfs::set_overlay(overlay?root.string():"",overlay?(root/"saves").string():"");
            for(const char* start:{"aa3558f/DEPTH.EXE","aa3558f\\DEPTH.EXE","aa3558f/DEPTH.COM","aa3558f\\DEPTH.COM","aa3558f/START.BAT","aa3558f\\START.BAT"}) {
                PlayerSettings settings; settings.cfg.root=root.string();settings.cfg.start=start;
                settings.cfg.args="/Q";settings.cfg.midi=0;
                // Same boundary conversion used by both Apple frontends; the DOS core is unchanged.
                settings.cfg.start=apple_startup::dos_start_path(settings.cfg.start);
                player=std::make_unique<Player>();std::string error;
                check(player->init(settings,&error),"player init");
                for(int frame=0;frame<10;++frame) player->run_frame();
                if(player->m->tvram[0]!='K') throw std::runtime_error(std::string("nested startup/CWD failed: ")+start);
                check(player->m->tvram[2]=='/',"slash option preserved in command tail");
                player->shutdown();player.reset();
            }
        }
        hostfs::set_overlay("","");fs::remove_all(root);
        puts("PASS: nested EXE/COM/BAT with host/DOS separators, sibling data, slash arguments and save overlay");
        return 0;
    } catch(const std::exception& error) {
        fprintf(stderr,"FAIL: %s\n",error.what());
        if(player) player->shutdown();hostfs::set_overlay("","");fs::remove_all(root);return 1;
    }
}
