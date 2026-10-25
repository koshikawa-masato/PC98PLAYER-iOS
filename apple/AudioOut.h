// SPDX-License-Identifier: MIT
#pragma once
#import <AudioToolbox/AudioToolbox.h>
#include <array>
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
    uint64_t generation = 0;
    bool started = false, paused = false, acceptingCallbacks = false;

    void fillLocked(AudioQueueBufferRef buffer) {
        auto* dst = static_cast<int16_t*>(buffer->mAudioData);
        size_t count = buffer->mAudioDataBytesCapacity / sizeof(int16_t);
        for (size_t i = 0; i < count; ++i) {
            dst[i] = samples.empty() ? 0 : samples.front();
            if (!samples.empty()) samples.pop_front();
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
        // Pause/resume retains already scheduled PCM and its position. Reopening
        // discarded that tail and inserted three silent buffers on every resume.
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
        if (started) AudioQueuePause(queue);
    }
    bool startOutput() {
        // Apply gain after the queued PCM, including a partially played buffer.
        // A PCM-side fade would miss the buffers already owned by AudioQueue.
        if (AudioQueueSetParameter(queue, kAudioQueueParam_VolumeRampTime, 0) != noErr ||
            AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 0) != noErr ||
            AudioQueueSetParameter(queue, kAudioQueueParam_VolumeRampTime, .005f) != noErr ||
            AudioQueueStart(queue, nullptr) != noErr) return false;
        return AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 1) == noErr;
    }
    bool resume() {
        if (!paused) return true;
        paused = false;
        if (started && !startOutput()) { AudioQueuePause(queue);paused = true;return false; }
        return true;
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
    // Clear both the producer FIFO and AudioQueue's scheduled buffers. Used at
    // discontinuities (state load/game change), never for an ordinary pause.
    void clear() {
        { std::lock_guard<std::mutex> lock(mutex); acceptingCallbacks = false; }
        if (queue) AudioQueueStop(queue, true);
        std::lock_guard<std::mutex> lock(mutex);
        samples.clear(); started = false; acceptingCallbacks = queue != nullptr;
    }
    void close() {
        { std::lock_guard<std::mutex> lock(mutex); acceptingCallbacks = false; }
        // Do not hold the mutex here: synchronous teardown may invoke callbacks.
        if (queue) { AudioQueueStop(queue, true); AudioQueueDispose(queue, true); }
        queue = nullptr; buffers.fill(nullptr); sampleRate = 0; started = paused = false;
        std::lock_guard<std::mutex> lock(mutex); samples.clear();
    }
    ~AudioOut() { close(); }
};
