# TestFlight配布

## 2026年11月10日：0.2.4（ビルド51）

エラー時のフィードバック案内と、初期オフ・プレビュー可能な任意の診断JSONを追加。Transporterで21:00 JSTに送信し、Appleの処理完了後に既存の内部テストグループへ追加しました。ビルド50の審査提出を差し替え、ビルド51をApp Storeへ提出しました。2026年11月11日に0.2.4の公開を確認しました。

- AppleビルドID：`1e724c87-293c-4f58-be40-b7db2bcce8e8`。
- 提出ID：`d218c377-dafd-4472-a4d5-e35cdbb14a5d`。
- IPA SHA-256：`ee1f27e103a2224669b3acdb631c283163339e5bb1df0d825676a15eefabab48`。
- HEAD `144e60e` とローカル変更。配布ソースのコピーとファイルハッシュを `out/TestFlight/build-51-sources/`、`out/TestFlight/build-51-record.json` に保存。
- 署名検証、実コアを使うエラー判定・JSONテスト、既存iOSスモーク46項目、受付サーバー30テストが通過。シミュレーターでエラー案内・フォーム・JSONプレビュー・閉じた後の再開を確認。
- 新しいエラー報告機能の実機確認および診断JSONを含む実送信は未実施。任意のゲームのフリーズやiOSアプリ自体のクラッシュは検出対象外。
- 任意診断を含むプライバシー回答とPagesポリシーを公開済み。
- [App Store審査提出](https://appstoreconnect.apple.com/apps/6826817332/distribution/reviewsubmissions/details/d218c377-dafd-4472-a4d5-e35cdbb14a5d)

## 2026年11月10日：0.2.4（ビルド50）

認証付きフィードバック版をTransporterでアップロード（19:57 JST）し、Appleの処理完了後に既存の「内部テスト」グループ（1名）へ追加。「テスト中」と表示されることを確認。テスト内容も登録済み。

- ソース：`codex/ios-title-catalog`、HEAD `0b8b836` とローカル変更。今回の配布に伴うcommit/pushは未実施。
- Xcode 27.2（27B52）／SDK 24B8118、Apple Distribution／PC98PLAYER iOS App Storeプロファイル。
- 受付先：`https://feedback.three-sisters.ai/v1/feedback`。
- 匿名／Xのメール受信、GitHubのIssue作成、iOS認証画面からのアプリ復帰を検証用シミュレーターで確認。自動テスト30件とworkerd/D1結合テストも成功。
- アプリ内ポリシーとプライバシーマニフェストに任意の報告本文・画像・ユーザーIDの取扱いを反映。この時点ではApp Store Connectの本番プライバシー回答は未更新でしたが、ビルド51の提出時に更新・公開済みです。
- 配布IPAの署名・Bundle ID・バージョン・ビルド番号・受付URL・dSYM UUID・マニフェスト同梱を確認。
- IPA SHA-256：`d2d3fa093ca5883c89a2033041e0ce6ae430db1ab715308969828da0bad6ffaf`。
- [App Store Connect ビルド50](https://appstoreconnect.apple.com/teams/94f4f5a7-ccba-45ef-b191-497842793d88/apps/6826817332/testflight/ios/ed8de648-da3f-439e-bf9d-a7d01585d6e4)

ビルド50は20:29 JSTに本番審査へ提出しましたが、その後、上記ビルド51へ差し替えました。

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
