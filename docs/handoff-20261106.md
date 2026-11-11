# Mac ローカルセッションへの引き継ぎ

更新日：2026-11-06（日本時間）。この文書作成前に確認した main は `dd786ef`。

## ユーザーの依頼と現在の目的

1. PR #1（端末内コンテンツフィルター）と #3（Apple 起動パス修正）を統合し、TestFlight で実機検証できるようにする。
2. App Store の紹介スクリーンショットを現在の表示に更新する。iPhone／iPad の縦画面・横画面を併記する。
3. ユーザーは配布用の証明書などが Mac ローカルにあると回答済み。ローカルの Xcode・キーチェーン・既存の Apple 認証を優先して使う。

「画面のアップデート」は **App Store 掲載画像の更新**という意味に訂正済み。アプリのデザイン自体を新しく作り替える依頼ではない。

TestFlight 用のビルド作成・署名・アップロードと掲載画像の更新は依頼済みなので、通常の手順を進めるたびに再確認する必要はない。App Store 本番への新ビルド提出・公開は今回の作業に含めない。OS のキーチェーン解除や Apple の追加認証など本人操作が必要なときだけ、その操作を依頼する。

## 最初に確認すること

- 現在のユーザー指示と適用される AGENTS.md を優先する。
- この Mac の既存チェックアウトを使う。`git status`・現在のブランチ・remote・HEAD を確認し、未コミット変更とローカルコミットを保護してから最新 main を取得・統合する。無条件の reset や checkout による上書きをしない。
- 他のエージェントも同じリポジトリで作業している。特に Pages の CSS／HTML とスクリーンショット処理を古い版へ戻さない。
- `xcodebuild -version`、選択 SDK、利用可能なシミュレーター、既存のコード署名 ID とプロファイルの有効期限・Team／Bundle ID を確認する。秘密鍵・パスワード・API キー本文を出力したりコミットしたりしない。
- クラウドの `/workspace`、仮想環境、stash はこの Mac にあると仮定しない。

## 統合済みの変更

- PR [#1](https://github.com/koshikawa-masato/PC98PLAYER-iOS/pull/1) と [#3](https://github.com/koshikawa-masato/PC98PLAYER-iOS/pull/3) は GitHub 上で **MERGED** を確認済み。元の宛先は `codex/ios-256-options` で、main にも統合済み。
- 起動パス変換は `apple/StartupPath.h` を iOS／macOS から呼ぶ。以前クラウドで試した core/player.cpp 内の変換を重ねて戻さない。現在のテストは EXE／COM／BAT、相対データ読込、`/Q` 引数、保存オーバーレイを検証する。
- `GameLibrary` は保存先共通のキャッシュ取得と Root 検証を行う。`Root=.`、フォルダ外参照、読み取り失敗と候補なしの案内を追加済み。キャッシュとセーブ分離を維持する。
- フィルターは成人向け／残酷描写を個別に有効化し、黒塗り・ぼかし・モザイクを選択できる。Core ML モデルは同梱、既定は両方オフ。詳細と限界は [docs/content-filter.md](docs/content-filter.md)。モデルのハッシュを確認済みで、再取得・再変換は通常不要。
- PR #5・#6 の Pages デザインと iPad 撮影修正も main に入っている。iPad 撮影は UI テストでシミュレーター自体を回転するため `IOS_UI_TESTS=ON` が必要。

## 検証済みの証拠

以下は `dd786ef` の結果。後続の変更があれば差分に応じて再検証する。

- [iOS／実モデル・Metal／画面撮影 CI](https://github.com/koshikawa-masato/PC98PLAYER-iOS/actions/runs/42174942510)：成功。iOS スモークテスト、Core ML・Metal テスト、実機向け未署名ビルド、iPhone／iPad 縦横撮影を含む。
- 同 CI の成果物：`app-store-screenshots`（5.77 MB）、`app-store-screens-logs`、`iOS-smoke-test`、`PC98PLAYER-iOS-development`。
- [macOS ビルド／CTest](https://github.com/koshikawa-masato/PC98PLAYER-iOS/actions/runs/42174942916)：成功。
- [Windows／256色テスト](https://github.com/koshikawa-masato/PC98PLAYER-iOS/actions/runs/42174942630)：成功。
- クラウドの Linux でも統合時点のコア・フィルター判定等8テストが合格。

CI 成功は、実機でのフィルター精度・発熱・速度や iCloud／NAS 実接続の確認を代替しない。上記成果物の画像は生成成功まで確認済みで、このクラウドセッションでは画像そのものの目視レビューや App Store へのアップロードはしていない。

## Mac で TestFlight へ配布する

既存手順：[docs/testflight.md](docs/testflight.md)。ローカル用スクリプトは `tools/archive_ios_testflight.sh`。`tools/ci_testflight.sh` は GitHub の一時 runner 用なので、普段使いの Mac でそのまま実行しない。

- App Store Connect：[RetroDOS Player / TestFlight](https://appstoreconnect.apple.com/apps/6826817332/testflight)
- Bundle ID：`jp.pc98player.ios`
- Apple Team：`8JN36X5T3B`
- 既存の配布証明書：Apple Distribution
- 既存プロファイル名：`PC98PLAYER iOS App Store`（実在・有効期限を確認する）

候補は **0.2.2 (11)**。番号は予約・アップロード済みではない。App Store Connect の最新ビルドを確認し、未使用で適切に増加する番号を選ぶ。スクリプト既定値の 0.2.1 (10) のまま実行しない。

以下は番号確認後の実行例。作業ディレクトリはリポジトリ直下。

```sh
IOS_VERSION=0.2.2 IOS_BUILD_NUMBER=11 \
  IOS_BUILD_ROOT=build/local-testflight \
  tools/archive_ios_testflight.sh
```

1. 正式版 Xcode と既存の署名を使用する。必要なら `DEVELOPER_DIR` をコマンド単位で指定する。署名エラーが出たらログから証明書の秘密鍵・プロファイル・チーム・Bundle ID の不一致を切り分ける。
2. アーカイブ／dSYM の UUID、IPA の Bundle ID・バージョン・ビルド番号、配布署名、フィルターモデルの同梱を確認する。古い出力をアップロードしない。
3. Mac の既存の認証方法で App Store Connect へ送る。既存手順は Transporter で `out/TestFlight/export/RetroDOS Player.ipa` をデリバリする方式。利用可能なら認証済みの CLI も使用できる。
4. Apple 側の処理完了・エラー有無を確認し、既存の内部テストグループへビルドを追加する。リポジトリ上の記録では「内部テスト」、本人1名、手動追加。現在のグループ構成を再確認する。
5. 実際に TestFlight でインストール可能になったことを確認してから「配布完了」と報告する。アップロード受付だけで完了扱いにしない。新しい外部テスターの招待は勝手に行わない。

### 実機確認の重点

- 成人向け／残酷描写を独立して切り替え、各効果・感度・再起動後の設定保持を確認。
- 初回推論待ちやゲーム変更・ステート読込・画面回転・全画面切替時に未加工画像や古い結果が出ないことを確認。
- 音声継続、表示遅延、発熱を記録。画像加工の成功を検出精度の証明にしない。
- 端末内／iCloud／NAS で直下とサブフォルダ起動を確認。Root 不正・起動候補なし・未ダウンロード・取得中断を区別し、不完全なキャッシュの公開や保存データの損失がないことを確認。

## App Store の紹介画面を更新する

1. 上記の `app-store-screenshots` 成果物を取得し、manifest と画像を目視確認する。端末・向き・表示内容・対象バージョンを合わせる。
2. 撮り直す場合は、リポジトリ直下で以下を実行する。各端末のシミュレーターが必要。画像の回転加工ではなく実際の端末表示を撮る。

   ```sh
   IOS_UI_TESTS=ON ./build_ios.sh
   python3 tools/capture_store_screens.py
   ```

3. 出力は `out/app-store-screens/`。iPhone 縦／横、iPad 縦／横の4枚と記録を確認し、App Store Connect が要求する解像度・端末枠に適合させる。シミュレーター画像の寸法を無条件に適合扱いしない。
4. App Store Connect の対象バージョンで掲載画像を更新する。公開中バージョンが編集不可なら、次回更新用素材として準備して制約を報告する。画像変更のために新しいバイナリを本番審査・公開へ進めない。
5. マウス中心のゲームは全画面表示が便利なことも案内する。ゲーム画面のダブルタップで切り替え、再ダブルタップで戻る。

利用者向けガイド：[GitHub Pages](https://koshikawa-masato.github.io/PC98PLAYER-iOS/)。NAS 接続・全画面操作・App Store バッジは掲載済み。必要な素材更新では、他エージェントが作った最新デザインを保持する。

## クラウドで残った制約

- TestFlight の [クラウド実行](https://github.com/koshikawa-masato/PC98PLAYER-iOS/actions/runs/42159363224) は署名用 Actions Secrets 6項目がなく停止。アプリのビルド失敗ではない。
- ユーザーは Mac ローカルの署名素材を使う方針。GitHub へ秘密鍵を登録し直すことを前提にしない。
- この作業では TestFlight アップロード、内部テストへの追加、App Store 掲載画像の差し替えはまだ完了していない。
- 実操作動画も未制作。旧24秒動画は静止画による補足。録画する場合はデモ起動／転送／NAS 接続を連続収録し、`tools/site/edit_recording.py` で章タイトルと暗転を付けられる。TestFlight と掲載画像の作業を先に進める。

## 引き継ぎ後に残す記録

実施コミット、使用 Xcode、バージョン／ビルド番号、実機・OS、テスト結果、アップロード結果、Apple の処理結果、TestFlight の利用可能状態、画像更新の状態をこの文書または配布記録へ追記する。秘密情報は記録しない。
