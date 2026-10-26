// SPDX-License-Identifier: MIT
#include "../ios/DuoPresentation.h"
#include <cstdio>
#include <stdexcept>
static void check(bool ok,const char* message) { if(!ok) throw std::runtime_error(message); }
int main() { try {
    DuoFullscreenPresentation p;
    check(!p.update(false),"normal phone and top-bottom opening keep the keyboard");
    check(duoUsesWideFullscreen(true,true,false,1000,800),"vertical hinge opens left/right");
    check(duoUsesWideFullscreen(true,false,false,1000,800),"fully-open wide inner screen maximizes");
    check(!duoUsesWideFullscreen(false,false,false,1000,800),"ordinary iPhone landscape is unchanged");
    check(!duoUsesWideFullscreen(true,false,false,800,1000),"top-bottom opening keeps the keyboard");
    check(!duoUsesWideFullscreen(true,true,true,1000,800),"closed Duo never exposes automatic fullscreen");
    check(p.update(true),"left/right opening enters fullscreen");
    check(!p.toggle(),"double tap restores controls in left/right posture");
    check(!p.update(true),"layout refresh does not override double tap");
    check(p.toggle(),"second double tap maximizes again");
    check(!p.update(false),"returning to top-bottom restores controls");
    check(p.toggle(),"manual fullscreen works in top-bottom posture");
    check(p.update(true) && p.update(false),"posture round trip preserves prior manual fullscreen");
    check(!p.toggle(),"manual exit restores controls");
    check(p.update(true) && !p.toggle() && !p.update(false) && p.update(true),"new left/right opening resets its temporary dismissal");
    puts("PASS: Duo posture, fullscreen override, outer display and normal iPhone isolation");return 0;
} catch(const std::exception& e) { fprintf(stderr,"FAIL: %s\n",e.what());return 1; } }
