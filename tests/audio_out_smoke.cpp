// SPDX-License-Identifier: MIT
#include "AudioOut.h"
#include <cstdio>
#include <cstdlib>
static void check(bool ok,const char* message) { if(!ok) { std::fprintf(stderr,"FAIL: %s\n",message);std::exit(1); } }
static void fadeConfigured(AudioQueueRef q) {
    check(q->gainAtStart==0 && q->volume==1,"start silent then restore unity gain");
    check(q->rampAtStart==.016f && q->rampTime==.016f,"sixteen millisecond output fade includes already queued audio");
}
static std::vector<int16_t> pcm(size_t frames,int16_t value) { return std::vector<int16_t>(frames*2,value); }
static void allSamples(AudioQueueRef q,int16_t expected) {
    check(q->scheduled.size()==AudioOut::bufferCount,"all output buffers primed");
    for(auto b:q->scheduled) {
        auto* data=static_cast<int16_t*>(b->mAudioData);
        for(size_t i=0;i<b->mAudioDataByteSize/2;++i) check(data[i]==expected,"scheduled audio has current PCM, not startup silence/stale data");
    }
}
int main() {
    AudioOut out;check(out.open(44100),"open");auto q=out.queue;
    check(!q->running && q->scheduled.empty(),"no empty queue startup");
    out.push(pcm(512,111));check(!q->running,"wait for enough real PCM");
    out.push(pcm(1024,111));check(q->running,"start after priming");allSamples(q,111);fadeConfigured(q);
    out.push(pcm(200,222));
    for(int i=0;i<100;++i) {
        out.pause();check(!q->running,"pause hardware output");
        check(out.samples.empty() && q->scheduled.empty(),"pause discards FIFO and hardware-prefetched old audio");
        out.push(pcm(50,999));check(out.samples.empty(),"paused output ignores new PCM");
        check(out.open(44100),"resume via existing open call");
        check(out.queue==q && !q->running && creations==1 && disposals==0,"resume reuses allocated queue and waits for fresh PCM");
        out.push(pcm(1536,(int16_t)(1000+i)));
        check(q->running,"fresh audio restarts output");allSamples(q,(int16_t)(1000+i));fadeConfigured(q);
    }
    out.push(pcm(200,222));
    auto buffer=q->scheduled.front();q->scheduled.erase(q->scheduled.begin());
    q->callback(q->context,q,buffer);
    auto* data=static_cast<int16_t*>(buffer->mAudioData);
    check(out.rebuffering && out.samples.size()==400 && data[1023]==0,"underrun preserves unread PCM and settles to silence");
    auto drain=[&]() { auto b=q->scheduled.front();q->scheduled.erase(q->scheduled.begin());q->callback(q->context,q,b);return b; };
    out.push(pcm(512,222));buffer=drain();data=static_cast<int16_t*>(buffer->mAudioData);
    check(out.rebuffering && out.samples.size()==1424 && data[0]==0 && data[1023]==0,"small refill stays silent instead of stuttering");
    out.push(pcm(2000,222));buffer=drain();data=static_cast<int16_t*>(buffer->mAudioData);
    check(!out.rebuffering && data[0]==0 && data[1022]>0 && data[1022]<222,"recovery fades fresh PCM in once");
    buffer=drain();data=static_cast<int16_t*>(buffer->mAudioData);
    check(data[1022]==222 && data[1023]==222,"recovery reaches unity gain in 16 milliseconds");
    check(q->volumeChanges==202,"each initial/resumed start resets gain and starts a fresh fade");
    out.clear();check(out.samples.empty() && q->scheduled.empty() && !q->running,"clear flushes hardware and producer queues");
    check(stopEnqueues==0,"late teardown callback cannot enqueue or deadlock");
    out.push(pcm(1536,333));allSamples(q,333);
    out.pause();out.clear();check(out.paused && q->scheduled.empty(),"state clear preserves pause");
    check(out.resume(),"resume after clear");out.push(pcm(1536,444));allSamples(q,444);
    out.clear();failEnqueue=true;out.push(pcm(1536,555));failEnqueue=false;
    check(!out.started && q->scheduled.empty(),"enqueue failure resets partial priming");
    out.push(pcm(1536,666));allSamples(q,666);
    out.clear();failStart=true;out.push(pcm(1536,777));failStart=false;
    check(!out.started && q->scheduled.empty(),"start failure clears scheduled audio");
    out.push(pcm(1536,888));allSamples(q,888);
    out.pause();check(out.resume() && !q->running,"resume after pause does not start old hardware buffers");
    out.push(pcm(1536,999));allSamples(q,999);
    out.clear();check(out.needsFrames(),"audio clock requests priming PCM");
    out.push(pcm(6000,123));check(!out.needsFrames(),"audio clock stops guest catch-up when 80 ms reserve is filled");
    for(int i=0;i<5;++i) drain();
    check(out.needsFrames(),"audio clock replenishes consumed reserve after UI stalls");
    check(out.open(48000) && creations==2 && disposals==1,"sample-rate change recreates queue");
    out.close();check(!out.queue && out.samples.empty() && disposals==2 && stopEnqueues==0,"close safely disposes all PCM");
    std::puts("Audio queue priming, 100 pause/resume cycles, fresh-only resume, clear, failure recovery and teardown passed");
}
