# App Store申請用下書き

対象: PC98PLAYER iOS 0.2.0 (5)
状態: TestFlight内部配信済み。App Store審査には未提出。

## 日本語メタデータ

名前: PC98PLAYER
サブタイトル: PC-98ソフトを手元のiPhoneで
キーワード: PC98,PC-98,PC9801,エミュレータ,レトロ,キーボード,DOS
サポートURL候補: https://github.com/koshikawa-masato/PC98PLAYER-iOS/issues

### 概要

PC98PLAYERは、PC-98用ソフトウェアをiPhoneやiPadで実行するためのプレイヤーです。
BIOSやROMファイルを追加せずに使える独自の互換実装を搭載しています。
すべてのソフトウェアの動作を保証するものではありません。

・PC-98をイメージした画面とソフトキーボード
・複数キーの同時押し、VF1〜VF5、テンキー、外付けキーボード入力
・16色／256色表示、OPN／OPNA音源の切り替え
・縦画面、横画面、ダブルタップによる全画面表示
・ドラッグによるマウス移動、一本指の左クリック、二本指の右クリック
・保存と読込に対応した8つのステートスロット

ゲームデータは同梱していません。利用する権利のあるソフトウェアをご自身でご用意ください。
「開く」から、この端末内やファイルアプリで接続したNASのゲームフォルダを選択します。
Mac／NAS上の元データは書き換えず、端末には実行用キャッシュを作成し、保存データを別に保持します。
ゲームデータなしでも「場所」からオリジナルDOSデモを起動し、画面表示やキーボード入力を試せます。

本アプリはNECの公式製品ではありません。

## App Reviewメモ案

No sign-in is required. No BIOS, ROM, or third-party game files are included or required for the built-in demo.

1. Launch PC98PLAYER.
2. Tap 場所 (Locations), the second button below the monitor.
3. Select オリジナルDOSデモ (Original DOS demo).
4. The monitor displays PC98PLAYER for iOS and keyboard instructions.
5. Tap letter keys. The DOS demo echoes the input. Shift can be held with another key or toggled by a single tap.
6. Rotate the iPhone to landscape to display the monitor on the left and keyboard on the right.
7. Double-tap the monitor to enter fullscreen; double-tap again to return.
8. Long-press the monitor in fullscreen to open Pause / Reset. After pausing through this menu, a single tap resumes without passing that tap to the guest.

For user-supplied software, tap 開く (Open) and select a folder containing PC98PLAYER.INI and its Start program. Data is selected through the iOS document picker; a NAS can be connected using the system Files app. The original folder remains unchanged.

## プライバシーポリシー本文案

PC98PLAYER iOSは、利用者アカウントの作成を必要とせず、広告・アクセス解析・トラッキング用SDKを組み込んでいません。
アプリ自体がゲームデータ、キー入力、セーブデータを開発者のサーバーへ送信することはありません。

利用者がファイルアプリで選択したゲームフォルダを読み込み、実行用データを端末のキャッシュに保存します。
ゲームの保存データとステートは端末のアプリ領域へ保存し、ゲームの元データとは分けて管理します。
設定やフォルダへのアクセス情報も端末内へ保存します。
NAS・クラウドのファイル提供サービスを選択した場合、そのサービスとの通信およびデータの取り扱いには、各サービス提供者の方針が適用されます。

本体キャッシュはアプリの「場所」から消去できます。この操作では保存データは消去しません。
アプリを削除すると、OSの通常の動作に従って端末内のアプリデータが削除されます。
バックアップやクラウド上のコピーの扱いは、端末と利用サービスの設定に従います。

お問い合わせ先候補: https://github.com/koshikawa-masato/PC98PLAYER-iOS/issues
GitHubへ問い合わせる場合は公開されるため、個人情報やゲーム本体を投稿しないでください。

## 提出前の残作業

- App Store Connectへ再ログインして最新の必須項目を確認
- 無料／有料と配信地域を決定
- プライバシーポリシーを公開URLへ設置し、アプリ内からも参照可能にする
- App Privacy回答、年齢区分、カテゴリ、権利情報を実装と配布内容に合わせて入力
- 審査用連絡先を設定（電話番号等はこのファイルへ記録しない）
- オリジナルデモを使ったiPhone／iPad等の必須スクリーンショットを取得・登録
- App Storeのバージョンとビルド0.2.0 (5)の選択を確認
- 縦横切り替え時の短い音声の途切れは既知。配布判断前に確認

Appleによる承認は未取得。この下書きの作成は審査提出や承認を意味しません。
