// SPDX-License-Identifier: MIT
// -----------------------------------------------------------------------------
//  video.cpp  --  画面合成（グラフィック 4 プレーン + テキスト VRAM）とフォント
//
//  字形は fontrom.cpp（擬似漢字 ROM）から引く。
// -----------------------------------------------------------------------------
#include "machine.h"
#include <string.h>

static inline uint32_t rgb4(uint8_t g, uint8_t r, uint8_t b) {
    return 0xFF000000u | ((uint32_t)(r * 17) << 16) | ((uint32_t)(g * 17) << 8) | (uint32_t)(b * 17);
}

static const uint8_t s_blank16[16] = {0};

int video_render(Machine* m, uint32_t* out) {
    // PC-9821 の 256 色: グラフィックはそちらで描き、テキストだけ重ねる
    int H = pegc_render(m, out);
    if (H) goto text;
    H = 400;
    {
    // パレット
    uint32_t pal[16];
    if (m->analog) {
        for (int i = 0; i < 16; i++) pal[i] = rgb4(m->pal[i][0], m->pal[i][1], m->pal[i][2]);
    } else {
        static const int lo_idx[4] = {3, 1, 2, 0}, hi_idx[4] = {7, 5, 6, 4};
        uint8_t dp[8];
        for (int k = 0; k < 4; k++) { dp[lo_idx[k]] = (m->dig_pal[k] >> 4) & 7; dp[hi_idx[k]] = m->dig_pal[k] & 7; }   // 上位 4bit が #0-3、下位が #4-7
        for (int i = 0; i < 16; i++) {
            uint8_t v = dp[i & 7];
            pal[i] = rgb4((v & 4) ? 15 : 0, (v & 2) ? 15 : 0, (v & 1) ? 15 : 0);
        }
    }

    // グラフィック
    bool gon = m->gdcs.display != 0;
    const uint8_t (*pl)[0x8000] = m->gvram[m->disp_bank];
    // GDC の表示領域（最大 4 つ）。各領域の開始アドレスと長さを読む
    auto area_sad = [&](int a) {
        const uint8_t* pr = m->gdcs.pram + a * 4;
        return (uint32_t)(pr[0] | (pr[1] << 8) | ((pr[2] & 3) << 16));
    };
    auto area_len = [&](int a) {
        const uint8_t* pr = m->gdcs.pram + a * 4;
        return (uint32_t)((pr[2] >> 4) | ((pr[3] & 0x3F) << 4));
    };
    int zoom = ((m->gdcs.zoom >> 4) & 15) + 1;   // ZOOM の上位 4bit が表示の倍率（下位は描画用）
    // 1 本の VRAM の行を何本の走査線で見せるか: GDC の CSRFORM の「1 行の走査線数」（200 ライン表示は 2）、
    // と ZOOM のうち大きいもの（BIOS・LIO の 200 ライン表示も CSRFORM で作る）
    int rep = (m->gdcs.csrform[0] & 0x1F) + 1;
    if (rep > 4) rep = 1;                       // グラフィックでは 1〜2 のはず。変な値は無視
    if (zoom > rep) rep = zoom;
    // 1 行の大きさ: GDC の PITCH（ワード数）。横に広い仮想画面を作って SAD で横スクロールするゲームがある
    //（ヴァリアブル・ジオ 2 の対戦画面は 64 ワード = 1024 ドット幅）。表示するのは先頭の 40 ワード（640 ドット）
    // GDC が 5MHz のときは PITCH がバイト単位（8 ドット）、2.5MHz のときはワード単位（16 ドット）
    uint32_t stride = m->gdc_clk5 ? (uint32_t)(m->gdcs.pitch >= 80 ? m->gdcs.pitch : 80)
                                  : (uint32_t)(m->gdcs.pitch >= 40 ? m->gdcs.pitch : 40) * 2;
    // LEN は走査線の本数（400 ライン基準）。GDC の表示領域は最大 4 つを順に表示する。
    // LEN=0 の領域は「画面の下端まで」という従来の扱い（その領域で描画を終える）。
    // 3 領域を使う場面（例: ファーランドストーリーの戦闘カットイン = 上部固定／
    // 中央は開始アドレスで横スクロール／下部ウィンドウ固定）では、2 領域目以降を
    // 一つの開始アドレスから流し読みすると、下部が中央のスクロールに引きずられる（#31）。
    int y = 0;
    auto render_line = [&](uint32_t addr) {
        uint32_t* o = out + y * 640;
        if (!gon) { for (int x = 0; x < 640; x++) o[x] = 0xFF000000u; return; }
        for (int bx = 0; bx < 80; bx++) {
            uint32_t a = (addr + bx) & 0x7FFF;
            uint8_t b = pl[0][a], r = pl[1][a], g = pl[2][a], e = m->analog ? pl[3][a] : 0;
            for (int k = 0; k < 8; k++) {
                int sh = 7 - k;
                int ci = ((b >> sh) & 1) | (((r >> sh) & 1) << 1) | (((g >> sh) & 1) << 2) | (((e >> sh) & 1) << 3);
                o[bx * 8 + k] = pal[ci];
            }
        }
    };
    for (int a = 0; a < 4 && y < 400; a++) {
        uint32_t len = area_len(a);
        bool last = (len == 0);            // LEN=0 は下端まで
        if (last) len = 400;
        if (len > 400) len = 400;
        uint32_t sad = area_sad(a);
        for (uint32_t l = 0; l < len && y < 400; l++, y++)
            render_line(sad * 2 + (l / (uint32_t)rep) * stride);
        if (last) break;
    }
    for (; y < 400; y++)
        for (int x = 0; x < 640; x++) out[y * 640 + x] = 0xFF000000u;

    }
text:
    // テキスト
    if (!m->gdcm.display) return H;
    int rowh = (m->gdcm.csrform[0] & 0x1F) + 1;
    if (rowh < 8 || rowh > 20) rowh = 16;
    int rows = H / rowh;
    bool blink_phase = (m->frame_count / 30) & 1;
    uint32_t tsad = (uint32_t)(m->gdcm.pram[0] | (m->gdcm.pram[1] << 8));
    bool rowInk[64] = {};   // 行ごとに「実際に見える字形・印があるか」（カーソルの判定に使う）
    for (int r = 0; r < rows; r++) {
        // 全角の右半分は「直前のセルが全角の左半分だった」ことで決まる（セルの中身は見ない）。
        // 外字（76・77 区）は同じコードが続くと左→右と交互になる。
        bool kanji2nd = false;
        uint16_t lastjis = 0;
        bool gaiji_right = false;
        uint16_t lastgaiji = 0xFFFF;
        uint8_t last_at = 0;
        for (int c = 0; c < 80; c++) {
            uint32_t cell = (tsad + (uint32_t)r * 80 + (uint32_t)c) & 0xFFF;
            uint8_t lo = m->tvram[cell * 2], hi = m->tvram[cell * 2 + 1];
            uint8_t at = m->tvram[0x2000 + cell * 2];
            uint8_t g2[16];
            const uint8_t* glyph = s_blank16;
            bool semigraph = false;
            if (kanji2nd) {
                kanji2nd = false;
                const uint8_t* k = font_get_kanji(lastjis);
                for (int y = 0; y < 16; y++) g2[y] = k[y * 2 + 1];
                glyph = g2;
                at = (uint8_t)((at & 0xEF) | (last_at & 0x10));
                gaiji_right = false; lastgaiji = 0xFFFF;
            } else if ((at & 0x10) && m->modeff[0]) {
                semigraph = true;
                gaiji_right = false; lastgaiji = 0xFFFF;
            } else if (hi == 0) {
                glyph = font_get_ank(lo);
                gaiji_right = false; lastgaiji = 0xFFFF;
            } else {
                uint16_t jis = (uint16_t)((((lo & 0x7F) + 0x20) << 8) | (hi & 0x7F));
                int row = lo & 0x7F;
                const uint8_t* k = font_get_kanji(jis);
                bool right = false;
                if (row == 0x56 || row == 0x57) {
                    if (gaiji_right && jis == lastgaiji) right = true;
                    gaiji_right = !right; lastgaiji = jis;
                } else {
                    gaiji_right = false; lastgaiji = 0xFFFF;
                    if (row < 0x09 || row > 0x0B) { kanji2nd = true; lastjis = jis; }
                }
                for (int y = 0; y < 16; y++) g2[y] = k[y * 2 + (right ? 1 : 0)];
                glyph = g2;
            }
            last_at = at;
            bool rev = (at & 4) != 0;
            bool ul = (at & 8) != 0;
            bool vl = (at & 0x10) != 0 && !m->modeff[0];
            bool visible = (at & 1) != 0;
            if ((at & 2) && blink_phase) visible = false;
            if (!visible && !rev) continue;
            uint32_t col = 0xFF000000u | ((at & 0x40) ? 0xFF0000u : 0) | ((at & 0x80) ? 0x00FF00u : 0) | ((at & 0x20) ? 0x0000FFu : 0);
            // 反転した空白は色が黒なら見えない（画面端に並ぶ Farland の反転空白など）ので印に数えない。
            // 反転でも色付きならベタ塗りの印として見えるので数える
            bool cellInk = rev && col != 0xFF000000u;
            int y0 = r * rowh;
            for (int y = 0; y < rowh && y0 + y < H; y++) {
                uint8_t bits = 0;
                if (visible) {
                    if (semigraph) {
                        int by = y / (rowh / 4 ? rowh / 4 : 4); if (by > 3) by = 3;
                        bits = (uint8_t)(((lo >> by) & 1 ? 0xF0 : 0) | ((lo >> (4 + by)) & 1 ? 0x0F : 0));
                    } else if (y < 16) bits = glyph[y];
                    if (ul && y == 15) bits = 0xFF;
                    if (vl) bits |= 0x80;
                }
                if (bits) cellInk = true;   // 反転前の字形ビットで判定する
                if (rev) bits = (uint8_t)~bits;
                uint32_t* o = out + (y0 + y) * 640 + c * 8;
                for (int k = 0; k < 8; k++) if (bits & (0x80 >> k)) o[k] = col;
            }
            if (cellInk && r < 64) rowInk[r] = true;
        }
    }
    // カーソル
    // カーソルのある行に本文が無いときは出さない: グラフィック専用画面へ移るのにカーソルを
    // 消し忘れるソフト（Farland Story など）では、起動時の BIOS カーソルが空のテキスト
    // 画面の位置に点滅し続けてしまう。以前は画面全体で判定していたが、Farland は画面端に
    // 「反転した黒の空白」を並べるため、それを本文と数えて会話・戦闘シーンで再び出てしまった。
    // 本文のある行では従来どおり点滅させる。
    if ((m->gdcm.csrform[0] & 0x80) && ((m->frame_count / 16) & 1)) {
        uint32_t ead = m->gdcm.ead & 0xFFF;
        int r = (int)(ead / 80), c = (int)(ead % 80);
        if (r < rows && r < 64 && rowInk[r]) {
            // カーソルの形: CSRFORM の開始ライン〜終了ライン。開始が終了より下なら何も出ない
            //（カーソルを消すのに表示ビットではなくこちらを使うソフトがある）
            int top = m->gdcm.csrform[1] & 0x1F, bot = (m->gdcm.csrform[2] >> 3) & 0x1F;
            if (bot >= rowh) bot = rowh - 1;
            for (int y = top; y <= bot; y++) {
                if (r * rowh + y >= H) break;
                uint32_t* o = out + (r * rowh + y) * 640 + c * 8;
                for (int k = 0; k < 8; k++) o[k] ^= 0x00FFFFFFu;
            }
        }
    }
    return H;
}
