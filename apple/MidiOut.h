// 外部 MIDI 出力（Core MIDI）。Player::midi_sink から完結した MIDI メッセージを受け、
// 選択された送信先（他の音源アプリの仮想ポート、Bluetooth／USB／ネットワーク MIDI 機器）へ送る。
// すべてメインスレッドから呼ぶ。ios/main.mm からだけ include すること。
#pragma once
#include <CoreMIDI/CoreMIDI.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

struct MidiOut {
    MIDIClientRef client = 0;
    MIDIPortRef port = 0;
    MIDIEndpointRef endpoint = 0;   // 借り物（所有しない）
    int32_t wantedUniqueID = 0;     // 0 = 最初に見つかった送信先
    std::string wantedName;         // uniqueID で見つからない時の名前フォールバック
    std::string connectedName;
    uint64_t messageCount = 0, sentCount = 0, errorCount = 0;

    MidiOut() = default;
    MidiOut(const MidiOut&) = delete;
    MidiOut& operator=(const MidiOut&) = delete;
    ~MidiOut() { close(); }

    // 利用可能な送信先の一覧（uniqueID と表示名）。設定画面の選択用
    static std::vector<std::pair<int32_t, std::string>> destinations() {
        std::vector<std::pair<int32_t, std::string>> list;
        ItemCount count = MIDIGetNumberOfDestinations();
        for (ItemCount i = 0; i < count; ++i) {
            MIDIEndpointRef ep = MIDIGetDestination(i);
            if (!ep) continue;
            int32_t uid = 0;
            MIDIObjectGetIntegerProperty(ep, kMIDIPropertyUniqueID, &uid);
            list.emplace_back(uid, endpointName(ep));
        }
        return list;
    }
    static std::string endpointName(MIDIEndpointRef ep) {
        CFStringRef name = nullptr;
        if (MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &name) != noErr || !name)
            MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &name);
        std::string result;
        if (name) {
            char buffer[256];
            if (CFStringGetCString(name, buffer, sizeof(buffer), kCFStringEncodingUTF8)) result = buffer;
            CFRelease(name);
        }
        return result;
    }

    // 送信先を開く。同じ指定で開き直した場合は何もしない
    bool open(int32_t uniqueID, const std::string& nameHint) {
        if (client && port && wantedUniqueID == uniqueID && wantedName == nameHint) {
            if (!endpoint) resolve();
            return endpoint != 0;
        }
        close();
        wantedUniqueID = uniqueID;
        wantedName = nameHint;
        if (MIDIClientCreate(CFSTR("RetroDOS Player"), nullptr, nullptr, &client) != noErr) { client = 0; return false; }
        if (MIDIOutputPortCreate(client, CFSTR("MIDI OUT"), &port) != noErr) { port = 0; close(); return false; }
        resolve();
        return endpoint != 0;
    }
    void close() {
        if (port) { MIDIPortDispose(port); port = 0; }
        if (client) { MIDIClientDispose(client); client = 0; }
        endpoint = 0;
        connectedName.clear();
    }
    bool connected() const { return endpoint != 0; }
    // 指定（uniqueID → 名前 → 最初の送信先）の順で送信先を探す
    bool resolve() {
        endpoint = 0;
        connectedName.clear();
        ItemCount count = MIDIGetNumberOfDestinations();
        MIDIEndpointRef byName = 0, first = 0;
        for (ItemCount i = 0; i < count; ++i) {
            MIDIEndpointRef ep = MIDIGetDestination(i);
            if (!ep) continue;
            if (!first) first = ep;
            int32_t uid = 0;
            MIDIObjectGetIntegerProperty(ep, kMIDIPropertyUniqueID, &uid);
            if (wantedUniqueID && uid == wantedUniqueID) { endpoint = ep; break; }
            if (!wantedName.empty() && !byName && endpointName(ep) == wantedName) byName = ep;
        }
        if (!endpoint) endpoint = byName ? byName : first;
        if (endpoint) connectedName = endpointName(endpoint);
        return endpoint != 0;
    }

    void handleMessage(const uint8_t* msg, int len) {
        ++messageCount;
        if (!msg || len < 1) return;
        if (!endpoint) {
            // 音源アプリが後から起動された場合に備え、1秒に1回だけ探し直す
            double now = CFAbsoluteTimeGetCurrent();
            if (now - lastResolveAttempt < 1.0) return;
            lastResolveAttempt = now;
            if (!port || !resolve()) return;
        }
        sendBytes(msg, len);
    }
    // 一時停止・終了用。全チャンネルの発音を止める
    void allSoundOff() {
        if (!endpoint) return;
        for (int ch = 0; ch < 16; ++ch) {
            const uint8_t off120[] = {(uint8_t)(0xB0 | ch), 120, 0};
            const uint8_t off123[] = {(uint8_t)(0xB0 | ch), 123, 0};
            sendBytes(off120, 3);
            sendBytes(off123, 3);
        }
    }
    // ゲーム開始・終了用。コントローラーも初期状態へ戻してから発音を止める
    void reset() {
        if (!endpoint) return;
        for (int ch = 0; ch < 16; ++ch) {
            const uint8_t reset121[] = {(uint8_t)(0xB0 | ch), 121, 0};
            sendBytes(reset121, 3);
        }
        allSoundOff();
    }

private:
    double lastResolveAttempt = 0;
    void sendBytes(const uint8_t* msg, int len) {
        if (!endpoint || !port) return;
        // MIDIPacketList は可変長なので、メッセージ長に合わせて確保する（SysEx 対応）
        size_t capacity = sizeof(MIDIPacketList) + (size_t)len + 256;
        std::vector<uint8_t> storage(capacity);
        MIDIPacketList* list = reinterpret_cast<MIDIPacketList*>(storage.data());
        MIDIPacket* packet = MIDIPacketListInit(list);
        packet = MIDIPacketListAdd(list, capacity, packet, 0, (ByteCount)len, msg);
        if (!packet) { ++errorCount; return; }
        if (MIDISend(port, endpoint, list) == noErr) ++sentCount;
        else { ++errorCount; endpoint = 0; connectedName.clear(); }   // 送信先が消えたら次回探し直す
    }
};
