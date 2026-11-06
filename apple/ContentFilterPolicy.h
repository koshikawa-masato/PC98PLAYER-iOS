// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>
namespace content_filter {
enum class Effect : int { Black=0, Blur=1, Mosaic=2 };
struct Settings {
    bool adult=false, harm=false;
    Effect effect=Effect::Black;
    int sensitivity=1;
    bool enabled() const { return adult || harm; }
    float threshold() const { return sensitivity==0?.80f:sensitivity==2?.45f:.65f; }
};
struct Scores { float adult=0, harm=0; };
struct Region { float x=0,y=0,width=1,height=1; };
struct Tile { Region region; Scores scores; };
inline bool valid(const Scores& s) {
    for(float v:{s.adult,s.harm}) if(!std::isfinite(v) || v<0 || v>1) return false;
    return true;
}
inline bool matches(const Scores& s,const Settings& settings) {
    return (settings.adult && s.adult>=settings.threshold()) ||
        (settings.harm && s.harm>=settings.threshold());
}
// Regions use top-left normalized image coordinates, independent of device rotation.
inline std::vector<Region> regions(const Scores& full,const std::vector<Tile>& tiles,const Settings& settings) {
    std::vector<Region> result;if(!settings.enabled()) return result;
    if(!valid(full)) return {{}}; // An invalid enabled result must never reveal its frame.
    for(const auto& tile:tiles) {
        if(!valid(tile.scores)) return {{}};
        if(!matches(tile.scores,settings)) continue;
        const auto& r=tile.region;float x=std::max(0.f,r.x-.025f),y=std::max(0.f,r.y-.025f);
        result.push_back({x,y,std::min(1.f,r.x+r.width+.025f)-x,std::min(1.f,r.y+r.height+.025f)-y});
    }
    // A positive scene without a localized positive is still covered in full.
    if(result.empty() && matches(full,settings)) result.push_back({});
    return result;
}
// Old jobs cannot present images after game, state, options or size changes.
struct Ticket { uint64_t generation,sequence; };
class PresentationGate {
    uint64_t generation=1,sequence=0,presented=0;
public:
    Ticket issue() { return {generation,++sequence}; }
    void invalidate() { ++generation;presented=0; }
    bool accept(Ticket t) {
        if(t.generation!=generation || t.sequence<=presented) return false;
        presented=t.sequence;return true;
    }
};
}
