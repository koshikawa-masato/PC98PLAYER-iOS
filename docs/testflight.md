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
IOS_VERSION=0.2.0 IOS_BUILD_NUMBER=4 tools/archive_ios_testflight.sh
```

アーカイブ、UUID照合済みdSYM、IPAを`out/TestFlight/`へ作成します。
Transporterで`out/TestFlight/export/PC98PLAYER.ipa`を追加し、デリバリします。
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
