// ソフトウェア MIDI 音源（TinySoundFont）。Player::midi_sink から完結した MIDI メッセージを受け、
// フレームごとの PCM（ステレオ交互の int16）に加算する。内部にロックを持たないため、呼び出しは
// 外部で直列化すること（再生中は生成スレッド、起動・停止時は生成スレッド停止下でメインスレッド）。
// この header は TSF_IMPLEMENTATION を定義するため、ただ 1 つの翻訳単位（ios/main.mm）からだけ include すること。
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>
#define TSF_IMPLEMENTATION
#include "../third_party/tinysoundfont/tsf.h"

struct MidiSynth {
    tsf* font = nullptr;
    std::vector<float> scratch;
    uint64_t messageCount = 0, noteOnCount = 0;
    float gain = 1.0f;   // モジュレータ実装で減衰スケールが仕様準拠になり全体が下がった分の補償（+6dB）。試聴で要調整
    float limiterGain = 1.0f;   // 出力段リミッタの現在ゲイン（診断用に公開）
    uint32_t ditherState = 0x2545F491u;
    // CC7／CC11 の現在値と目標値。ハードな跳びをスルーレート制限で滑らかにする
    int volCur[16], volTgt[16], expCur[16], expTgt[16];
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
        case 0xB0:
            if (data1 == 7) volTgt[channel] = data2;         // 音量はランプ経由で反映（renderMix 参照）
            else if (data1 == 11) expTgt[channel] = data2;   // エクスプレッションも同様
            else {
                tsf_channel_midi_control(font, channel, data1, data2);
                if (data1 == 121) volCur[channel] = volTgt[channel] = expCur[channel] = expTgt[channel] = 127;
            }
            break;
        case 0xC0: tsf_channel_set_presetnumber(font, channel, data1, channel == 9); break;
        case 0xD0: tsf_channel_set_pressure(font, channel, data1); break;
        case 0xE0: tsf_channel_set_pitchwheel(font, channel, data1 | (data2 << 7)); break;   // 0..16383、8192 が中央
        }
    }
    void renderMix(int16_t* interleaved, size_t frames) {
        if (!font || !interleaved || !frames) return;
        scratch.assign(frames * 2, 0.0f);
        // CC7／CC11 のランプを効かせるため、ブロックを細かく刻んで描く
        for (size_t done = 0; done < frames;) {
            size_t n = frames - done; if (n > 128) n = 128;
            advanceCcRamps((int)n);
            tsf_render_float(font, scratch.data() + done * 2, (int)n, 1);
            done += n;
        }
        // 出力段リミッタ（MIDI バス専用）：ブロックのピークを先に測り、天井を超える分だけ
        // バス全体のゲインを下げる。アタックはブロック単位で即時（＝先行測定なので
        // ピークを通さない）、リリースは約 120ms かけて滑らかに戻す。波形整形ではないので
        // 倍音歪みは出ない。エミュレータ側（ドライ）の音には一切触れない。
        const float ceiling = 0.92f;
        float peak = 0.0f;
        for (size_t i = 0; i < frames * 2; ++i) {
            float a = scratch[i] < 0 ? -scratch[i] : scratch[i];
            if (a > peak) peak = a;
        }
        float target = peak > ceiling ? ceiling / peak : 1.0f;
        // アタックはブロック先頭の約1msで target まで滑らかに下げる。ブロック境界で
        // ゲインを一段に切り替えると、前の曲の残響など鳴っている音に段差が乗り
        // 「ブツッ」というクリックになるため。ピークは先行測定できているので、
        // 1ms のランプでも天井の超過はその間の立ち上がり分だけで済む。
        // リリースはブロック全体でランプし、このブロックの上限 target は超えない。
        float gFrom = limiterGain, gTo = target;
        if (target > gFrom) {   // 回復方向：ブロック時間に応じて 1.0 へ部分的に戻す
            float blockSec = outputRate > 0 ? (float)frames / (float)outputRate : 0.02f;
            float step = blockSec / 0.12f; if (step > 1.0f) step = 1.0f;
            gTo = gFrom + (1.0f - gFrom) * step;
            if (gTo > target) gTo = target;
        }
        limiterGain = gTo;
        const size_t attackFrames = outputRate > 0 ? (size_t)(outputRate / 1000) : 44;
        for (size_t i = 0; i < frames * 2; ++i) {
            float s = scratch[i];
            if (s == 0.0f) continue;   // MIDI が無音のサンプルは従来と完全一致させる
            size_t frame = i / 2;
            float g;
            if (gTo < gFrom)   // アタック：先頭の約1msだけランプ、残りは gTo 一定
                g = frame < attackFrames ? gFrom + (gTo - gFrom) * (float)(frame + 1) / (float)attackFrames : gTo;
            else
                g = gFrom + (gTo - gFrom) * (float)(frame + 1) / (float)frames;
            // TPDF ディザ（±1 LSB）で切り捨ての量子化バイアスを消す
            ditherState ^= ditherState << 13; ditherState ^= ditherState >> 17; ditherState ^= ditherState << 5;
            float r1 = (float)(ditherState >> 8) * (1.0f / 16777216.0f);
            ditherState ^= ditherState << 13; ditherState ^= ditherState >> 17; ditherState ^= ditherState << 5;
            float r2 = (float)(ditherState >> 8) * (1.0f / 16777216.0f);
            float v = interleaved[i] + s * 32767.0f * g + (r1 - r2);
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
    // ステートセーブ用の MIDI 状態スナップショット。チャンネル状態（音色・
    // コントローラー・ピッチ等）は tsf_channel が素のデータなので丸ごと写し、
    // ランプ目標値と GS パラメータを添える。形式: "MSST" 版(4) チャンネル
    // バイト数(4) tsf_channel×16 volCur/volTgt/expCur/expTgt（各 int×16）GS×10。
    bool snapshotState(std::vector<uint8_t>& out) {
        out.clear();
        if (!font || !font->channels || font->channels->channelNum < 16) return false;
        auto put = [&](const void* p, size_t n) { const uint8_t* b = (const uint8_t*)p; out.insert(out.end(), b, b + n); };
        uint32_t version = 1, chanBytes = (uint32_t)sizeof(tsf_channel);
        put("MSST", 4); put(&version, 4); put(&chanBytes, 4);
        put(font->channels->channels, sizeof(tsf_channel) * 16);
        put(volCur, sizeof(volCur)); put(volTgt, sizeof(volTgt)); put(expCur, sizeof(expCur)); put(expTgt, sizeof(expTgt));
        int gs[10] = {gsReverbType, gsReverbChar, gsReverbTime, gsReverbLevel, gsChorusType,
                      gsChorusRate, gsChorusDepth, gsChorusFeedback, gsChorusLevel, 0};
        put(gs, sizeof(gs));
        return true;
    }
    // スナップショットの検証。data/len が正しければ channels へのポインタを返す
    const tsf_channel* stateChannels(const uint8_t* data, size_t len) {
        if (!data || len < 12 + sizeof(tsf_channel) * 16 + sizeof(volCur) * 4 + 40) return nullptr;
        if (memcmp(data, "MSST", 4) != 0) return nullptr;
        uint32_t version, chanBytes;
        memcpy(&version, data + 4, 4); memcpy(&chanBytes, data + 8, 4);
        if (version != 1 || chanBytes != sizeof(tsf_channel)) return nullptr;
        return (const tsf_channel*)(data + 12);
    }
    bool restoreState(const uint8_t* data, size_t len) {
        if (!font || !font->channels || font->channels->channelNum < 16) return false;
        const tsf_channel* chans = stateChannels(data, len);
        if (!chans) return false;
        const uint8_t* p = (const uint8_t*)(chans + 16);
        allSoundOff();
        memcpy(font->channels->channels, chans, sizeof(tsf_channel) * 16);
        memcpy(volCur, p, sizeof(volCur)); p += sizeof(volCur);
        memcpy(volTgt, p, sizeof(volTgt)); p += sizeof(volTgt);
        memcpy(expCur, p, sizeof(expCur)); p += sizeof(expCur);
        memcpy(expTgt, p, sizeof(expTgt)); p += sizeof(expTgt);
        int gs[10]; memcpy(gs, p, sizeof(gs));
        gsReverbType = gs[0]; gsReverbChar = gs[1]; gsReverbTime = gs[2]; gsReverbLevel = gs[3];
        gsChorusType = gs[4]; gsChorusRate = gs[5]; gsChorusDepth = gs[6]; gsChorusFeedback = gs[7]; gsChorusLevel = gs[8];
        // CC7/CC11 は保存時の目標値へ即時に合わせ、チャンネル側の派生値も作り直す
        for (int ch = 0; ch < 16; ++ch) {
            volCur[ch] = volTgt[ch]; expCur[ch] = expTgt[ch];
            tsf_channel_midi_control(font, ch, 7, volTgt[ch]);
            tsf_channel_midi_control(font, ch, 11, expTgt[ch]);
        }
        applyGsEffects();
        return true;
    }
    // 外部 MIDI 音源へ状態を送り直すためのメッセージ列をスナップショットから作る
    bool stateReplayMessages(const uint8_t* data, size_t len, std::vector<std::vector<uint8_t>>& out) {
        out.clear();
        if (!font) return false;
        const tsf_channel* chans = stateChannels(data, len);
        if (!chans) return false;
        const int* ramps = (const int*)(chans + 16);          // volCur, volTgt, expCur, expTgt の順
        const int* volTgtP = ramps + 16, * expTgtP = ramps + 48;
        const int* gs = ramps + 64;
        auto dt1 = [&](uint8_t addr3, const std::vector<uint8_t>& payload) {
            std::vector<uint8_t> m = {0xF0, 0x41, 0x10, 0x42, 0x12, 0x40, 0x01, addr3};
            int sum = 0x40 + 0x01 + addr3;
            for (uint8_t v : payload) { m.push_back(v & 0x7F); sum += v & 0x7F; }
            m.push_back((uint8_t)((128 - (sum & 0x7F)) & 0x7F));
            m.push_back(0xF7);
            out.push_back(m);
        };
        dt1(0x30, {(uint8_t)gs[0], (uint8_t)gs[1], (uint8_t)gs[2], (uint8_t)gs[3]});   // リバーブ
        dt1(0x38, {(uint8_t)gs[4]});                                                  // コーラスタイプ
        if (gs[5] >= 0 || gs[6] >= 0 || gs[7] >= 0 || gs[8] >= 0)                    // コーラス詳細（未指定は 0 で埋める）
            dt1(0x3A, {(uint8_t)(gs[5] < 0 ? 0 : gs[5]), (uint8_t)(gs[6] < 0 ? 0 : gs[6]),
                       (uint8_t)(gs[7] < 0 ? 0 : gs[7]), (uint8_t)(gs[8] < 0 ? 0 : gs[8])});
        static const int kCCs[] = {0, 32, 1, 2, 5, 91, 93, 65, 84, 100, 101, 6, 38, 64};
        for (int ch = 0; ch < 16; ++ch) {
            const tsf_channel& c = chans[ch];
            auto cc = [&](int num, int val) { out.push_back({(uint8_t)(0xB0 | ch), (uint8_t)num, (uint8_t)(val & 0x7F)}); };
            cc(0, c.midiCC[0]); cc(32, c.midiCC[32]);
            if (c.presetIndex < font->presetNum)
                out.push_back({(uint8_t)(0xC0 | ch), (uint8_t)(font->presets[c.presetIndex].preset & 0x7F)});
            for (int num : kCCs) if (num != 0 && num != 32) cc(num, c.midiCC[num]);
            cc(7, volTgtP[ch]); cc(11, expTgtP[ch]); cc(10, c.midiCC[10]);
            out.push_back({(uint8_t)(0xE0 | ch), (uint8_t)(c.pitchWheel & 0x7F), (uint8_t)((c.pitchWheel >> 7) & 0x7F)});
            if (c.midiPressure) out.push_back({(uint8_t)(0xD0 | ch), c.midiPressure});
        }
        return !out.empty();
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
        for (int ch = 0; ch < 16; ++ch) volCur[ch] = volTgt[ch] = expCur[ch] = expTgt[ch] = 127;
    }
    // CC7／CC11 を目標値へ少しずつ寄せ、tsf へ中間値を送る（フルスイングで約12ms）。
    // チャンネル音量は発音中のノートにも即効くため、値の跳びがそのまま波形の段差になる。
    void advanceCcRamps(int chunkFrames) {
        int step = outputRate > 0 ? (int)(127.0 * chunkFrames / (outputRate * 0.012) + 0.5) : 32;
        if (step < 1) step = 1;
        for (int ch = 0; ch < 16; ++ch) {
            if (volCur[ch] != volTgt[ch]) {
                int d = volTgt[ch] - volCur[ch]; if (d > step) d = step; else if (d < -step) d = -step;
                volCur[ch] += d; tsf_channel_midi_control(font, ch, 7, volCur[ch]);
            }
            if (expCur[ch] != expTgt[ch]) {
                int d = expTgt[ch] - expCur[ch]; if (d > step) d = step; else if (d < -step) d = -step;
                expCur[ch] += d; tsf_channel_midi_control(font, ch, 11, expCur[ch]);
            }
        }
    }
};
