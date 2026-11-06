# TestFlight配布

App Store Connect: https://appstoreconnect.apple.com/apps/6826817332/testflight

- Bundle ID: `jp.pc98player.ios`
- Apple Team: `8JN36X5T3B`
- 初回アップロード: 0.2.0 (3)、2026-10-25
- 内部テストグループ: 内部テスト（本人1名、ビルドは手動追加）
- 署名: Apple Distribution、`PC98PLAYER iOS App Store`プロファイル

## 次のビルドを作る

Xcode 27.1と配布証明書の秘密鍵、上記のApp Store配布プロファイルが必要です。
ビルド番号はアップロードのたびに増やします。

```sh
IOS_VERSION=0.2.0 IOS_BUILD_NUMBER=6 tools/archive_ios_testflight.sh
```

アーカイブ、UUID照合済みdSYM、IPAを`out/TestFlight/`へ作成します。
Transporterで`out/TestFlight/export/RetroDOS Player.ipa`を追加し、デリバリします。
証明書・秘密鍵・プロファイルはリポジトリへコミットしません。

## Appleでの処理後

TestFlightのiOSビルドで処理結果を確認し、内部テストグループへ追加します。
外部テストはテスト情報を記入し、AppleのBeta App Review承認が別途必要です。
App Storeへの本公開はこの手順では行いません。

配布版はReleaseビルドです。録音診断・スモークテスト用の起動引数とReplayKitは除外します。
ゲームデータ・BIOS・ROMは同梱せず、利用者がファイルアプリからフォルダを選択します。
設定保存とユーザーが選択したファイルの日時参照をPrivacyInfo.xcprivacyで申告しています。
元データはMac／NASに保持し、iPhone側はキャッシュ、セーブデータは別領域へ保存します。

## 既知の確認事項

縦画面と横画面の切り替え時に起きる音声の短い途切れは調査中です。
Appleへのアップロード成功と、外部テストの審査承認は別の状態です。

## App Store申請用ビルド

ビルド5は正式版Xcode 27.1（27A9275）とSDK 24A94232で作成しています。
27A9269で作成したビルド4はTestFlightでは利用できても、App Store提出前チェックでベータ版Xcodeとして拒否されました。正式版を指定し、新しいビルド領域を使ってください。

```sh
DEVELOPER_DIR=/path/to/GM-Xcode.app/Contents/Developer \
IOS_BUILD_ROOT=build/appstore-gm IOS_VERSION=0.2.0 IOS_BUILD_NUMBER=6 \
  tools/archive_ios_testflight.sh
```

`DEVELOPER_DIR`はコマンド単位で指定し、システムのXcode選択を変更する必要はありません。
Appleへ送るIPAのInfo.plistにあるDTXcodeBuild／DTSDKBuildも確認します。値を手で書き換えるのではなく、正式なツールチェーンでビルドします。

## 2026年10月29日 名称変更対応

ビルド6の表示名はRetroDOS Playerです。正式版Xcode 27.1 (27A9275)、SDK 24A94232でアーカイブ・配布署名・エクスポートを確認しました。Bundle IDと設定ファイル形式は維持しています。エクスポート後のIPA名も表示名に合わせて `RetroDOS Player.ipa` になります。旧名のIPAは以前のビルドなので選択しないでください。

## 統合版を GitHub Actions から配布する

PR #3（Apple起動パス）と PR #1（端末内フィルター）を統合しました。次のテスト版候補は **0.2.2 (11)** です。App Store Connect に同じ番号がある場合は、未使用の大きい番号を指定してください。

Settings → Secrets and variables → Actions に以下を登録します。値をチャットやリポジトリへ貼らないでください。

| Repository secret | 内容 |
|---|---|
| `APPLE_DISTRIBUTION_P12_BASE64` | 配布証明書と秘密鍵を含む p12 を改行なしの Base64 にしたもの |
| `APPLE_P12_PASSWORD` | p12 のエクスポートパスワード |
| `APPSTORE_PROFILE_BASE64` | Team `8JN36X5T3B` / Bundle ID `jp.pc98player.ios` 用 App Store 配布プロファイルの Base64 |
| `ASC_KEY_ID` | App Store Connect API キーの Key ID |
| `ASC_ISSUER_ID` | 同 API キーの Issuer ID |
| `ASC_PRIVATE_KEY` | 同 API キーの p8 本文。アップロード権限のあるキーを使用 |

Actions → **TestFlight** → Run workflow で version と build_number を指定します。配布設定用ファイルの main 更新でもワークフローが起動します。秘密情報の有無を確認後、コア／シミュレーター／Core ML・Metal テストを通し、署名・IPA出力・アップロードを実行します。認証素材は一時領域に展開し終了時に削除します。

アップロードとTestFlight配布完了は別です。Appleの処理完了後、App Store Connect の内部テストグループへビルドを追加してください。外部テストは Beta App Review が必要です。App Store 本番申請は行いません。

App Store の画面更新には、iOS ワークフローの **app-store-screenshots** 成果物を使います。実際のシミュレーター画面を iPhone／iPad の縦・横で撮影し、端末名と向きの記録を同梱します。画像を回転して横画面に見せる処理はしません。アップロード前に画面内容とApp Storeの要求サイズを確認し、配布対象バージョンと一致する画像を使用してください。App Store Connect 側の画像差し替えは別途必要です。
