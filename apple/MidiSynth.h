// ソフトウェア MIDI 音源（TinySoundFont）。Player::midi_sink から完結した MIDI メッセージを受け、
// フレームごとの PCM（ステレオ交互の int16）に加算する。すべてメインスレッドから呼ぶ。
// この header は TSF_IMPLEMENTATION を定義するため、ただ 1 つの翻訳単位（ios/main.mm）からだけ include すること。
#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>
#define TSF_IMPLEMENTATION
#include "../third_party/tinysoundfont/tsf.h"

struct MidiSynth {
    tsf* font = nullptr;
    std::vector<float> scratch;
    uint64_t messageCount = 0, noteOnCount = 0;
    float gain = 1.0f;   // モジュレータ実装で減衰スケールが仕様準拠になり全体が下がった分の補償（+6dB）。試聴で要調整
    int outputRate = 0;

    MidiSynth() = default;
    MidiSynth(const MidiSynth&) = delete;
    MidiSynth& operator=(const MidiSynth&) = delete;
    ~MidiSynth() { close(); }

    bool load(const void* data, int size, int sampleRate) {
        close();
        font = tsf_load_memory(data, size);
        if (!font) return false;
        setOutputRate(sampleRate);
        initChannels();
        return true;
    }
    // 出力の標本化周波数だけを変える（音色は読み直さない）。tsf_set_output は音量も戻すので掛け直す
    void setOutputRate(int rate) {
        if (!font) return;
        tsf_set_output(font, TSF_STEREO_INTERLEAVED, rate, 0.0f);
        tsf_set_volume(font, gain);
        outputRate = rate;
    }
    void handleMessage(const uint8_t* msg, int len) {
        ++messageCount;
        if (!font || !msg || len < 1) return;
        uint8_t status = msg[0];
        if (status >= 0xF8) return;   // リアルタイム
        if (status == 0xF0) {
            bool gmOn = len == 6 && msg[1] == 0x7E && msg[3] == 0x09 && msg[4] == 0x01 && msg[5] == 0xF7;
            static const uint8_t gsReset[] = {0xF0, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7};
            bool gs = len == (int)sizeof(gsReset);
            for (int i = 0; gs && i < len; ++i) gs = msg[i] == gsReset[i];
            if (gmOn || gs) reset();
            return;
        }
        if (status < 0x80 || status >= 0xF0) return;
        int channel = status & 0x0F, data1 = len > 1 ? msg[1] & 0x7F : 0, data2 = len > 2 ? msg[2] & 0x7F : 0;
        switch (status & 0xF0) {
        case 0x80: tsf_channel_note_off(font, channel, data1); break;
        case 0x90:
            if (data2) { tsf_channel_note_on(font, channel, data1, data2 / 127.0f); ++noteOnCount; }
            else tsf_channel_note_off(font, channel, data1);
            break;
        case 0xB0: tsf_channel_midi_control(font, channel, data1, data2); break;
        case 0xC0: tsf_channel_set_presetnumber(font, channel, data1, channel == 9); break;
        case 0xD0: tsf_channel_set_pressure(font, channel, data1); break;
        case 0xE0: tsf_channel_set_pitchwheel(font, channel, data1 | (data2 << 7)); break;   // 0..16383、8192 が中央
        }
    }
    void renderMix(int16_t* interleaved, size_t frames) {
        if (!font || !interleaved || !frames) return;
        scratch.assign(frames * 2, 0.0f);
        tsf_render_float(font, scratch.data(), (int)frames, 1);
        for (size_t i = 0; i < frames * 2; ++i) {
            float v = interleaved[i] + scratch[i] * 32767.0f;
            interleaved[i] = (int16_t)(v < -32768.0f ? -32768.0f : v > 32767.0f ? 32767.0f : v);
        }
    }
    // 一時停止用。発音だけを止め（リリースあり）、音色・コントローラーの設定は残す
    void allSoundOff() {
        if (!font) return;
        for (int ch = 0; ch < 16; ++ch) tsf_channel_note_off_all(font, ch);
    }
    // GM/GS リセットとゲーム終了用。tsf_reset はチャンネルを消すので 16 チャンネルを作り直す
    void reset() {
        if (!font) return;
        tsf_reset(font);
        initChannels();
    }
    void close() {
        if (font) tsf_close(font);
        font = nullptr;
        outputRate = 0;
    }
private:
    // tsf は設定されたことのないチャンネルのノートオンを捨てるため、最初に全チャンネルを作る
    void initChannels() {
        for (int ch = 0; ch < 16; ++ch) tsf_channel_set_presetnumber(font, ch, 0, ch == 9);
    }
};
