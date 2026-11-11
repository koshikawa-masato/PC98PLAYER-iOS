# エージェント向け引き継ぎ

更新日：2026-11-11（日本時間）。このファイルを最初に読み、現在のユーザー指示を優先してください。
旧引き継ぎは [2026-11-06の記録](docs/handoff-20261106.md) に保存しています。旧版の配布番号・未完了事項を現在の状態と混同しないでください。

## クローンして再開する

```sh
git clone https://github.com/koshikawa-masato/PC98PLAYER-iOS.git
cd PC98PLAYER-iOS
git switch main
git status --short
./tools/fetch_ymfm.sh
IOS_VERSION=0.2.4 IOS_BUILD_NUMBER=51 IOS_UI_TESTS=ON \
  IOS_FEEDBACK_URL=https://feedback.three-sisters.ai/v1/feedback ./build_ios.sh
```

このコマンドはローカルのシミュレーター用ビルドです。公開済みの番号を新しい配布に再使用しないでください。配布時はApp Store Connectで未使用の番号を確認します。

- CMakeとXcodeを使います。Duoの公開APIを含める場合はXcode 27.1以降。従来SDKでも条件付きコンパイルされます。
- ymfmは上記スクリプトで固定リビジョンを取得します。
- Core MLモデルとライセンスはリポジトリに含まれます。通常のビルドでモデルの再学習・再変換は不要です。
- ゲームデータ、セーブ、NAS接続、Apple署名情報、OAuth/CloudflareのSecret、ローカルのビルド成果物はクローンされません。
- エディタでは生成された `build/ios-iphonesimulator/PC98PLAYER.xcodeproj` を開きます。データなしの確認には起動引数 `--demo` を使えます。

## 現在のコードと公開版

- App Store公開版は **0.2.4（ビルド51）**。2026-11-11に公開を確認。署名・配布記録は [docs/testflight.md](docs/testflight.md)。
- フィードバックフォーム、匿名／Xのメール受付、GitHub App経由のIssue投稿、エラー時の案内、任意の診断JSONをソースへ取り込み済みです。
- 今回の統合には、公開版にまだ含まれていないモザイクの20×20ピクセル再判定と確認用UIテストを含みます。mainをビルドしたものとApp Store版が同一だとは扱わないでください。
- モザイクは大区画で候補を絞り、周辺の小区画を1回につき最大4個判定します。未判定部分は覆い、変化していない区画の結果とMetalテクスチャを再利用します。フィルター有効時の画面取得は最大20回/秒とし、ゲストCPU・音声の更新頻度は変えません。
- Pagesの現行ガイド・FAQ・画像は `docs/` にあります。古いデザインへ戻さず、現在の文面と操作画面を確認して更新してください。

## 未解決・確認が必要なこと

- **全画面の長押しメニューから一時停止できないという実機報告は未解決**です。シミュレーターでは再現せず、製品コードの修正は行っていません。長押しだけではメニューを表示し、そこから「一時停止」を選ぶ仕様です。[確認条件と限界](docs/fullscreen-menu-verification.md)を参照してください。
- モザイクの実ゲームでの精度・実機での引っかかり改善は、シミュレーターの成功だけで確認済みとしないでください。細かい切り出しで文脈が失われる場合は大区画の保護を維持します。成人向け／残酷描写の完全な検出を保証しません。
- Issue #10は手動タイトル画面登録と一覧サムネイルで代替し、クローズ済み。#21・#24・#25はこの記録時点で未完了です。作業前にGitHub上の最新状態を確認してください。
- NASの実接続、端末ロック解除、署名など、別のMacでそのまま引き継がれない状態があります。過去のスクリーンショットを現在の動作証拠にしないでください。

## 検証コマンド

```sh
cmake -S . -B build/native -DCMAKE_BUILD_TYPE=Release
cmake --build build/native --parallel 4
ctest --test-dir build/native --output-on-failure
```

起動済みの検証用シミュレーターのUDIDを指定します。これらは同じBundle IDのアプリをインストールするため、私用のゲーム・セーブを入れた端末ではなく検証用を使用してください。

```sh
./tools/test_ios_simulator.sh SIMULATOR_UDID
./tools/test_content_filter_simulator.sh SIMULATOR_UDID
xcodebuild test -project build/ios-iphonesimulator/PC98PLAYER.xcodeproj \
  -scheme PC98PLAYERiOS -configuration Debug \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -only-testing:PC98PLAYERiOSUITests/FullscreenMenuUITests CODE_SIGNING_ALLOWED=NO
```

受付サーバーはNode.js 24以降を使います。以下はローカル検証で、メールやIssueを送信しません。

```sh
cd server/feedback
npm ci
npm test
npm run test:runtime
```

30件のプロトコルテスト、workerd/D1の認証・重複送信テスト、ネイティブの `feedback_error_smoke` は統合前に成功しています。全画面UIテストも統合前のiPhone・Duoシミュレーターで成功。統合後のCI結果は対象PRのChecksを参照してください。

## 受付・配布の境界

- 受付URL：`https://feedback.three-sisters.ai/v1/feedback`。設定・Secret名・運用手順は [docs/feedback-vps.md](docs/feedback-vps.md)。Secretの値はGitや会話へ出さないでください。
- `IOS_FEEDBACK_URL` を指定しないローカルビルドは送信先未設定です。匿名とXは開発者宛てメール、GitHubは本人確認と公開確認後のIssueです。通常の動作確認で実報告を勝手に送信しないでください。
- App StoreアプリID `6826817332`、Bundle ID `jp.pc98player.ios`。署名は担当者のMacのXcode／キーチェーンを使います。
- この引き継ぎのためのmain統合では、TestFlight・App Storeへの新ビルド送信やCloudflareの再デプロイは行いません。配布作業はその時点のユーザー指示に従ってください。
- 共有コアのBIOS不要方針、Apple側での起動パス変換、ゲームキャッシュとセーブの分離を保持してください。
