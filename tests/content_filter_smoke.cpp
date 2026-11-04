// SPDX-License-Identifier: MIT
#include "ContentFilterPolicy.h"
#include <cstdio>
#include <limits>
#include <stdexcept>
using namespace content_filter;
static void check(bool ok,const char* message) { if(!ok)throw std::runtime_error(message); }
int main() {try {
    Settings settings;Scores adult{.9f,0},harm{0,.9f};
    check(regions(adult,{},settings).empty(),"disabled categories do not censor");
    settings.adult=true;check(matches(adult,settings) && !matches(harm,settings),"adult switch is independent");
    settings.adult=false;settings.harm=true;check(!matches(adult,settings) && matches(harm,settings),"harm switch is independent of adult classification");
    settings.adult=true;auto full=regions(adult,{},settings);check(full.size()==1 && full[0].width==1 && full[0].height==1,"globally unsafe scene without localization is fully covered");
    auto local=regions({},{{{.4f,.35f,.6f,.65f},adult}},settings);check(local.size()==1 && local[0].x<.4f && local[0].y<.35f && local[0].x+local[0].width<=1,"tile detections include an edge margin and stay in bounds");
    check(regions({std::numeric_limits<float>::quiet_NaN(),0},{},settings).size()==1,"nonfinite results fail closed");
    settings.sensitivity=0;check(!matches({.7f,0},settings),"lower sensitivity uses a higher threshold");settings.sensitivity=2;check(matches({.7f,0},settings),"higher sensitivity catches the same score");
    PresentationGate gate;auto old=gate.issue();gate.invalidate();auto fresh=gate.issue();check(!gate.accept(old) && gate.accept(fresh),"game or configuration changes reject old raw-frame jobs");
    auto earlier=gate.issue(),later=gate.issue();check(gate.accept(later) && !gate.accept(earlier) && !gate.accept(later),"out-of-order and duplicate results never overwrite newer protected frames");
    puts("PASS: independent categories, thresholds, conservative masks, invalid output, presentation generations");return 0;
} catch(const std::exception& e) {fprintf(stderr,"FAIL: %s\n",e.what());return 1;}}
