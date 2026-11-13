// ソフトウェア MIDI 音源（TinySoundFont）。Player::midi_sink から完結した MIDI メッセージを受け、
// フレームごとの PCM（ステレオ交互の int16）に加算する。内部にロックを持たないため、呼び出しは
// 外部で直列化すること（再生中は生成スレッド、起動・停止時は生成スレッド停止下でメインスレッド）。
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
    // Roland GS エフェクトパラメータ（SysEx で受信）。リバーブは既定値
    // （Hall 2 / Time 64 / Level 127）が従来の固定チューニングと一致する。
    // コーラスは -1 が「未指定＝エンジン既定値を使う」。
    int gsReverbType = 4, gsReverbChar = 4, gsReverbTime = 64, gsReverbLevel = 127;
    int gsChorusType = 2, gsChorusRate = -1, gsChorusDepth = -1, gsChorusFeedback = -1, gsChorusLevel = -1;

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
        applyGsEffects();
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
            if (gmOn || gs) { reset(); return; }
            // Roland DT1: F0 41 <device> 42 12 <addr x3> <data...> <checksum> F7
            if (len >= 11 && msg[1] == 0x41 && msg[3] == 0x42 && msg[4] == 0x12 && msg[len - 1] == 0xF7) {
                int sum = 0;
                for (int i = 5; i <= len - 3; ++i) sum += msg[i];
                if (msg[len - 2] == ((128 - (sum & 0x7F)) & 0x7F)) {
                    if (msg[5] == 0x40 && msg[6] == 0x00 && msg[7] == 0x7F) { reset(); return; }
                    if (msg[5] == 0x40 && msg[6] == 0x01) {
                        for (int i = 0; i < len - 10; ++i) {
                            int param = msg[7] + i;
                            uint8_t value = msg[8 + i] & 0x7F;
                            switch (param) {
                            case 0x30: gsReverbType = value; break;
                            case 0x31: gsReverbChar = value; break;
                            case 0x32: gsReverbTime = value; break;
                            case 0x33: gsReverbLevel = value; break;
                            case 0x38: gsChorusType = value; break;
                            case 0x3A: gsChorusRate = value; break;
                            case 0x3B: gsChorusDepth = value; break;
                            case 0x3C: gsChorusFeedback = value; break;
                            case 0x3D: gsChorusLevel = value; break;
                            default: break;   // 0x39 コーラスキャラクター等は未対応
                            }
                        }
                        applyGsEffects();
                    }
                }
            }
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
        gsReverbType = 4; gsReverbChar = 4; gsReverbTime = 64; gsReverbLevel = 127;
        gsChorusType = 2; gsChorusRate = gsChorusDepth = gsChorusFeedback = gsChorusLevel = -1;
        applyGsEffects();
    }
    // GS パラメータをエンジンのエフェクトへ反映する。リバーブの既定値は従来の
    // 固定チューニング（feedback .86 / damping .20 / wet .6 / size 1）と一致する。
    // コーラスの未指定項目は 0 を渡し、エンジン既定値のままにする。
    // リバーブタイプ 6/7（Delay 系）は Hall 2 相当で近似する。
    void applyGsEffects() {
        if (!font) return;
        static const float revFb[8]   = {0.78f, 0.81f, 0.84f, 0.88f, 0.86f, 0.90f, 0.86f, 0.86f};
        static const float revDamp[8] = {0.38f, 0.34f, 0.30f, 0.24f, 0.20f, 0.10f, 0.20f, 0.20f};
        static const float revSize[8] = {0.70f, 0.78f, 0.86f, 0.95f, 1.00f, 0.92f, 1.00f, 1.00f};
        int rt = gsReverbType & 7;
        float fb = revFb[rt] + (gsReverbTime - 64) * 0.0012f;
        if (fb > 0.97f) fb = 0.97f; else if (fb < 0.50f) fb = 0.50f;
        float damp = revDamp[rt] + (4.0f - gsReverbChar) * 0.015f;
        if (damp > 0.90f) damp = 0.90f; else if (damp < 0.02f) damp = 0.02f;
        tsf_set_reverb_parameters(font, fb, damp, 0.6f * gsReverbLevel / 127.0f, revSize[rt]);
        static const float choBase[8] = {14.0f, 15.5f, 17.0f, 19.0f, 17.0f, 3.5f, 45.0f, 45.0f};
        int ct = gsChorusType & 7;
        float rate = gsChorusRate >= 0 ? 0.1f + gsChorusRate * 0.011f : (ct == 5 ? 0.5f : 0.0f);
        float depth;
        if (ct >= 6) depth = 0.01f;   // Delay 系は変調なし（0 はエンジン既定値の意味なので微小値で表す）
        else if (gsChorusDepth >= 0) { depth = 0.3f + gsChorusDepth * 0.073f; if (ct == 5) depth *= 0.5f; }
        else depth = (ct == 5 ? 2.5f : 0.0f);
        float cf = gsChorusFeedback >= 0 ? gsChorusFeedback * 0.0035f : 0.0f;
        if (ct == 4 && cf < 0.20f) cf = 0.20f;
        if (ct == 5 && cf < 0.45f) cf = 0.45f;
        if (ct == 7 && cf < 0.40f) cf = 0.40f;
        float cwet = gsChorusLevel >= 0 ? gsChorusLevel / 64.0f : 0.0f;
        if (cwet > 1.6f) cwet = 1.6f;
        tsf_set_chorus_parameters(font, choBase[ct], depth, rate, cwet, cf);
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
