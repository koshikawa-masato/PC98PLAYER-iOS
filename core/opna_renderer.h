// SPDX-License-Identifier: MIT
// -----------------------------------------------------------------------------
//  opna_renderer.h  --  OPNA 音声生成の差し替え口
//
//  本体（CPU・DOS・タイマ・レジスタ）は音を作らない。ここが唯一の音源境界。
//
//  ・GMPV3_WITH_YMFM を定義してビルドすると ymfm (BSD, Aaron Giles) を使う。
//    ymfm は本リポジトリに同梱していない。tools/fetch_ymfm.ps1 で取得する。
//  ・定義しなければ無音スタブになる。この状態でもリポジトリはそのままビルドでき、
//    ドライバの常駐・レジスタ書き込み・MIDI 出力の確認はすべて行える。
//
//  同梱しない理由は単純で、配布物に他人の著作物を含めないため。ライセンス上は
//  BSD なので同梱してもよいが、含めなければ告知義務の管理そのものが消える。
// -----------------------------------------------------------------------------
#ifndef OPNA_RENDERER_H
#define OPNA_RENDERER_H

#include <stdint.h>
#include <vector>

class OpnaRenderer {
public:
    OpnaRenderer();
    ~OpnaRenderer();

    void init(uint32_t chip_clock, int sample_rate);
    void reset();

    // part: 0 = 188h/18Ah 側、1 = 18Ch/18Eh 側
    void write(int part, uint8_t addr, uint8_t val);

    // ADPCM-B の状態ビット（拡張ステータス読みの並び: EOS=04h / BRDY=08h /
    // ZERO=10h / PLAYING=20h だけを抜いたもの）。CPU 側が 18Ch の読みで
    // タイマフラグと合成して返すための値。ymfm が無いときは 0。
    uint8_t status_adpcm_bits();

    // 1 フレーム分のステレオサンプルを生成する（-1.0 .. +1.0）
    void render_one(float* left, float* right);

    // スナップショット復元後、レジスタの内容からチップ状態を作り直す
    void reload_from_registers(const uint8_t* part0, const uint8_t* part1);

    // チップ内部（エンベロープ・位相・リサンプル位置まで）を丸ごと保存／復元する。
    // ステートセーブ用。ymfm が無いときは空を返し、復元は何もしない。
    void save_chip(std::vector<uint8_t>& out);
    bool load_chip(const std::vector<uint8_t>& in);

    // ADPCM-B の DRAM の中身を差し替える（ステート復元で CPU 側ミラーと
    // 揃えるため）。チップ内部の保存には外部メモリが含まれないので別に持つ。
    void set_adpcm_ram(const uint8_t* data, size_t len);

    // ADPCM-B の CPU 駆動再生（実行・非記録・非外部メモリ）でゲストが流す
    // バイト列の FIFO。消費・破棄した累計（CPU 側の占有量計算と合わせる）、
    // ステート保存用の中身の取り出しと復元。
    uint64_t adpcm_stream_consumed();
    void adpcm_stream_bytes(std::vector<uint8_t>& out);
    void set_adpcm_stream(const uint8_t* data, size_t len);

    // FM と SSG の音量比。実機でもボードや本体のつまみで変わる部分なので開ける。
    void set_balance(double fm_gain, double ssg_gain);

    // リズム音源の ADPCM ROM。
    //   ・init() の時点で自前合成の 8KB が入っている（何も渡さなくても鳴る）
    //   ・本物の ROM を渡せばそちらで上書きされる（そちらが優先）
    //   ・data=NULL / len=0 で呼ぶと自前合成へ戻す
    // 戻り値 true = 差し替えた。
    bool set_rhythm_rom(const uint8_t* data, int len);

    // リズムを鳴らすかどうか。false にすると ADPCM-A の読み出しが 0 になり、
    // 本物を知っている人が「代用より無音がよい」を選べる。
    void set_rhythm_enabled(bool on);

    // いま何を使っているか。0 = 切 / 1 = 自前合成 / 2 = 渡された本物の ROM
    int rhythm_source() const;

    // 音源が組み込まれているか（0 = 無音スタブ）
    static int available();

private:
    void* impl_;
    uint32_t clock_;
    int      rate_;
};

#endif
