// SPDX-License-Identifier: MIT
#pragma once

// Preserve the user's fullscreen choice while the wide inner display supplies
// an automatic default. A double tap can dismiss it until the posture changes.
struct DuoFullscreenPresentation {
    bool requested = false;
    bool wideDuo = false;
    bool dismissedWide = false;
    bool active() const { return wideDuo ? !dismissedWide : requested; }
    bool update(bool wide) {
        if(wideDuo != wide) { wideDuo = wide; dismissedWide = false; }
        return active();
    }
    bool toggle() {
        if(wideDuo) dismissedWide = !dismissedWide;
        else requested = !requested;
        return active();
    }
};
inline bool duoUsesWideFullscreen(bool hardware, bool verticalDivision, bool closed, double width, double height) {
    return !closed && (verticalDivision || (hardware && width > height));
}
