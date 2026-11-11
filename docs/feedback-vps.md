# iOSのフィードバック受付（Cloudflare）

受付URLは `https://feedback.three-sisters.ai/v1/feedback`。Workers・D1・Turnstile・Email Serviceを使用する。XServer/VPSは不要。

## 利用者から見た動作

- オプションのバージョン、またはスクリーンショット保存画面から報告フォームを開く。
- 匿名：Turnstileで送信確認後、開発者へのメールとして受け付ける。ログイン不要。自動で公開Issueにはしない。
- X：Xで本人確認後、確認済みのユーザー名を付けて開発者へメールする。投稿・DM・メールアドレスへの権限は求めない。
- GitHub：本人確認と公開確認後、`koshikawa-masato/PC98PLAYER-iOS` にIssueを作る。作成者はGitHub Appで、確認済みの報告者を本文に記載する。
- スクリーンショットは任意。匿名・Xはメール添付。GitHub経路の画像は非公開受付に保管し、Issueへ自動公開しない。
- 受付番号はランダムなUUID。秘密鍵やログインコードではなく、問い合わせ時の照合番号。番号だけで報告を閲覧できるAPIはない。

## 認証と再送

アプリはシステムの `ASWebAuthenticationSession` を使用する。GitHub/Xのパスワードをアプリで入力・保存しない。

1. アプリが乱数のstate、S256 challenge、submission UUIDを作る。
2. Workerが独立したOAuth state/PKCEとSecure・HttpOnly・SameSite=Lax Cookieを発行する（10分）。
3. 固定のコールバックURLでstate・Cookieを照合し、取引を一度だけ消費する。プロバイダーのAPIでユーザーIDと名前を取得する。匿名ではTurnstileのhostname/action/cdataも検証する。
4. アプリへ5分有効の使い捨てコードを返す。コードはD1にハッシュだけ保存し、アプリのchallengeとsubmission UUIDに結び付ける。GitHub/Xのトークンはアプリ・DB・ログへ渡さない。
5. JSON POSTでコードとverifierを照合し、D1のトランザクションで報告保存とコード消費を行う。永続化できた場合のみ202と受付番号を返す。
6. 同じ報告の再送は同じ受付番号を返す。本文やverifierが違う再利用は409。外部配送の成否が不明な場合は `needs_review` とし、重複配送を避けるため自動再送しない。

外部APIへのリダイレクトは追従しない。Workersでサポートされる `redirect: manual` とHTTPステータス検証を使用する。

## デプロイ

Node.js 24以降、`server/feedback` で `npm ci`。Wrangler認証はMacのキーチェーンを使用する。Secretの値をGitへ入れない。

```sh
cd server/feedback
npm test
npm run test:runtime
npx wrangler d1 migrations apply retrodos-feedback --remote
npx wrangler deploy
```

`wrangler.jsonc` に公開ID・限定ドメイン・D1 binding・メール宛先を定義する。Secretは以下をWorkerに設定する。

| Secret | 用途 |
| --- | --- |
| GITHUB_CLIENT_SECRET | GitHub App OAuth |
| GITHUB_APP_PRIVATE_KEY | PKCS#8 PEM署名鍵 |
| X_CLIENT_ID / X_CLIENT_SECRET | X confidential client |
| TURNSTILE_SECRET | サーバー側確認 |
| RATE_HMAC_SECRET | IP/ユーザーのレート制限用HMAC鍵 |

GitHub Appは対象リポジトリ1件のみ、Issues read/writeと必須Metadata readだけを許可する。コードの変更権限はない。短命のinstallation tokenも対象repository IDとIssues writeに限定する。

コールバック（ワイルドカードなし）：

- `https://feedback.three-sisters.ai/v1/feedback/auth/github/callback`
- `https://feedback.three-sisters.ai/v1/feedback/auth/x/callback`

iOSのビルド時は `IOS_FEEDBACK_URL=https://feedback.three-sisters.ai/v1/feedback` を指定する。未設定・プロバイダー未設定の場合は送信を中止し、入力は保持する。アプリにはSecretを含めない。

## 保存・運用

本文・任意の画像・バージョン・認証済みユーザー情報を非公開D1へ保存する。画像はPNGのみ、最大2 MiB・4096辺・400万画素。任意の送信先URLや添付ファイルパスは受け付けない。

5分ごとのcronで未配送を処理し、期限切れ認証情報を削除する。受付DBの報告・添付は30日で削除する。メールと公開Issueにはこの削除期限は適用されない。生IPをDBへ保存せず、1時間単位のHMAC値で制限する。OAuthコードや本文を記録しないため、HTTP起動ログ・トレースは無効。

`needs_review` は自動配送されないため、運用者はD1で定期的に確認する。現在は自動アラート未実装。メール/GitHubに受付番号があるか確認し、届いていればdeliveredへ、届いていないことを確認できたものだけpendingへ戻す。状態だけを確認する例：

```sh
npx wrangler d1 execute retrodos-feedback --remote --command \
  "SELECT receipt,provider,status,created_at FROM reports WHERE status IN ('pending','delivering','needs_review') ORDER BY created_at"
```

停止時は `RECEPTION_ENABLED=false`（新規受付停止）と `DELIVERY_ENABLED=false`（配送停止）を設定してdeployする。直前の安定版へ戻す場合はWranglerのversion IDを記録してrollbackする。D1は破壊しない。認証失敗・重複配送・意図しない公開があれば即停止する。

## 検証

`test/feedback.test.mjs` はSQLiteを使った30件のプロトコル/不正入力/再送テスト。`test/runtime.mjs` は実際のworkerdとD1で認証コールバックと同時送信を確認する（外部プロバイダーはテスト応答、メール/Issueは作らない）。自動テストだけでは実際のOAuth設定・メール到着・iOS復帰は証明できないため、本番でテスト内容を明記した報告を使って別途確認する。


### 2026-11-10の確認記録

- ローカルの30件の自動テスト、workerd/D1結合テストが成功。CIワークフローを追加（GitHubでのCIは未実行）。
- GitHub Appの署名鍵を使い、短命トークンが対象リポジトリ1件だけに限定されていることを実APIで確認。
- iOS 27.0の検証用iPhoneシミュレータ、0.2.4ビルド50から匿名認証→アプリ復帰→受付番号表示→Gmail受信を確認。受付番号 `be497879-5ded-4530-b522-429455a92f05`。
- Safariのno-referrerフォームPOSTがOrigin:nullになる場合、およびCSPのform-actionで固定カスタムURLへの復帰が止まる場合を修正。Cookie/state/Turnstileの照合は維持。


iOSのPrivacyInfo.xcprivacyには、任意のフィードバックで扱うCustomer Support・Photos or Videos・User IDをアプリ機能のための取得として記載する。認証付き報告では本人に関連付くためLinked=true、Tracking=falseとする。

0.2.4（ビルド51）の提出時に、任意の報告本文・画像・ユーザー識別子・診断データに合わせてApp Store Connectのプライバシー回答を更新・公開済みです。アプリ内とPagesのポリシーも同じ内容に更新し、2026-11-11にApp Store公開を確認しました。次回データの扱いが変わる場合も、実装・マニフェスト・ポリシー・回答を揃えて更新してください。


- GitHubのiOS内ログイン→アプリ復帰→実Issue #23作成を確認。受付番号 `dab5bdfd-f7b9-449d-8edd-93a94a336bb3`。報告者は検証済みアカウント、投稿者は専用Botで、テストIssueは確認後にクローズ。
- Xの実認可→ `/2/users/me` による `@ponzu0147` の本人情報取得を確認。iOS内のXサインイン→アプリ復帰→受付番号表示→Gmail受信まで成功。受付番号 `f9c2664b-670c-4d53-a069-3d38ddfc42ed`、2026-11-10 19:15 JST。GitHub Issueにはせず、認証済みXハンドルを添えて開発者宛てメールだけに配送された。
- GitHubの取得失敗した旧署名鍵を失効し、ダウンロードした秘密鍵の一時ファイルも削除。Xの未使用app-only bearerを失効、未使用OAuth 1 APIキー/シークレットを明示承認に基づき更新。OAuth 2の設定には変更なし。

Cloudflare上の有効版は `89571327-11d5-4aa6-9f3c-ae3c417134fc`。
