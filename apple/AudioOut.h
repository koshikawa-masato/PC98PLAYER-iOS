// SPDX-License-Identifier: MIT
#pragma once
#import <AudioToolbox/AudioToolbox.h>
#include <array>
#include <algorithm>
#include <deque>
#include <mutex>
#include <vector>
#include <cstdint>
// Lifecycle operations and PCM production run on the main thread. The callback
// owns no guest state; its mutex also gates enqueueing during stop/dispose.
struct AudioOut {
    static constexpr size_t bufferCount = 3, bufferFrames = 512;
    AudioQueueRef queue = nullptr;
    std::array<AudioQueueBufferRef, bufferCount> buffers = {};
    std::mutex mutex;
    std::deque<int16_t> samples;
    size_t capacity = 44100;
    int sampleRate = 0;
    uint64_t generation = 0, underrunFrames = 0;
    bool started = false, paused = false, acceptingCallbacks = false;

    bool rebuffering = false;
    size_t recoveryFadeFrame = 0;
    int16_t lastLeft = 0, lastRight = 0;
    void fillLocked(AudioQueueBufferRef buffer) {
        auto* dst = static_cast<int16_t*>(buffer->mAudioData);
        size_t count = buffer->mAudioDataBytesCapacity / sizeof(int16_t), frames = count / 2;
        size_t reserve = std::max(bufferCount * bufferFrames * 2, (size_t)sampleRate / 10); // 50 ms stereo
        if (rebuffering && samples.size() >= reserve) { rebuffering = false;recoveryFadeFrame = 1; }
        if (rebuffering || samples.size() < count) {
            // Do not emit tiny PCM islands between repeated underruns. Keep the
            // unread tail until a useful reserve exists; taper the final value
            // to zero without replaying any previously consumed source samples.
            rebuffering = true;underrunFrames += frames;
            for(size_t frame=0;frame<frames;++frame) {
                float gain=frame<32 ? (31-frame)/32.f : 0;
                dst[frame*2]=(int16_t)(lastLeft*gain);dst[frame*2+1]=(int16_t)(lastRight*gain);
            }
            lastLeft=lastRight=0;
        } else {
            size_t fadeFrames=std::max((size_t)1,(size_t)sampleRate*16/1000);
            for(size_t frame=0;frame<frames;++frame) {
                float gain=1;
                if(recoveryFadeFrame) {
                    gain=std::min(1.f,(recoveryFadeFrame-1)/(float)fadeFrames);
                    if(++recoveryFadeFrame>fadeFrames+1) recoveryFadeFrame=0;
                }
                dst[frame*2]=(int16_t)(samples.front()*gain);samples.pop_front();
                dst[frame*2+1]=(int16_t)(samples.front()*gain);samples.pop_front();
            }
            lastLeft=dst[count-2];lastRight=dst[count-1];
        }
        buffer->mAudioDataByteSize = buffer->mAudioDataBytesCapacity;
    }
    static void callback(void* context, AudioQueueRef queue, AudioQueueBufferRef buffer) {
        auto* self = static_cast<AudioOut*>(context);
        std::lock_guard<std::mutex> lock(self->mutex);
        if (!self->acceptingCallbacks) return;
        self->fillLocked(buffer);
        AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
    }
    bool open(int rate) {
        // Keep the allocated queue, but never replay PCM queued before a pause.
        // resume() waits for newly generated PCM instead of priming silence.
        if (queue && sampleRate == rate) return resume();
        close();
        sampleRate = rate;
        capacity = (size_t)rate / 2; // at most 250 ms of stereo PCM
        AudioStreamBasicDescription fmt = {};
        fmt.mSampleRate = rate;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        fmt.mBytesPerPacket = fmt.mBytesPerFrame = 4;
        fmt.mFramesPerPacket = 1; fmt.mChannelsPerFrame = 2; fmt.mBitsPerChannel = 16;
        if (AudioQueueNewOutput(&fmt, callback, this, nullptr, nullptr, 0, &queue) != noErr) { close(); return false; }
        ++generation;
        for (auto& buffer : buffers) {
            if (AudioQueueAllocateBuffer(queue, bufferFrames * 4, &buffer) != noErr) { close(); return false; }
        }
        { std::lock_guard<std::mutex> lock(mutex); acceptingCallbacks = true; }
        // push() starts output once all queue buffers can contain actual PCM.
        return true;
    }
    void pause() {
        if (!queue || paused) return;
        paused = true;
        // Discard scheduled and prefetched audio across a pause. The next guest
        // frame supplies fresh PCM, with the existing 16 ms output fade.
        clear();
    }
    bool startOutput() {
        // Apply gain after the queued PCM, including a partially played buffer.
        // A PCM-side fade would miss the buffers already owned by AudioQueue.
        if (AudioQueueSetParameter(queue, kAudioQueueParam_VolumeRampTime, 0) != noErr ||
            AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 0) != noErr ||
            AudioQueueSetParameter(queue, kAudioQueueParam_VolumeRampTime, .016f) != noErr ||
            AudioQueueStart(queue, nullptr) != noErr) return false;
        return AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 1) == noErr;
    }
    bool resume() {
        if (!paused) return true;
        paused = false;
        return true;
    }
    bool needsFrames() {
        std::lock_guard<std::mutex> lock(mutex);
        // Audio consumption is the clock. Keep 80 ms of software PCM in reserve
        // so a layout transaction cannot drain the three hardware buffers.
        size_t target=std::max(bufferCount*bufferFrames*2,(size_t)sampleRate*2*80/1000);
        return queue && !paused && (!started || samples.size()<target);
    }
    void push(const std::vector<int16_t>& pcm) {
        if (!queue || paused) return;
        bool start = false, failed = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (samples.size() + pcm.size() > capacity) samples.clear();
            samples.insert(samples.end(), pcm.begin(), pcm.end());
            if (!started && samples.size() >= bufferCount * bufferFrames * 2) {
                for (auto buffer : buffers) {
                    fillLocked(buffer);
                    if (AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr) != noErr) { failed = true; break; }
                }
                if (!failed) { started = true; start = true; }
            }
        }
        if (failed || (start && !startOutput())) clear();
    }
    // Clear both the producer FIFO and AudioQueue's scheduled/prefetched buffers.
    // The callback gate is closed before synchronous stop invokes late callbacks.
    void clear() {
        { std::lock_guard<std::mutex> lock(mutex); acceptingCallbacks = false; }
        if (queue) AudioQueueStop(queue, true);
        std::lock_guard<std::mutex> lock(mutex);
        samples.clear(); started = false;rebuffering = false;recoveryFadeFrame=0;lastLeft=lastRight=0;acceptingCallbacks = queue != nullptr;
    }
    void close() {
        { std::lock_guard<std::mutex> lock(mutex); acceptingCallbacks = false; }
        // Do not hold the mutex here: synchronous teardown may invoke callbacks.
        if (queue) { AudioQueueStop(queue, true); AudioQueueDispose(queue, true); }
        queue = nullptr; buffers.fill(nullptr); sampleRate = 0; started = paused = false;
        std::lock_guard<std::mutex> lock(mutex); samples.clear();rebuffering=false;recoveryFadeFrame=0;lastLeft=lastRight=0;
    }
    ~AudioOut() { close(); }
};
