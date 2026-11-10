# 利用者向けサイト / GitHub Pages

## 2026年11月10日 フィードバック案内

トップの呼びかけと `#feedback` の3ステップ、FAQ `#feedback-faq` / `#feedback-screenshot` にアプリ内報告の手順を追加しました。`tutorial/images/feedback-*.png` の4枚は0.2.4（ビルド50）のiPhoneシミュレーターをDevice Hubで撮影した実画面です。報告本文は記入例、添付候補はオリジナルDOSデモで、説明用の報告は送信していません。

匿名・Xは開発者メール、GitHubは公開Issue、GitHubの画像は自動公開しない点を分けて説明しています。0.2.4公開前はTestFlightの操作例として案内し、App Store利用者には更新後の手順であることを明記します。公開を確認した時点で `feedback-version` の案内を更新してください。

リンク・画像の存在とページ内アンカー、スマートフォン幅での表示を確認してから公開します。アプリの送信経路は `docs/feedback-vps.md`、プライバシーは `docs/privacy-policy.txt` と同じ内容に保ちます。

`docs/index.html` が入口です。サイトのビルドは不要です。App Store の入手バッジには Apple 公式の日本語画像（tools.applemediaservices.com）を使用します。画像・動画・ZIP は相対パスのため、GitHub Pages のプロジェクトサイトのサブパスでも動作します。

## デザイン

昭和後期〜平成初期のパソコンをモチーフにしています。アイボリー筐体色・濃紺インク・4色ストライプ（赤／橙／黄／青）、CRT 風の動画セクション、ファンクションキー型の章ナビ、ウインドウ風タイトルバー付きカード、硬い影（オフセットシャドウ）を使います。本文はシステムフォントで可読性を保ち、見出し・ラベルだけドットフォントにしています。

- 見出しフォント：DotGothic16（SIL Open Font License 1.1、`assets/fonts/OFL.txt`）。外部フォント配信は使わず、ページで使う文字だけのサブセット（約50KB）を `assets/fonts/DotGothic16-subset.woff2` に同梱しています。
- 見出しに新しい漢字を追加したら再生成します（含まれない文字は代替フォントで表示されます）：

```sh
pip install fonttools brotli
curl -LO https://raw.githubusercontent.com/google/fonts/main/ofl/dotgothic16/DotGothic16-Regular.ttf
python3 tools/site/subset_font.py DotGothic16-Regular.ttf
```

- カーソル点滅などの動きは `prefers-reduced-motion` で停止します。

## 公開手順

1. GitHub リポジトリの Settings → Pages → Build and deployment で Source を **GitHub Actions** に設定します。
2. 変更を main に反映すると `.github/workflows/pages.yml` が `docs` を公開します。手動の場合は Actions の「Publish guide to GitHub Pages」で Run workflow を実行します。
3. Actions の成功と GitHub に表示される公開 URL で、画像・動画・ZIP・NAS ガイドを確認します。
4. App Store Connect のサポート URL を公開サイトの導入ガイドへ設定します。これは別途行う掲載情報の更新です。

標準構成の想定 URL は `https://koshikawa-masato.github.io/PC98PLAYER-iOS/` です。公開・利用可能になったことは GitHub の結果を見て確認してください。カスタムドメインは必須ではありません。既に Pages の公開方法がある場合は、その設定を確認してから変更してください。

## 画像・動画

- HTML の `img`、`video` で画像と MP4 を表示します。YouTube 等の `iframe` 埋め込みも可能ですが、現時点では外部プレーヤーを使いません。
- `videos/transfer-guide.mp4` は既存スクリーンショットによる24秒の無音スライド動画です。実操作の録画ではありません。日本語字幕を画像内に入れ、同内容の WebVTT も添付しています。
- 操作画像は2026年11月5日撮影の iPhone シミュレーター例です。App Store 最新版・iPad・横画面を新たに撮影したと誤認させる画像は追加していません。
- NAS は文字とデータフローで接続方法を案内します。NAS の実接続録画はありません。
- 最新版の iPhone 縦／対応モードの横、iPad 縦／横を撮影後、端末・向き・モード・アプリバージョンを添えて画面比較を追加してください。
- 実操作動画に差し替える場合は、個人名・NAS の実アドレス・認証情報が映らないよう撮影し、字幕とテキスト手順も合わせて更新してください。
- 自動再生は行わず、モバイルのインライン再生と標準コントロールを使用します。動画を見なくても本文だけで手順を追えます。

再生成：`python3 tools/site/make_video.py`（Pillow、ffmpeg/libx264、Linux の Noto Sans CJK フォントが必要）。動画は GitHub の1ファイル100 MiB制限を十分下回るサイズに保ちます。長い実操作動画が増えた場合は外部動画配信を検討してください。

## ローカル確認

リポジトリ直下で `python3 -m http.server 8000 --directory docs` を起動し、ローカルブラウザーで確認します。Pages 公開前のローカル確認は、公開後の動作確認を代替しません。

公式資料：
- https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages
- https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site
- https://developer.mozilla.org/en-US/docs/Web/HTML/Element/video

作成環境では公式ドキュメントの取得が403になりました。静的ファイルの配信とブラウザーの動画機能を使用し、実装の動作はローカルで検証します。

## 今回の検証結果

- ローカルHTTP配信をChromiumで開き、390／768／1440px幅で横方向のはみ出しがないこと、画像が読み込まれること、ページ内リンク先が存在することを確認しました。
- MP4の再生が進むこと、20秒へのシークができること、再生エラーがないことを確認しました。動画はH.264、1280×720、24秒、約183KBです。
- HTMLから参照するローカル画像・動画・字幕・CSS・ZIPの存在を確認しました。
- GitHub Pagesへの公開、公開後の動作、Safari／iPhone／iPad実機は未検証です。NASへの実接続、実操作録画も未実施です。

## 実操作版動画の収録・編集

ページを章別の配色・図解・番号付きステップで刷新しました。旧24秒スライドは補足として折りたたみ表示し、実操作版とは区別しています。実操作版の公開素材はまだありません。

必要な録画は次の3本です。iPhone/iPad の画面収録、または Mac の iOS シミュレーターで、アプリ・OS のバージョンを記録して撮影します。各章の途中は静止画に置き換えず、操作を連続して収録してください。

1. **デモ**：アプリを起動 →「一覧」→「デモ」→ キー入力 → 文字が出るまで。
2. **転送**：「ファイル」に届いた練習用ZIP → タップで展開 → アプリへ移動 →「開く」でフォルダ選択 → 起動 → キー入力。
3. **NAS**：「ファイル」→「サーバへ接続」→ デモ用NASに接続 → 共有表示 → アプリの「開く」で選択 → キャッシュ取得完了 → 起動。

NASは撮影用アカウントを使用し、パスワード入力や個人情報が映らない素材を用意します。認証区間を省略する場合は動画でその旨を示します。章の前後に1秒以上の余裕を残してください。画像を動かして操作録画に見せることはしません。

編集コマンド（既存ファイルは上書きしません）：

```sh
python3 tools/site/edit_recording.py demo.mov transfer.mov nas.mov --output /tmp/real-guide.mp4
```

映像を等速で保持して1280×720へ余白付きで収め、章間を0.6秒の暗転トランジションでつなぎます。各章の冒頭2.5秒は日本語の章タイトルを表示します。出力は無音です。撮影素材の音声を残す必要がある場合は、音声の編集を別途行ってください。

録画入手後は、実機またはシミュレーターの種別・撮影バージョンを付記してページへ掲載し、準備中表示を除去します。章タイトルだけで操作が説明しきれない部分には、収録内容に一致した字幕を追加します。現在の編集処理の動作確認は合成テスト映像で行い、実操作版の完成・検証とは区別します。
