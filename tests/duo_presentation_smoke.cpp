// SPDX-License-Identifier: MIT
#include "../ios/DuoPresentation.h"
#include <cstdio>
#include <stdexcept>
static void check(bool ok,const char* message) { if(!ok) throw std::runtime_error(message); }
int main() { try {
    check(duoNeedsFullscreenInset(true,true,false,1000,800),"vertical hinge opens left/right");
    check(duoNeedsFullscreenInset(true,false,false,1000,800),"fully-open wide inner screen needs fullscreen inset");
    check(!duoNeedsFullscreenInset(false,false,false,1000,800),"ordinary iPhone landscape is unchanged");
    check(!duoNeedsFullscreenInset(true,false,false,800,1000),"top-bottom opening uses standard insets");
    check(!duoNeedsFullscreenInset(true,true,true,1000,800),"closed Duo uses standard insets");
    puts("PASS: Duo fullscreen insets for inner and outer displays");return 0;
} catch(const std::exception& e) { fprintf(stderr,"FAIL: %s\n",e.what());return 1; } }
