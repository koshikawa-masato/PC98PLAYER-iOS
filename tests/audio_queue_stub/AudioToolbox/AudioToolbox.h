// SPDX-License-Identifier: MIT
#pragma once
// Deterministic AudioQueue double: records scheduled buffers and invokes a late
// callback during teardown, without depending on a host speaker or its timing.
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <vector>
using OSStatus=int;
constexpr int kAudioQueueParam_Volume=1,kAudioQueueParam_VolumeRampTime=4;
constexpr int noErr=0, kAudioFormatLinearPCM=1, kLinearPCMFormatFlagIsSignedInteger=1, kAudioFormatFlagIsPacked=2;
struct AudioStreamBasicDescription {
    double mSampleRate; unsigned mFormatID,mFormatFlags,mBytesPerPacket,mBytesPerFrame,mFramesPerPacket,mChannelsPerFrame,mBitsPerChannel;
};
struct AudioQueueBuffer { unsigned mAudioDataBytesCapacity; void* mAudioData; unsigned mAudioDataByteSize; };
using AudioQueueBufferRef=AudioQueueBuffer*;
struct TestAudioQueue;
using AudioQueueRef=TestAudioQueue*;
using OutputCallback=void(*)(void*,AudioQueueRef,AudioQueueBufferRef);
struct TestAudioQueue {
    OutputCallback callback;void* context;
    std::vector<AudioQueueBufferRef> allocated,scheduled;
    bool running=false;
    float volume=1,rampTime=0,gainAtStart=1,rampAtStart=0;
    int volumeChanges=0;
};
inline int creations=0,disposals=0,enqueues=0,stopEnqueues=0;
inline bool failStart=false,failEnqueue=false;
inline OSStatus AudioQueueNewOutput(const AudioStreamBasicDescription*,OutputCallback cb,void* context,void*,void*,int,AudioQueueRef* queue) {
    *queue=new TestAudioQueue{cb,context};++creations;return noErr;
}
inline OSStatus AudioQueueAllocateBuffer(AudioQueueRef q,unsigned size,AudioQueueBufferRef* b) {
    *b=new AudioQueueBuffer{size,std::calloc(1,size),0};q->allocated.push_back(*b);return noErr;
}
inline OSStatus AudioQueueEnqueueBuffer(AudioQueueRef q,AudioQueueBufferRef b,int,void*) {
    if(failEnqueue) return -1;
    ++enqueues;q->scheduled.push_back(b);return noErr;
}
inline OSStatus AudioQueueSetParameter(AudioQueueRef q,int parameter,float value) {
    if(parameter==kAudioQueueParam_Volume) { q->volume=value;++q->volumeChanges; }
    else if(parameter==kAudioQueueParam_VolumeRampTime) q->rampTime=value;
    else return -1;
    return noErr;
}
inline OSStatus AudioQueueStart(AudioQueueRef q,void*) {
    if(failStart) return -1;q->gainAtStart=q->volume;q->rampAtStart=q->rampTime;q->running=true;return noErr;
}
inline OSStatus AudioQueuePause(AudioQueueRef q) { q->running=false;return noErr; }
inline OSStatus AudioQueueStop(AudioQueueRef q,bool) {
    q->running=false;int before=enqueues;
    if(!q->allocated.empty()) q->callback(q->context,q,q->allocated.front());
    stopEnqueues+=enqueues-before;q->scheduled.clear();return noErr;
}
inline OSStatus AudioQueueDispose(AudioQueueRef q,bool) {
    for(auto b:q->allocated) { std::free(b->mAudioData);delete b; }delete q;++disposals;return noErr;
}
