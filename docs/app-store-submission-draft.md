# App Store申請用下書き

対象: RetroDOS Player 0.2.0（名称変更対応案）
状態: 2026年10月29日のリジェクト対応。以下は再提出用の原稿で、App Store Connectへの反映・再提出は未完了。

## 日本語メタデータ

名前: RetroDOS Player
サブタイトル: レトロなDOSゲームを手元で
キーワード: DOS,レトロ,ゲーム,エミュレータ,キーボード,マウス,NAS,16色,256色
サポートURL候補: https://github.com/koshikawa-masato/PC98PLAYER-iOS/issues

### 概要

RetroDOS Playerは、日本の16ビットパソコン向けDOSソフトウェアに対応する互換プレイヤーです。
BIOSやROMファイルを追加せずに使える独自の互換実装を搭載しています。
すべてのソフトウェアの動作を保証するものではありません。

・レトロなモニター表示と日本語ソフトキーボード
・複数キーの同時押し、VF1〜VF5、テンキー、外付けキーボード入力
・16色／256色表示、OPN／OPNA音源の切り替え
・縦画面、横画面、ダブルタップによる全画面表示
・ドラッグによるマウス移動、一本指の左クリック、二本指の右クリック
・保存と読込に対応した8つのステートスロット

ゲームデータは同梱していません。利用する権利のあるソフトウェアをご自身でご用意ください。
「開く」から、この端末内やファイルアプリで接続したNASのゲームフォルダを選択します。
Mac／NAS上の元データは書き換えず、端末には実行用キャッシュを作成し、保存データを別に保持します。
ゲームデータなしでも「場所」からオリジナルDOSデモを起動し、画面表示やキーボード入力を試せます。

本アプリは独立した開発者による互換プレイヤーです。

## App Reviewメモ案

No sign-in is required. No BIOS, ROM, or third-party game files are included or required for the built-in demo.

1. Launch RetroDOS Player.
2. Tap 場所 (Locations) below the monitor.
3. Select オリジナルDOSデモ (Original DOS demo).
4. The monitor displays RetroDOS Player and keyboard instructions.
5. Tap letter keys. The DOS demo echoes the input. Shift can be held with another key or toggled by a single tap.
6. Rotate the iPhone to landscape to display the monitor on the left and keyboard on the right.
7. Double-tap the monitor to enter fullscreen; double-tap again to return.
8. Long-press the monitor in fullscreen to open Pause / Reset. After pausing through this menu, a single tap resumes without passing that tap to the guest.

For user-supplied software, tap 開く (Open) and select a folder containing PC98PLAYER.INI and its Start program. Data is selected through the iOS document picker; a NAS can be connected using the system Files app. The original folder remains unchanged.

## プライバシーポリシー本文案

RetroDOS Playerは、利用者アカウントの作成を必要とせず、広告・アクセス解析・トラッキング用SDKを組み込んでいません。
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

## リジェクト対応・審査回答案

Thank you for your review. We have changed the app name to RetroDOS Player and revised the subtitle to remove the term “iPhone”. We have also removed the previous platform branding from the promotional description and keywords. The app is an independently developed compatibility player; no BIOS, ROM, or third-party game data is bundled. The built-in DOS demo is original and can be used without external files.

The internal configuration filename PC98PLAYER.INI is retained for compatibility with existing user data and the original open-source project. It is not the app's display name.

注意: 上記回答は反映後に送信する。新ビルドのアップロード、スクリーンショット差し替え、公開ポリシー更新は未完了。
元プロジェクトの著作権表示・MITライセンスは維持する。
